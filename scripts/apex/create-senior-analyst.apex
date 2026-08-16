/*
 * PrimeCapital Lending — senior credit analyst user.
 *
 * The escalation target for Action 6, and the org's first non-admin credit user.
 * That second role matters independently: the Credit Analyst permission set group
 * has only ever been assigned to a System Administrator, so its allowEdit=false on
 * Credit_Check__c has never actually been exercised against a restricted profile.
 * Admins are not blocked by object CRUD the way this user will be.
 *
 * Stock Standard User profile plus:
 *   Credit_Analyst PSG        — the same access an ordinary analyst gets
 *   Senior_Credit_Analyst     — adds Can_Clear_Escalation, which the PSG does not grant
 *
 * No Modify All Data, by virtue of the Standard User profile.
 *
 * Deliberately sets no password. A credential in a committed script is a credential
 * in version control; reset it from Setup > Users if an interactive login is needed.
 * The permission behaviour is verified without one, via System.runAs in
 * CreditEscalationTest.
 *
 * Safe to re-run: skipped entirely if the username already exists.
 *
 * Run with:  sf apex run -f scripts/apex/create-senior-analyst.apex -o AGENTFORCE
 */

final String SENIOR_USERNAME = 'senior.analyst.e8fb017a0cbd@primecapital.demo';

List<User> existing = [SELECT Id FROM User WHERE Username = :SENIOR_USERNAME LIMIT 1];

if (!existing.isEmpty()) {
    System.debug(LoggingLevel.INFO, 'Senior analyst already exists: ' + existing[0].Id);
} else {
    Profile standardUser = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

    User senior = new User(
        FirstName = 'Sofia',
        LastName = 'Marchetti',
        Alias = 'srcredit',
        Username = SENIOR_USERNAME,
        Email = 'senior.analyst@example.com',
        ProfileId = standardUser.Id,
        TimeZoneSidKey = 'Australia/Sydney',
        LocaleSidKey = 'en_AU',
        EmailEncodingKey = 'UTF-8',
        LanguageLocaleKey = 'en_US',
        IsActive = true
    );

    // Suppress the welcome email — this is a demo org, and the address is fictional.
    Database.DMLOptions options = new Database.DMLOptions();
    options.EmailHeader.triggerUserEmail = false;
    senior.setOptions(options);
    insert senior;

    PermissionSetGroup analystGroup = [
        SELECT Id
        FROM PermissionSetGroup
        WHERE DeveloperName = 'Credit_Analyst'
        LIMIT 1
    ];
    PermissionSet seniorSet = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'Senior_Credit_Analyst'
        LIMIT 1
    ];

    insert new List<PermissionSetAssignment>{
        new PermissionSetAssignment(AssigneeId = senior.Id, PermissionSetGroupId = analystGroup.Id),
        new PermissionSetAssignment(AssigneeId = senior.Id, PermissionSetId = seniorSet.Id)
    };

    System.debug(
        LoggingLevel.INFO,
        'Created senior analyst ' + senior.Id + ' (' + SENIOR_USERNAME + ') with Credit Analyst PSG + Senior Credit Analyst.'
    );
}
