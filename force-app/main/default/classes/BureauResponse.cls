/**
 * One credit bureau enquiry result, in the shape this org cares about rather than the shape
 * any particular bureau returns.
 *
 * Top-level rather than an inner class of CreditBureauService so that CreditBureauClient can
 * name it without an implementation of the interface having to depend on the service. A real
 * EquifaxClient should compile knowing only this class and the interface.
 *
 * A failed enquiry is a value, not an exception: `success = false` with a populated
 * statusMessage. The bureau being unreachable is a normal operating condition, and the access
 * attempt still has to be auditable, so callers must be able to record a result that has no score.
 */
public class BureauResponse {
    /** Bureau enquiry reference, format EQFX-CRI-yyyymmdd-nnnnnn. Durable business key for the pull. */
    public String reference;

    /** Null on a failed enquiry, and legitimately null for a thin file the bureau cannot score. */
    public Integer creditScore;

    /** When the bureau performed the enquiry, as distinct from when we got round to storing it. */
    public Datetime pulledAt;

    /** Raw bureau payload, retained verbatim for dispute handling. */
    public String fullReport;

    /** Short scenario/status label, e.g. Clean file or Thin file. Surfaced in the audit trail. */
    public String statusMessage;

    public Boolean success = false;

    public BureauResponse() {
    }

    public BureauResponse(String reference, Integer creditScore, Datetime pulledAt) {
        this.reference = reference;
        this.creditScore = creditScore;
        this.pulledAt = pulledAt;
        this.success = true;
    }
}
