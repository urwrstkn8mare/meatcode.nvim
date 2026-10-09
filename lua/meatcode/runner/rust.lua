--- Native Rust harness generation using the bundled, dependency-free runtime.
local M = {}
local structure = require("meatcode.runner.rust_structures")
local LIST, TREE = "Option<Box<ListNode>>", "Option<Rc<RefCell<TreeNode>>>"
local scalars = { i8=true,i16=true,i32=true,i64=true,isize=true,u8=true,u16=true,u32=true,u64=true,usize=true,f32=true,f64=true,bool=true,char=true,String=true }
local function clean(t) return structure.canonical(t) end
local function supported(t, records)
  if scalars[t] or t == LIST or t == TREE or (records and records[t]) then return true end
  local inner=t:match("^Vec<(.*)>$") or t:match("^Box<(.*)>$") or t:match("^Option<(.*)>$")
  if inner then return supported(inner,records) end
  inner=t:match("^BTreeMap<String,(.*)>$")
  if inner then return supported(inner,records) end
  inner=t:match("^Rc<RefCell<(.*)>>$")
  return inner and records and records[inner]~=nil or false
end
local function uncomment(text) return structure.strip(text) end
local function parameters(text, unrestricted, records)
  local out, start, depth = {}, 1, 0
  for i = 1, #text + 1 do
    local ch = text:sub(i,i)
    if ch == "<" or ch == "(" or ch == "[" then depth = depth + 1
    elseif ch == ">" or ch == ")" or ch == "]" then depth = depth - 1
    elseif (ch == "," and depth == 0) or i == #text + 1 then
      local part = vim.trim(text:sub(start,i-1))
      if part ~= "" and part ~= "&self" and part ~= "&mut self" and part ~= "self" and part ~= "mut self" then
        local name, typ = part:match("^([%w_]+)%s*:%s*(.+)$")
        if not typ then name, typ = part:match("^mut%s+([%w_]+)%s*:%s*(.+)$") end
        if not typ then return nil, "could not parse Rust parameter `" .. part .. "`" end
        typ = clean(typ)
        local declared_type = typ
        local borrow
        if typ:sub(1,4) == "&mut" then borrow="mut"; typ=typ:sub(5)
        elseif typ:sub(1,1) == "&" then borrow="ref"; typ=typ:sub(2) end
        if borrow and typ == "str" then typ="String" end
        if borrow and typ:match("^%[.*%]$") then typ="Vec<" .. typ:sub(2,-2) .. ">" end
        if not unrestricted and not supported(typ,records) then return nil, "unsupported Rust parameter type `" .. typ .. "`" end
        out[#out+1] = { name=name,type=typ,borrow=borrow,declared_type=declared_type }
      end
      start = i + 1
    end
  end
  return out
end
local function methods(text, unrestricted, records)
  local out = {}
  for name, args, suffix in text:gmatch("fn%s+([%w_]+)%s*(%b())%s*([^{}]*){") do
    local params, err = parameters(args:sub(2,-2), unrestricted, records)
    if not params then return nil, err end
    local ret = clean(suffix:match("%-%>%s*(.-)%s*$") or "()")
    if not unrestricted and ret ~= "()" and ret ~= "Self" and not supported(ret,records) then return nil, "unsupported Rust result type `" .. ret .. "`" end
    out[#out+1] = { name=name,params=params,ret=ret }
  end
  return out
end
local function signature(starter, unrestricted, code, ref)
  local records
  if not unrestricted then
    local schemas, schema_err = structure.discover(starter, code, ref)
    if not schemas then return nil, schema_err end
    records = schemas.records
  end
  local src = uncomment(starter or "")
  local body = src:match("impl%s+Solution%s*{(.*)")
  if not body then return nil, "could not find impl Solution in the Rust starter" end
  local parsed, err = methods(body, unrestricted, records)
  if not parsed then return nil, err end
  if not parsed[1] then return nil, "could not parse a Rust Solution method" end
  return parsed[1]
end
function M.parse_signature(starter, code, ref) return signature(starter, false, code, ref) end

--- Inspect declarations without confusing comments or literals with Rust code.
local function has_solution_method(code, name)
  local tokens, i = {}, 1
  while i <= #code do
    local ch, pair = code:sub(i, i), code:sub(i, i + 1)
    local _, raw_end, hashes = code:find('^r(#*)"', i)
    local character = ch == "'" and code:sub(i + 1):match("^([\1-\127\194-\244][\128-\191]*)'") or nil
    if pair == "//" then
      i = code:find("\n", i + 2, true) or (#code + 1)
      tokens[#tokens + 1] = " "
    elseif pair == "/*" then
      local depth = 1
      i = i + 2
      while i <= #code and depth > 0 do
        pair = code:sub(i, i + 1)
        if pair == "/*" then depth = depth + 1; i = i + 2
        elseif pair == "*/" then depth = depth - 1; i = i + 2
        else i = i + 1 end
      end
      tokens[#tokens + 1] = " "
    elseif raw_end then
      local _, finish = code:find('"' .. hashes, raw_end + 1, true)
      i = finish and finish + 1 or #code + 1
      tokens[#tokens + 1] = " "
    elseif ch == '"' or (ch == "'" and code:sub(i + 1, i + 1) == "\\") then
      local quote = ch
      i = i + 1
      while i <= #code do
        ch = code:sub(i, i)
        i = i + (ch == "\\" and 2 or 1)
        if ch == quote then break end
      end
      tokens[#tokens + 1] = " "
    elseif character then
      i = i + #character + 2
      tokens[#tokens + 1] = " "
    else
      tokens[#tokens + 1] = ch
      i = i + 1
    end
  end
  for body in table.concat(tokens):gmatch("impl%s+Solution%s*(%b{})") do
    local depth = 0
    for pos = 1, #body do
      local ch = body:sub(pos, pos)
      if ch == "{" then depth = depth + 1
      elseif ch == "}" then depth = depth - 1
      elseif depth == 1 and body:find("^fn%s+" .. name .. "%s*%(", pos) then return true end
    end
  end
  return false
end

--- Bridge compatible provider entry points in the payload, never the buffer.
--- Forwarding preserves recursion, helper methods, comments and string literals.
function M.adapt_submission(code, starter, judge_starter)
  local target, err = signature(judge_starter, true)
  if not target then return nil, "could not read the judge's Rust signature: " .. err end
  if has_solution_method(code, target.name) then return code end
  local source; source, err = signature(starter, true)
  if not source then return nil, "could not read the content provider's Rust signature: " .. err end
  if source.name == target.name then return code end
  if source.ret ~= target.ret or #source.params ~= #target.params then
    return nil, "Rust entry-point signatures differ beyond their names; use the judge's starter"
  end
  local args = {}
  for i, param in ipairs(target.params) do
    local original = source.params[i]
    if param.declared_type ~= original.declared_type then
      return nil, "Rust entry-point parameter " .. i .. " differs between providers; use the judge's starter"
    end
    args[i] = param.name
  end
  if not has_solution_method(code, source.name) then
    return nil, "Rust solution must implement `" .. source.name .. "` or `" .. target.name .. "`"
  end
  local params, suffix = uncomment(judge_starter):match("fn%s+" .. target.name .. "%s*(%b())%s*([^{}]*){")
  return code .. "\n\nimpl Solution {\n    pub fn " .. target.name .. params .. " " .. vim.trim(suffix)
    .. " {\n        Self::" .. source.name .. "(" .. table.concat(args, ", ") .. ")\n    }\n}\n"
end
function M.parse_class(starter, code, ref, target)
  local src=uncomment(starter or "")
  local candidates={}
  for candidate,implementation in src:gmatch("impl%s+([%w_]+)%s*(%b{})") do
    candidates[#candidates+1]={candidate,implementation}
  end
  local name=target
  if not name then
    for _,pair in ipairs(candidates) do
      if pair[1]=="Solution" then name=pair[1];break end
      for method in pair[2]:gmatch("fn%s+([%w_]+)%s*%(") do
        if method~="new" then name=pair[1];break end
      end
      if name then break end
    end
  end
  name=name or (candidates[1] and candidates[1][1]) or src:match("struct%s+([%w_]+)")
  if not name then return nil,"could not find a Rust design struct" end
  local bodies={}
  for _,pair in ipairs(candidates) do if pair[1]==name then bodies[#bodies+1]=pair[2] end end
  if #bodies==0 then return nil,"could not find impl "..name.." in the Rust starter" end
  local schemas,schema_err=structure.discover(starter,code,ref,name)
  if not schemas then return nil,schema_err end
  local parsed,err=methods(table.concat(bodies,"\n"),false,schemas.records)
  if not parsed then return nil, err end
  local cls = { name=name,methods={},ctor={},records=schemas.records }
  for _, method in ipairs(parsed) do
    if method.name == "new" then cls.ctor=method.params;cls.has_ctor=true
    else cls.methods[#cls.methods+1]=method end
  end
  return cls
end
function M.class_spec(cls)
  local function flags(params)
    local out={}
    for _,param in ipairs(params) do
      local t=param.type
      if t:sub(1,7)=="Option<" then t=t:sub(8,-2) end
      out[#out+1]=not scalars[t]
    end
    return out
  end
  local spec={name=cls.name,ctor=flags(cls.ctor),methods={}}
  for _,method in ipairs(cls.methods) do spec.methods[method.name]=flags(method.params) end
  return spec
end
local function bind(params, variable, retain_tree)
  local lines, args = { string.format('if %s.len()!=%d { return Err("wrong argument count".into()); }',variable,#params), "let mut values=" .. variable .. ".into_iter();" }, {}
  for i,param in ipairs(params) do
    local value='values.next().ok_or("missing argument")?'
    local decode="<" .. param.type .. " as FromJson>::from_json(" .. value .. ")?"
    if i>1 and param.type==TREE and params[1].type==TREE then decode="tree_argument(" .. value .. ",&arg1)?" end
    lines[#lines+1]="let " .. (param.borrow=="mut" and "mut " or "") .. "arg" .. i .. ":" .. param.type .. "=" .. decode .. ";"
    args[#args+1]=(param.borrow=="mut" and "&mut " or param.borrow=="ref" and "&" or "") .. "arg" .. i
      .. (retain_tree and i==1 and param.type==TREE and not param.borrow and ".clone()" or "")
  end
  return table.concat(lines,"\n"),table.concat(args,",")
end
local function function_body(sig)
  local retain_tree=sig.ret=="()" and sig.params[1] and sig.params[1].type==TREE
  local declarations,args=bind(sig.params,"args",retain_tree)
  local call="Solution::" .. sig.name .. "(" .. args .. ")"
  if sig.ret=="()" then
    local first=sig.params[1]
    local output=first and (first.borrow=="mut" or first.type==TREE) and "encoded(&arg1)" or '"null".to_owned()'
    return "let args=arguments(input)?;\n" .. declarations .. "\n" .. call .. ";\nOk(" .. output .. ")"
  end
  return "let args=arguments(input)?;\n" .. declarations .. "\nlet result=" .. call .. ";\nOk(encoded(&result))"
end
local function class_body(cls)
  if not cls.has_ctor then return nil, "Rust design struct needs a new constructor" end
  local ctor,args=bind(cls.ctor,"args")
  local lines={"let mut input=input;initialize_graph(std::slice::from_mut(&mut input))?;","let mut operations=array(input)?.into_iter();",'let first=operations.next().ok_or("missing constructor")?;',
    "let mut fields=array(first)?.into_iter();",'let name=String::from_json(fields.next().ok_or("missing constructor name")?)?;',
    'if name!="' .. cls.name .. '" { return Err("first operation must be the constructor".into()); }',
    "let args=fields.collect::<Vec<_>>();",ctor,"let mut object=" .. cls.name .. "::new(" .. args .. ");",
    'let mut output=String::from("[null");',"for operation in operations {", "let mut fields=array(operation)?.into_iter();",
    'let name=String::from_json(fields.next().ok_or("missing operation name")?)?;',"let args=fields.collect::<Vec<_>>();",
    "output.push(',');match name.as_str() {"}
  for _,method in ipairs(cls.methods) do
    local declarations,arguments=bind(method.params,"args")
    local call="object." .. method.name .. "(" .. arguments .. ")"
    lines[#lines+1]='"' .. method.name .. '" => {' .. declarations .. (method.ret=="()" and call .. ';output.push_str("null");'
      or "let result=" .. call .. ";output.push_str(&encoded(&result));") .. "},"
  end
  lines[#lines+1]='_ => return Err(format!("unknown operation {}",name)),}\n}\noutput.push(\']\');Ok(output)'
  return table.concat(lines,"\n")
end
local function roundtrip_body(cls)
  local encode,decode
  for _,method in ipairs(cls.methods) do
    if method.name=="encode" or method.name=="serialize" then encode=method end
    if method.name=="decode" or method.name=="deserialize" then decode=method end
  end
  if not encode or not decode or #encode.params~=1 or #decode.params~=1 or #cls.ctor~=0 then return nil,"unsupported Rust codec signature" end
  if encode.ret~=decode.params[1].type then return nil,"codec decode input does not match encode output" end
  local declarations,args=bind(encode.params,"args")
  local constructor=cls.name .. (cls.has_ctor and "::new()" or "{}")
  local encoded_arg=(decode.params[1].borrow=="mut" and "&mut " or decode.params[1].borrow=="ref" and "&" or "") .. "value"
  return "let args=arguments(input)?;\n" .. declarations .. "\nlet mut object=" .. constructor .. ";\nlet "
    .. (decode.params[1].borrow=="mut" and "mut " or "") .. "value=object." .. encode.name .. "(" .. args .. ");\n"
    .. "let result=object." .. decode.name .. "(" .. encoded_arg .. ");\nOk(encoded(&result))"
end
local MAIN=[=[
fn run() -> Result<String,String> {
    let dir=env::args().nth(1).unwrap_or(".".into());
    let cases=read_array(&dir,"cases.json")?;
    let inputs=read_array(&dir,"__INPUT__")?;
    if cases.len()!=inputs.len() { return Err("missing case input data".into()); }
    let shard:usize=env::args().nth(2).and_then(|value|value.parse().ok()).unwrap_or(0);
    let stride:usize=env::args().nth(3).and_then(|value|value.parse().ok()).unwrap_or(1).max(1);
    let mut report=String::from("{\"ok\":true,\"method\":\"rust\",\"cases\":[");
    let mut first=true;
    for (index,(case,input)) in cases.into_iter().zip(inputs).enumerate() {
        if index % stride!=shard { continue; }
        eprintln!("CASE {}",index);
        let block=String::from_json(case)?;
        let started=Instant::now();
        __ORACLE_INPUT__
        let (result,logs)=capture(&dir,index,false,||UserCode::execute(input));
        let mut status="no_oracle";let mut actual=None;let mut expected:Option<String>=None;let mut error=None;
        match result {
            Ok(value) => { actual=Some(value);__ORACLE__ }
            Err(message) => { status="error";error=Some(message); }
        }
        if !first { report.push(','); } first=false;
        let _=write!(report,"{{\"index\":{},\"elapsed_ms\":{},\"input\":",index,started.elapsed().as_secs_f64()*1000.0);
        quote_into(&mut report,&block);report.push_str(",\"status\":");quote_into(&mut report,status);
        if let Some(actual)=actual { report.push_str(",\"actual\":");quote_into(&mut report,&actual); }
        if let Some(expected)=expected { report.push_str(",\"expected\":");quote_into(&mut report,&expected); }
        if let Some(error)=error { report.push_str(",\"error\":");quote_into(&mut report,&error); }
        if !logs.is_empty() { report.push_str(",\"stdout\":");quote_into(&mut report,&logs); }
        report.push('}');
    }
    report.push_str("]}");Ok(report)
}
fn main() {
    match run() {
        Ok(report) => println!("{}",report),
        Err(error) => { let mut report=String::from("{\"ok\":false,\"cases\":[],\"error\":");quote_into(&mut report,&error);report.push('}');println!("{}",report); }
    }
}
]=]
local function generate(starter,oracle,code,ref,mode,target)
  local metadata,err
  if mode=="function" then metadata,err=M.parse_signature(starter,code,ref) else metadata,err=M.parse_class(starter,code,ref,target) end
  if not metadata then return nil,err end
  local body
  if mode=="function" then body=function_body(metadata)
  elseif mode=="class" then body,err=class_body(metadata)
  else body,err=roundtrip_body(metadata) end
  if not body then return nil,err end
  local roots={}
  local function add(method)
    for _,param in ipairs(method.params or {}) do roots[#roots+1]=param.type end
    if method.ret and method.ret~="()" then roots[#roots+1]=method.ret end
  end
  if mode=="function" then add(metadata) else
    for _,param in ipairs(metadata.ctor) do roots[#roots+1]=param.type end
    for _,method in ipairs(metadata.methods) do add(method) end
  end
  local shared={}
  local function wrap(source,name,other)
    if type(source)~="string" or source=="" then return nil,"no Rust solution source supplied" end
    local schemas,schema_err=structure.discover(starter,other,source,mode~="function" and metadata.name or "Solution",roots)
    if not schemas then return nil,schema_err end
    for inner,generated in pairs(schemas.shared_options) do shared[inner]=generated end
    local plain=uncomment(source)
    if plain:match("struct%s+ListNode") or plain:match("struct%s+TreeNode") then return nil,"custom Rust node definitions are unsupported; the harness supplies standard judge types" end
    if mode=="function" and not plain:match("struct%s+Solution") then source="struct Solution;\n" .. source end
    return "mod " .. name .. " {\nuse super::*;\n" .. structure.definitions(source,schemas.records) .. "\n" .. source .. "\n" .. schemas.codecs .. "\npub(super) fn execute(input:Json)->Result<String,String> {\n" .. body .. "\n}\n}\n"
  end
  local user;user,err=wrap(code,"UserCode",ref)
  if not user then return nil,err end
  local reference=oracle=="reference"
  local oracle_source=""
  if reference then oracle_source,err=wrap(ref,"OracleCode",code);if not oracle_source then return nil,err end end
  local this=debug.getinfo(1,"S").source:sub(2)
  local util = require("meatcode.util")
  local dir = vim.fs.dirname(this) .. "/harness/"
  local types = util.read_file(dir .. "rust_types.rs")
  local runtime = util.read_file(dir .. "rust_runtime.rs")
  if not runtime or not types then return nil,"missing Rust runtime -- reinstall meatcode.nvim" end
  local main=MAIN:gsub("__INPUT__",mode=="class" and "ops.json" or "arguments.json")
    :gsub("__ORACLE_INPUT__",reference and "let oracle_input=input.clone();" or "")
    :gsub("__ORACLE__",reference and [[
        let (oracle,_) = capture(&dir,index,true,||OracleCode::execute(oracle_input));
        match oracle { Ok(value)=>expected=Some(value),Err(message)=>{status="oracle_error";error=Some(message);} }
    ]] or "")
  local shared_codecs={}
  for _,generated in pairs(shared) do shared_codecs[#shared_codecs+1]=generated end
  table.sort(shared_codecs)
  return runtime .. "\n" .. types .. "\n" .. table.concat(shared_codecs,"\n") .. "\n" .. user .. oracle_source .. main
end
function M.generate(starter,oracle,code,ref) return generate(starter,oracle,code,ref,"function") end
function M.generate_class(starter,oracle,code,ref,target) return generate(starter,oracle,code,ref,"class",target) end
function M.generate_roundtrip(starter,oracle,code,ref) return generate(starter,oracle,code,ref,"roundtrip") end
return M
