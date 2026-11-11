/// Covers the Related_Meeting_Transcripts_to_Opps_and_Matters record-triggered flow, which creates
/// Related_Meeting_Transcript__c junctions linking a new Meeting_Transcript__c to every Opportunity
/// and Matter on its account (from Account__c, or from Contact__c's account).
@isTest
private class RelatedMeetingTranscriptsFlowTest {

    @testSetup
    static void setup() {
        AyTestDataSuite.init();

        AcctSeed__Project__c matter = new AcctSeed__Project__c();
        matter.Name = 'Transcript Link Test Matter';
        matter.AcctSeed__Account__c = AyTestDataSuite.accounts[0].Id;
        matter.AcctSeed__Opportunity__c = AyTestDataSuite.Opportunities[0].Id;
        matter.AcctSeed__Status__c = 'Active';
        insert matter;
    }

    private static Contact getContact() {
        return [SELECT Id, AccountId FROM Contact WHERE LastName = 'Test Contact LastName' LIMIT 1];
    }

    // Asserts exactly one junction per Opportunity and per Matter on the account, all stamped with
    // the account - the Opps/Matters are read back rather than hardcoded, since other automation may add more.
    private static void assertLinkedToAllOppsAndMatters(Id transcriptId, Id accountId) {
        Set<Id> expectedOpps = new Map<Id, Opportunity>([SELECT Id FROM Opportunity WHERE AccountId = :accountId]).keySet();
        Set<Id> expectedMatters = new Map<Id, AcctSeed__Project__c>(
            [SELECT Id FROM AcctSeed__Project__c WHERE AcctSeed__Account__c = :accountId]).keySet();
        System.assert(!expectedOpps.isEmpty() && !expectedMatters.isEmpty(), 'Test account should have an Opportunity and a Matter');

        List<Related_Meeting_Transcript__c> junctions = [
            SELECT Account__c, Opportunity__c, Matter__c
            FROM Related_Meeting_Transcript__c
            WHERE Meeting_Transcript__c = :transcriptId
        ];
        Set<Id> linkedOpps = new Set<Id>();
        Set<Id> linkedMatters = new Set<Id>();
        for (Related_Meeting_Transcript__c j : junctions) {
            System.assertEquals(accountId, j.Account__c, 'Every junction should carry the account');
            if (j.Opportunity__c != null) linkedOpps.add(j.Opportunity__c);
            if (j.Matter__c != null) linkedMatters.add(j.Matter__c);
        }
        System.assertEquals(expectedOpps, linkedOpps, 'Every Opportunity on the account should be linked');
        System.assertEquals(expectedMatters, linkedMatters, 'Every Matter on the account should be linked');
        System.assertEquals(expectedOpps.size() + expectedMatters.size(), junctions.size(), 'No duplicate or empty junctions');
    }

    @isTest
    static void testContactTranscriptLinksToAccountsOppsAndMatters() {
        // The Contact path used to look the Contact up by IndividualId (never matched) and added the
        // collection to itself instead of the new Opportunity junction, so it never linked anything.
        Contact con = getContact();
        Meeting_Transcript__c mt = new Meeting_Transcript__c(Contact__c = con.Id, Transcript__c = 'Hello', Zoom_Meeting_Id__c = 'contact-test');

        Test.startTest();
        insert mt;
        Test.stopTest();

        assertLinkedToAllOppsAndMatters(mt.Id, con.AccountId);
    }

    @isTest
    static void testAccountTranscriptStillLinks() {
        Id accountId = getContact().AccountId;
        Meeting_Transcript__c mt = new Meeting_Transcript__c(Account__c = accountId, Transcript__c = 'Hello', Zoom_Meeting_Id__c = 'account-test');

        Test.startTest();
        insert mt;
        Test.stopTest();

        assertLinkedToAllOppsAndMatters(mt.Id, accountId);
    }

    @isTest
    static void testUnlinkedTranscriptCreatesNoJunctions() {
        Meeting_Transcript__c mt = new Meeting_Transcript__c(Transcript__c = 'Hello', Zoom_Meeting_Id__c = 'queue-test');

        Test.startTest();
        insert mt;
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Related_Meeting_Transcript__c WHERE Meeting_Transcript__c = :mt.Id]);
    }
}
