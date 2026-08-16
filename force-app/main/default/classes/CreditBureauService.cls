/**
 * Action 2: pull credit bureau (CRI) data for a loan application, store it as an immutable
 * Credit Check, and audit the access in a way that a later failure cannot erase.
 *
 * Three things happen per application, in this order:
 *   1. The bureau is asked for a file, through the CreditBureauClient interface.
 *   2. Any previous Credit Check for that application is flipped to Is_Latest__c = false and a
 *      new one is inserted with Is_Latest__c = true. History is kept; only the pointer moves.
 *   3. A Credit_Check_Logged__e platform event is published recording who accessed what and why.
 *
 * Step 3 is the part worth explaining. The event is declared Publish Immediately, so it leaves
 * this transaction at the moment publish() executes rather than at commit. Its subscriber
 * (CreditCheckLoggedTrigger) therefore writes the Credit_Check_Log__c row in a separate
 * transaction, and that row survives even if everything above it rolls back. A credit bureau
 * access is a disclosure of someone's regulated CRI data: it happened whether or not our
 * database kept the result, so the record of it must not be undoable by our own failure.
 *
 * The honest limit of that claim: immediate publish makes the audit decoupled and retried, not
 * literally unloseable. The subscriber's insert is its own transaction with its own failure
 * modes, and a platform event can be dropped if the bus is exhausted. The guarantee is that a
 * rollback here cannot take the audit with it — not that the audit is unconditional.
 *
 * Writes run in system context. Credit_Check__c is granted Create-but-not-Edit so that no analyst
 * can revise a bureau result after the fact, but the Is_Latest__c flip on the previous record is
 * an update by definition. Rather than widen the permission set and lose the insert-only property
 * for everyone, the pointer flip runs as a system operation here. The control is that this class
 * writes exactly one field on exactly one prior record, and never touches the CRI values.
 */
public with sharing class CreditBureauService {
    /** Recorded on every audit row. Access_Type__c records the mechanism; this records the reason. */
    @TestVisible
    private static final String ACCESS_PURPOSE = 'Credit assessment';

    /** Credit_Check_Log__c.Access_Type__c is a restricted picklist of Pull and View. */
    @TestVisible
    private static final String ACCESS_TYPE_PULL = 'Pull';

    /**
     * The bureau. Swapped in tests, and swapped for a real EquifaxClient in production by
     * changing this one line. Everything below depends on the interface only.
     */
    @TestVisible
    private static CreditBureauClient client = new MockEquifaxClient();

    /** What the caller gets back: enough to answer "did it work and what was the score". */
    public class Result {
        @InvocableVariable(label='Loan Application Id')
        public Id loanApplicationId;

        @InvocableVariable(label='Credit Check Id')
        public Id creditCheckId;

        @InvocableVariable(label='Credit Score')
        public Integer creditScore;

        @InvocableVariable(label='Credit Check Reference')
        public String creditCheckReference;

        @InvocableVariable(label='Succeeded')
        public Boolean succeeded = false;

        @InvocableVariable(label='Status Message')
        public String statusMessage;
    }

    /**
     * Entry point for Flow and, later, for an agent action. Not wired to any agent topic yet —
     * that is a separate change.
     */
    @InvocableMethod(
        label='Run Credit Bureau Check'
        description='Pulls credit bureau (CRI) data for a loan application, stores it as a new immutable Credit Check marked as the latest, and publishes an access audit event.'
    )
    public static List<Result> run(List<Id> loanApplicationIds) {
        return pull(loanApplicationIds);
    }

    /**
     * Bulk-safe: one query for the applications, one delegated bureau call for the whole batch,
     * one update for the flips, one insert for the new checks, one publish for the audit.
     */
    public static List<Result> pull(List<Id> loanApplicationIds) {
        List<Result> results = new List<Result>();
        if (loanApplicationIds == null || loanApplicationIds.isEmpty()) {
            return results;
        }

        Set<Id> applicationIds = new Set<Id>(loanApplicationIds);
        List<Loan_Application__c> applications = [
            SELECT Id, Name, Borrower_Type__c
            FROM Loan_Application__c
            WHERE Id IN :applicationIds
            WITH USER_MODE
        ];

        if (applications.isEmpty()) {
            return results;
        }

        Map<Id, BureauResponse> responses = client.fetch(applications);

        List<Credit_Check__c> newChecks = new List<Credit_Check__c>();
        List<Loan_Application__c> ordered = new List<Loan_Application__c>();

        for (Loan_Application__c application : applications) {
            BureauResponse response = responses.get(application.Id);
            if (response == null) {
                // The interface requires an entry per application; a client that breaks that
                // contract must not silently produce an unaudited gap.
                response = new BureauResponse();
                response.statusMessage = 'Bureau client returned no response for ' + application.Name + '.';
            }

            // A failed enquiry is still stored. It records that an attempt was made and lets the
            // Is_Latest__c pointer reflect the most recent state of knowledge, which is "unknown".
            newChecks.add(
                new Credit_Check__c(
                    Loan_Application__c = application.Id,
                    Credit_Check_Date__c = response.pulledAt == null ? Datetime.now() : response.pulledAt,
                    Credit_Check_Reference__c = response.reference,
                    Credit_Score__c = response.creditScore,
                    Full_Credit_Report__c = response.fullReport,
                    Is_Latest__c = true
                )
            );
            ordered.add(application);
        }

        flipPreviousLatest(applicationIds);
        List<Database.SaveResult> inserts = Database.insert(newChecks, false);

        List<Credit_Check_Logged__e> events = new List<Credit_Check_Logged__e>();
        User accessor = accessor();

        for (Integer i = 0; i < ordered.size(); i++) {
            Loan_Application__c application = ordered[i];
            BureauResponse response = responses.get(application.Id);
            Credit_Check__c check = newChecks[i];

            Result result = new Result();
            result.loanApplicationId = application.Id;
            result.creditCheckReference = check.Credit_Check_Reference__c;
            result.creditScore = check.Credit_Score__c == null ? null : Integer.valueOf(check.Credit_Score__c);
            result.statusMessage = response == null ? null : response.statusMessage;

            if (inserts[i].isSuccess()) {
                result.creditCheckId = inserts[i].getId();
                result.succeeded = response != null && response.success == true;
            } else {
                result.statusMessage = inserts[i].getErrors()[0].getMessage();
            }
            results.add(result);

            // Published whether or not the insert succeeded. The bureau was queried either way,
            // and an access we failed to store is precisely the one most worth having audited.
            events.add(
                new Credit_Check_Logged__e(
                    Loan_Application_Id__c = application.Id,
                    Loan_Application_Number__c = application.Name,
                    Credit_Check_Id__c = result.creditCheckId,
                    Credit_Check_Reference__c = check.Credit_Check_Reference__c,
                    Credit_Score__c = check.Credit_Score__c,
                    Accessed_By_Id__c = accessor.Id,
                    Accessed_By_Username__c = accessor.Username,
                    Access_Timestamp__c = Datetime.now(),
                    Purpose__c = ACCESS_PURPOSE
                )
            );
        }

        publish(events);
        return results;
    }

    /**
     * Clears the previous latest pointer. Runs in system mode deliberately — see the class
     * comment. Scoped to the exact field and the exact applications being pulled.
     */
    private static void flipPreviousLatest(Set<Id> applicationIds) {
        List<Credit_Check__c> priors = [
            SELECT Id
            FROM Credit_Check__c
            WHERE Loan_Application__c IN :applicationIds AND Is_Latest__c = TRUE
        ];
        if (priors.isEmpty()) {
            return;
        }
        for (Credit_Check__c prior : priors) {
            prior.Is_Latest__c = false;
        }
        List<Database.SaveResult> results = Database.update(priors, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(
                    LoggingLevel.ERROR,
                    'Could not clear Is_Latest__c on ' +
                    priors[i].Id +
                    ': ' +
                    results[i].getErrors()[0].getMessage()
                );
            }
        }
    }

    /** The running user, for the audit. Never the Automated Process user — see the trigger. */
    private static User accessor() {
        return [SELECT Id, Username FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
    }

    /**
     * A failure to publish is logged rather than thrown. Raising here would roll back the credit
     * check the user asked for because we could not write the note about it, which is the wrong
     * trade — and the platform retries the delivery of an accepted event on our behalf.
     */
    private static void publish(List<Credit_Check_Logged__e> events) {
        if (events.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = EventBus.publish(events);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(
                    LoggingLevel.ERROR,
                    'Credit check audit event rejected for ' +
                    events[i].Loan_Application_Number__c +
                    ': ' +
                    results[i].getErrors()[0].getMessage()
                );
            }
        }
    }
}
