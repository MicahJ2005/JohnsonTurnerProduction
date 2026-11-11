/// Micah Johnson - Demand Chain 2026
/// Daily post to the system health Slack channel listing the Zoom calls and meetings the integration
/// gave up on in the last 24 hours. A failed row in Zoom_Integration_Error__c ends up Resolved
/// whether the work was later recovered or lost for good, so each one is checked against what
/// actually exists: a VoiceCall for the call, a transcript on it, an uploaded recording, a
/// Meeting_Transcript__c for the meeting. Paige DuCharme's calls (10/2026) were lost for weeks
/// behind rows marked Resolved.
///
/// Posts every day, including days with nothing lost, so a missing post means the job didn't run.
/// A weekday with nothing coming in at all is flagged too: the 10/9 meeting transcript outage
/// logged no errors for 12 days.
///
/// Schedule:  ZoomIngestionDigestScheduler.schedule();
/// Run now:   System.enqueueJob(new ZoomIngestionDigest());
public without sharing class ZoomIngestionDigest implements Queueable, Database.AllowsCallouts {

    private static final Integer MAX_LINES = 15;
    private static final String MEETING_CLASS = 'ZoomTranscriptFetchQueueable';

    @TestVisible
    private static Lookups lookups = new Lookups();

    public void execute(QueueableContext context) {
        String message;
        try {
            message = build(Datetime.now().addHours(-24)).format();
        } catch (Exception e) {
            message = ':rotating_light: Zoom check did not finish, so lost calls were not checked.\n'
                + SystemHealthSlack.escape(e.getMessage());
        }
        SystemHealthSlack.post(message);
    }

    @TestVisible
    private static Digest build(Datetime since) {
        List<Zoom_Integration_Error__c> retrying = lookups.stillRetrying();
        Digest digest = new Digest(since, lookups.ingestedSince(since), retrying.size());
        List<Zoom_Integration_Error__c> finished = lookups.finishedErrorsSince(since);

        // A call whose transcript or creation is still being retried isn't lost yet.
        Set<String> pending = new Set<String>();
        for (Zoom_Integration_Error__c e : retrying) {
            pending.add(e.Zoom_Meeting_Id__c);
        }

        Set<String> callKeys = new Set<String>();
        Set<String> meetingKeys = new Set<String>();
        Set<String> zoomUserIds = new Set<String>();
        for (Zoom_Integration_Error__c e : finished) {
            if (String.isBlank(e.Zoom_Meeting_Id__c) || pending.contains(e.Zoom_Meeting_Id__c)) {
                continue;
            }
            if (e.Apex_Class__c == MEETING_CLASS) {
                meetingKeys.add(e.Zoom_Meeting_Id__c);
                if (e.Zoom_User_Id__c != null) {
                    zoomUserIds.add(e.Zoom_User_Id__c);
                }
            } else {
                callKeys.add(e.Zoom_Meeting_Id__c);
            }
        }
        Map<String, CallState> calls = lookups.calls(callKeys);
        Set<String> untranscribableKeys = lookups.untranscribableCalls(callKeys);
        Set<String> transcribedMeetings = lookups.meetingsWithTranscript(meetingKeys);
        Map<String, String> userNames = lookups.userNamesByZoomId(zoomUserIds);

        for (Zoom_Integration_Error__c e : finished) {
            String key = e.Zoom_Meeting_Id__c;
            String reason = reasonFor(e);
            if (String.isBlank(key)) {
                digest.lose(Loss.OTHER, e.Apex_Class__c + '.' + e.Apex_Method__c, reason, e.Id, null);
                continue;
            }
            if (pending.contains(key)) {
                continue;
            }
            if (e.Apex_Class__c == MEETING_CLASS) {
                if (!transcribedMeetings.contains(key)) {
                    digest.lose(Loss.MEETING_TRANSCRIPT, userNames.get(e.Zoom_User_Id__c), reason, key, null);
                }
                continue;
            }

            CallState call = calls.get(key);
            if (e.Apex_Method__c == 'uploadRecording') {
                if (call != null && !call.recordingUploaded) {
                    digest.lose(Loss.RECORDING, call.userName, reason, key, call.voiceCallId);
                }
            } else if (untranscribableKeys.contains(key)) {
                digest.untranscribable.add(key);
            } else if (call == null) {
                // A transcript for a call with no VoiceCall is almost always a call under 10 seconds,
                // which the poll skips on purpose (all 29 checked against Zoom, 10/20-10/27/2026).
                if (e.Error_Type__c == 'Voice Call Not Found') {
                    digest.noCallRecord.add(key);
                } else {
                    digest.lose(Loss.CALL, ownerFromPayload(e.Raw_Payload__c), reason, key, null);
                }
            } else if (!call.hasTranscript) {
                digest.lose(Loss.TRANSCRIPT, call.userName, reason, key, call.voiceCallId);
            }
        }
        return digest;
    }

    /// Shortens a logged error to the part that names the cause, so one cause across many calls
    /// groups into one line.
    @TestVisible
    private static String reasonFor(Zoom_Integration_Error__c e) {
        String message = String.isBlank(e.Error_Message__c) ? e.Error_Type__c : e.Error_Message__c;
        if (message == null) {
            return 'no error message';
        }
        if (message.contains('FILE_SIZE_LIMIT_EXCEEDED')) {
            return 'recording too large to upload';
        }
        if (message.contains('errorMsg=')) {
            message = message.substringAfter('errorMsg=');
        }
        if (message.contains('. uploadUrl was')) {
            message = message.substringBefore('. uploadUrl was');
        }
        return message.normalizeSpace().abbreviate(150);
    }

    /// The recording payload saved with a failed VoiceCall creation names the Zoom user who owns the call.
    @TestVisible
    private static String ownerFromPayload(String rawPayload) {
        try {
            Map<String, Object> recording = (Map<String, Object>) JSON.deserializeUntyped(rawPayload);
            Map<String, Object> owner = (Map<String, Object>) recording.get('owner');
            return (String) owner.get('name');
        } catch (Exception e) {
            return null;
        }
    }

    public enum Loss { CALL, TRANSCRIPT, RECORDING, MEETING_TRANSCRIPT, OTHER }

    public class CallState {
        public Id voiceCallId;
        public String userName;
        public Boolean hasTranscript = false;
        public Boolean recordingUploaded = false;
    }

    public class Ingested {
        public Integer calls = 0;
        public Integer callTranscripts = 0;
        public Integer meetingTranscripts = 0;
    }

    /// Reads kept in one place so tests can swap in an in-memory version: VoiceCall can't be
    /// inserted in a test.
    public virtual without sharing class Lookups {
        public virtual List<Zoom_Integration_Error__c> finishedErrorsSince(Datetime since) {
            return [
                SELECT Id, Apex_Class__c, Apex_Method__c, Error_Type__c, Error_Message__c,
                       Zoom_Meeting_Id__c, Zoom_User_Id__c, Raw_Payload__c
                FROM Zoom_Integration_Error__c
                WHERE Resolved__c = true AND LastModifiedDate >= :since
                ORDER BY CreatedDate
            ];
        }

        /// Only rows with a retry scheduled: hundreds of Jul-Sep 2026 rows were logged unresolved with
        /// no retry, before the logger marked failures Resolved.
        public virtual List<Zoom_Integration_Error__c> stillRetrying() {
            return [SELECT Zoom_Meeting_Id__c FROM Zoom_Integration_Error__c WHERE Resolved__c = false AND Next_Retry_At__c != null];
        }

        /// Calls Zoom reported it couldn't transcribe (code 12000), on any of their rows. A retry's
        /// row keeps its original Error_Type__c and only the message says so.
        public virtual Set<String> untranscribableCalls(Set<String> vendorCallKeys) {
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

        public virtual Map<String, CallState> calls(Set<String> vendorCallKeys) {
            Map<String, CallState> byKey = new Map<String, CallState>();
            if (vendorCallKeys.isEmpty()) {
                return byKey;
            }
            Map<Id, CallState> byId = new Map<Id, CallState>();
            for (VoiceCall vc : [
                SELECT Id, VendorCallKey, User.Name, CreatedBy.Name, CallRecording.UploadDateTime
                FROM VoiceCall WHERE VendorCallKey IN :vendorCallKeys
            ]) {
                CallState call = new CallState();
                call.voiceCallId = vc.Id;
                call.userName = vc.User != null ? vc.User.Name : vc.CreatedBy.Name;
                call.recordingUploaded = vc.CallRecording != null && vc.CallRecording.UploadDateTime != null;
                byKey.put(vc.VendorCallKey, call);
                byId.put(vc.Id, call);
            }
            for (Call_Transcript__c t : [SELECT Voice_Call__c FROM Call_Transcript__c WHERE Voice_Call__c IN :byId.keySet()]) {
                byId.get(t.Voice_Call__c).hasTranscript = true;
            }
            return byKey;
        }

        public virtual Set<String> meetingsWithTranscript(Set<String> zoomMeetingIds) {
            Set<String> found = new Set<String>();
            for (Meeting_Transcript__c t : [SELECT Zoom_Event_Id__c FROM Meeting_Transcript__c WHERE Zoom_Event_Id__c IN :zoomMeetingIds]) {
                found.add(t.Zoom_Event_Id__c);
            }
            return found;
        }

        public virtual Map<String, String> userNamesByZoomId(Set<String> zoomUserIds) {
            Map<String, String> names = new Map<String, String>();
            for (User u : [SELECT Name, Zoom_User_Id__c FROM User WHERE Zoom_User_Id__c IN :zoomUserIds]) {
                names.put(u.Zoom_User_Id__c, u.Name);
            }
            return names;
        }

        public virtual Ingested ingestedSince(Datetime since) {
            Ingested counts = new Ingested();
            counts.calls = [SELECT COUNT() FROM VoiceCall WHERE CreatedDate >= :since];
            counts.callTranscripts = [SELECT COUNT() FROM Call_Transcript__c WHERE CreatedDate >= :since AND Transcript_Sequence__c = 1];
            counts.meetingTranscripts = [SELECT COUNT() FROM Meeting_Transcript__c WHERE CreatedDate >= :since];
            return counts;
        }
    }

    public class Digest {
        private Datetime since;
        private Ingested ingested;
        private Integer stillRetrying;
        // Kind -> (who + reason) -> calls or meetings; a call logged several times is listed once.
        private Map<Loss, Map<String, Set<String>>> lost = new Map<Loss, Map<String, Set<String>>>();
        private Map<String, List<Id>> recordsByGroup = new Map<String, List<Id>>();
        public Set<String> noCallRecord = new Set<String>();
        public Set<String> untranscribable = new Set<String>();

        public Digest(Datetime since, Ingested ingested, Integer stillRetrying) {
            this.since = since;
            this.ingested = ingested;
            this.stillRetrying = stillRetrying;
        }

        public void lose(Loss kind, String who, String reason, String key, Id recordId) {
            if (!lost.containsKey(kind)) {
                lost.put(kind, new Map<String, Set<String>>());
            }
            String groupKey = (String.isBlank(who) ? 'Unknown user' : who) + '\u001F' + reason;
            Map<String, Set<String>> groups = lost.get(kind);
            if (!groups.containsKey(groupKey)) {
                groups.put(groupKey, new Set<String>());
                recordsByGroup.put(kind.name() + groupKey, new List<Id>());
            }
            if (groups.get(groupKey).add(key) && recordId != null) {
                recordsByGroup.get(kind.name() + groupKey).add(recordId);
            }
        }

        public Integer count(Loss kind) {
            Integer n = 0;
            if (lost.containsKey(kind)) {
                for (Set<String> keys : lost.get(kind).values()) {
                    n += keys.size();
                }
            }
            return n;
        }

        /// Business hours fall in the window when it starts on a weekday (the runs Tuesday-Saturday).
        private Boolean isWeekdayWindow() {
            return Integer.valueOf(since.format('u')) <= 5;
        }

        public String format() {
            String title = 'Zoom check, ' + Datetime.now().format('EEE M/d');
            String inLine = 'In the last 24 hours: ' + plural(ingested.calls, 'call', 'calls') + ', '
                + plural(ingested.callTranscripts, 'call transcript', 'call transcripts') + ', '
                + plural(ingested.meetingTranscripts, 'meeting transcript', 'meeting transcripts')
                + '. Still retrying: ' + stillRetrying.format() + '.';
            List<String> notes = new List<String>();
            if (!noCallRecord.isEmpty()) {
                notes.add(plural(noCallRecord.size(), 'transcript', 'transcripts')
                    + ' for calls with no call record (calls under 10 seconds aren\'t logged)');
            }
            if (!untranscribable.isEmpty()) {
                notes.add(plural(untranscribable.size(), 'recording', 'recordings') + ' Zoom couldn\'t transcribe');
            }
            if (!notes.isEmpty()) {
                inLine += ' Not counted as lost: ' + String.join(notes, '; ') + '.';
            }

            List<String> quiet = new List<String>();
            if (isWeekdayWindow()) {
                if (ingested.calls == 0) {
                    quiet.add('calls');
                }
                if (ingested.callTranscripts == 0) {
                    quiet.add('call transcripts');
                }
                if (ingested.meetingTranscripts == 0) {
                    quiet.add('meeting transcripts');
                }
            }

            List<String> counts = new List<String>();
            addCount(counts, Loss.CALL, 'call not created', 'calls not created');
            addCount(counts, Loss.TRANSCRIPT, 'call without a transcript', 'calls without a transcript');
            addCount(counts, Loss.RECORDING, 'recording not uploaded', 'recordings not uploaded');
            addCount(counts, Loss.MEETING_TRANSCRIPT, 'meeting transcript missed', 'meeting transcripts missed');
            addCount(counts, Loss.OTHER, 'other error', 'other errors');

            String headline;
            if (counts.isEmpty() && quiet.isEmpty()) {
                headline = ':white_check_mark: ' + title + ': nothing lost.';
            } else {
                List<String> problems = new List<String>(counts);
                if (!quiet.isEmpty()) {
                    problems.add('no ' + String.join(quiet, ' or ') + ' came in on a weekday');
                }
                headline = ':warning: ' + title + ': ' + String.join(problems, ', ') + '.';
            }
            return headline + '\n' + inLine
                + section('Calls not created', Loss.CALL)
                + section('Calls without a transcript', Loss.TRANSCRIPT)
                + section('Recordings not uploaded', Loss.RECORDING)
                + section('Meeting transcripts missed', Loss.MEETING_TRANSCRIPT)
                + section('Other errors', Loss.OTHER);
        }

        private void addCount(List<String> counts, Loss kind, String one, String many) {
            Integer n = count(kind);
            if (n > 0) {
                counts.add(plural(n, one, many));
            }
        }

        private String plural(Integer n, String one, String many) {
            return n.format() + ' ' + (n == 1 ? one : many);
        }

        private String section(String heading, Loss kind) {
            if (!lost.containsKey(kind)) {
                return '';
            }
            List<String> lines = new List<String>();
            for (String groupKey : lost.get(kind).keySet()) {
                String who = groupKey.substringBefore('\u001F');
                String reason = groupKey.substringAfter('\u001F');
                Integer n = lost.get(kind).get(groupKey).size();
                String line = '• ' + SystemHealthSlack.escape(who) + (n > 1 ? ' ×' + n : '') + ' · ' + SystemHealthSlack.escape(reason);
                List<String> links = new List<String>();
                for (Id recordId : recordsByGroup.get(kind.name() + groupKey)) {
                    if (links.size() == 3) {
                        break;
                    }
                    links.add(SystemHealthSlack.recordLink(recordId));
                }
                if (!links.isEmpty()) {
                    line += ' · ' + String.join(links, ', ');
                }
                lines.add(line);
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
