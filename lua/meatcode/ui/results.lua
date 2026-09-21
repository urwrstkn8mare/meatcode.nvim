local config = require("meatcode.config")
local hl = require("meatcode.ui.highlight")

--- Renders local run results and cloud submission verdicts into a panel buffer.
local M = {}

local STATUS_LABEL = {
  pass = "PASS",
  pass_unordered = "PASS",
  fail = "FAIL",
  error = "ERROR",
  oracle_error = "ORACLE",
}

local STATUS_GROUP = {
  pass = "MeatCodePass",
  pass_unordered = "MeatCodeWarn",
  fail = "MeatCodeFail",
  error = "MeatCodeFail",
  oracle_error = "MeatCodeWarn",
}

local function push(lines, spans, text, group)
  table.insert(lines, text)
  if group then
    table.insert(spans, { #lines - 1, 0, #text, group })
  end
end

--- Indent a possibly multi-line blob for display.
local function block(lines, spans, label, value, group)
  if not value or value == "" then
    return
  end
  for i, l in ipairs(vim.split(value:gsub("%s+$", ""), "\n", { plain = true })) do
    push(lines, spans, string.format("      %-10s %s", i == 1 and label or "", l), group)
  end
end

function M.running(buf, what)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  " .. what .. "…", "" })
  vim.bo[buf].modifiable = false
  hl.apply(buf, { { 1, 0, 40, "MeatCodeMuted" } })
end

--- Local run results (from the harness).
function M.render_run(buf, result)
  local lines, spans = {}, {}
  push(lines, spans, "")

  if not result.ok then
    if result.unsupported then
      push(lines, spans, "  Cannot run this problem locally", "MeatCodeWarn")
    else
      push(lines, spans, "  Local run failed", "MeatCodeFail")
    end
    push(lines, spans, "")
    for _, l in ipairs(vim.split(result.error or "unknown error", "\n", { plain = true })) do
      push(lines, spans, "    " .. l, "MeatCodeMuted")
    end
  else
    local ok = result.passed == result.total
    push(lines, spans,
      string.format("  %s  %d/%d test cases passed",
        ok and "✓" or "✗", result.passed, result.total),
      ok and "MeatCodePass" or "MeatCodeFail")
    push(lines, spans, "")

    for _, c in ipairs(result.cases) do
      local label = STATUS_LABEL[c.status] or c.status
      local group = STATUS_GROUP[c.status] or "MeatCodeMuted"
      local timing = c.elapsed_ms and string.format("  (%.1f ms)", c.elapsed_ms) or ""
      push(lines, spans,
        string.format("  %-6s Case %d%s", label, c.index + 1, timing), group)

      if c.status == "pass_unordered" then
        push(lines, spans, "         (matched, but element order differs)", "MeatCodeWarn")
      end

      if c.status ~= "pass" then
        block(lines, spans, "input", c.input, "MeatCodeMuted")
        block(lines, spans, "expected", c.expected, "MeatCodeMuted")
        block(lines, spans, "actual", c.actual, "MeatCodeFail")
        block(lines, spans, "error", c.error, "MeatCodeFail")
      end
      block(lines, spans, "stdout", c.stdout, "MeatCodeMuted")
      push(lines, spans, "")
    end

    if result.passed == result.total and result.total > 0 then
      push(lines, spans,
        "  These are the visible cases only — submit to run the hidden suite.",
        "MeatCodeMuted")
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  hl.apply(buf, spans)
end

--- Cloud submission verdict.
function M.render_submit(buf, data)
  local lines, spans = {}, {}
  push(lines, spans, "")

  local status = (data.status and data.status.description) or "Unknown"
  local accepted = status == "Accepted"
  local passed = data.correct_test_case_count or 0
  local total = data.test_case_count or 0

  push(lines, spans,
    string.format("  %s  %s — %d/%d test cases", accepted and "✓" or "✗", status, passed, total),
    accepted and "MeatCodePass" or "MeatCodeFail")
  push(lines, spans, "")

  local dist = data.distribution or {}
  local time_pct = dist.timeDistribution and dist.timeDistribution.percentile
  local mem_pct = dist.memoryDistribution and dist.memoryDistribution.percentile

  if data.time then
    local ms = tonumber(data.time)
    local runtime = ms and string.format("%.0f ms", ms * 1000) or (tostring(data.time) .. "s")
    local beats = time_pct and string.format("  (Beats %.1f%%)", time_pct) or ""
    push(lines, spans, string.format("      runtime   %s%s", runtime, beats), "MeatCodeMuted")
  end
  if data.memory then
    local kb = tonumber(data.memory)
    local memory = kb and string.format("%.1f MB", kb / 1024) or tostring(data.memory)
    local beats = mem_pct and string.format("  (Beats %.1f%%)", mem_pct) or ""
    push(lines, spans, string.format("      memory    %s%s", memory, beats), "MeatCodeMuted")
  end

  if data.compile_output and data.compile_output ~= vim.NIL and data.compile_output ~= "" then
    push(lines, spans, "")
    block(lines, spans, "compile", data.compile_output, "MeatCodeFail")
  end

  local failing = data.last_executed_test_case
  if not accepted and type(failing) == "table" then
    push(lines, spans, "")
    push(lines, spans, string.format("  First failing case (#%d)",
      (failing.test_case_index or 0) + 1), "MeatCodeFail")
    block(lines, spans, "input", failing.input, "MeatCodeMuted")
    block(lines, spans, "expected", failing.expected_output, "MeatCodeMuted")
    block(lines, spans, "actual", failing.user_output, "MeatCodeFail")
    block(lines, spans, "logs", failing.user_logs, "MeatCodeMuted")
    if type(failing.input) == "string" and vim.trim(failing.input) ~= "" then
      push(lines, spans, "  " .. config.options.keys.problem.test_failed
        .. " to add this input to local tests", "MeatCodeMuted")
    end
  end

  if data.stderr and data.stderr ~= vim.NIL and data.stderr ~= "" then
    push(lines, spans, "")
    block(lines, spans, "stderr", data.stderr, "MeatCodeFail")
  end

  local streak = data.streakUpdate
  if accepted and streak then
    push(lines, spans, "")
    push(lines, spans, string.format("  streak %d day%s (best %d)",
      streak.currentStreak or 0, (streak.currentStreak == 1) and "" or "s", streak.maxStreak or 0),
      "MeatCodeMuted")
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  hl.apply(buf, spans)
end

--- LeetCode's submission-check response uses a different shape from NeetCode.
function M.render_leetcode_submit(buf, data)
  local lines, spans = {}, {}
  push(lines, spans, "")

  local status = data.status_msg or "Unknown"
  local accepted = data.status_code == 10 or status == "Accepted"
  local passed = tonumber(data.total_correct) or 0
  local total = tonumber(data.total_testcases) or 0
  push(lines, spans,
    string.format("  %s  %s — %d/%d test cases", accepted and "✓" or "✗", status, passed, total),
    accepted and "MeatCodePass" or "MeatCodeFail")
  push(lines, spans, "")

  if data.status_runtime then
    local beats = data.runtime_percentile
      and string.format("  (Beats %.1f%%)", tonumber(data.runtime_percentile) or 0) or ""
    push(lines, spans, string.format("      runtime   %s%s", data.status_runtime, beats), "MeatCodeMuted")
  end
  if data.status_memory then
    local beats = data.memory_percentile
      and string.format("  (Beats %.1f%%)", tonumber(data.memory_percentile) or 0) or ""
    push(lines, spans, string.format("      memory    %s%s", data.status_memory, beats), "MeatCodeMuted")
  end

  local compile = data.full_compile_error or data.compile_error
  local runtime = data.full_runtime_error or data.runtime_error
  if compile and compile ~= "" then
    push(lines, spans, "")
    block(lines, spans, "compile", compile, "MeatCodeFail")
  end
  if runtime and runtime ~= "" then
    push(lines, spans, "")
    block(lines, spans, "runtime", runtime, "MeatCodeFail")
  end
  if not accepted then
    push(lines, spans, "")
    block(lines, spans, "input", data.last_testcase or data.input, "MeatCodeMuted")
    block(lines, spans, "expected", data.expected_output, "MeatCodeMuted")
    block(lines, spans, "actual", data.code_output, "MeatCodeFail")
    block(lines, spans, "stdout", data.std_output, "MeatCodeMuted")
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  hl.apply(buf, spans)
end

return M
