/// Micah Johnson - Demand Chain 2026
/// Posts to the system health Slack channel. Goes through the Slack_Post_System_Health_Message
/// flow, which uses the same "Send Message to a Slack Channel" action as the org's other Slack
/// flows. The channel ID is the System_Health_Slack_Channel_Id custom label.
///
/// A post is a callout, so callers post before their transaction's first DML (for Box work,
/// before BoxMatterFolderService.commitChanges).
public without sharing class SystemHealthSlack {

    private static final String BOX_WEB = 'https://johnsonturner.app.box.com/folder/';

    // Tests capture posts instead of sending them; one test turns capture off and points the flow
    // name at a flow that doesn't exist, to check a failed post never escapes.
    @TestVisible
    private static List<String> postedForTest = new List<String>();
    @TestVisible
    private static Boolean captureInTests = true;
    @TestVisible
    private static String flowName = 'Slack_Post_System_Health_Message';

    public static void post(String message) {
        if (Test.isRunningTest() && captureInTests) {
            postedForTest.add(message);
            return;
        }
        try {
            Flow.Interview.createInterview(flowName, new Map<String, Object>{
                'channelId' => System.Label.System_Health_Slack_Channel_Id,
                'message' => message
            }).start();
        } catch (Exception e) {
            // A Slack failure shouldn't undo the work it was reporting on.
            System.debug(LoggingLevel.ERROR, 'SystemHealthSlack: post failed - ' + e.getMessage() + '\n' + message);
        }
    }

    /// Slack treats &, < and > as markup, so names have to be escaped to show as typed.
    public static String escape(String text) {
        if (text == null) {
            return '';
        }
        return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;');
    }

    public static String recordLink(Id recordId) {
        return '<' + URL.getOrgDomainUrl().toExternalForm() + '/' + recordId + '|' + recordId + '>';
    }

    public static String boxFolderLink(String folderId) {
        return '<' + BOX_WEB + folderId + '|' + folderId + '>';
    }
}
