/**
 * Backs the Applicants tab in the PrimeCapital Lending app.
 *
 * Applicants are modelled as Person Accounts (the FSC package could not be installed
 * alongside Data Cloud in this org), so an "applicant" is an Account with
 * IsPersonAccount = true. Business Accounts must never appear in this list.
 *
 * This exists instead of a saved list view because the Metadata API cannot address
 * standard person-account fields (PersonEmail, PersonMobilePhone, ...) as list view
 * columns — they fail to resolve — which would have left the tab source-uncontrolled.
 *
 * The query runs WITH USER_MODE, so it is subject to the running analyst's FLS and
 * sharing rather than the Apex class's. The tab cannot surface a field the analyst's
 * permission set group doesn't grant.
 */
public with sharing class ApplicantListController {
    @TestVisible
    private static final Integer MAX_ROWS = 200;

    @AuraEnabled(cacheable=true)
    public static List<Account> getApplicants() {
        try {
            return [
                SELECT
                    Id,
                    Name,
                    IsPersonAccount,
                    PersonEmail,
                    PersonMobilePhone,
                    PersonMailingCity,
                    PersonMailingStateCode,
                    PersonBirthdate
                FROM Account
                WHERE IsPersonAccount = TRUE
                WITH USER_MODE
                ORDER BY Name
                LIMIT :MAX_ROWS
            ];
        } catch (Exception e) {
            // Surface a clean message to the component rather than a raw stack trace.
            throw new AuraHandledException(e.getMessage());
        }
    }
}
