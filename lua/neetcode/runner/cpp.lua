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
#include <algorithm>
#include <array>
#include <bitset>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <functional>
#include <iostream>
#include <iterator>
#include <limits>
#include <list>
#include <map>
#include <numeric>
#include <queue>
#include <set>
#include <sstream>
#include <stack>
#include <string>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>
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

local function type_supported(t)
  t = clean_type(t)
  if SCALARS[t] then
    return true
  end
  local inner = t:match("^vector<(.+)>$")
  if inner then
    return type_supported(inner)
  end
  return false
end

--- Strip comments so they cannot be mistaken for code.
local function strip_comments(src)
  src = src:gsub("/%*.-%*/", "")
  src = src:gsub("//[^\n]*", "")
  return src
end

--- Parse `class Solution`'s single public method out of starter code.
---@return table|nil sig {ret, name, params={{type,name},...}}, string|nil err
function M.parse_signature(starter)
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

  if sig.ret ~= "void" and not type_supported(sig.ret) then
    return nil, string.format("unsupported return type `%s`", sig.ret)
  end
  for _, p in ipairs(sig.params) do
    if not type_supported(p.type) then
      return nil, string.format("unsupported parameter type `%s`", p.type)
    end
  end

  return sig, nil
end

--- Emit the argument declarations + call for one namespace.
local function emit_call(sig, ns, target)
  local lines = {}
  -- Remember the first node-typed argument: later node parameters may be given
  -- as a scalar that identifies a node inside it.
  local first_node = {}
  for i, p in ipairs(sig.params) do
    local ptype = clean_type(p.type)
    table.insert(lines, string.format(
      '        %s %s{}; ncrt::conv(ncrt::pick(A, %d, "%s"), %s);',
      ptype, p.name, i - 1, p.name, p.name))

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

  local argnames = {}
  for _, p in ipairs(sig.params) do
    table.insert(argnames, p.name)
  end
  local call = string.format("%s::Solution().%s(%s)", ns, sig.name, table.concat(argnames, ", "))

  if sig.ret == "void" then
    -- In-place problems mutate their first argument instead of returning.
    table.insert(lines, string.format("        %s;", call))
    local first = sig.params[1] and sig.params[1].name or nil
    table.insert(lines, string.format("        %s = %s;", target,
      first and ("ncrt::tj(" .. first .. ")") or '"null"'))
  else
    table.insert(lines, string.format("        auto __r = %s;", call))
    table.insert(lines, string.format("        %s = ncrt::tj(__r);", target))
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
  std::string dir = argc > 1 ? argv[1] : ".";
  ncrt::JV cases = ncrt::parseJson(readFile(dir + "/cases.json"));

  std::string out = "{\"ok\":true,\"method\":\"%s\",\"cases\":[";

  for (size_t ci = 0; ci < cases.arr.size(); ci++) {
    // Announce progress so a hard crash can still be attributed to a case.
    std::fprintf(stderr, "CASE %%zu\n", ci);
    std::fflush(stderr);

    std::string block = cases.arr[ci].str;
    ncrt::Args A = ncrt::parseArgs(block);

    std::string expected, actual, status, logs, errmsg;
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
      std::ostringstream cap;
      std::streambuf *saved = std::cout.rdbuf(cap.rdbuf());
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
      elapsed = std::chrono::duration<double, std::milli>(t1 - t0).count();
      logs = cap.str();

      if (userErr) status = "error";
      else if (actual == expected) status = "pass";
      else if (ncrt::canonical(actual) == ncrt::canonical(expected)) status = "pass_unordered";
      else status = "fail";
    }

    if (ci) out += ",";
    out += "{\"index\":" + std::to_string(ci);
    out += ",\"input\":" + ncrt::tj(block);
    out += ",\"status\":" + ncrt::tj(status);
    out += ",\"expected\":" + ncrt::tj(expected);
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

--- Build main.cpp. `user.cpp` and `ref.cpp` are included from the same dir.
---@return string|nil source, string|nil err
function M.generate(starter)
  local sig, err = M.parse_signature(starter)
  if not sig then
    return nil, err
  end

  local driver = string.format(FUNCTION_DRIVER, "", sig.name,
    emit_call(sig, "refsol", "expected"), emit_call(sig, "usersol", "actual"))


  return table.concat({
    PRELUDE,
    '\nnamespace usersol {\n#include "user.cpp"\n}\n',
    '\nnamespace refsol {\n#include "ref.cpp"\n}\n',
    driver,
  }), nil
end

-- ------------------------------------------------------------ class problems

--- Parse a "design" problem's class out of its starter code: the constructor
--- and every public method, with their types.
---@return table|nil cls {name, ctor={params}, methods={{ret,name,params}}}, string|nil err
function M.parse_class(starter)
  local src = strip_comments(starter)
  local name, body = src:match("class%s+([%w_]+)%s*{(.*)$")
  if not name then
    return nil, "could not find a class in the starter code"
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
      local parsed, perr = M.parse_params(ctor_params)
      if not parsed then
        return nil, perr
      end
      cls.ctor = { params = parsed }
    elseif ret and fname ~= name then
      local parsed, perr = M.parse_params(params)
      if not parsed then
        return nil, perr
      end
      ret = clean_type(ret)
      if ret ~= "void" and not type_supported(ret) then
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
function M.parse_params(params)
  local out = {}
  for _, part in ipairs(split_top(params)) do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" then
      local ptype, pname = part:match("^(.-)([%w_]+)%s*$")
      if not pname then
        return nil, "could not parse parameter: " .. part
      end
      ptype = clean_type(ptype)
      if not type_supported(ptype) then
        return nil, string.format("unsupported parameter type `%s`", ptype)
      end
      table.insert(out, { type = ptype, name = pname })
    end
  end
  return out, nil
end

--- The arity/list-ness table `runner.ops` needs to decode interleaved cases.
function M.class_spec(cls)
  local function flags(params)
    local out = {}
    for _, p in ipairs(params) do
      table.insert(out, p.type:match("^vector<") ~= nil)
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
local function emit_args(params, indent)
  local lines, names = {}, {}
  for i, p in ipairs(params) do
    table.insert(lines, string.format('%s%s %s{}; ncrt::conv(ncrt::argAt(a, %d), %s);',
      indent, p.type, p.name, i - 1, p.name))
    table.insert(names, p.name)
  end
  return table.concat(lines, "\n"), table.concat(names, ", ")
end

--- A replay function templated on the class, so the same body drives both the
--- user's implementation and the reference one.
local function emit_replay(cls)
  local ctor_decls, ctor_args = emit_args(cls.ctor.params, "  ")

  local branches = {}
  for _, m in ipairs(cls.methods) do
    local decls, args = emit_args(m.params, "      ")
    local call = string.format("obj.%s(%s)", m.name, args)
    local body
    if m.ret == "void" then
      body = string.format("%s\n      %s;\n      out += \"null\";", decls, call)
    else
      body = string.format("%s\n      auto r = %s;\n      out += ncrt::tj(r);", decls, call)
    end
    table.insert(branches, string.format(
      '    %sif (m == "%s") {\n%s\n    }',
      #branches > 0 and "else " or "", m.name, body))
  end

  return string.format([[
template <class T>
static std::string replay(const ncrt::JV &ops) {
  const ncrt::JV &ctor = ops.arr[0];
  ncrt::JV a = ncrt::tail(ctor);
%s
  T obj%s;
  std::string out = "[null";

  for (size_t i = 1; i < ops.arr.size(); i++) {
    std::string m = ops.arr[i].arr[0].str;
    ncrt::JV a = ncrt::tail(ops.arr[i]);
    out += ",";
%s
    else throw std::runtime_error("no method named `" + m + "`");
  }
  return out + "]";
}
]], ctor_decls, ctor_args == "" and "" or ("(" .. ctor_args .. ")"), table.concat(branches, "\n"))
end

--- Build main.cpp for a design problem.
---@return string|nil source, string|nil err
function M.generate_class(starter)
  local cls, err = M.parse_class(starter)
  if not cls then
    return nil, err
  end

  local driver = string.format([[
%s

static std::string readFile(const std::string &path) {
  std::ifstream f(path);
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

int main(int argc, char **argv) {
  std::string dir = argc > 1 ? argv[1] : ".";
  ncrt::JV cases = ncrt::parseJson(readFile(dir + "/ops.json"));
  ncrt::JV raw = ncrt::parseJson(readFile(dir + "/cases.json"));

  std::string out = "{\"ok\":true,\"method\":\"%s\",\"cases\":[";

  for (size_t ci = 0; ci < cases.arr.size(); ci++) {
    std::fprintf(stderr, "CASE %%zu\n", ci);
    std::fflush(stderr);

    const ncrt::JV &ops = cases.arr[ci];
    std::string expected, actual, status, logs, errmsg;
    double elapsed = 0.0;
    bool oracleOk = true, userErr = false;

    try {
      expected = replay<refsol::%s>(ops);
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
      std::ostringstream cap;
      std::streambuf *saved = std::cout.rdbuf(cap.rdbuf());
      auto t0 = std::chrono::steady_clock::now();
      try {
        actual = replay<usersol::%s>(ops);
      } catch (const std::exception &e) {
        userErr = true;
        errmsg = e.what();
      } catch (...) {
        userErr = true;
        errmsg = "unknown exception";
      }
      auto t1 = std::chrono::steady_clock::now();
      std::cout.rdbuf(saved);
      elapsed = std::chrono::duration<double, std::milli>(t1 - t0).count();
      logs = cap.str();

      if (userErr) status = "error";
      else if (actual == expected) status = "pass";
      else status = "fail";
    }

    if (ci) out += ",";
    out += "{\"index\":" + std::to_string(ci);
    out += ",\"input\":" + ncrt::tj(ncrt::argAt(raw, ci).str);
    out += ",\"status\":" + ncrt::tj(status);
    out += ",\"expected\":" + ncrt::tj(expected);
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
]], emit_replay(cls), cls.name, cls.name, cls.name)

  return table.concat({
    PRELUDE,
    '\nnamespace usersol {\n#include "user.cpp"\n}\n',
    '\nnamespace refsol {\n#include "ref.cpp"\n}\n',
    driver,
  }), nil
end

--- Some "class" problems are really round trips: an encode method and a decode
--- method that must invert each other. Their test cases are plain inputs, so we
--- feed the input through both and compare what comes back out.
---@return string|nil source, string|nil err
function M.generate_roundtrip(starter)
  local cls, err = M.parse_class(starter)
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
  local preamble = string.format([[
template <class T>
static std::string roundtrip(const ncrt::Args &A) {
  T obj;
  %s %s{}; ncrt::conv(ncrt::pick(A, 0, "%s"), %s);
  auto encoded = obj.%s(%s);
  auto decoded = obj.%s(encoded);
  return ncrt::tj(decoded);
}
]], p.type, p.name, p.name, p.name, enc.name, p.name, dec.name)

  local driver = string.format(FUNCTION_DRIVER, preamble,
    enc.name .. " -> " .. dec.name,
    string.format("        expected = roundtrip<refsol::%s>(A);", cls.name),
    string.format("        actual = roundtrip<usersol::%s>(A);", cls.name))

  return table.concat({
    PRELUDE,
    '\nnamespace usersol {\n#include "user.cpp"\n}\n',
    '\nnamespace refsol {\n#include "ref.cpp"\n}\n',
    driver,
  }), nil
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
