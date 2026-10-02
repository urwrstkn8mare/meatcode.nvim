local cpp = require("meatcode.runner.cpp")
local ops = require("meatcode.runner.ops")

--- Rewrites a local test case into the input format a judge's test endpoint
--- expects. The local suite mixes shapes: NeetCode labels every argument
--- (`nums=[1,2]`), LeetCode and LintCode hand out bare values one per line, and
--- design problems are either LeetCode's two lines (method names, argument
--- lists) or NeetCode's single interleaved line. The harnesses bind all of
--- these positionally, so the values themselves never change here — only the
--- labelling and, for design problems, the layout.
local M = {}

--- Split an argument line into its label and value. Only an identifier counts
--- as a label, the same rule both harnesses apply.
---@return string|nil name, string value
local function split_label(line)
  local name, value = line:match("^%s*([%a_][%w_]*)%s*=(.*)$")
  if name then return name, vim.trim(value) end
  return nil, vim.trim(line)
end

local function lines_of(block)
  local out = {}
  for line in (tostring(block) .. "\n"):gmatch("([^\n]*)\n") do
    line = vim.trim(line)
    if line ~= "" then table.insert(out, line) end
  end
  return out
end

--- Split one argument line on commas that sit outside brackets and quotes.
--- `root=[5,3,8], p=3` is three arguments; `nums=[1,2]` stays one value.
local function split_values(line)
  local _, value = split_label(line)
  local parts, buf, depth, quote = {}, {}, 0, nil
  local i = 1
  while i <= #value do
    local c = value:sub(i, i)
    if quote then
      buf[#buf + 1] = c
      if c == "\\" then
        local nxt = value:sub(i + 1, i + 1)
        if nxt ~= "" then buf[#buf + 1] = nxt; i = i + 1 end
      elseif c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
      buf[#buf + 1] = c
    elseif c == "[" or c == "{" or c == "(" then
      depth = depth + 1
      buf[#buf + 1] = c
    elseif c == "]" or c == "}" or c == ")" then
      depth = math.max(0, depth - 1)
      buf[#buf + 1] = c
    elseif c == "," and depth == 0 then
      local piece = vim.trim(table.concat(buf))
      local _, inner = split_label(piece)
      parts[#parts + 1] = inner
      buf = {}
    else
      buf[#buf + 1] = c
    end
    i = i + 1
  end
  local piece = vim.trim(table.concat(buf))
  if piece ~= "" or #parts > 0 then
    local _, inner = split_label(piece)
    parts[#parts + 1] = inner
  end
  return parts
end

--- The case's argument values in signature order, labels dropped.
---@param block string
---@return string[]
function M.values(block)
  local out = {}
  for _, line in ipairs(lines_of(block)) do
    vim.list_extend(out, split_values(line))
  end
  return out
end

--- Whether a case is a design problem's operation sequence (either layout)
--- rather than plain arguments, the same test `runner.run_selected` applies.
function M.is_operations(block)
  return tostring(block):match('^%s*%[%s*"') ~= nil
end

--- Argument labels a provider's own examples use, in order.
---@param cases string[]|nil
---@return string[]|nil
function M.labels(cases)
  for _, case in ipairs(type(cases) == "table" and cases or {}) do
    local names = {}
    for _, line in ipairs(lines_of(case)) do
      local name = split_label(line)
      if not name then
        names = nil
        break
      end
      table.insert(names, name)
    end
    if names and #names > 0 then return names end
  end
  return nil
end

--- Parameter names of the solution method in Python starter code, for when a
--- provider publishes no labelled example to copy them from.
---@return string[]|nil
function M.python_params(starter)
  for name, params in tostring(starter or ""):gmatch("def%s+([%w_]+)%s*%(([^%)]*)%)") do
    if not name:match("^_") then
      local out = {}
      for part in (params .. ","):gmatch("([^,]*),") do
        local param = vim.trim(part):match("^([%a_][%w_]*)")
        if param and param ~= "self" then table.insert(out, param) end
      end
      return out
    end
  end
  return nil
end

--- The case with every value labelled `name=value`.
---@return string|nil block, string|nil err
function M.labelled(block, names)
  local values = M.values(block)
  if #values ~= #names then
    return nil, string.format("case has %d argument(s) but the problem takes %d", #values, #names)
  end
  local out = {}
  for i, value in ipairs(values) do out[i] = names[i] .. "=" .. value end
  return table.concat(out, "\n"), nil
end

--- LeetCode's layout for a design case: method names on one line, each call's
--- argument list on the next.
---@return string|nil block, string|nil err
function M.leetcode_operations(block, spec)
  local operations, err = ops.normalize(block, spec)
  if not operations then return nil, err end
  local names, args = {}, {}
  for i, op in ipairs(operations) do
    names[i] = op[1]
    args[i] = vim.list_slice(op, 2)
  end
  return ops.encode(names) .. "\n" .. ops.encode(args), nil
end

--- One call's arguments as NeetCode's interleaved line spells them: nothing for
--- no arguments, the bare value for one, a wrapped list for several — the
--- inverse of `runner.ops`'s `take`.
local function interleave(out, args, params)
  if #args == 0 then return end
  if #args > 1 then
    table.insert(out, args)
    return
  end
  local value = args[1]
  -- A list argument whose only element is itself a list reads as a wrapper.
  local ambiguous = type(value) == "table" and #value == 1 and type(value[1]) == "table"
  table.insert(out, (ambiguous or (params and not params[1] and type(value) == "table")) and { value } or value)
end

--- NeetCode's layout for a design case: one line interleaving each method name
--- with its arguments.
---@return string|nil block, string|nil err
function M.neetcode_operations(block, spec)
  local operations, err = ops.normalize(block, spec)
  if not operations then return nil, err end
  local out = {}
  for i, op in ipairs(operations) do
    table.insert(out, op[1])
    local params = i == 1 and spec.ctor or spec.methods[op[1]]
    interleave(out, vim.list_slice(op, 2), params)
  end
  return ops.encode(out), nil
end

--- Arities of a design problem's class, from whichever starter the provider
--- shipped: `runner.ops` needs them to read NeetCode's interleaved layout.
---@return table|nil spec
function M.class_spec(meta)
  local starters = type(meta) == "table" and type(meta.starterCode) == "table" and meta.starterCode or {}
  if type(starters.python) == "string" and starters.python ~= "" then
    local spec = ops.python_spec(starters.python)
    if spec then return spec end
  end
  if type(starters.cpp) == "string" and starters.cpp ~= "" then
    local cls = cpp.parse_class(starters.cpp)
    if cls then return cpp.class_spec(cls) end
  end
  for _, lang in ipairs({ "swift", "rust" }) do
    if type(starters[lang]) == "string" and starters[lang] ~= "" then
      local generator = require("meatcode.runner." .. lang)
      local cls = generator.parse_class(starters[lang])
      if cls then return generator.class_spec(cls) end
    end
  end
  return nil
end

--- LintCode's own encodings for node arguments: `{1,2,#}` for a binary tree
--- and `1->2->null` for a linked list, where the local suite writes LeetCode's
--- `[1,2,null]`. Values already in LintCode's form pass through.
---@param values string[]
---@param types (string|nil)[] parameter types from the C++ starter, when known
function M.lintcode_values(values, types)
  local out = {}
  for i, value in ipairs(values) do
    local ptype = types[i]
    local ok, decoded = pcall(vim.json.decode, value)
    local list = ok and type(decoded) == "table" and decoded or nil
    if list and ptype == "TreeNode*" then
      local parts = {}
      for j, item in ipairs(list) do
        parts[j] = item == vim.NIL and "#" or ops.encode(item)
      end
      value = "{" .. table.concat(parts, ",") .. "}"
    elseif list and ptype == "ListNode*" then
      local parts = {}
      for j, item in ipairs(list) do parts[j] = ops.encode(item) end
      table.insert(parts, "null")
      value = table.concat(parts, "->")
    end
    out[i] = value
  end
  return out
end

return M
