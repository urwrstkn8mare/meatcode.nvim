# NeetCode's private API

NeetCode has no public/documented API. Everything here was recovered by reading
the site's Angular bundle and probing endpoints. It can change without notice —
`lua/neetcode/catalog/scraper.lua` is written to fail loudly and keep the last
good cache rather than silently serve wrong data.

## Transport

All backend calls go to a single base URL and use the
[firebase-functions `onCall`](https://firebase.google.com/docs/functions/callable-reference)
HTTP protocol:

```
POST https://neetcode.io/api/<functionName>
Content-Type: application/json
Authorization: Bearer <firebase-id-token>     # only for authenticated calls

{"data": { ...payload... }}
```

Replies are wrapped the same way:

```jsonc
{"data": ...}                                              // success
{"error": {"message": "Please sign in first.", "status": "UNAUTHENTICATED"}}
```

Note `data` is legitimately `null` for an unknown problem id — that is not an error.

## Authentication

Firebase Auth, project `neetcode-dd170`, web API key
`AIzaSyD4emZpWF1MIsu6Z8O6yaMMcPxJ2Z38L8g` (public — Firebase web keys identify a
project and are not secrets).

**Password sign-in is disabled on the project**, so a headless client cannot log
in with credentials:

```
POST https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword
-> {"error": {"code": 400, "message": "PASSWORD_LOGIN_DISABLED"}}
```

Accounts use OAuth providers (Google, GitHub). The workaround this plugin uses is
to have the user hand over a **refresh token** once, taken from the browser, and
exchange it for short-lived ID tokens:

```
POST https://securetoken.googleapis.com/v1/token?key=<API_KEY>
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token&refresh_token=<token>
-> {"id_token": "...", "expires_in": "3600", "user_id": "..."}
```

The refresh token lives in the browser's **IndexedDB** (`firebaseLocalStorageDb`
→ object store `firebaseLocalStorage`), not `localStorage` — Firebase JS SDK v9+
prefers IndexedDB. See `:NeetCode login` for the extraction snippet.

## Endpoints

### Unauthenticated

| Function | Payload | Returns |
| --- | --- | --- |
| `getProblemMetadataFunctionHttp` | `{problemId}` | Everything needed to solve a problem — see below |
| `getProblemListFunctionHttp` | `{filter}` | Map of `problemId -> {difficulty, free, tag, topics, name?}` |
| `callableFunctionHttp` | `{functionId: "getTopicCounts"}` | LeetCode-topic histogram |
| `callableFunctionHttp` | `{functionId: "getDriverImports", problemId, languageId}` | Per-language judge preamble |

`getProblemMetadataFunctionHttp` is the important one. For `two-integer-sum` it returns:

```jsonc
{
  "id": "two-integer-sum",
  "name": "Two Sum",
  "difficulty": "Easy",
  "description": "...",            // already Markdown, renders as-is
  "test_case_type": "function",    // "function" or "class"; both run locally
  "test_case_count": 33,           // hidden suite size
  "test_cases": [],                // always empty — hidden server-side
  "custom_test_cases": [           // the visible examples
    "nums=[3,4,5,6]\ntarget=7",
    "nums=[4,5,6]\ntarget=10"
  ],
  "starterCode": { "python": "...", "cpp": "...", /* 10 languages */ },
  "solutions":   { "python": "...", "cpp": "...", /* 10 languages */ },
  "availableLanguages": ["python", "cpp", ...],
  "article_body": "...", "video": "...", "topics": [...], "prereqs": [...]
}
```

**`solutions` is the key to local testing.** Expected outputs are never exposed,
but the reference implementation is — so running it locally over the same inputs
recovers the expected output. That is exactly what `lua/neetcode/runner` does.

### Authenticated

| Function | Payload | Notes |
| --- | --- | --- |
| `runCodeFunctionHttp` | `{problemId, rawCode, lang, testCases}` | Judge0-style result per case |
| `executeCodeFunctionHttp` | `{problemId, rawCode, lang}` | Submit against the hidden suite |
| `callableFunctionHttp` | `{functionId: "getCompletedProblems"}` | `{pattern: [leetcodeUrl, ...]}` |
| `callableFunctionHttp` | `{functionId: "markProblemComplete", topic, problem}` | `topic` = pattern, `problem` = full LeetCode URL |
| `callableFunctionHttp` | `{functionId: "markProblemIncomplete", topic, problem}` | |
| `callableFunctionHttp` | `{functionId: "getUserCode", problemId}` | Code saved from the web editor |
| `callableFunctionHttp` | `{functionId: "saveUserCode", problemId, lang, tabs, activeTabIndex}` | |
| `callableFunctionHttp` | `{functionId: "getTestCaseInput", problemId, testCaseIndex}` | One visible input |

`callableFunctionHttp` is a generic dispatcher multiplexing ~171 `functionId`s
(chat, GitHub sync, versus mode, admin, ...). The ones above are the relevant subset.

Submission responses:

```jsonc
{
  "status": {"id": 3, "description": "Accepted"},   // or "Wrong Answer", ...
  "test_case_count": 33, "correct_test_case_count": 33,
  "time": "0.029", "memory": 8316,
  "stderr": "",                                      // traceback on runtime error
  "last_executed_test_case": {                       // present when failing
    "input": "nums=[4,5,6]\ntarget=10",
    "expected_output": "[0,2]", "user_output": "[0,1]",
    "user_logs": "", "test_case_index": 1
  },
  "streakUpdate": {"currentStreak": 1, "maxStreak": 7, "isFirstOfDay": true},
  "distribution": { "timeDistribution": { "points": [...] } }
}
```

## The problem catalog

The roadmap grouping (`pattern`) and curated-list membership
(`blind75`/`neetcode150`/`neetcode250`) are **not exposed by any endpoint**. They
exist only as a static array inside the Angular bundle:

```js
[{ problem: "Two Sum", pattern: "Arrays & Hashing", link: "two-sum/",
   video: "KLlXCFG5TnA", difficulty: "Easy", code: "0001-two-sum",
   neetcode150: !0, blind75: !0, neetcode250: !0, ncLink: "two-integer-sum/" }, ...]
```

973 entries, 19 patterns, exactly 75 / 150 / 250 in the curated lists.

Two id namespaces are in play and they do **not** match:

- `ncLink` — the NeetCode problem id used by the API (`two-integer-sum`)
- `link` — the LeetCode slug, also the key used by progress endpoints (`two-sum`)

### Scraping it durably

The bundle is content-hashed (`main.<hash>.js`) and re-minified on every deploy,
so variable names are worthless as anchors. `scraper.lua` instead:

1. reads `https://neetcode.io/` and extracts `src="main.<hash>.js"`;
2. finds the literal string `pattern:"Arrays & Hashing"` in the bundle;
3. walks **backwards** to the `[` that opens the enclosing array, tracking brace depth;
4. parses the JS literal with `catalog/jsparse.lua` — a JSON parser will not do,
   since the bundle uses unquoted keys and minified `!0` / `!1` booleans;
5. **validates** the result (≥500 entries, exactly 75/150/250, expected patterns
   present) and only then replaces the cached catalog.

If any step fails the previous cache is kept. Nothing is bundled with the
plugin, so on a first run there is no catalog until the fetch succeeds; the
failure is surfaced rather than swallowed.

## Roadmap topology

Node coordinates come from the bundle (they drive ngx-graph on the site) and are
mirrored in `catalog/graph.lua`, where they order nodes left-to-right within a rank.

The **edges are not in the bundle as data**, so they are transcribed by hand from
the rendered roadmap. Unlike the problem catalog, topology is structural and
changes very rarely, so it is pinned rather than scraped.
