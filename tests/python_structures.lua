-- Typed structure (record/graph) regressions for the Python harness.
-- Exercises the real runner: user.py/ref.py/starter.py workdirs, cases.json,
-- ops.json and the python.py subprocess, like production local runs.
local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))
local root = vim.fn.tempname()
require('meatcode.config').setup({cache_dir=root, solutions_dir=root..'/solutions', runner={parallelism=2, time_limit=2}})
local runner = require('meatcode.runner')

local prelude = [[
class Leaf:
    def __init__(self, name: str, score: int = 7):
        self.name = name
        self.score = score

class Packet:
    def __init__(self, label: str, leaves: list[Leaf], index: dict[str, Leaf], maybe: Leaf | None = None):
        self.label = label
        self.leaves = leaves
        self.index = index
        self.maybe = maybe

class Node:
    def __init__(self, value: int, next: 'Node | None' = None):
        self.value = value
        self.next = next
]]

-- Builds matching user code (with a body) and starter stub for one method.
local function pair(signature, body)
  return prelude..'class Solution:\n    def '..signature..':\n        '..body..'\n',
    prelude..'class Solution:\n    def '..signature..': pass\n'
end

-- Asserts the run itself AND the exact serialized shape of every case, so
-- unordered legacy grading cannot mask positional record/field swaps.
local function run(id, code, starter, cases, outputs, kind)
  local report
  local meta = {starterCode={python=starter}, custom_test_cases=cases,
    expected_outputs=outputs, test_case_type=kind or 'function'}
  runner.run(id, code, 'python', meta, cases, function(r) report = r end)
  assert(vim.wait(120000, function() return report ~= nil end, 10), id..' timed out')
  assert(report.ok and report.passed == #cases, id..': '..vim.inspect(report))
  for i, out in ipairs(outputs) do
    local case = report.cases[i]
    assert(case and case.status == 'pass', id..' case '..i..' status: '..vim.inspect(case))
    assert(case.actual == out, id..' case '..i..' shape: got '..tostring(case.actual)
      ..' want '..out)
  end
  print(id..' passed '..report.passed..'/'..report.total)
end

-- A run expected to produce a per-case error (bad identity/shape input).
local function failing(id, code, starter, block)
  local report
  local meta = {starterCode={python=starter}, custom_test_cases={block},
    expected_outputs={'null'}}
  runner.run(id, code, 'python', meta, {block}, function(r) report = r end)
  assert(vim.wait(120000, function() return report ~= nil end, 10), id..' timed out')
  local case = report.cases and report.cases[1]
  assert(case and case.status == 'error',
    id..' was not rejected explicitly: '..vim.inspect(report))
  print(id..' rejected: '..(case.error or ''):gsub('\n.*', ''))
end

local function run_case()
  -- Nested records: positional arrays, named maps with record values,
  -- constructor defaults filled in, optional field defaulted to null.
  local code, stub = pair('echo(self, packet: Packet) -> Packet', 'return packet')
  run('python-nested-records', code, stub,
    {'["box",[["oak"]],{"primary":["elm"]},["fir"]]'},
    {'["box",[["oak",7]],{"primary":["elm",7]},["fir",7]]'})
  run('python-named-record', code, stub,
    {'{"label":"box","leaves":[["oak"]],"index":{}}'},
    {'["box",[["oak",7]],{},null]'})

  -- In-place mutation of a record argument keeps positional serialization.
  code, stub = pair('mutate(self, packet: Packet) -> None', "packet.label = 'changed'")
  run('python-inplace-record', code, stub,
    {'["old",[],{},null]'}, {'["changed",[],{},null]'})

  -- Standard ListNode/TreeNode encodings still work end to end.
  code, stub = pair('list_identity(self, head: ListNode) -> ListNode', 'return head')
  run('python-listnode', code, stub, {'[1,2,3]'}, {'[1,2,3]'})
  code, stub = pair('tree_identity(self, root: TreeNode) -> TreeNode', 'return root')
  run('python-treenode', code, stub, {'[1,2,3]'}, {'[1,2,3]'})

  -- Explicit graph identity: self-cycle, forward reference and shared target
  -- across two arguments; canonical integer ids on output; per-case isolation
  -- (the same string id in both cases must not leak between invocations).
  code, stub = pair('graph(self, root: Node) -> bool', 'return root.next.next is root')
  run('python-graph-cycle', code, stub,
    {'{"$id":"root","value":1,"next":{"$ref":"root"}}',
     '{"$id":"root","value":2,"next":{"$ref":"root"}}'},
    {'true', 'true'})
  code, stub = pair('same(self, a: Node, b: Node) -> bool', 'return a is b')
  run('python-forward-shared', code, stub,
    {'a={"$ref":1}\nb={"$id":1,"value":2,"next":null}'}, {'true'})
  code, stub = pair('echo_node(self, root: Node) -> Node', 'return root')
  run('python-graph-return', code, stub,
    {'{"$id":"root","value":1,"next":{"$ref":"root"}}'},
    {'{"$id":1,"value":1,"next":{"$ref":1}}'})
  code, stub = pair('both(self, a: Node, b: Node) -> list[Node]', 'return [a, b]')
  run('python-shared-return', code, stub,
    {'a={"$id":"n","value":2,"next":null}\nb={"$ref":"n"}'},
    {'[{"$id":1,"value":2,"next":null},{"$ref":1}]'})

  -- Graph errors: duplicate ids, unresolved references and wrong shapes.
  code, stub = pair('same(self, a: Node, b: Node) -> bool', 'return a is b')
  failing('python-duplicate-id', code, stub,
    '{"$id":1,"value":1,"next":null}\n{"$id":1,"value":2,"next":null}')
  code, stub = pair('echo_node(self, root: Node) -> Node', 'return root')
  failing('python-unresolved-ref', code, stub, '{"$ref":"missing"}')
  failing('python-unknown-field', code, stub, '{"value":1,"next":null,"extra":2}')
  code, stub = pair('get(self, leaf: Leaf) -> int', 'return leaf.score')
  run('python-scalar-field-identity', code, stub,
    {'{"$id":"x","name":"a","score":3}'}, {'3'})
  code, stub = pair('get(self, value: int) -> int', 'return value')
  failing('python-primitive-identity', code, stub, '{"$id":"x","value":3}')

  -- Named keys are stored attributes; positional order is constructor order.
  local reordered = [[
class Point:
    def __init__(self, y: int, x: int):
        self.x = x
        self.y = y
class Solution:
    def echo(self, point: Point) -> Point:
        return point
]]
  run('python-constructor-order', reordered, reordered,
    {'{"x":9,"y":2}', '(2,9)'}, {'[2,9]', '[2,9]'})
  failing('python-missing-field', reordered, reordered, '{"x":9}')
  failing('python-surplus-values', reordered, reordered, '[1,2,3]')
  local renamed = [[
class Record:
    __slots__ = ("value",)
    def __init__(self, initial: int):
        self.value = initial
class Solution:
    def both(self, a: Record, b: Record) -> list[Record]:
        return [a,b]
]]
  run('python-renamed-slotted-identity', renamed, renamed,
    {'a={"$ref":"r"}\nb={"$id":"r","value":4}'},
    {'[{"$id":1,"value":4},{"$ref":1}]'})
  local commented = [[
# Definition of Sample:
# class Sample:
#     def __init__(self, text: str):
#         self.text = text
class Solution:
    def echo(self, item: Sample) -> Sample:
        return item
]]
  run('python-comment-only-helper', commented, commented,
    {'{"text":"(literal)"}'}, {'["(literal)"]'})
  local constructed = prelude..[[
class Solution:
    def shared(self, leaf: Leaf) -> list[Leaf]:
        return [leaf, leaf]
]]
  run('python-created-sharing', constructed, constructed, {'["oak"]'},
    {'[{"$id":1,"name":"oak","score":7},{"$ref":1}]'})
  local dataclass_helper = [[
# @dataclass
# class Sample:
#     value: int
#     note: str | None = None
class Solution:
    def echo(self, item: Sample) -> Sample:
        return item
]]
  run('python-decorated-helper', dataclass_helper, dataclass_helper,
    {'{"value":6}', '[9,"text"]'}, {'[6,null]', '[9,"text"]'})
  -- Tuple rows keep Python parentheses but JSON keywords. Quoted "null" stays
  -- text; bare null/true/false become None/True/False.
  local flagged = [[
class Flag:
    def __init__(self, on: bool, tag: str | None = None):
        self.on = on
        self.tag = tag
class Solution:
    def echo(self, items: list[Flag]) -> list[Flag]:
        return items
]]
  run('python-json-words-in-tuples', flagged, flagged,
    {'[(true,null),(false,"null")]'},
    {'[[true,null],[false,"null"]]'})

  local no_init = [[
class Entry:
    def __init__(self, value: int):
        self.value = value
class Vault:
    def accepts(self, item: Entry) -> bool:
        return isinstance(item, Entry)
]]
  run('python-design-implicit-init',no_init,no_init,
    {'["Vault","accepts"]\n[[],[{"value":4}]]'}, {'[null,true]'}, 'class')
  local forward = [=[
class Entry:
    def __init__(self, value: int):
        self.value = value
class Solution:
    def total(self, items: List[Optional['Entry']]) -> int:
        return sum(item.value for item in items if item is not None)
]=]
  run('python-forward-annotations',forward,forward,
    {'[{"value":4},null,[6]]'}, {'10'})
  code,stub=pair('score(self, leaf: Leaf) -> int','return leaf.score')
  failing('python-nonoptional-record-null',code,stub,'null')
  code,stub=pair('fraction(self, value: float) -> float','return value + 0.5')
  run('python-float-integer-input',code,stub,{'4','"6"'},{'4.5','6.5'})
  local keeper=[[
class Entry:
    def __init__(self, value: int):
        self.value=value
class Keeper:
    def __init__(self, seed: Entry):
        self.seed=seed
    def make(self, value: int) -> Entry:
        return Entry(value)
    def pair(self) -> list[Entry]:
        return [self.seed,self.seed]
]]
  run('python-design-output-identities',keeper,keeper,
    {'["Keeper","make","make","pair"]\n[[{"$id":"seed","value":0}],[1],[2],[]]'},
    {'[null,{"$id":1,"value":1},{"$id":2,"value":2},[{"$id":3,"value":0},{"$ref":3}]]'}, 'class')

  -- Roundtrip path shares the same codecs (encode/decode pair, identity-free).
  local codec = [[
class Codec:
    def encode(self, strs: list[str]) -> str:
        return "|".join(strs)
    def decode(self, s: str) -> list[str]:
        return s.split("|") if s else []
]]
  run('python-roundtrip', codec, codec,
    {'strs=["hello","world"]', 'strs=[]'},
    {'["hello","world"]', '[]'}, 'class')

  -- Design path: object-valued operations decode to real records and the
  -- object-returning method serializes positionally.
  local vault = [[
class Entry:
    def __init__(self, value: int):
        self.value = value

class Vault:
    def __init__(self):
        self.items = []
    def add(self, item: Entry) -> None:
        self.items.append(item)
    def values(self) -> list[Entry]:
        return self.items
]]
  run('python-design-object-operation', vault, vault,
    {'["Vault","add","values"]\n[[],[{"value":4}],[]]'},
    {'[null,null,[[4]]]'}, 'class')
end

local ok, err = xpcall(run_case, debug.traceback)
vim.fn.delete(root, 'rf')
if not ok then
  io.stderr:write(err..'\n')
  vim.cmd('cquit 1')
end
vim.cmd('qa!')
