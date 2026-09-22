local catalog = require("meatcode.catalog")
local config = require("meatcode.config")
local hl = require("meatcode.ui.highlight")
local lang_info = require("meatcode.lang")
local pages = require("meatcode.ui.pages")
local problem_catalog = require("meatcode.catalog.problems")
local progress = require("meatcode.progress")
local providers = require("meatcode.providers")

--- The homepage: a centred full-page status screen with single-key jumps into
--- the workflow. q/<Esc> pops the page stack rather than closing everything.
local M = {}

--- The meat, then CODE in the same block style. Both blocks are centred as a
--- unit so the letters stay aligned whatever the window width is.
local MEAT = {
  "                   █████████",
  "               ███████████████",
  "             █████████  ████████",
  "  ████████████████          ██ ██",
  "███████     ████    █████    ██ ██",
  "█████               ██   ██    ████",
  "██ █                 ██   ██    ████",
  "████                  █████    ██ ██",
  "██ ██                         ██ ██",
  " ███████                  ████████",
  "  ██████████████████████████████",
  "     ████████████████████████",
}

local CODE = {
  " ██████   ██████  ██████   ████████",
  "██    ██ ██    ██ ██   ██  ██",
  "██       ██    ██ ██    ██ ██",
  "██       ██    ██ ██    ██ ██████",
  "██       ██    ██ ██    ██ ██",
  "██    ██ ██    ██ ██   ██  ██",
  " ██████   ██████  ██████   ████████",
}

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

--- One rendered row: `text` plus highlight spans in the row's own columns.
local function block(entries, width)
  local block_width = 0
  for _, entry in ipairs(entries) do
    block_width = math.max(block_width, vim.fn.strdisplaywidth(entry.text))
  end
  local pad = math.max(0, math.floor((width - block_width) / 2))
  local prefix = string.rep(" ", pad)
  local out = {}
  for _, entry in ipairs(entries) do
    local shifted = {}
    for _, span in ipairs(entry.spans or {}) do
      table.insert(shifted, { span[1] + #prefix, span[2] + #prefix, span[3] })
    end
    table.insert(out, { text = entry.text == "" and "" or prefix .. entry.text, spans = shifted, fn = entry.fn })
  end
  return out
end

local function render()
  if not is_open() then return end
  local all = problem_catalog.get() or problem_catalog.load()
  local keys = config.options.keys.home or {}
  local width = vim.api.nvim_win_get_width(0)

  local title = {}
  for _, art in ipairs(MEAT) do
    table.insert(title, { text = art, spans = { { 0, #art, "MeatCodeHeader" } } })
  end
  table.insert(title, { text = "" })
  for _, art in ipairs(CODE) do
    table.insert(title, { text = art, spans = { { 0, #art, "MeatCodeHeader" } } })
  end

  local body = {}
  local function section(name)
    table.insert(body, { text = name, spans = { { 0, #name, "MeatCodeMuted" } } })
  end
  local function row(label, value, group)
    local text = string.format("  %-9s %s", label, value)
    table.insert(body, { text = text, spans = group and { { 0, #text, group } } or nil })
  end
  local function action(key, label, fn)
    local text = string.format("  %-9s %s", key, label)
    table.insert(body, { text = text, spans = { { 2, 2 + #key, "MeatCodeKey" } }, fn = fn })
  end

  section("status")
  for _, backend in ipairs(providers.all()) do
    local logged_in = backend.auth.is_logged_in()
    row(backend.label, logged_in and "logged in" or "logged out",
      logged_in and "MeatCodeDone" or "MeatCodeMuted")
  end
  row("language", lang_info.name(config.options.lang))
  row("catalog", string.format("%d problems", all and #all.problems or 0))
  row("streak", streak_text())
  row("solved", string.format("%d problems", progress.solved_total()))
  table.insert(body, { text = "" })

  section("open")
  local list_label = catalog.LIST_LABELS[config.options.list] or config.options.list
  action(keys.roadmap or "r", "roadmap (" .. list_label .. ")", function() require("meatcode").roadmap() end)
  action(keys.list or "l", "problem finder", function() require("meatcode").list() end)
  action(keys.random or "n", "random unsolved (merged catalog)", function() require("meatcode").random() end)
  action(keys.daily or "d", "problem of the day (LeetCode)", function() require("meatcode").daily() end)

  local hint = "<CR> open · q back"
  local rendered = {}
  vim.list_extend(rendered, block(title, width))
  table.insert(rendered, { text = "" })
  vim.list_extend(rendered, block(body, width))
  table.insert(rendered, { text = "" })
  vim.list_extend(rendered, block({ { text = hint, spans = { { 0, #hint, "MeatCodeMuted" } } } }, width))

  -- Vertically centre the whole screen, leaving a little breathing room.
  local height = vim.api.nvim_win_get_height(0)
  local top = math.max(1, math.floor((height - #rendered) / 3))

  local lines, spans, rows = {}, {}, {}
  for _ = 1, top do table.insert(lines, "") end
  for _, entry in ipairs(rendered) do
    table.insert(lines, entry.text)
    for _, span in ipairs(entry.spans or {}) do
      table.insert(spans, { #lines - 1, span[1], span[2], span[3] })
    end
    if entry.fn then rows[#lines] = entry.fn end
  end

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
