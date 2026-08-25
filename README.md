# neetcode.nvim

A TUI for the [NeetCode](https://neetcode.io) roadmap. Browse the topic graph,
solve problems in a real buffer with your own LSP and keymaps, run the visible
test cases **locally**, and submit to NeetCode's cloud judge for the hidden suite.

```text
                                        ╭──────────────────────╮
                                        │    Arrays & Hash     │
                                        │ ██████████████░░ 8/9 │
                                        ╰──────────────────────╯
                                                    │
                                       ╭────────────┴─────────────╮
                                       │                          │
                           ╭──────────────────────╮   ╭──────────────────────╮
                           │     Two Pointers     │   │        Stack         │
                           │ ██████████░░░░░░ 3/5 │   │ ███░░░░░░░░░░░░░ 1/6 │
                           ╰──────────────────────╯   ╰──────────────────────╯
                                       │
                         ╭─────────────┴────────────┬──────────────────────────╮
                         │                          │                          │
             ╭──────────────────────╮   ╭──────────────────────╮   ╭──────────────────────╮
             │    Binary Search     │   │    Sliding Window    │   │     Linked List      │
             │ █████░░░░░░░░░░░ 2/7 │   │ ███████████░░░░░ 4/6 │   │ ████████░░░░░░░ 6/11 │
             ╰──────────────────────╯   ╰──────────────────────╯   ╰──────────────────────╯
```

This repo is the result of some careful LLM prompting. I am still happy to
respond to issues and PRs and understand the codebase enough to maintain it
until I no longer use it.

## Why local runs are possible

NeetCode keeps expected outputs server-side — the API hands you test case
*inputs* and a hidden suite count, never the answers. But it does expose its own
**reference solution** for every problem, unauthenticated.

So `run` executes your code *and* the reference solution over the same inputs and
diffs them, entirely on your machine — no rate limits, instant feedback.
`submit` still goes to the cloud, because only the backend has the hidden suite.

## Install

<details open><summary>lazy.nvim</summary>

```lua
{
  "samits/neetcode.nvim",
  cmd = "NeetCode",
  -- Draws problem diagrams inline. Optional: without it, a diagram stays a
  -- line you open in your browser.
  dependencies = { "3rd/image.nvim" },
  opts = {
    lang = "python",       -- or "cpp"
    list = "neetcode150",  -- blind75 | neetcode150 | neetcode250 | allNC
  },
}
```

</details>

<details><summary>packer.nvim</summary>

```lua
use { "samits/neetcode.nvim", config = function() require("neetcode").setup({}) end }
```

</details>

Requires Neovim 0.10+ and `curl`. Local runs need `python3` and/or a C++17 compiler.

## Log in

Browsing works signed out. Running, submitting and progress sync need an account.

NeetCode uses Google/GitHub OAuth and has password sign-in disabled, so there is
no way to log in from the terminal directly. Instead you hand over a Firebase
refresh token once:

1. Open <https://neetcode.io> in a browser, signed in.
2. Open the DevTools console and run the snippet printed by `:NeetCode login`.
3. `:NeetCode login <paste-token>`

The token is stored at `stdpath("cache")/neetcode/auth.json` with `0600`
permissions and is exchanged for a short-lived ID token as needed. Nothing is
sent anywhere except `neetcode.io` and Google's token endpoint.

## Usage

| Command | What it does |
| --- | --- |
| `:NeetCode` | Open the roadmap — everything else starts here |
| `:NeetCode run` | Run the visible test cases locally |
| `:NeetCode submit` | Submit to NeetCode's judge (hidden cases) |
| `:NeetCode list [name]` | Show or switch the curated list |
| `:NeetCode lang [name]` | Show or switch the language |
| `:NeetCode sync` | Refresh the catalog and your progress |
| `:NeetCode status` | Show current state |
| `:NeetCode login` / `logout` | Manage authentication |

`list` takes `blind75`, `neetcode150`, `neetcode250` or `allNC`; `lang` takes
`python` or `cpp` for local runs, plus any language NeetCode itself accepts if
you only ever `submit`. Both are also settable in `setup()`, and `L` / `H` on
the roadmap cycle the list without typing a command.

### Roadmap

| Key | Action |
| --- | --- |
| `h` `j` `k` `l` / arrows | Move between topics |
| `<CR>` | Open the topic's problem list |
| `L` / `H` | Next / previous curated list |
| `R` | Sync catalog and progress |

The terminal cursor is hidden while the roadmap has focus, since the selected
node already shows where you are. Set `ui.hide_cursor = false` to keep it.

### Solving

| Key | Action |
| --- | --- |
| `<leader>nr` | Run the visible test cases locally |
| `<leader>ns` | Submit to NeetCode |
| `<CR>` / `<Tab>` | In the statement: open the hint or diagram under the cursor |
| `q` | Close the problem |

Hints and topic/company tags are folded exactly as they are on the site.

### Diagrams

About a third of problems carry a diagram. With [`image.nvim`](https://github.com/3rd/image.nvim)
installed and a terminal that speaks the kitty graphics protocol (kitty,
Ghostty, WezTerm) they are drawn inline, with nothing but the diagram itself.
Without it, nothing breaks: a `🖼 open diagram` line takes its place, which
`<CR>` opens in your normal viewer. Disable with `ui.images = false`.

`<CR>` follows links the same way. Links in the prose show as an underlined
label with the URL hidden, and the footer carries the problem on NeetCode, on
LeetCode, and its video. Where a line holds more than one link, the column under
the cursor picks which.

### C++ and your language server

NeetCode's starter code has no `#include`s, no `using namespace std;`, and no
definition of `ListNode` / `TreeNode` / `Node` / `Interval` — its judge supplies
all of them. A language server does not, so valid solutions light up red.

So the plugin generates a `.clangd` beside your solutions (`runner.cpp.clangd`).
Your solution file is left exactly as NeetCode wrote it — nothing is inserted
into it, and nothing extra is submitted.

The generated config force-includes a shared `prelude.h` holding the standard
library and `using namespace std;`, plus a **per-problem header holding that
problem's own helper types**, lifted from the definition NeetCode leaves in its
starter comment. This matters
because there is no single right answer: `Node` is an adjacency list in Clone
Graph and a random pointer in Copy List with Random Pointer. Each problem gets
the one it actually has, so `node->random` is correctly rejected in Clone Graph
rather than silently accepted.

```text
solutions/
├── .clangd                 # one fragment per problem, PathMatch-scoped
└── .neetcode/
    ├── prelude.h           # standard library + using namespace std
    ├── clone-graph.h       # class Node { vector<Node*> neighbors; ... }
    └── meeting-schedule.h  # class Interval { int start, end; ... }
```

Headers are written when you open a problem and `.clangd` is rebuilt from
whatever exists on disk, so it stays consistent. An existing `.clangd` the
plugin did not write is left alone. Measured over seeded solutions,
`clangd --check` goes from 1–4 errors per file to zero.
| `?` | Help |
| `q` | Close |

### Problem list

| Key | Action |
| --- | --- |
| `<CR>` | Open the problem |
| `t` | Toggle solved |
| `o` | Open on LeetCode |
| `v` | Open the NeetCode video |

### Solving

The problem opens in a new tab: description on the left, your solution file on
the right, results underneath. The solution is a **real file on disk**, so your
LSP, treesitter, formatters and keymaps all work normally.

| Key | Action |
| --- | --- |
| `<leader>nr` | Run the visible test cases locally |
| `<leader>ns` | Submit to NeetCode (hidden suite) |

Solutions live at `stdpath("data")/neetcode/solutions/<topic>/<problem>.<ext>`.

**Extra test cases.** Create `<solution-file>.tests` next to your solution and
separate cases with a line containing `---`:

```text
nums=[1,2,3,4]
target=7
---
nums=[0,0]
target=0
```

## Local runs: what's supported

Local execution covers **Python** and **C++**, for both `function` problems and
the `class` ("design") problems. Handled:

- integers, floats, booleans, `char`, strings, and nested `vector`/`list` of those
- `ListNode` and `TreeNode`, array-encoded exactly as LeetCode does — including
  `List[ListNode]` (merge-k-sorted-lists) and scalars that identify an existing
  node inside another argument (`lowestCommonAncestor`'s `p` and `q`)
- helper classes such as `Interval`, recovered from the docstring the reference
  solution carries
- in-place problems that mutate their first argument and return nothing
- 32-bit values passed as zero-padded binary strings (`reverse-bits`)
- reference solutions whose parameter names differ from the test-case keys —
  arguments are bound positionally
- design problems (Min Stack, LRU Cache, Trie, Design Twitter, ...): the call
  sequence is replayed against both your class and the reference class, and the
  two return-value lists are diffed. Both encodings NeetCode uses are decoded —
  LeetCode's two-line `names` / `args` pair, and NeetCode's interleaved
  `["MinStack", "push", 1, ...]` form, whose argument boundaries are recovered
  from the arities in the starter code
- encode/decode pairs (Serialize/Deserialize Binary Tree, Encode and Decode
  Strings), judged by round-tripping the input through both halves
- test cases that quote their numbers (`"1"` rather than `1`), coerced to the
  parameter's declared type

Not run locally: SQL, and problems that encode arguments **by reference** rather
than by value — an adjacency list in `clone-graph`, the random pointers in
`copy-linked-list-with-random-pointer`. Those cannot be faithfully rebuilt, so
the plugin says so plainly rather than reporting a bogus diff, and points you at
`submit`, which always works. C++ additionally cannot take `vector<Interval>`
(`meeting-schedule`), which Python handles.

Across the NeetCode 150 that is 148/150 runnable locally in Python and 146/150
in C++.

When your output matches the reference only up to ordering, the case is reported
as passing with a note; the real judge makes the final call.

## Configuration

```lua
require("neetcode").setup({
  list = "neetcode150",
  lang = "python",
  solutions_dir = vim.fn.stdpath("data") .. "/neetcode/solutions",
  cache_dir = vim.fn.stdpath("cache") .. "/neetcode",
  catalog_max_age = 24 * 60 * 60,   -- false to only refresh on :NeetCode sync
  timeout = 30,
  runner = {
    python = { cmd = { "python3" } },
    cpp = { cmd = { "c++", "-std=c++17", "-O2", "-o", "{out}", "{source}" } },
    time_limit = 10,
  },
  ui = { node_width = 24, border = "rounded" },
  keys = {
    roadmap = { open = "<CR>", quit = "q", cycle_list = "L", sync = "R" },
    problem = { run = "<leader>nr", submit = "<leader>ns", quit = "q" },
  },
})
```

## How the catalog stays current

The roadmap grouping and curated-list membership are not in any API — they live
in a static array inside the site's JS bundle. The plugin scrapes that bundle,
anchoring on a stable data string and walking outward, so it survives the
re-minification that happens on every NeetCode deploy. Results are validated
(exactly 75/150/250, expected patterns present) before replacing the cache.

Nothing is bundled with the plugin: the catalog is fetched on first use and
refreshed in the background at most once a day. The UI never blocks on it — a
cached catalog renders immediately and is swapped out when newer data lands. A
first run needs network; it takes well under a second, and the roadmap says what
it is waiting for.

See [`doc/api.md`](doc/api.md) for the full reverse-engineered API map.

## Caveats

This uses a private API that can change at any time. It is not affiliated with
or endorsed by NeetCode. Be reasonable with the submit endpoint — it runs on
someone else's infrastructure.
