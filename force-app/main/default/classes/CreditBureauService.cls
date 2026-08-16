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

    /**
     * What the action is asked for.
     *
     * A wrapper rather than a bare List<Id> parameter, because these descriptions are the only
     * thing an agent has to work out what to pass. A primitive input surfaces as an untyped list
     * with no explanation, so the model has to guess; a described variable tells it exactly which
     * record Id belongs here.
     */
    public class Request {
        @InvocableVariable(
            label='Loan Application Id'
            description='Record Id of the Loan Application to run the credit bureau check for. This is the 18-character Id of the Loan Application record the user is viewing or has named, not the LA-0001 application number and not the applicant\'s Account Id.'
            required=true
        )
        public Id loanApplicationId;

        public Request() {
        }

        public Request(Id loanApplicationId) {
            this.loanApplicationId = loanApplicationId;
        }
    }

    /** What the caller gets back: enough to answer "did it work and what was the score". */
    public class Result {
        @InvocableVariable(
            label='Loan Application Id'
            description='The Loan Application this result belongs to. Returned so a batch of results can be matched back to what was asked for.'
        )
        public Id loanApplicationId;

        @InvocableVariable(
            label='Credit Check Id'
            description='Record Id of the Credit Check that was created and stored. Empty if the result could not be saved.'
        )
        public Id creditCheckId;

        @InvocableVariable(
            label='Credit Score'
            description='Credit score returned by the bureau, on a 0-1200 scale. Empty when the bureau could not score the file or the enquiry failed — treat an empty score as unknown, never as zero.'
        )
        public Integer creditScore;

        @InvocableVariable(
            label='Credit Check Reference'
            description='The bureau enquiry reference for this pull, e.g. EQFX-CRI-20260816-194980. Quote this when referring to the enquiry.'
        )
        public String creditCheckReference;

        @InvocableVariable(
            label='Succeeded'
            description='True when the bureau returned a usable credit file and it was stored. False when the enquiry failed or the record could not be saved; check Status Message for the reason before relying on the score.'
        )
        public Boolean succeeded = false;

        @InvocableVariable(
            label='Status Message'
            description='Plain-language outcome of the enquiry, such as Clean file, Thin file adverse, or the reason it failed. Use this to explain the result rather than restating the raw score.'
        )
        public String statusMessage;
    }

    /**
     * Entry point for Flow and for an agent action. Not wired to any agent topic yet — that is a
     * separate change.
     *
     * Returns exactly one Result per Request, in the order they were given, including for
     * applications that could not be found. Invocable callers match inputs to outputs by index,
     * so a shorter list would silently misattribute results across a batch.
     */
    @InvocableMethod(
        label='Run Credit Bureau Check'
        description='Runs a credit bureau (Equifax CRI) enquiry for a Loan Application. Stores the result as a new immutable Credit Check marked as the latest, marks any previous check as no longer latest, and records the access in the credit audit log. Use this when a credit score or bureau file is needed for an application and there is no current check, or when a fresh pull has been asked for.'
        category='Credit Assessment'
    )
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }

        List<Id> applicationIds = new List<Id>();
        for (Request request : requests) {
            applicationIds.add(request == null ? null : request.loanApplicationId);
        }

        Map<Id, Result> byApplication = new Map<Id, Result>();
        for (Result result : pull(applicationIds)) {
            byApplication.put(result.loanApplicationId, result);
        }

        for (Id applicationId : applicationIds) {
            Result result = byApplication.get(applicationId);
            if (result == null) {
                result = new Result();
                result.loanApplicationId = applicationId;
                result.statusMessage = applicationId == null
                    ? 'No Loan Application Id was supplied.'
                    : 'No Loan Application found for Id ' + applicationId + '.';
            }
            results.add(result);
        }
        return results;
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
