@IsTest
private class FindEvaluationTest {

    @TestSetup
    static void setup() {
        Role_c__c senior = new Role_c__c(Name = 'Senior Salesforce Developer', Must_Haves_c__c = 'Apex', Min_Years_c__c = 5);
        Role_c__c junior = new Role_c__c(Name = 'Junior Salesforce Admin', Must_Haves_c__c = 'Flow', Min_Years_c__c = 1);
        insert new List<Role_c__c>{ senior, junior };

        List<Candidate_c__c> cands = new List<Candidate_c__c>();
        for (String n : new List<String>{ 'Maria Lopez', 'Maria Garcia', 'Ahmed Hassan', 'Priya Nair' }) {
            cands.add(new Candidate_c__c(Name = n, Extraction_Status_c__c = 'Done',
                Candidate_Card_c__c = 'Card for ' + n, Total_Years_Experience_c__c = '5'));
        }
        insert cands;
        Map<String, Id> candId = new Map<String, Id>();
        for (Candidate_c__c c : cands) {
            candId.put(c.Name, c.Id);
        }

        // Score identifies each evaluation in the tests.
        insert new List<Evaluation__c>{
            build(candId.get('Maria Lopez'), senior.Id, 'Maria Lopez', 98),
            build(candId.get('Maria Lopez'), senior.Id, 'Maria Lopez', 90),
            build(candId.get('Maria Lopez'), junior.Id, 'Maria Lopez', 80),
            build(candId.get('Maria Garcia'), senior.Id, 'Maria Garcia', 50),
            build(candId.get('Ahmed Hassan'), senior.Id, 'Ahmed Hassan', 30)
        };
    }

    private static Evaluation__c build(Id candidateId, Id roleId, String candidateName, Decimal score) {
        return new Evaluation__c(
            Candidate__c = candidateId,
            Role__c = roleId,
            Candidate_Name__c = candidateName,
            Score__c = score,
            Recommendation__c = score >= 75 ? 'Strong' : 'Possible',
            Confidence__c = 'High',
            Rank__c = 1,
            Must_Points__c = 10,
            Experience_Points__c = 10,
            Nice_Points__c = 5,
            Reasoning__c = 'Reasoning for ' + candidateName,
            Gaps_And_Risks__c = 'Gaps for ' + candidateName
        );
    }

    // Makes the score 90 evaluation clearly newer than the score 98 one (same candidate and role).
    private static void orderMariaSeniorEvaluations() {
        Evaluation__c older = byScore(98);
        Evaluation__c newer = byScore(90);
        Test.setCreatedDate(older.Id, Datetime.now().addDays(-3));
        Test.setCreatedDate(newer.Id, Datetime.now().addDays(-1));
    }

    private static Evaluation__c byScore(Decimal score) {
        return [SELECT Id, Name, Score__c FROM Evaluation__c WHERE Score__c = :score LIMIT 1];
    }

    private static FindEvaluation.Result run(String evaluationId, String candidateName, String roleName) {
        FindEvaluation.Request req = new FindEvaluation.Request();
        req.evaluationId = evaluationId;
        req.candidateName = candidateName;
        req.roleName = roleName;
        return FindEvaluation.find(new List<FindEvaluation.Request>{ req })[0];
    }

    @IsTest
    static void byEvaluationIdReturnsEvaluationCandidateAndRole() {
        Evaluation__c target = byScore(50);
        FindEvaluation.Result r = run(String.valueOf(target.Id), null, null);
        System.assertEquals(null, r.message);
        System.assertEquals(target.Id, r.evaluation.Id);
        System.assertEquals('Maria Garcia', r.candidate.Name);
        System.assertEquals('Senior Salesforce Developer', r.role.Name);
    }

    @IsTest
    static void byEvaluationNumberIgnoresCase() {
        Evaluation__c target = byScore(30);
        FindEvaluation.Result r = run(target.Name.toLowerCase(), null, null);
        System.assertEquals(null, r.message);
        System.assertEquals(target.Id, r.evaluation.Id);
    }

    @IsTest
    static void unknownEvaluationNumber() {
        FindEvaluation.Result r = run('EVAL-99999', null, null);
        System.assert(r.message.contains('No evaluation was found with the number'));
    }

    @IsTest
    static void evaluationIdThatNoLongerExists() {
        Evaluation__c target = byScore(30);
        Id gone = target.Id;
        delete target;
        FindEvaluation.Result r = run(String.valueOf(gone), null, null);
        System.assert(r.message.contains('No evaluation was found with that Id'));
    }

    @IsTest
    static void latestEvaluationWinsForSameCandidateAndRole() {
        orderMariaSeniorEvaluations();
        FindEvaluation.Result r = run(null, 'Maria Lopez', 'Senior');
        System.assertEquals(null, r.message);
        System.assertEquals(90, r.evaluation.Score__c);
        System.assertEquals('Senior Salesforce Developer', r.role.Name);
    }

    @IsTest
    static void candidateEvaluatedForSeveralRolesAsksWhichRole() {
        FindEvaluation.Result r = run(null, 'Maria Lopez', null);
        System.assert(r.message.contains('Which role do you mean?'));
        System.assert(r.message.contains('Junior Salesforce Admin'));
        System.assert(r.message.contains('Senior Salesforce Developer'));
        System.assertEquals(null, r.evaluation);
    }

    @IsTest
    static void candidateWithOneRoleNeedsNoRoleName() {
        FindEvaluation.Result r = run(null, 'Ahmed', null);
        System.assertEquals(null, r.message);
        System.assertEquals(30, r.evaluation.Score__c);
    }

    @IsTest
    static void twoCandidatesMatchingANameAsksWhichOne() {
        FindEvaluation.Result r = run(null, 'Maria', 'Senior');
        System.assert(r.message.contains('Which one do you mean?'));
        System.assert(r.message.contains('Maria Lopez'));
        System.assert(r.message.contains('Maria Garcia'));
    }

    @IsTest
    static void exactNameWinsWhenSeveralCandidatesMatch() {
        insert new Candidate_c__c(Name = 'Maria', Extraction_Status_c__c = 'Done');
        Candidate_c__c exactMaria = [SELECT Id FROM Candidate_c__c WHERE Name = 'Maria' LIMIT 1];
        Role_c__c senior = [SELECT Id FROM Role_c__c WHERE Name = 'Senior Salesforce Developer' LIMIT 1];
        insert build(exactMaria.Id, senior.Id, 'Maria', 70);

        FindEvaluation.Result r = run(null, 'Maria', 'Senior');
        System.assertEquals(null, r.message);
        System.assertEquals(70, r.evaluation.Score__c);
    }

    @IsTest
    static void candidateWithoutEvaluationAsksToEvaluateFirst() {
        FindEvaluation.Result r = run(null, 'Priya', null);
        System.assert(r.message.contains('No evaluation was found'));
        System.assert(r.message.contains('Evaluate the candidate first'));
    }

    @IsTest
    static void unknownRole() {
        FindEvaluation.Result r = run(null, 'Maria Lopez', 'Banana');
        System.assert(r.message.contains('No role was found'));
    }

    @IsTest
    static void nothingGiven() {
        FindEvaluation.Result r = run(null, null, null);
        System.assert(r.message.contains('which candidate'));
    }

    @IsTest
    static void idOfWrongObjectWithNameIsRejected() {
        Id roleId = [SELECT Id FROM Role_c__c LIMIT 1].Id;
        FindEvaluation.Result r = run(String.valueOf(roleId), 'Maria', null);
        System.assert(r.message.contains('not valid'));
    }

    @IsTest
    static void nameTypedInTheIdInputIsUsedAsName() {
        FindEvaluation.Result r = run('Ahmed', null, null);
        System.assertEquals(null, r.message);
        System.assertEquals(30, r.evaluation.Score__c);
    }

    @IsTest
    static void deletedRoleStillReturnsTheEvaluationWithoutRole() {
        Role_c__c junior = [SELECT Id FROM Role_c__c WHERE Name = 'Junior Salesforce Admin' LIMIT 1];
        Evaluation__c target = byScore(80);
        delete junior;
        FindEvaluation.Result r = run(String.valueOf(target.Id), null, null);
        System.assertEquals(null, r.message);
        System.assertEquals(null, r.role);
        System.assertEquals('Maria Lopez', r.candidate.Name);
    }

    // Bulk safety: many mixed requests in one call still use a small, fixed number of queries.
    @IsTest
    static void manyRequestsUseAFixedNumberOfQueries() {
        Evaluation__c garcia = byScore(50);
        List<FindEvaluation.Request> requests = new List<FindEvaluation.Request>();
        for (Integer i = 0; i < 60; i++) {
            FindEvaluation.Request req = new FindEvaluation.Request();
            Integer kind = Math.mod(i, 4);
            if (kind == 0) {
                req.evaluationId = String.valueOf(garcia.Id);
            } else if (kind == 1) {
                req.candidateName = 'Ahmed';
            } else if (kind == 2) {
                req.candidateName = 'Maria Lopez';
                req.roleName = 'Junior';
            } else {
                req.candidateName = 'Nobody Here';
            }
            requests.add(req);
        }

        Test.startTest();
        List<FindEvaluation.Result> results = FindEvaluation.find(requests);
        Integer queriesUsed = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(60, results.size());
        System.assert(queriesUsed <= 5, 'Expected at most 5 queries for 60 requests, used ' + queriesUsed);
        System.assertEquals(garcia.Id, results[0].evaluation.Id);
        System.assertEquals('Ahmed Hassan', results[1].candidate.Name);
        System.assertEquals(80, results[2].evaluation.Score__c);
        System.assertEquals('Junior Salesforce Admin', results[2].role.Name);
        System.assert(results[3].message.contains('No evaluation was found'), results[3].message);
        System.assertEquals(garcia.Id, results[56].evaluation.Id);
    }

    @IsTest
    static void nullRequestListReturnsEmptyList() {
        System.assert(FindEvaluation.find(null).isEmpty());
    }
}