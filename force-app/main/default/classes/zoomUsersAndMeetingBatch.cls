public with sharing class zoomUsersAndMeetingBatch implements Database.Batchable<SObject>, Database.AllowsCallouts{
    private String token;
    private String queueId;
    // Backfill mode (see ZoomMeetingTranscriptService.backfill): replayDate is the local day being
    // re-imported and replayThroughDate the last day to replay. Both are null on the scheduled run.
    private Date replayDate;
    private Date replayThroughDate;
    public map<String, User> zoomUserIdsToUserMap;
    public Map<String,List<ZoomMeetingTranscriptService.RecordingFile>> userToTranscriptFileMap;

    public zoomUsersAndMeetingBatch(String token, string queueId) {
            this.token = token;
            this.queueId = queueId;
            this.userToTranscriptFileMap = userToTranscriptFileMap;
    }

    public zoomUsersAndMeetingBatch(String token, String queueId, Date replayDate, Date replayThroughDate) {
        this(token, queueId);
        this.replayDate = replayDate;
        this.replayThroughDate = replayThroughDate;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {

        if(Test.isRunningTest()){
            return Database.getQueryLocator([SELECT Id, Name, Zoom_User_Id__c
            FROM User
            WHERE IsActive = true
            AND Zoom_User_Id__c != null LIMIT 1]);
        }
        // Get Zoom User Id's in SF
        return Database.getQueryLocator([SELECT Id, Name, Zoom_User_Id__c
        FROM User
        WHERE IsActive = true
        AND Zoom_User_Id__c != null]);
    }
    public void execute(Database.BatchableContext bc, List<SObject> scope) {

        map<String, User> zoomUserIdsToUserMap = new map<String, User>();
        set<string> userIds = new set<string>(); 
        Map<string, Event> zoomIdToUserMap = new Map<string, Event>();
        // build zoomUserIdsToUserMap
        for(SObject u : scope){
            System.debug('scope: '+u);
            User uu = (User)u;
            System.debug('uu.Zoom_User_Id__c: '+uu.Zoom_User_Id__c);
            if(!zoomUserIdsToUserMap.containsKey(uu.Zoom_User_Id__c)){
                zoomUserIdsToUserMap.put(uu.Zoom_User_Id__c,uu);
                userIds.add(uu.Id);
            }
        }
        System.debug('zoomUserIdsToUserMap: '+zoomUserIdsToUserMap);
        
        zoomIdToUserMap = getUserEvents(userIds, replayDate != null ? replayDate : Date.today());
        System.debug('zoomIdToUserMap: '+zoomIdToUserMap);
        // Get all the Zoom Users associated with the SF Users)

        // Fetch Recent Zoom Meetings
        // Map<String,List<ZoomMeetingTranscriptService.RecordingFile>>
        userToTranscriptFileMap = replayDate == null
            ? ZoomMeetingTranscriptService.getRecentMeetings(token, zoomUserIdsToUserMap)
            : ZoomMeetingTranscriptService.getMeetingsForDate(token, zoomUserIdsToUserMap, replayDate);
        System.debug('userToTranscriptFileMap: '+userToTranscriptFileMap);

        // Each recording file's transcript is fetched and inserted in its own chained Queueable
        // transaction (see ZoomTranscriptFetchQueueable) instead of looping through them here.
        // Salesforce enforces a 120s *cumulative* callout timeout per transaction, so processing
        // several large transcripts back-to-back in one execute() could still time out even with
        // each individual callout's timeout maxed out - isolating each file into its own
        // transaction gives it a fresh callout/heap budget.
        List<ZoomTranscriptFetchQueueable.TranscriptJob> jobs = new List<ZoomTranscriptFetchQueueable.TranscriptJob>();

        for(string key: userToTranscriptFileMap.keySet()){
            List<String> parts = key.split('#');
            String zoomId = parts.size() > 0 ? parts[0] : '';
            String zoomMeetingId = parts.size() > 1 ? parts[1] : '';
            for(ZoomMeetingTranscriptService.RecordingFile file: userToTranscriptFileMap.get(key)){
                jobs.add(new ZoomTranscriptFetchQueueable.TranscriptJob(zoomId, zoomMeetingId, file));
            }
        }

        if(!jobs.isEmpty()){
            System.enqueueJob(new ZoomTranscriptFetchQueueable(token, queueId, zoomUserIdsToUserMap, zoomIdToUserMap, jobs, replayDate));
        }
    }
    public void finish(Database.BatchableContext bc) {
        System.debug('Batch job completed.');
        System.debug('FINISH userToTranscriptFileMap: '+userToTranscriptFileMap);
        System.debug('FINISH token: '+token);
        // Database.executeBatch(new ProcessZoomTranscriptsBatch(token, userToTranscriptFileMap), 1);

        // Backfill: replay the next day with a fresh token - Zoom tokens expire after an hour, so a
        // multi-day replay can't share the one it started with.
        if (replayDate != null && replayDate < replayThroughDate) {
            Database.executeBatch(new zoomUsersAndMeetingBatch(
                ZoomMeetingTranscriptService.getConfiguredZoomToken(), queueId, replayDate.addDays(1), replayThroughDate), 1);
        }
    }

     public static Map<string, Event> getUserEvents(Set<String> userIds) {
        return getUserEvents(userIds, Date.today());
     }

     public static Map<string, Event> getUserEvents(Set<String> userIds, Date onDate) {
        system.debug('IN getUserEvents - ' +userIds);
        List<Event> events = [SELECT Id, OwnerId, Owner.Name, CreatedDate, WhoId, Who.name, WhatId, What.name, Description, Subject, AccountId FROM Event WHERE OwnerId IN: userIds AND EndDate = :onDate];
        Map<string, Event> zoomIdToUserMap = new Map<string, Event>();
        if(events.size() > 0){
            for(Event a: events){
                system.debug('events--'+a.Who.name);
                system.debug('events--'+a.What.name);
                system.debug('events AccountId--'+a.AccountId);
                system.debug('events Subject--'+a.Subject);
                // Pattern 2: From "Meeting ID: 818 3207 1679"
                if(a.Description != null){
                    system.debug('events Description--'+a.Description);
                    Pattern textPattern = Pattern.compile('Meeting ID:\\s*(\\d{3})\\s*(\\d{4})\\s*(\\d{4})');
                    Matcher textMatcher = textPattern.matcher(a.Description);
                    if (textMatcher.find()) {
                        system.debug('###1 - '+textMatcher.group(1));
                        system.debug('###2 - '+textMatcher.group(2));
                        system.debug('###3 - '+textMatcher.group(3));
                        zoomIdToUserMap.put(textMatcher.group(1) + '' + textMatcher.group(2) + '' + textMatcher.group(3), a);
                        // return textMatcher.group(1) + textMatcher.group(2) + textMatcher.group(3);
                    }
                }
            }
        }
        return zoomIdToUserMap;
    }

}