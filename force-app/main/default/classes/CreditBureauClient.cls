/**
 * The seam between this org and a credit bureau.
 *
 * MockEquifaxClient implements it today. A real EquifaxClient would implement the same method
 * with a Named Credential HTTP callout and drop in without CreditBureauService changing at all —
 * the service depends on this interface and never names an implementation except through the
 * @TestVisible override in CreditBureauService.client.
 *
 * The signature takes a List of already-queried applications and returns a Map keyed by
 * application Id, rather than the more obvious fetch(Id) one-at-a-time form. Two reasons:
 * an implementation that received only an Id would have to query for the applicant details it
 * needs, putting SOQL inside a per-record call and making bulk operation impossible; and a real
 * bureau client wants to see the whole batch so it can decide for itself whether the underlying
 * API supports a multi-subject enquiry. Records arrive fully loaded so implementations do no SOQL.
 */
public interface CreditBureauClient {
    /**
     * Runs one enquiry per application. Implementations must return an entry for every
     * application passed in — a failed enquiry is a BureauResponse with success = false, never
     * a missing key and never an exception, because the access attempt still has to be audited.
     */
    Map<Id, BureauResponse> fetch(List<Loan_Application__c> applications);
}
