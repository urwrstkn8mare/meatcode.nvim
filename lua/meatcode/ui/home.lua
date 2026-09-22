local catalog = require("meatcode.catalog")
local config = require("meatcode.config")
local hl = require("meatcode.ui.highlight")
local lang_info = require("meatcode.lang")
local pages = require("meatcode.ui.pages")
local problem_catalog = require("meatcode.catalog.problems")
local progress = require("meatcode.progress")
local providers = require("meatcode.providers")

--- The homepage: a full-page status screen with single-key jumps into the
--- workflow. q/<Esc> pops the page stack rather than closing everything.
local M = {}

local state = { buf = nil, rows = {}, subscribed = false }

local function is_open()
  return state.buf and vim.api.nvim_buf_is_valid(state.buf) and pages.buf() == state.buf
end

function M.close()
  if state.buf and pages.buf() == state.buf then pages.pop() end
  state.buf, state.rows = nil, {}
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

  -- Block-letter title: the user's meat, with CODE in the same style.
  local title = {
    "                   █████████",
    "               ███████████████",
    "             █████████  ████████   ██████   ██████  ██████  ████████",
    "  ████████████████          ██ ██  ██    ██ ██    ██ ██   ██ ██",
    "███████     ████    █████    ██ ██  ██      ██      ██ ██   ██ ██",
    "█████               ██   ██    ████  ██      ██      ██ ██   ██ ██████",
    "██ █                 ██   ██    ████  ██      ██      ██ ██   ██ ██",
    "████                  █████    ██ ██  ██    ██ ██    ██ ██   ██ ██",
    "██ ██                         ██ ██   ██████   ██████  ██████  ████████",
    " ███████                  ████████",
    "  ██████████████████████████████",
    "     ████████████████████████",
  }
  local lines, spans, rows = { "" }, {}, {}
  for _, art in ipairs(title) do
    table.insert(lines, "  " .. art)
    table.insert(spans, { #lines - 1, 2, 2 + vim.fn.strdisplaywidth(art), "MeatCodeHeader" })
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

  section("status")
  for _, backend in ipairs(providers.all()) do
    local logged_in = backend.auth.is_logged_in()
    row(string.format("    %-8s %s", backend.label, logged_in and "logged in" or "logged out"),
      logged_in and "MeatCodeDone" or "MeatCodeMuted")
  end
  row(string.format("    %-8s %s", "language", lang_info.name(config.options.lang)))
  row(string.format("    %-8s %d problems", "merged", all and #all.problems or 0))
  row(string.format("    %-8s %d/%d solved · %s", "progress", summary.done, summary.total, streak_text()))
  row("")

  section("open")
  local list_label = catalog.LIST_LABELS[config.options.list] or config.options.list
  action(keys.roadmap or "r", "roadmap (" .. list_label .. ")", function() require("meatcode").roadmap() end)
  action(keys.list or "l", "problem finder", function() require("meatcode").list() end)
  action(keys.random or "n", "random unsolved (merged catalog)", function() require("meatcode").random() end)
  action(keys.daily or "d", "problem of the day (LeetCode)", function() require("meatcode").daily() end)
  row("")
  row("  <CR> opens the row under the cursor · q back", "MeatCodeMuted")

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  hl.apply(state.buf, spans)
  state.rows = rows
end

local function current()
  if not is_open() then return nil end
  return state.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

local function activate()
  local fn = current()
  if not fn then return end
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
      fn()
    end
  end
  local api = require("meatcode")
  map(keys.roadmap or "r", jump(api.roadmap), "Open roadmap")
  map(keys.list or "l", jump(api.list), "Open problem finder")
  map(keys.random or "n", jump(api.random), "Open random problem")
  map(keys.daily or "d", jump(api.daily), "Open daily problem")
  map("<CR>", activate, "Open selected row")
  map("q", M.close, "Back")
  map("<Esc>", M.close, "Back")
end

function M.open()
  if is_open() then return end
  catalog.load()
  problem_catalog.load()
  progress.load()

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].filetype = "meatcode-home"
  pages.push({ id = "home", buf = state.buf, title = "home" })

  vim.wo[vim.api.nvim_get_current_win()].cursorline = true
  vim.bo[state.buf].modifiable = false

  keymaps()
  render()
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
