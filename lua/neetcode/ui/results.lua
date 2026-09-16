local hl = require("neetcode.ui.highlight")

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
  pass = "NeetCodePass",
  pass_unordered = "NeetCodeWarn",
  fail = "NeetCodeFail",
  error = "NeetCodeFail",
  oracle_error = "NeetCodeWarn",
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
  hl.apply(buf, { { 1, 0, 40, "NeetCodeMuted" } })
end

--- Local run results (from the harness).
function M.render_run(buf, result)
  local lines, spans = {}, {}
  push(lines, spans, "")

  if not result.ok then
    if result.unsupported then
      push(lines, spans, "  Cannot run this problem locally", "NeetCodeWarn")
    else
      push(lines, spans, "  Local run failed", "NeetCodeFail")
    end
    push(lines, spans, "")
    for _, l in ipairs(vim.split(result.error or "unknown error", "\n", { plain = true })) do
      push(lines, spans, "    " .. l, "NeetCodeMuted")
    end
  else
    local ok = result.passed == result.total
    push(lines, spans,
      string.format("  %s  %d/%d test cases passed",
        ok and "✓" or "✗", result.passed, result.total),
      ok and "NeetCodePass" or "NeetCodeFail")
    push(lines, spans, "")

    for _, c in ipairs(result.cases) do
      local label = STATUS_LABEL[c.status] or c.status
      local group = STATUS_GROUP[c.status] or "NeetCodeMuted"
      local timing = c.elapsed_ms and string.format("  (%.1f ms)", c.elapsed_ms) or ""
      push(lines, spans,
        string.format("  %-6s Case %d%s", label, c.index + 1, timing), group)

      if c.status == "pass_unordered" then
        push(lines, spans, "         (matched, but element order differs)", "NeetCodeWarn")
      end

      if c.status ~= "pass" then
        block(lines, spans, "input", c.input, "NeetCodeMuted")
        block(lines, spans, "expected", c.expected, "NeetCodeMuted")
        block(lines, spans, "actual", c.actual, "NeetCodeFail")
        block(lines, spans, "error", c.error, "NeetCodeFail")
      end
      block(lines, spans, "stdout", c.stdout, "NeetCodeMuted")
      push(lines, spans, "")
    end

    if result.passed == result.total and result.total > 0 then
      push(lines, spans,
        "  These are the visible cases only — submit to run the hidden suite.",
        "NeetCodeMuted")
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
    accepted and "NeetCodePass" or "NeetCodeFail")
  push(lines, spans, "")

  local dist = data.distribution or {}
  local time_pct = dist.timeDistribution and dist.timeDistribution.percentile
  local mem_pct = dist.memoryDistribution and dist.memoryDistribution.percentile

  if data.time then
    local ms = tonumber(data.time)
    local runtime = ms and string.format("%.0f ms", ms * 1000) or (tostring(data.time) .. "s")
    local beats = time_pct and string.format("  (Beats %.1f%%)", time_pct) or ""
    push(lines, spans, string.format("      runtime   %s%s", runtime, beats), "NeetCodeMuted")
  end
  if data.memory then
    local kb = tonumber(data.memory)
    local memory = kb and string.format("%.1f MB", kb / 1024) or tostring(data.memory)
    local beats = mem_pct and string.format("  (Beats %.1f%%)", mem_pct) or ""
    push(lines, spans, string.format("      memory    %s%s", memory, beats), "NeetCodeMuted")
  end

  if data.compile_output and data.compile_output ~= vim.NIL and data.compile_output ~= "" then
    push(lines, spans, "")
    block(lines, spans, "compile", data.compile_output, "NeetCodeFail")
  end

  local failing = data.last_executed_test_case
  if not accepted and type(failing) == "table" then
    push(lines, spans, "")
    push(lines, spans, string.format("  First failing case (#%d)",
      (failing.test_case_index or 0) + 1), "NeetCodeFail")
    block(lines, spans, "input", failing.input, "NeetCodeMuted")
    block(lines, spans, "expected", failing.expected_output, "NeetCodeMuted")
    block(lines, spans, "actual", failing.user_output, "NeetCodeFail")
    block(lines, spans, "logs", failing.user_logs, "NeetCodeMuted")
    if type(failing.input) == "string" and vim.trim(failing.input) ~= "" then
      push(lines, spans, "  :NeetCode test-failed to add this input to local tests", "NeetCodeMuted")
    end
  end

  if data.stderr and data.stderr ~= vim.NIL and data.stderr ~= "" then
    push(lines, spans, "")
    block(lines, spans, "stderr", data.stderr, "NeetCodeFail")
  end

  local streak = data.streakUpdate
  if accepted and streak then
    push(lines, spans, "")
    push(lines, spans, string.format("  streak %d day%s (best %d)",
      streak.currentStreak or 0, (streak.currentStreak == 1) and "" or "s", streak.maxStreak or 0),
      "NeetCodeMuted")
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  hl.apply(buf, spans)
end

return M
