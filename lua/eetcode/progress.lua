local api = require("eetcode.api")
local auth = require("eetcode.api.auth")
local catalog = require("eetcode.catalog")
local config = require("eetcode.config")
local leetcode_auth = require("eetcode.api.leetcode_auth")
local leetcode_catalog = require("eetcode.catalog.leetcode")
local util = require("eetcode.util")

--- Unified progress keyed by LeetCode slug. The provider-specific sets are
--- retained so either service can refresh without erasing the other one.
local M = {}

local state = {
  solved = nil,
  neetcode = nil,
  leetcode = nil,
  listeners = {},
  fetching = false,
}

local function cache_path()
  return config.options.cache_dir .. "/progress.json"
end

local function slug_from_url(url)
  return type(url) == "string" and url:match("problems/([^/]+)") or nil
end

local function rebuild()
  state.solved = {}
  for slug in pairs(state.neetcode or {}) do
    state.solved[slug] = true
  end
  for slug in pairs(state.leetcode or {}) do
    state.solved[slug] = true
  end
end

local function load_cache()
  if state.solved then
    return state.solved
  end
  local cached = util.read_json(cache_path())
  local old = type(cached) == "table" and type(cached.solved) == "table" and cached.solved or {}
  state.neetcode = type(cached) == "table" and type(cached.neetcode) == "table"
    and cached.neetcode or vim.deepcopy(old)
  state.leetcode = type(cached) == "table" and type(cached.leetcode) == "table"
    and cached.leetcode or {}
  rebuild()
  return state.solved
end

local function persist()
  util.write_json(cache_path(), {
    solved = state.solved,
    neetcode = state.neetcode,
    leetcode = state.leetcode,
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

function M.is_solved(problem)
  local solved = load_cache()
  return problem.leetcode ~= nil and solved[problem.leetcode] == true
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

local function neetcode_solved(completed)
  local solved = {}
  for _, urls in pairs(completed or {}) do
    for _, url in ipairs(urls) do
      local slug = slug_from_url(url)
      if slug then solved[slug] = true end
    end
  end
  return solved
end

local function leetcode_solved(cat)
  local solved = {}
  for _, problem in ipairs((cat and cat.problems) or {}) do
    if problem.leetcode_solved then solved[problem.leetcode] = true end
  end
  return solved
end

--- Refresh both providers and expose their union everywhere in the plugin.
--- Accepted LeetCode submissions are also recorded on NeetCode as they happen;
--- LeetCode itself has no API for fabricating an accepted submission.
function M.sync(cb)
  cb = cb or function() end
  load_cache()
  if state.fetching then return cb(nil) end
  state.fetching = true

  local pending, errors = 0, {}
  local function begin() pending = pending + 1 end
  local function done(err)
    if err then table.insert(errors, err) end
    pending = pending - 1
    if pending > 0 then return end
    state.fetching = false
    rebuild()
    persist()
    emit()
    cb(#errors > 0 and table.concat(errors, "; ") or nil)
  end

  if auth.is_logged_in() then
    begin()
    api.completed(function(err, completed)
      if not err then state.neetcode = neetcode_solved(completed) end
      done(err and ("NeetCode: " .. err) or nil)
    end)
  end

  begin()
  leetcode_catalog.sync(function(err, cat)
    if not err and leetcode_auth.is_logged_in() then
      state.leetcode = leetcode_solved(cat)
    end
    done(err and ("LeetCode: " .. err) or nil)
  end)
end

function M.mark(problem, cb)
  cb = cb or function() end
  load_cache()
  if not problem.leetcode then return cb("problem has no LeetCode mapping") end

  if problem.provider == "leetcode" then
    state.leetcode[problem.leetcode] = true
  end
  state.neetcode[problem.leetcode] = true
  rebuild()
  persist()
  emit()

  if problem.id and problem.pattern and auth.is_logged_in() then
    return api.mark_complete(problem.pattern, problem.leetcode, cb)
  end
  cb(nil)
end

function M.unmark(problem, cb)
  cb = cb or function() end
  load_cache()
  if not problem.leetcode then return cb("problem has no LeetCode mapping") end
  if state.leetcode[problem.leetcode] then
    return cb("LeetCode accepted problems cannot be marked incomplete")
  end

  state.neetcode[problem.leetcode] = nil
  rebuild()
  persist()
  emit()
  if problem.id and problem.pattern and auth.is_logged_in() then
    return api.mark_incomplete(problem.pattern, problem.leetcode, cb)
  end
  cb(nil)
end

function M.toggle(problem, cb)
  cb = cb or function() end
  if M.is_solved(problem) then
    return M.unmark(problem, function(err) cb(err, err and nil or false) end)
  end
  M.mark(problem, function(err) cb(err, err and nil or true) end)
end

function M.load()
  load_cache()
end

return M
