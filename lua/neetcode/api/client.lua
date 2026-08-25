local config = require("neetcode.config")

local M = {}

--- Low level curl wrapper.
---@param opts table url, method, body, headers, timeout
---@param cb fun(err: string|nil, res: {status: integer, body: string}|nil)
function M.request(opts, cb)
  local url = assert(opts.url, "url required")
  local timeout = opts.timeout or config.options.timeout

  -- `-w` appends the status after the body so we can parse both from stdout
  -- without needing a second stream or a temp file for headers.
  local cmd = {
    "curl", "-sS", "-L",
    "--max-time", tostring(timeout),
    "-w", "\n%{http_code}",
    "-X", opts.method or "GET",
  }

  for k, v in pairs(opts.headers or {}) do
    table.insert(cmd, "-H")
    table.insert(cmd, string.format("%s: %s", k, v))
  end

  local stdin = nil
  if opts.body then
    -- Pass the payload over stdin; problem submissions can be large enough to
    -- bump into ARG_MAX on some systems.
    table.insert(cmd, "--data-binary")
    table.insert(cmd, "@-")
    stdin = opts.body
  end

  table.insert(cmd, url)

  local ok, err = pcall(vim.system, cmd, { text = true, stdin = stdin }, function(res)
    if res.code ~= 0 then
      local msg = (res.stderr or ""):gsub("%s+$", "")
      if msg == "" then
        msg = "curl exited with code " .. res.code
      end
      return cb(msg, nil)
    end

    local out = res.stdout or ""
    local body, status = out:match("^(.*)\n(%d+)$")
    if not status then
      return cb("malformed curl response", nil)
    end

    cb(nil, { status = tonumber(status), body = body })
  end)

  if not ok then
    cb(tostring(err), nil)
  end
end

--- Fetch a URL and hand back the raw body, failing on non-2xx.
---@param url string
---@param cb fun(err: string|nil, body: string|nil)
function M.get(url, cb)
  M.request({ url = url }, function(err, res)
    if err then
      return cb(err, nil)
    end
    if res.status < 200 or res.status >= 300 then
      return cb(string.format("GET %s returned HTTP %d", url, res.status), nil)
    end
    cb(nil, res.body)
  end)
end

--- Call a NeetCode Firebase-callable endpoint.
---
--- The backend speaks the firebase-functions `onCall` HTTP protocol: the payload
--- is wrapped in `{"data": ...}` and the reply is wrapped the same way, with
--- errors surfacing as `{"error": {"message": ..., "status": ...}}`.
---@param fn string function name, e.g. "getProblemMetadataFunctionHttp"
---@param data table payload placed under the `data` key
---@param opts table|nil token (string), timeout (seconds)
---@param cb fun(err: string|nil, data: any)
function M.callable(fn, data, opts, cb)
  opts = opts or {}
  local headers = { ["Content-Type"] = "application/json" }
  if opts.token then
    headers["Authorization"] = "Bearer " .. opts.token
  end

  M.request({
    url = "https://neetcode.io/api/" .. fn,
    method = "POST",
    body = vim.json.encode({ data = data }),
    headers = headers,
    timeout = opts.timeout,
  }, function(err, res)
    if err then
      return cb(err, nil)
    end

    local decoded_ok, decoded = pcall(vim.json.decode, res.body)
    if not decoded_ok then
      return cb(string.format("%s: bad JSON (HTTP %d)", fn, res.status), nil)
    end

    if type(decoded) == "table" and decoded.error then
      local e = decoded.error
      local msg = type(e) == "table" and (e.message or e.status) or tostring(e)
      return cb(string.format("%s: %s", fn, msg), nil)
    end

    if res.status < 200 or res.status >= 300 then
      return cb(string.format("%s: HTTP %d", fn, res.status), nil)
    end

    -- `data` is legitimately null for unknown problem ids, so distinguish that
    -- from a transport failure rather than reporting it as an error here.
    local payload = type(decoded) == "table" and decoded.data or nil
    if payload == vim.NIL then
      payload = nil
    end
    cb(nil, payload)
  end)
end

--- Convenience wrapper for the generic `callableFunctionHttp` dispatcher, which
--- multiplexes ~170 backend functions behind a `functionId` field.
function M.dispatch(function_id, data, opts, cb)
  local payload = vim.tbl_extend("force", data or {}, { functionId = function_id })
  return M.callable("callableFunctionHttp", payload, opts, cb)
end

return M
