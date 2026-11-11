@isTest
private class ZoomPhoneCallReconcilerTest {

    // VoiceCall can't be inserted in a test, so the calls and transcripts Salesforce has come from
    // here; the retry rows are real.
    class FakeLookups extends ZoomPhoneCallReconciler.Lookups {
        Map<String, Id> voiceCallsByKey = new Map<String, Id>();
        Set<String> transcribed = new Set<String>();

        public override Map<String, Id> voiceCalls(Set<String> vendorCallKeys) {
            return voiceCallsByKey;
        }
        public override Set<String> callsWithTranscript(Set<String> vendorCallKeys) {
            return transcribed;
        }
    }

    // Serves the Zoom token and the recordings list; a page holds the recordings for one
    // next_page_token value (null for the first page).
    class ZoomMock implements HttpCalloutMock {
        Map<String, List<Map<String, Object>>> pages = new Map<String, List<Map<String, Object>>>();
        Integer status = 200;

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('oauth/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"tok"}');
                return res;
            }
            res.setStatusCode(status);
            if (status != 200) {
                res.setBody('{"code":124,"message":"Invalid access token."}');
                return res;
            }
            String token = req.getEndpoint().contains('next_page_token=') ? req.getEndpoint().substringAfter('next_page_token=') : null;
            Map<String, Object> body = new Map<String, Object>{ 'recordings' => pages.get(token) };
            if (token == null && pages.containsKey('p2')) {
                body.put('next_page_token', 'p2');
            }
            res.setBody(JSON.serialize(body));
            return res;
        }
    }

    static Map<String, Object> recording(String callId, String recordingId, String owner, String ownerType,
            Integer hoursAgo, Integer seconds, Boolean transcribed) {
        Datetime started = Datetime.now().addHours(-hoursAgo);
        Map<String, Object> r = new Map<String, Object>{
            'id' => recordingId,
            'call_id' => callId,
            'date_time' => started.formatGMT('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            'end_time' => started.addSeconds(seconds).formatGMT('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            'direction' => 'outbound',
            'caller_number' => '9094',
            'callee_number' => '+16125550100',
            'download_url' => 'https://zoom.us/v2/phone/recording/download/' + recordingId,
            'owner' => new Map<String, Object>{ 'name' => owner, 'type' => ownerType, 'extension_number' => 9094 }
        };
        if (transcribed) {
            r.put('transcript_download_url', 'https://zoom.us/v2/phone/recording_transcript/download/' + recordingId);
        }
        return r;
    }

    static ZoomMock mockWith(List<Map<String, Object>> recordings) {
        ZoomMock mock = new ZoomMock();
        mock.pages.put(null, recordings);
        Test.setMock(HttpCalloutMock.class, mock);
        return mock;
    }

    static void run(FakeLookups fake, ZoomPhoneCallReconciler job) {
        ZoomPhoneCallReconciler.lookups = fake;
        Test.startTest();
        System.enqueueJob(job);
        Test.stopTest();
    }

    static List<Zoom_Integration_Error__c> queued() {
        return [
            SELECT Apex_Method__c, Error_Type__c, Zoom_Meeting_Id__c, Recording_Id__c, Voice_Call_Id__c,
                   Raw_Payload__c, Next_Retry_At__c, Retry_Count__c, Resolved__c
            FROM Zoom_Integration_Error__c WHERE Apex_Class__c = 'ZoomPhoneCallReconciler' ORDER BY Apex_Method__c
        ];
    }

    static String posted() {
        System.assertEquals(1, SystemHealthSlack.postedForTest.size(), 'Every run should post once');
        return SystemHealthSlack.postedForTest[0];
    }

    @isTest
    static void testMissingCallIsRecreatedWithItsTranscript() {
        mockWith(new List<Map<String, Object>>{ recording('c1', 'r1', 'Kelly Hurley', 'user', 20, 200, true) });

        run(new FakeLookups(), new ZoomPhoneCallReconciler());

        List<Zoom_Integration_Error__c> rows = queued();
        System.assertEquals(2, rows.size(), rows);
        Zoom_Integration_Error__c creation = rows[0];
        System.assertEquals('Voice Call Creation Failed', creation.Error_Type__c);
        System.assertEquals('c1', creation.Zoom_Meeting_Id__c);
        System.assertEquals('r1', creation.Recording_Id__c);
        System.assertEquals(false, creation.Resolved__c);
        System.assert(creation.Next_Retry_At__c <= Datetime.now(), 'The next creation pass should pick it up');
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(creation.Raw_Payload__c);
        System.assertEquals('https://zoom.us/v2/phone/recording/download/r1', payload.get('download_url'));

        Zoom_Integration_Error__c transcript = rows[1];
        System.assertEquals('Voice Call Not Found', transcript.Error_Type__c);
        System.assertEquals('r1', transcript.Recording_Id__c);
        System.assertEquals(null, transcript.Voice_Call_Id__c);
        System.assert(transcript.Next_Retry_At__c > Datetime.now().addMinutes(40), 'Should wait for the creation pass');

        String message = posted();
        System.assert(message.startsWith(':wrench:') && message.contains(': 1 call not in Salesforce.'), message);
        System.assert(message.contains('*Calls not in Salesforce*\n• Kelly Hurley · '), message);
        System.assert(message.contains(' · 3m 20s · c1'), message);
    }

    @isTest
    static void testCallWithoutTranscriptIsQueued() {
        mockWith(new List<Map<String, Object>>{ recording('c2', 'r2', 'Paige DuCharme', 'user', 20, 45, true) });
        FakeLookups fake = new FakeLookups();
        fake.voiceCallsByKey.put('c2', '0LQ000000000002');

        run(fake, new ZoomPhoneCallReconciler());

        List<Zoom_Integration_Error__c> rows = queued();
        System.assertEquals(1, rows.size(), rows);
        System.assertEquals('Transcript Not Ready', rows[0].Error_Type__c);
        // Ids come back in their 18-character form.
        System.assert(rows[0].Voice_Call_Id__c.startsWith('0LQ000000000002'), rows[0].Voice_Call_Id__c);
        System.assertEquals('r2', rows[0].Recording_Id__c);
        System.assert(rows[0].Next_Retry_At__c <= Datetime.now());
        String message = posted();
        System.assert(message.contains(': 1 call without a transcript.'), message);
        System.assert(message.contains('*Calls without a transcript*\n• Paige DuCharme · '), message);
        System.assert(message.contains(' · c2 · <') && message.contains('/0LQ000000000002'), message);
    }

    @isTest
    static void testCompleteCallsQueueNothing() {
        mockWith(new List<Map<String, Object>>{ recording('c3', 'r3', 'Erin Turner', 'user', 20, 60, true) });
        FakeLookups fake = new FakeLookups();
        fake.voiceCallsByKey.put('c3', '0LQ000000000003');
        fake.transcribed.add('c3');

        run(fake, new ZoomPhoneCallReconciler());

        System.assertEquals(0, queued().size());
        String message = posted();
        System.assert(message.startsWith(':white_check_mark:'), message);
        System.assert(message.contains('Checked 1 calls Zoom recorded and transcribed since'), message);
    }

    @isTest
    static void testSkipsShortRecentAndUntranscribedRecordings() {
        mockWith(new List<Map<String, Object>>{
            recording('short', 'r4', 'Erin Turner', 'user', 20, 8, true),
            recording('recent', 'r5', 'Erin Turner', 'user', 1, 60, true),
            recording('notx', 'r6', 'Erin Turner', 'user', 20, 60, false)
        });

        run(new FakeLookups(), new ZoomPhoneCallReconciler());

        System.assertEquals(0, queued().size());
        System.assert(posted().contains('Checked 0 calls'), posted());
    }

    @isTest
    static void testSkipsCallsStillRetryingAndTranscriptsZoomCannotMake() {
        insert new List<Zoom_Integration_Error__c>{
            new Zoom_Integration_Error__c(Apex_Class__c = 'ZoomPhoneIntegration', Error_Type__c = 'Transcript Not Ready',
                Zoom_Meeting_Id__c = 'busy', Recording_Id__c = 'r7', Resolved__c = false, Next_Retry_At__c = Datetime.now()),
            new Zoom_Integration_Error__c(Apex_Class__c = 'ZoomPhoneIntegration', Error_Type__c = 'Transcript Not Ready', Resolved__c = true,
                Zoom_Meeting_Id__c = 'cannot', Error_Message__c = 'Error fetching transcript: {"code":12000,"message":"Unable to transcribe this recording."}'),
            new Zoom_Integration_Error__c(Apex_Class__c = 'ZoomPhoneIntegration', Error_Type__c = 'Zoom Cannot Transcribe', Resolved__c = true,
                Zoom_Meeting_Id__c = 'cannotNoCall')
        };
        mockWith(new List<Map<String, Object>>{
            recording('busy', 'r7', 'Erin Turner', 'user', 20, 60, true),
            recording('cannot', 'r8', 'Erin Turner', 'user', 20, 60, true),
            recording('cannotNoCall', 'r9', 'Erin Turner', 'user', 20, 60, true)
        });
        FakeLookups fake = new FakeLookups();
        fake.voiceCallsByKey.put('cannot', '0LQ000000000008');

        run(fake, new ZoomPhoneCallReconciler());

        // The call with no VoiceCall is still recreated, without a transcript retry.
        List<Zoom_Integration_Error__c> rows = queued();
        System.assertEquals(1, rows.size(), rows);
        System.assertEquals('cannotNoCall', rows[0].Zoom_Meeting_Id__c);
        System.assertEquals('Voice Call Creation Failed', rows[0].Error_Type__c);
        System.assert(posted().contains('Skipped: 1 still being retried, 1 Zoom couldn\'t transcribe.'), posted());
    }

    @isTest
    static void testUsesTheUsersLongestRecordingOfTheCall() {
        mockWith(new List<Map<String, Object>>{
            recording('c10', 'queueLeg', 'CSR', 'callQueue', 20, 300, true),
            recording('c10', 'shortLeg', 'Robin Jones', 'user', 20, 60, true),
            recording('c10', 'userLeg', 'Krystal Lilyquist', 'user', 20, 140, true)
        });

        run(new FakeLookups(), new ZoomPhoneCallReconciler());

        List<Zoom_Integration_Error__c> rows = queued();
        System.assertEquals(2, rows.size(), rows);
        System.assertEquals('userLeg', rows[0].Recording_Id__c);
        System.assertEquals('userLeg', rows[1].Recording_Id__c);
        System.assert(posted().contains('• Krystal Lilyquist · '), posted());
    }

    @isTest
    static void testReadsEveryPage() {
        ZoomMock mock = mockWith(new List<Map<String, Object>>{ recording('p1call', 'r11', 'Erin Turner', 'user', 30, 60, true) });
        mock.pages.put('p2', new List<Map<String, Object>>{ recording('p2call', 'r12', 'Erin Turner', 'user', 40, 60, true) });
        FakeLookups fake = new FakeLookups();
        fake.voiceCallsByKey.put('p1call', '0LQ000000000011');
        fake.voiceCallsByKey.put('p2call', '0LQ000000000012');

        run(fake, new ZoomPhoneCallReconciler());

        System.assertEquals(2, queued().size());
        System.assert(posted().contains('Checked 2 calls'), posted());
    }

    @isTest
    static void testHoldsWhenMoreCallsAreMissingThanTheCap() {
        mockWith(new List<Map<String, Object>>{
            recording('h1', 'r13', 'Erin Turner', 'user', 20, 60, true),
            recording('h2', 'r14', 'Erin Turner', 'user', 21, 60, true)
        });

        run(new FakeLookups(), new ZoomPhoneCallReconciler(1));

        System.assertEquals(0, queued().size());
        String message = posted();
        System.assert(message.startsWith(':warning:'), message);
        System.assert(message.contains('2 calls missing is more than the 1 this job queues on its own'), message);
        System.assert(message.contains('`System.enqueueJob(new ZoomPhoneCallReconciler(2));`'), message);
        System.assert(message.contains('*Calls not in Salesforce*'), message);
    }

    @isTest
    static void testZoomErrorIsPostedAndQueuesNothing() {
        ZoomMock mock = mockWith(new List<Map<String, Object>>());
        mock.status = 401;

        run(new FakeLookups(), new ZoomPhoneCallReconciler());

        System.assertEquals(0, queued().size());
        String message = posted();
        System.assert(message.startsWith(':rotating_light:') && message.contains('did not finish'), message);
        System.assert(message.contains('returned 401'), message);
    }

    @isTest
    static void testDefaultLookupsReadSalesforce() {
        Set<String> keys = new Set<String>{ 'none' };
        ZoomPhoneCallReconciler.Lookups real = new ZoomPhoneCallReconciler.Lookups();
        System.assertEquals(0, real.voiceCalls(keys).size());
        System.assertEquals(0, real.callsWithTranscript(keys).size());
    }

    @isTest
    static void testSchedulerQueuesTheReconciler() {
        mockWith(new List<Map<String, Object>>());
        // Scheduled outside startTest so only the direct execute() below runs.
        ZoomPhoneCallReconcilerScheduler.jobName = 'Test ' + ZoomPhoneCallReconcilerScheduler.JOB_NAME;
        Id jobId = ZoomPhoneCallReconcilerScheduler.schedule();
        ZoomPhoneCallReconciler.lookups = new FakeLookups();
        Test.startTest();
        new ZoomPhoneCallReconcilerScheduler().execute(null);
        Test.stopTest();

        System.assertEquals(ZoomPhoneCallReconcilerScheduler.CRON, [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId].CronExpression);
        System.assert(posted().startsWith(':white_check_mark:'), posted());
    }
}
