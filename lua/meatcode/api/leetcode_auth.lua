local client = require("meatcode.api.client")
local config = require("meatcode.config")
local util = require("meatcode.util")

local M = {}

local state = { loaded = false, cookie = nil, csrf = nil, user = nil }

local USER_QUERY = [[
query globalData {
  userStatus {
    userId
    username
    isSignedIn
    isPremium
    isVerified
  }
}
]]

local function path()
  return config.options.cache_dir .. "/leetcode-auth.json"
end

local function parse(cookie)
  if type(cookie) ~= "string" then
    return nil, "expected the Cookie request header from leetcode.com"
  end
  cookie = vim.trim(cookie)
  local csrf = cookie:match("csrftoken=([^;]+)")
  local session = cookie:match("LEETCODE_SESSION=([^;]+)")
  if not csrf or csrf == "" then
    return nil, "cookie has no csrftoken"
  end
  if not session or session == "" then
    return nil, "cookie has no LEETCODE_SESSION"
  end
  return { cookie = cookie, csrf = csrf }
end

local function load()
  if state.loaded then
    return
  end
  state.loaded = true
  local saved = util.read_json(path())
  if type(saved) ~= "table" then
    return
  end
  local parsed = parse(saved.cookie)
  if parsed then
    state.cookie = parsed.cookie
    state.csrf = parsed.csrf
    state.user = type(saved.user) == "table" and saved.user or nil
  end
end

local function persist()
  util.write_json(path(), { cookie = state.cookie, user = state.user })
  pcall(vim.uv.fs_chmod, path(), 384) -- 0600
end

function M.headers(cookie)
  load()
  local parsed = cookie and parse(cookie) or nil
  local raw = parsed and parsed.cookie or state.cookie
  local csrf = parsed and parsed.csrf or state.csrf
  local headers = {
    ["Accept"] = "application/json",
    ["Content-Type"] = "application/json",
    ["Origin"] = "https://leetcode.com",
    ["Referer"] = "https://leetcode.com/",
    ["User-Agent"] = "Mozilla/5.0 (compatible; meatcode.nvim)",
  }
  if raw then
    headers["Cookie"] = raw
    headers["x-csrftoken"] = csrf
  end
  return headers
end

local function validate(cookie, cb)
  client.request({
    url = "https://leetcode.com/graphql/",
    method = "POST",
    headers = M.headers(cookie),
    body = vim.json.encode({ query = USER_QUERY, variables = vim.empty_dict() }),
  }, function(err, res)
    if err then
      return cb(err, nil)
    end
    local ok, decoded = pcall(vim.json.decode, res.body or "")
    local user = ok and decoded and decoded.data and decoded.data.userStatus
    if res.status < 200 or res.status >= 300 then
      return cb("LeetCode returned HTTP " .. tostring(res.status), nil)
    end
    if type(user) ~= "table" or not user.isSignedIn or user.username == vim.NIL then
      return cb("LeetCode rejected the cookie; copy the complete Cookie request header", nil)
    end
    cb(nil, user)
  end)
end

function M.login(cookie, cb)
  cb = cb or function() end
  local parsed, err = parse(cookie)
  if not parsed then
    return cb(err)
  end
  validate(parsed.cookie, function(validate_err, user)
    if validate_err then
      return cb(validate_err)
    end
    state.loaded = true
    state.cookie = parsed.cookie
    state.csrf = parsed.csrf
    state.user = user
    persist()
    cb(nil, user)
  end)
end

function M.logout()
  state = { loaded = true, cookie = nil, csrf = nil, user = nil }
  if vim.uv.fs_stat(path()) then
    pcall(vim.uv.fs_unlink, path())
  end
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
    return cb("not logged in to LeetCode — run :MeatCode login leetcode", nil)
  end
  validate(state.cookie, function(err, user)
    if err then
      return cb(err, nil)
    end
    state.user = user
    persist()
    cb(nil, user)
  end)
end

return M
