@IsTest
private class FindCandidatesTest {

    @TestSetup
    static void setup() {
        List<Candidate_c__c> cands = new List<Candidate_c__c>{
            build('Maria Lopez', '10', 'Apex, LWC, Flow', 'Madrid, Spain', 'Done'),
            build('Maria Garcia', '7.5', 'Java, Flow', 'Seville, Spain', 'Done'),
            build('Ahmed Hassan', '3', 'Sales Cloud, Flow', 'Cairo, Egypt', 'Done'),
            build('Priya Nair', '6.5', 'Sales Cloud, CPQ', 'Manchester, United Kingdom', 'Done'),
            build('Tom Becker', 'n/a', 'Excel', 'Berlin, Germany', 'Done'),
            build('Sam Test', '12', 'Apex, LWC', 'Madrid, Spain', 'Done'),
            build('Lena Fischer', '15', 'Design', 'Zurich, Switzerland', 'Needs Review')
        };
        insert cands;
    }

    private static Candidate_c__c build(String name, String years, String skills, String location, String status) {
        return new Candidate_c__c(
            Name = name,
            Total_Years_Experience_c__c = years,
            Skills_c__c = skills,
            Location_c__c = location,
            Current_Title_c__c = 'Title of ' + name,
            Extraction_Status_c__c = status,
            Candidate_Card_c__c = 'Card for ' + name
        );
    }

    private static FindCandidates.Result run(FindCandidates.Request req) {
        return FindCandidates.find(new List<FindCandidates.Request>{ req })[0];
    }

    private static FindCandidates.Request request() {
        return new FindCandidates.Request();
    }

    private static List<String> names(FindCandidates.Result r) {
        List<String> out = new List<String>();
        for (Candidate_c__c c : r.candidates) {
            out.add(c.Name);
        }
        return out;
    }

    @IsTest
    static void minYearsKeepsTenOrMoreMostYearsFirst() {
        FindCandidates.Request req = request();
        req.minYears = 10;
        FindCandidates.Result r = run(req);
        System.assertEquals(null, r.message);
        System.assertEquals(new List<String>{ 'Sam Test', 'Maria Lopez' }, names(r));
        System.assertEquals(2, r.totalMatched);
        System.assert(r.resultText.contains('at least 10 years'));
        System.assert(r.resultText.contains('no readable years'));
    }

    @IsTest
    static void filterBySkill() {
        FindCandidates.Request req = request();
        req.skill = 'LWC';
        System.assertEquals(2, run(req).candidates.size());
    }

    @IsTest
    static void filterByLocation() {
        FindCandidates.Request req = request();
        req.location = 'Spain';
        System.assertEquals(3, run(req).candidates.size());
    }

    @IsTest
    static void filterByName() {
        FindCandidates.Request req = request();
        req.name = 'Maria';
        System.assertEquals(2, run(req).candidates.size());
    }

    @IsTest
    static void combinedFilters() {
        FindCandidates.Request req = request();
        req.skill = 'LWC';
        req.minYears = 11;
        FindCandidates.Result r = run(req);
        System.assertEquals(new List<String>{ 'Sam Test' }, names(r));
    }

    @IsTest
    static void noMatchGivesMessage() {
        FindCandidates.Request req = request();
        req.skill = 'COBOL';
        FindCandidates.Result r = run(req);
        System.assert(r.message.contains('No processed candidates match'));
        System.assert(r.candidates.isEmpty());
        System.assertEquals(0, r.totalMatched);
    }

    @IsTest
    static void noFiltersReturnsAllDoneCandidatesSortedUnknownLast() {
        FindCandidates.Result r = run(request());
        List<String> found = names(r);
        System.assertEquals(6, found.size());
        System.assertEquals('Sam Test', found[0]);
        System.assertEquals('Tom Becker', found[5]);
        System.assert(!found.contains('Lena Fischer'), 'Only status Done is returned.');
    }

    @IsTest
    static void maxResultsLimitsTheListButNotTheTotal() {
        FindCandidates.Request req = request();
        req.maxResults = 2;
        FindCandidates.Result r = run(req);
        System.assertEquals(2, r.candidates.size());
        System.assertEquals(6, r.totalMatched);
        System.assert(r.resultText.contains('Showing 2 of 6'));
    }

    @IsTest
    static void includeCardsAddsCardTextAndCapsAtEight() {
        List<Candidate_c__c> extra = new List<Candidate_c__c>();
        for (Integer i = 0; i < 5; i++) {
            extra.add(build('Extra ' + i, '1', 'Apex', 'Rome, Italy', 'Done'));
        }
        insert extra;

        FindCandidates.Request req = request();
        req.includeCards = true;
        req.maxResults = 50;
        FindCandidates.Result r = run(req);
        System.assertEquals(FindCandidates.MAX_RESULTS_WITH_CARDS, r.candidates.size());
        System.assert(r.resultText.contains('Card for Sam Test'));
    }

    @IsTest
    static void negativeMinYearsIsRejected() {
        FindCandidates.Request req = request();
        req.minYears = -1;
        System.assert(run(req).message.contains('cannot be negative'));
    }

    @IsTest
    static void wildcardOnlyTextIsIgnoredNotUsedAsWildcard() {
        FindCandidates.Request req = request();
        req.name = '%';
        FindCandidates.Result r = run(req);
        System.assertEquals(null, r.message);
        System.assertEquals(6, r.candidates.size());
    }

    @IsTest
    static void nullRequestListReturnsEmptyList() {
        System.assert(FindCandidates.find(null).isEmpty());
    }
}