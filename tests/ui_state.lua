local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))
if vim.env.MEATCODE_PICKER then
  vim.opt.rtp:append(assert(vim.env.MEATCODE_TELESCOPE, 'set MEATCODE_TELESCOPE to telescope.nvim'))
  vim.opt.rtp:append(assert(vim.env.MEATCODE_PLENARY, 'set MEATCODE_PLENARY to plenary.nvim'))
end
local root=vim.fn.tempname()
local util=require('meatcode.util')
local catalog=require('meatcode.catalog')
local problem_catalog=require('meatcode.catalog.problems')
local progress=require('meatcode.progress')
local availability=require('meatcode.catalog.availability')
local providers=require('meatcode.providers')
local problem={key='neetcode:double',name='Double',difficulty='Easy',providers={neetcode={id='double'}},topics={},companies={}}
local cat={problems={problem},by_provider={neetcode={double=problem},leetcode={},lintcode={}},by_pattern={}}
local python_only={key='neetcode:python-only',name='Python Only',difficulty='Easy',providers={neetcode={id='python-only'}},topics={},companies={}}
if vim.env.MEATCODE_PICKER then
  table.insert(cat.problems,python_only)
  cat.by_provider.neetcode['python-only']=python_only
end
catalog.load=function()return cat end;catalog.get=function()return cat end
problem_catalog.load=function()return cat end;problem_catalog.get=function()return cat end
problem_catalog.ensure=function(cb)cb(nil,cat)end
if not vim.env.MEATCODE_PICKER then availability.warm=function()end end
progress.sync=function()end -- The simulated history request never completes.
local saved
local resolved
local submits=0
for _,backend in ipairs(providers.all())do
  local logged=false
  backend.auth={is_logged_in=function()return logged end,user=function()return {}end,
    login=function(_,cb)logged=true;cb(nil)end,logout=function()logged=false end,
    refresh=function(cb)cb(nil)end}
  backend.resolve=function(_,cb)
    if backend.name=='leetcode' then resolved=cb else cb(nil,nil)end
  end
  backend.fetch=function(request,lang,cb)
    local meta={schema=util.META_SCHEMA,provider=backend.name,name='Double',difficulty='Easy',title='Double',description='Return twice n.',
      starterCode={python='class Solution:\n    def double(self, n: int) -> int:\n        return n * 2\n',
        swift='class Solution { func double(_ n: Int) -> Int { return n * 2 } }',
        rust='impl Solution { pub fn double(n: i32) -> i32 { n * 2 } }'},
      availableLanguages={'python','swift','rust'},custom_test_cases={'2'},expected_outputs={'4'},test_case_type='function',test_case_count=1}
    if request.name=='Python Only' then
      meta.starterCode.swift=nil;meta.starterCode.rust=nil;meta.availableLanguages={'python'}
    end
    cb(nil,meta)
  end
  backend.enrich=nil
  backend.saved_code=function(_,_,cb)saved=cb end
  backend.test=nil
  backend.submit=function(_,_,code,lang,cb)
    submits=submits+1
    vim.defer_fn(function()cb(nil,{accepted=true,status='Accepted'})end,20)
  end
  backend.normalize_submission=function(data)return data end
end
local mc=require('meatcode')
local opts={cache_dir=root,solutions_dir=root..'/solutions',lang='python',ui={images=false},runner={parallelism=1,python={auto_imports=false}}}
if vim.env.MEATCODE_NO_SETUP then
  require('meatcode.config').setup(opts)
  require('meatcode.ui.highlight').setup()
else mc.setup(opts)end
providers.set_order('content',{'neetcode'})
providers.set_order('submit',{'neetcode'})
vim.cmd('runtime plugin/meatcode.lua')
local ui=require('meatcode.ui.problem')
local function text(buf)return table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n')end
local function buffer(ft)
  for _,b in ipairs(vim.api.nvim_list_bufs())do if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype==ft then return b end end
end
local function settle(fn,msg)assert(vim.wait(5000,fn,10),msg)end
local function run()
  vim.cmd('MeatCode')
  local home=buffer('meatcode-home')
  assert(home and text(home):match('NeetCode%s+logged out'),'homepage initially logged out')
  vim.cmd('MeatCode login neetcode fixture')
  settle(function()return text(home):match('NeetCode%s+logged in')end,'login did not refresh homepage independently of history sync')
  vim.cmd('MeatCode logout neetcode')
  assert(text(home):match('NeetCode%s+logged out'),'logout did not refresh homepage')
  ui.open(problem)
  settle(function()return ui.is_session_tab()and buffer('python')end,'problem did not open')
  local py=buffer('python'); local py_path=vim.api.nvim_buf_get_name(py)
  vim.api.nvim_buf_set_lines(py,0,-1,false,{'class Solution:','    def double(self, n):','        return n * 3'})
  vim.api.nvim_exec_autocmds('TextChangedI',{buffer=py})
  assert(util.read_file(py_path):match('return n %* 3'),'insert-mode autosave did not write code')
  assert(not vim.bo[py].modified,'autosave left solution dirty')
  vim.o.autoread = true
  local tick = vim.api.nvim_buf_get_changedtick(py)
  vim.cmd('checktime '..py)
  assert(vim.api.nvim_buf_get_changedtick(py) == tick,'autosave looked external, so checktime reloaded the solution')
  if saved then saved(nil,{lang='python',tabs={{code='class Solution:\n    def double(self,n): return 999'}}})end
  vim.wait(50,function()return false end,10)
  assert(text(py):match('return n %* 3'),'late cloud saved code overwrote autosaved edit')
  if resolved then resolved(nil,'lc-double')end
  vim.wait(20,function()return false end,10)
  vim.cmd('MeatCode lang swift')
  vim.cmd('MeatCode lang rust')
  settle(function()local b=buffer('rust');return b and ui.is_session_tab() and vim.api.nvim_get_current_buf()==b end,'rapid language changes did not reopen latest language')
  assert(vim.api.nvim_buf_get_name(buffer('rust')):match('/double%.rs$'),'provider enrichment changed the saved solution identity')
  assert(util.read_file(py_path):match('return n %* 3'),'language cutover lost old code')
  assert(text(home):match('language%s+Rust'),'homepage language did not update')
  vim.cmd('MeatCode lang python')
  settle(function()return ui.is_session_tab() and vim.api.nvim_get_current_buf()==py end,'saved Python solution was not reopened')
  assert(text(py):match('return n %* 3'),'reopened Python solution not preserved')
  providers.set_order('content',{'leetcode','neetcode'})
  settle(function()local active=ui.active();return active and active.content=='leetcode' and vim.api.nvim_get_current_buf()==py end,'content chain change did not reopen existing problem immediately')
  assert(text(py):match('return n %* 3'),'content chain cutover lost the saved solution')
  vim.api.nvim_buf_set_lines(py,0,-1,false,{'import time','class Solution:','    def double(self,n):','        time.sleep(20)','        return n*2'})
  vim.api.nvim_exec_autocmds('TextChangedI',{buffer=py})
  ui.run()
  vim.api.nvim_buf_set_lines(py,0,-1,false,{'class Solution:','    def double(self,n): return n*2'})
  vim.api.nvim_exec_autocmds('TextChangedI',{buffer=py})
  ui.run()
  local results=buffer('meatcode-results')
  settle(function()return text(results):match('1/1')~=nil end,'replacement run did not render passing results: '..text(results))
  vim.api.nvim_buf_set_lines(py,0,-1,false,{'import time','class Solution:','    def double(self,n):','        time.sleep(20)','        return n*2'})
  vim.api.nvim_exec_autocmds('TextChangedI',{buffer=py})
  ui.run();ui.submit()
  settle(function()return text(results):match('Accepted')~=nil end,'submission did not replace local run')
  assert(submits==1,'submission not invoked exactly once')
  local before=text(results)
  require('meatcode.runner').set_cloud_mode('never')
  assert(text(results)==before,'state refresh overwrote submission result')
  ui.run();ui.close()
  assert(not ui.is_session_tab(),'closing running problem left a live session')
  assert(util.read_file(py_path):match('time.sleep'),'closing problem lost saved edit')
  vim.wait(100,function()return false end,10)
  print('Rendered homepage login/logout, live language, autosave, stale saved-code guard, rapid reopen, replacement run, submit-during-run, state panel preservation, and close cancellation passed')
end
local function picker_run()
  local checked=0
  availability.check(problem,function()checked=checked+1 end)
  availability.check(python_only,function()checked=checked+1 end)
  settle(function()return checked==2 end,'availability fixtures not loaded')
  vim.cmd('MeatCode')
  local home=buffer('meatcode-home')
  vim.cmd('MeatCode list')
  settle(function()local b=buffer('TelescopeResults');return b and text(b):match('Python Only')end,'Python catalogue not rendered')
  vim.cmd('MeatCode login neetcode fixture')
  settle(function()return text(home):match('NeetCode%s+logged in')end,'buried homepage did not update auth')
  vim.cmd('MeatCode lang rust')
  settle(function()
    local b=buffer('TelescopeResults')
    return b and text(b):match('Double') and not text(b):match('Python Only')
  end,'language change did not live-filter actual picker results')
  assert(text(home):match('language%s+Rust'),'buried homepage language stale')
  local prompt=buffer('TelescopePrompt')
  local quit
  for _,mapping in ipairs(vim.api.nvim_buf_get_keymap(prompt,'n'))do if mapping.lhs=='q' then quit=mapping.callback end end
  assert(quit,'actual picker quit mapping missing')
  quit()
  settle(function()return vim.api.nvim_get_current_buf()==home end,'catalogue back nav did not reveal homepage')
  assert(text(home):match('NeetCode%s+logged in')and text(home):match('language%s+Rust'),'revealed homepage reverted state')
  print('Actual Telescope results live-filtered by language; buried/revealed homepage stayed current')
end
local ok,err=xpcall(vim.env.MEATCODE_PICKER and picker_run or run,debug.traceback)
vim.fn.delete(root,'rf')
if not ok then io.stderr:write(err..'\n');vim.cmd('cquit 1')end
vim.cmd('qa!')
