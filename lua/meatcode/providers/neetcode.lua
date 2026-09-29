local api = require("meatcode.api")
local auth = require("meatcode.api.auth")
local formats = require("meatcode.runner.formats")

local M = {
  name = "neetcode",
  label = "NeetCode",
  auth = auth,
}

local function record(problem)
  return problem.providers and problem.providers.neetcode
end

local function id(problem)
  local value = record(problem)
  return value and value.id
end

function M.fetch(problem, lang, cb)
  local problem_id = id(problem)
  if not problem_id then return cb("problem is unavailable on NeetCode", nil) end
  api.problem(problem_id, cb)
end

function M.submit(problem, meta, code, lang, cb)
  api.submit(id(problem), code, lang, cb)
end

--- NeetCode's run input: every argument labelled the way NeetCode's own
--- examples label it; design cases use its single interleaved line.
---@return string[]|nil test_cases, string|nil err
local function test_cases(meta, cases)
  local names = formats.labels(meta.custom_test_cases)
    or formats.python_params(type(meta.starterCode) == "table" and meta.starterCode.python or nil)
  local spec = meta.test_case_type == "class" and formats.class_spec(meta) or nil
  local out = {}
  for i, case in ipairs(cases) do
    local block, err
    if meta.test_case_type == "class" and formats.is_operations(case) then
      if not spec then return nil, "could not read the class shape from NeetCode's starter code" end
      block, err = formats.neetcode_operations(case, spec)
    elseif names then
      block, err = formats.labelled(case, names)
    else
      err = "could not work out NeetCode's argument names"
    end
    if not block then return nil, string.format("case %d: %s", i, err) end
    out[i] = block
  end
  return out, nil
end

local function text(value)
  if type(value) ~= "string" or value == "" then return nil end
  return value
end

--- One Judge0-style run result in `runner`'s cloud-case shape. A crash still
--- reports "Wrong Answer", with the traceback in `stderr` and no output.
local function test_case(result)
  local ran = type(result) == "table" and result or {}
  local tc = type(ran.last_executed_test_case) == "table" and ran.last_executed_test_case or {}
  local status = type(ran.status) == "table" and ran.status.description or nil
  local case = {
    expected = text(tc.expected_output),
    actual = text(tc.user_output),
    stdout = text(tc.user_logs),
  }
  if status == "Accepted" then
    case.correct = true
  elseif not case.actual then
    case.error = text(ran.compile_output) or text(ran.stderr) or status or "no result from NeetCode"
  elseif status == "Wrong Answer" then
    case.correct = false
  else
    case.error = status or "no verdict from NeetCode"
  end
  return case
end

--- At most this many cases per run: the judge rejects more outright.
local CASES_PER_RUN = 4

--- Run `blocks` in chunks, one call after another with a breather between, so
--- a large suite does not trip the judge's case-count or rate limits.
---@param cb fun(err: string|nil, results: table[]|nil)
---@return fun() cancel
local function run_chunked(problem_id, code, lang, blocks, cb)
  local out, start, cancelled, cancel_call = {}, 1, false, nil
  local function finish(err, results)
    if cancelled then return end
    cancelled = true
    cb(err, results)
  end
  local function step()
    if cancelled then return end
    local chunk = vim.list_slice(blocks, start, start + CASES_PER_RUN - 1)
    cancel_call = api.run(problem_id, code, lang, chunk, function(err, results)
      if cancelled then return end
      if err or type(results) ~= "table" or #results ~= #chunk then
        return finish(err or "NeetCode returned an unexpected run result", nil)
      end
      vim.list_extend(out, results)
      start = start + #chunk
      if start > #blocks then return finish(nil, out) end
      vim.defer_fn(step, 250)
    end)
  end
  step()
  return function()
    cancelled = true
    if cancel_call then cancel_call() end
  end
end

--- Run `code` on `cases` with NeetCode's "Run": its own solution supplies each
--- expected output and its checker grades yours. `meta` must be NeetCode's own
--- metadata.
---@param cb fun(err: string|nil, results: table[]|nil)
---@return fun() cancel
function M.test(problem, meta, code, lang, cases, cb)
  local problem_id = id(problem)
  if not problem_id then
    cb("problem is unavailable on NeetCode", nil)
    return function() end
  end
  local blocks, err = test_cases(meta, cases)
  if not blocks then
    cb(err, nil)
    return function() end
  end
  return run_chunked(problem_id, code, lang, blocks, function(run_err, results)
    if run_err then return cb(run_err, nil) end
    local first = results[1]
    if type(first) == "table" and text(first.compile_output) then
      return cb("compile error on NeetCode: " .. first.compile_output, nil)
    end
    local out = {}
    for i, result in ipairs(results) do out[i] = test_case(result) end
    cb(nil, out)
  end)
end

function M.saved_code(problem, lang, cb)
  api.user_code(id(problem), cb)
end

function M.normalize_submission(data)
  local status = data.status and data.status.description or "Unknown"
  local failing = type(data.last_executed_test_case) == "table" and data.last_executed_test_case or {}
  local dist = data.distribution or {}
  local time_dist = dist.timeDistribution or {}
  local memory_dist = dist.memoryDistribution or {}
  local runtime = tonumber(data.time)
  local memory = tonumber(data.memory)
  return {
    status = status,
    accepted = status == "Accepted",
    passed = tonumber(data.correct_test_case_count) or 0,
    total = tonumber(data.test_case_count) or 0,
    runtime = runtime and string.format("%.0f ms", runtime * 1000) or data.time,
    runtime_percentile = tonumber(time_dist.percentile),
    memory = memory and string.format("%.1f MB", memory / 1024) or data.memory,
    memory_percentile = tonumber(memory_dist.percentile),
    compile_output = data.compile_output ~= vim.NIL and data.compile_output or nil,
    runtime_error = data.stderr ~= vim.NIL and data.stderr or nil,
    input = failing.input,
    expected = failing.expected_output,
    actual = failing.user_output,
    stdout = failing.user_logs,
    failed_input = status == "Accepted" and nil or failing.input,
    streak = data.streakUpdate,
  }
end

function M.links(problem)
  local value = record(problem)
  if not value or not value.id then return {} end
  local out = {
    { label = "NeetCode", url = "https://neetcode.io/problems/" .. value.id },
    { label = "NeetCode solution", url = "https://neetcode.io/solutions/" .. value.id },
  }
  if value.video then
    table.insert(out, { label = "NeetCode video", url = "https://youtube.com/watch?v=" .. value.video })
  end
  return out
end

return M
