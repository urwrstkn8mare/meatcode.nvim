local availability = require("meatcode.catalog.availability")
local catalog = require("meatcode.catalog")
local config = require("meatcode.config")
local hl = require("meatcode.ui.highlight")
local lang_info = require("meatcode.lang")
local progress = require("meatcode.progress")
local providers = require("meatcode.providers")
local util = require("meatcode.util")

--- Floating, fuzzable problem picker overlay for a single roadmap topic.
local M = {}

local state = {
  picker = nil,
  prompt_buf = nil,
  pattern = nil,
  list = nil,
  opening_key = nil,
  subscribed = false,
}

local entry_cache = {}

local function telescope()
  local modules = {}
  for _, name in ipairs({
    "telescope.pickers", "telescope.finders", "telescope.config",
    "telescope.actions", "telescope.actions.state", "telescope.pickers.entry_display",
  }) do
    local ok, module = pcall(require, name)
    if not ok then return nil end
    modules[name] = module
  end
  return modules
end

local function picker_open()
  return state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf)
end

local function close_picker()
  if not picker_open() then return end
  local modules = telescope()
  if modules then pcall(modules["telescope.actions"].close, state.prompt_buf) end
  state.prompt_buf, state.picker = nil, nil
end

local function title()
  local problems = catalog.pattern_problems(state.pattern, state.list)
  local done = 0
  for _, p in ipairs(problems) do
    if progress.is_solved(p) then done = done + 1 end
  end
  return string.format("%s — %d/%d completed · %s",
    state.pattern, done, #problems, catalog.LIST_LABELS[state.list] or state.list)
end

local function provider_text(problem)
  local labels = {}
  for _, name in ipairs(providers.NAMES) do
    if providers.available(problem, name) then
      table.insert(labels, ({ leetcode = "LC", neetcode = "NC", lintcode = "LI" })[name])
    end
  end
  return table.concat(labels, "/")
end

local function number_text(problem)
  local num = nil
  local lc = problem.providers and problem.providers.leetcode
  if lc then
    if lc.frontend_id then
      num = tostring(lc.frontend_id)
    elseif type(lc.id) == "number" then
      num = tostring(lc.id)
    elseif type(lc.id) == "string" and lc.id:match("^%d+$") then
      num = lc.id
    end
  end

  if not num then
    local nc = problem.providers and problem.providers.neetcode
    if nc and nc.github then
      local n = nc.github:match("^(%d+)")
      if n then num = tostring(tonumber(n)) end
    end
  end

  if not num then
    local full_cat = require("meatcode.catalog.problems").get()
      or require("meatcode.catalog.problems").load()
    if full_cat and full_cat.by_provider and full_cat.by_provider.leetcode and lc and lc.id then
      local full = full_cat.by_provider.leetcode[tostring(lc.id)]
      local full_lc = full and full.providers and full.providers.leetcode
      if full_lc and full_lc.frontend_id then num = tostring(full_lc.frontend_id) end
    end
  end

  if not num then
    local nc = problem.providers and problem.providers.neetcode
    if nc and nc.id and type(nc.id) == "number" then
      num = "N" .. tostring(nc.id)
    end
  end

  if num and num ~= "" then
    return num .. "."
  end
  return ""
end

local function entries(modules)
  local problems = catalog.pattern_problems(state.pattern, state.list)
  local displayer = modules["telescope.pickers.entry_display"].create({
    separator = " ",
    items = {
      { width = 4 },
      { width = 6 },
      { remaining = true },
      { width = 8 },
      { width = 14 },
    },
  })

  return modules["telescope.finders"].new_table({
    results = problems,
    entry_maker = function(problem)
      local count = progress.completion_count(problem)
      local ids = {}
      for name, record in pairs(problem.providers or {}) do
        table.insert(ids, name .. " " .. tostring(record.id))
      end
      table.sort(ids)
      local ordinal = table.concat({
        number_text(problem), problem.name or "", problem.difficulty or "",
        table.concat(ids, " "), table.concat(problem.topics or {}, " "),
        table.concat(problem.companies or {}, " "),
      }, " ")
      local function display()
        local lock = ""
        local nc = problem.providers and problem.providers.neetcode
        if nc and nc.paid then lock = " [pro]" end
        return displayer({
          { tostring(count), count > 0 and "MeatCodeDone" or "MeatCodeTodo" },
          number_text(problem),
          count > 0 and { problem.name, "MeatCodeDone" } or problem.name,
          { problem.difficulty, hl.difficulty(problem.difficulty) },
          { provider_text(problem) .. lock, (nc and nc.paid) and "MeatCodeWarn" or "MeatCodeMuted" },
        })
      end
      local key = providers.problem_key(problem)
      local cached = key and entry_cache[key]
      if cached then
        cached.value, cached.ordinal, cached.display = problem, ordinal, display
        return cached
      end
      local entry = { value = problem, ordinal = ordinal, display = display }
      if key then entry_cache[key] = entry end
      return entry
    end,
  })
end

local function refresh()
  if not picker_open() or not state.picker then return end
  local modules = telescope()
  if not modules then return end
  local prompt_title = title()
  state.picker.prompt_title = prompt_title
  if state.picker.layout and state.picker.layout.prompt and state.picker.layout.prompt.border then
    pcall(function() state.picker.layout.prompt.border:change_title(prompt_title) end)
  end
  state.picker:refresh(entries(modules), { reset_prompt = false })
end

local function verdict_message(problem)
  if availability.is_locked(problem) then
    return problem.name .. " isn't accessible on any provider you have unlocked"
  end
  if availability.is_unsupported(problem, config.options.lang) then
    return problem.name .. " doesn't support " .. lang_info.name(config.options.lang)
  end
  return problem.name .. " supports " .. lang_info.name(config.options.lang)
end

local function probe(problem)
  if availability.known(problem) or availability.is_checking(problem) then return end
  availability.check(problem, function(_, _, _)
    -- Availability result cached for select_current check
  end)
end

local function on_move()
  vim.schedule(function()
    if not picker_open() or not state.picker then return end
    local modules = telescope()
    if not modules then return end
    local selected = modules["telescope.actions.state"].get_selected_entry()
    if selected and selected.value then probe(selected.value) end
  end)
end

local function watch_hover(actions)
  for _, name in ipairs({
    "move_selection_next", "move_selection_previous",
    "move_selection_better", "move_selection_worse",
  }) do
    if actions[name] then
      actions[name]:enhance({ post = on_move })
    end
  end
end

local function fallback(pattern, list)
  local problems = catalog.pattern_problems(pattern, list)
  if #problems == 0 then return util.notify("No problems found for " .. pattern) end
  local done = 0
  for _, p in ipairs(problems) do
    if progress.is_solved(p) then done = done + 1 end
  end
  local prompt = string.format("%s — %d/%d completed · %s", pattern, done, #problems, catalog.LIST_LABELS[list] or list)
  vim.ui.select(problems, {
    prompt = prompt,
    format_item = function(p)
      local count = progress.completion_count(p)
      local nc = p.providers and p.providers.neetcode
      local lock = (nc and nc.paid) and " [pro]" or ""
      return string.format("[%2d] %-40s %-7s%s", count, p.name, p.difficulty, lock)
    end,
  }, function(choice)
    if not choice then return end
    local key = providers.problem_key(choice)
    state.opening_key = key
    require("meatcode.ui.problem").open(choice, {
      guard = function() return state.opening_key == key end,
    })
  end)
end

function M.close()
  close_picker()
end

function M.refresh()
  refresh()
end

function M.open(pattern, list)
  if not pattern then return end
  catalog.load()
  progress.load()
  state.pattern = pattern
  state.list = list or config.options.list

  if picker_open() then
    close_picker()
  end

  local modules = telescope()
  if not modules then
    return fallback(state.pattern, state.list)
  end

  local actions = modules["telescope.actions"]
  local action_state = modules["telescope.actions.state"]

  state.picker = modules["telescope.pickers"].new({}, {
    prompt_title = title(),
    results_title = " <CR> solve · <C-o> browser · q / <Esc> back ",
    finder = entries(modules),
    sorter = modules["telescope.config"].values.generic_sorter({}),
    previewer = false,
    initial_mode = "insert",
    sorting_strategy = "ascending",
    selection_strategy = "follow",
    layout_strategy = "vertical",
    layout_config = {
      prompt_position = "top",
      width = function(_, max_columns, _)
        return math.min(max_columns - 4, math.max(60, math.floor(max_columns * 0.75)))
      end,
      height = function(_, _, max_lines)
        return math.min(max_lines - 4, math.max(12, math.floor(max_lines * 0.65)))
      end,
    },
    on_complete = { on_move },
    attach_mappings = function(prompt_buf, map)
      state.prompt_buf = prompt_buf

      local function close()
        close_picker()
      end

      local function open_selected(problem)
        local key = providers.problem_key(problem)
        state.opening_key = key
        require("meatcode.ui.problem").open(problem, {
          guard = function() return state.opening_key == key end,
          will_show = close,
        })
      end

      local function unsupported(problem)
        util.err(problem.name .. " doesn't support " .. lang_info.name(config.options.lang))
      end

      local function locked_out(problem)
        util.err(problem.name .. " isn't accessible on any provider you have unlocked")
      end

      local function decide(problem)
        if availability.is_locked(problem) then
          locked_out(problem)
        elseif availability.is_unsupported(problem, config.options.lang) then
          unsupported(problem)
        else
          open_selected(problem)
        end
      end

      local function select_current()
        local selected = action_state.get_selected_entry()
        if not selected then return end
        local problem = selected.value
        if availability.known(problem) then
          decide(problem)
          return
        end
        local handle = util.progress("Checking " .. problem.name .. "'s language support…")
        availability.check(problem, function(_, _, err)
          vim.schedule(function()
            if err then
              handle:cancel()
              util.err(problem.name .. ": couldn't check language support — " .. err)
              return
            end
            handle:finish(verdict_message(problem))
            decide(problem)
          end)
        end)
      end

      actions.select_default:replace(select_current)
      actions.select_horizontal:replace(select_current)
      actions.select_vertical:replace(select_current)
      actions.select_tab:replace(select_current)
      actions.delete_buffer:replace(function() end)

      local function open_browser()
        local selected = action_state.get_selected_entry()
        if not selected then return end
        require("meatcode.ui.links").open(selected.value)
      end

      map("i", "<C-o>", open_browser)
      map("n", "o", open_browser)
      map("i", "<Esc>", close)
      map("n", "q", close)
      map("n", "<Esc>", close)

      watch_hover(actions)
      return true
    end,
  })

  state.picker:find()

  if not state.subscribed then
    state.subscribed = true
    catalog.on_update(function() vim.schedule(refresh) end)
    progress.on_update(function() vim.schedule(refresh) end)
    availability.on_update(function() vim.schedule(refresh) end)
  end
end

return M
