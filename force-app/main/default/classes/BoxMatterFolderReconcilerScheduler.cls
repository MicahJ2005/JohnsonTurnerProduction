/// Micah Johnson - Demand Chain 2026
/// Runs BoxMatterFolderReconciler every morning. Scheduled Apex can't make callouts, so this only
/// queues the reconciler, which does the Box work.
///
/// To register the schedule, run once in anonymous Apex:
///   BoxMatterFolderReconcilerScheduler.schedule();
public without sharing class BoxMatterFolderReconcilerScheduler implements Schedulable {

    public static final String JOB_NAME = 'Box Matter Folder Reconciler';
    // 5:30 AM in the scheduling user's time zone: after the 3 AM ProjectUpdate job, before staff start.
    public static final String CRON = '0 30 5 * * ?';

    // Tests see the org's real schedule, so they register under another name.
    @TestVisible
    private static String jobName = JOB_NAME;

    public static Id schedule() {
        return System.schedule(jobName, CRON, new BoxMatterFolderReconcilerScheduler());
    }

    public void execute(SchedulableContext context) {
        System.enqueueJob(new BoxMatterFolderReconciler());
    }
}
