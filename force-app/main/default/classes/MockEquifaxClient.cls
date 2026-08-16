/**
 * Stand-in for the Equifax CRI API. Returns canned bureau data so the assessment flow can be
 * demonstrated end to end without a bureau contract, a Named Credential, or a real consumer's
 * credit file.
 *
 * Scenarios are keyed on Loan_Application__c.Name (LA-000X), not on record Id. Ids differ in
 * every org and every scratch rebuild; the AutoNumber survives a seed reload, so the demo
 * scenarios stay attached to the applications they were written for. Unknown applications fall
 * through to a mid-range default rather than failing, so a newly created application is still
 * demonstrable.
 *
 * The scenario table is an inline map rather than one static resource per scenario. Static
 * resources would win if the payloads were real captured bureau responses that a non-developer
 * had to edit; these are hand-written fixtures whose whole value is being readable next to the
 * code that shapes them, and keeping them here means one file to read rather than five.
 *
 * Deliberately implements no callout of any kind, so it is safe in a test context. The real
 * client goes where noted in fetch().
 */
public with sharing class MockEquifaxClient implements CreditBureauClient {
    /** Returned for any application without a named scenario. */
    @TestVisible
    private static final Integer DEFAULT_SCORE = 700;

    @TestVisible
    private static final String REFERENCE_PREFIX = 'EQFX-CRI-';

    /**
     * One canned bureau file. Kept as a small inner type rather than a raw Map so the scenario
     * table below reads as data and the JSON payload is assembled in one place.
     */
    private class Scenario {
        Integer score;
        String status;
        String fileDepth;
        Integer defaults;
        Integer enquiriesLast6Months;
        Boolean scoreable = true;

        Scenario(Integer score, String status, String fileDepth, Integer defaults, Integer enquiries) {
            this.score = score;
            this.status = status;
            this.fileDepth = fileDepth;
            this.defaults = defaults;
            this.enquiriesLast6Months = enquiries;
        }
    }

    /**
     * LA-0003 returns 585 where the existing CC-0003 holds 640. That divergence is intentional:
     * a fresh pull showing deterioration against the previous one is exactly the situation
     * Is_Latest__c exists to represent, and it gives the escalation path something real to fire on.
     */
    private static Map<String, Scenario> scenarios() {
        return new Map<String, Scenario>{
            'LA-0001' => new Scenario(720, 'Clean file', 'Thick', 0, 1),
            'LA-0002' => new Scenario(790, 'Clean file, long history', 'Thick', 0, 0),
            'LA-0003' => new Scenario(585, 'Thin file, adverse', 'Thin', 2, 5),
            'LA-0004' => new Scenario(705, 'Clean file', 'Moderate', 0, 2)
        };
    }

    public Map<Id, BureauResponse> fetch(List<Loan_Application__c> applications) {
        // A real EquifaxClient replaces this method body: build the enquiry from each application,
        // POST it through a Named Credential, and map the bureau's response onto BureauResponse.
        // Nothing outside this method would change.
        Map<String, Scenario> byNumber = scenarios();
        Map<Id, BureauResponse> responses = new Map<Id, BureauResponse>();

        for (Loan_Application__c application : applications) {
            Scenario scenario = byNumber.get(application.Name);
            if (scenario == null) {
                scenario = new Scenario(DEFAULT_SCORE, 'Clean file', 'Moderate', 0, 1);
            }

            Datetime pulledAt = Datetime.now();
            BureauResponse response = new BureauResponse(
                newReference(pulledAt),
                scenario.scoreable ? scenario.score : null,
                pulledAt
            );
            response.statusMessage = scenario.status;
            response.fullReport = report(application, scenario, response.reference, pulledAt);
            responses.put(application.Id, response);
        }

        return responses;
    }

    /**
     * EQFX-CRI-yyyymmdd-nnnnnn, matching the format already in the seeded CC records. The suffix
     * is random rather than sequential because a bureau reference is the bureau's identifier, not
     * ours — nothing in this org should be able to predict the next one.
     */
    @TestVisible
    private static String newReference(Datetime pulledAt) {
        Integer suffix = Math.round(Math.random() * 999999);
        return REFERENCE_PREFIX + pulledAt.formatGmt('yyyyMMdd') + '-' + String.valueOf(suffix).leftPad(6, '0');
    }

    /** Shaped loosely like a bureau payload so Full_Credit_Report__c holds something plausible. */
    private static String report(
        Loan_Application__c application,
        Scenario scenario,
        String reference,
        Datetime pulledAt
    ) {
        return JSON.serializePretty(
            new Map<String, Object>{
                'bureau' => 'Equifax',
                'product' => 'CRI',
                'enquiry_reference' => reference,
                'enquiry_datetime' => pulledAt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
                'subject' => new Map<String, Object>{
                    'loan_application' => application.Name,
                    'borrower_type' => application.Borrower_Type__c
                },
                'score' => scenario.scoreable ? scenario.score : null,
                'score_range' => '0-1200',
                'file_depth' => scenario.fileDepth,
                'defaults_recorded' => scenario.defaults,
                'enquiries_last_6_months' => scenario.enquiriesLast6Months,
                'status' => scenario.status,
                'disclaimer' => 'Mock data. Not a real credit reporting body response.'
            }
        );
    }
}
