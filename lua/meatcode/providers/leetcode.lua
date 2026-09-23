local api = require("meatcode.api.leetcode")
local auth = require("meatcode.api.leetcode_auth")

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
  }
end

return M
