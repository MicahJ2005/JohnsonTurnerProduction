/// Micah Johnson - Demand Chain 2026
/// Nightly check that every Active Matter's Box folder is in "Matters" and every Completed Matter's
/// is in "Matters (Completed)". Misplaced folders go to BoxMatterFolderMoveQueueable to be moved and
/// verified. A summary is posted to the system health Slack channel on every run, including runs
/// that find nothing, so a missing post means the job didn't run - never that all is well.
///
/// Other statuses are ignored: On hold or Pending Close matters can sit in Matters (Completed) on purpose.
///
/// Schedule:  BoxMatterFolderReconcilerScheduler.schedule();
/// Run now:   System.enqueueJob(new BoxMatterFolderReconciler());
public without sharing class BoxMatterFolderReconciler implements Queueable, Database.AllowsCallouts {

    /// More misplaced folders than this in one night points to a bad read or a bulk status change
    /// rather than drift, so the run posts the list and moves nothing until someone has looked.
    @TestVisible
    private static final Integer DEFAULT_MAX_MOVES = 50;
    private static final Integer MAX_LINES = 25;

    private Integer maxMoves;

    public BoxMatterFolderReconciler() {
        this(DEFAULT_MAX_MOVES);
    }

    /// Pass a higher cap to clear a held run after checking its list.
    public BoxMatterFolderReconciler(Integer maxMoves) {
        this.maxMoves = maxMoves;
    }

    public void execute(QueueableContext context) {
        RunSummary summary = new RunSummary();
        BoxMatterFolderService service = new BoxMatterFolderService();
        List<Id> toMove = new List<Id>();
        try {
            Set<String> inMatters = service.listChildFolderIds(BoxMatterFolderService.MATTERS_FOLDER_ID);
            Set<String> inCompleted = service.listChildFolderIds(BoxMatterFolderService.COMPLETED_FOLDER_ID);
            summary.foldersInMatters = inMatters.size();
            summary.foldersInCompleted = inCompleted.size();

            toMove = findMisplaced(inMatters, inCompleted, summary);
            if (toMove.size() > maxMoves) {
                summary.holdReason = toMove.size() + ' misplaced folders is more than the ' + maxMoves
                    + ' this job moves on its own, so nothing was moved. After checking the list, run '
                    + '`System.enqueueJob(new BoxMatterFolderReconciler(' + toMove.size() + '));`';
                toMove.clear();
            }
            if (toMove.isEmpty()) {
                SystemHealthSlack.post(summary.format());
            }
        } catch (Exception e) {
            toMove.clear();
            summary.fatalError = e.getMessage();
            SystemHealthSlack.post(summary.format());
        } finally {
            service.commitChanges();
        }

        if (!toMove.isEmpty()) {
            BoxMatterFolderMoveQueueable.enqueue(new BoxMatterFolderMoveQueueable(toMove, summary));
        }
    }

    private static List<Id> findMisplaced(Set<String> inMatters, Set<String> inCompleted, RunSummary summary) {
        BoxMatterFolderService.MatterSource matters = BoxMatterFolderService.matters();

        // Completed matters are looked up by the folder IDs found in Matters; Active matters are
        // few enough to read and check against the Completed listing in memory.
        List<AcctSeed__Project__c> candidates = matters.completedInFolders(inMatters);
        for (AcctSeed__Project__c matter : matters.activeWithFolders()) {
            summary.activeChecked++;
            if (inCompleted.contains(matter.Box_Matter_Folder_ID__c)) {
                candidates.add(matter);
            }
        }
        summary.completedChecked = matters.countCompletedWithFolders();

        // A folder linked to more than one matter can't follow both statuses; moving it would just
        // flip it back and forth night after night.
        Set<String> candidateFolders = new Set<String>();
        for (AcctSeed__Project__c matter : candidates) {
            candidateFolders.add(matter.Box_Matter_Folder_ID__c);
        }
        Set<String> sharedFolders = matters.sharedFolders(candidateFolders);

        List<Id> toMove = new List<Id>();
        for (AcctSeed__Project__c matter : candidates) {
            String target = BoxMatterFolderService.targetFolderFor(matter.AcctSeed__Status__c);
            String current = target == BoxMatterFolderService.MATTERS_FOLDER_ID
                ? BoxMatterFolderService.COMPLETED_FOLDER_ID
                : BoxMatterFolderService.MATTERS_FOLDER_ID;
            String line = '• ' + SystemHealthSlack.escape(matter.Name) + ' (' + SystemHealthSlack.recordLink(matter.Id)
                + ') · folder ' + SystemHealthSlack.boxFolderLink(matter.Box_Matter_Folder_ID__c)
                + ' · ' + matter.AcctSeed__Status__c + ', in ' + BoxMatterFolderService.folderLabel(current);
            if (sharedFolders.contains(matter.Box_Matter_Folder_ID__c)) {
                summary.skippedShared.add(line + ' · folder is shared with another matter');
            } else {
                summary.misplaced.add(line);
                toMove.add(matter.Id);
            }
        }
        return toMove;
    }

    /// Carried through the move chain and posted by its last job.
    public class RunSummary {
        public Integer activeChecked = 0;
        public Integer completedChecked = 0;
        public Integer foldersInMatters = 0;
        public Integer foldersInCompleted = 0;
        public List<String> misplaced = new List<String>();
        public List<String> skippedShared = new List<String>();
        public List<String> moved = new List<String>();
        public List<String> wouldMove = new List<String>();
        public List<String> failed = new List<String>();
        public Integer alreadyFixed = 0;
        public Integer statusChanged = 0;
        public String holdReason;
        public String fatalError;
        public Boolean reportOnly = BoxMatterFolderService.isReportOnly();

        public void record(BoxMatterFolderService.MoveResult result) {
            switch on result.outcome {
                when MOVED {
                    moved.add(BoxMatterFolderMoveQueueable.describe(result));
                }
                when WOULD_MOVE {
                    wouldMove.add(BoxMatterFolderMoveQueueable.describe(result));
                }
                when FAILED {
                    failed.add(BoxMatterFolderMoveQueueable.describe(result));
                }
                when ALREADY_IN_PLACE {
                    alreadyFixed++;
                }
                when NOT_APPLICABLE {
                    statusChanged++;
                }
            }
        }

        public String format() {
            String title = 'Box folder check, ' + Datetime.now().format('EEE M/d')
                + (reportOnly ? ' (sandbox: report only, nothing moved)' : '');
            String scope = 'Checked ' + activeChecked.format() + ' Active and ' + completedChecked.format()
                + ' Completed matters against ' + foldersInMatters.format() + ' folders in Matters and '
                + foldersInCompleted.format() + ' in Matters (Completed).';

            if (fatalError != null) {
                return ':rotating_light: ' + title + ' did not finish, so folders were not fully checked.\n'
                    + SystemHealthSlack.escape(fatalError)
                    + section('Failed before it stopped', failed)
                    + section('Moved before it stopped', moved);
            }
            if (holdReason != null) {
                return ':warning: ' + title + ': ' + holdReason + '\n' + scope + section('Misplaced', misplaced);
            }
            if (misplaced.isEmpty() && skippedShared.isEmpty()) {
                return ':white_check_mark: ' + title + ': every Active and Completed matter folder is in the right place.\n' + scope;
            }

            List<String> counts = new List<String>{ misplaced.size() + ' misplaced' };
            if (!moved.isEmpty()) {
                counts.add(moved.size() + ' moved');
            }
            if (!wouldMove.isEmpty()) {
                counts.add(wouldMove.size() + ' would move');
            }
            if (!failed.isEmpty()) {
                counts.add(failed.size() + ' failed');
            }
            if (alreadyFixed > 0) {
                counts.add(alreadyFixed + ' already fixed by the time the job ran');
            }
            if (statusChanged > 0) {
                counts.add(statusChanged + ' skipped because the status changed');
            }
            if (!skippedShared.isEmpty()) {
                counts.add(skippedShared.size() + ' skipped (shared folder)');
            }
            Boolean clean = failed.isEmpty() && skippedShared.isEmpty() && wouldMove.isEmpty();
            return (clean ? ':white_check_mark: ' : ':warning: ') + title + ': ' + String.join(counts, ', ') + '.\n' + scope
                + section('Failed', failed)
                + section('Moved', moved)
                + section('Would move', wouldMove)
                + section('Skipped', skippedShared);
        }

        private String section(String heading, List<String> lines) {
            if (lines.isEmpty()) {
                return '';
            }
            List<String> shown = new List<String>();
            for (Integer i = 0; i < lines.size() && i < MAX_LINES; i++) {
                shown.add(lines[i]);
            }
            if (lines.size() > MAX_LINES) {
                shown.add('…and ' + (lines.size() - MAX_LINES) + ' more');
            }
            return '\n*' + heading + '*\n' + String.join(shown, '\n');
        }
    }
}
