# meatcode.nvim

LeetCode/NeetCode/LintCode without leaving Neovim. Browse NeetCode's roadmap or
a merged catalog, solve/test locally, submit to any of the three.

![The meatcode.nvim homepage](doc/screenshot.png)

## Features

- **Local test runs, no network, no rate limit.** `<leader>nr` runs your code
  against NeetCode's reference solution on the same inputs, locally, and
  diffs them. 148/150 of the NeetCode 150 in Python, 146/150 in C++ —
  [how this works](doc/local-runs.md).
- **Editable test cases.** Cases are a file you own — add, edit or delete
  them, and `<leader>na` drops a failed submission's input straight in —
  [more](doc/local-runs.md).
- **Type-aware C++ autocomplete.** Starter code omits `ListNode`/`TreeNode`/
  `Node`; the plugin generates a per-problem header and `.clangd` so clangd
  sees exactly the types that problem defines, and rejects the rest.
  [Why per-problem](doc/cpp.md).
- **Three providers, one problem.** Statements, tests and starter code come
  from whichever provider serves them first; submissions go to whichever
  accepts them first. Reorder either chain with `<leader>nc`.
- **NeetCode's roadmap as an ASCII DAG**, with per-topic progress across
  Blind 75, NeetCode 150, 250, or the full catalog.
- **One progress count, from your real submission history.** A problem's
  count is the number of distinct calendar days you got an accepted
  submission for it, merged across LeetCode and NeetCode and capped at one
  per day — not a local checkbox. [How it's counted](doc/progress.md).
- **Your solution is a real file on disk**, so LSP, treesitter, formatter and
  your own keymaps all behave normally.

## Requirements

- Neovim 0.10+ and `curl`
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for the
  problem finder
- `python3` and/or a C++ compiler for local test runs
- optional: [image.nvim](https://github.com/3rd/image.nvim) for inline diagrams

Only C++ and Python are supported today; PRs for more languages welcome.

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

Every option: [doc/configuration.md](doc/configuration.md).

## Log in

Browsing and opening free problems works signed out; submitting does not. Run
`:MeatCode login leetcode|neetcode|lintcode` and the page walks you through
getting the credential — or press `<CR>` on a status row of the homepage.

Credentials are written `0600` under `stdpath("cache")/meatcode` and only ever
sent to the service they belong to. [What each provider
wants](doc/authentication.md).

## Usage

| Command | What it does |
| --- | --- |
| `:MeatCode` | Homepage: providers, language, catalog, progress, jumps |
| `:MeatCode roadmap [name]` | The topic DAG for a curated list |
| `:MeatCode list [query]` | Fuzzy-search the merged catalog |
| `:MeatCode random` | A random unsolved problem you can open |
| `:MeatCode daily` | LeetCode's problem of the day |
| `:MeatCode lang [name]` | Show or change the solution language |
| `:MeatCode login`/`logout [provider]` | See above |

Everything you do *to* a problem is a buffer-local mapping, not another Ex
command. A problem opens in its own tab: statement left, solution right,
results underneath.

| Key | Action |
| --- | --- |
| `<leader>nr` | Run the test cases locally |
| `<leader>ns` | Submit |
| `<leader>nt` | Edit the local test cases |
| `<leader>na` | Add the last failed submission input as a case |
| `<leader>nR` | Reset the solution to the starter code |
| `<leader>no` | Open a provider/solution/video link |
| `<leader>nc` | Reorder the content/submit provider chains |
| `<CR>`/`<Tab>` | Open the hint, link or diagram under the cursor |
| `q` | Close |

The roadmap, list and finder each advertise their own keys on screen (`?` on
the roadmap for the full set).

## Docs

- [Configuration](doc/configuration.md) — every option and highlight group
- [Local test runs](doc/local-runs.md) — coverage, editing cases, crash output
- [C++ and clangd](doc/cpp.md) — the generated headers and `.clangd`
- [Progress tracking](doc/progress.md) — how completions and streaks count
- Provider APIs — [NeetCode](doc/api/neetcode.md),
  [LeetCode](doc/api/leetcode.md), [LintCode](doc/api/lintcode.md)
- `:help meatcode`

## TODO

- Sorting and filtering in the problem list view
- Local test runs for LeetCode- and LintCode-only problems (cloud test runs at
  minimum, where no reference solution exists)
- More languages (Java, Go, Rust, TypeScript)
- Notes per problem, kept beside the solution file
- A solved/attempted filter in the finder, driven by the shared history

## Notes and thanks

All three APIs used here are undocumented and can change without notice.
meatcode.nvim is not affiliated with or endorsed by NeetCode, LeetCode or
LintCode; submissions run on their infrastructure, so be reasonable with them.

Fair warning: this repo is mostly the result of some careful LLM prompting. I
still read every issue and PR and know the codebase well enough to maintain it
for as long as I use it.

Thanks to [leetcode.nvim](https://github.com/kawre/leetcode.nvim) for inspiration.
