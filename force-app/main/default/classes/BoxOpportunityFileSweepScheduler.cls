/// Micah Johnson - Demand Chain 2026
/// Runs BoxOpportunityFileMoveQueueable.sweep every morning over the last 30 days of conversions,
/// which moves files that reached an Opportunity's Box folder after its Matter was created. Scheduled
/// Apex can't make callouts, so this only queues the sweep, which does the Box work.
///
/// To register the schedule, run once in anonymous Apex:
///   BoxOpportunityFileSweepScheduler.schedule();
public without sharing class BoxOpportunityFileSweepScheduler implements Schedulable {

    public static final String JOB_NAME = 'Box Opportunity File Sweep';
    // 6:15 AM in the scheduling user's time zone: clear of the 5:30 AM Box folder check (both use the
    // same Box login), before staff start.
    public static final String CRON = '0 15 6 * * ?';
    public static final Integer LOOKBACK_DAYS = 30;

    // Tests see the org's real schedule, so they register under another name.
    @TestVisible
    private static String jobName = JOB_NAME;

    public static Id schedule() {
        return System.schedule(jobName, CRON, new BoxOpportunityFileSweepScheduler());
    }

    public void execute(SchedulableContext context) {
        BoxOpportunityFileMoveQueueable.sweep(Datetime.now().addDays(-LOOKBACK_DAYS));
    }
}
