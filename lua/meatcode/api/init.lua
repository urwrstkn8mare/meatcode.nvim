local auth = require("meatcode.api.auth")
local client = require("meatcode.api.client")
local util = require("meatcode.util")

--- Typed wrappers over the NeetCode backend.
---
--- Endpoint names and payload shapes were recovered from the site's JS bundle;
--- see doc/api/neetcode.md for the full map.
local M = {}


--- Run `fn(token, cb)` with a fresh ID token, short-circuiting on auth failure.
local function authed(fn, cb)
  auth.id_token(function(err, token)
    if err then
      return cb(err, nil)
    end
    fn(token, cb)
  end)
end

--- Full problem payload: description, starter code and reference solutions for
--- every supported language, article body and video id. Works unauthenticated.
---@param problem_id string NeetCode problem id, e.g. "two-integer-sum"
---@param cb fun(err: string|nil, meta: table|nil)
function M.problem(problem_id, cb)
  client.callable("getProblemMetadataFunctionHttp", { problemId = problem_id }, nil, function(err, data)
    if err then
      return cb(err, nil)
    end
    if not data then
      return cb("unknown problem: " .. problem_id, nil)
    end
    data.schema = util.META_SCHEMA
    cb(nil, data)
  end)
end

--- Run code against a set of visible test cases on NeetCode's judge.
---@param problem_id string
---@param code string
---@param lang string
---@param test_cases string[] each a newline-separated "name=value" block
---@param cb fun(err: string|nil, results: table[]|nil)
function M.run(problem_id, code, lang, test_cases, cb)
  authed(function(token, done)
    client.callable("runCodeFunctionHttp", {
      problemId = problem_id,
      rawCode = code,
      lang = lang,
      testCases = test_cases,
    }, { token = token, timeout = 90 }, done)
  end, cb)
end

--- Submit against the full hidden test suite.
---@param cb fun(err: string|nil, result: table|nil)
function M.submit(problem_id, code, lang, cb)
  authed(function(token, done)
    client.callable("executeCodeFunctionHttp", {
      problemId = problem_id,
      rawCode = code,
      lang = lang,
    }, { token = token, timeout = 120 }, done)
  end, cb)
end


--- Code the user last saved on neetcode.io for a problem.
function M.user_code(problem_id, cb)
  authed(function(token, done)
    client.dispatch("getUserCode", { problemId = problem_id }, { token = token }, done)
  end, cb)
end

--- Push local code back up to neetcode.io so the web editor stays in sync.
function M.save_user_code(problem_id, lang, code, cb)
  authed(function(token, done)
    client.dispatch("saveUserCode", {
      problemId = problem_id,
      lang = lang,
      tabs = { { name = "main", code = code } },
      activeTabIndex = 0,
    }, { token = token }, done)
  end, cb)
end

--- One visible test case input, by index.
function M.test_case_input(problem_id, index, cb)
  authed(function(token, done)
    client.dispatch("getTestCaseInput", {
      problemId = problem_id,
      testCaseIndex = index,
    }, { token = token }, done)
  end, cb)
end

function M.user_stats(cb)
  authed(function(token, done)
    client.dispatch("getUserStats", {}, { token = token }, done)
  end, cb)
end

--- Per-day activity summary used by the streak calendar: a map of
--- "YYYY-MM-DD" (UTC) to `{count = integer}`, plus `joined` (account creation
--- date). Days with `count == 0` have no recorded activity.
function M.streak_data(cb)
  authed(function(token, done)
    client.dispatch("getUserStreakData", {}, { token = token }, done)
  end, cb)
end

--- Every run/submission recorded on one UTC calendar day.
---@param date string "YYYY-MM-DD"
---@param cb fun(err: string|nil, activity: {submissions: table[]}|nil)
function M.day_activity(date, cb)
  authed(function(token, done)
    client.dispatch("getUserDailyActivity", { date = date }, { token = token }, done)
  end, cb)
end

return M
