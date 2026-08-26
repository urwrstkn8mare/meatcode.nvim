local catalog = require("neetcode.catalog")
local config = require("neetcode.config")
local dag = require("neetcode.ui.dag")
local graph = require("neetcode.catalog.graph")
local hl = require("neetcode.ui.highlight")
local progress = require("neetcode.progress")
local tabs = require("neetcode.ui.tab")
local util = require("neetcode.util")

--- The roadmap screen: an ASCII rendering of the NeetCode topic DAG with per
--- topic progress, plus list switching and topic drill-down.
local M = {}

local HIDDEN_CURSOR = "a:NeetCodeHiddenCursor"

local state = {
  buf = nil, win = nil, tab = nil, selected = nil, layout = nil, subscribed = false,
  guicursor = nil,
}

local hide_token = 0

local function is_open()
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

--- The roadmap is navigated by moving a highlighted node, so the terminal
--- cursor only adds noise. Blend it away while this window has focus, and put
--- 'guicursor' back on every path out — including a crash-adjacent one.
---
--- Moving the cursor (to keep the selected node in view) makes many terminals
--- un-hide it, so this is re-applied after every move rather than once on enter.
local function hide_cursor()
  if not config.options.ui.hide_cursor then
    return
  end
  if not is_open() or vim.api.nvim_get_current_win() ~= state.win then
    return
  end
  vim.api.nvim_set_hl(0, "NeetCodeHiddenCursor", { blend = 100, nocombine = true })
  if not state.guicursor then
    local current = vim.o.guicursor
    state.guicursor = (current ~= "" and current ~= HIDDEN_CURSOR)
      and current
      or "n-v-c-sm:block,i-ci-ve:ver25,r-cr-o:hor20"
  end
  vim.o.guicursor = HIDDEN_CURSOR
  -- DEC civis. Neovim already sends this for blend=100, but a CUP (the
  -- cursor move onto the selected node) often makes the terminal show it
  -- again; repeating the sequence after the draw keeps it gone.
  hide_token = hide_token + 1
  local token = hide_token
  if vim.fn.has("gui_running") == 0 then
    vim.schedule(function()
      if token ~= hide_token then
        return
      end
      if is_open() and vim.api.nvim_get_current_win() == state.win then
        pcall(vim.api.nvim_ui_send, "\27[?25l")
      end
    end)
  end
end

local function show_cursor()
  hide_token = hide_token + 1
  if state.guicursor then
    vim.o.guicursor = state.guicursor
    state.guicursor = nil
  end
  if vim.fn.has("gui_running") == 0 then
    pcall(vim.api.nvim_ui_send, "\27[?25h")
  end
end

local HEADER_ROWS = 3

local function summary_line(width)
  local s = progress.summary(config.options.list)
  local d = s.by_difficulty
  local list = config.options.list
  local left = string.format("  %s", catalog.LIST_LABELS[list] or list)
  local right = string.format(
    "Easy %d/%d   Medium %d/%d   Hard %d/%d   ·   %d/%d solved  ",
    d.Easy.done, d.Easy.total, d.Medium.done, d.Medium.total,
    d.Hard.done, d.Hard.total, s.done, s.total)

  local pad = width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right)
  if pad < 1 then
    return left .. " " .. right
  end
  return left .. string.rep(" ", pad) .. right
end

local function render()
  if not is_open() then
    return
  end

  local width = vim.api.nvim_win_get_width(state.win)

  -- First run: there is no catalog yet. Say so rather than drawing a roadmap
  -- of empty progress bars; the update listener re-renders when it arrives.
  if not catalog.get() then
    local lines = { "", "", util.center("Fetching the problem catalog from neetcode.io…", width) }
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.bo[state.buf].modifiable = false
    hl.apply(state.buf, { { 2, 0, #lines[3], "NeetCodeMuted" } })
    return
  end

  local layout = dag.render({
    ranks = graph.ranks(),
    edges = graph.edges,
    width = width,
    node_width = config.options.ui.node_width,
    short_names = graph.short_names,
    selected = state.selected,
    progress = function(name)
      return progress.pattern_progress(name, config.options.list)
    end,
  })
  state.layout = layout

  local lines = {
    summary_line(width),
    string.rep("─", math.max(10, width - 2)),
    "",
  }
  for _, l in ipairs(layout.lines) do
    table.insert(lines, l)
  end
  table.insert(lines, "")

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  local spans = {
    { 0, 0, #lines[1], "NeetCodeHeader" },
    { 1, 0, #lines[2], "NeetCodeMuted" },
  }
  for _, s in ipairs(layout.spans) do
    table.insert(spans, { s[1] + HEADER_ROWS, s[2], s[3], s[4] })
  end
  hl.apply(state.buf, spans)

  -- Park the cursor on the selected node so scrolling follows navigation.
  local pos = layout.positions[state.selected]
  if pos then
    local row = pos.row + HEADER_ROWS + 2
    pcall(vim.api.nvim_win_set_cursor, state.win, { math.min(row, #lines), math.max(pos.col, 0) })
  end
  hide_cursor()
end

--- Move the selection. `dir` is one of "up" | "down" | "left" | "right".
local function navigate(dir)
  local layout = state.layout
  if not layout then
    return
  end
  local cur = layout.positions[state.selected]
  if not cur then
    return
  end

  local best, best_score = nil, math.huge
  for name, pos in pairs(layout.positions) do
    if name ~= state.selected then
      local ok
      if dir == "up" then
        ok = pos.rank == cur.rank - 1
      elseif dir == "down" then
        ok = pos.rank == cur.rank + 1
      elseif dir == "left" then
        ok = pos.rank == cur.rank and pos.center < cur.center
      else
        ok = pos.rank == cur.rank and pos.center > cur.center
      end

      if ok then
        local score = math.abs(pos.center - cur.center)
        if score < best_score then
          best, best_score = name, score
        end
      end
    end
  end

  -- Falling off the end of a rank wraps to the nearest node one rank over.
  if not best and (dir == "left" or dir == "right") then
    return
  end
  if best then
    state.selected = best
    render()
  end
end

local function cycle_list(delta)
  local idx = 1
  for i, name in ipairs(catalog.LISTS) do
    if name == config.options.list then
      idx = i
    end
  end
  idx = ((idx - 1 + delta) % #catalog.LISTS) + 1
  config.options.list = catalog.LISTS[idx]
  render()
end

function M.close()
  show_cursor()
  pcall(vim.api.nvim_del_augroup_by_name, "NeetCodeRoadmapCursor")
  if state.tab then
    tabs.clear(state.tab)
  end
  if is_open() then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win, state.buf, state.tab = nil, nil, nil
end

local function cursor_autocmds()
  local group = vim.api.nvim_create_augroup("NeetCodeRoadmapCursor", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "CursorMoved" }, {
    group = group, buffer = state.buf, callback = hide_cursor,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "BufWipeout" }, {
    group = group, buffer = state.buf, callback = show_cursor,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = show_cursor })
  -- The float dies with its tab (e.g. a problem tab closing). Restore the
  -- cursor and drop stale handles so the next :NeetCode can reopen cleanly.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      if tonumber(ev.match) ~= state.win then
        return
      end
      show_cursor()
      if state.tab then
        tabs.clear(state.tab)
      end
      state.win, state.buf, state.tab = nil, nil, nil
    end,
  })
  -- CmdlineEnter's pattern is the cmdline type, so these are not buffer-local.
  vim.api.nvim_create_autocmd("CmdlineEnter", {
    group = group,
    callback = function()
      if is_open() and vim.api.nvim_get_current_win() == state.win then
        show_cursor()
      end
    end,
  })
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    callback = hide_cursor,
  })
end

local function keymaps()
  local keys = config.options.keys.roadmap
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, silent = true, desc = desc })
  end

  map("j", function() navigate("down") end, "next topic")
  map("k", function() navigate("up") end, "previous topic")
  map("h", function() navigate("left") end, "topic to the left")
  map("l", function() navigate("right") end, "topic to the right")
  map("<Down>", function() navigate("down") end, "next topic")
  map("<Up>", function() navigate("up") end, "previous topic")
  map("<Left>", function() navigate("left") end, "topic to the left")
  map("<Right>", function() navigate("right") end, "topic to the right")

  map(keys.open, function()
    require("neetcode.ui.problems").open(state.selected, config.options.list)
  end, "open topic")

  map(keys.cycle_list, function() cycle_list(1) end, "next problem list")
  map("H", function() cycle_list(-1) end, "previous problem list")
  map(keys.quit, M.close, "close")
  map("<Esc>", M.close, "close")

  map(keys.sync, function()
    util.notify("syncing catalog and progress…")
    catalog.sync(function(err)
      vim.schedule(function()
        if err then
          util.err("catalog sync failed: " .. err)
        else
          util.notify("catalog updated (" .. catalog.age_string() .. ")")
          render()
        end
      end)
    end)
    progress.sync(function(err)
      vim.schedule(function()
        if err then
          util.err("progress sync failed: " .. err)
        else
          render()
        end
      end)
    end)
  end, "sync")

  map("?", function()
    util.notify(table.concat({
      "hjkl / arrows  move between topics",
      keys.open .. "             open the selected topic",
      keys.cycle_list .. " / H          switch problem list",
      keys.sync .. "              sync catalog + progress",
      keys.quit .. "              close",
    }, "\n"))
  end, "help")
end

function M.open()
  if is_open() then
    vim.api.nvim_set_current_win(state.win)
    hide_cursor()
    return
  end

  catalog.load()
  progress.load()
  state.selected = state.selected or "Arrays & Hashing"

  state.tab = vim.api.nvim_get_current_tabpage()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "neetcode-roadmap"
  tabs.name_buffer(state.buf, "roadmap")
  tabs.set(state.tab, "roadmap")

  local width = math.min(vim.o.columns - 4, 130)
  local height = vim.o.lines - 6
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = config.options.ui.border,
    title = " NeetCode Roadmap ",
    title_pos = "center",
  })

  vim.wo[state.win].wrap = false
  vim.wo[state.win].cursorline = false
  vim.bo[state.buf].modifiable = false

  keymaps()
  cursor_autocmds()
  hide_cursor()
  render()

  -- Refresh when background syncs land. Registered once for the lifetime of the
  -- session; render() is a no-op while the window is closed.
  if not state.subscribed then
    state.subscribed = true
    catalog.on_update(function()
      vim.schedule(function()
        pcall(render)
      end)
    end)
    progress.on_update(function()
      vim.schedule(function()
        pcall(render)
      end)
    end)
  end

  -- Progress is cheap to refetch and keeps the roadmap honest across devices.
  progress.sync(function() end)
end

function M.refresh()
  render()
end

return M
