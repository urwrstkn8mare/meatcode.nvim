--- Native Swift harness generation. Judge helpers stay outside submitted code.
local M = {}
local scalar = {
  Int=true, Int8=true, Int16=true, Int32=true, Int64=true,
  UInt=true, UInt8=true, UInt16=true, UInt32=true, UInt64=true,
  Double=true, Float=true, Bool=true, String=true, Character=true,
  ListNode=true, TreeNode=true,
}
local function clean(t) return (t:gsub("%s+", "")) end
local function supported(t)
  t = clean(t):gsub("%?+$", "")
  local inner = t:match("^%[(.*)%]$")
  return inner and supported(inner) or scalar[t] == true
end
--- Replace comments (including nested block comments) and string literals
--- (standard, multiline, raw #) with spaces, preserving newlines and 1-to-1 byte positions.
local function lexical_strip(src)
  if type(src) ~= "string" then return "" end
  local out = {}
  local i = 1
  local len = #src
  while i <= len do
    local ch = src:sub(i, i)
    local next_ch = src:sub(i + 1, i + 1)

    if ch == "/" and next_ch == "/" then
      while i <= len and src:sub(i, i) ~= "\n" do
        out[#out + 1] = " "
        i = i + 1
      end
      if i <= len and src:sub(i, i) == "\n" then
        out[#out + 1] = "\n"
        i = i + 1
      end
    elseif ch == "/" and next_ch == "*" then
      local depth = 1
      out[#out + 1] = " "
      out[#out + 1] = " "
      i = i + 2
      while i <= len and depth > 0 do
        if src:sub(i, i + 1) == "/*" then
          depth = depth + 1
          out[#out + 1] = " "
          out[#out + 1] = " "
          i = i + 2
        elseif src:sub(i, i + 1) == "*/" then
          depth = depth - 1
          out[#out + 1] = " "
          out[#out + 1] = " "
          i = i + 2
        else
          local c = src:sub(i, i)
          out[#out + 1] = (c == "\n" and "\n" or " ")
          i = i + 1
        end
      end
    else
      local hashes = src:match("^(#*)", i)
      local hash_len = #hashes
      local after_hashes = src:sub(i + hash_len, i + hash_len)
      if after_hashes == '"' then
        local is_multiline = src:sub(i + hash_len, i + hash_len + 2) == '"""'
        local quote_len = is_multiline and 3 or 1
        local close_delim = (is_multiline and '"""' or '"') .. hashes
        local delim_len = hash_len + quote_len
        for _ = 1, delim_len do
          out[#out + 1] = " "
        end
        i = i + delim_len
        while i <= len do
          if hash_len == 0 and not is_multiline and src:sub(i, i) == "\n" then
            out[#out + 1] = "\n"
            i = i + 1
            break
          end
          if src:sub(i, i) == "\\" then
            local esc_hashes = src:match("^(#*)", i + 1)
            if #esc_hashes == hash_len then
              local esc_total = 1 + hash_len + 1
              for _ = 1, math.min(esc_total, len - i + 1) do
                local c = src:sub(i, i)
                out[#out + 1] = (c == "\n" and "\n" or " ")
                i = i + 1
              end
            else
              local c = src:sub(i, i)
              out[#out + 1] = (c == "\n" and "\n" or " ")
              i = i + 1
            end
          elseif src:sub(i, i + #close_delim - 1) == close_delim then
            for _ = 1, #close_delim do
              out[#out + 1] = " "
            end
            i = i + #close_delim
            break
          else
            local c = src:sub(i, i)
            out[#out + 1] = (c == "\n" and "\n" or " ")
            i = i + 1
          end
        end
      else
        out[#out + 1] = ch
        i = i + 1
      end
    end
  end
  return table.concat(out)
end
local function uncomment(src)
  return lexical_strip(src)
end
local function params(text, unrestricted)
  local out, start, depth = {}, 1, 0
  for i = 1, #text + 1 do
    local c = text:sub(i, i)
    if c == "[" or c == "(" or c == "<" then depth = depth + 1
    elseif c == "]" or c == ")" or (c == ">" and text:sub(i - 1, i - 1) ~= "-") then depth = depth - 1
    elseif (c == "," and depth == 0) or i == #text + 1 then
      local part = vim.trim(text:sub(start, i - 1))
      if part ~= "" then
        local external, name, typ = part:match("^([%w_]+)%s+([%w_]+)%s*:%s*(.+)$")
        if not typ then name, typ = part:match("^([%w_]+)%s*:%s*(.+)$"); external = name end
        if not typ then return nil, "cannot parse Swift parameter `" .. part .. "`" end
        local inout = typ:match("^inout%s+") ~= nil
        typ = clean(typ:gsub("^inout%s+", ""):gsub("%s*=.*$", ""))
        if not unrestricted and not supported(typ) then return nil, "unsupported Swift parameter type `" .. typ .. "`" end
        out[#out + 1] = { external=external == "_" and "" or external, name=name, type=typ, inout=inout }
      end
      start = i + 1
    end
  end
  return out
end
local function methods(src, unrestricted)
  local out = {}
  for name, arguments, suffix in src:gmatch("func%s+([%w_]+)%s*%((.-)%)([^{}]*){") do
    local args, err = params(arguments, unrestricted)
    if not args then return nil, err end
    local ret = clean(suffix:match("%-%>%s*(.-)%s*$") or "Void")
    if ret ~= "Void" and ret ~= "()" and not unrestricted and not supported(ret) then return nil, "unsupported Swift result type `" .. ret .. "`" end
    if ret == "()" then ret = "Void" end
    out[#out + 1] = { name=name, params=args, ret=ret }
  end
  return out
end
local function find_solution_blocks(stripped)
  local blocks, p, depth = {}, 1, 0
  while p <= #stripped do
    local _, finish, kind = stripped:find("^([%a]+)%s+Solution%f[%W]", p)
    if depth == 0 and (kind == "class" or kind == "struct" or kind == "extension") then
      local brace = stripped:find("{", finish + 1, true)
      if not brace then break end
      local closing, nested = brace + 1, 1
      while closing <= #stripped and nested > 0 do
        local ch = stripped:sub(closing, closing)
        if ch == "{" then nested = nested + 1
        elseif ch == "}" then nested = nested - 1 end
        closing = closing + 1
      end
      if nested ~= 0 then break end
      blocks[#blocks + 1] = { kind = kind, body_start = brace + 1, body_end = closing - 2 }
      p = closing
    else
      local ch = stripped:sub(p, p)
      if ch == "{" then depth = depth + 1
      elseif ch == "}" then depth = depth - 1 end
      p = p + 1
    end
  end
  return blocks
end
local function scan_block_methods(stripped, block)
  local depth = 1
  local i = block.body_start
  local last_boundary = block.body_start
  local out = {}
  while i <= block.body_end do
    local c = stripped:sub(i, i)
    if c == "{" then
      depth = depth + 1
      i = i + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 1 then last_boundary = i + 1 end
      i = i + 1
    elseif (c == ";" or c == "\n") and depth == 1 then
      last_boundary = i + 1
      i = i + 1
    elseif depth == 1 and stripped:find("^func%f[%W]", i) then
      local prefix = stripped:sub(last_boundary, i - 1)
      local is_mutating = prefix:match("%f[%w]mutating%f[%W]") ~= nil
      local is_static = (prefix:match("%f[%w]static%f[%W]") ~= nil) or (prefix:match("%f[%w]class%f[%W]") ~= nil)
      local name_start = i + 4
      local name = stripped:match("^%s*([%w_]+)", name_start)
      if name then
        local name_find = stripped:find(name, name_start, true)
        local after_name_pos = name_find and (name_find + #name) or (name_start + #name)
        local rest = stripped:sub(after_name_pos)
        local has_generic = rest:match("^%s*<") ~= nil
        local param_open_pos
        if has_generic then
          local g_depth = 0
          local idx = stripped:find("<", after_name_pos, true)
          while idx and idx <= block.body_end do
            local ch = stripped:sub(idx, idx)
            if ch == "<" then g_depth = g_depth + 1
            elseif ch == ">" then
              g_depth = g_depth - 1
              if g_depth == 0 then
                param_open_pos = stripped:find("%(", idx + 1)
                break
              end
            end
            idx = idx + 1
          end
        else
          param_open_pos = stripped:find("%(", after_name_pos)
        end

        if param_open_pos and param_open_pos <= block.body_end then
          local raw_params = stripped:match("^%b()", param_open_pos)
          if raw_params then
            local after_params_pos = param_open_pos + #raw_params
            local brace_pos = stripped:find("{", after_params_pos, true)
            if brace_pos and brace_pos <= block.body_end + 1 then
              local raw_suffix = vim.trim(stripped:sub(after_params_pos, brace_pos - 1))
              local is_async = raw_suffix:match("%f[%w]async%f[%W]") ~= nil
              local is_throwing = (raw_suffix:match("%f[%w]throws%f[%W]") ~= nil)
                or (raw_suffix:match("%f[%w]rethrows%f[%W]") ~= nil)

              out[#out + 1] = {
                name = name,
                mutating = is_mutating,
                static = is_static,
                is_generic = has_generic,
                is_async = is_async,
                is_throwing = is_throwing,
                raw_params = raw_params,
                raw_suffix = raw_suffix,
                kind = block.kind,
              }
              depth = 2
              i = brace_pos + 1
            else
              i = i + 1
            end
          else
            i = i + 1
          end
        else
          i = i + 1
        end
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return out
end
local function extract_solution_methods(code, unrestricted)
  local stripped = lexical_strip(code or "")
  local blocks = find_solution_blocks(stripped)
  local all_methods = {}
  for _, block in ipairs(blocks) do
    local block_methods = scan_block_methods(stripped, block)
    for _, m in ipairs(block_methods) do
      m.kind = block.kind
      local p_text = m.raw_params and m.raw_params:sub(2, -2) or ""
      local parsed_params = params(p_text, unrestricted)
      m.params = parsed_params
      local ret = clean(m.raw_suffix:match("%-%>%s*(.-)%s*$") or "Void")
      if ret == "()" then ret = "Void" end
      m.ret = ret
      all_methods[#all_methods + 1] = m
    end
  end
  return all_methods, blocks
end
local function has_solution_method(code, name, expected_params)
  local methods_list = extract_solution_methods(code, true)
  for _, m in ipairs(methods_list) do
    if m.name == name then
      if not expected_params then
        return true
      end
      if m.params and #m.params == #expected_params then
        local match = true
        for i = 1, #expected_params do
          local ep = expected_params[i]
          local mp = m.params[i]
          if mp.external ~= ep.external then
            match = false
            break
          end
          if ep.type and mp.type ~= ep.type then
            match = false
            break
          end
          if ep.inout ~= nil and mp.inout ~= ep.inout then
            match = false
            break
          end
        end
        if match then return true end
      end
    end
  end
  return false
end
local function parse_starter_signature(starter, unrestricted)
  if type(starter) ~= "string" or starter == "" then
    return nil, "no Swift starter code to derive a signature from"
  end
  local stripped = lexical_strip(starter)
  local blocks = find_solution_blocks(stripped)
  if #blocks == 0 then
    return nil, "Swift starter must define class or struct Solution"
  end
  local methods_list = scan_block_methods(stripped, blocks[1])
  if #methods_list == 0 then
    return nil, "could not parse a Swift function signature"
  end
  local m = methods_list[1]
  if m.is_generic then
    return nil, "unsupported generic Swift method signature"
  end
  if m.is_async then
    return nil, "unsupported async Swift method signature"
  end
  if m.is_throwing then
    return nil, "unsupported throwing Swift method signature"
  end
  if m.static then
    return nil, "unsupported static Swift method signature"
  end
  local p_text = m.raw_params and m.raw_params:sub(2, -2) or ""
  local parsed_params, err = params(p_text, unrestricted)
  if not parsed_params then return nil, err end

  local ret = clean(m.raw_suffix:match("%-%>%s*(.-)%s*$") or "Void")
  if ret == "()" then ret = "Void" end
  if not unrestricted and ret ~= "Void" and not supported(ret) then
    return nil, "unsupported Swift result type `" .. ret .. "`"
  end

  return {
    name = m.name,
    params = parsed_params,
    ret = ret,
    kind = blocks[1].kind,
    mutating = m.mutating,
    static = m.static,
    raw_params = m.raw_params,
    raw_suffix = m.raw_suffix,
  }
end
function M.parse_signature(starter)
  return parse_starter_signature(starter, false)
end
--- Bridge compatible provider entry points in the payload, never the buffer.
--- Appends an extension Solution that forwards calls to the original implementation.
function M.adapt_submission(code, starter, judge_starter)
  if type(code) ~= "string" then return nil, "no Swift solution code provided" end
  local target, err = parse_starter_signature(judge_starter, true)
  if not target then
    return nil, "could not read the judge's Swift signature: " .. tostring(err)
  end

  if has_solution_method(code, target.name, target.params) then
    return code
  end

  local source; source, err = parse_starter_signature(starter, true)
  if not source then
    return nil, "could not read the content provider's Swift signature: " .. tostring(err)
  end

  if source.name == target.name then
    local labels_match = (#source.params == #target.params)
    if labels_match then
      for i = 1, #target.params do
        if source.params[i].external ~= target.params[i].external then
          labels_match = false
          break
        end
      end
    end
    if labels_match then
      return code
    end
  end
  if #source.params ~= #target.params then
    return nil, "Swift entry-point signatures differ in parameter count; use the judge's starter"
  end

  if source.ret ~= target.ret then
    return nil, "Swift entry-point return types differ; use the judge's starter"
  end

  for i, sp in ipairs(source.params) do
    local tp = target.params[i]
    if sp.type ~= tp.type or sp.inout ~= tp.inout then
      return nil, "Swift entry-point parameter " .. i .. " differs between providers; use the judge's starter"
    end
  end

  local solution_kind = "class"
  local stripped_code = lexical_strip(code)
  local code_blocks = find_solution_blocks(stripped_code)
  local found_decl = false
  for _, b in ipairs(code_blocks) do
    if b.kind == "struct" then
      solution_kind = "struct"
      found_decl = true
      break
    elseif b.kind == "class" then
      solution_kind = "class"
      found_decl = true
      break
    end
  end
  if not found_decl then
    if target.kind == "struct" or (source and source.kind == "struct") then
      solution_kind = "struct"
    end
  end

  if solution_kind == "struct" and source.mutating and not target.mutating then
    return nil, "Swift entry-point mutability differs; use the judge's starter"
  end
  local implements_source = has_solution_method(code, source.name, source.params)
  if not implements_source then
    return nil, "Swift solution must implement `" .. source.name .. "` or `" .. target.name .. "`"
  end
  local call_args = {}
  for i, sp in ipairs(source.params) do
    local tp = target.params[i]
    local val = (sp.inout and "&" or "") .. tp.name
    if sp.external ~= "" then
      call_args[i] = sp.external .. ": " .. val
    else
      call_args[i] = val
    end
  end

  local call_expr = "self." .. source.name .. "(" .. table.concat(call_args, ", ") .. ")"
  local body_stmt
  if target.ret == "Void" then
    body_stmt = "        " .. call_expr
  else
    body_stmt = "        return " .. call_expr
  end

  local mut_prefix = ""
  if solution_kind == "struct" and (target.mutating or source.mutating) then
    mut_prefix = "mutating "
  end

  local raw_params = target.raw_params or "()"
  local raw_suffix = (target.raw_suffix and target.raw_suffix ~= "") and (" " .. target.raw_suffix) or ""

  local extension = "\n\nextension Solution {\n    "
    .. mut_prefix .. "func " .. target.name .. raw_params .. raw_suffix
    .. " {\n" .. body_stmt .. "\n    }\n}\n"

  return code .. extension
end
function M.parse_class(starter)
  local src = uncomment(starter or "")
  local name = src:match("class%s+([%w_]+)") or src:match("struct%s+([%w_]+)")
  if not name then return nil, "could not find a Swift class or struct" end
  local ctor, err = params(src:match("init%s*%((.-)%)") or "")
  if not ctor then return nil, err end
  local parsed; parsed, err = methods(src)
  if not parsed then return nil, err end
  return { name=name, kind=src:match("class%s+" .. name) and "class" or "struct", ctor=ctor, methods=parsed }
end
function M.class_spec(cls)
  local function flags(list)
    local out = {}
    for _, p in ipairs(list) do out[#out + 1] = p.type:sub(1,1) == "[" or p.type:find("Node",1,true) ~= nil end
    return out
  end
  local spec = { name=cls.name, ctor=flags(cls.ctor), methods={} }
  for _, method in ipairs(cls.methods) do spec.methods[method.name] = flags(method.params) end
  return spec
end
local function bind(list, input)
  local declarations, arguments = {}, {}
  declarations[#declarations + 1] = string.format('guard %s.count == %d else { throw mcError("wrong argument count") }', input, #list)
  for i, p in ipairs(list) do
    local name = "_arg" .. i
    local first = list[1] and list[1].type:gsub("%?$", "")
    local node = p.type:gsub("%?$", "")
    local decoder = i > 1 and node == first and (node == "TreeNode" or node == "ListNode")
      and string.format("mcNodeReference(%s[%d], %s.self, _arg1)", input, i-1, p.type)
      or string.format("mcDecode(%s[%d], %s.self)", input, i-1, p.type)
    declarations[#declarations + 1] = string.format("%s %s = try %s", p.inout and "var" or "let", name, decoder)
    arguments[#arguments + 1] = (p.external ~= "" and p.external .. ": " or "") .. (p.inout and "&" or "") .. name
  end
  return table.concat(declarations, "\n"), table.concat(arguments, ", ")
end
local function function_body(sig, module, roundtrip)
  local declarations, arguments = bind(sig.params, "args")
  local call = "object." .. sig.name .. "(" .. arguments .. ")"
  if roundtrip then call = "object.decode(" .. (roundtrip.external ~= "" and roundtrip.external .. ": " or "") .. call .. ")" end
  local invoke
  if sig.ret == "Void" and not roundtrip then
    invoke = call .. "\nreturn " .. (#sig.params > 0 and "try _arg1.toJSON()" or "NSNull()")
  else
    invoke = "return try " .. call .. ".toJSON()"
  end
  return declarations .. "\n" .. (sig.kind == "struct" and "var" or "let")
    .. " object = " .. module .. "." .. (sig.class or "Solution") .. "()\n" .. invoke
end
local function class_body(cls, module)
  local declarations, arguments = bind(cls.ctor, "ctorArgs")
  local lines = {
    'guard let ctor = operations.first, let name = ctor.first as? String, name == "' .. cls.name .. '" else { throw mcError("missing constructor") }',
    "let ctorArgs = Array(ctor.dropFirst())", declarations,
    (cls.kind == "struct" and "var" or "let") .. " object = " .. module .. "." .. cls.name .. "(" .. arguments .. ")",
    "var outputs: [Any] = [NSNull()]",
    "for operation in operations.dropFirst() {",
    'guard let name = operation.first as? String else { throw mcError("invalid operation") }',
    "let args = Array(operation.dropFirst())", "switch name {",
  }
  for _, method in ipairs(cls.methods) do
    local binding, args = bind(method.params, "args")
    lines[#lines + 1] = 'case "' .. method.name .. '":'
    lines[#lines + 1] = binding
    local call = "object." .. method.name .. "(" .. args .. ")"
    lines[#lines + 1] = method.ret == "Void" and call .. "\noutputs.append(NSNull())"
      or "outputs.append(try " .. call .. ".toJSON())"
  end
  lines[#lines + 1] = 'default: throw mcError("unknown operation: " + name)'
  lines[#lines + 1] = "}\n}\nreturn outputs"
  return table.concat(lines, "\n")
end
local MAIN = [=[
do {
    let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
    guard let cases = try mcRead(dir, "cases.json") as? [String] else { throw mcError("invalid cases.json") }
    __INPUTS__
    let shard = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 0 : 0
    let stride = CommandLine.arguments.count > 3 ? max(1, Int(CommandLine.arguments[3]) ?? 1) : 1
    var reports: [[String: Any]] = []
    for (index, block) in cases.enumerated() where index % stride == shard {
        fputs("CASE \(index)\n", stderr)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            __ARGUMENTS__
            let (actual, logs) = try mcCapture(dir) { try mcText(executeUser(input)) }
            __ORACLE__
            var row: [String: Any] = ["index": index, "input": block, "status": "no_oracle", "actual": actual,
                "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000]
            __EXPECTED__
            if !logs.isEmpty { row["stdout"] = logs }
            reports.append(row)
        } catch {
            reports.append(["index": index, "input": block, "status": "error", "error": error.localizedDescription])
        }
    }
    print(try mcText(["ok": true, "method": "swift", "cases": reports]))
} catch {
    print(try! mcText(["ok": false, "error": error.localizedDescription, "cases": []]))
}
]=]
local function source(code, ref, oracle, signature, body, design)
  local imports = {}
  local function wrap(text, name)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("^%s*import%s+[%w_.]+%s*$") then imports[line] = true else lines[#lines+1] = line end
    end
    return "enum " .. name .. " {\n" .. table.concat(lines,"\n") .. "\n}\n"
  end
  local user = wrap(code or "", "UserCode")
  local reference = oracle == "reference"
  if reference and not ref then return nil, "no Swift reference source" end
  local oracle_code = reference and wrap(ref,"OracleCode") or ""
  local this = debug.getinfo(1,"S").source:sub(2)
  local runtime = require("meatcode.util").read_file(vim.fs.dirname(this) .. "/harness/swift_runtime.swift")
  if not runtime then return nil, "missing Swift runtime -- reinstall meatcode.nvim" end
  local input_type = design and "[[Any]]" or "[Any]"
  local user_body = body(signature,"UserCode")
  local helpers = "func executeUser(_ " .. (design and "operations" or "args") .. ": " .. input_type .. ") throws -> Any {\n" .. user_body .. "\n}\n"
  if reference then helpers = helpers .. "func executeOracle(_ " .. (design and "operations" or "args") .. ": " .. input_type .. ") throws -> Any {\n" .. body(signature,"OracleCode") .. "\n}\n" end
  local main = MAIN:gsub("__INPUTS__", design
    and 'guard let inputs = try mcRead(dir, "ops.json") as? [[[Any]]] else { throw mcError("invalid ops.json") }'
    or 'guard let inputs = try mcRead(dir, "arguments.json") as? [[String]] else { throw mcError("invalid arguments.json") }')
    :gsub("__ARGUMENTS__", design and "let input = inputs[index]"
      or "let input = try inputs[index].map { try JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }")
    :gsub("__ORACLE__", reference and "let (expected, _) = try mcCapture(dir) { try mcText(executeOracle(input)) }" or "")
    :gsub("__EXPECTED__", reference and 'row["expected"] = expected' or "")
  local extra = vim.tbl_keys(imports); table.sort(extra)
  return runtime .. "\n" .. table.concat(extra,"\n") .. "\n" .. user .. oracle_code .. helpers .. main
end
function M.generate(starter, oracle, code, ref)
  local sig, err = M.parse_signature(starter)
  if not sig then return nil, err end
  return source(code,ref,oracle,sig,function_body,false)
end
function M.generate_class(starter, oracle, code, ref)
  local cls, err = M.parse_class(starter)
  if not cls then return nil, err end
  return source(code,ref,oracle,cls,class_body,true)
end
function M.generate_roundtrip(starter, oracle, code, ref)
  local cls, err = M.parse_class(starter)
  if not cls then return nil, err end
  local encode, decode
  for _, method in ipairs(cls.methods) do
    if method.name == "encode" or method.name == "serialize" then encode = method end
    if method.name == "decode" or method.name == "deserialize" then decode = method end
  end
  if not encode or not decode or #encode.params ~= 1 or #decode.params ~= 1 then return nil, "unsupported Swift codec signature" end
  encode.class = cls.name
  return source(code,ref,oracle,encode,function(sig,module)
    local body = function_body(sig,module,decode.params[1])
    return body:gsub("object.decode%(", "object." .. decode.name .. "(")
  end,false)
end
return M
