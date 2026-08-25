local client = require("neetcode.api.client")
local config = require("neetcode.config")
local util = require("neetcode.util")

--- NeetCode authenticates with Firebase. Their project has password sign-in
--- disabled (accounts are Google/GitHub OAuth only), so there is no way to log
--- in from a headless client. Instead the user pastes a *refresh* token once,
--- which we exchange for short-lived ID tokens indefinitely.
local M = {}

-- Public web API key, read straight out of the site's JS bundle. This is not a
-- secret; Firebase web keys identify the project and are safe to embed.
local FIREBASE_API_KEY = "AIzaSyD4emZpWF1MIsu6Z8O6yaMMcPxJ2Z38L8g"
local TOKEN_URL = "https://securetoken.googleapis.com/v1/token?key=" .. FIREBASE_API_KEY

-- Refresh a minute early so a token can't expire mid-request.
local EXPIRY_SKEW = 60

local state = { id_token = nil, expires_at = 0, refresh_token = nil, loaded = false }

local function auth_path()
  return config.options.cache_dir .. "/auth.json"
end

local function load()
  if state.loaded then
    return
  end
  state.loaded = true
  local data = util.read_json(auth_path())
  if type(data) == "table" then
    state.refresh_token = data.refresh_token
    state.id_token = data.id_token
    state.expires_at = tonumber(data.expires_at) or 0
  end
end

local function persist()
  local path = auth_path()
  util.write_json(path, {
    refresh_token = state.refresh_token,
    id_token = state.id_token,
    expires_at = state.expires_at,
  })
  -- The refresh token is a long-lived credential; keep it owner-readable only.
  pcall(vim.uv.fs_chmod, path, 384) -- 0600
end

function M.is_logged_in()
  load()
  return state.refresh_token ~= nil and state.refresh_token ~= ""
end

--- Store a refresh token pulled from the browser and verify it works.
---@param token string
---@param cb fun(err: string|nil)
function M.login(token, cb)
  load()
  token = vim.trim(token or "")
  if token == "" then
    return cb("empty token")
  end

  state.refresh_token = token
  state.id_token = nil
  state.expires_at = 0

  M.id_token(function(err)
    if err then
      state.refresh_token = nil
      return cb(err)
    end
    persist()
    cb(nil)
  end)
end

function M.logout()
  load()
  state = { id_token = nil, expires_at = 0, refresh_token = nil, loaded = true }
  os.remove(auth_path())
end

--- Return a valid Firebase ID token, refreshing it if needed.
---@param cb fun(err: string|nil, token: string|nil)
function M.id_token(cb)
  load()

  if not state.refresh_token then
    return cb("not logged in — run :NeetCode login", nil)
  end

  if state.id_token and os.time() < state.expires_at - EXPIRY_SKEW then
    return cb(nil, state.id_token)
  end

  local body = table.concat({
    "grant_type=refresh_token",
    "refresh_token=" .. vim.uri_encode(state.refresh_token, "rfc2396"),
  }, "&")

  client.request({
    url = TOKEN_URL,
    method = "POST",
    body = body,
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
  }, function(err, res)
    if err then
      return cb(err, nil)
    end

    local ok, decoded = pcall(vim.json.decode, res.body)
    if not ok or type(decoded) ~= "table" then
      return cb("could not decode token response", nil)
    end

    if decoded.error then
      local msg = type(decoded.error) == "table" and decoded.error.message or tostring(decoded.error)
      if msg == "TOKEN_EXPIRED" or msg == "INVALID_REFRESH_TOKEN" or msg == "USER_DISABLED" then
        msg = msg .. " — your saved token is no longer valid, run :NeetCode login again"
      end
      return cb(msg, nil)
    end

    state.id_token = decoded.id_token
    state.expires_at = os.time() + (tonumber(decoded.expires_in) or 3600)
    persist()
    cb(nil, state.id_token)
  end)
end

--- Run an authenticated callable, acquiring a token first.
function M.with_token(fn)
  return M.id_token(function(err, token)
    if err then
      return fn(err, nil)
    end
    fn(nil, token)
  end)
end

return M
