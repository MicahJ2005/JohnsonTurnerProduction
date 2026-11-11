/// Covers the Event_Relationship_Link record-triggered flow, which creates Related_Event__c rows
/// linking an Event to its account and every Opportunity and Matter on that account.
@isTest
private class EventRelationshipLinkFlowTest {

    @testSetup
    static void setup() {
        AyTestDataSuite.init();

        AcctSeed__Project__c matter = new AcctSeed__Project__c();
        matter.Name = 'Event Link Test Matter';
        matter.AcctSeed__Account__c = AyTestDataSuite.accounts[0].Id;
        matter.AcctSeed__Opportunity__c = AyTestDataSuite.Opportunities[0].Id;
        matter.AcctSeed__Status__c = 'Active';
        insert matter;
    }

    private static Contact getContact() {
        return [SELECT Id, AccountId FROM Contact WHERE LastName = 'Test Contact LastName' LIMIT 1];
    }

    private static Event newEvent(String subject) {
        return new Event(
            Subject = subject,
            StartDateTime = Datetime.now().addDays(1),
            EndDateTime = Datetime.now().addDays(1).addHours(1)
        );
    }

    private static List<Related_Event__c> linksFor(Id eventId) {
        return [
            SELECT Account__c, Opportunity__c, Matter__c, Lead__c, Event_Subject__c, Event_Start_Date_Time__c
            FROM Related_Event__c
            WHERE Event_Id__c = :eventId
        ];
    }

    // Asserts one Account link plus one link per Opportunity and per Matter on the account - the
    // set of Opps/Matters is read back rather than hardcoded, since other automation may add more.
    private static void assertLinkedToAccountAndAllItsWork(Id eventId, Id accountId) {
        Set<Id> expectedOpps = new Map<Id, Opportunity>([SELECT Id FROM Opportunity WHERE AccountId = :accountId]).keySet();
        Set<Id> expectedMatters = new Map<Id, AcctSeed__Project__c>(
            [SELECT Id FROM AcctSeed__Project__c WHERE AcctSeed__Account__c = :accountId]).keySet();
        System.assert(!expectedOpps.isEmpty() && !expectedMatters.isEmpty(), 'Test account should have an Opportunity and a Matter');

        Integer accountLinks = 0;
        Set<Id> linkedOpps = new Set<Id>();
        Set<Id> linkedMatters = new Set<Id>();
        for (Related_Event__c link : linksFor(eventId)) {
            if (link.Account__c != null) {
                System.assertEquals(accountId, link.Account__c);
                accountLinks++;
            }
            if (link.Opportunity__c != null) linkedOpps.add(link.Opportunity__c);
            if (link.Matter__c != null) linkedMatters.add(link.Matter__c);
        }
        System.assertEquals(1, accountLinks, 'Expected exactly one Account link');
        System.assertEquals(expectedOpps, linkedOpps, 'Every Opportunity on the account should be linked');
        System.assertEquals(expectedMatters, linkedMatters, 'Every Matter on the account should be linked');
    }

    @isTest
    static void testContactOnlyEventLinksThroughContactsAccount() {
        Contact con = getContact();
        Event evt = newEvent('Case Commencement Call - Zoom');
        evt.WhoId = con.Id;

        Test.startTest();
        insert evt;
        Test.stopTest();

        assertLinkedToAccountAndAllItsWork(evt.Id, con.AccountId);
        System.assertEquals('Case Commencement Call - Zoom', linksFor(evt.Id)[0].Event_Subject__c);
    }

    @isTest
    static void testContactAddedToEventWithNoWhoOrWhatLinks() {
        Contact con = getContact();
        Event evt = newEvent('Added Contact Later');
        insert evt;
        System.assertEquals(0, linksFor(evt.Id).size(), 'An Event with no Name or Related To should not be linked');

        Test.startTest();
        update new Event(Id = evt.Id, WhoId = con.Id);
        Test.stopTest();

        assertLinkedToAccountAndAllItsWork(evt.Id, con.AccountId);
    }

    @isTest
    static void testRescheduledContactOnlyEventUpdatesLinksWithoutDuplicating() {
        Contact con = getContact();
        Event evt = newEvent('Reschedule Me');
        evt.WhoId = con.Id;
        insert evt;
        Integer linkCount = linksFor(evt.Id).size();
        System.assert(linkCount > 0, 'The Contact-only Event should have been linked on insert');

        Datetime newStart = Datetime.now().addDays(3);
        Test.startTest();
        update new Event(Id = evt.Id, StartDateTime = newStart, EndDateTime = newStart.addHours(1));
        Test.stopTest();

        List<Related_Event__c> links = linksFor(evt.Id);
        System.assertEquals(linkCount, links.size(), 'Rescheduling should update existing links, not add more');
        for (Related_Event__c link : links) {
            System.assertEquals(newStart, link.Event_Start_Date_Time__c);
        }
    }

    @isTest
    static void testRelatedToAccountStillLinks() {
        Id accountId = getContact().AccountId;
        Event evt = newEvent('Related To Account');
        evt.WhatId = accountId;

        Test.startTest();
        insert evt;
        Test.stopTest();

        assertLinkedToAccountAndAllItsWork(evt.Id, accountId);
    }

    @isTest
    static void testContactWithRelatedToOpportunityIsNotDoubleLinked() {
        // Related To takes precedence - the Opportunity path should run once, not also the Contact path.
        Contact con = getContact();
        Opportunity opp = [SELECT Id FROM Opportunity WHERE AccountId = :con.AccountId LIMIT 1];
        Event evt = newEvent('Contact And Opportunity');
        evt.WhoId = con.Id;
        evt.WhatId = opp.Id;

        Test.startTest();
        insert evt;
        Test.stopTest();

        assertLinkedToAccountAndAllItsWork(evt.Id, con.AccountId);
    }
}
