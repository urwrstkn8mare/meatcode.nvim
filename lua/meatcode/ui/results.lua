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
  no_oracle = "RAN",
}

local STATUS_GROUP = {
  pass = "MeatCodePass",
  pass_unordered = "MeatCodeWarn",
  fail = "MeatCodeFail",
  error = "MeatCodeFail",
  oracle_error = "MeatCodeWarn",
  no_oracle = "MeatCodeMuted",
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
  if result.oracle_stage then
    local source = result.oracle_stage == "expected" and "statement/learned answers"
      or ((result.oracle_provider and (result.oracle_provider .. " ")) or "")
        .. result.oracle_stage .. " solution"
    push(lines, spans, "  Oracle: " .. source, "MeatCodeMuted")
    push(lines, spans, "")
  end

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
    local unjudged = result.unjudged or 0
    push(lines, spans,
      string.format("  %s  %d/%d test cases passed",
        ok and "✓" or "✗", result.passed, result.total),
      ok and "MeatCodePass" or "MeatCodeFail")
    if unjudged > 0 then
      push(lines, spans,
        string.format("     %d case(s) ran unjudged — expected output is N/A",
          unjudged),
        "MeatCodeMuted")
    end
    push(lines, spans, "")

    for _, c in ipairs(result.cases) do
      local label = STATUS_LABEL[c.status] or c.status
      local group = STATUS_GROUP[c.status] or "MeatCodeMuted"
      local timing = c.elapsed_ms and string.format("  (%.1f ms)", c.elapsed_ms) or ""
      push(lines, spans,
        string.format("  %-6s Case %d%s", label, c.index + 1, timing), group)

      if c.status == "pass_unordered" then
        push(lines, spans, "         (matched, but element order differs)", "MeatCodeWarn")
      elseif c.status == "no_oracle" then
        push(lines, spans, "         (expected: N/A — no known answer for this input)", "MeatCodeMuted")
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

--- Normalized cloud submission verdict from any provider adapter.
function M.render_submit(buf, data)
  local lines, spans = {}, {}
  push(lines, spans, "")

  local status = data.status or "Unknown"
  local accepted = data.accepted == true
  local passed = tonumber(data.passed) or 0
  local total = tonumber(data.total) or 0
  push(lines, spans,
    string.format("  %s  %s — %d/%d test cases", accepted and "✓" or "✗", status, passed, total),
    accepted and "MeatCodePass" or "MeatCodeFail")
  push(lines, spans, "")

  if data.runtime then
    local beats = data.runtime_percentile
      and string.format("  (Beats %.1f%%)", data.runtime_percentile) or ""
    push(lines, spans, string.format("      runtime   %s%s", tostring(data.runtime), beats), "MeatCodeMuted")
  end
  if data.memory then
    local beats = data.memory_percentile
      and string.format("  (Beats %.1f%%)", data.memory_percentile) or ""
    push(lines, spans, string.format("      memory    %s%s", tostring(data.memory), beats), "MeatCodeMuted")
  end

  if data.compile_output and data.compile_output ~= "" then
    push(lines, spans, "")
    block(lines, spans, "compile", data.compile_output, "MeatCodeFail")
  end
  if data.runtime_error and data.runtime_error ~= "" then
    push(lines, spans, "")
    block(lines, spans, "runtime", data.runtime_error, "MeatCodeFail")
  end
  if not accepted then
    push(lines, spans, "")
    block(lines, spans, "input", data.input, "MeatCodeMuted")
    block(lines, spans, "expected", data.expected, "MeatCodeMuted")
    block(lines, spans, "actual", data.actual, "MeatCodeFail")
    block(lines, spans, "stdout", data.stdout, "MeatCodeMuted")
    if type(data.failed_input) == "string" and vim.trim(data.failed_input) ~= "" then
      push(lines, spans, "  " .. config.options.keys.problem.test_failed
        .. " to add this input to local tests", "MeatCodeMuted")
    end
    if data.learned then
      push(lines, spans,
        "  Expected output cached for local runs.",
        "MeatCodeMuted")
    end
    if data.oracle_update then
      push(lines, spans, "  " .. data.oracle_update, "MeatCodeWarn")
    end
  end

  local streak = data.streak
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

return M
