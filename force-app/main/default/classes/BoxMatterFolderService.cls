/// Micah Johnson - Demand Chain 2026
/// Moves Matter folders between Box's "Matters" and "Matters (Completed)" folders and confirms
/// where each one actually landed. Also does the verified file moves for
/// BoxOpportunityFileMoveQueueable (converted Opportunity files into the Matter's folder).
///
/// box.Toolkit.moveFolder (and the box__MoveFolder_v2 flow action built on it) returns true even
/// when Box refuses the move - every Shield-blocked move from 9/7 to 10/21/2026 "succeeded" that
/// way. So the move goes out as a plain PUT through Toolkit.sendRequest instead (same Box app and
/// service account, so the same Shield allowances apply), which keeps Box's real error, and the
/// folder's parent is read back afterwards rather than trusting any return value.
///
/// A move Box doesn't answer in time isn't a refusal: Box keeps moving a large folder after
/// Salesforce stops waiting (Archbold, 10/26/2026: 1.7 GB, timed out at 10 seconds, landed anyway).
/// Those come back UNCONFIRMED so the caller can check again later instead of alerting.
///
/// without sharing: runs from the nightly reconciler and from flow-triggered queueables; whether a
/// folder gets moved shouldn't depend on the running user's Matter visibility.
public without sharing class BoxMatterFolderService {

    public static final String MATTERS_FOLDER_ID = '348129788949';
    public static final String COMPLETED_FOLDER_ID = '371800845408';

    private static final String BOX_API = 'https://api.box.com/2.0';
    private static final Integer PAGE_SIZE = 1000;

    public static final Integer READ_TIMEOUT_MS = 10000;
    public static final Integer MOVE_TIMEOUT_MS = 30000;
    /// A folder's (or file's) read, move and read back, each running to its timeout.
    public static final Integer WORST_CASE_MS_PER_FOLDER = READ_TIMEOUT_MS + MOVE_TIMEOUT_MS + READ_TIMEOUT_MS;
    /// Callouts left unused for the Slack post at the end of a job.
    private static final Integer SPARE_CALLOUTS = 2;
    /// Apex allows 120 seconds of callouts per transaction; the rest is left for the Slack post.
    @TestVisible
    private static Integer calloutBudgetMs = 110000;

    public enum Outcome { MOVED, ALREADY_IN_PLACE, WOULD_MOVE, NOT_APPLICABLE, FAILED, UNCONFIRMED }

    /// Report-only in sandboxes: a sandbox's Matters are a stale copy, and if its Box connection
    /// points at the live enterprise, acting on that copy would move real client folders.
    @TestVisible
    private static Boolean reportOnly {
        get {
            if (reportOnly == null) {
                reportOnly = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
            }
            return reportOnly;
        }
        set;
    }

    public static Boolean isReportOnly() {
        return reportOnly;
    }

    /// Only Active and Completed have a home folder. Every other status (On hold, Pending Close,
    /// Inactive, ...) is left wherever its folder already is, on purpose.
    public static String targetFolderFor(String status) {
        if (status == 'Completed') {
            return COMPLETED_FOLDER_ID;
        }
        if (status == 'Active') {
            return MATTERS_FOLDER_ID;
        }
        return null;
    }

    public static String folderLabel(String folderId) {
        if (folderId == MATTERS_FOLDER_ID) {
            return 'Matters';
        }
        if (folderId == COMPLETED_FOLDER_ID) {
            return 'Matters (Completed)';
        }
        return folderId;
    }

    public class MoveResult {
        public Id matterId;
        public String matterName;
        public String folderId;
        public String targetFolderId;
        public Outcome outcome;
        public String finalParentId;
        public String finalParentName;
        public String error;
    }

    /// Where one Box folder or file ended up after moveItemAndVerify.
    public class ItemMove {
        public String itemType;
        public String itemId;
        public String targetFolderId;
        public Outcome outcome;
        public String finalParentId;
        public String finalParentName;
        public String error;
    }

    /// One entry of a Box folder listing.
    public class Item {
        public String id;
        public String type;
        public String name;
    }

    public class BoxApiException extends Exception {}

    /// Matter reads for the move jobs and the reconciler, kept in one place so tests can swap in an
    /// in-memory version: inserting more than one Matter in a test trips AyMatterTrigger's trust
    /// balance batch, and every insert runs dozens of queries of Matter automation.
    public virtual without sharing class MatterSource {
        public virtual List<AcctSeed__Project__c> byIds(List<Id> matterIds) {
            return [
                SELECT Id, Name, AcctSeed__Status__c, Box_Matter_Folder_ID__c
                FROM AcctSeed__Project__c
                WHERE Id IN :matterIds
            ];
        }

        /// Looked up by folder ID: there are 10,000+ Completed matters but only a few thousand
        /// folders in Matters.
        public virtual List<AcctSeed__Project__c> completedInFolders(Set<String> folderIds) {
            return [
                SELECT Id, Name, AcctSeed__Status__c, Box_Matter_Folder_ID__c
                FROM AcctSeed__Project__c
                WHERE AcctSeed__Status__c = 'Completed' AND Box_Matter_Folder_ID__c IN :folderIds
            ];
        }

        public virtual List<AcctSeed__Project__c> activeWithFolders() {
            return [
                SELECT Id, Name, AcctSeed__Status__c, Box_Matter_Folder_ID__c
                FROM AcctSeed__Project__c
                WHERE AcctSeed__Status__c = 'Active' AND Box_Matter_Folder_ID__c != null
            ];
        }

        public virtual Integer countCompletedWithFolders() {
            return [
                SELECT COUNT() FROM AcctSeed__Project__c
                WHERE AcctSeed__Status__c = 'Completed' AND Box_Matter_Folder_ID__c != null
            ];
        }

        /// The given folder IDs that more than one Matter points at.
        public virtual Set<String> sharedFolders(Set<String> folderIds) {
            Set<String> shared = new Set<String>();
            for (AggregateResult row : [
                SELECT Box_Matter_Folder_ID__c folderId
                FROM AcctSeed__Project__c
                WHERE Box_Matter_Folder_ID__c IN :folderIds
                GROUP BY Box_Matter_Folder_ID__c
                HAVING COUNT(Id) > 1
            ]) {
                shared.add((String) row.get('folderId'));
            }
            return shared;
        }
    }

    @TestVisible
    private static MatterSource matterSource = new MatterSource();

    public static MatterSource matters() {
        return matterSource;
    }

    private box.Toolkit toolkit;
    private Long calloutMillis = 0;

    /// Whether another moveAndVerify fits in this transaction's callout time even if every Box
    /// call in it runs to its timeout.
    public Boolean hasTimeForAnotherMove() {
        return hasRoomFor(WORST_CASE_MS_PER_FOLDER, 3);
    }

    /// Whether worstCaseMs more of Box calls, and that many more callouts, fit in this transaction.
    public Boolean hasRoomFor(Integer worstCaseMs, Integer callouts) {
        return calloutMillis + worstCaseMs <= calloutBudgetMs
            && Limits.getCallouts() + callouts + SPARE_CALLOUTS <= Limits.getLimitCallouts();
    }

    /// Puts the Matter's folder where its status says it belongs and reports where it really is
    /// afterwards. Box errors come back as a FAILED result, never as an exception; a move Box
    /// didn't answer that hasn't landed yet comes back UNCONFIRMED.
    public MoveResult moveAndVerify(AcctSeed__Project__c matter) {
        MoveResult result = new MoveResult();
        result.matterId = matter.Id;
        result.matterName = matter.Name;
        result.folderId = matter.Box_Matter_Folder_ID__c;
        result.targetFolderId = targetFolderFor(matter.AcctSeed__Status__c);

        if (result.targetFolderId == null || String.isBlank(result.folderId)) {
            result.outcome = Outcome.NOT_APPLICABLE;
            return result;
        }

        ItemMove move = moveItemAndVerify('folder', result.folderId, result.targetFolderId);
        result.outcome = move.outcome;
        result.finalParentId = move.finalParentId;
        result.finalParentName = move.finalParentName;
        result.error = move.error;
        return result;
    }

    /// Moves a Box folder or file (itemType 'folder' or 'file') into targetFolderId and reports where
    /// it really is afterwards. Box errors come back as a FAILED result, never as an exception; a
    /// move Box didn't answer that hasn't landed yet comes back UNCONFIRMED.
    public ItemMove moveItemAndVerify(String itemType, String itemId, String targetFolderId) {
        ItemMove result = new ItemMove();
        result.itemType = itemType;
        result.itemId = itemId;
        result.targetFolderId = targetFolderId;

        String moveError;
        Boolean unanswered = false;
        try {
            // Read first: most flow-triggered folder moves are edits to a matter whose folder is
            // already in the right place, and those shouldn't cost a move.
            readParent(result);
            if (result.finalParentId == result.targetFolderId) {
                result.outcome = Outcome.ALREADY_IN_PLACE;
                return result;
            }
            if (reportOnly) {
                result.outcome = Outcome.WOULD_MOVE;
                return result;
            }

            String body = JSON.serialize(new Map<String, Object>{
                'parent' => new Map<String, Object>{ 'id' => result.targetFolderId }
            });
            try {
                HttpResponse moveRes = send('PUT', itemPath(result) + '?fields=parent', body, MOVE_TIMEOUT_MS);
                if (!isSuccess(moveRes)) {
                    moveError = describeError(moveRes);
                }
            } catch (CalloutException e) {
                unanswered = true;
                moveError = e.getMessage().containsIgnoreCase('timed out')
                    ? 'no reply to the move within ' + (MOVE_TIMEOUT_MS / 1000) + ' seconds'
                    : e.getMessage();
            }

            // Box's reply to the PUT isn't the proof - where the item is now is.
            readParent(result);
            if (result.finalParentId == result.targetFolderId) {
                result.outcome = Outcome.MOVED;
            } else {
                result.outcome = unanswered ? Outcome.UNCONFIRMED : Outcome.FAILED;
                result.error = moveError != null ? moveError : 'move returned success, but the ' + itemType + ' did not move';
            }
        } catch (Exception e) {
            result.outcome = unanswered ? Outcome.UNCONFIRMED : Outcome.FAILED;
            result.error = moveError != null ? moveError : e.getMessage();
        }
        return result;
    }

    /// IDs of every folder directly inside parentFolderId.
    public Set<String> listChildFolderIds(String parentFolderId) {
        Set<String> folderIds = new Set<String>();
        for (Item item : listItems(parentFolderId)) {
            if (item.type == 'folder') {
                folderIds.add(item.id);
            }
        }
        return folderIds;
    }

    /// Everything directly inside folderId. Pages by marker: "Matters (Completed)" holds 10,000+
    /// folders, and Box rejects offset paging past 10,000.
    public List<Item> listItems(String folderId) {
        List<Item> items = new List<Item>();
        String marker;
        do {
            String path = '/folders/' + folderId + '/items?fields=id,type,name&usemarker=true&limit=' + PAGE_SIZE;
            if (marker != null) {
                path += '&marker=' + EncodingUtil.urlEncode(marker, 'UTF-8');
            }
            HttpResponse res = send('GET', path, null, READ_TIMEOUT_MS);
            if (!isSuccess(res)) {
                throw new BoxApiException('Could not list ' + folderLabel(folderId) + ': ' + describeError(res));
            }

            Map<String, Object> page = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> entries = (List<Object>) page.get('entries');
            if (entries != null) {
                for (Object entry : entries) {
                    Map<String, Object> fields = (Map<String, Object>) entry;
                    Item item = new Item();
                    item.id = String.valueOf(fields.get('id'));
                    item.type = (String) fields.get('type');
                    item.name = (String) fields.get('name');
                    items.add(item);
                }
            }
            Object nextMarker = page.get('next_marker');
            marker = nextMarker == null || String.isBlank(String.valueOf(nextMarker)) ? null : String.valueOf(nextMarker);
        } while (marker != null);
        return items;
    }

    /// Saves any Box token the toolkit refreshed during this transaction. It does DML, so it must
    /// come after the transaction's last callout (Slack posts included), and it must not be
    /// skipped - a refreshed token that never gets saved can leave the Box service account logged out.
    public void commitChanges() {
        if (toolkit != null) {
            toolkit.commitChanges();
        }
    }

    private void readParent(ItemMove result) {
        HttpResponse res = send('GET', itemPath(result) + '?fields=parent', null, READ_TIMEOUT_MS);
        if (!isSuccess(res)) {
            throw new BoxApiException(describeError(res));
        }
        Map<String, Object> item = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> parent = (Map<String, Object>) item.get('parent');
        result.finalParentId = parent == null ? null : String.valueOf(parent.get('id'));
        result.finalParentName = parent == null ? null : String.valueOf(parent.get('name'));
    }

    private static String itemPath(ItemMove result) {
        return (result.itemType == 'file' ? '/files/' : '/folders/') + result.itemId;
    }

    /// Timeouts surface as a CalloutException ("Read timed out"); box.Toolkit passes setTimeout through.
    private HttpResponse send(String method, String path, String body, Integer timeoutMs) {
        HttpRequest req = new HttpRequest();
        req.setMethod(method);
        req.setEndpoint(BOX_API + path);
        req.setTimeout(timeoutMs);
        if (body != null) {
            req.setHeader('Content-Type', 'application/json');
            req.setBody(body);
        }

        Long started = System.currentTimeMillis();
        try {
            // box.Toolkit can't authenticate inside a test; tests mock the plain callout instead.
            if (Test.isRunningTest()) {
                return new Http().send(req);
            }
            if (toolkit == null) {
                toolkit = new box.Toolkit();
            }
            HttpResponse res = toolkit.sendRequest(req);
            if (res == null) {
                throw new BoxApiException(String.isNotBlank(toolkit.mostRecentError) ? toolkit.mostRecentError : 'No response from Box');
            }
            return res;
        } finally {
            calloutMillis += System.currentTimeMillis() - started;
        }
    }

    private static Boolean isSuccess(HttpResponse res) {
        return res.getStatusCode() >= 200 && res.getStatusCode() < 300;
    }

    /// "403 forbidden_by_policy: Access denied by Shield policy" from Box's error body.
    private static String describeError(HttpResponse res) {
        try {
            Map<String, Object> err = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return res.getStatusCode() + ' ' + err.get('code') + ': ' + err.get('message');
        } catch (Exception e) {
            String body = res.getBody();
            return res.getStatusCode() + (String.isBlank(body) ? '' : ' ' + body.left(300));
        }
    }
}
