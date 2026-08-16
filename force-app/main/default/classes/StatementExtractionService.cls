/**
 * Intake automation: reads an uploaded financial statement PDF and writes the verified
 * figures onto its Loan Application.
 *
 * This is intake, not assessment. It runs once when a statement is attached; the agent
 * later reads the stored fields and never sees the PDF.
 *
 * Apex rather than Flow, deliberately. ContentDocumentLink cannot carry a record-triggered
 * Flow — the Spring '26 feature that opened file objects to Flow covers ContentDocument and
 * ContentVersion only — but it does support Apex triggers. Triggering on the link (rather
 * than falling back to ContentVersion.FirstPublishLocationId) matters because that field is
 * insert-only and records wherever a file was FIRST published, so it silently mis-routes any
 * file uploaded elsewhere and linked to the application afterwards. Flow also has no JSON
 * parser and no way to keep model latency out of the user's save.
 *
 * The write runs in system context. An intake automation legitimately needs to write
 * Verified_* fields that the uploading user may not hold FLS for (they sit in the
 * Loan_Application_Sensitive_Financials set). The control is that this class writes exactly
 * four fields on exactly one object and nothing else.
 */
public with sharing class StatementExtractionService {
    @TestVisible
    private static final Decimal CONFIDENCE_THRESHOLD = 0.80;

    @TestVisible
    private static final String PROMPT_TEMPLATE = 'Extract_Financials';

    /** Input parameter key on the Extract_Financials flex template — an sObject input of type ContentDocument. */
    @TestVisible
    private static final String INPUT_PARAM = 'Input:varStatement';

    private static final Integer NOTES_MAX_LENGTH = 5000;

    /** Statements handled per queueable execution; the remainder chains into a follow-up job. */
    @TestVisible
    private static final Integer MAX_PER_RUN = 5;

    /**
     * Set in tests to stand in for the model response. The prompt template cannot be invoked
     * from a test context, so this is the seam that makes the parse/gate/write path testable
     * end to end rather than only in pieces.
     */
    @TestVisible
    private static String mockResponse;

    /** One statement to extract, paired with the application it was attached to. */
    public class Request {
        @InvocableVariable(label='Loan Application Id' required=true)
        public Id loanApplicationId;

        @InvocableVariable(label='Content Document Id' required=true)
        public Id contentDocumentId;

        @InvocableVariable(label='File Title')
        public String fileTitle;

        public Request() {
        }

        public Request(Id loanApplicationId, Id contentDocumentId, String fileTitle) {
            this.loanApplicationId = loanApplicationId;
            this.contentDocumentId = contentDocumentId;
            this.fileTitle = fileTitle;
        }
    }

    /** Parsed model output plus the gate decision. */
    public class Extraction {
        public Decimal revenue;
        public Decimal netIncome;
        public Decimal confidence;
        public String sourceNotes;
        public Boolean passed = false;
        public String outcome;
    }

    /**
     * Flow / process entry point. Not used by the trigger, which enqueues directly, but exposed
     * so extraction can be re-run for a statement without re-uploading it.
     */
    @InvocableMethod(
        label='Extract Financials From Statement'
        description='Reads an attached statement PDF with the Extract Financials prompt template and writes the verified figures to the Loan Application if confidence passes.'
    )
    public static void extract(List<Request> requests) {
        enqueue(requests);
    }

    /** Queues extraction, respecting the org's queueable ceiling. */
    public static void enqueue(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            System.debug(
                LoggingLevel.WARN,
                'Statement extraction skipped: queueable limit reached for ' + requests.size() + ' statement(s).'
            );
            return;
        }
        System.enqueueJob(new StatementExtractionQueueable(requests));
    }

    /**
     * Invokes the template for each statement, gates the result, and applies every write in a
     * single DML. Returns whatever could not be processed this run so the caller can chain.
     */
    public static List<Request> processBatch(List<Request> requests) {
        List<Request> remainder = new List<Request>();
        Map<Id, Loan_Application__c> updatesById = new Map<Id, Loan_Application__c>();
        List<Request> handled = new List<Request>();

        for (Integer i = 0; i < requests.size(); i++) {
            if (i >= MAX_PER_RUN) {
                remainder.add(requests[i]);
                continue;
            }
            handled.add(requests[i]);
        }

        Map<Id, Loan_Application__c> existing = new Map<Id, Loan_Application__c>(
            [
                SELECT Id, Statement_Extraction_Notes__c
                FROM Loan_Application__c
                WHERE Id IN :loanApplicationIds(handled)
            ]
        );

        for (Request req : handled) {
            Extraction ex = parseAndGate(invokeTemplate(req.contentDocumentId));

            Loan_Application__c la = updatesById.get(req.loanApplicationId);
            if (la == null) {
                la = new Loan_Application__c(Id = req.loanApplicationId);
                Loan_Application__c prior = existing.get(req.loanApplicationId);
                la.Statement_Extraction_Notes__c = prior == null ? null : prior.Statement_Extraction_Notes__c;
                updatesById.put(req.loanApplicationId, la);
            }

            if (ex.passed) {
                // TODO Component 2b: publish to audit log via Platform Event.
                la.Verified_Annual_Revenue__c = ex.revenue;
                la.Verified_Net_Income__c = ex.netIncome;
                la.Needs_Financial_Review__c = false;
            } else {
                // Never clear a figure that is already there — a failed read is not evidence of zero.
                la.Needs_Financial_Review__c = true;
            }

            la.Statement_Extraction_Notes__c = prependNote(la.Statement_Extraction_Notes__c, req, ex);
        }

        if (!updatesById.isEmpty()) {
            List<Database.SaveResult> results = Database.update(updatesById.values(), false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    System.debug(
                        LoggingLevel.ERROR,
                        'Statement extraction could not update ' +
                        updatesById.values()[i].Id +
                        ': ' +
                        results[i].getErrors()[0].getMessage()
                    );
                }
            }
        }

        return remainder;
    }

    private static Set<Id> loanApplicationIds(List<Request> requests) {
        Set<Id> ids = new Set<Id>();
        for (Request req : requests) {
            ids.add(req.loanApplicationId);
        }
        return ids;
    }

    /**
     * Calls the Extract Financials prompt template. Returns null on any failure — an unavailable
     * model or an exhausted quota routes to human review rather than throwing, because there is
     * no org-visible GenAI quota to pre-flight against.
     */
    private static String invokeTemplate(Id contentDocumentId) {
        if (mockResponse != null || Test.isRunningTest()) {
            return mockResponse;
        }
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();

            ConnectApi.EinsteinLlmAdditionalConfigInput config = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            config.applicationName = 'PromptBuilderPreview';
            input.additionalConfig = config;

            ConnectApi.WrappedValue statement = new ConnectApi.WrappedValue();
            statement.value = new Map<String, String>{ 'id' => contentDocumentId };
            input.inputParams = new Map<String, ConnectApi.WrappedValue>{ INPUT_PARAM => statement };
            input.isPreview = false;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                PROMPT_TEMPLATE,
                input
            );
            return response.generations.isEmpty() ? null : response.generations[0].text;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                'Extract Financials failed for ' + contentDocumentId + ': ' + e.getTypeName() + ' - ' + e.getMessage()
            );
            return null;
        }
    }

    /**
     * Parses the model's JSON and applies the confidence gate. Every failure mode — blank
     * response, fenced or malformed JSON, missing confidence, unreadable figure — resolves to
     * passed = false with a human-readable reason rather than an exception.
     */
    @TestVisible
    private static Extraction parseAndGate(String raw) {
        Extraction ex = new Extraction();

        if (String.isBlank(raw)) {
            ex.outcome = 'No response from the extraction model.';
            return ex;
        }

        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(stripCodeFences(raw));
        } catch (Exception e) {
            ex.outcome = 'Model response was not valid JSON: ' + e.getMessage();
            return ex;
        }

        if (!(parsed instanceof Map<String, Object>)) {
            ex.outcome = 'Model response was not a JSON object.';
            return ex;
        }

        Map<String, Object> values = (Map<String, Object>) parsed;
        ex.revenue = toDecimal(values.get('verified_annual_revenue'));
        ex.netIncome = toDecimal(values.get('verified_net_income'));
        ex.confidence = toDecimal(values.get('confidence'));
        ex.sourceNotes = values.get('source_notes') == null ? null : String.valueOf(values.get('source_notes'));

        if (ex.confidence == null) {
            ex.outcome = 'Model returned no confidence score.';
            return ex;
        }
        if (ex.confidence < CONFIDENCE_THRESHOLD) {
            ex.outcome = 'Confidence ' + ex.confidence + ' is below the ' + CONFIDENCE_THRESHOLD + ' threshold.';
            return ex;
        }
        if (ex.revenue == null || ex.netIncome == null) {
            ex.outcome = 'Model could not read one or both figures.';
            return ex;
        }

        ex.passed = true;
        ex.outcome = 'Written at confidence ' + ex.confidence + '.';
        return ex;
    }

    /** Models emit ```json fences despite being told not to. */
    @TestVisible
    private static String stripCodeFences(String raw) {
        String trimmed = raw.trim();
        if (!trimmed.startsWith('```')) {
            return trimmed;
        }
        Integer firstBreak = trimmed.indexOf('\n');
        if (firstBreak > -1) {
            trimmed = trimmed.substring(firstBreak + 1);
        }
        if (trimmed.endsWith('```')) {
            trimmed = trimmed.substring(0, trimmed.length() - 3);
        }
        return trimmed.trim();
    }

    /** JSON numbers arrive as Integer, Long, Double, Decimal or String depending on how they were written. */
    @TestVisible
    private static Decimal toDecimal(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        if (value instanceof Integer) {
            return Decimal.valueOf((Integer) value);
        }
        if (value instanceof Long) {
            return Decimal.valueOf((Long) value);
        }
        if (value instanceof Double) {
            return Decimal.valueOf((Double) value);
        }
        if (value instanceof String) {
            try {
                return Decimal.valueOf(((String) value).replaceAll('[^0-9\\.\\-]', ''));
            } catch (Exception e) {
                return null;
            }
        }
        return null;
    }

    /** Newest entry first, truncated at the field length so the recent history is what survives. */
    @TestVisible
    private static String prependNote(String existingNotes, Request req, Extraction ex) {
        String entry =
            '[' +
            Datetime.now().formatGmt('yyyy-MM-dd HH:mm') +
            ' UTC] ' +
            (String.isBlank(req.fileTitle) ? 'statement' : req.fileTitle) +
            ' (' +
            req.contentDocumentId +
            ')\n' +
            (ex.passed ? 'WRITTEN' : 'NOT WRITTEN — flagged for review') +
            ': ' +
            ex.outcome +
            (ex.passed ? '\nrevenue ' + ex.revenue + ', net income ' + ex.netIncome : '') +
            (String.isBlank(ex.sourceNotes) ? '' : '\nmodel notes: ' + ex.sourceNotes);

        String combined = String.isBlank(existingNotes) ? entry : entry + '\n\n' + existingNotes;
        return combined.length() > NOTES_MAX_LENGTH ? combined.substring(0, NOTES_MAX_LENGTH) : combined;
    }
}
