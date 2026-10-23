@isTest
private class EventTriggerHandlerTest {

    private static User makeUser(String profileName, String alias) {
        Profile prof = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        return new User(
            FirstName = alias,
            LastName = 'EventMatchTest',
            Alias = alias,
            Email = alias + '.ethtest@example.com',
            Username = alias + '.ethtest@example.com.' + UserInfo.getOrganizationId(),
            ProfileId = prof.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    @isTest
    static void testFilterKeepsOnlyAttorneyOwnedEvents() {
        User attorney = makeUser(EventTriggerHandler.ATTORNEY_PROFILE, 'atty');
        User inactiveAttorney = makeUser(EventTriggerHandler.ATTORNEY_PROFILE, 'oldatty');
        inactiveAttorney.IsActive = false;
        User staff = makeUser('Standard User', 'staff');
        User permSetUser = makeUser('Standard User', 'psuser');

        // Users and permission set assignments are setup objects; insert them as the running user
        // so they stay isolated from any non-setup DML in the test.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ attorney, inactiveAttorney, staff, permSetUser };
            PermissionSet matchingPermSet = [
                SELECT Id
                FROM PermissionSet
                WHERE Name = :EventTriggerHandler.MATCHING_PERMISSION_SET
                LIMIT 1
            ];
            insert new PermissionSetAssignment(AssigneeId = permSetUser.Id, PermissionSetId = matchingPermSet.Id);
        }

        List<Event> events = new List<Event>{
            new Event(OwnerId = attorney.Id, Subject = 'Attorney Event'),
            new Event(OwnerId = inactiveAttorney.Id, Subject = 'Inactive Attorney Event'),
            new Event(OwnerId = staff.Id, Subject = 'Staff Event'),
            new Event(OwnerId = permSetUser.Id, Subject = 'Permission Set Event')
        };

        Test.startTest();
        List<Event> attorneyEvents = EventTriggerHandler.filterToAttorneyOwnedEvents(events);
        Test.stopTest();

        Set<String> keptSubjects = new Set<String>();
        for (Event evt : attorneyEvents) {
            keptSubjects.add(evt.Subject);
        }
        Assert.areEqual(new Set<String>{ 'Attorney Event', 'Permission Set Event' }, keptSubjects,
            'Only Events owned by an active Attorney-profile user or a permission set holder should be kept.');
    }

    @isTest
    static void testFilterEmptyList() {
        Test.startTest();
        List<Event> attorneyEvents = EventTriggerHandler.filterToAttorneyOwnedEvents(new List<Event>());
        Test.stopTest();

        Assert.isTrue(attorneyEvents.isEmpty(), 'An empty list should pass through without querying.');
    }

    @isTest
    static void testInsertAttorneyAndStaffEvents() {
        User attorney = makeUser(EventTriggerHandler.ATTORNEY_PROFILE, 'atty');
        User staff = makeUser('Standard User', 'staff');
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ attorney, staff };
        }

        Test.startTest();
        insert new List<Event>{
            new Event(OwnerId = attorney.Id, Subject = 'Jane TestUser', StartDateTime = System.now(), EndDateTime = System.now().addHours(1)),
            new Event(OwnerId = staff.Id, Subject = 'Jane TestUser', StartDateTime = System.now(), EndDateTime = System.now().addHours(1))
        };
        Test.stopTest();

        // The Agentforce prompt callout cannot succeed in a unit test, so the attorney's Event is evaluated
        // but finds no matches; the staff Event is skipped before matching. Neither should be flagged.
        for (Event evt : [SELECT Has_Potential_Account_Matches__c FROM Event WHERE Subject = 'Jane TestUser']) {
            Assert.isFalse(evt.Has_Potential_Account_Matches__c, 'No Event should be flagged in a test context.');
        }
    }
}
