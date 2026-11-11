@isTest
private class ZoomPhoneIntegrationRedirectTest {

    // Phone transcript download that redirects with a configurable header name (null = no header).
    class MockPhoneTranscriptRedirect implements HttpCalloutMock {
        String headerName;
        MockPhoneTranscriptRedirect(String headerName) {
            this.headerName = headerName;
        }
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('zoom-redirected-transcript.com')) {
                res.setStatusCode(200);
                res.setBody('{"timeline":[]}');
            } else {
                res.setStatusCode(302);
                if (headerName != null) {
                    res.setHeader(headerName, 'https://zoom-redirected-transcript.com/mock-transcript.txt');
                }
            }
            return res;
        }
    }

    @isTest
    static void testFetchTranscriptFollowsCapitalizedLocationHeader() {
        // A 'location'-only lookup returned null when Zoom sent "Location", failing 108 phone
        // transcript downloads on 10/13/2026.
        Test.setMock(HttpCalloutMock.class, new MockPhoneTranscriptRedirect('Location'));

        Test.startTest();
        String body = ZoomPhoneIntegration.fetchTranscriptFromZoom('recording123', 'mockToken');
        Test.stopTest();

        System.assertEquals('{"timeline":[]}', body, 'The redirect should be followed when the header is "Location"');
    }

    @isTest
    static void testFetchTranscriptStillFollowsLowercaseLocationHeader() {
        Test.setMock(HttpCalloutMock.class, new MockPhoneTranscriptRedirect('location'));

        Test.startTest();
        String body = ZoomPhoneIntegration.fetchTranscriptFromZoom('recording123', 'mockToken');
        Test.stopTest();

        System.assertEquals('{"timeline":[]}', body, 'The redirect should still be followed when the header is "location"');
    }

    @isTest
    static void testFetchTranscriptThrowsClearErrorWhenRedirectHasNoLocation() {
        Test.setMock(HttpCalloutMock.class, new MockPhoneTranscriptRedirect(null));

        String message;
        Test.startTest();
        try {
            ZoomPhoneIntegration.fetchTranscriptFromZoom('recording123', 'mockToken');
        } catch (CalloutException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        System.assert(message != null && message.contains('no Location header'), 'Expected a descriptive error, got: ' + message);
    }
}
