local api = require("neetcode.api")
local auth = require("neetcode.api.auth")
local catalog = require("neetcode.catalog")
local config = require("neetcode.config")
local util = require("neetcode.util")

--- Tracks which problems are solved.
---
--- The server is the source of truth (progress is shared with neetcode.io), but
--- it is cached on disk so the roadmap renders instantly and still works offline.
local M = {}

-- Set of LeetCode slugs that are solved.
local state = { solved = nil, listeners = {}, fetching = false }

local function cache_path()
  return config.options.cache_dir .. "/progress.json"
end

local function slug_from_url(url)
  return url:match("problems/([^/]+)")
end

local function load_cache()
  if state.solved then
    return state.solved
  end
  local cached = util.read_json(cache_path())
  state.solved = (type(cached) == "table" and type(cached.solved) == "table") and cached.solved or {}
  return state.solved
end

local function persist()
  util.write_json(cache_path(), { solved = state.solved, updated_at = os.time() })
end

function M.on_update(fn)
  table.insert(state.listeners, fn)
end

local function emit()
  for _, fn in ipairs(state.listeners) do
    pcall(fn)
  end
end

---@param problem table catalog entry
function M.is_solved(problem)
  local solved = load_cache()
  return problem.leetcode ~= nil and solved[problem.leetcode] == true
end

--- Solved / total counts for one roadmap pattern under the active list.
---@return integer done, integer total
function M.pattern_progress(pattern, list)
  catalog.load()
  local problems = catalog.pattern_problems(pattern, list)
  local done = 0
  for _, p in ipairs(problems) do
    if M.is_solved(p) then
      done = done + 1
    end
  end
  return done, #problems
end

--- Totals across the whole active list, split by difficulty.
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
  if not cat then
    return out
  end

  for _, p in ipairs(cat.problems) do
    if catalog.in_list(p, list) then
      local bucket = out.by_difficulty[p.difficulty]
      out.total = out.total + 1
      if bucket then
        bucket.total = bucket.total + 1
      end
      if M.is_solved(p) then
        out.done = out.done + 1
        if bucket then
          bucket.done = bucket.done + 1
        end
      end
    end
  end
  return out
end

--- Pull progress from the server and cache it.
---@param cb fun(err: string|nil)|nil
function M.sync(cb)
  cb = cb or function() end
  if not auth.is_logged_in() then
    load_cache()
    return cb("not logged in — run :NeetCode login")
  end
  if state.fetching then
    return cb(nil)
  end
  state.fetching = true

  api.completed(function(err, completed)
    state.fetching = false
    if err then
      load_cache()
      return cb(err)
    end

    local solved = {}
    for _, urls in pairs(completed or {}) do
      for _, url in ipairs(urls) do
        local slug = slug_from_url(url)
        if slug then
          solved[slug] = true
        end
      end
    end

    state.solved = solved
    persist()
    emit()
    cb(nil)
  end)
end

--- Mark solved locally and push to the server.
function M.mark(problem, cb)
  cb = cb or function() end
  load_cache()
  if not problem.leetcode then
    return cb("problem has no LeetCode mapping")
  end

  state.solved[problem.leetcode] = true
  persist()
  emit()

  api.mark_complete(problem.pattern, problem.leetcode, function(err)
    cb(err)
  end)
end

function M.unmark(problem, cb)
  cb = cb or function() end
  load_cache()
  if not problem.leetcode then
    return cb("problem has no LeetCode mapping")
  end

  state.solved[problem.leetcode] = nil
  persist()
  emit()

  api.mark_incomplete(problem.pattern, problem.leetcode, function(err)
    cb(err)
  end)
end

--- Flip solved state locally and on the server.
---@param problem table catalog entry
---@param cb fun(err: string|nil, solved: boolean|nil)|nil
function M.toggle(problem, cb)
  cb = cb or function() end
  if M.is_solved(problem) then
    return M.unmark(problem, function(err)
      cb(err, false)
    end)
  end
  M.mark(problem, function(err)
    cb(err, true)
  end)
end

function M.load()
  load_cache()
end

return M
