/**
 * Finds processed candidates by simple rules (name, skill, minimum years, location).
 * No AI is used: this is a fast search for questions like
 * "find all candidates with at least 10 years of experience".
 *
 * Read-only (no DML). Runs with sharing and in user mode, so the recruiter only gets
 * records and fields they are allowed to see.
 *
 * Years are stored as Text on the Candidate, so SOQL cannot compare them as numbers.
 * The class reads them into numbers in Apex and filters there.
 */
public with sharing class FindCandidates {

    @TestVisible private static final Integer DEFAULT_MAX_RESULTS = 25;
    @TestVisible private static final Integer HARD_MAX_RESULTS = 50;
    @TestVisible private static final Integer MAX_RESULTS_WITH_CARDS = 8;
    @TestVisible private static final Integer QUERY_LIMIT = 200;
    private static final String STATUS_DONE = 'Done';

    public class Request {
        @InvocableVariable(label='Candidate Name' description='Part of the candidate name. Leave empty for any name.')
        public String name;

        @InvocableVariable(label='Skill' description='A skill the candidate must have, for example LWC. Leave empty for any skill.')
        public String skill;

        @InvocableVariable(label='Minimum Years' description='Minimum years of experience, for example 10 means 10 or more. Leave empty for any.')
        public Decimal minYears;

        @InvocableVariable(label='Location' description='Part of the city or country, for example Madrid. Leave empty for any location.')
        public String location;

        @InvocableVariable(label='Max Results' description='How many candidates to return. Default 25, maximum 50.')
        public Integer maxResults;

        @InvocableVariable(label='Include Cards' description='True to include each Candidate Card text, so questions can be answered from the CV. Limits the result to 8 candidates.')
        public Boolean includeCards;
    }

    public class Result {
        @InvocableVariable(label='Message' description='Empty when candidates were found. Otherwise a short explanation for the recruiter.')
        public String message;

        @InvocableVariable(label='Result Text' description='The list of matching candidates (name, Id, years, title, location) and a summary line. Show this to the recruiter.')
        public String resultText;

        @InvocableVariable(label='Candidates' description='The matching candidates that are returned.')
        public List<Candidate_c__c> candidates;

        @InvocableVariable(label='Total Matched' description='How many candidates matched the rules in total, before the result limit.')
        public Integer totalMatched;
    }

    @InvocableMethod(
        label='Find Candidates'
        description='Finds processed candidates by name, skill, minimum years of experience or location. Does not use AI.'
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
        res.candidates = new List<Candidate_c__c>();
        res.totalMatched = 0;
        try {
            if (req.minYears != null && req.minYears < 0) {
                res.message = 'Minimum years cannot be negative.';
                return res;
            }

            Boolean withCards = req.includeCards == true;
            Integer maxResults = effectiveMax(req.maxResults, withCards);

            String namePattern = pattern(req.name);
            String skillPattern = pattern(req.skill);
            String locationPattern = pattern(req.location);

            List<Candidate_c__c> rows = query(namePattern, skillPattern, locationPattern, withCards);

            List<Row> matched = new List<Row>();
            Integer unknownYears = 0;
            for (Candidate_c__c c : rows) {
                Decimal years = parseYears(c.Total_Years_Experience_c__c);
                if (req.minYears != null) {
                    if (years == null) {
                        unknownYears++;
                        continue;
                    }
                    if (years < req.minYears) {
                        continue;
                    }
                }
                matched.add(new Row(c, years));
            }
            matched.sort();

            res.totalMatched = matched.size();
            if (matched.isEmpty()) {
                res.message = 'No processed candidates match: ' + describeFilters(req) + '.'
                    + unknownNote(unknownYears);
                return res;
            }

            Integer shown = Math.min(maxResults, matched.size());
            List<String> lines = new List<String>();
            for (Integer i = 0; i < shown; i++) {
                Row row = matched[i];
                res.candidates.add(row.cand);
                lines.add(formatLine(i + 1, row, withCards));
            }

            String summary = 'Showing ' + shown + ' of ' + matched.size() + ' matching candidates ('
                + describeFilters(req) + ', most years first).'
                + unknownNote(unknownYears);
            if (rows.size() >= QUERY_LIMIT) {
                summary += ' Only the ' + QUERY_LIMIT + ' newest processed candidates were checked.';
            }
            res.resultText = String.join(lines, '\n') + '\n' + summary;
            res.message = null;
        } catch (Exception e) {
            res.candidates = new List<Candidate_c__c>();
            res.totalMatched = 0;
            res.resultText = null;
            res.message = 'The candidates could not be searched: ' + e.getMessage();
        }
        return res;
    }

    // ---------- Query ----------

    private static List<Candidate_c__c> query(String namePattern, String skillPattern, String locationPattern, Boolean withCards) {
        String fields = 'Id, Name, Current_Title_c__c, Location_c__c, Skills_c__c, '
            + 'Total_Years_Experience_c__c, Extraction_Status_c__c';
        if (withCards) {
            fields += ', Candidate_Card_c__c';
        }
        // Only fixed text is added to the query string. User text goes in as bind variables.
        String soql = 'SELECT ' + fields + ' FROM Candidate_c__c WHERE Extraction_Status_c__c = :statusDone';
        Map<String, Object> binds = new Map<String, Object>{ 'statusDone' => STATUS_DONE };
        if (namePattern != null) {
            soql += ' AND Name LIKE :namePattern';
            binds.put('namePattern', namePattern);
        }
        if (skillPattern != null) {
            soql += ' AND Skills_c__c LIKE :skillPattern';
            binds.put('skillPattern', skillPattern);
        }
        if (locationPattern != null) {
            soql += ' AND Location_c__c LIKE :locationPattern';
            binds.put('locationPattern', locationPattern);
        }
        soql += ' ORDER BY CreatedDate DESC LIMIT ' + QUERY_LIMIT;

        List<Candidate_c__c> rows = new List<Candidate_c__c>();
        for (SObject so : Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE)) {
            rows.add((Candidate_c__c) so);
        }
        return rows;
    }

    // ---------- Sorting wrapper: most years first, unknown years last ----------

    private class Row implements Comparable {
        public Candidate_c__c cand;
        public Decimal years;

        public Row(Candidate_c__c cand, Decimal years) {
            this.cand = cand;
            this.years = years;
        }

        public Integer compareTo(Object other) {
            Row o = (Row) other;
            if (years == null && o.years == null) {
                return 0;
            }
            if (years == null) {
                return 1;
            }
            if (o.years == null) {
                return -1;
            }
            if (years == o.years) {
                return 0;
            }
            return years > o.years ? -1 : 1;
        }
    }

    // ---------- Helpers ----------

    private static Integer effectiveMax(Integer requested, Boolean withCards) {
        Integer value = (requested == null || requested < 1) ? DEFAULT_MAX_RESULTS : requested;
        value = Math.min(value, HARD_MAX_RESULTS);
        if (withCards) {
            value = Math.min(value, MAX_RESULTS_WITH_CARDS);
        }
        return value;
    }

    // Returns a LIKE pattern, or null when the text is blank. Removes wildcards typed by the user.
    private static String pattern(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String safe = value.trim().replace('%', '').replace('_', '');
        return String.isBlank(safe) ? null : '%' + safe + '%';
    }

    private static Decimal parseYears(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Decimal.valueOf(value.trim());
        } catch (TypeException e) {
            return null;
        }
    }

    private static String formatLine(Integer position, Row row, Boolean withCards) {
        Candidate_c__c c = row.cand;
        String yearsText = row.years == null ? 'unknown' : String.valueOf(row.years);
        String line = position + '. ' + c.Name
            + ' | Id: ' + c.Id
            + ' | Years: ' + yearsText
            + ' | Title: ' + (String.isBlank(c.Current_Title_c__c) ? 'n/a' : c.Current_Title_c__c)
            + ' | Location: ' + (String.isBlank(c.Location_c__c) ? 'n/a' : c.Location_c__c);
        if (withCards) {
            line += '\nCARD:\n' + (c.Candidate_Card_c__c == null ? '' : c.Candidate_Card_c__c) + '\n-----';
        }
        return line;
    }

    private static String describeFilters(Request req) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(req.name) && pattern(req.name) != null) {
            parts.add('name contains "' + req.name.trim() + '"');
        }
        if (String.isNotBlank(req.skill) && pattern(req.skill) != null) {
            parts.add('skills contain "' + req.skill.trim() + '"');
        }
        if (req.minYears != null) {
            parts.add('at least ' + req.minYears + ' years');
        }
        if (String.isNotBlank(req.location) && pattern(req.location) != null) {
            parts.add('location contains "' + req.location.trim() + '"');
        }
        return parts.isEmpty() ? 'all processed candidates' : String.join(parts, ', ');
    }

    private static String unknownNote(Integer unknownYears) {
        if (unknownYears == 0) {
            return '';
        }
        return ' ' + unknownYears + ' candidate(s) have no readable years and were not counted.';
    }
}
