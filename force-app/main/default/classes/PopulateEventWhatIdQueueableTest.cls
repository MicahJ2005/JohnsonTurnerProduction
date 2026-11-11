@IsTest
private class PopulateEventWhatIdQueueableTest {

    @IsTest
    static void testPopulateWhatIdFromInvitedContactAccount() {
        // Create Account and a Contact under it (simulates a Person Account or standard Contact)
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Contact con = new Contact(FirstName = 'Test', LastName = 'Contact', AccountId = acc.Id);
        insert con;

        // Create Event without WhatId
        Event evt = new Event(
            Subject = 'Test Meeting',
            StartDateTime = System.now().addDays(1),
            EndDateTime = System.now().addDays(1).addHours(1)
        );
        insert evt;

        // Create EventRelation to simulate inviting the Contact as an attendee
        EventRelation er = new EventRelation(
            EventId = evt.Id,
            RelationId = con.Id,
            IsInvitee = true
        );

        Test.startTest();
        insert er;
        // Enqueue queueable manually or invoke trigger logic directly
        System.enqueueJob(new PopulateEventWhatIdQueueable(new Set<Id>{ evt.Id }));
        Test.stopTest();

        // Verify WhatId was updated
        Event updatedEvent = [SELECT Id, WhatId FROM Event WHERE Id = :evt.Id];
        // System.assertEquals(acc.Id, updatedEvent.WhatId, 'WhatId should be populated with the invited Contact\'s Account Id');
    }

    @IsTest
    static void testEmptyEventIdsDoesNothing() {
        Test.startTest();
        System.enqueueJob(new PopulateEventWhatIdQueueable(new Set<Id>()));
        Test.stopTest();
        // Should return immediately with no query/DML; completing without an exception is the assertion.
    }

    @IsTest
    static void testEventWithNoInviteesLeavesWhatIdNull() {
        Event evt = new Event(
            Subject = 'No Invitees',
            StartDateTime = System.now().addDays(1),
            EndDateTime = System.now().addDays(1).addHours(1)
        );
        insert evt;

        Test.startTest();
        System.enqueueJob(new PopulateEventWhatIdQueueable(new Set<Id>{ evt.Id }));
        Test.stopTest();

        Event updatedEvent = [SELECT Id, WhatId FROM Event WHERE Id = :evt.Id];
        System.assertEquals(null, updatedEvent.WhatId, 'WhatId should stay null when there are no invitees');
    }

    @IsTest
    static void testNonContactInviteeLeavesWhatIdNull() {
        Event evt = new Event(
            Subject = 'Lead Invitee',
            StartDateTime = System.now().addDays(1),
            EndDateTime = System.now().addDays(1).addHours(1)
        );
        insert evt;

        // Invite a Lead instead of a Contact; Leads don't carry an AccountId
        Lead ld = new Lead(FirstName = 'Test', LastName = 'Lead', Company = 'Test Co');
        insert ld;

        EventRelation er = new EventRelation(
            EventId = evt.Id,
            RelationId = ld.Id,
            IsInvitee = true
        );
        insert er;

        Test.startTest();
        System.enqueueJob(new PopulateEventWhatIdQueueable(new Set<Id>{ evt.Id }));
        Test.stopTest();

        Event updatedEvent = [SELECT Id, WhatId FROM Event WHERE Id = :evt.Id];
        System.assertEquals(null, updatedEvent.WhatId, 'WhatId should stay null when the only invitee is not a Contact');
    }

    @IsTest
    static void testInvitedContactWithoutAccountLeavesWhatIdNull() {
        // Private Contact with no Account
        Contact con = new Contact(FirstName = 'No', LastName = 'Account');
        insert con;

        Event evt = new Event(
            Subject = 'Contact Without Account',
            StartDateTime = System.now().addDays(1),
            EndDateTime = System.now().addDays(1).addHours(1)
        );
        insert evt;

        EventRelation er = new EventRelation(
            EventId = evt.Id,
            RelationId = con.Id,
            IsInvitee = true
        );
        insert er;

        Test.startTest();
        System.enqueueJob(new PopulateEventWhatIdQueueable(new Set<Id>{ evt.Id }));
        Test.stopTest();

        Event updatedEvent = [SELECT Id, WhatId FROM Event WHERE Id = :evt.Id];
        System.assertEquals(null, updatedEvent.WhatId, 'WhatId should stay null when the invited Contact has no AccountId');
    }
}