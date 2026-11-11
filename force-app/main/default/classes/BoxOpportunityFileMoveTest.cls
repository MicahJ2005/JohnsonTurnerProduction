/// Micah Johnson - Demand Chain 2026
/// Covers BoxOpportunityFileMoveQueueable (and the file side of BoxMatterFolderService) against a
/// fake Box that tracks where each file and folder actually is. Matters come from an in-memory
/// ConversionSource, and jobs are run directly, since tests can't chain queueables.
@IsTest
private class BoxOpportunityFileMoveTest {

    private static final String OPP_FOLDER = '100';
    private static final String OPP_CLIENT_ACCOUNT = '101';
    private static final String MATTER_FOLDER = '200';
    private static final String UPLOADS = '201';
    private static final String PORTAL = '202';
    private static final String PORTAL_CLIENT_ACCOUNT = '203';

    private static final String SIGNED = 'f1';
    private static final String UNSIGNED = 'f2';
    private static final String LOOSE = 'f3';

    /// Stands in for Box: folders and files with a name and a parent. Lists folder contents, moves
    /// files, and can refuse a move (Shield 403), clash with a same-named file (409), or time out on
    /// Salesforce's side after Box has moved the file unless it's also in silentlyIgnored.
    private class BoxMock implements HttpCalloutMock {
        Map<String, String> parentOf = new Map<String, String>();
        Map<String, String> nameOf = new Map<String, String>();
        Map<String, String> typeOf = new Map<String, String>();
        Set<String> shieldBlocked = new Set<String>();
        Set<String> timesOut = new Set<String>();
        Set<String> silentlyIgnored = new Set<String>();
        Integer listStatus = 200;
        Integer moves = 0;

        void add(String type, String id, String name, String parentId) {
            typeOf.put(id, type);
            nameOf.put(id, name);
            parentOf.put(id, parentId);
        }

        public HttpResponse respond(HttpRequest req) {
            String endpoint = req.getEndpoint();
            String path = endpoint.contains('/2.0/files/') ? endpoint.substringAfter('/2.0/files/') : endpoint.substringAfter('/2.0/folders/');
            String id = path.substringBefore('?').substringBefore('/');
            if (path.contains('/items')) {
                return listItems(id);
            }
            if (!parentOf.containsKey(id)) {
                return reply(404, '{"type":"error","status":404,"code":"not_found","message":"Not Found"}');
            }
            if (req.getMethod() == 'PUT') {
                moves++;
                if (shieldBlocked.contains(id)) {
                    return reply(403, '{"type":"error","status":403,"code":"forbidden_by_policy","message":"Access denied by Shield policy"}');
                }
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
                String targetId = (String) ((Map<String, Object>) body.get('parent')).get('id');
                for (String other : parentOf.keySet()) {
                    if (other != id && parentOf.get(other) == targetId && nameOf.get(other) == nameOf.get(id)) {
                        return reply(409, '{"type":"error","status":409,"code":"item_name_in_use","message":"Item with the same name already exists"}');
                    }
                }
                if (!silentlyIgnored.contains(id)) {
                    parentOf.put(id, targetId);
                }
                if (timesOut.contains(id)) {
                    throw new CalloutException('Read timed out');
                }
            }
            String parentId = parentOf.get(id);
            return reply(200, JSON.serialize(new Map<String, Object>{
                'type' => typeOf.get(id),
                'id' => id,
                'parent' => new Map<String, Object>{ 'type' => 'folder', 'id' => parentId, 'name' => nameOf.get(parentId) }
            }));
        }

        private HttpResponse listItems(String folderId) {
            if (listStatus != 200) {
                return reply(listStatus, '{"type":"error","status":' + listStatus + ',"code":"unauthorized","message":"Unauthorized"}');
            }
            List<String> children = new List<String>();
            for (String id : parentOf.keySet()) {
                if (parentOf.get(id) == folderId) {
                    children.add(id);
                }
            }
            children.sort();
            List<Object> entries = new List<Object>();
            for (String id : children) {
                entries.add(new Map<String, Object>{ 'type' => typeOf.get(id), 'id' => id, 'name' => nameOf.get(id) });
            }
            return reply(200, JSON.serialize(new Map<String, Object>{ 'entries' => entries, 'limit' => 1000 }));
        }

        private HttpResponse reply(Integer status, String body) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(body);
            return res;
        }
    }

    private class FakeConversions extends BoxOpportunityFileMoveQueueable.ConversionSource {
        Map<Id, BoxOpportunityFileMoveQueueable.Conversion> byMatter = new Map<Id, BoxOpportunityFileMoveQueueable.Conversion>();
        Boolean fail = false;

        Id add(String matterName, String matterFolderId, String opportunityFolderId) {
            String prefix = AcctSeed__Project__c.SObjectType.getDescribe().getKeyPrefix();
            BoxOpportunityFileMoveQueueable.Conversion conversion = new BoxOpportunityFileMoveQueueable.Conversion();
            conversion.matterId = Id.valueOf(prefix + String.valueOf(byMatter.size() + 1).leftPad(12, '0'));
            conversion.matterName = matterName;
            conversion.matterFolderId = matterFolderId;
            conversion.opportunityFolderId = opportunityFolderId;
            byMatter.put(conversion.matterId, conversion);
            return conversion.matterId;
        }

        public override BoxOpportunityFileMoveQueueable.Conversion byId(Id matterId) {
            if (fail) {
                throw new QueryException('simulated query failure');
            }
            return byMatter.get(matterId);
        }

        public override List<Id> convertedSince(Datetime since) {
            return new List<Id>(byMatter.keySet());
        }
    }

    private static FakeConversions conversions;
    private static Id matterId;

    /// A converted Opportunity with two files in its Client Account folder and one loose file, and a
    /// Matter folder whose Client Account sits inside Client Portal (how the folder flow builds it).
    private static BoxMock setUp() {
        BoxMock box = new BoxMock();
        box.add('folder', OPP_FOLDER, 'Jane Client Opportunity', '0');
        box.add('folder', OPP_CLIENT_ACCOUNT, BoxOpportunityFileMoveQueueable.CLIENT_ACCOUNT_FOLDER, OPP_FOLDER);
        box.add('file', SIGNED, 'Initial Service Agreement (Signed) - Jane Client.pdf', OPP_CLIENT_ACCOUNT);
        box.add('file', UNSIGNED, 'Initial Service Agreement (Unsigned) - Jane Client.docx', OPP_CLIENT_ACCOUNT);
        box.add('file', LOOSE, 'Petition & Summons.pdf', OPP_FOLDER);
        box.add('folder', MATTER_FOLDER, 'Jane Client Matter', '0');
        box.add('folder', UPLOADS, BoxOpportunityFileMoveQueueable.UPLOADS_FOLDER, MATTER_FOLDER);
        box.add('folder', PORTAL, BoxOpportunityFileMoveQueueable.CLIENT_PORTAL_FOLDER, MATTER_FOLDER);
        box.add('folder', PORTAL_CLIENT_ACCOUNT, BoxOpportunityFileMoveQueueable.CLIENT_ACCOUNT_FOLDER, PORTAL);
        Test.setMock(HttpCalloutMock.class, box);

        conversions = new FakeConversions();
        matterId = conversions.add('Jane Client & Co', MATTER_FOLDER, OPP_FOLDER);
        BoxOpportunityFileMoveQueueable.conversions = conversions;
        BoxMatterFolderService.reportOnly = false;
        return box;
    }

    private static void runFlowMove(List<Id> matterIds) {
        List<BoxOpportunityFileMoveQueueable.Request> requests = new List<BoxOpportunityFileMoveQueueable.Request>();
        for (Id id : matterIds) {
            BoxOpportunityFileMoveQueueable.Request request = new BoxOpportunityFileMoveQueueable.Request();
            request.matterId = id;
            requests.add(request);
        }
        BoxOpportunityFileMoveQueueable.moveFromFlow(requests);
        runQueued();
    }

    /// Runs the job the flow action (or a previous job) queued.
    private static void runQueued() {
        BoxOpportunityFileMoveQueueable job = BoxOpportunityFileMoveQueueable.queuedForTest;
        Assert.isNotNull(job, 'Expected a queued move job');
        BoxOpportunityFileMoveQueueable.queuedForTest = null;
        job.execute(null);
    }

    private static List<String> posted() {
        return SystemHealthSlack.postedForTest;
    }

    @IsTest
    static void filesLandInTheirMatterFoldersQuietly() {
        BoxMock box = setUp();

        runFlowMove(new List<Id>{ matterId });

        Assert.areEqual(PORTAL_CLIENT_ACCOUNT, box.parentOf.get(SIGNED));
        Assert.areEqual(PORTAL_CLIENT_ACCOUNT, box.parentOf.get(UNSIGNED));
        Assert.areEqual(UPLOADS, box.parentOf.get(LOOSE));
        Assert.isNull(BoxOpportunityFileMoveQueueable.queuedForTest, 'Nothing to recheck');
        Assert.isTrue(posted().isEmpty(), 'Successful moves should not post: ' + posted());
    }

    @IsTest
    static void clientAccountAtTheTopOfTheMatterFolderIsUsed() {
        BoxMock box = setUp();
        box.add('folder', '204', BoxOpportunityFileMoveQueueable.CLIENT_ACCOUNT_FOLDER, MATTER_FOLDER);

        runFlowMove(new List<Id>{ matterId });

        Assert.areEqual('204', box.parentOf.get(SIGNED));
        Assert.areEqual('204', box.parentOf.get(UNSIGNED));
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    @IsTest
    static void shieldBlockedFileIsReportedWithBoxError() {
        BoxMock box = setUp();
        box.shieldBlocked.add(SIGNED);

        runFlowMove(new List<Id>{ matterId });

        Assert.areEqual(OPP_CLIENT_ACCOUNT, box.parentOf.get(SIGNED));
        Assert.isNull(BoxOpportunityFileMoveQueueable.queuedForTest, 'A refused move is reported, not rechecked');
        Assert.areEqual(1, posted().size());
        String alert = posted()[0];
        Assert.isTrue(alert.contains('for Jane Client &amp; Co (') && alert.contains(matterId), alert);
        Assert.isTrue(alert.contains('2 of 3 moved; the rest are still in the Opportunity folder.'), alert);
        Assert.isTrue(alert.contains('|' + OPP_FOLDER + '>') && alert.contains('|' + MATTER_FOLDER + '>'), alert);
        Assert.isTrue(alert.contains('• Initial Service Agreement (Signed) - Jane Client.pdf → Client Account · Box: 403 forbidden_by_policy: Access denied by Shield policy'), alert);
    }

    @IsTest
    static void sameNamedFileInTheMatterFolderIsReported() {
        BoxMock box = setUp();
        box.add('file', 'f9', 'Petition & Summons.pdf', UPLOADS);

        runFlowMove(new List<Id>{ matterId });

        Assert.areEqual(OPP_FOLDER, box.parentOf.get(LOOSE));
        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('• Petition &amp; Summons.pdf → Client Uploads - New Documents Here · Box: 409 item_name_in_use'), posted()[0]);
    }

    @IsTest
    static void missingSubfolderIsRecheckedThenReported() {
        BoxMock box = setUp();
        box.parentOf.remove(UPLOADS);

        runFlowMove(new List<Id>{ matterId });
        Assert.areEqual(PORTAL_CLIENT_ACCOUNT, box.parentOf.get(SIGNED), 'Files with a target still move on the first pass');
        Assert.isTrue(posted().isEmpty(), 'The Matter\'s subfolders may still be building: ' + posted());
        Assert.areEqual(BoxOpportunityFileMoveQueueable.RECHECK_DELAY_MINUTES, BoxOpportunityFileMoveQueueable.queuedDelayForTest);

        runQueued();

        Assert.isNull(BoxOpportunityFileMoveQueueable.queuedForTest, 'Only one recheck');
        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('No "Client Uploads - New Documents Here" folder in the Matter folder (looked at the top level), '
            + 'so 1 file stayed at the top of the Opportunity folder: Petition &amp; Summons.pdf'), posted()[0]);
    }

    @IsTest
    static void subfolderBuiltBeforeTheRecheckGetsItsFilesQuietly() {
        BoxMock box = setUp();
        box.parentOf.remove(UPLOADS);
        runFlowMove(new List<Id>{ matterId });

        box.parentOf.put(UPLOADS, MATTER_FOLDER);
        runQueued();

        Assert.areEqual(UPLOADS, box.parentOf.get(LOOSE));
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    @IsTest
    static void moveThatTimesOutButLandsStaysQuiet() {
        BoxMock box = setUp();
        box.timesOut.add(SIGNED);

        runFlowMove(new List<Id>{ matterId });

        Assert.areEqual(PORTAL_CLIENT_ACCOUNT, box.parentOf.get(SIGNED));
        Assert.isNull(BoxOpportunityFileMoveQueueable.queuedForTest, 'A move confirmed by the read back needs no recheck');
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    @IsTest
    static void unansweredMoveIsRetriedThenReported() {
        BoxMock box = setUp();
        box.timesOut.add(SIGNED);
        box.silentlyIgnored.add(SIGNED);

        runFlowMove(new List<Id>{ matterId });
        Assert.isTrue(posted().isEmpty(), posted().toString());
        Assert.areEqual(3, box.moves);

        runQueued();

        Assert.areEqual(4, box.moves, 'The recheck moves only the file still in the Opportunity folder');
        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('0 of 1 moved'), posted()[0]);
        Assert.isTrue(posted()[0].contains('no reply to the move within 30 seconds (tried twice, 5 minutes apart)'), posted()[0]);
    }

    @IsTest
    static void unreadableBoxIsRecheckedThenReported() {
        BoxMock box = setUp();
        box.listStatus = 401;

        runFlowMove(new List<Id>{ matterId });
        Assert.isTrue(posted().isEmpty(), posted().toString());

        runQueued();

        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('• Couldn\'t read the folders in Box: Could not list 100: 401 unauthorized: Unauthorized'), posted()[0]);
    }

    @IsTest
    static void nothingToMoveStaysQuiet() {
        BoxMock box = setUp();
        box.parentOf.remove(SIGNED);
        box.parentOf.remove(UNSIGNED);
        box.parentOf.remove(LOOSE);
        Id noOpportunityFolder = conversions.add('No Opportunity Folder', '300', null);

        runFlowMove(new List<Id>{ matterId, noOpportunityFolder });

        Assert.areEqual(0, box.moves);
        Assert.isNull(BoxOpportunityFileMoveQueueable.queuedForTest);
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    @IsTest
    static void filesThatDontFitInOneJobCarryOn() {
        BoxMock box = setUp();
        BoxMatterFolderService.calloutBudgetMs = 1;

        runFlowMove(new List<Id>{ matterId });
        Assert.areEqual(1, box.moves, 'The first file always runs; the next might not fit');
        Assert.areEqual(0, BoxOpportunityFileMoveQueueable.queuedDelayForTest, 'The handoff runs straight away');
        runQueued();
        runQueued();

        Assert.areEqual(3, box.moves);
        Assert.areEqual(UPLOADS, box.parentOf.get(LOOSE));
        Assert.isNull(BoxOpportunityFileMoveQueueable.queuedForTest);
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    /// Second conversion: one loose file and a Matter folder with only Client Uploads.
    private static Id addSecondConversion(BoxMock box) {
        box.add('folder', '400', 'Second Opportunity', '0');
        box.add('file', 'f4', 'Retainer.pdf', '400');
        box.add('folder', '500', 'Second Matter', '0');
        box.add('folder', '501', BoxOpportunityFileMoveQueueable.UPLOADS_FOLDER, '500');
        return conversions.add('Second Matter', '500', '400');
    }

    @IsTest
    static void severalMattersShareAJobAndRechecksComeLast() {
        BoxMock box = setUp();
        box.parentOf.remove(UPLOADS);
        Id second = addSecondConversion(box);

        runFlowMove(new List<Id>{ matterId, second });
        Assert.areEqual('501', box.parentOf.get('f4'), 'Both matters fit in one job');
        Assert.areEqual(BoxOpportunityFileMoveQueueable.RECHECK_DELAY_MINUTES, BoxOpportunityFileMoveQueueable.queuedDelayForTest);
        Assert.isTrue(posted().isEmpty(), posted().toString());

        runQueued();

        Assert.areEqual(1, posted().size(), 'Only the first matter is still missing a folder');
        Assert.isTrue(posted()[0].contains('Jane Client &amp; Co'), posted()[0]);
    }

    @IsTest
    static void mattersThatDontFitInOneJobCarryOn() {
        BoxMock box = setUp();
        Id second = addSecondConversion(box);
        BoxMatterFolderService.calloutBudgetMs = 1;

        runFlowMove(new List<Id>{ second, matterId });
        Assert.areEqual('501', box.parentOf.get('f4'));
        Assert.areEqual(1, box.moves, 'The next matter might not fit');
        while (BoxOpportunityFileMoveQueueable.queuedForTest != null) {
            runQueued();
        }

        Assert.areEqual(4, box.moves);
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    @IsTest
    static void sweepMovesLeftoverFilesAndPostsOneSummary() {
        BoxMock box = setUp();
        box.parentOf.remove(UPLOADS);
        addSecondConversion(box);

        BoxOpportunityFileMoveQueueable.sweep(Datetime.newInstance(2026, 9, 7, 0, 0, 0));
        runQueued();
        Assert.isTrue(posted().isEmpty(), 'The summary waits for the recheck: ' + posted());
        runQueued();

        Assert.isNull(BoxOpportunityFileMoveQueueable.queuedForTest);
        Assert.areEqual(1, posted().size());
        String summary = posted()[0];
        Assert.isTrue(summary.startsWith(':warning: Opportunity file check'), summary);
        Assert.isTrue(summary.contains('3 files moved for 2 Matters, 1 Matter has files that couldn\'t move.'), summary);
        Assert.isTrue(summary.contains('Checked 2 Matters converted since 9/7'), summary);
        Assert.isTrue(summary.contains('No "Client Uploads - New Documents Here" folder in the Matter folder'), summary);
        Assert.isTrue(summary.contains('Second Matter (') && summary.contains(' · 1 file'), summary);
        Assert.isTrue(summary.contains('Jane Client &amp; Co (') && summary.contains(' · 2 files'), summary);
    }

    @IsTest
    static void sweepOnACleanDayPostsAllClear() {
        BoxMock box = setUp();
        box.parentOf.remove(SIGNED);
        box.parentOf.remove(UNSIGNED);
        box.parentOf.remove(LOOSE);

        BoxOpportunityFileMoveQueueable.sweep(Datetime.newInstance(2026, 9, 27, 0, 0, 0));
        runQueued();

        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].startsWith(':white_check_mark:') && posted()[0].contains('nothing left in an Opportunity folder'), posted()[0]);
        Assert.isTrue(posted()[0].contains('Checked 1 Matter converted since 9/27'), posted()[0]);
    }

    @IsTest
    static void sweepThatCannotFinishSaysSo() {
        setUp();
        conversions.fail = true;

        BoxOpportunityFileMoveQueueable.sweep(Datetime.now().addDays(-30));
        runQueued();

        Assert.isNull(BoxOpportunityFileMoveQueueable.queuedForTest, 'The run stops');
        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].startsWith(':rotating_light:') && posted()[0].contains('simulated query failure'), posted()[0]);
    }

    @IsTest
    static void sandboxSweepOnlyReports() {
        BoxMock box = setUp();
        BoxMatterFolderService.reportOnly = true;

        BoxOpportunityFileMoveQueueable.sweep(Datetime.now().addDays(-30));
        runQueued();

        Assert.areEqual(0, box.moves);
        Assert.isTrue(posted()[0].contains('report only') && posted()[0].contains('3 files would move'), posted()[0]);
    }

    @IsTest
    static void schedulerQueuesASweep() {
        setUp();
        BoxOpportunityFileSweepScheduler.jobName = 'Test ' + BoxOpportunityFileSweepScheduler.JOB_NAME;

        Id jobId = BoxOpportunityFileSweepScheduler.schedule();
        Assert.areEqual(BoxOpportunityFileSweepScheduler.CRON, [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId].CronExpression);

        new BoxOpportunityFileSweepScheduler().execute(null);
        Assert.isNotNull(BoxOpportunityFileMoveQueueable.queuedForTest);
    }

    @IsTest
    static void blankRequestsQueueNothing() {
        setUp();

        BoxOpportunityFileMoveQueueable.moveFromFlow(new List<BoxOpportunityFileMoveQueueable.Request>{ new BoxOpportunityFileMoveQueueable.Request() });

        Assert.isNull(BoxOpportunityFileMoveQueueable.queuedForTest);
    }

    @IsTest
    static void sandboxRunsOnlyReport() {
        BoxMock box = setUp();
        BoxMatterFolderService.reportOnly = true;

        runFlowMove(new List<Id>{ matterId });

        Assert.areEqual(0, box.moves);
        Assert.areEqual(OPP_CLIENT_ACCOUNT, box.parentOf.get(SIGNED));
        Assert.isTrue(posted().isEmpty(), posted().toString());
    }

    @IsTest
    static void unexpectedErrorIsPostedAndTheChainGoesOn() {
        setUp();
        conversions.fail = true;

        runFlowMove(new List<Id>{ matterId });

        Assert.areEqual(1, posted().size());
        Assert.isTrue(posted()[0].contains('stopped before finishing: simulated query failure'), posted()[0]);
    }

    @IsTest
    static void realConversionQueryRuns() {
        String prefix = AcctSeed__Project__c.SObjectType.getDescribe().getKeyPrefix();
        Id missing = Id.valueOf(prefix + '000000000001');

        BoxOpportunityFileMoveQueueable.ConversionSource real = new BoxOpportunityFileMoveQueueable.ConversionSource();
        Assert.isNull(real.byId(missing));
        Assert.isTrue(real.convertedSince(Datetime.now().addDays(-30)).isEmpty());
    }
}
