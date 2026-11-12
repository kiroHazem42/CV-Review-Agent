/**
 * Finds the Role and the Candidates that the "Evaluate Candidates" flow needs.
 *
 * Why Apex here: the recruiter (through the agent) can give an Id, a name, part of a
 * name, or nothing. Resolving that safely (exact match first, ambiguity, not-ready
 * candidates, cap of 5) is clearer and easier to unit test in code than in flow elements.
 *
 * Read-only: no DML. Runs with sharing and in user mode, so the recruiter only gets
 * records and fields they are allowed to see. The flow still does the AI call,
 * the scoring and the saving.
 */
public with sharing class ResolveEvaluationInputs {

    // Used when the recruiter names nobody: the most recent processed candidates.
    @TestVisible private static final Integer MAX_CANDIDATES = 5;
    // Used when the recruiter names the candidates (names and Ids together).
    @TestVisible private static final Integer MAX_NAMED_CANDIDATES = 10;
    @TestVisible private static final Integer MAX_LISTED_NAMES = 5;
    private static final Integer QUERY_LIMIT = 20;
    // The name search is shared by all the names of a request, so its limit is higher. It reads small fields only.
    private static final Integer SHARED_QUERY_LIMIT = 2000;
    // The most queries one request can run (1 role + 3 candidates). Used to stop before the governor limit.
    private static final Integer QUERIES_PER_REQUEST = 4;
    private static final String STATUS_DONE = 'Done';

    public class Request {
        @InvocableVariable(label='Role Id' description='The Salesforce Id of the job role. Use only if you already have it.')
        public String roleId;

        @InvocableVariable(label='Role Name' description='The role title or part of it, for example Senior Salesforce Developer. Use when the recruiter names the role.')
        public String roleName;

        @InvocableVariable(label='Candidate Id' description='The Salesforce Id of one candidate, or several Ids separated by commas. Use only if you already have them.')
        public String candidateId;

        @InvocableVariable(label='Candidate Name' description='The name or part of the name of one candidate, or several names separated by commas (for example Ahmed, Maria, Priya), up to 10. Leave empty to use the most recent processed candidates.')
        public String candidateName;
    }

    public class Result {
        @InvocableVariable(label='Message' description='Empty when the role and candidates were found. Otherwise a message for the recruiter (not found, which one do you mean, or what is missing).')
        public String message;

        @InvocableVariable(label='Role' description='The role to evaluate against. Empty when message is not empty.')
        public Role_c__c role;

        @InvocableVariable(label='Candidates' description='The candidates to evaluate: the named ones (at most 10) or the 5 most recent. Empty when message is not empty.')
        public List<Candidate_c__c> candidates;
    }

    @InvocableMethod(
        label='Resolve Role and Candidates'
        description='Finds one role and the processed candidates to compare: up to 10 named candidates (names or Ids separated by commas), or the 5 most recent when none is named. Returns a message when something is missing or unclear.'
        category='CV Review'
    )
    public static List<Result> resolve(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null) {
            return results;
        }
        for (Request req : requests) {
            results.add(resolveOne(req));
        }
        return results;
    }

    private static Result resolveOne(Request req) {
        Result res = new Result();
        res.candidates = new List<Candidate_c__c>();
        // A governor limit error cannot be caught, so stop with a clear message before reaching it.
        if (Limits.getQueries() + QUERIES_PER_REQUEST > Limits.getLimitQueries()) {
            res.message = 'Too many requests were sent in one go. Please try again with fewer.';
            return res;
        }
        try {
            Role_c__c foundRole = findRole(req, res);
            if (foundRole == null) {
                return res;
            }
            List<Candidate_c__c> foundCandidates = findCandidates(req, res);
            if (foundCandidates.isEmpty()) {
                return res;
            }
            res.role = foundRole;
            res.candidates = foundCandidates;
            res.message = null;
        } catch (Exception e) {
            // Includes missing object/field access in user mode. Keep the text plain for the recruiter.
            res.role = null;
            res.candidates = new List<Candidate_c__c>();
            res.message = 'The data could not be read: ' + e.getMessage();
        }
        return res;
    }

    // ---------- Role ----------

    private static Role_c__c findRole(Request req, Result res) {
        String idText = clean(req.roleId);
        String nameText = clean(req.roleName);

        if (String.isNotBlank(idText)) {
            Id roleRecordId = toId(idText, Role_c__c.SObjectType);
            if (roleRecordId != null) {
                List<Role_c__c> byId = [
                    SELECT Id, Name, Job_Description_c__c, Must_Haves_c__c, Nice_To_Haves_c__c, Min_Years_c__c
                    FROM Role_c__c
                    WHERE Id = :roleRecordId
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (byId.isEmpty()) {
                    res.message = 'No role was found with that Id.';
                    return null;
                }
                return byId[0];
            }
            if (String.isBlank(nameText)) {
                // The agent put a name in the Id input: use it as a name.
                nameText = idText;
            } else {
                res.message = 'The role Id "' + idText + '" is not valid.';
                return null;
            }
        }

        if (String.isBlank(nameText)) {
            res.message = 'Please tell me which role to use (name or Id).';
            return null;
        }

        String pattern = '%' + likeSafe(nameText) + '%';
        List<Role_c__c> matches = [
            SELECT Id, Name, Job_Description_c__c, Must_Haves_c__c, Nice_To_Haves_c__c, Min_Years_c__c
            FROM Role_c__c
            WHERE Name LIKE :pattern
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT :QUERY_LIMIT
        ];

        if (matches.isEmpty()) {
            res.message = 'No role was found matching "' + nameText + '". Check the name or save the role first.';
            return null;
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        List<Role_c__c> exact = new List<Role_c__c>();
        for (Role_c__c r : matches) {
            if (r.Name != null && r.Name.equalsIgnoreCase(nameText)) {
                exact.add(r);
            }
        }
        if (exact.size() == 1) {
            return exact[0];
        }
        List<String> names = new List<String>();
        for (Role_c__c r : matches) {
            names.add(r.Name);
        }
        res.message = ambiguousMessage('roles', nameText, names);
        return null;
    }

    // ---------- Candidates ----------

    private static List<Candidate_c__c> findCandidates(Request req, Result res) {
        List<String> idTexts = splitList(req.candidateId);
        List<String> nameTexts = splitList(req.candidateName);

        if (idTexts.isEmpty() && nameTexts.isEmpty()) {
            return recentCandidates(res);
        }
        if (idTexts.size() + nameTexts.size() > MAX_NAMED_CANDIDATES) {
            res.message = 'Please name at most ' + MAX_NAMED_CANDIDATES + ' candidates in one request.';
            return new List<Candidate_c__c>();
        }
        // The agent put one name in the Id input: use it as a name.
        if (nameTexts.isEmpty() && idTexts.size() == 1 && toId(idTexts[0], Candidate_c__c.SObjectType) == null) {
            nameTexts = idTexts;
            idTexts = new List<String>();
        }

        // The queries run once for all Ids and once for all names, never inside a loop.
        Map<Id, Candidate_c__c> byId = candidatesById(idTexts);
        Map<String, List<Candidate_c__c>> byName = candidatesByName(nameTexts);

        // All or nothing: if one candidate cannot be resolved, its message is returned and nobody is evaluated.
        List<Candidate_c__c> found = new List<Candidate_c__c>();
        Set<Id> seen = new Set<Id>();
        for (String idText : idTexts) {
            Id candRecordId = toId(idText, Candidate_c__c.SObjectType);
            if (candRecordId == null) {
                res.message = 'The candidate Id "' + idText + '" is not valid.';
                return new List<Candidate_c__c>();
            }
            Candidate_c__c cand = byId.get(candRecordId);
            if (cand == null) {
                res.message = 'No candidate was found with that Id.';
                return new List<Candidate_c__c>();
            }
            List<Candidate_c__c> one = readyOrMessage(cand, res);
            if (one.isEmpty()) {
                return one;
            }
            if (seen.add(one[0].Id)) {
                found.add(one[0]);
            }
        }
        for (String nameText : nameTexts) {
            List<Candidate_c__c> one = pickByName(nameText, byName.get(nameText), res);
            if (one.isEmpty()) {
                return one;
            }
            if (seen.add(one[0].Id)) {
                found.add(one[0]);
            }
        }
        return found;
    }

    // One query for all the Ids. Texts that are not candidate Ids are skipped here and reported by the caller.
    private static Map<Id, Candidate_c__c> candidatesById(List<String> idTexts) {
        Set<Id> ids = new Set<Id>();
        for (String idText : idTexts) {
            Id candRecordId = toId(idText, Candidate_c__c.SObjectType);
            if (candRecordId != null) {
                ids.add(candRecordId);
            }
        }
        if (ids.isEmpty()) {
            return new Map<Id, Candidate_c__c>();
        }
        return new Map<Id, Candidate_c__c>([
            SELECT Id, Name, Total_Years_Experience_c__c, Candidate_Card_c__c, Current_Title_c__c, Extraction_Status_c__c
            FROM Candidate_c__c
            WHERE Id IN :ids
            WITH USER_MODE
        ]);
    }

    // Two queries for all the names together: a small one that finds the matches (newest first),
    // then one that loads the cards of only those matches. Returns the matches of each name.
    private static Map<String, List<Candidate_c__c>> candidatesByName(List<String> nameTexts) {
        Map<String, List<Candidate_c__c>> byName = new Map<String, List<Candidate_c__c>>();
        if (nameTexts.isEmpty()) {
            return byName;
        }
        // Only fixed text is added to the query string. User text goes in as bind variables.
        Map<String, Object> binds = new Map<String, Object>{ 'statusDone' => STATUS_DONE };
        List<String> filters = new List<String>();
        for (String nameText : nameTexts) {
            String key = 'n' + filters.size();
            binds.put(key, '%' + likeSafe(nameText) + '%');
            filters.add('Name LIKE :' + key);
        }
        List<Candidate_c__c> light = Database.queryWithBinds(
            'SELECT Id, Name FROM Candidate_c__c WHERE Extraction_Status_c__c = :statusDone AND ('
                + String.join(filters, ' OR ') + ') ORDER BY CreatedDate DESC LIMIT ' + SHARED_QUERY_LIMIT,
            binds, AccessLevel.USER_MODE);

        // The newest QUERY_LIMIT matches of each name.
        Map<String, List<Id>> idsByName = new Map<String, List<Id>>();
        Set<Id> wanted = new Set<Id>();
        for (String nameText : nameTexts) {
            String text = likeSafe(nameText);
            List<Id> ids = new List<Id>();
            for (Candidate_c__c c : light) {
                if (ids.size() == QUERY_LIMIT) {
                    break;
                }
                if (c.Name != null && c.Name.containsIgnoreCase(text)) {
                    ids.add(c.Id);
                }
            }
            idsByName.put(nameText, ids);
            wanted.addAll(ids);
        }

        Map<Id, Candidate_c__c> full = new Map<Id, Candidate_c__c>([
            SELECT Id, Name, Total_Years_Experience_c__c, Candidate_Card_c__c, Current_Title_c__c, Extraction_Status_c__c
            FROM Candidate_c__c
            WHERE Id IN :wanted
            WITH USER_MODE
        ]);
        for (String nameText : nameTexts) {
            List<Candidate_c__c> matches = new List<Candidate_c__c>();
            for (Id candId : idsByName.get(nameText)) {
                if (full.containsKey(candId)) {
                    matches.add(full.get(candId));
                }
            }
            byName.put(nameText, matches);
        }
        return byName;
    }

    // Picks the one candidate a name means from its matches, or sets a message. No query.
    private static List<Candidate_c__c> pickByName(String nameText, List<Candidate_c__c> matches, Result res) {
        List<Candidate_c__c> withCard = new List<Candidate_c__c>();
        for (Candidate_c__c c : matches) {
            if (String.isNotBlank(c.Candidate_Card_c__c)) {
                withCard.add(c);
            }
        }
        if (withCard.isEmpty()) {
            res.message = 'No processed candidate was found matching "' + nameText + '".';
            return new List<Candidate_c__c>();
        }
        if (withCard.size() == 1) {
            return withCard;
        }
        List<Candidate_c__c> exact = new List<Candidate_c__c>();
        for (Candidate_c__c c : withCard) {
            if (c.Name != null && c.Name.equalsIgnoreCase(nameText)) {
                exact.add(c);
            }
        }
        if (exact.size() == 1) {
            return exact;
        }
        List<String> names = new List<String>();
        for (Candidate_c__c c : withCard) {
            names.add(c.Name);
        }
        res.message = ambiguousMessage('candidates', nameText, names);
        return new List<Candidate_c__c>();
    }

    private static List<Candidate_c__c> recentCandidates(Result res) {
        // Candidate_Card_c__c is Long Text, so it cannot be filtered in SOQL: filter in Apex.
        List<Candidate_c__c> rows = [
            SELECT Id, Name, Total_Years_Experience_c__c, Candidate_Card_c__c, Current_Title_c__c, Extraction_Status_c__c
            FROM Candidate_c__c
            WHERE Extraction_Status_c__c = :STATUS_DONE
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT :QUERY_LIMIT
        ];
        List<Candidate_c__c> picked = new List<Candidate_c__c>();
        for (Candidate_c__c c : rows) {
            if (String.isNotBlank(c.Candidate_Card_c__c)) {
                picked.add(c);
                if (picked.size() == MAX_CANDIDATES) {
                    break;
                }
            }
        }
        if (picked.isEmpty()) {
            res.message = 'There are no processed candidates yet. Upload CVs and wait until their status is Done.';
        }
        return picked;
    }

    private static List<Candidate_c__c> readyOrMessage(Candidate_c__c cand, Result res) {
        if (cand.Extraction_Status_c__c != STATUS_DONE) {
            res.message = cand.Name + ' is not ready (status: ' + cand.Extraction_Status_c__c
                + '). Only candidates with status Done can be evaluated.';
            return new List<Candidate_c__c>();
        }
        if (String.isBlank(cand.Candidate_Card_c__c)) {
            res.message = cand.Name + ' has no Candidate Card yet, so there is nothing to evaluate.';
            return new List<Candidate_c__c>();
        }
        return new List<Candidate_c__c>{ cand };
    }

    // ---------- Helpers ----------

    private static String clean(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    // "Ahmed, Maria; Priya" -> (Ahmed, Maria, Priya). Blank parts are dropped.
    private static List<String> splitList(String value) {
        List<String> parts = new List<String>();
        if (String.isBlank(value)) {
            return parts;
        }
        for (String part : value.split('[,;]')) {
            if (String.isNotBlank(part)) {
                parts.add(part.trim());
            }
        }
        return parts;
    }

    // Remove LIKE wildcards typed by the user so they cannot widen the search.
    private static String likeSafe(String value) {
        return value.replace('%', '').replace('_', '');
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