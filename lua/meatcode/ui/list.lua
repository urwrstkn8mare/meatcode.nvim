local availability = require("meatcode.catalog.availability")
local catalog = require("meatcode.catalog.problems")
local config = require("meatcode.config")
local lang_info = require("meatcode.lang")
local pages = require("meatcode.ui.pages")
local progress = require("meatcode.progress")
local providers = require("meatcode.providers")
local util = require("meatcode.util")

local M = {}

--- `page_buf` is a placeholder backdrop registered with the page stack so
--- back-navigation (closing a problem opened from here, or q on the list
--- itself) lands on the list rather than falling through to whatever page
--- was under it. The floating picker is the real UI; the page only exists
--- for bookkeeping and gets relaunched via `on_show`.
local state = { picker = nil, prompt_buf = nil, page_buf = nil, query = nil, subscribed = false }

--- Entry tables keyed by `providers.problem_key`, reused (mutated in place,
--- never replaced) across every `entries()` call so a problem's row stays
--- the *same* Lua table across refreshes. Telescope's `follow` selection
--- strategy matches the held selection by table identity (`==`), not by
--- value -- a fresh table per refresh (the previous behaviour) meant it
--- could never find the previously-selected row again, so every background
--- refresh (an availability probe completing, progress syncing, etc.) reset
--- the cursor to the top of the list.
local entry_cache = {}

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
    if not availability.is_unsupported(problem, lang) and not availability.is_locked(problem) then
      table.insert(problems, problem)
    end
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
      local ordinal = table.concat({
        number_text(problem), problem.name or "", problem.difficulty or "",
        table.concat(ids, " "), table.concat(problem.topics or {}, " "),
        table.concat(problem.companies or {}, " "),
      }, " ")
      local function display()
        return displayer({
          { tostring(count), count > 0 and "MeatCodeDone" or "MeatCodeTodo" },
          number_text(problem),
          count > 0 and { problem.name, "MeatCodeDone" } or problem.name,
          { problem.difficulty, "MeatCode" .. problem.difficulty },
          { provider_text(problem), "MeatCodeMuted" },
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

local function picker_open()
  return state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf)
end

local function is_current_page()
  return state.page_buf and pages.buf() == state.page_buf
end

--- Close the floating picker windows without touching the page stack —
--- reused by the picker's own q/<Esc>/select handlers and by the page's
--- `on_close` (fired if something else pops/clears the stack out from
--- under us, e.g. `:MeatCode` navigating elsewhere).
local function close_picker()
  if not picker_open() then return end
  local modules = telescope()
  if modules then pcall(modules["telescope.actions"].close, state.prompt_buf) end
  state.prompt_buf, state.picker = nil, nil
end

local function title()
  local cat = catalog.get()
  local problems = cat and cat.problems or {}
  local unsupported, locked = availability.hidden_counts(problems, config.options.lang)
  local hidden = unsupported + locked
  return string.format(" Problems · %d merged · LC %d · NC %d · LI %d%s · %s ",
    #problems,
    catalog.provider_count("leetcode"), catalog.provider_count("neetcode"),
    catalog.provider_count("lintcode"),
    hidden > 0 and string.format(" · %d hidden (%d unsupported, %d locked)", hidden, unsupported, locked) or "",
    streak_text())
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

--- Human verdict for `problem`'s already-checked availability -- used to
--- finish a "Checking…" progress handle with the actual outcome so it never
--- reads as stuck, whichever of `probe`/`select_current` triggered it.
local function verdict_message(problem)
  if availability.is_locked(problem) then
    return problem.name .. " isn't accessible on any provider you have unlocked"
  elseif availability.is_unsupported(problem, config.options.lang) then
    return problem.name .. " doesn't support " .. lang_info.name(config.options.lang)
  end
  return problem.name .. " supports " .. lang_info.name(config.options.lang)
end

--- Probe an unchecked entry's availability in the background, hiding the
--- entry the moment it confirms the configured language is unsupported
--- everywhere, or that the problem is inaccessible on every provider.
--- Already-checked entries are a cache hit inside `availability.check` and
--- return instantly, so this is cheap to call on every hover; a check
--- already in flight for the same problem is skipped instead of spinning up
--- a second one. The progress handle always resolves -- to the verdict on
--- success, to a visible error when the probe genuinely failed -- so this
--- never leaves a "Checking…" toast as the last thing you see for a row.
local function probe(problem)
  if availability.known(problem) or availability.is_checking(problem) then return end
  local handle = util.progress("Checking " .. problem.name .. "'s language support…")
  availability.check(problem, function(_, _, err)
    vim.schedule(function()
      if err then
        handle:cancel()
        util.err(problem.name .. ": couldn't check language support — " .. err)
        return
      end
      handle:finish(verdict_message(problem))
      refresh()
    end)
  end)
end

--- Probe whatever entry is currently selected. Wired to `move_selection_*`
--- (explicit up/down navigation) below, and to the picker's `on_complete`
--- in `open_picker` -- typing in the prompt re-filters and silently changes
--- the default selection without ever firing a `move_selection_*` action, so
--- without the `on_complete` hook the first (and every re-filtered) match
--- never gets probed until the user manually presses up/down.
local function on_move()
  vim.schedule(function()
    if not picker_open() or not state.picker then return end
    local ok, entry = pcall(function() return state.picker:get_selection() end)
    if ok and entry and entry.value then probe(entry.value) end
  end)
end

--- Telescope clears every action's pre/post hooks at the start of each new
--- picker, so this only ever runs for the currently open list.
local function watch_hover(actions)
  for _, name in ipairs({
    "move_selection_next", "move_selection_previous",
    "move_selection_worse", "move_selection_better",
  }) do
    actions[name]:enhance({ post = on_move })
  end
end

local function open_picker(query)
  state.query = query
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
    -- Keep whatever row is currently selected selected across refreshes
    -- (default "reset" jumps to the top on every re-sort) -- paired with
    -- entry_cache above so a background availability probe completing
    -- doesn't yank the cursor out from under you while you're browsing.
    selection_strategy = "follow",
    layout_strategy = "vertical",
    layout_config = { width = 9999, height = 9999, prompt_position = "top" },
    -- A completion callback runs after every async find/filter pass,
    -- including the ones typing triggers -- covers the selection changing
    -- without a `move_selection_*` action ever firing (see `on_move`).
    on_complete = { on_move },
    -- Blank borderchars (not `border = false`) keep this reading as a page
    -- like the roadmap, not a floating popup: a real border window still
    -- gets created, so the prompt/results titles still render -- just onto
    -- invisible box edges instead of a visible rounded frame.
    borderchars = { " ", " ", " ", " ", " ", " ", " ", " " },
    attach_mappings = function(prompt_buf, map)
      state.prompt_buf = prompt_buf
      local function close()
        close_picker()
      end
      local function back()
        close()
        if is_current_page() then pages.pop() end
      end
      local function open_selected(problem)
        local key = providers.problem_key(problem)
        state.opening_key = key
        -- Leave the list (and the page stack under it) open while the
        -- problem preps in the background; only take over the screen once
        -- it is actually ready, and only if nothing else was picked meanwhile.
        require("meatcode.ui.problem").open(problem, {
          guard = function() return state.opening_key == key end,
          will_show = close,
        })
      end
      local function unsupported(problem)
        util.err(problem.name .. " doesn't support " .. lang_info.name(config.options.lang))
        refresh()
      end
      local function locked_out(problem)
        util.err(problem.name .. " isn't accessible on any provider you have unlocked")
        refresh()
      end
      --- Decide open-vs-hidden from the persisted cache rather than a raw
      --- `check` result: a probe that could not determine anything (every
      --- content candidate erroring, or none ever resolving an id) leaves
      --- the cache unset rather than blacklisting the problem, and
      --- `is_unsupported`/`is_locked` already treat "unset" as "not
      --- confirmed" -- matching `entries()`'s own filter and avoiding a
      --- false report on a probe that never actually found out.
      local function decide(problem)
        if availability.is_locked(problem) then
          locked_out(problem)
        elseif availability.is_unsupported(problem, config.options.lang) then
          unsupported(problem)
        else
          open_selected(problem)
        end
      end
      --- Entries here are LeetCode problems, not buffers or files, so
      --- telescope's generic file/buffer actions must not run their default
      --- implementations against them: they index fields (`bufnr`,
      --- `filename`) these entries never set. A global keymap as common as
      --- kickstart.nvim's `<C-d>`/`dd` -> `actions.delete_buffer` otherwise
      --- crashes here with "Invalid 'name': Expected Lua string" (indexing
      --- `vim.bo[nil]`), and `<C-x>`/`<C-v>`/`<C-t>` would error trying to
      --- `vim.split()` our `display` closure. Route every "open" variant
      --- through the same handler as `<CR>` and make delete a no-op.
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
      map("i", "<Esc>", back)
      map("n", "q", back)
      map("n", "<Esc>", back)
      watch_hover(actions)
      return true
    end,
  })
  state.picker:find()
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

  if not is_current_page() then
    if not (state.page_buf and vim.api.nvim_buf_is_valid(state.page_buf)) then
      state.page_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[state.page_buf].bufhidden = "hide"
    end
    pages.push({
      id = "list", buf = state.page_buf, title = "list",
      on_show = function() if not picker_open() then open_picker(state.query) end end,
      on_close = close_picker,
    })
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
