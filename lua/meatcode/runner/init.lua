local config = require("meatcode.config")
local cpp = require("meatcode.runner.cpp")
local ops = require("meatcode.runner.ops")
local util = require("meatcode.util")

--- Runs a solution against visible cases. Oracle precedence is stage-major:
--- reference, official editorial, popular community solution, then published
--- statement answers. Provider fallback order only breaks ties inside a stage.
--- Community code is never trusted blindly: candidates are tried in popularity
--- order and must pass every known example before one may judge user cases.
--- Cases with no known answer still execute and report RAN under the statement
--- oracle. A cloud judge's revealed expected output is persisted for later runs.
local M = {}

M.SUPPORTED = { python = true, cpp = true }

--- Strongest potentially available stage. Final selection happens in `run`
--- because executable candidates must first survive their sanity run.
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
local function expected_values(problem_id, meta, cases)
  local published = {}
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
  local out = {}
  for i, case in ipairs(cases) do out[i] = published[case_key(case)] or vim.NIL end
  return out
end

local function expected_json(problem_id, meta, cases)
  return ops.encode(expected_values(problem_id, meta, cases))
end

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



--- Isolate provider-supplied code from the network, home directory, process
--- table and host filesystem. Only the per-run scratch directory is writable.
--- The user may opt out explicitly; otherwise missing bubblewrap fails closed.
local function sandbox_command(cmd, dir, required)
  if not required or config.options.runner.sandbox == false then return cmd, false end
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
  local dir = workdir(problem_id, "python")
  local ref = signature_source(meta, "python", oracle)
  if not ref or ref == "" then
    return fail(cb, "no Python starter code to derive the signature from", true)
  end

  util.write_file(dir .. "/user.py", code)
  util.write_file(dir .. "/ref.py", ref)
  util.write_file(dir .. "/harness.py", util.read_file(harness_dir() .. "/python.py"))
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
  local dir = workdir(problem_id, "python")
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

  util.write_file(dir .. "/user.py", code)
  util.write_file(dir .. "/ref.py", ref)
  util.write_file(dir .. "/harness.py", util.read_file(harness_dir() .. "/python.py"))
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
  local dir = workdir(problem_id, "cpp")
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

  util.write_file(dir .. "/user.cpp", strip_includes(code))
  util.write_file(dir .. "/ref.cpp", ref and strip_includes(ref) or "")
  util.write_file(dir .. "/main.cpp", main_src)
  util.write_json(dir .. "/cases.json", cases)
  util.write_file(dir .. "/expected.json", expected_json(problem_id, meta, cases))

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

local function source_candidates(meta, lang)
  local out = {}
  for _, stage in ipairs({ "reference", "editorial", "community" }) do
    for _, candidate in ipairs(type(meta.oracle_candidates) == "table"
      and type(meta.oracle_candidates[stage]) == "table"
      and meta.oracle_candidates[stage] or {}) do
      if type(candidate.code) == "string" and candidate.code ~= "" then
        table.insert(out,
          vim.tbl_extend("force", vim.deepcopy(candidate), { stage = stage }))
      end
    end
  end
  if #out == 0 then
    local code = type(meta.solutions) == "table" and meta.solutions[lang] or nil
    if type(code) == "string" and code ~= "" then
      table.insert(out, { stage = "reference", provider = "neetcode", code = code })
    end
  end
  return out
end

local function validation_path(problem_id, lang)
  return string.format("%s/oracle-validations/%s-%s.json",
    config.options.cache_dir, util.slug(tostring(problem_id)), lang)
end

local function saved_selection(problem_id, lang, meta)
  return meta._selected_oracle or util.read_json(validation_path(problem_id, lang))
end

local function save_selection(problem_id, lang, meta, candidate, validation_key)
  candidate.validation_key = validation_key
  candidate.code_hash = vim.fn.sha256(candidate.code)
  meta._selected_oracle = vim.deepcopy(candidate)
  util.write_json(validation_path(problem_id, lang), {
    stage = candidate.stage,
    provider = candidate.provider,
    id = candidate.id,
    code_hash = candidate.code_hash,
    validation_key = validation_key,
  })
end

--- Pick the first executable source under stage-major/provider-minor order.
--- Community candidates require known answers; a popularity ranking alone is
--- never enough to make arbitrary user code an oracle.
local function resolve_source(problem_id, lang, meta, cases, cb, status)
  local candidates = source_candidates(meta, lang)
  local values = expected_values(problem_id, meta, cases)
  local known = {}
  for i, value in ipairs(values) do
    if value ~= vim.NIL then table.insert(known, cases[i]) end
  end
  local fingerprint_parts = {}
  for i, value in ipairs(values) do
    if value ~= vim.NIL then
      table.insert(fingerprint_parts, case_key(cases[i]) .. "\0" .. tostring(value))
    end
  end
  local validation_key = vim.fn.sha256(table.concat(fingerprint_parts, "\1"))
  local selected = saved_selection(problem_id, lang, meta)
  if type(selected) == "table" and selected.validation_key == validation_key then
    for _, candidate in ipairs(candidates) do
      if candidate.stage == selected.stage and candidate.provider == selected.provider
        and (selected.code == nil or candidate.code == selected.code)
        and (selected.code_hash == nil or vim.fn.sha256(candidate.code) == selected.code_hash) then
        if status then
          status(string.format("Using cached %s %s oracle",
            candidate.provider or "local", candidate.stage))
        end
        return cb(candidate, {})
      end
    end
    meta._selected_oracle = nil
  end
  local index, rejected = 1, {}
  local function step()
    local candidate = candidates[index]
    index = index + 1
    if not candidate then
      meta._selected_oracle = nil
      return cb(nil, rejected)
    end
    if candidate.stage == "community" and #known == 0 then return step() end
    local trial_meta = vim.deepcopy(meta)
    trial_meta._oracle_code = candidate.code
    trial_meta._untrusted_user = true
    local trial_cases = #known > 0 and known or cases
    local trial_oracle = #known > 0 and "expected" or "reference"
    if status then
      status(string.format("Validating %s %s candidate %d/%d on %d workers",
        candidate.provider or "local", candidate.stage, index - 1, #candidates,
        parallelism(#trial_cases)))
    end
    run_selected(problem_id, candidate.code, lang,
      trial_meta, trial_cases, function(report)
        if report.ok and report.total > 0 and report.passed == report.total then
          save_selection(problem_id, lang, meta, candidate, validation_key)
          return cb(candidate, rejected)
        end
        if status then
          local reason = (report.error or "Candidate failed known cases"):match("^[^\n]+")
          status(reason .. " — trying next source")
        end
        table.insert(rejected, candidate)
        step()
      end, trial_oracle)
  end
  step()
end

--- Run `code` against `cases` locally.
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

  resolve_source(problem_id, lang, meta, cases, function(candidate)
    local selected = vim.deepcopy(meta)
    selected._oracle_code = candidate and candidate.code or nil
    local harness_oracle = candidate and "reference" or "expected"
    if status then
      local workers = parallelism(#cases)
      status((candidate
        and string.format("Running with %s %s oracle", candidate.provider, candidate.stage)
        or "Running with statement and learned answers (unknown outputs are N/A)")
        .. string.format(" on %d worker%s", workers, workers == 1 and "" or "s"))
    end
    run_selected(problem_id, code, lang, selected, cases, function(report)
      report.oracle_stage = candidate and candidate.stage or "expected"
      report.oracle_provider = candidate and candidate.provider or nil
      report.oracle_id = candidate and candidate.id or nil
      cb(report)
    end, harness_oracle)
  end, status)
end

--- Re-run oracle selection after the cloud judge teaches us a new answer.
--- Rejected community candidates are removed from this session so subsequent
--- runs start at the newly selected candidate rather than retrying known-bad
--- code.
function M.revalidate(problem_id, lang, meta, cases, cb, status)
  resolve_source(problem_id, lang, meta, cases, function(candidate, rejected)
    local bad = {}
    for _, item in ipairs(rejected or {}) do
      if item.stage == "community" then bad[item.code] = true end
    end
    if type(meta.oracle_candidates) == "table"
      and type(meta.oracle_candidates.community) == "table" then
      meta.oracle_candidates.community = vim.tbl_filter(function(item)
        return not bad[item.code]
      end, meta.oracle_candidates.community)
    end
    cb({
      stage = candidate and candidate.stage or "expected",
      provider = candidate and candidate.provider or nil,
      id = candidate and candidate.id or nil,
      rejected = #vim.tbl_keys(bad),
    })
  end, status)
end

return M
