local catalog = require("meatcode.catalog")
local config = require("meatcode.config")
local hl = require("meatcode.ui.highlight")
local pages = require("meatcode.ui.pages")
local progress = require("meatcode.progress")
local util = require("meatcode.util")

--- Problem list for a single roadmap topic, as a full page on the nav stack.
local M = {}

local state = { buf = nil, rows = {}, pattern = nil, list = nil, subscribed = false }

local function is_open()
  return state.buf and vim.api.nvim_buf_is_valid(state.buf) and pages.buf() == state.buf
end

function M.close()
  if state.buf and pages.buf() == state.buf then pages.pop() end
  state.buf = nil
end

local function render()
  if not is_open() then
    return
  end

  local problems = catalog.pattern_problems(state.pattern, state.list)
  state.rows = problems

  local done = 0
  for _, p in ipairs(problems) do
    if progress.is_solved(p) then
      done = done + 1
    end
  end

  -- Build every row left-aligned, then centre the block as a unit so the
  -- columns stay lined up.
  local entries = {}
  local header = string.format("%s — %d/%d completed · %s",
    state.pattern, done, #problems, catalog.LIST_LABELS[state.list] or state.list)
  table.insert(entries, { text = header, spans = { { 0, #header, "MeatCodeHeader" } } })
  table.insert(entries, { text = "" })

  for _, p in ipairs(problems) do
    local count = progress.completion_count(p)
    local mark = string.format("%2d", count)
    local nc = p.providers and p.providers.neetcode
    local lock = nc and nc.paid and "  [pro]" or ""
    local line = string.format("%s  %-52s %-7s%s", mark, p.name, p.difficulty, lock)
    local row_spans = { { 0, #mark, count > 0 and "MeatCodeDone" or "MeatCodeTodo" } }
    if count > 0 then
      table.insert(row_spans, { 0, #line, "MeatCodeDone" })
    end
    local dcol = line:find(p.difficulty, 1, true)
    if dcol then
      table.insert(row_spans, { dcol - 1, dcol - 1 + #p.difficulty, hl.difficulty(p.difficulty) })
    end
    if lock ~= "" then
      table.insert(row_spans, { #line - #lock, #line, "MeatCodeWarn" })
    end
    table.insert(entries, { text = line, spans = row_spans })
  end

  local width = vim.api.nvim_win_get_width(0)
  local block_width = 0
  for _, entry in ipairs(entries) do
    block_width = math.max(block_width, vim.fn.strdisplaywidth(entry.text))
  end
  local prefix = string.rep(" ", math.max(0, math.floor((width - block_width) / 2)))

  local lines, spans = { "" }, {}
  for _, entry in ipairs(entries) do
    table.insert(lines, entry.text == "" and "" or prefix .. entry.text)
    for _, span in ipairs(entry.spans or {}) do
      table.insert(spans, { #lines - 1, span[1] + #prefix, span[2] + #prefix, span[3] })
    end
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
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return state.rows[row - 3]
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
    -- Keep this page on the stack; the problem opens in a new tab and closing
    -- it should land back here rather than skipping to the roadmap.
    require("meatcode.ui.problem").open(p)
  end, "open problem")

  map("q", M.close, "back")
  map("<Esc>", M.close, "back")


  map("o", function()
    local p = current()
    if not p then return end
    require("meatcode.ui.links").open(p)
  end, "open a problem link")
end


function M.open(pattern, list)
  if not pattern then
    return
  end
  catalog.load()
  state.pattern = pattern
  state.list = list or config.options.list

  if is_open() then
    render()
    return
  end

  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].filetype = "meatcode-roadmap-problems"
  pages.push({ id = "problems", buf = state.buf, title = pattern, on_show = render })
  vim.wo[0].cursorline = true

  keymaps()
  render()
  pcall(vim.api.nvim_win_set_cursor, 0, { 4, 0 })
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
