local M = {}

local function clean(s)
  return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    :gsub("^const%s+", ""):gsub("%s*%*%s*", "*"):gsub("&+$", ""):gsub("std::", ""))
end

local function comments(src)
  src = tostring(src or "")
  local out, i, n = {}, 1, #src
  while i <= n do
    local c, nextc = src:sub(i, i), src:sub(i + 1, i + 1)
    if c == "R" and nextc == '"' then
      local open = src:find("(", i + 2, true)
      if not open then i = i + 1
      else
        local delim = src:sub(i + 2, open - 1)
        local close = src:find(")" .. delim .. '"', open + 1, true)
        i = close and (close + #delim + 2) or (n + 1)
      end
    elseif c == '"' or c == "'" then
      local quote = c
      i = i + 1
      while i <= n do
        if src:sub(i, i) == "\\" then i = i + 2
        elseif src:sub(i, i) == quote then i = i + 1; break
        else i = i + 1 end
      end
    elseif c == "/" and nextc == "/" then
      local ending = src:find("\n", i + 2, true) or (n + 1)
      out[#out+1] = src:sub(i + 2, ending - 1)
      i = ending
    elseif c == "/" and nextc == "*" then
      local close = src:find("*/", i + 2, true)
      if not close then break end
      local block = src:sub(i + 2, close - 1):gsub("^%*+", "")
      out[#out+1] = (block:gsub("\n%s*%*%s?", "\n"))
      i = close + 2
    else
      i = i + 1
    end
  end
  return table.concat(out, "\n")
end

local function split(s)
  local out, depth, from = {}, 0, 1
  for i=1,#s do
    local c=s:sub(i,i)
    if c=='<' or c=='(' then depth=depth+1 elseif c=='>' or c==')' then depth=depth-1
    elseif c==',' and depth==0 then out[#out+1]=clean(s:sub(from,i-1)); from=i+1 end
  end
  if from<=#s then out[#out+1]=clean(s:sub(from)) end
  return out
end

local function mask_noncode(src)
  local chars, i, n = {}, 1, #src
  local function blank(a, b)
    for k = a, b do
      chars[k] = src:sub(k, k) == "\n" and "\n" or " "
    end
  end
  while i <= n do
    local c, nextc = src:sub(i, i), src:sub(i + 1, i + 1)
    if c == "/" and nextc == "/" then
      local e = src:find("\n", i + 2, true) or (n + 1)
      blank(i, e - 1); i = e
    elseif c == "/" and nextc == "*" then
      local e = src:find("*/", i + 2, true)
      if not e then blank(i, n); break end
      blank(i, e + 1); i = e + 2
    elseif c == '"' or c == "'" then
      local quote, start = c, i
      i = i + 1
      while i <= n do
        if src:sub(i, i) == "\\" then i = i + 2
        elseif src:sub(i, i) == quote then i = i + 1; break
        else i = i + 1 end
      end
      blank(start, math.min(i - 1, n))
    elseif c == "R" and nextc == '"' then
      local open = src:find("(", i + 2, true)
      if not open then chars[i] = c; i = i + 1
      else
        local delim = src:sub(i + 2, open - 1)
        local close = src:find(")" .. delim .. '"', open + 1, true)
        local e = close and (close + #delim + 1) or n
        blank(i, e); i = e + 1
      end
    else chars[i] = c; i = i + 1 end
  end
  return table.concat(chars)
end

local function declarations(source)
  source = tostring(source or "")
  local src = mask_noncode(source)
  local out, pos = {}, 1
  while true do
    local cs, cb, cn = src:find("%f[%a]class%s+([%w_:]+)%s*{", pos)
    local ss, sb, sn = src:find("%f[%a]struct%s+([%w_:]+)%s*{", pos)
    local start, brace, kind, name
    if cs and (not ss or cs < ss) then start, brace, kind, name = cs, cb, "class", cn
    elseif ss then start, brace, kind, name = ss, sb, "struct", sn
    else break end
    local depth, i = 1, brace + 1
    while i <= #src and depth > 0 do
      local c = src:sub(i,i)
      if c == "{" then depth = depth + 1 elseif c == "}" then depth = depth - 1 end
      i = i + 1
    end
    if depth ~= 0 then return out, "unclosed " .. kind .. " declaration `" .. name .. "`" end
    local body = src:sub(brace + 1, i - 2)
    -- One-line declarations (`struct P { int id; vector<int> vs; };`) carry
    -- several statements per line; expose each top-level segment on its own.
    local segs, seg, depth = {}, {}, 0
    for k = 1, #body do
      local c = body:sub(k, k)
      if c == "<" or c == "(" or c == "{" then depth = depth + 1
      elseif c == ">" or c == ")" or c == "}" then depth = depth - 1 end
      if c == ";" and depth == 0 then
        table.insert(segs, table.concat(seg) .. ";")
        seg = {}
      else
        table.insert(seg, c)
      end
    end
    if #seg > 0 then table.insert(segs, table.concat(seg)) end
    local fields, ctor, ctor_body, field_error, ctor_fields = {}, nil, nil, nil, nil
    local public = kind == "struct"
    for _, line in ipairs(segs) do
      for _, spec in ipairs({ "public", "private", "protected" }) do
        local inner = line:match("^%s*" .. spec .. "%s*:%s*(.+)$")
        if inner then public = spec == "public"; line = inner end
      end
      if line:match("^%s*public%s*:") then public = true end
      if line:match("^%s*private%s*:") or line:match("^%s*protected%s*:") then public = false end
      local params, tail = line:match("^%s*" .. name:match("([^:]+)$") .. "%s*%(([^)]*)%)%s*([{%:].*)")
      if params then ctor = params; ctor_body = (tail:gsub("[%s;]+$", "")) end
      if public then
        local decl = line:match("^%s*(.-)%s*;%s*$")
        if decl and not decl:find("%(") and not decl:find("%.") then
          if decl:find("=") then
            field_error = "unsupported field declaration in `" .. name .. "`: `" .. decl .. "` (declared default initializers are not supported)"
          else
            local chunks = split(decl)
            local typ, first
            if chunks[1] then typ, first = chunks[1]:match("^(.+[%s%*])([%w_]+)$") end
            if typ and first and first:match("^[%a_]") and not typ:match("^using ") and not typ:match("^typedef ") then
              fields[#fields+1] = {type=typ, name=first}
              for k = 2, #chunks do
                local fname = chunks[k]:match("^[%s*&]*([%w_]+)$")
                if fname then fields[#fields+1] = {type=typ, name=fname} end
              end
            end
          end
        end
      end
    end
    local ctor_error = nil
    local ctor_init, ctor_braces
    if ctor and ctor_body then
      ctor_init, ctor_braces = ctor_body:match("^%s*:%s*(.-)%s*{(.*)}$")
    end
    local refcap = false
    for _,f in ipairs(fields) do
      if f.type:find("*") then refcap = true end
    end
    local default_ctor = body:match("%f[%w]" .. name:match("([^:]+)$") .. "%s*%(%s*%)") ~= nil
    if ctor and not refcap then
      local params = split(ctor)
      local ptype_of, mapped, bindings, order = {}, {}, {}, {}
      for _,param in ipairs(params) do
        local typ, pname = param:match("^(.-)%s+([%w_]+)$")
        if not typ then
          ctor_error = "unsupported constructor parameter in `" .. name .. "`: " .. param
        else
          ptype_of[pname] = typ
        end
      end
      local function bind(pname, field, what, detail)
        if not field then
          ctor_error = "unsupported constructor " .. what .. " for `" .. name .. "`: unknown field" .. (detail and " `" .. detail .. "`" or "")
          return false
        end
        if not ptype_of[pname] then
          ctor_error = "unsupported constructor " .. what .. " for `" .. name .. "`: unknown parameter `" .. pname .. "`"
          return false
        end
        if clean(ptype_of[pname]) ~= clean(field.type) then
          ctor_error = "unsupported constructor " .. what .. " for `" .. name .. "`: parameter `" .. pname .. "` type does not match field `" .. field.name .. "`"
          return false
        end
        if bindings[pname] or mapped[field.name] then
          ctor_error = "unsupported constructor mapping for `" .. name .. "`: `" .. pname .. "`/`" .. field.name .. "` bound twice"
          return false
        end
        bindings[pname], mapped[field.name] = field, true
        return true
      end
      -- 1) An initializer list explicitly binds parameters to fields
      -- (`: key(k), value(v)`).
      if not ctor_error and ctor_init then
        for entry in ctor_init:gmatch("[^,]+") do
          local field, pname = entry:match("^%s*([%w_]+)%s*%(%s*([%w_]+)%s*%)%s*$")
          local field_decl
          if field then
            for _,f in ipairs(fields) do if f.name == field then field_decl = f end end
          end
          if not bind(pname, field_decl, "initializer", entry) then break end
        end
      end
      -- 2) Direct parameter-to-field assignments in the body bind the rest;
      -- any other statement is a transform the codec cannot model.
      local braces = ctor_braces or (ctor_body and ctor_body:match("%b{}"))
      if not ctor_error and braces then
        local compact = braces:gsub("[%s{};]", ""):gsub("this%->", "")
        for fname, pname in compact:gmatch("([%w_]+)=([%w_]+)") do
          local field_decl
          for _,f in ipairs(fields) do if f.name == fname then field_decl = f end end
          if not bind(pname, field_decl, "assignment", fname .. " = " .. pname) then break end
          compact = compact:gsub(fname .. "=" .. pname, "", 1)
        end
        if not ctor_error and compact ~= "" then
          ctor_error = "unsupported constructor body for `" .. name .. "`: only direct parameter-to-field assignments or initializer lists are supported"
        end
      end
      -- 3) Remaining parameters may share a field's name (bijective rename).
      if not ctor_error then
        for _,param in ipairs(params) do
          local _,pname = param:match("^(.-)%s+([%w_]+)$")
          if not bindings[pname] then
            for _,f in ipairs(fields) do
              if not mapped[f.name] and f.name == pname then
                if clean(ptype_of[pname]) == clean(f.type) then
                  bindings[pname], mapped[f.name] = f, true
                end
                break
              end
            end
          end
        end
      end
      -- 4) Positional order follows constructor parameter order.
      if not ctor_error then
        for _,param in ipairs(params) do
          local _,pname = param:match("^(.-)%s+([%w_]+)$")
          local bound = bindings[pname]
          if not bound then
            ctor_error = "unsupported constructor mapping for `" .. name .. "`: parameter `" .. pname .. "` does not map to a public field"
            break
          end
          order[#order+1] = bound
        end
      end
      if not ctor_error and #order ~= #fields then
        ctor_error = "unsupported constructor mapping for `" .. name .. "`: constructor does not map every public field"
      end
      fields = not ctor_error and order or fields
      if not ctor_error then
        ctor_fields = {}
        for _,field in ipairs(order) do ctor_fields[#ctor_fields+1] = field.name end
      end
    end
    if refcap and ctor then
      local params, param_field = split(ctor), {}
      local param_types = {}
      for _,param in ipairs(params) do
        local typ, pname = param:match("^(.-)%s+([%w_]+)$")
        if not typ then ctor_error = "unsupported constructor parameter in `" .. name .. "`: " .. param
        else param_types[pname] = typ end
      end
      for entry in (ctor_init or ""):gmatch("[^,]+") do
        local field, arg = entry:match("^%s*([%w_]+)%s*%(%s*([%w_]+)%s*%)%s*$")
        if field and param_types[arg] then
          local target
          for _,f in ipairs(fields) do if f.name == field then target = f end end
          if not target or clean(target.type) ~= clean(param_types[arg]) then
            ctor_error = "unsupported constructor mapping for `" .. name .. "`: initializer `" .. entry .. "`"
          else
            param_field[arg] = field
          end
        else
          local value = entry:match("^%s*[%w_]+%s*%(%s*([%w_]+)%s*%)%s*$")
          if value ~= "nullptr" and value ~= "true" and value ~= "false"
            and not (value and value:match("^[-+]?%d+$")) then
            ctor_error = "unsupported constructor initializer for `" .. name .. "`: `" .. entry .. "`"
          end
        end
      end
      local braces = ctor_braces or (ctor_body and ctor_body:match("%b{}"))
      if braces then
        local compact = braces:gsub("[%s{};]", ""):gsub("this%->", "")
        for field, pname in compact:gmatch("([%w_]+)=([%w_]+)") do
          local target
          for _,f in ipairs(fields) do if f.name == field then target = f end end
          if not target or not param_types[pname] or clean(target.type) ~= clean(param_types[pname]) then
            ctor_error = "unsupported constructor body for `" .. name .. "`: only direct parameter-to-field assignments are supported"
          else
            param_field[pname] = field
            compact = compact:gsub(field .. "=" .. pname, "", 1)
          end
        end
        if compact ~= "" then
          ctor_error = "unsupported constructor body for `" .. name .. "`: only direct parameter-to-field assignments are supported"
        end
      end
      ctor_fields = {}
      for _,param in ipairs(params) do
        local _,pname = param:match("^(.-)%s+([%w_]+)$")
        if param_field[pname] then ctor_fields[#ctor_fields+1] = param_field[pname]
        else ctor_error = "unsupported constructor mapping for `" .. name .. "`: parameter `" .. pname .. "` does not map to a stored field" end
      end
    end
    if refcap and ctor_fields then
      local ordered, seen = {}, {}
      for _,field_name in ipairs(ctor_fields) do
        for _,field in ipairs(fields) do
          if field.name == field_name and not seen[field_name] then
            ordered[#ordered+1] = field
            seen[field_name] = true
          end
        end
      end
      for _,field in ipairs(fields) do
        if not seen[field.name] then ordered[#ordered+1] = field end
      end
      fields = ordered
    end
    out[#out + 1] = {name=name, kind=kind, fields=fields, ctor=ctor and split(ctor) or nil,
      ctor_fields=ctor_fields, ctor_error=ctor_error, field_error=field_error, refcap=refcap,
      ctor_init=ctor_init, ctor_body=ctor_body, default_ctor=default_ctor,
      source=source:sub(start, i - 1)}
    pos = i
  end
  return out
end

local function helper_definition(t)
  if not t.source then
    return nil, "unsupported helper declaration `" .. t.name .. "`: original source is unavailable"
  end
  return t.source
end

local function codec(t, typename, qualify)
  local names, optionals, decoded, args, after, walk, encode, graph, preindex_fields = {}, {}, {}, {}, {}, {}, {}, {}, {}
  local indices = {}
  for i,f in ipairs(t.fields) do indices[f.name] = i end
  local ctor_fields = t.ctor_fields
  for i,f in ipairs(t.fields) do
    names[#names+1] = '"' .. f.name .. '"'
    local optional = clean(f.type):match("^optional<") ~= nil
    if optional or f.default then optionals[#optionals+1] = '"' .. f.name .. '"' end
    local access = (optional or f.default) and "fieldOpt" or "field"
    local read = "ncrt::from_json<" .. qualify(clean(f.type)) .. ">(ncrt::" .. access
      .. '(v, "' .. f.name .. '", ' .. (i-1) .. "))"
    if f.default then
      read = '(ncrt::has_field(v, "' .. f.name .. '", ' .. (i-1) .. ") ? "
        .. read .. " : " .. qualify(f.default) .. ")"
    end
    decoded[#decoded+1] = "  auto __f" .. i .. " = " .. read .. ";"
    preindex_fields[#preindex_fields+1] = "  ncrt::preindex_typed<" .. qualify(clean(f.type))
      .. ">(ncrt::fieldOpt(v, \"" .. f.name .. "\", " .. (i-1) .. "));"
    encode[#encode+1] = "  out.arr.push_back(ncrt::to_value(x." .. f.name .. "));"
    walk[#walk+1] = "  ncrt::walk_references(ptr->" .. f.name .. ", state);"
    graph[#graph+1] = '  out.obj.emplace_back("' .. f.name .. '", ncrt::to_value(ptr->' .. f.name .. "));"
  end
  local used = {}
  if t.ctor then
    for _,name in ipairs(ctor_fields or {}) do
      args[#args+1] = "std::move(__f" .. indices[name] .. ")"
      used[name] = true
    end
    for i,f in ipairs(t.fields) do
      if not used[f.name] then
        if f.type:match("^%s*const%s+") then
          return nil, nil, "unsupported constructor mapping for `" .. t.name .. "`: immutable field `" .. f.name .. "` is not a constructor parameter"
        end
        after[#after+1] = "  x." .. f.name .. " = std::move(__f" .. i .. ");"
      end
    end
  else
    for i in ipairs(t.fields) do args[#args+1] = "std::move(__f" .. i .. ")" end
  end
  local call = (t.ctor and "(" or "{") .. table.concat(args, ", ") .. (t.ctor and ")" or "}")
  local optional_count = 0
  for i = #t.fields, 1, -1 do
    local f = t.fields[i]
    if f.default or clean(f.type):match("^optional<") then optional_count = optional_count + 1 else break end
  end
  local validate = {
    '  if (!allow_identity) ncrt::reject_identity_tags(v, "' .. t.name .. '");',
    '  if (v.type != JV::ARR && v.type != JV::OBJ) throw std::runtime_error("record `' .. t.name .. '` input must be an array or object");',
    "  if (v.type == JV::ARR && (v.arr.size() < " .. (#t.fields-optional_count)
      .. " || v.arr.size() > " .. #t.fields .. ')) throw std::runtime_error("wrong field count for ' .. t.name .. '");',
    '  ncrt::check_object(v, "' .. t.name .. '", {' .. table.concat(names, ", ")
      .. "}, {" .. table.concat(optionals, ", ") .. "});",
  }
  local decl = "namespace ncrt { template<> struct Codec<" .. typename .. "> {\n"
    .. '  static const char *name() { return "' .. t.name .. '"; }\n'
    .. "  static void validate(const JV&, bool);\n"
    .. "  static " .. typename .. " decode(const JV&);\n"
    .. "  static void construct(const JV&, void*);\n"
    .. "  static void preindex(const JV&);\n"
    .. "  static JV encode(const " .. typename .. "&);\n"
    .. "  static void walk(const " .. typename .. "*, WalkState&);\n"
    .. "  static JV encode_ref(const " .. typename .. "*);\n}; }\n"
  local scope = "Codec<" .. typename .. ">::"
  local body = {
    "namespace ncrt {",
    "inline void " .. scope .. "validate(const JV& v, bool allow_identity) {",
    table.concat(validate, "\n"), "}",
    "inline void " .. scope .. "preindex(const JV& v) {",
    table.concat(preindex_fields, "\n"), "}",
    "inline " .. typename .. " " .. scope .. "decode(const JV& v) {",
    "  validate(v, false);", table.concat(decoded, "\n"),
  }
  if #after == 0 then
    body[#body+1] = "  return " .. typename .. call .. ";"
  else
    body[#body+1] = "  " .. typename .. " x" .. call .. ";"
    body[#body+1] = table.concat(after, "\n")
    body[#body+1] = "  return x;"
  end
  body[#body+1] = "}\ninline void " .. scope .. "construct(const JV& v, void* storage) {"
  body[#body+1] = "  validate(v, true);"
  body[#body+1] = table.concat(decoded, "\n")
  body[#body+1] = "  auto* ptr = ::new (storage) " .. typename .. call .. ";"
  if #after > 0 then
    body[#body+1] = "  auto& x = *ptr;"
    body[#body+1] = table.concat(after, "\n")
  end
  body[#body+1] = "}\ninline void " .. scope .. "walk(const " .. typename .. "* ptr, WalkState& state) {"
  body[#body+1] = "  if (!ptr) return;"
  body[#body+1] = table.concat(walk, "\n")
  body[#body+1] = "}\ninline JV " .. scope .. "encode(const " .. typename .. "& x) {"
  body[#body+1] = "  JV out; out.type = JV::ARR;"
  body[#body+1] = table.concat(encode, "\n")
  body[#body+1] = "  return out;\n}\ninline JV " .. scope .. "encode_ref(const " .. typename .. "* ptr) {"
  body[#body+1] = [[
  if (!ptr) return JV();
  auto& ctx = identity();
  auto found = ctx.encoded.find(ptr);
  JV out; out.type = JV::OBJ;
  JV id; id.type = JV::NUM;
  if (found != ctx.encoded.end()) {
    id.num = static_cast<double>(found->second);
    out.obj.emplace_back("$ref", std::move(id));
    return out;
  }
  auto key = ++ctx.next_id;
  ctx.encoded[ptr] = key;
  id.num = static_cast<double>(key);
  out.obj.emplace_back("$id", std::move(id));]]
  body[#body+1] = table.concat(graph, "\n")
  body[#body+1] = "  return out;\n}\n}"
  return decl, table.concat(body, "\n"), nil
end

--- Emit a codec per namespace that defines a record, plus a global alias when
--- the type exists at global scope. Call sites qualify record types with their
-- Scalar names that can never be records; everything else matching an
-- identifier is treated as a record reference when collecting reachability.
local SCALAR_NAMES = {
  ["int"]=true, ["long"]=true, ["long long"]=true, ["unsigned"]=true,
  ["unsigned int"]=true, ["unsigned long"]=true, ["unsigned long long"]=true,
  ["uint32_t"]=true, ["uint64_t"]=true, ["int32_t"]=true, ["int64_t"]=true,
  ["size_t"]=true, ["double"]=true, ["float"]=true, ["bool"]=true,
  ["char"]=true, ["string"]=true, ["void"]=true,
}

--- Record names a serialized type references directly: vector elements, map
--- values, optional inners and pointer targets recurse into the same treatment.
local function type_records(t, out)
  t = clean(t)
  local vector = t:match("^vector<(.+)>$")
  if vector then return type_records(vector, out) end
  if t:match("^map<") then
    local inner = t:match("^map<(.+)>$")
    local depth, from = 0, nil
    for i = 1, #inner do
      local c = inner:sub(i, i)
      if c == "<" or c == "(" then depth = depth + 1
      elseif c == ">" or c == ")" then depth = depth - 1
      elseif c == "," and depth == 0 then from = i; break end
    end
    if from then return type_records(inner:sub(from + 1), out) end
    return
  end
  local opt = t:match("^optional<(.+)>$")
  if opt then return type_records(opt, out) end
  local bare = t:gsub("%*$", "")
  local simple = bare:match("([^:]+)$") or bare
  if simple:match("^[%w_]+$") and not SCALAR_NAMES[simple]
    and simple ~= "ListNode" and simple ~= "TreeNode" then
    out[simple] = true
  end
end
local function valid_schema_type(t, known)
  t = clean(t)
  if SCALAR_NAMES[t] then return true end
  local inner = t:match("^vector<(.+)>$") or t:match("^optional<(.+)>$")
  if inner then return valid_schema_type(inner, known) end
  local map = t:match("^map<(.+)>$")
  if map then
    local args = split(map)
    return #args == 2 and clean(args[1]) == "string" and valid_schema_type(args[2], known)
  end
  local ptr = t:match("^([%w_:]+)%*$")
  if ptr then
    local simple = ptr:match("([^:]+)$") or ptr
    return simple == "ListNode" or simple == "TreeNode" or known[simple] ~= nil
  end
  local simple = t:match("([^:]+)$") or t
  return t:match("^[%w_:]+$") ~= nil and known[simple] ~= nil
end
local function pointer_targets(t, out)
  t = clean(t)
  local inner = t:match("^vector<(.+)>$") or t:match("^optional<(.+)>$")
  if inner then return pointer_targets(inner, out) end
  local map = t:match("^map<(.+)>$")
  if map then
    local args = split(map)
    return pointer_targets(args[2] or "", out)
  end
  local bare = t:match("^(.+)%*$")
  if bare then return type_records(bare, out) end
end

--- Fixpoint closure over record fields starting from serialized signature
--- types. Algorithm-internal records the signatures never touch stay out.
local function reachable(roots, decls_by_name)
  local seen, frontier = {}, {}
  local function add_name(name)
    if not seen[name] then seen[name] = true; frontier[#frontier+1] = name end
  end
  for _,t in ipairs(roots or {}) do
    local names = {}
    type_records(t, names)
    for name in pairs(names) do add_name(name) end
  end
  while #frontier > 0 do
    for _, d in ipairs(decls_by_name[table.remove(frontier)] or {}) do
      for _,f in ipairs(d.fields) do
        local names = {}
        type_records(f.type, names)
        for name in pairs(names) do add_name(name) end
      end
    end
  end
  return seen
end

--- Shared reachability computation for generate/defined_records: the closure
--- of record types reachable from the serialized signature roots.
function M.reachable_set(starter, code, ref, target, roots)
  local decls_by_name = {}
  local function add_declarations(src)
    for _,d in ipairs(declarations(src)) do
      decls_by_name[d.name] = decls_by_name[d.name] or {}
      table.insert(decls_by_name[d.name], d)
    end
  end
  add_declarations(comments(starter or ""))
  add_declarations(starter or "")
  add_declarations(code or "")
  add_declarations(ref or "")
  if not roots then
    local all = {}
    for name,d in pairs(decls_by_name) do
      if name ~= "Solution" and name ~= target and name ~= "ListNode" and name ~= "TreeNode" then
        all[name] = true
      end
    end
    return all
  end
  return reachable(roots, decls_by_name)
end

function M.generate(starter, code, ref, target, roots)
  local definitions, codec_decls, codec_bodies = {}, {}, {}
  local globals, namespaced, comment_injected = {}, {}, {}
  local function skip(name)
    return name == "Solution" or name == target or name == "ListNode" or name == "TreeNode"
  end
  local reach = M.reachable_set(starter, code, ref, target, roots)
  local refcap_targets = {}
  for _,t in ipairs(roots or {}) do pointer_targets(t, refcap_targets) end
  for _,src in ipairs({comments(starter or ""), starter or "", code or "", ref or ""}) do
    for _,d in ipairs(declarations(src)) do
      if reach[d.name] then
        for _,f in ipairs(d.fields) do
          pointer_targets(f.type, refcap_targets)
        end
      end
    end
  end
  -- Records the actual sources mention (but that are not serialized) still
  -- need their documented definitions injected for the code to compile.
  local referenced = {}
  local usage = (code or "") .. "\n" .. (ref or "")
  local user_names, ref_names = {}, {}
  for _,d in ipairs(declarations(code or "")) do user_names[d.name] = true end
  for _,d in ipairs(declarations(ref or "")) do ref_names[d.name] = true end
  local actual_names = {}
  for name in pairs(user_names) do
    if not ref or ref_names[name] then actual_names[name] = true end
  end
  local starterDecls, err = declarations(starter or "")
  if err then return nil, nil, nil, err end
  local commentDecls, e = declarations(comments(starter or ""))
  if e then return nil, nil, nil, e end
  for _,d in ipairs(starterDecls) do
    if not skip(d.name) and not globals[d.name] and not actual_names[d.name] then
      d.refcap = refcap_targets[d.name] or false
      if reach[d.name] then
        if d.field_error then return nil, nil, nil, d.field_error end
        if d.ctor_error then return nil, nil, nil, d.ctor_error end
      elseif not usage:find("%f[%w]" .. d.name .. "%f[^%w]") then
        goto continue_starter
      end
      local body, derr = helper_definition(d)
      if not body then return nil, nil, nil, derr end
      definitions[#definitions+1] = body .. ";"
      globals[d.name] = d
      comment_injected[d.name] = true
      if reach[d.name] then
        local decl, body, ce = codec(d,d.name, function(t) return t end)
        if not decl then return nil, nil, nil, ce end
        codec_decls[#codec_decls+1], codec_bodies[#codec_bodies+1] = decl, body
      end
      ::continue_starter::
    end
  end
  for _,d in ipairs(commentDecls) do
    if not skip(d.name) and not globals[d.name] and not actual_names[d.name] then
      d.refcap = refcap_targets[d.name] or false
      if reach[d.name] then
        if d.field_error then return nil, nil, nil, d.field_error end
        if d.ctor_error then return nil, nil, nil, d.ctor_error end
      elseif not usage:find("%f[%w]" .. d.name .. "%f[^%w]") then
        goto continue_comment
      end
      local body, derr = helper_definition(d)
      if not body then return nil, nil, nil, derr end
      definitions[#definitions+1] = body .. ";"
      globals[d.name] = d
      comment_injected[d.name] = true
      if reach[d.name] then
        local decl, body, ce = codec(d,d.name, function(t) return t end)
        if not decl then return nil, nil, nil, ce end
        codec_decls[#codec_decls+1], codec_bodies[#codec_bodies+1] = decl, body
      end
      ::continue_comment::
    end
  end
  for _,entry in ipairs({{"usersol",code or ""},{"refsol",ref or ""}}) do
    local parsed,pe=declarations(entry[2]); if pe then return nil, nil, nil, pe end
    local own_types = {}
    for _,record in ipairs(parsed) do own_types[record.name] = true end
    local function qualify(t)
      -- Already-qualified names (`usersol::Point`) must stay as they are.
      -- Rewriting the trailing identifier again produces `usersol::usersol::Point`.
      return (t:gsub("()([%a_][%w_]*)", function(pos, word)
        if t:sub(pos - 2, pos - 1) == "::" then return word end
        if not own_types[word] then return word end
        return entry[1] .. "::" .. word
      end))
    end
    for _,d in ipairs(parsed) do
      d.refcap = refcap_targets[d.name] or false
      if not skip(d.name) and reach[d.name] then
        if d.field_error then return nil, nil, nil, d.field_error end
        if #d.fields==0 then return nil, nil, nil,"unsupported record `" .. d.name .. "`: no public data fields detected (supported declarations require direct public fields)" end
        if d.ctor_error then return nil, nil, nil, d.ctor_error end
        -- Graph objects are placement-constructed through their declared
        -- constructor; no synthetic default constructor is required.
        local decl, body, ce=codec(d,entry[1].."::"..d.name, qualify)
        if not decl then return nil, nil, nil, ce end
        codec_decls[#codec_decls+1], codec_bodies[#codec_bodies+1] = decl, body
        namespaced[d.name] = namespaced[d.name] or {}
        namespaced[d.name][entry[1]] = d
        if not globals[d.name] then globals[d.name] = d end
      end
    end
  end
  for _,src in ipairs({starter or "",code or "",ref or ""}) do
    local parsed,e=declarations(src)
    if e then return nil, nil, nil, e end
    for _,d in ipairs(parsed) do
      if reach[d.name] then
        for _,f in ipairs(d.fields) do
          if not valid_schema_type(f.type, globals) then
            return nil, nil, nil, "record `" .. d.name .. "` has unsupported serialized field type `" .. f.type .. "`"
          end
        end
      end
    end
  end
  -- Pointer fields must target a record we know: ListNode/TreeNode keep their
  -- runtime encodings, everything else needs a generated codec.
  for _,d in pairs(globals) do
    local targets = {}
    for _,f in ipairs(d.fields) do pointer_targets(f.type, targets) end
    for bare in pairs(targets) do
      if bare ~= "ListNode" and bare ~= "TreeNode" and not globals[bare] then
        return nil, nil, nil, "record `" .. d.name .. "` contains a pointer to `" .. bare
          .. "`, which is not a known record type"
      end
    end
  end
  local aliases = {}
  for name in pairs(namespaced) do
    if not comment_injected[name] then
      aliases[#aliases+1] = "using " .. name .. " = usersol::" .. name .. ";"
    end
  end
  for name in pairs(reach) do
    if not globals[name] then
      return nil, nil, nil, "serialized field references `" .. name .. "`, which is not a known record type"
    end
  end
  return table.concat(definitions,"\n"),
    table.concat(codec_decls, "\n") .. "\n" .. table.concat(codec_bodies, "\n"),
    table.concat(aliases,"\n"), nil
end

--- Records the driver's call sites may reference, per namespace: documented
--- comment helpers (global scope, visible to both namespaces) plus each
--- namespace's own definitions. Namespace definitions shadow comment ones.
--- With `roots` the map is limited to the reachable closure; internal records
--- the signatures never touch are absent, so call sites never qualify them.
function M.defined_records(starter, code, ref, target, roots)
  local reach = M.reachable_set(starter, code, ref, target, roots)
  local out = {}
  local comment_records = {}
  for _,d in ipairs(declarations(comments(starter or ""))) do
    if d.name ~= "Solution" and d.name ~= target and d.name ~= "ListNode" and d.name ~= "TreeNode"
      and #d.fields > 0 and reach[d.name] then comment_records[d.name] = { refcap = d.refcap, global = true } end
  end
  for _,d in ipairs(declarations(starter or "")) do
    if d.name ~= "Solution" and d.name ~= target and d.name ~= "ListNode" and d.name ~= "TreeNode"
      and #d.fields > 0 and reach[d.name] and not comment_records[d.name] then
      comment_records[d.name] = { refcap = d.refcap, global = true }
    end
  end
  for _,entry in ipairs({{"usersol",code or ""},{"refsol",ref or ""}}) do
    local names = {}
    for name,info in pairs(comment_records) do names[name] = info end
    for _,d in ipairs(declarations(entry[2])) do
      if d.name ~= "Solution" and d.name ~= target and d.name ~= "ListNode" and d.name ~= "TreeNode"
        and #d.fields > 0 and reach[d.name] then names[d.name] = { refcap = d.refcap, global = false } end
    end
    out[entry[1]] = names
  end
  return out
end

return M
