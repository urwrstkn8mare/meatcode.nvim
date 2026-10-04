# LeetCode's private API

LeetCode has no documented public API. Everything below is what the site's own
web client does, recovered by watching it and reading
`lua/meatcode/api/leetcode.lua` into shape. It can change without notice.

The companion documents are [neetcode.md](neetcode.md), which covers the other
half: problem metadata, reference solutions, and the roadmap catalog, and
[lintcode.md](lintcode.md), which covers LintCode.

## Transport

Almost everything is one GraphQL endpoint:

```
POST https://leetcode.com/graphql/
Content-Type: application/json
Cookie: <the full browser cookie>
x-csrftoken: <csrftoken from that cookie>
Referer: https://leetcode.com/

{"query": "...", "variables": {...}}
```

Submitting and polling for a verdict are plain REST calls on `leetcode.com`.

## Authentication

Session cookie only. There is no token endpoint a headless client can use, so
the plugin asks for the complete `Cookie` request header from a signed-in tab
and stores it verbatim. Two values inside it matter:

- `LEETCODE_SESSION` — the session itself
- `csrftoken` — echoed back as the `x-csrftoken` header on every request

The cookie is validated once at login with:

```graphql
query globalData {
  userStatus { userId username isSignedIn isPremium isVerified }
}
```

`isPremium` is what decides whether a paid-only problem is opened from LeetCode
or falls back to NeetCode. Credentials land in
`stdpath("cache")/meatcode/leetcode-auth.json` with mode `0600`.

## Queries

### The catalog

```graphql
query problemsetQuestionList($skip: Int!, $limit: Int!) {
  problemsetQuestionList: questionList(categorySlug: "", skip: $skip, limit: $limit, filters: {}) {
    total: totalNum
    questions: data { questionId questionFrontendId title titleSlug difficulty isPaidOnly status }
  }
}
```

Fetched 100 at a time with a 200 ms gap between pages, the way the site pages
it, for roughly 3000 problems. The legacy REST export
`/api/problems/algorithms/` returns the same data in one shot but carries the
bulk-export bot-protection risk, so it is not used. The result is cached at
`stdpath("cache")/meatcode/leetcode-catalog.json` and cross-linked with the
NeetCode catalog by slug.

Note the two id namespaces: `questionFrontendId` is the number you see on the
site, `questionId` is the internal id, and **submitting requires the internal
one**.

### A single problem

```graphql
query questionData($titleSlug: String!) {
  question(titleSlug: $titleSlug) {
    questionId questionFrontendId title titleSlug isPaidOnly difficulty
    content codeSnippets { lang langSlug code } exampleTestcaseList
    metaData hints topicTags { name slug }
  }
}
```

- `content` is HTML, not Markdown (NeetCode's is Markdown) — it is rendered
  before display.
- `codeSnippets` is the starter code per language; `langSlug` is LeetCode's
  name for the language (`python3`, `golang`, `mysql`, ...) and is mapped to
  the plugin's own names.
- `exampleTestcaseList` is the visible input list. Expected outputs are not
  separate fields; the conservative statement parser recovers them from
  `content`.
- `metaData` is a JSON string describing parameter names and types.


### Official editorials and community solutions

```graphql
question(titleSlug: $slug) {
  solution { canSeeDetail paidOnly content }
}
allPlaygroundCodes(uuid: $uuid) { code langSlug }
```

Free editorial content embeds each approach as
`/playground/<uuid>/shared`; `allPlaygroundCodes` supplies the runnable
language variants. Premium-gated editorials have no visible content and fall
through.

```graphql
questionSolutions(filters: {
  questionSlug: $slug, first: 30, skip: 0, orderBy: most_votes
}) {
  solutions { id title solutionTags { name } post { content } }
}
```

Community posts are already vote-ordered. Language-labelled fenced blocks are
extracted, but are only retained as candidates: the local runner must execute
each against every known visible answer before trusting it as an oracle.

### Daily problem and streak

```graphql
query questionOfToday { activeDailyCodingChallengeQuestion { date link question { ... } } }
query getStreakCounter { streakCounter { streakCount daysSkipped currentDayCompleted } }
```

### Submission history

```graphql
query submissionList($offset: Int!, $limit: Int!, $lastKey: String) {
  submissionList(offset: $offset, limit: $limit, lastKey: $lastKey) {
    lastKey hasNext
    submissions { id lang timestamp statusDisplay titleSlug }
  }
}
```

Every submission on the account, newest first, across all problems — this is
what backs completion counting. The REST equivalent `/api/submissions/` answers
HTTP 403 for non-browser clients even with a valid session cookie; this query
does not.

`id` is monotonic, so the highest id seen is stored as a cursor and later runs
only page until they reach it.

## Submitting

```
POST https://leetcode.com/problems/<slug>/submit/
Referer: https://leetcode.com/problems/<slug>/

{"lang": "python3", "question_id": "<internal questionId>", "typed_code": "..."}
-> {"submission_id": 123456789}
```

`question_id` must be LeetCode's own internal id. LeetCode metadata and the
merged catalog carry it; a NeetCode roadmap record, NeetCode metadata or
LintCode metadata (whose `question_id` is LintCode's own) do not. When neither
LeetCode source is at hand, the adapter first resolves it by slug with
`question(titleSlug) { questionId }` and keeps it for the session. A missing
id sent as the string `"nil"` got an HTML HTTP 500 back.

When a function-style solution was opened from another provider, the submission
path fetches LeetCode's full question metadata first and uses its starter to
bridge compatible entry-point names through the language's submission adapter.
That response also supplies the internal question id. Adaptation only affects
the payload, not the saved solution or local-run entry point; it does not rename
symbols throughout the user's code. Missing adapters or incompatible signatures
stop submission before upload.

Then poll until the judge finishes — on the same endpoint leetcode.com polls:

```jsonc
GET https://leetcode.com/submissions/detail/<submission_id>/v2/check/

{"state": "PENDING"}                          // keep polling; also STARTED,
                                              // PREPARING, COMPILING, RUNNING_TESTS
{"state": "SUCCESS", "ai_state": "STARTED",   // tests done, restrictions check
 "judger_status_code": 10, ...}               // still running: keep polling
{"state": "SUCCESS",
 "ai_state": "SUCCESS",                       // may be absent if nothing to check
 "status_code": 10,                           // 10 is the accepted verdict
 "status_msg": "Accepted",
 "total_correct": 57, "total_testcases": 57,
 "status_runtime": "12 ms", "runtime_percentile": 91.3,
 "status_memory": "17.6 MB", "memory_percentile": 44.0,
 "last_testcase": "...",                      // present on a failure
 "expected_output": "...", "code_output": "...", "std_output": "...",
 "compile_error": "...", "full_compile_error": "...",
 "runtime_error": "...", "full_runtime_error": "...",
 "ai_judge_message": "..."}                   // why, on status_code 50
```

Once the tests pass, problems whose statement restricts the approach get an
AI-judged restrictions check (`ai_state` PENDING → STARTED → SUCCESS). It can
overturn passing tests into `status_code` 50, "Restrictions Failed", with the
reason in `ai_judge_message`; LeetCode then voids the run's runtime, memory and
percentiles. The legacy `/submissions/detail/<id>/check/` reports the tests
alone — "Accepted" with percentiles for code the site itself rejects — so the
plugin does not poll it. `state` FAILURE or REVOKED, or `ai_state` FAILURE, is
a judging error.

The plugin polls every 750 ms, at least 10 times and up to twice the configured
`timeout` in seconds. A submission is finished when `state` is `SUCCESS` and
`ai_state` is neither PENDING nor STARTED; `status_code == 10` (or
`status_msg == "Accepted"`) is what records a completion. A failing verdict
carries `last_testcase`, which `<leader>na` can drop straight into your local
suite.

`submissionDetails(submissionId)` returns the stored verdict afterwards
(`statusCode`, `statusDisplay`, `aiJudgeMessage`); both check endpoints answer
`{"state": "PENDING"}` for the judge once its result expires.

## Test runs ("Run")

The cloud oracle uses the editor's "Run": your code against custom inputs,
graded against LeetCode's own solution with the problem's checker, and never
recorded as a submission.

```
POST https://leetcode.com/problems/<slug>/interpret_solution/
Referer: https://leetcode.com/problems/<slug>/

{"lang": "python3", "question_id": "<internal questionId>",
 "typed_code": "...", "data_input": "\"babad\"\n\"cbbd\""}
-> {"interpret_id": "runcode_1790600217.557905_FfJzBZvk05", "test_case": "..."}
```

`data_input` is every case's arguments, one per line, back to back; LeetCode
splits them by the method's parameter count. Design cases use the two-line
`names` / `args` layout. Poll the legacy check endpoint until `state` is
`SUCCESS`:

```jsonc
GET https://leetcode.com/submissions/detail/<interpret_id>/check/

{"state": "SUCCESS",
 "status_code": 10,                          // your code ran; 15 runtime error,
                                             // 20 compile error, 14 time limit
 "code_answer": ["\"aba\"", "\"bb\"", ""],   // your outputs, padded with ""
 "expected_code_answer": ["\"bab\"", "\"bb\"", ""],
 "compare_result": "11",                     // per case, the checker's verdict
 "correct_answer": true,
 "std_output_list": ["", "", ""],
 "runtime_error": "...", "full_runtime_error": "...",
 "compile_error": "...", "full_compile_error": "...",
 "expected_status_code": 10}                 // LeetCode's own solution ran
```

`status_msg` "Accepted" here only means the code ran; `compare_result` is the
verdict, and it comes from the checker: `"aba"` against an expected `"bab"` for
Longest Palindromic Substring is a `1`. On a runtime error `code_answer` stops
at the failing case while `expected_code_answer` still covers every input.

Runs fired within a second or two of each other answer HTTP 429, and bursts can
meet Cloudflare's "Just a moment…" page (HTTP 403).
