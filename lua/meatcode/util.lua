local M = {}

--- Bumped whenever a provider's problem metadata grows a field the runner
--- depends on, so caches written by an older version are refetched instead of
--- silently running without it.
M.META_SCHEMA = 3

--- Lazily resolved so a plugin that merely has fidget.nvim on the runtimepath
--- (but never calls `setup()`, or hasn't loaded it yet) is never force-loaded
--- just because MeatCode notified something — only probed the first time a
--- caller actually asks for keyed/progress notifications.
local fidget_notify, fidget_progress -- nil = unresolved, false = unavailable

local function resolve_fidget_notify()
  if fidget_notify == nil then
    local ok, mod = pcall(require, "fidget")
    fidget_notify = (ok and type(mod.notify) == "function") and mod.notify or false
  end
  return fidget_notify
end

local function resolve_fidget_progress()
  if fidget_progress == nil then
    local ok, mod = pcall(require, "fidget.progress")
    fidget_progress = (ok and mod) or false
  end
  return fidget_progress
end

--- `opts.key` groups a sequence of related updates ("opening…" ->
--- "preparing…" -> "ready") into one updating toast when fidget.nvim is
--- installed and reachable; without it (or with some other notifier) this is
--- a plain `vim.notify` and every call is its own message — entirely
--- optional, MeatCode works identically either way.
---@param msg string
---@param level integer|nil
---@param opts {key: string|nil}|nil
function M.notify(msg, level, opts)
  level = level or vim.log.levels.INFO
  local key = opts and opts.key
  if key then
    local notify_fn = resolve_fidget_notify()
    if notify_fn then
      local ok = pcall(notify_fn, msg, level, { key = key, group = "meatcode", annote = "MeatCode" })
      if ok then return end
    end
  end
  vim.notify(msg, level, { title = "MeatCode" })
end

local progress_seq = 0

--- A cancellable/finishable status indicator for one logical task ("opening
--- Two Sum", "checking NeetCode for a stronger oracle"). Renders as a real
--- spinner via fidget.nvim's progress handles when it is installed;
--- otherwise degrades to a single notify that gets replaced in place on
--- every `:report()` rather than stacking a toast per update.
---@param message string initial status text
---@return table handle with :report(message), :finish(message|nil), :cancel()
function M.progress(message)
  local mod = resolve_fidget_progress()
  if mod then
    local ok, handle = pcall(mod.handle.create, {
      title = "MeatCode",
      message = message,
      lsp_client = { name = "MeatCode" },
    })
    if ok and handle then
      return {
        report = function(_, msg) pcall(handle.report, handle, { message = msg }) end,
        finish = function(_, msg)
          if msg then pcall(function() handle.message = msg end) end
          pcall(handle.finish, handle)
        end,
        cancel = function(_) pcall(handle.cancel, handle) end,
      }
    end
  end
  progress_seq = progress_seq + 1
  local key = "meatcode-progress-" .. progress_seq
  M.notify(message, vim.log.levels.INFO, { key = key })
  return {
    report = function(_, msg) M.notify(msg, vim.log.levels.INFO, { key = key }) end,
    finish = function(_, msg) if msg then M.notify(msg, vim.log.levels.INFO, { key = key }) end end,
    cancel = function(_) end,
  }
end

function M.err(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

--- Turn a display name into a filesystem/id friendly slug.
--- "Heap / Priority Queue" -> "heap-priority-queue"
function M.slug(s)
  return (s:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""))
end

--- Recursive mkdir built on libuv, so it is safe to call from inside a
--- vim.system callback (vim.fn.mkdir is not allowed in a fast event context).
function M.mkdirp(path)
  if not path or path == "" or path == "/" then
    return path
  end
  if vim.uv.fs_stat(path) then
    return path
  end
  local parent = vim.fs.dirname(path)
  if parent and parent ~= path then
    M.mkdirp(parent)
  end
  vim.uv.fs_mkdir(path, 493) -- 0755
  return path
end

function M.read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

function M.write_file(path, data)
  M.mkdirp(vim.fs.dirname(path))
  local fd, e = io.open(path, "wb")
  if not fd then
    return nil, e
  end
  fd:write(data)
  fd:close()
  return true
end

function M.file_age(path)
  local st = vim.uv.fs_stat(path)
  if not st then
    return nil
  end
  return os.time() - st.mtime.sec
end

function M.read_json(path)
  local raw = M.read_file(path)
  if not raw or raw == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  return ok and decoded or nil
end

function M.write_json(path, tbl)
  return M.write_file(path, vim.json.encode(tbl))
end

--- Centre `s` inside `width` cells, truncating with an ellipsis when too long.
function M.center(s, width)
  local len = vim.fn.strdisplaywidth(s)
  if len > width then
    while vim.fn.strdisplaywidth(s) > width - 1 and #s > 0 do
      s = s:sub(1, -2)
    end
    s = s .. "…"
    len = vim.fn.strdisplaywidth(s)
  end
  local left = math.floor((width - len) / 2)
  return string.rep(" ", left) .. s .. string.rep(" ", width - len - left)
end

--- Pad `s` to `width` cells (display width aware).
function M.pad(s, width)
  local len = vim.fn.strdisplaywidth(s)
  if len >= width then
    return s
  end
  return s .. string.rep(" ", width - len)
end

return M
