/**
 * AuditLogger
 * Writes one row to Agent_Audit_Log__c for every agent action call.
 *
 * Why "without sharing": recruiters have NO access to the audit object.
 * The class runs in system mode so the row is still written.
 * CreatedById is still the real user who ran the action.
 *
 * It never throws. A failed log must never break the recruiter's request.
 */
public without sharing class AuditLogger {

    public static final String STATUS_SUCCESS = 'Success';
    public static final String STATUS_NEEDS_INPUT = 'Needs Input';
    public static final String STATUS_FAILED = 'Failed';

    public class Request {
        @InvocableVariable(label='Action' description='Name of the agent action, for example Evaluate Candidates.' required=true)
        public String actionName;

        @InvocableVariable(label='Status' description='Success, Needs Input or Failed.' required=true)
        public String status;

        @InvocableVariable(label='Inputs' description='What was passed to the action, as short text.')
        public String inputsText;

        @InvocableVariable(label='Summary' description='The result text returned to the recruiter.')
        public String summary;

        @InvocableVariable(label='Error Message' description='The error text when the status is Failed.')
        public String errorMessage;

        @InvocableVariable(label='Related Record Id' description='Id of the main record, for example a role or a bookmark.')
        public String relatedRecordId;
    }

    @InvocableMethod(
        label='Log Agent Action'
        category='CV Review'
        description='Writes one audit row for an agent action. Never fails the caller.'
    )
    public static void log(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        List<Agent_Audit_Log__c> rows = new List<Agent_Audit_Log__c>();
        for (Request r : requests) {
            if (r != null) {
                rows.add(toRow(r));
            }
        }
        if (rows.isEmpty()) {
            return;
        }
        try {
            // System mode on purpose: this org checks the user's object and field access on Apex inserts,
            // even in a "without sharing" class, and recruiters have no access to this object.
            List<Database.SaveResult> results = Database.insert(rows, false, AccessLevel.SYSTEM_MODE);
            for (Database.SaveResult sr : results) {
                if (!sr.isSuccess()) {
                    System.debug(LoggingLevel.ERROR,
                        'AuditLogger could not save a row: ' + sr.getErrors()[0].getMessage());
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AuditLogger failed: ' + e.getMessage());
        }
    }

    @TestVisible
    private static Agent_Audit_Log__c toRow(Request r) {
        Agent_Audit_Log__c row = new Agent_Audit_Log__c();
        row.Action__c = cut(String.isBlank(r.actionName) ? 'Unknown action' : r.actionName.trim(),
                            Agent_Audit_Log__c.Action__c);
        row.Inputs__c = cut(r.inputsText, Agent_Audit_Log__c.Inputs__c);
        row.Summary__c = cut(r.summary, Agent_Audit_Log__c.Summary__c);
        row.Error_Message__c = cut(r.errorMessage, Agent_Audit_Log__c.Error_Message__c);
        row.Related_Record_Id__c = cleanId(r.relatedRecordId);

        String known = knownStatus(r.status);
        if (known == null) {
            // A wrong status is a bug in the caller. Make it visible instead of losing the row.
            row.Status__c = STATUS_FAILED;
            if (String.isBlank(row.Error_Message__c)) {
                row.Error_Message__c = cut('Unknown status passed to the logger: ' + r.status,
                                           Agent_Audit_Log__c.Error_Message__c);
            }
        } else {
            row.Status__c = known;
        }
        return row;
    }

    private static String knownStatus(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String v = value.trim();
        for (String s : new List<String>{ STATUS_SUCCESS, STATUS_NEEDS_INPUT, STATUS_FAILED }) {
            if (s.equalsIgnoreCase(v)) {
                return s;
            }
        }
        return null;
    }

    private static String cleanId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return String.valueOf(Id.valueOf(value.trim()));
        } catch (Exception e) {
            return null;
        }
    }

    // Cuts the text to the real field length (read from the org), so an insert never fails on length.
    private static String cut(String value, Schema.SObjectField field) {
        if (value == null) {
            return null;
        }
        Integer max = field.getDescribe().getLength();
        if (max != null && max > 0 && value.length() > max) {
            return value.substring(0, max);
        }
        return value;
    }
}
