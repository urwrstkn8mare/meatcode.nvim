local util = require("meatcode.util")

--- Make sense of how a C++ test harness died. AddressSanitizer,
--- UndefinedBehaviorSanitizer, libc++'s hardening checks, assert() and the C++
--- runtime's terminate handler each describe a crash differently on stderr;
--- this reduces them to what went wrong, where in the solution, and the calls
--- that led there, plus the stdout the harness saved on the way out.
local M = {}

--- Solution sources compiled into the harness. Frames anywhere else belong to
--- the harness, the standard library or a sanitizer runtime.
local SOURCES = { ["user.cpp"] = true, ["ref.cpp"] = true }

--- Most of a crashed solution's stdout lives in `crash.log`; the panel shows
--- only what it printed last.
local STDOUT_LINES = 40

---@class meatcode.CrashFrame
---@field fn string|nil function name, without the harness namespace or parameters
---@field file string|nil source file name
---@field line integer|nil
---@field col integer|nil
---@field count integer|nil consecutive recursive calls folded into this frame

---@class meatcode.Crash
---@field what string one line: what went wrong
---@field at meatcode.CrashFrame|nil innermost frame in the solution
---@field callers meatcode.CrashFrame[] solution frames further out
---@field freed meatcode.CrashFrame|nil where the memory was freed
---@field allocated meatcode.CrashFrame|nil where it was allocated
---@field stdout string|nil what the solution printed before it died

local function basename(path)
  return path:match("[^/]+$") or path
end

local function bytes(n)
  return tonumber(n) == 1 and "1 byte" or (n .. " bytes")
end

--- `usersol::Solution::dfs(TreeNode*, int) const` → `Solution::dfs`, and a
--- lambda's `Solution::f(int)::$_0::operator()(int) const` → `Solution::f::lambda`.
local function short_name(fn)
  fn = fn:gsub("^usersol::", ""):gsub("^refsol::", "")
  fn = fn:gsub("operator%(%)", "operator\1")
  fn = fn:gsub("%b()", "")
  fn = fn:gsub("::%$_%d+::operator\1", "::lambda"):gsub("::{lambda#?%d*}::operator\1", "::lambda")
  fn = fn:gsub("operator\1", "operator()")
  return vim.trim((fn:gsub("%s+const$", "")))
end

--- Addresses change from run to run and mean nothing to a reader.
local function without_addresses(text)
  text = text:gsub("%s*%[0x%x+,%s*0x%x+%)", "")
  text = text:gsub("%s*%(pc 0x%x+.-%)", "")
  text = text:gsub(" at pc 0x%x+.*$", "")
  text = text:gsub("0x%x+", "")
  return vim.trim((text:gsub("%s%s+", " ")))
end

--- A stack frame, symbolized or not:
--- `#3 0x1f in ns::f(int) /dir/user.cpp:29:41`, `#0 0x1f in abort+0x90 (libc.dylib:…)`.
local function parse_frame(text)
  local body = text:match("^%s*#%d+%s+0x%x+%s+in%s+(.-)%s*$")
  if not body then
    return nil
  end
  local fn, path, line, col = body:match("^(.-)%s+(%S+):(%d+):(%d+)$")
  if not fn then
    fn, path, line = body:match("^(.-)%s+(%S+):(%d+)$")
  end
  if not fn then
    return { fn = body }
  end
  return { fn = short_name(fn), file = basename(path), line = tonumber(line), col = tonumber(col) }
end

--- Where a bad access landed relative to the memory it was near.
local function landing(line)
  local n, rel, size = line:match("is located (%d+) bytes (%a+) (%d+)%-byte region")
  if n then
    return string.format("%s %s a %s-byte block", bytes(n), rel == "after" and "past the end of" or rel, size)
  end
  n, size = line:match("is located (%d+) bytes inside of (%d+)%-byte region")
  if n then
    return string.format("%s into a %s-byte block", bytes(n), size)
  end
  local name
  n, rel, name = line:match("is located (%d+) bytes (.-) global variable '(.-)'")
  if n then
    return string.format("%s %s global '%s'", bytes(n), rel == "after" and "past the end of" or rel, name)
  end
  local var, verb = line:match("%) '(.-)'.-<== Memory access at offset %d+ (.-) this variable")
  if var then
    return verb .. " local '" .. var .. "'"
  end
end

--- AddressSanitizer names a deadly signal by its short name.
local SIGNALS = {
  SEGV = "invalid memory access (segmentation fault)",
  BUS = "invalid or misaligned memory access (bus error)",
  FPE = "arithmetic exception, such as integer division by zero",
  ILL = "a runtime check failed (illegal instruction)",
  TRAP = "a runtime check failed (trap)",
  ABRT = "the program aborted",
  ["stack-overflow"] = "stack overflow: recursion too deep or never ending",
  ["attempting double-free"] = "double free",
  ["attempting free"] = "free of memory that was never allocated",
}

local function describe_asan(found)
  local head = found.asan:gsub(" on %a* ?address.*$", ""):gsub(" on 0x%x+.*$", "")
  head = without_addresses(head)
  if head == "SEGV" and found.zero_page then
    return "null pointer dereference" .. (found.signal_access and (" (" .. found.signal_access .. ")") or "")
  end
  if SIGNALS[head] then
    return SIGNALS[head]
  end
  local detail = {}
  if found.access then
    table.insert(detail, found.access)
  end
  if found.landing then
    table.insert(detail, found.landing)
  end
  return #detail > 0 and (head .. ": " .. table.concat(detail, ", ")) or head
end

--- Split off the stdout the harness saved (`CRASH STDOUT <shown> <total>`).
local function take_stdout(stderr)
  local s, e, shown, total = stderr:find("\nCRASH STDOUT (%d+) (%d+)\n")
  if not s then
    return stderr, nil
  end
  shown, total = tonumber(shown), tonumber(total)
  local out = stderr:sub(e + 1, e + shown)
  if total > shown then
    out = string.format("… (the last %d of %d bytes)\n", shown, total) .. out
  end
  return stderr:sub(1, s) .. stderr:sub(e + shown + 1), out ~= "" and out or nil
end

--- Consecutive frames in one function are a recursion: fold them together.
local function fold(frames)
  local folded = {}
  for _, f in ipairs(frames) do
    local prev = folded[#folded]
    if prev and prev.fn == f.fn and prev.file == f.file then
      prev.count = (prev.count or 1) + 1
    else
      table.insert(folded, { fn = f.fn, file = f.file, line = f.line, col = f.col })
    end
  end
  return folded
end

local function first_own(frames)
  for _, f in ipairs(frames or {}) do
    if f.file and SOURCES[f.file] then
      return f
    end
  end
end

--- Read a crash out of a harness's stderr; nil when it holds no report this
--- understands (a bare signal, a timeout, an ordinary error message).
---@param stderr string
---@return meatcode.Crash|nil
function M.parse(stderr)
  local text, stdout = take_stdout(stderr or "")
  local found, stacks, section, ub_at = {}, {}, nil, nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local frame = parse_frame(line)
    if frame then
      if section then
        stacks[section] = stacks[section] or {}
        table.insert(stacks[section], frame)
      end
    elseif line:find("ERROR: AddressSanitizer: ", 1, true) then
      found.asan = found.asan or line:match("ERROR: AddressSanitizer: (.+)$")
      section = stacks.main and "later" or "main"
    elseif line:find(": runtime error: ", 1, true) then
      local path, l, c, msg = line:match("^(.-):(%d+):(%d+): runtime error: (.+)$")
      if msg and not found.ub then
        found.ub = without_addresses(msg)
        ub_at = { file = basename(path), line = tonumber(l), col = tonumber(c) }
        section = stacks.main and "later" or "main"
      end
    elseif line:find("freed by thread", 1, true) then
      section = "freed"
    elseif line:find("allocated by thread", 1, true) then
      section = "allocated"
    elseif line:find("is located in stack of thread", 1, true) or line:find("^SUMMARY: ") then
      section = nil
    else
      found.check = found.check or line:match("libc%+%+ Hardening assertion .- failed: (.+)$")
      found.exception = found.exception or line:match("terminating due to uncaught exception of type (.+)$")
      found.thrown = found.thrown or line:match("terminate called after throwing an instance of '(.-)'")
      found.reason = found.reason or line:match("^%s*what%(%):%s*(.-)%s*$")
      found.assertion = found.assertion
        or line:match("^Assertion failed: %((.*)%), function ")
        or line:match("Assertion `(.*)' failed%.$")
      local kind, size = line:match("^(%u+) of size (%d+) at ")
      if kind and not found.access then
        found.access = kind:lower() .. " of " .. bytes(size)
      end
      found.landing = found.landing or landing(line)
      found.signal_access = found.signal_access or line:match("caused by a (%u+) memory access")
      if found.signal_access then
        found.signal_access = found.signal_access:lower()
      end
      found.zero_page = found.zero_page or line:find("address points to the zero page", 1, true) ~= nil
    end
  end

  local what = found.check
    or (found.exception and ("uncaught exception " .. found.exception))
    or (found.thrown and ("uncaught exception " .. found.thrown .. (found.reason and (": " .. found.reason) or "")))
    or (found.assertion and ("assertion failed: " .. found.assertion))
    or found.ub
    or (found.asan and describe_asan(found))
  if not what then
    return nil
  end

  local own = {}
  for _, f in ipairs(stacks.main or {}) do
    if f.file and SOURCES[f.file] then
      table.insert(own, f)
    end
  end
  local callers = fold(own)
  local at = table.remove(callers, 1)
  if ub_at and SOURCES[ub_at.file] then
    -- UndefinedBehaviorSanitizer knows the exact column.
    at = at or {}
    at.file, at.line, at.col = ub_at.file, ub_at.line, ub_at.col
  end

  return {
    what = what,
    at = at,
    callers = callers,
    freed = first_own(stacks.freed),
    allocated = first_own(stacks.allocated),
    stdout = stdout,
  }
end

--- `line 29 in Solution::longestPalindrome`.
local function place(frame)
  local where = (frame.file == "ref.cpp" and "reference line " or "line ") .. tostring(frame.line)
  if frame.col then
    where = where .. ", column " .. frame.col
  end
  if frame.fn then
    where = where .. " in " .. frame.fn
  end
  if frame.count then
    -- Sanitizers print at most about 255 frames, so a long run is a lower bound.
    where = where .. string.format(" (%d%s nested calls)", frame.count, frame.count >= 250 and "+" or "")
  end
  return where
end

--- The frame's source line, with a caret under the column when it is known.
local function excerpt(frame, source)
  local code = frame.line and source(frame.file)[frame.line]
  if not code or vim.trim(code) == "" then
    return nil
  end
  local indent = #code:match("^%s*")
  local gutter = tostring(frame.line)
  local rows = { gutter .. " │ " .. code:sub(indent + 1) }
  if frame.col and frame.col > indent then
    table.insert(rows, string.rep(" ", #gutter) .. " │ " .. string.rep(" ", frame.col - indent - 1) .. "^")
  end
  return table.concat(rows, "\n")
end

--- A one-line account for logs and oracle rejection reasons.
---@param crash meatcode.Crash
function M.summary(crash)
  return crash.at and crash.at.line and (crash.what .. " (" .. place(crash.at) .. ")") or crash.what
end

--- Display blocks for the results panel: where it crashed (with the source
--- line from `dir`), the solution calls that led there, where the memory
--- involved was freed and allocated, and the tail of the solution's stdout.
---@param crash meatcode.Crash
---@param dir string scratch directory holding user.cpp / ref.cpp
---@return table<string, string>
function M.describe(crash, dir)
  local sources = {}
  local function source(file)
    if not sources[file] then
      sources[file] = vim.split(util.read_file(dir .. "/" .. file) or "", "\n", { plain = true })
    end
    return sources[file]
  end
  local function located(frame)
    if not frame or not frame.line then
      return nil
    end
    local code = excerpt(frame, source)
    return place(frame) .. (code and ("\n" .. code) or "")
  end

  local blocks = {
    at = located(crash.at),
    freed = located(crash.freed),
    allocated = located(crash.allocated),
  }
  local callers = {}
  for i, frame in ipairs(crash.callers) do
    if i > 5 then
      table.insert(callers, "…")
      break
    end
    table.insert(callers, place(frame))
  end
  blocks.callers = #callers > 0 and table.concat(callers, "\n") or nil

  if crash.stdout then
    local rows = vim.split(crash.stdout:gsub("\n$", ""), "\n", { plain = true })
    if #rows > STDOUT_LINES then
      local hidden = #rows - STDOUT_LINES
      rows = vim.list_slice(rows, hidden + 1)
      table.insert(rows, 1, string.format("… %d earlier lines", hidden))
    end
    blocks.stdout = table.concat(rows, "\n")
  end
  return blocks
end

return M
