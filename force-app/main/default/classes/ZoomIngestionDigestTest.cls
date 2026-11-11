@isTest
private class ZoomIngestionDigestTest {

    // VoiceCall can't be inserted in a test, so what exists in Salesforce comes from here; the
    // error rows themselves are real.
    class FakeLookups extends ZoomIngestionDigest.Lookups {
        Map<String, ZoomIngestionDigest.CallState> callsByKey = new Map<String, ZoomIngestionDigest.CallState>();
        Set<String> transcribedMeetings = new Set<String>();
        Map<String, String> userNames = new Map<String, String>();
        ZoomIngestionDigest.Ingested ingested = busyDay();
        Boolean failCalls = false;

        public override Map<String, ZoomIngestionDigest.CallState> calls(Set<String> vendorCallKeys) {
            if (failCalls) {
                throw new QueryException('simulated failure');
            }
            return callsByKey;
        }
        public override Set<String> meetingsWithTranscript(Set<String> zoomMeetingIds) {
            return transcribedMeetings;
        }
        public override Map<String, String> userNamesByZoomId(Set<String> zoomUserIds) {
            return userNames;
        }
        public override ZoomIngestionDigest.Ingested ingestedSince(Datetime since) {
            return ingested;
        }
    }

    static ZoomIngestionDigest.Ingested busyDay() {
        ZoomIngestionDigest.Ingested counts = new ZoomIngestionDigest.Ingested();
        counts.calls = 300;
        counts.callTranscripts = 280;
        counts.meetingTranscripts = 8;
        return counts;
    }

    static ZoomIngestionDigest.CallState call(Boolean hasTranscript, Boolean recordingUploaded) {
        ZoomIngestionDigest.CallState state = new ZoomIngestionDigest.CallState();
        state.voiceCallId = '0LQ000000000001';
        state.userName = 'Chris Johnson';
        state.hasTranscript = hasTranscript;
        state.recordingUploaded = recordingUploaded;
        return state;
    }

    static Zoom_Integration_Error__c error(String className, String method, String errorType, String key, String message) {
        return new Zoom_Integration_Error__c(
            Apex_Class__c = className, Apex_Method__c = method, Error_Type__c = errorType,
            Zoom_Meeting_Id__c = key, Error_Message__c = message, Resolved__c = true
        );
    }

    static ZoomIngestionDigest.Digest run(FakeLookups fake) {
        ZoomIngestionDigest.lookups = fake;
        return ZoomIngestionDigest.build(Datetime.now().addHours(-24));
    }

    @isTest
    static void testFailedCreationWithNoVoiceCallIsReportedByOwner() {
        Zoom_Integration_Error__c failed = error('ZoomPhoneIntegration', 'processWebhookRecordingCompleted', 'Voice Call Creation Failed', 'c1',
            'VoiceCall creation reported failure for call_id c1. isSuccess=false errorMsg=Missing access to the Conversational Intelligence feature.');
        failed.Raw_Payload__c = '{"call_id":"c1","owner":{"name":"Paige DuCharme","type":"user"}}';
        insert failed;

        ZoomIngestionDigest.Digest digest = run(new FakeLookups());
        String message = digest.format();

        System.assertEquals(1, digest.count(ZoomIngestionDigest.Loss.CALL));
        System.assert(message.startsWith(':warning:') && message.contains(': 1 call not created.'), message);
        System.assert(message.contains('• Paige DuCharme · Missing access to the Conversational Intelligence feature.'), message);
    }

    @isTest
    static void testRecoveredCallIsNotReported() {
        insert error('ZoomPhoneIntegration', 'processWebhookRecordingCompleted', 'Voice Call Creation Failed', 'c1', 'errorMsg=Missing access');
        FakeLookups fake = new FakeLookups();
        fake.callsByKey.put('c1', call(true, true));

        String message = run(fake).format();

        System.assert(message.startsWith(':white_check_mark:'), message);
        System.assert(message.contains('300 calls, 280 call transcripts, 8 meeting transcripts'), message);
    }

    @isTest
    static void testCallWithoutTranscriptLinksTheCall() {
        insert error('ZoomPhoneIntegration', 'processWebhookTranscriptReady', 'Other', 'c2', 'Argument 1 cannot be null');
        FakeLookups fake = new FakeLookups();
        fake.callsByKey.put('c2', call(false, true));

        ZoomIngestionDigest.Digest digest = run(fake);
        String message = digest.format();

        System.assertEquals(1, digest.count(ZoomIngestionDigest.Loss.TRANSCRIPT));
        System.assert(message.contains('*Calls without a transcript*\n• Chris Johnson · Argument 1 cannot be null · <'), message);
    }

    @isTest
    static void testShortCallsAndUntranscribableRecordingsAreNotLost() {
        insert new List<Zoom_Integration_Error__c>{
            error('ZoomPhoneIntegration', 'processWebhookTranscriptReady', 'Voice Call Not Found', 'short1', 'No VoiceCall found yet for call_id short1'),
            error('ZoomPhoneTranscriptBuildQueueable', 'execute', 'Zoom Cannot Transcribe', 'c3', 'Unable to transcribe this recording.')
        };
        FakeLookups fake = new FakeLookups();
        fake.callsByKey.put('c3', call(false, true));

        String message = run(fake).format();

        System.assert(message.startsWith(':white_check_mark:'), message);
        System.assert(message.contains('1 transcript for calls with no call record'), message);
        System.assert(message.contains('1 recording Zoom couldn\'t transcribe'), message);
    }

    @isTest
    static void testCallZoomCouldNotTranscribeIsNotLostOnItsOtherRows() {
        // Paige DuCharme's backfill, 10/27/2026: the call's creation-failure row and its transcript
        // retry row (still typed Transcript Not Ready, code 12000 in the message) both finish.
        insert new List<Zoom_Integration_Error__c>{
            error('ZoomPhoneIntegration', 'processWebhookRecordingCompleted', 'Voice Call Creation Failed', 'c8', 'errorMsg=Missing access'),
            error('ZoomPhoneIntegration', 'backfillMissingTranscripts', 'Transcript Not Ready', 'c8',
                'Error fetching transcript: {"code":12000,"message":"Unable to transcribe this recording."}')
        };
        FakeLookups fake = new FakeLookups();
        fake.callsByKey.put('c8', call(false, true));

        ZoomIngestionDigest.Digest digest = run(fake);

        System.assertEquals(0, digest.count(ZoomIngestionDigest.Loss.TRANSCRIPT));
        System.assert(digest.format().contains('1 recording Zoom couldn\'t transcribe'), digest.format());
    }

    @isTest
    static void testUploadFailureReportedOnlyWhenRecordingIsMissing() {
        insert new List<Zoom_Integration_Error__c>{
            error('ZoomPhoneIntegration', 'uploadRecording', 'Callout Error', 'big',
                'Error during audio upload: Failed to upload audio. Status: 400, Response: [{"errorCode":"FILE_SIZE_LIMIT_EXCEEDED"}]. uploadUrl was: https://x'),
            error('ZoomPhoneIntegration', 'uploadRecording', 'Callout Error', 'retried', 'Error during audio upload. uploadUrl was: https://x')
        };
        FakeLookups fake = new FakeLookups();
        fake.callsByKey.put('big', call(true, false));
        fake.callsByKey.put('retried', call(true, true));

        ZoomIngestionDigest.Digest digest = run(fake);

        System.assertEquals(1, digest.count(ZoomIngestionDigest.Loss.RECORDING));
        System.assert(digest.format().contains('• Chris Johnson · recording too large to upload'), digest.format());
    }

    @isTest
    static void testMissedMeetingTranscriptNamesTheUser() {
        Zoom_Integration_Error__c missed = error('ZoomTranscriptFetchQueueable', 'execute', 'Other', 'm1', 'Argument 1 cannot be null');
        missed.Zoom_User_Id__c = 'zoomUser1';
        Zoom_Integration_Error__c recovered = error('ZoomTranscriptFetchQueueable', 'execute', 'Other', 'm2', 'Argument 1 cannot be null');
        insert new List<Zoom_Integration_Error__c>{ missed, recovered };
        FakeLookups fake = new FakeLookups();
        fake.transcribedMeetings.add('m2');
        fake.userNames.put('zoomUser1', 'Erin Example');

        ZoomIngestionDigest.Digest digest = run(fake);

        System.assertEquals(1, digest.count(ZoomIngestionDigest.Loss.MEETING_TRANSCRIPT));
        System.assert(digest.format().contains('*Meeting transcripts missed*\n• Erin Example · Argument 1 cannot be null'), digest.format());
    }

    @isTest
    static void testCallLoggedTwiceIsCountedOnce() {
        insert new List<Zoom_Integration_Error__c>{
            error('ZoomPhoneIntegration', 'processWebhookTranscriptReady', 'Other', 'c4', 'Argument 1 cannot be null'),
            error('ZoomPhoneIntegration', 'processWebhookTranscriptReady', 'Other', 'c4', 'Argument 1 cannot be null'),
            error('ZoomPhoneIntegration', 'processWebhookTranscriptReady', 'Other', 'c5', 'Argument 1 cannot be null')
        };
        FakeLookups fake = new FakeLookups();
        fake.callsByKey.put('c4', call(false, true));
        fake.callsByKey.put('c5', call(false, true));

        ZoomIngestionDigest.Digest digest = run(fake);

        System.assertEquals(2, digest.count(ZoomIngestionDigest.Loss.TRANSCRIPT));
        System.assert(digest.format().contains('• Chris Johnson ×2 · Argument 1 cannot be null'), digest.format());
    }

    @isTest
    static void testCallStillRetryingIsNotLostYet() {
        Zoom_Integration_Error__c gaveUp = error('ZoomPhoneIntegration', 'processWebhookTranscriptReady', 'Other', 'c7', 'Argument 1 cannot be null');
        Zoom_Integration_Error__c retrying = error('ZoomPhoneIntegration', 'processTranscriptRetry', 'Transcript Not Ready', 'c7', 'still processing');
        retrying.Resolved__c = false;
        retrying.Next_Retry_At__c = Datetime.now().addMinutes(20);
        // An old unresolved row with no retry scheduled isn't a retry.
        Zoom_Integration_Error__c stale = error('ZoomTranscriptFetchQueueable', 'execute', 'Callout Error', 'm9', 'Read timed out');
        stale.Resolved__c = false;
        insert new List<Zoom_Integration_Error__c>{ gaveUp, retrying, stale };
        FakeLookups fake = new FakeLookups();
        fake.callsByKey.put('c7', call(false, true));

        ZoomIngestionDigest.Digest digest = run(fake);

        System.assertEquals(0, digest.count(ZoomIngestionDigest.Loss.TRANSCRIPT));
        System.assert(digest.format().contains('Still retrying: 1.'), digest.format());
    }

    @isTest
    static void testErrorWithoutACallIsReportedByMethod() {
        insert error('ZoomPhoneIntegration', 'getZoomToken', 'Callout Error', null, 'Failed to get Zoom token: invalid_client');

        ZoomIngestionDigest.Digest digest = run(new FakeLookups());

        System.assertEquals(1, digest.count(ZoomIngestionDigest.Loss.OTHER));
        System.assert(digest.format().contains('• ZoomPhoneIntegration.getZoomToken · Failed to get Zoom token: invalid_client'), digest.format());
    }

    @isTest
    static void testNothingComingInOnAWeekdayIsFlagged() {
        FakeLookups fake = new FakeLookups();
        fake.ingested = new ZoomIngestionDigest.Ingested();
        ZoomIngestionDigest.lookups = fake;

        String wednesday = ZoomIngestionDigest.build(Datetime.newInstance(2026, 10, 28, 7, 15, 0)).format();
        String sunday = ZoomIngestionDigest.build(Datetime.newInstance(2026, 10, 25, 7, 15, 0)).format();

        System.assert(wednesday.contains(':warning:') && wednesday.contains('no calls or call transcripts or meeting transcripts came in on a weekday'), wednesday);
        System.assert(sunday.startsWith(':white_check_mark:'), sunday);
    }

    @isTest
    static void testExecutePostsTheDigest() {
        Test.startTest();
        System.enqueueJob(new ZoomIngestionDigest());
        Test.stopTest();

        System.assertEquals(1, SystemHealthSlack.postedForTest.size());
        System.assert(SystemHealthSlack.postedForTest[0].contains('Zoom check'), SystemHealthSlack.postedForTest[0]);
    }

    @isTest
    static void testExecutePostsWhenTheCheckFails() {
        insert error('ZoomPhoneIntegration', 'processWebhookTranscriptReady', 'Other', 'c6', 'boom');
        FakeLookups fake = new FakeLookups();
        fake.failCalls = true;
        ZoomIngestionDigest.lookups = fake;

        new ZoomIngestionDigest().execute(null);

        System.assertEquals(1, SystemHealthSlack.postedForTest.size());
        System.assert(SystemHealthSlack.postedForTest[0].startsWith(':rotating_light: Zoom check did not finish'), SystemHealthSlack.postedForTest[0]);
    }

    @isTest
    static void testOwnerFromPayloadToleratesBadPayloads() {
        System.assertEquals(null, ZoomIngestionDigest.ownerFromPayload(null));
        System.assertEquals(null, ZoomIngestionDigest.ownerFromPayload('not json'));
        System.assertEquals(null, ZoomIngestionDigest.ownerFromPayload('{"call_id":"c1"}'));
    }

    @isTest
    static void testSchedulerQueuesTheDigest() {
        // Scheduled outside startTest so only the direct execute() below runs.
        ZoomIngestionDigestScheduler.jobName = 'Test ' + ZoomIngestionDigestScheduler.JOB_NAME;
        Id jobId = ZoomIngestionDigestScheduler.schedule();
        Test.startTest();
        new ZoomIngestionDigestScheduler().execute(null);
        Test.stopTest();

        System.assertEquals(ZoomIngestionDigestScheduler.CRON, [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId].CronExpression);
        System.assertEquals(1, SystemHealthSlack.postedForTest.size(), 'The queued digest should have posted');
    }
}
