--- Renders a problem statement the way the website presents it.
---
--- Every provider's statement is first brought into one markdown dialect by
--- `ui.statement`, so this renderer sees the same shapes whichever site served
--- the problem: headings, prose, lists, example blocks, diagrams, folded hints.
--- We conceal the markup and translate the maths into the characters a
--- terminal can actually draw. Topics, companies and availability live in the
--- footer; provider links live in the <leader>no fuzzy picker, not here.
local providers = require("meatcode.providers")
local statement = require("meatcode.ui.statement")

local M = {}

local NS = vim.api.nvim_create_namespace("meatcode_description")

--- State for the render in progress. `images` maps a row to a diagram to draw.
--- `links` maps a row to the openable spans on it -- inline links and diagrams
--- alike -- because a line can carry more than one.
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

local function blank(s)
  return (" "):rep(#s)
end

local function inline(marks, row, line)
  delimited(marks, row, line, "%*%*[^%*]+%*%*", 2, "MeatCodeBold")
  delimited(marks, row, line, "`[^`]+`", 1, "MeatCodeInlineCode")
  -- LaTeX and `<code>` spans are the same thing written two ways; they look
  -- alike so a statement does not betray which site it came from.
  delimited(marks, row, line, "%$[^%$]+%$", 1, "MeatCodeInlineCode")
  -- Emphasis is searched with bold, code and maths blanked out (same byte
  -- offsets), so their asterisks are never taken for its delimiters.
  local masked = line:gsub("%*%*[^%*]+%*%*", blank):gsub("`[^`]+`", blank):gsub("%$[^%$]+%$", blank)
  delimited(marks, row, masked, "%*[^%*%s][^%*]-%*", 1, "MeatCodeItalic")
end

-- ---------------------------------------------------------------- blocks

local INDENT = "  "

--- Append one prose chunk to `lines`, recording highlight marks as we go.
---@param text string markdown in the `ui.statement` dialect
---@param prefix string leading whitespace for every line of this chunk
---@param tight boolean|nil drop a leading gap, so a fold body sits under its header
local function render_md(text, lines, marks, prefix, tight)
  prefix = prefix or INDENT
  local in_code, code_start = false, nil
  local pending, seen = false, false
  -- What the last row drawn was: "text", "item", "heading", "image" or "code".
  local last = nil

  --- Emit a deferred blank line. Runs of them collapse into one, and any that
  --- would trail the chunk simply never get flushed. A list hangs directly off
  --- the sentence that introduces it, and its items never spread apart.
  local function gap(kind)
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
    if kind == "item" and (last == "text" or last == "item") then
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
        hl_group = "MeatCodeCodeBlock", hl_eol = true,
      } })
    end
    in_code, code_start = false, nil
    pending = true
  end

  for _, raw_line in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = raw_line:gsub("%s+$", "")

    if line:match("^%s*```") then
      if in_code then
        close_code()
      else
        gap("code")
        in_code, code_start = true, #lines
        last = "code"
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
    local url = trimmed:match("^!%[.-%]%((.-)%)$")
    if url and url ~= "" then
      gap("image")
      local label = prefix .. "🖼  open diagram"
      table.insert(lines, label)
      table.insert(marks, { #lines - 1, 0, { end_col = #label, hl_group = "MeatCodeFold" } })
      images[#lines - 1] = url
      add_link(#lines - 1, 0, #(lines[#lines]) + 1, url)
      seen, pending, last = true, true, "image"
      goto continue
    end

    local heading = trimmed:match("^#+%s+(.*)$")
    if heading then
      gap("heading")
      table.insert(lines, prefix .. heading:gsub("`", ""))
      table.insert(marks, { #lines - 1, 0, { end_col = #lines[#lines], hl_group = "MeatCodeSection" } })
      seen, pending, last = true, true, "heading"
      goto continue
    end

    -- HTML bodies keep their source indentation, which would otherwise leak
    -- through as a ragged left edge. Prose owns none of it; `prefix` sets it.
    line = typeset(trimmed)
    -- Any image left inline keeps only its alt text.
    line = line:gsub("!%[([^%]]*)%]%([^%)]*%)", "%1")

    local number, numbered = line:match("^(%d+%.)%s+(.*)$")
    local bullet = line:match("^[%*%-]%s+(.*)$")
    local kind = (number or bullet) and "item" or "text"
    gap(kind)
    if number then
      line = prefix .. number .. " " .. numbered
    elseif bullet then
      line = prefix .. "• " .. bullet
    else
      line = prefix .. line
    end
    local text, spans = delink(line)
    table.insert(lines, text)
    local row = #lines - 1
    inline(marks, row, text)
    for _, span in ipairs(spans) do
      table.insert(marks, { row, span.from, { end_col = span.to, hl_group = "MeatCodeLink" } })
      add_link(row, span.from, span.to, span.url)
    end
    seen, last = true, kind

    ::continue::
  end

  if in_code then
    close_code()
  end
end

-- ---------------------------------------------------------------- render

---@param buf integer
---@param problem table catalog entry
---@param meta table problem metadata
---@param sections table[] from M.sections
---@param opts table|nil {completions = integer}
---@return table fold_rows, table image_rows, table link_rows
function M.render(buf, problem, meta, sections, opts)
  local lines, marks = {}, {}
  local fold_rows = {}
  images, links = {}, {}

  -- Header: the title carries the page, so give it weight and breathing room.
  table.insert(lines, "")
  table.insert(lines, INDENT .. meta.name)
  table.insert(marks, { #lines - 1, 0, { end_col = #lines[#lines], hl_group = "MeatCodeTitle" } })
  table.insert(lines, "")

  local badge = string.format("%s●  %s", INDENT, meta.difficulty)
  local completions = (opts or {}).completions or 0
  local status = string.format("%d completion%s", completions, completions == 1 and "" or "s")
  local sep = "   ·   "
  -- Only NeetCode reports its hidden test count; "0 hidden tests" would be a
  -- claim nobody made.
  local hidden = tonumber(meta.test_case_count) or 0
  local tail = hidden > 0 and string.format("%s%d hidden tests", sep, hidden) or ""

  table.insert(lines, badge .. sep .. status .. tail)
  local row = #lines - 1
  table.insert(marks, { row, 0, { end_col = #badge,
    hl_group = require("meatcode.ui.highlight").difficulty(meta.difficulty) } })
  table.insert(marks, { row, #badge, { end_col = #badge + #sep, hl_group = "MeatCodeMuted" } })
  table.insert(marks, { row, #badge + #sep, { end_col = #badge + #sep + #status,
    hl_group = completions > 0 and "MeatCodeDone" or "MeatCodeMuted" } })
  table.insert(marks, { row, #badge + #sep + #status,
    { end_col = #badge + #sep + #status + #tail, hl_group = "MeatCodeMuted" } })
  table.insert(lines, "")

  -- Tags and availability live in the footer; see below.
  for _, section in ipairs(sections) do
    if section.kind == "md" then
      render_md(section.text, lines, marks)
    else
      if #lines > 0 and lines[#lines] ~= "" then
        table.insert(lines, "")
      end
      local header = string.format("%s%s %s", INDENT, section.open and "▾" or "▸", section.summary)
      table.insert(lines, header)
      table.insert(marks, { #lines - 1, 0, { end_col = #header, hl_group = "MeatCodeFold" } })
      fold_rows[#lines - 1] = section

      if section.open then
        render_md(section.text, lines, marks, INDENT .. INDENT, true)
      end
    end
  end

  -- Footer: provider-independent tags, then where the problem can be solved.
  local function footer_row(label, value, value_group)
    local text = string.format("%s%-11s%s", INDENT, label, value)
    table.insert(lines, text)
    local row_at = #lines - 1
    table.insert(marks, { row_at, 0, { end_col = #INDENT + 11, hl_group = "MeatCodeMuted" } })
    table.insert(marks, { row_at, #INDENT + 11, { end_col = #text, hl_group = value_group } })
  end

  local footer = {}
  if #(problem.topics or {}) > 0 then
    table.insert(footer, { "types", table.concat(problem.topics, " · "), "MeatCodeTag" })
  end
  if #(problem.companies or {}) > 0 then
    table.insert(footer, { "companies", table.concat(problem.companies, " · "), "MeatCodeTag" })
  end

  local where = {}
  for _, name in ipairs(providers.NAMES) do
    local record = problem.providers and problem.providers[name]
    if record then
      local backend = providers.get(name)
      local locked = record.paid and not providers.paid_unlocked(name)
      table.insert(where, backend.label
        .. (record.paid and (locked and " [paid · locked]" or " [paid]") or ""))
    end
  end
  if #where > 0 then
    table.insert(footer, { "available", table.concat(where, " · "), "MeatCodeMuted" })
  end

  if #footer > 0 then
    table.insert(lines, "")
    for _, entry in ipairs(footer) do
      footer_row(entry[1], entry[2], entry[3])
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

--- The statement body plus its collapsible folds (hints and the like).
---@param meta table problem metadata
---@param provider string provider that served `meta`
function M.sections(meta, provider)
  local normalized = statement.normalize(meta, provider)
  local out = {}
  if vim.trim(normalized.body) ~= "" then
    table.insert(out, { kind = "md", text = normalized.body })
  end
  for _, fold in ipairs(normalized.folds) do
    table.insert(out, { kind = "fold", summary = fold.summary, text = fold.text, open = false })
  end
  return out
end

return M
