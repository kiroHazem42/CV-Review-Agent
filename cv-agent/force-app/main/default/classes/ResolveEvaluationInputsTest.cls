@IsTest
private class ResolveEvaluationInputsTest {

    @TestSetup
    static void setup() {
        insert new List<Role_c__c>{
            new Role_c__c(Name = 'Senior Salesforce Developer', Job_Description_c__c = 'Build things.',
                Must_Haves_c__c = 'Apex\nLWC', Nice_To_Haves_c__c = 'Git', Min_Years_c__c = 5),
            new Role_c__c(Name = 'Junior Salesforce Admin', Job_Description_c__c = 'Admin things.',
                Must_Haves_c__c = 'Flow', Nice_To_Haves_c__c = '', Min_Years_c__c = 1)
        };

        List<Candidate_c__c> cands = new List<Candidate_c__c>();
        for (String n : new List<String>{ 'Maria Lopez', 'Maria Garcia', 'Ahmed Hassan', 'Priya Nair', 'Tom Becker', 'Sam Test' }) {
            cands.add(new Candidate_c__c(Name = n, Extraction_Status_c__c = 'Done',
                Candidate_Card_c__c = 'Card for ' + n, Total_Years_Experience_c__c = '5'));
        }
        cands.add(new Candidate_c__c(Name = 'Lena Fischer', Extraction_Status_c__c = 'Needs Review'));
        insert cands;
    }

    private static ResolveEvaluationInputs.Result run(String roleId, String roleName, String candId, String candName) {
        ResolveEvaluationInputs.Request req = new ResolveEvaluationInputs.Request();
        req.roleId = roleId;
        req.roleName = roleName;
        req.candidateId = candId;
        req.candidateName = candName;
        return ResolveEvaluationInputs.resolve(new List<ResolveEvaluationInputs.Request>{ req })[0];
    }

    private static Id candidateId(String name) {
        return [SELECT Id FROM Candidate_c__c WHERE Name = :name LIMIT 1].Id;
    }

    @IsTest
    static void roleByNameAndRecentCandidatesCapAtFive() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, null);
        System.assertEquals(null, r.message);
        System.assertEquals('Senior Salesforce Developer', r.role.Name);
        System.assertEquals(ResolveEvaluationInputs.MAX_CANDIDATES, r.candidates.size());
    }

    @IsTest
    static void roleById() {
        Id roleId = [SELECT Id FROM Role_c__c WHERE Name = 'Junior Salesforce Admin' LIMIT 1].Id;
        ResolveEvaluationInputs.Result r = run(String.valueOf(roleId), null, null, null);
        System.assertEquals(null, r.message);
        System.assertEquals('Junior Salesforce Admin', r.role.Name);
    }

    @IsTest
    static void roleNameInTheIdInputIsUsedAsName() {
        ResolveEvaluationInputs.Result r = run('Junior', null, null, null);
        System.assertEquals(null, r.message);
        System.assertEquals('Junior Salesforce Admin', r.role.Name);
    }

    @IsTest
    static void roleNotFound() {
        ResolveEvaluationInputs.Result r = run(null, 'Banana', null, null);
        System.assert(r.message.contains('No role was found'));
        System.assertEquals(null, r.role);
        System.assert(r.candidates.isEmpty());
    }

    @IsTest
    static void roleAmbiguous() {
        ResolveEvaluationInputs.Result r = run(null, 'Salesforce', null, null);
        System.assert(r.message.contains('Which one do you mean?'));
        System.assertEquals(null, r.role);
    }

    @IsTest
    static void roleExactNameWinsOverLongerName() {
        insert new Role_c__c(Name = 'Senior Salesforce Developer Lead', Must_Haves_c__c = 'Apex', Min_Years_c__c = 8);
        ResolveEvaluationInputs.Result r = run(null, 'Senior Salesforce Developer', null, null);
        System.assertEquals(null, r.message);
        System.assertEquals('Senior Salesforce Developer', r.role.Name);
    }

    @IsTest
    static void noRoleGiven() {
        ResolveEvaluationInputs.Result r = run(null, null, null, null);
        System.assert(r.message.contains('which role'));
    }

    @IsTest
    static void roleIdOfWrongObjectIsRejected() {
        Id wrongType = candidateId('Tom Becker');
        ResolveEvaluationInputs.Result r = run(String.valueOf(wrongType), 'Senior', null, null);
        System.assert(r.message.contains('not valid'));
    }

    @IsTest
    static void candidateByName() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, 'Ahmed');
        System.assertEquals(null, r.message);
        System.assertEquals(1, r.candidates.size());
        System.assertEquals('Ahmed Hassan', r.candidates[0].Name);
    }

    @IsTest
    static void candidateNameAmbiguous() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, 'Maria');
        System.assert(r.message.contains('Which one do you mean?'));
        System.assert(r.candidates.isEmpty());
        System.assertEquals(null, r.role);
    }

    @IsTest
    static void candidateExactNameWins() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, 'Maria Lopez');
        System.assertEquals(null, r.message);
        System.assertEquals(1, r.candidates.size());
    }

    @IsTest
    static void candidateNotFound() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, 'Zed');
        System.assert(r.message.contains('No processed candidate'));
    }

    @IsTest
    static void candidateByIdWhenReady() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', String.valueOf(candidateId('Priya Nair')), null);
        System.assertEquals(null, r.message);
        System.assertEquals('Priya Nair', r.candidates[0].Name);
    }

    @IsTest
    static void candidateByIdNotReady() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', String.valueOf(candidateId('Lena Fischer')), null);
        System.assert(r.message.contains('not ready'));
        System.assert(r.candidates.isEmpty());
    }

    @IsTest
    static void candidateIdOfWrongObjectIsRejected() {
        Id roleId = [SELECT Id FROM Role_c__c LIMIT 1].Id;
        ResolveEvaluationInputs.Result r = run(null, 'Senior', String.valueOf(roleId), 'Ahmed');
        System.assert(r.message.contains('not valid'));
    }

    private static List<String> names(ResolveEvaluationInputs.Result r) {
        List<String> out = new List<String>();
        for (Candidate_c__c c : r.candidates) {
            out.add(c.Name);
        }
        return out;
    }

    @IsTest
    static void severalNamesAreAllReturnedInOrder() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, 'Ahmed, Priya ,Tom');
        System.assertEquals(null, r.message);
        System.assertEquals(new List<String>{ 'Ahmed Hassan', 'Priya Nair', 'Tom Becker' }, names(r));
        System.assertEquals('Senior Salesforce Developer', r.role.Name);
    }

    @IsTest
    static void severalIdsAreAllReturned() {
        String ids = candidateId('Priya Nair') + ',' + candidateId('Tom Becker');
        ResolveEvaluationInputs.Result r = run(null, 'Senior', ids, null);
        System.assertEquals(null, r.message);
        System.assertEquals(new List<String>{ 'Priya Nair', 'Tom Becker' }, names(r));
    }

    @IsTest
    static void idsAndNamesCanBeMixed() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', String.valueOf(candidateId('Priya Nair')), 'Ahmed; Sam');
        System.assertEquals(null, r.message);
        System.assertEquals(new List<String>{ 'Priya Nair', 'Ahmed Hassan', 'Sam Test' }, names(r));
    }

    @IsTest
    static void sameCandidateTwiceIsReturnedOnce() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, 'Ahmed, Ahmed Hassan, Tom');
        System.assertEquals(null, r.message);
        System.assertEquals(new List<String>{ 'Ahmed Hassan', 'Tom Becker' }, names(r));
    }

    @IsTest
    static void oneUnknownNameInTheListStopsEverything() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, 'Ahmed, Zed, Tom');
        System.assert(r.message.contains('No processed candidate'));
        System.assert(r.message.contains('Zed'));
        System.assert(r.candidates.isEmpty());
        System.assertEquals(null, r.role);
    }

    @IsTest
    static void oneAmbiguousNameInTheListAsksWhichOne() {
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, 'Ahmed, Maria');
        System.assert(r.message.contains('Which one do you mean?'));
        System.assert(r.candidates.isEmpty());
    }

    @IsTest
    static void oneNotReadyIdInTheListStopsEverything() {
        String ids = candidateId('Priya Nair') + ',' + candidateId('Lena Fischer');
        ResolveEvaluationInputs.Result r = run(null, 'Senior', ids, null);
        System.assert(r.message.contains('not ready'));
        System.assert(r.candidates.isEmpty());
    }

    @IsTest
    static void oneInvalidIdInTheListIsRejected() {
        String ids = candidateId('Priya Nair') + ',abc';
        ResolveEvaluationInputs.Result r = run(null, 'Senior', ids, null);
        System.assert(r.message.contains('"abc" is not valid'));
        System.assert(r.candidates.isEmpty());
    }

    @IsTest
    static void tenNamedCandidatesAreAllowed() {
        List<Candidate_c__c> extra = new List<Candidate_c__c>();
        List<String> wanted = new List<String>();
        for (Integer i = 0; i < ResolveEvaluationInputs.MAX_NAMED_CANDIDATES; i++) {
            String n = 'Extra Person' + i + 'x';
            wanted.add(n);
            extra.add(new Candidate_c__c(Name = n, Extraction_Status_c__c = 'Done',
                Candidate_Card_c__c = 'Card for ' + n, Total_Years_Experience_c__c = '2'));
        }
        insert extra;
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, String.join(wanted, ', '));
        System.assertEquals(null, r.message);
        System.assertEquals(ResolveEvaluationInputs.MAX_NAMED_CANDIDATES, r.candidates.size());
    }

    @IsTest
    static void moreThanTenNamedCandidatesIsRejected() {
        List<String> wanted = new List<String>();
        for (Integer i = 0; i <= ResolveEvaluationInputs.MAX_NAMED_CANDIDATES; i++) {
            wanted.add('Person' + i);
        }
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, String.join(wanted, ', '));
        System.assert(r.message.contains('at most 10'));
        System.assert(r.candidates.isEmpty());
    }

    @IsTest
    static void noProcessedCandidatesYet() {
        delete [SELECT Id FROM Candidate_c__c];
        ResolveEvaluationInputs.Result r = run(null, 'Senior', null, null);
        System.assert(r.message.contains('no processed candidates'));
    }

    @IsTest
    static void emptyRequestListReturnsEmptyList() {
        System.assert(ResolveEvaluationInputs.resolve(null).isEmpty());
    }
}