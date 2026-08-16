/*
 * PrimeCapital Lending — demo seed data.
 *
 * Creates the three scenario chains that sit alongside the existing LA-0001 /
 * Maria Chen overstatement case, so each agent path has a record to demo against:
 *
 *   Daniel Okafor    secured_business    clean file, declared ~= verified   -> no escalation
 *   Priya Raman      unsecured_business  thin data, no verified figures     -> low confidence, escalates
 *   Tom Whitfield    unsecured_personal  different segment                  -> different policy pre-filter result
 *
 * Every applicant is fictional: example.com addresses and ACMA's reserved
 * fictional-drama mobile range (0491 570 xxx), which is not a real subscriber range.
 *
 * Computed fields — DSCR, disparity flag/percent, grounding confidence, escalation,
 * memo draft — are deliberately left blank. The deterministic calc that populates
 * them isn't built yet, and hand-faking those values would misrepresent the demo.
 *
 * Safe to re-run: any chain whose applicant already exists is skipped.
 *
 * Run with:  sf apex run -f scripts/apex/seed-demo-data.apex -o AGENTFORCE
 */

Id personAccountRt = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
    .get('PersonAccount')
    .getRecordTypeId();

Map<String, Account> applicantsByEmail = new Map<String, Account>{
    'daniel.okafor@example.com' => new Account(
        RecordTypeId = personAccountRt,
        FirstName = 'Daniel',
        LastName = 'Okafor',
        PersonBirthdate = Date.newInstance(1979, 11, 4),
        PersonEmail = 'daniel.okafor@example.com',
        PersonMobilePhone = '0491 570 218',
        PersonMailingStreet = '18 Kembla Street',
        PersonMailingCity = 'Wollongong',
        PersonMailingStateCode = 'NSW',
        PersonMailingPostalCode = '2500',
        PersonMailingCountryCode = 'AU',
        Description = 'Director/guarantor — Okafor Freight Services Pty Ltd (secured business working capital applicant). Demo seed data — fictional.'
    ),
    'priya.raman@example.com' => new Account(
        RecordTypeId = personAccountRt,
        FirstName = 'Priya',
        LastName = 'Raman',
        PersonBirthdate = Date.newInstance(1988, 6, 17),
        PersonEmail = 'priya.raman@example.com',
        PersonMobilePhone = '0491 570 337',
        PersonMailingStreet = '7 Lygon Street',
        PersonMailingCity = 'Brunswick East',
        PersonMailingStateCode = 'VIC',
        PersonMailingPostalCode = '3057',
        PersonMailingCountryCode = 'AU',
        Description = 'Director/guarantor — Raman Spice Imports Pty Ltd (unsecured trade finance applicant, incomplete financials). Demo seed data — fictional.'
    ),
    'tom.whitfield@example.com' => new Account(
        RecordTypeId = personAccountRt,
        FirstName = 'Tom',
        LastName = 'Whitfield',
        PersonBirthdate = Date.newInstance(1993, 2, 9),
        PersonEmail = 'tom.whitfield@example.com',
        PersonMobilePhone = '0491 570 461',
        PersonMailingStreet = '3/22 Gladstone Road',
        PersonMailingCity = 'Highgate Hill',
        PersonMailingStateCode = 'QLD',
        PersonMailingPostalCode = '4101',
        PersonMailingCountryCode = 'AU',
        Description = 'Consumer applicant — unsecured personal loan. Demo seed data — fictional.'
    )
};

// Skip anything already seeded so the script can be re-run safely.
for (Account existing : [
    SELECT PersonEmail FROM Account WHERE PersonEmail IN :applicantsByEmail.keySet()
]) {
    applicantsByEmail.remove(existing.PersonEmail);
}

if (applicantsByEmail.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'Seed data already present — nothing to do.');
    return;
}

insert applicantsByEmail.values();

Map<String, Id> applicantIdByEmail = new Map<String, Id>();
for (Account a : applicantsByEmail.values()) {
    applicantIdByEmail.put(a.PersonEmail, a.Id);
}

List<Loan_Application__c> applications = new List<Loan_Application__c>();

if (applicantIdByEmail.containsKey('daniel.okafor@example.com')) {
    applications.add(
        new Loan_Application__c(
            Applicant__c = applicantIdByEmail.get('daniel.okafor@example.com'),
            Security_Type__c = 'Secured',
            Borrower_Type__c = 'Business',
            Loan_Purpose__c = 'Working_Capital',
            Loan_Amount_Requested__c = 250000,
            Declared_Annual_Revenue__c = 980000,
            Verified_Annual_Revenue__c = 965000,
            Declared_Net_Income__c = 145000,
            Verified_Net_Income__c = 142000,
            Application_Status__c = 'In_Review',
            Submission_Date__c = Date.today().addDays(-6)
        )
    );
}

if (applicantIdByEmail.containsKey('priya.raman@example.com')) {
    // Verified figures deliberately absent — this is the thin-data / low-confidence file.
    applications.add(
        new Loan_Application__c(
            Applicant__c = applicantIdByEmail.get('priya.raman@example.com'),
            Security_Type__c = 'Unsecured',
            Borrower_Type__c = 'Business',
            Loan_Purpose__c = 'Trade_Finance',
            Loan_Amount_Requested__c = 120000,
            Declared_Annual_Revenue__c = 400000,
            Declared_Net_Income__c = 62000,
            Application_Status__c = 'New',
            Submission_Date__c = Date.today().addDays(-3)
        )
    );
}

if (applicantIdByEmail.containsKey('tom.whitfield@example.com')) {
    // Consumer file: no business revenue, so only the income figures are meaningful.
    applications.add(
        new Loan_Application__c(
            Applicant__c = applicantIdByEmail.get('tom.whitfield@example.com'),
            Security_Type__c = 'Unsecured',
            Borrower_Type__c = 'Consumer',
            Loan_Purpose__c = 'Other',
            Loan_Amount_Requested__c = 45000,
            Declared_Net_Income__c = 95000,
            Verified_Net_Income__c = 92000,
            Application_Status__c = 'New',
            Submission_Date__c = Date.today().addDays(-1)
        )
    );
}

insert applications;

Map<Id, Integer> scoreByApplicant = new Map<Id, Integer>();
Map<Id, String> referenceByApplicant = new Map<Id, String>();
if (applicantIdByEmail.containsKey('daniel.okafor@example.com')) {
    Id k = applicantIdByEmail.get('daniel.okafor@example.com');
    scoreByApplicant.put(k, 790);
    referenceByApplicant.put(k, 'EQFX-CRI-20260810-118204');
}
if (applicantIdByEmail.containsKey('priya.raman@example.com')) {
    Id k = applicantIdByEmail.get('priya.raman@example.com');
    scoreByApplicant.put(k, 640);
    referenceByApplicant.put(k, 'EQFX-CRI-20260813-226071');
}
if (applicantIdByEmail.containsKey('tom.whitfield@example.com')) {
    Id k = applicantIdByEmail.get('tom.whitfield@example.com');
    scoreByApplicant.put(k, 705);
    referenceByApplicant.put(k, 'EQFX-CRI-20260815-339518');
}

List<Credit_Check__c> checks = new List<Credit_Check__c>();
for (Loan_Application__c app : applications) {
    checks.add(
        new Credit_Check__c(
            Loan_Application__c = app.Id,
            Credit_Score__c = scoreByApplicant.get(app.Applicant__c),
            Credit_Check_Reference__c = referenceByApplicant.get(app.Applicant__c),
            Credit_Check_Date__c = System.now().addDays(-1),
            Is_Latest__c = true
        )
    );
}

insert checks;

System.debug(
    LoggingLevel.INFO,
    'Seeded ' +
    applicantsByEmail.size() +
    ' applicants, ' +
    applications.size() +
    ' loan applications, ' +
    checks.size() +
    ' credit checks.'
);
