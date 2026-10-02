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
local function uncomment(src)
  return src:gsub("/%*.-%*/", ""):gsub("//[^\n]*", "")
end
local function params(text)
  local out, start, depth = {}, 1, 0
  for i = 1, #text + 1 do
    local c = text:sub(i, i)
    if c == "[" or c == "(" or c == "<" then depth = depth + 1
    elseif c == "]" or c == ")" or c == ">" then depth = depth - 1
    elseif (c == "," and depth == 0) or i == #text + 1 then
      local part = vim.trim(text:sub(start, i - 1))
      if part ~= "" then
        local external, name, typ = part:match("^([%w_]+)%s+([%w_]+)%s*:%s*(.+)$")
        if not typ then name, typ = part:match("^([%w_]+)%s*:%s*(.+)$"); external = name end
        if not typ then return nil, "cannot parse Swift parameter `" .. part .. "`" end
        local inout = typ:match("^inout%s+") ~= nil
        typ = clean(typ:gsub("^inout%s+", ""):gsub("%s*=.*$", ""))
        if not supported(typ) then return nil, "unsupported Swift parameter type `" .. typ .. "`" end
        out[#out + 1] = { external=external == "_" and "" or external, name=name, type=typ, inout=inout }
      end
      start = i + 1
    end
  end
  return out
end
local function methods(src)
  local out = {}
  for name, arguments, suffix in src:gmatch("func%s+([%w_]+)%s*%((.-)%)([^{}]*){") do
    local args, err = params(arguments)
    if not args then return nil, err end
    local ret = clean(suffix:match("%-%>%s*(.-)%s*$") or "Void")
    if ret ~= "Void" and ret ~= "()" and not supported(ret) then return nil, "unsupported Swift result type `" .. ret .. "`" end
    if ret == "()" then ret = "Void" end
    out[#out + 1] = { name=name, params=args, ret=ret }
  end
  return out
end
function M.parse_signature(starter)
  if type(starter) ~= "string" then return nil, "no Swift starter code to derive a signature from" end
  local src = uncomment(starter)
  local start = src:find("class%s+Solution") or src:find("struct%s+Solution")
  if not start then return nil, "Swift starter must define class or struct Solution" end
  local parsed, err = methods(src:sub(start))
  if not parsed then return nil, err end
  if not parsed[1] then return nil, "could not parse a Swift function signature" end
  parsed[1].kind = src:sub(start):match("^(%w+)")
  return parsed[1]
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
