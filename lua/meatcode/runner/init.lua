local answers = require("meatcode.runner.answers")
local config = require("meatcode.config")
local cpp = require("meatcode.runner.cpp")
local crash = require("meatcode.runner.crash")
local ops = require("meatcode.runner.ops")
local providers = require("meatcode.providers")
local util = require("meatcode.util")

--- Runs a solution against the local suite. Oracle precedence is stage-major:
--- an openleetcode checker, then reference, official editorial and popular
--- community solutions, then the cloud — the submit provider's own test run.
--- Provider fallback order only breaks ties inside a stage.
---
--- Local candidates are validated one at a time in the background (`prepare`),
--- sandboxed against every known answer; community code needs at least one.
--- Failures are blacklisted permanently, so a later pass only tries candidates
--- it has not seen. A run never waits for that: until a candidate is selected
--- it uses the cloud oracle.
---
--- Every oracle feeds one answer cache (`runner.answers`). The cloud oracle is
--- always cautious: its test run starts alongside your local run and is
--- cancelled when every output matches a cached answer; otherwise the judge's
--- verdict decides the cases that did not match. Your code always runs alone,
--- unsandboxed; provider code and checkers only ever run sandboxed.
local M = {}

M.SUPPORTED = { python = true, cpp = true }

local EXECUTABLE_STAGES = { "reference", "editorial", "community" }

---@class meatcode.CloudCase
---@field expected string|nil the judge's own answer
---@field actual string|nil your output as the judge ran it
---@field correct boolean|nil the judge's verdict on that output
---@field stdout string|nil
---@field error string|nil why the judge has no verdict for the case

---@class meatcode.CloudOracle
---@field provider string submit provider name
---@field test fun(code: string, cases: string[], cb: fun(err: string|nil, results: meatcode.CloudCase[]|nil)): fun()

-- ------------------------------------------------------------ cloud setting

--- When the cloud oracle judges even though a local oracle is available:
--- "complex" for problems NeetCode marks as having no single exact output
--- (unless an openleetcode checker covers them), "always", or "never".
M.CLOUD_MODES = { "complex", "always", "never" }

local cloud_mode_choice = nil

local function cloud_mode_path()
  return config.options.cache_dir .. "/cloud-oracle.json"
end

---@return "complex"|"always"|"never"
function M.cloud_mode()
  if not cloud_mode_choice then
    local saved = util.read_json(cloud_mode_path())
    local mode = type(saved) == "table" and saved.force or nil
    cloud_mode_choice = vim.tbl_contains(M.CLOUD_MODES, mode) and mode or "complex"
  end
  return cloud_mode_choice
end

--- Persist the cloud-oracle setting for every problem.
function M.set_cloud_mode(mode)
  if vim.tbl_contains(M.CLOUD_MODES, mode) then
    cloud_mode_choice = mode
    util.write_json(cloud_mode_path(), { force = mode })
  end
  return M.cloud_mode()
end

--- Whether runs use the cloud oracle even with `selected` available.
function M.forces_cloud(meta, selected)
  local mode = M.cloud_mode()
  if mode == "always" then return true end
  if mode == "never" then return false end
  return type(meta) == "table" and meta.complexTestCases == true
    and not (selected and selected.stage == "checker")
end

-- ------------------------------------------------------------ stages

local function checker_applies(meta, lang)
  return type(meta.checker) == "table" and M.SUPPORTED[lang] == true
    and (meta.test_case_type or "function") == "function"
    and tostring(meta.checker.judge):lower() ~= "exact"
end

--- Strongest potentially available stage. The oracle a run actually uses is
--- `selected`, once `prepare` has validated one; "cloud" is always last.
---@return "checker"|"reference"|"editorial"|"community"|"cloud"|nil
function M.oracle(meta, lang)
  if type(meta) ~= "table" then return nil end
  if checker_applies(meta, lang) then return "checker" end
  if M.SUPPORTED[lang] then
    for _, stage in ipairs(EXECUTABLE_STAGES) do
      local candidates = type(meta.oracle_candidates) == "table"
        and meta.oracle_candidates[stage] or nil
      if type(candidates) == "table" and #candidates > 0 then return stage end
    end
    local ref = type(meta.solutions) == "table" and meta.solutions[lang] or nil
    if type(ref) == "string" and ref ~= "" then return "reference" end
  end
  return "cloud"
end

local STAGE_LABEL = {
  checker = "openleetcode checker",
  reference = "reference solution",
  editorial = "official editorial",
  community = "community solution",
  cloud = "judge test run",
  answers = "known answers",
}

--- Human description of one oracle: stage, provider, and — for a community
--- post — which specific one, when that much is known.
---@param stage string
---@param provider string|nil
---@param extra {title: string|nil, votes: number|nil}|nil
local function describe(stage, provider, extra)
  if stage == "cloud" and provider then
    return providers.get(provider).label .. " test run"
  end
  if stage == "checker" or stage == "answers" or not provider or not providers.known(provider) then
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

--- The oracle local runs currently use. `cloud_provider` is the judge whose
--- test run is available, if any.
---@return string|nil
function M.describe(problem_id, meta, lang, cloud_provider)
  if not M.oracle(meta, lang) then return nil end
  local selected = M.selected(problem_id, lang, meta)
  local cloud = cloud_provider and describe("cloud", cloud_provider) .. ", cached answers first" or nil
  if cloud and M.forces_cloud(meta, selected) then
    return cloud .. (M.cloud_mode() == "always" and " (forced for every problem)"
      or " (NeetCode marks this problem's output as not exactly comparable)")
  end
  if selected then return describe(selected.stage, selected.provider, selected) end
  local fallback = cloud or describe("answers")
  if M.preparing(problem_id, lang) then
    return fallback .. " (validating local oracle candidates in the background)"
  end
  return fallback
end

--- Description of the oracle a finished run actually used.
---@param result meatcode.RunResult
---@return string|nil
function M.describe_result(result)
  if not result.oracle_stage then return nil end
  local out = describe(result.oracle_stage, result.oracle_provider,
    { title = result.oracle_title, votes = result.oracle_votes })
  if result.oracle_pending then
    out = out .. " (local oracle still validating in the background)"
  end
  return out
end

--- Remember an answer exposed by a failed submission to `provider`.
---@return boolean learned whether it was new
function M.learn(problem_id, input, expected, provider)
  if type(input) ~= "string" or vim.trim(input) == ""
    or type(expected) ~= "string" or vim.trim(expected) == "" then
    return false
  end
  return answers.add(problem_id, {
    { input = input, output = expected, source = "judge:" .. tostring(provider or "judge") },
  }) > 0
end

--- The answer-cache source a candidate's outputs are stored under.
local function source_of(candidate)
  return (candidate.stage == "checker" and "checker:" or "oracle:") .. candidate.code_hash
end

--- Answer sources to trust besides the ground truth: the selected candidate's.
local function trusted(candidate)
  return candidate and { [source_of(candidate)] = true } or nil
end

-- ------------------------------------------------------------ execution

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

--- Count passes, judged and unjudged cases from the statuses.
local function tally(report)
  local passed, judged, unjudged = 0, 0, 0
  for _, c in ipairs(report.cases or {}) do
    if c.status == "no_oracle" then
      -- Ran fine, but nothing knows an answer for this input, so it is not
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

local function summarize(report)
  if report.unsupported then
    report.error = (report.error or "unsupported")
      .. " — use " .. config.options.keys.problem.submit .. " to run this one in the cloud"
  end
  return tally(report)
end

--- `unsupported` marks a problem we cannot faithfully reproduce locally, as
--- opposed to something going wrong; the results panel presents the two differently.
local function fail(cb, msg, unsupported)
  cb(summarize({ ok = false, error = msg, cases = {}, unsupported = unsupported }))
end

--- Read a bundled harness file (python.py, checker.py, cpp_runtime.h, ...).
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
    [5] = "SIGTRAP: a runtime check failed, such as an out-of-bounds index",
    [6] = "SIGABRT: abort",
    [8] = "SIGFPE: arithmetic exception",
    [11] = "SIGSEGV: segmentation fault — invalid memory access",
  }
  diagnostics[vim.uv.os_uname().sysname == "Darwin" and 10 or 7] =
    "SIGBUS: bus error — invalid or misaligned memory access"
  return diagnostics[signal]
end

--- Inside the macOS sandbox, Xcode's tool shims cannot refresh their lookup
--- cache (it lives in the shared temporary directory) and say so on stderr,
--- yet the tool still runs: drop those lines from anything shown.
local function without_shim_noise(text)
  return (text:gsub("[^\n]*couldn't create cache file '[^']*xcrun_db[^\n]*\n?", ""))
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

  local msg = without_shim_noise(res.stderr or ""):gsub("CASE %d+\n", "")
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

--- The 0-based case a failed harness had started last (it announces each
--- with `CASE <n>` on stderr), or nil when it died before the first.
local function crashed_case(stderr)
  local last = nil
  for idx in (stderr or ""):gmatch("CASE (%d+)") do
    last = tonumber(idx)
  end
  return last
end

--- Complete a failed run. A crash while a test case was running is reported
--- against that case and its input: what went wrong (from a sanitizer, libc++
--- or assert() report when there is one, saved whole to `crash.log`), where in
--- the solution, the calls that led there and what it printed. Without a
--- report that locates it, a C++ crash gets an LLDB backtrace instead.
---@param res vim.SystemCompleted
---@param cmd string[]
---@param dir string
---@param timeout_ms integer
---@param debug_crash boolean|nil
---@param cases string[]
---@param cb fun(result: meatcode.RunResult)
local function finish_failure(res, cmd, dir, timeout_ms, debug_crash, cases, cb)
  local last = crashed_case(res.stderr)

  local report = crash.parse(without_shim_noise(res.stderr or ""))
  local msg = report and crash.summary(report) or process_failure(res)
  local details
  if report then
    util.write_file(dir .. "/crash.log", res.stderr or "")
    details = crash.describe(report, dir)
    details.what = report.what
    details.report = dir .. "/crash.log"
  elseif last then
    local first, rest = msg:match("^([^\n]*)\n(.*)$")
    details = { what = first or msg, output = rest and vim.trim(rest) or nil }
  end
  if last then
    details.case = last + 1
    details.input = cases[last + 1]
    msg = string.format("test case %d: %s", last + 1, msg)
  end
  local result = { ok = false, error = msg, crash = details, cases = {} }

  local located = report and report.at
  if located or not debug_crash or not res.signal or res.signal == 0 or res.signal == 15 or res.signal == 9 then
    return cb(summarize(result))
  end
  debugger_backtrace(cmd, dir, timeout_ms, function(backtrace)
    if backtrace then
      result.error = result.error .. "\n\nbacktrace:\n" .. backtrace
      if result.crash then result.crash.backtrace = backtrace end
    end
    cb(summarize(result))
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

--- macOS: `sandbox-exec` applies a Seatbelt profile (harness/sandbox.sb) that
--- denies everything it does not list: the toolchain and system libraries can
--- be read and run, the scratch directory (which also holds TMPDIR) is the only
--- place that can be written, and the network, your files and other services
--- stay out of reach. The environment is cleared. There is no PID namespace on
--- macOS, so the process table stays visible. Paths need no rewriting because
--- the process keeps the host layout.
local function macos_sandbox_command(cmd, dir)
  if vim.fn.executable("sandbox-exec") ~= 1 then
    return nil, "`sandbox-exec` is required to run provider-supplied code safely on macOS"
  end
  local tmp = util.mkdirp(dir .. "/tmp")
  local wrapped = {
    "sandbox-exec",
    -- Seatbelt matches resolved paths, so a scratch directory reached through a
    -- symlink (/tmp is /private/tmp) must be named by its real path.
    "-D", "WORK_DIR=" .. (vim.uv.fs_realpath(dir) or dir),
    "-f", harness_dir() .. "/sandbox.sb", "--",
    "/usr/bin/env", "-i",
    "PATH=/usr/bin:/bin",
    "HOME=/nonexistent",
    "TMPDIR=" .. tmp,
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
local function execute(cmd, dir, cases, cb, debug_crash, untrusted)
  local timeout_ms = (config.options.runner.time_limit or 10) * 1000
  local shards = parallelism(#cases)
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
        elseif not failure or (crashed_case(res.stderr) or math.huge) < (crashed_case(failure.res.stderr) or math.huge) then
          -- Several workers may fail; report the earliest case, as a judge would.
          failure = { res = res, cmd = command.cmd, sandboxed = command.sandboxed }
        end
        pending = pending - 1
        if pending > 0 then return end
        if failure then
          return finish_failure(failure.res, failure.cmd, dir, timeout_ms,
            debug_crash and shards == 1 and not failure.sandboxed, cases, cb)
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

--- `expected.json`: every acceptable answer per case, `[]` for none.
local function expected_json(cases, answer_lists)
  local lists = {}
  for i = 1, #cases do lists[i] = (answer_lists and answer_lists[i]) or {} end
  return ops.encode(lists)
end

local function run_python(problem_id, code, meta, cases, cb, oracle, answer_lists)
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
  util.write_file(dir .. "/cases.json", ops.encode(cases))
  util.write_file(dir .. "/types.json", declared_types(meta))
  util.write_file(dir .. "/expected.json", expected_json(cases, answer_lists))

  local py = vim.deepcopy(config.options.runner.python.cmd)
  table.insert(py, dir .. "/harness.py")
  table.insert(py, dir)
  table.insert(py, "function")
  table.insert(py, oracle)
  execute(py, dir, cases, cb, false, meta._untrusted_user or oracle == "reference")
end

--- Design problems: normalise the call sequence, then replay it in the harness.
--- `mode` is "class" for an operation sequence, "roundtrip" for encode/decode.
local function run_python_class(problem_id, code, meta, cases, cb, mode, oracle, answer_lists)
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
  util.write_file(dir .. "/cases.json", ops.encode(cases))
  util.write_file(dir .. "/types.json", declared_types(meta))
  util.write_file(dir .. "/expected.json", expected_json(cases, answer_lists))

  local py = vim.deepcopy(config.options.runner.python.cmd)
  table.insert(py, dir .. "/harness.py")
  table.insert(py, dir)
  table.insert(py, mode)
  table.insert(py, oracle)
  execute(py, dir, cases, cb, false, meta._untrusted_user or oracle == "reference")
end

local function run_cpp(problem_id, code, meta, cases, cb, mode, oracle, answer_lists)
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
  util.write_file(dir .. "/cases.json", ops.encode(cases))
  util.write_file(dir .. "/expected.json", expected_json(cases, answer_lists))

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
        local msg = vim.trim(without_shim_noise(res.stderr or ""))
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
      execute({ bin, dir }, dir, cases, cb, true, untrusted)
    end)
  end)
end

--- Whether `lang` and the problem's shape allow a local run at all. Finer
--- limits (argument types, a class that will not parse) surface as an
--- `unsupported` report from the harness itself.
local function runs_locally(meta, lang)
  local kind = meta.test_case_type or "function"
  local starter = type(meta.starterCode) == "table" and meta.starterCode[lang] or nil
  return M.SUPPORTED[lang] == true and (kind == "function" or kind == "class")
    and type(starter) == "string" and starter ~= ""
end

--- Why a problem cannot run locally, for the results panel.
local function local_limit(meta, lang)
  if not M.SUPPORTED[lang] then return string.format("local runs are not supported for %s yet", lang) end
  local kind = meta.test_case_type or "function"
  if kind ~= "function" and kind ~= "class" then
    return string.format("`%s` problems can only run in the cloud", kind)
  end
  return "no starter code is available for a local run"
end

--- Run `code` locally, graded against `answer_lists` (every acceptable answer
--- per case). Under the "reference" oracle the harness runs `_oracle_code`
--- itself and grades against its output instead.
local function run_selected(problem_id, code, lang, meta, cases, cb, oracle, answer_lists)
  local kind = meta.test_case_type or "function"
  if kind ~= "function" and kind ~= "class" then
    return fail(cb, string.format("`%s` problems can only run in the cloud", kind), true)
  end
  if kind == "class" and not cases[1]:match('^%s*%[%s*"') then kind = "roundtrip" end
  if lang == "python" then
    if kind ~= "function" then
      return run_python_class(problem_id, code, meta, cases, cb, kind, oracle, answer_lists)
    end
    return run_python(problem_id, code, meta, cases, cb, oracle, answer_lists)
  end
  return run_cpp(problem_id, code, meta, cases, cb, kind, oracle, answer_lists)
end

--- Grade `outputs` (JSON text per case; nil where the solution produced none)
--- with an openleetcode checker. The checker is remote code, so it always runs
--- sandboxed, in Python whatever the solution's language.
local function run_checker(problem_id, checker, cases, outputs, cb, scope)
  local dir = workdir(problem_id, "checker", scope)
  local harness = read_harness(cb, "python.py")
  if not harness then return end
  local script = read_harness(cb, "checker.py")
  if not script then return end
  local encoded = {}
  for i = 1, #cases do encoded[i] = outputs[i] or vim.NIL end

  util.write_file(dir .. "/harness.py", harness)
  util.write_file(dir .. "/checker.py", script)
  util.write_json(dir .. "/checker.json", {
    source = checker.source,
    call = checker.call,
    params = checker.params,
    utilities = checker.utilities or vim.NIL,
  })
  util.write_file(dir .. "/cases.json", ops.encode(cases))
  util.write_file(dir .. "/outputs.json", ops.encode(encoded))

  local py = vim.deepcopy(config.options.runner.python.cmd)
  table.insert(py, dir .. "/checker.py")
  table.insert(py, dir)
  execute(py, dir, cases, cb, false, true)
end

-- ------------------------------------------------------------ oracle selection

--- The checker as a candidate: it goes first, and needs a Python to run in.
local function checker_candidate(meta, lang)
  if not checker_applies(meta, lang) then return nil end
  local python = config.options.runner.python.cmd[1]
  if not python or vim.fn.executable(python) ~= 1 then return nil end
  local checker = meta.checker
  return {
    stage = "checker",
    provider = "openleetcode",
    id = checker.path,
    checker = checker,
    code_hash = vim.fn.sha256(table.concat({
      checker.source, checker.call, table.concat(checker.params, ","), checker.utilities or "",
    }, "\0")),
  }
end

--- Local candidates in precedence order: the checker, then stage-major
--- executables in provider order, then popularity (the order providers list
--- them in).
local function source_candidates(meta, lang)
  local out = {}
  local checker = checker_candidate(meta, lang)
  if checker then table.insert(out, checker) end
  if not M.SUPPORTED[lang] then return out end
  local executables = {}
  for _, stage in ipairs(EXECUTABLE_STAGES) do
    for _, candidate in ipairs(type(meta.oracle_candidates) == "table"
      and type(meta.oracle_candidates[stage]) == "table"
      and meta.oracle_candidates[stage] or {}) do
      if type(candidate.code) == "string" and candidate.code ~= "" then
        table.insert(executables, vim.tbl_extend("force", {}, candidate,
          { stage = stage, code_hash = vim.fn.sha256(candidate.code) }))
      end
    end
  end
  if #executables == 0 then
    local code = type(meta.solutions) == "table" and meta.solutions[lang] or nil
    if type(code) == "string" and code ~= "" then
      table.insert(executables, { stage = "reference", provider = "neetcode", code = code,
        code_hash = vim.fn.sha256(code) })
    end
  end
  vim.list_extend(out, executables)
  return out
end

--- Every input with a ground-truth answer (statements, failed submissions)
--- and its acceptable answers, their fingerprint, and the visible examples a
--- reference/editorial is smoke-run on when nothing is known. Independent of
--- the editable suite, so editing cases never invalidates a selection.
local function validation_set(problem_id, meta)
  local defaults = type(meta.custom_test_cases) == "table" and meta.custom_test_cases or {}
  local known = answers.known(problem_id, meta)
  local parts = {}
  for _, item in ipairs(known) do
    table.insert(parts, item.input .. "\0" .. table.concat(item.answers, "\0"))
  end
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

--- Blacklist a candidate and forget every answer it produced.
local function reject(problem_id, lang, state, candidate, reason)
  state.rejected[candidate.code_hash] = {
    stage = candidate.stage, provider = candidate.provider,
    id = candidate.id, reason = reason,
  }
  if state.selection and state.selection.code_hash == candidate.code_hash then
    state.selection = nil
  end
  save_state(problem_id, lang, state)
  answers.purge(problem_id, source_of(candidate))
end

--- Outputs from a sandboxed oracle run, as answer-cache entries.
local function oracle_entries(report, source)
  local entries, errors = {}, {}
  for _, c in ipairs(type(report) == "table" and report.cases or {}) do
    if c.status == "error" or c.status == "oracle_error" then
      table.insert(errors, (type(c.error) == "string" and c.error:match("^[^\n]+")) or c.status)
    elseif type(c.input) == "string" and type(c.actual) == "string" then
      table.insert(entries, { input = c.input, output = c.actual, source = source })
    end
  end
  return entries, errors
end

--- Give every case an answer, sandboxing the selected executable candidate
--- only for inputs that still have none (typically cases the user just
--- added). `scope` keeps concurrent oracle runs out of each other's scratch
--- directory.
local function ensure_oracle_outputs(problem_id, lang, meta, candidate, cases, cb, status, scope)
  local lists = answers.lookup(problem_id, meta, cases, trusted(candidate))
  local missing = {}
  for i, case in ipairs(cases) do
    if #lists[i] == 0 then table.insert(missing, case) end
  end
  if #missing == 0 then
    return cb(nil)
  end

  if status then
    status(string.format(
      "Computing oracle outputs for %d new case%s (%d cached)",
      #missing, #missing == 1 and "" or "s", #cases - #missing))
  end

  local trial_meta = vim.tbl_extend("force", {}, meta, {
    _untrusted_user = true,
    _scope = scope,
  })

  run_selected(problem_id, candidate.code, lang, trial_meta, missing, function(report)
    if report.unsupported then
      return cb(report.error or "oracle unsupported")
    end
    if report.error and #(report.cases or {}) == 0 then
      return cb(report.error)
    end
    local entries, errors = oracle_entries(report, source_of(candidate))
    if #errors > 0 then
      return cb("oracle failed on a case: " .. errors[1])
    end
    if #entries < #missing then
      return cb("oracle produced no output for a case")
    end
    answers.add(problem_id, entries)
    cb(nil)
  end, "expected")
end

--- The local oracle validated against the current known answers, or nil when
--- none has been (yet). Synchronous: never executes anything.
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

--- Why a report failed validation, from its last meaningful line.
local function failure_reason(report, fallback)
  if type(report.error) == "string" then
    return report.error:match("([^\n]+)%s*$") or fallback
  end
  for _, c in ipairs(report.cases or {}) do
    if c.status ~= "pass" and c.status ~= "pass_unordered" then
      local what = type(c.error) == "string" and c.error:match("([^\n]+)%s*$") or c.status
      return string.format("%s on %s", what, (tostring(c.input):gsub("\n", " ")))
    end
  end
  return fallback
end

--- Validate the checker: it must accept every known answer. With nothing known
--- it only has to load.
local function validate_checker(problem_id, candidate, known, cb)
  local cases, outputs = {}, {}
  for _, item in ipairs(known) do
    for _, output in ipairs(item.answers) do
      table.insert(cases, item.input)
      table.insert(outputs, output)
    end
  end
  run_checker(problem_id, candidate.checker, cases, outputs, function(report)
    if report.unsupported then return cb(nil, report.error) end
    if report.ok and report.passed == report.total then return cb(true) end
    cb(false, failure_reason(report, "rejected a known answer"))
  end, "oracle")
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

  local function choose(candidate, report)
    local previous = state.selection
    state.selection = {
      stage = candidate.stage,
      provider = candidate.provider,
      id = candidate.id,
      code_hash = candidate.code_hash,
      validation_key = validation_key,
    }
    save_state(problem_id, lang, state)
    if previous and previous.code_hash ~= candidate.code_hash then
      -- Only the selected candidate's outputs are trusted.
      answers.purge(problem_id, source_of(previous))
    end
    if report then
      -- The pass that proved the candidate also seeds its per-case outputs.
      answers.add(problem_id, (oracle_entries(report, source_of(candidate))))
    end
    cb(candidate, rejected)
  end

  local step
  local function refuse(candidate, reason)
    reject(problem_id, lang, state, candidate, reason)
    table.insert(rejected, candidate)
    if status then status(reason .. " — trying next candidate") end
    step()
  end

  step = function()
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

    if candidate.stage == "checker" then
      if status then status("Validating the openleetcode checker against known answers") end
      return validate_checker(problem_id, candidate, known, function(ok, reason)
        if ok then return choose(candidate, nil) end
        if ok == nil then
          -- No sandbox or no Python: not the checker's fault, so no blacklist;
          -- the executable candidates may still run.
          return step()
        end
        refuse(candidate, reason)
      end)
    end

    local trial_cases, trial_answers = {}, {}
    for i, item in ipairs(known) do
      trial_cases[i], trial_answers[i] = item.input, item.answers
    end
    if #trial_cases == 0 then trial_cases = defaults end
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
        return choose(candidate, report)
      end
      if report.unsupported then
        -- Not this candidate's fault (no sandbox, or the problem cannot run
        -- locally at all): every other candidate would fail the same way.
        return cb(nil, rejected, report.error)
      end
      refuse(candidate, failure_reason(report, "failed known cases"))
    end, #known > 0 and "expected" or "reference", #known > 0 and trial_answers or nil)
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

--- Select (or confirm) the local oracle in the background and precompute an
--- executable one's outputs for `cases`, so a later run never waits on
--- provider code. Single-flight per problem/language: a call while one is in
--- flight queues exactly one more pass with the latest arguments (e.g. new
--- candidates from another provider, a checker that just arrived, or a newly
--- learned answer), and every caller's `cb` receives the outcome of the final
--- pass.
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
          stage = candidate and candidate.stage or "cloud",
          provider = candidate and candidate.provider or nil,
          id = candidate and candidate.id or nil,
          title = candidate and candidate.title or nil,
          votes = candidate and candidate.votes or nil,
          rejected = rejected_total,
          error = err or output_err,
        }
        for _, waiter in ipairs(job.waiters) do waiter(info) end
      end
      if not candidate or candidate.stage == "checker"
        or type(pass_cases) ~= "table" or #pass_cases == 0 then
        return done()
      end
      ensure_oracle_outputs(problem_id, lang, pass_meta, candidate, pass_cases,
        function(output_err) done(output_err) end, pass_status, "oracle")
    end, pass_status)
  end
  pass(meta, cases, status)
end

-- ------------------------------------------------------------ runs

--- Start the cloud test run. `wait` hands its outcome over once (right away if
--- it already finished); `cancel` ends it early and drops the outcome.
local function start_cloud(cloud, code, cases)
  local job = { finished = false, cancelled = false, waiters = {} }
  job.stop = cloud.test(code, cases, function(err, results)
    vim.schedule(function()
      if job.cancelled then return end
      job.finished, job.err, job.results = true, err, results
      for _, waiter in ipairs(job.waiters) do waiter(err, results) end
      job.waiters = {}
    end)
  end)
  function job.wait(fn)
    if job.finished then return fn(job.err, job.results) end
    table.insert(job.waiters, fn)
  end
  function job.cancel()
    if job.finished or job.cancelled then return end
    job.cancelled = true
    if job.stop then job.stop() end
  end
  return job
end

--- Store what a test run revealed. The judge's own answers are ground truth.
--- When it accepted your code's output, that output joins them — unless the
--- result's `actual` is not your output at all, in which case nothing about
--- it can be trusted and it is left out.
local function learn_from_cloud(problem_id, provider, cases, report, results)
  local source, entries = "cloud:" .. provider, {}
  local by_index = {}
  for _, c in ipairs(type(report) == "table" and report.cases or {}) do
    by_index[(c.index or 0) + 1] = c
  end
  for i, result in ipairs(results) do
    if cases[i] then
      if result.expected then
        table.insert(entries, { input = cases[i], output = result.expected, source = source })
      end
      local local_case = by_index[i]
      local confirmed = result.correct == true and result.actual and local_case
        and type(local_case.actual) == "string"
        and answers.compare(local_case.actual, result.actual) == "pass"
      if confirmed and answers.compare(result.actual, result.expected or "") ~= "pass" then
        table.insert(entries, { input = cases[i], output = result.actual, source = source })
      end
    end
  end
  return answers.add(problem_id, entries)
end

--- A selected executable oracle whose stored output contradicts the judge on a
--- problem with one right answer is wrong: blacklist it.
---@return table|nil rejected candidate
local function contradicted(problem_id, lang, meta, selected, cases, results, provider)
  if not selected or selected.stage == "checker" or meta.complexTestCases == true then return nil end
  local source, store = source_of(selected), answers.load(problem_id)
  for i, result in ipairs(results) do
    if cases[i] and result.expected then
      for _, entry in ipairs(store[answers.key(cases[i])] or {}) do
        if entry.source == source and answers.compare(entry.output, result.expected) == nil then
          local state = load_state(problem_id, lang)
          reject(problem_id, lang, state, selected, string.format("contradicted %s's judge on %s",
            providers.get(provider).label, (answers.key(cases[i]):gsub("\n", " "))))
          return selected
        end
      end
    end
  end
  return nil
end

--- A report built entirely from the judge's test run, for problems that cannot
--- run locally.
local function cloud_report(cloud, cases, results, reason)
  local report = { ok = true, cases = {} }
  for i, case in ipairs(cases) do
    local result = results[i] or {}
    local status = result.correct == true and "pass"
      or result.correct == false and "fail"
      or result.error and "error"
      or "no_oracle"
    table.insert(report.cases, {
      index = i - 1,
      input = case,
      status = status,
      expected = result.expected,
      actual = result.actual,
      stdout = result.stdout,
      error = result.error,
      judged_by = "cloud",
    })
  end
  report.cloud = { provider = cloud.provider, state = "judged", judged = #cases, only = reason }
  return tally(report)
end

--- Why the harness refused a problem, minus the "submit it instead" advice
--- `summarize` appends: the cloud is about to run it after all.
local function local_reason(report)
  return (tostring(report.error or "unsupported"):gsub(" — use .*$", ""))
end

--- Run everything on the judge: the problem cannot run locally.
local function cloud_only(problem_id, code, cases, cloud, finish, status, reason, job)
  job = job or start_cloud(cloud, code, cases)
  if status then
    status(string.format("Running %d case%s on %s's judge (%s)", #cases, #cases == 1 and "" or "s",
      providers.get(cloud.provider).label, reason))
  end
  job.wait(function(err, results)
    if err or type(results) ~= "table" then
      return finish(summarize({
        ok = false,
        unsupported = true,
        error = reason .. "; the " .. describe("cloud", cloud.provider) .. " failed: " .. tostring(err or "no result"),
        cases = {},
      }), "cloud", cloud.provider)
    end
    learn_from_cloud(problem_id, cloud.provider, cases, nil, results)
    finish(cloud_report(cloud, cases, results, reason), "cloud", cloud.provider)
  end)
end

--- Judge the cases a local run could not settle with the test run's verdicts.
local function merge_cloud(problem_id, lang, meta, selected, cloud, cases, report, pending, err, results)
  report.cloud = { provider = cloud.provider }
  if err or type(results) ~= "table" then
    report.cloud.state = "unavailable"
    report.cloud.error = tostring(err or "no result")
    local label = providers.get(cloud.provider).label
    for _, c in pairs(pending) do
      c.no_verdict = "no " .. label .. " verdict — judged from cached answers only"
    end
    return
  end
  report.cloud.learned = learn_from_cloud(problem_id, cloud.provider, cases, report, results)
  local judged = 0
  for index, c in pairs(pending) do
    local result = results[index]
    local matches = result and result.actual and type(c.actual) == "string"
      and answers.compare(c.actual, result.actual) == "pass"
    if result and result.correct == true and matches then
      c.status = "pass"
      c.judged_by = "cloud"
      c.expected = result.expected or c.expected
      judged = judged + 1
    elseif result and result.correct == true then
      -- The judge accepted, but not your output: on a rerun it graded
      -- something else (randomized, flaky, or misattributed). Grade yours
      -- against what it did accept instead.
      local list = { result.actual or result.expected }
      if result.expected and result.actual
        and answers.compare(result.actual, result.expected) ~= "pass" then
        table.insert(list, result.expected)
      end
      c.status, c.expected = answers.grade(c.actual, list)
      c.judged_by = "cloud"
      c.cloud_actual = result.actual
      judged = judged + 1
    elseif result and result.correct == false then
      c.status = "fail"
      c.judged_by = "cloud"
      c.expected = result.expected or c.expected
      if result.actual and c.actual and answers.compare(c.actual, result.actual) ~= "pass" then
        c.cloud_actual = result.actual
      end
      judged = judged + 1
    elseif result and result.expected and type(c.actual) == "string" then
      -- The judge could not run your code on this case, but it printed its answer.
      c.status, c.expected = answers.grade(c.actual, { result.expected })
      c.judged_by = "cloud"
      c.cloud_error = result.error
      judged = judged + 1
    elseif result then
      c.cloud_error = result.error or "no verdict from the judge"
    end
  end
  report.cloud.state = "judged"
  report.cloud.judged = judged
  local rejected = contradicted(problem_id, lang, meta, selected, cases, results, cloud.provider)
  if rejected then report.rejected = describe(rejected.stage, rejected.provider, rejected) end
  tally(report)
end

--- The cloud oracle, always cautious: the test run starts alongside the local
--- run and is cancelled when every output matches a cached answer; otherwise
--- the judge settles every case that did not match.
local function cloud_run(problem_id, code, lang, meta, cases, cloud, selected, finish, status)
  local job = start_cloud(cloud, code, cases)
  local label = providers.get(cloud.provider).label
  if status then
    status(string.format("Running %d case%s locally · %s test run started alongside",
      #cases, #cases == 1 and "" or "s", label))
  end
  local lists = answers.lookup(problem_id, meta, cases, trusted(selected))
  run_selected(problem_id, code, lang, meta, cases, function(report)
    if report.unsupported then
      return cloud_only(problem_id, code, cases, cloud, finish, status, local_reason(report), job)
    end
    if not report.ok then
      job.cancel()
      return finish(report, "cloud", cloud.provider)
    end
    local pending, count = {}, 0
    for _, c in ipairs(report.cases) do
      if c.status ~= "pass" and c.status ~= "error" then
        pending[(c.index or 0) + 1] = c
        count = count + 1
      end
    end
    if count == 0 then
      job.cancel()
      report.cloud = { provider = cloud.provider, state = "skipped" }
      return finish(report, "cloud", cloud.provider)
    end
    if status then
      status(string.format("Waiting for the %s test run to settle %d case%s", label, count,
        count == 1 and "" or "s"))
    end
    job.wait(function(err, results)
      merge_cloud(problem_id, lang, meta, selected, cloud, cases, report, pending, err, results)
      finish(report, "cloud", cloud.provider)
    end)
  end, "expected", lists)
end

--- The checker judges every output; cached answers only supply what to show.
local function checker_run(problem_id, code, lang, meta, cases, selected, cloud, finish, status)
  local lists = answers.lookup(problem_id, meta, cases, trusted(selected))
  run_selected(problem_id, code, lang, meta, cases, function(report)
    if report.unsupported and cloud then
      return cloud_only(problem_id, code, cases, cloud, finish, status, local_reason(report))
    end
    if not report.ok then return finish(report, "checker", "openleetcode") end
    local outputs, by_index = {}, {}
    for _, c in ipairs(report.cases) do
      by_index[c.index or 0] = c
      if c.status ~= "error" and type(c.actual) == "string" then outputs[(c.index or 0) + 1] = c.actual end
    end
    if status then status("Checking outputs with the openleetcode checker") end
    run_checker(problem_id, selected.checker, cases, outputs, function(verdicts)
      if not verdicts.ok then
        report.checker_error = verdicts.error
        return finish(report, "checker", "openleetcode")
      end
      local accepted = {}
      for _, verdict in ipairs(verdicts.cases or {}) do
        local c = by_index[verdict.index]
        if c and (verdict.status == "pass" or verdict.status == "fail") then
          c.status = verdict.status
          c.judged_by = "checker"
          if verdict.status == "pass" then
            table.insert(accepted, { input = c.input, output = c.actual, source = source_of(selected) })
          end
        elseif c and verdict.status == "oracle_error" then
          c.status = "oracle_error"
          c.error = verdict.error
        end
      end
      answers.add(problem_id, accepted)
      finish(tally(report), "checker", "openleetcode")
    end, "probe")
  end, "expected", lists)
end

--- Run `code` against `cases` locally.
---
--- The selected local oracle judges, computing outputs for cases it has not
--- seen (sandboxed) first. The cloud oracle (`cloud`, the submit provider's test
--- run) takes over when nothing local is selected yet, when the cloud setting
--- forces it, and for problems that cannot run locally at all. Your solution
--- always runs alone, unsandboxed.
---@param cloud meatcode.CloudOracle|nil
function M.run(problem_id, code, lang, meta, cases, cb, status, cloud)
  if #cases == 0 then
    return fail(cb, "no test cases to run", true)
  end

  local selected = M.selected(problem_id, lang, meta)
  local pending = not selected and M.preparing(problem_id, lang)

  local function finish(report, stage, provider_name)
    local candidate = selected and selected.stage == stage and selected or nil
    report.oracle_stage = stage
    report.oracle_provider = provider_name
    report.oracle_id = candidate and candidate.id or nil
    report.oracle_title = candidate and candidate.title or nil
    report.oracle_votes = candidate and candidate.votes or nil
    report.oracle_pending = (stage == "cloud" or stage == "answers") and pending or nil
    cb(report)
  end

  if not runs_locally(meta, lang) then
    if cloud then
      return cloud_only(problem_id, code, cases, cloud, finish, status, local_limit(meta, lang))
    end
    return fail(cb, local_limit(meta, lang), true)
  end

  if cloud and (not selected or M.forces_cloud(meta, selected)) then
    return cloud_run(problem_id, code, lang, meta, cases, cloud, selected, finish, status)
  end

  if not selected then
    -- No judge to ask: known answers grade what they can; the rest runs unjudged.
    local lists = answers.lookup(problem_id, meta, cases, nil)
    return run_selected(problem_id, code, lang, meta, cases, function(report)
      finish(report, "answers", nil)
    end, "expected", lists)
  end

  if selected.stage == "checker" then
    return checker_run(problem_id, code, lang, meta, cases, selected, cloud, finish, status)
  end

  ensure_oracle_outputs(problem_id, lang, meta, selected, cases, function(err)
    if err then
      if cloud then return cloud_run(problem_id, code, lang, meta, cases, cloud, nil, finish, status) end
      return fail(cb, err)
    end
    local workers = parallelism(#cases)
    if status then
      status(string.format("Running with %s %s oracle · %d worker%s",
        selected.provider, selected.stage, workers, workers == 1 and "" or "s"))
    end
    local lists = answers.lookup(problem_id, meta, cases, trusted(selected))
    run_selected(problem_id, code, lang, meta, cases, function(report)
      if report.unsupported and cloud then
        return cloud_only(problem_id, code, cases, cloud, finish, status, local_reason(report))
      end
      finish(report, selected.stage, selected.provider)
    end, "expected", lists)
  end, status, "probe")
end

return M
