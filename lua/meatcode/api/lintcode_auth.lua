local client = require("meatcode.api.client")
local config = require("meatcode.config")
local util = require("meatcode.util")

local M = {}

local state = { loaded = false, cookie = nil, user = nil }

local function path()
  return config.options.cache_dir .. "/lintcode-auth.json"
end

local function parse(cookie)
  if type(cookie) ~= "string" or vim.trim(cookie) == "" then
    return nil, "expected the Cookie request header from lintcode.com"
  end
  return vim.trim(cookie)
end

local function load()
  if state.loaded then return end
  state.loaded = true
  local saved = util.read_json(path())
  if type(saved) == "table" and type(saved.cookie) == "string" and saved.cookie ~= "" then
    state.cookie = saved.cookie
    state.user = type(saved.user) == "table" and saved.user or nil
  end
end

local function persist()
  util.write_json(path(), { cookie = state.cookie, user = state.user })
  pcall(vim.uv.fs_chmod, path(), 384) -- 0600
end

function M.headers(cookie)
  load()
  local raw = cookie and parse(cookie) or state.cookie
  local headers = { ["Accept"] = "application/json" }
  if raw then
    headers["Cookie"] = raw
    local csrf = raw:match("csrftoken=([^;]+)") or raw:match("csrf=([^;]+)")
    if csrf then headers["X-CSRFToken"] = csrf end
  end
  return headers
end

local function validate(cookie, cb)
  client.request({
    url = "https://apiv1.lintcode.com/new/api/accounts/profile/",
    headers = M.headers(cookie),
  }, function(err, res)
    if err then return cb(err, nil) end
    local ok, decoded = pcall(vim.json.decode, res.body or "")
    local user = ok and decoded and decoded.data and decoded.data.user_info
    if res.status < 200 or res.status >= 300 then
      return cb("LintCode returned HTTP " .. tostring(res.status), nil)
    end
    if type(user) ~= "table" then
      return cb("LintCode rejected the cookie; copy the complete Cookie request header", nil)
    end
    cb(nil, user)
  end)
end

function M.login(cookie, cb)
  cb = cb or function() end
  local parsed, err = parse(cookie)
  if not parsed then return cb(err) end
  validate(parsed, function(validate_err, user)
    if validate_err then return cb(validate_err) end
    state = { loaded = true, cookie = parsed, user = user }
    persist()
    cb(nil, user)
  end)
end

function M.logout()
  state = { loaded = true, cookie = nil, user = nil }
  if vim.uv.fs_stat(path()) then pcall(vim.uv.fs_unlink, path()) end
end

function M.is_logged_in()
  load()
  return state.cookie ~= nil
end

function M.user()
  load()
  return state.user
end

function M.refresh(cb)
  cb = cb or function() end
  load()
  if not state.cookie then
    return cb("not logged in to LintCode — run :MeatCode login lintcode", nil)
  end
  validate(state.cookie, function(err, user)
    if err then return cb(err, nil) end
    state.user = user
    persist()
    cb(nil, user)
  end)
end

return M
