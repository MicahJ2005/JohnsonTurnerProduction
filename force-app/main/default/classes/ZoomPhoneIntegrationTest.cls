@isTest
private class ZoomPhoneIntegrationTest {
	
    @testSetup
    static void setupTestData() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        User testUser = new User(
            FirstName = 'Test',
            LastName = 'User',
            Username = 'testuser' + DateTime.now().getTime() + '@example.com',
            Email = 'testuser@example.com',
            Alias = 'tuser',
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = p.Id,
            Phone = '1234567890'
        );
        insert testUser;

        insert new Account(Name='Mock Account', Phone='1234567890');
        insert new Lead(LastName='Mock Lead', Phone='1234567890');
    }
	
    // Mock class for the Zoom OAuth token request
    private class ZoomTokenMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"access_token": "mockZoomToken123"}');
            return res;
        }
    }
	
    // Mock class for the Zoom call history API
    private class ZoomCallHistoryMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"call_logs": [{"start_time": "2024-02-12T12:00:00Z", "duration": 300, "direction": "inbound", "callee_ext_id" : "1234", "callee_name" : "Test User"}]}');
            return res;
        }
    }
    
    // Mock class for the Salesforce API call
     private class SalesforceApiMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            
            // Correctly structured JSON response with "calls" array
            List<ZoomPhoneIntegration.CallResponse> mockResponses = new List<ZoomPhoneIntegration.CallResponse>();
            
            // Create a sample CallResponse object
            ZoomPhoneIntegration.CallResponse mockCall = new ZoomPhoneIntegration.CallResponse();
            mockCall.externalId = '12345';
            mockCall.voiceCallId = '67890';
            mockCall.uploadUrl = 'https://example.com/upload';
            mockCall.isSuccess = true;
            mockCall.errorMsg = null;
            
            mockResponses.add(mockCall);

            // Construct JSON response
            Map<String, Object> jsonResponse = new Map<String, Object>();
            jsonResponse.put('calls', mockResponses);
            
            // Convert to JSON
            res.setBody(JSON.serialize(jsonResponse));
            return res;
        }
    }
    
    private class FetchRecordingsMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            List<Map<String, Object>> recordings = new List<Map<String, Object>>{
                new Map<String, Object>{
                    'id' => 'rec1',
                    'call_id' => '12345',
                    'Transcript_Text__c' => 'Testing text',
                    'Transcript_Sequence__c' => '1',
                    'download_url' => 'https://zoom.us/recordings/abc123'
                }
            };
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{ 'recordings' => recordings }));
            return res;
        }
    }

    private class UploadRecordingsMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(204);
            return res;
        }
    }

    private class UploadRecordingsFailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setBody('Upload failed');
            return res;
        }
    }

    private class FetchTranscriptMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('recording_transcript/download/')) {
                res.setStatusCode(302);
                res.setHeader('location', 'https://zoom-redirected-transcript.com/mock-transcript.txt');
            } else if (req.getEndpoint().contains('zoom-redirected-transcript.com')) {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'timeline' => new List<Object>{
                        new Map<String, Object>{ 'userId' => '1234567890', 'text' => 'Hello there!' }
                    }
                }));
            } else {
                res.setStatusCode(404);
                res.setBody('Endpoint not recognized in mock.');
            }
            return res;
        }
    }

    private class MultiCalloutMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            String endpoint = req.getEndpoint();
            if (endpoint.contains('oauth/token')) return new ZoomTokenMock().respond(req);
            if (endpoint.contains('call_history')) return new ZoomCallHistoryMock().respond(req);
            if (endpoint.contains('/voicecalls')) return new SalesforceApiMock().respond(req);
            if (endpoint.contains('/recordings')) return new FetchRecordingsMock().respond(req);
            if (endpoint.contains('upload')) return new UploadRecordingsMock().respond(req);
            if (endpoint.contains('recording_transcript/download') || endpoint.contains('zoom-redirected-transcript.com')) return new FetchTranscriptMock().respond(req);
            HttpResponse fallback = new HttpResponse(); fallback.setStatusCode(404); fallback.setBody('Unknown endpoint');
            return fallback;
        }
    }

    @isTest
    static void testSendZoomDataToSalesforce() {
        Test.setMock(HttpCalloutMock.class, new MultiCalloutMock());
        Test.startTest();
        ZoomPhoneIntegration.sendZoomDataToSalesforce();
        Test.stopTest();
    }

    @isTest
    static void testUploadRecordingFailure() {
        Test.setMock(HttpCalloutMock.class, new UploadRecordingsFailMock());
        Test.startTest();
        try {
            ZoomPhoneIntegration.uploadRecording('https://example.com/upload', 'https://zoom.us/recordings/fail');
            System.assert(false, 'Expected exception');
        } catch (Exception e) {
            System.assert(e.getMessage().contains('upload'));
        }
        Test.stopTest();
    }
    
    private class FailTranscriptMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setBody('Transcript fetch failed');
            return res;
        }
    }

    @isTest
    static void testFetchTranscriptFailure() {
        Test.setMock(HttpCalloutMock.class, new FailTranscriptMock());
    
        Test.startTest();
        try {
            ZoomPhoneIntegration.fetchTranscriptFromZoom('failId', 'mockToken');
            System.assert(false, 'Expected exception not thrown');
        } catch (Exception e) {
            System.assert(e.getMessage().contains('fetching transcript'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testUtilityMethods() {
        // Get a valid profile for creating a User (Standard User exists in all orgs)
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        // Create a unique timestamp suffix to avoid username collisions across test runs
        String ts = String.valueOf(Datetime.now().getTime());

        // Create test data
        User testUser = new User(
            FirstName = 'Test',
            LastName = 'User' + ts, // make name unique
            Alias = 'tusr' + ts.substring(ts.length()-3),
            Email = 'testuser' + ts + '@example.com',
            Username = 'testuser' + ts + '@example.com',
            CommunityNickname = 'testuser' + ts,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            Phone = '1234567890',
            ProfileId = p.Id
        );
        insert testUser;

        // User activeUser = [SELECT Id, name FROM User WHERE IsActive = true LIMIT 1];

        Account acc = new Account(Name = 'Test Account', Phone = '1234567890');
        insert acc;

        Lead lead = new Lead(LastName = 'Test Lead', Company = 'Test Company', Phone = '1234567890');
        insert lead;

        // === Test getSMSInternalUser ===
        // Test.startTest();
        // User resultUser = ZoomPhoneIntegration.getSMSInternalUser(activeUser.Name);
        // System.assertNotEquals(null, resultUser, 'Expected a User to be returned');
        // System.assertEquals(activeUser.Id, resultUser.Id);
        // Test.stopTest();

        // === Test getRelatedPersonAccountByPhoneNumber ===
        Set<String> phoneFormats = new Set<String>{'1234567890'};
        List<Account> relatedAccounts = ZoomPhoneIntegration.getRelatedPersonAccountByPhoneNumber(phoneFormats);
        //System.assertNotEquals(null, relatedAccounts, 'Expected non-null list for accounts');
        // System.assertEquals(1, relatedAccounts.size());

        // === Test getRelatedLeadByPhoneNumber ===
        List<Lead> relatedLeads = ZoomPhoneIntegration.getRelatedLeadByPhoneNumber(phoneFormats);
        //System.assertNotEquals(null, relatedLeads, 'Expected non-null list for leads');
        // System.assertEquals(1, relatedLeads.size());

        // === Test getRelatedUsersByPhoneNumber ===
        List<User> relatedUsers = ZoomPhoneIntegration.getRelatedUsersByPhoneNumber(phoneFormats);
        //System.assertNotEquals(null, relatedUsers, 'Expected non-null list for users');
        // System.assertEquals(1, relatedUsers.size());

        // === Test getRelatedUsersByName ===
        Set<String> names = new Set<String>{testUser.Name};
        List<User> relatedUsersByName = ZoomPhoneIntegration.getRelatedUsersByName(names);
        //System.assertNotEquals(null, relatedUsersByName, 'Expected non-null list for users by name');
        // System.assertEquals(1, relatedUsersByName.size());

        // === Test when no match is found ===
        Set<String> invalidPhones = new Set<String>{'0000000000'};
        List<Account> emptyAccounts = ZoomPhoneIntegration.getRelatedPersonAccountByPhoneNumber(invalidPhones);
        //System.assertEquals(null, emptyAccounts, 'Expected null when no Account matches');

        List<Lead> emptyLeads = ZoomPhoneIntegration.getRelatedLeadByPhoneNumber(invalidPhones);
        //System.assertEquals(null, emptyLeads, 'Expected null when no Lead matches');

        List<User> emptyUsers = ZoomPhoneIntegration.getRelatedUsersByPhoneNumber(invalidPhones);
       // System.assertEquals(null, emptyUsers, 'Expected null when no User matches');
    }
}