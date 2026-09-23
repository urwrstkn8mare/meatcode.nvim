local tabs = require("meatcode.ui.tab")

--- Full-page navigation stack for home/roadmap/drilldown. Each page owns one
--- scratch buffer in the current tab; opening a page pushes the previous one,
--- and q/<Esc> pops back to it instead of closing everything.
local M = {}

local stack = {}

local function current()
  return stack[#stack]
end

--- A page is a screen, not a file: no numbers, no signs, no wrapping.
local function dress(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].list = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].colorcolumn = ""
  vim.opt_local.fillchars:append("eob: ")
end

function M.depth()
  return #stack
end

--- Show `buf` full-window in the current tab, remembering `page` for back nav.
---@param page {id: string, buf: integer, title: string, on_close: fun()|nil}
function M.push(page)
  local prev = current()
  if prev and prev.buf == page.buf then return end
  if prev and prev.win and vim.api.nvim_win_is_valid(prev.win) then
    prev.win = nil
  end
  table.insert(stack, page)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, page.buf)
  page.win = win
  page.tab = vim.api.nvim_get_current_tabpage()
  dress(win)
  tabs.name_buffer(page.buf, page.title)
  tabs.set(page.tab, page.title)
end

--- Pop the current page. Returns true when a previous page was revealed.
function M.pop()
  local page = table.remove(stack)
  if not page then return false end
  if page.on_close then pcall(page.on_close) end
  if page.buf and vim.api.nvim_buf_is_valid(page.buf) then
    pcall(vim.api.nvim_buf_delete, page.buf, { force = true })
  end
  local prev = current()
  if not prev then return true end
  if prev.buf and vim.api.nvim_buf_is_valid(prev.buf) then
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, prev.buf)
    prev.win = win
    prev.tab = vim.api.nvim_get_current_tabpage()
    dress(win)
    tabs.name_buffer(prev.buf, prev.title)
    tabs.set(prev.tab, prev.title)
    if prev.on_show then pcall(prev.on_show) end
    return true
  end
  return M.pop()
end

--- Drop every page without revealing anything.
function M.clear()
  while #stack > 0 do
    local page = table.remove(stack)
    if page.on_close then pcall(page.on_close) end
    if page.buf and vim.api.nvim_buf_is_valid(page.buf) then
      pcall(vim.api.nvim_buf_delete, page.buf, { force = true })
    end
  end
end

--- The buffer currently on top of the stack, if any.
function M.buf()
  local page = current()
  return page and page.buf or nil
end

--- Show the top page in the current window. Used when closing a problem tab so
--- q/:q lands back on home/roadmap/drilldown instead of an empty buffer.
---@return boolean
function M.reveal()
  local page = current()
  if not (page and page.buf and vim.api.nvim_buf_is_valid(page.buf)) then
    return false
  end
  -- Callers may invoke this from whatever tab a prior `:tabclose` happened to
  -- land on (Vim's post-close focus target is not guaranteed to be the page's
  -- own tab), so jump there explicitly instead of trusting "current window".
  if page.tab and vim.api.nvim_tabpage_is_valid(page.tab) then
    pcall(vim.api.nvim_set_current_tabpage, page.tab)
  end
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, page.buf)
  page.win = win
  page.tab = vim.api.nvim_get_current_tabpage()
  dress(win)
  tabs.name_buffer(page.buf, page.title)
  tabs.set(page.tab, page.title)
  if page.on_show then pcall(page.on_show) end
  return true
end

--- Re-assert the page's window-local look on every tab switch, and after any
--- mode change. Nothing above should ever leave a page dressed with
--- numbers/signs on, but a stray path (manual gt/gT, a `:tabclose` focus
--- quirk, a future bug) is cheap insurance against a window silently keeping
--- the wrong local options. The `InsertLeave`/`ModeChanged` hook exists
--- because Telescope's search prompt runs in Insert mode: closing it from an
--- Insert-mode mapping (list.lua's back-navigation) makes Neovim fire
--- `InsertLeave` only after that mapping's callback returns, i.e. after
--- `dress()` already ran for the revealed page -- a user's own
--- `InsertLeave`/`ModeChanged` autocmd (e.g. the common relativenumber
--- numbertoggle recipe) then fires against the now-current page window and
--- re-enables what `dress()` just turned off.
local function reassert()
  local page = current()
  if not (page and page.buf and vim.api.nvim_buf_is_valid(page.buf)) then return end
  local win = vim.fn.bufwinid(page.buf)
  if win == -1 or vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then return end
  dress(win)
end

vim.api.nvim_create_autocmd({ "TabEnter", "InsertLeave", "ModeChanged" }, {
  group = vim.api.nvim_create_augroup("MeatCodePagesDress", { clear = true }),
  callback = function() vim.schedule(reassert) end,
})

return M
