--- Tab and scratch-buffer titles.
---
--- Neovim's default tabline labels a tab after the current window's buffer, so
--- a problem tab would show the abbreviated solution path and the roadmap
--- float would show [Scratch]. Named buffers plus a tab-page title (used when
--- nobody else owns 'tabline') keep those labels as "roadmap" / the problem
--- name regardless of which split is focused.
local M = {}

local TABLINE = "%!v:lua.require'neetcode.ui.tab'.draw()"

local function ensure_tabline()
  if vim.g.neetcode_tabline then
    return
  end
  -- Don't fight bufferline, lualine, tabby, and friends.
  if vim.o.tabline ~= "" then
    return
  end
  vim.o.tabline = TABLINE
  vim.g.neetcode_tabline = true
end

--- A title other plugins (bufferline tabs mode, taboo, tabby) also look for.
local function set_var(tab, key, value)
  pcall(vim.api.nvim_tabpage_set_var, tab, key, value)
end

local function del_var(tab, key)
  pcall(vim.api.nvim_tabpage_del_var, tab, key)
end

local function get_var(tabnr, key)
  local ok, val = pcall(vim.fn.gettabvar, tabnr, key)
  if not ok or val == nil or val == vim.NIL or val == "" then
    return nil
  end
  return val
end

--- Give a scratch buffer a display name. A URI scheme keeps Neovim from
--- treating it as a cwd-relative file.
function M.name_buffer(buf, name)
  if not (buf and vim.api.nvim_buf_is_valid(buf) and name and name ~= "") then
    return
  end
  local label = "neetcode://" .. name:gsub("[/\\]", " · ")
  if vim.api.nvim_buf_get_name(buf) == label then
    return
  end
  if not pcall(vim.api.nvim_buf_set_name, buf, label) then
    pcall(vim.api.nvim_buf_set_name, buf, label .. "/" .. buf)
  end
end

function M.set(tab, name)
  if not (tab and vim.api.nvim_tabpage_is_valid(tab) and name and name ~= "") then
    return
  end
  -- Remember a pre-existing custom name so closing the roadmap restores it.
  local ok, prev = pcall(vim.api.nvim_tabpage_get_var, tab, "neetcode_prev_name")
  if not ok or prev == nil or prev == vim.NIL then
    local had, existing = pcall(vim.api.nvim_tabpage_get_var, tab, "name")
    set_var(tab, "neetcode_prev_name", (had and existing and existing ~= vim.NIL) and existing or "")
  end
  set_var(tab, "neetcode_name", name)
  set_var(tab, "name", name)
  set_var(tab, "taboo_tab_name", name)
  ensure_tabline()
  pcall(vim.cmd.redrawtabline)
end

function M.clear(tab)
  if not (tab and vim.api.nvim_tabpage_is_valid(tab)) then
    return
  end
  local ok, prev = pcall(vim.api.nvim_tabpage_get_var, tab, "neetcode_prev_name")
  del_var(tab, "neetcode_name")
  del_var(tab, "neetcode_prev_name")
  del_var(tab, "taboo_tab_name")
  if ok and type(prev) == "string" and prev ~= "" then
    set_var(tab, "name", prev)
  else
    del_var(tab, "name")
  end
  pcall(vim.cmd.redrawtabline)
end

local function default_label(tabnr)
  local buflist = vim.fn.tabpagebuflist(tabnr)
  local winnr = vim.fn.tabpagewinnr(tabnr)
  local bufnr = buflist[winnr]
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return "[No Name]"
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local bt = vim.bo[bufnr].buftype
  if name == "" then
    if bt == "quickfix" then
      return "[Quickfix List]"
    elseif bt == "help" then
      return "[Help]"
    elseif bt == "terminal" then
      return "[Terminal]"
    elseif bt == "nofile" or bt == "acwrite" then
      return "[Scratch]"
    end
    return "[No Name]"
  end
  if bt == "help" then
    return vim.fn.fnamemodify(name, ":t")
  end
  return vim.fn.pathshorten(vim.fn.fnamemodify(name, ":~:."))
end

local function modified(tabnr)
  local buflist = vim.fn.tabpagebuflist(tabnr)
  local winnr = vim.fn.tabpagewinnr(tabnr)
  local bufnr = buflist[winnr]
  return bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified
end

--- Default-tabline lookalike that prefers a NeetCode title when one is set.
function M.draw()
  local ok, result = pcall(function()
    local parts = {}
    local current = vim.fn.tabpagenr()
    for i = 1, vim.fn.tabpagenr("$") do
      local sel = i == current
      table.insert(parts, sel and "%#TabLineSel#" or "%#TabLine#")
      table.insert(parts, "%" .. i .. "T")
      local label = get_var(i, "neetcode_name") or default_label(i)
      local flag = modified(i) and "+" or ""
      table.insert(parts, string.format(" %d %s%s ", i, flag, label))
    end
    table.insert(parts, "%#TabLineFill#%T")
    return table.concat(parts)
  end)
  return (ok and result) or ""
end

return M
