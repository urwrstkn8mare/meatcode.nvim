local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))
local swift = require('meatcode.runner.swift')

local root = vim.fn.tempname() .. '_swift_sub_tests'
vim.fn.mkdir(root, 'p')

local function compile_and_run(id, payload, test_harness)
  local file = root .. '/' .. id .. '.swift'
  local exe = root .. '/' .. id
  local full_code = payload .. '\n' .. test_harness .. '\n'
  local fd = assert(io.open(file, 'w'))
  fd:write(full_code)
  fd:close()
  local compiled = vim.system({'swiftc', '-o', exe, file}, {text=true}):wait()
  assert(compiled.code == 0, id .. ' compilation failed:\n' .. (compiled.stderr or ''))
  local executed = vim.system({exe}, {text=true}):wait()
  assert(executed.code == 0, id .. ' execution failed:\n' .. (executed.stderr or ''))
  return executed.stdout
end

local function run()
  -- 1. NeetCode hasDuplicate -> LeetCode containsDuplicate
  local neet_code = [[class Solution {
    func hasDuplicate(_ nums: [Int]) -> Bool {
        var set = Set<Int>()
        for num in nums {
            let (inserted, _) = set.insert(num)
            if !inserted { return true }
        }
        return false
    }
}]]
  local neet_starter = 'class Solution { func hasDuplicate(_ nums: [Int]) -> Bool {} }'
  local leet_judge = 'class Solution { func containsDuplicate(_ nums: [Int]) -> Bool {} }'

  local payload, err = swift.adapt_submission(neet_code, neet_starter, leet_judge)
  assert(payload, err)
  assert(payload:sub(1, #neet_code) == neet_code, 'original code must remain a prefix unchanged')
  compile_and_run('neet_duplicate', payload, [[
precondition(Solution().containsDuplicate([1, 2, 3, 1]) == true)
precondition(Solution().containsDuplicate([1, 2, 3, 4]) == false)
precondition(Solution().containsDuplicate([]) == false)
print("hasDuplicate passed")
]])

  -- 2. Parameter labels and local argument names differ
  local source_labels = 'class Solution { func solve(from items: [Int], factor mult: Int) -> Int {} }'
  local judge_labels = 'class Solution { func solve(_ values: [Int], _ factor: Int) -> Int {} }'
  local code_labels = [[class Solution {
    func solve(from items: [Int], factor mult: Int) -> Int {
        return items.reduce(0, +) * mult
    }
}]]
  payload, err = swift.adapt_submission(code_labels, source_labels, judge_labels)
  assert(payload, err)
  compile_and_run('labels_diff', payload, [[
precondition(Solution().solve([1, 2, 3], 4) == 24)
precondition(Solution().solve([], 10) == 0)
print("labels passed")
]])

  -- 3. Same base method name but different external labels
  local source_same_name = 'class Solution { func solve(_ nums: [Int]) -> Int {} }'
  local judge_same_name = 'class Solution { func solve(values: [Int]) -> Int {} }'
  local code_same_name = [[class Solution {
    func solve(_ nums: [Int]) -> Int {
        return nums.count
    }
}]]
  payload, err = swift.adapt_submission(code_same_name, source_same_name, judge_same_name)
  assert(payload, err)
  compile_and_run('same_name_labels', payload, [[
precondition(Solution().solve(values: [10, 20, 30]) == 3)
precondition(Solution().solve(values: []) == 0)
print("same name different labels passed")
]])

  -- 4. Inout parameter forwarding
  local source_inout = 'class Solution { func reverseString(_ s: inout [Character]) {} }'
  local judge_inout = 'class Solution { func reverse(_ chars: inout [Character]) {} }'
  local code_inout = [[class Solution {
    func reverseString(_ s: inout [Character]) {
        s.reverse()
    }
}]]
  payload, err = swift.adapt_submission(code_inout, source_inout, judge_inout)
  assert(payload, err)
  compile_and_run('inout_forwarding', payload, [[
var chars: [Character] = ["h", "e", "l", "l", "o"]
Solution().reverse(&chars)
precondition(chars == ["o", "l", "l", "e", "h"])
print("inout passed")
]])

  -- 5. Recursion is preserved intact
  local source_rec = 'class Solution { func factorial(_ n: Int) -> Int {} }'
  local judge_rec = 'class Solution { func solve(_ n: Int) -> Int {} }'
  local code_rec = [[class Solution {
    func helper(_ n: Int) -> Int { return n }
    func factorial(_ n: Int) -> Int {
        if n <= 1 { return 1 }
        return helper(n) * factorial(n - 1)
    }
}]]
  payload, err = swift.adapt_submission(code_rec, source_rec, judge_rec)
  assert(payload, err)
  compile_and_run('recursion', payload, [[
precondition(Solution().solve(5) == 120)
precondition(Solution().solve(1) == 1)
precondition(Solution().solve(0) == 1)
print("recursion passed")
]])

  -- 6. Decoys: comments (including nested block comments), strings, unrelated classes, nested helper methods
  local source_decoys = 'class Solution { func compute(_ n: Int) -> Int {} }'
  local judge_decoys = 'class Solution { func solve(_ n: Int) -> Int {} }'
  local code_decoys = [[class Other {
    func solve(_ n: Int) -> Int { return 999 }
}
class Solution {
    struct Nested {
        func solve(_ n: Int) -> Int { return 888 }
    }
    func helper() {
        func solve(_ n: Int) -> Int { return 777 }
    }
    func compute(_ n: Int) -> Int {
        let _str = "func solve(_ n: Int) -> Int { return 666 }"
        let _raw = #"func solve(_ n: Int) -> Int { return 555 }"#
        let _multi = """
        func solve(_ n: Int) -> Int { return 444 }
        """
        // func solve(_ n: Int) -> Int { return 333 }
        /* func solve(_ n: Int) -> Int { return 222 } */
        /* outer /* inner func solve(_ n: Int) -> Int { return 111 } */ still outer */
        return n * 3
    }
}]]
  payload, err = swift.adapt_submission(code_decoys, source_decoys, judge_decoys)
  assert(payload, err)
  compile_and_run('decoys', payload, [[
precondition(Solution().solve(10) == 30)
print("decoys passed")
]])

  -- 7. Existing true target method takes precedence and bypasses adaptation
  local code_existing = [[class Solution {
    func containsDuplicate(_ nums: [Int]) -> Bool {
        return nums.count > 1
    }
}]]
  payload, err = swift.adapt_submission(code_existing, neet_starter, leet_judge)
  assert(payload == code_existing, 'existing target method must return original code verbatim')
  compile_and_run('existing_target', payload, [[
precondition(Solution().containsDuplicate([1, 2]) == true)
precondition(Solution().containsDuplicate([1]) == false)
print("existing target passed")
]])

  -- 8. Struct Solution and method mutability
  local source_struct = 'struct Solution { mutating func add(_ delta: Int) -> Int {} }'
  local judge_struct = 'struct Solution { mutating func accumulate(_ delta: Int) -> Int {} }'
  local code_struct = [[struct Solution {
    var total = 0
    mutating func add(_ delta: Int) -> Int {
        total += delta
        return total
    }
}]]
  payload, err = swift.adapt_submission(code_struct, source_struct, judge_struct)
  assert(payload, err)
  compile_and_run('struct_mutability', payload, [[
var s = Solution()
precondition(s.accumulate(5) == 5)
precondition(s.accumulate(10) == 15)
print("struct mutability passed")
]])

  -- 9. Return versus Void
  local source_void = 'class Solution { func touch(_ nums: inout [Int]) {} }'
  local judge_void = 'class Solution { func apply(_ nums: inout [Int]) {} }'
  local code_void = [[class Solution {
    func touch(_ nums: inout [Int]) {
        nums.append(42)
    }
}]]
  payload, err = swift.adapt_submission(code_void, source_void, judge_void)
  assert(payload, err)
  compile_and_run('return_void', payload, [[
var list = [1, 2]
Solution().apply(&list)
precondition(list == [1, 2, 42])
print("return void passed")
]])

  -- 10. Cloud adaptation preserves types unsupported by local serialization
  local source_cloud = 'struct Solution { func transform(dict: [String: [Int]]) -> [String: Int] {} }'
  local judge_cloud = 'struct Solution { func summarize(dict: [String: [Int]]) -> [String: Int] {} }'
  local code_cloud = [=[struct Solution {
    func transform(dict: [String: [Int]]) -> [String: Int] {
        var res: [String: Int] = [:]
        for (k, v) in dict {
            res[k] = v.reduce(0, +)
        }
        return res
    }
}]=]
  payload, err = swift.adapt_submission(code_cloud, source_cloud, judge_cloud)
  assert(payload, err)
  compile_and_run('cloud_types', payload, [=[
let s = Solution()
let out = s.summarize(dict: ["a": [1, 2, 3], "b": [4, 5]])
precondition(out["a"] == 6 && out["b"] == 9)
print("cloud types passed")
]=])

  -- 11. Incompatible signatures are rejected
  local valid_code = 'class Solution { func solve(_ a: Int) -> Int { return a } }'
  local valid_starter = 'class Solution { func solve(_ a: Int) -> Int {} }'

  -- Parameter count (arity) mismatch
  local bad_arity = 'class Solution { func other(_ a: Int, _ b: Int) -> Int {} }'
  local p_bad, e_bad = swift.adapt_submission(valid_code, valid_starter, bad_arity)
  assert(p_bad == nil and type(e_bad) == 'string', 'arity mismatch accepted')

  -- Parameter type mismatch
  local bad_type = 'class Solution { func other(_ a: String) -> Int {} }'
  p_bad, e_bad = swift.adapt_submission(valid_code, valid_starter, bad_type)
  assert(p_bad == nil and type(e_bad) == 'string', 'type mismatch accepted')

  -- Inout mismatch
  local inout_source = 'class Solution { func solve(_ a: inout [Int]) {} }'
  local non_inout_judge = 'class Solution { func other(_ a: [Int]) {} }'
  p_bad, e_bad = swift.adapt_submission('class Solution { func solve(_ a: inout [Int]) {} }', inout_source, non_inout_judge)
  assert(p_bad == nil and type(e_bad) == 'string', 'inout mismatch accepted')

  -- Return type mismatch
  local bad_ret = 'class Solution { func other(_ a: Int) -> Bool {} }'
  p_bad, e_bad = swift.adapt_submission(valid_code, valid_starter, bad_ret)
  assert(p_bad == nil and type(e_bad) == 'string', 'return mismatch accepted')

  -- Return versus Void mismatch
  local bad_void = 'class Solution { func other(_ a: Int) {} }'
  p_bad, e_bad = swift.adapt_submission(valid_code, valid_starter, bad_void)
  assert(p_bad == nil and type(e_bad) == 'string', 'return vs void mismatch accepted')

  -- Struct mutability mismatch (mutating source but non-mutating judge)
  local mut_struct_source = 'struct Solution { mutating func update(_ a: Int) -> Int {} }'
  local non_mut_judge = 'struct Solution { func other(_ a: Int) -> Int {} }'
  local mut_code = 'struct Solution { mutating func update(_ a: Int) -> Int { return a } }'
  p_bad, e_bad = swift.adapt_submission(mut_code, mut_struct_source, non_mut_judge)
  assert(p_bad == nil and type(e_bad) == 'string', 'mutability mismatch accepted')

  -- Unsupported generic method
  local gen_judge = 'class Solution { func other<T>(_ a: T) -> T {} }'
  p_bad, e_bad = swift.adapt_submission(valid_code, valid_starter, gen_judge)
  assert(p_bad == nil and type(e_bad) == 'string', 'generic method accepted')

  -- Unsupported async method
  local async_judge = 'class Solution { func other(_ a: Int) async -> Int {} }'
  p_bad, e_bad = swift.adapt_submission(valid_code, valid_starter, async_judge)
  assert(p_bad == nil and type(e_bad) == 'string', 'async method accepted')

  -- Unsupported throwing method
  local throw_judge = 'class Solution { func other(_ a: Int) throws -> Int {} }'
  p_bad, e_bad = swift.adapt_submission(valid_code, valid_starter, throw_judge)
  assert(p_bad == nil and type(e_bad) == 'string', 'throwing method accepted')

  -- Missing implementation in Solution
  local missing_code = 'class Solution { func unrelated() {} }'
  p_bad, e_bad = swift.adapt_submission(missing_code, valid_starter, 'class Solution { func other(_ a: Int) -> Int {} }')
  assert(p_bad == nil and type(e_bad) == 'string', 'missing implementation accepted')


  print('All Swift submission adaptation tests passed successfully!')
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, 'rf')
if not ok then error(err) end
