local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))
local server = vim.env.MEATCODE_RUST_ANALYZER or vim.fn.exepath('rust-analyzer')
assert(server ~= '', 'install rust-analyzer or set MEATCODE_RUST_ANALYZER')
local util = require('meatcode.util')
local base = vim.fn.tempname()
util.mkdirp(base)
local root = vim.uv.fs_realpath(base) .. '/solutions with spaces'
local p = { key='neetcode:double', name='Double', difficulty='Easy', providers={neetcode={id='double'},leetcode={id='double'}}, topics={}, companies={} }
local catalog = { problems={p}, by_provider={neetcode={double=p},leetcode={},lintcode={}}, by_pattern={} }
for _, name in ipairs({'meatcode.catalog','meatcode.catalog.problems'}) do
  local m = require(name)
  m.load=function()return catalog end; m.get=function()return catalog end
  m.ensure=function(cb)cb(nil,catalog)end
end
require('meatcode.progress').sync=function()end
require('meatcode.catalog.availability').warm=function()end
local providers = require('meatcode.providers')
local original = 'use std::collections::HashSet; impl Solution { pub fn double(n: i32) -> i32 { let values = vec![n]; let unique: HashSet<_> = values.iter().collect(); values.len() as i32 * n * unique.len() as i32 } }'
local submitted
for _, backend in ipairs(providers.all()) do
  backend.auth={is_logged_in=function()return true end,user=function()return {}end}
  backend.resolve=function(_,cb)cb(nil,nil)end
  backend.fetch=function(_,_,cb)cb(nil,{
    schema=util.META_SCHEMA,name='Double',difficulty='Easy',description='Return n.',
    starterCode={rust=original},availableLanguages={'rust'},custom_test_cases={'2'},expected_outputs={'2'},test_case_type='function',test_case_count=1,
  })end
  backend.enrich=nil;backend.saved_code=nil;backend.test=nil
  backend.submit=function(_,_,code,_,cb)submitted=code;cb(nil,{accepted=true,status='Accepted'})end
  backend.normalize_submission=function(data)return data end
end
require('meatcode').setup({solutions_dir=root,cache_dir=root..'/cache',lang='rust',ui={images=false}})
providers.set_order('content',{'neetcode'});providers.set_order('submit',{'neetcode'})
local ui=require('meatcode.ui.problem')
local editor=require('meatcode.runner.rust_editor')
local client
local function settle(fn,msg)assert(vim.wait(30000,fn,20),msg)end
local function run()
  ui.open(p)
  settle(function()return vim.bo.filetype=='rust' and ui.is_session_tab()end,'problem not shown')
  local buf=vim.api.nvim_get_current_buf()
  local file=vim.api.nvim_buf_get_name(buf)
  assert(table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n')==original,'editor changed the solution source')
  local id=assert(vim.lsp.start({name='rust_analyzer',cmd={server},root_dir=root}))
  settle(function()client=vim.lsp.get_client_by_id(id);return client and client.initialized end,'server not initialized')
  local function request(method,params)
    local result=assert(client:request_sync(method,params,30000,buf))
    if result.err and result.err.code==-32801 then return nil end -- Indexing invalidated the request.
    assert(not result.err,vim.inspect(result.err))
    return result.result
  end
  local uri={uri=vim.uri_from_fname(file)}
  local hover
  settle(function()
    hover=request('textDocument/hover',{textDocument=uri,position={line=0,character=assert(original:find('Solution',1,true))-1}})
    return hover and vim.inspect(hover):find('Solution',1,true)
  end,'Solution context not resolved')
  local pos=assert(original:find('values.len',1,true))+#'values.'-1
  settle(function()
    local completion=request('textDocument/completion',{textDocument=uri,position={line=0,character=pos},context={triggerKind=1}})
    for _, item in ipairs(completion and (completion.items or completion) or {})do
      if item.label=='len' then return true end
    end
  end,'Vec::len completion unavailable in actual solution buffer')
  local function errors()
    return vim.tbl_filter(function(d)return d.severity==vim.diagnostic.severity.ERROR end,vim.diagnostic.get(buf))
  end
  assert(#errors()==0,vim.inspect(errors()))
  print('Actual Rust solution resolves Solution and offers Vec::len completion')
  vim.api.nvim_buf_set_lines(buf,0,1,false,{'impl Solution { pub fn double(n: i32) -> i32 { true } }'})
  vim.cmd('write')
  settle(function()
    for _,d in ipairs(errors())do if tostring(d.code)=='E0308' and d.lnum==0 then return true end end
  end,'saved type error did not reach solution diagnostics')
  vim.api.nvim_buf_set_lines(buf,0,1,false,{original})
  vim.cmd('write')
  settle(function()return #errors()==0 end,'fixed type error did not clear')
  print('rustc check-on-save reports and clears a real type error at the solution line')
  ui.submit()
  settle(function()return submitted~=nil end,'submission not invoked')
  assert(submitted==original,'editor support leaked into cloud submission: '..tostring(submitted))
  settle(function()
    for _,b in ipairs(vim.api.nvim_list_bufs())do
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype=='meatcode-results'
        and table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false),'\n'):find('Accepted',1,true)then return true end
    end
  end,'submission did not finish')
  require('meatcode.runner').set_cloud_mode('never')
  ui.run()
  local results
  settle(function()
    for _,b in ipairs(vim.api.nvim_list_bufs())do
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype=='meatcode-results' then
        results=table.concat(vim.api.nvim_buf_get_lines(b,0,-1,false),'\n')
        if results:find('1/1',1,true)then return true end
      end
    end
  end,'Rust solution failed its real local run: '..tostring(results))
  print('Cloud submission contains only user code; real local Rust run passes')
  local rust=require('meatcode.runner.rust')
  local runner=require('meatcode.runner')
  local function judge_run(id,code,starter,cases,outputs,cb)
    runner.run(id,code,'rust',{starterCode={rust=starter},custom_test_cases=cases,expected_outputs=outputs,test_case_type='function'},cases,cb)
  end
  local judge='impl Solution { pub fn solve(value: i32) -> i32 { value } }'
  local backend=providers.get('leetcode')
  backend.fetch=function(_,_,cb)cb(nil,{provider='leetcode',question_id='42',starterCode={rust=judge},test_case_type='function'})end
  local judged
  backend.submit=function(_,meta,payload,_,cb)
    judge_run('provider-signature',payload,meta.starterCode.rust,{'2'},{'2'},function(report)
      judged=report;cb(nil,report)
    end)
  end
  backend.normalize_submission=function(report)
    return {accepted=report.ok and report.passed==1,status=report.ok and report.passed==1 and 'Accepted' or 'Compile Error',compile_output=report.error}
  end
  providers.set_order('submit',{'leetcode'})
  ui.submit()
  settle(function()return judged~=nil end,'cross-provider submission did not reach the judge')
  assert(judged.ok and judged.passed==1,vim.inspect(judged))
  assert(table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n')==original,'judge adaptation changed the solution buffer')
  print('NeetCode source submits to a different Rust judge entry point without modifying the solution')

  local function adapted_run(id,code,source,target,cases,outputs)
    local payload,err=rust.adapt_submission(code,source,target)
    assert(payload,err)
    local report
    judge_run(id,payload,target,cases,outputs,function(r)report=r end)
    settle(function()return report~=nil end,id..' timed out')
    assert(report.ok and report.passed==#cases,id..': '..vim.inspect(report))
  end
  local recursive=[=[
struct Other;
impl Other { fn solve(n: i32) -> i32 { n } }
impl Solution {
    fn helper(n: i32) -> i32 { n }
    pub fn factorial(n: i32) -> i32 {
        let _literal = r###"pub fn solve(n: i32) -> i32 { }"###;
        let _brace = '}';
        /* nested /* fn solve(n: i32) { } */ comment */
        fn solve(n: i32) -> i32 { n }
        if n == 0 { 1 } else { Self::helper(n) * Self::factorial(n - 1) }
    }
}
]=]
  adapted_run('recursive-entry',recursive,'impl Solution { pub fn factorial(n: i32) -> i32 { 0 } }',judge,{'0','5'},{'1','120'})
  adapted_run('existing-entry','impl Solution { pub fn solve(n: i32) -> i32 { n+3 } }',original,judge,{'2'},{'5'})
  local mutation='impl Solution { pub fn reverse(nums: &mut Vec<i32>) { nums.reverse(); } }'
  adapted_run('borrowed-entry',mutation,mutation,'impl Solution { pub fn reorder(values: &mut Vec<i32>) {} }',{'[1,2,3]','[]'},{'[3,2,1]','[]'})
  local payload,err=rust.adapt_submission(mutation,mutation,'impl Solution { pub fn reorder(values: &mut [i32]) {} }')
  assert(payload==nil,'incompatible borrowed types were accepted')
  payload,err=rust.adapt_submission(original,original,'impl Solution { pub fn solve(value: i32) -> bool { false } }')
  assert(payload==nil,'incompatible return types were accepted')
  print('Rust judge adaptation preserves recursion and literals, accepts existing entry points, and checks exact borrowed types')
  local opaque='type Items=Vec<i32>; impl Solution { pub fn identity(items: Items) -> Items { items } }'
  local opaque_source='impl Solution { pub fn identity(items: Items) -> Items {} }'
  local opaque_judge='impl Solution { pub fn solve(values: Items) -> Items {} }'
  payload,err=rust.adapt_submission(opaque,opaque_source,opaque_judge)
  assert(payload,err)
  local opaque_path=root..'/opaque.rs'
  util.write_file(opaque_path,'struct Solution;\n'..payload..'\nfn main() { assert_eq!(Solution::solve(vec![3,1,4]),vec![3,1,4]); }\n')
  local compiled=vim.system({'rustc','--edition=2021','-o',root..'/opaque',opaque_path},{text=true}):wait()
  assert(compiled.code==0,compiled.stderr)
  local executed=vim.system({root..'/opaque'},{text=true}):wait()
  assert(executed.code==0,executed.stderr)
  print('Cloud Rust entry-point adaptation also preserves types unsupported by local serialization')
  -- Same filename in different topics must not share custom Node definitions.
  local a=root..'/graphs/node.rs';local b=root..'/lists/node.rs'
  local graph='// #[derive(Clone)]\n// pub struct Node { pub neighbors: Vec<i32> }\nimpl Solution { pub fn test(n: Node) -> usize { n.clone().neighbors.len() } }'
  local list='/*\n * pub struct Node { pub next: Option<Box<Node>> }\n */\nimpl Solution { pub fn test(n: Node) -> bool { n.next.is_none() } }'
  util.write_file(a,graph);util.write_file(b,list)
  local prepared=false;editor.ensure(a,graph,function()prepared=true end);settle(function()return prepared end,'graph support missing')
  prepared=false;editor.ensure(b,list,function()prepared=true end);settle(function()return prepared end,'list support missing')
  for _,entry in ipairs({{a,graph,'neighbors'},{b,list,'next'}})do
    local node_buf=vim.fn.bufadd(entry[1]);vim.fn.bufload(node_buf)
    assert(vim.lsp.buf_attach_client(node_buf,client.id))
    local lines=vim.split(entry[2],'\n',{plain=true})
    local column=assert(lines[#lines]:find('Node',1,true))-1
    settle(function()
      local hover_node=request('textDocument/hover',{textDocument={uri=vim.uri_from_fname(entry[1])},position={line=#lines-1,character=column}})
      return hover_node and vim.inspect(hover_node):find(entry[3],1,true)
    end,'wrong editor Node shape for '..entry[1])
  end
  local function compile(path)
    local project=assert(util.read_json(root..'/rust-project.json'))
    local index=vim.fn.index(project._meatcode_paths,path)+1
    assert(index>0,'solution missing from crate graph')
    local wrapper=project.crates[index].build.label
    return vim.system({'rustc','--edition=2021','--crate-name','test_solution','--crate-type=lib','--emit=metadata','--error-format=json','-o',root..'/test.rmeta',wrapper},{text=true}):wait()
  end
  assert(compile(a).code==0,'graph helper lost derive/fields')
  assert(compile(b).code==0,'list helper conflicted with graph helper')
  local wrong=graph:gsub('n%.clone%(%)%.neighbors%.len%(%)', 'n.next.is_none() as usize')
  util.write_file(a,wrong)
  local rejected=compile(a)
  local missing_field=false
  for line in rejected.stderr:gmatch('[^\n]+')do
    local diagnostic=vim.json.decode(line)
    if type(diagnostic.code)=='table' and diagnostic.code.code=='E0609' then missing_field=true end
  end
  assert(rejected.code~=0 and missing_field,'unrelated Node field not rejected: '..rejected.stderr)
  print('Per-problem helper shapes remain isolated')
end
local ok,err=xpcall(run,debug.traceback)
if client then client:stop(true)end
ui.close();vim.fn.delete(base,'rf')
if not ok then print(err);vim.cmd('cquit')else vim.cmd('qa!')end
