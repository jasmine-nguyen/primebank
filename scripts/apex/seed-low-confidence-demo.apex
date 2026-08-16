/*
 * PrimeCapital Lending — low grounding confidence demo record.
 *
 * The four seeded applications all compute High or Medium confidence, so none of
 * them demonstrates escalation. LA-0003 (Priya Raman) was originally seeded as the
 * thin-data case, but the statement extraction demo later wrote verified figures
 * onto it and a bureau pull gave it a current credit check, so it now scores High.
 * Rather than strip evidence back off a record that earns its place in three other
 * demos, this adds a purpose-built incomplete application.
 *
 * Deliberately missing, one per confidence signal:
 *   - Verified_Annual_Revenue__c / Verified_Net_Income__c   (no statement processed)
 *   - Declared_Annual_Revenue__c and Security_Type__c        (incomplete intake form)
 *   - no Credit_Check__c at all                              (bureau never pulled)
 *
 * Expected result: Grounding_Confidence__c = 20.00, Grounding_Signals_Missing__c =
 * "verified financials; current credit check; complete applicant profile", and the
 * Escalate To Senior Analyst action routes it on those grounds.
 *
 * The applicant is fictional: an example.com address and ACMA's reserved
 * fictional-drama mobile range (0491 570 xxx), which is not a real subscriber range.
 *
 * Safe to re-run: skipped entirely if the applicant already exists.
 *
 * Run with:  sf apex run -f scripts/apex/seed-low-confidence-demo.apex -o AGENTFORCE
 */

final String APPLICANT_EMAIL = 'nathan.cole@example.com';

List<Account> existing = [SELECT Id FROM Account WHERE PersonEmail = :APPLICANT_EMAIL LIMIT 1];

if (!existing.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'Low confidence demo applicant already exists — nothing to do.');
} else {
    Id personAccountRt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
        .get('PersonAccount')
        .getRecordTypeId();

    Account applicant = new Account(
        RecordTypeId = personAccountRt,
        FirstName = 'Nathan',
        LastName = 'Cole',
        PersonEmail = APPLICANT_EMAIL,
        PersonMobilePhone = '0491 570 214',
        PersonMailingCity = 'Newcastle',
        PersonMailingStateCode = 'NSW',
        PersonMailingCountryCode = 'AU'
    );
    insert applicant;

    // Only the fields the object genuinely requires. Everything the confidence calc
    // looks for is left unset on purpose — this record is the missing-evidence case.
    Loan_Application__c application = new Loan_Application__c(
        Applicant__c = applicant.Id,
        Application_Status__c = 'New',
        Borrower_Type__c = 'Business',
        Loan_Purpose__c = 'Working_Capital',
        Loan_Amount_Requested__c = 180000,
        Submission_Date__c = Date.today()
    );
    insert application;

    Loan_Application__c stored = [
        SELECT Name, Grounding_Confidence__c, Grounding_Signals_Missing__c
        FROM Loan_Application__c
        WHERE Id = :application.Id
    ];
    System.debug(
        LoggingLevel.INFO,
        'Created ' +
        stored.Name +
        ' confidence=' +
        stored.Grounding_Confidence__c +
        ' missing=[' +
        stored.Grounding_Signals_Missing__c +
        ']'
    );
}
