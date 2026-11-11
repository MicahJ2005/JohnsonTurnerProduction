@isTest
private class ZoomPhoneTranscriptDedupeTest {

    // VoiceCall isn't createable via DML in a test, so these work on in-memory rows with
    // VoiceCall-shaped Ids rather than saved records.
    static final Id CALL_A = '0LQ000000000001';
    static final Id CALL_B = '0LQ000000000002';

    static Call_Transcript__c transcript(Id callId, Integer sequence, String text) {
        return new Call_Transcript__c(Voice_Call__c = callId, Transcript_Sequence__c = sequence, Transcript_Text__c = text);
    }

    // Zoom answers with no calls and no recordings, so the sync job queued by execute() runs to
    // the end without doing anything.
    class EmptyZoomMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(req.getEndpoint().contains('oauth/token')
                ? '{"access_token": "mockToken"}'
                : '{"call_logs": [], "recordings": []}');
            return res;
        }
    }

    @isTest
    static void testDropsNewTranscriptForCallThatAlreadyHasOne() {
        List<Call_Transcript__c> kept = ZoomPhoneIntegration.withoutDuplicateTranscripts(
            new List<Call_Transcript__c>{ transcript(CALL_A, 1, 'a'), transcript(CALL_B, 1, 'b') },
            new Set<Id>{ CALL_A }
        );

        System.assertEquals(1, kept.size(), 'Only the call without a saved transcript should be kept');
        System.assertEquals(CALL_B, kept[0].Voice_Call__c);
    }

    @isTest
    static void testKeepsOnlyFirstRecordingOfACall() {
        // Zoom records both ends of some calls; each recording's transcript arrives as its own
        // chunks starting again at sequence 1.
        List<Call_Transcript__c> kept = ZoomPhoneIntegration.withoutDuplicateTranscripts(
            new List<Call_Transcript__c>{
                transcript(CALL_A, 1, 'first 1'), transcript(CALL_A, 2, 'first 2'),
                transcript(CALL_B, 1, 'other'),
                transcript(CALL_A, 1, 'second 1'), transcript(CALL_A, 2, 'second 2')
            },
            new Set<Id>()
        );

        List<String> texts = new List<String>();
        for (Call_Transcript__c t : kept) texts.add(t.Transcript_Text__c);
        System.assertEquals(new List<String>{ 'first 1', 'first 2', 'other' }, texts,
            'Both chunks of the first recording are kept and the second recording is dropped');
    }

    @isTest
    static void testPassesThroughRowsThatAreAlreadySaved() {
        Id savedId = Call_Transcript__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
        Call_Transcript__c saved = transcript(CALL_A, 1, 'update');
        saved.Id = savedId;

        List<Call_Transcript__c> kept = ZoomPhoneIntegration.withoutDuplicateTranscripts(
            new List<Call_Transcript__c>{ saved }, new Set<Id>{ CALL_A }
        );

        System.assertEquals(1, kept.size(), 'An update to an existing transcript is not a duplicate');
    }

    @isTest
    static void testUpsertForMissingVoiceCallDoesNotThrow() {
        // Runs the lock and re-check against a VoiceCall that doesn't exist: nothing to lock,
        // nothing already saved, and the save itself fails on the lookup as it always has.
        ZoomPhoneIntegration.upsertCallTranscripts(new List<Call_Transcript__c>{ transcript(CALL_A, 1, 'a') }, false);

        System.assertEquals(0, [SELECT COUNT() FROM Call_Transcript__c]);
    }

    @isTest
    static void testSyncScheduleNoLongerStartsTranscriptRetries() {
        // ZoomPhoneTranscriptRetrySchedulable already runs the retry pass at the same minutes; the
        // sync schedule starting it as well put two chains on the same rows.
        insert new Zoom_Integration_Error__c(
            Apex_Class__c = 'ZoomPhoneIntegration', Apex_Method__c = 'processWebhookTranscriptReady',
            Error_Type__c = 'Transcript Not Ready', Recording_Id__c = 'rec1', Zoom_Meeting_Id__c = 'call1',
            Retry_Count__c = 0, Next_Retry_At__c = Datetime.now().addMinutes(-1), Resolved__c = false
        );

        Test.setMock(HttpCalloutMock.class, new EmptyZoomMock());
        Test.startTest();
        new ZoomPhoneIntegration().execute(null);
        Integer queued = Limits.getQueueableJobs();
        Test.stopTest();

        System.assertEquals(1, queued, 'Only the sync job should be queued, not a transcript retry chain');
        System.assertEquals(false, [SELECT Resolved__c FROM Zoom_Integration_Error__c WHERE Recording_Id__c = 'rec1'].Resolved__c,
            'The due retry is left for ZoomPhoneTranscriptRetrySchedulable');
    }
}
