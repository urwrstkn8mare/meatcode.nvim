local M = {}

local function lexical(source)
  local out,comments,i={}, {},1
  while i<=#source do
    local first=i
    local c,pair=source:sub(i,i),source:sub(i,i+1)
    local hashes=source:match('^r(#*)"',i)
    if pair=="//" then
      i=source:find("\n",i+2,true) or #source+1
      comments[#comments+1]=source:sub(first+2,i-1)
    elseif pair=="/*" then
      local depth=1;i=i+2
      while i<=#source and depth>0 do
        pair=source:sub(i,i+1)
        if pair=="/*" then depth=depth+1;i=i+2
        elseif pair=="*/" then depth=depth-1;i=i+2
        else i=i+1 end
      end
      local body=source:sub(first+2,i-3)
      comments[#comments+1]=body:gsub("\n%s*%* ?", "\n")
    elseif hashes then
      local ending=source:find('"'..hashes,i+#hashes+2,true)
      i=ending and ending+#hashes+1 or #source+1
    elseif c=='"' then
      i=i+1
      while i<=#source do
        c=source:sub(i,i);i=i+1
        if c=="\\" then i=i+1 elseif c=='"' then break end
      end
    elseif c=="'" then
      local ending=i+1
      while ending<=math.min(#source,i+16) do
        local ch=source:sub(ending,ending)
        if ch=="\\" then ending=ending+2
        elseif ch=="'" then break
        else ending=ending+1 end
      end
      local body=source:sub(i+1,ending-1)
      if source:sub(ending,ending)=="'" and
        (#body==1 or body:match("^\\u%b{}$") or (#body==2 and body:sub(1,1)=="\\")
          or (#body<=4 and not body:find("[%z\1-\127]"))) then i=ending+1
      else i=i+1;out[#out+1]=c;first=i end
    else i=i+1;out[#out+1]=c;first=i end
    if i>first then out[#out+1]=source:sub(first,i-1):gsub("[^\n]"," ") end
  end
  return table.concat(out),table.concat(comments,"\n")
end
function M.strip(source) return (lexical(source or "")) end

local function balanced(text, start, open, close)
  if text:sub(start,start) ~= open then return nil end
  local depth, quote, escaped = 0, nil, false
  for i=start,#text do
    local c=text:sub(i,i)
    if quote then
      if escaped then escaped=false elseif c=="\\" then escaped=true elseif c==quote then quote=nil end
    elseif c=='"' then quote=c
    elseif c==open then depth=depth+1
    elseif c==close then depth=depth-1;if depth==0 then return text:sub(start+1,i-1),i end end
  end
end
local function split(text)
  local out,start,depth={},1,0
  for i=1,#text+1 do
    local c=text:sub(i,i)
    if c=='<' or c=='(' or c=='[' or c=='{' then depth=depth+1
    elseif c=='>' or c==')' or c==']' or c=='}' then depth=depth-1
    elseif (c==',' and depth==0) or i==#text+1 then
      local part=vim.trim(text:sub(start,i-1));if part~='' then out[#out+1]=part end;start=i+1
    end
  end
  return out
end
local function declarations(source,exclude,documented)
  local actual,comments=lexical(source or "")
  local records={}
  local function scan(original,masked,is_documented)
    local at=1
    while true do
      local s,e,name=masked:find("struct%s+([%a_][%w_]*)%s*{",at)
      if not s then break end
      local brace=masked:find("{",e)
      local body,finish=balanced(masked,brace,"{","}")
      if not body then return nil,"unsupported Rust struct declaration `"..name.."`: unclosed body" end
      if name~=exclude and not (is_documented and (name=="ListNode" or name=="TreeNode")) then
        local fields,schema_error={}
        for _,part in ipairs(split(body)) do
          local field,typ=part:match("^(.-):%s*(.+)$")
          field=field and field:gsub("^pub%s*%b()%s*",""):gsub("^pub%s+","")
          if not field or not field:match("^[%a_][%w_]*$") then
            schema_error="unsupported Rust struct `"..name.."`: only plain named fields can be serialized"
          elseif typ:find("#%s*%[") or typ:find("=") then
            schema_error="unsupported Rust field declaration in `"..name.."."..field.."`"
          else fields[#fields+1]={name=field,type=vim.trim(typ)} end
        end
        local first=masked:sub(1,s-1):match("()pub%s*%b()%s*$") or masked:sub(1,s-1):match("()pub%s+$") or s
        while true do
          local attr=masked:sub(1,first-1):match("()#%b[]%s*$")
          if not attr then break end
          first=attr
        end
        local definitions={original:sub(first,finish)}
        local pos=1
        while true do
          local start,ending=masked:find("impl%s+"..name.."%s*{",pos)
          if not start then break end
          local opening=masked:find("{",ending)
          local _,last=balanced(masked,opening,"{","}")
          if not last then break end
          definitions[#definitions+1]=original:sub(start,last)
          pos=last+1
        end
        records[name]={name=name,fields=fields,source=table.concat(definitions,"\n"),schema_error=schema_error}
      end
      at=finish+1
    end
    return true
  end
  if documented~=false then
    local ok,err=scan(comments,M.strip(comments),true)
    if not ok then return nil,err end
  end
  local ok,err=scan(source or "",actual,false)
  if not ok then return nil,err end
  return records
end
local function canonical(t)
  return (t:gsub("%s+",""):gsub("std::collections::HashMap", "HashMap"):gsub("std::collections::BTreeMap", "BTreeMap"):gsub("std::vec::Vec","Vec"):gsub("std::string::String","String"):gsub("std::rc::Rc","Rc"):gsub("std::cell::RefCell","RefCell"):gsub("std::option::Option","Option"):gsub("std::boxed::Box","Box"))
end
M.canonical=canonical
local function supported(t,records)
  t=canonical(t)
  if ({i8=true,i16=true,i32=true,i64=true,isize=true,u8=true,u16=true,u32=true,u64=true,usize=true,f32=true,f64=true,bool=true,char=true,String=true})[t] then return true end
  if t=="Option<Box<ListNode>>" or t=="Option<Rc<RefCell<TreeNode>>>" then return true end
  if records[t] then return true end
  local inner=t:match("^Vec<(.*)>$") or t:match("^Box<(.*)>$") or t:match("^Option<(.*)>$")
  if inner then return supported(inner,records) end
  inner=t:match("^BTreeMap<String,(.*)>$")
  if inner then return supported(inner,records) end
  inner=t:match("^Rc<RefCell<(.*)>>$")
  return inner and records[inner]~=nil or false
end
local function ctor_fields(source,name,fields)
  local by_name={}
  for _,field in ipairs(fields) do by_name[field.name]=true end
  for impl_body in M.strip(source):gmatch("impl%s+"..name.."%s*(%b{})") do
    local _,finish,args=impl_body:find("fn%s+new%s*(%b())")
    if args then
      local params,parameter_names={},{}
      for _,part in ipairs(split(args:sub(2,-2))) do
        local pname=part:match("^mut%s+([%a_][%w_]*)%s*:") or part:match("^([%a_][%w_]*)%s*:")
        if pname then params[#params+1]=pname;parameter_names[pname]=true end
      end
      local open=impl_body:find("{",finish+1,true)
      local body=open and balanced(impl_body,open,"{","}")
      body=body and vim.trim(body):gsub("^return%s+",""):gsub(";%s*$","")
      local literal=body and (body:match("^Self%s*(%b{})$") or body:match("^"..name.."%s*(%b{})$"))
      if literal then
        local assigned,seen,valid={},{},true
        for _,part in ipairs(split(literal:sub(2,-2))) do
          local field,param=part:match("^([%w_]+)%s*:%s*([%w_]+)$")
          if not field then field=part:match("^([%w_]+)$");param=field end
          if not field or not by_name[field] or not parameter_names[param] or assigned[param] or seen[field] then valid=false;break end
          assigned[param],seen[field]=field,true
        end
        if valid and #params==#fields then
          local order={}
          for _,param in ipairs(params) do if not assigned[param] then valid=false;break end;order[#order+1]=assigned[param] end
          if valid then return order end
        end
      end
    end
  end
end
local function default_expr(t,records,seen)
  t=canonical(t)
  if t:match("^Vec<") then return "Vec::new()" end
  if t:match("^BTreeMap<String,") then return "BTreeMap::new()" end
  if t:match("^Option<") then return "None" end
  local boxed=t:match("^Box<(.*)>$")
  if boxed then local value=default_expr(boxed,records,seen);return value and "Box::new("..value..")" or nil end
  local pointed=t:match("^Rc<RefCell<(.*)>>$")
  if pointed then local value=default_expr(pointed,records,seen);return value and "Rc::new(RefCell::new("..value.."))" or nil end
  if records[t] then
    if seen[t] then return nil end
    seen[t]=true;local fields={}
    for _,field in ipairs(records[t].fields) do
      local value=default_expr(field.type,records,seen);if not value then seen[t]=nil;return nil end
      fields[#fields+1]=field.name..":"..value
    end
    seen[t]=nil;return t.."{"..table.concat(fields,",").."}"
  end
  if ({i8=true,i16=true,i32=true,i64=true,isize=true,u8=true,u16=true,u32=true,u64=true,usize=true,f32=true,f64=true,bool=true,char=true,String=true})[t] then return "Default::default()" end
end
local function codec(record,records)
  local ordered={}
  if record.order then
    local by_name={}
    for _,f in ipairs(record.fields) do by_name[f.name]=f end
    for _,name in ipairs(record.order) do ordered[#ordered+1]=by_name[name] end
  else
    for _,f in ipairs(record.fields) do ordered[#ordered+1]=f end
  end
  local code={'impl FromJson for '..record.name..' { fn from_json(value:Json)->Result<Self,String> { match value {',
    'Json::Array(fields)=>{ if fields.len()!='..#ordered..'{return Err("wrong field count for '..record.name..'".into());} let mut values=fields.into_iter();Ok(Self {'}
  for _,f in ipairs(ordered) do code[#code+1]=f.name..':<'..f.type..' as FromJson>::from_json(values.next().unwrap())?,' end
  code[#code+1]='}) }, Json::Object(mut m)=>{ if m.contains_key("$id")||m.contains_key("$ref"){return Err("identity tags are unsupported on value record '..record.name..'".into());} let result=Self {'
  for _,f in ipairs(ordered) do code[#code+1]=f.name..':<'..f.type..' as FromJson>::from_json(m.remove("'..f.name..'").ok_or("missing required field '..record.name..'.'..f.name..'")?)?,' end
  code[#code+1]='}; if !m.is_empty(){return Err("unknown object field in '..record.name..'".into());} Ok(result) }, Json::Reference(_)=>Err("identity tags are unsupported on value record '..record.name..'".into()), _=>Err("expected array or object for '..record.name..'".into()) } } }'
  code[#code+1]="impl ToJson for "..record.name.." { fn to_json(&self,out:&mut String){out.push('[');"
  for i,f in ipairs(ordered) do code[#code+1]=(i>1 and "out.push(',');" or "").."self."..f.name..".to_json(out);" end
  code[#code+1]="out.push(']');} const HAS_REFERENCES:bool=false"
  for _,f in ipairs(ordered) do code[#code+1]="|| <"..f.type.." as ToJson>::HAS_REFERENCES" end
  code[#code+1]='; fn shared_reference(&self,seen:&mut HashSet<(TypeId,usize)>)->bool { false'
  for _,f in ipairs(ordered) do code[#code+1]='|| self.'..f.name..'.shared_reference(seen)' end
  code[#code+1]='} }'
  code[#code+1]='impl GraphRecord for '..record.name..' { fn graph_empty()->Self { Self {'
  for _,f in ipairs(ordered) do
    local value=default_expr(f.type,records,{[record.name]=true})
    if not value then return nil,"Rust graph shell for `"..record.name.."` cannot safely initialize field `"..f.name.."` of type `"..f.type.."`" end
    code[#code+1]=f.name..':'..value..','
  end
  code[#code+1]='} } fn graph_populate(&mut self,mut fields:BTreeMap<String,Json>)->Result<(),String> {'
  for _,f in ipairs(ordered) do code[#code+1]='self.'..f.name..'=<'..f.type..' as FromJson>::from_json(fields.remove("'..f.name..'").ok_or_else(||format!("missing required field '..record.name..'.'..f.name..'"))?)?;' end
  code[#code+1]='if !fields.is_empty(){return Err("unknown field in identity definition for '..record.name..'".into());} Ok(()) } fn graph_fields(&self,out:&mut String){'
  for _,f in ipairs(ordered) do code[#code+1]="out.push_str(\",\\\""..f.name.."\\\":\");self."..f.name..".to_json(out);" end
  code[#code+1]='} }'
  return table.concat(code,'\n')
end
local function option_code(inner)
  return 'impl FromJson for Option<'..inner..'> { fn from_json(v:Json)->Result<Self,String>{match v{Json::Null=>Ok(None),v=><'..inner..' as FromJson>::from_json(v).map(Some)}} }\n'
    ..'impl ToJson for Option<'..inner..'> { const HAS_REFERENCES:bool=<'..inner..' as ToJson>::HAS_REFERENCES; fn shared_reference(&self,seen:&mut HashSet<(TypeId,usize)>)->bool {self.as_ref().is_some_and(|value|value.shared_reference(seen))} fn to_json(&self,o:&mut String){match self{Some(v)=>v.to_json(o),None=>o.push_str("null")}} }'
end
function M.discover(starter,code,ref,exclude,roots)
  local all={}
  for _,source in ipairs({starter or "",code or "",ref or ""}) do
    local found,err=declarations(source,exclude or "Solution");if not found then return nil,err end
    for name,record in pairs(found) do all[name]=record end
  end
  if not roots then return {records=all} end
  local needed,options={},{}
  local function visit(typ)
    typ=canonical(typ)
    if typ=="Option<Box<ListNode>>" or typ=="Option<Rc<RefCell<TreeNode>>>" then return true end
    if all[typ] then
      if needed[typ] then return true end
      local record=all[typ]
      if record.schema_error then return nil,record.schema_error end
      needed[typ]=record
      for _,field in ipairs(record.fields) do
        if not supported(field.type,all) then return nil,"unsupported Rust field type `"..field.type.."` in `"..typ.."."..field.name.."`" end
        local ok,err=visit(field.type);if not ok then return nil,err end
      end
      record.order=ctor_fields(record.source,typ,record.fields)
      return true
    end
    local inner=typ:match("^Option<(.*)>$")
    if inner then options[inner]=true;return visit(inner) end
    inner=typ:match("^Vec<(.*)>$") or typ:match("^Box<(.*)>$") or typ:match("^BTreeMap<String,(.*)>$") or typ:match("^Rc<RefCell<(.*)>>$")
    if inner then return visit(inner) end
    return true
  end
  for _,typ in ipairs(roots) do local ok,err=visit(typ);if not ok then return nil,err end end
  local impls,shared={},{}
  for _,record in pairs(needed) do
    local generated,err=codec(record,needed);if not generated then return nil,err end
    impls[#impls+1]=generated
  end
  for inner in pairs(options) do
    local local_type=false
    for name in inner:gmatch("[%w_]+") do if needed[name] then local_type=true;break end end
    if local_type then impls[#impls+1]=option_code(inner) else shared[inner]=option_code(inner) end
  end
  table.sort(impls)
  return {records=all,codecs=table.concat(impls,"\n"),shared_options=shared}
end
--- Definitions a module source still lacks, so user and oracle never share stale copies.
function M.definitions(source, records)
  local names={}
  for name in M.strip(source):gmatch("%f[%a]struct%s+([%a_][%w_]*)") do names[name]=true end
  local out={}
  for name,record in pairs(records or {}) do
    if not names[name] then out[#out+1]=record.source end
  end
  table.sort(out)
  return table.concat(out,'\n')
end
return M
