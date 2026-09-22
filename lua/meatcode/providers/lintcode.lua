local api = require("meatcode.api.lintcode")
local auth = require("meatcode.api.lintcode_auth")

local M = {
  name = "lintcode",
  label = "LintCode",
  auth = auth,
}

local function id(problem)
  return problem.providers and problem.providers.lintcode and problem.providers.lintcode.id
end

function M.resolve(problem, cb)
  local leetcode = problem.providers and problem.providers.leetcode
  if not leetcode or not leetcode.id then return cb(nil, nil) end
  api.resolve_leetcode_slug(leetcode.id, cb)
end

function M.fetch(problem, lang, cb)
  local problem_id = id(problem)
  if not problem_id then return cb("problem is unavailable on LintCode", nil) end
  api.problem(problem_id, lang, cb)
end

function M.submit(problem, meta, code, lang, cb)
  api.submit(id(problem), code, lang, cb)
end

function M.normalize_submission(data)
  local function field(snake, camel)
    local value = data[snake]
    if value == nil then value = data[camel] end
    return value
  end
  local judge_status = tostring(field("judge_status", "judgeStatus") or "")
  local status = tostring(data.status or judge_status ~= "" and judge_status or "Unknown")
  local lowered = status:lower()
  local accepted = lowered == "accepted" or lowered == "success" or judge_status:lower() == "success"
  return {
    status = status,
    accepted = accepted,
    passed = tonumber(field("data_accepted_count", "dataAcceptedCount")) or 0,
    total = tonumber(field("data_total_count", "dataTotalCount")) or 0,
    runtime = field("time_cost", "timeCost") and tostring(field("time_cost", "timeCost")) .. " ms" or nil,
    memory = field("memory_cost", "memoryCost") and tostring(field("memory_cost", "memoryCost")) or nil,
    compile_output = field("compile_info", "compileInfo"),
    runtime_error = field("error_message", "errorMessage"),
    input = data.input,
    expected = data.expected,
    actual = data.output,
    stdout = data.stdout,
    failed_input = accepted and nil or data.input,
  }
end

function M.links(problem)
  local problem_id = id(problem)
  if not problem_id then return {} end
  return {
    { label = "LintCode", url = "https://www.lintcode.com/problem/" .. tostring(problem_id) .. "/" },
    { label = "LintCode solutions", url = "https://www.lintcode.com/problem/" .. tostring(problem_id) .. "/solution" },
  }
end

return M
