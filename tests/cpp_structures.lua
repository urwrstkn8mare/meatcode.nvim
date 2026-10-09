-- Declaration-derived record codecs: arbitrary named records, nested records,
-- collection/optional/map fields, constructor order, in-place and design
-- behavior, comment-only vs actual definitions, identity graphs (self-cycles,
-- shared/forward references, per-case isolation), explicit shape errors, and
-- the standard ListNode/TreeNode encodings.
local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))
local root = vim.fn.tempname()
require('meatcode.config').setup({cache_dir=root, solutions_dir=root..'/solutions', runner={parallelism=1, time_limit=2}})
if vim.env.MEATCODE_CPP_COMPILER then
  require('meatcode.config').options.runner.cpp.cmd[1] = vim.env.MEATCODE_CPP_COMPILER
  -- The sandbox resolves symlinks; keep clang++ in C++ driver mode.
  if vim.fs.basename(vim.env.MEATCODE_CPP_COMPILER) == 'clang++' then
    table.insert(require('meatcode.config').options.runner.cpp.cmd, '--driver-mode=g++')
  end
  if vim.env.SDKROOT then
    vim.list_extend(require('meatcode.config').options.runner.cpp.cmd, {'-isysroot', vim.env.SDKROOT})
  end
end

local runner = require('meatcode.runner')

local function raw_run(id, code, starter, cases, outputs, kind)
  local report
  runner.run(id, code, 'cpp', {starterCode={cpp=starter}, custom_test_cases=cases,
    expected_outputs=outputs, test_case_type=kind or 'function'}, cases, function(r) report=r end)
  assert(vim.wait(180000, function() return report~=nil end, 10), id..' timed out')
  return report
end

local function run(id, code, starter, cases, outputs, kind)
  local report = raw_run(id, code, starter, cases, outputs, kind)
  assert(report.ok and report.passed == #cases, id..': '..vim.inspect(report))
  for i, case in ipairs(report.cases or {}) do
    assert(case.actual == outputs[i], id..' case '..i..' produced '..tostring(case.actual)
      ..', expected '..outputs[i])
  end
  print(id..' passed '..report.passed..'/'..report.total)
end

local function error_run(id, code, starter, cases)
  local report = raw_run(id, code, starter, cases, {})
  assert(report.ok and report.passed == 0 and #report.cases == #cases,
    id..' did not reject each input in the harness: '..vim.inspect(report))
  for i, case in ipairs(report.cases or {}) do
    assert(case.status == 'error' or case.status == 'oracle_error',
      id..' case '..i..' expected an error, got '..case.status)
  end
  print(id..' reported the expected error')
end

local function unsupported_run(id, code, starter)
  local report = raw_run(id, code, starter, {'[]'}, {'[]'})
  assert(not report.ok and report.unsupported == true,
    id..' expected an unsupported error, got: '..vim.inspect(report))
  print(id..' reported the expected unsupported boundary')
end

local function run_all()
  -- ---------------------------------------------------------------- value records
  -- Comment-documented Point: nested record vector, named-object and positional
  -- arguments, positional return order.
  local point_comment = [[
/**
 * struct Point {
 *   int x;
 *   int y;
 * };
 */
]]
  local point_starter = point_comment .. [[
class Solution {
public:
  vector<Point> shift(vector<Point>& points, int dx) {}
};
]]
  local point_code = point_comment .. [[
class Solution {
public:
  vector<Point> shift(vector<Point>& points, int dx) {
    for (auto& point : points) point.x += dx;
    return points;
  }
};
]]
  run('cpp-structures-point-nested', point_code, point_starter,
    {'points=[[1,2],[8,1]]\ndx=2', 'points=[{"x":1,"y":2},{"x":0,"y":1}]\ndx=3',
      'points=[{"y":2,"x":1}]\ndx=1'},
    {'[[3,2],[10,1]]', '[[4,2],[3,1]]', '[[2,2]]'})

  -- Records defined only in the actual source (no comment block): nested
  -- record plus a vector field, decoded positionally and by name.
  local packet_starter = point_comment .. [[
class Solution {
public:
  Packet merge(vector<Packet>& packets) {}
};
]]
  local packet_code = [[
struct Packet { Point origin; vector<int> samples; };
class Solution { public:
  Packet merge(vector<Packet>& packets) {
    Packet result;
    result.origin = packets[0].origin;
    for (auto& packet : packets)
      for (int value : packet.samples) result.samples.push_back(value);
    return result;
  }
};
]]
  run('cpp-structures-packet-actual', packet_code, packet_starter,
    {'packets=[{"origin":{"x":1,"y":2},"samples":[4,5]},{"origin":{"x":0,"y":0},"samples":[9]}]',
      '[[[1,2],[4,5]],[[0,0],[9]]]'},
    {'[[1,2],[4,5,9]]', '[[1,2],[4,5,9]]'})

  -- Map and optional fields: null optional, sorted map keys, named objects
  -- may omit optionals; wrong shapes fail explicitly.
  local bag_comment = [[
/**
 * struct Bag {
 *   std::optional<int> tag;
 *   std::map<std::string, int> counts;
 *   int id;
 * };
 */
]]
  local bag_starter = bag_comment .. [[
class Solution {
public:
  Bag echo(Bag bag) {}
};
]]
  local bag_code = bag_comment .. [[
class Solution {
public:
  Bag echo(Bag bag) { return bag; }
};
]]
  run('cpp-structures-map-optional', bag_code, bag_starter,
    {'bag=[7,{"a":1,"b":2},3]', 'bag={"id":7,"counts":{"b":2,"a":1}}', 'bag=[null,{},0]'},
    {'[7,{"a":1,"b":2},3]', '[null,{"a":1,"b":2},7]', '[null,{},0]'})
  error_run('cpp-structures-bag-shape', bag_code, bag_starter,
    {'bag=[1,2,3,4]'})

  -- Constructor parameter order over field declaration order: positional
  -- slots follow the constructor mapping (a before b), not field order.
  local order_starter = [[
struct Order { int b; int a; Order(int x, int y) : a(x), b(y) {} };
class Solution {
public:
  Order swap(Order order) {}
};
]]
  local order_code = [[
struct Order { int b; int a; Order(int x, int y) : a(x), b(y) {} };
class Solution { public:
  Order swap(Order order) {
    int keep = order.a; order.a = order.b; order.b = keep;
    return order;
  }
};
]]
  run('cpp-structures-ctor-order', order_code, order_starter,
    {'order=[3,4]', 'order={"a":1,"b":2}'},
    {'[4,3]', '[2,1]'})

  -- Non-default value constructors decode directly through vectors and
  -- nested aggregate fields without constructing T{} or assigning fields.
  local nested_ctor_starter = [[
struct Point { int x; int y; Point(int x, int y) : x(x), y(y) {} };
struct Envelope { vector<Point> points; };
class Solution { public:
  vector<Envelope> echo(vector<Envelope> values) {}
};
]]
  local nested_ctor_code = [[
struct Point { int x; int y; Point(int x, int y) : x(x), y(y) {} };
struct Envelope { vector<Point> points; };
class Solution { public:
  vector<Envelope> echo(vector<Envelope> values) { return values; }
};
]]
  run('cpp-structures-nondefault-nested-vector', nested_ctor_code, nested_ctor_starter,
    {'values=[[[[1,2],[3,4]]]]'}, {'[[[[1,2],[3,4]]]]'})

  -- Scalar-only records are still reference-capable when used through a
  -- pointer; acyclic pointer inputs accept ordinary positional and named data.
  local token_starter = [[
struct Token { int value; Token(int value) : value(value) {} };
class Solution { public: Token* echo(Token* token) {} };
]]
  local token_code = [[
struct Token { int value; Token(int value) : value(value) {} };
class Solution { public: Token* echo(Token* token) { return token; } };
]]
  run('cpp-structures-plain-pointer-values', token_code, token_starter,
    {'token=[5]', 'token={"value":7}'}, {'[5]', '[7]'})

  -- In-place value-record mutation through the void-return path.
  local mutate_starter = [[
struct Counter { int hits; int misses; };
class Solution {
public:
  void tally(vector<Counter>& counters, int delta) {}
};
]]
  local mutate_code = [[
struct Counter { int hits; int misses; };
class Solution { public:
  void tally(vector<Counter>& counters, int delta) {
    for (auto& counter : counters) { counter.hits += delta; counter.misses -= delta; }
  }
};
]]
  run('cpp-structures-in-place', mutate_code, mutate_starter,
    {'counters=[(1,2),(3,4)]\ndelta=2', '[]\n5'},
    {'[[3,0],[5,2]]', '[]'})

  -- ------------------------------------------------------------------ design
  -- Design class with a nested record constructor argument and record ops.
  local design = [[
/**
 * class Interval {
 * public:
 *     int start, end;
 *     Interval(int start, int end) {
 *         this->start = start;
 *         this->end = end;
 *     }
 * }
 */
class Calendar { Interval slot; public:
    Calendar(Interval initial) : slot(initial) {}
    bool overlaps(Interval other) { return other.start < slot.end && slot.start < other.end; }
};]]
  run('cpp-structures-design', design, design,
    {'["Calendar","overlaps","overlaps"]\n[[[2,5]],[[4,7]],[[5,8]]]',
      '["Calendar","overlaps"]\n[[{"start":1,"end":9}],[{"start":2,"end":3}]]'},
    {'[null,true,false]', '[null,true]'}, 'class')

  -- Roundtrip pair driven through both directions.
  local roundtrip = [[
class Codec {
public:
    string encode(string s) { return s; }
    string decode(string s) { return s; }
};]]
  run('cpp-structures-roundtrip', roundtrip, roundtrip,
    {'"abc"', '""'}, {'"abc"', '""'}, 'class')

  -- --------------------------------------------------------------- identity
  -- Reference-capable records: self-cycle keeps its id, explicit string ids
  -- renumber canonically, and per-case isolation restarts the numbering.
  local node_comment = [[
/**
 * class Node {
 * public:
 *     int val;
 *     Node *next;
 *     Node(int x) : val(x), next(nullptr) {}
 * }
 */
]]
  local node_starter = node_comment .. [[
class Solution {
public:
  Node* identity(Node* head) {}
};
]]
  local node_code = node_comment .. [[
class Solution {
public:
  Node* identity(Node* head) { return head; }
};
]]
  run('cpp-structures-node-cycle', node_code, node_starter,
    {'head={"$id":1,"val":7,"next":{"$ref":1}}', 'head={"$id":"n","val":9,"next":null}'},
    {'{"$id":1,"val":7,"next":{"$ref":1}}', '{"$id":1,"val":9,"next":null}'})

  -- A solution-built acyclic chain serializes positionally.
  local chain_starter = node_comment .. [[
class Solution {
public:
  Node* build(int n) {}
};
]]
  local chain_code = node_comment .. [[
class Solution {
public:
  Node* build(int n) {
    Node* head = new Node(n);
    head->next = new Node(n + 1);
    return head;
  }
};
]]
  run('cpp-structures-node-positional', chain_code, chain_starter,
    {'3'}, {'[3,[4,null]]'})

  -- Sharing created by the solution itself must keep identity.
  local pair_starter = node_comment .. [[
struct Pair { Node *a; Node *b; };
class Solution {
public:
    Pair dup(int v) {}
};
]]
  local pair_code = node_comment .. [[
struct Pair { Node *a; Node *b; };
class Solution { public:
    Pair dup(int v) {
        Node* n = new Node(v);
        Pair p; p.a = n; p.b = n;
        return p;
    }
};
]]
  run('cpp-structures-shared-output', pair_code, pair_starter,
    {'5'}, {'[{"$id":1,"val":5,"next":null},{"$ref":1}]'})

  -- Forward reference across arguments, then the explicit rejection cases.
  local linked_comment = node_comment .. [[
/**
 * struct Other {
 *   int tag;
 * };
 */
]]
  local linked_starter = linked_comment .. [[
class Solution {
public:
  bool linked(Node* a, Node* b) {}
};
]]
  local linked_code = linked_comment .. [[
class Solution {
public:
  bool linked(Node* a, Node* b) { return a == b; }
};
]]
  run('cpp-structures-forward-ref', linked_code, linked_starter,
    {'a={"$ref":"a"}\nb={"$id":"a","val":1,"next":null}'}, {'true'})

  local forward_design_starter = node_comment .. [[
class Registry {
public:
  Registry() {}
  bool has_value(Node* node) {}
};
]]
  local forward_design_code = node_comment .. [[
class Registry {
public:
  Registry() {}
  bool has_value(Node* node) { return node && node->val == 7; }
};
]]
  run('cpp-structures-forward-ref-design-ops', forward_design_code, forward_design_starter,
    {'["Registry","has_value","has_value"]\n[[],[{"$ref":"later"}],[{"$id":"later","val":7,"next":null}]]'},
    {'[null,true,true]'}, 'class')

  error_run('cpp-structures-duplicate-id', linked_code, linked_starter,
    {'a={"$id":1,"val":1,"next":null}\nb={"$id":1,"val":2,"next":null}'})

  error_run('cpp-structures-unresolved-ref', node_code, node_starter,
    {'head={"$ref":99}'})

  error_run('cpp-structures-ref-extra-fields', node_code, node_starter,
    {'head={"$ref":99,"val":1}'})

  local mixed_starter = linked_comment .. [[
class Solution {
public:
  bool mix(Node* a, Other* b) {}
};
]]
  local mixed_code = linked_comment .. [[
class Solution {
public:
  bool mix(Node* a, Other* b) { return a != nullptr && b != nullptr; }
};
]]
  error_run('cpp-structures-wrong-type-ref', mixed_code, mixed_starter,
    {'a={"$id":"x","val":1,"next":null}\nb={"$ref":"x"}'})

  error_run('cpp-structures-value-identity-tag', bag_code, bag_starter,
    {'bag={"$id":1,"tag":1,"counts":{},"id":2}'})

  error_run('cpp-structures-node-missing-field', node_code, node_starter,
    {'head={"$id":1,"val":5}'})

  -- Helpers present only in actual source are bound separately in each
  -- generated namespace, while unrelated unsupported state remains untouched.
  local packet_actual_starter = [[
class Solution {
public:
  vector<Packet> echo(vector<Packet>& packets) {}
};
]]
  local packet_actual_code = [[
struct Packet { int id; };
class Solution { public:
  vector<Packet> echo(vector<Packet>& packets) { return packets; }
};
]]
  run('cpp-structures-actual-source-helper', packet_actual_code, packet_actual_starter,
    {'packets=[{"id":3},{"id":1}]'}, {'[[3],[1]]'})

  local starter_record = [[
struct Ticket { int id; };
class Solution { public:
  Ticket echo(Ticket value) {}
};
]]
  local starter_record_code = [[
class Solution { public:
  Ticket echo(Ticket value) { return value; }
};
]]
  run('cpp-structures-actual-starter-helper', starter_record_code, starter_record,
    {'value={"id":12}'}, {'[12]'})

  local internal_starter = [[
class Solution { public:
  int inc(int value) {}
};
]]
  local internal_code = [[
struct Internal { int value = 5; };
class Solution { public:
  int inc(int value) { return value + 1; }
};
]]
  run('cpp-structures-unserialized-internal-state', internal_code, internal_starter,
    {'2', '9'}, {'3', '10'})

  -- Pointer identity recurses through maps, optionals, and vectors; map
  -- traversal is sorted and a forward ref shares the later scalar-only target.
  local graph_starter = [[
class Solution { public:
  Bag share(Bag bag) {}
};
]]
  local graph_code = [[
struct Leaf { int value; };
struct Bag {
  map<string, optional<Leaf*>> lookup;
  vector<Leaf*> items;
};
class Solution { public:
  Bag share(Bag bag) {
    Leaf* shared = bag.items[0];
    bag.items = {shared, shared};
    bag.lookup["z"] = shared;
    return bag;
  }
};
]]
  run('cpp-structures-nested-container-identity', graph_code, graph_starter,
    {'bag={"lookup":{"a":{"$ref":"leaf"},"none":null},"items":[{"$id":"leaf","value":6}]}'},
    {'[{"a":{"$id":1,"value":6},"none":null,"z":{"$ref":1}},[{"$ref":1},{"$ref":1}]]'})

  local unsafe_ctor_starter = [[
class Solution { public:
  Unsafe echo(Unsafe value) {}
};
]]
  local unsafe_ctor_code = [[
struct Unsafe {
  int first;
  int second;
  Unsafe(int a, int b) : first(a + 1), second(b) {}
};
class Solution { public:
  Unsafe echo(Unsafe value) { return value; }
};
]]
  unsupported_run('cpp-structures-unsafe-constructor', unsafe_ctor_code, unsafe_ctor_starter)

  -- The operation target is named by the first design operation even when a
  -- helper class precedes it in the starter/source.
  local target_after_helper = [[
class Helper {
public:
  int value;
  int get() { return value; }
};
class Calendar {
public:
  Calendar() {}
  int today() { return 0; }
};
]]
  local target_after_helper_code = [[
class Helper {
public:
  int value;
  int get() { return value; }
};
class Calendar {
public:
  Calendar() {}
  int today() { return 7; }
};
]]
  run('cpp-structures-design-target-after-helper', target_after_helper_code,
    target_after_helper, {'["Calendar","today"]\n[[],[]]'}, {'[null,7]'}, 'class')

  -- ---------------------------------------------------- unsupported boundaries
  local bad_ptr_starter = [[
class Solution {
public:
  vector<Link> go(vector<Link>& l) {}
};
]]
  local bad_ptr_code = [[
struct Link { int v; Foo* next; };
class Solution { public: vector<Link> go(vector<Link>& l) { return l; } };
]]
  unsupported_run('cpp-structures-unknown-pointer', bad_ptr_code, bad_ptr_starter)

  local no_default_starter = [[
class Solution {
public:
  vector<C> go(vector<C>& l) {}
};
]]
  local no_default_code = [[
struct C { int v; C* next; C(int x) : v(x) {} };
class Solution { public: vector<C> go(vector<C>& l) { return l; } };
]]
  run('cpp-structures-nondefault-pointer-field', no_default_code, no_default_starter,
    {'l=[[3,null]]'}, {'[[3,null]]'})

  local default_init_starter = [[
class Solution {
public:
  vector<D> go(vector<D>& l) {}
};
]]
  local default_init_code = [[
struct D { int x = 5; };
class Solution { public: vector<D> go(vector<D>& l) { return l; } };
]]
  unsupported_run('cpp-structures-default-initializer', default_init_code, default_init_starter)

  -- ------------------------------------------------------ standard encodings
  local list_starter = [[
class Solution {
public:
  ListNode* reverse(ListNode* head) {}
};
]]
  local list_code = [[
class Solution {
public:
  ListNode* reverse(ListNode* head) {
    ListNode* prev = nullptr;
    while (head) { ListNode* next = head->next; head->next = prev; prev = head; head = next; }
    return prev;
  }
};
]]
  run('cpp-structures-list-regression', list_code, list_starter,
    {'[1,2,3]', '[]'}, {'[3,2,1]', '[]'})

  local tree_starter = [[
class Solution {
public:
  int depth(TreeNode* root) {}
};
]]
  local tree_code = [[
class Solution {
public:
  int depth(TreeNode* root) {
    if (!root) return 0;
    return 1 + max(depth(root->left), depth(root->right));
  }
};
]]
  run('cpp-structures-tree-regression', tree_code, tree_starter,
    {'[1,null,2,3]', '[]'}, {'3', '0'})
end

local ok, err = xpcall(run_all, debug.traceback)
vim.fn.delete(root, 'rf')
if not ok then io.stderr:write(err..'\n'); vim.cmd('cquit 1') end
vim.cmd('qa!')