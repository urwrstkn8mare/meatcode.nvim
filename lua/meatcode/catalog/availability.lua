local config = require("meatcode.config")
local providers = require("meatcode.providers")
local util = require("meatcode.util")

--- Which languages a problem can actually be solved in, merged across every
--- content-chain candidate. A probe fetches each candidate provider's raw
--- metadata once (the same request opening the problem would make) and
--- unions their `availableLanguages`. The result is provider-set, not
--- language-set: switching your configured language later is a cache lookup,
--- never a re-fetch, because the probe already discovered every language
--- every candidate supports.
local M = {}

local state = { data = nil, pending = {} }

local function path()
  return config.options.cache_dir .. "/language-availability.json"
end

local function load()
  if state.data then return state.data end
  local saved = util.read_json(path())
  state.data = type(saved) == "table" and saved or {}
  return state.data
end

local function persist()
  util.write_json(path(), state.data or {})
end

--- The full set of languages known to be servable for `problem`, or nil if
--- it has never been probed.
function M.known(problem)
  local key = providers.problem_key(problem)
  if not key then return nil end
  local entry = load()[key]
  return entry and entry.languages or nil
end

--- Whether `problem` has been probed and confirmed to not support `lang` on
--- any content-chain candidate.
function M.is_unsupported(problem, lang)
  local languages = M.known(problem)
  if not languages then return false end
  return not vim.tbl_contains(languages, lang)
end

--- Probe every content-chain candidate for `problem` and persist the merged
--- language set. `cb(languages)` receives the merged set (possibly empty when
--- every candidate genuinely reports no languages, e.g. a locked problem).
--- A wholesale network failure (every candidate erroring) is not cached, so
--- a later probe retries instead of blacklisting on a transient outage.
function M.check(problem, cb)
  local key = providers.problem_key(problem)
  if not key then return cb(nil) end
  local cached = load()[key]
  if cached then return cb(cached.languages) end

  if state.pending[key] then
    table.insert(state.pending[key], cb)
    return
  end
  state.pending[key] = { cb }

  local function finish(languages)
    local waiters = state.pending[key]
    state.pending[key] = nil
    for _, waiter in ipairs(waiters) do waiter(languages) end
  end

  local candidates = providers.candidates(problem, "content")
  if #candidates == 0 then
    load()[key] = { languages = {}, checked_at = os.time() }
    persist()
    return finish({})
  end

  local seen, languages, any_success = {}, {}, false
  local function add(list)
    for _, lang in ipairs(list or {}) do
      if not seen[lang] then
        seen[lang] = true
        table.insert(languages, lang)
      end
    end
  end

  local i = 0
  local function step()
    i = i + 1
    local name = candidates[i]
    if not name then
      if any_success then
        load()[key] = { languages = languages, checked_at = os.time() }
        persist()
      end
      return finish(languages)
    end
    providers.ensure_id(problem, name, function(_, id)
      if not id then return step() end
      providers.get(name).fetch(problem, config.options.lang, function(err, meta)
        if not err and meta then
          local available = meta.availableLanguages
          if meta.paid_only and (type(available) ~= "table" or #available == 0) then
            -- Locked content ships no language list; that says nothing about
            -- what an unlock would reveal, so this candidate stays unknown.
          else
            any_success = true
            if type(available) == "table" then add(available) end
          end
        end
        step()
      end)
    end)
  end
  step()
end

return M
