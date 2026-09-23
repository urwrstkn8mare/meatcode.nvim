local config = require("meatcode.config")
local cpp = require("meatcode.runner.cpp")
local ops = require("meatcode.runner.ops")
local providers = require("meatcode.providers")
local util = require("meatcode.util")

--- Runs a solution against visible cases. Oracle precedence is stage-major:
--- reference, official editorial, popular community solution, then published
--- statement answers. Provider fallback order only breaks ties inside a stage.
--- Executable candidates are validated one at a time in the background
--- (`prepare`), sandboxed against every known answer; community code needs at
--- least one. Failures are blacklisted permanently, so a later pass only tries
--- candidates it has not seen. A run never waits for that: until a candidate
--- is selected it is judged by statement/learned answers, and cases without a
--- known answer report RAN. Your code always runs alone, unsandboxed.
local M = {}

M.SUPPORTED = { python = true, cpp = true }

--- Strongest potentially available stage. The oracle a run actually uses is
--- `selected`, once `prepare` has validated one.
---@return "reference"|"editorial"|"community"|"expected"|nil
function M.oracle(meta, lang)
  if type(meta) ~= "table" or not M.SUPPORTED[lang] then return nil end
  for _, stage in ipairs({ "reference", "editorial", "community" }) do
    local candidates = type(meta.oracle_candidates) == "table"
      and meta.oracle_candidates[stage] or nil
    if type(candidates) == "table" and #candidates > 0 then return stage end
  end
  local ref = type(meta.solutions) == "table" and meta.solutions[lang] or nil
  if type(ref) == "string" and ref ~= "" then return "reference" end
  local starter = type(meta.starterCode) == "table" and meta.starterCode[lang] or nil
  return type(starter) == "string" and starter ~= "" and "expected" or nil
end

local STAGE_LABEL = {
  reference = "reference solution",
  editorial = "official editorial",
  community = "community solution",
  expected = "statement/learned answers",
}

--- Human description of one oracle: stage, provider, and — for a community
--- post — which specific one, when that much is known.
---@param stage string
---@param provider string|nil
---@param extra {title: string|nil, votes: number|nil}|nil
local function describe(stage, provider, extra)
  if stage == "expected" or not provider then
    return STAGE_LABEL[stage] or stage
  end
  local out = STAGE_LABEL[stage] .. " from " .. providers.get(provider).label
  if extra and stage == "community" then
    if type(extra.title) == "string" and extra.title ~= "" then
      local title = extra.title
      if vim.fn.strdisplaywidth(title) > 50 then
        title = vim.fn.strcharpart(title, 0, 47) .. "…"
      end
      out = out .. ' — "' .. title .. '"'
    end
    if type(extra.votes) == "number" and extra.votes > 0 then
      out = out .. string.format(" (%d votes)", extra.votes)
    end
  end
  return out
end

--- The oracle local runs currently use: the validated selection, or known
--- answers while validation is pending or after every candidate was rejected.
---@return string|nil
function M.describe(problem_id, meta, lang)
  if not M.oracle(meta, lang) then return nil end
  local selected = M.selected(problem_id, lang, meta)
  if selected then return describe(selected.stage, selected.provider, selected) end
  if M.preparing(problem_id, lang) then
    return describe("expected") .. " (validating executable oracle candidates in the background)"
  end
  return describe("expected")
end

--- Description of the oracle a finished run actually used.
---@param result meatcode.RunResult
---@return string|nil
function M.describe_result(result)
  if not result.oracle_stage then return nil end
  local out = describe(result.oracle_stage, result.oracle_provider,
    { title = result.oracle_title, votes = result.oracle_votes })
  if result.oracle_pending then
    out = out .. " (executable oracle still validating in the background)"
  end
  return out
end

local function case_key(block)
  local parts = {}
  for _, line in ipairs(vim.split(block, "\n", { plain = true })) do
    line = vim.trim(line)
    if line ~= "" then table.insert(parts, line) end
  end
  return table.concat(parts, "\n")
end

local function learned_path(problem_id)
  return string.format("%s/known-answers/%s.json",
    config.options.cache_dir, util.slug(tostring(problem_id)))
end

--- Remember an answer exposed by a failed cloud submission.
function M.learn(problem_id, input, expected)
  if type(input) ~= "string" or vim.trim(input) == ""
    or type(expected) ~= "string" or vim.trim(expected) == "" then
    return false
  end
  local path = learned_path(problem_id)
  local known = util.read_json(path) or {}
  known[case_key(input)] = expected
  util.write_json(path, known)
  return true
end

--- Line all published and judge-learned answers up with editable local cases.
--- `meta._oracle_outputs` (from a prior sandboxed oracle run) overrides everything
--- else for the cases it covers. `meta._probe_oracle` skips learned answers so a
--- probe measuring the oracle itself is not short-circuited by a prior cache.
local function expected_values(problem_id, meta, cases)
  local published = {}
  if not meta._probe_oracle then
    for _, answer in ipairs(type(meta.oracle_answers) == "table" and meta.oracle_answers or {}) do
      if type(answer.input) == "string" and type(answer.output) == "string" then
        local key = case_key(answer.input)
        if published[key] == nil then published[key] = answer.output end
      end
    end
    -- Compatibility with provider metadata used directly by scripts.
    local sources = type(meta.custom_test_cases) == "table" and meta.custom_test_cases or {}
    for i, output in ipairs(type(meta.expected_outputs) == "table" and meta.expected_outputs or {}) do
      if sources[i] and type(output) == "string" and output ~= "" then
        local key = case_key(sources[i])
        if published[key] == nil then published[key] = output end
      end
    end
    for key, output in pairs(util.read_json(learned_path(problem_id)) or {}) do
      if type(output) == "string" and output ~= "" then published[key] = output end
    end
  end
  for key, output in pairs(type(meta._oracle_outputs) == "table" and meta._oracle_outputs or {}) do
    if type(output) == "string" and output ~= "" then published[key] = output end
  end
  local out = {}
  for i, case in ipairs(cases) do out[i] = published[case_key(case)] or vim.NIL end
  return out
end

local function expected_json(problem_id, meta, cases)
  return ops.encode(expected_values(problem_id, meta, cases))
end

local function harness_dir()
  local this = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fn.fnamemodify(this, ":p")) .. "/harness"
end

--- Scratch directory for one run. `scope` separates background oracle work
--- ("oracle"), foreground oracle outputs ("probe") and your own runs (nil),
--- which may execute concurrently.
local function workdir(problem_id, lang, scope)
  local dir = string.format("%s/run/%s-%s%s", config.options.cache_dir, problem_id, lang,
    scope and ("-" .. scope) or "")
  util.mkdirp(dir)
  return dir
end

--- Remove preprocessor includes so user code can be pulled into a namespace.
local function strip_includes(src)
  return (src:gsub("#include%s*[<\"][^>\"]*[>\"]", ""))
end

---@class meatcode.RunResult
---@field ok boolean
---@field cases table[]
---@field error string|nil
---@field method string|nil
---@field passed integer
---@field total integer

local function summarize(report)
  if report.unsupported then
    report.error = (report.error or "unsupported")
      .. " — use " .. config.options.keys.problem.submit .. " to run this one in the cloud"
  end
  local passed, judged, unjudged = 0, 0, 0
  for _, c in ipairs(report.cases or {}) do
    if c.status == "no_oracle" then
      -- Ran fine, but nothing published an answer for this input, so it is not
      -- counted for or against the run.
      unjudged = unjudged + 1
    else
      judged = judged + 1
      if c.status == "pass" or c.status == "pass_unordered" then
        passed = passed + 1
      end
    end
  end
  report.passed = passed
  report.total = judged
  report.unjudged = unjudged
  return report
end

--- `unsupported` marks a problem we cannot faithfully reproduce locally, as
--- opposed to something going wrong; the results panel presents the two differently.
local function fail(cb, msg, unsupported)
  cb(summarize({ ok = false, error = msg, cases = {}, unsupported = unsupported }))
end

--- Read a bundled harness file (python.py, cpp_runtime.h, cpp_stdlib.h).
--- A nil here means a broken/partial install (e.g. a sparse checkout that
--- dropped `runner/harness/`), not a normal failure mode; surface it as a
--- clear error instead of letting `util.write_file` crash on a nil body.
local function read_harness(cb, name)
  local content = util.read_file(harness_dir() .. "/" .. name)
  if not content then
    fail(cb, "missing runner harness file '" .. name .. "' -- reinstall meatcode.nvim")
    return nil
  end
  return content
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

--- Describe crash signals that commonly indicate an error in a C++ solution.
---@param signal integer
---@return string|nil
local function crash_diagnostic(signal)
  local diagnostics = {
    [4] = "SIGILL: illegal instruction",
    [6] = "SIGABRT: abort",
    [8] = "SIGFPE: arithmetic exception",
    [11] = "SIGSEGV: segmentation fault — invalid memory access",
  }
  diagnostics[vim.uv.os_uname().sysname == "Darwin" and 10 or 7] =
    "SIGBUS: bus error — invalid or misaligned memory access"
  return diagnostics[signal]
end

--- Format a terminated process result for the local-run results panel.
---@param res vim.SystemCompleted
---@return string
local function process_failure(res)
  if res.code == 124 or res.signal == 15 or res.signal == 9 then
    return "timed out — possible infinite loop"
  end
  if res.signal and res.signal ~= 0 then
    local diagnostic = crash_diagnostic(res.signal)
    if diagnostic then
      return string.format("crashed with signal %d (%s)", res.signal, diagnostic)
    end
    return string.format("crashed with signal %d", res.signal)
  end

  local msg = (res.stderr or ""):gsub("CASE %d+\n", "")
  msg = vim.trim(msg)
  if msg == "" then
    return "the harness produced no output (exit code " .. tostring(res.code) .. ")"
  end
  return msg
end

--- Re-run a crashed C++ harness under LLDB to recover a symbolic backtrace.
---@param cmd string[]
---@param dir string
---@param timeout_ms integer
---@param cb fun(backtrace: string|nil)
local function debugger_backtrace(cmd, dir, timeout_ms, cb)
  if vim.fn.executable("lldb") ~= 1 then
    return cb(nil)
  end

  local debugger = {
    "lldb", "--batch", "--no-lldbinit", "--no-use-colors",
    "--one-line", "run",
    "--one-line-on-crash", "thread backtrace",
    "--",
  }
  for _, arg in ipairs(cmd) do
    table.insert(debugger, arg)
  end

  vim.system(debugger, { text = true, cwd = dir, timeout = timeout_ms }, function(res)
    vim.schedule(function()
      local output = vim.trim((res.stdout or "") .. "\n" .. (res.stderr or ""))
      local marker = output:find("(lldb) thread backtrace", 1, true)
      if marker then
        output = vim.trim(output:sub(marker + #"(lldb) thread backtrace"))
      end
      cb(output:find("frame #", 1, true) and output or nil)
    end)
  end)
end

--- Complete a failed run, including an LLDB backtrace for a C++ crash.
---@param res vim.SystemCompleted
---@param cmd string[]
---@param dir string
---@param timeout_ms integer
---@param debug_crash boolean|nil
---@param cb fun(result: meatcode.RunResult)
local function finish_failure(res, cmd, dir, timeout_ms, debug_crash, cb)
  local last = nil
  for idx in (res.stderr or ""):gmatch("CASE (%d+)") do
    last = tonumber(idx)
  end

  local msg = process_failure(res)
  if last then
    msg = string.format("test case %d: %s", last + 1, msg)
  end

  if not debug_crash or not res.signal or res.signal == 0 or res.signal == 15 or res.signal == 9 then
    return cb(summarize({ ok = false, error = msg, cases = {} }))
  end
  debugger_backtrace(cmd, dir, timeout_ms, function(backtrace)
    if backtrace then
      msg = msg .. "\n\nbacktrace:\n" .. backtrace
    end
    cb(summarize({ ok = false, error = msg, cases = {} }))
  end)
end



--- Linux: bubblewrap runs each candidate in fresh user, PID, network, IPC and
--- mount namespaces. `/usr` and the dynamic-loader cache are exposed read-only,
--- `/dev`, `/proc` and a tmpfs `/tmp` are virtual, and only the scratch
--- directory is writable.
local function linux_sandbox_command(cmd, dir)
  if vim.fn.executable("bwrap") ~= 1 then
    return nil, "bubblewrap (`bwrap`) is required to run provider-supplied code safely"
  end
  local wrapped = {
    "bwrap", "--unshare-all", "--die-with-parent", "--new-session",
    "--cap-drop", "ALL", "--clearenv",
    "--setenv", "PATH", "/usr/bin:/bin",
    "--setenv", "HOME", "/nonexistent",
    "--setenv", "LANG", "C.UTF-8",
    "--setenv", "TMPDIR", "/tmp",
    "--ro-bind", "/usr", "/usr",
    "--symlink", "usr/bin", "/bin",
    "--symlink", "usr/lib", "/lib",
    "--symlink", "usr/lib", "/lib64",
    "--dir", "/etc",
    "--ro-bind", "/etc/ld.so.cache", "/etc/ld.so.cache",
    "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
    "--dir", "/nonexistent",
    "--bind", dir, "/work", "--chdir", "/work", "--",
  }
  for _, arg in ipairs(cmd) do
    if arg == dir then
      arg = "/work"
    elseif arg:sub(1, #dir + 1) == dir .. "/" then
      arg = "/work/" .. arg:sub(#dir + 2)
    end
    table.insert(wrapped, arg)
  end
  return wrapped, true
end

--- macOS: `sandbox-exec` applies a Seatbelt profile that denies the network,
--- the home directory and external volumes, clears the environment, and makes
--- only the scratch directory readable and writable. There is no PID namespace
--- on macOS, so the process table stays visible; otherwise the scope matches
--- Linux. Paths need no rewriting because the process keeps the host layout.
local function macos_sandbox_command(cmd, dir)
  if vim.fn.executable("sandbox-exec") ~= 1 then
    return nil, "`sandbox-exec` is required to run provider-supplied code safely on macOS"
  end
  local home = vim.uv.os_homedir() or "/nonexistent"
  local wrapped = {
    "sandbox-exec",
    "-D", "WORK_DIR=" .. dir,
    "-D", "HOME_DIR=" .. home,
    "-f", harness_dir() .. "/sandbox.sb", "--",
    "/usr/bin/env", "-i",
    "PATH=/usr/bin:/bin",
    "HOME=/nonexistent",
    "TMPDIR=/tmp",
    "LANG=C.UTF-8",
  }
  for _, arg in ipairs(cmd) do
    table.insert(wrapped, arg)
  end
  return wrapped, true
end

--- Isolate provider-supplied code from the network, home directory, process
--- table and host filesystem. Only the per-run scratch directory is writable.
--- The user may opt out explicitly; otherwise a missing sandbox fails closed.
local function sandbox_command(cmd, dir, required)
  if not required or config.options.runner.sandbox == false then return cmd, false end
  if vim.fn.has("mac") == 1 then
    return macos_sandbox_command(cmd, dir)
  end
  return linux_sandbox_command(cmd, dir)
end

local function parallelism(case_count)
  local configured = config.options.runner.parallelism
  if configured == false then return 1 end
  configured = tonumber(configured) or 0
  local ceiling = configured > 0 and configured or vim.uv.available_parallelism()
  return math.max(1, math.min(case_count, ceiling))
end

function M.parallelism(case_count)
  return parallelism(case_count)
end

--- Run independent case shards concurrently, then restore stable case order.
local function execute(cmd, dir, case_count, cb, debug_crash, untrusted)
  local timeout_ms = (config.options.runner.time_limit or 10) * 1000
  local shards = parallelism(case_count)
  local commands = {}
  for shard = 0, shards - 1 do
    local shard_cmd = vim.deepcopy(cmd)
    if shards > 1 then
      table.insert(shard_cmd, tostring(shard))
      table.insert(shard_cmd, tostring(shards))
    end
    local isolated, sandboxed_or_err = sandbox_command(shard_cmd, dir, untrusted)
    if not isolated then return fail(cb, sandboxed_or_err, true) end
    table.insert(commands, { cmd = isolated, sandboxed = sandboxed_or_err })
  end

  local pending, reports, failure = #commands, {}, nil
  for _, command in ipairs(commands) do
    vim.system(command.cmd, { text = true, cwd = dir, timeout = timeout_ms * 6 }, function(res)
      vim.schedule(function()
        local report = decode_report(res.stdout or "")
        if report then
          table.insert(reports, report)
        elseif not failure then
          failure = { res = res, cmd = command.cmd, sandboxed = command.sandboxed }
        end
        pending = pending - 1
        if pending > 0 then return end
        if failure then
          return finish_failure(failure.res, failure.cmd, dir, timeout_ms,
            debug_crash and shards == 1 and not failure.sandboxed, cb)
        end

        local merged = { ok = true, cases = {}, parallelism = shards }
        for _, report_part in ipairs(reports) do
          vim.list_extend(merged.cases, report_part.cases or {})
          merged.method = merged.method or report_part.method
          if report_part.ok == false then
            merged.ok = false
            merged.unsupported = merged.unsupported or report_part.unsupported
            merged.error = merged.error or report_part.error
          end
        end
        table.sort(merged.cases, function(a, b)
          return (a.index or 0) < (b.index or 0)
        end)
        cb(summarize(merged))
      end)
    end)
  end
end

--- The source the harness reads the signature from: the reference solution when
--- there is one, otherwise the starter code, which declares the same method.
local function signature_source(meta, lang, oracle)
  if oracle == "reference" then
    return meta._oracle_code or (meta.solutions and meta.solutions[lang])
  end
  return meta.starterCode and meta.starterCode[lang] or nil
end

--- Parameter types LeetCode declares in `metaData`, as a JSON array.
---
--- Starter code usually annotates its own parameters, but the encode/decode
--- starters do not, and an unannotated `root` would reach the solution as a
--- plain list instead of a tree. `metaData` names the type in that case.
local function declared_types(meta)
  local decoded = type(meta.meta_data) == "string"
    and select(2, pcall(vim.json.decode, meta.meta_data)) or nil
  local types = {}
  for _, param in ipairs(type(decoded) == "table" and decoded.params or {}) do
    table.insert(types, type(param.type) == "string" and param.type or vim.NIL)
  end
  return ops.encode(types)
end

local function run_python(problem_id, code, meta, cases, cb, oracle)
  local dir = workdir(problem_id, "python", meta._scope)
  local ref = signature_source(meta, "python", oracle)
  if not ref or ref == "" then
    return fail(cb, "no Python starter code to derive the signature from", true)
  end
  local harness = read_harness(cb, "python.py")
  if not harness then return end

  util.write_file(dir .. "/user.py", code)
  util.write_file(dir .. "/ref.py", ref)
  util.write_file(dir .. "/harness.py", harness)
  util.write_json(dir .. "/cases.json", cases)
  util.write_file(dir .. "/types.json", declared_types(meta))
  util.write_file(dir .. "/expected.json", expected_json(problem_id, meta, cases))

  local py = vim.deepcopy(config.options.runner.python.cmd)
  table.insert(py, dir .. "/harness.py")
  table.insert(py, dir)
  table.insert(py, "function")
  table.insert(py, oracle)
  execute(py, dir, #cases, cb, false, meta._untrusted_user or oracle == "reference")
end

--- Design problems: normalise the call sequence, then replay it in the harness.
--- `mode` is "class" for an operation sequence, "roundtrip" for encode/decode.
local function run_python_class(problem_id, code, meta, cases, cb, mode, oracle)
  local dir = workdir(problem_id, "python", meta._scope)
  local ref = signature_source(meta, "python", oracle)
  if not ref or ref == "" then
    return fail(cb, "no Python starter code to derive the signature from", true)
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

  local harness = read_harness(cb, "python.py")
  if not harness then return end

  util.write_file(dir .. "/user.py", code)
  util.write_file(dir .. "/ref.py", ref)
  util.write_file(dir .. "/harness.py", harness)
  util.write_json(dir .. "/cases.json", cases)
  util.write_file(dir .. "/types.json", declared_types(meta))
  util.write_file(dir .. "/expected.json", expected_json(problem_id, meta, cases))

  local py = vim.deepcopy(config.options.runner.python.cmd)
  table.insert(py, dir .. "/harness.py")
  table.insert(py, dir)
  table.insert(py, mode)
  table.insert(py, oracle)
  execute(py, dir, #cases, cb, false, meta._untrusted_user or oracle == "reference")
end

local function run_cpp(problem_id, code, meta, cases, cb, mode, oracle)
  local dir = workdir(problem_id, "cpp", meta._scope)
  local starter = meta.starterCode and meta.starterCode.cpp
  if not starter or starter == "" then
    return fail(cb, "no C++ starter code to derive the signature from", true)
  end
  local ref = oracle == "reference"
    and (meta._oracle_code or (meta.solutions and meta.solutions.cpp)) or nil

  local main_src, gen_err
  if mode == "roundtrip" then
    main_src, gen_err = cpp.generate_roundtrip(starter, oracle)
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
    main_src, gen_err = cpp.generate_class(starter, oracle)
  else
    main_src, gen_err = cpp.generate(starter, oracle)
  end
  if not main_src then
    return fail(cb, gen_err, true)
  end
  local runtime = read_harness(cb, "cpp_runtime.h")
  if not runtime then return end
  local stdlib = read_harness(cb, "cpp_stdlib.h")
  if not stdlib then return end

  util.write_file(dir .. "/user.cpp", strip_includes(code))
  util.write_file(dir .. "/ref.cpp", ref and strip_includes(ref) or "")
  util.write_file(dir .. "/main.cpp", main_src)
  util.write_json(dir .. "/cases.json", cases)
  util.write_file(dir .. "/expected.json", expected_json(problem_id, meta, cases))

  util.write_file(dir .. "/cpp_runtime.h", runtime)
  util.write_file(dir .. "/cpp_stdlib.h", stdlib)

  local bin = dir .. "/run"
  local compile = {}
  for _, arg in ipairs(config.options.runner.cpp.cmd) do
    arg = arg:gsub("{out}", bin):gsub("{source}", dir .. "/main.cpp")
    table.insert(compile, arg)
  end

  local untrusted = meta._untrusted_user or oracle == "reference"
  local compile_cmd, sandbox_err = sandbox_command(compile, dir, untrusted)
  if not compile_cmd then return fail(cb, sandbox_err, true) end
  vim.system(compile_cmd, { text = true, cwd = dir, timeout = 120000 }, function(res)
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
      execute({ bin, dir }, dir, #cases, cb, true, untrusted)
    end)
  end)
end

local function run_selected(problem_id, code, lang, meta, cases, cb, oracle)
  local kind = meta.test_case_type or "function"
  if kind ~= "function" and kind ~= "class" then
    return fail(cb, string.format("`%s` problems can only run in the cloud", kind), true)
  end
  if kind == "class" and not cases[1]:match('^%s*%[%s*"') then kind = "roundtrip" end
  if lang == "python" then
    if kind ~= "function" then
      return run_python_class(problem_id, code, meta, cases, cb, kind, oracle)
    end
    return run_python(problem_id, code, meta, cases, cb, oracle)
  end
  return run_cpp(problem_id, code, meta, cases, cb, kind, oracle)
end

--- Executable candidates in precedence order: stage-major, then provider
--- order, then popularity (the order providers list them in).
local function source_candidates(meta, lang)
  local out = {}
  for _, stage in ipairs({ "reference", "editorial", "community" }) do
    for _, candidate in ipairs(type(meta.oracle_candidates) == "table"
      and type(meta.oracle_candidates[stage]) == "table"
      and meta.oracle_candidates[stage] or {}) do
      if type(candidate.code) == "string" and candidate.code ~= "" then
        table.insert(out, vim.tbl_extend("force", {}, candidate,
          { stage = stage, code_hash = vim.fn.sha256(candidate.code) }))
      end
    end
  end
  if #out == 0 then
    local code = type(meta.solutions) == "table" and meta.solutions[lang] or nil
    if type(code) == "string" and code ~= "" then
      table.insert(out, { stage = "reference", provider = "neetcode", code = code,
        code_hash = vim.fn.sha256(code) })
    end
  end
  return out
end

--- Every input with a known answer: the provider's visible examples that
--- carry a published answer, plus inputs a failed submission disclosed.
--- Independent of the editable suite, so editing cases never invalidates a
--- selection. Returns the cases, their fingerprint, and the visible examples
--- (what a reference/editorial is smoke-run on when nothing is known).
local function validation_set(problem_id, meta)
  local defaults = type(meta.custom_test_cases) == "table" and meta.custom_test_cases or {}
  local inputs, seen = {}, {}
  for _, case in ipairs(defaults) do
    local key = type(case) == "string" and case_key(case) or ""
    if key ~= "" and not seen[key] then
      seen[key] = true
      table.insert(inputs, case)
    end
  end
  for key in pairs(util.read_json(learned_path(problem_id)) or {}) do
    if type(key) == "string" and key ~= "" and not seen[key] then
      seen[key] = true
      table.insert(inputs, key)
    end
  end
  local known, parts = {}, {}
  for i, value in ipairs(expected_values(problem_id, meta, inputs)) do
    if value ~= vim.NIL then
      table.insert(known, inputs[i])
      table.insert(parts, case_key(inputs[i]) .. "\0" .. tostring(value))
    end
  end
  table.sort(parts)
  return known, vim.fn.sha256(table.concat(parts, "\1")), defaults
end

--- Selection and blacklist for one problem/language:
--- `selection` is the candidate that passed against the fingerprint
--- `validation_key`; `rejected` maps code hashes of candidates that failed
--- known answers (or did not compile/run) to why. Known answers only grow, so
--- a rejection is permanent: later passes go straight to untried candidates.
local function state_path(problem_id, lang)
  return string.format("%s/oracle-validations/%s-%s.json",
    config.options.cache_dir, util.slug(tostring(problem_id)), lang)
end

local function load_state(problem_id, lang)
  local raw = util.read_json(state_path(problem_id, lang))
  raw = type(raw) == "table" and raw or {}
  return {
    selection = type(raw.selection) == "table" and raw.selection or nil,
    rejected = type(raw.rejected) == "table" and raw.rejected or {},
  }
end

local function save_state(problem_id, lang, state)
  util.write_json(state_path(problem_id, lang), {
    selection = state.selection,
    rejected = next(state.rejected) and state.rejected or vim.empty_dict(),
  })
end

local function is_selection(selection, candidate, validation_key)
  return type(selection) == "table"
    and selection.code_hash == candidate.code_hash
    and selection.stage == candidate.stage
    and selection.provider == candidate.provider
    and selection.validation_key == validation_key
end

--- Per-case outputs from the selected executable oracle. Kept separate from
--- user runs so provider code only executes when a case is new or the oracle
--- itself changed.
local function oracle_outputs_path(problem_id, lang)
  return string.format("%s/oracle-outputs/%s-%s.json",
    config.options.cache_dir, util.slug(tostring(problem_id)), lang)
end

local function load_oracle_cache(problem_id, lang, candidate)
  local cached = util.read_json(oracle_outputs_path(problem_id, lang))
  if type(cached) ~= "table"
    or cached.code_hash ~= candidate.code_hash
    or cached.stage ~= candidate.stage
    or cached.provider ~= candidate.provider then
    return {}
  end
  return type(cached.outputs) == "table" and cached.outputs or {}
end

--- Merge fresh outputs into the on-disk cache. Background preparation and a
--- foreground run may both add outputs, so re-read rather than overwrite.
local function persist_oracle_outputs(problem_id, lang, candidate, fresh)
  local outputs = load_oracle_cache(problem_id, lang, candidate)
  for key, value in pairs(fresh) do outputs[key] = value end
  util.write_json(oracle_outputs_path(problem_id, lang), {
    stage = candidate.stage,
    provider = candidate.provider,
    id = candidate.id,
    code_hash = candidate.code_hash,
    outputs = next(outputs) and outputs or vim.empty_dict(),
  })
  return outputs
end

--- Actuals from a sandboxed oracle run, keyed by case.
local function oracle_actuals(report)
  local outputs, errors = {}, {}
  for _, c in ipairs(type(report) == "table" and report.cases or {}) do
    if c.status == "error" or c.status == "oracle_error" then
      table.insert(errors, (type(c.error) == "string" and c.error:match("^[^\n]+")) or c.status)
    elseif type(c.input) == "string" and type(c.actual) == "string" then
      outputs[case_key(c.input)] = c.actual
    end
  end
  return outputs, errors
end

--- Ensure every case has an oracle output, sandboxing the selected provider
--- solution only for inputs that are still missing (typically cases the user
--- just added). `scope` keeps concurrent oracle runs out of each other's
--- scratch directory.
local function ensure_oracle_outputs(problem_id, lang, meta, candidate, cases, cb, status, scope)
  local outputs = load_oracle_cache(problem_id, lang, candidate)
  local missing, cached_n = {}, 0
  for _, case in ipairs(cases) do
    local out = outputs[case_key(case)]
    if type(out) == "string" and out ~= "" then
      cached_n = cached_n + 1
    else
      table.insert(missing, case)
    end
  end

  if #missing == 0 then
    return cb(nil, outputs)
  end

  if status then
    status(string.format(
      "Computing oracle outputs for %d new case%s (%d cached)",
      #missing, #missing == 1 and "" or "s", cached_n))
  end

  local trial_meta = vim.tbl_extend("force", {}, meta, {
    _untrusted_user = true,
    _probe_oracle = true,
    _scope = scope,
    oracle_answers = {},
  })
  trial_meta.expected_outputs = nil
  trial_meta.custom_test_cases = nil
  trial_meta._oracle_outputs = nil

  run_selected(problem_id, candidate.code, lang, trial_meta, missing, function(report)
    if report.unsupported then
      return cb(report.error or "oracle unsupported", nil)
    end
    if report.error and #(report.cases or {}) == 0 then
      return cb(report.error, nil)
    end
    local fresh, errors = oracle_actuals(report)
    if #errors > 0 then
      return cb("oracle failed on a case: " .. errors[1], nil)
    end
    for _, case in ipairs(missing) do
      local out = fresh[case_key(case)]
      if type(out) ~= "string" or out == "" then
        return cb("oracle produced no output for a case", nil)
      end
    end
    cb(nil, persist_oracle_outputs(problem_id, lang, candidate, fresh))
  end, "expected")
end

--- The executable oracle validated against the current known answers, or nil
--- when none has been (yet). Synchronous: never executes anything.
---@return table|nil candidate
function M.selected(problem_id, lang, meta)
  local state = load_state(problem_id, lang)
  if not state.selection then return nil end
  local _, validation_key = validation_set(problem_id, meta)
  for _, candidate in ipairs(source_candidates(meta, lang)) do
    if is_selection(state.selection, candidate, validation_key)
      and not state.rejected[candidate.code_hash] then
      return candidate
    end
  end
  return nil
end

--- Walk candidates in precedence order, one at a time. Blacklisted ones are
--- skipped; the saved selection is accepted without re-running when the known
--- answers are unchanged; anything else is sandboxed against the known answers
--- and either selected or blacklisted. A stronger candidate that appeared
--- since the last pass is therefore tried before the saved selection.
---@param cb fun(candidate: table|nil, rejected: table[], err: string|nil)
local function select_oracle(problem_id, lang, meta, cb, status)
  local candidates = source_candidates(meta, lang)
  local known, validation_key, defaults = validation_set(problem_id, meta)
  local state = load_state(problem_id, lang)
  local index, rejected = 0, {}

  local function step()
    index = index + 1
    local candidate = candidates[index]
    if not candidate then
      if state.selection then
        state.selection = nil
        save_state(problem_id, lang, state)
      end
      return cb(nil, rejected)
    end
    if state.rejected[candidate.code_hash] then return step() end
    -- Popularity alone never makes community code an oracle.
    if candidate.stage == "community" and #known == 0 then return step() end
    if is_selection(state.selection, candidate, validation_key) then
      return cb(candidate, rejected)
    end
    local trial_cases = #known > 0 and known or defaults
    if #trial_cases == 0 then return step() end

    if status then
      local workers = parallelism(#trial_cases)
      status(string.format("Validating %s %s candidate %d/%d · %d worker%s",
        candidate.provider or "local", candidate.stage, index, #candidates,
        workers, workers == 1 and "" or "s"))
    end
    local trial_meta = vim.tbl_extend("force", {}, meta, {
      _oracle_code = candidate.code,
      _untrusted_user = true,
      _scope = "oracle",
    })
    run_selected(problem_id, candidate.code, lang, trial_meta, trial_cases, function(report)
      if report.ok and report.total > 0 and report.passed == report.total then
        state.selection = {
          stage = candidate.stage,
          provider = candidate.provider,
          id = candidate.id,
          code_hash = candidate.code_hash,
          validation_key = validation_key,
        }
        save_state(problem_id, lang, state)
        -- The pass that proved the candidate also seeds its per-case outputs.
        persist_oracle_outputs(problem_id, lang, candidate, (oracle_actuals(report)))
        return cb(candidate, rejected)
      end
      if report.unsupported then
        -- Not this candidate's fault (no sandbox, or the problem cannot run
        -- locally at all): every other candidate would fail the same way.
        return cb(nil, rejected, report.error)
      end
      -- The last line carries the point of a traceback/compiler dump.
      local reason = (report.error or "failed known cases"):match("([^\n]+)%s*$")
        or "failed known cases"
      state.rejected[candidate.code_hash] = {
        stage = candidate.stage, provider = candidate.provider,
        id = candidate.id, reason = reason,
      }
      save_state(problem_id, lang, state)
      table.insert(rejected, candidate)
      if status then status(reason .. " — trying next candidate") end
      step()
    end, #known > 0 and "expected" or "reference")
  end
  step()
end

---@type table<string, {waiters: function[], again: table|nil}>
local jobs = {}

local function job_key(problem_id, lang)
  return tostring(problem_id) .. "\0" .. lang
end

--- Whether a background preparation is in flight for this problem/language.
function M.preparing(problem_id, lang)
  return jobs[job_key(problem_id, lang)] ~= nil
end

--- Select (or confirm) the executable oracle in the background and precompute
--- its outputs for `cases`, so a later run never waits on provider code.
--- Single-flight per problem/language: a call while one is in flight queues
--- exactly one more pass with the latest arguments (e.g. new candidates from
--- another provider, or a newly learned answer), and every caller's `cb`
--- receives the outcome of the final pass.
---@param cb fun(info: {stage: string, provider: string|nil, id: any, title: string|nil, votes: number|nil, rejected: integer, error: string|nil})|nil
function M.prepare(problem_id, lang, meta, cases, cb, status)
  local key = job_key(problem_id, lang)
  local job = jobs[key]
  if job then
    job.again = { meta = meta, cases = cases, status = status }
    if cb then table.insert(job.waiters, cb) end
    return
  end
  job = { waiters = cb and { cb } or {} }
  jobs[key] = job
  local rejected_total = 0

  local function pass(pass_meta, pass_cases, pass_status)
    select_oracle(problem_id, lang, pass_meta, function(candidate, rejected, err)
      rejected_total = rejected_total + #rejected
      local function done(output_err)
        if job.again then
          local nxt = job.again
          job.again = nil
          return pass(nxt.meta, nxt.cases, nxt.status)
        end
        jobs[key] = nil
        local info = {
          stage = candidate and candidate.stage or "expected",
          provider = candidate and candidate.provider or nil,
          id = candidate and candidate.id or nil,
          title = candidate and candidate.title or nil,
          votes = candidate and candidate.votes or nil,
          rejected = rejected_total,
          error = err or output_err,
        }
        for _, waiter in ipairs(job.waiters) do waiter(info) end
      end
      if not candidate or type(pass_cases) ~= "table" or #pass_cases == 0 then
        return done()
      end
      ensure_oracle_outputs(problem_id, lang, pass_meta, candidate, pass_cases,
        function(output_err) done(output_err) end, pass_status, "oracle")
    end, pass_status)
  end
  pass(meta, cases, status)
end

--- Run `code` against `cases` locally.
---
--- Uses the executable oracle `prepare` already validated; outputs for cases
--- it has not seen yet are computed (sandboxed) first. Until one is
--- validated, the run is judged by statement/learned answers alone and never
--- waits on validation. Your solution always runs alone, unsandboxed.
function M.run(problem_id, code, lang, meta, cases, cb, status)
  if not M.SUPPORTED[lang] then
    return fail(cb, string.format("local runs are not supported for %s yet", lang), true)
  end
  if #cases == 0 then
    return fail(cb, "no visible test cases available for this problem", true)
  end
  if not M.oracle(meta, lang) then
    return fail(cb, "no starter code is available for a local run", true)
  end

  local candidate = M.selected(problem_id, lang, meta)
  local pending = not candidate and M.preparing(problem_id, lang)

  local function run_user(outputs)
    local selected = vim.tbl_extend("force", {}, meta, { _oracle_outputs = outputs })
    selected._oracle_code = nil
    local workers = parallelism(#cases)
    if status then
      status(string.format("Running with %s · %d worker%s",
        candidate and string.format("%s %s oracle", candidate.provider, candidate.stage)
          or pending and "statement/learned answers (oracle still validating)"
          or "statement/learned answers",
        workers, workers == 1 and "" or "s"))
    end
    run_selected(problem_id, code, lang, selected, cases, function(report)
      report.oracle_stage = candidate and candidate.stage or "expected"
      report.oracle_provider = candidate and candidate.provider or nil
      report.oracle_id = candidate and candidate.id or nil
      report.oracle_title = candidate and candidate.title or nil
      report.oracle_votes = candidate and candidate.votes or nil
      report.oracle_pending = pending or nil
      cb(report)
    end, "expected")
  end

  if not candidate then
    return run_user(nil)
  end
  ensure_oracle_outputs(problem_id, lang, meta, candidate, cases, function(err, outputs)
    if err then
      return fail(cb, err)
    end
    run_user(outputs)
  end, status, "probe")
end

return M
