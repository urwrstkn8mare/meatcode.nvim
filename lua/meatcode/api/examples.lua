--- Recovers published answers and executable solution blocks from provider
--- statements/editorials/community posts.
---
--- Answer parsing is deliberately conservative. Solution extraction is likewise
--- language-aware: a block only belongs to a language when the provider labels
--- it, and callers still execute it against known examples before trusting it.
---
--- Parsing is deliberately all-or-nothing: an example list is only returned when
--- every example yields an output and the count lines up with the inputs the
--- provider reports. A partial parse would judge a case against the wrong
--- answer, which is worse than having no local run at all.
local M = {}

local ENTITIES = {
  lt = "<", gt = ">", amp = "&", quot = '"', apos = "'", nbsp = " ", ["#39"] = "'", ["#34"] = '"',
}

--- Decode the HTML entities LeetCode statements use.
function M.unescape(s)
  return (s:gsub("&([#%w]+);", function(name)
    local named = ENTITIES[name]
    if named then return named end
    local code = name:match("^#(%d+)$")
    if code then
      local ok, char = pcall(vim.fn.nr2char, tonumber(code))
      if ok then return char end
    end
    return "&" .. name .. ";"
  end))
end

--- Flatten statement HTML to plain text, keeping line structure.
local function to_text(html)
  local text = html:gsub("<br%s*/?>", "\n")
  text = text:gsub("</p>", "\n")
  text = text:gsub("</pre>", "\n")
  text = text:gsub("<[^>]->", "")
  return M.unescape(text)
end

--- Everything after `Output:` on one statement line. The colon is required:
--- explanations open with prose like "Output is ordered by length".
local function output_value(line)
  local value = line:match("^%s*Output:%s*(.*)$")
  if not value then return nil end
  value = vim.trim(value)
  return value ~= "" and value or nil
end

--- Expected outputs of a LeetCode statement's examples, in statement order.
---
--- Design problems print `Output` as a bare label with the value on the next
--- line, so a label with nothing after it takes the next non-empty line.
---@param content string the `question.content` HTML
---@return string[] outputs
function M.leetcode(content)
  if type(content) ~= "string" then return {} end
  local lines = vim.split(to_text(content), "\n", { plain = true })
  local outputs = {}
  for i, line in ipairs(lines) do
    if line:match("^%s*Output:?%s*$") then
      for j = i + 1, #lines do
        local next_line = vim.trim(lines[j])
        if next_line ~= "" then
          if not next_line:match("^Explanation") then table.insert(outputs, next_line) end
          break
        end
      end
    else
      local value = output_value(line)
      if value then table.insert(outputs, value) end
    end
  end
  return outputs
end

--- Rewrite one LintCode example input into the `name=value` blocks the runner
--- speaks. LintCode labels arguments in prose ("binary tree = {1,2,3}") and
--- serialises trees/lists as `{1,2,#}` where LeetCode writes `[1,2,null]`.
---@param input string
function M.normalize_lintcode_input(input)
  local out = {}
  for _, raw in ipairs(vim.split(input, "\n", { plain = true })) do
    for _, line in ipairs(M.split_arguments(vim.trim((raw:gsub("\r$", ""))))) do
      if line ~= "" then
        local name, value = line:match("^([%a_][%w_ ]*)%s*=%s*(.*)$")
        if name then
          table.insert(out, (vim.trim(name):gsub("%s+", "_")) .. "=" .. M.retree(value))
        else
          table.insert(out, M.retree(line))
        end
      end
    end
  end
  return table.concat(out, "\n")
end

--- Split a line that carries several arguments (`num1 = "1", num2 = "2"`) into
--- one per argument. Commas inside a value are left alone: a split only happens
--- where a top-level comma is followed by another `name =`.
---@return string[]
function M.split_arguments(line)
  local parts, start, depth, quote = {}, 1, 0, nil
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if quote then
      if c == "\\" then i = i + 1
      elseif c == quote then quote = nil end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == "[" or c == "{" or c == "(" then
      depth = depth + 1
    elseif c == "]" or c == "}" or c == ")" then
      depth = depth - 1
    elseif c == "," and depth == 0 and line:sub(i + 1):match("^%s*[%a_][%w_ ]*%s*=") then
      table.insert(parts, vim.trim(line:sub(start, i - 1)))
      start = i + 1
    end
    i = i + 1
  end
  table.insert(parts, vim.trim(line:sub(start)))
  return parts
end

--- LintCode's brace-and-hash node encoding, in LeetCode's bracket-and-null form.
function M.retree(value)
  if not value:match("^%b{}$") then return value end
  local inner = value:sub(2, -2)
  local parts = {}
  for _, item in ipairs(vim.split(inner, ",", { plain = true })) do
    item = vim.trim(item)
    table.insert(parts, item == "#" and "null" or item)
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local CODE_TAGS = {
  python = { python = true, python3 = true, py = true },
  cpp = { cpp = true, ["c++"] = true },
}

--- Language-labelled fenced code blocks from ordinary Markdown (LeetCode) and
--- LintCode's single-fence `[[python]] ... [[cpp]] ...` convention.
---@param content string
---@param lang "python"|"cpp"
---@param allow_unlabelled boolean|nil trusted external language tag/title
---@return string[]
function M.code_blocks(content, lang, allow_unlabelled)
  if type(content) ~= "string" or not CODE_TAGS[lang] then return {} end
  content = M.unescape(content):gsub("\\r\\n", "\n"):gsub("\\n", "\n"):gsub("\r\n", "\n")
  local out = {}
  local seen = {}
  local function add(code)
    code = vim.trim(code or "")
    if code ~= "" and not seen[code] then
      seen[code] = true
      table.insert(out, code)
    end
  end

  for info, body in content:gmatch("```([^\n]*)\n(.-)```") do
    local tag = vim.trim(info):match("^([^%s%[]+)") or ""
    if CODE_TAGS[lang][tag:lower()] then add(body) end
  end

  -- LintCode puts several languages inside one unlabelled fence.
  for fence in content:gmatch("```%s*\n(.-)```") do
    local wanted = false
    local body = {}
    for _, line in ipairs(vim.split(fence, "\n", { plain = true })) do
      local tag = line:match("^%s*%[%[([^%]]+)%]%]%s*$")
      if tag then
        if wanted then add(table.concat(body, "\n")) end
        wanted = CODE_TAGS[lang][tag:lower()] == true
        body = {}
      elseif wanted then
        table.insert(body, line)
      end
    end
    if wanted then add(table.concat(body, "\n")) end
  end
  if allow_unlabelled then
    for body in content:gmatch("```%s*\n(.-)```") do
      if not body:find("%[%[[^%]]+%]%]") then add(body) end
    end
  end
  return out
end

--- Examples in a LintCode statement, which is Markdown rather than HTML.
---
--- Both halves are labelled, but the shape varies by problem: the value may sit
--- on the label's line or on the lines under it, inside a fenced block or not.
--- Anything from a label to the next label, fence or blank line is the value,
--- which also keeps multi-argument inputs together:
---
---     Input:                     Input : s = "abccccdd"
---     ```                        Output : 7
---     numbers = [2,7,11,15]
---     target = 9
---     ```
---     Output:
---     ```
---     [0,1]
---     ```
---@param markdown string
---@return {input: string, output: string}[]
function M.lintcode(markdown)
  if type(markdown) ~= "string" then return {} end
  local examples, pending, open_label, body = {}, nil, nil, {}

  --- Attach one half of an example; a completed pair is emitted.
  local function store(which, value)
    pending = pending or {}
    -- A repeated half means the previous example never got its other one.
    if pending[which] then pending = {} end
    pending[which] = value
    if pending.input and pending.output then
      table.insert(examples, pending)
      pending = nil
    end
  end

  local function finish()
    if not open_label then return end
    local value = vim.trim(table.concat(body, "\n"))
    local which = open_label
    open_label, body = nil, {}
    if value ~= "" then store(which, value) end
  end

  for _, raw in ipairs(vim.split(M.unescape(markdown), "\n", { plain = true })) do
    local line = vim.trim((raw:gsub("\r$", "")))
    local bare = line:gsub("%*", "")
    local which, inline = nil, nil
    local head, rest = bare:match("^(%a+)%s*:%s*(.*)$")
    if head == "Input" or head == "Output" then
      which, inline = head:lower(), rest
    end
    if which then
      finish()
      open_label = which
      if inline ~= "" then
        body = { inline }
        finish()
      end
    elseif line == "" or line:match("^```") or bare:match("^Explanation") or bare:match("^Example") then
      -- A label's value often starts on the next line, inside a fence: those
      -- openers sit between the label and its value and must not close it.
      if not (open_label and #body == 0) then finish() end
    elseif open_label then
      table.insert(body, line)
    end
  end
  finish()
  return examples
end

return M
