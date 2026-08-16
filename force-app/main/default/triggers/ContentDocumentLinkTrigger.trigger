/**
 * Fires statement extraction when a PDF is attached to a Loan Application.
 *
 * after insert only: ContentDocumentLink.LinkedEntityId and ContentDocumentId are both
 * insert-only, so an update trigger could never see anything but ShareType/Visibility changes.
 *
 * The Loan Application key prefix is read from describe rather than hardcoded. Credit_Check__c
 * sits at the adjacent prefix a06, so a loose or stale literal would quietly send credit-check
 * attachments through financial extraction.
 */
trigger ContentDocumentLinkTrigger on ContentDocumentLink(after insert) {
    String loanApplicationPrefix = Loan_Application__c.SObjectType.getDescribe().getKeyPrefix();

    Set<Id> documentIds = new Set<Id>();
    for (ContentDocumentLink link : Trigger.new) {
        if (String.valueOf(link.LinkedEntityId).startsWith(loanApplicationPrefix)) {
            documentIds.add(link.ContentDocumentId);
        }
    }

    if (documentIds.isEmpty()) {
        return;
    }

    // Only statements. A .txt or an image attached to the application is left alone.
    Map<Id, ContentVersion> pdfByDocumentId = new Map<Id, ContentVersion>();
    for (ContentVersion version : [
        SELECT Id, ContentDocumentId, Title, FileType
        FROM ContentVersion
        WHERE ContentDocumentId IN :documentIds AND IsLatest = TRUE AND FileType = 'PDF'
    ]) {
        pdfByDocumentId.put(version.ContentDocumentId, version);
    }

    if (pdfByDocumentId.isEmpty()) {
        return;
    }

    List<StatementExtractionService.Request> requests = new List<StatementExtractionService.Request>();
    for (ContentDocumentLink link : Trigger.new) {
        ContentVersion version = pdfByDocumentId.get(link.ContentDocumentId);
        if (version != null && String.valueOf(link.LinkedEntityId).startsWith(loanApplicationPrefix)) {
            requests.add(
                new StatementExtractionService.Request(link.LinkedEntityId, link.ContentDocumentId, version.Title)
            );
        }
    }

    StatementExtractionService.enqueue(requests);
}
