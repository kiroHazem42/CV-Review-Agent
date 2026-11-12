@IsTest
private class AuditLoggerTest {

    private static AuditLogger.Request req(String action, String status) {
        AuditLogger.Request r = new AuditLogger.Request();
        r.actionName = action;
        r.status = status;
        return r;
    }

    private static List<Agent_Audit_Log__c> allRows() {
        return [
            SELECT Action__c, Status__c, Inputs__c, Summary__c, Error_Message__c,
                   Related_Record_Id__c, CreatedById
            FROM Agent_Audit_Log__c
            ORDER BY CreatedDate DESC, Id DESC
        ];
    }

    @IsTest
    static void logsOneRowWithAllFields() {
        AuditLogger.Request r = req('Evaluate Candidates', 'Success');
        r.inputsText = 'role=Senior; candidates=Maria';
        r.summary = 'Maria 100 Strong';
        r.errorMessage = null;
        r.relatedRecordId = String.valueOf(UserInfo.getUserId());

        Test.startTest();
        AuditLogger.log(new List<AuditLogger.Request>{ r });
        Test.stopTest();

        List<Agent_Audit_Log__c> rows = allRows();
        Assert.areEqual(1, rows.size());
        Assert.areEqual('Evaluate Candidates', rows[0].Action__c);
        Assert.areEqual('Success', rows[0].Status__c);
        Assert.areEqual('role=Senior; candidates=Maria', rows[0].Inputs__c);
        Assert.areEqual('Maria 100 Strong', rows[0].Summary__c);
        Assert.areEqual(String.valueOf(UserInfo.getUserId()), rows[0].Related_Record_Id__c);
        Assert.areEqual(UserInfo.getUserId(), rows[0].CreatedById);
    }

    @IsTest
    static void needsInputAndFailedAreAccepted() {
        AuditLogger.Request a = req('Bookmark Candidate', 'needs input');
        AuditLogger.Request b = req('Bookmark Candidate', 'FAILED');
        b.errorMessage = 'The bookmark could not be saved: duplicate';

        AuditLogger.log(new List<AuditLogger.Request>{ a, b });

        Integer needs = [SELECT COUNT() FROM Agent_Audit_Log__c WHERE Status__c = 'Needs Input'];
        Assert.areEqual(1, needs);
        List<Agent_Audit_Log__c> failedRows = [SELECT Error_Message__c FROM Agent_Audit_Log__c WHERE Status__c = 'Failed'];
        Assert.areEqual(1, failedRows.size());
        Assert.isTrue(failedRows[0].Error_Message__c.startsWith('The bookmark could not'));
    }

    @IsTest
    static void longTextIsCutToFieldLength() {
        AuditLogger.Request r = req('Evaluate Candidates', 'Success');
        r.summary = 'x'.repeat(200000);
        r.inputsText = 'y'.repeat(200000);
        r.errorMessage = 'z'.repeat(200000);

        AuditLogger.log(new List<AuditLogger.Request>{ r });

        List<Agent_Audit_Log__c> rows = allRows();
        Assert.areEqual(1, rows.size());
        Assert.areEqual(Agent_Audit_Log__c.Summary__c.getDescribe().getLength(), rows[0].Summary__c.length());
        Assert.areEqual(Agent_Audit_Log__c.Inputs__c.getDescribe().getLength(), rows[0].Inputs__c.length());
        Assert.areEqual(Agent_Audit_Log__c.Error_Message__c.getDescribe().getLength(), rows[0].Error_Message__c.length());
    }

    @IsTest
    static void unknownOrBlankStatusBecomesFailedWithNote() {
        AuditLogger.Request a = req('Candidate Search', 'Banana');
        AuditLogger.Request b = req('Candidate Search', null);

        AuditLogger.log(new List<AuditLogger.Request>{ a, b });

        List<Agent_Audit_Log__c> rows = allRows();
        Assert.areEqual(2, rows.size());
        for (Agent_Audit_Log__c row : rows) {
            Assert.areEqual('Failed', row.Status__c);
            Assert.isTrue(row.Error_Message__c.startsWith('Unknown status passed to the logger'));
        }
    }

    @IsTest
    static void blankActionBecomesUnknownAction() {
        AuditLogger.log(new List<AuditLogger.Request>{ req('   ', 'Success') });
        Assert.areEqual('Unknown action', allRows()[0].Action__c);
    }

    @IsTest
    static void badRelatedIdIsIgnored() {
        AuditLogger.Request r = req('Candidate Search', 'Success');
        r.relatedRecordId = 'not-an-id';
        AuditLogger.log(new List<AuditLogger.Request>{ r });
        Assert.isNull(allRows()[0].Related_Record_Id__c);
    }

    @IsTest
    static void nullAndEmptyInputDoNothingAndDoNotThrow() {
        AuditLogger.log(null);
        AuditLogger.log(new List<AuditLogger.Request>());
        AuditLogger.log(new List<AuditLogger.Request>{ null });
        Assert.areEqual(0, allRows().size());
    }

    @IsTest
    static void bulkRowsAreWritten() {
        List<AuditLogger.Request> many = new List<AuditLogger.Request>();
        for (Integer i = 0; i < 50; i++) {
            many.add(req('Candidate Search', 'Success'));
        }
        AuditLogger.log(many);
        Assert.areEqual(50, allRows().size());
    }

    @IsTest
    static void worksForAUserWithNoAccessToTheAuditObject() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'audtst',
            Email = 'audit.test@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'AuditTest',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Africa/Cairo',
            UserName = 'audit.test.' + String.valueOf(System.currentTimeMillis()) + '@example.com'
        );
        insert u;

        System.runAs(u) {
            // This user must not be able to create audit rows by itself ...
            Assert.isFalse(Schema.SObjectType.Agent_Audit_Log__c.isCreateable());
            // ... but the logger still writes the row.
            AuditLogger.log(new List<AuditLogger.Request>{ req('Bookmark Candidate', 'Success') });
        }

        List<Agent_Audit_Log__c> rows = allRows();
        Assert.areEqual(1, rows.size());
        Assert.areEqual(u.Id, rows[0].CreatedById);
    }
}
