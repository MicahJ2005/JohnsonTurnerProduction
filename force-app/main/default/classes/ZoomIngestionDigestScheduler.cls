/// Micah Johnson - Demand Chain 2026
/// Runs ZoomIngestionDigest every morning. Scheduled Apex can't make callouts, and the Slack post is
/// one, so this only queues the digest.
///
/// To register the schedule, run once in anonymous Apex:
///   ZoomIngestionDigestScheduler.schedule();
public without sharing class ZoomIngestionDigestScheduler implements Schedulable {

    public static final String JOB_NAME = 'Zoom Ingestion Digest';
    // 7:15 AM in the scheduling user's time zone: after the 5:30 AM Box folder check, before staff
    // start, and clear of the Zoom jobs at :00 and :30.
    public static final String CRON = '0 15 7 * * ?';

    // Tests see the org's real schedule, so they register under another name.
    @TestVisible
    private static String jobName = JOB_NAME;

    public static Id schedule() {
        return System.schedule(jobName, CRON, new ZoomIngestionDigestScheduler());
    }

    public void execute(SchedulableContext context) {
        System.enqueueJob(new ZoomIngestionDigest());
    }
}
