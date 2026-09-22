local config = require("meatcode.config")
local scraper = require("meatcode.catalog.scraper")
local util = require("meatcode.util")

--- Loads, caches and indexes NeetCode's curated roadmap catalog. Entries use
--- the same provider-neutral identity shape as the all-problems catalog.
local M = {}

local state = { catalog = nil, refreshing = false, listeners = {}, waiters = {} }

local LISTS = { "blind75", "neetcode150", "neetcode250", "allNC" }
M.LISTS = LISTS

M.LIST_LABELS = {
  blind75 = "Blind 75",
  neetcode150 = "NeetCode 150",
  neetcode250 = "NeetCode 250",
  allNC = "NeetCode All",
}

local function cache_path()
  return config.options.cache_dir .. "/catalog.json"
end

local function trim_slug(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("/+$", "")
  return s ~= "" and s or nil
end

local function provider_record(id, extra)
  if not id then return nil end
  return vim.tbl_extend("force", { id = id }, extra or {})
end

local function key(providers)
  if providers.leetcode then return "leetcode:" .. providers.leetcode.id end
  if providers.neetcode then return "neetcode:" .. providers.neetcode.id end
end

---@class meatcode.Catalog
---@field problems table[]
---@field by_provider table<string, table<string, table>>
---@field by_pattern table<string, table[]>
---@field hash string|nil
---@field fetched_at integer|nil
---@field source string

local function index(raw, meta)
  local cat = {
    problems = {},
    by_provider = { leetcode = {}, neetcode = {}, lintcode = {} },
    by_pattern = {},
    hash = meta and meta.hash,
    fetched_at = meta and meta.fetched_at,
    source = (meta and meta.source) or "cache",
  }

  for _, p in ipairs(raw) do
    local nc_id = trim_slug(p.ncLink)
    local lc_id = trim_slug(p.link)
    local providers = {
      neetcode = provider_record(nc_id, {
        video = p.video ~= "" and p.video or nil,
        github = p.code,
        paid = p.pro == true,
      }),
      leetcode = provider_record(lc_id),
    }
    local entry = {
      key = key(providers),
      name = p.problem,
      pattern = p.pattern,
      difficulty = p.difficulty,
      providers = providers,
      topics = {},
      companies = {},
      blind75 = p.blind75 == true,
      neetcode150 = p.neetcode150 == true,
      neetcode250 = p.neetcode250 == true,
    }

    table.insert(cat.problems, entry)
    for name, record in pairs(providers) do
      if record then cat.by_provider[name][tostring(record.id)] = entry end
    end
    cat.by_pattern[entry.pattern] = cat.by_pattern[entry.pattern] or {}
    table.insert(cat.by_pattern[entry.pattern], entry)
  end

  return cat
end

function M.find(provider, id)
  local cat = M.get()
  return cat and cat.by_provider[provider] and cat.by_provider[provider][tostring(id)] or nil
end

function M.in_list(problem, list)
  if list == "allNC" or list == nil then return true end
  return problem[list] == true
end

function M.pattern_problems(pattern, list)
  local cat = M.get()
  if not cat then return {} end
  local out = {}
  for _, p in ipairs(cat.by_pattern[pattern] or {}) do
    if M.in_list(p, list) then table.insert(out, p) end
  end
  return out
end

function M.get()
  return state.catalog
end

function M.on_update(fn)
  table.insert(state.listeners, fn)
end

local function emit()
  for _, fn in ipairs(state.listeners) do pcall(fn, state.catalog) end
end

local function set(raw, meta)
  state.catalog = index(raw, meta)
  return state.catalog
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

  scraper.fetch(function(err, result)
    if err then return finish(err, nil) end

    util.write_json(cache_path(), {
      problems = result.problems,
      hash = result.hash,
      fetched_at = result.fetched_at,
    })

    local cat = set(result.problems, {
      hash = result.hash,
      fetched_at = result.fetched_at,
      source = "live",
    })
    emit()
    finish(nil, cat)
  end)
end

function M.load(cb)
  if state.catalog then
    if cb then cb(state.catalog) end
    return state.catalog
  end

  local cached = util.read_json(cache_path())
  local age = util.file_age(cache_path())
  if type(cached) == "table" and type(cached.problems) == "table" and #cached.problems > 0 then
    set(cached.problems, { hash = cached.hash, fetched_at = cached.fetched_at, source = "cache" })
  end

  local max_age = config.options.catalog_max_age
  local stale = max_age and (age == nil or age > max_age)
  if stale then
    M.sync(function(err)
      if err and not state.catalog then
        vim.schedule(function() util.err("could not fetch the problem catalog: " .. err) end)
      end
    end)
  end

  if cb then cb(state.catalog) end
  return state.catalog
end

function M.age_string()
  local cat = state.catalog
  if not cat or not cat.fetched_at then return "unknown" end
  local secs = os.time() - cat.fetched_at
  if secs < 60 then return "just now" end
  if secs < 3600 then return string.format("%dm ago", math.floor(secs / 60)) end
  if secs < 86400 then return string.format("%dh ago", math.floor(secs / 3600)) end
  return string.format("%dd ago", math.floor(secs / 86400))
end

return M
