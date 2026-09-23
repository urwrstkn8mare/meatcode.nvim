local tabs = require("meatcode.ui.tab")

--- Full-page navigation stack for home/roadmap/drilldown. Each page owns one
--- scratch buffer, shown full-window inside the single tab dedicated to
--- pages; opening a page pushes the previous one, and q/<Esc> pops back to
--- it instead of closing everything.
local M = {}

local stack = {}

--- The tab dedicated to the page stack, once one exists. Home, roadmap, list
--- and drilldown pages are mutually exclusive full-page screens, so at most
--- one tab should ever be showing them -- everything below jumps to this
--- tab rather than opening a second one or bouncing a page into whatever
--- window happened to be current (e.g. a problem's own pane).
local pages_tab = nil

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

local function pages_tab_valid()
  return pages_tab ~= nil and vim.api.nvim_tabpage_is_valid(pages_tab)
end

--- Jump to the dedicated pages tab, creating one if none exists yet. A page
--- command run while the pages tab is already open elsewhere (from a
--- problem tab, an LSP-jump tab, or any other editing tab) lands there
--- instead of opening a second pages tab. The first page ever opened keeps
--- today's behaviour of taking over the current window when that window is
--- an ordinary editing tab; a problem tab is never hijacked that way -- a
--- fresh tab is opened for it instead, so a page command never lands inside
--- one of a problem's own panes.
local function focus_tab()
  if pages_tab_valid() then
    if vim.api.nvim_get_current_tabpage() ~= pages_tab then
      pcall(vim.api.nvim_set_current_tabpage, pages_tab)
    end
    return
  end
  local ok, problem = pcall(require, "meatcode.ui.problem")
  if ok and problem.is_session_tab and problem.is_session_tab() then
    vim.cmd("tabnew")
  end
  pages_tab = vim.api.nvim_get_current_tabpage()
end

--- Jump to the pages tab if one exists, without pushing or popping anything.
--- Used when a page command targets the page that is already on top of the
--- stack: nothing to show that isn't already shown, but the command may
--- have been run from a different tab and must still land back on it.
function M.focus()
  if pages_tab_valid() and vim.api.nvim_get_current_tabpage() ~= pages_tab then
    pcall(vim.api.nvim_set_current_tabpage, pages_tab)
  end
end

--- Show `buf` full-window in the pages tab, remembering `page` for back nav.
---@param page {id: string, buf: integer, title: string, on_close: fun()|nil}
function M.push(page)
  focus_tab()
  local prev = current()
  if not (prev and prev.buf == page.buf) then
    if prev then
      if prev.win and vim.api.nvim_win_is_valid(prev.win) then
        prev.win = nil
      end
      -- The page being covered (not popped -- it stays on the stack for back
      -- nav) may own external UI tied to it being the one on screen, e.g.
      -- list.lua's floating picker; let it tear that down now rather than
      -- leaving it floating over whatever gets pushed on top.
      if prev.on_close then pcall(prev.on_close) end
    end
    -- Re-opening a page that is already buried further down (e.g. home,
    -- then roadmap, then home again without ever popping back through
    -- roadmap) reuses its own buffer -- drop the stale entry for it instead
    -- of leaving two stack entries pointing at the same buffer, one of them
    -- unreachable and doomed to collide names with the one about to be
    -- pushed on top.
    for i = #stack, 1, -1 do
      if stack[i].buf == page.buf then
        table.remove(stack, i)
      end
    end
    table.insert(stack, page)
  end
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, page.buf)
  page.win = win
  dress(win)
  tabs.name_buffer(page.buf, page.title)
  tabs.set(pages_tab, page.title)
end

--- Pop the current page. Returns true when a previous page was revealed.
function M.pop()
  local page = table.remove(stack)
  if not page then return false end
  local prev = current()
  -- Show the previous page BEFORE deleting the popped one's buffer: if that
  -- buffer is the sole content of the pages tab's sole window, force-
  -- deleting it while nothing else is shown there yet closes the whole tab
  -- (Neovim's normal behaviour for a tab's last buffer when other tabs
  -- exist) -- "the current window" grabbed afterward would then belong to
  -- some unrelated tab instead of the one still hosting the page stack.
  local shown = false
  if prev and prev.buf and vim.api.nvim_buf_is_valid(prev.buf) then
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, prev.buf)
    prev.win = win
    dress(win)
    tabs.name_buffer(prev.buf, prev.title)
    tabs.set(pages_tab, prev.title)
    shown = true
  end
  if page.on_close then pcall(page.on_close) end
  if page.buf and vim.api.nvim_buf_is_valid(page.buf) then
    pcall(vim.api.nvim_buf_delete, page.buf, { force = true })
  end
  if not prev then return true end
  if shown then
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
  -- land on (Vim's post-close focus target is not guaranteed to be the
  -- dedicated pages tab), so jump there explicitly instead of trusting
  -- "current window" -- and adopt the tab we land in as the pages tab when
  -- none was tracked yet (e.g. a problem closed with no other tab open, so
  -- its own tab is repurposed in place instead).
  if pages_tab_valid() and vim.api.nvim_get_current_tabpage() ~= pages_tab then
    pcall(vim.api.nvim_set_current_tabpage, pages_tab)
  end
  pages_tab = vim.api.nvim_get_current_tabpage()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, page.buf)
  page.win = win
  dress(win)
  tabs.name_buffer(page.buf, page.title)
  tabs.set(pages_tab, page.title)
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
