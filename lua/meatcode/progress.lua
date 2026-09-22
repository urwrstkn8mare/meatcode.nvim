local catalog = require("meatcode.catalog")
local config = require("meatcode.config")
local lang_info = require("meatcode.lang")
local leetcode_api = require("meatcode.api.leetcode")
local problem_catalog = require("meatcode.catalog.problems")
local nc_api = require("meatcode.api")
local providers = require("meatcode.providers")
local util = require("meatcode.util")

--- Completion history keyed by language, then LeetCode slug, then local calendar
--- day. An accepted submission can count once per day regardless of provider.
local M = {}

local state = {
  completions = nil,
  cursors = nil,
  listeners = {},
  checking = false,
}

local function cache_path()
  return config.options.cache_dir .. "/progress.json"
end

local function load_cache()
  if state.completions then
    return state.completions
  end
  local cached = util.read_json(cache_path())
  state.completions = type(cached) == "table" and type(cached.completions) == "table"
    and cached.completions or {}
  -- Pre-provider caches used bare LeetCode slugs. Migrate once to the canonical
  -- provider-qualified key so LintCode-only and NeetCode-only problems count too.
  for _, by_problem in pairs(state.completions) do
    if type(by_problem) == "table" then
      for key, days in pairs(vim.deepcopy(by_problem)) do
        if type(key) == "string" and not key:find(":", 1, true) then
          by_problem["leetcode:" .. key] = by_problem["leetcode:" .. key] or days
          by_problem[key] = nil
        end
      end
    end
  end
  local cursors = type(cached) == "table" and cached.cursors or nil
  state.cursors = {
    leetcode = type(cursors) == "table" and type(cursors.leetcode) == "table" and cursors.leetcode or {},
    neetcode = type(cursors) == "table" and type(cursors.neetcode) == "table" and cursors.neetcode or {},
  }
  return state.completions
end

local function persist()
  util.write_json(cache_path(), {
    completions = state.completions,
    cursors = state.cursors,
    updated_at = os.time(),
  })
end

function M.on_update(fn)
  table.insert(state.listeners, fn)
end

local function emit()
  for _, fn in ipairs(state.listeners) do
    pcall(fn)
  end
end

--- Return how many calendar days contain an accepted submission for this problem
--- in `lang`. The configured language is used when it is omitted.
---@param problem table
---@param lang string|nil
---@return integer
function M.completion_count(problem, lang)
  local key = providers.problem_key(problem)
  if not key then return 0 end
  local days = load_cache()[lang or config.options.lang]
  local completed = days and days[key] or nil
  if type(completed) ~= "table" then return 0 end
  return vim.tbl_count(completed)
end

function M.is_solved(problem)
  return M.completion_count(problem) > 0
end

function M.pattern_progress(pattern, list)
  catalog.load()
  local problems = catalog.pattern_problems(pattern, list)
  local done = 0
  for _, p in ipairs(problems) do
    if M.is_solved(p) then done = done + 1 end
  end
  return done, #problems
end

function M.summary(list)
  local cat = catalog.get() or catalog.load()
  local out = {
    total = 0,
    done = 0,
    by_difficulty = {
      Easy = { done = 0, total = 0 },
      Medium = { done = 0, total = 0 },
      Hard = { done = 0, total = 0 },
    },
  }
  if not cat then return out end
  for _, p in ipairs(cat.problems) do
    if catalog.in_list(p, list) then
      local bucket = out.by_difficulty[p.difficulty]
      out.total = out.total + 1
      if bucket then bucket.total = bucket.total + 1 end
      if M.is_solved(p) then
        out.done = out.done + 1
        if bucket then bucket.done = bucket.done + 1 end
      end
    end
  end
  return out
end

--- Record one accepted submission on `day` ("YYYY-MM-DD"; defaults to today in
--- local time). Multiple accepts through LeetCode and NeetCode on the same
--- calendar day share one completion.
---@param problem table
---@param lang string
---@param day string|nil
---@return boolean recorded Whether this was a new completion day.
function M.record_acceptance(problem, lang, day)
  local key = providers.problem_key(problem)
  if not key then return false end
  local completions = load_cache()
  local by_language = completions[lang]
  if type(by_language) ~= "table" then
    by_language = {}
    completions[lang] = by_language
  end
  local days = by_language[key]
  if type(days) ~= "table" then
    days = {}
    by_language[key] = days
  end

  day = day or os.date("%Y-%m-%d")
  if days[day] then return false end
  days[day] = true
  persist()
  emit()
  return true
end

-- A hard ceiling on pagination so a runaway `has_next` cannot hang forever.
local MAX_LEETCODE_PAGES = 1000
local LEETCODE_PAGE_SIZE = 20
local SYNC_DELAY_MS = 300
-- How often (in submissions/days checked) a long first-time walk reports
-- progress. A same-day incremental check rarely reaches this and stays quiet.
local PROGRESS_EVERY = 5

--- Fetch and record accepted LeetCode submissions in `lang`. Incremental:
--- paging stops as soon as the last-seen submission id (persisted per
--- language) reappears, so a launch with nothing new costs one page. A
--- language with no stored cursor yet walks the full account history once,
--- then stays incremental from then on.
---@param lang string
---@param cb fun(err: string|nil, totals: {checked: integer, recorded: integer}|nil)
---@param on_progress fun(checked: integer, recorded: integer)|nil
function M.sync_leetcode(lang, cb, on_progress)
  load_cache()
  local stop_at_id = state.cursors.leetcode[lang]
  local remote_lang = leetcode_api.lang(lang)
  local offset, last_key, checked, recorded = 0, nil, 0, 0
  local newest_id = nil

  local function finish(err, result)
    if not err and newest_id then
      state.cursors.leetcode[lang] = newest_id
      persist()
    end
    cb(err, result)
  end

  local function step(page)
    if page > MAX_LEETCODE_PAGES then
      return finish(nil, { checked = checked, recorded = recorded, truncated = true })
    end
    leetcode_api.submissions_page(offset, LEETCODE_PAGE_SIZE, last_key, function(err, page_data)
      if err then
        return finish(err, nil)
      end
      local dump = type(page_data.submissions_dump) == "table" and page_data.submissions_dump or {}
      for _, sub in ipairs(dump) do
        if stop_at_id and sub.id == stop_at_id then
          return finish(nil, { checked = checked, recorded = recorded })
        end
        newest_id = newest_id or sub.id -- the feed is newest-first
        checked = checked + 1
        if sub.status_display == "Accepted" and sub.lang == remote_lang
          and type(sub.title_slug) == "string" and sub.title_slug ~= "" then
          local day = os.date("%Y-%m-%d", tonumber(sub.timestamp))
          if M.record_acceptance({ providers = { leetcode = { id = sub.title_slug } } }, lang, day) then
            recorded = recorded + 1
          end
        end
      end
      if on_progress then on_progress(checked, recorded) end
      if page_data.has_next then
        offset = offset + LEETCODE_PAGE_SIZE
        last_key = page_data.last_key
        vim.defer_fn(function() step(page + 1) end, SYNC_DELAY_MS)
      else
        finish(nil, { checked = checked, recorded = recorded })
      end
    end)
  end
  step(1)
end

--- Fetch and record accepted NeetCode submissions in `lang` from the daily
--- activity log (the data backing the streak calendar).
---
--- Incremental: only days on or after the persisted cursor date are
--- re-fetched (the boundary day is re-checked too, since NeetCode buckets by
--- UTC day and late submissions can still land on an already-seen day before
--- the next check). A language with no stored cursor yet walks every day with
--- recorded activity.
---@param lang string
---@param cb fun(err: string|nil, totals: {checked: integer, recorded: integer}|nil)
---@param on_progress fun(checked: integer, recorded: integer)|nil
function M.sync_neetcode(lang, cb, on_progress)
  load_cache()
  catalog.load()
  local cursor_date = state.cursors.neetcode[lang]

  nc_api.streak_data(function(err, streak)
    if err then
      return cb(err, nil)
    end
    local dates = {}
    for date, info in pairs((type(streak) == "table" and streak.activityByDate) or {}) do
      if type(info) == "table" and (tonumber(info.count) or 0) > 0
        and (not cursor_date or date >= cursor_date) then
        table.insert(dates, date)
      end
    end
    table.sort(dates)

    local checked, recorded, idx = 0, 0, 0
    local newest_date = cursor_date
    local function step()
      idx = idx + 1
      local date = dates[idx]
      if not date then
        if newest_date then
          state.cursors.neetcode[lang] = newest_date
          persist()
        end
        return cb(nil, { checked = checked, recorded = recorded })
      end
      nc_api.day_activity(date, function(day_err, activity)
        if not day_err and type(activity) == "table" and type(activity.submissions) == "table" then
          local cat = catalog.get()
          for _, sub in ipairs(activity.submissions) do
            checked = checked + 1
            if sub.status == "Accepted" and sub.language == lang
              and type(sub.problemId) == "string" then
              local entry = cat and cat.by_provider.neetcode[sub.problemId]
              if entry and M.record_acceptance(entry, lang, date) then
                recorded = recorded + 1
              end
            end
          end
        end
        if not newest_date or date > newest_date then
          newest_date = date
        end
        if on_progress then on_progress(checked, recorded) end
        vim.defer_fn(step, SYNC_DELAY_MS)
      end)
    end
    step()
  end)
end

--- Throttled "still working" notifier for a long first-time walk. Silent for
--- a fast incremental check (the common case), since it rarely reaches
--- `PROGRESS_EVERY` submissions checked before finishing.
local function progress_reporter(provider)
  local last_notified = 0
  return function(checked)
    if checked - last_notified < PROGRESS_EVERY then
      return
    end
    last_notified = checked
    vim.schedule(function()
      util.notify(string.format("%s: %d submissions checked…", provider, checked))
    end)
  end
end

--- Pick up accepted submissions made since the last check, for `lang`. A
--- language checked for the first time walks its full provider history once
--- and is incremental on every call after that. Notifies when the check
--- starts and again with a summary when it finishes; a provider that isn't
--- logged in is skipped without a notification.
---@param lang string|nil defaults to the configured language
---@param cb fun(err: string|nil, totals: {checked: integer, recorded: integer}|nil)
function M.check_new(lang, cb)
  cb = cb or function() end
  lang = lang or config.options.lang

  local run_leetcode = providers.get("leetcode").auth.is_logged_in()
  local run_neetcode = providers.get("neetcode").auth.is_logged_in()
  if not run_leetcode and not run_neetcode then
    return cb(nil, { checked = 0, recorded = 0 })
  end

  util.notify(string.format("checking for new %s submissions…", lang_info.name(lang)))

  local errors, pending = {}, (run_leetcode and 1 or 0) + (run_neetcode and 1 or 0)
  local totals = { checked = 0, recorded = 0 }
  local function done(label, err, result)
    if err then
      table.insert(errors, label .. ": " .. err)
    elseif result then
      totals.checked = totals.checked + (result.checked or 0)
      totals.recorded = totals.recorded + (result.recorded or 0)
    end
    pending = pending - 1
    if pending > 0 then
      return
    end
    vim.schedule(function()
      if #errors > 0 then
        util.err("submissions check failed: " .. table.concat(errors, "; "))
      elseif totals.recorded > 0 then
        util.notify(string.format("found %d new completion day%s",
          totals.recorded, totals.recorded == 1 and "" or "s"))
      else
        util.notify("submissions up to date")
      end
      cb(#errors > 0 and table.concat(errors, "; ") or nil, totals)
    end)
  end

  if run_leetcode then
    M.sync_leetcode(lang, function(err, result) done("LeetCode", err, result) end,
      progress_reporter("LeetCode"))
  end
  if run_neetcode then
    M.sync_neetcode(lang, function(err, result) done("NeetCode", err, result) end,
      progress_reporter("NeetCode"))
  end
end

--- Refresh all provider catalogs and opportunistically pick up new accepted
--- submissions for the configured language. Completion counts remain offline.
function M.sync(cb)
  cb = cb or function() end
  load_cache()
  problem_catalog.sync(function(err)
    emit()
    cb(err)
  end)

  if not state.checking then
    state.checking = true
    M.check_new(config.options.lang, function()
      state.checking = false
      emit()
    end)
  end
end

function M.load()
  load_cache()
end

return M
