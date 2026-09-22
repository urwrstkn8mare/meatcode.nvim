local M = {}

--- Every known provider, in canonical order. Completion keys and solution
--- filenames derive from this, so it never follows user configuration.
M.NAMES = { "leetcode", "neetcode", "lintcode" }

--- Fallback-chain slots. `content` chooses statement/tests/starter, `submit`
--- chooses the judge. Chains persist in the cache dir and are edited through
--- the <leader>nc configurator, never via setup().
M.SLOTS = { "content", "submit" }

local loaded = {}
local chains = nil

function M.known(name)
  return vim.tbl_contains(M.NAMES, name)
end

function M.get(name)
  if not M.known(name) then return nil end
  if not loaded[name] then loaded[name] = require("meatcode.providers." .. name) end
  return loaded[name]
end

function M.all()
  local out = {}
  for _, name in ipairs(M.NAMES) do table.insert(out, M.get(name)) end
  return out
end

local function chains_path()
  return require("meatcode.config").options.cache_dir .. "/provider-chains.json"
end

local function sanitize(chain)
  local out, seen = {}, {}
  for _, name in ipairs(type(chain) == "table" and chain or {}) do
    if M.known(name) and not seen[name] then
      seen[name] = true
      table.insert(out, name)
    end
  end
  if #out == 0 then return { unpack(M.NAMES) } end
  return out
end

local function load_chains()
  if chains then return chains end
  local saved = require("meatcode.util").read_json(chains_path())
  chains = {
    content = sanitize(saved and saved.content),
    submit = sanitize(saved and saved.submit),
  }
  return chains
end

--- The fallback chain for `slot` ("content" or "submit"). Unknown names are
--- dropped; an empty result falls back to every provider.
function M.order(slot)
  return { unpack(load_chains()[slot == "submit" and "submit" or "content"]) }
end

--- Replace the fallback chain for `slot` and persist it as the new default.
---@return string[] the sanitized chain actually stored
function M.set_order(slot, chain)
  slot = slot == "submit" and "submit" or "content"
  load_chains()[slot] = sanitize(chain)
  require("meatcode.util").write_json(chains_path(), chains)
  return M.order(slot)
end

function M.id(problem, name)
  local record = type(problem) == "table" and type(problem.providers) == "table"
    and problem.providers[name] or nil
  return type(record) == "table" and record.id or nil
end

function M.available(problem, name)
  return M.id(problem, name) ~= nil
end

--- Providers from `slot`'s chain that could serve `problem`. LintCode stays a
--- candidate whenever LeetCode is present, since its id resolves on demand.
function M.candidates(problem, slot)
  local out = {}
  for _, name in ipairs(M.order(slot)) do
    if M.available(problem, name)
      or (name == "lintcode" and M.available(problem, "leetcode")) then
      table.insert(out, name)
    end
  end
  return out
end

function M.problem_key(problem)
  if type(problem) == "table" and type(problem.key) == "string" then return problem.key end
  for _, name in ipairs(M.NAMES) do
    local id = M.id(problem, name)
    if id then return name .. ":" .. tostring(id) end
  end
end

--- Stable on-disk identity: the first known provider id, so solution files
--- keep their names whatever the configured fallback order is.
function M.filename(problem)
  for _, name in ipairs(M.NAMES) do
    local id = M.id(problem, name)
    if id then return tostring(id) end
  end
end

--- Whether paid-only problems on `name` can be opened. Any login unlocks
--- NeetCode and LintCode, while LeetCode additionally needs Premium.
function M.paid_unlocked(name)
  local backend = M.get(name)
  if not backend or not backend.auth.is_logged_in() then return false end
  if name == "leetcode" then
    local user = backend.auth.user()
    return type(user) == "table" and user.isPremium == true
  end
  return true
end

function M.ensure_id(problem, name, cb)
  local id = M.id(problem, name)
  if id then return cb(nil, id) end
  local provider = M.get(name)
  if not provider or not provider.resolve then return cb(nil, nil) end
  provider.resolve(problem, function(err, resolved)
    if err or not resolved then return cb(err, resolved) end
    problem.providers = problem.providers or {}
    problem.providers[name] = problem.providers[name] or {}
    problem.providers[name].id = resolved
    cb(nil, resolved)
  end)
end

function M.links(problem)
  local links = {}
  for _, provider in ipairs(M.all()) do
    for _, link in ipairs(provider.links(problem) or {}) do table.insert(links, link) end
  end
  return links
end

return M
