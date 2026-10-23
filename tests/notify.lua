-- Keyed notifications and progress updates replace in place through the
-- notifiers that own `vim.notify`. Each fake follows the replace contract of
-- the plugin it stands for: snacks.nvim keys on `id`, nvim-notify and noice
-- return a handle the next call passes back as `replace`.
local source = debug.getinfo(1, 'S').source:sub(2)
vim.opt.rtp:prepend(vim.fn.fnamemodify(source, ':p:h:h'))

-- Fresh module per scenario: util caches whether fidget.nvim is reachable.
local function fresh()
  package.loaded['meatcode.util'] = nil
  package.loaded['fidget'] = nil
  package.loaded['notify'] = nil
  return require('meatcode.util')
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function updates(util, key)
  for _, msg in ipairs({'opening', 'preparing', 'ready'}) do util.notify(msg, nil, {key=key}) end
end

-- nvim-notify: `replace` must name a notification that is still open, else it
-- reports an error and drops the message.
local function nvim_notify()
  local state = {open={}, errors={}, seq=0}
  state.module = setmetatable({}, {__call=function(_, msg, _, opts)
    if opts.replace then
      local id = type(opts.replace) == 'table' and opts.replace.id or opts.replace
      if not state.open[id] then
        table.insert(state.errors, 'Invalid notification to replace')
        return
      end
      state.open[id] = nil
    end
    state.seq = state.seq + 1
    state.open[state.seq] = {msg=msg, on_close=opts.on_close}
    return {id=state.seq}
  end})
  state.close = function(id)
    local notif = state.open[id]
    state.open[id] = nil
    if notif.on_close then notif.on_close() end
  end
  return state
end

local function run()
  -- built-in vim.notify returns nothing, so every update is its own message
  local util, calls = fresh(), {}
  vim.notify = function(msg, _, opts) table.insert(calls, {msg=msg, opts=opts}) end
  updates(util, 'plain')
  assert(#calls == 3 and calls[3].opts.replace == nil and calls[3].opts.title == 'MeatCode', 'built-in notify stopped stacking')
  print('built-in vim.notify stacks updates')

  -- snacks.nvim (directly, or behind noice) replaces by `id`
  util = fresh()
  local shown, auto = {}, 0
  vim.notify = function(msg, _, opts)
    auto = auto + 1
    local id = opts.id or ('auto'..auto)
    shown[id] = msg
    return id
  end
  updates(util, 'open')
  util.notify('unrelated')
  local progress = util.progress('checking NeetCode')
  progress:report('checking LeetCode')
  progress:finish('stronger oracle ready')
  assert(count(shown) == 3 and shown.open == 'ready', 'snacks keyed updates stacked: '..vim.inspect(shown))
  assert(vim.tbl_contains(vim.tbl_values(shown), 'stronger oracle ready'), 'progress did not finish in place')
  print('snacks-style notifier replaced keyed and progress updates in place')

  -- noice hands back {id=...} and maps `replace` for its nvim-notify backend
  -- itself; its own on_close must not be overridden
  util = fresh()
  calls = {}
  vim.notify = function(msg, _, opts)
    table.insert(calls, {msg=msg, opts=opts})
    return {id=#calls}
  end
  updates(util, 'open')
  assert(calls[2].opts.replace.id == 1 and calls[3].opts.replace.id == 2, 'noice handle not passed back as replace')
  assert(calls[3].opts.id == 'open' and calls[3].opts.on_close == nil, 'noice got on_close or lost id')
  print('noice-style notifier received the previous handle as replace')

  -- noice defers calls made in a fast event and returns nothing; an update
  -- from a libuv callback must still be sent once, with the previous handle
  util = fresh()
  calls = {}
  local noice
  noice = function(msg, level, opts)
    if vim.in_fast_event() then return vim.schedule(function() noice(msg, level, opts) end) end
    table.insert(calls, {msg=msg, opts=opts})
    return {id=#calls}
  end
  vim.notify = noice
  util.notify('opening', nil, {key='open'})
  local timer = vim.uv.new_timer()
  timer:start(0, 0, function() util.notify('ready', nil, {key='open'}) end)
  vim.wait(1000, function() return #calls >= 2 end)
  vim.wait(50)
  timer:close()
  assert(#calls == 2 and calls[2].msg == 'ready' and calls[2].opts.replace.id == 1, 'fast-event update duplicated or lost: '..vim.inspect(calls))
  print('update from a fast event sent once with the previous handle')

  -- nvim-notify as vim.notify itself: a closed notification is forgotten, so
  -- the next update opens a new one instead of failing to replace it
  util = fresh()
  local notify = nvim_notify()
  package.loaded['notify'] = notify.module
  vim.notify = notify.module
  updates(util, 'open')
  assert(count(notify.open) == 1 and notify.open[3].msg == 'ready', 'nvim-notify updates stacked')
  notify.close(3)
  util.notify('reopened', nil, {key='open'})
  assert(#notify.errors == 0 and count(notify.open) == 1, 'nvim-notify replaced a closed notification: '..vim.inspect(notify.errors))
  print('nvim-notify replaced in place and reopened after close')

  -- nvim-notify behind a wrapper MeatCode cannot recognise: the stale replace
  -- fails, and the update is shown fresh rather than lost
  util = fresh()
  notify = nvim_notify()
  vim.notify = function(...) return notify.module(...) end
  util.notify('opening', nil, {key='open'})
  notify.close(1)
  util.notify('ready', nil, {key='open'})
  assert(count(notify.open) == 1 and notify.open[2].msg == 'ready', 'update lost after a failed replace')
  print('wrapped nvim-notify kept the update after a failed replace')

  -- fidget.nvim still takes precedence when present
  util = fresh()
  local fidget = {}
  package.loaded['fidget'] = {notify=function(msg, _, opts) fidget[opts.key] = msg end}
  calls = {}
  vim.notify = function(msg) table.insert(calls, msg) end
  updates(util, 'open')
  assert(fidget.open == 'ready' and #calls == 0, 'fidget no longer preferred')
  print('fidget.nvim still preferred for keyed updates')
end

local orig = vim.notify
local ok, err = xpcall(run, debug.traceback)
vim.notify = orig
if not ok then
  io.stderr:write(err..'\n')
  vim.cmd('cquit 1')
end
vim.cmd('qa!')
