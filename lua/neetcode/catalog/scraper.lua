local client = require("neetcode.api.client")
local jsparse = require("neetcode.catalog.jsparse")

--- Scrapes the problem catalog out of neetcode.io's JS bundle.
---
--- There is no public API that exposes a problem's roadmap pattern or its
--- Blind75/NC150/NC250 membership — that table only exists as a static literal
--- inside the Angular bundle. The bundle filename is content-hashed and its
--- variable names are re-minified on every deploy, so we locate the table by
--- anchoring on a stable data string instead of on any identifier.
local M = {}

local SITE = "https://neetcode.io"

-- Anchors are tried in order; each is a string that appears inside the first
-- element of the catalog array. Pattern names are user-visible and stable.
local ANCHORS = {
  'pattern:"Arrays & Hashing"',
  "pattern:'Arrays & Hashing'",
  '"pattern":"Arrays & Hashing"',
  'pattern:"Two Pointers"',
}

local REQUIRED_KEYS = { "problem", "pattern", "difficulty" }

--- Sanity-check a scraped table before we let it replace a known-good catalog.
---@return boolean ok, string|nil reason
function M.validate(list)
  if type(list) ~= "table" then
    return false, "not a table"
  end
  if #list < 500 then
    return false, string.format("only %d entries, expected 500+", #list)
  end

  local first = list[1]
  if type(first) ~= "table" then
    return false, "entries are not objects"
  end
  for _, key in ipairs(REQUIRED_KEYS) do
    if first[key] == nil then
      return false, "entries are missing the " .. key .. " field"
    end
  end

  local counts = { blind75 = 0, neetcode150 = 0, neetcode250 = 0 }
  local patterns = {}
  for _, p in ipairs(list) do
    for key in pairs(counts) do
      if p[key] then
        counts[key] = counts[key] + 1
      end
    end
    if p.pattern then
      patterns[p.pattern] = true
    end
  end

  -- The curated lists are fixed-size by definition; if these drift the shape of
  -- the data has changed and we should not trust the scrape.
  if counts.blind75 ~= 75 then
    return false, string.format("blind75 has %d problems, expected 75", counts.blind75)
  end
  if counts.neetcode150 ~= 150 then
    return false, string.format("neetcode150 has %d problems, expected 150", counts.neetcode150)
  end
  if counts.neetcode250 ~= 250 then
    return false, string.format("neetcode250 has %d problems, expected 250", counts.neetcode250)
  end

  if not patterns["Arrays & Hashing"] or not patterns["Math & Geometry"] then
    return false, "expected roadmap patterns are missing"
  end

  return true, nil
end

--- Pull the catalog literal out of an already-downloaded bundle.
---@param src string
---@return table|nil list, string|nil err
function M.extract(src)
  for _, anchor in ipairs(ANCHORS) do
    local anchor_pos = src:find(anchor, 1, true)
    if anchor_pos then
      local start = jsparse.enclosing_array_start(src, anchor_pos)
      if start then
        local ok, list = pcall(jsparse.parse, src, start)
        if ok then
          local valid, reason = M.validate(list)
          if valid then
            return list, nil
          end
          -- Keep trying other anchors; report the most informative failure.
          local _ = reason
        end
      end
    end
  end
  return nil, "could not locate the problem catalog in the bundle"
end

--- Resolve the current content-hashed main bundle URL from the site's index.
---@param cb fun(err: string|nil, url: string|nil, hash: string|nil)
function M.bundle_url(cb)
  client.get(SITE .. "/", function(err, body)
    if err then
      return cb(err, nil, nil)
    end
    local file = body:match('src="(main%.[%w]+%.js)"') or body:match('src="(main%-[%w]+%.js)"')
    if not file then
      return cb("could not find the main bundle in the page source", nil, nil)
    end
    local hash = file:match("main[%.%-]([%w]+)%.js")
    cb(nil, SITE .. "/" .. file, hash)
  end)
end

--- Download and parse the live catalog.
---@param cb fun(err: string|nil, result: {problems: table, hash: string, fetched_at: integer}|nil)
function M.fetch(cb)
  M.bundle_url(function(err, url, hash)
    if err then
      return cb(err, nil)
    end
    client.get(url, function(err2, src)
      if err2 then
        return cb(err2, nil)
      end
      local list, err3 = M.extract(src)
      if not list then
        return cb(err3, nil)
      end
      cb(nil, { problems = list, hash = hash, fetched_at = os.time() })
    end)
  end)
end

return M
