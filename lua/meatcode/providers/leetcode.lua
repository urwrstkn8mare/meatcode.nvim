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

function M.submit(problem, meta, code, lang, cb)
  api.submit(id(problem), meta.question_id, code, lang, cb)
end

function M.normalize_submission(data)
  local accepted = data.status_code == 10 or data.status_msg == "Accepted"
  return {
    status = data.status_msg or "Unknown",
    accepted = accepted,
    passed = tonumber(data.total_correct) or 0,
    total = tonumber(data.total_testcases) or 0,
    runtime = data.status_runtime,
    runtime_percentile = tonumber(data.runtime_percentile),
    memory = data.status_memory,
    memory_percentile = tonumber(data.memory_percentile),
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
