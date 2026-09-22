local api = require("meatcode.api")
local auth = require("meatcode.api.auth")

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
