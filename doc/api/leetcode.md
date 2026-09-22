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
- `exampleTestcaseList` is the visible cases. Expected outputs are not
  included, which is exactly why local runs go through NeetCode's reference
  solution.
- `metaData` is a JSON string describing parameter names and types.

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

Then poll until the judge finishes:

```jsonc
GET https://leetcode.com/submissions/detail/<submission_id>/check/

{"state": "PENDING"}                          // keep polling
{"state": "SUCCESS",
 "status_code": 10,                           // 10 is the accepted verdict
 "status_msg": "Accepted",
 "total_correct": 57, "total_testcases": 57,
 "status_runtime": "12 ms", "runtime_percentile": 91.3,
 "status_memory": "17.6 MB", "memory_percentile": 44.0,
 "last_testcase": "...",                      // present on a failure
 "expected_output": "...", "code_output": "...", "std_output": "...",
 "compile_error": "...", "full_compile_error": "...",
 "runtime_error": "...", "full_runtime_error": "..."}
```

The plugin polls every 750 ms, at least 10 times and up to twice the configured
`timeout` in seconds. A submission is finished when `state` is `SUCCESS` or a
`status_code` is present; `status_code == 10` (or `status_msg == "Accepted"`)
is what records a completion. A failing verdict carries `last_testcase`, which
`<leader>na` can drop straight into your local suite.
