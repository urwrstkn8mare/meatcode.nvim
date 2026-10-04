local api = require("meatcode.api.leetcode")
local auth = require("meatcode.api.leetcode_auth")
local formats = require("meatcode.runner.formats")

local M = {
  name = "leetcode",
  label = "LeetCode",
  auth = auth,
}

local function id(problem)
  return problem.providers and problem.providers.leetcode and problem.providers.leetcode.id
end

function M.fetch(problem, lang, cb)
  local slug = id(problem)
  if not slug then return cb("problem is unavailable on LeetCode", nil) end
  api.problem(slug, cb)
end

--- Add executable oracle candidates that live outside the question payload.
function M.enrich(problem, lang, meta, cb, status)
  local pending = 2
  local function done()
    pending = pending - 1
    if pending == 0 then cb(nil, meta) end
  end
  meta.editorial_solutions = meta.editorial_solutions or {}
  meta.community_solutions = meta.community_solutions or {}
  if status then status("Checking LeetCode's official editorial…") end
  api.editorial_solutions(id(problem), lang, function(err, codes)
    if err and status then status("LeetCode editorial unavailable; continuing.") end
    if not err then meta.editorial_solutions[lang] = codes or {} end
    done()
  end)
  if status then status("Checking LeetCode's most-voted community solutions…") end
  api.community_solutions(id(problem), lang, function(err, codes)
    if err and status then status("LeetCode community solutions unavailable; continuing.") end
    if not err then meta.community_solutions[lang] = codes or {} end
    done()
  end)
end

--- The submit endpoint keys on LeetCode's internal `questionId`, which only
--- LeetCode-sourced data carries: NeetCode roadmap records and metadata have
--- none, and LintCode metadata's `question_id` is LintCode's own id.
local function known_question_id(problem, meta)
  if meta.provider == "leetcode" and meta.question_id then return meta.question_id end
  local question_id = problem.providers.leetcode.question_id
  if question_id and question_id ~= "" then return question_id end
end

function M.submit(problem, meta, code, lang, cb)
  local slug = id(problem)
  local question_id = known_question_id(problem, meta)
  if question_id then return api.submit(slug, question_id, code, lang, cb) end
  api.question_id(slug, function(err, resolved)
    if err then return cb(err, nil) end
    -- The session owns this problem copy; a resubmit skips the lookup.
    problem.providers.leetcode.question_id = resolved
    api.submit(slug, resolved, code, lang, cb)
  end)
end

--- LeetCode's "Run" input: every case's arguments, one per line, back to back.
--- Design cases use LeetCode's two-line layout.
---@return string|nil data_input, string|nil err
local function data_input(meta, cases)
  local spec = meta.test_case_type == "class" and formats.class_spec(meta) or nil
  local blocks = {}
  for i, case in ipairs(cases) do
    if meta.test_case_type == "class" and formats.is_operations(case) then
      if not spec then return nil, "could not read the class shape from LeetCode's starter code" end
      local block, err = formats.leetcode_operations(case, spec)
      if not block then return nil, string.format("case %d: %s", i, err) end
      blocks[i] = block
    else
      blocks[i] = table.concat(formats.values(case), "\n")
    end
  end
  return table.concat(blocks, "\n"), nil
end

--- Entry `i` of one of the run's per-case lists. Each list is padded with a
--- trailing "", and every real answer is JSON-rendered, so "" never is one.
local function nth(list, i)
  local value = type(list) == "table" and list[i] or nil
  if value == nil or value == vim.NIL or value == "" then return nil end
  return value
end

--- Per-case results of a finished run, in `runner`'s cloud-case shape.
---@return table[]|nil results, string|nil err
local function test_results(data, count)
  if data.status_code == 20 then
    return nil, "compile error on LeetCode: " .. tostring(data.full_compile_error or data.compile_error or "")
  end
  if data.expected_status_code and data.expected_status_code ~= 10 then
    return nil, "LeetCode's own solution failed on these inputs (" .. tostring(data.expected_status_msg
      or data.expected_runtime_error or "invalid test case?") .. ")"
  end
  local bits = type(data.compare_result) == "string" and data.compare_result or ""
  local failure = data.status_code ~= 10
    and (tostring(data.status_msg or "error") .. (data.runtime_error and (": " .. data.runtime_error) or ""))
    or nil
  local out, failed = {}, false
  for i = 1, count do
    local actual = nth(data.code_answer, i)
    local case = { expected = nth(data.expected_code_answer, i), actual = actual, stdout = nth(data.std_output_list, i) }
    if actual then
      case.correct = bits:sub(i, i) == "1"
    elseif failure and not failed then
      failed = true
      case.error = failure
    elseif failure then
      case.error = "not run: an earlier case failed on LeetCode"
    end
    out[i] = case
  end
  return out, nil
end

--- Run `code` on `cases` with LeetCode's "Run": its own solution supplies each
--- expected output and the problem's checker grades yours, so a different but
--- valid answer is still correct. `meta` must be LeetCode's own metadata.
---@param cb fun(err: string|nil, results: table[]|nil)
---@return fun() cancel
function M.test(problem, meta, code, lang, cases, cb)
  local slug = id(problem)
  if not slug then
    cb("problem is unavailable on LeetCode", nil)
    return function() end
  end
  local input, input_err = data_input(meta, cases)
  if not input then
    cb(input_err, nil)
    return function() end
  end

  local cancelled, cancel_run = false, nil
  local function run(question_id)
    if cancelled then return end
    cancel_run = api.interpret(slug, question_id, code, lang, input, function(err, data)
      if err then return cb(err, nil) end
      local results, results_err = test_results(data, #cases)
      cb(results_err, results)
    end)
  end
  local question_id = known_question_id(problem, meta)
  if question_id then
    run(question_id)
  else
    api.question_id(slug, function(err, resolved)
      if cancelled then return end
      if err then return cb(err, nil) end
      problem.providers.leetcode.question_id = resolved
      run(resolved)
    end)
  end
  return function()
    cancelled = true
    if cancel_run then cancel_run() end
  end
end

--- `status_code` of a verdict whose tests all passed but whose code broke a
--- restriction in the statement, per LeetCode's AI-judged restrictions check.
local RESTRICTIONS_FAILED = 50

function M.normalize_submission(data)
  local accepted = data.status_code == 10 or data.status_msg == "Accepted"
  -- LeetCode voids the run's stats on this verdict (its site shows runtime and
  -- memory as N/A, with no percentiles), and states why instead.
  local restricted = data.status_code == RESTRICTIONS_FAILED
  return {
    status = data.status_msg or "Unknown",
    accepted = accepted,
    passed = tonumber(data.total_correct) or 0,
    total = tonumber(data.total_testcases) or 0,
    runtime = not restricted and data.status_runtime or nil,
    runtime_percentile = not restricted and tonumber(data.runtime_percentile) or nil,
    memory = not restricted and data.status_memory or nil,
    memory_percentile = not restricted and tonumber(data.memory_percentile) or nil,
    restriction = restricted and data.ai_judge_message or nil,
    compile_output = data.full_compile_error or data.compile_error,
    runtime_error = data.full_runtime_error or data.runtime_error,
    input = data.last_testcase or data.input,
    expected = data.expected_output,
    actual = data.code_output,
    stdout = data.std_output,
    failed_input = accepted and nil or data.last_testcase or data.input,
  }
end

function M.links(problem)
  local slug = id(problem)
  if not slug then return {} end
  return {
    { label = "LeetCode", url = "https://leetcode.com/problems/" .. slug .. "/" },
    { label = "LeetCode solutions", url = "https://leetcode.com/problems/" .. slug .. "/solutions/" },
    { label = "LeetCode submissions", url = "https://leetcode.com/problems/" .. slug .. "/submissions/" },
  }
end

return M
