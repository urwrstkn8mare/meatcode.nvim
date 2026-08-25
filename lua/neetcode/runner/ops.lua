--- Normalises the test cases of "design" problems into an operation sequence.
---
--- Those problems ask you to implement a class, and their inputs come in two
--- shapes. The LeetCode shape puts method names and argument lists on separate
--- lines:
---
---     ["WordDictionary","addWord","search"]
---     [[],["day"],["day"]]
---
--- The NeetCode shape interleaves them on one line, and drops the wrapper list
--- whenever a call takes a single scalar:
---
---     ["MinStack", "push", 1, "push", 2, "getMin"]
---
--- The second shape is only decodable if you know each method's arity, which we
--- read out of the starter code. Both collapse to `[name, arg1, arg2, ...]`.
local M = {}

--- Take one call's arguments off the token stream.
---@param params boolean[] one entry per parameter: true when it is a list type
---@return table args, integer next_index
local function take(toks, i, params)
  local n = #params
  if n == 0 or toks[i] == nil then
    return {}, i
  end
  local tok = toks[i]

  if type(tok) ~= "table" then
    return { tok }, i + 1
  end

  if n == 1 then
    if not params[1] then
      -- Scalar parameter, so the list can only be a wrapper.
      return { tok[1] }, i + 1
    end
    -- List parameter: unwrap only when the payload is itself a list.
    if #tok == 1 and type(tok[1]) == "table" then
      return { tok[1] }, i + 1
    end
    return { tok }, i + 1
  end

  if #tok == n then
    return vim.list_slice(tok, 1, n), i + 1
  end
  return { tok }, i + 1
end

--- Turn one raw test case into `{ {name, arg...}, ... }`.
---@param raw string
---@param spec table {ctor = boolean[], methods = {[name] = boolean[]}}
---@return table|nil ops, string|nil err
function M.normalize(raw, spec)
  local lines = {}
  for line in tostring(raw):gmatch("[^\n]+") do
    if vim.trim(line) ~= "" then
      table.insert(lines, vim.trim(line))
    end
  end
  if #lines == 0 then
    return nil, "empty test case"
  end

  local ok, first = pcall(vim.json.decode, lines[1])
  if not ok or type(first) ~= "table" then
    return nil, "could not decode the operation list"
  end

  local ops = {}

  -- Two-line form: names on one line, argument lists on the next.
  if #lines >= 2 then
    local ok2, argsets = pcall(vim.json.decode, lines[2])
    if not ok2 or type(argsets) ~= "table" then
      return nil, "could not decode the argument list"
    end
    for idx, name in ipairs(first) do
      local op = { name }
      for _, a in ipairs(argsets[idx] or {}) do
        table.insert(op, a)
      end
      table.insert(ops, op)
    end
    return ops, nil
  end

  -- One-line form: walk it, using each method's arity to know where to stop.
  local ctor = { first[1] }
  local args, i = take(first, 2, spec.ctor)
  vim.list_extend(ctor, args)
  table.insert(ops, ctor)

  while i <= #first do
    local name = first[i]
    local params = type(name) == "string" and spec.methods[name] or nil
    if not params then
      return nil, string.format("unrecognised operation `%s` in the test case", tostring(name))
    end
    local op = { name }
    args, i = take(first, i + 1, params)
    vim.list_extend(op, args)
    table.insert(ops, op)
  end

  return ops, nil
end

--- JSON encoder that treats every table as an array. `vim.json.encode` renders
--- an empty table as `{}`, which both harnesses would read as an object.
local function encode(v)
  if v == nil or v == vim.NIL then
    return "null"
  end
  local t = type(v)
  if t == "boolean" then
    return tostring(v)
  end
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return string.format("%d", v)
    end
    return tostring(v)
  end
  if t == "string" then
    return vim.json.encode(v)
  end
  local parts = {}
  for idx = 1, #v do
    parts[idx] = encode(v[idx])
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

--- Encode every test case as its operation sequence.
---@return string|nil json, string|nil err
function M.encode_cases(cases, spec)
  local all = {}
  for _, raw in ipairs(cases) do
    local ops, err = M.normalize(raw, spec)
    if not ops then
      return nil, err
    end
    table.insert(all, ops)
  end
  return encode(all), nil
end

--- Split a parameter list on top-level commas only, so `Dict[str, int]` stays
--- in one piece.
local function split_params(s)
  local parts, depth, cur = {}, 0, {}
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "[" or c == "(" or c == "<" then
      depth = depth + 1
    elseif c == "]" or c == ")" or c == ">" then
      depth = depth - 1
    end
    if c == "," and depth == 0 then
      table.insert(parts, table.concat(cur))
      cur = {}
    else
      table.insert(cur, c)
    end
  end
  if #cur > 0 then
    table.insert(parts, table.concat(cur))
  end
  return parts
end

--- Read a class's arities out of Python starter code.
---@return table|nil spec, string|nil err
function M.python_spec(starter)
  if not starter or starter == "" then
    return nil, "no Python starter code to derive the class shape from"
  end
  local name = starter:match("class%s+([%w_]+)")
  if not name then
    return nil, "could not find a class in the starter code"
  end

  local spec = { name = name, ctor = {}, methods = {} }
  for method, params in starter:gmatch("def%s+([%w_]+)%s*%(([^%)]*)%)") do
    local flags = {}
    for _, part in ipairs(split_params(params)) do
      part = vim.trim(part)
      if part ~= "" and part ~= "self" then
        table.insert(flags, part:find("[Ll]ist") ~= nil)
      end
    end
    if method == "__init__" then
      spec.ctor = flags
    elseif not method:match("^_") then
      spec.methods[method] = flags
    end
  end
  return spec, nil
end

M.take = take
M.encode = encode

return M
