local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))
local root = vim.fn.tempname()
require('meatcode.config').setup({cache_dir=root, solutions_dir=root..'/solutions', runner={parallelism=2, time_limit=2}})
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
local function await_run(id, code, starter, cases, outputs, kind)
  local report
  runner.run(id, code, 'cpp', {starterCode={cpp=starter}, custom_test_cases=cases,
    expected_outputs=outputs, test_case_type=kind or 'function'}, cases, function(r) report=r end)
  assert(vim.wait(120000, function() return report~=nil end, 10), id..' timed out')
  assert(report.ok and report.passed==#cases, id..': '..vim.inspect(report))
  print(id..' passed '..report.passed..'/'..report.total)
end
local prelude = [[
/**
 * Definition of Interval:
 * class Interval {
 * public:
 *     int start, end;
 *     Interval(int start, int end) {
 *         this->start = start;
 *         this->end = end;
 *     }
 * }
 */
]]
local starter = prelude..[[
class Solution {
public:
    bool canAttendMeetings(vector<Interval>& intervals) {}
};
]]
local code = prelude..[[
#include <ranges>
class Solution {
public:
    bool canAttendMeetings(vector<Interval>& intervals) {
        sort(intervals.begin(), intervals.end(),
             [](const auto& a, const auto& b) { return a.start < b.start; });
        for (size_t i = 1; i < intervals.size(); ++i) {
            if (intervals[i].start < intervals[i - 1].end) return false;
        }
        return true;
    }
};
]]
local function run()
  await_run('cpp-meeting-rooms', code, starter,
    {'[[0,30],[5,10],[15,20]]', 'intervals=[(5,8),(9,15)]',
      'intervals=[(15,20),(0,30),(5,10)]', '[[7,10],[2,4]]',
      '[[5,8],[8,10]]', '[]', '[[1,2]]', '[[-5,-1],[-3,0]]'},
    {'false','true','false','true','true','true','true','false'})
  local merge = prelude..[[class Solution { public:
    Interval span(vector<Interval>& intervals) {
        Interval result(intervals[0].start, intervals[0].end);
        for (const auto& interval : intervals) {
            result.start = min(result.start, interval.start);
            result.end = max(result.end, interval.end);
        }
        return result;
    }
};]]
  await_run('cpp-interval-return', merge, merge,
    {'[[5,8],[-2,4],[9,15]]'}, {'[-2,15]'})
  local mutate = prelude..[[class Solution { public:
    void shift(vector<Interval>& intervals, int delta) {
        for (auto& interval : intervals) { interval.start += delta; interval.end += delta; }
    }
};]]
  await_run('cpp-interval-in-place', mutate, mutate,
    {'intervals=[(1,3),(-4,0)]\ndelta=2', '[]\n5'}, {'[[3,5],[-2,2]]','[]'})
  local design = prelude..[[class Calendar { Interval slot; public:
    Calendar(Interval initial) : slot(initial) {}
    bool overlaps(Interval other) { return other.start < slot.end && slot.start < other.end; }
};]]
  await_run('cpp-interval-design', design, design,
    {'["Calendar","overlaps","overlaps"]\n[[[2,5]],[[4,7]],[[5,8]]]'},
    {'[null,true,false]'}, 'class')
  local meta = {starterCode={cpp=starter}, solutions={cpp=code},
    custom_test_cases={'intervals=[(0,30),(5,10),(15,20)]', 'intervals=[(5,8),(9,15)]'}}
  local prepared
  runner.prepare('cpp-interval-reference', 'cpp', meta, meta.custom_test_cases, function(info) prepared=info end)
  assert(vim.wait(120000, function() return prepared~=nil end, 10), 'oracle preparation timed out')
  assert(prepared.stage=='reference', 'reference preparation failed: '..vim.inspect(prepared)
    ..'\n'..vim.inspect(require('meatcode.util').read_json(root..'/oracle-validations/cpp-interval-reference-cpp.json')))
  local report
  runner.run('cpp-interval-reference', code, 'cpp', meta, meta.custom_test_cases, function(r) report=r end)
  assert(vim.wait(120000, function() return report~=nil end, 10), 'oracle run timed out')
  assert(report.ok and report.passed==2, 'reference run failed: '..vim.inspect(report))
  print('cpp interval sandboxed reference preparation and cached-answer run passed')
end
local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, 'rf')
if not ok then io.stderr:write(err..'\n');vim.cmd('cquit 1') end
vim.cmd('qa!')
