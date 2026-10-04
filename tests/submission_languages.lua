local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))

local cpp = require('meatcode.submission.cpp')
local py = require('meatcode.submission.python')

local root = vim.fn.tempname() .. ' with spaces'
vim.fn.mkdir(root, 'p')

local function compile_and_run_cpp(name, code, main_body)
  local src_path = root .. '/' .. name .. '.cpp'
  local bin_path = root .. '/' .. name
  local full_src = [[
#include <vector>
#include <string>
#include <utility>
#include <memory>
#include <cassert>
#include <iostream>
using namespace std;

]] .. code .. [[

int main() {
]] .. main_body .. [[
    cout << "passed\n";
    return 0;
}
]]
  vim.fn.writefile(vim.split(full_src, '\n', { plain = true }), src_path)
  local compiled = vim.system({ 'c++', '-std=c++23', '-o', bin_path, src_path }, { text = true }):wait()
  assert(compiled.code == 0, name .. ' C++ compilation failed: ' .. (compiled.stderr or ''))
  local executed = vim.system({ bin_path }, { text = true }):wait()
  assert(executed.code == 0, name .. ' C++ execution failed: ' .. (executed.stderr or ''))
  assert(executed.stdout:find('passed') ~= nil, name .. ' C++ unexpected output: ' .. executed.stdout)
end

local function run_python(name, code, test_body)
  local script_path = root .. '/' .. name .. '.py'
  local full_src = code .. '\n\n' .. test_body .. '\nprint("passed")\n'
  vim.fn.writefile(vim.split(full_src, '\n', { plain = true }), script_path)
  local executed = vim.system({ 'python3', script_path }, { text = true }):wait()
  assert(executed.code == 0, name .. ' Python execution failed: ' .. (executed.stderr or ''))
  assert(executed.stdout:find('passed') ~= nil, name .. ' Python unexpected output: ' .. executed.stdout)
end

local function run()
  -- =========================================================================
  -- C++ Tests
  -- =========================================================================

  -- 1. Real C++ cross-provider adaptation with different method names
  local cpp_source = 'class Solution { public: int search(vector<int>& nums, int target) {} };'
  local cpp_judge = 'class Solution { public: int find(vector<int>& nums, int target) {} };'
  local cpp_code = [[
class Solution {
public:
    int search(vector<int>& nums, int target) {
        for (int i = 0; i < (int)nums.size(); ++i) {
            if (nums[i] == target) return i;
        }
        return -1;
    }
};
]]
  local cpp_payload, cpp_err = cpp.adapt_submission(cpp_code, cpp_source, cpp_judge)
  assert(cpp_payload, 'C++ search -> find failed: ' .. tostring(cpp_err))
  compile_and_run_cpp('cpp_basic', cpp_payload, [[
    vector<int> v{10, 20, 30};
    Solution s;
    assert(s.find(v, 20) == 1);
    assert(s.find(v, 99) == -1);
  ]])
  print('C++ cross-provider method forwarding compiles and executes')

  -- 2. C++ existing target method takes precedence without modification
  local cpp_existing_code = [[
class Solution {
public:
    int find(vector<int>& nums, int target) {
        return 777;
    }
};
]]
  local cpp_existing_payload, cpp_existing_err = cpp.adapt_submission(cpp_existing_code, cpp_source, cpp_judge)
  assert(cpp_existing_payload == cpp_existing_code, 'C++ existing target method was modified')
  compile_and_run_cpp('cpp_existing', cpp_existing_payload, [[
    vector<int> v{1};
    Solution s;
    assert(s.find(v, 1) == 777);
  ]])
  print('C++ existing judge target method takes precedence')

  -- 3. C++ recursion preservation
  local cpp_rec_source = 'class Solution { public: int factorial(int n) {} };'
  local cpp_rec_judge = 'class Solution { public: int solve(int n) {} };'
  local cpp_rec_code = [[
class Solution {
public:
    int factorial(int n) {
        if (n <= 1) return 1;
        return n * factorial(n - 1);
    }
};
]]
  local cpp_rec_payload, cpp_rec_err = cpp.adapt_submission(cpp_rec_code, cpp_rec_source, cpp_rec_judge)
  assert(cpp_rec_payload, 'C++ recursion adaptation failed: ' .. tostring(cpp_rec_err))
  compile_and_run_cpp('cpp_recursion', cpp_rec_payload, [[
    Solution s;
    assert(s.solve(5) == 120);
    assert(s.solve(0) == 1);
  ]])
  print('C++ recursion is preserved through forwarding')

  -- 4. C++ comments and string decoys
  local cpp_decoys_code = [=[
class Other {
public:
    int solve(int n) { return 999; }
};

class Solution {
public:
    // int solve(int n) { return 0; }
    /* void solve(int x) {} */
    int search(int n) {
        string s = "int solve(int n) { return 0; }";
        const char* raw = R"delim(int solve(int n) {})delim";
        auto solve_lambda = [](int x) { return x; };
        return n * 2;
    }
};
]=]
  local cpp_decoys_source = 'class Solution { public: int search(int n) {} };'
  local cpp_decoys_judge = 'class Solution { public: int solve(int n) {} };'
  local cpp_decoys_payload, cpp_decoys_err = cpp.adapt_submission(cpp_decoys_code, cpp_decoys_source, cpp_decoys_judge)
  assert(cpp_decoys_payload, 'C++ decoys adaptation failed: ' .. tostring(cpp_decoys_err))
  compile_and_run_cpp('cpp_decoys', cpp_decoys_payload, [[
    Solution s;
    assert(s.solve(10) == 20);
  ]])
  print('C++ comment, string, and unrelated class decoys are ignored')

  -- 5. C++ in-place reference mutation
  local cpp_mut_source = 'class Solution { public: void reverse(vector<int>& nums) {} };'
  local cpp_mut_judge = 'class Solution { public: void reorder(vector<int>& values) {} };'
  local cpp_mut_code = [[
class Solution {
public:
    void reverse(vector<int>& nums) {
        int l = 0, r = (int)nums.size() - 1;
        while (l < r) {
            int tmp = nums[l];
            nums[l] = nums[r];
            nums[r] = tmp;
            ++l; --r;
        }
    }
};
]]
  local cpp_mut_payload, cpp_mut_err = cpp.adapt_submission(cpp_mut_code, cpp_mut_source, cpp_mut_judge)
  assert(cpp_mut_payload, 'C++ mutation adaptation failed: ' .. tostring(cpp_mut_err))
  compile_and_run_cpp('cpp_mutation', cpp_mut_payload, [[
    vector<int> v{1, 2, 3};
    Solution s;
    s.reorder(v);
    assert(v[0] == 3 && v[1] == 2 && v[2] == 1);
  ]])
  print('C++ exact reference passing and in-place mutation preserved')

  -- 6. C++ cloud types unsupported by local serialization
  local cpp_cloud_source = 'class Solution { public: pair<int, int> solve(pair<int, int> p) {} };'
  local cpp_cloud_judge = 'class Solution { public: pair<int, int> process(pair<int, int> p) {} };'
  local cpp_cloud_code = [[
class Solution {
public:
    pair<int, int> solve(pair<int, int> p) {
        return {p.second, p.first};
    }
};
]]
  local cpp_cloud_payload, cpp_cloud_err = cpp.adapt_submission(cpp_cloud_code, cpp_cloud_source, cpp_cloud_judge)
  assert(cpp_cloud_payload, 'C++ cloud types adaptation failed: ' .. tostring(cpp_cloud_err))
  compile_and_run_cpp('cpp_cloud', cpp_cloud_payload, [[
    Solution s;
    auto res = s.process({42, 99});
    assert(res.first == 99 && res.second == 42);
  ]])
  print('C++ cloud types unsupported by local serialization succeed')

  local move_source = 'class Solution { public: int read(unique_ptr<int> value) {} };'
  local move_judge = 'class Solution { public: int consume(unique_ptr<int> value) {} };'
  local move_code = 'class Solution { public: int read(unique_ptr<int> value) { return *value; } };'
  local moved, move_err = cpp.adapt_submission(move_code, move_source, move_judge)
  assert(moved, move_err)
  compile_and_run_cpp('cpp_move_only', moved, [[
    assert(Solution().consume(make_unique<int>(42)) == 42);
  ]])
  print('C++ forwarding preserves move-only value arguments')

  -- 7. C++ incompatible types and arity rejected
  local diff_ret_judge = 'class Solution { public: bool find(vector<int>& nums, int target) {} };'
  local bad_ret, _ = cpp.adapt_submission(cpp_code, cpp_source, diff_ret_judge)
  assert(bad_ret == nil, 'C++ incompatible return type was accepted')

  local diff_param_judge = 'class Solution { public: int find(vector<int> nums, int target) {} };'
  local bad_param, _ = cpp.adapt_submission(cpp_code, cpp_source, diff_param_judge)
  assert(bad_param == nil, 'C++ incompatible parameter type (by-value vs ref) was accepted')

  local const_param_judge = 'class Solution { public: int find(const vector<int>& nums, int target) {} };'
  local bad_const, _ = cpp.adapt_submission(cpp_code, cpp_source, const_param_judge)
  assert(bad_const == nil, 'C++ incompatible const parameter type was accepted')

  local diff_arity_judge = 'class Solution { public: int find(vector<int>& nums) {} };'
  local bad_arity, _ = cpp.adapt_submission(cpp_code, cpp_source, diff_arity_judge)
  assert(bad_arity == nil, 'C++ incompatible arity was accepted')

  local missing_method, _ = cpp.adapt_submission('class Solution {};', cpp_source, cpp_judge)
  assert(missing_method == nil, 'C++ solution missing both methods was accepted')
  print('C++ incompatible types, arities, and missing methods rejected')

  -- =========================================================================
  -- Python Tests
  -- =========================================================================

  -- 1. Real Python cross-provider adaptation with different method names
  local py_source = 'class Solution:\n    def search(self, nums: list[int], target: int) -> int:\n        pass\n'
  local py_judge = 'class Solution:\n    def find(self, nums: list[int], target: int) -> int:\n        pass\n'
  local py_code = [[
class Solution:
    def search(self, nums: list[int], target: int) -> int:
        return nums.index(target) if target in nums else -1
]]
  local py_payload, py_err = py.adapt_submission(py_code, py_source, py_judge)
  assert(py_payload, 'Python search -> find failed: ' .. tostring(py_err))
  run_python('py_basic', py_payload, [[
s = Solution()
assert s.find([10, 20, 30], 20) == 1
assert s.find([10, 20, 30], 99) == -1
]])
  print('Python cross-provider method forwarding executes')

  -- 2. Python existing target method takes precedence without modification
  local py_existing_code = [[
class Solution:
    def find(self, nums: list[int], target: int) -> int:
        return 777
]]
  local py_existing_payload, py_existing_err = py.adapt_submission(py_existing_code, py_source, py_judge)
  assert(py_existing_payload == py_existing_code, 'Python existing target method was modified')
  run_python('py_existing', py_existing_payload, [[
s = Solution()
assert s.find([1], 1) == 777
]])
  print('Python existing judge target method takes precedence')

  -- 3. Python recursion preservation
  local py_rec_source = 'class Solution:\n    def factorial(self, n: int) -> int:\n        pass\n'
  local py_rec_judge = 'class Solution:\n    def solve(self, n: int) -> int:\n        pass\n'
  local py_rec_code = [[
class Solution:
    def factorial(self, n: int) -> int:
        if n <= 1:
            return 1
        return n * self.factorial(n - 1)
]]
  local py_rec_payload, py_rec_err = py.adapt_submission(py_rec_code, py_rec_source, py_rec_judge)
  assert(py_rec_payload, 'Python recursion adaptation failed: ' .. tostring(py_rec_err))
  run_python('py_recursion', py_rec_payload, [[
s = Solution()
assert s.solve(5) == 120
assert s.solve(0) == 1
]])
  print('Python recursion is preserved through forwarding')

  -- 4. Python comments, docstrings, decorators, and decoys
  local py_decoys_code = [=[
class Other:
    def solve(self, n: int) -> int:
        return 999

class Solution:
    """Class docstring."""
    # def solve(self, n: int) -> int:
    def double(self, n: int) -> int:
        def solve(x):
            return x
        s = "def solve(self, n):"
        return n * 2
]=]
  local py_decoys_source = 'class Solution:\n    def double(self, n: int) -> int:\n        pass\n'
  local py_decoys_judge = 'class Solution:\n    def solve(self, n: int) -> int:\n        pass\n'
  local py_decoys_payload, py_decoys_err = py.adapt_submission(py_decoys_code, py_decoys_source, py_decoys_judge)
  assert(py_decoys_payload, 'Python decoys adaptation failed: ' .. tostring(py_decoys_err))
  run_python('py_decoys', py_decoys_payload, [[
s = Solution()
assert s.solve(10) == 20
]])
  print('Python docstring, comments, and nested/unrelated decoys are handled cleanly')

  -- 5. Python in-place reference mutation
  local py_mut_source = 'class Solution:\n    def reverse(self, nums: list[int]) -> None:\n        pass\n'
  local py_mut_judge = 'class Solution:\n    def reorder(self, values: list[int]) -> None:\n        pass\n'
  local py_mut_code = [[
class Solution:
    def reverse(self, nums: list[int]) -> None:
        nums.reverse()
]]
  local py_mut_payload, py_mut_err = py.adapt_submission(py_mut_code, py_mut_source, py_mut_judge)
  assert(py_mut_payload, 'Python mutation adaptation failed: ' .. tostring(py_mut_err))
  run_python('py_mutation', py_mut_payload, [[
v = [1, 2, 3]
s = Solution()
s.reorder(v)
assert v == [3, 2, 1]
]])
  print('Python in-place list mutation is preserved through forwarding')

  -- 6. Python name and annotation differences allowed with compatible arity
  local py_diff_source = 'class Solution:\n    def search(self, numbers: list[int], val: int) -> int:\n        pass\n'
  local py_diff_judge = 'class Solution:\n    def find(self, nums: list[int], target: int) -> int:\n        pass\n'
  local py_diff_code = [[
class Solution:
    def search(self, numbers: list[int], val: int) -> int:
        return numbers.index(val)
]]
  local py_diff_payload, py_diff_err = py.adapt_submission(py_diff_code, py_diff_source, py_diff_judge)
  assert(py_diff_payload, 'Python annotation/name difference failed: ' .. tostring(py_diff_err))
  run_python('py_diff_names', py_diff_payload, [[
s = Solution()
assert s.find([10, 20], 20) == 1
assert s.find(nums=[10, 20], target=20) == 1
]])
  print('Python parameter name and annotation differences with compatible positional arity succeed')

  -- 7. Python incompatible arity rejected
  local py_bad_arity_judge = 'class Solution:\n    def find(self, nums: list[int]) -> int:\n        pass\n'
  local py_bad_arity, _ = py.adapt_submission(py_code, py_source, py_bad_arity_judge)
  assert(py_bad_arity == nil, 'Python incompatible parameter count was accepted')

  local py_missing, _ = py.adapt_submission('class Solution:\n    pass\n', py_source, py_judge)
  assert(py_missing == nil, 'Python solution missing both methods was accepted')

  local py_syntax_err, _ = py.adapt_submission('class Solution: def broken(\n', py_source, py_judge)
  assert(py_syntax_err == nil, 'Python syntax error was accepted')
  print('Python incompatible arity, missing methods, and syntax errors rejected')

  for _, declaration in ipairs({
    'def find(self, *, nums, target):',
    'def find(self, nums, target=0):',
    'def find(self, *args):',
    'async def find(self, nums, target):',
  }) do
    local rejected = py.adapt_submission(py_code, py_source, 'class Solution:\n    '..declaration..'\n        pass\n')
    assert(rejected == nil, 'unsupported Python callable shape was adapted')
  end
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, 'rf')
if not ok then error(err) end
print('All C++ and Python submission adapter tests passed!')
vim.cmd('qa!')
