/**
 * Writes the credit access audit row, in its own transaction.
 *
 * Credit_Check_Logged__e is a Publish Immediately event, so this runs decoupled from whatever
 * transaction published it and its insert survives that transaction rolling back. That is the
 * entire reason the audit goes through an event rather than a direct insert alongside the
 * Credit Check.
 *
 * Two consequences of running here rather than in the publishing transaction:
 *
 * 1. This executes as the Automated Process user, so UserInfo would report that user rather than
 *    whoever actually accessed the bureau data. The accessor is read from the event payload.
 *
 * 2. The Ids in the payload may no longer resolve. If the publishing transaction rolled back,
 *    Credit_Check_Id__c points at a record that was never committed, and setting a lookup to a
 *    non-existent Id throws INVALID_CROSS_REFERENCE_KEY — which would destroy the audit row in
 *    exactly the case this design exists to protect. So the lookups are populated only after
 *    confirming the targets exist, and are left null otherwise. The audit content itself is
 *    denormalised onto the log and never depends on those lookups resolving.
 */
trigger CreditCheckLoggedTrigger on Credit_Check_Logged__e(after insert) {
    Set<Id> creditCheckIds = new Set<Id>();
    Set<Id> loanApplicationIds = new Set<Id>();

    for (Credit_Check_Logged__e event : Trigger.new) {
        if (String.isNotBlank(event.Credit_Check_Id__c)) {
            creditCheckIds.add((Id) event.Credit_Check_Id__c);
        }
        if (String.isNotBlank(event.Loan_Application_Id__c)) {
            loanApplicationIds.add((Id) event.Loan_Application_Id__c);
        }
    }

    // Which of those actually survived. Anything missing here rolled back or was deleted.
    Set<Id> liveCreditChecks = new Map<Id, Credit_Check__c>(
            [SELECT Id FROM Credit_Check__c WHERE Id IN :creditCheckIds]
        )
        .keySet();
    Set<Id> liveApplications = new Map<Id, Loan_Application__c>(
            [SELECT Id FROM Loan_Application__c WHERE Id IN :loanApplicationIds]
        )
        .keySet();

    List<Credit_Check_Log__c> logs = new List<Credit_Check_Log__c>();

    for (Credit_Check_Logged__e event : Trigger.new) {
        Credit_Check_Log__c log = new Credit_Check_Log__c(
            Access_Type__c = 'Pull',
            Access_Timestamp__c = event.Access_Timestamp__c == null
                ? event.CreatedDate
                : event.Access_Timestamp__c,
            Purpose__c = event.Purpose__c,
            Credit_Check_Reference__c = event.Credit_Check_Reference__c,
            Credit_Score__c = event.Credit_Score__c,
            Loan_Application_Number__c = event.Loan_Application_Number__c,
            Accessed_By_Username__c = event.Accessed_By_Username__c
        );

        if (String.isNotBlank(event.Accessed_By_Id__c)) {
            log.Accessed_By__c = (Id) event.Accessed_By_Id__c;
        }
        if (String.isNotBlank(event.Credit_Check_Id__c) && liveCreditChecks.contains((Id) event.Credit_Check_Id__c)) {
            log.Credit_Check__c = (Id) event.Credit_Check_Id__c;
        }
        if (
            String.isNotBlank(event.Loan_Application_Id__c) &&
            liveApplications.contains((Id) event.Loan_Application_Id__c)
        ) {
            log.Loan_Application__c = (Id) event.Loan_Application_Id__c;
        }

        logs.add(log);
    }

    // Partial success: one malformed event must not stop the rest of the batch being audited.
    List<Database.SaveResult> results = Database.insert(logs, false);
    for (Integer i = 0; i < results.size(); i++) {
        if (!results[i].isSuccess()) {
            System.debug(
                LoggingLevel.ERROR,
                'Credit check audit row failed for reference ' +
                logs[i].Credit_Check_Reference__c +
                ': ' +
                results[i].getErrors()[0].getMessage()
            );
        }
    }
}
