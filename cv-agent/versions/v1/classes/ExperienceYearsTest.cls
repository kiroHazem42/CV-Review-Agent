@IsTest
private class ExperienceYearsTest {

    // A fixed "today" so the results never change: November 2026.
    private static final Date TODAY = Date.newInstance(2026, 11, 12);

    private static ExperienceYears.Result run(String periods, String claimed) {
        return ExperienceYears.calculateOne(periods, claimed, TODAY);
    }

    @IsTest
    static void twoJobsInARowAreAddedUp() {
        // 2018-09 to 2021-01 is 29 months, 2021-02 to 2026-11 is 70 months.
        ExperienceYears.Result r = run('2018-09/2021-01; 2021-02/Present', '7');
        Assert.areEqual(99, r.months);
        Assert.areEqual('8', r.years);
        Assert.isTrue(r.calculation.contains('99 months = 8 years'));
        Assert.isTrue(r.check.contains('no conflict'));
    }

    @IsTest
    static void overlappingJobsAreCountedOnce() {
        // The 2023 freelance year is inside the 2022-to-present job.
        ExperienceYears.Result r = run('2022-01/Present; 2023-01/2023-12; 2020-05/2021-12', 'over 12 years');
        Assert.areEqual(79, r.months);
        Assert.areEqual('7', r.years);
        Assert.isTrue(r.check.contains('claims 12 years'));
        Assert.isTrue(r.check.contains('add up to 7 years'));
    }

    @IsTest
    static void yearOnlyDatesCountEndMinusStart() {
        ExperienceYears.Result r = run('2017/2020', null);
        Assert.areEqual(36, r.months);
        Assert.areEqual('3', r.years);
        Assert.isTrue(r.check.contains('no total to compare'));
    }

    @IsTest
    static void threeJobsOverTenYears() {
        ExperienceYears.Result r = run('2021-03/Present; 2018-06/2021-02; 2016-09/2018-05', '10');
        Assert.areEqual(123, r.months);
        Assert.areEqual('10', r.years);
    }

    @IsTest
    static void wordingWithToAndCurrentIsAccepted() {
        ExperienceYears.Result r = run('2020-01 to 2020-12; 2024-01 to current', null);
        // 12 months plus 2024-01 to 2026-11 (35 months).
        Assert.areEqual(47, r.months);
        Assert.areEqual('4', r.years);
    }

    @IsTest
    static void noPeriodsGiveZero() {
        ExperienceYears.Result r = run(null, '5');
        Assert.areEqual(0, r.months);
        Assert.areEqual('0', r.years);
        Assert.isTrue(r.calculation.contains('No job in the CV has written dates'));
        Assert.isTrue(r.check.contains('claims 5 years'));
        Assert.areEqual('0', run('   ', null).years);
    }

    @IsTest
    static void badEntriesAreSkippedNotGuessed() {
        // Not dates, end before start, a year in the future, a month that does not exist, and no end date.
        ExperienceYears.Result r = run('about 3 years/Present; 2021-05/2020-01; 2030-01/2031-01; 2019-13/2020-01; 2019-01; 2019-01/2019-06', null);
        Assert.areEqual(6, r.months);
        Assert.areEqual('1', r.years);
        Assert.isTrue(r.calculation.contains('5 entry(ies) could not be read'));
    }

    @IsTest
    static void futureEndDateStopsAtThisMonth() {
        ExperienceYears.Result r = run('2026-01/2026-12', null);
        Assert.areEqual(11, r.months);
    }

    @IsTest
    static void invocableHandlesAListAndNull() {
        ExperienceYears.Request a = new ExperienceYears.Request();
        a.periods = '2017/2020';
        ExperienceYears.Request b = new ExperienceYears.Request();
        List<ExperienceYears.Result> results = ExperienceYears.calculate(new List<ExperienceYears.Request>{ a, b, null });
        Assert.areEqual(3, results.size());
        Assert.areEqual('3', results[0].years);
        Assert.areEqual('0', results[1].years);
        Assert.areEqual('0', results[2].years);
        Assert.isTrue(ExperienceYears.calculate(null).isEmpty());
    }
}
