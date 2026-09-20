local auth = require("eetcode.api.leetcode_auth")
local catalog = require("eetcode.catalog.leetcode")
local nc_catalog = require("eetcode.catalog")
local config = require("eetcode.config")
local hl = require("eetcode.ui.highlight")
local progress = require("eetcode.progress")
local tabs = require("eetcode.ui.tab")
local util = require("eetcode.util")

local M = {}

local state = {
  buf = nil,
  win = nil,
  rows = {},
  query = "",
  subscribed = false,
}

local function is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function streak_text()
  if not auth.is_logged_in() then
    return "Streak: log in with :EetCode login leetcode"
  end
  local streak = catalog.streak()
  if not streak then
    return "Streak: unavailable"
  end
  local days = tonumber(streak.streakCount) or 0
  local today = streak.currentDayCompleted and "today complete" or "solve one today"
  return string.format("Streak: %d day%s · %s", days, days == 1 and "" or "s", today)
end

local function matches(problem, query)
  if query == "" then
    return true
  end
  local haystack = table.concat({
    problem.frontend_id or "",
    problem.name or "",
    problem.leetcode or "",
    problem.difficulty or "",
  }, " "):lower()
  return haystack:find(query:lower(), 1, true) ~= nil
end

local function render()
  if not is_open() then
    return
  end
  local cat = catalog.get()
  local lines, spans = {}, {}
  state.rows = {}

  local count = cat and #cat.problems or 0
  table.insert(lines, string.format("  LeetCode — %d problems · %s", count, streak_text()))
  table.insert(spans, { 0, 0, #lines[1], "EetCodeHeader" })
  table.insert(lines, "  / search   <CR> solve   o browser   R sync   :EetCode random   :EetCode daily")
  table.insert(spans, { 1, 0, #lines[2], "EetCodeMuted" })
  table.insert(lines, state.query ~= "" and ("  Search: " .. state.query) or "")
  if state.query ~= "" then
    table.insert(spans, { 2, 0, #lines[3], "EetCodeKey" })
  end
  table.insert(lines, "")

  if not cat then
    table.insert(lines, "  Fetching all LeetCode problems…")
    table.insert(spans, { #lines - 1, 0, #lines[#lines], "EetCodeMuted" })
  else
    for _, p in ipairs(cat.problems) do
      if matches(p, state.query) then
        local solved = progress.is_solved(p)
        local mark = solved and "✓" or "○"
        local lock = p.paid and "  [pro]" or ""
        local number = p.frontend_id ~= "" and (p.frontend_id .. ".") or ""
        local line = string.format("  %s  %-7s %-54s %-7s%s", mark, number, p.name, p.difficulty, lock)
        table.insert(lines, line)
        state.rows[#lines] = p
        local row = #lines - 1
        table.insert(spans, { row, 2, 2 + #mark, solved and "EetCodeDone" or "EetCodeTodo" })
        if solved then
          table.insert(spans, { row, 0, #line, "EetCodeDone" })
        end
        local dcol = line:find(p.difficulty, 1, true)
        if dcol then
          table.insert(spans, { row, dcol - 1, dcol - 1 + #p.difficulty, hl.difficulty(p.difficulty) })
        end
        if p.paid then
          table.insert(spans, { row, #line - #lock, #line, "EetCodeWarn" })
        end
      end
    end
    if vim.tbl_isempty(state.rows) then
      table.insert(lines, "  No problems match " .. vim.inspect(state.query))
      table.insert(spans, { #lines - 1, 0, #lines[#lines], "EetCodeMuted" })
    end
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  hl.apply(state.buf, spans)
end

local function current()
  if not is_open() then
    return nil
  end
  return state.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
end

function M.close()
  if is_open() then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win, state.buf = nil, nil
end

local function search()
  vim.ui.input({ prompt = "Search LeetCode: ", default = state.query }, function(input)
    if input == nil then
      return
    end
    state.query = vim.trim(input)
    render()
    if is_open() then
      pcall(vim.api.nvim_win_set_cursor, state.win, { 5, 0 })
    end
  end)
end

local function keymaps()
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true, desc = desc })
  end
  map("<CR>", function()
    local problem = current()
    if problem then
      M.close()
      require("eetcode.ui.problem").open(problem)
    end
  end, "solve problem")
  map("/", search, "search all LeetCode problems")
  map("o", function()
    local problem = current()
    if problem then
      vim.ui.open("https://leetcode.com/problems/" .. problem.leetcode .. "/")
    end
  end, "open on LeetCode")
  map("R", function()
    util.notify("syncing LeetCode problems and progress…")
    catalog.sync(function(err)
      vim.schedule(function()
        if err then util.err(err) else render() end
      end)
    end)
  end, "sync LeetCode")
  map("q", M.close, "close")
  map("<Esc>", M.close, "close")
end

function M.open(query)
  nc_catalog.load()
  catalog.refresh_mappings()
  state.query = vim.trim(query or state.query or "")
  if is_open() then
    render()
    vim.api.nvim_set_current_win(state.win)
    return
  end

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "eetcode-leetcode-problems"
  tabs.name_buffer(state.buf, "leetcode")
  local width = math.min(vim.o.columns - 8, 104)
  local height = math.min(vim.o.lines - 8, 34)
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = config.options.ui.border,
    title = " LeetCode Problems ",
    title_pos = "center",
  })
  vim.wo[state.win].cursorline = true
  keymaps()
  render()
  pcall(vim.api.nvim_win_set_cursor, state.win, { 5, 0 })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.win),
    once = true,
    callback = function() state.win, state.buf = nil, nil end,
  })

  if not state.subscribed then
    state.subscribed = true
    catalog.on_update(function()
      vim.schedule(function() pcall(render) end)
    end)
    progress.on_update(function()
      vim.schedule(function() pcall(render) end)
    end)
  end

  catalog.ensure(function(err)
    vim.schedule(function()
      if err and not catalog.get() then
        util.err("could not fetch LeetCode problems: " .. err)
      end
      render()
    end)
  end)
end

function M.refresh()
  render()
end

return M
