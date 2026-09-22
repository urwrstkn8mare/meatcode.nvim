# Logging in

Browsing and opening free problems works signed out. Submitting needs an
account with whichever provider you submit to.

Run `:MeatCode login <provider>`, or press `<CR>` on a provider's status row on
the homepage. Each login page walks you through getting the value, and offers a
browser-console script where one is possible.

| Provider | What you hand over |
| --- | --- |
| `leetcode` | The full `Cookie` request header from a signed-in `leetcode.com` tab. It must contain `LEETCODE_SESSION` and `csrftoken`. The cookie is HttpOnly, so it has to come out of DevTools > Network by hand. |
| `neetcode` | NeetCode's Firebase refresh token, out of IndexedDB. The login page's script reads it for you. |
| `lintcode` | LintCode's JWT refresh token (`localStorage` `@JWT:REFRESH_TOKEN`). The login page's script picks it out; the plugin mints short-lived access tokens from it as needed. |

Credentials are written with `0600` permissions under
`stdpath("cache")/meatcode`, one file per provider, and are only ever sent to
the service they belong to. `:MeatCode logout <provider>` deletes one.

What each API expects on the wire is in [api/leetcode.md](api/leetcode.md),
[api/neetcode.md](api/neetcode.md) and [api/lintcode.md](api/lintcode.md).

## Unlocking paid problems

Paid-only problems are skipped unless the provider serving them is unlocked:
any login does it for NeetCode and LintCode, while LeetCode needs Premium on
the account behind the cookie. When one provider cannot serve a problem, the
content chain falls through to the next (`<leader>nc` to reorder).
