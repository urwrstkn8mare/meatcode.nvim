local M = {}

--- Replace comments (including nested block comments) and string literals
--- (standard, multiline, raw #) with spaces, preserving newlines and 1-to-1 byte positions.
local function lexical_strip(src)
  if type(src) ~= "string" then return "" end
  local out, comments = {}, {}
  local i = 1
  local len = #src
  while i <= len do
    local ch = src:sub(i, i)
    local next_ch = src:sub(i + 1, i + 1)

    if ch == "/" and next_ch == "/" then
      local first = i
      while i <= len and src:sub(i, i) ~= "\n" do
        out[#out + 1] = " "
        i = i + 1
      end
      comments[#comments+1] = src:sub(first+2,i-1)
      if i <= len and src:sub(i, i) == "\n" then
        out[#out + 1] = "\n"
        i = i + 1
      end
    elseif ch == "/" and next_ch == "*" then
      local first = i
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
      comments[#comments+1] = src:sub(first+2,i-3):gsub("^%*+", ""):gsub("\n[ \t]*%*[ \t]?", "\n")
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
  return table.concat(out), table.concat(comments,"\n")
end
M.strip = lexical_strip
local strip = lexical_strip
local function split(text)
  local out, start, depth = {}, 1, 0
  for i = 1, #text + 1 do
    local c = text:sub(i, i)
    if c == "[" or c == "(" or c == "<" then depth = depth + 1
    elseif c == "]" or c == ")" or c == ">" then depth = depth - 1
    elseif (c == "," and depth == 0) or i == #text + 1 then
      local part = vim.trim(text:sub(start, i - 1))
      if part ~= "" then out[#out + 1] = part end
      start = i + 1
    end
  end
  return out
end

local scalar_types = {
  Int=true, Int8=true, Int16=true, Int32=true, Int64=true,
  UInt=true, UInt8=true, UInt16=true, UInt32=true, UInt64=true,
  Double=true, Float=true, Bool=true, String=true, Character=true,
  ListNode=true, TreeNode=true,
}

local function closing(src, open)
  local depth = 1
  for i = open + 1, #src do
    local c = src:sub(i,i)
    if c == "{" then depth=depth+1 elseif c == "}" then depth=depth-1 end
    if depth == 0 then return i end
  end
end

local function descriptors(original)
  local src, result = strip(original), {}
  for _,kind in ipairs({"class","struct"}) do
    for at,name in src:gmatch("()%f[%a]"..kind.."%s+([%w_]+)[^{}\n]*{") do
      local open = src:find("{",at,true)
      local close = closing(src,open)
      if close then
        local body = src:sub(open+1,close-1)
        local raw = original:sub(open+1,close-1)
        local d = {name=name,kind=kind,fields={},params={},source=original:sub(at,close)}
        local top, pos = {}, 1
        while pos <= #body do
          local brace = body:find("{",pos,true)
          if not brace then top[#top+1]=body:sub(pos);break end
          local finish = closing(body,brace)
          if not finish then break end
          local prefix = body:sub(pos,brace-1)
          -- Computed properties are not stored fields.
          prefix = prefix:gsub("[^\n;]*%f[%a]var%s+[%w_]+%s*:[^\n;]*$", function(text) return text:gsub("[^\n]"," ") end)
          top[#top+1]=prefix
          top[#top+1]=body:sub(brace,finish):gsub("[^\n]"," ")
          pos=finish+1
        end
        for offset,line in table.concat(top):gmatch("()([^\n;]+)") do
          local declaration=line:match("%f[%a](var%s+.*)") or line:match("%f[%a](let%s+.*)")
          if declaration then
            local mut,field,typ=declaration:match("^(%w+)%s+([%w_]+)%s*:%s*([^=;]+)")
            if not field then d.ambiguous=true else
              local raw_line=raw:sub(offset,offset+#line-1)
              d.fields[#d.fields+1]={name=field,type=typ:gsub("%s+",""),mutable=mut=="var",default=raw_line:match("=%s*(.-)%s*$")}
            end
          end
        end
        local start, finish, parameters = body:find("%f[%a]init%s*%((.-)%)")
        if start then
          local brace = body:find("{",finish+1,true)
          local ending = brace and closing(body,brace)
          d.init_body = ending and body:sub(brace+1,ending-1) or ""
          if body:find("%f[%a]init%s*%(",finish+1) then d.ambiguous=true end
          local paren = body:find("(",start,true)
          parameters = raw:sub(paren+1,finish-1)
          for _,p in ipairs(split(parameters)) do
            local external,internal,typ=p:match("^([%w_]+)%s+([%w_]+)%s*:%s*([^=]+)")
            if not typ then internal,typ=p:match("^([%w_]+)%s*:%s*([^=]+)");external=internal end
            if not internal then d.ambiguous=true else
              d.params[#d.params+1]={external=external,name=internal,type=typ:gsub("%s+",""),default=p:match("=%s*(.-)%s*$")}
            end
          end
        end
        result[name]=d
      end
    end
  end
  return result
end

function M.types(src)
  local out = {}
  for name in pairs(descriptors(src)) do out[name] = true end
  return out
end

function M.extensions(src, namespace, target, roots)
  local available,types,chunks=descriptors(src),{},{}
  if roots then
    local function visit(typ)
      typ=typ:gsub("%s+","")
      if typ:sub(-1)=="?" then visit(typ:sub(1,-2));return end
      local inner=typ:match("^%[(.*)%]$")
      if inner then visit(inner:match("^String:(.*)$") or inner);return end
      if scalar_types[typ] or types[typ] or not available[typ] then return end
      types[typ]=available[typ]
      for _,field in ipairs(types[typ].fields) do visit(field.type) end
    end
    for _,typ in ipairs(roots) do visit(typ) end
  else types=available;types[target or "Solution"]=nil end
  local function qualified(typ)
    return typ:gsub("[%a_][%w_]*",function(name)
      return scalar_types[name] and name or namespace.."."..name
    end)
  end
  local function supported(typ)
    if typ:sub(-1)=="?" then return supported(typ:sub(1,-2)) end
    local inner=typ:match("^%[(.*)%]$")
    if inner then return supported(inner:match("^String:(.*)$") or inner) end
    return scalar_types[typ] or types[typ] ~= nil
  end
  for name,d in pairs(types) do
    d.order, d.labels, d.defaults = {}, {}, {}
    if d.ambiguous then return nil,nil,"unsupported Swift initializer mapping for "..name end
    for _,field in ipairs(d.fields) do
      if not supported(field.type) then return nil,nil,"unsupported Swift field type "..name.."."..field.name..": "..field.type end
    end
    if d.init_body then
      local assigned, seen = {}, {}
      for statement in d.init_body:gmatch("[^\n;]+") do
        if vim.trim(statement) ~= "" then
          local field,param=statement:match("^%s*self%.([%w_]+)%s*=%s*([%w_]+)%s*$")
          if not field then field,param=statement:match("^%s*([%w_]+)%s*=%s*([%w_]+)%s*$") end
          if not field or assigned[param] or seen[field] then
            return nil,nil,"unsupported Swift initializer mapping for "..name
          end
          assigned[param],seen[field]=field,true
        end
      end
      for _,p in ipairs(d.params) do
        local found
        for i,f in ipairs(d.fields) do if f.name==assigned[p.name] then found=i;break end end
        if not found then return nil,nil,"unsupported Swift initializer mapping for "..name end
        d.order[#d.order+1]=found
        d.labels[#d.labels+1]=p.external=="_" and "" or p.external
        d.defaults[#d.order]=p.default
      end
      if #d.order~=#d.fields then return nil,nil,"unsupported Swift initializer mapping for "..name end
    elseif d.kind=="class" and #d.fields>0 then
      return nil,nil,"unsupported Swift class without an explicit field initializer: "..name
    else
      for i,f in ipairs(d.fields) do
        if not f.mutable and f.default then return nil,nil,"unsupported Swift initializer mapping for "..name end
        d.order[i]=i;d.labels[i]=f.name;d.defaults[i]=f.default
      end
    end
  end
  local function shell(typ,active)
    if typ:sub(-1)=="?" then return "nil" end
    if typ:sub(1,1)=="[" then return typ:find(":",1,true) and "[:]" or "[]" end
    if typ=="Bool" then return "false" end
    if typ=="String" then return '""' end
    if typ=="Character" then return 'Character(" ")' end
    if typ=="ListNode" or typ=="TreeNode" then return typ.."()" end
    if scalar_types[typ] then return "0" end
    local d=types[typ]
    if not d or active[typ] then return nil end
    active[typ]=true
    local args={}
    for i,fi in ipairs(d.order) do
      local value=shell(d.fields[fi].type,active)
      if not value then active[typ]=nil;return nil end
      args[#args+1]=(d.labels[i]~="" and d.labels[i]..": " or "")..value
    end
    active[typ]=nil
    return namespace.."."..typ.."("..table.concat(args,", ")..")"
  end
  for name,d in pairs(types) do
    local enc,args,positional,named,populate,shell_args,field_names={},{},{},{},{},{},{}
    local shell_error
    for i,fi in ipairs(d.order) do
      local f=d.fields[fi]
      local typ=qualified(f.type)
      local prefix=d.labels[i]~="" and d.labels[i]..": " or ""
      field_names[#field_names+1]='"'..f.name..'"'
      enc[#enc+1]="try self."..f.name..".toJSON()"
      args[#args+1]=prefix.."v"..i
      local missing=d.defaults[i] and "v"..i.." = "..d.defaults[i].."\n"
        or 'throw mcError("missing required field: '..f.name..'")'
      positional[#positional+1]="let v"..i..": "..typ.."; if values.count > "..(i-1).." { v"..i.." = try mcDecode(values["..(i-1).."], "..typ..".self) } else { "..missing.." }"
      named[#named+1]='let v'..i..': '..typ..'; if let raw = obj["'..f.name..'"] { v'..i..' = try mcDecode(raw, '..typ..'.self) } else { '..missing..' }'
      if d.kind=="class" then
        local value=shell(f.type,{[name]=true})
        if not f.mutable then shell_error="unsupported Swift identity field "..name.."."..f.name..": field must be mutable"
        elseif not value then shell_error="unsupported Swift identity shell field "..name.."."..f.name..": "..f.type end
        if value then shell_args[#shell_args+1]=prefix..value end
        populate[#populate+1]='if let raw = obj["'..f.name..'"] { instance.'..f.name..' = try mcDecode(raw, '..typ..'.self) } else { '
          ..(d.defaults[i] and "instance."..f.name.." = "..d.defaults[i].."\n" or 'throw mcError("missing required field: '..f.name..'")')..' }'
      end
    end
    local allowed="Set(["..table.concat(field_names,",").."])"
    local guard='guard Set(obj.keys).isSubset(of: '..allowed..') else { throw mcError("unknown fields for '..name..'") }; '
    local identity_decode,identity_encode="","["..table.concat(enc,", ").."]"
    if d.kind=="class" then
      local fields={}
      for _,fi in ipairs(d.order) do
        local f=d.fields[fi]
        fields[#fields+1]='"'..f.name..'": try self.'..f.name..".toJSON()"
      end
      identity_encode="try mcEncodeReference(self, fields: { "..(#fields==0 and "[:]" or "["..table.concat(fields,", ").."]").." }, positional: { ["..table.concat(enc,", ").."] })"
      local branch=shell_error and 'throw mcError("'..shell_error..'")'
        or "return (try mcReference(value, "..namespace.."."..name..".self, allocate: { "..namespace.."."..name.."("..table.concat(shell_args,", ")..") }, populate: { instance, obj in guard Set(obj.keys).subtracting([\"$id\"]).isSubset(of: "..allowed..") else { throw mcError(\"unknown fields for "..name.."\") }; "..table.concat(populate,"; ").." })) as! Self"
      identity_decode='if let object = value as? [String: Any], object["$id"] != nil || object["$ref"] != nil { '..branch.." }\n"
    else
      guard='guard obj["$id"] == nil && obj["$ref"] == nil else { throw mcError("identity tags are invalid for Swift value type '..name..'") }; '..guard
    end
    local make=(d.kind=="class" and namespace.."."..name or "Self").."("..table.concat(args,", ")..")"
    chunks[#chunks+1]="extension "..namespace.."."..name..": MCJSON {\nstatic func fromJSON(_ value: Any) throws -> Self {\n"..identity_decode
      .."if let values = value as? [Any] { guard values.count <= "..#d.order.." else { throw mcError(\"wrong positional field count for "..name.."\") }; "..table.concat(positional,"; ")..(#positional>0 and "; " or "").."return "..make.." as! Self }\n"
      .."guard let obj = value as? [String: Any] else { throw mcError(\"expected object or positional array for "..name.."\") }; "..guard..table.concat(named,"; ")..(#named>0 and "; " or "").."return "..make.." as! Self\n"
      .."}\nstatic var mcHasReferences: Bool { "
      ..(d.kind=="class" and "true" or #d.order==0 and "false" or table.concat(vim.tbl_map(function(fi) return qualified(d.fields[fi].type)..".self.mcHasReferences" end,d.order)," || "))
      .." }\nfunc toJSON() throws -> Any { return "..identity_encode.." }\nfunc mcProbe(_ visited: inout Set<ObjectIdentifier>) -> Bool {\n"
      ..(d.kind=="class" and "if !visited.insert(ObjectIdentifier(self)).inserted { return true }\n" or "")
      .."var shared = false\n"..table.concat(vim.tbl_map(function(fi) return "if self."..d.fields[fi].name..".mcProbe(&visited) { shared = true }" end,d.order),"\n")
      .."\nreturn shared\n}\n}\n"
  end
  table.sort(chunks)
  return table.concat(chunks,"\n"),types
end
function M.documented_helpers(starter, actual, target)
  local _,comments=lexical_strip(starter or "")
  local definitions=descriptors(comments)
  for name,d in pairs(descriptors(starter or "")) do definitions[name]=d end
  local existing=descriptors(actual or "")
  local out={}
  for name,d in pairs(definitions) do
    if name~=(target or "Solution") and not scalar_types[name] and not existing[name] then out[#out+1]=d.source end
  end
  table.sort(out)
  return table.concat(out,"\n")
end

return M
