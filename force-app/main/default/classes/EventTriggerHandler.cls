public class EventTriggerHandler {
    // Only Events on an attorney's calendar are evaluated for potential Account matches. Attorneys are
    // identified by profile so the filter follows staffing changes without a maintained list of names;
    // the permission set covers anyone who should be included but is on another profile (e.g., an
    // attorney who is also a System Administrator).
    @TestVisible private static final String ATTORNEY_PROFILE = 'Attorney';
    @TestVisible private static final String MATCHING_PERMISSION_SET = 'Event_Account_Matching';

    public static void handleAfterInsert(List<Event> newEvents) {
        Set<Id> eventIdsToProcess = new Set<Id>();

        for (Event evt : newEvents) {
            // Existing behavior: attempt to populate WhatId for invite-based Event records.
            if (evt.WhatId == null && evt.WhoId == null) {
                eventIdsToProcess.add(evt.Id);
            }
        }

        if (!eventIdsToProcess.isEmpty()) {
            System.enqueueJob(new PopulateEventWhatIdQueueable(eventIdsToProcess));
        }

        // New behavior: if the Event is not already related to an Account/Lead, see whether
        // the subject is likely to match a Person Account or Lead and set the checkbox.
        List<Event> eventsToEvaluate = new List<Event>();
        for (Event evt : newEvents) {
            if (evt.WhatId == null && evt.WhoId == null && String.isNotBlank(evt.Subject)) {
                eventsToEvaluate.add(evt);
            }
        }
        eventsToEvaluate = filterToAttorneyOwnedEvents(eventsToEvaluate);

        if (!eventsToEvaluate.isEmpty()) {
            List<Event> eventsToUpdate = new List<Event>();
            for (Event evt : eventsToEvaluate) {
                List<EventAccountMatchController.AccountMatchWrapper> matches =
                    EventAccountMatchController.getPotentialMatches(evt.Id);

                eventsToUpdate.add(new Event(
                    Id = evt.Id,
                    Has_Potential_Account_Matches__c = !matches.isEmpty()
                ));
            }

            if (!eventsToUpdate.isEmpty()) {
                update eventsToUpdate;
            }
        }
    }

    // Keeps only Events owned by an active User on the Attorney profile or assigned the Event Account
    // Matching permission set. Events on anyone else's calendar (paralegals, staff, or client portal
    // users who received an invite copy of the meeting) are left unflagged.
    @TestVisible
    private static List<Event> filterToAttorneyOwnedEvents(List<Event> events) {
        if (events.isEmpty()) {
            return events;
        }

        Set<Id> ownerIds = new Set<Id>();
        for (Event evt : events) {
            ownerIds.add(evt.OwnerId);
        }

        Set<Id> attorneyIds = new Set<Id>();
        for (User u : [
            SELECT Id
            FROM User
            WHERE Id IN :ownerIds
              AND IsActive = true
              AND Profile.Name = :ATTORNEY_PROFILE
        ]) {
            attorneyIds.add(u.Id);
        }
        for (PermissionSetAssignment psa : [
            SELECT AssigneeId
            FROM PermissionSetAssignment
            WHERE AssigneeId IN :ownerIds
              AND Assignee.IsActive = true
              AND PermissionSet.Name = :MATCHING_PERMISSION_SET
        ]) {
            attorneyIds.add(psa.AssigneeId);
        }

        List<Event> attorneyEvents = new List<Event>();
        for (Event evt : events) {
            if (attorneyIds.contains(evt.OwnerId)) {
                attorneyEvents.add(evt);
            }
        }
        return attorneyEvents;
    }
}