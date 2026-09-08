local config = require("neetcode.config")
local cpp = require("neetcode.runner.cpp")
local ops = require("neetcode.runner.ops")
local util = require("neetcode.util")

--- Runs a solution against the visible test cases, locally.
---
--- NeetCode keeps expected outputs server-side, so we obtain them by executing
--- the site's own reference solution over the same inputs and diffing the two.
--- That keeps `run` fully offline and instant; `submit` still goes to the cloud
--- because only the backend has the hidden test suite.
local M = {}

M.SUPPORTED = { python = true, cpp = true }

local function harness_dir()
  local this = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(this) .. "/harness"
end

local function workdir(problem_id, lang)
  local dir = string.format("%s/run/%s-%s", config.options.cache_dir, problem_id, lang)
  util.mkdirp(dir)
  return dir
end

--- Remove preprocessor includes so user code can be pulled into a namespace.
local function strip_includes(src)
  return (src:gsub("#include%s*[<\"][^>\"]*[>\"]", ""))
end

---@class neetcode.RunResult
---@field ok boolean
---@field cases table[]
---@field error string|nil
---@field method string|nil
---@field passed integer
---@field total integer

local function summarize(report)
  if report.unsupported then
    report.error = (report.error or "unsupported")
      .. " — use :NeetCode submit to run this one in the cloud"
  end
  local passed = 0
  for _, c in ipairs(report.cases or {}) do
    if c.status == "pass" or c.status == "pass_unordered" then
      passed = passed + 1
    end
  end
  report.passed = passed
  report.total = #(report.cases or {})
  return report
end

--- `unsupported` marks a problem we cannot faithfully reproduce locally, as
--- opposed to something going wrong; the results panel presents the two differently.
local function fail(cb, msg, unsupported)
  cb(summarize({ ok = false, error = msg, cases = {}, unsupported = unsupported }))
end

--- Decode a harness report, tolerating trailing noise on stdout.
local function decode_report(stdout)
  local line = nil
  for candidate in stdout:gmatch("[^\n]+") do
    if candidate:sub(1, 1) == "{" then
      line = candidate
    end
  end
  if not line then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, line)
  return ok and decoded or nil
end

--- Run the compiled/interpreted harness and hand back a report.
local function execute(cmd, dir, cb)
  local timeout_ms = (config.options.runner.time_limit or 10) * 1000
  -- Give the whole batch room proportional to the number of cases.
  vim.system(cmd, { text = true, cwd = dir, timeout = timeout_ms * 6 }, function(res)
    vim.schedule(function()
      local report = decode_report(res.stdout or "")
      if report then
        return cb(summarize(report))
      end

      -- No report: the process died. Attribute it to the last announced case.
      local last = nil
      for idx in (res.stderr or ""):gmatch("CASE (%d+)") do
        last = tonumber(idx)
      end

      local msg
      if res.code == 124 or res.signal == 15 or res.signal == 9 then
        msg = "timed out — possible infinite loop"
      elseif res.signal and res.signal ~= 0 then
        msg = string.format("crashed with signal %d", res.signal)
      else
        msg = (res.stderr or ""):gsub("CASE %d+\n", "")
        msg = vim.trim(msg)
        if msg == "" then
          msg = "the harness produced no output (exit code " .. tostring(res.code) .. ")"
        end
      end
      if last then
        msg = string.format("test case %d: %s", last + 1, msg)
      end
      cb(summarize({ ok = false, error = msg, cases = {} }))
    end)
  end)
end

local function run_python(problem_id, code, meta, cases, cb)
  local dir = workdir(problem_id, "python")
  local ref = meta.solutions and meta.solutions.python
  if not ref or ref == "" then
    return fail(cb, "NeetCode publishes no Python reference solution for this problem", true)
  end

  util.write_file(dir .. "/user.py", code)
  util.write_file(dir .. "/ref.py", ref)
  util.write_json(dir .. "/cases.json", cases)

  local py = vim.deepcopy(config.options.runner.python.cmd)
  table.insert(py, harness_dir() .. "/python.py")
  table.insert(py, dir)
  execute(py, dir, cb)
end

--- Design problems: normalise the call sequence, then replay it in the harness.
--- `mode` is "class" for an operation sequence, "roundtrip" for encode/decode.
local function run_python_class(problem_id, code, meta, cases, cb, mode)
  local dir = workdir(problem_id, "python")
  local ref = meta.solutions and meta.solutions.python
  if not ref or ref == "" then
    return fail(cb, "NeetCode publishes no Python reference solution for this problem", true)
  end

  if mode == "class" then
    local spec, spec_err = ops.python_spec(meta.starterCode and meta.starterCode.python)
    if not spec then
      return fail(cb, spec_err, true)
    end
    local encoded, enc_err = ops.encode_cases(cases, spec)
    if not encoded then
      return fail(cb, enc_err, true)
    end
    util.write_file(dir .. "/ops.json", encoded)
  end

  util.write_file(dir .. "/user.py", code)
  util.write_file(dir .. "/ref.py", ref)
  util.write_json(dir .. "/cases.json", cases)

  local py = vim.deepcopy(config.options.runner.python.cmd)
  table.insert(py, harness_dir() .. "/python.py")
  table.insert(py, dir)
  table.insert(py, mode)
  execute(py, dir, cb)
end

local function run_cpp(problem_id, code, meta, cases, cb, mode)
  local dir = workdir(problem_id, "cpp")
  local ref = meta.solutions and meta.solutions.cpp
  if not ref or ref == "" then
    return fail(cb, "NeetCode publishes no C++ reference solution for this problem", true)
  end
  local starter = meta.starterCode and meta.starterCode.cpp
  if not starter or starter == "" then
    return fail(cb, "no C++ starter code to derive the signature from", true)
  end

  local main_src, gen_err
  if mode == "roundtrip" then
    main_src, gen_err = cpp.generate_roundtrip(starter)
  elseif mode == "class" then
    local cls, cls_err = cpp.parse_class(starter)
    if not cls then
      return fail(cb, cls_err, true)
    end
    local encoded, enc_err = ops.encode_cases(cases, cpp.class_spec(cls))
    if not encoded then
      return fail(cb, enc_err, true)
    end
    util.write_file(dir .. "/ops.json", encoded)
    main_src, gen_err = cpp.generate_class(starter)
  else
    main_src, gen_err = cpp.generate(starter)
  end
  if not main_src then
    return fail(cb, gen_err, true)
  end

  util.write_file(dir .. "/user.cpp", strip_includes(code))
  util.write_file(dir .. "/ref.cpp", strip_includes(ref))
  util.write_file(dir .. "/main.cpp", main_src)
  util.write_json(dir .. "/cases.json", cases)

  local runtime = util.read_file(harness_dir() .. "/cpp_runtime.h")
  util.write_file(dir .. "/cpp_runtime.h", runtime)
  local stdlib = util.read_file(harness_dir() .. "/cpp_stdlib.h")
  util.write_file(dir .. "/cpp_stdlib.h", stdlib)

  local bin = dir .. "/run"
  local compile = {}
  for _, arg in ipairs(config.options.runner.cpp.cmd) do
    arg = arg:gsub("{out}", bin):gsub("{source}", dir .. "/main.cpp")
    table.insert(compile, arg)
  end

  vim.system(compile, { text = true, cwd = dir, timeout = 120000 }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        local msg = vim.trim(res.stderr or "")
        -- Compiler noise from our generated driver is not useful to the user;
        -- surface the diagnostics that point at their own file first.
        local own = {}
        for line in msg:gmatch("[^\n]+") do
          if line:match("user%.cpp") then
            table.insert(own, (line:gsub("^.*user%.cpp:", "line ")))
          end
        end
        if #own > 0 then
          msg = "compile error\n" .. table.concat(own, "\n")
        else
          msg = "compile error\n" .. msg
        end
        return fail(cb, msg)
      end
      execute({ bin, dir }, dir, cb)
    end)
  end)
end

--- Run `code` against `cases` locally.
---@param problem_id string
---@param code string
---@param lang string
---@param meta table problem metadata (needs solutions + starterCode)
---@param cases string[] "name=value" input blocks
---@param cb fun(result: neetcode.RunResult)
function M.run(problem_id, code, lang, meta, cases, cb)
  if not M.SUPPORTED[lang] then
    return fail(cb, string.format("local runs are not supported for %s yet", lang), true)
  end
  if #cases == 0 then
    return fail(cb, "no visible test cases available for this problem", true)
  end
  local kind = meta.test_case_type or "function"
  if kind ~= "function" and kind ~= "class" then
    return fail(cb, string.format("`%s` problems can only run in the cloud", kind), true)
  end
  -- A few problems are tagged "class" but hand out plain `name=value` inputs:
  -- those are encode/decode pairs judged by round-tripping the input.
  if kind == "class" and not cases[1]:match("^%s*%[") then
    kind = "roundtrip"
  end

  if lang == "python" then
    if kind ~= "function" then
      return run_python_class(problem_id, code, meta, cases, cb, kind)
    end
    return run_python(problem_id, code, meta, cases, cb)
  end
  return run_cpp(problem_id, code, meta, cases, cb, kind)
end

return M
