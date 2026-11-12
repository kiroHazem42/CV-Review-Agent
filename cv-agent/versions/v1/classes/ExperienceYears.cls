/**
 * Works out a candidate's total years of experience from the job periods found in the CV.
 *
 * Why Apex: the AI reads the dates well but is not reliable at adding them up.
 * So the AI only lists the dated jobs, and this class does the arithmetic the same way every time.
 *
 * Rules: only dated jobs count, overlapping time is counted once, "Present" means this month,
 * and the result is months / 12 rounded to the nearest whole number. No DML. Never throws.
 */
public with sharing class ExperienceYears {

    public class Request {
        @InvocableVariable(label='Job Periods' description='One entry per dated job as START/END, separated by semicolons. Dates as YYYY-MM or YYYY. END can be Present. Example: 2018-09/2021-01; 2021-02/Present')
        public String periods;

        @InvocableVariable(label='Claimed Years' description='The number of years the CV text itself claims, if any. Used only to report a conflict.')
        public String claimedYears;
    }

    public class Result {
        @InvocableVariable(label='Years' description='Total years of experience as a whole number, 0 when no job has dates.')
        public String years;

        @InvocableVariable(label='Months' description='Total months counted, overlapping time counted once.')
        public Integer months;

        @InvocableVariable(label='Calculation' description='One line that shows how the years were worked out.')
        public String calculation;

        @InvocableVariable(label='Check' description='One line that compares the result with the number of years the CV claims.')
        public String check;
    }

    @InvocableMethod(
        label='Calculate Experience Years'
        description='Adds up the dated job periods of a CV into whole years. Overlapping time is counted once.'
        category='CV Review'
    )
    public static List<Result> calculate(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null) {
            return results;
        }
        for (Request req : requests) {
            results.add(calculateOne(req == null ? null : req.periods, req == null ? null : req.claimedYears, Date.today()));
        }
        return results;
    }

    @TestVisible
    private static Result calculateOne(String periods, String claimedYears, Date today) {
        Result res = new Result();
        res.months = 0;
        res.years = '0';
        try {
            Integer nowIndex = today.year() * 12 + today.month() - 1;
            List<Long> keys = new List<Long>();
            List<String> shown = new List<String>();
            Integer skipped = 0;

            if (String.isNotBlank(periods)) {
                for (String entry : periods.split(';')) {
                    if (String.isBlank(entry)) {
                        continue;
                    }
                    List<String> parts = entry.trim().replace(' to ', '/').split('/');
                    if (parts.size() != 2) {
                        skipped++;
                        continue;
                    }
                    Integer startIndex = monthIndex(parts[0], false, today);
                    Integer endIndex = monthIndex(parts[1], true, today);
                    if (startIndex == null || endIndex == null) {
                        skipped++;
                        continue;
                    }
                    // Nothing after this month counts.
                    endIndex = Math.min(endIndex, nowIndex + 1);
                    if (endIndex <= startIndex) {
                        skipped++;
                        continue;
                    }
                    // Sortable key: start first, then end.
                    keys.add(((Long) startIndex) * 100000L + endIndex);
                    shown.add(parts[0].trim() + ' to ' + parts[1].trim());
                }
            }

            // Merge overlapping or touching periods, then add up the months.
            keys.sort();
            Integer total = 0;
            Integer curStart = null;
            Integer curEnd = null;
            for (Long key : keys) {
                Integer s = (Integer) (key / 100000L);
                Integer e = (Integer) Math.mod(key, 100000L);
                if (curStart == null) {
                    curStart = s;
                    curEnd = e;
                } else if (s <= curEnd) {
                    curEnd = Math.max(curEnd, e);
                } else {
                    total += curEnd - curStart;
                    curStart = s;
                    curEnd = e;
                }
            }
            if (curStart != null) {
                total += curEnd - curStart;
            }

            Integer years = (total + 6) / 12;
            res.months = total;
            res.years = String.valueOf(years);

            if (shown.isEmpty()) {
                res.calculation = 'YEARS: 0. No job in the CV has written dates.';
            } else {
                res.calculation = 'YEARS: ' + String.join(shown, ' + ') + ' = ' + total + ' months = ' + years
                    + ' years (worked out by the system from the dated jobs; overlapping time is counted once).';
            }
            if (skipped > 0) {
                res.calculation += ' ' + skipped + ' entry(ies) could not be read as dates and were not counted.';
            }
            res.check = checkText(claimedYears, years);
        } catch (Exception e) {
            res.months = 0;
            res.years = '0';
            res.calculation = 'YEARS: 0. The job dates could not be worked out.';
            res.check = 'Years of experience: not checked.';
        }
        return res;
    }

    // Month number since year 0. A start points at the first counted month, an end at the month after the last one.
    // Year-only dates point at January, so "2017 to 2020" is 36 months.
    private static Integer monthIndex(String text, Boolean isEnd, Date today) {
        if (String.isBlank(text)) {
            return null;
        }
        String t = text.trim().toLowerCase();
        if (isEnd && (t.startsWith('present') || t.startsWith('current') || t == 'now' || t == 'today' || t == 'ongoing')) {
            return today.year() * 12 + today.month();
        }
        Matcher m = Pattern.compile('^(\\d{4})(?:[-.](\\d{1,2}))?$').matcher(t);
        if (!m.matches()) {
            return null;
        }
        Integer y = Integer.valueOf(m.group(1));
        if (y < 1950 || y > today.year()) {
            return null;
        }
        if (m.group(2) == null) {
            return y * 12;
        }
        Integer mo = Integer.valueOf(m.group(2));
        if (mo < 1 || mo > 12) {
            return null;
        }
        Integer index = y * 12 + mo - 1;
        return isEnd ? index + 1 : index;
    }

    private static String checkText(String claimedYears, Integer years) {
        Integer claimed = null;
        if (String.isNotBlank(claimedYears)) {
            Matcher m = Pattern.compile('(\\d{1,2})').matcher(claimedYears);
            if (m.find()) {
                claimed = Integer.valueOf(m.group(1));
            }
        }
        if (claimed == null) {
            return 'Years of experience: the CV states no total to compare with.';
        }
        if (Math.abs(claimed - years) > 2) {
            return 'Years of experience: the CV claims ' + claimed + ' years, but the dated jobs add up to ' + years + ' years.';
        }
        return 'Years of experience: no conflict (the CV claims ' + claimed + ', the dated jobs give ' + years + ').';
    }
}
