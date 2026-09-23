--- Editor-only convenience for Python solutions.
---
--- LeetCode/NeetCode/LintCode all ship Python starters that reference names
--- (`Optional`, `ListNode`, `TreeNode`, a problem-specific `Node`/`Interval`,
--- …) the judge injects into the execution namespace but never actually
--- defines in the file itself -- `lua/meatcode/runner/harness/python.py`
--- does the same for local runs (see its `base_namespace`/`extract_prelude`).
--- A language server sees none of that, so a perfectly valid solution lights
--- up with undefined-name diagnostics.
---
--- Unlike the C++ side (`.clangd` force-include, see `doc/cpp.md`), Pyright
--- and pylsp have no mechanism to declare a name in scope without it actually
--- being there. `M.seed` therefore inserts a real, clearly-marked block at
--- the top of the file; `M.strip` removes exactly that block before a local
--- run or a cloud submission, so neither ever sees anything beyond your
--- solution.
local M = {}

M.MARK_START = "# --- meatcode: auto-imports for your editor (stripped before running/submitting) ---"
M.MARK_END = "# --- meatcode: end auto-imports ---"

local TYPING_NAMES = {
  "Optional", "List", "Dict", "Tuple", "Set", "Union", "Any", "Deque",
  "DefaultDict", "Iterator", "Iterable", "Callable", "Sequence", "Mapping",
  "FrozenSet", "Counter", "OrderedDict",
}

--- Whole-word occurrence of `name` in `text`.
local function mentions(text, name)
  return text:find("%f[%w_]" .. name .. "%f[%W]") ~= nil
end

local function needs_typing(starter)
  for _, name in ipairs(TYPING_NAMES) do
    if mentions(starter, name) then return true end
  end
  return false
end

-- The same shapes `runner/harness/python.py`'s `base_namespace` hands every
-- local run, used only as a fallback when the starter carries no
-- problem-specific definition to lift (see `class_prelude` below).
local GENERIC_TYPES = {
  { name = "ListNode", def = table.concat({
    "class ListNode:",
    "    def __init__(self, val=0, next=None):",
    "        self.val = val",
    "        self.next = next",
  }, "\n") },
  { name = "TreeNode", def = table.concat({
    "class TreeNode:",
    "    def __init__(self, val=0, left=None, right=None):",
    "        self.val = val",
    "        self.left = left",
    "        self.right = right",
  }, "\n") },
}

--- Pull a helper-type definition out of a starter's own leading comment or
--- docstring -- the same "# class ListNode: ..." (LeetCode, NeetCode) or
--- `"""Definition of ListNode: class ListNode(object): ..."""` (LintCode)
--- text every provider already ships to document the type its judge injects.
--- A leading provider-private import (LintCode's `from lintcode import
--- (ListNode,)`, which does not exist outside its judge) is dropped rather
--- than kept, since it would fail to import here. Returns "" when nothing
--- recognizable precedes the solution class.
local function class_prelude(starter)
  local lines = vim.split(starter, "\n", { plain = true })
  local collected = {}
  local i, n = 1, #lines
  while i <= n do
    local raw = lines[i]
    local trimmed = vim.trim(raw)
    if trimmed == "" then
      table.insert(collected, "")
    elseif trimmed:sub(1, 1) == "#" then
      table.insert(collected, (raw:gsub("^%s*#%s?", "")))
    elseif trimmed:match('^"""') or trimmed:match("^'''") then
      local quote = trimmed:sub(1, 3)
      local rest = trimmed:sub(4)
      local close = rest:find(quote, 1, true)
      if close then
        table.insert(collected, rest:sub(1, close - 1))
      else
        i = i + 1
        while i <= n and vim.trim(lines[i]) ~= quote do
          table.insert(collected, lines[i])
          i = i + 1
        end
      end
    elseif trimmed:match("^from%s+%S+%s+import%s*%($") then
      i = i + 1
      while i <= n and vim.trim(lines[i]) ~= ")" do
        i = i + 1
      end
    elseif trimmed:match("^from%s+%S+%s+import%s") or trimmed:match("^import%s") then
      -- single-line provider-private import; drop it
    else
      break
    end
    i = i + 1
  end
  local start = nil
  for idx, line in ipairs(collected) do
    if line:match("^class%s+%w") then
      start = idx
      break
    end
  end
  if not start then return "" end
  return vim.trim(table.concat(collected, "\n", start, #collected))
end

--- `starter` with an auto-import block prepended when it looks like it needs
--- one -- unchanged otherwise (e.g. a problem with no typing annotations and
--- no custom types, like an int-only "A + B"). Idempotent: a starter that
--- already carries the block (e.g. `M.strip` was skipped somewhere) is
--- returned as-is.
function M.seed(starter)
  if starter:find(M.MARK_START, 1, true) then return starter end
  local extras = {}
  if needs_typing(starter) then table.insert(extras, "from typing import *") end
  local prelude = class_prelude(starter)
  if prelude ~= "" then
    table.insert(extras, prelude)
  else
    for _, t in ipairs(GENERIC_TYPES) do
      if mentions(starter, t.name) then table.insert(extras, t.def) end
    end
  end
  if #extras == 0 then return starter end
  local header = M.MARK_START .. "\n" .. table.concat(extras, "\n\n\n") .. "\n" .. M.MARK_END
  return header .. "\n\n" .. starter
end

--- The inverse of `M.seed`: drop the auto-import block, if present, before a
--- local run or a cloud submission. A no-op on code that never had one.
function M.strip(code)
  if not code:find(M.MARK_START, 1, true) then return code end
  local lines = vim.split(code, "\n", { plain = true })
  local s_idx, e_idx
  for idx, line in ipairs(lines) do
    if not s_idx and line == M.MARK_START then
      s_idx = idx
    elseif s_idx and line == M.MARK_END then
      e_idx = idx
      break
    end
  end
  if not (s_idx and e_idx) then return code end
  local out = {}
  for idx = 1, s_idx - 1 do table.insert(out, lines[idx]) end
  local after = e_idx + 1
  if lines[after] == "" then after = after + 1 end
  for idx = after, #lines do table.insert(out, lines[idx]) end
  return table.concat(out, "\n")
end

return M
