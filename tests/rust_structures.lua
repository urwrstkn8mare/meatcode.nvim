local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))
local root = vim.fn.tempname()
require('meatcode.config').setup({cache_dir=root, solutions_dir=root..'/solutions', runner={parallelism=1, time_limit=2}})
if vim.env.MEATCODE_RUSTC then require('meatcode.config').options.runner.rust.cmd[1]=vim.env.MEATCODE_RUSTC end
local runner=require('meatcode.runner')

local function raw_run(id, code, starter, cases, outputs, kind)
  local report
  runner.run(id,code,'rust',{starterCode={rust=starter},custom_test_cases=cases,
    expected_outputs=outputs,test_case_type=kind or 'function'},cases,function(r)report=r end)
  assert(vim.wait(180000,function()return report~=nil end,10),id..' timed out')
  assert(report.ok,id..': harness failed '..vim.inspect(report))
  return report
end
local function run(id,code,starter,cases,outputs,kind)
  local report=raw_run(id,code,starter,cases,outputs,kind)
  assert(report.passed==#cases,id..': '..vim.inspect(report))
  print(id..' passed '..report.passed..'/'..report.total)
  return report
end
local function shape(id,code,cases,outputs,kind,starter)
  local report=run(id,code,starter or code,cases,outputs,kind)
  for i,case in ipairs(report.cases) do
    assert(case.actual==outputs[i],id..' case '..i..' produced '..case.actual..', expected '..outputs[i])
  end
end
local function error_run(id,code,cases,pattern)
  local report=raw_run(id,code,code,cases,{'null'})
  assert(report.passed==0,id..' unexpectedly passed '..vim.inspect(report))
  for _,case in ipairs(report.cases) do
    assert(case.status=='error' and case.error,id..' expected an error, got '..vim.inspect(case))
    assert(case.error:find(pattern,1,true),id..' wrong error: '..case.error)
  end
  print(id..' reported the expected error')
end

local function main_run()
  -- Value records: actual definitions, positional + named objects, nested records, Vec, string map.
  local packet_code=[[
use std::collections::BTreeMap;
struct Point { pub x: i32, pub y: i32 }
struct Packet { pub point: Point, pub points: Vec<Point>, pub lookup: BTreeMap<String,i32> }
impl Solution { pub fn shift(packet: Packet) -> Packet { packet } }
]]
  shape('rust-custom-records',packet_code,
    {'[[1,2],[[3,4]],{"a":7}]','{"point":{"x":9,"y":5},"points":[],"lookup":{}}'},
    {'[[1,2],[[3,4]],{"a":7}]','[[9,5],[],{}]'})

  -- Constructor parameter order drives positional decode/encode; named objects stay by name.
  local pair_code=[[
struct Pair { pub first: i32, pub second: i32 }
impl Pair { pub fn new(second: i32, first: i32) -> Pair { Pair { first, second } } }
impl Solution { pub fn same(pair: Pair) -> Pair { pair } }
]]
  shape('rust-constructor-order',pair_code,{'[1,2]','{"first":1,"second":2}'},{'[1,2]','[2,1]'})

  -- Documented-only helper is injected into the user module without duplicating real code.
  local injected_starter=[[
// struct Point { pub x: i32, pub y: i32 }
impl Solution { pub fn make(x: i32) -> Point { Point { x, y: x * 2 } } }
]]
  run('rust-documented-record',"impl Solution { pub fn make(x: i32) -> Point { Point { x, y: x * 2 } } }",
    injected_starter,{'3','-2'},{'[3,6]','[-2,-4]'})

  -- Option and map/empty shapes must survive exactly.
  shape('rust-optional-shape',
    "impl Solution { pub fn classify(flag: Option<i32>) -> Option<Vec<i32>> { flag.map(|v|vec![v,v+1]) } }",
    {'5','null'},{'[5,6]','null'})
  shape('rust-map-shape',[[
use std::collections::BTreeMap;
impl Solution { pub fn index(word: String) -> BTreeMap<String,i32> { BTreeMap::from([(word.clone(), word.len() as i32)]) } }
]],{'"abc"'},{'{"abc":3}'})
  shape('rust-empty-map-shape',[[
use std::collections::BTreeMap;
impl Solution { pub fn empty(values: Vec<i32>) -> BTreeMap<String,i32> { values.into_iter().map(|v|(v.to_string(),v)).collect() } }
]],{'[]'},{'{}'})

  -- Reference graphs: explicit ids, self-cycle, forward/shared references across arguments.
  local node_code=[[
struct Node { pub value: i32, pub next: Option<Rc<RefCell<Node>>> }
impl Solution { pub fn identity(node: Rc<RefCell<Node>>) -> Rc<RefCell<Node>> { node } }
]]
  shape('rust-reference-cycle',node_code,
    {'{"$id":44,"value":7,"next":{"$ref":44}}','{"$id":"node","value":9,"next":null}'},
    {'{"$id":1,"value":7,"next":{"$ref":1}}','{"$id":1,"value":9,"next":null}'})
  local linked_code=[[
struct Node { pub value: i32, pub next: Option<Rc<RefCell<Node>>> }
impl Solution { pub fn linked(a: Rc<RefCell<Node>>, b: Rc<RefCell<Node>>) -> bool { Rc::ptr_eq(&a,&b) } }
]]
  run('rust-forward-reference',linked_code,linked_code,
    {'a={"$ref":"a"}\nb={"$id":"a","value":1,"next":null}'},{'true'})
  local pair_node_code=[[
struct Node { pub value: i32, pub next: Option<Rc<RefCell<Node>>> }
impl Solution { pub fn pair(node: Rc<RefCell<Node>>) -> Vec<Rc<RefCell<Node>>> { vec![node.clone(), node] } }
]]
  shape('rust-shared-output',pair_node_code,
    {'{"$id":"n","value":5,"next":null}'},{'[{"$id":1,"value":5,"next":null},{"$ref":1}]'})

  -- Sharing and cycles built by the solution itself still serialize with identity.
  shape('rust-output-cycle',[[
struct Node { pub value: i32, pub next: Option<Rc<RefCell<Node>>> }
impl Solution {
    pub fn loop_back(n: i32) -> Rc<RefCell<Node>> {
        let node=Rc::new(RefCell::new(Node { value: n, next: None }));
        node.borrow_mut().next=Some(node.clone());
        node
    }
}
]],{'42'},{'{"$id":1,"value":42,"next":{"$ref":1}}'})

  -- Standard node types keep their list/tree encodings.
  local list_code='impl Solution { pub fn identity(head: Option<Box<ListNode>>) -> Option<Box<ListNode>> { head } }'
  run('rust-list-regression',list_code,list_code,{'[1,2,3]','[]'},{'[1,2,3]','[]'})
  local tree_code='impl Solution { pub fn identity(root: Option<Rc<RefCell<TreeNode>>>) -> Option<Rc<RefCell<TreeNode>>> { root } }'
  run('rust-tree-regression',tree_code,tree_code,{'[1,null,2,3]','[]'},{'[1,null,2,3]','[]'})

  -- Identity and shape errors are explicit, never silent coercion.
  error_run('rust-duplicate-id',linked_code,
    {'a={"$id":1,"value":1,"next":null}\nb={"$id":1,"value":2,"next":null}'},'duplicate identity id')
  error_run('rust-unresolved-ref',node_code,{'{"$ref":99}'},'unresolved identity reference')
  local point_area=[[
struct Point { pub x: i32, pub y: i32 }
impl Solution { pub fn area(point: Point) -> i32 { point.x * point.y } }
]]
  error_run('rust-value-identity-tag',point_area,
    {'{"$id":1,"x":2,"y":3}'},'identity tags are unsupported on value record Point')
  error_run('rust-surplus-fields',point_area,{'[1,2,3]'},'wrong field count for Point')
  local typed_refs=[[
struct Node { pub value: i32, pub next: Option<Rc<RefCell<Node>>> }
struct Other { pub tag: i32 }
impl Solution { pub fn mix(a: Rc<RefCell<Node>>, b: Rc<RefCell<Other>>) -> bool { true } }
]]
  error_run('rust-wrong-type-ref',typed_refs,
    {'a={"$id":"x","value":1,"next":null}\nb={"$ref":"x"}'},'identity reference has the wrong type')
  error_run('rust-missing-field',node_code,{'{"$id":1,"value":5}'},'missing required field Node.next')

  -- Design mode with custom record constructor and operation arguments (positional and named).
  local design_starter=[[
// struct Point { pub x: i32, pub y: i32 }
struct Rect { pub w: i32, pub h: i32, pub at: Point }
impl Rect {
    fn new(at: Point) -> Self { Self { w: 0, h: 0, at } }
    fn resize(&mut self, w: i32, h: i32) { self.w = w; self.h = h; }
    fn shift(&mut self, at: Point) { self.at = at; }
    fn anchor(&self) -> Point { Point { x: self.at.x, y: self.at.y } }
}
]]
  local design_code=design_starter:gsub("^// struct Point[^\n]*\n","")
  shape('rust-design-records',design_code,
    {'["Rect","resize","anchor","shift","anchor"]\n[[[9,9]],[3,4],[],[[1,1]],[]]',
      '["Rect","shift","anchor"]\n[[{"x":5,"y":5}],[{"x":2,"y":7}],[]]'},
    {'[null,null,[9,9],null,[1,1]]','[null,null,[2,7]]'},'class',design_starter)

  shape('rust-singleton-tuple',[[struct Sample { value: i32 }
impl Solution { pub fn echo(sample: Sample) -> Sample { sample } }
]],{'(4,)'},{'[4]'})
  shape('rust-renamed-constructor-fields',[[struct Pair { first: i32, second: i32 }
impl Pair { fn new(right: i32, left: i32) -> Self { Self { first: left, second: right } } }
impl Solution { pub fn echo(pair: Pair) -> Pair { pair } }
]],{'{"first":8,"second":4}'},{'[4,8]'})
  local documented=[[
// #[derive(Clone)]
// struct Pair { first: i32, second: i32 }
// impl Pair { fn new(right: i32, left: i32) -> Self { Self { first: left, second: right } } }
impl Solution { pub fn shift(pair: Pair) -> Pair { unimplemented!() } }
]]
  run('rust-injected-helper-constructor',[[impl Solution {
    pub fn shift(pair: Pair) -> Pair {
        let copy=pair.clone();
        Pair::new(copy.second+1,copy.first+2)
    }
}]],documented,{'(4,8,)'},{'[5,10]'})
  shape('rust-nested-options',[[impl Solution {
    pub fn echo(values: std::option::Option<Option<std::vec::Vec<i32>>>) -> Option<Option<Vec<i32>>> { values }
}]],{'[1,2]','null'},{'[1,2]','null'})
  shape('rust-internal-state',[[use std::collections::HashMap;
struct State { values: HashMap<i32,i32> }
impl Solution { pub fn sum(values: Vec<i32>) -> i32 {
    let message=r#"struct Fake { bad: Unsupported } // {"#;
    let _brace='}';
    let mut state=State {values: HashMap::new()};
    for value in values { state.values.insert(value,value); }
    assert!(!message.is_empty());
    state.values.values().sum()
} }
]],{'[1,2,3]'},{'6'})
  local store=[[
use std::collections::HashMap;
struct Point { x: i32, y: i32 }
impl Point { fn new(x: i32, y: i32) -> Self { Self { x,y } } }
struct Store { values: HashMap<i32,i32> }
impl Store {
    fn new(point: Point) -> Self { Self { values: HashMap::from([(point.x,point.y)]) } }
    fn get(&self, x: i32) -> i32 { *self.values.get(&x).unwrap_or(&-1) }
    fn put(&mut self, point: Point) { self.values.insert(point.x,point.y); }
}
]]
  shape('rust-design-target-and-state',store,
    {'["Store","get","put","get"]\n[[{"x":1,"y":4}],[1],[{"x":1,"y":9}],[1]]'},
    {'[null,4,null,9]'},'class')
  error_run('rust-nested-duplicate-id',node_code,
    {'{"$id":"x","value":1,"next":{"$id":"x","value":2,"next":null}}'},'duplicate identity id')
  local keeper=[[
struct Entry { value: i32 }
struct Keeper { seed: Rc<RefCell<Entry>> }
impl Keeper {
    fn new(seed: Rc<RefCell<Entry>>) -> Self { Self { seed } }
    fn make(&self, value: i32) -> Rc<RefCell<Entry>> { Rc::new(RefCell::new(Entry { value })) }
    fn pair(&self) -> Vec<Rc<RefCell<Entry>>> { vec![self.seed.clone(),self.seed.clone()] }
}
]]
  shape('rust-design-output-identities',keeper,
    {'["Keeper","make","make","pair"]\n[[{"$id":"seed","value":0}],[1],[2],[]]'},
    {'[null,{"$id":1,"value":1},{"$id":2,"value":2},[{"$id":3,"value":0},{"$ref":3}]]'},'class')

  -- Shared Option codecs must not conflict between isolated oracle/user modules.
  local optional='impl Solution { pub fn expand(value: Option<i32>) -> Option<Vec<i32>> { value.map(|v|vec![v,v+1]) } }'
  local cases={'5','null'}
  local meta={starterCode={rust=optional},solutions={rust=optional},
    custom_test_cases=cases,expected_outputs={'[5,6]','null'}}
  local prepared
  runner.prepare('rust-optional-reference','rust',meta,cases,function(info)prepared=info end)
  assert(vim.wait(120000,function()return prepared~=nil end,10),'optional oracle preparation timed out')
  assert(prepared.stage=='reference','optional oracle rejected: '..vim.inspect(prepared))
  shape('rust-optional-reference',optional,cases,{'[5,6]','null'})
end

local ok,err=xpcall(main_run,debug.traceback)
vim.fn.delete(root,'rf')
if not ok then io.stderr:write(err..'\n');vim.cmd('cquit 1') end
vim.cmd('qa!')