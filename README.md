# meatcode.nvim

(L/N)eetCode without leaving Neovim. Browse problems via NeetCode's roadmap or a
fuzzy-searchable list of all LeetCode problems. Work on it locally, run/debug
test cases locally, and submit to LeetCode (sometimes NeetCode if LeetCode
submission locked).

![NeetCode Roadmap](doc/screenshot.png)

Currently only C++/Python supported, feel free to submit a PR to add more
languages.

Fair warning: this repo is mostly the result of some careful LLM prompting. I
still read every issue and PR and know the codebase well enough to maintain it
for as long as I use it.

## Requirements

- Neovim 0.10+ and `curl`
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for the
  LeetCode problem list
- `python3` and/or a C++ compiler, if you want local test runs
- optional: [image.nvim](https://github.com/3rd/image.nvim) to draw problem
  diagrams inline

## Install

<details open><summary>lazy.nvim</summary>

```lua
{
  "urwrstkn8mare/meatcode.nvim",
  cmd = "MeatCode",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "3rd/image.nvim", -- optional
  },
  opts = {
    lang = "python",      -- or "cpp"
    list = "neetcode150", -- blind75 | neetcode150 | neetcode250 | allNC
  },
}
```

</details>

<details><summary>packer.nvim</summary>

```lua
use {
  "urwrstkn8mare/meatcode.nvim",
  requires = { "nvim-telescope/telescope.nvim" },
  config = function() require("meatcode").setup({}) end,
}
```

</details>

Every option is listed in [doc/configuration.md](doc/configuration.md).

## Log in

Browsing and opening free problems works signed out. Submitting needs an
account with whichever provider you submit to.

| Command | What you hand over |
| --- | --- |
| `:MeatCode login leetcode` | the full `Cookie` request header from a signed-in `leetcode.com` tab (it must contain `LEETCODE_SESSION` and `csrftoken`) |
| `:MeatCode login neetcode` | NeetCode's Firebase refresh token, out of browser storage |

Both commands walk you through getting the value. Credentials are written with
`0600` permissions under `stdpath("cache")/meatcode` and are only ever sent to
the service they belong to. `:MeatCode logout leetcode` / `:MeatCode logout
neetcode` deletes one, `:MeatCode status` shows where you stand.

## Usage

| Command | What it does |
| --- | --- |
| `:MeatCode` | Open the roadmap |
| `:MeatCode roadmap [name]` | Open the roadmap on `blind75`, `neetcode150`, `neetcode250`, or `allNC` |
| `:MeatCode list [query]` | Fuzzy-search every LeetCode problem |
| `:MeatCode random` | Open a random accessible problem you have not completed in the current language |
| `:MeatCode daily` | Open LeetCode's problem of the day |
| `:MeatCode lang [name]` | Show or change the solution language |
| `:MeatCode status` | Show both provider states |
| `:MeatCode login`/`logout [provider]` | See above |

Anything you do to a problem is a buffer-local mapping rather than another Ex
command.

**Roadmap** — `hjkl` or arrows to move, `<CR>` to open a topic, `L`/`H` to
cycle curated lists, `?` for help, `q` to close. The terminal cursor is hidden
while the roadmap has focus since the highlighted node already shows where you
are (`ui.hide_cursor = false` keeps it).

**Problem list** — `<CR>` opens, `o` opens it on LeetCode, `v` plays the
NeetCode video, `q` closes. The number beside a problem is how many days you
have completed it in the current language.

**LeetCode finder** — a full-page Telescope picker with the problem count and
your current streak. Type to filter by number, title, slug, or difficulty;
`<CR>` opens, `<C-o>` opens it in a browser.

**Solving** — the problem opens in its own tab: statement on the left, your
solution on the right, results underneath.

| Key | Action |
| --- | --- |
| `<leader>nr` | Run the visible test cases locally |
| `<leader>ns` | Submit |
| `<leader>nt` | Edit the local test cases |
| `<leader>na` | Add the last failed submission input as a local case |
| `<leader>nR` | Reset the solution to the starter code |
| `<leader>nol` / `<leader>non` | Open the problem using LeetCode / NeetCode |
| `<CR>` or `<Tab>` | In the statement: open the hint, link, or diagram under the cursor |
| `q` | Close the problem |

## How it works

**Two providers, one problem.** Statements, starter code and submissions come
from LeetCode by default. If a problem is Premium and you are not, the matching
NeetCode problem is used instead where one exists. `<leader>nol` / `<leader>non`
switch an open problem by hand.

**Your solution is a real file on disk**, at
`stdpath("data")/meatcode/solutions/<topic>/<problem>.<ext>`, so your LSP,
treesitter, formatter and keymaps all behave normally. For C++ the plugin also
writes a `.clangd` so the language server stops flagging valid solutions; see
[doc/cpp.md](doc/cpp.md).

**Local runs need no network and no rate limit.** Expected outputs are kept
server-side, but NeetCode exposes its own *reference solution* for every
problem. So `<leader>nr` runs your code and the reference over the same inputs
and diffs them, on your machine. `<leader>ns` still goes to the cloud judge for
the hidden suite. Python and C++, function and design problems: 148/150 of the
NeetCode 150 run locally in Python, 146/150 in C++. What's covered and what
isn't, plus editing the case list, is in
[doc/local-runs.md](doc/local-runs.md).

**Completions come from your actual submission history**, not a local
checkbox. Accepted cloud submissions in the current language count once per
problem per day, and LeetCode and NeetCode share one history, so submissions
you made outside this plugin still count. Details in
[doc/progress.md](doc/progress.md).

**The catalog keeps itself current.** Nothing is bundled with the plugin; it is
fetched on first use and refreshed in the background at most once a day. The UI
never blocks on it, and completion history stays readable offline.

## Docs

- [Configuration](doc/configuration.md) — every option, plus highlight groups
- [Local test runs](doc/local-runs.md) — coverage, editing cases, crash output
- [C++ and clangd](doc/cpp.md) — why a `.clangd` is generated and what's in it
- [Progress tracking](doc/progress.md) — how completions and streaks are counted
- [NeetCode's API](doc/api/neetcode.md) and [LeetCode's API](doc/api/leetcode.md) — what was reverse-engineered, and how it holds up
- `:help meatcode` — the same ground in Vim help form

## Caveats

Both APIs used here are undocumented and can change without notice.
meatcode.nvim is not affiliated with or endorsed by NeetCode or LeetCode.
Submissions run on their infrastructure; be reasonable with them.
