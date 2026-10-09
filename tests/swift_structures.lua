local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))
local swift = require('meatcode.runner.swift')
local root = vim.fn.tempname() .. '_swift_structures'
vim.fn.mkdir(root, 'p')

local starter = [[
struct Point { let x: Int; let y: Int; init(y: Int, x: Int) {} }
class Solution { func transform(_ packet: Packet) -> Packet { fatalError() } }
]]
local code = [[
struct Point {
    let x: Int
    let y: Int
    init(y: Int, x: Int) { self.x = x; self.y = y }
}
struct Packet {
    let point: Point
    let values: [Int]
    let labels: [String: String]
    let note: String?
    init(point: Point, values: [Int], labels: [String: String], note: String?) {
        self.point = point; self.values = values; self.labels = labels; self.note = note
    }
}
class Solution {
    func transform(_ packet: Packet) -> Packet {
        Packet(point: Point(y: packet.point.y, x: packet.point.x + 1),
            values: packet.values, labels: packet.labels, note: packet.note)
    }
}
]]
local function write(path, text)
  local f = assert(io.open(path, 'w')); f:write(text); f:close()
end
local function run()
  local generated, err = swift.generate(starter, nil, code)
  assert(generated, err)
  local src = root .. '/main.swift'
  local exe = root .. '/run'
  write(src, generated)
  local compiled = vim.system({'swiftc', '-o', exe, src}, {text=true}):wait()
  assert(compiled.code == 0, 'swift structure compilation failed:\n' .. (compiled.stderr or ''))
  write(root .. '/cases.json', '["case"]')
  local argument = vim.json.encode({point={x=2, y=7}, values={4,5}, labels={a='b'}, note=vim.NIL})
  write(root .. '/arguments.json', vim.json.encode({{argument}}))
  local result = vim.system({exe, root}, {text=true}):wait()
  assert(result.code == 0, result.stderr or '')
  local report = vim.json.decode(result.stdout)
  assert(report.ok and report.cases[1].status == 'no_oracle', result.stdout)
  local actual = vim.json.decode(report.cases[1].actual)
  assert(actual[1][1] == 7 and actual[1][2] == 3 and actual[2][1] == 4 and actual[3].a == 'b')
  write(root .. '/arguments.json', vim.json.encode({{vim.json.encode('wrong')}}))
  result = vim.system({exe, root}, {text=true}):wait()
  report = vim.json.decode(result.stdout)
  assert(report.ok and report.cases[1].status == 'error'
    and report.cases[1].error:find('expected object or positional array for Packet', 1, true))
  local design_starter = [[
struct Point { let x: Int; let y: Int; init(x: Int, y: Int) {} }
class Solution { init(point: Point) {} func shift(_ amount: Int) -> Point { fatalError() } }
]]
  local design_code = [[
struct Point { let x: Int; let y: Int; init(x: Int, y: Int) { self.x = x; self.y = y } }
class Solution {
    var point: Point
    init(point: Point) { self.point = point }
    func shift(_ amount: Int) -> Point {
        point = Point(x: point.x + amount, y: point.y)
        return point
    }
}
]]
  local design_source, design_err = swift.generate_class(design_starter, nil, design_code)
  assert(design_source, design_err)
  write(src, design_source)
  compiled = vim.system({'swiftc', '-o', exe, src}, {text=true}):wait()
  assert(compiled.code == 0, 'Swift design compilation failed:\n' .. (compiled.stderr or ''))
  write(root .. '/cases.json', '["case"]')
  write(root .. '/ops.json', vim.json.encode({{{'Solution', {x=3, y=4}}, {'shift', 2}}}))
  result = vim.system({exe, root}, {text=true}):wait()
  assert(result.code == 0, result.stderr or '')
  report = vim.json.decode(result.stdout)
  assert(report.ok and report.cases[1].status == 'no_oracle', result.stdout)
  actual = vim.json.decode(report.cases[1].actual)
  assert(actual[2][1] == 5 and actual[2][2] == 4)
  local helper = [[// struct Helper { let value: Int
// init(value: Int) { self.value = value }
// }
class Solution { func f(_ value: Helper) -> Helper { value } }]]
  local helper_code = [[class Solution { func f(_ value: Helper) -> Helper { value } }]]
  local helper_source, helper_err = swift.generate(helper, nil, helper_code)
  assert(helper_source, helper_err)
  write(src, helper_source)
  compiled = vim.system({'swiftc', '-o', exe, src}, {text=true}):wait()
  assert(compiled.code == 0, 'comment-only helper compilation failed:\\n' .. (compiled.stderr or ''))
  write(root .. '/cases.json', '["helper"]')
  write(root .. '/arguments.json', vim.json.encode({{'{"value":4}'}}))
  result = vim.system({exe, root}, {text=true}):wait()
  report = vim.json.decode(result.stdout)
  assert(report.cases[1].actual == '[4]', result.stdout)
  local unsupported, why = swift.parse_signature('class Solution { func f(_ p: Missing) -> Int { 0 } }')
  assert(not unsupported and why:find('unsupported Swift parameter type', 1, true))
  -- Class graph identity: self-cycle and shared/forward references preserved.
  local graph_starter = [[
final class Node {
    var val: Int
    var next: Node?
    init(_ val: Int, _ next: Node?) { self.val = val; self.next = next }
}
class Solution { func transform(_ node: Node) -> Node { node } }
]]
  local graph_source, graph_err = swift.generate(graph_starter, nil, graph_starter)
  assert(graph_source, graph_err)
  write(src, graph_source)
  compiled = vim.system({'swiftc', '-o', exe, src}, {text=true}):wait()
  assert(compiled.code == 0, 'Swift graph compilation failed:\n' .. (compiled.stderr or ''))
  write(root .. '/cases.json', '["case"]')
  write(root .. '/arguments.json', vim.json.encode({{ vim.json.encode({ ['$id']=1, val=7, next={ ['$ref']=1 } }) }}))
  result = vim.system({exe, root}, {text=true}):wait()
  assert(result.code == 0, result.stderr or '')
  report = vim.json.decode(result.stdout)
  assert(report.ok and report.cases[1].status == 'no_oracle', result.stdout)
  actual = vim.json.decode(report.cases[1].actual)
  assert(actual and actual.val == 7 and actual.next
    and actual.next["$ref"] == 1 and actual["$id"] == 1, result.stdout)
  -- Per-case identity isolation: a new case must resolve its own ids.
  write(root .. '/cases.json', '["a", "b"]')
  write(root .. '/arguments.json', vim.json.encode({ { vim.json.encode({ ['$id']=1, val=7, next={ ['$ref']=1 } }) }, { vim.json.encode({ ['$id']=1, val=2, next={ ['$ref']=1 } }) } }))
  result = vim.system({exe, root}, {text=true}):wait()
  assert(result.code == 0 and result.stdout ~= '', result.stderr or '')
  report = vim.json.decode(result.stdout)
  assert(report.ok and #report.cases == 2
    and report.cases[2].status == 'no_oracle'
    and vim.json.decode(report.cases[2].actual).val == 2
    and vim.json.decode(report.cases[2].actual).next["$ref"] == 1)

  require('meatcode.config').setup({cache_dir=root..'/cache',solutions_dir=root..'/solutions',
    runner={parallelism=2,time_limit=2}})
  local runner=require('meatcode.runner')
  local function exercise(id,source,cases,expected,errors,stub)
    local outcome
    runner.run(id,source,'swift',{starterCode={swift=stub or source},
      custom_test_cases=cases,expected_outputs=expected},cases,function(r)outcome=r end)
    assert(vim.wait(120000,function()return outcome~=nil end,10),id..' timed out')
    assert(outcome.ok,id..': '..vim.inspect(outcome))
    for i,row in ipairs(outcome.cases) do
      if errors then
        assert(row.status=='error' and row.error:find(errors[i],1,true),id..': '..vim.inspect(row))
      else
        assert(row.status=='pass' and require('meatcode.runner.answers').compare(row.actual,expected[i])=='pass',
          id..': '..vim.inspect(row))
      end
    end
    print(id..' passed')
  end
  local sample=[[
final class Sample {
    var value: Int
    init(_ initial: Int = 7) { self.value = initial }
}
]]
  local maps=sample..[[class Solution {
    func echo(_ records: [String: Sample?]) -> [String: Sample?] { records }
}]]
  exercise('swift-optional-record-map',maps,
    {'{"a":[4],"empty":null}','{"b":{"$ref":"s"},"a":{"$id":"s","value":4}}','{"a":[]}'},
    {'{"a":[4],"empty":null}','{"a":{"$id":1,"value":4},"b":{"$ref":1}}','{"a":[7]}'})
  exercise('swift-unknown-record-field',maps,{'{"a":{"value":4,"extra":9}}'},
    {'null'},{'unknown fields for Sample'})
  exercise('swift-duplicate-id',maps,
    {'{"a":{"$id":1,"value":4},"b":{"$id":1,"value":9}}'}, {'null'},{'duplicate identity id'})
  exercise('swift-unresolved-ref',maps,{'{"a":{"$ref":"missing"}}'},
    {'null'},{'unresolved identity reference'})
  local sharing=sample..[[class Solution {
    func share(_ sample: Sample) -> [Sample] { [sample,sample] }
}]]
  exercise('swift-created-sharing',sharing,{'[5]'},
    {'[{"$id":1,"value":5},{"$ref":1}]'})
  local built_cycle=[[
final class Node {
    var value: Int
    var next: Node?
    init(_ value: Int, _ next: Node?) { self.value=value; self.next=next }
}
class Solution {
    func loop(_ value: Int) -> Node {
        let node=Node(value,nil)
        node.next=node
        return node
    }
}
]]
  exercise('swift-created-cycle',built_cycle,{'9'},
    {'{"$id":1,"value":9,"next":{"$ref":1}}'})
  local wrong_type=sample..[[
final class Other { var tag: Int; init(_ tag: Int) { self.tag=tag } }
class Solution { func same(_ a: Sample, _ b: Other) -> Bool { false } }
]]
  exercise('swift-wrong-type-ref',wrong_type,
    {'a={"$id":"same","value":5}\nb={"$ref":"same"}'}, {'null'},{'identity reference has the wrong type'})
  exercise('swift-starter-actual-helper',[[class Solution {
    func echo(_ sample: Sample) -> Sample { sample }
}]],{'{"value":6}'},{'[6]'},nil,sample..[[class Solution {
    func echo(_ sample: Sample) -> Sample { sample }
}]])
  exercise('swift-commented-default',[[struct Sample {
    var value: Int = 7 // default value
}
class Solution { func echo(_ sample: Sample) -> Sample { sample } }
]],{'{}'}, {'[7]'})
  exercise('swift-singleton-tuple',[[struct Sample { var value: Int }
class Solution { func echo(_ sample: Sample) -> Sample { sample } }
]],{'(4,)'},{'[4]'})
  exercise('swift-block-comment-helper',[[class Solution {
    func echo(_ point: Point) -> Point { point }
}]],{'(4,)'},{'[4]'},nil,[[/* struct Point { var value: Int } */
class Solution { func echo(_ point: Point) -> Point { point } }
]])
  exercise('swift-internal-state',[[struct State { var values: Set<Int> }
class Solution {
    func sum(_ values: [Int]) -> Int {
        let state=State(values: Set(values))
        return state.values.reduce(0,+)
    }
}]],{'[1,2,3]'},{'6'})
  exercise('swift-empty-class',[[class Empty {}
class Solution { func echo(_ value: Empty) -> Empty { value } }
]],{'{}','{"$id":"empty"}'},{'[]','{"$id":1}'})
  local keeper=sample..[[
class Keeper {
    var seed: Sample
    init(_ seed: Sample) { self.seed=seed }
    func make(_ value: Int) -> Sample { Sample(value) }
    func pair() -> [Sample] { [seed,seed] }
}
]]
  local outcome
  local case='["Keeper","make","make","pair"]\n[[{"$id":"seed","value":0}],[1],[2],[]]'
  runner.run('swift-design-output-identities',keeper,'swift',
    {starterCode={swift=keeper},test_case_type='class',custom_test_cases={case},expected_outputs={
      '[null,{"$id":1,"value":1},{"$id":2,"value":2},[{"$id":3,"value":0},{"$ref":3}]]'}},
    {case},function(value)outcome=value end)
  assert(vim.wait(120000,function()return outcome~=nil end,10),'Swift design identity run timed out')
  assert(outcome.ok and outcome.passed==1,'swift-design-output-identities: '..vim.inspect(outcome))
  print('swift-design-output-identities passed')
end
local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, 'rf')
if not ok then error(err) end
print('All Swift structure regressions passed')
