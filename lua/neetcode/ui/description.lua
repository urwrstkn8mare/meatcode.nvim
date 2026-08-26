--- Renders a NeetCode problem statement the way the website presents it.
---
--- The payload is markdown with HTML mixed in: `<details class="hint-accordion">`
--- blocks for topics/hints, `<code>` spans, `<br>` spacing, and LaTeX between
--- dollar signs. We fold the accordions, conceal the markup and translate the
--- maths into the characters a terminal can actually draw.
local M = {}

local NS = vim.api.nvim_create_namespace("neetcode_description")

--- State for the render in progress. `images` maps a row to a diagram to draw.
--- `links` maps a row to the openable spans on it -- inline links, diagrams and
--- footer links alike -- because a line can carry more than one.
local images, links = {}, {}

---@param from integer byte column, inclusive
---@param to integer byte column, exclusive
local function add_link(row, from, to, url)
  links[row] = links[row] or {}
  table.insert(links[row], { from = from, to = to, url = url })
end

--- Replace `[label](url)` with just `label`, reporting where each one landed.
---
--- The parentheses are matched as a balanced pair, so a URL containing its own
--- brackets -- Wikipedia's `Foo_(disambiguation)` -- survives intact.
---@return string text, table spans
local function delink(line)
  local out, spans, pos = {}, {}, 1

  while true do
    local start, close, label = line:find("%[([^%]]*)%]", pos)
    if not start then
      break
    end

    local paren = line:sub(close + 1, close + 1) == "(" and line:match("^%b()", close + 1)
    if paren then
      table.insert(out, line:sub(pos, start - 1))
      local from = #table.concat(out)
      table.insert(out, label)
      table.insert(spans, { from = from, to = from + #label, url = paren:sub(2, -2) })
      pos = close + #paren + 1
    else
      -- A bare `[...]`, which is ordinary prose.
      table.insert(out, line:sub(pos, close))
      pos = close + 1
    end
  end

  table.insert(out, line:sub(pos))
  return table.concat(out), spans
end

-- ------------------------------------------------------------------- text

local ENTITIES = {
  ["&lt;"] = "<", ["&gt;"] = ">", ["&amp;"] = "&", ["&quot;"] = '"',
  ["&#39;"] = "'", ["&apos;"] = "'", ["&nbsp;"] = " ",
}

local SUPER = {
  ["0"] = "⁰", ["1"] = "¹", ["2"] = "²", ["3"] = "³", ["4"] = "⁴",
  ["5"] = "⁵", ["6"] = "⁶", ["7"] = "⁷", ["8"] = "⁸", ["9"] = "⁹", ["-"] = "⁻",
}

--- Longest first, so `\leq` is not eaten by `\le`.
local MATH = {
  { "\\leftarrow", "←" }, { "\\rightarrow", "→" }, { "\\lfloor", "⌊" },
  { "\\rfloor", "⌋" }, { "\\lceil", "⌈" }, { "\\rceil", "⌉" },
  { "\\ldots", "…" }, { "\\infty", "∞" }, { "\\times", "×" },
  { "\\dots", "…" }, { "\\cdot", "·" }, { "\\sqrt", "√" },
  { "\\text", "" }, { "\\neq", "≠" }, { "\\leq", "≤" }, { "\\geq", "≥" },
  { "\\sum", "Σ" }, { "\\log", "log" }, { "\\ne", "≠" }, { "\\le", "≤" },
  { "\\ge", "≥" }, { "\\{", "{" }, { "\\}", "}" }, { "\\%", "%" }, { "\\ ", " " },
}

local function plain_gsub(s, from, to)
  return (s:gsub(from:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"), (to:gsub("%%", "%%%%"))))
end

--- Fold HTML down to the markdown subset we render.
local function clean_html(s)
  -- A tag's count lives in a nested span; keep it off the tag's name.
  s = s:gsub("<span[^>]*>(.-)</span>", " %1")
  s = s:gsub("<code>(.-)</code>", "`%1`")
  s = s:gsub("<a[^>]*>(.-)</a>", "%1")
  s = s:gsub("<strong>(.-)</strong>", "**%1**")
  s = s:gsub("<b>(.-)</b>", "**%1**")
  s = s:gsub("<em>(.-)</em>", "*%1*")
  s = s:gsub('<img[^>]*src="([^"]*)"[^>]*>', "\n![](%1)\n")
  s = s:gsub("<br%s*/?>", "\n")
  s = s:gsub("</?p[^>]*>", "\n")
  s = s:gsub("</?div[^>]*>", "\n")
  s = s:gsub("<[^>]+>", "")
  for entity, char in pairs(ENTITIES) do
    s = plain_gsub(s, entity, char)
  end
  return s
end

--- Maths that a monospace grid can show: symbols, then digit superscripts.
local function typeset(s)
  for _, pair in ipairs(MATH) do
    s = plain_gsub(s, pair[1], pair[2])
  end
  local function sup(digits)
    return (digits:gsub(".", SUPER))
  end
  s = s:gsub("%^{(%-?%d+)}", sup)
  s = s:gsub("%^(%-?%d+)", sup)
  return s
end

-- --------------------------------------------------------------- sections

--- Split the raw statement into prose chunks and collapsible accordions.
local function split_sections(raw)
  local out, pos = {}, 1
  while true do
    local s, e, body = raw:find("<details[^>]*>(.-)</details>", pos)
    if not s then
      break
    end
    local before = raw:sub(pos, s - 1)
    if vim.trim(before) ~= "" then
      table.insert(out, { kind = "md", text = before })
    end

    local summary = vim.trim(clean_html(body:match("<summary>(.-)</summary>") or "Hint"))
    local rest = body:gsub("<summary>.-</summary>", "", 1)

    -- Accordions holding nothing but links (Topics, Company Tags) read better
    -- as a single wrapped line of tags than as one link per line.
    local tags = {}
    for tag in rest:gmatch("<a[^>]*>(.-)</a>") do
      tag = vim.trim(clean_html(tag))
      -- Company tags carry a count; topic tags do not.
      local name, count = tag:match("^(.-)%s+(%d+)$")
      table.insert(tags, { name = name or tag, count = count })
    end
    local remainder = rest:gsub("<a[^>]*>.-</a>", ""):gsub("<[^>]+>", "")

    local section = { kind = "fold", summary = summary, text = rest, open = false }
    if #tags > 0 and vim.trim(remainder) == "" then
      section.tags = tags
    end
    table.insert(out, section)
    pos = e + 1
  end

  local tail = raw:sub(pos)
  if vim.trim(tail) ~= "" then
    table.insert(out, { kind = "md", text = tail })
  end
  return out
end

-- ---------------------------------------------------------------- inline

--- Conceal a delimiter pair and highlight what sits between it.
local function delimited(marks, row, line, pattern, dlen, group)
  local init = 1
  while true do
    local s, e = line:find(pattern, init)
    if not s then
      return
    end
    table.insert(marks, { row, s - 1, { end_col = s - 1 + dlen, conceal = "" } })
    table.insert(marks, { row, s - 1 + dlen, { end_col = e - dlen, hl_group = group } })
    table.insert(marks, { row, e - dlen, { end_col = e, conceal = "" } })
    init = e + 1
  end
end

local function inline(marks, row, line)
  delimited(marks, row, line, "%*%*[^%*]+%*%*", 2, "NeetCodeBold")
  delimited(marks, row, line, "`[^`]+`", 1, "NeetCodeInlineCode")
  delimited(marks, row, line, "%$[^%$]+%$", 1, "NeetCodeMath")
end

-- ---------------------------------------------------------------- blocks

local INDENT = "  "

--- Append one prose chunk to `lines`, recording highlight marks as we go.
---@param prefix string leading whitespace for every line of this chunk
---@param tight boolean|nil drop a leading gap, so a fold body sits under its header
local function render_md(text, lines, marks, prefix, tight)
  prefix = prefix or INDENT
  local in_code, code_start = false, nil
  local pending, seen = false, false

  --- Emit a deferred blank line. Runs of them collapse into one, and any that
  --- would trail the chunk simply never get flushed.
  local function gap()
    if not pending then
      return
    end
    pending = false
    if #lines == 0 or lines[#lines] == "" then
      return
    end
    if tight and not seen then
      return
    end
    table.insert(lines, "")
  end

  --- Band the whole fenced block with one mark, so `hl_eol` fills every row of
  --- it out to the window edge instead of stopping at each line's last column.
  local function close_code()
    if code_start and #lines > code_start then
      table.insert(marks, { code_start, 0, {
        end_row = #lines, end_col = 0,
        hl_group = "NeetCodeCodeBlock", hl_eol = true,
      } })
    end
    in_code, code_start = false, nil
  end

  for _, raw_line in ipairs(vim.split(clean_html(text), "\n", { plain = true })) do
    local line = raw_line:gsub("%s+$", "")

    if line:match("^%s*```") then
      if in_code then
        close_code()
      else
        gap()
        in_code, code_start = true, #lines
      end
      goto continue
    end

    if in_code then
      table.insert(lines, prefix .. INDENT .. line)
      seen = true
      goto continue
    end

    if vim.trim(line) == "" then
      pending = true
      goto continue
    end

    local trimmed = vim.trim(line)

    -- Images hang from this row. image.nvim (when it works) covers the label
    -- with the diagram via virtual padding; otherwise <CR> still opens it.
    local alt, url = trimmed:match("^!%[(.-)%]%((.-)%)$")
    if url and url ~= "" then
      gap()
      local label = string.format("%s🖼  %s", prefix, alt ~= "" and alt or "open diagram")
      table.insert(lines, label)
      table.insert(marks, { #lines - 1, 0, { end_col = #label, hl_group = "NeetCodeFold" } })
      images[#lines - 1] = url
      add_link(#lines - 1, 0, #(lines[#lines]) + 1, url)
      seen, pending = true, true
      goto continue
    end

    -- HTML bodies keep their source indentation, which would otherwise leak
    -- through as a ragged left edge. Prose owns none of it; `prefix` sets it.
    line = typeset(trimmed)
    -- Any image left inline keeps only its alt text.
    line = line:gsub("!%[([^%]]*)%]%([^%)]*%)", "%1")

    local heading = line:match("^%*%*(.-):?%*%*$")
    if line:match("^#+%s") then
      heading = line:gsub("^#+%s*", "")
    end

    if heading then
      gap()
      table.insert(lines, prefix .. heading)
      table.insert(marks, { #lines - 1, 0, { end_col = #lines[#lines], hl_group = "NeetCodeSection" } })
      seen, pending = true, true
    elseif line:match("^%-%-%-+$") then
      pending = true
    else
      gap()
      local bullet, rest = line:match("^([%*%-])%s+(.*)$")
      if bullet then
        line = prefix .. "• " .. rest
      else
        line = prefix .. line
      end
      local text, spans = delink(line)
      table.insert(lines, text)
      local row = #lines - 1
      inline(marks, row, text)
      for _, span in ipairs(spans) do
        table.insert(marks, { row, span.from, { end_col = span.to, hl_group = "NeetCodeLink" } })
        add_link(row, span.from, span.to, span.url)
      end
      seen = true
    end

    ::continue::
  end

  if in_code then
    close_code()
  end
end

--- A row of tags: names picked out, counts and separators held back.
local function render_tags(tags, lines, marks)
  local prefix = INDENT .. INDENT
  local text, spans = prefix, {}
  for i, tag in ipairs(tags) do
    if i > 1 then
      text = text .. "   ·   "
    end
    local from = #text
    text = text .. tag.name
    table.insert(spans, { from, #text, "NeetCodeTag" })
    if tag.count then
      text = text .. " " .. tag.count
    end
  end

  table.insert(lines, text)
  local row = #lines - 1
  -- Everything is muted, then the names are lifted back out of it.
  table.insert(marks, { row, 0, { end_col = #text, hl_group = "NeetCodeMuted" } })
  for _, span in ipairs(spans) do
    table.insert(marks, { row, span[1], { end_col = span[2], hl_group = "NeetCodeTag" } })
  end
end

-- ---------------------------------------------------------------- render

---@param buf integer
---@param problem table catalog entry
---@param meta table problem metadata
---@param sections table[] from M.sections
---@param opts table|nil {solved = boolean}
---@return table fold_rows, table image_rows, table link_rows
function M.render(buf, problem, meta, sections, opts)
  local lines, marks = {}, {}
  local fold_rows = {}
  images, links = {}, {}

  -- Header: the title carries the page, so give it weight and breathing room.
  table.insert(lines, "")
  table.insert(lines, INDENT .. meta.name)
  table.insert(marks, { #lines - 1, 0, { end_col = #lines[#lines], hl_group = "NeetCodeTitle" } })
  table.insert(lines, "")

  local badge = string.format("%s●  %s", INDENT, meta.difficulty)
  local solved = (opts or {}).solved
  local status = solved and "✓ Solved" or "○ Unsolved"
  local sep = "   ·   "
  local tail = string.format("%s%d hidden tests", sep, meta.test_case_count or 0)

  table.insert(lines, badge .. sep .. status .. tail)
  local row = #lines - 1
  table.insert(marks, { row, 0, { end_col = #badge,
    hl_group = require("neetcode.ui.highlight").difficulty(meta.difficulty) } })
  table.insert(marks, { row, #badge, { end_col = #badge + #sep, hl_group = "NeetCodeMuted" } })
  table.insert(marks, { row, #badge + #sep, { end_col = #badge + #sep + #status,
    hl_group = solved and "NeetCodeDone" or "NeetCodeMuted" } })
  table.insert(marks, { row, #badge + #sep + #status,
    { end_col = #badge + #sep + #status + #tail, hl_group = "NeetCodeMuted" } })
  table.insert(lines, "")

  for _, section in ipairs(sections) do
    if section.kind == "md" then
      render_md(section.text, lines, marks)
    else
      if #lines > 0 and lines[#lines] ~= "" then
        table.insert(lines, "")
      end
      local header = string.format("%s%s %s", INDENT, section.open and "▾" or "▸", section.summary)
      table.insert(lines, header)
      table.insert(marks, { #lines - 1, 0, { end_col = #header, hl_group = "NeetCodeFold" } })
      fold_rows[#lines - 1] = section

      if section.open then
        if section.tags then
          render_tags(section.tags, lines, marks)
        else
          render_md(section.text, lines, marks, INDENT .. INDENT, true)
        end
      end
    end
  end

  -- Footer: where this problem lives, openable with the same key as a diagram.
  local footer = {}
  if problem.id then
    table.insert(footer, { "neetcode", "https://neetcode.io/problems/" .. problem.id })
  end
  if problem.leetcode then
    table.insert(footer, { "leetcode", "https://leetcode.com/problems/" .. problem.leetcode .. "/" })
  end
  if problem.video then
    table.insert(footer, { "video", "https://youtube.com/watch?v=" .. problem.video })
  end
  if #footer > 0 then
    table.insert(lines, "")
    for _, entry in ipairs(footer) do
      local label = string.format("%s%-10s %s", INDENT, entry[1], entry[2])
      table.insert(lines, label)
      table.insert(marks, { #lines - 1, 0, { end_col = #label, hl_group = "NeetCodeMuted" } })
      add_link(#lines - 1, 0, #label + 1, entry[2])
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, m[1], m[2], m[3])
  end

  return fold_rows, images, links
end

---@param raw string the `description` field of the problem metadata
function M.sections(raw)
  return split_sections(raw or "")
end

return M
