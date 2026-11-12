# CV Review Agent

An Agentforce agent that helps recruiters inside Salesforce. It reads uploaded CVs, turns each one into a structured Candidate Card, lets the recruiter search candidates, evaluates and ranks candidates against a job role with a transparent score, and saves bookmarks with the recruiter's notes.

**Author:** Kirollos Doos

## Contents

1. [What the solution does](#what-the-solution-does)
2. [Architecture overview](#architecture-overview)
3. [Data model](#data-model)
4. [Candidate Card design](#candidate-card-design)
5. [Scoring model](#scoring-model)
6. [Key design decisions and trade-offs](#key-design-decisions-and-trade-offs)
7. [Assumptions made](#assumptions-made)
8. [Known limitations](#known-limitations)
9. [Testing approach](#testing-approach)
10. [Repository layout](#repository-layout)
11. [Setup and deployment](#setup-and-deployment)

## What the solution does

| Step | What the recruiter does | What happens |
|---|---|---|
| 1. Upload | Uploads one or more CV files in the **CV Analyser** screen | One Candidate record is created per file, with status `Processing` |
| 2. Extract | Nothing: it runs in the background | The CV is read, the candidate fields are filled and a Candidate Card is written. Status becomes `Done`, `Needs Review` or `Failed` |
| 3. Search | Asks the agent, for example "who knows LWC in Madrid with at least 5 years?" | A rule-based search returns the matching candidates. No AI is used for the search |
| 4. Evaluate | Asks "compare Ahmed, Maria and Priya for the Senior Salesforce Developer role" | Each candidate is judged against the role, scored, ranked from 1, and one Evaluation record is saved per candidate |
| 5. Bookmark | Answers the agent's question "which candidates do you want to bookmark, with any notes?" | One Bookmark record is saved per candidate, with the score, reasoning, role and the recruiter's notes |

Every agent action writes one row to an audit log.

## Architecture overview

```
 Recruiter
    |
    |  uploads CVs                                    chats with the agent
    v                                                        v
+-----------------------+                     +------------------------------+
| CvUpload              |                     | CV Review Agent (Agentforce) |
| screen flow           |                     |  Agent Router                |
+-----------------------+                     |   -> candidate_review        |
    | creates Candidate (Processing)          |   -> ambiguous_question      |
    v                                         |   -> off_topic               |
+-----------------------+                     +------------------------------+
| candidatefieldscreation|                        |            |            |
| record-triggered flow  |                        v            v            v
| (async, after commit)  |               Candidate_Search  Evaluate_   Bookmark_
+-----------------------+                    flow          Candidates   Candidate
    |        |        |                        |             flow         flow
    v        v        v                        v              |            |
 Extract_CV  Experience  CvReadRetry      FindCandidates      |            v
 prompt      Years       (Apex,           (Apex)              |       FindEvaluation
 template    (Apex)      queueable)                           |       (Apex)
                                                              v
                                          ResolveEvaluationInputs (Apex)
                                          Judge_Requirements prompt template
                                          score, confidence and rank formulas
                                                              |
        every agent action  --------------------------------> AuditLogger (Apex)
```

### Building blocks

| Layer | Component | Purpose |
|---|---|---|
| Agent | `CV_Review_Agent` (Agent Script, in `aiAuthoringBundles`) | One router and three subagents. `candidate_review` owns the three actions |
| Flows | `CvUpload` | Screen flow: upload files, create Candidates, link each file to its Candidate |
| | `candidatefieldscreation` | Record-triggered on Candidate when status is `Processing`. Runs asynchronously after the save. Calls the extraction prompt, the years calculation and the retry |
| | `Candidate_Search` | Agent action: rule-based search |
| | `Evaluate_Candidates` | Agent action: judge, score, rank and save evaluations |
| | `Bookmark_Candidate` | Agent action: save one bookmark per evaluation, without duplicates |
| Prompt templates | `Extract_CV` | Reads one CV file and returns the candidate fields and the Candidate Card as structured output |
| | `Judge_Requirements` | Rates each requirement of a role as MET, PARTLY or NOT SHOWN for one candidate. It returns counts and reasoning, never a score |
| Output schemas | `OutputForCandidteFields`, `JudgeRequirementsResult` | Lightning types that fix the shape of the two prompt outputs |
| Apex | `ExperienceYears` | Calculates total years from the job dates the prompt lists. Overlapping time is counted once |
| | `CvReadRetry` | Reads a CV again once, after a short delay, when the file was not ready |
| | `FindCandidates` | Search by name, skill, minimum years and location |
| | `ResolveEvaluationInputs` | Turns what the recruiter said (Id, name, part of a name, or nothing) into one role and the candidates to compare |
| | `FindEvaluation` | Turns "bookmark Maria" into exactly one saved evaluation |
| | `AuditLogger` | Writes the audit row. Never fails the caller |
| Security | `CV_Recruiter`, `CV_Audit_Reader`, `CV_AI_agents` permission sets | Recruiters work with candidates, roles, evaluations and bookmarks. Only audit readers see the audit log |
| UI | `CV_Analyzer` app, `Cv_Analyser` page, object tabs and layouts | Where the recruiter uploads CVs and opens the records |

### Agent behaviour rules

- It uses only the data returned by its actions. It never invents candidates, skills, scores or Ids.
- Scores, ranks, recommendations and confidence come only from the evaluation action. The agent never calculates or changes a number.
- Ranks start at 1. The best candidate is rank 1.
- The actions return plain labelled facts. The agent designs the layout of the answer (one block per candidate, short bullet lists, no tables).
- After every ranking it asks which candidates to bookmark and whether to add notes.
- It judges only on skills, experience and the role's requirements. It never comments on age, gender, nationality, marital status, religion or photo.
- When an action returns a question ("Which one do you mean?"), it asks the recruiter instead of guessing.

## Data model

```
Role_c__c 1 ----< Evaluation__c >---- 1 Candidate_c__c 1 ----< Candidate_Bookmark__c
                        ^                                              |
                        +----------------------------------------------+
                                  (each bookmark points to one evaluation)

Agent_Audit_Log__c   (stands alone: one row per agent action call)
```

### Candidate (`Candidate_c__c`)

| Field | Type | Notes |
|---|---|---|
| Name | Text | Full name from the CV |
| `Email_c__c`, `Phone_c__c`, `Location_c__c`, `Current_Title_c__c` | Email, Phone, Text | Contact details and latest title |
| `Skills_c__c` | Text Area | Up to 15 main skills, comma separated |
| `Total_Years_Experience_c__c` | Text | Whole years, calculated by Apex from the job dates |
| `Candidate_Card_c__c` | Long Text (32,768) | The full Candidate Card |
| `Extraction_Status_c__c` | Picklist | `Processing`, `Done`, `Needs Review`, `Failed` |
| `Error_Message_c__c` | Text Area | Why extraction failed, and the retry marker |
| `Source_File_Id_c__c` | Text (18) | The uploaded file |

### Role (`Role_c__c`)

| Field | Type | Notes |
|---|---|---|
| Name | Text | Role title |
| `Job_Description_c__c` | Long Text | Full description |
| `Must_Haves_c__c` | Long Text | One requirement per line |
| `Nice_To_Haves_c__c` | Long Text | One requirement per line. Can be empty |
| `Min_Years_c__c` | Number | Minimum years of experience |

### Evaluation (`Evaluation__c`)

One record per candidate per evaluation run. Master-detail to Candidate, lookup to Role.

| Field | Type | Notes |
|---|---|---|
| `Score__c` | Number | 0 to 100. A validation rule enforces the range |
| `Rank__c` | Number | Position in that run, starting at 1 |
| `Recommendation__c` | Picklist | `Strong`, `Possible`, `Weak` |
| `Confidence__c` | Picklist | `High`, `Medium`, `Low` |
| `Must_Points__c`, `Experience_Points__c`, `Nice_Points__c` | Number | The three parts of the score |
| `Reasoning__c` | Long Text | Strengths, with quotes from the card |
| `Gaps_And_Risks__c` | Long Text | Gaps, conflicts and what to ask in the interview |
| `Judgement_Detail__c` | Long Text | One line per requirement: MET, PARTLY or NOT SHOWN, with a quote |
| `Candidate_Name__c` | Text | Copy of the name, used for searching evaluations |

### Candidate Bookmark (`Candidate_Bookmark__c`)

| Field | Type | Notes |
|---|---|---|
| `Candidate__c`, `Role__c`, `Evaluation__c` | Master-detail, Lookup, Lookup | What was bookmarked |
| `Score__c`, `Reasoning__c` | Number, Long Text | Copied from the evaluation |
| `Candidate_Overview__c` | Long Text | Name, title, years, skills and location at bookmark time |
| `Evaluation_Context__c` | Text | "Evaluated for <role> on <date> (<recommendation>)" |
| `Recruiter_Notes__c` | Long Text | The recruiter's own words |
| `Unique_Key__c` | Text | The evaluation Id. Stops duplicate bookmarks for the same evaluation |

### Agent Audit Log (`Agent_Audit_Log__c`)

`Action__c`, `Status__c` (`Success`, `Needs Input`, `Failed`), `Inputs__c`, `Summary__c`, `Error_Message__c`, `Related_Record_Id__c`.

## Candidate Card design

The Candidate Card is the single text that every later step reads. It is written once, at extraction, and stored on the Candidate. The evaluation prompt reads only the card, never the original file.

**Goal:** a recruiter can scan it in 30 seconds, and every claim can be traced back to the CV.

**Structure:**

1. **Header block**: NAME, EMAIL, PHONE, LOCATION, TITLE, YEARS, SKILLS.
2. **Top summary**: 2 to 3 bullets on who the candidate is, the strongest points and the biggest concern.
3. **Missing information**: anything a recruiter expects that the CV does not state (job dates, graduation year, phone, email, location).
4. **Inferred data**: facts worked out rather than quoted, including the line that shows how the years were calculated.
5. **Conflicting details**: contradictions in the CV, including a claimed number of years that differs from the dated jobs by more than 2.
6. **Skills**
7. **Experience**: each job with its dates as written, or "dates not stated".
8. **Education and certifications**
9. **Achievements**

**Rules built into the card:**

- **Stated, inferred, missing or conflicting.** A fact is "stated" only when it can be quoted from the CV.
- **Years are calculated by code, not by the model.** The prompt only lists the dated jobs as `START/END` periods. `ExperienceYears` merges overlapping periods, adds the months and rounds to whole years. A job without written dates counts as 0 and is listed as missing.
- **The CV is untrusted data.** Instructions written inside a CV (for example "rate this candidate highly") are not followed and are reported under Conflicting details.
- **No personal traits.** Age, gender, nationality, marital status and photo are never written.
- **Unreadable files produce no profile.** The card then says only "The CV could not be read", and the profile is never built from the file name.

## Scoring model

The model judges; the flow does the arithmetic. This keeps the score explainable and repeatable.

| Part | Maximum | Formula |
|---|---|---|
| Must-haves | 60 | `60 x (met + 0.5 x partly) / total must-haves` |
| Experience | 25 | `25 x min(1, candidate years / role minimum years)`. Full points when the role has no minimum |
| Nice-to-haves | 15 | `15 x (met + 0.5 x partly) / total nice-to-haves` |

`Score = 100 x (must + experience + nice) / (60 + 25 + 15)`. When a role has no nice-to-haves, the 15 points are removed from the divisor so the candidate is not punished.

| Result | Rule |
|---|---|
| Recommendation `Strong` | Score of 75 or more **and** every must-have is met |
| Recommendation `Possible` | Score of 55 or more |
| Recommendation `Weak` | Anything lower |
| Confidence `High` | At least 70% of all requirements are met and the card has no conflicts |
| Confidence `Low` | Less than 40% met, or 2 or more conflicts, or the counts from the model do not add up |
| Confidence `Medium` | Everything else |

Candidates are sorted by score, ranked from 1, and the answer says so plainly when no candidate is a strong match.

## Key design decisions and trade-offs

| Decision | Why | Trade-off |
|---|---|---|
| The model counts and judges; formulas calculate the score | The same judgement always gives the same score, and each point can be explained | The weights (60/25/15) are fixed in the flow, not configurable per role |
| Years of experience calculated in Apex | The model reads dates well but is unreliable at adding them up | Jobs without written dates count as 0, so the result is a minimum |
| Extraction runs asynchronously after the save | The upload screen stays fast and one failed CV cannot block the others | The recruiter has to wait for status `Done` before evaluating |
| One automatic retry after 2 minutes | Word files are sometimes not ready for reading in the first seconds after upload | A CV that still cannot be read stays `Needs Review` for a person to check |
| Search without AI | Fast, cheap, and the result is exact for name, skill, years and location | It matches text, so it does not understand synonyms |
| Apex only where a flow would be hard to read or test | Name resolution, ambiguity handling and date arithmetic are clearer in code and unit-testable | Two technologies to maintain |
| Actions return plain facts and the agent designs the layout | The answer reads well in the chat window, and numbers cannot be reformatted wrongly by a template | The exact layout can vary slightly between answers |
| Ambiguity returns a question, never a guess | Bookmarking or evaluating the wrong "Maria" is worse than one extra question | One more turn in the conversation |
| Bookmark copies the score, reasoning and overview | The bookmark still makes sense if the candidate is re-evaluated later | Copied data is a snapshot and does not update |
| One bookmark per evaluation (unique key) | Asking twice does not create duplicates | A new bookmark for the same candidate needs a new evaluation |
| All reads run in user mode with sharing | Recruiters only get records and fields they are allowed to see | The audit logger must run in system mode, because recruiters have no access to the audit log |
| Bulk-safe Apex | `FindEvaluation` uses at most 5 queries for any number of requests. `ResolveEvaluationInputs` and `FindCandidates` use a fixed number per request and stop with a clear message before a governor limit | Dynamic SOQL with bind variables is a little harder to read than static SOQL |

## Assumptions made

- Recruiters work inside Salesforce and upload CVs as files (PDF, DOCX, DOC).
- CVs are written in a language the configured model can read. Prompts and messages are in English.
- A role lists its must-haves and nice-to-haves one per line.
- Only candidates with status `Done` and a Candidate Card can be evaluated.
- One request compares at most 10 named candidates. When nobody is named, the 5 most recent processed candidates are compared.
- "Present" in a CV means the current month.
- A requirement that is "not shown" in the CV does not mean the candidate lacks it. It becomes an interview question, not a rejection.
- The org has Agentforce, Prompt Builder and the Einstein generative AI features enabled.

## Known limitations

- **Scanned CVs.** A scanned PDF with no text layer may not be readable. It ends as `Needs Review`.
- **Fixed weights.** The 60/25/15 split and the 75/55 thresholds are the same for every role.
- **Text search.** The search matches text. "LWC" does not find "Lightning Web Components".
- **Leading-wildcard searches.** Name, skill and location searches use `LIKE '%text%'`, which cannot use an index. This is fine for thousands of candidates, and would need a search index for very large volumes.
- **Search window.** The candidate search checks the 200 newest processed candidates that match the text filters.
- **Evaluation speed.** Each candidate needs one model call, so a 10-candidate comparison takes several seconds.
- **Each evaluation saves new records.** Running the same comparison twice creates a second set of evaluations.
- **Model variation.** The MET, PARTLY and NOT SHOWN judgement comes from a language model. The same card can occasionally be judged slightly differently between runs. The confidence value is there to flag weak evidence.
- **Read-only agent.** The agent cannot edit or delete candidates, roles or evaluations. That is done in Salesforce.
- **Markdown rendering.** The agent answers in simple Markdown. A chat surface that does not render Markdown shows the bold markers as plain characters.

## Testing approach

### Apex unit tests

81 test methods in 6 test classes. All 81 pass, and every class is above 90% coverage.

| Class | Coverage | What the tests cover |
|---|---|---|
| `AuditLogger` | 98% | Row content, unknown status, text cut to field length, never throws |
| `CvReadRetry` | 100% | Only candidates still waiting are retried; delay limits |
| `ExperienceYears` | 93% | Overlapping periods, year-only dates, "Present", unreadable dates, claimed-years conflict |
| `FindCandidates` | 93% | Each filter, combined filters, sorting by years, result limits, cards |
| `FindEvaluation` | 96% | By Id, by number, by name, ambiguous names, several roles, deleted role, and 60 requests in one call with 5 queries or fewer |
| `ResolveEvaluationInputs` | 92% | Role by Id and name, ambiguity, candidates by Id and name, not-ready candidates, the limit of 10, the 5 most recent |

Run them with:

```
sf apex run test --class-names AuditLoggerTest --class-names CvReadRetryTest --class-names ExperienceYearsTest --class-names FindCandidatesTest --class-names FindEvaluationTest --class-names ResolveEvaluationInputsTest --code-coverage --wait 15
```

### End-to-end tests with demo CVs

Five demo CVs in `demo-cvs/` cover the main cases:

| File | Case |
|---|---|
| `Maria_Lopez_CV.pdf` | Strong match, text PDF |
| `Ahmed_Hassan_CV.docx` | Word document |
| `Priya_Nair_CV.docx` | Partial match, with a claimed-years conflict and overlapping jobs |
| `Tom_Becker_CV.doc` | Older Word format |
| `Lena_Fischer_CV_scanned.pdf` | Scanned PDF |

### Agent conversation tests

Scenarios to run in the Agentforce Builder preview, with the expected result:

- "Compare Ahmed, Maria and Priya for the Senior Salesforce Developer role": one evaluation call with all names, ranking starts at 1, ends with the bookmark question.
- "Bookmark #1, note: ask about relocation": one bookmark with the note.
- "Find candidates with at least 5 years of Apex": rule-based search.
- Vague and off-topic messages go to the `ambiguous_question` and `off_topic` subagents.

### Direct flow and action checks

The flows and invocable Apex classes can be called through the REST API (`/services/data/vXX.X/actions/custom/flow/<FlowName>` and `/actions/custom/apex/<ClassName>`) to check the exact output without the agent in between.

## Repository layout

```
cv-agent/
  force-app/main/default/
    aiAuthoringBundles/     Agent Script source of the agent
    bots/                   Agent definition and versions
    genAiPlannerBundles/    Published agent versions
    genAiPromptTemplates/   Extract_CV, Judge_Requirements
    lightningTypes/         Output schemas of the two prompts
    flows/                  The five flows
    classes/                Apex classes and tests
    objects/                The five custom objects, fields, validation rule, list views
    permissionsets/         CV_Recruiter, CV_Audit_Reader, CV_AI_agents
    applications/ tabs/ flexipages/ layouts/
  demo-cvs/                 Five demo CVs for testing
  docs/                     Solution document
  versions/v1/              First version of the agent, the evaluation flow and the Apex classes (rollback copy)
```

## Setup and deployment

**Prerequisites:** Salesforce CLI, and an org with Agentforce, Prompt Builder and Einstein generative AI enabled.

```
sf org login web --alias cv-agent-org
sf project deploy start --source-dir force-app --target-org cv-agent-org
sf org assign permset --name CV_Recruiter --target-org cv-agent-org
sf agent publish authoring-bundle --api-name CV_Review_Agent --target-org cv-agent-org
sf agent activate --api-name CV_Review_Agent --target-org cv-agent-org
```

Then:

1. Create a Role record with its must-haves and nice-to-haves, one per line.
2. Open the **CV Analyzer** app and upload the CVs from `demo-cvs/`.
3. Wait until the candidates show status `Done`.
4. Open the agent and ask it to compare the candidates for the role.

**Rollback:** `versions/v1/` holds the first version of the agent script, the evaluation flow and the Apex classes. Copy the files back over `force-app/main/default/` and deploy.
