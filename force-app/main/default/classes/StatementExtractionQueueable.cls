/**
 * Runs statement extraction off the user's save.
 *
 * The prompt-template action reports hasCallout = false, so this is not strictly a callout
 * context — but model latency is measured in seconds, and holding that inside a trigger would
 * burn the transaction's time budget and keep the record locked while an analyst waits. Async
 * regardless. Declared AllowsCallouts so it still works if the platform ever reclassifies the
 * invocation.
 *
 * Chains itself when more statements are queued than one execution should attempt, so a bulk
 * upload doesn't lose the tail.
 */
public with sharing class StatementExtractionQueueable implements Queueable, Database.AllowsCallouts {
    private final List<StatementExtractionService.Request> requests;

    public StatementExtractionQueueable(List<StatementExtractionService.Request> requests) {
        this.requests = requests;
    }

    public void execute(QueueableContext context) {
        List<StatementExtractionService.Request> remainder = StatementExtractionService.processBatch(requests);

        // Chaining is not permitted inside a test context, and the batch is small there anyway.
        if (!remainder.isEmpty() && !Test.isRunningTest()) {
            StatementExtractionService.enqueue(remainder);
        }
    }
}
