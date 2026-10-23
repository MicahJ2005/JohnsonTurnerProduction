// Covers CommunicationBacklinkService / CommunicationBacklinkQueueable: communications that were already
// in Salesforce get linked when a matching Lead or Opportunity is created afterward.
@isTest
private class CommunicationBacklinkServiceTest {

    private static final String LEAD_PHONE_E164 = '+16125550101';
    private static final String CLIENT_PHONE_E164 = '+16125550110';
    private static final String CLIENT_EMAIL = 'client.backlink@example.com';

    private static Id personRecordTypeId() {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('PersonAccount').getRecordTypeId();
    }

    private static VoiceCall newCall(String toNumber, Id relatedRecordId) {
        return new VoiceCall(
            FromPhoneNumber = '9058',
            ToPhoneNumber = toNumber,
            VendorType = 'Custom',
            CallType = 'Outbound',
            CallStartDateTime = Datetime.now().addMinutes(-10),
            CallEndDateTime = Datetime.now().addMinutes(-5),
            RelatedRecordId = relatedRecordId
        );
    }

    private static Lead newLead(String phone, String mobile, String email) {
        return new Lead(
            LastName = 'Backlink',
            Company = 'Backlink Co',
            Phone = phone,
            MobilePhone = mobile,
            Email = email,
            Status = 'Open - Not Contacted',
            Area_Of_Law__c = 'Business Services'
        );
    }

    private static Opportunity newOpp(Id accountId, String name) {
        return new Opportunity(
            Name = name,
            AccountId = accountId,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Area_of_Law__c = 'Family Law'
        );
    }

    private static String sessionText(String sender, String recipient, String message) {
        return 'Date/Time: 2026-10-01T15:00:00Z\nSender: ' + sender + ', \nTo: ' + recipient + ', \nMessage: ' + message + '\n\n';
    }

    // ── Leads ─────────────────────────────────────────────────────────────────

    @isTest
    static void newLeadClaimsOrphanCallAndLinksTranscript() {
        CommunicationBacklinkService.activeOverride = true;
        Account other = new Account(RecordTypeId = personRecordTypeId(), FirstName = 'Already', LastName = 'Matched');
        insert other;

        VoiceCall orphan = newCall(LEAD_PHONE_E164, null);
        VoiceCall alreadyMatched = newCall(LEAD_PHONE_E164, other.Id);
        VoiceCall tooOld = newCall(LEAD_PHONE_E164, null);
        insert new List<VoiceCall>{ orphan, alreadyMatched, tooOld };
        Test.setCreatedDate(tooOld.Id, Datetime.now().addDays(-(CommunicationBacklinkService.LOOKBACK_DAYS + 5)));
        Call_Transcript__c transcript = new Call_Transcript__c(Voice_Call__c = orphan.Id, Transcript_Text__c = 'Hello');
        insert transcript;

        Lead lead = newLead('(612) 555-0101', null, null);
        Test.startTest();
        insert lead;
        Test.stopTest();

        Map<Id, VoiceCall> calls = new Map<Id, VoiceCall>([SELECT Id, RelatedRecordId FROM VoiceCall]);
        System.assertEquals(lead.Id, calls.get(orphan.Id).RelatedRecordId, 'Orphan call should point at the new Lead');
        System.assertEquals(other.Id, calls.get(alreadyMatched.Id).RelatedRecordId, 'A call already matched to someone else is left alone');
        System.assertEquals(null, calls.get(tooOld.Id).RelatedRecordId, 'Calls older than the lookback window are left alone');

        List<Related_Call_Transcript__c> junctions = [
            SELECT Lead__c, Opportunity__c, Matter__c FROM Related_Call_Transcript__c WHERE Call_Transcript__c = :transcript.Id
        ];
        System.assertEquals(1, junctions.size(), 'One Lead junction for the transcript');
        System.assertEquals(lead.Id, junctions[0].Lead__c);
        System.assertEquals(null, junctions[0].Opportunity__c);
    }

    @isTest
    static void newLeadClaimsOrphanTextSession() {
        CommunicationBacklinkService.activeOverride = true;
        SMS_Session__c orphan = new SMS_Session__c(
            Zoom_Session_Id__c = 'backlink-session-1',
            SMS_Session_Date__c = Date.today(),
            SMS_Session_Text__c = sessionText('16125550102', 'Jane Attorney', 'Hi, this is about my case')
        );
        // The number appears only in the message body, not as a participant.
        SMS_Session__c mentionOnly = new SMS_Session__c(
            Zoom_Session_Id__c = 'backlink-session-2',
            SMS_Session_Date__c = Date.today(),
            SMS_Session_Text__c = sessionText('16125550199', 'Jane Attorney', 'You can also reach me at 612-555-0102')
        );
        insert new List<SMS_Session__c>{ orphan, mentionOnly };

        Lead lead = newLead(null, '612-555-0102', null);
        Test.startTest();
        insert lead;
        Test.stopTest();

        Map<Id, SMS_Session__c> sessions = new Map<Id, SMS_Session__c>([SELECT Id, Prospect__c, Account__c FROM SMS_Session__c]);
        System.assertEquals(lead.Id, sessions.get(orphan.Id).Prospect__c, 'Session should point at the Lead');
        System.assertEquals(null, sessions.get(mentionOnly.Id).Prospect__c, 'A number inside a message is not a participant');

        List<SMS_Session_Individual__c> individuals = [
            SELECT Lead__c, Type__c, Zoom_Session_Id__c FROM SMS_Session_Individual__c WHERE SMS_Session__c = :orphan.Id
        ];
        System.assertEquals(1, individuals.size());
        System.assertEquals(lead.Id, individuals[0].Lead__c);
        System.assertEquals('Lead', individuals[0].Type__c);
        System.assertEquals('backlink-session-1', individuals[0].Zoom_Session_Id__c, 'Zoom session id keeps ZoomSMSIntegration from adding a duplicate');
    }

    @isTest
    static void newLeadLinksEmailsByExactAddress() {
        CommunicationBacklinkService.activeOverride = true;
        EmailMessage match = new EmailMessage(
            Subject = 'Consult follow-up', Status = '3', FromAddress = 'intake@example.org', FromName = 'Intake',
            ToAddress = 'Jane Doe <jane.doe@example.com>; someone@example.com', CcAddress = 'paralegal@example.org'
        );
        EmailMessage nearMiss = new EmailMessage(
            Subject = 'Different person', Status = '3', FromAddress = 'intake@example.org', FromName = 'Intake',
            ToAddress = 'xjane.doe@example.com'
        );
        insert new List<EmailMessage>{ match, nearMiss };

        Lead lead = newLead(null, null, 'Jane.Doe@example.com');
        Test.startTest();
        insert lead;
        Test.stopTest();

        List<Related_Email_Message__c> junctions = [
            SELECT Email_Message_Id__c, Email_Subject__c, Email_Recipients__c FROM Related_Email_Message__c WHERE Lead__c = :lead.Id
        ];
        System.assertEquals(1, junctions.size(), 'Only the email with the exact address should link');
        System.assertEquals(String.valueOf(match.Id), junctions[0].Email_Message_Id__c);
        System.assertEquals('Consult follow-up', junctions[0].Email_Subject__c);
        System.assert(junctions[0].Email_Recipients__c.contains('paralegal@example.org'), 'Recipients include To and Cc');
    }

    @isTest
    static void phoneAddedToExistingLeadIsMatched() {
        CommunicationBacklinkService.activeOverride = true;
        Lead lead = newLead(null, null, null);
        insert lead;
        VoiceCall orphan = newCall(LEAD_PHONE_E164, null);
        insert orphan;

        Test.startTest();
        lead.Phone = '612.555.0101';
        update lead;
        Test.stopTest();

        System.assertEquals(lead.Id, [SELECT RelatedRecordId FROM VoiceCall WHERE Id = :orphan.Id].RelatedRecordId);
    }

    @isTest
    static void internalUserNumberIsNotMatched() {
        CommunicationBacklinkService.activeOverride = true;
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User staff = new User(
            FirstName = 'Staff', LastName = 'Backlink', Email = 'staff.backlink@example.com',
            Username = 'staff.backlink.' + Datetime.now().getTime() + '@example.com', Alias = 'stbk',
            Phone = '(612) 555-0103', ProfileId = p.Id, TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert staff;
        }
        VoiceCall staffLine = newCall('+16125550103', null);
        insert staffLine;

        Test.startTest();
        insert newLead('612-555-0103', null, null);
        Test.stopTest();

        System.assertEquals(null, [SELECT RelatedRecordId FROM VoiceCall WHERE Id = :staffLine.Id].RelatedRecordId,
            'A test Lead carrying a staff number must not claim that line\'s calls');
    }

    @isTest
    static void inactiveSwitchSkipsMatching() {
        CommunicationBacklinkService.activeOverride = false;
        VoiceCall orphan = newCall(LEAD_PHONE_E164, null);
        insert orphan;

        Test.startTest();
        insert newLead('612-555-0101', null, null);
        Test.stopTest();

        System.assertEquals(null, [SELECT RelatedRecordId FROM VoiceCall WHERE Id = :orphan.Id].RelatedRecordId);
    }

    // ── Opportunities ─────────────────────────────────────────────────────────

    @isTest
    static void newOpportunityLinksEverythingForThePerson() {
        CommunicationBacklinkService.activeOverride = false;
        Account client = new Account(
            RecordTypeId = personRecordTypeId(), FirstName = 'Client', LastName = 'Backlink',
            Phone = '(612) 555-0110', PersonEmail = CLIENT_EMAIL
        );
        insert client;
        Id personContactId = [SELECT PersonContactId FROM Account WHERE Id = :client.Id].PersonContactId;

        // Matched to the person before they had an Opportunity, so ingest created no junctions.
        VoiceCall accountCall = newCall('+16125550111', client.Id);
        // Never matched to anyone.
        VoiceCall orphanCall = newCall(CLIENT_PHONE_E164, null);
        insert new List<VoiceCall>{ accountCall, orphanCall };
        Call_Transcript__c accountTranscript = new Call_Transcript__c(Voice_Call__c = accountCall.Id, Transcript_Text__c = 'A');
        Call_Transcript__c orphanTranscript = new Call_Transcript__c(Voice_Call__c = orphanCall.Id, Transcript_Text__c = 'B');
        insert new List<Call_Transcript__c>{ accountTranscript, orphanTranscript };

        Meeting_Transcript__c meeting = new Meeting_Transcript__c(Contact__c = personContactId, Transcript__c = 'Hello', Zoom_Meeting_Id__c = 'backlink-mt');
        insert meeting;

        SMS_Session__c accountSession = new SMS_Session__c(Account__c = client.Id, Zoom_Session_Id__c = 'backlink-acct', SMS_Session_Date__c = Date.today());
        SMS_Session__c orphanSession = new SMS_Session__c(
            Zoom_Session_Id__c = 'backlink-orphan', SMS_Session_Date__c = Date.today(),
            SMS_Session_Text__c = sessionText('Jane Attorney', '+16125550110', 'Following up')
        );
        insert new List<SMS_Session__c>{ accountSession, orphanSession };

        EmailMessage addressed = new EmailMessage(
            Subject = 'Retainer', Status = '3', FromAddress = 'attorney@example.org', FromName = 'Attorney', ToAddress = CLIENT_EMAIL
        );
        insert addressed;

        Opportunity opp = newOpp(client.Id, 'Backlink Opp');
        CommunicationBacklinkService.activeOverride = true;
        Test.startTest();
        insert opp;
        Test.stopTest();

        System.assertEquals(opp.Id, [SELECT RelatedRecordId FROM VoiceCall WHERE Id = :orphanCall.Id].RelatedRecordId,
            'Orphan call matched by phone should point at the new Opportunity');
        assertOneJunction([SELECT Account__c FROM Related_Call_Transcript__c WHERE Opportunity__c = :opp.Id AND Call_Transcript__c = :accountTranscript.Id], client.Id);
        assertOneJunction([SELECT Account__c FROM Related_Call_Transcript__c WHERE Opportunity__c = :opp.Id AND Call_Transcript__c = :orphanTranscript.Id], client.Id);
        assertOneJunction([SELECT Account__c FROM Related_Meeting_Transcript__c WHERE Opportunity__c = :opp.Id AND Meeting_Transcript__c = :meeting.Id], client.Id);
        System.assertEquals(1, [SELECT COUNT() FROM Related_Text_Message__c WHERE Opportunity__c = :opp.Id AND Text_Message_Session__c = :accountSession.Id]);
        System.assertEquals(1, [SELECT COUNT() FROM Related_Text_Message__c WHERE Opportunity__c = :opp.Id AND Text_Message_Session__c = :orphanSession.Id]);
        System.assertEquals(client.Id, [SELECT Account__c FROM SMS_Session__c WHERE Id = :orphanSession.Id].Account__c);
        System.assertEquals(1, [SELECT COUNT() FROM SMS_Session_Individual__c WHERE SMS_Session__c = :orphanSession.Id AND Account__c = :client.Id AND Type__c = 'Account']);
        String addressedId = addressed.Id;
        assertOneJunction([SELECT Account__c FROM Related_Email_Message__c WHERE Opportunity__c = :opp.Id AND Email_Message_Id__c = :addressedId], client.Id);
    }

    @isTest
    static void otherOpportunityLinksAreCopiedWithoutDuplicates() {
        CommunicationBacklinkService.activeOverride = false;
        Account client = new Account(RecordTypeId = personRecordTypeId(), FirstName = 'Repeat', LastName = 'Client');
        insert client;
        Opportunity earlier = newOpp(client.Id, 'Earlier Opp');
        Opportunity opp = newOpp(client.Id, 'New Opp');
        insert new List<Opportunity>{ earlier, opp };

        EmailMessage em = new EmailMessage(Subject = 'Old thread', Status = '3', FromAddress = 'a@example.org', ToAddress = 'b@example.org');
        insert em;
        // Linked by hand to the earlier Opportunity only; no address on it matches the client.
        insert new Related_Email_Message__c(Opportunity__c = earlier.Id, Account__c = client.Id, Email_Message_Id__c = em.Id);

        Test.startTest();
        CommunicationBacklinkService.linkOpportunities(new Set<Id>{ opp.Id });
        CommunicationBacklinkService.linkOpportunities(new Set<Id>{ opp.Id });
        Test.stopTest();

        String emailId = em.Id;
        System.assertEquals(1, [SELECT COUNT() FROM Related_Email_Message__c WHERE Opportunity__c = :opp.Id AND Email_Message_Id__c = :emailId],
            'Email linked to another Opportunity on the Account is copied once, even when run twice');
    }

    @isTest
    static void businessAccountOpportunityIsSkipped() {
        CommunicationBacklinkService.activeOverride = true;
        Account company = new Account(Name = 'Backlink Holdings', Phone = '(612) 555-0120');
        insert company;
        VoiceCall orphan = newCall('+16125550120', null);
        insert orphan;

        Test.startTest();
        insert newOpp(company.Id, 'Company Opp');
        Test.stopTest();

        System.assertEquals(null, [SELECT RelatedRecordId FROM VoiceCall WHERE Id = :orphan.Id].RelatedRecordId);
    }

    @isTest
    static void queueableProcessesOneOpportunityPerRun() {
        CommunicationBacklinkService.activeOverride = false;
        Account client = new Account(RecordTypeId = personRecordTypeId(), FirstName = 'Two', LastName = 'Opps', Phone = '(612) 555-0130');
        insert client;
        Opportunity first = newOpp(client.Id, 'First');
        Opportunity second = newOpp(client.Id, 'Second');
        insert new List<Opportunity>{ first, second };
        VoiceCall orphan = newCall('+16125550130', null);
        insert orphan;

        Test.startTest();
        System.enqueueJob(new CommunicationBacklinkQueueable(new List<Id>(), new List<Id>{ first.Id, second.Id }));
        Test.stopTest();

        System.assertEquals(first.Id, [SELECT RelatedRecordId FROM VoiceCall WHERE Id = :orphan.Id].RelatedRecordId,
            'Only the first Opportunity runs in this job; the rest chain to the next one');
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    @isTest
    static void sessionHeadersAreParsedForParticipantsOnly() {
        Id fakeLeadId = Lead.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
        Map<String, Id> byPhone = new Map<String, Id>{ '6125550140' => fakeLeadId };
        System.assertEquals(fakeLeadId, CommunicationBacklinkService.matchSessionText(sessionText('+16125550140', 'Staff', 'x'), byPhone));
        System.assertEquals(fakeLeadId, CommunicationBacklinkService.matchSessionText(sessionText('Staff', 'Other Person, 16125550140', 'x'), byPhone));
        System.assertEquals(null, CommunicationBacklinkService.matchSessionText(sessionText('Staff', 'Other', 'call 612-555-0140'), byPhone));
        System.assertEquals(null, CommunicationBacklinkService.matchSessionText(null, byPhone));
    }

    @isTest
    static void phonesNormalizeToTenDigits() {
        System.assertEquals('6125550150', CommunicationBacklinkService.normalizePhone('+1 (612) 555-0150'));
        System.assertEquals('6125550150', CommunicationBacklinkService.normalizePhone('1-6125550150'));
        System.assertEquals('6125550150', CommunicationBacklinkService.normalizePhone('612.555.0150'));
        System.assertEquals(null, CommunicationBacklinkService.normalizePhone('9058'), 'Extensions never match');
        System.assertEquals(null, CommunicationBacklinkService.normalizePhone(''));
    }

    private static void assertOneJunction(List<SObject> junctions, Id accountId) {
        System.assertEquals(1, junctions.size(), 'Exactly one junction to the new Opportunity');
        System.assertEquals(accountId, junctions[0].get('Account__c'));
    }
}
