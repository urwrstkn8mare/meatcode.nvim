# LintCode's private API

LintCode has no documented public API. Everything below is what the site's own
web client does, recovered by watching it and reading
`lua/meatcode/api/lintcode.lua` into shape. It can change without notice.

The companion documents are [neetcode.md](neetcode.md) and
[leetcode.md](leetcode.md), which cover the other two providers behind the same
`lua/meatcode/providers/*` adapter shape.

## Transport

Almost everything is one JSON API host:

```
GET https://apiv1.lintcode.com/...
Accept: application/json
Authorization: Bearer <jwt>           # only for authenticated calls
```

Authenticated POSTs also send `Content-Type`, `Origin`, and `Referer`. Keep
`Origin` off GETs: the problem endpoints answer those with
`{"success": false, "detail": "未定义的错误"}` when it is present.

Envelope:

```jsonc
{"success": true, "code": 200, "detail": "", "data": ...}
```

## Authentication

Two JWTs. The web client keeps a week-long refresh token in `localStorage`
under `@JWT:REFRESH_TOKEN` and trades it for an access token that lives about
500 seconds; only the access token goes out as `Authorization: Bearer <jwt>`.
The plugin therefore stores the *refresh* token — its login page ships a
console script that scans `localStorage`/`sessionStorage`/cookies for JWTs and
prints the one whose payload says `"token_type": "refresh"` — and mints access
tokens on demand:

```
POST https://apiv1.lintcode.com/v2/api/token-refresh/
{"refresh": "<jwt>"}
-> {"data": {"access": "<jwt>", "access_lifetime": 500}}
```

A rotated `refresh` in that response replaces the stored one. Access tokens are
re-minted 30 seconds before `exp`, and concurrent callers share one in-flight
refresh. A pasted header block, a bare `Bearer ...` value, or a bare `eyJ...`
token are all accepted at login; a `Cookie` header pasted alongside is stored
and replayed too, with a `csrftoken`/`csrf` value inside it echoed back as
`X-CSRFToken`. The cookie alone does not authenticate.

The credential is validated once at login with:

```
GET https://apiv1.lintcode.com/new/api/accounts/profile/
-> {"data": {"user_info": {...}}}
```

Credentials land in `stdpath("cache")/meatcode/lintcode-auth.json` with mode
`0600`.

## Endpoints

### A single problem

```
GET https://apiv1.lintcode.com/v2/api/problems/<id>/?lang=2
```

Returns the statement (`description`, `example`, `new_notice`/`notice`,
`challenge`), `title`/`unique_name`, numeric `level` (0 Naive, 1 Easy, 2
Medium, 3 Hard), `is_locked`, `accept_languages`, `tags`, `company_tags`, and
the visible `testcase_sample`. The plugin concatenates the statement blocks
into Markdown and exposes topics/companies as plain names.

### Starter code

```
GET https://apiv1.lintcode.com/new/api/problems/<id>/reset/?scene=1&language=<lang>
-> {"data": {"code": "..."}}
```

Fetched for exactly the language being opened, since the endpoint takes one
language at a time.

### The catalog

```
GET https://apiv1.lintcode.com/new/api/problems/?_format=new&page_size=200&page=<n>
```

Paged until the returned row count reaches the envelope `count`, with a short
delay between pages. Rows carry `problem_id`, `title`/`en_title`, `level`,
`is_locked`, `problem_tags`, and `company_tags`.

### LeetCode slug mapping

```
GET https://www.lintcode.com/problem/<leetcode-slug>/ -> 302 to /problem/<id>/
```

The site keeps a redirect from LeetCode slugs to numeric LintCode ids. The
plugin follows it through `curl`'s effective URL, then persists the mapping in
`provider-mappings.json` so the merged catalog only resolves each slug once.
Title matching covers the rest at catalog-merge time, but only when a title is
unique on both sides.

### Community solutions

```
GET https://apiv1.lintcode.com/new/api/solution-code/
    ?problem_id=<id>&page=1&page_size=100
```
Rows carry `content`, `languages`/`languages_types`, `like_count`,
`is_official` and `is_highlight`. The plugin pages to the envelope `count`.
Because the endpoint pins highlighted rows ahead of ordinary ones, it then
sorts the complete result by `like_count` and extracts the requested
`[[python]]` or `[[cpp]]` sections from LintCode's multi-language fenced
blocks. These remain untrusted candidates until they pass
every visible case with a known expected output.

## Submitting

```
POST https://apiv1.lintcode.com/new/api/submissions/
{"is_test_submission": false, "problem_id": 56, "language": "python3",
 "source": 99, "code": "..."}
-> {"data": {"id": 123456}}
```

Then poll until the judge finishes:

```
GET https://apiv1.lintcode.com/new/api/submissions/refresh/?id=<id>
{"judge_finished": true, "judge_status": "success", ...}
```

A submission is finished when `judge_finished`/`judgeFinished` is true. The
verdict names arrive in either snake_case or camelCase, so the adapter reads
both.

## Submission history

```
GET https://apiv1.lintcode.com/v2/api/submissions/?_format=new&page=<n>&page_size=<k>&status=1
-> {"count": 41, "next": "...", "previous": null, "data": [
     {"id": 34707959, "status": 1, "language": "python3",
      "created_at": "2026-09-22T09:17:22.291120Z", "problem_id": 1,
      "problem_title": "A + B Problem", "problem_unique_name": "a-b-problem",
      "time_cost": 81, ...}]}
```

`status=1` is the accepted verdict and filters server-side, so a history walk
only pages over completions. The rows are newest first, `created_at` is UTC,
and `problem_id` is the same numeric id the problem endpoints take — which is
how a row is matched to the merged catalog and recorded as a completion day.
Paging stops at the last-recorded submission id, so an incremental check costs
one request.
