local M = {}

M.NS = vim.api.nvim_create_namespace("neetcode")

--- Highlight groups, linked to the colorscheme where a sensible analogue exists
--- so the plugin inherits the user's palette instead of hardcoding colours.
local GROUPS = {
  NeetCodeMuted = { link = "Comment" },
  NeetCodeDone = { link = "DiagnosticOk" },
  NeetCodeTodo = { link = "Comment" },
  NeetCodeNodeDone = { link = "DiagnosticOk" },
  NeetCodeNodeTodo = { link = "Function" },
  NeetCodeNodeSelected = { link = "IncSearch" },
  NeetCodeEdge = { link = "Comment" },
  NeetCodeBarFill = { link = "DiagnosticOk" },
  NeetCodeBarEmpty = { link = "Comment" },
  NeetCodeEasy = { link = "DiagnosticOk" },
  NeetCodeMedium = { link = "DiagnosticWarn" },
  NeetCodeHard = { link = "DiagnosticError" },
  NeetCodePass = { link = "DiagnosticOk" },
  NeetCodeFail = { link = "DiagnosticError" },
  NeetCodeWarn = { link = "DiagnosticWarn" },
  NeetCodeKey = { link = "Special" },
  NeetCodeHeader = { link = "Directory" },
  -- blend=100 is how the TUI hides the cursor (see :help tui-cursor-shape).
  NeetCodeHiddenCursor = { blend = 100, nocombine = true },

  -- Problem statement.
  NeetCodeBold = { bold = true },
  NeetCodeInlineCode = { link = "@markup.raw" },
  NeetCodeCodeBlock = { link = "CursorLine" },
  NeetCodeMath = { link = "Constant" },
  NeetCodeFold = { link = "Directory" },
  NeetCodeTag = { link = "Type" },
}

function M.setup()
  for name, opts in pairs(GROUPS) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", opts, { default = true }))
  end

  -- A terminal cannot make text bigger, so the statement's heading levels are
  -- separated by weight instead: the title is bold and underlined, section
  -- headings are bold alone. Attributes and `link` are mutually exclusive, so
  -- Title's colour is copied across rather than linked -- which is why neither
  -- of these lives in GROUPS above.
  local ok, title = pcall(vim.api.nvim_get_hl, 0, { name = "Title", link = false })
  local fg = ok and title.fg or nil
  vim.api.nvim_set_hl(0, "NeetCodeTitle",
    { fg = fg, bold = true, underline = true, default = true })
  vim.api.nvim_set_hl(0, "NeetCodeSection",
    { fg = fg, bold = true, default = true })

  -- Links show as an underlined label; the URL itself is never displayed.
  local okd, dir = pcall(vim.api.nvim_get_hl, 0, { name = "Directory", link = false })
  vim.api.nvim_set_hl(0, "NeetCodeLink",
    { fg = okd and dir.fg or nil, underline = true, default = true })
end

function M.difficulty(d)
  if d == "Easy" then
    return "NeetCodeEasy"
  elseif d == "Medium" then
    return "NeetCodeMedium"
  elseif d == "Hard" then
    return "NeetCodeHard"
  end
  return "NeetCodeMuted"
end

--- Apply a list of {line, col_start, col_end, group} spans (0-indexed, end-exclusive).
function M.apply(buf, spans, ns)
  ns = ns or M.NS
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, s in ipairs(spans) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, s[1], s[2], {
      end_col = s[3],
      hl_group = s[4],
    })
  end
end

return M
