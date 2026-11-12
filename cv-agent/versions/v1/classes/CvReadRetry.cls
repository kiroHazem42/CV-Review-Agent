/**
 * Reads a CV again a few minutes later, once.
 *
 * Why: a Word file is sometimes not ready for the AI in the first seconds after upload.
 * The extraction flow then marks the candidate "Needs Review" with the PENDING marker and calls this class.
 * After the delay, the job puts the candidate back to "Processing" with the RETRY marker, which starts
 * the extraction flow again. The flow sees the RETRY marker and does not ask for a third try.
 */
public with sharing class CvReadRetry {

    public static final String PENDING_MARKER = '[auto-retry pending]';
    public static final String RETRY_MARKER = '[auto-retry]';
    @TestVisible private static final Integer DEFAULT_DELAY_MINUTES = 2;
    @TestVisible private static final Integer MAX_DELAY_MINUTES = 10;

    public class Request {
        @InvocableVariable(label='Candidate Id' description='The candidate whose CV must be read again.' required=true)
        public Id candidateId;

        @InvocableVariable(label='Delay Minutes' description='How long to wait before reading again. Default 2, maximum 10.')
        public Integer delayMinutes;
    }

    @InvocableMethod(
        label='Schedule CV Read Retry'
        description='Reads the CV of a candidate again after a short delay, once. Use it when the file was not ready.'
        category='CV Review'
    )
    public static void schedule(List<Request> requests) {
        if (requests == null) {
            return;
        }
        Set<Id> ids = new Set<Id>();
        Integer delay = DEFAULT_DELAY_MINUTES;
        for (Request req : requests) {
            if (req != null && req.candidateId != null) {
                ids.add(req.candidateId);
                if (req.delayMinutes != null) {
                    delay = req.delayMinutes;
                }
            }
        }
        if (ids.isEmpty()) {
            return;
        }
        delay = Math.max(0, Math.min(delay, MAX_DELAY_MINUTES));
        System.enqueueJob(new RetryJob(ids), delay);
    }

    public class RetryJob implements Queueable {
        private Set<Id> ids;

        public RetryJob(Set<Id> ids) {
            this.ids = ids;
        }

        public void execute(QueueableContext context) {
            retryNow(ids);
        }
    }

    // Only candidates still waiting for the retry are touched. A recruiter who fixed the record meanwhile is left alone.
    @TestVisible
    private static Integer retryNow(Set<Id> ids) {
        List<Candidate_c__c> toRetry = new List<Candidate_c__c>();
        for (Candidate_c__c c : [
            SELECT Id, Extraction_Status_c__c, Error_Message_c__c
            FROM Candidate_c__c
            WHERE Id IN :ids AND Extraction_Status_c__c = 'Needs Review'
        ]) {
            if (c.Error_Message_c__c != null && c.Error_Message_c__c.contains(PENDING_MARKER)) {
                c.Extraction_Status_c__c = 'Processing';
                c.Error_Message_c__c = RETRY_MARKER;
                toRetry.add(c);
            }
        }
        if (!toRetry.isEmpty()) {
            update toRetry;
        }
        return toRetry.size();
    }
}
