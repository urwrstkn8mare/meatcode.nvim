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
Cookie: <the full browser cookie>     # only for authenticated calls
```

Authenticated POSTs also send `Content-Type`, `Origin`, and `Referer`. Keep
`Origin` off GETs: the problem endpoints answer those with
`{"success": false, "detail": "未定义的错误"}` when it is present.

Envelope:

```jsonc
{"success": true, "code": 200, "detail": "", "data": ...}
```

## Authentication

Session cookie only. The plugin asks for the complete `Cookie` request header
from a signed-in `www.lintcode.com` tab and stores it verbatim. A `csrftoken`
or `csrf` value inside it is echoed back as `X-CSRFToken`.

The cookie is validated once at login with:

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
both. An accepted verdict records a completion through the normal provider
path; LintCode account history is not walked, so only submissions made through
the plugin count.
