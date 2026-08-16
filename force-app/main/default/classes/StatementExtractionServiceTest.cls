@IsTest
private class StatementExtractionServiceTest {
    private static final String GOOD_JSON = '{"verified_annual_revenue": 900000, "verified_net_income": 120500, "confidence": 0.9, "source_notes": "Sales revenue $900,000 under Income."}';

    private static Id personAccountRecordTypeId() {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('PersonAccount')
            .getRecordTypeId();
    }

    @TestSetup
    static void makeData() {
        Account applicant = new Account(
            RecordTypeId = personAccountRecordTypeId(),
            FirstName = 'Statement',
            LastName = 'Tester'
        );
        insert applicant;

        insert new Loan_Application__c(
            Applicant__c = applicant.Id,
            Application_Status__c = 'New',
            Borrower_Type__c = 'Business',
            Loan_Purpose__c = 'Working_Capital',
            Loan_Amount_Requested__c = 500000,
            Submission_Date__c = Date.today(),
            Declared_Annual_Revenue__c = 1200000
        );
    }

    private static Loan_Application__c reload() {
        return [
            SELECT
                Id,
                Verified_Annual_Revenue__c,
                Verified_Net_Income__c,
                Needs_Financial_Review__c,
                Statement_Extraction_Notes__c,
                Financial_Disparity_Percent__c
            FROM Loan_Application__c
            LIMIT 1
        ];
    }

    private static void runWith(String modelResponse) {
        StatementExtractionService.mockResponse = modelResponse;
        Loan_Application__c la = [SELECT Id FROM Loan_Application__c LIMIT 1];

        Test.startTest();
        StatementExtractionService.processBatch(
            new List<StatementExtractionService.Request>{
                new StatementExtractionService.Request(la.Id, '069000000000000AAA', 'FinStmt_Test.pdf')
            }
        );
        Test.stopTest();
    }

    @IsTest
    static void writesFiguresWhenConfidencePasses() {
        runWith(GOOD_JSON);

        Loan_Application__c la = reload();
        Assert.areEqual(900000, la.Verified_Annual_Revenue__c, 'Revenue should be written when confidence passes');
        Assert.areEqual(120500, la.Verified_Net_Income__c, 'Net income should be written when confidence passes');
        Assert.isFalse(la.Needs_Financial_Review__c, 'A confident extraction should not need review');
        Assert.isTrue(
            la.Statement_Extraction_Notes__c.contains('WRITTEN'),
            'Notes should record the write: ' + la.Statement_Extraction_Notes__c
        );
    }

    @IsTest
    static void triggersDisparityCalcOnWrite() {
        runWith(GOOD_JSON);

        // Declared 1,200,000 vs verified 900,000 -> +33.33%, computed by the before-save flow.
        Assert.areEqual(
            33.33,
            reload().Financial_Disparity_Percent__c,
            'Writing verified revenue should make the disparity flow recompute'
        );
    }

    @IsTest
    static void flagsForReviewWhenConfidenceBelowThreshold() {
        runWith('{"verified_annual_revenue": 900000, "verified_net_income": 120500, "confidence": 0.42, "source_notes": "figures illegible"}');

        Loan_Application__c la = reload();
        Assert.isNull(la.Verified_Annual_Revenue__c, 'Low confidence must not write a figure');
        Assert.isTrue(la.Needs_Financial_Review__c, 'Low confidence should flag for human review');
        Assert.isTrue(
            la.Statement_Extraction_Notes__c.contains('0.42'),
            'Notes should record the failing confidence: ' + la.Statement_Extraction_Notes__c
        );
    }

    @IsTest
    static void flagsForReviewWhenJsonIsMalformed() {
        runWith('I could not read this document, sorry.');

        Loan_Application__c la = reload();
        Assert.isNull(la.Verified_Annual_Revenue__c, 'Malformed JSON must not write a figure');
        Assert.isTrue(la.Needs_Financial_Review__c, 'Malformed JSON should flag for human review');
    }

    @IsTest
    static void flagsForReviewWhenModelReturnsNothing() {
        runWith(null);

        Assert.isTrue(reload().Needs_Financial_Review__c, 'An empty model response should flag for human review');
    }

    @IsTest
    static void flagsForReviewWhenAFigureIsNull() {
        runWith('{"verified_annual_revenue": 900000, "verified_net_income": null, "confidence": 0.95, "source_notes": "net income not stated"}');

        Loan_Application__c la = reload();
        Assert.isNull(la.Verified_Annual_Revenue__c, 'A partial extraction must write neither figure');
        Assert.isTrue(la.Needs_Financial_Review__c, 'A missing figure should flag for human review');
    }

    @IsTest
    static void parsesJsonWrappedInCodeFences() {
        runWith('```json\n' + GOOD_JSON + '\n```');

        Assert.areEqual(
            900000,
            reload().Verified_Annual_Revenue__c,
            'Fenced JSON should parse — models emit fences despite instructions'
        );
    }

    @IsTest
    static void parsesFiguresGivenAsStrings() {
        runWith('{"verified_annual_revenue": "900,000", "verified_net_income": "120500", "confidence": "0.9", "source_notes": ""}');

        Assert.areEqual(
            900000,
            reload().Verified_Annual_Revenue__c,
            'Figures returned as formatted strings should still parse'
        );
    }

    @IsTest
    static void doesNotClearAnExistingFigureOnFailedRead() {
        Loan_Application__c la = [SELECT Id FROM Loan_Application__c LIMIT 1];
        la.Verified_Annual_Revenue__c = 850000;
        update la;

        runWith('{"verified_annual_revenue": null, "verified_net_income": null, "confidence": 0.1, "source_notes": "unreadable"}');

        Assert.areEqual(
            850000,
            reload().Verified_Annual_Revenue__c,
            'A failed read must never clear a figure that was already verified'
        );
    }

    @IsTest
    static void triggerIgnoresNonPdfAttachments() {
        Loan_Application__c la = [SELECT Id FROM Loan_Application__c LIMIT 1];

        ContentVersion cv = new ContentVersion(
            Title = 'notes',
            PathOnClient = 'notes.txt',
            VersionData = Blob.valueOf('not a statement')
        );
        insert cv;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;

        Test.startTest();
        insert new ContentDocumentLink(
            ContentDocumentId = documentId,
            LinkedEntityId = la.Id,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
        Test.stopTest();

        Assert.isFalse(
            reload().Needs_Financial_Review__c,
            'A non-PDF attachment should not enter extraction at all'
        );
    }

    @IsTest
    static void triggerIgnoresAttachmentsOnOtherObjects() {
        Account applicant = [SELECT Id FROM Account LIMIT 1];

        ContentVersion cv = new ContentVersion(
            Title = 'FinStmt_Elsewhere',
            PathOnClient = 'FinStmt_Elsewhere.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 fake')
        );
        insert cv;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;

        Test.startTest();
        insert new ContentDocumentLink(
            ContentDocumentId = documentId,
            LinkedEntityId = applicant.Id,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
        Test.stopTest();

        Assert.isFalse(
            reload().Needs_Financial_Review__c,
            'A PDF attached to an Account must not touch any Loan Application'
        );
    }

    @IsTest
    static void enqueuesForPdfAttachedToLoanApplication() {
        Loan_Application__c la = [SELECT Id FROM Loan_Application__c LIMIT 1];

        ContentVersion cv = new ContentVersion(
            Title = 'FinStmt_Trigger_Test',
            PathOnClient = 'FinStmt_Trigger_Test.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 fake')
        );
        insert cv;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;

        Test.startTest();
        insert new ContentDocumentLink(
            ContentDocumentId = documentId,
            LinkedEntityId = la.Id,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
        Integer queued = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(1, queued, 'A PDF on a Loan Application should enqueue exactly one extraction job');
    }
}
