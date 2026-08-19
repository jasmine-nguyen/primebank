@IsTest
private class CreditEscalationTest {
    private static Id personAccountRecordTypeId() {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('PersonAccount')
            .getRecordTypeId();
    }

    @TestSetup
    static void makeData() {
        insert new Account(
            RecordTypeId = personAccountRecordTypeId(),
            FirstName = 'Escalation',
            LastName = 'Tester'
        );
    }

    /**
     * Builds an application with every evidence signal present, then removes whichever the caller
     * wants missing. Written as a full record minus omissions rather than a minimal record plus
     * additions, so a test reads as "this file is complete except for X".
     */
    private static Loan_Application__c application(
        Boolean withVerifiedFinancials,
        Boolean withCompleteProfile,
        Boolean needsReview
    ) {
        Account applicant = [SELECT Id FROM Account LIMIT 1];
        Loan_Application__c la = new Loan_Application__c(
            Applicant__c = applicant.Id,
            Application_Status__c = 'New',
            Borrower_Type__c = 'Business',
            Loan_Purpose__c = 'Working_Capital',
            Loan_Amount_Requested__c = 500000,
            Submission_Date__c = Date.today(),
            Needs_Financial_Review__c = needsReview
        );
        if (withCompleteProfile) {
            la.Security_Type__c = 'Secured';
            la.Declared_Annual_Revenue__c = 1000000;
        }
        if (withVerifiedFinancials) {
            la.Verified_Annual_Revenue__c = 950000;
            la.Verified_Net_Income__c = 140000;
        }
        insert la;
        return la;
    }

    private static void addCurrentCreditCheck(Id loanApplicationId, Integer score) {
        insert new Credit_Check__c(
            Loan_Application__c = loanApplicationId,
            Credit_Check_Date__c = Datetime.now(),
            Credit_Check_Reference__c = 'EQFX-CRI-20260816-000001',
            Credit_Score__c = score,
            Is_Latest__c = true
        );
    }

    private static Loan_Application__c reload(Id loanApplicationId) {
        return [
            SELECT
                Id,
                OwnerId,
                Grounding_Confidence__c,
                Grounding_Signals_Missing__c,
                Current_Credit_Checks__c,
                Escalated__c,
                Escalation_Reason__c,
                Financial_Disparity_Flag__c
            FROM Loan_Application__c
            WHERE Id = :loanApplicationId
        ];
    }

    /**
     * User creation is a setup-object DML, so it cannot share a transaction with the custom-object
     * DML these tests do. The runAs wrapper puts it in its own context and avoids MIXED_DML.
     */
    private static User analyst(String alias, Boolean isSenior) {
        User created;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            created = new User(
                FirstName = 'Test',
                LastName = alias,
                Alias = alias,
                Username = alias + '.creditescalation@primecapital.test',
                Email = alias + '@example.com',
                ProfileId = standard.Id,
                TimeZoneSidKey = 'Australia/Sydney',
                LocaleSidKey = 'en_AU',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US'
            );
            insert created;

            Set<String> setNames = new Set<String>{ 'Loan_Application_Base', 'Credit_Check' };
            if (isSenior) {
                setNames.add('Senior_Credit_Analyst');
            }
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet ps : [SELECT Id FROM PermissionSet WHERE Name IN :setNames]) {
                assignments.add(new PermissionSetAssignment(AssigneeId = created.Id, PermissionSetId = ps.Id));
            }
            insert assignments;
        }
        return created;
    }

    /**
     * Grants a test user record-level Edit on an application.
     *
     * Without this the separation-of-duties tests fail on sharing rather than on the rule they are
     * meant to exercise: Loan_Application__c is Private, so once escalation moves ownership to the
     * senior, the junior cannot see the record at all. That is the design working — sharing is the
     * first line of defence and the validation rule the second — but a test of the rule has to get
     * past the first line to reach the second.
     */
    private static void shareWith(Id loanApplicationId, Id userId) {
        insert new Loan_Application__Share(
            ParentId = loanApplicationId,
            UserOrGroupId = userId,
            AccessLevel = 'Edit',
            RowCause = Schema.Loan_Application__Share.RowCause.Manual
        );
    }

    private static Flow.Interview.Escalate_To_Senior_Analyst escalate(Id loanApplicationId) {
        Flow.Interview.Escalate_To_Senior_Analyst flow = new Flow.Interview.Escalate_To_Senior_Analyst(
            new Map<String, Object>{ 'varLoanApplicationId' => loanApplicationId }
        );
        flow.start();
        return flow;
    }

    // ---------------------------------------------------------------- confidence bands

    @IsTest
    static void confidenceIsHighWhenEveryEvidenceSignalIsPresent() {
        Loan_Application__c la = application(true, true, false);
        addCurrentCreditCheck(la.Id, 720);

        Loan_Application__c stored = reload(la.Id);
        Assert.areEqual(100, stored.Grounding_Confidence__c, 'A complete evidence base should score High');
        Assert.isTrue(
            String.isBlank(stored.Grounding_Signals_Missing__c),
            'Nothing should be listed as missing: ' + stored.Grounding_Signals_Missing__c
        );
    }

    @IsTest
    static void confidenceIsMediumWhenOnlyTheProfileIsIncomplete() {
        Loan_Application__c la = application(true, false, false);
        addCurrentCreditCheck(la.Id, 720);

        Loan_Application__c stored = reload(la.Id);
        Assert.areEqual(50, stored.Grounding_Confidence__c, 'A usable file with a thin profile should score Medium');
        Assert.isTrue(
            stored.Grounding_Signals_Missing__c.contains('declared revenue'),
            'The missing declared revenue must be named by field: ' + stored.Grounding_Signals_Missing__c
        );
        Assert.isTrue(
            stored.Grounding_Signals_Missing__c.contains('security type'),
            'The missing security type must be named by field: ' + stored.Grounding_Signals_Missing__c
        );
        Assert.isFalse(
            stored.Grounding_Signals_Missing__c.contains('complete applicant profile'),
            'The grouped label must be gone — it hid which of three fields was absent: ' +
            stored.Grounding_Signals_Missing__c
        );
    }

    /**
     * LA-0004's exact shape, and the case that exposed the grouped labels: a file complete in
     * every respect except the applicant's own declared revenue. The old formula reported this as
     * "complete applicant profile", which reads as a thin applicant record and never mentions the
     * figure that is actually absent — the same figure the disparity control abstained for. The
     * two controls were covering each other correctly and the wording hid it.
     *
     * Asserted by exact equality, not contains: a grouped label concatenated alongside the
     * per-field one would still satisfy contains, and that is the failure being guarded against.
     */
    @IsTest
    static void aMissingDeclaredRevenueIsNamedRatherThanGroupedUnderTheProfile() {
        Loan_Application__c la = application(true, true, false);
        addCurrentCreditCheck(la.Id, 720);

        Test.startTest();
        la.Declared_Annual_Revenue__c = null;
        update la;
        Test.stopTest();

        Loan_Application__c stored = reload(la.Id);
        Assert.areEqual(50, stored.Grounding_Confidence__c, 'A sound evidence base with one profile gap is Medium');
        Assert.areEqual(
            'declared revenue',
            stored.Grounding_Signals_Missing__c,
            'The one absent field must be named, and nothing else claimed alongside it'
        );
    }

    @IsTest
    static void confidenceIsLowWhenVerifiedFinancialsAreMissing() {
        Loan_Application__c la = application(false, true, false);
        addCurrentCreditCheck(la.Id, 720);

        Loan_Application__c stored = reload(la.Id);
        Assert.areEqual(20, stored.Grounding_Confidence__c, 'No verified financials is a hard evidence failure');
        Assert.isTrue(
            stored.Grounding_Signals_Missing__c.contains('verified revenue'),
            'The missing verified revenue must be named by field: ' + stored.Grounding_Signals_Missing__c
        );
        Assert.isTrue(
            stored.Grounding_Signals_Missing__c.contains('verified net income'),
            'The missing verified net income must be named by field: ' + stored.Grounding_Signals_Missing__c
        );
    }

    @IsTest
    static void confidenceIsLowWhenTheReviewGateIsFlagged() {
        Loan_Application__c la = application(true, true, true);
        addCurrentCreditCheck(la.Id, 720);

        Loan_Application__c stored = reload(la.Id);
        Assert.areEqual(20, stored.Grounding_Confidence__c, 'An unreadable statement is a hard evidence failure');
        Assert.isTrue(
            stored.Grounding_Signals_Missing__c.contains('statement flagged for review'),
            'The review gate should be named: ' + stored.Grounding_Signals_Missing__c
        );
    }

    @IsTest
    static void confidenceIsLowWhenThereIsNoCurrentCreditCheck() {
        Loan_Application__c la = application(true, true, false);

        Loan_Application__c stored = reload(la.Id);
        Assert.areEqual(0, stored.Current_Credit_Checks__c, 'No bureau file should roll up to zero');
        Assert.areEqual(20, stored.Grounding_Confidence__c, 'No current bureau file is a hard evidence failure');
        Assert.isTrue(
            stored.Grounding_Signals_Missing__c.contains('current credit check'),
            'The bureau gap should be named: ' + stored.Grounding_Signals_Missing__c
        );
    }

    /**
     * The no-verdict boundary, asserted directly. Confidence answers "is the evidence here", so a
     * complete file with an appalling score is still High — the moment a bad score could drag this
     * field down, it would have stopped measuring completeness and started expressing an opinion
     * about the loan.
     */
    @IsTest
    static void confidenceIgnoresTheCreditScoreEntirely() {
        Loan_Application__c poorFile = application(true, true, false);
        addCurrentCreditCheck(poorFile.Id, 300);

        Assert.areEqual(
            100,
            reload(poorFile.Id).Grounding_Confidence__c,
            'A complete evidence base scores High regardless of how bad the bureau result is'
        );
    }

    @IsTest
    static void supersededCreditChecksDoNotCountAsCurrent() {
        Loan_Application__c la = application(true, true, false);
        addCurrentCreditCheck(la.Id, 720);

        Credit_Check__c only = [SELECT Id FROM Credit_Check__c WHERE Loan_Application__c = :la.Id];
        only.Is_Latest__c = false;
        update only;

        Loan_Application__c stored = reload(la.Id);
        Assert.areEqual(0, stored.Current_Credit_Checks__c, 'A superseded check is not a current one');
        Assert.areEqual(20, stored.Grounding_Confidence__c, 'Losing the current bureau file should drop confidence');
    }

    // ---------------------------------------------------------------- escalation

    @IsTest
    static void escalationRoutesALowConfidenceFileToTheSeniorAnalyst() {
        Loan_Application__c la = application(false, true, false);

        Test.startTest();
        Flow.Interview.Escalate_To_Senior_Analyst flow = escalate(la.Id);
        Test.stopTest();

        Assert.areEqual(true, flow.getVariableValue('varEscalated'), 'A Low file should escalate');
        Assert.areEqual('Low', flow.getVariableValue('varConfidenceBand'), 'The band should be reported as Low');

        Loan_Application__c stored = reload(la.Id);
        Assert.isTrue(stored.Escalated__c, 'The record should be flagged as escalated');
        Assert.areNotEqual(UserInfo.getUserId(), stored.OwnerId, 'Ownership should leave the current analyst');
        Assert.isTrue(
            stored.Escalation_Reason__c.contains('Low grounding confidence'),
            'Confidence must be named as the primary reason: ' + stored.Escalation_Reason__c
        );
        Assert.isTrue(
            stored.Escalation_Reason__c.contains('verified revenue'),
            'The reason must name WHICH evidence is missing: ' + stored.Escalation_Reason__c
        );
    }

    @IsTest
    static void evidenceTrailStatesTheConfidenceAndWhyItIsLow() {
        Loan_Application__c la = application(false, true, false);

        Test.startTest();
        String trail = (String) escalate(la.Id).getVariableValue('varEvidenceTrail');
        Test.stopTest();

        Assert.isTrue(trail.contains('Grounding confidence'), 'The trail must state the confidence: ' + trail);
        Assert.isTrue(trail.contains('(Low)'), 'The trail must state the band: ' + trail);
        Assert.isTrue(trail.contains('Evidence missing'), 'The trail must state why: ' + trail);
        Assert.isTrue(
            trail.contains('no current credit check on file'),
            'A missing bureau file is itself evidence and must be reported: ' + trail
        );
        Assert.isTrue(
            trail.contains('not provided'),
            'An absent figure must read as absent, never as zero: ' + trail
        );
    }

    @IsTest
    static void aReRunOnUnchangedEvidenceChangesNothing() {
        Loan_Application__c la = application(false, true, false);
        escalate(la.Id);
        Loan_Application__c afterFirst = reload(la.Id);

        Test.startTest();
        Flow.Interview.Escalate_To_Senior_Analyst second = escalate(la.Id);
        Test.stopTest();

        Assert.areEqual(
            true,
            second.getVariableValue('varAlreadyEscalated'),
            'A re-run is a refresh, not a new escalation, and must report itself as one'
        );
        Loan_Application__c afterSecond = reload(la.Id);
        Assert.areEqual(afterFirst.OwnerId, afterSecond.OwnerId, 'A re-run must not bounce ownership');
        // The reason IS rewritten on every re-assessment, but from the same unchanged fields, so it
        // lands on the same string and field history records nothing. Churn only shows up when the
        // evidence has actually moved — see aReAssessmentRewritesTheReasonToMatchTheNewState.
        Assert.areEqual(
            afterFirst.Escalation_Reason__c,
            afterSecond.Escalation_Reason__c,
            'Unchanged evidence must produce an unchanged reason'
        );
    }

    @IsTest
    static void aReAssessmentRewritesTheReasonToMatchTheNewState() {
        // Low on two counts: no verified financials, and no bureau file on record.
        Loan_Application__c la = application(false, true, false);
        escalate(la.Id);
        Loan_Application__c afterFirst = reload(la.Id);
        Assert.isTrue(
            afterFirst.Escalation_Reason__c.contains('current credit check'),
            'Precondition: the first reason should name the missing bureau file: ' + afterFirst.Escalation_Reason__c
        );

        // The analyst closes one of the two gaps. The file stays escalated and stays Low, but the
        // reason it carries is now describing a state the record has moved past.
        addCurrentCreditCheck(la.Id, 700);

        Test.startTest();
        Flow.Interview.Escalate_To_Senior_Analyst second = escalate(la.Id);
        Test.stopTest();

        Loan_Application__c afterSecond = reload(la.Id);
        Assert.areEqual(true, second.getVariableValue('varAlreadyEscalated'), 'A refresh is not a new escalation');
        Assert.areNotEqual(
            afterFirst.Escalation_Reason__c,
            afterSecond.Escalation_Reason__c,
            'A re-assessment must rewrite the reason once the evidence has changed'
        );
        Assert.isFalse(
            afterSecond.Escalation_Reason__c.contains('current credit check'),
            'The refreshed reason must not still name a gap that has been closed: ' + afterSecond.Escalation_Reason__c
        );
        Assert.isTrue(
            afterSecond.Escalation_Reason__c.contains('verified revenue'),
            'The gap that remains must still be named: ' + afterSecond.Escalation_Reason__c
        );
        Assert.areEqual(afterFirst.OwnerId, afterSecond.OwnerId, 'A refresh must not bounce ownership');
        Assert.isTrue(afterSecond.Escalated__c, 'A refresh must leave the file escalated');
        Assert.areEqual(
            afterSecond.Escalation_Reason__c,
            (String) second.getVariableValue('varEscalationReason'),
            'What the agent is told must match what was stored'
        );
    }

    @IsTest
    static void aResolvedTriggerLeavesTheFileEscalatedWithAClearedNote() {
        Loan_Application__c la = application(true, true, false);
        addCurrentCreditCheck(la.Id, 720);
        // Declared 1,000,000 against verified 500,000 is +100%, well past the 20% threshold.
        la.Verified_Annual_Revenue__c = 500000;
        update la;
        escalate(la.Id);
        Loan_Application__c afterFirst = reload(la.Id);
        Assert.isTrue(afterFirst.Escalated__c, 'Precondition: the disparity should have routed it');

        // A corrected statement arrives and the disparity falls away.
        la.Verified_Annual_Revenue__c = 950000;
        update la;

        Test.startTest();
        Flow.Interview.Escalate_To_Senior_Analyst second = escalate(la.Id);
        Test.stopTest();

        Loan_Application__c afterSecond = reload(la.Id);
        Assert.isFalse(afterSecond.Financial_Disparity_Flag__c, 'Precondition: the disparity should be resolved');
        Assert.isTrue(afterSecond.Escalated__c, 'A cleared trigger is not a cleared escalation');
        Assert.areEqual(afterFirst.OwnerId, afterSecond.OwnerId, 'The file stays with the senior it was given to');
        Assert.isTrue(
            afterSecond.Escalation_Reason__c.startsWith('Escalation conditions no longer met'),
            'The reason must say the condition has cleared, not describe a disparity that is gone: ' +
            afterSecond.Escalation_Reason__c
        );
        Assert.areEqual(
            afterSecond.Escalation_Reason__c,
            (String) second.getVariableValue('varEscalationReason'),
            'What the agent is told must match what was stored'
        );
    }

    @IsTest
    static void aCompleteFileWithNoDisparityDoesNotEscalate() {
        Loan_Application__c la = application(true, true, false);
        addCurrentCreditCheck(la.Id, 720);

        Test.startTest();
        Flow.Interview.Escalate_To_Senior_Analyst flow = escalate(la.Id);
        Test.stopTest();

        Assert.areEqual(false, flow.getVariableValue('varEscalated'), 'Nothing should escalate on a complete file');
        Assert.isFalse(reload(la.Id).Escalated__c, 'The record must be left alone');
    }

    @IsTest
    static void aDisparityEscalatesAndIsReportedWithoutCitingConfidence() {
        // Declared 1,000,000 against verified 500,000 is +100%, well past the 20% threshold.
        Loan_Application__c la = application(true, true, false);
        la.Verified_Annual_Revenue__c = 500000;
        update la;
        addCurrentCreditCheck(la.Id, 720);

        Test.startTest();
        Flow.Interview.Escalate_To_Senior_Analyst flow = escalate(la.Id);
        Test.stopTest();

        Assert.areEqual(true, flow.getVariableValue('varEscalated'), 'A flagged disparity should escalate');
        String reason = (String) flow.getVariableValue('varEscalationReason');
        Assert.isTrue(
            reason.contains('disparity'),
            'The disparity must be stated as the reason the file was routed: ' + reason
        );
        Assert.isFalse(
            reason.contains('Low grounding confidence'),
            'This file has complete evidence, so confidence must not be cited: ' + reason
        );
    }

    @IsTest
    static void anUnknownIdReportsFailureRatherThanAClearFile() {
        Test.startTest();
        Flow.Interview.Escalate_To_Senior_Analyst flow = escalate(
            Id.valueOf(Loan_Application__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA')
        );
        Test.stopTest();

        Assert.areEqual(false, flow.getVariableValue('varEscalated'), 'Nothing can be escalated');
        Assert.isTrue(
            ((String) flow.getVariableValue('varEscalationReason')).contains('No Loan Application was found'),
            'A bad Id must be reported as a failure, not as an assessed all-clear'
        );
    }

    // ---------------------------------------------------------------- separation of duties

    @IsTest
    static void anAnalystWithoutThePermissionCannotClearAnEscalation() {
        Loan_Application__c la = application(false, true, false);
        escalate(la.Id);
        User junior = analyst('junior', false);
        shareWith(la.Id, junior.Id);

        String error = '';
        Test.startTest();
        System.runAs(junior) {
            try {
                update new Loan_Application__c(Id = la.Id, Escalated__c = false);
                Assert.fail('A junior analyst must not be able to close an escalation');
            } catch (DmlException e) {
                error = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isTrue(
            error.contains('Only a senior credit analyst can close an escalation'),
            'The block should come from the separation-of-duties rule, got: ' + error
        );
        Assert.isTrue(reload(la.Id).Escalated__c, 'The escalation must still stand');
    }

    @IsTest
    static void aSeniorWithThePermissionCanClearAnEscalation() {
        Loan_Application__c la = application(false, true, false);
        escalate(la.Id);
        User senior = analyst('senior', true);
        shareWith(la.Id, senior.Id);

        Test.startTest();
        System.runAs(senior) {
            update new Loan_Application__c(Id = la.Id, Escalated__c = false);
        }
        Test.stopTest();

        Assert.isFalse(
            reload(la.Id).Escalated__c,
            'Can_Clear_Escalation is what distinguishes a senior, and it must actually work'
        );
    }

    @IsTest
    static void theRuleOnlyBlocksClearingAndNotOrdinaryEdits() {
        Loan_Application__c la = application(false, true, false);
        User junior = analyst('junior2', false);
        shareWith(la.Id, junior.Id);

        Test.startTest();
        System.runAs(junior) {
            update new Loan_Application__c(Id = la.Id, Loan_Amount_Requested__c = 600000);
        }
        Test.stopTest();

        Assert.areEqual(
            600000,
            [SELECT Loan_Amount_Requested__c FROM Loan_Application__c WHERE Id = :la.Id]
                .Loan_Amount_Requested__c,
            'An unrelated edit by a junior must not be caught by the escalation rule'
        );
    }

    /**
     * The insert-only claim on Credit_Check__c, finally exercised against a restricted profile.
     * It is enforced only by allowEdit=false in the permission set, which never applies to an
     * administrator — so until there was a non-admin user, this had never actually been proven.
     */
    @IsTest
    static void aNonAdminCannotUpdateAStoredCreditCheck() {
        Loan_Application__c la = application(true, true, false);
        addCurrentCreditCheck(la.Id, 720);
        Credit_Check__c stored = [SELECT Id FROM Credit_Check__c WHERE Loan_Application__c = :la.Id];
        User junior = analyst('junior3', false);
        shareWith(la.Id, junior.Id);

        String error = '';
        Test.startTest();
        System.runAs(junior) {
            try {
                Credit_Check__c edit = new Credit_Check__c(Id = stored.Id, Credit_Score__c = 999);
                Database.update(edit, AccessLevel.USER_MODE);
                Assert.fail('A credit analyst must not be able to revise a stored bureau result');
            } catch (Exception e) {
                error = e.getMessage();
            }
        }
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(error), 'The update should have been refused');
        Assert.areEqual(
            720,
            [SELECT Credit_Score__c FROM Credit_Check__c WHERE Id = :stored.Id].Credit_Score__c,
            'The stored bureau score must be unchanged'
        );
    }
}
