local leetcode = require("meatcode.api.leetcode")
local lintcode = require("meatcode.api.lintcode")
local config = require("meatcode.config")
local roadmap = require("meatcode.catalog")
local util = require("meatcode.util")

local M = {}

local state = {
  catalog = nil,
  leetcode = nil,
  lintcode = nil,
  refreshing = false,
  listeners = {},
  waiters = {},
  streak = nil,
  fetched_at = nil,
  mappings = nil,
}

local function cache_path()
  return config.options.cache_dir .. "/problems-catalog.json"
end

local function mappings_path()
  return config.options.cache_dir .. "/provider-mappings.json"
end

local function load_mappings()
  if state.mappings then return state.mappings end
  local saved = util.read_json(mappings_path())
  state.mappings = type(saved) == "table" and saved or { leetcode_to_lintcode = {} }
  state.mappings.leetcode_to_lintcode = state.mappings.leetcode_to_lintcode or {}
  return state.mappings
end

local function normalize_title(title)
  return type(title) == "string" and title:lower():gsub("[^%w]", "") or ""
end

local function names(items)
  local out = {}
  for _, item in ipairs(type(items) == "table" and items or {}) do
    local name = type(item) == "table" and (item.name or item.tag_name) or item
    if type(name) == "string" and name ~= "" then table.insert(out, name) end
  end
  return out
end

local function union(left, right)
  local out, seen = {}, {}
  for _, list in ipairs({ left or {}, right or {} }) do
    for _, value in ipairs(list) do
      local key = value:lower()
      if not seen[key] then
        seen[key] = true
        table.insert(out, value)
      end
    end
  end
  table.sort(out, function(a, b) return a:lower() < b:lower() end)
  return out
end

local function lint_difficulty(level)
  return ({ [0] = "Naive", "Easy", "Medium", "Hard" })[tonumber(level)] or "Unknown"
end

local function canonical_key(providers)
  for _, name in ipairs({ "leetcode", "neetcode", "lintcode" }) do
    if providers[name] then return name .. ":" .. tostring(providers[name].id) end
  end
end

local function add_indexes(cat, problem)
  table.insert(cat.problems, problem)
  for name, record in pairs(problem.providers or {}) do
    if record then cat.by_provider[name][tostring(record.id)] = problem end
  end
end

local function index()
  roadmap.load()
  local nc = roadmap.get()
  local mappings = load_mappings().leetcode_to_lintcode
  local cat = {
    problems = {},
    by_provider = { leetcode = {}, neetcode = {}, lintcode = {} },
    fetched_at = state.fetched_at,
    source = "cache",
  }
  local title_counts = { leetcode = {}, lintcode = {} }
  local lc_by_title = {}

  for _, item in ipairs(state.leetcode or {}) do
    local title_key = normalize_title(item.title)
    title_counts.leetcode[title_key] = (title_counts.leetcode[title_key] or 0) + 1
  end
  for _, item in ipairs(state.lintcode or {}) do
    local title_key = normalize_title(item.title or item.en_title)
    title_counts.lintcode[title_key] = (title_counts.lintcode[title_key] or 0) + 1
  end

  for _, item in ipairs(state.leetcode or {}) do
    local slug = item.titleSlug
    if type(slug) == "string" and slug ~= "" and type(item.title) == "string" then
      local providers = {
        leetcode = {
          id = slug,
          question_id = tostring(item.questionId or ""),
          frontend_id = tostring(item.questionFrontendId or ""),
          paid = item.isPaidOnly == true,
        },
      }
      local nc_problem = nc and nc.by_provider.leetcode[slug] or nil
      if nc_problem and nc_problem.providers.neetcode then
        providers.neetcode = vim.deepcopy(nc_problem.providers.neetcode)
      end
      local remembered = mappings[slug]
      if remembered then providers.lintcode = { id = tostring(remembered) } end
      local problem = {
        key = "leetcode:" .. slug,
        name = item.title,
        difficulty = item.difficulty or "Unknown",
        pattern = nc_problem and nc_problem.pattern or nil,
        providers = providers,
        topics = vim.deepcopy(nc_problem and nc_problem.topics or {}),
        companies = vim.deepcopy(nc_problem and nc_problem.companies or {}),
      }
      add_indexes(cat, problem)
      local title_key = normalize_title(item.title)
      if title_counts.leetcode[title_key] == 1 then lc_by_title[title_key] = problem end
    end
  end

  for _, item in ipairs(state.lintcode or {}) do
    local id = tostring(item.problem_id or "")
    local title = item.title or item.en_title
    if id ~= "" and type(title) == "string" and title ~= "" then
      local title_key = normalize_title(title)
      local problem = title_counts.lintcode[title_key] == 1 and lc_by_title[title_key] or nil
      if problem and not problem.providers.lintcode then
        problem.providers.lintcode = {
          id = id,
          paid = item.is_locked == true,
        }
        cat.by_provider.lintcode[id] = problem
        problem.topics = union(problem.topics, names(item.problem_tags))
        problem.companies = union(problem.companies, names(item.company_tags))
      elseif not cat.by_provider.lintcode[id] then
        local providers = {
          lintcode = { id = id, paid = item.is_locked == true },
        }
        add_indexes(cat, {
          key = canonical_key(providers),
          name = title,
          difficulty = lint_difficulty(item.level),
          providers = providers,
          topics = names(item.problem_tags),
          companies = names(item.company_tags),
        })
      end
    end
  end

  for _, nc_problem in ipairs(nc and nc.problems or {}) do
    local nc_record = nc_problem.providers.neetcode
    if nc_record and not cat.by_provider.neetcode[tostring(nc_record.id)] then
      add_indexes(cat, vim.deepcopy(nc_problem))
    end
  end

  table.sort(cat.problems, function(a, b)
    local alc = a.providers.leetcode
    local blc = b.providers.leetcode
    local an = alc and tonumber(alc.frontend_id)
    local bn = blc and tonumber(blc.frontend_id)
    if an and bn and an ~= bn then return an < bn end
    if an ~= nil and bn == nil then return true end
    if an == nil and bn ~= nil then return false end
    if a.name ~= b.name then return a.name:lower() < b.name:lower() end
    return a.key < b.key
  end)

  state.catalog = cat
  return cat
end

local function persist()
  util.write_json(cache_path(), {
    leetcode = state.leetcode,
    lintcode = state.lintcode,
    streak = state.streak,
    fetched_at = state.fetched_at,
  })
end

local function emit()
  for _, fn in ipairs(state.listeners) do pcall(fn, state.catalog) end
end

function M.on_update(fn)
  table.insert(state.listeners, fn)
end

function M.get()
  return state.catalog
end

function M.find(provider, id)
  local cat = state.catalog
  return cat and cat.by_provider[provider] and cat.by_provider[provider][tostring(id)] or nil
end

function M.streak()
  return state.streak
end

function M.provider_count(name)
  local cat = state.catalog
  return cat and vim.tbl_count(cat.by_provider[name] or {}) or 0
end

function M.load(cb)
  if state.catalog then
    if cb then cb(state.catalog) end
    return state.catalog
  end
  local cached = util.read_json(cache_path())
  if type(cached) == "table" then
    state.leetcode = type(cached.leetcode) == "table" and cached.leetcode or nil
    state.lintcode = type(cached.lintcode) == "table" and cached.lintcode or nil
    state.streak = type(cached.streak) == "table" and cached.streak or nil
    state.fetched_at = tonumber(cached.fetched_at)
    if state.leetcode or state.lintcode then index() end
  end
  if cb then cb(state.catalog) end
  return state.catalog
end

function M.refresh_mappings()
  if state.leetcode or state.lintcode then
    index()
    emit()
  end
end

function M.remember_lintcode(leetcode_slug, lintcode_id)
  if not leetcode_slug or not lintcode_id then return end
  local mappings = load_mappings()
  mappings.leetcode_to_lintcode[leetcode_slug] = tostring(lintcode_id)
  util.write_json(mappings_path(), mappings)
  M.refresh_mappings()
end

function M.sync(cb)
  cb = cb or function() end
  if state.refreshing then
    table.insert(state.waiters, cb)
    return
  end
  state.refreshing = true
  state.waiters = { cb }

  local errors, pending = {}, 4
  local fresh = { leetcode = nil, lintcode = nil, streak = nil }
  local function done(name, err, value)
    if err then table.insert(errors, name .. ": " .. err) else fresh[name] = value end
    pending = pending - 1
    if pending > 0 then return end

    state.refreshing = false
    if fresh.leetcode then state.leetcode = fresh.leetcode end
    if fresh.lintcode then state.lintcode = fresh.lintcode end
    if fresh.streak then state.streak = fresh.streak end
    if fresh.leetcode or fresh.lintcode then
      state.fetched_at = os.time()
      persist()
      index()
      emit()
    end

    local err_text = #errors > 0 and table.concat(errors, "; ") or nil
    local waiters = state.waiters
    state.waiters = {}
    for _, waiter in ipairs(waiters) do waiter(err_text, state.catalog) end
  end

  leetcode.problems(function(err, rows) done("leetcode", err, rows) end)
  lintcode.problems(function(err, rows) done("lintcode", err, rows) end)
  leetcode.streak(function(err, streak) done("streak", err, streak) end)
  roadmap.sync(function(err, cat) done("neetcode", err, cat) end)
end

function M.ensure(cb)
  local cat = M.load()
  local age = util.file_age(cache_path())
  local max_age = config.options.catalog_max_age
  local stale = max_age and (age == nil or age > max_age)
  if not cat or stale then
    return M.sync(function(err, fresh) cb(err, fresh or cat) end)
  end
  cb(nil, cat)
end

roadmap.on_update(function()
  M.refresh_mappings()
end)

return M
