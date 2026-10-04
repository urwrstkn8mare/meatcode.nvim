--- Submission-only entry-point adapters. Unknown languages must never bypass validation.
local M = {}
local adapters = {
  cpp = "meatcode.submission.cpp",
  python = "meatcode.submission.python",
  rust = "meatcode.runner.rust",
  swift = "meatcode.runner.swift",
}

function M.adapt(code, lang, starter, judge_starter)
  local module = adapters[lang]
  if not module then
    return nil, "cross-provider submission adaptation is not implemented for "
      .. require("meatcode.lang").name(lang) .. "; use the submit judge as the content provider"
  end
  if type(judge_starter) ~= "string" or judge_starter == "" then
    return nil, "the submit judge has no " .. require("meatcode.lang").name(lang) .. " starter signature"
  end
  return require(module).adapt_submission(code, starter, judge_starter)
end

return M
