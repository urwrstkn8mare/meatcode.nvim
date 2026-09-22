local availability = require("meatcode.catalog.availability")
local catalog = require("meatcode.catalog.problems")
local config = require("meatcode.config")
local lang_info = require("meatcode.lang")
local progress = require("meatcode.progress")
local providers = require("meatcode.providers")
local util = require("meatcode.util")

local M = {}

local state = { picker = nil, prompt_buf = nil, subscribed = false, from_home = false, hover_group = nil }

local function streak_text()
  local provider = providers.get("leetcode")
  if not provider.auth.is_logged_in() then return "log in for streak" end
  local streak = catalog.streak()
  if not streak then return "streak unavailable" end
  local days = tonumber(streak.streakCount) or 0
  local today = streak.currentDayCompleted and "today complete" or "solve one today"
  return string.format("%d day%s · %s", days, days == 1 and "" or "s", today)
end

local function telescope()
  local modules = {}
  for _, name in ipairs({
    "telescope.pickers", "telescope.finders", "telescope.config",
    "telescope.actions", "telescope.actions.state", "telescope.pickers.entry_display",
  }) do
    local ok, module = pcall(require, name)
    if not ok then return nil, "Telescope is required for :MeatCode list" end
    modules[name] = module
  end
  return modules
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
  local lc = problem.providers.leetcode
  if lc and lc.frontend_id and lc.frontend_id ~= "" then return lc.frontend_id .. "." end
  local lint = problem.providers.lintcode
  if lint then return "L" .. tostring(lint.id) end
  local nc = problem.providers.neetcode
  return nc and "N" .. tostring(nc.id) or ""
end

local function entries(modules)
  local cat = catalog.get()
  local lang = config.options.lang
  local problems = {}
  for _, problem in ipairs(cat and cat.problems or {}) do
    if not availability.is_unsupported(problem, lang) then table.insert(problems, problem) end
  end
  local displayer = modules["telescope.pickers.entry_display"].create({
    separator = " ",
    items = {
      { width = 4 }, { width = 7 }, { remaining = true }, { width = 8 }, { width = 10 },
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
      return {
        value = problem,
        ordinal = table.concat({
          number_text(problem), problem.name or "", problem.difficulty or "",
          table.concat(ids, " "), table.concat(problem.topics or {}, " "),
          table.concat(problem.companies or {}, " "),
        }, " "),
        display = function()
          return displayer({
            { tostring(count), count > 0 and "MeatCodeDone" or "MeatCodeTodo" },
            number_text(problem),
            count > 0 and { problem.name, "MeatCodeDone" } or problem.name,
            { problem.difficulty, "MeatCode" .. problem.difficulty },
            { provider_text(problem), "MeatCodeMuted" },
          })
        end,
      }
    end,
  })
end

local function picker_open()
  return state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf)
end

local function title()
  local cat = catalog.get()
  return string.format(" Problems · %d merged · LC %d · NC %d · LI %d · %s ",
    cat and #cat.problems or 0,
    catalog.provider_count("leetcode"), catalog.provider_count("neetcode"),
    catalog.provider_count("lintcode"), streak_text())
end

local function refresh()
  if not picker_open() or not state.picker then return end
  local modules = telescope()
  if not modules then return end
  local prompt_title = title()
  state.picker.prompt_title = prompt_title
  if state.picker.layout and state.picker.layout.prompt and state.picker.layout.prompt.border then
    state.picker.layout.prompt.border:change_title(prompt_title)
  end
  state.picker:refresh(entries(modules), { reset_prompt = false })
end

--- Probe an unchecked entry's language support in the background; hide it
--- from the list the moment the probe confirms the configured language is
--- unsupported everywhere. Already-checked entries are a cache hit and
--- return instantly, so this is cheap to call on every hover.
local function probe(problem)
  if availability.known(problem) then return end
  availability.check(problem, function(languages)
    vim.schedule(function()
      if not vim.tbl_contains(languages or {}, config.options.lang) then
        refresh()
      end
    end)
  end)
end

local function stop_hover_watch()
  if state.hover_group then
    pcall(vim.api.nvim_del_augroup_by_id, state.hover_group)
    state.hover_group = nil
  end
end

--- Probe whatever entry is under the cursor as the user moves through the
--- list, debounced so holding j/k doesn't fire a probe per line crossed.
local function watch_hover()
  stop_hover_watch()
  local bufnr = state.picker and state.picker.results_bufnr
  if not bufnr then return end
  state.hover_group = vim.api.nvim_create_augroup("MeatCodeListHover", { clear = true })
  local generation = 0
  local function on_move()
    generation = generation + 1
    local gen = generation
    vim.defer_fn(function()
      if gen ~= generation or not picker_open() or not state.picker then return end
      local ok, entry = pcall(function() return state.picker:get_selection() end)
      if ok and entry and entry.value then probe(entry.value) end
    end, 150)
  end
  vim.api.nvim_create_autocmd("CursorMoved", { group = state.hover_group, buffer = bufnr, callback = on_move })
  on_move()
end

local function open_picker(query)
  local modules, err = telescope()
  if not modules then return util.err(err) end
  local actions = modules["telescope.actions"]
  local action_state = modules["telescope.actions.state"]

  state.picker = modules["telescope.pickers"].new({}, {
    prompt_title = title(),
    results_title = " <CR> solve · <C-o> browser · q back ",
    finder = entries(modules),
    sorter = modules["telescope.config"].values.generic_sorter({}),
    previewer = false,
    default_text = vim.trim(query or ""),
    initial_mode = "insert",
    sorting_strategy = "ascending",
    layout_strategy = "vertical",
    layout_config = { width = 9999, height = 9999, prompt_position = "top" },
    attach_mappings = function(prompt_buf, map)
      state.prompt_buf = prompt_buf
      local function close()
        stop_hover_watch()
        actions.close(prompt_buf)
        state.prompt_buf, state.picker = nil, nil
      end
      local function open_selected(problem)
        close()
        -- Leave the page stack alone so closing the problem can reveal it.
        require("meatcode.ui.problem").open(problem)
      end
      actions.select_default:replace(function()
        local selected = action_state.get_selected_entry()
        if not selected then return end
        local problem = selected.value
        local known = availability.known(problem)
        if known then
          if vim.tbl_contains(known, config.options.lang) then
            open_selected(problem)
          else
            util.err(problem.name .. " doesn't support " .. lang_info.name(config.options.lang))
            refresh()
          end
          return
        end
        util.notify("Checking " .. problem.name .. "'s language support…")
        availability.check(problem, function(languages)
          vim.schedule(function()
            if languages and #languages > 0 and not vim.tbl_contains(languages, config.options.lang) then
              util.err(problem.name .. " doesn't support " .. lang_info.name(config.options.lang))
              refresh()
              return
            end
            open_selected(problem)
          end)
        end)
      end)
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
      return true
    end,
  })
  state.picker:find()
  watch_hover()
end

function M.open(query)
  require("meatcode.catalog").load()
  catalog.load()
  catalog.refresh_mappings()
  progress.load()

  if picker_open() then
    local win = vim.fn.bufwinid(state.prompt_buf)
    if win ~= -1 then vim.api.nvim_set_current_win(win) end
    return
  end

  local function ready(err, cat)
    vim.schedule(function()
      if not cat then return util.err("could not fetch problems: " .. tostring(err or "empty catalog")) end
      if not picker_open() then open_picker(query) end
    end)
  end

  if catalog.get() then
    open_picker(query)
  else
    util.notify("fetching problem catalogs…")
    catalog.ensure(ready)
  end

  progress.sync(function(err)
    if err and not catalog.get() then
      vim.schedule(function() util.err("could not sync problems: " .. err) end)
    end
  end)

  if not state.subscribed then
    state.subscribed = true
    catalog.on_update(function() vim.schedule(refresh) end)
    progress.on_update(function() vim.schedule(refresh) end)
  end
end

function M.refresh()
  refresh()
end

return M
