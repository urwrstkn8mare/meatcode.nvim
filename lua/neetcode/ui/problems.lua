local catalog = require("neetcode.catalog")
local config = require("neetcode.config")
local hl = require("neetcode.ui.highlight")
local progress = require("neetcode.progress")
local tabs = require("neetcode.ui.tab")
local util = require("neetcode.util")

--- Problem list for a single roadmap topic.
local M = {}

local state = { buf = nil, win = nil, rows = {}, pattern = nil, list = nil, subscribed = false }

local function is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

function M.close()
  if is_open() then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win, state.buf = nil, nil
end

local function render()
  if not is_open() then
    return
  end

  local problems = catalog.pattern_problems(state.pattern, state.list)
  state.rows = problems

  local lines, spans = {}, {}
  local done = 0
  for _, p in ipairs(problems) do
    if progress.is_solved(p) then
      done = done + 1
    end
  end

  table.insert(lines, string.format("  %s — %d/%d solved · %s",
    state.pattern, done, #problems, catalog.LIST_LABELS[state.list] or state.list))
  table.insert(spans, { 0, 0, #lines[1], "NeetCodeHeader" })
  table.insert(lines, "")

  for i, p in ipairs(problems) do
    local solved = progress.is_solved(p)
    local mark = solved and "✓" or "○"
    local lock = p.pro and "  [pro]" or ""
    local line = string.format("  %s  %-52s %-7s%s", mark, p.name, p.difficulty, lock)
    table.insert(lines, line)

    local row = #lines - 1
    table.insert(spans, { row, 2, 2 + #mark, solved and "NeetCodeDone" or "NeetCodeTodo" })
    if solved then
      table.insert(spans, { row, 0, #line, "NeetCodeDone" })
    end
    local dcol = line:find(p.difficulty, 1, true)
    if dcol then
      table.insert(spans, { row, dcol - 1, dcol - 1 + #p.difficulty, hl.difficulty(p.difficulty) })
    end
    if p.pro then
      table.insert(spans, { row, #line - #lock, #line, "NeetCodeWarn" })
    end
    local _ = i
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  hl.apply(state.buf, spans)
end

--- The catalog entry under the cursor, if any.
local function current()
  if not is_open() then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(state.win)[1]
  return state.rows[row - 2]
end

local function keymaps()
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true, desc = desc })
  end

  map("<CR>", function()
    local p = current()
    if not p then
      return
    end
    if not p.id then
      return util.err(p.name .. " is LeetCode-only and cannot be opened in NeetCode")
    end
    M.close()
    require("neetcode.ui.problem").open(p)
  end, "open problem")

  map("q", M.close, "close")
  map("<Esc>", M.close, "close")

  map("t", function()
    local p = current()
    if not p then
      return
    end
    if progress.is_solved(p) then
      progress.unmark(p, function(err)
        vim.schedule(function()
          if err then util.err(err) end
        end)
      end)
    else
      progress.mark(p, function(err)
        vim.schedule(function()
          if err then util.err(err) end
        end)
      end)
    end
    render()
  end, "toggle solved")

  map("o", function()
    local p = current()
    if p and p.leetcode then
      vim.ui.open("https://leetcode.com/problems/" .. p.leetcode .. "/")
    end
  end, "open on LeetCode")

  map("v", function()
    local p = current()
    if p and p.video then
      vim.ui.open("https://youtube.com/watch?v=" .. p.video)
    else
      util.notify("no video for this problem")
    end
  end, "open the NeetCode video")
end

function M.open(pattern, list)
  if not pattern then
    return
  end
  state.pattern = pattern
  state.list = list or config.options.list

  if is_open() then
    tabs.name_buffer(state.buf, pattern)
    render()
    return
  end

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "neetcode-problems"
  tabs.name_buffer(state.buf, pattern)

  local width = math.min(vim.o.columns - 8, 92)
  local height = math.min(vim.o.lines - 8, 30)
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = config.options.ui.border,
    title = " " .. pattern .. " ",
    title_pos = "center",
  })
  vim.wo[state.win].cursorline = true

  keymaps()
  render()
  pcall(vim.api.nvim_win_set_cursor, state.win, { 3, 0 })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.win),
    once = true,
    callback = function()
      state.win, state.buf = nil, nil
    end,
  })
  if not state.subscribed then
    state.subscribed = true
    progress.on_update(function()
      vim.schedule(function()
        pcall(render)
      end)
    end)
  end
end

return M
