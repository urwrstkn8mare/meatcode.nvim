local api = require("eetcode.api.leetcode")
local config = require("eetcode.config")
local nc_catalog = require("eetcode.catalog")
local util = require("eetcode.util")

local M = {}

local state = { catalog = nil, refreshing = false, listeners = {}, waiters = {}, streak = nil }

local function cache_path()
  return config.options.cache_dir .. "/leetcode-catalog.json"
end

local function attach_neetcode(problem)
  local nc = nc_catalog.get()
  local mapped = nc and nc.by_leetcode[problem.leetcode] or nil
  if mapped then
    problem.id = mapped.id
    problem.pattern = mapped.pattern
    problem.video = mapped.video
    problem.pro = mapped.pro
    problem.github = mapped.github
  end
  return problem
end

--- Note: `raw` items are the flat GraphQL `questionList` shape
--- (`questionId`, `questionFrontendId`, `title`, `titleSlug`, `difficulty`,
--- `isPaidOnly`, `status`) — see `api/leetcode.lua`'s `M.problems`.
local function index(raw, meta)
  local out = {
    problems = {},
    by_leetcode = {},
    fetched_at = meta and meta.fetched_at,
    source = (meta and meta.source) or "cache",
  }

  for _, item in ipairs(raw or {}) do
    local p = attach_neetcode({
      provider = "leetcode",
      leetcode_id = tostring(item.questionId or ""),
      frontend_id = tostring(item.questionFrontendId or ""),
      name = item.title,
      leetcode = item.titleSlug,
      difficulty = item.difficulty or "Unknown",
      paid = item.isPaidOnly == true,
      leetcode_solved = item.status == "ac",
    })
    if p.leetcode and p.name then
      table.insert(out.problems, p)
      out.by_leetcode[p.leetcode] = p
    end
  end

  table.sort(out.problems, function(a, b)
    local an, bn = tonumber(a.frontend_id), tonumber(b.frontend_id)
    if an and bn then
      return an < bn
    elseif an then
      return true
    elseif bn then
      return false
    end
    return a.frontend_id < b.frontend_id
  end)
  return out
end

local function emit()
  for _, fn in ipairs(state.listeners) do
    pcall(fn, state.catalog)
  end
end

local function persist(raw)
  util.write_json(cache_path(), {
    problems = raw,
    fetched_at = os.time(),
    streak = state.streak,
  })
end

function M.on_update(fn)
  table.insert(state.listeners, fn)
end

function M.get()
  return state.catalog
end

function M.find(slug)
  return state.catalog and state.catalog.by_leetcode[slug] or nil
end

function M.streak()
  return state.streak
end

function M.load(cb)
  if state.catalog then
    if cb then cb(state.catalog) end
    return state.catalog
  end
  local cached = util.read_json(cache_path())
  if type(cached) == "table" and type(cached.problems) == "table" then
    -- An older cache in the pre-GraphQL REST shape indexes to zero problems;
    -- treat that the same as no cache so `ensure()` forces a fresh sync
    -- instead of serving an empty catalog.
    local candidate = index(cached.problems, { fetched_at = cached.fetched_at, source = "cache" })
    if #candidate.problems > 0 then
      state.catalog = candidate
      state.streak = type(cached.streak) == "table" and cached.streak or nil
    end
  end
  if cb then cb(state.catalog) end
  return state.catalog
end

function M.refresh_mappings()
  if not state.catalog then
    return
  end
  for _, problem in ipairs(state.catalog.problems) do
    attach_neetcode(problem)
  end
end

function M.sync(cb)
  cb = cb or function() end
  if state.refreshing then
    table.insert(state.waiters, cb)
    return
  end
  state.refreshing = true
  state.waiters = { cb }

  local function finish(err, cat)
    state.refreshing = false
    local waiters = state.waiters
    state.waiters = {}
    for _, waiter in ipairs(waiters) do waiter(err, cat) end
  end

  api.problems(function(err, raw)
    if err then return finish(err, state.catalog) end
    if type(raw) ~= "table" or #raw < 1000 then
      return finish("LeetCode returned an incomplete problem list", state.catalog)
    end
    api.streak(function(streak_err, streak)
      if not streak_err then state.streak = streak end
      persist(raw)
      state.catalog = index(raw, { fetched_at = os.time(), source = "live" })
      emit()
      finish(nil, state.catalog)
    end)
  end)
end

function M.ensure(cb)
  local cat = M.load()
  local max_age = config.options.catalog_max_age
  local stale = max_age and (util.file_age(cache_path()) == nil or util.file_age(cache_path()) > max_age)
  if not cat or stale then
    return M.sync(function(err, fresh)
      cb(err, fresh or cat)
    end)
  end
  cb(nil, cat)
end

nc_catalog.on_update(function()
  M.refresh_mappings()
  emit()
end)

return M
