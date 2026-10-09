--- Generates a C++ test harness.
---
--- C++ has no reflection, so the method signature is parsed out of the problem's
--- starter code (which always declares exactly one method) and used to emit
--- typed local variables that marshal each JSON input into the right C++ type.
local M = {}

local SCALARS = {
  ["int"] = true, ["long"] = true, ["long long"] = true, ["unsigned"] = true,
  ["unsigned int"] = true, ["unsigned long"] = true, ["unsigned long long"] = true,
  ["uint32_t"] = true, ["uint64_t"] = true, ["int32_t"] = true, ["int64_t"] = true,
  ["size_t"] = true,
  ["double"] = true, ["float"] = true, ["bool"] = true, ["char"] = true,
  ["string"] = true, ["std::string"] = true,
  ["ListNode*"] = true, ["TreeNode*"] = true,
}

local PRELUDE = [[
#include "cpp_stdlib.h"
using namespace std;

#include "cpp_runtime.h"
using ncrt::ListNode;
using ncrt::TreeNode;
]]

--- Normalise a type: collapse whitespace, drop const/&, keep pointers.
local function clean_type(t)
  t = t:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  t = t:gsub("^const%s+", "")
  t = t:gsub("%s*&+%s*$", "")
  t = t:gsub("%s*%*%s*", "*")
  t = t:gsub("std::", "")
  t = t:gsub("%s*<%s*", "<"):gsub("%s*>%s*", ">"):gsub("%s*,%s*", ",")
  return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split a template/param list on top-level commas only.
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

local function type_supported(t, starter, code, ref)
  t = clean_type(t)
  if SCALARS[t] then return true end
  local inner = t:match("^vector<(.+)>$") or t:match("^optional<(.+)>$")
  if inner then return type_supported(inner, starter, code, ref) end
  local map = t:match("^map<(.+)>$")
  if map then
    local args = split_top(map)
    return #args == 2 and clean_type(args[1]) == "string"
      and type_supported(args[2], starter, code, ref)
  end
  local ptr = t:match("^([%w_:]+)%*$")
  if t:find("%*$") then return ptr ~= nil and not SCALARS[ptr] and type_supported(ptr, starter, code, ref) end
  local custom = t:match("^([%w_:]+)$")
  if custom then
    local sources = (starter or "") .. "\n" .. (code or "") .. "\n" .. (ref or "")
    return sources:match("%f[%w]class%s+" .. custom:gsub("::", "%%s*::%%s*") .. "%f[^%w]")
      or sources:match("%f[%w]struct%s+" .. custom:gsub("::", "%%s*::%%s*") .. "%f[^%w]") ~= nil
  end
  return false
end

local function qualify_type(t, ns, defined)
  t = clean_type(t)
  local ctor, inside = t:match("^([%w_:]+)<(.+)>$")
  if ctor then
    local args = split_top(inside)
    for i, arg in ipairs(args) do
      args[i] = qualify_type(arg, ns, defined)
    end
    return ctor .. "<" .. table.concat(args, ",") .. ">"
  end
  local ptr = t:match("^(.+)%*$")
  if ptr then return qualify_type(ptr, ns, defined) .. "*" end
  if defined and defined[ns] and defined[ns][t] and not defined[ns][t].global then
    return ns .. "::" .. t
  end
  return t
end

--- Strip comments so they cannot be mistaken for code.
local function strip_comments(src)
  src = src:gsub("/%*.-%*/", "")
  src = src:gsub("//[^\n]*", "")
  return src
end

--- Parse `class Solution`'s single public method out of starter code.
---@return table|nil sig {ret, name, params={{type,name},...}}, string|nil err
function M.parse_signature(starter, code, ref)
  -- `code` and `ref` are accepted for the shared language API. The current
  -- signature parser only needs the starter; declaration-derived codecs are
  -- generated separately from these sources.
  local src = strip_comments(starter)
  local body = src:match("class%s+Solution%s*{(.*)$")
  if not body then
    return nil, "could not find `class Solution` in the starter code"
  end
  local after_public = body:match("public%s*:(.*)$")
  if after_public then
    body = after_public
  end

  -- <return type> <name>(<params>) {
  local ret, name, params = body:match("([%w_][%w_%s%*&<>,:]-)%s+([%w_]+)%s*%(([^%)]*)%)%s*{")
  if not ret then
    return nil, "could not parse the method signature"
  end

  local sig = { ret = clean_type(ret), name = name, params = {} }
  for _, part in ipairs(split_top(params)) do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" then
      -- The parameter name is the trailing identifier; everything else is type.
      local ptype, pname = part:match("^(.-)([%w_]+)%s*$")
      if not pname then
        return nil, "could not parse parameter: " .. part
      end
      table.insert(sig.params, { type = clean_type(ptype), name = pname })
    end
  end
  if sig.ret ~= "void" and not type_supported(sig.ret, starter, code, ref) then
    return nil, string.format("unsupported return type `%s`", sig.ret)
  end
  for _, p in ipairs(sig.params) do
    if not type_supported(p.type, starter, code, ref) then
      return nil, string.format("unsupported parameter type `%s`", p.type)
    end
  end

  return sig, nil
end

--- Emit the argument declarations + call for one namespace.
local function emit_call(sig, ns, target, defined)
  local lines = {}
  local first_node = {}
  -- Per-case identity scope: each namespace block decodes its own arguments,
  -- so ids never leak between user/reference or across cases.
  table.insert(lines, "        ncrt::reset_identity();")
  table.insert(lines, "        ncrt::preindex_args(A);")
  -- Remember the first node-typed argument: later node parameters may be given
  -- as a scalar that identifies a node inside it.
  for i, p in ipairs(sig.params) do
    local ptype = qualify_type(p.type, ns, defined)
    table.insert(lines, string.format(
      '        ncrt::preindex_typed<%s>(ncrt::pick(A, %d, "%s"));',
      ptype, i - 1, p.name))
  end
  for i, p in ipairs(sig.params) do
    local ptype = qualify_type(p.type, ns, defined)
    local custom_ptr = ptype:find("%*$") and ptype ~= "ListNode*" and ptype ~= "TreeNode*"
    if custom_ptr then
      table.insert(lines, string.format(
        '        %s %s{}; ncrt::conv_ref(ncrt::pick(A, %d, "%s"), %s);',
        ptype, p.name, i - 1, p.name, p.name))
    elseif ptype == "ListNode*" or ptype == "TreeNode*" then
      table.insert(lines, string.format(
        '        %s %s{}; ncrt::conv(ncrt::pick(A, %d, "%s"), %s);',
        ptype, p.name, i - 1, p.name, p.name))
    else
      table.insert(lines, string.format(
        '        %s %s = ncrt::from_json<%s>(ncrt::pick(A, %d, "%s"));',
        ptype, p.name, ptype, i - 1, p.name))
    end

    if ptype == "TreeNode*" or ptype == "ListNode*" then
      local root = first_node[ptype]
      if root then
        table.insert(lines, string.format(
          '        if (!%s) %s = ncrt::findByValue(%s, (int)ncrt::pick(A, %d, "%s").num);',
          p.name, p.name, root, i - 1, p.name))
      else
        first_node[ptype] = p.name
      end
    end
  end
  -- Forward references must all have found their `$id` definition by now.
  table.insert(lines, "        ncrt::identity().verify();")

  local argnames = {}
  for _, p in ipairs(sig.params) do
    table.insert(argnames, p.name)
  end
  local call = string.format("%s::Solution().%s(%s)", ns, sig.name, table.concat(argnames, ", "))

  local ret = clean_type(sig.ret)
  local ret_custom_ptr = ret:find("%*$") and ret ~= "ListNode*" and ret ~= "TreeNode*"
  local ret_standard_ptr = ret == "ListNode*" or ret == "TreeNode*"
  if sig.ret == "void" then
    table.insert(lines, string.format("        %s;", call))
    local first = sig.params[1] and sig.params[1].name or nil
    local first_type = first and clean_type(sig.params[1].type) or ""
    local first_custom_ptr = first_type:find("%*$") and first_type ~= "ListNode*" and first_type ~= "TreeNode*"
    local first_standard_ptr = first_type == "ListNode*" or first_type == "TreeNode*"
    local render = first_custom_ptr and ("ncrt::tj_ref(" .. first .. ")")
      or (first_standard_ptr and ("ncrt::tj(" .. first .. ")")
        or ("ncrt::tj_graph(" .. (first or "") .. ")"))
    table.insert(lines, string.format("        %s = %s;", target, first and render or '"null"'))
  elseif ret_custom_ptr then
    table.insert(lines, string.format("        auto __r = %s;", call))
    table.insert(lines, string.format("        %s = ncrt::tj_ref(__r);", target))
  elseif ret_standard_ptr then
    table.insert(lines, string.format("        auto __r = %s;", call))
    table.insert(lines, string.format("        %s = ncrt::tj(__r);", target))
  else
    table.insert(lines, string.format("        auto __r = %s;", call))
    table.insert(lines, string.format("        %s = ncrt::tj_graph(__r);", target))
  end
  return table.concat(lines, "\n")
end

local FUNCTION_DRIVER = [[
%s
static std::string readFile(const std::string &path) {
  std::ifstream f(path);
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

int main(int argc, char **argv) {
  ncrt::installCrashHooks();
  std::string dir = argc > 1 ? argv[1] : ".";
  size_t shard = argc > 2 ? std::stoull(argv[2]) : 0;
  size_t stride = argc > 3 ? std::stoull(argv[3]) : 1;
  ncrt::JV cases = ncrt::parseJson(readFile(dir + "/cases.json"));
  ncrt::JV published = ncrt::parseJson(readFile(dir + "/expected.json"));

  std::string out = "{\"ok\":true,\"method\":\"%s\",\"cases\":[";
  bool firstCase = true;

  for (size_t ci = 0; ci < cases.arr.size(); ci++) {
    if (ci %% stride != shard) continue;
    // Announce progress so a hard crash can still be attributed to a case.
    std::fprintf(stderr, "CASE %%zu\n", ci);
    std::fflush(stderr);

    std::string block = cases.arr[ci].str;
    ncrt::Args A = ncrt::parseArgs(block);

    std::string actual, status, logs, errmsg, expected;
    std::vector<std::string> answers;
    double elapsed = 0.0;
    bool oracleOk = true, userErr = false;

    try {
%s
    } catch (const std::exception &e) {
      oracleOk = false;
      errmsg = e.what();
    } catch (...) {
      oracleOk = false;
      errmsg = "unknown exception in reference solution";
    }

    if (!oracleOk) {
      status = "oracle_error";
    } else {
      if (!answers.empty()) expected = answers[0];
      std::ostringstream cap;
      std::streambuf *saved = std::cout.rdbuf(cap.rdbuf());
      ncrt::capturing = cap.rdbuf();
      auto t0 = std::chrono::steady_clock::now();
      try {
%s
      } catch (const std::exception &e) {
        userErr = true;
        errmsg = e.what();
      } catch (...) {
        userErr = true;
        errmsg = "unknown exception";
      }
      auto t1 = std::chrono::steady_clock::now();
      std::cout.rdbuf(saved);
      ncrt::capturing = nullptr;
      elapsed = std::chrono::duration<double, std::milli>(t1 - t0).count();
      logs = cap.str();

      if (userErr) status = "error";
      else status = ncrt::judge(actual, answers, expected);
    }

    if (!firstCase) out += ",";
    firstCase = false;
    out += "{\"index\":" + std::to_string(ci);
    out += ",\"input\":" + ncrt::tj(block);
    out += ",\"status\":" + ncrt::tj(status);
    if (!answers.empty()) out += ",\"expected\":" + ncrt::tj(expected);
    out += ",\"actual\":" + ncrt::tj(actual);
    out += ",\"elapsed_ms\":" + ncrt::tj(elapsed);
    if (!logs.empty()) out += ",\"stdout\":" + ncrt::tj(logs);
    if (!errmsg.empty()) out += ",\"error\":" + ncrt::tj(errmsg);
    out += "}";
  }

  out += "]}";
  std::cout << out << std::endl;
  return 0;
}
]]

--- Take every known answer for case `ci` and parse it into the vector
--- `ncrt::judge` grades against, leaving it empty when none parse.
local PUBLISHED_EXPECTED = [[
        const ncrt::JV &pub = ncrt::argAt(published, ci);
        for (size_t k = 0; k < pub.arr.size(); k++) {
          const ncrt::JV &item = pub.arr[k];
          if (item.type == ncrt::JV::STR && !item.str.empty()) {
            answers.push_back(ncrt::render(ncrt::parseJson(item.str)));
          }
        }
]]

--- `user.cpp` is always included; `ref.cpp` only when it is the oracle, since
--- under the published-answer oracle there is no reference solution to compile.
local function translation_unit(driver, oracle, starter, code, ref, emit, target, roots)
  local structures = require("meatcode.runner.cpp_structures")
  local defined = structures.defined_records(starter, code, ref, target, roots)
  local definitions, codecs, aliases, structure_err =
    structures.generate(starter, code, oracle == "expected" and nil or ref, target, roots)
  if structure_err then return nil, structure_err end
  local parts = { PRELUDE, "\n", definitions, '\nnamespace usersol {\n#include "user.cpp"\n}\n' }
  if oracle ~= "expected" then
    table.insert(parts, '\nnamespace refsol {\n#include "ref.cpp"\n}\n')
  end
  table.insert(parts, "\n" .. codecs .. "\n" .. aliases .. "\n")
  table.insert(parts, emit and emit(defined) or driver)
  return table.concat(parts), nil
end

--- Build main.cpp. `user.cpp` (and, for the reference oracle, `ref.cpp`) are
--- included from the same dir.
---@param starter string
---@param oracle string|nil "reference" (default) or "expected"
function M.generate(starter, oracle, code, ref)
  local sig, err = M.parse_signature(starter, code, ref)
  if not sig then
    return nil, err
  end

  local roots = { sig.ret }
  for _, p in ipairs(sig.params) do roots[#roots + 1] = p.type end
  local function build(defined)
    local expected_block = oracle == "expected" and PUBLISHED_EXPECTED
      or (emit_call(sig, "refsol", "expected", defined) .. "\n        answers.push_back(expected);")
    local driver = string.format(FUNCTION_DRIVER, "", sig.name,
      expected_block, emit_call(sig, "usersol", "actual", defined))
    return driver
  end

  return translation_unit(nil, oracle, starter, code, ref, build, "Solution", roots)
end
-- ------------------------------------------------------------ class problems

--- Parse a "design" problem's class out of its starter code: the constructor
--- and every public method, with their types.
---@return table|nil cls {name, ctor={params}, methods={{ret,name,params}}}, string|nil err
local function find_class(src, target)
  local pos = 1
  while true do
    local start, brace, name = src:find("%f[%a]class%s+([%w_]+)%s*{", pos)
    if not start then return nil end
    local depth, i = 1, brace + 1
    while i <= #src and depth > 0 do
      local c = src:sub(i, i)
      if c == "{" then depth = depth + 1
      elseif c == "}" then depth = depth - 1 end
      i = i + 1
    end
    if depth == 0 and (not target or name == target) then
      return name, src:sub(brace + 1, i - 2)
    end
    pos = i
  end
end
function M.parse_class(starter, code, ref, target)
  local src = strip_comments(starter)
  local name, body = find_class(src, target)
  if not name then
    return nil, target and ("could not find design target class `" .. target .. "`")
      or "could not find a class in the starter code"
  end
  local after_public = body:match("public%s*:(.*)$")
  if after_public then
    body = after_public
  end

  local cls = { name = name, ctor = nil, methods = {} }
  -- Declarations sit at one indent level inside the class body; anything more
  -- deeply nested belongs to a member's implementation.
  for line in body:gmatch("[^\n]+") do
    local ret, fname, params = line:match("^%s*([%w_][%w_%s%*&<>,:]-)%s+([%w_]+)%s*%(([^%)]*)%)%s*[{;]")
    local ctor_params = line:match("^%s*" .. name .. "%s*%(([^%)]*)%)%s*[{:;]")

    if ctor_params and not cls.ctor then
      local parsed, perr = M.parse_params(ctor_params, starter, code, ref)
      if not parsed then
        return nil, perr
      end
      cls.ctor = { params = parsed }
    elseif ret and fname ~= name then
      local parsed, perr = M.parse_params(params, starter, code, ref)
      if not parsed then
        return nil, perr
      end
      ret = clean_type(ret)
      if ret ~= "void" and not type_supported(ret, starter, code, ref) then
        return nil, string.format("unsupported return type `%s` on `%s`", ret, fname)
      end
      table.insert(cls.methods, { ret = ret, name = fname, params = parsed })
    end
  end

  cls.ctor = cls.ctor or { params = {} }
  if #cls.methods == 0 then
    return nil, "the starter class declares no methods"
  end
  return cls, nil
end

--- Shared "<type> <name>" parameter list parsing.
---@return table|nil params, string|nil err
function M.parse_params(params, starter, code, ref)
  local out = {}
  for _, part in ipairs(split_top(params)) do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" then
      local ptype, pname = part:match("^(.-)([%w_]+)%s*$")
      if not pname then
        return nil, "could not parse parameter: " .. part
      end
      ptype = clean_type(ptype)
      if not type_supported(ptype, starter, code, ref) then
        return nil, string.format("unsupported parameter type `%s`", ptype)
      end
      table.insert(out, { type = ptype, name = pname })
    end
  end
  return out, nil
end

function M.class_spec(cls)
  local function flags(params)
    local out = {}
    for _, p in ipairs(params) do
      table.insert(out, p.type:match("^vector<") ~= nil or not SCALARS[clean_type(p.type)])
    end
    return out
  end
  local spec = { name = cls.name, ctor = flags(cls.ctor.params), methods = {} }
  for _, m in ipairs(cls.methods) do
    spec.methods[m.name] = flags(m.params)
  end
  return spec
end

--- Declare and fill locals for one call's arguments, reading them from `a`.
--- Record types the namespace defines itself are qualified so usersol/refsol
--- definitions stay distinct.
local function emit_args(params, ns, defined)
  local lines, names = {}, {}
  for i, p in ipairs(params) do
    local ptype = qualify_type(p.type, ns, defined)
    local indent = ns == "usersol" and "  " or "      "
    local custom_ptr = ptype:find("%*$") and ptype ~= "ListNode*" and ptype ~= "TreeNode*"
    if custom_ptr then
      table.insert(lines, string.format('%s%s %s{}; ncrt::conv_ref(ncrt::argAt(a, %d), %s);',
        indent, ptype, p.name, i, p.name))
    elseif ptype == "ListNode*" or ptype == "TreeNode*" then
      table.insert(lines, string.format('%s%s %s{}; ncrt::conv(ncrt::argAt(a, %d), %s);',
        indent, ptype, p.name, i, p.name))
    else
      table.insert(lines, string.format('%s%s %s = ncrt::from_json<%s>(ncrt::argAt(a, %d));',
        indent, ptype, p.name, ptype, i))
    end
    table.insert(names, p.name)
  end
  return table.concat(lines, "\n"), table.concat(names, ", ")
end

--- A replay function templated on the class, so the same body drives both the
--- user's implementation and the reference one.
local function emit_replay(cls, ns, defined)
  local ctor_decls, ctor_args = emit_args(cls.ctor.params, ns, defined)

  local typed_ctor = {}
  for i,p in ipairs(cls.ctor.params) do
    local ptype = qualify_type(p.type, ns, defined)
    typed_ctor[#typed_ctor+1] = string.format(
      '  ncrt::preindex_typed<%s>(ncrt::argAt(ops.arr[0], %d));', ptype, i)
  end
  local typed_ops = {}
  for _,m in ipairs(cls.methods) do
    local lines = {}
    for i,p in ipairs(m.params) do
      local ptype = qualify_type(p.type, ns, defined)
      lines[#lines+1] = string.format(
        '      ncrt::preindex_typed<%s>(ncrt::argAt(ops.arr[__i], %d));', ptype, i)
    end
    typed_ops[#typed_ops+1] = string.format(
      '    %sif (__method == "%s") {\n%s\n    }',
      #typed_ops > 0 and "else " or "", m.name, table.concat(lines, "\n"))
  end
  local branches = {}
  for _, m in ipairs(cls.methods) do
    local decls, args = emit_args(m.params, ns, defined)
    local call = string.format("obj.%s(%s)", m.name, args)
    local ret = clean_type(m.ret)
    local ret_ptr = ret:find("%*$") and ret ~= "ListNode*" and ret ~= "TreeNode*"
    local standard_ptr = ret == "ListNode*" or ret == "TreeNode*"
    local body
    if m.ret == "void" then
      body = string.format("%s\n      %s;\n      out += \"null\";", decls, call)
    elseif ret_ptr then
      body = string.format("%s\n      auto r = %s;\n      out += ncrt::tj_ref(r);", decls, call)
    elseif standard_ptr then
      body = string.format("%s\n      auto r = %s;\n      out += ncrt::tj(r);", decls, call)
    else
      body = string.format("%s\n      auto r = %s;\n      out += ncrt::tj_graph(r);", decls, call)
    end
    table.insert(branches, string.format(
      '    %sif (m == "%s") {\n%s\n    }',
      #branches > 0 and "else " or "", m.name, body))
  end

  return string.format([[
static std::string replay_%s(const ncrt::JV &ops) {
  ncrt::reset_identity();
  ncrt::preindex(ops);
  // Bind the original operation values. Copying them would make one identity
  // definition look like two objects.
%s
  for (size_t __i = 1; __i < ops.arr.size(); ++__i) {
    std::string __method = ops.arr[__i].arr[0].str;
%s
  }
  const ncrt::JV &a = ops.arr[0];
%s
  %s::%s obj%s;
  std::string out = "[null";

  for (size_t i = 1; i < ops.arr.size(); i++) {
    std::string m = ops.arr[i].arr[0].str;
    const ncrt::JV &a = ops.arr[i];
    out += ",";
%s
    else throw std::runtime_error("no method named `" + m + "`");
  }
  ncrt::identity().verify();
  return out + "]";
}
]], ns, table.concat(typed_ctor, "\n"), table.concat(typed_ops, "\n"),
  ctor_decls, ns, cls.name,
  ctor_args == "" and "" or ("(" .. ctor_args .. ")"), table.concat(branches, "\n"))
end

--- Build main.cpp for a design problem.
---@param starter string
---@param oracle string|nil "reference" (default) or "expected"
---@return string|nil source, string|nil err
function M.generate_class(starter, oracle, code, ref, target)
  local cls, err = M.parse_class(starter, code, ref, target)
  if not cls then
    return nil, err
  end

  local roots = {}
  for _, p in ipairs(cls.ctor.params) do roots[#roots + 1] = p.type end
  for _, m in ipairs(cls.methods) do
    roots[#roots + 1] = m.ret
    for _, p in ipairs(m.params) do roots[#roots + 1] = p.type end
  end
  local function build(defined)
    local replays = emit_replay(cls, "usersol", defined)
    local expected_block
    if oracle == "expected" then
      expected_block = PUBLISHED_EXPECTED
    else
      replays = replays .. "\n" .. emit_replay(cls, "refsol", defined)
      expected_block = "        expected = replay_refsol(ops);\n        answers.push_back(expected);"
    end
    return string.format([[
%s

static std::string readFile(const std::string &path) {
  std::ifstream f(path);
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

int main(int argc, char **argv) {
  ncrt::installCrashHooks();
  std::string dir = argc > 1 ? argv[1] : ".";
  size_t shard = argc > 2 ? std::stoull(argv[2]) : 0;
  size_t stride = argc > 3 ? std::stoull(argv[3]) : 1;
  ncrt::JV cases = ncrt::parseJson(readFile(dir + "/ops.json"));
  ncrt::JV raw = ncrt::parseJson(readFile(dir + "/cases.json"));
  ncrt::JV published = ncrt::parseJson(readFile(dir + "/expected.json"));

  std::string out = "{\"ok\":true,\"method\":\"%s\",\"cases\":[";
  bool firstCase = true;

  for (size_t ci = 0; ci < cases.arr.size(); ci++) {
    if (ci %% stride != shard) continue;
    std::fprintf(stderr, "CASE %%zu\n", ci);
    std::fflush(stderr);

    const ncrt::JV &ops = cases.arr[ci];
    std::string actual, status, logs, errmsg, expected;
    std::vector<std::string> answers;
    double elapsed = 0.0;
    bool oracleOk = true, userErr = false;

    try {
%s
    } catch (const std::exception &e) {
      oracleOk = false;
      errmsg = e.what();
    } catch (...) {
      oracleOk = false;
      errmsg = "unknown exception in reference solution";
    }

    if (!oracleOk) {
      status = "oracle_error";
    } else {
      if (!answers.empty()) expected = answers[0];
      std::ostringstream cap;
      std::streambuf *saved = std::cout.rdbuf(cap.rdbuf());
      ncrt::capturing = cap.rdbuf();
      auto t0 = std::chrono::steady_clock::now();
      try {
        actual = replay_usersol(ops);
      } catch (const std::exception &e) {
        userErr = true;
        errmsg = e.what();
      } catch (...) {
        userErr = true;
        errmsg = "unknown exception";
      }
      auto t1 = std::chrono::steady_clock::now();
      std::cout.rdbuf(saved);
      ncrt::capturing = nullptr;
      elapsed = std::chrono::duration<double, std::milli>(t1 - t0).count();
      logs = cap.str();

      if (userErr) status = "error";
      else status = ncrt::judge(actual, answers, expected);
    }

    if (!firstCase) out += ",";
    firstCase = false;
    out += "{\"index\":" + std::to_string(ci);
    out += ",\"input\":" + ncrt::tj(ncrt::argAt(raw, ci).str);
    out += ",\"status\":" + ncrt::tj(status);
    if (!answers.empty()) out += ",\"expected\":" + ncrt::tj(expected);
    out += ",\"actual\":" + ncrt::tj(actual);
    out += ",\"elapsed_ms\":" + ncrt::tj(elapsed);
    if (!logs.empty()) out += ",\"stdout\":" + ncrt::tj(logs);
    if (!errmsg.empty()) out += ",\"error\":" + ncrt::tj(errmsg);
    out += "}";
  }

  out += "]}";
  std::cout << out << std::endl;
  return 0;
}
]], replays, cls.name, expected_block)
  end

  return translation_unit(nil, oracle, starter, code, ref, build, cls.name, roots)
end

--- Some "class" problems are really round trips: an encode method and a decode
--- method that must invert each other. Their test cases are plain inputs, so we
--- feed the input through both and compare what comes back out.
---@param starter string
---@param oracle string|nil "reference" (default) or "expected"
---@return string|nil source, string|nil err
function M.generate_roundtrip(starter, oracle, code, ref, target)
  local cls, err = M.parse_class(starter, code, ref, target)
  if not cls then
    return nil, err
  end
  if #cls.methods < 2 then
    return nil, "expected an encode/decode pair in the starter class"
  end

  local enc, dec = cls.methods[1], cls.methods[2]
  if #enc.params ~= 1 or #dec.params ~= 1 then
    return nil, "expected both methods to take a single argument"
  end
  if clean_type(dec.params[1].type) ~= clean_type(enc.ret) then
    return nil, string.format("`%s` does not consume what `%s` produces", dec.name, enc.name)
  end

  local p = enc.params[1]
  local roots = { enc.ret, p.type, dec.params[1].type }
  for _, ctor_param in ipairs(cls.ctor.params) do roots[#roots + 1] = ctor_param.type end
  local function build(defined)
    local function roundtrip(ns)
      local ptype = qualify_type(p.type, ns, defined)
      local ret = clean_type(dec.params[1].type)
      local standard_ptr = ret == "ListNode*" or ret == "TreeNode*"
      local render = standard_ptr and "ncrt::tj(decoded)" or "ncrt::tj_graph(decoded)"
      return string.format([[
static std::string roundtrip_%s(const ncrt::Args &A) {
  ncrt::reset_identity();
  ncrt::preindex_args(A);
  ncrt::preindex_typed<%s>(ncrt::pick(A, 0, "%s"));
  %s::%s obj;
  %s %s = ncrt::from_json<%s>(ncrt::pick(A, 0, "%s"));
  ncrt::identity().verify();
  auto encoded = obj.%s(%s);
  auto decoded = obj.%s(encoded);
  return %s;
}
]], ns, ptype, p.name, ns, cls.name, ptype, p.name, ptype, p.name,
   enc.name, p.name, dec.name, render)
    end
    local expected_block = oracle == "expected"
        and string.format('        answers.push_back(ncrt::render(ncrt::pick(A, 0, "%s")));', p.name)
      or string.format("        answers.push_back(roundtrip_refsol(A));", cls.name)
    return string.format(FUNCTION_DRIVER,
      roundtrip("usersol") .. (oracle == "expected" and "" or ("\n" .. roundtrip("refsol"))),
      enc.name .. " -> " .. dec.name,
      expected_block,
      "        actual = roundtrip_usersol(A);")
  end

  return translation_unit(nil, oracle, starter, code, ref, build, cls.name, roots)
end

--- Helper type definitions NeetCode leaves in the starter's comment block.
---
--- The judge injects `ListNode`, `TreeNode`, `Node` and `Interval` implicitly
--- and documents them in a comment instead. Those comments are the only
--- authoritative source: `Node` means an adjacency list in Clone Graph and a
--- random pointer in Copy List, so there is no single definition to guess at.
---@return table[] { { name = "Node", source = "class Node {...};" }, ... }
function M.starter_types(starter)
  local out, seen = {}, {}

  for block in (starter or ""):gmatch("/%*.-%*/") do
    -- Drop the delimiters, then the ` * ` decoration some blocks carry.
    local body = block:gsub("^/%*+", ""):gsub("%*/$", "")
    local lines = {}
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, (line:gsub("^%s*%*%s?", "")))
    end
    body = table.concat(lines, "\n")

    for _, keyword in ipairs({ "class", "struct" }) do
      local init = 1
      while true do
        local start, brace, name = body:find("%f[%a]" .. keyword .. "%s+([%w_]+)%s*{", init)
        if not start then
          break
        end

        local depth, i = 0, brace
        while i <= #body do
          local c = body:sub(i, i)
          if c == "{" then
            depth = depth + 1
          elseif c == "}" then
            depth = depth - 1
            if depth == 0 then
              break
            end
          end
          i = i + 1
        end
        if depth ~= 0 then
          break
        end

        -- The slice stops at the closing brace, and some blocks omit the
        -- semicolon entirely, so it is always supplied here.
        local source = body:sub(start, i) .. ";"
        if not seen[name] then
          seen[name] = true
          table.insert(out, { name = name, source = source })
        end
        init = i + 1
      end
    end
  end

  return out
end

M.clean_type = clean_type
M.type_supported = type_supported

return M
