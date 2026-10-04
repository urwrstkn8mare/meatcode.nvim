# Configuration

`setup()` is optional — every key below already has the value shown. Pass only
what you want to change.

```lua
require("meatcode").setup({
  -- Which curated list the roadmap opens on:
  -- "blind75" | "neetcode150" | "neetcode250" | "allNC"
  list = "neetcode150",

  -- Language used for starter code, local runs and submissions.
  lang = "python",

  -- Solutions are written to <dir>/<topic-slug>/<problem-id>.<ext>
  solutions_dir = vim.fn.stdpath("data") .. "/meatcode/solutions",

  -- Scraped catalogs, problem metadata, credentials and progress.
  cache_dir = vim.fn.stdpath("cache") .. "/meatcode",

  -- Refresh a cached catalog in the background once it is this old.
  -- false keeps cached catalogs until they go missing.
  catalog_max_age = 24 * 60 * 60,

  -- Seconds before a network call is abandoned.
  timeout = 30,

  runner = {
    -- Provider reference/editorial/community code is remote and untrusted.
    -- true sandboxes oracle validation/output caching (bwrap / sandbox-exec)
    -- and fails closed when unavailable. Your solution runs separately,
    -- unsandboxed. false executes provider code with your user permissions.
    sandbox = true,
    -- Independent cases use separate processes. 0 = auto (up to CPU count),
    -- 1 = sequential, N = at most N concurrent workers.
    parallelism = 0,
    python = {
      cmd = { "python3" },
      -- Prepend imports/types (Optional, ListNode, ...) a starter needs but
      -- never defines, so a language server stops flagging a valid
      -- solution. Stripped back out before every run/submit. doc/python.md.
      auto_imports = true,
    },
    cpp = {
      -- {source} and {out} are substituted at build time. Like LeetCode's
      -- judge: -O2 with AddressSanitizer, plus UndefinedBehaviorSanitizer and
      -- libc++'s debug hardening. -g lets crash reports name the line in your
      -- solution. See "When C++ crashes" in doc/local-runs.md.
      cmd = {
        "c++", "-std=c++23", "-O2", "-g",
        "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
        "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG",
        "-o", "{out}", "{source}",
      },
      -- Generate a .clangd beside your solutions. See doc/cpp.md.
      clangd = true,
    },
    swift = {
      -- {source} and {out} are substituted at build time.
      cmd = { "swiftc", "-O", "-o", "{out}", "{source}" },
    },
    rust = {
      -- {source} and {out} are substituted at build time. The local harness
      -- uses rustc and the standard library; it does not fetch crates.
      cmd = { "rustc", "--edition=2021", "-O", "-o", "{out}", "{source}" },
      -- Generate a non-Cargo project with editor context outside solutions.
      rust_analyzer = true,
    },
    -- Wall clock limit per test case, in seconds.
    time_limit = 10,
  },

  ui = {
    -- Roadmap node width in cells; labels are centred inside it.
    node_width = 24,
    border = "rounded",
    -- The roadmap is navigated with a highlighted node, so the terminal
    -- cursor is just noise while that window has focus.
    hide_cursor = true,
    -- Draw problem diagrams inline via image.nvim, where the terminal can.
    images = true,
    image_max_height = 18,
  },

  keys = {
    roadmap = {
      open = "<CR>",
      quit = "q",
      cycle_list = "L",
    },
    home = {
      roadmap = "r",
      list = "l",
      random = "n",
      daily = "d",
    },
    problem = {
      run = "<leader>nr",
      submit = "<leader>ns",
      tests = "<leader>nt",
      test_failed = "<leader>na",
      reset = "<leader>nR",
      links = "<leader>no",
      configure = "<leader>nc",
      quit = "q",
    },
  },
})
```

Provider chains and the cloud-oracle setting (when the submit judge's test run
replaces local oracles — see [local test runs](local-runs.md#the-cloud-oracle))
are not `setup()` options: `<leader>nc` edits both and saves them under
`cache_dir`.

Changes apply to open views immediately. The submit chain and cloud mode are
used by the next run/submission; editing the content chain reopens the current
problem through the new chain without replacing its saved solution. Login and
content-chain changes recheck cached catalogue access.

## Swift editor support

MeatCode uses your editor's LSP setup; it does not configure, enable or start
language servers. For Swift, install `sourcekit-lsp` with your Swift toolchain
(Xcode supplies it on macOS), then configure and enable `sourcekit` normally.

Solutions are standalone files, not Swift packages or Xcode projects.
nvim-lspconfig's default SourceKit configuration supports them through native
Neovim LSP; no custom root detector is needed. For Neovim 0.11+:

```lua
vim.lsp.config("sourcekit", {
  filetypes = { "swift" }, -- Leave C/C++ to clangd if you use it.
})
vim.lsp.enable("sourcekit")
```

No `Package.swift` or generated Swift project is needed, and MeatCode leaves
your solution source unchanged.

## Rust editor support

`runner.rust.rust_analyzer = true` (the default) generates `rust-project.json`
under `solutions_dir`, with each solution as a separate crate. The edition comes
from `runner.rust.cmd`; the sysroot comes from its compiler. No Cargo project or
crate downloads are needed.

Configure your usual rust-analyzer LSP setup with `rust-project.json` as a root
marker. Modern nvim-lspconfig supports this already. Standard-library completion
and navigation require `rust-src` for that compiler; with rustup, install it using
`rustup component add rust-src`. Toolchains that bundle the sources need no
additional installation.

Generated files live under `.meatcode/rust/`: shared `ListNode`/`TreeNode` types
from the local harness, plus per-solution context and crate wrappers supplying
`Solution`, `Rc`, `RefCell`, `VecDeque`, and any struct/impl definitions documented
in the starter's comments. Contexts are isolated by solution path, so two problems
with different `Node` definitions cannot conflict.

Rust-analyzer loads your solution as a normal module with a crate-local judge
prelude. A separate stable-Rust wrapper uses `include!` for rustc check-on-save.
Your solution file contains only your code: no generated imports or footer.
Completion and compiler diagnostics target the original buffer without line
offsets. Your own type definitions and imports take precedence over the judge
prelude. Local runs read only your solution.

Opening a Rust problem updates the managed crate graph and reloads rust-analyzer
clients rooted at `solutions_dir`; unrelated Rust projects are not restarted.
A `rust-project.json` not generated by MeatCode is left untouched; you must
include the generated wrappers in that custom graph yourself.
`runner.rust.rust_analyzer = false` disables generation.

## Cross-provider submissions

For function-style problems in Python, C++, Swift and Rust, submitting to a
different provider fetches that judge's starter first. A language-specific
adapter bridges compatible entry-point names in the **submission payload only**.
For example, NeetCode's Swift `hasDuplicate` can serve LeetCode's
`containsDuplicate`; Rust's `has_duplicate` can serve `contains_duplicate`.
Swift argument labels are adapted too. Your buffer, saved file and local-run
entry point are unchanged; an existing judge entry point takes precedence.

Typed languages require compatible parameter and return types, including
reference/inout semantics. Python requires compatible positional instance
methods; unsupported callable forms are rejected rather than guessed.
Incompatible or unparseable signatures stop submission before upload.
Same-provider submissions and design-class APIs are not rewritten.

New language support must register an `adapt_submission(code, starter,
judge_starter)` implementation in `lua/meatcode/submission/init.lua`.
Cross-provider function submissions without a registered adapter fail before
upload instead of bypassing validation.

## Diagrams

About a third of problems carry a diagram. With
[image.nvim](https://github.com/3rd/image.nvim) installed and a terminal that
speaks the kitty graphics protocol (kitty, Ghostty, WezTerm) they are drawn
inline, with no caption or framing — just the diagram.

Without it nothing breaks: a `🖼 open diagram` line takes its place and `<CR>`
opens it in your normal viewer. `ui.images = false` forces that behaviour.

`<CR>` follows links the same way, through `vim.ui.open()`. Links in the prose
show as an underlined label with the URL hidden, and the statement footer
carries the problem on LeetCode, on NeetCode, and its video. Where one line
holds several links, the column under the cursor picks which.

## Highlight groups

All defined with `default = true` and linked to standard groups, so a
colorscheme can override any of them:

`MeatCodeNodeDone`, `MeatCodeNodeTodo`, `MeatCodeNodeSelected`, `MeatCodeEdge`,
`MeatCodeBarFill`, `MeatCodeBarEmpty`, `MeatCodeEasy`, `MeatCodeMedium`,
`MeatCodeHard`, `MeatCodePass`, `MeatCodeFail`, `MeatCodeWarn`.
