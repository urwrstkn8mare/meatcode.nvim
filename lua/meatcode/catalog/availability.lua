local config = require("meatcode.config")
local providers = require("meatcode.providers")
local util = require("meatcode.util")

--- Which languages a problem can actually be solved in, and whether it is
--- reachable at all, merged across every content-chain candidate. A probe
--- fetches each candidate provider's raw metadata once (the same request
--- opening the problem would make, so it already carries this user's real
--- credentials), unions their `availableLanguages`, and notes when every
--- candidate's own response withheld every language while flagged
--- paid-only -- a wall this specific fetch just proved, not a guess about
--- what a provider's login/subscription tier should unlock. The result is
--- provider-set, not language-set: switching your configured language later
--- is a cache lookup, never a re-fetch, because the probe already
--- discovered every language every candidate supports.
local M = {}

local state = { data = nil, pending = {}, warmer = nil, listeners = {} }

--- Cache-entry format version, bumped whenever `check`'s walled/empty
--- determination changes in a way that could have produced a different
--- verdict for an already-cached entry. An older probe generation could
--- mistake "every candidate withheld content" for "checked, zero languages,
--- accessible" -- it never mistook the other direction, so an entry that
--- already carries real languages or a locked verdict is never wrong and
--- never needs this.
local PROBE_SCHEMA = 1

--- Whether `entry` predates the current walled logic in a way that could
--- have hidden a wall behind "accessible with zero languages", and so is
--- worth re-probing once instead of trusting forever. An entry missing
--- `schema` entirely predates the field itself and is caught the same way.
local function needs_reprobe(entry)
  if not entry then return false end
  if entry.locked then return false end
  if type(entry.languages) == "table" and #entry.languages > 0 then return false end
  return entry.schema ~= PROBE_SCHEMA
end

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

local function store(problem, entry)
  local key = providers.problem_key(problem)
  if not key then return end
  entry.schema = PROBE_SCHEMA
  load()[key] = entry
  persist()
  for _, listener in ipairs(state.listeners) do pcall(listener, problem) end
end

--- The full set of languages known to be servable for `problem`, or nil if
--- it has never been probed.
function M.known(problem)
  local key = providers.problem_key(problem)
  if not key then return nil end
  local entry = load()[key]
  if needs_reprobe(entry) then return nil end
  return entry and entry.languages or nil
end

--- Subscribe to determined availability cache updates.
---@param fn fun(problem: table)
function M.on_update(fn)
  table.insert(state.listeners, fn)
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
--- candidate at all, or every candidate's own (already-authenticated)
--- response withheld every language while flagged paid-only. Unlike a plain
--- language mismatch this can never resolve itself by switching
--- `:MeatCode lang`, so it is worth hiding outright rather than just
--- filtering by language.
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
--- language set. `cb(languages, locked, err)` receives the merged set
--- (possibly empty when every candidate genuinely reports no languages) and
--- whether every candidate turned out to be a permanent access wall for this
--- user -- decided from that candidate's own paid-only-and-language-less
--- response, since the fetch already carries this user's real credentials,
--- never from a separate per-provider "is this account entitled" guess.
--- `err` is nil on any determined outcome (success or locked) and a concrete
--- message when the probe genuinely could not find out -- a candidate
--- erroring, or nothing ever resolving an id at all -- so a caller never has
--- to guess why nothing happened; that state still leaves the probe uncached
--- so a later attempt can succeed once whatever failed recovers. A cached
--- entry `needs_reprobe` flags gets the same treatment: probed again as if
--- it were never cached.
function M.check(problem, cb)
  local key = providers.problem_key(problem)
  if not key then return cb(nil, false, "problem has no stable identity") end
  local cached = load()[key]
  if cached and not needs_reprobe(cached) then return cb(cached.languages, cached.locked == true, nil) end

  if state.pending[key] then
    table.insert(state.pending[key], cb)
    return
  end
  state.pending[key] = { cb }

  local function finish(languages, locked, err)
    local waiters = state.pending[key]
    state.pending[key] = nil
    for _, waiter in ipairs(waiters) do waiter(languages, locked, err) end
  end

  local candidates = providers.candidates(problem, "content")
  if #candidates == 0 then
    store(problem, { languages = {}, locked = true, checked_at = os.time() })
    return finish({}, true, nil)
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
  local errors = {}
  local i = 0
  local function step()
    i = i + 1
    local name = candidates[i]
    if not name then
      if any_success then
        store(problem, { languages = languages, checked_at = os.time() })
        return finish(languages, false, nil)
      end
      local locked = attempted and all_walled
      if locked then
        store(problem, { languages = {}, locked = true, checked_at = os.time() })
        return finish({}, true, nil)
      end
      local err = #errors > 0 and table.concat(errors, "; ")
        or "no provider could resolve this problem"
      return finish(languages, false, err)
    end
    providers.ensure_id(problem, name, function(id_err, id)
      if not id then
        if id_err then table.insert(errors, name .. ": " .. id_err) end
        return step()
      end
      attempted = true
      providers.get(name).fetch(problem, config.options.lang, function(err, meta)
        if err or not meta then
          -- A network/fetch error says nothing about access -- do not let it
          -- count as a paywall, but do surface it if nothing else succeeds.
          all_walled = false
          table.insert(errors, name .. ": " .. tostring(err or "no metadata"))
        else
          local available = meta.availableLanguages
          local no_languages = type(available) ~= "table" or #available == 0
          if meta.paid_only and no_languages then
            -- This candidate's own response -- fetched with this user's real
            -- credentials -- withheld every language; that is a genuine dead
            -- end whatever `providers.paid_unlocked` assumes about this
            -- provider's access tiers.
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

-- One catalog probe at a time keeps this background sweep below the request
-- cadence of the providers' own paginated catalog syncs, while still letting
-- an interactive hover coalesce with the same `check` if the user reaches it.
local BACKGROUND_DELAY_MS = 500

--- Warm the persisted availability cache for every currently unknown problem.
--- A sweep is deliberately serial: each `check` may itself follow multiple
--- content-chain providers, so parallelising catalog-wide work would turn one
--- background task into a request burst. Calling this again while a sweep is
--- running merges new catalog entries into the same queue.
---@param problems table[]
function M.warm(problems)
  local warm = state.warmer
  if not warm then
    warm = { queue = {}, seen = {}, checked = 0, failures = 0, locked = 0, running = false }
    state.warmer = warm
  end

  for _, problem in ipairs(problems or {}) do
    local key = providers.problem_key(problem)
    if key and not warm.seen[key] and not M.known(problem) then
      warm.seen[key] = true
      table.insert(warm.queue, problem)
    end
  end
  if warm.running or #warm.queue == 0 then return end

  warm.running = true
  warm.handle = util.progress("Checking catalog access & language support…")
  local function step()
    local problem = table.remove(warm.queue, 1)
    if not problem then
      warm.running = false
      local message = string.format("Catalog access & language support checked for %d problem%s",
        warm.checked, warm.checked == 1 and "" or "s")
      if warm.locked > 0 then
        message = message .. string.format(" · %d locked", warm.locked)
      end
      if warm.failures > 0 then
        message = message .. string.format(" · %d couldn't be checked", warm.failures)
      end
      warm.handle:finish(message)
      state.warmer = nil
      return
    end

    warm.checked = warm.checked + 1
    warm.handle:report(string.format("Checking catalog language support %d/%d: %s",
      warm.checked, warm.checked + #warm.queue, problem.name))
    M.check(problem, function(_, locked, err)
      if err then
        warm.failures = warm.failures + 1
      elseif locked then
        warm.locked = warm.locked + 1
      end
      vim.defer_fn(step, BACKGROUND_DELAY_MS)
    end)
  end
  step()
end

return M
