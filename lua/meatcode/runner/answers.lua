local config = require("meatcode.config")
local util = require("meatcode.util")

--- One cache of correct answers per problem, shared by every oracle.
---
--- Each input maps to every answer known for it, with the source that produced
--- it: `judge:<provider>` (disclosed by a failed submission),
--- `cloud:<provider>` (a judge's test run: its own answer, plus yours when the
--- judge accepted a different one), `oracle:<code hash>` (an executable
--- candidate's output) and `checker:<hash>` (an output an openleetcode checker
--- accepted). Answers printed in statements join as `statement:<provider>`
--- straight from the metadata, never persisted.
---
--- Judge, cloud and statement answers are ground truth. The rest only count
--- while the candidate that produced them is the selected oracle, and are
--- purged when it is rejected. Several answers for one input are normal: a
--- problem may accept more than one.
local M = {}

--- At most this many answers are kept per input; judge-disclosed ones are the
--- last to go.
local MAX_PER_INPUT = 16

local GROUND_TRUTH = { judge = true, cloud = true, statement = true }

---@param source string
---@return string kind "judge"|"cloud"|"statement"|"oracle"|"checker"
function M.kind(source)
  return (tostring(source):match("^([^:]+)"))
end

--- Identity of an input: its trimmed argument lines with `name=` labels
--- dropped. The harnesses bind arguments positionally, so NeetCode's
--- `nums=[1,2]` and LeetCode's `[1,2]` are the same input and share answers.
---@param block string
---@return string
function M.key(block)
  local parts = {}
  for line in (tostring(block) .. "\n"):gmatch("([^\n]*)\n") do
    line = vim.trim(line)
    if line ~= "" then
      local value = line:match("^[%a_][%w_]*%s*=(.*)$")
      table.insert(parts, value and vim.trim(value) or line)
    end
  end
  return table.concat(parts, "\n")
end

local function path(problem_id)
  return string.format("%s/known-answers/%s.json",
    config.options.cache_dir, util.slug(tostring(problem_id)))
end

--- Every stored answer, by input key. The store predating the shared cache held
--- a single judge-disclosed answer string per input; those read as such.
---@return table<string, {output: string, source: string}[]>
function M.load(problem_id)
  local raw = util.read_json(path(problem_id))
  local out = {}
  for key, entries in pairs(type(raw) == "table" and raw or {}) do
    if type(entries) == "string" then entries = { { output = entries, source = "judge" } } end
    if type(key) == "string" and type(entries) == "table" then
      local normalized = M.key(key)
      local list = out[normalized] or {}
      for _, entry in ipairs(entries) do
        if type(entry) == "table" and type(entry.output) == "string" and vim.trim(entry.output) ~= ""
          and type(entry.source) == "string" then
          table.insert(list, { output = entry.output, source = entry.source })
        end
      end
      if #list > 0 then out[normalized] = list end
    end
  end
  return out
end

local function save(problem_id, store)
  if next(store) == nil then
    os.remove(path(problem_id))
    return
  end
  util.write_json(path(problem_id), store)
end

--- Record answers, re-reading the store first: background validation and a
--- foreground run may both be adding. An output already stored from the same
--- source is not stored twice.
---@param entries {input: string, output: string, source: string}[]
---@return integer added
function M.add(problem_id, entries)
  local store, added = M.load(problem_id), 0
  for _, entry in ipairs(entries) do
    if type(entry.input) == "string" and type(entry.output) == "string"
      and vim.trim(entry.output) ~= "" then
      local key = M.key(entry.input)
      local list = store[key] or {}
      local known = false
      for _, existing in ipairs(list) do
        if existing.output == entry.output and existing.source == entry.source then
          known = true
          break
        end
      end
      if not known then
        table.insert(list, { output = entry.output, source = entry.source })
        added = added + 1
        while #list > MAX_PER_INPUT do
          local drop = 1
          for i, existing in ipairs(list) do
            if M.kind(existing.source) ~= "judge" then
              drop = i
              break
            end
          end
          table.remove(list, drop)
        end
        store[key] = list
      end
    end
  end
  if added > 0 then save(problem_id, store) end
  return added
end

--- Forget every answer `source` produced.
function M.purge(problem_id, source)
  local store, changed = M.load(problem_id), false
  for key, list in pairs(store) do
    local kept = vim.tbl_filter(function(entry) return entry.source ~= source end, list)
    if #kept ~= #list then
      changed = true
      store[key] = #kept > 0 and kept or nil
    end
  end
  if changed then save(problem_id, store) end
end

--- Answers printed in the statements, by input key.
local function statement_answers(meta)
  local out = {}
  local function add(input, output, provider)
    if type(input) ~= "string" or type(output) ~= "string" or vim.trim(output) == "" then return end
    local key = M.key(input)
    out[key] = out[key] or {}
    table.insert(out[key], { output = output, source = "statement:" .. tostring(provider or "statement") })
  end
  for _, answer in ipairs(type(meta.oracle_answers) == "table" and meta.oracle_answers or {}) do
    if type(answer) == "table" then add(answer.input, answer.output, answer.provider) end
  end
  -- Provider metadata used directly, before the oracle chain was merged.
  local sources = type(meta.custom_test_cases) == "table" and meta.custom_test_cases or {}
  for i, output in ipairs(type(meta.expected_outputs) == "table" and meta.expected_outputs or {}) do
    add(sources[i], output, meta.provider)
  end
  return out
end

--- Every answer trusted for each case, strongest first: judge-disclosed, test
--- runs, statements, then answers from the `trusted` sources (the selected
--- candidate). An empty list means no known answer.
---@param trusted table<string, boolean>|nil
---@return string[][]
function M.lookup(problem_id, meta, cases, trusted)
  local store, statements = M.load(problem_id), statement_answers(meta)
  local out = {}
  for i, case in ipairs(cases) do
    local key = M.key(case)
    local list, seen = {}, {}
    local function take(entries, wanted)
      for _, entry in ipairs(entries or {}) do
        if wanted(entry.source) and not seen[entry.output] then
          seen[entry.output] = true
          table.insert(list, entry.output)
        end
      end
    end
    take(store[key], function(source) return M.kind(source) == "judge" end)
    take(store[key], function(source) return M.kind(source) == "cloud" end)
    take(statements[key], function() return true end)
    take(store[key], function(source) return trusted ~= nil and trusted[source] == true end)
    out[i] = list
  end
  return out
end

--- Ground-truth answers a candidate is validated against: statement answers
--- and answers disclosed by failed submissions. Test-run answers are left out
--- so every run that learns one does not force a revalidation; a candidate
--- that disagrees with one is caught when the run merges it instead.
---@return {input: string, answers: string[]}[]
function M.known(problem_id, meta)
  local by_key = {}
  local function add(key, output)
    by_key[key] = by_key[key] or {}
    if not vim.tbl_contains(by_key[key], output) then table.insert(by_key[key], output) end
  end
  for key, list in pairs(statement_answers(meta)) do
    for _, entry in ipairs(list) do add(key, entry.output) end
  end
  for key, list in pairs(M.load(problem_id)) do
    for _, entry in ipairs(list) do
      if M.kind(entry.source) == "judge" then add(key, entry.output) end
    end
  end
  local out = {}
  for key, list in pairs(by_key) do
    table.sort(list)
    table.insert(out, { input = key, answers = list })
  end
  table.sort(out, function(a, b) return a.input < b.input end)
  return out
end

---@return boolean
function M.is_ground_truth(source)
  return GROUND_TRUTH[M.kind(source)] == true
end

local function decode(text)
  if type(text) ~= "string" then return false, nil end
  local ok, value = pcall(vim.json.decode, text)
  return ok, value
end

local function equal(a, b)
  if type(a) == "number" and type(b) == "number" then
    -- Judges print floats rounded (LeetCode to five places).
    return math.abs(a - b) <= 1e-5
  end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  if vim.islist(a) ~= vim.islist(b) then return false end
  for k, v in pairs(a) do
    if not equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

--- Order-insensitive form: every list sorted by its encoding, recursively.
local function canonical(value)
  if type(value) ~= "table" then return value end
  local out = vim.islist(value) and {} or vim.empty_dict()
  for k, v in pairs(value) do out[k] = canonical(v) end
  if vim.islist(out) then
    table.sort(out, function(x, y) return vim.json.encode(x) < vim.json.encode(y) end)
  end
  return out
end

local function squeeze(text)
  return (vim.trim(text):gsub("%s+", ""))
end

--- How an output compares with one answer, under the harnesses' rules: equal,
--- equal up to list ordering, or neither. Anything that is not JSON is
--- compared as text.
---@return "pass"|"pass_unordered"|nil
function M.compare(actual, answer)
  local ok_a, a = decode(actual)
  local ok_b, b = decode(answer)
  if not (ok_a and ok_b) then
    return type(actual) == "string" and type(answer) == "string"
      and squeeze(actual) == squeeze(answer) and "pass" or nil
  end
  if equal(a, b) then return "pass" end
  if equal(canonical(a), canonical(b)) then return "pass_unordered" end
  return nil
end

--- Grade an output against every acceptable answer: the status, and the
--- answer to show (the one matched, or the first).
---@param answers string[]
---@return "pass"|"pass_unordered"|"fail"|"no_oracle" status, string|nil shown
function M.grade(actual, answers)
  if #answers == 0 then return "no_oracle", nil end
  local unordered = nil
  for _, answer in ipairs(answers) do
    local verdict = M.compare(actual, answer)
    if verdict == "pass" then return "pass", answer end
    if verdict == "pass_unordered" and not unordered then unordered = answer end
  end
  if unordered then return "pass_unordered", unordered end
  return "fail", answers[1]
end

return M
