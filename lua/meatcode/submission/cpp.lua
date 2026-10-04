--- C++ cross-provider submission entry-point adapter.
--- Preserves exact declared types, references, and user source code while
--- safely injecting a forwarding method into class Solution for compatible judges.
local M = {}

local KEYWORDS = {
  ["if"] = true,
  ["while"] = true,
  ["for"] = true,
  ["switch"] = true,
  ["return"] = true,
  ["catch"] = true,
}

--- Mask comments, regular strings, character literals, and raw strings with spaces.
--- Preserves exact character offsets and newlines so masked indices map 1:1 to source.
local function mask_code(code)
  local out = {}
  local i = 1
  local n = #code
  while i <= n do
    local c2 = code:sub(i, i + 1)
    if c2 == "//" then
      out[#out + 1] = "  "
      i = i + 2
      while i <= n do
        local ch = code:sub(i, i)
        if ch == "\n" then
          out[#out + 1] = "\n"
          i = i + 1
          break
        else
          out[#out + 1] = " "
          i = i + 1
        end
      end
    elseif c2 == "/*" then
      out[#out + 1] = "  "
      i = i + 2
      while i <= n do
        if code:sub(i, i + 1) == "*/" then
          out[#out + 1] = "  "
          i = i + 2
          break
        else
          local ch = code:sub(i, i)
          out[#out + 1] = (ch == "\n") and "\n" or " "
          i = i + 1
        end
      end
    elseif (code:sub(i, i) == "R" and code:sub(i + 1, i + 1) == '"')
      and (i == 1 or not code:sub(i - 1, i - 1):match("[%w_]")) then
      -- Raw string literal R"delim(...)delim"
      local paren = code:find("%(", i + 2)
      local delim = paren and code:sub(i + 2, paren - 1) or nil
      if paren and delim and #delim <= 16 and not delim:find("[%s%(%)%\\]") then
        local terminator = ")" .. delim .. '"'
        local term_pos = code:find(terminator, paren + 1, true)
        local end_pos = term_pos and (term_pos + #terminator - 1) or n
        for pos = i, end_pos do
          local ch = code:sub(pos, pos)
          out[#out + 1] = (ch == "\n") and "\n" or " "
        end
        i = end_pos + 1
      else
        out[#out + 1] = code:sub(i, i)
        i = i + 1
      end
    elseif code:sub(i, i) == '"' then
      -- Regular string literal
      out[#out + 1] = " "
      i = i + 1
      while i <= n do
        local ch = code:sub(i, i)
        if ch == "\\" and i + 1 <= n then
          out[#out + 1] = "  "
          i = i + 2
        elseif ch == '"' then
          out[#out + 1] = " "
          i = i + 1
          break
        else
          out[#out + 1] = (ch == "\n") and "\n" or " "
          i = i + 1
        end
      end
    elseif code:sub(i, i) == "'" then
      -- Character literal
      out[#out + 1] = " "
      i = i + 1
      while i <= n do
        local ch = code:sub(i, i)
        if ch == "\\" and i + 1 <= n then
          out[#out + 1] = "  "
          i = i + 2
        elseif ch == "'" then
          out[#out + 1] = " "
          i = i + 1
          break
        else
          out[#out + 1] = (ch == "\n") and "\n" or " "
          i = i + 1
        end
      end
    else
      out[#out + 1] = code:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Normalise a type for comparison: collapse whitespace, trim leading/trailing spaces,
--- normalize spacing around template brackets, commas, pointers, and references.
--- Keeps const, &, and * intact to preserve exact semantics.
local function clean_type(t)
  if not t then return "" end
  t = t:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  t = t:gsub("std::", "")
  t = t:gsub("%s*<%s*", "<"):gsub("%s*>%s*", ">"):gsub("%s*,%s*", ",")
  t = t:gsub("%s*%*%s*", "*"):gsub("%s*&%s*", "&")
  return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split a parameter list on top-level commas only, respecting nested <> and ().
local function split_top(s)
  local parts, depth, cur = {}, 0, {}
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "<" or c == "(" then
      depth = depth + 1
    elseif c == ">" or c == ")" then
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

--- Find the position of `class Solution` or `struct Solution`.
local function find_solution_class(masked)
  local patterns = {
    "[%s;{}%(]class%s+Solution%f[%W]",
    "^%s*class%s+Solution%f[%W]",
    "[%s;{}%(]struct%s+Solution%f[%W]",
    "^%s*struct%s+Solution%f[%W]",
  }
  for _, pat in ipairs(patterns) do
    local s, e = masked:find(pat)
    if s then
      return s, e
    end
  end
  return nil, nil
end

--- Find the matching closing brace `}` for an opening brace at `open_brace`.
local function find_closing_brace(masked, open_brace)
  local depth = 1
  for pos = open_brace + 1, #masked do
    local ch = masked:sub(pos, pos)
    if ch == "{" then
      depth = depth + 1
    elseif ch == "}" then
      depth = depth - 1
      if depth == 0 then
        return pos
      end
    end
  end
  return nil
end

--- Determine whether `code` implements a Solution method named `name`.
--- Distinguishes actual Solution methods from decoys in comments, strings,
--- unrelated classes, and nested helper functions/classes.
local function has_solution_method(code, name)
  local masked = mask_code(code)
  local class_start, class_end = find_solution_class(masked)
  if class_start then
    local open_brace = masked:find("{", class_end)
    if open_brace then
      local close_brace = find_closing_brace(masked, open_brace)
      if close_brace then
        local depth = 1
        for pos = open_brace + 1, close_brace - 1 do
          local ch = masked:sub(pos, pos)
          if ch == "{" then
            depth = depth + 1
          elseif ch == "}" then
            depth = depth - 1
          elseif depth == 1 then
            if not masked:sub(pos - 1, pos - 1):match("[%w_]") then
              if masked:sub(pos):find("^" .. name .. "%f[%W]%s*%(") then
                return true
              end
            end
          end
        end
      end
    end
  end

  -- Check out-of-class definition: Solution::name(...)
  if masked:find("[%s;{}]Solution%s*::%s*" .. name .. "%f[%W]%s*%(")
    or masked:find("^%s*Solution%s*::%s*" .. name .. "%f[%W]%s*%(") then
    return true
  end

  return false
end

--- Parse the public Solution entry-point method signature out of starter code.
local function parse_signature(starter)
  if type(starter) ~= "string" or starter == "" then
    return nil, "empty starter code"
  end

  local masked = mask_code(starter)
  local class_start, class_end = find_solution_class(masked)
  if not class_start then
    return nil, "could not find `class Solution` in starter code"
  end

  local open_brace = masked:find("{", class_end)
  if not open_brace then
    return nil, "could not find body of `class Solution` in starter code"
  end

  local close_brace = find_closing_brace(masked, open_brace)
  if not close_brace then
    return nil, "could not find closing brace of `class Solution` in starter code"
  end

  local masked_body = masked:sub(open_brace + 1, close_brace - 1)

  local search_start = 1
  local _, pub_end = masked_body:find("public%s*:")
  if pub_end then
    search_start = pub_end + 1
  end

  local sub_masked = masked_body:sub(search_start)

  -- Match: <return type> <name>(<parameters>) [{;]
  -- Using [^%(;]- to ensure we do not match across prior statements/semicolons.
  for ret, name, params_str in sub_masked:gmatch("([%w_][^%(;]-)%s+([%w_]+)%s*(%b())%s*[{;]") do
    if not KEYWORDS[name] then
      local clean_ret = ret:gsub("^%s*virtual%s+", ""):gsub("^%s*inline%s+", ""):gsub("^%s*static%s+", ""):gsub("^%s*explicit%s+", "")
      clean_ret = vim.trim(clean_ret)

      local inner_params = params_str:sub(2, -2)
      local params = {}
      for i, part in ipairs(split_top(inner_params)) do
        part = vim.trim(part)
        if part ~= "" and part ~= "void" then
          part = part:gsub("%s*=.*$", "")
          local ptype, pname = part:match("^(.-)([%w_]+)%s*$")
          if not pname or vim.trim(ptype) == "" then
            return nil, "unsupported C++ parameter declaration"
          end
          ptype = vim.trim(ptype)
          table.insert(params, {
            name = pname,
            type = clean_type(ptype),
            raw_type = ptype,
          })
        end
      end

      return {
        name = name,
        ret = clean_type(clean_ret),
        ret_raw = clean_ret,
        params = params,
      }, nil
    end
  end

  return nil, "could not parse method signature from starter code"
end

--- Inject a forwarding method into class Solution right before its closing brace.
local function inject_forwarding_method(code, source_name, target)
  local masked = mask_code(code)
  local class_start, class_end = find_solution_class(masked)
  if not class_start then
    return nil, "could not find `class Solution` in C++ source"
  end

  local open_brace = masked:find("{", class_end)
  if not open_brace then
    return nil, "could not find body of `class Solution` in C++ source"
  end

  local close_brace = find_closing_brace(masked, open_brace)
  if not close_brace then
    return nil, "could not find closing brace of `class Solution` in C++ source"
  end

  local param_decls = {}
  local call_args = {}
  for i, param in ipairs(target.params) do
    local pname = param.name ~= "" and param.name or ("_arg" .. i)
    table.insert(param_decls, param.raw_type .. " " .. pname)
    local argument = pname
    if not param.type:match("&$") or param.type:match("&&$") then
      argument = "static_cast<" .. param.raw_type .. "&&>(" .. pname .. ")"
    end
    table.insert(call_args, argument)
  end

  local call_stmt
  if target.ret == "void" then
    call_stmt = source_name .. "(" .. table.concat(call_args, ", ") .. ");"
  else
    call_stmt = "return " .. source_name .. "(" .. table.concat(call_args, ", ") .. ");"
  end

  local method_decl = string.format(
    "\npublic:\n    %s %s(%s) {\n        %s\n    }\n",
    target.ret_raw,
    target.name,
    table.concat(param_decls, ", "),
    call_stmt
  )

  local before = code:sub(1, close_brace - 1)
  local after = code:sub(close_brace)
  return before .. method_decl .. after
end

--- Bridge compatible provider entry points in the payload, never the buffer.
--- Preserves exact declared types/references, recursion, helper methods, comments,
--- and string literals.
---@param code string
---@param starter string
---@param judge_starter string
---@return string|nil payload, string|nil err
function M.adapt_submission(code, starter, judge_starter)
  local target, err = parse_signature(judge_starter)
  if not target then
    return nil, "could not read the judge's C++ signature: " .. (err or "unknown error")
  end

  if has_solution_method(code, target.name) then
    return code
  end

  local source; source, err = parse_signature(starter)
  if not source then
    return nil, "could not read the content provider's C++ signature: " .. (err or "unknown error")
  end

  if source.name == target.name then
    return code
  end

  if source.ret ~= target.ret or #source.params ~= #target.params then
    return nil, "C++ entry-point signatures differ beyond their names; use the judge's starter"
  end

  for i, param in ipairs(target.params) do
    local original = source.params[i]
    if param.type ~= original.type then
      return nil, "C++ entry-point parameter " .. i .. " differs between providers; use the judge's starter"
    end
  end

  if not has_solution_method(code, source.name) then
    return nil, "C++ solution must implement `" .. source.name .. "` or `" .. target.name .. "`"
  end

  return inject_forwarding_method(code, source.name, target)
end

return M
