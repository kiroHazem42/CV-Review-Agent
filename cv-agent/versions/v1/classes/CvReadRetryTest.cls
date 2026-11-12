@IsTest
private class CvReadRetryTest {

    private static Candidate_c__c make(String name, String status, String message) {
        return new Candidate_c__c(Name = name, Extraction_Status_c__c = status, Error_Message_c__c = message);
    }

    private static Candidate_c__c reload(Id candidateId) {
        return [SELECT Extraction_Status_c__c, Error_Message_c__c FROM Candidate_c__c WHERE Id = :candidateId];
    }

    @IsTest
    static void waitingCandidateGoesBackToProcessingWithTheRetryMarker() {
        Candidate_c__c c = make('Waiting', 'Needs Review', 'The file was not ready. ' + CvReadRetry.PENDING_MARKER);
        insert c;

        Integer changed = CvReadRetry.retryNow(new Set<Id>{ c.Id });

        Assert.areEqual(1, changed);
        Candidate_c__c after = reload(c.Id);
        Assert.areEqual('Processing', after.Extraction_Status_c__c);
        Assert.areEqual(CvReadRetry.RETRY_MARKER, after.Error_Message_c__c);
    }

    @IsTest
    static void candidatesNotWaitingAreLeftAlone() {
        Candidate_c__c done = make('Done one', 'Done', null);
        Candidate_c__c reviewedByHand = make('Reviewed', 'Needs Review', 'Checked by a recruiter.');
        Candidate_c__c noMessage = make('No message', 'Needs Review', null);
        insert new List<Candidate_c__c>{ done, reviewedByHand, noMessage };

        Integer changed = CvReadRetry.retryNow(new Set<Id>{ done.Id, reviewedByHand.Id, noMessage.Id });

        Assert.areEqual(0, changed);
        Assert.areEqual('Done', reload(done.Id).Extraction_Status_c__c);
        Assert.areEqual('Needs Review', reload(reviewedByHand.Id).Extraction_Status_c__c);
        Assert.areEqual('Checked by a recruiter.', reload(reviewedByHand.Id).Error_Message_c__c);
        Assert.areEqual('Needs Review', reload(noMessage.Id).Extraction_Status_c__c);
    }

    @IsTest
    static void scheduleRunsTheRetryJob() {
        Candidate_c__c c = make('Scheduled', 'Needs Review', CvReadRetry.PENDING_MARKER);
        insert c;
        CvReadRetry.Request req = new CvReadRetry.Request();
        req.candidateId = c.Id;
        req.delayMinutes = 99;

        Test.startTest();
        CvReadRetry.schedule(new List<CvReadRetry.Request>{ req });
        Test.stopTest();

        // The job has run. The extraction flow may already have picked the record up after that,
        // so only check that it is no longer waiting for the retry.
        Candidate_c__c after = reload(c.Id);
        Assert.isFalse(after.Error_Message_c__c != null && after.Error_Message_c__c.contains(CvReadRetry.PENDING_MARKER));
    }

    @IsTest
    static void nullAndEmptyRequestsDoNothing() {
        CvReadRetry.schedule(null);
        CvReadRetry.schedule(new List<CvReadRetry.Request>());
        CvReadRetry.schedule(new List<CvReadRetry.Request>{ null, new CvReadRetry.Request() });
        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'CvReadRetry']);
    }
}
