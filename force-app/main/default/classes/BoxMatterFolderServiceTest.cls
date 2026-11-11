/// Micah Johnson - Demand Chain 2026
/// Covers BoxMatterFolderService, BoxMatterFolderMoveQueueable, BoxMatterFolderReconciler,
/// BoxMatterFolderReconcilerScheduler and SystemHealthSlack against a fake Box that tracks where each folder actually is.
///
/// Matters come from an in-memory MatterSource: inserting more than one Matter in a test trips
/// AyMatterTrigger's trust balance batch, and each insert costs dozens of queries of Matter
/// automation. Only the last test inserts a (single) Matter, to cover the real queries: test data
/// written before a callout blocks it, so no other test does DML. Jobs are run directly, since
/// tests can't chain queueables.
@IsTest
private class BoxMatterFolderServiceTest {

    private static final String MATTERS = BoxMatterFolderService.MATTERS_FOLDER_ID;
    private static final String COMPLETED = BoxMatterFolderService.COMPLETED_FOLDER_ID;

    private static final String ACTIVE_IN_COMPLETED = 'Active In Completed & Co';
    private static final String COMPLETED_IN_MATTERS = 'Completed In Matters';
    private static final String ACTIVE_IN_PLACE = 'Active In Place';
    private static final String ON_HOLD_IN_COMPLETED = 'On Hold In Completed';

    /// Stands in for Box: tracks each folder's parent, applies moves, pages folder listings by
    /// marker, and can refuse a move (Shield 403) or accept one without moving anything - the case
    /// box.Toolkit.moveFolder reported as success. A folder in timesOut makes the move time out on
    /// Salesforce's side, after Box has moved it unless it's also in silentlyIgnored.
    private class BoxMock implements HttpCalloutMock {
        Map<String, String> parentOf = new Map<String, String>();
        Set<String> shieldBlocked = new Set<String>();
        Set<String> silentlyIgnored = new Set<String>();
        Set<String> timesOut = new Set<String>();
        Integer listStatus = 200;
        Integer moves = 0;

        public HttpResponse respond(HttpRequest req) {
            String path = req.getEndpoint().substringAfter('/2.0/folders/');
            String folderId = path.substringBefore('?').substringBefore('/');
            if (path.contains('/items')) {
                return listItems(folderId, req.getEndpoint().substringAfter('&marker='));
            }
            if (!parentOf.containsKey(folderId)) {
                return reply(404, '{"type":"error","status":404,"code":"not_found","message":"Not Found"}');
            }
            if (req.getMethod() == 'PUT') {
                moves++;
                if (shieldBlocked.contains(folderId)) {
                    return reply(403, '{"type":"error","status":403,"code":"forbidden_by_policy","message":"Access denied by Shield policy"}');
                }
                if (!silentlyIgnored.contains(folderId)) {
                    Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
                    parentOf.put(folderId, (String) ((Map<String, Object>) body.get('parent')).get('id'));
                }
                if (timesOut.contains(folderId)) {
                    throw new CalloutException('Read timed out');
                }
            }
            String parentId = parentOf.get(folderId);
            return reply(200, JSON.serialize(new Map<String, Object>{
                'type' => 'folder',
                'id' => folderId,
                'parent' => new Map<String, Object>{ 'type' => 'folder', 'id' => parentId, 'name' => BoxMatterFolderService.folderLabel(parentId) }
            }));
        }

        // One folder per page so the reconciler has to follow next_marker.
        private HttpResponse listItems(String parentId, String marker) {
            if (listStatus != 200) {
                return reply(listStatus, '{"type":"error","status":' + listStatus + ',"code":"unauthorized","message":"Unauthorized"}');
            }
            List<String> children = new List<String>();
            for (String folderId : parentOf.keySet()) {
                if (parentOf.get(folderId) == parentId) {
                    children.add(folderId);
                }
            }
            children.sort();

            Integer start = String.isBlank(marker) ? 0 : Integer.valueOf(marker);
            List<Object> entries = new List<Object>();
            if (start < children.size()) {
                entries.add(new Map<String, Object>{ 'type' => 'folder', 'id' => children[start] });
            }
            if (start == 0) {
                // Files can sit next to matter folders and must be ignored.
                entries.add(new Map<String, Object>{ 'type' => 'file', 'id' => '555' });
            }
            Map<String, Object> page = new Map<String, Object>{ 'entries' => entries, 'limit' => 1000 };
            if (start + 1 < children.size()) {
                page.put('next_marker', String.valueOf(start + 1));
            }
            return reply(200, JSON.serialize(page));
        }

        private HttpResponse reply(Integer status, String body) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(body);
            return res;
        }
    }

    /// In-memory Matters with fake IDs, answering the same questions as the real MatterSource.
    private class FakeMatters extends BoxMatterFolderService.MatterSource {
        List<AcctSeed__Project__c> all = new List<AcctSeed__Project__c>();

        void add(String name, String status, String folderId) {
            String prefix = AcctSeed__Project__c.SObjectType.getDescribe().getKeyPrefix();
            Id fakeId = Id.valueOf(prefix + String.valueOf(all.size() + 1).leftPad(12, '0'));
            all.add(new AcctSeed__Project__c(Id = fakeId, Name = name, AcctSeed__Status__c = status, Box_Matter_Folder_ID__c = folderId));
        }

        Id idOf(String name) {
            for (AcctSeed__Project__c matter : all) {
                if (matter.Name == name) {
                    return matter.Id;
                }
            }
            return null;
        }

        public override List<AcctSeed__Project__c> byIds(List<Id> matterIds) {
            Set<Id> wanted = new Set<Id>(matterIds);
            List<AcctSeed__Project__c> found = new List<AcctSeed__Project__c>();
            for (AcctSeed__Project__c matter : all) {
                if (wanted.contains(matter.Id)) {
                    found.add(matter);
                }
            }
            return found;
        }

        public override List<AcctSeed__Project__c> completedInFolders(Set<String> folderIds) {
            List<AcctSeed__Project__c> found = new List<AcctSeed__Project__c>();
            for (AcctSeed__Project__c matter : all) {
                if (matter.AcctSeed__Status__c == 'Completed' && folderIds.contains(matter.Box_Matter_Folder_ID__c)) {
                    found.add(matter);
                }
            }
            return found;
        }

        public override List<AcctSeed__Project__c> activeWithFolders() {
            List<AcctSeed__Project__c> found = new List<AcctSeed__Project__c>();
            for (AcctSeed__Project__c matter : all) {
                if (matter.AcctSeed__Status__c == 'Active' && matter.Box_Matter_Folder_ID__c != null) {
                    found.add(matter);
                }
            }
            return found;
        }

        public override Integer countCompletedWithFolders() {
            Integer count = 0;
            for (AcctSeed__Project__c matter : all) {
                if (matter.AcctSeed__Status__c == 'Completed' && matter.Box_Matter_Folder_ID__c != null) {
                    count++;
                }
            }
            return count;
        }

        public override Set<String> sharedFolders(Set<String> folderIds) {
            Set<String> seen = new Set<String>();
            Set<String> shared = new Set<String>();
            for (AcctSeed__Project__c matter : all) {
                if (folderIds.contains(matter.Box_Matter_Folder_ID__c) && !seen.add(matter.Box_Matter_Folder_ID__c)) {
                    shared.add(matter.Box_Matter_Folder_ID__c);
                }
            }
            return shared;
        }
    }

    private static FakeMatters fakeMatters;

    /// 9001 and 9002 are in the wrong folder for their status; 9005 is On hold and may sit anywhere;
    /// 9006 is shared by two matters and not in either Box folder unless a test puts it there.
    private static BoxMock setUp() {
        fakeMatters = new FakeMatters();
        fakeMatters.add(ACTIVE_IN_COMPLETED, 'Active', '9001');
        fakeMatters.add(COMPLETED_IN_MATTERS, 'Completed', '9002');
        fakeMatters.add(ACTIVE_IN_PLACE, 'Active', '9003');
        fakeMatters.add(ON_HOLD_IN_COMPLETED, 'On hold', '9005');
        fakeMatters.add('Shared Completed', 'Completed', '9006');
        fakeMatters.add('Shared Active', 'Active', '9006');
        BoxMatterFolderService.matterSource = fakeMatters;
        BoxMatterFolderService.reportOnly = false;

        BoxMock box = new BoxMock();
        box.parentOf.put('9001', COMPLETED);
        box.parentOf.put('9002', MATTERS);
        box.parentOf.put('9003', MATTERS);
        box.parentOf.put('9005', COMPLETED);
        Test.setMock(HttpCalloutMock.class, box);
        return box;
    }

    private static void runFlowMove(List<String> names) {
        List<BoxMatterFolderMoveQueueable.Request> requests = new List<BoxMatterFolderMoveQueueable.Request>();
        for (String name : names) {
            BoxMatterFolderMoveQueueable.Request request = new BoxMatterFolderMoveQueueable.Request();
            request.matterId = fakeMatters.idOf(name);
            requests.add(request);
        }
        BoxMatterFolderMoveQueueable.moveFromFlow(requests);
        runQueued();
    }

    /// Runs the job the flow action (or a previous job) queued.
    private static void runQueued() {
        BoxMatterFolderMoveQueueable job = BoxMatterFolderMoveQueueable.queuedForTest;
        Assert.isNotNull(job, 'Expected a queued move job');
        BoxMatterFolderMoveQueueable.queuedForTest = null;
        job.execute(null);
    }

    private static void runReconciler(BoxMatterFolderReconciler reconciler) {
        reconciler.execute((QueueableContext) null);
    }

    private static List<String> posted() {
        return SystemHealthSlack.postedForTest;
    }

    @IsTest
    static void flowMoveLandsFoldersAndStaysQuiet() {
        BoxMock box = setUp();

        runFlowMove(new List<String>{ ACTIVE_IN_COMPLETED, COMPLETED_IN_MATTERS, ACTIVE_IN_PLACE });

        Assert.areEqual(MATTERS, box.parentOf.get('9001'));
        Assert.areEqual(COMPLETED, box.parentOf.get('9002'));
        Assert.areEqual(2, box.moves, 'A folder already in place should not be moved');
        Assert.isTrue(posted().isEmpty(), 'Successful moves should not post: ' + posted());
    }

    @IsTest
    static void shieldBlockedMovePostsBoxError() {
        BoxMock box = setUp();
        box.shieldBlocked.add('9001');

        runFlowMove(new List<String>{ ACTIVE_IN_COMPLETED });

        Assert.areEqual(COMPLETED, box.parentOf.get('9001'));
        Assert.areEqual(1, posted().size());
        String alert = posted()[0];
        Assert.isTrue(alert.contains('Active In Completed &amp; Co'), alert);
        Assert.isTrue(alert.contains(fakeMatters.idOf(ACTIVE_IN_COMPLETED)), alert);
        Assert.isTrue(alert.contains('9001'), alert);
        Assert.isTrue(alert.contains('should be in Matters, still in Matters (Completed)'), alert);
        Assert.isTrue(alert.contains('403 forbidden_by_policy: Access denied by Shield policy'), alert);
    }

    @IsTest
    static void moveThatReportsSuccessButDoesNotLandIsCaught() {
        BoxMock box = setUp();
        box.silentlyIgnored.add('9002');

        runFlowMove(new List<String>{ COMPLETED_IN_MATTERS });

        Assert.areEqual(1, box.moves);
        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('still in Matters ·'), posted()[0]);
        Assert.isTrue(posted()[0].contains('move returned success, but the folder did not move'), posted()[0]);
    }

    @IsTest
    static void otherStatusesAndBlankRequestsAreLeftAlone() {
        BoxMock box = setUp();

        BoxMatterFolderMoveQueueable.moveFromFlow(new List<BoxMatterFolderMoveQueueable.Request>{ new BoxMatterFolderMoveQueueable.Request() });
        Assert.isNull(BoxMatterFolderMoveQueueable.queuedForTest, 'A request without a Matter should queue nothing');
        runFlowMove(new List<String>{ ON_HOLD_IN_COMPLETED });

        Assert.areEqual(COMPLETED, box.parentOf.get('9005'));
        Assert.areEqual(0, box.moves);
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    @IsTest
    static void missingFolderIsReported() {
        BoxMock box = setUp();
        box.parentOf.remove('9003');

        runFlowMove(new List<String>{ ACTIVE_IN_PLACE });

        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('location unknown · Box: 404 not_found: Not Found'), posted()[0]);
    }

    @IsTest
    static void flowMovesAreSplitAcrossChainedJobs() {
        BoxMock box = setUp();
        BoxMatterFolderMoveQueueable.foldersPerJob = 1;

        runFlowMove(new List<String>{ ACTIVE_IN_COMPLETED, COMPLETED_IN_MATTERS });

        Assert.areEqual(1, box.moves);
        Assert.isNotNull(BoxMatterFolderMoveQueueable.queuedForTest, 'The second folder should be chained to another job');

        runQueued();
        Assert.areEqual(2, box.moves);
        Assert.areEqual(MATTERS, box.parentOf.get('9001'));
        Assert.areEqual(COMPLETED, box.parentOf.get('9002'));
        Assert.isNull(BoxMatterFolderMoveQueueable.queuedForTest);
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    @IsTest
    static void moveThatTimesOutButLandsStaysQuiet() {
        BoxMock box = setUp();
        box.timesOut.add('9001');

        runFlowMove(new List<String>{ ACTIVE_IN_COMPLETED });

        Assert.areEqual(MATTERS, box.parentOf.get('9001'));
        Assert.isNull(BoxMatterFolderMoveQueueable.queuedForTest, 'A move confirmed by the read back needs no recheck');
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    @IsTest
    static void unansweredMoveThatLandsLaterStaysQuiet() {
        BoxMock box = setUp();
        box.timesOut.add('9001');
        box.silentlyIgnored.add('9001');

        runFlowMove(new List<String>{ ACTIVE_IN_COMPLETED });

        Assert.isTrue(posted().isEmpty(), 'An unanswered move should be rechecked before anyone is alerted: ' + posted());
        Assert.areEqual(BoxMatterFolderMoveQueueable.RECHECK_DELAY_MINUTES, BoxMatterFolderMoveQueueable.queuedDelayForTest);

        // Box finishes the move while the recheck waits.
        box.parentOf.put('9001', MATTERS);
        runQueued();

        Assert.areEqual(1, box.moves, 'A folder that landed should not be moved again');
        Assert.isNull(BoxMatterFolderMoveQueueable.queuedForTest);
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    @IsTest
    static void unansweredMoveIsRetriedThenReported() {
        BoxMock box = setUp();
        box.timesOut.add('9001');
        box.silentlyIgnored.add('9001');
        BoxMatterFolderService.calloutBudgetMs = 1;

        // One folder per job here, so the unconfirmed move has to ride along to the chain's last job.
        runFlowMove(new List<String>{ ACTIVE_IN_COMPLETED, COMPLETED_IN_MATTERS });
        Assert.areEqual(0, BoxMatterFolderMoveQueueable.queuedDelayForTest, 'The handoff runs straight away');
        runQueued();
        Assert.areEqual(COMPLETED, box.parentOf.get('9002'));
        Assert.isTrue(posted().isEmpty(), posted().toString());
        Assert.areEqual(BoxMatterFolderMoveQueueable.RECHECK_DELAY_MINUTES, BoxMatterFolderMoveQueueable.queuedDelayForTest);

        runQueued();

        Assert.areEqual(3, box.moves, 'The recheck should try the move once more');
        Assert.isNull(BoxMatterFolderMoveQueueable.queuedForTest, 'Only one recheck');
        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('should be in Matters, still in Matters (Completed)'), posted()[0]);
        Assert.isTrue(posted()[0].contains('no reply to the move within 30 seconds (tried twice, 5 minutes apart)'), posted()[0]);
    }

    @IsTest
    static void jobHandsOnFoldersThatMightNotFitInCalloutTime() {
        BoxMock box = setUp();
        BoxMatterFolderService.calloutBudgetMs = 1;

        runFlowMove(new List<String>{ ACTIVE_IN_COMPLETED, COMPLETED_IN_MATTERS });

        Assert.areEqual(1, box.moves, 'The first folder always runs; the second might not fit');
        Assert.isNotNull(BoxMatterFolderMoveQueueable.queuedForTest);

        runQueued();
        Assert.areEqual(MATTERS, box.parentOf.get('9001'));
        Assert.areEqual(COMPLETED, box.parentOf.get('9002'));
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    @IsTest
    static void reconcilerSummaryWaitsForRecheck() {
        BoxMock box = setUp();
        box.timesOut.add('9001');
        box.silentlyIgnored.add('9001');

        runReconciler(new BoxMatterFolderReconciler());
        runQueued();
        Assert.isTrue(posted().isEmpty(), 'The summary should wait for the recheck');

        box.parentOf.put('9001', MATTERS);
        runQueued();

        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('2 misplaced, 2 moved.'), posted()[0]);
        Assert.isTrue(posted()[0].contains('Active In Completed &amp; Co'), posted()[0]);
    }

    @IsTest
    static void reconcilerMovesMisplacedFoldersThenPostsSummary() {
        BoxMock box = setUp();

        runReconciler(new BoxMatterFolderReconciler());

        Assert.isTrue(posted().isEmpty(), 'The summary should wait for the move chain');
        runQueued();

        Assert.areEqual(MATTERS, box.parentOf.get('9001'));
        Assert.areEqual(COMPLETED, box.parentOf.get('9002'));
        Assert.areEqual(COMPLETED, box.parentOf.get('9005'), 'On hold matters are not the reconciler\'s business');
        Assert.areEqual(1, posted().size());
        String summary = posted()[0];
        Assert.isTrue(summary.contains('2 misplaced, 2 moved.'), summary);
        Assert.isTrue(summary.contains('Checked 3 Active and 2 Completed matters against 2 folders in Matters and 2 in Matters (Completed).'), summary);
        Assert.isTrue(summary.contains('Active In Completed &amp; Co'), summary);
        Assert.isTrue(summary.contains('moved to Matters (Completed)'), summary);
    }

    @IsTest
    static void reconcilerPostsOnCleanDays() {
        BoxMock box = setUp();
        box.parentOf.put('9001', MATTERS);
        box.parentOf.put('9002', COMPLETED);

        runReconciler(new BoxMatterFolderReconciler());

        Assert.isNull(BoxMatterFolderMoveQueueable.queuedForTest);
        Assert.areEqual(0, box.moves);
        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('every Active and Completed matter folder is in the right place'), posted()[0]);
    }

    @IsTest
    static void reconcilerReportsWhenBoxCannotBeRead() {
        BoxMock box = setUp();
        box.listStatus = 401;

        runReconciler(new BoxMatterFolderReconciler());

        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('did not finish'), posted()[0]);
        Assert.isTrue(posted()[0].contains('Could not list Matters: 401 unauthorized'), posted()[0]);
    }

    @IsTest
    static void reconcilerHoldsUnusuallyLargeRuns() {
        BoxMock box = setUp();

        runReconciler(new BoxMatterFolderReconciler(1));

        Assert.isNull(BoxMatterFolderMoveQueueable.queuedForTest);
        Assert.areEqual(0, box.moves);
        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('nothing was moved'), posted()[0]);
        Assert.isTrue(posted()[0].contains(COMPLETED_IN_MATTERS), posted()[0]);
    }

    @IsTest
    static void reconcilerSkipsFoldersSharedByTwoMatters() {
        BoxMock box = setUp();
        box.parentOf.put('9006', MATTERS);

        runReconciler(new BoxMatterFolderReconciler());
        runQueued();

        Assert.areEqual(MATTERS, box.parentOf.get('9006'));
        Assert.areEqual(2, box.moves);
        Assert.isTrue(posted()[0].contains('1 skipped (shared folder)'), posted()[0]);
        Assert.isTrue(posted()[0].contains('folder is shared with another matter'), posted()[0]);
    }

    @IsTest
    static void sandboxRunsOnlyReport() {
        BoxMock box = setUp();
        BoxMatterFolderService.reportOnly = true;

        runReconciler(new BoxMatterFolderReconciler());
        runQueued();

        Assert.areEqual(0, box.moves);
        Assert.areEqual(COMPLETED, box.parentOf.get('9001'));
        Assert.isTrue(posted()[0].contains('report only'), posted()[0]);
        Assert.isTrue(posted()[0].contains('2 would move'), posted()[0]);
    }

    @IsTest
    static void scheduleRegistersNightlyJob() {
        setUp();
        BoxMatterFolderReconcilerScheduler.jobName = 'Test ' + BoxMatterFolderReconcilerScheduler.JOB_NAME;

        Id jobId = BoxMatterFolderReconcilerScheduler.schedule();
        CronTrigger scheduled = [SELECT CronExpression, CronJobDetail.Name FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual(BoxMatterFolderReconcilerScheduler.CRON, scheduled.CronExpression);
        Assert.areEqual(BoxMatterFolderReconcilerScheduler.jobName, scheduled.CronJobDetail.Name);

        // The scheduler only queues the reconciler, which is what makes the callouts.
        new BoxMatterFolderReconcilerScheduler().execute(null);
        Assert.areEqual(1, Limits.getQueueableJobs());
    }

    @IsTest
    static void failedSlackPostDoesNotEscape() {
        SystemHealthSlack.captureInTests = false;
        SystemHealthSlack.flowName = 'No_Such_Flow_For_Test';

        SystemHealthSlack.post('This should be swallowed, not thrown');

        Assert.isTrue(posted().isEmpty());
    }

    @IsTest
    static void realMatterQueriesMatchOnStatusAndFolder() {
        AcctSeed__Project__c real = new AcctSeed__Project__c(Name = 'Real Matter', AcctSeed__Status__c = 'Active', Box_Matter_Folder_ID__c = '8001');
        insert real;
        BoxMatterFolderService.MatterSource matters = BoxMatterFolderService.matters();

        Assert.areEqual(1, matters.byIds(new List<Id>{ real.Id }).size());
        Assert.areEqual(real.Id, matters.activeWithFolders()[0].Id);
        Assert.isTrue(matters.completedInFolders(new Set<String>{ '8001' }).isEmpty(), 'The matter is Active, not Completed');
        Assert.areEqual(0, matters.countCompletedWithFolders());
        Assert.isTrue(matters.sharedFolders(new Set<String>{ '8001' }).isEmpty(), 'Only one matter uses folder 8001');
    }
}
