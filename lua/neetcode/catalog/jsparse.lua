--- Minimal parser for the subset of JavaScript literal syntax that Angular's
--- minifier emits for static data tables.
---
--- This is deliberately *not* a JSON parser: the bundle uses unquoted object
--- keys and the minified booleans `!0` / `!1`, neither of which is valid JSON.
--- Everything else (strings, numbers, nested arrays/objects) overlaps with JSON.
local M = {}

local ESCAPES = {
  ['"'] = '"', ["'"] = "'", ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v", ["0"] = "\0",
}

---@class neetcode.JsParser
local P = {}
P.__index = P

local function new(src, pos)
  return setmetatable({ src = src, pos = pos or 1 }, P)
end

function P:error(msg)
  error(string.format("jsparse: %s at offset %d", msg, self.pos), 0)
end

function P:skip_ws()
  local _, e = self.src:find("^[ \t\r\n]+", self.pos)
  if e then
    self.pos = e + 1
  end
end

function P:peek()
  return self.src:sub(self.pos, self.pos)
end

function P:expect(ch)
  if self:peek() ~= ch then
    self:error(string.format("expected %q, got %q", ch, self:peek()))
  end
  self.pos = self.pos + 1
end

function P:parse_string()
  local quote = self:peek()
  if quote ~= '"' and quote ~= "'" then
    self:error("expected a string")
  end
  self.pos = self.pos + 1

  local parts = {}
  while true do
    local ch = self:peek()
    if ch == "" then
      self:error("unterminated string")
    elseif ch == quote then
      self.pos = self.pos + 1
      break
    elseif ch == "\\" then
      local esc = self.src:sub(self.pos + 1, self.pos + 1)
      self.pos = self.pos + 2
      if esc == "u" then
        local hex
        if self:peek() == "{" then
          -- \u{1f600} style escape
          local close = self.src:find("}", self.pos, true)
          if not close then
            self:error("unterminated \\u{...}")
          end
          hex = self.src:sub(self.pos + 1, close - 1)
          self.pos = close + 1
        else
          hex = self.src:sub(self.pos, self.pos + 3)
          self.pos = self.pos + 4
        end
        local cp = tonumber(hex, 16)
        table.insert(parts, cp and vim.fn.nr2char(cp, 1) or "")
      elseif esc == "x" then
        local cp = tonumber(self.src:sub(self.pos, self.pos + 1), 16)
        self.pos = self.pos + 2
        table.insert(parts, cp and string.char(cp) or "")
      else
        table.insert(parts, ESCAPES[esc] or esc)
      end
    else
      -- Consume a whole run of ordinary characters at once.
      local nxt = self.src:find("[\\" .. quote .. "]", self.pos)
      if not nxt then
        self:error("unterminated string")
      end
      table.insert(parts, self.src:sub(self.pos, nxt - 1))
      self.pos = nxt
    end
  end

  return table.concat(parts)
end

function P:parse_object()
  self:expect("{")
  local obj = {}
  self:skip_ws()
  if self:peek() == "}" then
    self.pos = self.pos + 1
    return obj
  end

  while true do
    self:skip_ws()
    local key
    local ch = self:peek()
    if ch == '"' or ch == "'" then
      key = self:parse_string()
    else
      local s, e, ident = self.src:find("^([%a_$][%w_$]*)", self.pos)
      if not s then
        self:error("expected an object key")
      end
      key = ident
      self.pos = e + 1
    end

    self:skip_ws()
    self:expect(":")
    self:skip_ws()
    obj[key] = self:parse_value()

    self:skip_ws()
    local sep = self:peek()
    if sep == "," then
      self.pos = self.pos + 1
    elseif sep == "}" then
      self.pos = self.pos + 1
      return obj
    else
      self:error(string.format("expected ',' or '}', got %q", sep))
    end
  end
end

function P:parse_array()
  self:expect("[")
  local arr = {}
  self:skip_ws()
  if self:peek() == "]" then
    self.pos = self.pos + 1
    return arr
  end

  while true do
    self:skip_ws()
    table.insert(arr, self:parse_value())
    self:skip_ws()
    local sep = self:peek()
    if sep == "," then
      self.pos = self.pos + 1
    elseif sep == "]" then
      self.pos = self.pos + 1
      return arr
    else
      self:error(string.format("expected ',' or ']', got %q", sep))
    end
  end
end

function P:parse_value()
  self:skip_ws()
  local ch = self:peek()

  if ch == "{" then
    return self:parse_object()
  elseif ch == "[" then
    return self:parse_array()
  elseif ch == '"' or ch == "'" then
    return self:parse_string()
  elseif ch == "!" then
    -- Minified booleans: !0 is true, !1 is false.
    local digit = self.src:sub(self.pos + 1, self.pos + 1)
    self.pos = self.pos + 2
    return digit == "0"
  end

  local s, e, word = self.src:find("^(%a+)", self.pos)
  if s then
    self.pos = e + 1
    if word == "true" then return true end
    if word == "false" then return false end
    if word == "null" or word == "undefined" then return nil end
    self:error("unexpected identifier " .. word)
  end

  local ns, ne, num = self.src:find("^(%-?%d+%.?%d*[eE]?[%+%-]?%d*)", self.pos)
  if ns then
    self.pos = ne + 1
    return tonumber(num)
  end

  self:error(string.format("unexpected character %q", ch))
end

--- Parse a single literal starting at `pos` in `src`.
---@return any value, integer next_pos
function M.parse(src, pos)
  local p = new(src, pos)
  local value = p:parse_value()
  return value, p.pos
end

--- Find the index of the `[` that opens the array containing `anchor_pos`,
--- scanning backwards while tracking brace depth so nested objects are skipped.
---
--- Bundle variable names change on every deploy, so anchoring on a stable *data*
--- string and walking outward is far more durable than matching `O=[`.
---@return integer|nil
function M.enclosing_array_start(src, anchor_pos)
  local depth = 0
  for i = anchor_pos, 1, -1 do
    local ch = src:sub(i, i)
    if ch == "}" then
      depth = depth + 1
    elseif ch == "{" then
      if depth > 0 then
        depth = depth - 1
      end
    elseif ch == "[" and depth == 0 then
      return i
    elseif ch == "]" and depth == 0 then
      -- A sibling array closed before we found our opener.
      return nil
    end
  end
  return nil
end

return M
