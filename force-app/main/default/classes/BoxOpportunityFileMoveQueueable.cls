/// Micah Johnson - Demand Chain 2026
/// Moves a converted Opportunity's Box files into its Matter's folder and verifies each one through
/// BoxMatterFolderService:
///  - loose files at the top of the Opportunity folder go to the Matter's "Client Uploads - New Documents Here"
///  - files in the Opportunity's "Client Account" folder go to the Matter's "Client Account", which is
///    at the top of the Matter folder or inside "Client Portal"
///
/// Replaces BOX_Move_Opportunity_Files_To_Matter's box__MoveFile loops, which sent every failure
/// straight back into the loop: while Box Shield refused these moves (9/7 to about 10/24/2026), 180+
/// conversions left their files in the Opportunity folder without a trace.
///
/// Two callers:
///  - BOX_Move_Opportunity_Files_To_Matter, through the invocable below, a minute after the Matter's
///    Box folder is set. A file that doesn't land, or a Matter folder missing the subfolder a file
///    should go to, is posted to the system health Slack channel.
///  - BoxOpportunityFileSweepScheduler every morning, through sweep(), over recent conversions:
///    files added to the Opportunity folder after the Matter was created (signed agreements often
///    are) get moved then. One summary is posted at the end of the run. A one-off backfill is the
///    same call with an earlier date.
///
/// A matter gets one recheck 5 minutes later, instead of an alert, when a move went unanswered, Box
/// couldn't be read, or a target subfolder doesn't exist yet (BOX_Create_Matter_Folders_and_Sub_Folders
/// builds them at about the same time). The recheck lists the Opportunity folder again and moves
/// whatever is still there; its result is the one reported.
///
/// A job takes another matter only while one more, at its slowest, still fits in the callout time
/// left; files that don't fit carry on to the next job.
public without sharing class BoxOpportunityFileMoveQueueable implements Queueable, Database.AllowsCallouts {

    public static final String UPLOADS_FOLDER = 'Client Uploads - New Documents Here';
    public static final String CLIENT_ACCOUNT_FOLDER = 'Client Account';
    public static final String CLIENT_PORTAL_FOLDER = 'Client Portal';

    /// Time for Box to finish an unanswered move and for the Matter's subfolders to be built.
    @TestVisible
    private static final Integer RECHECK_DELAY_MINUTES = 5;
    /// A matter at its slowest: up to five folder listings, then one file's read, move and read back.
    private static final Integer WORST_CASE_MS_PER_MATTER = 5 * BoxMatterFolderService.READ_TIMEOUT_MS + BoxMatterFolderService.WORST_CASE_MS_PER_FOLDER;
    private static final Integer WORST_CASE_CALLOUTS_PER_MATTER = 8;
    private static final Integer MAX_LINES = 25;

    // Tests can't chain queueables, so jobs are parked here for the test to run directly.
    @TestVisible
    private static BoxOpportunityFileMoveQueueable queuedForTest;
    @TestVisible
    private static Integer queuedDelayForTest;

    @TestVisible
    private static ConversionSource conversions = new ConversionSource();

    private List<Id> matterIds;
    private SweepSummary summary;
    private Boolean isRecheck = false;
    private List<Id> recheckLater = new List<Id>();
    // Set while matterIds[0]'s moves span more than one job.
    private MatterReport report;
    private List<FileMove> pending;
    // Posted at the end of the job, after its last Box call.
    private List<String> alerts = new List<String>();

    public BoxOpportunityFileMoveQueueable(List<Id> matterIds) {
        this(matterIds, null, false, new List<Id>());
    }

    private BoxOpportunityFileMoveQueueable(List<Id> matterIds, SweepSummary summary, Boolean isRecheck, List<Id> recheckLater) {
        this.matterIds = new List<Id>(matterIds);
        this.summary = summary;
        this.isRecheck = isRecheck;
        this.recheckLater = recheckLater;
    }

    public class Request {
        @InvocableVariable(label='Matter Id' description='Matter (AcctSeed__Project__c) converted from an Opportunity whose Box files should move into the Matter folder' required=true)
        public Id matterId;
    }

    @InvocableMethod(label='Move Opportunity Box Files To Matter (Verified)' description='Queues a move of the converted Opportunity\'s Box files into the Matter folder (loose files to Client Uploads, Client Account files to Client Account), reads each file back from Box to confirm it landed, and posts any failure to the system health Slack channel.')
    public static void moveFromFlow(List<Request> requests) {
        List<Id> ids = new List<Id>();
        for (Request request : requests) {
            if (request.matterId != null) {
                ids.add(request.matterId);
            }
        }
        if (!ids.isEmpty()) {
            enqueue(new BoxOpportunityFileMoveQueueable(ids), 0);
        }
    }

    /// Checks every Matter converted from an Opportunity since the given time and moves whatever is
    /// still in its Opportunity folder. Posts one summary once the run, rechecks included, is done.
    public static void sweep(Datetime since) {
        List<Id> ids = conversions.convertedSince(since);
        enqueue(new BoxOpportunityFileMoveQueueable(ids, new SweepSummary(since), false, new List<Id>()), 0);
    }

    private static void enqueue(BoxOpportunityFileMoveQueueable job, Integer delayMinutes) {
        if (Test.isRunningTest()) {
            queuedForTest = job;
            queuedDelayForTest = delayMinutes;
            return;
        }
        System.enqueueJob(job, delayMinutes);
    }

    public void execute(QueueableContext context) {
        BoxMatterFolderService service = new BoxMatterFolderService();
        Boolean stoppedMidMatter = false;
        try {
            Integer started = 0;
            while (!matterIds.isEmpty()) {
                if (report == null) {
                    // The first matter always runs so the chain can't stall.
                    if (started > 0 && !service.hasRoomFor(WORST_CASE_MS_PER_MATTER, WORST_CASE_CALLOUTS_PER_MATTER)) {
                        break;
                    }
                    started++;
                    report = new MatterReport(matterIds[0], conversions.byId(matterIds[0]));
                    pending = plan(service);
                }
                if (!moveFiles(service)) {
                    stoppedMidMatter = true;
                    break;
                }
                finishMatter();
            }
            if (summary != null && matterIds.isEmpty() && recheckLater.isEmpty()) {
                alerts.add(summary.format());
            }
        } catch (Exception e) {
            // Box errors are already problems on the report, so this is something unexpected.
            stoppedMidMatter = false;
            if (summary != null) {
                summary.fatalError = e.getMessage();
                alerts.add(summary.format());
                matterIds.clear();
                recheckLater.clear();
            } else {
                alerts.add(':warning: Moving the Opportunity\'s Box files to Matter ' + SystemHealthSlack.recordLink(matterIds[0])
                    + ' stopped before finishing: ' + SystemHealthSlack.escape(e.getMessage()));
                matterIds.remove(0);
            }
            report = null;
            pending = null;
        } finally {
            for (String alert : alerts) {
                SystemHealthSlack.post(alert);
            }
            service.commitChanges();
        }

        // A queueable can only queue one job, so the rechecks ride along until the last matter.
        if (!matterIds.isEmpty()) {
            BoxOpportunityFileMoveQueueable next = new BoxOpportunityFileMoveQueueable(matterIds, summary, isRecheck, recheckLater);
            if (stoppedMidMatter) {
                next.report = report;
                next.pending = pending;
            }
            enqueue(next, 0);
        } else if (!recheckLater.isEmpty()) {
            enqueue(new BoxOpportunityFileMoveQueueable(recheckLater, summary, true, new List<Id>()), RECHECK_DELAY_MINUTES);
        }
    }

    /// Lists what's in the Opportunity folder and works out where each file goes.
    private List<FileMove> plan(BoxMatterFolderService service) {
        List<FileMove> moves = new List<FileMove>();
        Conversion conversion = report.conversion;
        if (conversion == null || String.isBlank(conversion.opportunityFolderId) || String.isBlank(conversion.matterFolderId)) {
            return moves;
        }
        try {
            List<BoxMatterFolderService.Item> opportunityTop = service.listItems(conversion.opportunityFolderId);
            List<BoxMatterFolderService.Item> looseFiles = filesIn(opportunityTop);
            BoxMatterFolderService.Item opportunityClientAccount = named(opportunityTop, CLIENT_ACCOUNT_FOLDER);
            List<BoxMatterFolderService.Item> clientAccountFiles = opportunityClientAccount == null
                ? new List<BoxMatterFolderService.Item>()
                : filesIn(service.listItems(opportunityClientAccount.id));
            if (looseFiles.isEmpty() && clientAccountFiles.isEmpty()) {
                return moves;
            }

            List<BoxMatterFolderService.Item> matterTop = service.listItems(conversion.matterFolderId);
            BoxMatterFolderService.Item uploads = named(matterTop, UPLOADS_FOLDER);
            BoxMatterFolderService.Item clientAccount = named(matterTop, CLIENT_ACCOUNT_FOLDER);
            BoxMatterFolderService.Item portal = named(matterTop, CLIENT_PORTAL_FOLDER);
            if (clientAccount == null && portal != null && !clientAccountFiles.isEmpty()) {
                clientAccount = named(service.listItems(portal.id), CLIENT_ACCOUNT_FOLDER);
            }

            addMoves(moves, looseFiles, uploads, UPLOADS_FOLDER, 'at the top of the Opportunity folder', 'looked at the top level');
            addMoves(moves, clientAccountFiles, clientAccount, CLIENT_ACCOUNT_FOLDER, 'in the Opportunity\'s Client Account folder',
                'looked at the top level and in ' + CLIENT_PORTAL_FOLDER);
        } catch (Exception e) {
            report.problem('Couldn\'t read the folders in Box: ' + SystemHealthSlack.escape(e.getMessage()), true);
        }
        return moves;
    }

    private void addMoves(
        List<FileMove> moves, List<BoxMatterFolderService.Item> files, BoxMatterFolderService.Item target,
        String targetName, String whereFilesAre, String whereLooked
    ) {
        if (files.isEmpty()) {
            return;
        }
        report.files += files.size();
        if (target == null) {
            List<String> names = new List<String>();
            for (BoxMatterFolderService.Item file : files) {
                names.add(SystemHealthSlack.escape(file.name));
            }
            report.problem('No "' + targetName + '" folder in the Matter folder (' + whereLooked + '), so '
                + files.size() + (files.size() == 1 ? ' file stayed ' : ' files stayed ') + whereFilesAre + ': '
                + String.join(names, ', '), true);
            return;
        }
        for (BoxMatterFolderService.Item file : files) {
            FileMove move = new FileMove();
            move.fileId = file.id;
            move.fileName = file.name;
            move.targetFolderId = target.id;
            move.targetName = targetName;
            moves.add(move);
        }
    }

    /// Returns false if it ran out of callout time with files still to move.
    private Boolean moveFiles(BoxMatterFolderService service) {
        Integer attempted = 0;
        while (!pending.isEmpty()) {
            // The first file always runs so the chain can't stall.
            if (attempted > 0 && !service.hasTimeForAnotherMove()) {
                return false;
            }
            attempted++;
            FileMove next = pending.remove(0);
            BoxMatterFolderService.ItemMove result = service.moveItemAndVerify('file', next.fileId, next.targetFolderId);
            switch on result.outcome {
                when MOVED, ALREADY_IN_PLACE {
                    report.moved++;
                }
                when WOULD_MOVE {
                    report.wouldMove++;
                }
                when UNCONFIRMED {
                    report.problem(next.describe(result.error + (isRecheck ? ' (tried twice, ' + RECHECK_DELAY_MINUTES + ' minutes apart)' : '')), true);
                }
                when else {
                    report.problem(next.describe(result.error), false);
                }
            }
        }
        return true;
    }

    /// A matter whose problems a recheck might clear waits for it; otherwise its result is final.
    private void finishMatter() {
        Boolean waitForRecheck = report.retryable && !isRecheck;
        if (waitForRecheck) {
            recheckLater.add(report.matterId);
        }
        if (summary != null) {
            summary.record(report, !isRecheck, !waitForRecheck);
        } else if (!waitForRecheck && !report.problems.isEmpty()) {
            alerts.add(report.format());
        }
        matterIds.remove(0);
        report = null;
        pending = null;
    }

    private static List<BoxMatterFolderService.Item> filesIn(List<BoxMatterFolderService.Item> items) {
        List<BoxMatterFolderService.Item> files = new List<BoxMatterFolderService.Item>();
        for (BoxMatterFolderService.Item item : items) {
            if (item.type == 'file') {
                files.add(item);
            }
        }
        return files;
    }

    private static BoxMatterFolderService.Item named(List<BoxMatterFolderService.Item> items, String folderName) {
        for (BoxMatterFolderService.Item item : items) {
            if (item.type == 'folder' && item.name == folderName) {
                return item;
            }
        }
        return null;
    }

    private static String plural(Integer n, String one, String many) {
        return n.format() + ' ' + (n == 1 ? one : many);
    }

    private static List<String> capped(List<String> lines) {
        List<String> shown = new List<String>();
        for (Integer i = 0; i < lines.size() && i < MAX_LINES; i++) {
            shown.add(lines[i]);
        }
        if (lines.size() > MAX_LINES) {
            shown.add('…and ' + (lines.size() - MAX_LINES) + ' more');
        }
        return shown;
    }

    public class FileMove {
        public String fileId;
        public String fileName;
        public String targetFolderId;
        public String targetName;

        public String describe(String error) {
            return SystemHealthSlack.escape(fileName) + ' → ' + targetName + ' · Box: ' + SystemHealthSlack.escape(error);
        }
    }

    public class Conversion {
        public Id matterId;
        public String matterName;
        public String matterFolderId;
        public String opportunityFolderId;
    }

    /// Matter reads, kept in one place so tests can swap in an in-memory version: inserting a
    /// Matter in a test runs dozens of queries of Matter automation.
    public virtual without sharing class ConversionSource {
        public virtual Conversion byId(Id matterId) {
            for (AcctSeed__Project__c matter : [
                SELECT Id, Name, Box_Matter_Folder_ID__c, AcctSeed__Opportunity__r.Box_Opportunity_Folder_ID__c
                FROM AcctSeed__Project__c
                WHERE Id = :matterId
            ]) {
                Conversion conversion = new Conversion();
                conversion.matterId = matter.Id;
                conversion.matterName = matter.Name;
                conversion.matterFolderId = matter.Box_Matter_Folder_ID__c;
                conversion.opportunityFolderId = matter.AcctSeed__Opportunity__r?.Box_Opportunity_Folder_ID__c;
                return conversion;
            }
            return null;
        }

        /// Matters created since the given time that have both a Box folder and an Opportunity with one.
        public virtual List<Id> convertedSince(Datetime since) {
            List<Id> ids = new List<Id>();
            for (AcctSeed__Project__c matter : [
                SELECT Id FROM AcctSeed__Project__c
                WHERE CreatedDate >= :since AND Box_Matter_Folder_ID__c != null
                  AND AcctSeed__Opportunity__r.Box_Opportunity_Folder_ID__c != null
                ORDER BY CreatedDate
            ]) {
                ids.add(matter.Id);
            }
            return ids;
        }
    }

    /// One matter's outcome, carried across jobs until its moves are done.
    public class MatterReport {
        public Id matterId;
        public Conversion conversion;
        public Integer files = 0;
        public Integer moved = 0;
        public Integer wouldMove = 0;
        public List<String> problems = new List<String>();
        // Something a recheck might clear: an unanswered move, a missing subfolder, Box unreadable.
        public Boolean retryable = false;

        public MatterReport(Id matterId, Conversion conversion) {
            this.matterId = matterId;
            this.conversion = conversion;
        }

        public void problem(String line, Boolean couldClear) {
            problems.add(line);
            retryable = retryable || couldClear;
        }

        public String label() {
            String name = conversion != null ? SystemHealthSlack.escape(conversion.matterName) : 'Matter';
            return name + ' (' + SystemHealthSlack.recordLink(matterId) + ')';
        }

        public String folders() {
            return conversion == null ? '' : 'Opportunity folder ' + SystemHealthSlack.boxFolderLink(conversion.opportunityFolderId)
                + ' · Matter folder ' + SystemHealthSlack.boxFolderLink(conversion.matterFolderId);
        }

        public String format() {
            String headline = ':warning: Box files didn\'t all move from the Opportunity to the Matter for ' + label() + '.';
            if (files > 0) {
                headline += ' ' + moved + ' of ' + files + ' moved; the rest are still in the Opportunity folder.';
            }
            List<String> lines = new List<String>{ headline };
            if (conversion != null) {
                lines.add(folders());
            }
            for (String problem : problems) {
                lines.add('• ' + problem);
            }
            return String.join(lines, '\n');
        }
    }

    /// A sweep's single report, carried through the chain and posted by its last job.
    public class SweepSummary {
        public Datetime since;
        public Integer checked = 0;
        public Map<Id, Integer> movedByMatter = new Map<Id, Integer>();
        public Map<Id, String> labels = new Map<Id, String>();
        public Integer wouldMove = 0;
        public List<String> failed = new List<String>();
        public String fatalError;
        public Boolean reportOnly = BoxMatterFolderService.isReportOnly();

        public SweepSummary(Datetime since) {
            this.since = since;
        }

        /// Moved files count on every pass; problems only from a matter's last pass.
        public void record(MatterReport report, Boolean firstPass, Boolean finalPass) {
            if (firstPass) {
                checked++;
            }
            wouldMove += report.wouldMove;
            if (report.moved > 0) {
                Integer before = movedByMatter.containsKey(report.matterId) ? movedByMatter.get(report.matterId) : 0;
                movedByMatter.put(report.matterId, before + report.moved);
                labels.put(report.matterId, report.label());
            }
            if (finalPass && !report.problems.isEmpty()) {
                failed.add('• ' + report.label() + ' · ' + report.folders() + '\n    ' + String.join(report.problems, '\n    '));
            }
        }

        public String format() {
            String title = 'Opportunity file check, ' + Datetime.now().format('EEE M/d')
                + (reportOnly ? ' (sandbox: report only, nothing moved)' : '');
            String scope = 'Checked ' + plural(checked, 'Matter', 'Matters') + ' converted since ' + since.format('M/d')
                + ' for files still in the Opportunity\'s Box folder.';

            Integer movedFiles = 0;
            List<String> movedLines = new List<String>();
            for (Id matterId : movedByMatter.keySet()) {
                Integer n = movedByMatter.get(matterId);
                movedFiles += n;
                movedLines.add('• ' + labels.get(matterId) + ' · ' + plural(n, 'file', 'files'));
            }

            if (fatalError != null) {
                return ':rotating_light: ' + title + ' did not finish.\n' + SystemHealthSlack.escape(fatalError) + '\n' + scope
                    + section('Couldn\'t move', failed) + section('Moved before it stopped', movedLines);
            }
            if (movedLines.isEmpty() && failed.isEmpty() && wouldMove == 0) {
                return ':white_check_mark: ' + title + ': nothing left in an Opportunity folder.\n' + scope;
            }

            List<String> counts = new List<String>();
            if (movedFiles > 0) {
                counts.add(plural(movedFiles, 'file', 'files') + ' moved for ' + plural(movedLines.size(), 'Matter', 'Matters'));
            }
            if (wouldMove > 0) {
                counts.add(plural(wouldMove, 'file', 'files') + ' would move');
            }
            if (!failed.isEmpty()) {
                counts.add(plural(failed.size(), 'Matter has', 'Matters have') + ' files that couldn\'t move');
            }
            return (failed.isEmpty() ? ':white_check_mark: ' : ':warning: ') + title + ': ' + String.join(counts, ', ') + '.\n' + scope
                + section('Couldn\'t move', failed) + section('Moved', movedLines);
        }

        private String section(String heading, List<String> lines) {
            return lines.isEmpty() ? '' : '\n*' + heading + '*\n' + String.join(capped(lines), '\n');
        }
    }
}
