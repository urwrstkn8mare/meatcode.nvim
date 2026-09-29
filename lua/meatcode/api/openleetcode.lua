local client = require("meatcode.api.client")
local config = require("meatcode.config")
local util = require("meatcode.util")

--- Checkers from openleetcode (github.com/therepanic/openleetcode), an open
--- set of LeetCode test manifests. A manifest's `oracle.python3` section is a
--- Python `Checker` class plus a call such as
--- `Checker().longestPalindrome(s, {result})` that decides whether any output
--- is correct for any input — the strongest local oracle there is, and exact
--- even when a problem accepts several answers.
---
--- Manifests live at `tests/<bucket>/<id>. <slug>/manifest.yaml`, 500 ids per
--- bucket. An index of the bucket listings (GitHub's contents API) maps slugs
--- to directories; without it the path is derived from the frontend id.
--- Parsed checkers, misses included, are cached for `catalog_max_age`.
local M = {}

local REPO = "therepanic/openleetcode"
local RAW = "https://raw.githubusercontent.com/" .. REPO .. "/main/"
local CONTENTS = "https://api.github.com/repos/" .. REPO .. "/contents/tests"
local BUCKET = 500

local function cache_dir()
  return config.options.cache_dir .. "/openleetcode"
end

local function index_path()
  return cache_dir() .. "/index.json"
end

local function checker_path(slug)
  return string.format("%s/checkers/%s.json", cache_dir(), util.slug(slug))
end

local function utilities_path()
  return cache_dir() .. "/utilities.py"
end

local function fresh(path)
  local age = util.file_age(path)
  if not age then return false end
  local max_age = config.options.catalog_max_age
  return max_age == false or age < (tonumber(max_age) or 0)
end

-- ------------------------------------------------------------------ YAML

--- Key under which every parsed mapping keeps its keys in document order.
local ORDER = {}

local function indent_of(line)
  return #line:match("^ *")
end

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local ESCAPES = {
  n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/", ["0"] = "\0",
  b = "\b", f = "\f", a = "\a", v = "\v", e = "\27", [" "] = " ",
}

--- A double-quoted scalar's value, or nil while its closing quote is missing.
local function double_quoted(text)
  local out, i = {}, 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == '"' then return table.concat(out) end
    if c == "\\" then
      local n = text:sub(i + 1, i + 1)
      local width = ({ x = 2, u = 4, U = 8 })[n]
      if width then
        table.insert(out, utf8_char(tonumber(text:sub(i + 2, i + 1 + width), 16) or 0xFFFD))
        i = i + 2 + width
      else
        table.insert(out, ESCAPES[n] or n)
        i = i + 2
      end
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  return nil
end

--- A single-quoted scalar's value (`''` is a quote), or nil while unclosed.
local function single_quoted(text)
  local out, i = {}, 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == "'" then
      if text:sub(i + 1, i + 1) ~= "'" then return table.concat(out) end
      table.insert(out, "'")
      i = i + 2
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  return nil
end

--- A quoted scalar starting on line `i`, folding any continuation lines.
---@return string value, integer next_line
local function quoted(lines, i, value)
  local quote = value:sub(1, 1)
  local decode = quote == '"' and double_quoted or single_quoted
  local raw, j = value:sub(2), i
  while true do
    local text = decode(raw)
    if text then return text, j + 1 end
    j = j + 1
    if j > #lines then return raw, j end
    local continuation = vim.trim(lines[j])
    if continuation == "" then
      raw = raw .. "\n"
    elseif quote == '"' and raw:sub(-1) == "\\" then
      raw = raw:sub(1, -2) .. continuation
    else
      raw = raw .. (raw:sub(-1) == "\n" and "" or " ") .. continuation
    end
  end
end

--- A `|`/`>` block scalar whose header sits on line `i`.
---@return string value, integer next_line
local function block_scalar(lines, i, parent_indent, header)
  local style = header:sub(1, 1)
  local indicators = header:match("^[|>]([%d+-]*)") or ""
  local chomp = indicators:match("[+-]")
  local explicit = tonumber(indicators:match("%d"))
  local body, j = {}, i + 1
  local block_indent = explicit and (parent_indent + explicit) or nil
  while j <= #lines do
    local line = lines[j]
    if line:match("^%s*$") then
      table.insert(body, "")
    else
      local indent = indent_of(line)
      if indent <= parent_indent then break end
      block_indent = block_indent or indent
      if indent < block_indent then break end
      table.insert(body, line:sub(block_indent + 1))
    end
    j = j + 1
  end
  local trailing = 0
  while #body > 0 and body[#body] == "" do
    table.remove(body)
    trailing = trailing + 1
  end

  local text
  if style == ">" then
    local out, joined = {}, false
    for _, line in ipairs(body) do
      if line == "" or line:match("^%s") then
        table.insert(out, (joined and "\n" or "") .. line .. "\n")
        joined = false
      else
        table.insert(out, (joined and " " or "") .. line)
        joined = true
      end
    end
    text = table.concat(out)
  else
    text = table.concat(body, "\n")
  end
  if chomp == "+" then
    text = text .. string.rep("\n", trailing + 1)
  elseif chomp ~= "-" and #body > 0 then
    text = text .. "\n"
  end
  return text, j
end

--- `key: value` (the key possibly quoted), or nil for anything else.
local function split_key(rest)
  local quote = rest:sub(1, 1)
  if quote == '"' or quote == "'" then
    local close = rest:find(quote, 2, true)
    if close and rest:sub(close + 1, close + 1) == ":" then
      return rest:sub(2, close - 1), vim.trim(rest:sub(close + 2))
    end
    return nil
  end
  local key, value = rest:match("^([^:]-):%s+(.*)$")
  if not key then
    key, value = rest:match("^([^:]-):$"), ""
  end
  if not key or vim.trim(key) == "" then return nil end
  return vim.trim(key), value
end

--- A plain scalar, minus any trailing ` # comment`.
local function plain(value)
  local cut = value:find("%s#")
  if cut then value = value:sub(1, cut - 1) end
  return vim.trim(value)
end

--- Parse the part of YAML the manifests use outside `tests`: nested block
--- mappings holding plain, quoted and block scalars. Sequences (only `tests`
--- has them) are skipped; flow collections are kept as text. Every mapping
--- records its key order under `ORDER`.
---@param text string
---@return table
function M.parse(text)
  local lines = vim.split((text:gsub("\r\n?", "\n")), "\n", { plain = true })
  local root = { [ORDER] = {} }
  local stack = { { indent = -1, node = root } }
  local function set(node, key, value)
    if node[key] == nil then table.insert(node[ORDER], key) end
    node[key] = value
  end

  local i = 1
  while i <= #lines do
    local line = lines[i]
    local indent = indent_of(line)
    local rest = line:sub(indent + 1)
    if rest == "" or rest:match("^#") or rest:match("^%-%-%-") or rest:match("^%.%.%.") then
      i = i + 1
    else
      while indent <= stack[#stack].indent do table.remove(stack) end
      local node = stack[#stack].node
      if rest == "-" or rest:match("^%-%s") then
        i = i + 1
        while i <= #lines do
          local next_line = lines[i]
          if not next_line:match("^%s*$") and not next_line:match("^%s*#")
            and indent_of(next_line) <= indent then
            break
          end
          i = i + 1
        end
      else
        local key, value = split_key(rest)
        if not key then
          i = i + 1
        elseif value == "" or value:match("^#") then
          local child = { [ORDER] = {} }
          set(node, key, child)
          table.insert(stack, { indent = indent, node = child })
          i = i + 1
        elseif value:match("^[|>]") then
          local content
          content, i = block_scalar(lines, i, indent, value)
          set(node, key, content)
        elseif value:match("^[\"']") then
          local content
          content, i = quoted(lines, i, value)
          set(node, key, content)
        else
          set(node, key, plain(value))
          i = i + 1
        end
      end
    end
  end
  return root
end

--- The checker a parsed manifest carries, or nil when it has none.
---@return {id: integer|nil, title: string|nil, path: string, params: string[], call: string, source: string, judge: string|nil}|nil
function M.extract(doc, path)
  local oracle = type(doc.oracle) == "table" and doc.oracle.python3 or nil
  if type(oracle) ~= "table" or type(oracle.checker) ~= "string" or type(oracle.call) ~= "string"
    or not oracle.call:find("{result}", 1, true) then
    return nil
  end
  local entry = type(doc.entry) == "table" and doc.entry or {}
  local params = type(entry.params) == "table" and vim.deepcopy(entry.params[ORDER] or {}) or {}
  if #params == 0 then return nil end
  return {
    id = tonumber(entry.id),
    title = type(entry.title) == "string" and entry.title or nil,
    path = path,
    params = params,
    call = oracle.call,
    source = oracle.checker,
    judge = type(doc.judge) == "table" and type(doc.judge.type) == "string" and doc.judge.type or nil,
  }
end

-- ------------------------------------------------------------------ fetching

local function encode_path(path)
  local segments = {}
  for segment in path:gmatch("[^/]+") do
    table.insert(segments, vim.uri_encode(segment, "rfc2396"))
  end
  return table.concat(segments, "/")
end

--- `slug -> manifest directory` for every problem openleetcode carries.
local function index(cb)
  local cached = util.read_json(index_path())
  if type(cached) == "table" and fresh(index_path()) then return cb(cached) end
  client.get(CONTENTS, function(err, body)
    local ok, buckets = pcall(vim.json.decode, body or "")
    if err or not ok or type(buckets) ~= "table" then
      return cb(type(cached) == "table" and cached or nil)
    end
    local dirs = {}
    for _, item in ipairs(buckets) do
      if type(item) == "table" and item.type == "dir" and type(item.name) == "string" then
        table.insert(dirs, item.name)
      end
    end
    local out, pending, failed = {}, #dirs, false
    if pending == 0 then return cb(type(cached) == "table" and cached or nil) end
    for _, dir in ipairs(dirs) do
      client.get(CONTENTS .. "/" .. dir, function(list_err, list_body)
        local list_ok, items = pcall(vim.json.decode, list_body or "")
        if list_err or not list_ok or type(items) ~= "table" then
          failed = true
        else
          for _, item in ipairs(items) do
            local slug = type(item) == "table" and type(item.name) == "string"
              and item.name:match("^%d+%.%s+(.+)$")
            if slug then out[slug] = "tests/" .. dir .. "/" .. item.name end
          end
        end
        pending = pending - 1
        if pending > 0 then return end
        vim.schedule(function()
          if failed then return cb(type(cached) == "table" and cached or out) end
          util.write_json(index_path(), out)
          cb(out)
        end)
      end)
    end
  end)
end

--- The manifest directory derived from a LeetCode frontend id.
local function bucket_path(frontend_id, slug)
  local id = tonumber(frontend_id)
  if not id or id < 1 then return nil end
  local low = math.floor((id - 1) / BUCKET) * BUCKET + 1
  return string.format("tests/%d-%d/%d. %s", low, low + BUCKET - 1, id, slug)
end

--- openleetcode's Python runtime helpers (`to_tree_node`, `list_node_to_array`,
--- ...), which a checker may call. Optional: a checker that needs none still
--- works without them.
local function utilities(cb)
  local path = utilities_path()
  local cached = util.read_file(path)
  if cached and fresh(path) then return cb(cached) end
  client.get(RAW .. "runtimes/python3/utilities.py", function(err, body)
    vim.schedule(function()
      if err or not body then return cb(cached) end
      util.write_file(path, body)
      cb(body)
    end)
  end)
end

--- The checker for a LeetCode slug, or nil when openleetcode has none for it.
--- A fresh cache answers synchronously; otherwise the manifest is fetched, and
--- a failed fetch falls back to a stale cache entry.
---@param slug string LeetCode title slug
---@param frontend_id string|integer|nil LeetCode's displayed id, used without the index
---@param cb fun(err: string|nil, checker: table|nil)
function M.checker(slug, frontend_id, cb)
  if type(slug) ~= "string" or slug == "" then return cb(nil, nil) end
  local path = checker_path(slug)
  local cached = util.read_json(path)
  local cached_checker = type(cached) == "table" and type(cached.checker) == "table" and cached.checker or nil
  if type(cached) == "table" and fresh(path) then return cb(nil, cached_checker) end

  local function remember(checker)
    util.write_json(path, { checker = checker or vim.NIL })
    cb(nil, checker)
  end
  index(function(dirs)
    local dir = type(dirs) == "table" and dirs[slug] or bucket_path(frontend_id, slug)
    if not dir then return vim.schedule(function() remember(nil) end) end
    client.get(RAW .. encode_path(dir) .. "/manifest.yaml", function(err, body)
      vim.schedule(function()
        if err then
          if err:match("HTTP 404") then return remember(nil) end
          if type(cached) == "table" then return cb(nil, cached_checker) end
          return cb(err, nil)
        end
        local ok, doc = pcall(M.parse, body or "")
        local checker = ok and M.extract(doc, dir) or nil
        if not checker then return remember(nil) end
        utilities(function(helpers)
          checker.utilities = helpers
          remember(checker)
        end)
      end)
    end)
  end)
end

return M
