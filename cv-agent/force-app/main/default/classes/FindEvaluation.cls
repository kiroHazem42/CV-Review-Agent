/**
 * Finds ONE saved Evaluation per request for the "Bookmark Candidate" flow.
 *
 * The recruiter says "bookmark Maria", not an Id. This class turns what the agent sends
 * (an Evaluation Id or number, a candidate name, a role name) into exactly one Evaluation,
 * and returns its Candidate and Role too so the flow needs no extra lookups.
 *
 * When the request is unclear it returns a message (which candidate? which role?)
 * instead of guessing. Read-only (no DML). Runs with sharing and in user mode.
 *
 * Bulk-safe: all requests are read first, then at most 5 queries run for all of them together,
 * however many requests come in. No query runs inside a loop.
 */
public with sharing class FindEvaluation {

    // How many evaluations (or roles) one request looks at, newest first.
    @TestVisible private static final Integer QUERY_LIMIT = 50;
    @TestVisible private static final Integer MAX_LISTED_NAMES = 5;
    // The search queries are shared by all requests, so their limit is higher. They read small fields only.
    private static final Integer SHARED_QUERY_LIMIT = 2000;

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
        // Step 1: read every request. No query.
        List<Search> searches = new List<Search>();
        for (Request req : requests) {
            searches.add(new Search(req));
        }
        // Steps 2 to 4: the queries, once for all requests together.
        try {
            matchRoles(searches);
            matchEvaluations(searches);
            loadEvaluations(searches);
        } catch (Exception e) {
            for (Search s : searches) {
                s.res = new Result();
                s.res.message = 'The evaluation could not be read: ' + e.getMessage();
            }
        }
        for (Search s : searches) {
            results.add(s.res);
        }
        return results;
    }

    // What one request asks for, worked out from its text only.
    private class Search {
        Result res = new Result();
        Id evalId;            // the request gave an evaluation Id
        String evalNumber;    // the request gave a number like EVAL-00003
        String candText;      // candidate name as typed
        String candLike;      // candidate name without wildcards, used for the search
        String roleText;      // role name as typed
        String roleLike;      // role name without wildcards
        Set<Id> roleIds;      // roles that match roleLike (null = any role)
        Id chosenId;          // the evaluation picked by the name search

        Search(Request req) {
            String idText = req == null ? null : clean(req.evaluationId);
            candText = req == null ? null : clean(req.candidateName);
            roleText = req == null ? null : clean(req.roleName);

            if (idText != null) {
                evalId = toId(idText, Evaluation__c.SObjectType);
                if (evalId != null) {
                    return;
                }
                if (idText.toUpperCase().startsWith('EVAL-')) {
                    evalNumber = idText.toUpperCase();
                    return;
                }
                if (candText != null) {
                    res.message = 'The evaluation Id "' + idText + '" is not valid.';
                    return;
                }
                // The agent put a name in the Id input: use it as a candidate name.
                candText = idText;
            }
            candLike = likeSafe(candText);
            if (candLike == null) {
                res.message = 'Please tell me which candidate to bookmark (a name or an evaluation Id).';
                return;
            }
            roleLike = likeSafe(roleText);
        }

        // True while this request still needs the search by candidate name.
        Boolean isNameSearch() {
            return res.message == null && candLike != null;
        }
    }

    // Query 1: the roles named in the requests.
    private static void matchRoles(List<Search> searches) {
        Map<String, Object> binds = new Map<String, Object>();
        List<String> filters = new List<String>();
        for (Search s : searches) {
            if (s.isNameSearch() && s.roleLike != null) {
                String key = 'r' + filters.size();
                binds.put(key, '%' + s.roleLike + '%');
                filters.add('Name LIKE :' + key);
            }
        }
        if (filters.isEmpty()) {
            return;
        }
        // Only fixed text is added to the query string. User text goes in as bind variables.
        List<Role_c__c> roles = Database.queryWithBinds(
            'SELECT Id, Name FROM Role_c__c WHERE ' + String.join(filters, ' OR ') + ' LIMIT ' + SHARED_QUERY_LIMIT,
            binds, AccessLevel.USER_MODE);

        for (Search s : searches) {
            if (!s.isNameSearch() || s.roleLike == null) {
                continue;
            }
            s.roleIds = new Set<Id>();
            for (Role_c__c r : roles) {
                if (s.roleIds.size() < QUERY_LIMIT && r.Name != null && r.Name.containsIgnoreCase(s.roleLike)) {
                    s.roleIds.add(r.Id);
                }
            }
            if (s.roleIds.isEmpty()) {
                s.res.message = 'No role was found matching "' + s.roleText + '".';
            }
        }
    }

    // Query 2: the evaluations that match the candidate names (small fields only), newest first.
    private static void matchEvaluations(List<Search> searches) {
        Map<String, Object> binds = new Map<String, Object>();
        List<String> filters = new List<String>();
        for (Search s : searches) {
            if (!s.isNameSearch()) {
                continue;
            }
            Integer n = filters.size();
            binds.put('c' + n, '%' + s.candLike + '%');
            String filter = 'Candidate_Name__c LIKE :c' + n;
            if (s.roleIds != null) {
                binds.put('x' + n, s.roleIds);
                filter = '(' + filter + ' AND Role__c IN :x' + n + ')';
            }
            filters.add(filter);
        }
        if (filters.isEmpty()) {
            return;
        }
        List<Evaluation__c> found = Database.queryWithBinds(
            'SELECT Id, Candidate__c, Role__c, Role__r.Name, Candidate_Name__c FROM Evaluation__c WHERE '
                + String.join(filters, ' OR ') + ' ORDER BY CreatedDate DESC LIMIT ' + SHARED_QUERY_LIMIT,
            binds, AccessLevel.USER_MODE);

        for (Search s : searches) {
            if (s.isNameSearch()) {
                choose(s, found);
            }
        }
    }

    // Picks the one evaluation of a request from the shared search result, or sets a message. No query.
    private static void choose(Search s, List<Evaluation__c> found) {
        List<Evaluation__c> evals = new List<Evaluation__c>();
        for (Evaluation__c ev : found) {
            if (evals.size() == QUERY_LIMIT) {
                break;
            }
            if (ev.Candidate_Name__c != null && ev.Candidate_Name__c.containsIgnoreCase(s.candLike)
                    && (s.roleIds == null || s.roleIds.contains(ev.Role__c))) {
                evals.add(ev);
            }
        }
        if (evals.isEmpty()) {
            s.res.message = 'No evaluation was found for "' + s.candText + '"'
                + (s.roleText == null ? '' : ' and the role "' + s.roleText + '"')
                + '. Evaluate the candidate first.';
            return;
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
                if (n != null && n.equalsIgnoreCase(s.candText)) {
                    exact.add(cId);
                }
            }
            if (exact.size() != 1) {
                s.res.message = ambiguousMessage('candidates', s.candText, candidateNames.values());
                return;
            }
            chosenCandidate = exact[0];
        }

        // One role only. If the candidate was evaluated for several roles, ask which one.
        Evaluation__c latest = null;
        Map<Id, String> roleNames = new Map<Id, String>();
        Boolean hasDeletedRole = false;
        for (Evaluation__c ev : evals) {
            if (ev.Candidate__c != chosenCandidate) {
                continue;
            }
            if (latest == null) {
                // Newest evaluation first, so the first one is the latest.
                latest = ev;
            }
            if (ev.Role__c == null) {
                hasDeletedRole = true;
            } else {
                roleNames.put(ev.Role__c, ev.Role__r == null ? null : ev.Role__r.Name);
            }
        }
        if (roleNames.size() + (hasDeletedRole ? 1 : 0) > 1) {
            List<String> names = new List<String>();
            for (String roleName : roleNames.values()) {
                if (roleName != null) {
                    names.add(roleName);
                }
            }
            names.sort();
            if (hasDeletedRole) {
                names.add('(a deleted role)');
            }
            s.res.message = latest.Candidate_Name__c + ' was evaluated for several roles: '
                + String.join(names, '; ') + '. Which role do you mean?';
            return;
        }
        s.chosenId = latest.Id;
    }

    // Queries 3 to 5: the full evaluations, their candidates and their roles, for all requests together.
    private static void loadEvaluations(List<Search> searches) {
        Set<Id> evalIds = new Set<Id>();
        Set<String> evalNumbers = new Set<String>();
        for (Search s : searches) {
            if (s.res.message != null) {
                continue;
            }
            if (s.evalNumber != null) {
                evalNumbers.add(s.evalNumber);
            } else {
                evalIds.add(s.evalId != null ? s.evalId : s.chosenId);
            }
        }
        if (evalIds.isEmpty() && evalNumbers.isEmpty()) {
            return;
        }

        Map<Id, Evaluation__c> evalsById = new Map<Id, Evaluation__c>();
        Map<String, Evaluation__c> evalsByNumber = new Map<String, Evaluation__c>();
        Set<Id> candidateIds = new Set<Id>();
        Set<Id> roleIds = new Set<Id>();
        for (Evaluation__c ev : [
            SELECT Id, Name, Candidate__c, Role__c, Candidate_Name__c, Score__c, Recommendation__c,
                   Confidence__c, Reasoning__c, Gaps_And_Risks__c, CreatedDate
            FROM Evaluation__c
            WHERE Id IN :evalIds OR Name IN :evalNumbers
            WITH USER_MODE
        ]) {
            evalsById.put(ev.Id, ev);
            evalsByNumber.put(ev.Name.toUpperCase(), ev);
            candidateIds.add(ev.Candidate__c);
            if (ev.Role__c != null) {
                roleIds.add(ev.Role__c);
            }
        }
        Map<Id, Candidate_c__c> candidates = new Map<Id, Candidate_c__c>([
            SELECT Id, Name, Current_Title_c__c, Total_Years_Experience_c__c, Skills_c__c, Location_c__c
            FROM Candidate_c__c
            WHERE Id IN :candidateIds
            WITH USER_MODE
        ]);
        Map<Id, Role_c__c> roles = new Map<Id, Role_c__c>([
            SELECT Id, Name FROM Role_c__c WHERE Id IN :roleIds WITH USER_MODE
        ]);

        for (Search s : searches) {
            if (s.res.message != null) {
                continue;
            }
            Evaluation__c ev = s.evalNumber != null
                ? evalsByNumber.get(s.evalNumber)
                : evalsById.get(s.evalId != null ? s.evalId : s.chosenId);
            if (ev == null) {
                s.res.message = s.evalNumber != null
                    ? 'No evaluation was found with the number ' + s.evalNumber + '.'
                    : 'No evaluation was found with that Id.';
                continue;
            }
            Candidate_c__c cand = candidates.get(ev.Candidate__c);
            if (cand == null) {
                s.res.message = 'The candidate of this evaluation could not be read.';
                continue;
            }
            s.res.evaluation = ev;
            s.res.candidate = cand;
            s.res.role = roles.get(ev.Role__c);
        }
    }

    // ---------- Helpers ----------

    private static String clean(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    // The text to search for, or null when it is blank. Removes wildcards typed by the user.
    private static String likeSafe(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String safe = value.trim().replace('%', '').replace('_', '');
        return String.isBlank(safe) ? null : safe;
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