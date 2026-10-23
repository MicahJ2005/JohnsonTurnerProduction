// Links communications that were already in Salesforce before a Lead or Opportunity existed.
//
// Each integration matches a call, text session, meeting transcript, or email to a person only when it
// is ingested (CallTrascriptCommunicationLinkFlow, ZoomSMSIntegration, ZoomTranscriptFetchQueueable,
// EmailMessageTriggerHandler), so anything that arrives before the person's Lead or Opportunity exists
// stays orphaned. This runs the same matching in reverse, from the new record back to the communications.
//
// Leads: orphan calls and text sessions are matched by phone and emails by address, then linked the way
// the integrations would have linked them; LeadTriggerHandler carries those links over at conversion.
// Meeting transcripts carry no phone or address to match on, so they are only reached through the
// Opportunity path.
//
// Opportunities (Person Accounts only): everything already tied to the Account's person, its converted
// Leads, or its other Opportunities and Matters is linked to the new Opportunity, plus orphan calls,
// texts, and emails that match the Account by phone or address. Business Accounts are skipped because
// their Opportunities aren't all for the same person.
public without sharing class CommunicationBacklinkService {

    @TestVisible private static final String ACTIVATION_CLASS_NAME = 'CommunicationBacklinkService';
    // Orphans are matched by phone/address only within this window. In prod (April-October 2026), 111 of the
    // 115 orphan calls a later Lead would have claimed were within 90 days of the call, and all within 180.
    @TestVisible private static final Integer LOOKBACK_DAYS = 180;
    // SMS_Session_Text__c can reach 131K characters, so orphan sessions are read a few at a time.
    private static final Integer SESSION_TEXT_CHUNK = 20;
    // Junction lookups that can tie a communication to an Account's records, in the order they're checked.
    private static final List<String> JUNCTION_ANCHOR_FIELDS = new List<String>{ 'Account__c', 'Opportunity__c', 'Matter__c', 'Lead__c' };

    @TestVisible private static Boolean activeOverride;

    private static Set<String> internalPhones;
    private static Set<String> internalEmails;

    // ── Trigger entry points ──────────────────────────────────────────────────

    public static void handleLeadAfterInsert(List<Lead> newLeads) {
        Set<Id> leadIds = new Set<Id>();
        for (Lead l : newLeads) {
            if (hasContactInfo(l)) {
                leadIds.add(l.Id);
            }
        }
        enqueue(leadIds, new Set<Id>());
    }

    // A phone number or email added after the Lead was created can match communications that arrived in
    // between, so those changes are checked too. Converted Leads are left to LeadTriggerHandler and the
    // Opportunity path.
    public static void handleLeadAfterUpdate(List<Lead> newLeads, Map<Id, Lead> oldMap) {
        Set<Id> leadIds = new Set<Id>();
        for (Lead l : newLeads) {
            Lead old = oldMap.get(l.Id);
            Boolean contactInfoChanged = l.Phone != old.Phone || l.MobilePhone != old.MobilePhone || l.Email != old.Email;
            if (!l.IsConverted && contactInfoChanged && hasContactInfo(l)) {
                leadIds.add(l.Id);
            }
        }
        enqueue(leadIds, new Set<Id>());
    }

    public static void handleOpportunityAfterInsert(List<Opportunity> newOpps) {
        Set<Id> oppIds = new Set<Id>();
        for (Opportunity o : newOpps) {
            if (o.AccountId != null) {
                oppIds.add(o.Id);
            }
        }
        enqueue(new Set<Id>(), oppIds);
    }

    // The work runs after commit so it sees what LinkCommunicationsOnNewOpp and LeadTriggerHandler
    // (at conversion) created in the same transaction, and only fills in what's still missing.
    private static void enqueue(Set<Id> leadIds, Set<Id> opportunityIds) {
        if ((leadIds.isEmpty() && opportunityIds.isEmpty()) || !isActive()) {
            return;
        }
        // Records created inside another async job may leave no room to enqueue; they're skipped
        // rather than failing the caller's transaction.
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            System.debug(LoggingLevel.WARN, 'CommunicationBacklinkService: no queueable headroom, skipped Leads '
                + leadIds + ' and Opportunities ' + opportunityIds);
            return;
        }
        System.enqueueJob(new CommunicationBacklinkQueueable(new List<Id>(leadIds), new List<Id>(opportunityIds)));
    }

    private static Boolean isActive() {
        if (activeOverride != null) {
            return activeOverride;
        }
        List<TriggerActivation__mdt> activations = [
            SELECT Active__c
            FROM TriggerActivation__mdt
            WHERE Trigger_Class_Name__c = :ACTIVATION_CLASS_NAME
            LIMIT 1
        ];
        return activations.isEmpty() || activations[0].Active__c;
    }

    private static Boolean hasContactInfo(Lead l) {
        return String.isNotBlank(l.Phone) || String.isNotBlank(l.MobilePhone) || String.isNotBlank(l.Email);
    }

    // ── Leads ─────────────────────────────────────────────────────────────────

    public static void linkLeads(Set<Id> leadIds) {
        List<Lead> leads = [
            SELECT Id, Phone, MobilePhone, Email
            FROM Lead
            WHERE Id IN :leadIds AND IsConverted = false
            ORDER BY CreatedDate ASC
        ];
        if (leads.isEmpty()) {
            return;
        }

        // A call or text session points at only one record, so when two Leads share a number the
        // earlier one keeps it. Email junctions are many-to-many, so every Lead with the address gets one.
        Map<String, Id> leadByPhone = new Map<String, Id>();
        Map<String, Set<Id>> leadsByAddress = new Map<String, Set<Id>>();
        for (Lead l : leads) {
            for (String phone : externalPhones(new List<String>{ l.Phone, l.MobilePhone })) {
                if (!leadByPhone.containsKey(phone)) {
                    leadByPhone.put(phone, l.Id);
                }
            }
            String address = externalEmail(l.Email);
            if (address != null) {
                addToAddressMap(leadsByAddress, address, l.Id);
            }
        }

        linkCallsToLeads(leadByPhone);
        claimSessions(findOrphanSessions(leadByPhone), true);
        insertEmailJunctions(findEmailsByAddress(leadsByAddress), 'Lead__c', new Map<Id, Id>());
    }

    // Mirrors CallTrascriptCommunicationLinkFlow's Lead branch: the VoiceCall points at the Lead and each
    // transcript gets a Related_Call_Transcript__c with only Lead__c set.
    private static void linkCallsToLeads(Map<String, Id> leadByPhone) {
        Map<Id, Id> leadByCall = new Map<Id, Id>();
        List<VoiceCall> claimed = new List<VoiceCall>();
        for (VoiceCall vc : findOrphanCalls(leadByPhone.keySet())) {
            Id leadId = matchCall(vc, leadByPhone);
            if (leadId != null) {
                leadByCall.put(vc.Id, leadId);
                claimed.add(new VoiceCall(Id = vc.Id, RelatedRecordId = leadId));
            }
        }
        claimCalls(claimed);

        Map<Id, Set<Id>> leadsByTranscript = new Map<Id, Set<Id>>();
        if (!leadByCall.isEmpty()) {
            for (Call_Transcript__c ct : [SELECT Id, Voice_Call__c FROM Call_Transcript__c WHERE Voice_Call__c IN :leadByCall.keySet()]) {
                addToSetMap(leadsByTranscript, ct.Id, leadByCall.get(ct.Voice_Call__c));
            }
        }
        insertMissingJunctions(Related_Call_Transcript__c.SObjectType, 'Call_Transcript__c', 'Lead__c', leadsByTranscript, new Map<Id, Id>());
    }

    // ── Opportunities ─────────────────────────────────────────────────────────

    public static void linkOpportunities(Set<Id> opportunityIds) {
        OpportunityScope scope = new OpportunityScope(opportunityIds);
        if (scope.accountByNewOpp.isEmpty()) {
            return;
        }
        linkCallsToOpportunities(scope);
        linkMeetingsToOpportunities(scope);
        linkTextsToOpportunities(scope);
        linkEmailsToOpportunities(scope);
    }

    // Matches CallTrascriptCommunicationLinkFlow, which links a transcript to every Opportunity and Matter
    // on the Account its VoiceCall points at. Orphan calls matched by phone are pointed at the new
    // Opportunity.
    private static void linkCallsToOpportunities(OpportunityScope scope) {
        Map<Id, Id> accountByCall = new Map<Id, Id>();
        Set<Id> anchorIds = scope.accountByAnchor.keySet();
        for (VoiceCall vc : [SELECT Id, RelatedRecordId FROM VoiceCall WHERE RelatedRecordId IN :anchorIds]) {
            accountByCall.put(vc.Id, scope.accountByAnchor.get(vc.RelatedRecordId));
        }

        List<VoiceCall> claimed = new List<VoiceCall>();
        for (VoiceCall vc : findOrphanCalls(scope.accountByPhone.keySet())) {
            Id accountId = matchCall(vc, scope.accountByPhone);
            if (accountId != null) {
                accountByCall.put(vc.Id, accountId);
                claimed.add(new VoiceCall(Id = vc.Id, RelatedRecordId = scope.newOppsByAccount.get(accountId)[0]));
            }
        }
        claimCalls(claimed);

        Map<Id, Set<Id>> accountsByTranscript = new Map<Id, Set<Id>>();
        if (!accountByCall.isEmpty()) {
            for (Call_Transcript__c ct : [SELECT Id, Voice_Call__c FROM Call_Transcript__c WHERE Voice_Call__c IN :accountByCall.keySet()]) {
                addToSetMap(accountsByTranscript, ct.Id, accountByCall.get(ct.Voice_Call__c));
            }
        }

        Set<Id> accountIds = scope.accountIds;
        Set<Id> otherOppIds = scope.otherOppIds;
        Set<Id> matterIds = scope.matterIds;
        Set<Id> convertedLeadIds = scope.convertedLeadIds;
        for (Related_Call_Transcript__c j : [
            SELECT Call_Transcript__c, Account__c, Opportunity__c, Matter__c, Lead__c
            FROM Related_Call_Transcript__c
            WHERE Call_Transcript__c != null
              AND (Account__c IN :accountIds OR Opportunity__c IN :otherOppIds
                   OR Matter__c IN :matterIds OR Lead__c IN :convertedLeadIds)
        ]) {
            addToSetMap(accountsByTranscript, j.Call_Transcript__c, scope.accountFor(j, JUNCTION_ANCHOR_FIELDS));
        }

        insertMissingJunctions(Related_Call_Transcript__c.SObjectType, 'Call_Transcript__c', 'Opportunity__c',
            scope.toNewOpps(accountsByTranscript), scope.accountByNewOpp);
    }

    // Matches Related_Meeting_Transcripts_to_Opps_and_Matters, which links a transcript to every
    // Opportunity and Matter on its Account__c (or Contact__c's Account).
    private static void linkMeetingsToOpportunities(OpportunityScope scope) {
        Map<Id, Set<Id>> accountsByTranscript = new Map<Id, Set<Id>>();
        Set<Id> accountIds = scope.accountIds;
        Set<Id> personContactIds = scope.personContactIds;
        Set<Id> otherOppIds = scope.otherOppIds;
        Set<Id> matterIds = scope.matterIds;
        Set<Id> convertedLeadIds = scope.convertedLeadIds;

        for (Meeting_Transcript__c mt : [
            SELECT Id, Account__c, Contact__c, Lead__c
            FROM Meeting_Transcript__c
            WHERE Account__c IN :accountIds OR Contact__c IN :personContactIds OR Lead__c IN :convertedLeadIds
        ]) {
            addToSetMap(accountsByTranscript, mt.Id, scope.accountFor(mt, new List<String>{ 'Account__c', 'Contact__c', 'Lead__c' }));
        }
        for (Related_Meeting_Transcript__c j : [
            SELECT Meeting_Transcript__c, Account__c, Opportunity__c, Matter__c, Lead__c
            FROM Related_Meeting_Transcript__c
            WHERE Meeting_Transcript__c != null
              AND (Account__c IN :accountIds OR Opportunity__c IN :otherOppIds
                   OR Matter__c IN :matterIds OR Lead__c IN :convertedLeadIds)
        ]) {
            addToSetMap(accountsByTranscript, j.Meeting_Transcript__c, scope.accountFor(j, JUNCTION_ANCHOR_FIELDS));
        }

        insertMissingJunctions(Related_Meeting_Transcript__c.SObjectType, 'Meeting_Transcript__c', 'Opportunity__c',
            scope.toNewOpps(accountsByTranscript), scope.accountByNewOpp);
    }

    private static void linkTextsToOpportunities(OpportunityScope scope) {
        Map<Id, Set<Id>> accountsBySession = new Map<Id, Set<Id>>();
        Set<Id> accountIds = scope.accountIds;
        Set<Id> otherOppIds = scope.otherOppIds;
        Set<Id> matterIds = scope.matterIds;
        Set<Id> convertedLeadIds = scope.convertedLeadIds;

        for (SMS_Session__c s : [
            SELECT Id, Account__c, Person_Account__c, Prospect__c
            FROM SMS_Session__c
            WHERE Account__c IN :accountIds OR Person_Account__c IN :accountIds OR Prospect__c IN :convertedLeadIds
        ]) {
            addToSetMap(accountsBySession, s.Id, scope.accountFor(s, new List<String>{ 'Account__c', 'Person_Account__c', 'Prospect__c' }));
        }
        // A session's own Account__c holds only the last participant matched, so the per-participant
        // rows are checked as well.
        for (SMS_Session_Individual__c i : [
            SELECT SMS_Session__c, Account__c, Lead__c
            FROM SMS_Session_Individual__c
            WHERE SMS_Session__c != null AND (Account__c IN :accountIds OR Lead__c IN :convertedLeadIds)
        ]) {
            addToSetMap(accountsBySession, i.SMS_Session__c, scope.accountFor(i, new List<String>{ 'Account__c', 'Lead__c' }));
        }
        for (Related_Text_Message__c j : [
            SELECT Text_Message_Session__c, Opportunity__c, Matter__c, Lead__c
            FROM Related_Text_Message__c
            WHERE Text_Message_Session__c != null
              AND (Opportunity__c IN :otherOppIds OR Matter__c IN :matterIds OR Lead__c IN :convertedLeadIds)
        ]) {
            addToSetMap(accountsBySession, j.Text_Message_Session__c, scope.accountFor(j, new List<String>{ 'Opportunity__c', 'Matter__c', 'Lead__c' }));
        }

        List<SessionMatch> orphanMatches = findOrphanSessions(scope.accountByPhone);
        claimSessions(orphanMatches, false);
        for (SessionMatch m : orphanMatches) {
            addToSetMap(accountsBySession, m.sessionId, m.recordId);
        }

        insertMissingJunctions(Related_Text_Message__c.SObjectType, 'Text_Message_Session__c', 'Opportunity__c',
            scope.toNewOpps(accountsBySession), new Map<Id, Id>());
    }

    private static void linkEmailsToOpportunities(OpportunityScope scope) {
        Map<Id, Set<Id>> accountsByEmail = findEmailsByAddress(scope.accountsByAddress);
        Set<Id> accountIds = scope.accountIds;
        Set<Id> otherOppIds = scope.otherOppIds;
        Set<Id> matterIds = scope.matterIds;
        Set<Id> convertedLeadIds = scope.convertedLeadIds;

        for (Related_Email_Message__c j : [
            SELECT Email_Message_Id__c, Account__c, Opportunity__c, Matter__c, Lead__c
            FROM Related_Email_Message__c
            WHERE Email_Message_Id__c != null
              AND (Account__c IN :accountIds OR Opportunity__c IN :otherOppIds
                   OR Matter__c IN :matterIds OR Lead__c IN :convertedLeadIds)
        ]) {
            Id emailId = toId(j.Email_Message_Id__c);
            if (emailId != null) {
                addToSetMap(accountsByEmail, emailId, scope.accountFor(j, JUNCTION_ANCHOR_FIELDS));
            }
        }

        insertEmailJunctions(scope.toNewOpps(accountsByEmail), 'Opportunity__c', scope.accountByNewOpp);
    }

    // Everything the Opportunity path needs to know about the Accounts behind the new Opportunities.
    private class OpportunityScope {
        Map<Id, Id> accountByNewOpp = new Map<Id, Id>();
        Map<Id, List<Id>> newOppsByAccount = new Map<Id, List<Id>>();
        Set<Id> accountIds = new Set<Id>();
        // Records whose communications belong to the Account's person: the Account and its Contacts,
        // Leads converted into it, and its other Opportunities and Matters.
        Map<Id, Id> accountByAnchor = new Map<Id, Id>();
        Set<Id> personContactIds = new Set<Id>();
        Set<Id> convertedLeadIds = new Set<Id>();
        Set<Id> otherOppIds = new Set<Id>();
        Set<Id> matterIds = new Set<Id>();
        Map<String, Id> accountByPhone = new Map<String, Id>();
        Map<String, Set<Id>> accountsByAddress = new Map<String, Set<Id>>();

        OpportunityScope(Set<Id> opportunityIds) {
            for (Opportunity o : [
                SELECT Id, AccountId, ContactId, Contact_ID__c, Account.PersonContactId,
                       Account.Phone, Account.PersonMobilePhone, Account.PersonHomePhone, Account.PersonEmail
                FROM Opportunity
                WHERE Id IN :opportunityIds AND Account.IsPersonAccount = true
                ORDER BY CreatedDate ASC
            ]) {
                accountByNewOpp.put(o.Id, o.AccountId);
                if (!newOppsByAccount.containsKey(o.AccountId)) {
                    newOppsByAccount.put(o.AccountId, new List<Id>());
                }
                newOppsByAccount.get(o.AccountId).add(o.Id);
                accountIds.add(o.AccountId);
                addAnchor(o.AccountId, o.AccountId);
                for (Id contactId : new List<Id>{ o.Account.PersonContactId, o.ContactId, o.Contact_ID__c }) {
                    if (contactId != null) {
                        addAnchor(contactId, o.AccountId);
                        personContactIds.add(contactId);
                    }
                }
                addContactInfo(o.AccountId, new List<String>{ o.Account.Phone, o.Account.PersonMobilePhone, o.Account.PersonHomePhone }, o.Account.PersonEmail);
            }
            if (accountIds.isEmpty()) {
                return;
            }

            for (Lead l : [
                SELECT Id, ConvertedAccountId, Phone, MobilePhone, Email
                FROM Lead
                WHERE IsConverted = true AND ConvertedAccountId IN :accountIds
            ]) {
                addAnchor(l.Id, l.ConvertedAccountId);
                convertedLeadIds.add(l.Id);
                addContactInfo(l.ConvertedAccountId, new List<String>{ l.Phone, l.MobilePhone }, l.Email);
            }
            Set<Id> newOppIds = accountByNewOpp.keySet();
            for (Opportunity o : [SELECT Id, AccountId FROM Opportunity WHERE AccountId IN :accountIds AND Id NOT IN :newOppIds]) {
                addAnchor(o.Id, o.AccountId);
                otherOppIds.add(o.Id);
            }
            for (AcctSeed__Project__c m : [SELECT Id, AcctSeed__Account__c FROM AcctSeed__Project__c WHERE AcctSeed__Account__c IN :accountIds]) {
                addAnchor(m.Id, m.AcctSeed__Account__c);
                matterIds.add(m.Id);
            }
        }

        private void addAnchor(Id recordId, Id accountId) {
            accountByAnchor.put(recordId, accountId);
        }

        private void addContactInfo(Id accountId, List<String> phones, String email) {
            for (String phone : externalPhones(phones)) {
                if (!accountByPhone.containsKey(phone)) {
                    accountByPhone.put(phone, accountId);
                }
            }
            String address = externalEmail(email);
            if (address != null) {
                addToAddressMap(accountsByAddress, address, accountId);
            }
        }

        // First of the given lookup fields that points at one of this scope's Accounts' records.
        Id accountFor(SObject record, List<String> fields) {
            for (String field : fields) {
                Id value = (Id) record.get(field);
                if (value != null && accountByAnchor.containsKey(value)) {
                    return accountByAnchor.get(value);
                }
            }
            return null;
        }

        // Re-keys communication -> Accounts as communication -> the new Opportunities on those Accounts.
        Map<Id, Set<Id>> toNewOpps(Map<Id, Set<Id>> accountsByComm) {
            Map<Id, Set<Id>> oppsByComm = new Map<Id, Set<Id>>();
            for (Id commId : accountsByComm.keySet()) {
                for (Id accountId : accountsByComm.get(commId)) {
                    if (newOppsByAccount.containsKey(accountId)) {
                        for (Id oppId : newOppsByAccount.get(accountId)) {
                            addToSetMap(oppsByComm, commId, oppId);
                        }
                    }
                }
            }
            return oppsByComm;
        }
    }

    // ── Calls ─────────────────────────────────────────────────────────────────

    private static List<VoiceCall> findOrphanCalls(Set<String> phones) {
        if (phones.isEmpty()) {
            return new List<VoiceCall>();
        }
        // VoiceCall stores external numbers in E.164 (+16125551234); the other two forms cover any call
        // logged without the plus sign or country code.
        Set<String> variants = new Set<String>();
        for (String phone : phones) {
            variants.add('+1' + phone);
            variants.add('1' + phone);
            variants.add(phone);
        }
        Datetime cutoff = Datetime.now().addDays(-LOOKBACK_DAYS);
        return [
            SELECT Id, FromPhoneNumber, ToPhoneNumber
            FROM VoiceCall
            WHERE RelatedRecordId = null
              AND CreatedDate >= :cutoff
              AND (FromPhoneNumber IN :variants OR ToPhoneNumber IN :variants)
            ORDER BY CreatedDate ASC
        ];
    }

    private static Id matchCall(VoiceCall vc, Map<String, Id> recordByPhone) {
        for (String phone : new List<String>{ normalizePhone(vc.FromPhoneNumber), normalizePhone(vc.ToPhoneNumber) }) {
            if (phone != null && recordByPhone.containsKey(phone)) {
                return recordByPhone.get(phone);
            }
        }
        return null;
    }

    // Pointing the VoiceCall itself at the record is best effort: VoiceCall writes depend on Conversation
    // Insights access the running user may not have, and a rejected update shouldn't stop the transcript,
    // text, and email links.
    private static void claimCalls(List<VoiceCall> calls) {
        if (calls.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.update(calls, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(LoggingLevel.WARN, 'CommunicationBacklinkService: VoiceCall ' + calls[i].Id
                    + ' not linked to ' + calls[i].RelatedRecordId + ': ' + results[i].getErrors());
            }
        }
    }

    // ── Text sessions ─────────────────────────────────────────────────────────

    private class SessionMatch {
        Id sessionId;
        String zoomSessionId;
        Id recordId;

        SessionMatch(SMS_Session__c session, Id recordId) {
            this.sessionId = session.Id;
            this.zoomSessionId = session.Zoom_Session_Id__c;
            this.recordId = recordId;
        }
    }

    // ZoomSMSIntegration writes a participant it can't match into the session's "Sender:" and "To:" lines
    // as a raw phone number, which is the only place an orphan session keeps it. SMS_Session_Text__c is a
    // long text area and can't be filtered in SOQL, so orphan sessions are read and parsed here.
    private static List<SessionMatch> findOrphanSessions(Map<String, Id> recordByPhone) {
        List<SessionMatch> matches = new List<SessionMatch>();
        if (recordByPhone.isEmpty()) {
            return matches;
        }
        Date cutoff = Date.today().addDays(-LOOKBACK_DAYS);
        List<Id> sessionIds = new List<Id>(new Map<Id, SMS_Session__c>([
            SELECT Id
            FROM SMS_Session__c
            WHERE Account__c = null AND Prospect__c = null AND Person_Account__c = null
              AND SMS_Session_Date__c >= :cutoff
        ]).keySet());

        for (Integer i = 0; i < sessionIds.size(); i += SESSION_TEXT_CHUNK) {
            List<Id> chunk = new List<Id>();
            for (Integer j = i; j < Math.min(i + SESSION_TEXT_CHUNK, sessionIds.size()); j++) {
                chunk.add(sessionIds[j]);
            }
            for (SMS_Session__c s : [SELECT Id, Zoom_Session_Id__c, SMS_Session_Text__c FROM SMS_Session__c WHERE Id IN :chunk]) {
                Id recordId = matchSessionText(s.SMS_Session_Text__c, recordByPhone);
                if (recordId != null) {
                    matches.add(new SessionMatch(s, recordId));
                }
            }
        }
        return matches;
    }

    @TestVisible
    private static Id matchSessionText(String text, Map<String, Id> recordByPhone) {
        if (String.isBlank(text)) {
            return null;
        }
        for (String line : text.split('\n')) {
            if (!line.startsWith('Sender: ') && !line.startsWith('To: ')) {
                continue;
            }
            for (String participant : line.substringAfter(': ').split(',')) {
                String phone = normalizePhone(participant);
                if (phone != null && recordByPhone.containsKey(phone)) {
                    return recordByPhone.get(phone);
                }
            }
        }
        return null;
    }

    // Writes what ZoomSMSIntegration writes when it matches a participant at ingest. The individual's
    // Zoom_Session_Id__c and Type__c are part of that class's dedupe key, so its next sync of the same
    // session doesn't add a duplicate.
    private static void claimSessions(List<SessionMatch> matches, Boolean isLead) {
        if (matches.isEmpty()) {
            return;
        }
        List<SMS_Session__c> sessions = new List<SMS_Session__c>();
        List<SMS_Session_Individual__c> individuals = new List<SMS_Session_Individual__c>();
        for (SessionMatch m : matches) {
            SMS_Session__c session = new SMS_Session__c(Id = m.sessionId);
            SMS_Session_Individual__c individual = new SMS_Session_Individual__c(
                SMS_Session__c = m.sessionId,
                Zoom_Session_Id__c = m.zoomSessionId,
                Type__c = isLead ? 'Lead' : 'Account'
            );
            if (isLead) {
                session.Prospect__c = m.recordId;
                individual.Lead__c = m.recordId;
            } else {
                session.Account__c = m.recordId;
                individual.Account__c = m.recordId;
            }
            sessions.add(session);
            individuals.add(individual);
        }
        update sessions;
        insert individuals;
    }

    // ── Emails ────────────────────────────────────────────────────────────────

    // Same address matching as EmailMessageTriggerHandler: From, To, Cc, and Bcc, case-insensitive.
    private static Map<Id, Set<Id>> findEmailsByAddress(Map<String, Set<Id>> recordsByAddress) {
        Map<Id, Set<Id>> recordsByEmail = new Map<Id, Set<Id>>();
        if (recordsByAddress.isEmpty()) {
            return recordsByEmail;
        }
        Set<String> addresses = recordsByAddress.keySet();
        List<String> patterns = new List<String>();
        for (String address : addresses) {
            patterns.add('%' + address + '%');
        }
        Datetime cutoff = Datetime.now().addDays(-LOOKBACK_DAYS);
        for (EmailMessage em : [
            SELECT Id, FromAddress, ToAddress, CcAddress, BccAddress
            FROM EmailMessage
            WHERE CreatedDate >= :cutoff
              AND (FromAddress IN :addresses OR ToAddress LIKE :patterns
                   OR CcAddress LIKE :patterns OR BccAddress LIKE :patterns)
        ]) {
            // LIKE also matches longer addresses that contain this one, so only exact addresses count.
            for (String address : collectAddresses(em)) {
                if (recordsByAddress.containsKey(address)) {
                    for (Id recordId : recordsByAddress.get(address)) {
                        addToSetMap(recordsByEmail, em.Id, recordId);
                    }
                }
            }
        }
        return recordsByEmail;
    }

    // Related_Email_Message__c keeps the email's Id in a text field, so existing rows are compared after
    // converting it back to an Id; both Id lengths are searched in case an older row stored 15 characters.
    private static void insertEmailJunctions(Map<Id, Set<Id>> recordsByEmail, String targetField, Map<Id, Id> accountByRecord) {
        if (recordsByEmail.isEmpty()) {
            return;
        }
        Set<Id> emailIds = recordsByEmail.keySet();
        Set<String> emailIdStrings = new Set<String>();
        for (Id emailId : emailIds) {
            String idString = emailId;
            emailIdStrings.add(idString);
            emailIdStrings.add(idString.left(15));
        }
        Set<Id> targetIds = new Set<Id>();
        for (Set<Id> ids : recordsByEmail.values()) {
            targetIds.addAll(ids);
        }

        Set<String> existing = new Set<String>();
        for (SObject j : Database.query(
            'SELECT Email_Message_Id__c, ' + targetField + ' FROM Related_Email_Message__c'
            + ' WHERE Email_Message_Id__c IN :emailIdStrings AND ' + targetField + ' IN :targetIds'
        )) {
            Id emailId = toId((String) j.get('Email_Message_Id__c'));
            if (emailId != null) {
                existing.add(pairKey(emailId, (Id) j.get(targetField)));
            }
        }

        List<Related_Email_Message__c> junctions = new List<Related_Email_Message__c>();
        for (EmailMessage em : [SELECT Id, Subject, ToAddress, CcAddress FROM EmailMessage WHERE Id IN :emailIds]) {
            for (Id targetId : recordsByEmail.get(em.Id)) {
                if (!existing.add(pairKey(em.Id, targetId))) {
                    continue;
                }
                Related_Email_Message__c j = new Related_Email_Message__c(
                    Account__c = accountByRecord.get(targetId),
                    Email_Message_Id__c = em.Id,
                    Email_Subject__c = em.Subject?.left(255),
                    Email_Recipients__c = combinedRecipients(em)
                );
                j.put(targetField, targetId);
                junctions.add(j);
            }
        }
        insert junctions;
    }

    // To and Cc together, as EmailMessageTriggerHandler.buildRelatedMsg stores them, cut to the field's
    // 255 characters.
    private static String combinedRecipients(EmailMessage em) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(em.ToAddress)) {
            parts.add(em.ToAddress.trim());
        }
        if (String.isNotBlank(em.CcAddress)) {
            parts.add(em.CcAddress.trim());
        }
        return String.join(parts, ', ').left(255);
    }

    private static Set<String> collectAddresses(EmailMessage em) {
        Set<String> addresses = new Set<String>();
        for (String field : new List<String>{ em.FromAddress, em.ToAddress, em.CcAddress, em.BccAddress }) {
            if (String.isBlank(field)) {
                continue;
            }
            for (String raw : field.split('[,;]')) {
                String address = raw.trim().toLowerCase();
                // "Name <address>" form
                if (address.contains('<') && address.contains('>')) {
                    address = address.substringBetween('<', '>').trim();
                }
                if (String.isNotBlank(address)) {
                    addresses.add(address);
                }
            }
        }
        return addresses;
    }

    // ── Shared ────────────────────────────────────────────────────────────────

    // One junction per (communication, record) pair that doesn't already exist. For Opportunities the
    // LinkCommunicationsOnNewOpp flow has usually created some of them by the time this runs.
    private static void insertMissingJunctions(
        SObjectType junctionType, String commField, String targetField,
        Map<Id, Set<Id>> recordsByComm, Map<Id, Id> accountByRecord
    ) {
        if (recordsByComm.isEmpty()) {
            return;
        }
        Set<Id> commIds = recordsByComm.keySet();
        Set<Id> targetIds = new Set<Id>();
        for (Set<Id> ids : recordsByComm.values()) {
            targetIds.addAll(ids);
        }

        Set<String> existing = new Set<String>();
        for (SObject j : Database.query(
            'SELECT ' + commField + ', ' + targetField + ' FROM ' + String.valueOf(junctionType)
            + ' WHERE ' + commField + ' IN :commIds AND ' + targetField + ' IN :targetIds'
        )) {
            existing.add(pairKey((Id) j.get(commField), (Id) j.get(targetField)));
        }

        List<SObject> junctions = new List<SObject>();
        for (Id commId : commIds) {
            for (Id targetId : recordsByComm.get(commId)) {
                if (!existing.add(pairKey(commId, targetId))) {
                    continue;
                }
                SObject j = junctionType.newSObject();
                j.put(commField, commId);
                j.put(targetField, targetId);
                if (accountByRecord.containsKey(targetId)) {
                    j.put('Account__c', accountByRecord.get(targetId));
                }
                junctions.add(j);
            }
        }
        insert junctions;
    }

    // 10-digit US number, or null for extensions, short codes, and international numbers.
    @TestVisible
    private static String normalizePhone(String phone) {
        if (String.isBlank(phone)) {
            return null;
        }
        String digits = phone.replaceAll('[^0-9]', '');
        if (digits.length() == 11 && digits.startsWith('1')) {
            digits = digits.substring(1);
        }
        return digits.length() == 10 ? digits : null;
    }

    // Numbers that belong to an internal user are skipped (as ZoomPhoneIntegration does), so a test Lead
    // carrying a staff number can't claim every call on that line.
    private static Set<String> externalPhones(List<String> phones) {
        if (internalPhones == null) {
            internalPhones = new Set<String>();
            for (User u : [SELECT Phone, MobilePhone FROM User WHERE IsActive = true AND UserType = 'Standard']) {
                internalPhones.add(normalizePhone(u.Phone));
                internalPhones.add(normalizePhone(u.MobilePhone));
            }
        }
        Set<String> result = new Set<String>();
        for (String phone : phones) {
            String normalized = normalizePhone(phone);
            if (normalized != null && !internalPhones.contains(normalized)) {
                result.add(normalized);
            }
        }
        return result;
    }

    private static String externalEmail(String email) {
        if (String.isBlank(email)) {
            return null;
        }
        if (internalEmails == null) {
            internalEmails = new Set<String>();
            for (User u : [SELECT Email FROM User WHERE IsActive = true AND UserType = 'Standard']) {
                internalEmails.add(u.Email.toLowerCase());
            }
        }
        String address = email.trim().toLowerCase();
        return internalEmails.contains(address) ? null : address;
    }

    private static Id toId(String value) {
        try {
            return String.isBlank(value) ? null : Id.valueOf(value.trim());
        } catch (Exception e) {
            return null;
        }
    }

    private static String pairKey(Id commId, Id recordId) {
        return commId + '|' + recordId;
    }

    private static void addToSetMap(Map<Id, Set<Id>> setMap, Id key, Id value) {
        if (value == null) {
            return;
        }
        if (!setMap.containsKey(key)) {
            setMap.put(key, new Set<Id>());
        }
        setMap.get(key).add(value);
    }

    private static void addToAddressMap(Map<String, Set<Id>> setMap, String key, Id value) {
        if (!setMap.containsKey(key)) {
            setMap.put(key, new Set<Id>());
        }
        setMap.get(key).add(value);
    }
}
