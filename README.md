# meatcode.nvim

LeetCode/NeetCode/LintCode without leaving Neovim. Browse NeetCode's roadmap or
a merged catalog, solve/test locally, submit to any of the three.

![The meatcode.nvim homepage](doc/screenshot.png)

## Features

- Test locally (fast) against a sandboxed reference 'oracle' solution ([how](doc/local-runs.md)).
- Editable test cases (can also take from failed submissions) ([more](doc/local-runs.md)).
- C++ autocomplete sees exactly the types each problem defines, via a generated per-problem header ([why](doc/cpp.md)).
- Statements, tests, starter code and submissions fall through a reorderable chain across all 3 providers.
- Browse NeetCode's roadmap as an ASCII DAG.
- Completions is counted from your real cloud submission history, merged across all 3 providers ([how](doc/progress.md)).
- Your solution is a real file on disk, so LSP, treesitter, formatter and your keymaps just work.

## Requirements

- Neovim 0.10+ and `curl`
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for the
  problem finder
- `python3` and/or a C++ compiler for local test runs
- [bubblewrap](https://github.com/containers/bubblewrap) (`bwrap`) on Linux or
  Apple's built-in `sandbox-exec` on macOS to sandbox provider-supplied
  reference/editorial/community oracles (your solution runs separately)
- optional: [image.nvim](https://github.com/3rd/image.nvim) for inline diagrams
- optional: [fidget.nvim](https://github.com/j-hui/fidget.nvim) for spinners
  on long-running steps (opening a problem, checking other providers for a
  stronger oracle) and status updates that replace in place instead of
  stacking a toast per step. Detected automatically if installed — nothing to
  configure on meatcode's side. Without it (or with any other notifier),
  everything still works through plain `vim.notify`.

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
- More languages (i.e. Rust)
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
