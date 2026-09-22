local catalog = require("meatcode.catalog")
local config = require("meatcode.config")
local hl = require("meatcode.ui.highlight")
local lang_info = require("meatcode.lang")
local problem_catalog = require("meatcode.catalog.problems")
local progress = require("meatcode.progress")
local providers = require("meatcode.providers")
local tabs = require("meatcode.ui.tab")
local util = require("meatcode.util")

--- The homepage: one glanceable screen for login state, list/language, roadmap
--- progress and the streak, with single-key jumps into the workflow.
local M = {}

local state = { buf = nil, win = nil, tab = nil, rows = {}, subscribed = false }

local function is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

function M.close()
  if state.tab then tabs.clear(state.tab) end
  if is_open() then pcall(vim.api.nvim_win_close, state.win, true) end
  state.win, state.buf, state.tab, state.rows = nil, nil, nil, {}
end

local function streak_text()
  local auth = providers.get("leetcode").auth
  if not auth.is_logged_in() then return "log in for streak" end
  local streak = problem_catalog.streak()
  if not streak then return "streak unavailable" end
  local days = tonumber(streak.streakCount) or 0
  local today = streak.currentDayCompleted and "today complete" or "solve one today"
  return string.format("%d day%s · %s", days, days == 1 and "" or "s", today)
end

local function render()
  if not is_open() then return end
  local cat = catalog.get() or catalog.load()
  local all = problem_catalog.get() or problem_catalog.load()
  local summary = progress.summary(config.options.list)
  local keys = config.options.keys.home or {}

  -- 🍖 on the left, CODE on the right: the meat *is* the ascii art.
  local title = {
    "   _  _   ___  _____  ___ ___  ___  ___ ",
    " _| || |_/ _ \\/__  / / __/ _ \\/ _ \\/ _ \\",
    "|_  ..  _|  __/  / / | (_| (_)  __/  __/ ",
    "|_      _|\\___/  /_/  \\___\\___/\\___/\\___|",
    "  |_||_|                                 ",
  }
  local lines, spans, rows = { "" }, {}, {}
  for _, art in ipairs(title) do
    table.insert(lines, "  " .. art)
    table.insert(spans, { #lines - 1, 2, 2 + #art, "MeatCodeHeader" })
  end
  table.insert(lines, "")

  local function section(title)
    table.insert(lines, "  " .. title)
    table.insert(spans, { #lines - 1, 2, 2 + #title, "MeatCodeMuted" })
  end
  local function row(text, group)
    table.insert(lines, text)
    if group then table.insert(spans, { #lines - 1, 0, #text, group }) end
  end
  local function action(key, label, fn)
    local line = string.format("    %-8s %s", key, label)
    table.insert(lines, line)
    table.insert(spans, { #lines - 1, 4, 4 + #key, "MeatCodeKey" })
    rows[#lines] = fn
  end

  section("providers")
  for _, backend in ipairs(providers.all()) do
    local logged_in = backend.auth.is_logged_in()
    row(string.format("    %-8s %s", backend.label, logged_in and "logged in" or "logged out"),
      logged_in and "MeatCodeDone" or "MeatCodeMuted")
  end
  row("")

  section("workspace")
  local list = catalog.LIST_LABELS[config.options.list] or config.options.list
  row(string.format("    %-8s %s", "list", list))
  row(string.format("    %-8s %s", "language", lang_info.name(config.options.lang)))
  row(string.format("    %-8s %d problems, %s (%s)", "roadmap",
    cat and #cat.problems or 0, catalog.age_string(), cat and cat.source or "none"))
  row(string.format("    %-8s %d problems", "merged", all and #all.problems or 0))
  row(string.format("    %-8s %d/%d solved · %s", "progress", summary.done, summary.total, streak_text()))
  row("")

  section("open")
  action(keys.roadmap or "r", "roadmap", function() require("meatcode").roadmap() end)
  action(keys.list or "l", "problem finder", function() require("meatcode").list() end)
  action(keys.random or "n", "random unsolved", function() require("meatcode").random() end)
  action(keys.daily or "d", "problem of the day", function() require("meatcode").daily() end)
  row("")
  row("  <CR> opens the row under the cursor · q closes", "MeatCodeMuted")

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  hl.apply(state.buf, spans)
  state.rows = rows
end

local function current()
  if not is_open() then return nil end
  return state.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
end

local function activate()
  local fn = current()
  if not fn then return end
  M.close()
  fn()
end

local function keymaps()
  local keys = config.options.keys.home or {}
  local function map(lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true, desc = desc })
    end
  end
  local function jump(fn)
    return function()
      M.close()
      fn()
    end
  end
  local api = require("meatcode")
  map(keys.roadmap or "r", jump(api.roadmap), "Open roadmap")
  map(keys.list or "l", jump(api.list), "Open problem finder")
  map(keys.random or "n", jump(api.random), "Open random problem")
  map(keys.daily or "d", jump(api.daily), "Open daily problem")
  map("<CR>", activate, "Open selected row")
  map("q", M.close, "Close homepage")
  map("<Esc>", M.close, "Close homepage")
end

function M.open()
  if is_open() then
    vim.api.nvim_set_current_win(state.win)
    return
  end
  catalog.load()
  problem_catalog.load()
  progress.load()

  state.tab = vim.api.nvim_get_current_tabpage()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "meatcode-home"
  tabs.name_buffer(state.buf, "home")
  tabs.set(state.tab, "home")

  local width = math.min(vim.o.columns - 4, 72)
  local height = math.min(vim.o.lines - 6, 34)
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = config.options.ui.border,
    title = " MeatCode ",
    title_pos = "center",
  })
  vim.wo[state.win].cursorline = true
  vim.bo[state.buf].modifiable = false

  keymaps()
  render()
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.win),
    once = true,
    callback = function()
      state.win, state.buf = nil, nil
      if state.tab then tabs.clear(state.tab) end
      state.tab = nil
    end,
  })
  if not state.subscribed then
    state.subscribed = true
    local function refresh()
      vim.schedule(function() pcall(render) end)
    end
    catalog.on_update(refresh)
    problem_catalog.on_update(refresh)
    progress.on_update(refresh)
  end
  progress.sync(function() end)
end

function M.refresh()
  render()
end

return M
