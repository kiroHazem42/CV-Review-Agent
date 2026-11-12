/**
 * Finds ONE saved Evaluation for the "Bookmark Candidate" flow.
 *
 * The recruiter says "bookmark Maria", not an Id. This class turns what the agent sends
 * (an Evaluation Id or number, a candidate name, a role name) into exactly one Evaluation,
 * and returns its Candidate and Role too so the flow needs no extra lookups.
 *
 * When the request is unclear it returns a message (which candidate? which role?)
 * instead of guessing. Read-only (no DML). Runs with sharing and in user mode.
 */
public with sharing class FindEvaluation {

    @TestVisible private static final Integer QUERY_LIMIT = 50;
    @TestVisible private static final Integer MAX_LISTED_NAMES = 5;

    public class Request {
        @InvocableVariable(label='Evaluation Id' description='The Id (or the number like EVAL-00003) of a saved evaluation. Use only if you already have it.')
        public String evaluationId;

        @InvocableVariable(label='Candidate Name' description='The name or part of the name of the candidate to bookmark.')
        public String candidateName;

        @InvocableVariable(label='Role Name' description='The role the candidate was evaluated for, or part of its title. Leave empty if only one role was evaluated.')
        public String roleName;
    }

    public class Result {
        @InvocableVariable(label='Message' description='Empty when one evaluation was found. Otherwise a message for the recruiter (not found, which one do you mean).')
        public String message;

        @InvocableVariable(label='Evaluation' description='The evaluation to bookmark. Empty when message is not empty.')
        public Evaluation__c evaluation;

        @InvocableVariable(label='Candidate' description='The candidate of that evaluation.')
        public Candidate_c__c candidate;

        @InvocableVariable(label='Role' description='The role of that evaluation. Empty if the role was deleted.')
        public Role_c__c role;
    }

    @InvocableMethod(
        label='Find Evaluation'
        description='Finds the latest saved evaluation of one candidate for one role, from an evaluation Id or number, or from a candidate name and a role name.'
        category='CV Review'
    )
    public static List<Result> find(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null) {
            return results;
        }
        for (Request req : requests) {
            results.add(findOne(req));
        }
        return results;
    }

    private static Result findOne(Request req) {
        Result res = new Result();
        try {
            String idText = clean(req.evaluationId);
            String candText = clean(req.candidateName);
            String roleText = clean(req.roleName);

            if (idText != null) {
                Id evalId = toId(idText, Evaluation__c.SObjectType);
                if (evalId != null) {
                    List<Evaluation__c> byId = [
                        SELECT Id, Name, Candidate__c, Role__c, Candidate_Name__c, Score__c, Recommendation__c,
                               Confidence__c, Reasoning__c, Gaps_And_Risks__c, CreatedDate
                        FROM Evaluation__c
                        WHERE Id = :evalId
                        WITH USER_MODE
                        LIMIT 1
                    ];
                    if (byId.isEmpty()) {
                        res.message = 'No evaluation was found with that Id.';
                        return res;
                    }
                    return fill(res, byId[0]);
                }
                if (idText.toUpperCase().startsWith('EVAL-')) {
                    String evalNumber = idText.toUpperCase();
                    List<Evaluation__c> byNumber = [
                        SELECT Id, Name, Candidate__c, Role__c, Candidate_Name__c, Score__c, Recommendation__c,
                               Confidence__c, Reasoning__c, Gaps_And_Risks__c, CreatedDate
                        FROM Evaluation__c
                        WHERE Name = :evalNumber
                        WITH USER_MODE
                        LIMIT 1
                    ];
                    if (byNumber.isEmpty()) {
                        res.message = 'No evaluation was found with the number ' + evalNumber + '.';
                        return res;
                    }
                    return fill(res, byNumber[0]);
                }
                if (candText == null) {
                    // The agent put a name in the Id input: use it as a candidate name.
                    candText = idText;
                } else {
                    res.message = 'The evaluation Id "' + idText + '" is not valid.';
                    return res;
                }
            }

            String candPattern = pattern(candText);
            if (candPattern == null) {
                res.message = 'Please tell me which candidate to bookmark (a name or an evaluation Id).';
                return res;
            }

            Set<Id> roleIds = null;
            if (roleText != null) {
                String rolePattern = pattern(roleText);
                if (rolePattern != null) {
                    List<Role_c__c> roles = [
                        SELECT Id, Name FROM Role_c__c
                        WHERE Name LIKE :rolePattern
                        WITH USER_MODE
                        LIMIT :QUERY_LIMIT
                    ];
                    if (roles.isEmpty()) {
                        res.message = 'No role was found matching "' + roleText + '".';
                        return res;
                    }
                    roleIds = new Map<Id, Role_c__c>(roles).keySet();
                }
            }

            List<Evaluation__c> evals;
            if (roleIds == null) {
                evals = [
                    SELECT Id, Name, Candidate__c, Role__c, Candidate_Name__c, Score__c, Recommendation__c,
                           Confidence__c, Reasoning__c, Gaps_And_Risks__c, CreatedDate
                    FROM Evaluation__c
                    WHERE Candidate_Name__c LIKE :candPattern
                    WITH USER_MODE
                    ORDER BY CreatedDate DESC
                    LIMIT :QUERY_LIMIT
                ];
            } else {
                evals = [
                    SELECT Id, Name, Candidate__c, Role__c, Candidate_Name__c, Score__c, Recommendation__c,
                           Confidence__c, Reasoning__c, Gaps_And_Risks__c, CreatedDate
                    FROM Evaluation__c
                    WHERE Candidate_Name__c LIKE :candPattern AND Role__c IN :roleIds
                    WITH USER_MODE
                    ORDER BY CreatedDate DESC
                    LIMIT :QUERY_LIMIT
                ];
            }

            if (evals.isEmpty()) {
                res.message = 'No evaluation was found for "' + candText + '"'
                    + (roleText == null ? '' : ' and the role "' + roleText + '"')
                    + '. Evaluate the candidate first.';
                return res;
            }

            // One candidate only. If several candidates match, an exact name wins, else ask.
            Map<Id, String> candidateNames = new Map<Id, String>();
            for (Evaluation__c ev : evals) {
                if (!candidateNames.containsKey(ev.Candidate__c)) {
                    candidateNames.put(ev.Candidate__c, ev.Candidate_Name__c);
                }
            }
            Id chosenCandidate = null;
            if (candidateNames.size() == 1) {
                chosenCandidate = new List<Id>(candidateNames.keySet())[0];
            } else {
                List<Id> exact = new List<Id>();
                for (Id cId : candidateNames.keySet()) {
                    String n = candidateNames.get(cId);
                    if (n != null && n.equalsIgnoreCase(candText)) {
                        exact.add(cId);
                    }
                }
                if (exact.size() == 1) {
                    chosenCandidate = exact[0];
                } else {
                    res.message = ambiguousMessage('candidates', candText, candidateNames.values());
                    return res;
                }
            }

            List<Evaluation__c> candidateEvals = new List<Evaluation__c>();
            Set<Id> distinctRoles = new Set<Id>();
            Boolean hasDeletedRole = false;
            for (Evaluation__c ev : evals) {
                if (ev.Candidate__c == chosenCandidate) {
                    candidateEvals.add(ev);
                    if (ev.Role__c == null) {
                        hasDeletedRole = true;
                    } else {
                        distinctRoles.add(ev.Role__c);
                    }
                }
            }

            Integer roleKinds = distinctRoles.size() + (hasDeletedRole ? 1 : 0);
            if (roleKinds > 1) {
                List<String> roleNames = new List<String>();
                for (Role_c__c r : [SELECT Name FROM Role_c__c WHERE Id IN :distinctRoles WITH USER_MODE ORDER BY Name]) {
                    roleNames.add(r.Name);
                }
                if (hasDeletedRole) {
                    roleNames.add('(a deleted role)');
                }
                res.message = candidateEvals[0].Candidate_Name__c + ' was evaluated for several roles: '
                    + String.join(roleNames, '; ') + '. Which role do you mean?';
                return res;
            }

            // Newest evaluation first, so index 0 is the latest.
            return fill(res, candidateEvals[0]);
        } catch (Exception e) {
            res.evaluation = null;
            res.candidate = null;
            res.role = null;
            res.message = 'The evaluation could not be read: ' + e.getMessage();
            return res;
        }
    }

    // Loads the Candidate and Role of an evaluation and completes the result.
    private static Result fill(Result res, Evaluation__c ev) {
        List<Candidate_c__c> cands = [
            SELECT Id, Name, Current_Title_c__c, Total_Years_Experience_c__c, Skills_c__c, Location_c__c
            FROM Candidate_c__c
            WHERE Id = :ev.Candidate__c
            WITH USER_MODE
            LIMIT 1
        ];
        if (cands.isEmpty()) {
            res.message = 'The candidate of this evaluation could not be read.';
            return res;
        }
        Role_c__c foundRole = null;
        if (ev.Role__c != null) {
            List<Role_c__c> roles = [
                SELECT Id, Name FROM Role_c__c WHERE Id = :ev.Role__c WITH USER_MODE LIMIT 1
            ];
            if (!roles.isEmpty()) {
                foundRole = roles[0];
            }
        }
        res.evaluation = ev;
        res.candidate = cands[0];
        res.role = foundRole;
        res.message = null;
        return res;
    }

    // ---------- Helpers ----------

    private static String clean(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    // LIKE pattern, or null when the text is blank. Removes wildcards typed by the user.
    private static String pattern(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String safe = value.trim().replace('%', '').replace('_', '');
        return String.isBlank(safe) ? null : '%' + safe + '%';
    }

    private static Id toId(String value, Schema.SObjectType expectedType) {
        try {
            Id parsed = Id.valueOf(value);
            return parsed.getSobjectType() == expectedType ? parsed : null;
        } catch (StringException e) {
            return null;
        }
    }

    private static String ambiguousMessage(String plural, String searchText, List<String> names) {
        List<String> shown = new List<String>();
        for (Integer i = 0; i < names.size() && i < MAX_LISTED_NAMES; i++) {
            shown.add(names[i]);
        }
        String more = names.size() > MAX_LISTED_NAMES ? ' and more' : '';
        return 'I found ' + names.size() + ' ' + plural + ' matching "' + searchText + '": '
            + String.join(shown, '; ') + more + '. Which one do you mean?';
    }
}
