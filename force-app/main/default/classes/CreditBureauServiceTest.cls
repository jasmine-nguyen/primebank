@IsTest
private class CreditBureauServiceTest {
    /**
     * Stands in for the bureau. The point of CreditBureauClient being an interface is that this
     * exists without any HTTP mocking, and that the service under test never learns which
     * implementation it is talking to.
     */
    private class StubClient implements CreditBureauClient {
        private Integer score;
        private Boolean succeed;
        private Boolean returnNothing = false;

        StubClient(Integer score, Boolean succeed) {
            this.score = score;
            this.succeed = succeed;
        }

        public Map<Id, BureauResponse> fetch(List<Loan_Application__c> applications) {
            Map<Id, BureauResponse> responses = new Map<Id, BureauResponse>();
            if (returnNothing) {
                return responses;
            }
            Integer i = 0;
            for (Loan_Application__c application : applications) {
                BureauResponse response = new BureauResponse(
                    'EQFX-CRI-20260816-00000' + i,
                    score,
                    Datetime.now()
                );
                response.success = succeed;
                response.statusMessage = succeed ? 'Clean file' : 'Bureau unavailable';
                response.fullReport = '{"mock":true}';
                responses.put(application.Id, response);
                i++;
            }
            return responses;
        }
    }

    private static Id personAccountRecordTypeId() {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('PersonAccount')
            .getRecordTypeId();
    }

    @TestSetup
    static void makeData() {
        Account applicant = new Account(
            RecordTypeId = personAccountRecordTypeId(),
            FirstName = 'Bureau',
            LastName = 'Tester'
        );
        insert applicant;

        List<Loan_Application__c> applications = new List<Loan_Application__c>();
        for (Integer i = 0; i < 2; i++) {
            applications.add(
                new Loan_Application__c(
                    Applicant__c = applicant.Id,
                    Application_Status__c = 'New',
                    Borrower_Type__c = 'Business',
                    Loan_Purpose__c = 'Working_Capital',
                    Loan_Amount_Requested__c = 500000,
                    Submission_Date__c = Date.today()
                )
            );
        }
        insert applications;
    }

    private static Loan_Application__c firstApplication() {
        return [SELECT Id, Name FROM Loan_Application__c ORDER BY Name LIMIT 1];
    }

    private static List<Credit_Check_Log__c> logs() {
        return [
            SELECT
                Id,
                Access_Type__c,
                Access_Timestamp__c,
                Purpose__c,
                Credit_Check__c,
                Credit_Check_Reference__c,
                Credit_Score__c,
                Loan_Application__c,
                Loan_Application_Number__c,
                Accessed_By__c,
                Accessed_By_Username__c
            FROM Credit_Check_Log__c
        ];
    }

    /**
     * Builds an uninserted application carrying a chosen AutoNumber Name. Name is not writeable,
     * so the scenario tests below cannot use inserted records — a test org allocates whatever
     * number comes next, never LA-0001. Deserialising is the only way to exercise the mock's
     * scenario table against the numbers it is actually keyed on.
     */
    private static Loan_Application__c applicationNamed(String applicationNumber) {
        return (Loan_Application__c) JSON.deserialize(
            '{"attributes":{"type":"Loan_Application__c"},"Id":"' +
            fakeId(1) +
            '","Name":"' +
            applicationNumber +
            '","Borrower_Type__c":"Business"}',
            Loan_Application__c.class
        );
    }

    private static Id fakeId(Integer index) {
        return Id.valueOf(
            Loan_Application__c.SObjectType.getDescribe().getKeyPrefix() +
            '0'.repeat(12 - String.valueOf(index).length()) +
            String.valueOf(index) +
            'AAA'
        );
    }

    // ---------------------------------------------------------------- store + pointer

    @IsTest
    static void pullStoresTheBureauResultAsTheLatestCheck() {
        CreditBureauService.client = new StubClient(720, true);
        Loan_Application__c application = firstApplication();

        Test.startTest();
        List<CreditBureauService.Result> results = CreditBureauService.pull(new List<Id>{ application.Id });
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'One application should produce one result');
        Assert.isTrue(results[0].succeeded, 'A successful enquiry should report success');
        Assert.areEqual(720, results[0].creditScore, 'The result should carry the bureau score');

        List<Credit_Check__c> checks = [
            SELECT Id, Credit_Score__c, Is_Latest__c, Credit_Check_Reference__c, Full_Credit_Report__c
            FROM Credit_Check__c
            WHERE Loan_Application__c = :application.Id
        ];
        Assert.areEqual(1, checks.size(), 'The pull should insert exactly one Credit Check');
        Assert.areEqual(720, checks[0].Credit_Score__c, 'The bureau score should be stored');
        Assert.isTrue(checks[0].Is_Latest__c, 'A newly inserted check is the latest');
        Assert.isNotNull(checks[0].Full_Credit_Report__c, 'The raw bureau payload should be retained');
    }

    @IsTest
    static void secondPullFlipsThePreviousCheckAndKeepsIt() {
        CreditBureauService.client = new StubClient(700, true);
        Loan_Application__c application = firstApplication();

        Test.startTest();
        CreditBureauService.pull(new List<Id>{ application.Id });
        CreditBureauService.pull(new List<Id>{ application.Id });
        Test.stopTest();

        List<Credit_Check__c> checks = [
            SELECT Id, Is_Latest__c, CreatedDate
            FROM Credit_Check__c
            WHERE Loan_Application__c = :application.Id
        ];
        Assert.areEqual(2, checks.size(), 'History is immutable — the first check must still be there');

        Integer latest = 0;
        for (Credit_Check__c check : checks) {
            if (check.Is_Latest__c) {
                latest++;
            }
        }
        Assert.areEqual(1, latest, 'Exactly one check may be marked latest after a re-pull');
    }

    @IsTest
    static void pullIsBulkSafeAcrossApplications() {
        CreditBureauService.client = new StubClient(710, true);
        List<Loan_Application__c> applications = [SELECT Id FROM Loan_Application__c];
        List<Id> ids = new List<Id>();
        for (Loan_Application__c application : applications) {
            ids.add(application.Id);
        }

        Test.startTest();
        List<CreditBureauService.Result> results = CreditBureauService.pull(ids);
        Integer queries = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'Every application in the batch should return a result');
        Assert.areEqual(2, [SELECT COUNT() FROM Credit_Check__c], 'One check per application');
        Assert.isTrue(queries < 10, 'A two-record batch must not approach the query limit, used: ' + queries);
    }

    @IsTest
    static void pullIgnoresEmptyInput() {
        CreditBureauService.client = new StubClient(700, true);

        Test.startTest();
        Assert.areEqual(0, CreditBureauService.pull(new List<Id>()).size(), 'No input, no results');
        Assert.areEqual(0, CreditBureauService.pull(null).size(), 'Null input must not throw');
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Credit_Check__c], 'Nothing should have been written');
    }

    // ---------------------------------------------------------------- audit

    @IsTest
    static void pullWritesAnAuditRowThroughThePlatformEvent() {
        CreditBureauService.client = new StubClient(720, true);
        Loan_Application__c application = firstApplication();

        Test.startTest();
        CreditBureauService.pull(new List<Id>{ application.Id });
        Test.stopTest();

        List<Credit_Check_Log__c> audit = logs();
        Assert.areEqual(1, audit.size(), 'The pull should produce exactly one audit row');
        Assert.areEqual('Pull', audit[0].Access_Type__c, 'A bureau enquiry is a Pull');
        Assert.areEqual('Credit assessment', audit[0].Purpose__c, 'The permitted purpose should be recorded');
        Assert.areEqual(UserInfo.getUserId(), audit[0].Accessed_By__c, 'The running user is the accessor');
        Assert.areEqual(
            UserInfo.getUserName(),
            audit[0].Accessed_By_Username__c,
            'The username should be denormalised onto the row'
        );
        Assert.areEqual(720, audit[0].Credit_Score__c, 'The disclosed score should be captured as data');
        Assert.areEqual(
            application.Name,
            audit[0].Loan_Application_Number__c,
            'The application number should be captured as data'
        );
        Assert.isNotNull(audit[0].Credit_Check_Reference__c, 'The bureau reference should be captured as data');
        Assert.isNotNull(audit[0].Credit_Check__c, 'The lookup should resolve when the check committed');
    }

    /**
     * The headline behaviour. The Credit Check is rolled back after the event is published;
     * the audit row must still be there afterwards, because the bureau access happened whether
     * or not this org kept the result.
     */
    @IsTest
    static void auditSurvivesARollbackOfThePullThatCausedIt() {
        CreditBureauService.client = new StubClient(660, true);
        Loan_Application__c application = firstApplication();

        Test.startTest();
        Savepoint priorState = Database.setSavepoint();
        CreditBureauService.pull(new List<Id>{ application.Id });
        Assert.areEqual(1, [SELECT COUNT() FROM Credit_Check__c], 'The check exists before the rollback');
        Database.rollback(priorState);
        Test.stopTest();

        Assert.areEqual(
            0,
            [SELECT COUNT() FROM Credit_Check__c],
            'The rollback must have undone the Credit Check insert'
        );

        List<Credit_Check_Log__c> audit = logs();
        Assert.areEqual(1, audit.size(), 'The audit row must survive the rollback that destroyed the check');
        Assert.isNotNull(
            audit[0].Credit_Check_Reference__c,
            'The surviving row must still name what was accessed'
        );
        Assert.areEqual(660, audit[0].Credit_Score__c, 'The surviving row must still record what was disclosed');
        Assert.areEqual(
            application.Name,
            audit[0].Loan_Application_Number__c,
            'The surviving row must still name whose file was accessed'
        );
        Assert.isNull(
            audit[0].Credit_Check__c,
            'The lookup must be left null rather than pointing at a rolled-back Id, which would fail the insert'
        );
    }

    @IsTest
    static void aFailedEnquiryIsStillStoredAndStillAudited() {
        CreditBureauService.client = new StubClient(null, false);
        Loan_Application__c application = firstApplication();

        Test.startTest();
        List<CreditBureauService.Result> results = CreditBureauService.pull(new List<Id>{ application.Id });
        Test.stopTest();

        Assert.isFalse(results[0].succeeded, 'A failed enquiry should not report success');
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Credit_Check__c WHERE Credit_Score__c = NULL],
            'A failed enquiry is still recorded, without a score'
        );
        Assert.areEqual(1, logs().size(), 'A failed enquiry is still an access and must be audited');
    }

    @IsTest
    static void aClientReturningNothingStillProducesAnAuditRow() {
        StubClient stub = new StubClient(700, true);
        stub.returnNothing = true;
        CreditBureauService.client = stub;
        Loan_Application__c application = firstApplication();

        Test.startTest();
        CreditBureauService.pull(new List<Id>{ application.Id });
        Test.stopTest();

        Assert.areEqual(
            1,
            logs().size(),
            'A client breaking its contract must not create a silent unaudited gap'
        );
    }

    // ---------------------------------------------------------------- mock bureau scenarios

    @IsTest
    static void mockReturnsTheCleanScenarioForLA0001() {
        Map<Id, BureauResponse> responses = new MockEquifaxClient()
            .fetch(new List<Loan_Application__c>{ applicationNamed('LA-0001') });

        BureauResponse response = responses.values()[0];
        Assert.areEqual(720, response.creditScore, 'LA-0001 is the clean-file scenario, consistent with CC-0001');
        Assert.isTrue(response.success, 'A clean file is a successful enquiry');
        Assert.isTrue(
            response.fullReport.contains('LA-0001'),
            'The raw payload should name its subject: ' + response.fullReport
        );
    }

    @IsTest
    static void mockReturnsTheAdverseScenarioForLA0003() {
        Map<Id, BureauResponse> responses = new MockEquifaxClient()
            .fetch(new List<Loan_Application__c>{ applicationNamed('LA-0003') });

        BureauResponse response = responses.values()[0];
        Assert.areEqual(585, response.creditScore, 'LA-0003 is the thin-file adverse scenario that hooks escalation');
        Assert.isTrue(
            response.fullReport.contains('"defaults_recorded" : 2'),
            'The adverse payload should carry the defaults driving the escalation: ' + response.fullReport
        );
    }

    @IsTest
    static void mockFallsBackToADefaultForAnUnknownApplication() {
        Map<Id, BureauResponse> responses = new MockEquifaxClient()
            .fetch(new List<Loan_Application__c>{ applicationNamed('LA-9999') });

        Assert.areEqual(
            700,
            responses.values()[0].creditScore,
            'An application with no scenario should still be demonstrable'
        );
    }

    @IsTest
    static void mockReferenceMatchesTheBureauFormat() {
        Map<Id, BureauResponse> responses = new MockEquifaxClient()
            .fetch(new List<Loan_Application__c>{ applicationNamed('LA-0001') });

        String reference = responses.values()[0].reference;
        Assert.isTrue(
            Pattern.matches('EQFX-CRI-\\d{8}-\\d{6}', reference),
            'Reference should match the seeded EQFX-CRI-yyyymmdd-nnnnnn format, got: ' + reference
        );
    }

    @IsTest
    static void mockReturnsAnEntryForEveryApplicationItIsGiven() {
        List<Loan_Application__c> applications = new List<Loan_Application__c>{
            applicationNamed('LA-0001'),
            applicationNamed('LA-0003')
        };
        applications[1] = (Loan_Application__c) JSON.deserialize(
            '{"attributes":{"type":"Loan_Application__c"},"Id":"' +
            fakeId(2) +
            '","Name":"LA-0003","Borrower_Type__c":"Business"}',
            Loan_Application__c.class
        );

        Map<Id, BureauResponse> responses = new MockEquifaxClient().fetch(applications);

        Assert.areEqual(
            2,
            responses.size(),
            'The interface contract requires one response per application, so no access goes unaudited'
        );
    }

    // ---------------------------------------------------------------- invocable

    @IsTest
    static void invocableEntryPointRunsThePull() {
        CreditBureauService.client = new StubClient(715, true);
        Loan_Application__c application = firstApplication();

        Test.startTest();
        List<CreditBureauService.Result> results = CreditBureauService.run(
            new List<CreditBureauService.Request>{ new CreditBureauService.Request(application.Id) }
        );
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'The invocable should return one result per application');
        Assert.areEqual(715, results[0].creditScore, 'The invocable should surface the score to its caller');
        Assert.isNotNull(results[0].creditCheckId, 'The invocable should return the stored check Id');
    }

    /**
     * Invocable callers pair inputs to outputs by index. A missing application must still occupy
     * its slot, or a batch would attribute one application's credit result to another.
     */
    @IsTest
    static void invocableReturnsOneResultPerRequestEvenWhenAnApplicationIsMissing() {
        CreditBureauService.client = new StubClient(700, true);
        Loan_Application__c application = firstApplication();

        Test.startTest();
        List<CreditBureauService.Result> results = CreditBureauService.run(
            new List<CreditBureauService.Request>{
                new CreditBureauService.Request(fakeId(9)),
                new CreditBureauService.Request(application.Id)
            }
        );
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'Every request must get a result slot');
        Assert.isFalse(results[0].succeeded, 'An unknown application should report failure, not vanish');
        Assert.isTrue(
            results[0].statusMessage.contains('No Loan Application found'),
            'The empty slot should say why: ' + results[0].statusMessage
        );
        Assert.isTrue(results[1].succeeded, 'The real application should still succeed in the same batch');
        Assert.areEqual(
            application.Id,
            results[1].loanApplicationId,
            'Results must stay aligned with the requests that produced them'
        );
    }
}
