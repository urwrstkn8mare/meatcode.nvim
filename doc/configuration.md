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
    python = { cmd = { "python3" } },
    cpp = {
      -- {source} and {out} are substituted at build time. Debug symbols and
      -- -O0 are what let an LLDB rerun show a source backtrace on a crash.
      cmd = { "c++", "-std=c++23", "-g", "-O0", "-o", "{out}", "{source}" },
      -- Generate a .clangd beside your solutions. See doc/cpp.md.
      clangd = true,
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
      switch_provider = "<leader>nd",
      quit = "q",
    },
  },
})
```

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
