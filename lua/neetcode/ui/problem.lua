local api = require("neetcode.api")
local config = require("neetcode.config")
local description = require("neetcode.ui.description")
local hl = require("neetcode.ui.highlight")
local lang_info = require("neetcode.lang")
local progress = require("neetcode.progress")
local results = require("neetcode.ui.results")
local runner = require("neetcode.runner")
local tabs = require("neetcode.ui.tab")
local util = require("neetcode.util")

--- The solving view: description on the left, a real on-disk solution file on
--- the right (so LSP, treesitter and your own keymaps all work normally), and a
--- results panel underneath.
local M = {}

local state = {
  problem = nil, meta = nil, lang = nil,
  tab = nil, desc_win = nil, code_win = nil, res_win = nil,
  desc_buf = nil, code_buf = nil, res_buf = nil,
  path = nil, busy = false, sections = nil, folds = nil, images = nil, links = nil,
  drawn = {},
}

local function meta_cache_path(id)
  return string.format("%s/meta/%s.json", config.options.cache_dir, id)
end

--- Problem metadata, from cache when present. Metadata is effectively static,
--- so a cached copy is refreshed only when the user asks for a sync.
local function fetch_meta(id, cb)
  local cached = util.read_json(meta_cache_path(id))
  if cached then
    return cb(nil, cached)
  end
  api.problem(id, function(err, meta)
    if err then
      return cb(err, nil)
    end
    util.write_json(meta_cache_path(id), meta)
    cb(nil, meta)
  end)
end

local function solution_path(problem, lang)
  return string.format("%s/%s/%s.%s",
    config.options.solutions_dir,
    util.slug(problem.pattern),
    problem.id,
    lang_info.ext(lang))
end

--- Extra test cases the user has written, stored alongside the solution.
local function user_test_cases(path)
  local raw = util.read_file(path .. ".tests")
  if not raw then
    return {}
  end
  local out = {}
  for _, blockdata in ipairs(vim.split(raw, "\n---\n", { plain = true })) do
    local trimmed = vim.trim(blockdata)
    if trimmed ~= "" then
      table.insert(out, trimmed)
    end
  end
  return out
end

local function test_cases()
  local cases = {}
  for _, c in ipairs(state.meta.custom_test_cases or {}) do
    table.insert(cases, c)
  end
  for _, c in ipairs(user_test_cases(state.path)) do
    table.insert(cases, c)
  end
  return cases
end

local function current_code()
  return table.concat(vim.api.nvim_buf_get_lines(state.code_buf, 0, -1, false), "\n")
end

local function save()
  if state.code_buf and vim.api.nvim_buf_is_valid(state.code_buf) then
    vim.api.nvim_buf_call(state.code_buf, function()
      if vim.bo.modified then
        vim.cmd("silent write")
      end
    end)
  end
end

--- Is a problem currently open with a live results panel?
local function ready()
  if state.res_buf and vim.api.nvim_buf_is_valid(state.res_buf)
    and state.code_buf and vim.api.nvim_buf_is_valid(state.code_buf) then
    return true
  end
  util.err("no problem is open — use :NeetCode to pick one")
  return false
end

--- Take down whatever image.nvim is currently drawing for us.
local function clear_images()
  for _, img in ipairs(state.drawn) do
    pcall(function()
      img:clear()
    end)
  end
  state.drawn = {}
end

--- Draw the statement's diagrams inline. image.nvim reserves the rows itself
--- through `with_virtual_padding`, so the surrounding text is never covered.
--- Anything missing here -- the plugin, a capable terminal, ImageMagick --
--- just leaves the 🖼 line, which still opens the diagram on <CR>.
--- Can diagrams be drawn in place? Decides whether they get a label instead.
local function inline_images()
  if not config.options.ui.images then
    return false
  end
  return (pcall(require, "image"))
end

local function render_images()
  if not config.options.ui.images or vim.tbl_isempty(state.images or {}) then
    return
  end
  local ok, image = pcall(require, "image")
  if not ok then
    return
  end

  for row, url in pairs(state.images) do
    pcall(image.from_url, url, {
      window = state.desc_win,
      buffer = state.desc_buf,
      x = 2,
      y = row,
      with_virtual_padding = true,
      max_height = config.options.ui.image_max_height,
    }, function(img)
      if not img then
        return
      end
      table.insert(state.drawn, img)
      pcall(function()
        img:render()
      end)
    end)
  end
end

local function render_description()
  clear_images()
  state.folds, state.images, state.links = description.render(
    state.desc_buf, state.problem, state.meta, state.sections,
    { solved = progress.is_solved(state.problem), inline_images = inline_images() })
  render_images()
end

function M.run()
  if state.busy then
    return util.notify("already running")
  end
  if not ready() then
    return
  end
  save()

  local cases = test_cases()
  state.busy = true
  results.running(state.res_buf, "Running " .. #cases .. " local test case" .. (#cases == 1 and "" or "s"))

  runner.run(state.problem.id, current_code(), state.lang, state.meta, cases, function(result)
    state.busy = false
    vim.schedule(function()
      if state.res_buf and vim.api.nvim_buf_is_valid(state.res_buf) then
        results.render_run(state.res_buf, result)
      end
    end)
  end)
end

function M.submit()
  if state.busy then
    return util.notify("already running")
  end
  if not ready() then
    return
  end
  save()

  state.busy = true
  results.running(state.res_buf, "Submitting to NeetCode")

  api.submit(state.problem.id, current_code(), state.lang, function(err, data)
    state.busy = false
    vim.schedule(function()
      if not (state.res_buf and vim.api.nvim_buf_is_valid(state.res_buf)) then
        return
      end
      if err then
        return results.render_run(state.res_buf, { ok = false, error = err, cases = {}, passed = 0, total = 0 })
      end

      results.render_submit(state.res_buf, data)

      if data.status and data.status.description == "Accepted" then
        util.notify(state.problem.name .. " accepted 🎉")
        -- The backend records the solve itself; mirror it locally so the
        -- roadmap updates without waiting for a refetch.
        progress.mark(state.problem, function() end)
        pcall(render_description)
        pcall(function()
          require("neetcode.ui.roadmap").refresh()
        end)
      end
    end)
  end)
end

--- Push the current buffer up to neetcode.io so the web editor matches.
function M.push()
  save()
  api.save_user_code(state.problem.id, state.lang, current_code(), function(err)
    vim.schedule(function()
      if err then
        util.err("could not sync code: " .. err)
      else
        util.notify("code pushed to neetcode.io")
      end
    end)
  end)
end

function M.close()
  clear_images()
  if state.tab and vim.api.nvim_tabpage_is_valid(state.tab) then
    save()
    vim.cmd("tabclose")
  end
  state.tab = nil
end


--- The link under the cursor. A line can hold several -- Find Median links to
--- both "median" and "mean" -- so the column decides which one.
local function link_at(row, col)
  local spans = state.links and state.links[row]
  if not spans then
    return nil
  end
  for _, span in ipairs(spans) do
    if col >= span.from and col < span.to then
      return span.url
    end
  end
  -- Off the label, but an unambiguous line still follows from anywhere on it.
  if #spans == 1 then
    return spans[1].url
  end
  return nil
end

--- <CR> in the statement: follow the link under the cursor -- an inline link, a
--- diagram or a footer link -- or toggle the hint accordion under it.
local function activate()
  local cursor = vim.api.nvim_win_get_cursor(state.desc_win)
  local row, col = cursor[1] - 1, cursor[2]

  local url = link_at(row, col)
  if url then
    return vim.ui.open(url)
  end

  local section = state.folds and state.folds[row]
  if not section then
    return
  end
  section.open = not section.open
  render_description()
  pcall(vim.api.nvim_win_set_cursor, state.desc_win, { row + 1, 0 })
end

local function keymaps()
  local keys = config.options.keys.problem
  for _, buf in ipairs({ state.code_buf, state.desc_buf, state.res_buf }) do
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, desc = desc })
    end
    map(keys.run, M.run, "neetcode: run local tests")
    map(keys.submit, M.submit, "neetcode: submit to NeetCode")
  end

  for _, buf in ipairs({ state.desc_buf, state.res_buf }) do
    vim.keymap.set("n", config.options.keys.problem.quit, M.close,
      { buffer = buf, silent = true, desc = "neetcode: close problem" })
  end

  for _, lhs in ipairs({ "<CR>", "<Tab>" }) do
    vim.keymap.set("n", lhs, activate,
      { buffer = state.desc_buf, silent = true, desc = "neetcode: open hint or diagram" })
  end
end

local function harness_file(name)
  local this = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(this)) .. "/runner/harness/" .. name
end

--- Teach a language server what NeetCode's judge supplies implicitly.
---
--- The starter code has no #includes and no node-type definitions, so clangd
--- reports errors on solutions that are perfectly valid. A `.clangd` beside the
--- solutions force-includes a shared header carrying the standard library, plus
--- a per-problem header carrying that problem's own helper types. Nothing here
--- reaches the judge, and your solution file is left exactly as you wrote it.
local CLANGD_MARKER = "Written by neetcode.nvim"

local function support_dir()
  return config.options.solutions_dir .. "/.neetcode"
end

--- Rebuild `.clangd` from whatever per-problem headers exist on disk, so the
--- file stays consistent however many problems have been opened.
local function rebuild_clangd()
  local dir = support_dir()
  local fragments = {
    "# " .. CLANGD_MARKER .. " -- delete this file to opt out.",
    "CompileFlags:",
    "  Add:",
    "    - -std=c++17",
    "    - -include",
    "    - " .. dir .. "/prelude.h",
  }

  local entries = vim.fn.glob(dir .. "/*.h", false, true)
  table.sort(entries)
  for _, path in ipairs(entries) do
    local id = vim.fn.fnamemodify(path, ":t:r")
    if id ~= "prelude" then
      -- PathMatch is a regex over the whole path; ids are kebab-case, but
      -- escape anyway rather than trusting that.
      local pattern = id:gsub("[%^%$%(%)%%%.%[%]%*%+%?]", "\\%0")
      vim.list_extend(fragments, {
        "---",
        "If:",
        "  PathMatch: .*/" .. pattern .. "\\.cpp",
        "CompileFlags:",
        "  Add:",
        "    - -include",
        "    - " .. path,
      })
    end
  end

  util.write_file(dir .. "/../.clangd", table.concat(fragments, "\n") .. "\n")
end

--- Write a header holding one problem's own helper types, if it declares any.
local function write_types(dir, problem_id, starter)
  local types = require("neetcode.runner.cpp").starter_types(starter)
  if #types == 0 then
    return
  end
  local body = {
    "// " .. CLANGD_MARKER .. ", from this problem's starter code.",
    "#pragma once",
    '#include "prelude.h"',
    "",
  }
  for _, t in ipairs(types) do
    table.insert(body, t.source)
    table.insert(body, "")
  end
  util.write_file(dir .. "/" .. problem_id .. ".h", table.concat(body, "\n"))
end

--- Cover solutions seeded before now, so the config is right for every file
--- present rather than only the one being opened. Problem metadata is cached,
--- so this costs a few small reads and no network.
local function backfill_types(dir)
  local pattern = config.options.solutions_dir .. "/*/*.cpp"
  for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
    local id = vim.fn.fnamemodify(path, ":t:r")
    if not vim.uv.fs_stat(dir .. "/" .. id .. ".h") then
      local cached = util.read_json(meta_cache_path(id))
      local starter = cached and (cached.starterCode or {}).cpp
      if starter then
        write_types(dir, id, starter)
      end
    end
  end
end

--- Write the shared prelude and, when the starter documents helper types, a
--- header holding that problem's own copies of them.
local function ensure_clangd(problem_id, starter)
  if not config.options.runner.cpp.clangd then
    return
  end

  local existing = util.read_file(config.options.solutions_dir .. "/.clangd")
  if existing and not existing:find(CLANGD_MARKER, 1, true) then
    -- Someone else's configuration; leave it be.
    return
  end

  local dir = support_dir()
  util.mkdirp(dir)

  local base = util.read_file(harness_file("cpp_prelude.h"))
  if not base then
    return
  end
  util.write_file(dir .. "/prelude.h", base)

  write_types(dir, problem_id, starter)
  backfill_types(dir)
  rebuild_clangd()
end

--- Seed the solution file: prefer code already saved on neetcode.io, else the
--- official starter code.
local function seed_file(path, cb)
  local starter = (state.meta.starterCode or {})[state.lang] or ""

  if state.lang == "cpp" then
    ensure_clangd(state.problem.id, starter)
  end

  if vim.uv.fs_stat(path) then
    return cb()
  end

  api.user_code(state.problem.id, function(err, data)
    local code = nil
    if not err and type(data) == "table" then
      local tabs = data.tabs or (data.code and { { code = data.code } })
      if type(tabs) == "table" and tabs[1] and type(tabs[1].code) == "string" then
        if data.lang == nil or data.lang == state.lang then
          code = tabs[1].code
        end
      end
    end
    util.write_file(path, (code and code ~= "" and code) or starter)
    vim.schedule(cb)
  end)
end

local function build_windows()
  vim.cmd("tabnew")
  state.tab = vim.api.nvim_get_current_tabpage()
  tabs.set(state.tab, state.problem.name)

  -- Left: description. Reuse the tabnew buffer so it isn't left listed as
  -- [No Name]/[Scratch] in the tabline.
  state.desc_win = vim.api.nvim_get_current_win()
  state.desc_buf = vim.api.nvim_get_current_buf()
  vim.bo[state.desc_buf].buftype = "nofile"
  vim.bo[state.desc_buf].bufhidden = "wipe"
  vim.bo[state.desc_buf].swapfile = false
  vim.bo[state.desc_buf].buflisted = false
  vim.bo[state.desc_buf].filetype = "neetcode-problem"
  vim.bo[state.desc_buf].modified = false
  tabs.name_buffer(state.desc_buf, state.problem.name)
  vim.wo[state.desc_win].wrap = true
  vim.wo[state.desc_win].linebreak = true
  vim.wo[state.desc_win].breakindent = true
  -- `breakindent` alone keeps a wrapped line flush with its own indent;
  -- a showbreak string would push every continuation further right.
  vim.wo[state.desc_win].showbreak = ""
  vim.wo[state.desc_win].conceallevel = 2
  vim.wo[state.desc_win].concealcursor = "nvic"
  vim.wo[state.desc_win].number = false
  vim.wo[state.desc_win].relativenumber = false
  vim.wo[state.desc_win].signcolumn = "no"

  -- Right: the solution file itself.
  vim.cmd("botright vsplit " .. vim.fn.fnameescape(state.path))
  state.code_win = vim.api.nvim_get_current_win()
  state.code_buf = vim.api.nvim_get_current_buf()
  vim.bo[state.code_buf].filetype = lang_info.filetype(state.lang)

  -- Below the solution: results.
  vim.cmd("belowright split")
  state.res_win = vim.api.nvim_get_current_win()
  state.res_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.res_win, state.res_buf)
  vim.bo[state.res_buf].filetype = "neetcode-results"
  vim.bo[state.res_buf].bufhidden = "wipe"
  vim.bo[state.res_buf].modifiable = false
  vim.wo[state.res_win].number = false
  vim.wo[state.res_win].relativenumber = false
  vim.wo[state.res_win].signcolumn = "no"
  vim.wo[state.res_win].wrap = false

  vim.api.nvim_win_set_width(state.desc_win, math.floor(vim.o.columns * 0.42))
  vim.api.nvim_win_set_height(state.res_win, math.min(14, math.floor(vim.o.lines * 0.35)))

  vim.api.nvim_set_current_win(state.code_win)

  -- Image geometry is in cells, so a resize invalidates it.
  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("NeetCodeProblemImages", { clear = true }),
    buffer = state.desc_buf,
    callback = render_images,
  })
end

---@param problem table catalog entry
---@param opts table|nil lang
function M.open(problem, opts)
  opts = opts or {}
  local lang = opts.lang or config.options.lang

  util.notify("loading " .. problem.name .. "…")
  fetch_meta(problem.id, function(err, meta)
    vim.schedule(function()
      if err then
        return util.err("could not load problem: " .. err)
      end

      local available = meta.availableLanguages or {}
      if #available > 0 and not vim.tbl_contains(available, lang) then
        util.notify(string.format(
          "%s is not available for this problem; falling back to %s",
          lang_info.name(lang), lang_info.name(available[1])))
        lang = available[1]
      end

      state.problem = problem
      state.meta = meta
      state.sections = description.sections(meta.description)
      state.lang = lang
      state.path = solution_path(problem, lang)
      util.mkdirp(vim.fs.dirname(state.path))

      seed_file(state.path, function()
        build_windows()
        render_description()
        keymaps()

        local keys = config.options.keys.problem
        vim.bo[state.res_buf].modifiable = true
        vim.api.nvim_buf_set_lines(state.res_buf, 0, -1, false, {
          "",
          string.format("  %s  run local tests      %s  submit to NeetCode", keys.run, keys.submit),
          "",
          string.format("  %d visible test case(s) · %d hidden",
            #test_cases(), meta.test_case_count or 0),
          "",
          "  Local runs diff your output against NeetCode's reference solution.",
          "  Submitting runs the full hidden suite in the cloud.",
          "",
          "  <CR> in the statement opens a ▸ hint or a 🖼 diagram.",
        })
        vim.bo[state.res_buf].modifiable = false
        hl.apply(state.res_buf, {
          { 1, 0, 80, "NeetCodeKey" },
          { 3, 0, 80, "NeetCodeMuted" },
          { 5, 0, 80, "NeetCodeMuted" },
          { 6, 0, 80, "NeetCodeMuted" },
          { 8, 0, 80, "NeetCodeMuted" },
        })
      end)
    end)
  end)
end

return M
