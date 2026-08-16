@IsTest
private class ApplicantListControllerTest {
    private static Id personAccountRecordTypeId() {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get('PersonAccount')
            .getRecordTypeId();
    }

    @TestSetup
    static void makeData() {
        insert new List<Account>{
            new Account(
                RecordTypeId = personAccountRecordTypeId(),
                FirstName = 'Test',
                LastName = 'Applicant',
                PersonEmail = 'test.applicant@example.com'
            ),
            new Account(Name = 'Test Business Pty Ltd')
        };
    }

    @IsTest
    static void returnsPersonAccountsOnly() {
        Test.startTest();
        List<Account> applicants = ApplicantListController.getApplicants();
        Test.stopTest();

        Assert.areEqual(1, applicants.size(), 'Only the Person Account should be returned');
        Assert.areEqual('Test Applicant', applicants[0].Name, 'Unexpected applicant returned');
        Assert.areEqual(
            'test.applicant@example.com',
            applicants[0].PersonEmail,
            'PersonEmail should be selected for the datatable'
        );
    }

    @IsTest
    static void excludesBusinessAccounts() {
        List<Account> applicants = ApplicantListController.getApplicants();

        for (Account a : applicants) {
            Assert.isTrue(a.IsPersonAccount, a.Name + ' is not a Person Account');
        }
    }
}
