/// Micah Johnson - Demand Chain 2026
/// Nightly check that every Zoom Phone call Zoom recorded and transcribed in the last few days made
/// it into Salesforce: a VoiceCall for the call and a Call_Transcript__c on it. Most lost calls leave
/// no Zoom_Integration_Error__c row to find (8/31-10/20/2026: 294 calls, most with nothing logged),
/// so this starts from Zoom's own recording list instead of from the error rows.
///
/// Anything missing goes back through the normal retry passes that ZoomPhoneTranscriptRetrySchedulable
/// runs at :00 and :30: a 'Voice Call Creation Failed' row carrying the recording as its payload (the
/// same row a failed phone.recording_completed webhook saves) and a transcript retry row. A call that
/// still fails shows in the 7:15 ZoomIngestionDigest. A summary is posted to the system health Slack
/// channel on every run, including runs that find nothing, so a missing post means the job didn't run.
///
/// Schedule:  ZoomPhoneCallReconcilerScheduler.schedule();
/// Run now:   System.enqueueJob(new ZoomPhoneCallReconciler());
public without sharing class ZoomPhoneCallReconciler implements Queueable, Database.AllowsCallouts {

    private static final Integer LOOKBACK_DAYS = 3;
    // A call that ended this recently may still be going through the webhook and its retries.
    private static final Integer SETTLE_HOURS = 2;
    // Calls under 10 seconds are skipped on purpose when VoiceCalls are created.
    private static final Integer MIN_SECONDS = 10;
    // Transcript rows for calls that have no VoiceCall yet wait for the creation pass to run first.
    private static final Integer TRANSCRIPT_DELAY_MINUTES = 50;
    private static final Integer MAX_PAGES = 50;
    private static final Integer MAX_LINES = 15;

    /// More missing calls than this in one night points to an outage or a bad read rather than the
    /// odd dropped call, so the run posts the list and queues nothing until someone has looked.
    @TestVisible
    private static final Integer DEFAULT_MAX_QUEUED = 100;

    @TestVisible
    private static Lookups lookups = new Lookups();

    private Integer maxQueued;

    public ZoomPhoneCallReconciler() {
        this(DEFAULT_MAX_QUEUED);
    }

    /// Pass a higher cap to clear a held run after checking its list.
    public ZoomPhoneCallReconciler(Integer maxQueued) {
        this.maxQueued = maxQueued;
    }

    public void execute(QueueableContext context) {
        Summary summary = new Summary(Datetime.now().addDays(-LOOKBACK_DAYS));
        List<Zoom_Integration_Error__c> rows = new List<Zoom_Integration_Error__c>();
        try {
            rows = findMissing(fetchRecordings(summary), summary);
            if (summary.missingCount() > maxQueued) {
                summary.holdReason = summary.missingCount() + ' calls missing is more than the ' + maxQueued
                    + ' this job queues on its own, so nothing was queued. After checking the list, run '
                    + '`System.enqueueJob(new ZoomPhoneCallReconciler(' + summary.missingCount() + '));`';
                rows.clear();
            }
        } catch (Exception e) {
            rows.clear();
            summary.fatalError = e.getMessage();
        }
        // The post is a callout, so it goes before the insert.
        SystemHealthSlack.post(summary.format());
        if (!rows.isEmpty()) {
            insert rows;
        }
    }

    /// Every recording Zoom lists for the lookback window.
    private static List<Map<String, Object>> fetchRecordings(Summary summary) {
        ZoomConfig__mdt cfg = [
            SELECT AccountId__c, ClientId__c, ClientSecret__c FROM ZoomConfig__mdt WHERE DeveloperName = 'Default' LIMIT 1
        ];
        String token = ZoomPhoneIntegration.getZoomToken(cfg.ClientId__c, cfg.ClientSecret__c, cfg.AccountId__c);

        List<Map<String, Object>> recordings = new List<Map<String, Object>>();
        String nextPage = null;
        Integer pages = 0;
        do {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('https://api.zoom.us/v2/phone/recordings?page_size=300'
                + '&from=' + summary.since.formatGMT('yyyy-MM-dd')
                + '&to=' + Datetime.now().formatGMT('yyyy-MM-dd')
                + (String.isNotBlank(nextPage) ? '&next_page_token=' + EncodingUtil.urlEncode(nextPage, 'UTF-8') : ''));
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + token);
            req.setTimeout(60000);
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                throw new CalloutException('Zoom recordings list returned ' + res.getStatusCode() + ': ' + res.getBody().abbreviate(300));
            }
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            if (body.get('recordings') != null) {
                for (Object o : (List<Object>) body.get('recordings')) {
                    recordings.add((Map<String, Object>) o);
                }
            }
            nextPage = (String) body.get('next_page_token');
            pages++;
        } while (String.isNotBlank(nextPage) && pages < MAX_PAGES);
        summary.stoppedEarly = String.isNotBlank(nextPage);
        return recordings;
    }

    /// Picks one recording per call and returns the retry rows for every call Salesforce is missing.
    @TestVisible
    private static List<Zoom_Integration_Error__c> findMissing(List<Map<String, Object>> recordings, Summary summary) {
        Datetime settled = Datetime.now().addHours(-SETTLE_HOURS);
        Map<String, Map<String, Object>> byCall = new Map<String, Map<String, Object>>();
        for (Map<String, Object> recording : recordings) {
            String callId = (String) recording.get('call_id');
            Datetime started = parse((String) recording.get('date_time'));
            Datetime ended = parse((String) recording.get('end_time'));
            if (callId == null || recording.get('transcript_download_url') == null || started == null || ended == null
                    || ended > settled || (ended.getTime() - started.getTime()) / 1000 < MIN_SECONDS) {
                continue;
            }
            if (!byCall.containsKey(callId) || isBetter(recording, byCall.get(callId))) {
                byCall.put(callId, recording);
            }
        }
        summary.checked = byCall.size();

        Map<String, Id> voiceCalls = lookups.voiceCalls(byCall.keySet());
        Set<String> transcribed = lookups.callsWithTranscript(byCall.keySet());
        Set<String> candidates = new Set<String>();
        for (String callId : byCall.keySet()) {
            if (!transcribed.contains(callId)) {
                candidates.add(callId);
            }
        }
        Set<String> retrying = lookups.stillRetrying(candidates);
        Set<String> untranscribable = lookups.untranscribable(candidates);

        List<Zoom_Integration_Error__c> rows = new List<Zoom_Integration_Error__c>();
        for (String callId : candidates) {
            Map<String, Object> recording = byCall.get(callId);
            Id voiceCallId = voiceCalls.get(callId);
            if (retrying.contains(callId)) {
                summary.retrying++;
                continue;
            }
            if (voiceCallId == null) {
                summary.noCall.add(describe(recording, callId, null));
                rows.add(creationRow(recording, callId));
                if (!untranscribable.contains(callId)) {
                    rows.add(transcriptRow(recording, callId, null));
                }
            } else if (untranscribable.contains(callId)) {
                summary.untranscribable++;
            } else {
                summary.noTranscript.add(describe(recording, callId, voiceCallId));
                rows.add(transcriptRow(recording, callId, voiceCallId));
            }
        }
        return rows;
    }

    /// Both legs of a call can be recorded, and a call-queue call has a recording owned by the queue.
    /// The user's recording names who the VoiceCall belongs to; the longer one has the fuller transcript.
    private static Boolean isBetter(Map<String, Object> candidate, Map<String, Object> current) {
        Boolean candidateIsUser = ownerType(candidate) == 'user';
        Boolean currentIsUser = ownerType(current) == 'user';
        if (candidateIsUser != currentIsUser) {
            return candidateIsUser;
        }
        return seconds(candidate) > seconds(current);
    }

    private static Zoom_Integration_Error__c creationRow(Map<String, Object> recording, String callId) {
        return new Zoom_Integration_Error__c(
            Apex_Class__c = 'ZoomPhoneCallReconciler',
            Apex_Method__c = 'missingCall',
            Error_Type__c = 'Voice Call Creation Failed',
            Error_Message__c = 'Nightly repair: Zoom recorded and transcribed this call but Salesforce has no VoiceCall for it; recreating it.',
            Zoom_Meeting_Id__c = callId,
            Recording_Id__c = (String) recording.get('id'),
            Raw_Payload__c = JSON.serialize(recording),
            Retry_Count__c = 0,
            Next_Retry_At__c = Datetime.now(),
            Resolved__c = false
        );
    }

    /// A call with no VoiceCall yet gets a 'Voice Call Not Found' row, which the transcript retry
    /// resolves by call id once the creation pass has made it. If the creation fails for good, the
    /// digest reports it once, from the creation row; it doesn't count this row as a second loss.
    private static Zoom_Integration_Error__c transcriptRow(Map<String, Object> recording, String callId, Id voiceCallId) {
        return new Zoom_Integration_Error__c(
            Apex_Class__c = 'ZoomPhoneCallReconciler',
            Apex_Method__c = 'missingTranscript',
            Error_Type__c = voiceCallId != null ? 'Transcript Not Ready' : 'Voice Call Not Found',
            Error_Message__c = 'Nightly repair: Zoom has a transcript for this call but Salesforce doesn\'t; fetching it.',
            Zoom_Meeting_Id__c = callId,
            Recording_Id__c = (String) recording.get('id'),
            Voice_Call_Id__c = voiceCallId,
            Retry_Count__c = 0,
            Next_Retry_At__c = voiceCallId != null ? Datetime.now() : Datetime.now().addMinutes(TRANSCRIPT_DELAY_MINUTES),
            Resolved__c = false
        );
    }

    private static String describe(Map<String, Object> recording, String callId, Id voiceCallId) {
        Map<String, Object> owner = (Map<String, Object>) recording.get('owner');
        String who = owner != null && owner.get('name') != null ? String.valueOf(owner.get('name')) : 'Unknown owner';
        Integer secs = seconds(recording);
        String line = '• ' + SystemHealthSlack.escape(who) + ' · ' + parse((String) recording.get('date_time')).format('EEE M/d h:mm a')
            + ' · ' + (secs / 60) + 'm ' + Math.mod(secs, 60) + 's · ' + SystemHealthSlack.escape(callId);
        if (voiceCallId != null) {
            line += ' · ' + SystemHealthSlack.recordLink(voiceCallId);
        }
        return line;
    }

    private static String ownerType(Map<String, Object> recording) {
        Map<String, Object> owner = (Map<String, Object>) recording.get('owner');
        return owner != null ? (String) owner.get('type') : null;
    }

    private static Integer seconds(Map<String, Object> recording) {
        Datetime started = parse((String) recording.get('date_time'));
        Datetime ended = parse((String) recording.get('end_time'));
        return started == null || ended == null ? 0 : (Integer) ((ended.getTime() - started.getTime()) / 1000);
    }

    private static Datetime parse(String zoomTime) {
        try {
            return String.isBlank(zoomTime) ? null : Datetime.valueOfGmt(zoomTime.replace('T', ' ').replace('Z', ''));
        } catch (Exception e) {
            return null;
        }
    }

    /// Reads kept in one place so tests can swap in an in-memory version: VoiceCall can't be
    /// inserted in a test.
    public virtual without sharing class Lookups {
        public virtual Map<String, Id> voiceCalls(Set<String> vendorCallKeys) {
            Map<String, Id> byKey = new Map<String, Id>();
            for (VoiceCall vc : [SELECT Id, VendorCallKey FROM VoiceCall WHERE VendorCallKey IN :vendorCallKeys]) {
                byKey.put(vc.VendorCallKey, vc.Id);
            }
            return byKey;
        }

        /// Checked across every VoiceCall with the key: a few calls have two.
        public virtual Set<String> callsWithTranscript(Set<String> vendorCallKeys) {
            Set<String> keys = new Set<String>();
            for (Call_Transcript__c t : [
                SELECT Voice_Call__r.VendorCallKey FROM Call_Transcript__c WHERE Voice_Call__r.VendorCallKey IN :vendorCallKeys
            ]) {
                keys.add(t.Voice_Call__r.VendorCallKey);
            }
            return keys;
        }

        public virtual Set<String> stillRetrying(Set<String> vendorCallKeys) {
            Set<String> keys = new Set<String>();
            for (Zoom_Integration_Error__c e : [
                SELECT Zoom_Meeting_Id__c FROM Zoom_Integration_Error__c
                WHERE Zoom_Meeting_Id__c IN :vendorCallKeys AND Resolved__c = false AND Next_Retry_At__c != null
            ]) {
                keys.add(e.Zoom_Meeting_Id__c);
            }
            return keys;
        }

        /// Calls Zoom reported it couldn't transcribe (code 12000), on any of their rows. A retry's
        /// row keeps its original Error_Type__c and only the message says so.
        public virtual Set<String> untranscribable(Set<String> vendorCallKeys) {
            Set<String> keys = new Set<String>();
            for (Zoom_Integration_Error__c e : [
                SELECT Zoom_Meeting_Id__c, Error_Type__c, Error_Message__c
                FROM Zoom_Integration_Error__c WHERE Zoom_Meeting_Id__c IN :vendorCallKeys
            ]) {
                if (e.Error_Type__c == 'Zoom Cannot Transcribe'
                        || (e.Error_Message__c != null && e.Error_Message__c.contains('"code":12000'))) {
                    keys.add(e.Zoom_Meeting_Id__c);
                }
            }
            return keys;
        }
    }

    public class Summary {
        public Datetime since;
        public Integer checked = 0;
        public Integer retrying = 0;
        public Integer untranscribable = 0;
        public Boolean stoppedEarly = false;
        public List<String> noCall = new List<String>();
        public List<String> noTranscript = new List<String>();
        public String holdReason;
        public String fatalError;

        public Summary(Datetime since) {
            this.since = since;
        }

        public Integer missingCount() {
            return noCall.size() + noTranscript.size();
        }

        public String format() {
            String title = 'Zoom call repair, ' + Datetime.now().format('EEE M/d');
            if (fatalError != null) {
                return ':rotating_light: ' + title + ' did not finish, so missing calls were not checked.\n'
                    + SystemHealthSlack.escape(fatalError);
            }
            String scope = 'Checked ' + checked.format() + ' calls Zoom recorded and transcribed since '
                + since.format('EEE M/d') + '.';
            List<String> skipped = new List<String>();
            if (retrying > 0) {
                skipped.add(retrying.format() + ' still being retried');
            }
            if (untranscribable > 0) {
                skipped.add(untranscribable.format() + ' Zoom couldn\'t transcribe');
            }
            if (!skipped.isEmpty()) {
                scope += ' Skipped: ' + String.join(skipped, ', ') + '.';
            }
            if (stoppedEarly) {
                scope += ' Stopped after ' + MAX_PAGES + ' pages of recordings, so the oldest calls weren\'t checked.';
            }

            if (holdReason != null) {
                return ':warning: ' + title + ': ' + holdReason + '\n' + scope
                    + section('Calls not in Salesforce', noCall) + section('Calls without a transcript', noTranscript);
            }
            if (missingCount() == 0) {
                return ':white_check_mark: ' + title + ': every transcribed call is in Salesforce with its transcript.\n' + scope;
            }
            List<String> counts = new List<String>();
            if (!noCall.isEmpty()) {
                counts.add(noCall.size() + (noCall.size() == 1 ? ' call' : ' calls') + ' not in Salesforce');
            }
            if (!noTranscript.isEmpty()) {
                counts.add(noTranscript.size() + (noTranscript.size() == 1 ? ' call' : ' calls') + ' without a transcript');
            }
            return ':wrench: ' + title + ': ' + String.join(counts, ', ')
                + '. Sent back through the Zoom retry jobs; any that still fail will show in the 7:15 Zoom check.\n' + scope
                + section('Calls not in Salesforce', noCall) + section('Calls without a transcript', noTranscript);
        }

        private String section(String heading, List<String> lines) {
            if (lines.isEmpty()) {
                return '';
            }
            List<String> shown = new List<String>();
            for (Integer i = 0; i < lines.size() && i < MAX_LINES; i++) {
                shown.add(lines[i]);
            }
            if (lines.size() > MAX_LINES) {
                shown.add('…and ' + (lines.size() - MAX_LINES) + ' more');
            }
            return '\n*' + heading + '*\n' + String.join(shown, '\n');
        }
    }
}
