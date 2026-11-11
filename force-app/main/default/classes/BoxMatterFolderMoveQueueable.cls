/// Micah Johnson - Demand Chain 2026
/// Moves Matter Box folders to the folder their status calls for and verifies each one through
/// BoxMatterFolderService. Two callers:
///  - Box_update_Metadata_Matter_Flow, through the invocable below. Any folder that doesn't land
///    is posted to the system health Slack channel right away.
///  - BoxMatterFolderReconciler, which passes its run summary along; the last job in the chain
///    posts that summary instead of individual alerts.
///
/// Status and folder ID are re-read when each job runs instead of being taken from the flow, so
/// two quick status changes (like the 10/21/2026 Completed -> Active toggle) can't land out of order.
///
/// Up to 8 folders per job: Apex allows 120 seconds of total callout time per transaction, and each
/// folder takes up to three Box calls (read, move, read back). A job stops early and hands the rest
/// on when another folder might not fit in what's left of that time.
///
/// A move Box doesn't answer in time (UNCONFIRMED) isn't reported yet. Once the chain is through,
/// those matters get one delayed recheck: a folder that landed in the meantime counts as moved,
/// and one still out of place is moved again and reported if that fails too.
public without sharing class BoxMatterFolderMoveQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible
    private static Integer foldersPerJob = 8;
    /// Time for Box to finish a large move it didn't answer. Apex allows 10 minutes at most.
    @TestVisible
    private static final Integer RECHECK_DELAY_MINUTES = 5;

    // Tests can't chain queueables, so jobs are parked here for the test to run directly.
    @TestVisible
    private static BoxMatterFolderMoveQueueable queuedForTest;
    @TestVisible
    private static Integer queuedDelayForTest;

    private List<Id> matterIds;
    private BoxMatterFolderReconciler.RunSummary summary;
    private Boolean isRecheck = false;
    // Unanswered moves waiting for the recheck, carried along until the chain's last job.
    private List<Id> unconfirmed = new List<Id>();

    public BoxMatterFolderMoveQueueable(List<Id> matterIds, BoxMatterFolderReconciler.RunSummary summary) {
        this.matterIds = matterIds;
        this.summary = summary;
    }

    private BoxMatterFolderMoveQueueable(List<Id> matterIds, BoxMatterFolderReconciler.RunSummary summary, Boolean isRecheck, List<Id> unconfirmed) {
        this(matterIds, summary);
        this.isRecheck = isRecheck;
        this.unconfirmed = unconfirmed;
    }

    public class Request {
        @InvocableVariable(label='Matter Id' description='Matter (AcctSeed__Project__c) whose Box folder should be moved to match its status' required=true)
        public Id matterId;
    }

    @InvocableMethod(label='Move Matter Box Folder (Verified)' description='Queues a move of each Matter\'s Box folder to Matters (Active) or Matters (Completed), reads the folder back from Box to confirm it landed, and posts any failure to the system health Slack channel.')
    public static void moveFromFlow(List<Request> requests) {
        List<Id> ids = new List<Id>();
        for (Request request : requests) {
            if (request.matterId != null) {
                ids.add(request.matterId);
            }
        }
        if (ids.isEmpty()) {
            return;
        }
        // If this transaction can't queue another job, leave the folder to the nightly reconciler
        // rather than fail the flow interview.
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            System.debug(LoggingLevel.WARN, 'BoxMatterFolderMoveQueueable: queueable limit reached, ' + ids.size() + ' folder move(s) left to the nightly reconciler');
            return;
        }
        enqueue(new BoxMatterFolderMoveQueueable(ids, null));
    }

    public static void enqueue(BoxMatterFolderMoveQueueable job) {
        enqueue(job, 0);
    }

    private static void enqueue(BoxMatterFolderMoveQueueable job, Integer delayMinutes) {
        if (Test.isRunningTest()) {
            queuedForTest = job;
            queuedDelayForTest = delayMinutes;
            return;
        }
        System.enqueueJob(job, delayMinutes);
    }

    public void execute(QueueableContext context) {
        List<Id> thisJob = new List<Id>();
        List<Id> remaining = new List<Id>();
        for (Id matterId : matterIds) {
            if (thisJob.size() < foldersPerJob) {
                thisJob.add(matterId);
            } else {
                remaining.add(matterId);
            }
        }

        BoxMatterFolderService service = new BoxMatterFolderService();
        List<BoxMatterFolderService.MoveResult> failures = new List<BoxMatterFolderService.MoveResult>();
        try {
            Integer attempted = 0;
            for (AcctSeed__Project__c matter : BoxMatterFolderService.matters().byIds(thisJob)) {
                // The first folder always runs so the chain can't stall.
                if (attempted > 0 && !service.hasTimeForAnotherMove()) {
                    remaining.add(matter.Id);
                    continue;
                }
                attempted++;
                BoxMatterFolderService.MoveResult result = settle(service.moveAndVerify(matter));
                if (result.outcome == BoxMatterFolderService.Outcome.UNCONFIRMED) {
                    unconfirmed.add(result.matterId);
                } else if (summary != null) {
                    summary.record(result);
                } else if (result.outcome == BoxMatterFolderService.Outcome.FAILED) {
                    failures.add(result);
                }
            }

            if (!failures.isEmpty()) {
                SystemHealthSlack.post(failureAlert(failures));
            }
            if (summary != null && remaining.isEmpty() && unconfirmed.isEmpty()) {
                SystemHealthSlack.post(summary.format());
            }
        } catch (Exception e) {
            // moveAndVerify already turns Box errors into FAILED results, so this is something
            // unexpected. Say so instead of letting the chain (and the daily summary) stop silently.
            remaining.clear();
            unconfirmed.clear();
            if (summary != null) {
                summary.fatalError = e.getMessage();
                SystemHealthSlack.post(summary.format());
            } else {
                SystemHealthSlack.post(':warning: Box folder move job stopped before finishing: ' + SystemHealthSlack.escape(e.getMessage())
                    + '\nThe nightly folder check will pick up anything it missed.');
            }
        } finally {
            service.commitChanges();
        }

        // A queueable can only queue one job, so unconfirmed moves ride along until nothing remains.
        if (!remaining.isEmpty()) {
            enqueue(new BoxMatterFolderMoveQueueable(remaining, summary, isRecheck, unconfirmed), 0);
        } else if (!unconfirmed.isEmpty()) {
            enqueue(new BoxMatterFolderMoveQueueable(unconfirmed, summary, true, new List<Id>()), RECHECK_DELAY_MINUTES);
        }
    }

    /// On the recheck, a folder already in place means the first move landed after all, and a
    /// second unanswered move is a failure.
    private BoxMatterFolderService.MoveResult settle(BoxMatterFolderService.MoveResult result) {
        if (!isRecheck) {
            return result;
        }
        if (result.outcome == BoxMatterFolderService.Outcome.ALREADY_IN_PLACE) {
            result.outcome = BoxMatterFolderService.Outcome.MOVED;
        } else if (result.outcome == BoxMatterFolderService.Outcome.UNCONFIRMED) {
            result.outcome = BoxMatterFolderService.Outcome.FAILED;
            result.error += ' (tried twice, ' + RECHECK_DELAY_MINUTES + ' minutes apart)';
        }
        return result;
    }

    public static String describe(BoxMatterFolderService.MoveResult result) {
        String line = '• ' + SystemHealthSlack.escape(result.matterName) + ' (' + SystemHealthSlack.recordLink(result.matterId)
            + ') · folder ' + SystemHealthSlack.boxFolderLink(result.folderId) + ' · ';
        String target = BoxMatterFolderService.folderLabel(result.targetFolderId);
        if (result.outcome == BoxMatterFolderService.Outcome.MOVED) {
            return line + 'moved to ' + target;
        }
        if (result.outcome == BoxMatterFolderService.Outcome.WOULD_MOVE) {
            return line + 'in ' + SystemHealthSlack.escape(result.finalParentName) + ', would move to ' + target;
        }
        String location = result.finalParentName == null ? 'location unknown' : 'still in ' + SystemHealthSlack.escape(result.finalParentName);
        return line + 'should be in ' + target + ', ' + location + ' · Box: ' + SystemHealthSlack.escape(result.error);
    }

    private static String failureAlert(List<BoxMatterFolderService.MoveResult> failures) {
        List<String> lines = new List<String>{
            ':warning: Box folder move failed for ' + failures.size() + (failures.size() == 1 ? ' matter' : ' matters')
                + '. The nightly folder check will try again.'
        };
        for (BoxMatterFolderService.MoveResult result : failures) {
            lines.add(describe(result));
        }
        return String.join(lines, '\n');
    }
}
