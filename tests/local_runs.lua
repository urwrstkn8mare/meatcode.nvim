local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))
local root = vim.fn.tempname()
require('meatcode.config').setup({cache_dir=root, solutions_dir=root..'/solutions', runner={parallelism=2, time_limit=2}})
local runner=require('meatcode.runner')
local function await_run(id,lang,code,starter,cases,outputs,kind)
  if vim.env.MEATCODE_SMOKE_LANG and lang ~= 'python' and lang ~= vim.env.MEATCODE_SMOKE_LANG then return end
  local report
  local meta={starterCode={[lang]=starter},custom_test_cases=cases,expected_outputs=outputs,test_case_type=kind or 'function'}
  runner.run(id,code,lang,meta,cases,function(r) report=r end)
  assert(vim.wait(120000,function() return report~=nil end,10),id..' timed out')
  assert(report.ok and report.passed==#cases,id..': '..vim.inspect(report))
  print(id..' passed '..report.passed..'/'..report.total)
  return report
end
local function run()
  local answers=require('meatcode.runner.answers')
  assert(answers.grade('{"items":{}}', {'{"items":[]}'} )=='fail',
    'empty object field was graded as an empty list')
  assert(answers.grade('[{},1]', {'[1,[]]'} )=='fail',
    'unordered grading erased empty object/list distinctions')
  assert(answers.grade('{"a":1,"b":[]}', {'{"b":[],"a":1}'} )=='pass',
    'JSON object key order changed an exact verdict')
  print('structured answer shapes and object key ordering passed')
  local system=vim.system
  local processes={}
  vim.system=function(...) local p=system(...);table.insert(processes,p);return p end
  local stale=0
  local starter='class Solution:\n    def double(self, n: int) -> int:\n        pass\n'
  local code='import time\nclass Solution:\n    def double(self, n: int) -> int:\n        time.sleep(20)\n        return n * 2\n'
  local cancel=runner.run('cancel',code,'python',{starterCode={python=starter}}, {'2'},function() stale=stale+1 end)
  assert(vim.wait(2000,function() return #processes>0 end,10))
  cancel();cancel()
  await_run('cancel','python','class Solution:\n    def double(self,n): return n*2\n',starter,{'2','4'},{'4','8'})
  assert(vim.wait(2000,function() local ok=vim.uv.kill(processes[1].pid,0);return not ok end,10),'cancelled process still alive')
  assert(stale==0,'cancelled callback delivered')
  vim.system=system
  local stopped,late,callback=0,0,nil
  local cancel_cloud=runner.run('cloud-cancel','','sql',{}, {'2'},function()late=late+1 end,nil,{provider='leetcode',test=function(_,_,cb) callback=cb;return function()stopped=stopped+1 end end})
  cancel_cloud();cancel_cloud();callback(nil,{{correct=true,expected='4',actual='4'}})
  vim.wait(100,function()return false end,10)
  assert(stopped==1 and late==0,'cloud cancellation delivered stale result')
  print('local replacement, process termination, cloud cancellation passed')
  await_run('swift-array','swift','class Solution { func sum(_ nums: [Int]) -> Int { nums.reduce(0,+) } }','class Solution { func sum(_ nums: [Int]) -> Int { return 0 } }',{'[1,2,3]','[]','[-4,2]'},{'6','0','-2'})
  await_run('rust-array','rust','impl Solution { pub fn sum(nums: Vec<i32>) -> i32 { nums.iter().sum() } }','impl Solution { pub fn sum(nums: Vec<i32>) -> i32 { 0 } }',{'[1,2,3]','[]','[-4,2]'},{'6','0','-2'})
  local swift_list='class Solution { func identity(_ head: ListNode?) -> ListNode? { return head } }'
  local rust_list='impl Solution { pub fn identity(head: Option<Box<ListNode>>) -> Option<Box<ListNode>> { head } }'
  await_run('swift-list','swift',swift_list,swift_list,{'[1,2,3]','[]'},{'[1,2,3]','[]'})
  await_run('rust-list','rust',rust_list,rust_list,{'[1,2,3]','[]'},{'[1,2,3]','[]'})
  local swift_tree='class Solution { func identity(_ root: TreeNode?) -> TreeNode? { return root } }'
  local rust_tree='impl Solution { pub fn identity(root: Option<Rc<RefCell<TreeNode>>>) -> Option<Rc<RefCell<TreeNode>>> { root } }'
  await_run('swift-tree','swift',swift_tree,swift_tree,{'[1,null,2,3]','[]'},{'[1,null,2,3]','[]'})
  await_run('rust-tree','rust',rust_tree,rust_tree,{'[1,null,2,3]','[]'},{'[1,null,2,3]','[]'})
  local swift_text='class Solution { func identity(_ text: String) -> String { return text } }'
  local rust_text='impl Solution { pub fn identity(text: String) -> String { text } }'
  await_run('swift-unicode','swift',swift_text,swift_text,{'"\\ud83d\\ude00"','"λ"','"a\\nb"'},{'"😀"','"λ"','"a\\nb"'})
  await_run('rust-unicode','rust',rust_text,rust_text,{'"\\ud83d\\ude00"','"λ"','"a\\nb"'},{'"😀"','"λ"','"a\\nb"'})
  local swift_lists='class Solution { func identity(_ heads: [ListNode?]) -> [ListNode?] { heads } }'
  local rust_lists='impl Solution { pub fn identity(heads: Vec<Option<Box<ListNode>>>) -> Vec<Option<Box<ListNode>>> { heads } }'
  await_run('swift-node-collection','swift',swift_lists,swift_lists,{'[[1,2],[],[3]]'},{'[[1,2],[],[3]]'})
  await_run('rust-node-collection','rust',rust_lists,rust_lists,{'[[1,2],[],[3]]'},{'[[1,2],[],[3]]'})
  local swift_refs='class Solution { func same(_ root: TreeNode?, _ p: TreeNode?, _ q: TreeNode?) -> Bool { root?.left === p && root?.right === q } }'
  local rust_refs='impl Solution { pub fn same(root: Option<Rc<RefCell<TreeNode>>>, p: Option<Rc<RefCell<TreeNode>>>, q: Option<Rc<RefCell<TreeNode>>>) -> bool { let tree=root.unwrap(); let node=tree.borrow(); Rc::ptr_eq(node.left.as_ref().unwrap(),p.as_ref().unwrap()) && Rc::ptr_eq(node.right.as_ref().unwrap(),q.as_ref().unwrap()) } }'
  await_run('swift-tree-references','swift',swift_refs,swift_refs,{'root=[5,3,8], p=3, q=8','root=[5,3,8], p=8, q=3'},{'true','false'})
  await_run('rust-tree-references','rust',rust_refs,rust_refs,{'root=[5,3,8], p=3, q=8','root=[5,3,8], p=8, q=3'},{'true','false'})
  local swift_bools='class Solution { func invert(rows: [[Bool]]) -> [[Bool]] { rows.map { $0.map { !$0 } } } }'
  local rust_bools='impl Solution { pub fn invert(rows: Vec<Vec<bool>>) -> Vec<Vec<bool>> { rows.into_iter().map(|row|row.into_iter().map(|v|!v).collect()).collect() } }'
  await_run('swift-nested-bools','swift',swift_bools,swift_bools,{'[[true,false],[],[false]]'},{'[[false,true],[],[true]]'})
  await_run('rust-nested-bools','rust',rust_bools,rust_bools,{'[[true,false],[],[false]]'},{'[[false,true],[],[true]]'})
  local swift_stdout='class Solution { func noisy(_ n: Int) -> Int { print(String(repeating:"x",count:200000),terminator:""); return n*2 } }'
  local rust_stdout='impl Solution { pub fn noisy(n: i32) -> i32 { print!("{}", "x".repeat(200000)); n*2 } }'
  for lang, code in pairs({swift=swift_stdout,rust=rust_stdout}) do
    local report=await_run(lang..'-stdout',lang,code,code,{'3'},{'6'})
    if report then assert(report.cases[1].stdout==string.rep('x',200000),'stdout truncated or mixed into return value') end
  end
  local swift_mutate='class Solution { func reverse(_ nums: inout [Int]) { nums.reverse() } }'
  local rust_mutate='impl Solution { pub fn reverse(nums: &mut Vec<i32>) { nums.reverse(); } }'
  await_run('swift-mutate','swift',swift_mutate,swift_mutate,{'[1,2,3]'},{'[3,2,1]'})
  await_run('rust-mutate','rust',rust_mutate,rust_mutate,{'[1,2,3]'},{'[3,2,1]'})
  local swift_class='class Counter { var value: Int; init(_ start: Int) { value=start }; func add(_ delta: Int) { value += delta }; func get() -> Int { return value } }'
  local rust_class='struct Counter { value: i32 } impl Counter { fn new(start: i32) -> Self { Self { value: start } } fn add(&mut self, delta: i32) { self.value += delta; } fn get(&self) -> i32 { self.value } }'
  await_run('swift-design','swift',swift_class,swift_class,{'["Counter","add","get"]\n[[2],[3],[]]'},{'[null,null,5]'},'class')
  await_run('rust-design','rust',rust_class,rust_class,{'["Counter","add","get"]\n[[2],[3],[]]'},{'[null,null,5]'},'class')
  local swift_codec='class Codec { func encode(_ strs: [String]) -> String { return strs.joined(separator: "|") }; func decode(_ s: String) -> [String] { return s.isEmpty ? [] : s.components(separatedBy: "|") } }'
  local rust_codec='struct Codec {} impl Codec { fn new() -> Self { Self {} } fn encode(&self, strs: Vec<String>) -> String { strs.join("|") } fn decode(&self, s: String) -> Vec<String> { if s.is_empty() { vec![] } else { s.split("|").map(str::to_string).collect() } } }'
  await_run('swift-roundtrip','swift',swift_codec,swift_codec,{'strs=["hello","world"]','strs=[]'},{'["hello","world"]','[]'},'class')
  await_run('rust-roundtrip','rust',rust_codec,rust_codec,{'strs=["hello","world"]','strs=[]'},{'["hello","world"]','[]'},'class')
  for _, lang in ipairs(vim.env.MEATCODE_SMOKE_LANG and {vim.env.MEATCODE_SMOKE_LANG} or {'swift','rust'}) do
    local code=lang=='swift' and 'class Solution { func sum(_ nums: [Int]) -> Int { nums.reduce(0,+) } }'
      or 'impl Solution { pub fn sum(nums: Vec<i32>) -> i32 { nums.iter().sum() } }'
    local meta={starterCode={[lang]=code},solutions={[lang]=code},custom_test_cases={'[1,2]'}}
    local prepared
    runner.prepare('oracle-'..lang,lang,meta,meta.custom_test_cases,function(info)prepared=info end)
    assert(vim.wait(120000,function()return prepared~=nil end,10),'oracle preparation timed out '..lang)
    assert(prepared.stage=='reference','sandbox oracle failed '..lang..': '..vim.inspect(prepared))
    local report
    runner.run('oracle-'..lang,code,lang,meta,meta.custom_test_cases,function(r)report=r end)
    assert(vim.wait(120000,function()return report~=nil end,10),'oracle run timed out '..lang)
    assert(report.ok and report.passed==1,'oracle run failed '..lang..': '..vim.inspect(report))
    print(lang..' sandboxed reference preparation and cached-answer run passed')
  end
end
local ok,err=xpcall(run,debug.traceback)
vim.fn.delete(root,'rf')
if not ok then io.stderr:write(err..'\n');vim.cmd('cquit 1') end
vim.cmd('qa!')
