local config = require("meatcode.config")
local hl = require("meatcode.ui.highlight")
local providers = require("meatcode.providers")
local tabs = require("meatcode.ui.tab")
local util = require("meatcode.util")

--- Fallback-chain configurator: reorder the content chain (statement, tests,
--- starter) and the submit chain (judge) per slot. Saving persists the chains
--- as the new default for every problem opened afterwards.
local M = {}

local state = { buf = nil, win = nil, rows = {}, slot = "content" }

local function is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

function M.close()
  if is_open() then pcall(vim.api.nvim_win_close, state.win, true) end
  state.win, state.buf, state.rows = nil, nil, {}
end

local function move(slot, from, delta)
  local chain = providers.order(slot)
  local to = from + delta
  if from < 1 or from > #chain or to < 1 or to > #chain then return end
  chain[from], chain[to] = chain[to], chain[from]
  providers.set_order(slot, chain)
  local problem = require("meatcode.ui.problem")
  if problem.refresh_chains then problem.refresh_chains() end
end

local function render()
  if not is_open() then return end
  local lines, spans, rows = { "", "  provider fallback chains", "" }, {}, {}
  table.insert(spans, { 1, 2, 2 + #"provider fallback chains", "MeatCodeHeader" })

  local function section(slot, blurb)
    table.insert(lines, "  " .. slot)
    table.insert(spans, { #lines - 1, 2, 2 + #slot, "MeatCodeMuted" })
    table.insert(lines, "  " .. blurb)
    table.insert(spans, { #lines - 1, 2, #lines[#lines], "MeatCodeMuted" })
    for i, name in ipairs(providers.order(slot)) do
      local backend = providers.get(name)
      local line = string.format("    %d. %s", i, backend.label)
      table.insert(lines, line)
      table.insert(spans, { #lines - 1, 7, #line, "MeatCodeKey" })
      rows[#lines] = { slot = slot, index = i }
    end
    table.insert(lines, "")
  end

  section("content", "statement, visible tests, starter code")
  section("submit", "cloud judge (WIP solution is never touched)")

  table.insert(lines, "  <C-k>/<C-j> move row · <Tab> jump slots · q closes")
  table.insert(spans, { #lines - 1, 2, #lines[#lines], "MeatCodeMuted" })

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

local function keymaps()
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true, desc = desc })
  end
  local function nudge(delta)
    local row = current()
    if not row then return util.notify("put the cursor on a provider row") end
    move(row.slot, row.index, delta)
    render()
    local target = nil
    for linenr, entry in pairs(state.rows) do
      if entry.slot == row.slot and entry.index == row.index + delta then target = linenr end
    end
    if target then pcall(vim.api.nvim_win_set_cursor, state.win, { target, 0 }) end
  end
  map("<C-k>", function() nudge(-1) end, "Move provider earlier")
  map("<C-j>", function() nudge(1) end, "Move provider later")
  map("K", function() nudge(-1) end, "Move provider earlier")
  map("J", function() nudge(1) end, "Move provider later")
  map("<Tab>", function()
    local first = nil
    for linenr, entry in pairs(state.rows) do
      if entry.slot == "submit" and (not first or linenr < first) then first = linenr end
    end
    if first then pcall(vim.api.nvim_win_set_cursor, state.win, { first, 0 }) end
  end, "Jump to submit chain")
  map("q", M.close, "Close chains")
  map("<Esc>", M.close, "Close chains")
end

function M.open()
  if is_open() then
    vim.api.nvim_set_current_win(state.win)
    return
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "meatcode-chains"
  tabs.name_buffer(state.buf, "provider chains")

  local width = math.min(vim.o.columns - 8, 64)
  local height = math.min(vim.o.lines - 8, 20)
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = config.options.ui.border,
    title = " Provider chains ",
    title_pos = "center",
  })
  vim.wo[state.win].cursorline = true

  keymaps()
  render()
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(state.win),
    once = true,
    callback = function() state.win, state.buf = nil, nil end,
  })
end

return M
