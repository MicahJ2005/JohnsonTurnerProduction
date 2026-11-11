/// Micah Johnson - Demand Chain 2026
/// Runs ZoomPhoneCallReconciler every morning. Scheduled Apex can't make callouts, so this only
/// queues the reconciler, which reads Zoom.
///
/// To register the schedule, run once in anonymous Apex:
///   ZoomPhoneCallReconcilerScheduler.schedule();
public without sharing class ZoomPhoneCallReconcilerScheduler implements Schedulable {

    public static final String JOB_NAME = 'Zoom Phone Call Repair';
    // 5:10 AM in the scheduling user's time zone: the calls it queues go through the 5:30 and 6:00
    // Zoom retry passes and are done before the 7:15 Zoom Ingestion Digest checks them.
    public static final String CRON = '0 10 5 * * ?';

    // Tests see the org's real schedule, so they register under another name.
    @TestVisible
    private static String jobName = JOB_NAME;

    public static Id schedule() {
        return System.schedule(jobName, CRON, new ZoomPhoneCallReconcilerScheduler());
    }

    public void execute(SchedulableContext context) {
        System.enqueueJob(new ZoomPhoneCallReconciler());
    }
}
