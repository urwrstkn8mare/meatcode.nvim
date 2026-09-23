--- Brings every provider's problem statement into one markdown dialect, so a
--- problem reads the same whichever of LeetCode, NeetCode or LintCode served it.
---
--- LeetCode ships HTML, NeetCode markdown with HTML accordions, LintCode loose
--- markdown stitched together from separate fields. Each is first flattened to
--- markdown, then laid out again by one set of rules: headings come from a
--- fixed vocabulary, every example becomes a single `Input / Output /
--- Explanation` block, images sit on their own line. Topics and company tags
--- are problem metadata rather than prose -- they are dropped here and the
--- statement footer shows them for every provider alike.
---
--- The output dialect is what `ui.description` renders: `# Heading` lines,
--- fenced blocks, `* ` / `1. ` list items, `![](url)` image lines, and inline
--- `**bold**`, `*italic*`, `` `code` ``, `$math$` and `[label](url)`.
local M = {}

-- ------------------------------------------------------------------ html

local NAMED = { lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

local function decode(s)
  s = s:gsub("&#[xX](%x+);", function(hex) return vim.fn.nr2char(tonumber(hex, 16)) end)
  s = s:gsub("&#(%d+);", function(dec) return vim.fn.nr2char(tonumber(dec)) end)
  -- An unknown name returns nil, which keeps the text as written.
  s = s:gsub("&(%a+);", NAMED)
  -- Last, so `&amp;lt;` stays the literal text `&lt;`.
  s = s:gsub("&amp;", "&")
  -- Non-breaking spaces only ever pad prose; they must not defeat trimming.
  return (s:gsub("\194\160", " "))
end

--- Only real HTML elements are removed: statements are full of `<`, from
--- `1 <= n` to `List<Integer>`, and none of that is markup.
local TAGS = {}
for name in ([[a abbr b big blockquote br center code dd del details div dl dt em
  font h1 h2 h3 h4 h5 h6 hr i img ins kbd li ol p pre s small span strike strong
  sub summary sup table tbody td tfoot th thead tr tt u ul var]]):gmatch("%S+") do
  TAGS[name] = true
end

local function strip_tags(s)
  return (s:gsub("</?(%a%w*)[^<>]*>", function(name)
    if TAGS[name:lower()] then return "" end
  end))
end

local SUPER = {
  ["0"] = "⁰", ["1"] = "¹", ["2"] = "²", ["3"] = "³", ["4"] = "⁴",
  ["5"] = "⁵", ["6"] = "⁶", ["7"] = "⁷", ["8"] = "⁸", ["9"] = "⁹",
  ["-"] = "⁻", ["+"] = "⁺",
}
local SUB = {
  ["0"] = "₀", ["1"] = "₁", ["2"] = "₂", ["3"] = "₃", ["4"] = "₄",
  ["5"] = "₅", ["6"] = "₆", ["7"] = "₇", ["8"] = "₈", ["9"] = "₉",
  ["-"] = "₋", ["+"] = "₊",
}

--- `10<sup>5</sup>` becomes `10⁵`; what has no such glyph falls back to the
--- `^`/`_` spelling NeetCode and LintCode write by hand.
local function scripts(s)
  local function convert(map, marker)
    return function(body)
      body = strip_tags(body)
      if body:match("^[%d%+%-]+$") then return (body:gsub(".", map)) end
      return marker .. (#body > 1 and "{" .. body .. "}" or body)
    end
  end
  s = s:gsub("<sup[^>]*>(.-)</sup>", convert(SUPER, "^"))
  return (s:gsub("<sub[^>]*>(.-)</sub>", convert(SUB, "_")))
end

local function image(src)
  return "\n![](" .. src .. ")\n"
end

--- Preformatted content keeps only its text: it is laid out again as a block.
local function plain(html)
  html = html:gsub('<img[^>]-src="([^"]*)"[^>]*>', image)
  html = html:gsub("<li[^>]*>", "\n- ")
  html = html:gsub("<br%s*/?>", "\n"):gsub("</?p[^>]*>", "\n")
  return decode(strip_tags(scripts(html)))
end

---@param base string|nil origin that site-relative links resolve against
local function html_to_md(s, base)
  s = s:gsub("\r", ""):gsub("<!%-%-.-%-%->", "")

  local function block(body)
    return "\n```\n" .. plain(body) .. "\n```\n"
  end
  -- LeetCode's newer problems put each example in a styled div rather than a
  -- <pre>; both collapse to the same fenced block.
  s = s:gsub('<div[^>]-class="example%-block"[^>]*>(.-)</div>', block)
  s = s:gsub("<pre[^>]*>(.-)</pre>", block)

  s = s:gsub("<ol[^>]*>(.-)</ol>", function(body)
    local n = 0
    return "\n" .. body:gsub("<li[^>]*>", function()
      n = n + 1
      return "\n" .. n .. ". "
    end) .. "\n"
  end)
  s = s:gsub("<li[^>]*>", "\n* ")

  s = scripts(s)
  s = s:gsub("<code[^>]*>(.-)</code>", "`%1`")
  -- Nested emphasis (`<strong><em>x</em> y</strong>`) has no terminal
  -- rendering of its own; the outer weight wins.
  s = s:gsub("<strong[^>]*>(.-)</strong>", function(inner)
    return "**" .. inner:gsub("</?em>", ""):gsub("</?i>", "") .. "**"
  end)
  s = s:gsub("<b>(.-)</b>", "**%1**")
  s = s:gsub("<em>(.-)</em>", function(inner)
    return "*" .. inner:gsub("%*%*", "") .. "*"
  end)
  s = s:gsub("<i>(.-)</i>", "*%1*")
  s = s:gsub('<a[^>]-href="([^"]*)"[^>]*>(.-)</a>', function(href, label)
    label = strip_tags(label)
    if href:sub(1, 1) == "/" and base then href = base .. href end
    if href == "" or href:sub(1, 1) == "#" then return label end
    return "[" .. label .. "](" .. href .. ")"
  end)
  s = s:gsub("<(https?://[^>%s]+)>", "[%1](%1)")
  s = s:gsub('<img[^>]-src="([^"]*)"[^>]*>', image)
  s = s:gsub("<br%s*/?>", "\n"):gsub("</?p[^>]*>", "\n"):gsub("</?div[^>]*>", "\n")
  s = s:gsub("</?[uo]l[^>]*>", "\n"):gsub("</li>", "\n")
  return decode(strip_tags(s))
end

-- ------------------------------------------------------------- structure

local IMAGE = "^!%[.-%]%((.-)%)$"

--- LintCode writes its labels with a fullwidth colon as often as not.
local function ascii_colon(s)
  return (s:gsub("：", ":"))
end

--- The one vocabulary of section names. `false` drops a heading that only
--- groups what follows (LintCode's "Examples" above its numbered examples).
local function heading_name(text)
  text = vim.trim((ascii_colon(text):gsub("[`*]", ""):gsub(":%s*$", "")))
  local lower = text:lower()
  if lower == "examples" then return false end
  if lower:match("^example%s*%d*$") then return "Example" end
  if lower:match("^follow[%s%-]*up$") or lower == "challenge" then return "Follow-up" end
  if lower == "note" or lower == "notes" then return "Note" end
  if lower == "constraints" then return "Constraints" end
  return text
end

--- A line that is a heading on its own: `# Name` or `**Name:**`.
local function heading_of(t)
  local h = t:match("^#+%s+(.+)$")
  if h then return h end
  local inner = ascii_colon(t):match("^%*%*(.-)%*%*:?$")
  if inner and inner ~= "" and not inner:find("%*%*", 1) then return inner end
end

--- `Follow up: …` / `**Note:** …`: a label run into the paragraph it heads.
local function lead_heading(t)
  t = ascii_colon(t)
  local label, rest = t:match("^%*%*([^%*]-)%*%*%s*(.*)$")
  if not label then label, rest = t:match("^(%a[%a%s%-]-)%s*(:.*)$") end
  if not label then return nil end
  local colon = label:match(":%s*$") or rest:match("^:")
  rest = vim.trim((rest:gsub("^:", "")))
  local name = heading_name(label)
  if colon and rest ~= "" and (name == "Follow-up" or name == "Note") then
    return name, rest
  end
end

local LABELS = { input = "Input", output = "Output", explanation = "Explanation" }

--- `Input: x`, `Input：x` or a bare `Input` line.
local function label_of(text)
  local word, rest = text:match("^(%a+)%s*(.*)$")
  local name = word and LABELS[word:lower()]
  if not name then return nil end
  if rest:sub(1, 1) == ":" then
    rest = rest:sub(2)
  elseif rest:sub(1, 3) == "：" then
    rest = rest:sub(4)
  elseif rest ~= "" then
    return nil
  end
  return name, vim.trim(rest)
end

--- Gather one example -- wherever its provider put the pieces: inside a
--- fence, beside it, or a label per fence -- and lay it out as one block.
---@return integer next line index
local function example(src, i, n, push)
  local preface, fields, images = {}, {}, {}
  local current, in_fence, fenced = nil, false, false

  local function add(text, outside)
    local name, value = label_of(vim.trim(text))
    if name then
      current = { name = name, inline = value, lines = {}, outside = outside }
      table.insert(fields, current)
      fenced = false
    elseif current then
      table.insert(current.lines, text)
    else
      table.insert(preface, text)
    end
  end

  while i <= #src do
    local raw = src[i]:gsub("%s+$", "")
    local t = vim.trim(raw)
    if t:match("^```") then
      in_fence = not in_fence
      fenced = fenced or not in_fence
    elseif t == "" then
      -- Spacing inside an example is the renderer's call, not the provider's.
    elseif t:match(IMAGE) then
      table.insert(images, t:match(IMAGE))
    elseif in_fence then
      add(raw, false)
    else
      local text = t:gsub("%*%*", ""):gsub("`", "")
      -- A label wins over heading syntax: `**Explanation:**` opens a field.
      -- Other prose after the block is only absorbed while it continues a
      -- label written outside any fence (LintCode's "Explanation:" paragraph).
      if label_of(text) then
        add(text, true)
      elseif heading_of(t) or t:match("^%-%-%-+$") then
        break
      elseif current and current.outside and not fenced then
        add(text, true)
      else
        break
      end
    end
    i = i + 1
  end

  push("", "# Example " .. n, "")
  for _, url in ipairs(images) do
    push("![](" .. url .. ")", "")
  end

  local body = vim.list_extend({}, preface)
  for _, field in ipairs(fields) do
    local lines, inline = field.lines, field.inline
    if inline ~= "" and #lines == 0 then
      table.insert(body, field.name .. ": " .. inline)
    elseif inline == "" and #lines == 1 then
      table.insert(body, field.name .. ": " .. vim.trim(lines[1]))
    elseif #lines > 0 then
      table.insert(body, field.name .. ":" .. (inline ~= "" and " " .. inline or ""))
      vim.list_extend(body, lines)
    end
  end
  if #body > 0 then
    push("```")
    for _, line in ipairs(body) do push(line) end
    push("```", "")
  end
  return i
end

--- Lay loose markdown out by the shared rules.
local function canonical(md)
  local src = vim.split(md, "\n", { plain = true })
  local out, examples = {}, 0
  local function push(...)
    for _, line in ipairs({ ... }) do table.insert(out, line) end
  end

  local i = 1
  while i <= #src do
    local line = src[i]:gsub("%s+$", "")
    local t = vim.trim(line)
    local h = heading_of(t)
    local name = h ~= nil and heading_name(h)

    if t:match("^```") then
      -- Code outside an example passes through; only its language tag goes.
      push("```")
      i = i + 1
      while i <= #src and not vim.trim(src[i]):match("^```") do
        push((src[i]:gsub("%s+$", "")))
        i = i + 1
      end
      push("```")
      i = i + 1
    elseif name == "Example" then
      examples = examples + 1
      i = example(src, i + 1, examples, push)
    else
      if h then
        if name then push("", "# " .. name, "") end
      elseif t:match("^%-%-%-+$") or t:match("^%*+$") then
        -- Rules and stray emphasis markers carry no content.
      elseif t:match(IMAGE) then
        push("", "![](" .. t:match(IMAGE) .. ")", "")
      else
        local lead, rest = lead_heading(t)
        if lead then
          push("", "# " .. lead, "", rest)
        else
          push(line)
        end
      end
      i = i + 1
    end
  end
  return table.concat(out, "\n")
end

-- ------------------------------------------------------------- providers

local ORIGINS = {
  leetcode = "https://leetcode.com",
  neetcode = "https://neetcode.io",
  lintcode = "https://www.lintcode.com",
}

--- NeetCode accordions that only restate `topics` / `company_tags`.
local METADATA = { topics = true, ["company tags"] = true }

---@param meta table provider problem metadata
---@param provider string provider that served `meta`
---@return {body: string, folds: {summary: string, text: string}[]}
function M.normalize(meta, provider)
  local raw = type(meta.description) == "string" and meta.description or ""
  local folds = {}

  if provider == "neetcode" then
    raw = raw:gsub("<details[^>]*>(.-)</details>", function(inner)
      local summary = vim.trim(decode(strip_tags(inner:match("<summary>(.-)</summary>") or "Hint")))
      if not METADATA[summary:lower()] then
        table.insert(folds, { summary = summary, text = (inner:gsub("<summary>.-</summary>", "", 1)) })
      end
      return ""
    end)
  elseif provider == "leetcode" then
    for index, hint in ipairs(type(meta.hints) == "table" and meta.hints or {}) do
      if type(hint) == "string" and vim.trim(hint) ~= "" then
        table.insert(folds, { summary = "Hint " .. index, text = hint })
      end
    end
  end

  local origin = ORIGINS[provider]
  local function markdown(s)
    return canonical(html_to_md(s, origin))
  end
  for _, fold in ipairs(folds) do
    fold.text = markdown(fold.text)
  end
  return { body = markdown(raw), folds = folds }
end

return M
