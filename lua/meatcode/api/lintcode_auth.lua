local client = require("meatcode.api.client")
local config = require("meatcode.config")
local util = require("meatcode.util")

local M = {}

--- LintCode's web client holds a long-lived refresh JWT (localStorage
--- `@JWT:REFRESH_TOKEN`, good for a week) and mints a short-lived access JWT
--- from it (≈500 seconds) which it sends as `Authorization: Bearer <access>`.
--- Storing only an access token would log you out minutes later, so the
--- refresh token is what gets persisted and access tokens are minted on demand
--- via `/v2/api/token-refresh/`.
local API = "https://apiv1.lintcode.com"
local REFRESH_URL = API .. "/v2/api/token-refresh/"
local SKEW = 30 -- seconds of slack before an access token is considered stale

local state = { loaded = false, creds = nil, user = nil }
local refreshing = nil -- queued callbacks while one refresh is in flight

local function path()
  return config.options.cache_dir .. "/lintcode-auth.json"
end

local BAD_INPUT =
  "expected a LintCode JWT — run the login script, or copy the Authorization header from a signed-in tab"

--- Payload of a JWT, or nil when the value is not a decodable JWT.
local function payload(token)
  if type(token) ~= "string" then return nil end
  local part = token:match("^[%w%-_]+%.([%w%-_]+)%.")
  if not part then return nil end
  part = part:gsub("-", "+"):gsub("_", "/")
  part = part .. string.rep("=", (4 - #part % 4) % 4)
  local ok, raw = pcall(vim.base64.decode, part)
  if not ok then return nil end
  local decoded_ok, decoded = pcall(vim.json.decode, raw)
  return decoded_ok and type(decoded) == "table" and decoded or nil
end

local function expired(token, skew)
  local claims = payload(token)
  local exp = claims and tonumber(claims.exp)
  if not exp then return false end
  return exp - (skew or SKEW) <= os.time()
end

--- Sort JWTs found in `input` into refresh/access slots. LintCode tags them in
--- the payload as `token_type`; anything untagged is treated as an access
--- token, and an unexpired refresh token always wins.
local function classify(token, creds)
  local claims = payload(token)
  local kind = claims and claims.token_type
  if kind == "refresh" then
    creds.refresh = token
  elseif kind == "access" or not creds.access then
    creds.access = token
  end
end

--- Accept the login script's combined `Bearer … Cookie: …` line, a pasted
--- header block, a bare JWT, or a bare cookie string.
local function parse(input)
  if type(input) ~= "string" or vim.trim(input) == "" then return nil, BAD_INPUT end
  local creds = {}
  for _, raw in ipairs(vim.split(input, "\n", { plain = true })) do
    local line = vim.trim(raw)
    local cookie = line:match("[Cc][Oo][Oo][Kk][Ii][Ee]%s*:%s*(.+)$")
    if cookie then
      creds.cookie = vim.trim(cookie)
    elseif line:find("=", 1, true) and not line:find("eyJ", 1, true) then
      creds.cookie = creds.cookie and (creds.cookie .. "; " .. line) or line
    end
    for token in line:gmatch("eyJ[%w%-_]*%.[%w%-_]+%.[%w%-_]+") do
      classify(token, creds)
    end
  end
  if not creds.refresh and not creds.access then return nil, BAD_INPUT end
  if creds.refresh and expired(creds.refresh, 0) then
    return nil, "that LintCode refresh token has already expired — rerun the script on a signed-in tab"
  end
  return creds
end

local function load()
  if state.loaded then return end
  state.loaded = true
  local saved = util.read_json(path())
  if type(saved) ~= "table" then return end
  local creds = {}
  for _, key in ipairs({ "refresh", "access", "cookie" }) do
    if type(saved[key]) == "string" and saved[key] ~= "" then creds[key] = saved[key] end
  end
  if creds.refresh or creds.access then
    state.creds = creds
    state.user = type(saved.user) == "table" and saved.user or nil
  end
end

local function persist()
  local creds = state.creds or {}
  util.write_json(path(), {
    refresh = creds.refresh,
    access = creds.access,
    cookie = creds.cookie,
    user = state.user,
  })
  pcall(vim.uv.fs_chmod, path(), 384) -- 0600
end

--- Headers for `creds` (defaults to the stored credentials) exactly as they
--- stand; call `M.with_headers` instead when the access token may be stale.
function M.headers(creds)
  load()
  creds = creds or state.creds
  local headers = { ["Accept"] = "application/json" }
  if not creds then return headers end
  if creds.access then headers["Authorization"] = "Bearer " .. creds.access end
  if creds.cookie then
    headers["Cookie"] = creds.cookie
    local csrf = creds.cookie:match("csrftoken=([^;]+)") or creds.cookie:match("csrf=([^;]+)")
    if csrf then headers["X-CSRFToken"] = csrf end
  end
  return headers
end

--- Mint a new access token from `creds.refresh`, updating `creds` in place.
local function mint(creds, cb)
  client.request({
    url = REFRESH_URL,
    method = "POST",
    headers = {
      ["Accept"] = "application/json",
      ["Content-Type"] = "application/json",
      ["Origin"] = "https://www.lintcode.com",
      ["Referer"] = "https://www.lintcode.com/",
    },
    body = vim.json.encode({ refresh = creds.refresh }),
  }, function(err, res)
    if err then return cb(err) end
    local ok, body = pcall(vim.json.decode, res.body or "")
    local data = ok and type(body) == "table" and body.data or nil
    if data == vim.NIL then data = nil end
    local access = type(data) == "table" and (data.access or data.access_token)
      or (ok and type(body) == "table" and body.access)
    if type(access) ~= "string" or access == "" then
      local detail = ok and type(body) == "table" and body.detail or nil
      return cb("LintCode refused to refresh the session"
        .. (detail and detail ~= "" and (": " .. detail) or "")
        .. " — rerun :MeatCode login lintcode")
    end
    creds.access = access
    local rotated = type(data) == "table" and data.refresh or nil
    if type(rotated) == "string" and rotated ~= "" then creds.refresh = rotated end
    cb(nil)
  end)
end

--- Ensure `creds` carries a usable access token, minting one when needed.
local function ensure(creds, cb)
  if creds.access and not expired(creds.access) then return cb(nil) end
  if not creds.refresh then
    return cb(creds.access and "that LintCode access token has expired — rerun :MeatCode login lintcode"
      or "not logged in to LintCode — run :MeatCode login lintcode")
  end
  mint(creds, cb)
end

--- Headers for the stored credentials, refreshing the access token first.
--- Concurrent callers share a single in-flight refresh.
function M.with_headers(cb)
  load()
  local creds = state.creds
  if not creds then return cb("not logged in to LintCode — run :MeatCode login lintcode", nil) end
  if creds.access and not expired(creds.access) then return cb(nil, M.headers(creds)) end
  if refreshing then
    table.insert(refreshing, cb)
    return
  end
  refreshing = { cb }
  ensure(creds, function(err)
    local waiting = refreshing
    refreshing = nil
    if not err then persist() end
    for _, waiter in ipairs(waiting) do
      waiter(err, err and nil or M.headers(creds))
    end
  end)
end

local function profile(creds, cb)
  client.request({
    url = API .. "/new/api/accounts/profile/",
    headers = M.headers(creds),
  }, function(err, res)
    if err then return cb(err, nil) end
    local ok, decoded = pcall(vim.json.decode, res.body or "")
    local data = ok and type(decoded) == "table" and decoded.data
    local user = type(data) == "table" and data.user_info
    if res.status < 200 or res.status >= 300 then
      return cb("LintCode returned HTTP " .. tostring(res.status), nil)
    end
    if type(user) ~= "table" then
      return cb("LintCode rejected the credential — rerun the login script on a signed-in tab", nil)
    end
    cb(nil, user)
  end)
end

local function validate(creds, cb)
  ensure(creds, function(err)
    if err then return cb(err, nil) end
    profile(creds, cb)
  end)
end

function M.login(credential, cb)
  cb = cb or function() end
  local creds, err = parse(credential)
  if not creds then return cb(err) end
  validate(creds, function(validate_err, user)
    if validate_err then return cb(validate_err) end
    state = { loaded = true, creds = creds, user = user }
    persist()
    cb(nil, user)
  end)
end

function M.logout()
  state = { loaded = true, creds = nil, user = nil }
  if vim.uv.fs_stat(path()) then pcall(vim.uv.fs_unlink, path()) end
end

--- True while a credential that can still authenticate is on disk: an
--- unexpired refresh token, or an access token that has not lapsed yet.
function M.is_logged_in()
  load()
  local creds = state.creds
  if not creds then return false end
  if creds.refresh and not expired(creds.refresh, 0) then return true end
  return creds.access ~= nil and not expired(creds.access)
end

function M.user()
  load()
  return state.user
end

function M.refresh(cb)
  cb = cb or function() end
  load()
  if not state.creds then
    return cb("not logged in to LintCode — run :MeatCode login lintcode", nil)
  end
  validate(state.creds, function(err, user)
    if err then return cb(err, nil) end
    state.user = user
    persist()
    cb(nil, user)
  end)
end

return M
