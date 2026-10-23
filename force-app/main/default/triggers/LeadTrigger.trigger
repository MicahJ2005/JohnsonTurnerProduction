trigger LeadTrigger on Lead (after insert, after update) {
    if (Trigger.isAfter && Trigger.isInsert) {
        CommunicationBacklinkService.handleLeadAfterInsert(Trigger.new);
    }
    if (Trigger.isAfter && Trigger.isUpdate) {
        LeadTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
        CommunicationBacklinkService.handleLeadAfterUpdate(Trigger.new, Trigger.oldMap);
    }
}