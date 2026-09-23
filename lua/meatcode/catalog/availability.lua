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

--- Whether `problem` has been probed and confirmed inaccessible on every
--- content-chain candidate for this user specifically -- either there is no
--- candidate at all, or every candidate that responded is paywalled and
--- `providers.paid_unlocked` says this user's login/plan does not clear that
--- wall. Unlike a plain language mismatch this can never resolve itself by
--- switching `:MeatCode lang`, so it is worth hiding outright rather than
--- just filtering by language.
function M.is_locked(problem)
  local key = providers.problem_key(problem)
  if not key then return false end
  local entry = load()[key]
  return entry ~= nil and entry.locked == true
end

--- How many of `problems` are hidden from browsing UIs for `lang`, split
--- between "confirmed unsupported in this language" and "confirmed
--- inaccessible on every provider". Reads the same persisted probe cache
--- `entries()`-style filters already consult, so this runs no new probes.
function M.hidden_counts(problems, lang)
  local unsupported, locked = 0, 0
  for _, problem in ipairs(problems or {}) do
    if M.is_locked(problem) then
      locked = locked + 1
    elseif M.is_unsupported(problem, lang) then
      unsupported = unsupported + 1
    end
  end
  return unsupported, locked
end

--- Whether a probe for `problem` is already in flight. Callers use this to
--- avoid renotifying "Checking…" for every hover/select while one fetch is
--- still resolving -- `check` already coalesces the actual work behind
--- `state.pending`, but callers outside this module have no other way to
--- see that a wait is already queued.
function M.is_checking(problem)
  local key = providers.problem_key(problem)
  return key ~= nil and state.pending[key] ~= nil
end

--- Probe every content-chain candidate for `problem` and persist the merged
--- language set. `cb(languages, locked)` receives the merged set (possibly
--- empty when every candidate genuinely reports no languages) and whether
--- every candidate turned out to be a permanent access wall for this user.
--- A candidate that errors, or never resolves an id at all, leaves the whole
--- probe uncached so a later attempt retries instead of guessing; only a
--- definitive "no candidates" or "every reachable candidate is paywalled and
--- unlockable-by-nobody-here" verdict gets persisted.
function M.check(problem, cb)
  local key = providers.problem_key(problem)
  if not key then return cb(nil) end
  local cached = load()[key]
  if cached then return cb(cached.languages, cached.locked == true) end

  if state.pending[key] then
    table.insert(state.pending[key], cb)
    return
  end
  state.pending[key] = { cb }

  local function finish(languages, locked)
    local waiters = state.pending[key]
    state.pending[key] = nil
    for _, waiter in ipairs(waiters) do waiter(languages, locked) end
  end

  local candidates = providers.candidates(problem, "content")
  if #candidates == 0 then
    load()[key] = { languages = {}, locked = true, checked_at = os.time() }
    persist()
    return finish({}, true)
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

  -- `attempted` guards against declaring "locked everywhere" when nothing
  -- ever actually resolved an id (e.g. every candidate failed to cross-map),
  -- which says nothing about paywalls at all.
  local attempted, all_walled = false, true
  local i = 0
  local function step()
    i = i + 1
    local name = candidates[i]
    if not name then
      if any_success then
        load()[key] = { languages = languages, checked_at = os.time() }
        persist()
        return finish(languages, false)
      end
      local locked = attempted and all_walled
      if locked then
        load()[key] = { languages = {}, locked = true, checked_at = os.time() }
        persist()
      end
      return finish(languages, locked)
    end
    providers.ensure_id(problem, name, function(_, id)
      if not id then return step() end
      attempted = true
      providers.get(name).fetch(problem, config.options.lang, function(err, meta)
        if err or not meta then
          -- A network/fetch error says nothing about access -- do not let it
          -- count as a paywall.
          all_walled = false
        else
          local available = meta.availableLanguages
          local walled = meta.paid_only and not providers.paid_unlocked(name)
          if walled and (type(available) ~= "table" or #available == 0) then
            -- Locked content this user cannot unlock ships no language list;
            -- this candidate is a genuine dead end.
          else
            any_success = true
            all_walled = false
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
