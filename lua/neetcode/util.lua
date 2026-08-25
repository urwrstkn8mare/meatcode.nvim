local M = {}

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "neetcode" })
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
