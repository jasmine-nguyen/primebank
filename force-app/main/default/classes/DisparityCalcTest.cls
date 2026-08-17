/**
 * Covers the guard on Loan_Application_Financial_Disparity_Calc, the before-save flow
 * that writes Financial_Disparity_Percent__c and Financial_Disparity_Flag__c.
 *
 * The control must DECLINE to answer when it lacks a revenue figure. It previously
 * coerced a missing declared revenue to zero, producing a spurious -100% with the flag
 * clear — which on a credit file reads as "checked, no overstatement", an assertion the
 * system had no basis to make. A cleared flag is the absence of a finding, never a
 * finding of innocence.
 *
 * The two computing tests use the exact inputs of seed records LA-0001 and LA-0003.
 * Those seeds must not be re-processed, so reading them back would only show they are
 * undisturbed — it could not show the guarded logic still reproduces their numbers.
 * Asserting their inputs here is what proves that.
 */
@IsTest
private class DisparityCalcTest {
    private static Id personAccountRecordTypeId() {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('PersonAccount')
            .getRecordTypeId();
    }

    @TestSetup
    static void makeData() {
        insert new Account(
            RecordTypeId = personAccountRecordTypeId(),
            FirstName = 'Disparity',
            LastName = 'Tester'
        );
    }

    /**
     * Inserting is what exercises the flow — it runs before save, so the stored values
     * are settled by the time the DML returns.
     */
    private static Loan_Application__c applicationWith(Decimal declared, Decimal verified) {
        Loan_Application__c application = new Loan_Application__c(
            Applicant__c = [SELECT Id FROM Account LIMIT 1].Id,
            Application_Status__c = 'New',
            Borrower_Type__c = 'Business',
            Loan_Purpose__c = 'Working_Capital',
            Loan_Amount_Requested__c = 500000,
            Submission_Date__c = Date.today(),
            Declared_Annual_Revenue__c = declared,
            Verified_Annual_Revenue__c = verified
        );
        insert application;

        return [
            SELECT Financial_Disparity_Percent__c, Financial_Disparity_Flag__c
            FROM Loan_Application__c
            WHERE Id = :application.Id
        ];
    }

    @IsTest
    static void aMissingDeclaredRevenueComputesNothingRatherThanMinusOneHundred() {
        Loan_Application__c stored = applicationWith(null, 118000);

        Assert.isNull(
            stored.Financial_Disparity_Percent__c,
            'A missing declared figure must yield no percentage at all, not a fabricated -100%'
        );
        Assert.isFalse(
            stored.Financial_Disparity_Flag__c,
            'No disparity is asserted when the calc could not run'
        );
    }

    @IsTest
    static void aDeclaredZeroIsTreatedAsNoAnswerRatherThanAZeroRevenue() {
        Loan_Application__c stored = applicationWith(0, 118000);

        Assert.isNull(
            stored.Financial_Disparity_Percent__c,
            'A declared zero is a non-answer, so no percentage should be stored'
        );
        Assert.isFalse(stored.Financial_Disparity_Flag__c, 'No disparity is asserted');
    }

    @IsTest
    static void aMissingVerifiedRevenueStillComputesNothing() {
        Loan_Application__c stored = applicationWith(1200000, null);

        Assert.isNull(
            stored.Financial_Disparity_Percent__c,
            'The pre-existing verified-revenue guard must still hold'
        );
        Assert.isFalse(stored.Financial_Disparity_Flag__c, 'No disparity is asserted');
    }

    @IsTest
    static void anOverstatementIsComputedAndFlagged() {
        // LA-0001's figures: declared 1,200,000 against verified 900,000 is +33.33%.
        Loan_Application__c stored = applicationWith(1200000, 900000);

        Assert.areEqual(
            33.33,
            stored.Financial_Disparity_Percent__c,
            'Guarding the inputs must not change the arithmetic on a complete file'
        );
        Assert.isTrue(
            stored.Financial_Disparity_Flag__c,
            'An overstatement past the 20% threshold must still raise the flag'
        );
    }

    @IsTest
    static void anOverstatementAtTheSeedDisparityIsComputedAndFlagged() {
        // LA-0003's figures: declared 400,000 against verified 320,000 is +25%.
        Loan_Application__c stored = applicationWith(400000, 320000);

        Assert.areEqual(
            25.00,
            stored.Financial_Disparity_Percent__c,
            'The seeded disparity demo must still compute to 25%'
        );
        Assert.isTrue(stored.Financial_Disparity_Flag__c, 'A 25% overstatement must still flag');
    }

    @IsTest
    static void anUnderstatementIsComputedButNeverFlagged() {
        // Declared below verified is negative, which can never satisfy a >= +20% test.
        Loan_Application__c stored = applicationWith(400000, 800000);

        Assert.areEqual(
            -50.00,
            stored.Financial_Disparity_Percent__c,
            'A genuine understatement is a real figure and must still be recorded'
        );
        Assert.isFalse(
            stored.Financial_Disparity_Flag__c,
            'The control flags overstatement only'
        );
    }
}
