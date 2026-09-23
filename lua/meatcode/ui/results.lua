local config = require("meatcode.config")
local hl = require("meatcode.ui.highlight")
local providers = require("meatcode.providers")
local runner = require("meatcode.runner")

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

--- True for a real, non-empty display value. `vim.json.decode` turns a
--- JSON `null` into the `vim.NIL` sentinel, which is truthy in Lua and
--- indistinguishable from a real value unless checked explicitly here;
--- provider adapters don't uniformly filter it out of passthrough fields
--- (compile/runtime errors, failing input/expected/actual/stdout), so this
--- is the one place all of that external data funnels through display.
local function has_text(value)
  return value ~= nil and value ~= vim.NIL and value ~= ""
end

--- Indent a possibly multi-line blob for display.
local function block(lines, spans, label, value, group)
  if not has_text(value) then
    return
  end
  for i, l in ipairs(vim.split(value:gsub("%s+$", ""), "\n", { plain = true })) do
    push(lines, spans, string.format("      %-10s %s", i == 1 and label or "", l), group)
  end
end

--- `block` for a judge's prose rather than program output: the results pane
--- does not wrap, so reflow the words to fit the window showing `buf`.
local function prose(lines, spans, buf, label, value, group)
  if not has_text(value) then
    return
  end
  local win = vim.fn.bufwinid(buf)
  -- `block` indents 17 columns; one more keeps text off the window edge.
  local width = math.max(20, (win ~= -1 and vim.api.nvim_win_get_width(win) or 80) - 18)
  local rows = {}
  for _, paragraph in ipairs(vim.split(value, "\n", { plain = true })) do
    local row = ""
    for word in paragraph:gmatch("%S+") do
      if row ~= "" and vim.fn.strdisplaywidth(row .. " " .. word) > width then
        table.insert(rows, row)
        row = word
      else
        row = row == "" and word or row .. " " .. word
      end
    end
    table.insert(rows, row)
  end
  block(lines, spans, label, table.concat(rows, "\n"), group)
end

local function show(buf, lines, spans)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  hl.apply(buf, spans)
end

function M.running(buf, what)
  show(buf, { "", "  " .. what .. "…", "" }, { { 1, 0, 40, "MeatCodeMuted" } })
end

--- Local run results (from the harness).
function M.render_run(buf, result)
  local lines, spans = {}, {}
  push(lines, spans, "")
  if result.oracle_stage then
    push(lines, spans, "  Oracle: " .. (runner.describe_result(result) or result.oracle_stage), "MeatCodeMuted")
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
    if (result.parallelism or 1) > 1 then
      push(lines, spans,
        string.format("     %d test workers ran cases in parallel", result.parallelism),
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

  show(buf, lines, spans)
end

--- Normalized cloud submission verdict from any provider adapter, tagged with
--- the `provider` name that judged it.
function M.render_submit(buf, data)
  local lines, spans = {}, {}
  push(lines, spans, "")

  local status = data.status or "Unknown"
  local accepted = data.accepted == true
  local passed = tonumber(data.passed) or 0
  local total = tonumber(data.total) or 0
  push(lines, spans,
    string.format("  %s  %s on %s — %d/%d test cases", accepted and "✓" or "✗", status,
      providers.get(data.provider).label, passed, total),
    accepted and "MeatCodePass" or "MeatCodeFail")
  push(lines, spans, "")
  prose(lines, spans, buf, "violation", data.restriction, "MeatCodeFail")

  if has_text(data.runtime) then
    local beats = data.runtime_percentile
      and string.format("  (Beats %.1f%%)", data.runtime_percentile) or ""
    push(lines, spans, string.format("      runtime   %s%s", tostring(data.runtime), beats), "MeatCodeMuted")
  end
  if has_text(data.memory) then
    local beats = data.memory_percentile
      and string.format("  (Beats %.1f%%)", data.memory_percentile) or ""
    push(lines, spans, string.format("      memory    %s%s", tostring(data.memory), beats), "MeatCodeMuted")
  end

  if has_text(data.compile_output) then
    push(lines, spans, "")
    block(lines, spans, "compile", data.compile_output, "MeatCodeFail")
  end
  if has_text(data.runtime_error) then
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

  show(buf, lines, spans)
end

--- A submission that ended without a verdict (auth, network or judge failure).
function M.render_submit_error(buf, provider, err)
  local lines, spans = {}, {}
  push(lines, spans, "")
  push(lines, spans, "  Submission to " .. providers.get(provider).label .. " failed", "MeatCodeFail")
  push(lines, spans, "")
  for _, l in ipairs(vim.split(err, "\n", { plain = true })) do
    push(lines, spans, "    " .. l, "MeatCodeMuted")
  end
  show(buf, lines, spans)
end

return M
