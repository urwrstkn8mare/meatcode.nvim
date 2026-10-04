local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))
local providers = require('meatcode.providers')
local root = vim.fn.tempname() .. ' with spaces'
vim.fn.mkdir(root, 'p')
local problem = {providers={neetcode={id='duplicate'},leetcode={id='contains-duplicate'}}}
local fixtures = {
  swift = {
    starter='class Solution { func hasDuplicate(_ nums: [Int]) -> Bool {} }',
    judge='class Solution { func containsDuplicate(_ nums: [Int]) -> Bool {} }',
    code='class Solution { func hasDuplicate(_ nums: [Int]) -> Bool { var set = Set<Int>(); for num in nums { let (inserted, _) = set.insert(num); if !inserted { return true } }; return false } }',
    main='\nprecondition(Solution().containsDuplicate([1,2,3,3])); precondition(!Solution().containsDuplicate([1,2,3,4])); precondition(!Solution().containsDuplicate([])); print("accepted")\n',
    compiler={'swiftc'}, ext='swift',
  },
  rust = {
    starter='impl Solution { pub fn has_duplicate(nums: Vec<i32>) -> bool {} }',
    judge='impl Solution { pub fn contains_duplicate(nums: Vec<i32>) -> bool {} }',
    code='impl Solution { pub fn has_duplicate(nums: Vec<i32>) -> bool { let mut seen = std::collections::HashSet::new(); nums.iter().any(|n| !seen.insert(*n)) } }',
    prelude='struct Solution;\n',
    main='\nfn main() { assert!(Solution::contains_duplicate(vec![1,2,3,3])); assert!(!Solution::contains_duplicate(vec![1,2,3,4])); assert!(!Solution::contains_duplicate(vec![])); println!("accepted"); }\n',
    compiler={'rustc','--edition=2021'}, ext='rs',
  },
  cpp = {
    starter='class Solution { public: bool hasDuplicate(vector<int>& nums) {} };',
    judge='class Solution { public: bool containsDuplicate(vector<int>& nums) {} };',
    code='class Solution { public: bool hasDuplicate(vector<int>& nums) { unordered_set<int> seen; for (int n : nums) if (!seen.insert(n).second) return true; return false; } };',
    prelude='#include <vector>\n#include <unordered_set>\n#include <cassert>\n#include <iostream>\nusing namespace std;\n',
    main='\nint main() { vector<int> duplicate{1,2,3,3}, unique{1,2,3,4}, empty; Solution s; assert(s.containsDuplicate(duplicate)); assert(!s.containsDuplicate(unique)); assert(!s.containsDuplicate(empty)); cout << "accepted\\n"; }\n',
    compiler={'c++','-std=c++23'}, ext='cpp',
  },
  python = {
    starter='class Solution:\n    def hasDuplicate(self, nums: list[int]) -> bool:\n        pass\n',
    judge='class Solution:\n    def containsDuplicate(self, nums: list[int]) -> bool:\n        pass\n',
    code='class Solution:\n    def hasDuplicate(self, nums: list[int]) -> bool:\n        return len(set(nums)) != len(nums)\n',
    main='\ns = Solution()\nassert s.containsDuplicate([1,2,3,3])\nassert not s.containsDuplicate([1,2,3,4])\nassert not s.containsDuplicate([])\nprint("accepted")\n', ext='py',
  },
}
local backend = providers.get('leetcode')
local uploads = 0
local function run()
  for _, lang in ipairs({'swift','rust','cpp','python'}) do
    local fixture = fixtures[lang]
    local original_meta = {starterCode={[lang]=fixture.starter},test_case_type='function'}
    backend.fetch=function(_, requested, cb)
      cb(nil,{provider='leetcode',question_id='217',starterCode={[requested]=fixture.judge},test_case_type='function'})
    end
    backend.submit=function(_, meta, payload, submitted_lang, cb)
      uploads=uploads+1
      local file=root..'/judge.'..fixture.ext
      vim.fn.writefile(vim.split((fixture.prelude or '')..payload..fixture.main,'\n',{plain=true}),file)
      local command
      if fixture.compiler then
        command=vim.deepcopy(fixture.compiler)
        vim.list_extend(command,{'-o',root..'/judge',file})
        local compiled=vim.system(command,{text=true}):wait()
        assert(compiled.code==0,lang..' judge compile failed: '..compiled.stderr)
        command={root..'/judge'}
      else
        command={'python3',file}
      end
      local executed=vim.system(command,{text=true}):wait()
      assert(executed.code==0,lang..' judge failed: '..executed.stderr)
      assert(executed.stdout=='accepted\n',lang..' judge returned unexpected verdict: '..executed.stdout)
      cb(nil,{accepted=true})
    end
    local result, err
    providers.submit(problem,original_meta,fixture.code,lang,'neetcode','leetcode',function(e,r)err=e;result=r end)
    assert(not err and result and result.accepted,lang..': '..tostring(err))
    assert(original_meta.starterCode[lang]==fixture.starter,'judge signature leaked into content metadata')
    print(lang..' cross-provider payload passes the actual judge entry point')
  end
  local submitted_before=uploads
  backend.fetch=function(_,lang,cb)
    cb(nil,{starterCode={[lang]='class Solution { fun solve(n: Int): Int {} }'},test_case_type='function'})
  end
  local err
  providers.submit(problem,{starterCode={kotlin='class Solution { fun original(n: Int): Int {} }'}},'class Solution {}','kotlin','neetcode','leetcode',function(e)err=e end)
  assert(err and uploads==submitted_before,'language without an adapter uploaded unchecked code')
  print('Future language without an adapter is rejected before upload')
  backend.fetch=function(_,lang,cb) cb(nil,{starterCode={[lang]=fixtures.swift.judge},test_case_type='function'}) end
  err=nil
  providers.submit(problem,{starterCode={swift='class Solution { func hasDuplicate(_ nums: [String]) -> Bool {} }'}},fixtures.swift.code,'swift','neetcode','leetcode',function(e)err=e end)
  assert(err and uploads==submitted_before,'incompatible signature uploaded unchecked code')
  print('Incompatible provider signatures are rejected before upload')
end
local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root,'rf')
if not ok then error(err) end
vim.cmd('qa!')
