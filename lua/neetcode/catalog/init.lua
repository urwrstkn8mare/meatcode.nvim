local config = require("neetcode.config")
local scraper = require("neetcode.catalog.scraper")
local util = require("neetcode.util")

--- Loads, caches and indexes the problem catalog.
---
--- The catalog is always scraped from the live site; nothing is bundled with the
--- plugin. A cached copy is served immediately and refreshed in the background
--- when it ages past `catalog_max_age`, with listeners notified when newer data
--- lands, so the UI never blocks on the network. On a first run there is nothing
--- to serve until the fetch completes.
local M = {}

local state = { catalog = nil, refreshing = false, listeners = {} }

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

--- Strip the trailing slash NeetCode stores on its link fields.
local function trim_slug(s)
  if type(s) ~= "string" then
    return nil
  end
  s = s:gsub("/+$", "")
  return s ~= "" and s or nil
end

---@class neetcode.Catalog
---@field problems table[]
---@field by_id table<string, table>
---@field by_pattern table<string, table[]>
---@field by_leetcode table<string, table>
---@field hash string|nil
---@field fetched_at integer|nil
---@field source string

--- Build lookup indexes over a raw scraped list.
local function index(raw, meta)
  local cat = {
    problems = {},
    by_id = {},
    by_pattern = {},
    by_leetcode = {},
    hash = meta and meta.hash,
    fetched_at = meta and meta.fetched_at,
    source = (meta and meta.source) or "cache",
  }

  for _, p in ipairs(raw) do
    local entry = {
      name = p.problem,
      pattern = p.pattern,
      difficulty = p.difficulty,
      video = p.video ~= "" and p.video or nil,
      -- NeetCode's own problem id; absent for problems that only exist on
      -- LeetCode, which we can list but cannot open in the editor.
      id = trim_slug(p.ncLink),
      leetcode = trim_slug(p.link),
      github = p.code,
      pro = p.pro == true,
      blind75 = p.blind75 == true,
      neetcode150 = p.neetcode150 == true,
      neetcode250 = p.neetcode250 == true,
    }

    table.insert(cat.problems, entry)
    if entry.id then
      cat.by_id[entry.id] = entry
    end
    if entry.leetcode then
      cat.by_leetcode[entry.leetcode] = entry
    end
    cat.by_pattern[entry.pattern] = cat.by_pattern[entry.pattern] or {}
    table.insert(cat.by_pattern[entry.pattern], entry)
  end

  return cat
end

--- Does this problem belong to the given curated list?
function M.in_list(problem, list)
  if list == "allNC" or list == nil then
    return true
  end
  return problem[list] == true
end

--- Problems for one roadmap pattern, filtered to a curated list.
---@return table[]
function M.pattern_problems(pattern, list)
  local cat = M.get()
  if not cat then
    return {}
  end
  local out = {}
  for _, p in ipairs(cat.by_pattern[pattern] or {}) do
    if M.in_list(p, list) then
      table.insert(out, p)
    end
  end
  return out
end

--- The currently loaded catalog, or nil if `load` has not run yet.
---@return neetcode.Catalog|nil
function M.get()
  return state.catalog
end

function M.on_update(fn)
  table.insert(state.listeners, fn)
end

local function emit()
  for _, fn in ipairs(state.listeners) do
    pcall(fn, state.catalog)
  end
end

local function set(raw, meta)
  state.catalog = index(raw, meta)
  return state.catalog
end

--- Fetch a fresh catalog and persist it. Safe to call at any time; concurrent
--- calls collapse into the running refresh.
---@param cb fun(err: string|nil, catalog: neetcode.Catalog|nil)|nil
function M.sync(cb)
  if state.refreshing then
    if cb then
      cb("a catalog sync is already running", nil)
    end
    return
  end
  state.refreshing = true

  scraper.fetch(function(err, result)
    state.refreshing = false
    if err then
      if cb then
        cb(err, nil)
      end
      return
    end

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
    if cb then
      cb(nil, cat)
    end
  end)
end

--- Load the catalog from cache, refreshing in the background when it is older
--- than `catalog_max_age`. Returns nil on a first run, until the fetch lands.
---@param cb fun(catalog: neetcode.Catalog|nil)|nil
function M.load(cb)
  if state.catalog then
    if cb then
      cb(state.catalog)
    end
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
    -- Never block the caller on this; the UI renders from whatever we have.
    M.sync(function(err)
      if err and not state.catalog then
        -- Nothing cached to fall back on, so the failure has to be visible.
        vim.schedule(function()
          util.err("could not fetch the problem catalog: " .. err)
        end)
      end
    end)
  end

  if cb then
    cb(state.catalog)
  end
  return state.catalog
end

function M.age_string()
  local cat = state.catalog
  if not cat or not cat.fetched_at then
    return "unknown"
  end
  local secs = os.time() - cat.fetched_at
  if secs < 60 then
    return "just now"
  elseif secs < 3600 then
    return string.format("%dm ago", math.floor(secs / 60))
  elseif secs < 86400 then
    return string.format("%dh ago", math.floor(secs / 3600))
  end
  return string.format("%dd ago", math.floor(secs / 86400))
end

return M
