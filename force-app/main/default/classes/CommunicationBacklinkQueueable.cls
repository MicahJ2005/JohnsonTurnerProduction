// Async body of CommunicationBacklinkService, enqueued from the Lead and Opportunity triggers. Works
// through the records a few at a time and chains to the next job for the rest.
public without sharing class CommunicationBacklinkQueueable implements Queueable {

    @TestVisible private static final Integer LEADS_PER_RUN = 50;
    // One Opportunity per run: an Account's existing junctions can number in the tens of thousands
    // (24K email junctions on the largest), so a single heavy Account can use most of a job's query rows.
    @TestVisible private static final Integer OPPORTUNITIES_PER_RUN = 1;

    private List<Id> leadIds;
    private List<Id> opportunityIds;

    public CommunicationBacklinkQueueable(List<Id> leadIds, List<Id> opportunityIds) {
        this.leadIds = leadIds;
        this.opportunityIds = opportunityIds;
    }

    public void execute(QueueableContext ctx) {
        Set<Id> leadBatch = takeFirst(leadIds, LEADS_PER_RUN);
        Set<Id> opportunityBatch = takeFirst(opportunityIds, OPPORTUNITIES_PER_RUN);

        if (!leadBatch.isEmpty()) {
            CommunicationBacklinkService.linkLeads(leadBatch);
        }
        if (!opportunityBatch.isEmpty()) {
            CommunicationBacklinkService.linkOpportunities(opportunityBatch);
        }

        // Apex tests can't chain queueables, so only the first batch runs there.
        if ((!leadIds.isEmpty() || !opportunityIds.isEmpty()) && !Test.isRunningTest()) {
            System.enqueueJob(new CommunicationBacklinkQueueable(leadIds, opportunityIds));
        }
    }

    // Removes and returns up to count Ids from the front of the list.
    private static Set<Id> takeFirst(List<Id> ids, Integer count) {
        Set<Id> taken = new Set<Id>();
        while (!ids.isEmpty() && taken.size() < count) {
            taken.add(ids.remove(0));
        }
        return taken;
    }
}
