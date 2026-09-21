local auth = require("meatcode.api.leetcode_auth")
local catalog = require("meatcode.catalog.leetcode")
local nc_catalog = require("meatcode.catalog")
local progress = require("meatcode.progress")
local util = require("meatcode.util")

local M = {}

local state = {
  picker = nil,
  prompt_buf = nil,
  subscribed = false,
}

local function streak_text()
  if not auth.is_logged_in() then
    return "log in for streak"
  end
  local streak = catalog.streak()
  if not streak then
    return "streak unavailable"
  end
  local days = tonumber(streak.streakCount) or 0
  local today = streak.currentDayCompleted and "today complete" or "solve one today"
  return string.format("%d day%s · %s", days, days == 1 and "" or "s", today)
end

local function telescope()
  local modules = {}
  for _, name in ipairs({
    "telescope.pickers",
    "telescope.finders",
    "telescope.config",
    "telescope.actions",
    "telescope.actions.state",
    "telescope.pickers.entry_display",
  }) do
    local ok, module = pcall(require, name)
    if not ok then
      return nil, "Telescope is required for :MeatCode list"
    end
    modules[name] = module
  end
  return modules
end

local function entries(modules)
  local cat = catalog.get()
  local displayer = modules["telescope.pickers.entry_display"].create({
    separator = " ",
    items = {
      { width = 4 },
      { width = 7 },
      { remaining = true },
      { width = 8 },
      { width = 5 },
    },
  })

  return modules["telescope.finders"].new_table({
    results = cat and cat.problems or {},
    entry_maker = function(problem)
      local count = progress.completion_count(problem)
      return {
        value = problem,
        ordinal = table.concat({
          problem.frontend_id or "",
          problem.name or "",
          problem.leetcode or "",
          problem.difficulty or "",
        }, " "),
        display = function()
          return displayer({
            { tostring(count), count > 0 and "MeatCodeDone" or "MeatCodeTodo" },
            problem.frontend_id ~= "" and (problem.frontend_id .. ".") or "",
            count > 0 and { problem.name, "MeatCodeDone" } or problem.name,
            { problem.difficulty, "MeatCode" .. problem.difficulty },
            problem.paid and { "[pro]", "MeatCodeWarn" } or "",
          })
        end,
      }
    end,
  })
end

local function picker_open()
  return state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf)
end

local function refresh()
  if not picker_open() or not state.picker then
    return
  end
  local modules = telescope()
  if modules then
    local cat = catalog.get()
    local title = string.format(" LeetCode · %d problems · %s ",
      cat and #cat.problems or 0, streak_text())
    state.picker.prompt_title = title
    if state.picker.layout and state.picker.layout.prompt
        and state.picker.layout.prompt.border then
      state.picker.layout.prompt.border:change_title(title)
    end
    state.picker:refresh(entries(modules), { reset_prompt = false })
  end
end

local function open_picker(query)
  local modules, err = telescope()
  if not modules then
    return util.err(err)
  end

  local actions = modules["telescope.actions"]
  local action_state = modules["telescope.actions.state"]
  local cat = catalog.get()
  local count = cat and #cat.problems or 0

  state.picker = modules["telescope.pickers"].new({}, {
    prompt_title = string.format(" LeetCode · %d problems · %s ", count, streak_text()),
    results_title = " <CR> solve · <C-o> browser · :MeatCode random · :MeatCode daily ",
    finder = entries(modules),
    sorter = modules["telescope.config"].values.generic_sorter({}),
    previewer = false,
    default_text = vim.trim(query or ""),
    initial_mode = "insert",
    sorting_strategy = "ascending",
    layout_strategy = "vertical",
    layout_config = {
      width = 0.98,
      height = 0.95,
      prompt_position = "top",
    },
    attach_mappings = function(prompt_buf, map)
      state.prompt_buf = prompt_buf
      actions.select_default:replace(function()
        local selected = action_state.get_selected_entry()
        if not selected then
          return
        end
        actions.close(prompt_buf)
        state.prompt_buf, state.picker = nil, nil
        require("meatcode.ui.problem").open(selected.value)
      end)

      local function open_browser()
        local selected = action_state.get_selected_entry()
        if selected then
          vim.ui.open("https://leetcode.com/problems/" .. selected.value.leetcode .. "/")
        end
      end
      map("i", "<C-o>", open_browser)
      map("n", "o", open_browser)
      return true
    end,
  })
  state.picker:find()
end

function M.open(query)
  nc_catalog.load()
  catalog.load()
  catalog.refresh_mappings()
  progress.load()

  if picker_open() then
    local win = vim.fn.bufwinid(state.prompt_buf)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    end
    return
  end

  local function ready(err, cat)
    vim.schedule(function()
      if not cat then
        return util.err("could not fetch LeetCode problems: " .. tostring(err or "empty catalog"))
      end
      if not picker_open() then
        open_picker(query)
      end
    end)
  end

  local cached = catalog.get()
  if cached then
    open_picker(query)
  else
    util.notify("fetching LeetCode problems…")
    catalog.ensure(ready)
  end

  -- Opening either top-level view refreshes the catalog and streak in the
  -- background. Completion history stays local and offline-safe.
  progress.sync(function(err)
    if err and not catalog.get() then
      vim.schedule(function() util.err("could not sync LeetCode problems: " .. err) end)
    end
  end)

  if not state.subscribed then
    state.subscribed = true
    catalog.on_update(function()
      vim.schedule(refresh)
    end)
    progress.on_update(function()
      vim.schedule(refresh)
    end)
  end
end

function M.refresh()
  refresh()
end

return M
