local api = require("neetcode.api")
local config = require("neetcode.config")
local description = require("neetcode.ui.description")
local hl = require("neetcode.ui.highlight")
local lang_info = require("neetcode.lang")
local progress = require("neetcode.progress")
local results = require("neetcode.ui.results")
local runner = require("neetcode.runner")
local tabs = require("neetcode.ui.tab")
local tests = require("neetcode.ui.tests")
local util = require("neetcode.util")

--- The solving view: description on the left, a real on-disk solution file on
--- the right (so LSP, treesitter and your own keymaps all work normally), and a
--- results panel underneath.
local M = {}

--- One session per open problem tab, keyed by problem id. Opening the same
--- problem again focuses the existing tab instead of splitting another copy.
---@type table<string, table>
local sessions = {}

--- problem ids currently fetching metadata / seeding, so a double <CR> on the
--- list does not open two tabs of the same question.
---@type table<string, boolean>
local opening = {}

local function session_alive(s)
  return s and s.tab and vim.api.nvim_tabpage_is_valid(s.tab)
end

local function session_by_win(win)
  if not win then
    return nil
  end
  for _, s in pairs(sessions) do
    if s.desc_win == win or s.code_win == win or s.res_win == win then
      return s
    end
  end
end

local function current_session()
  local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
  if ok then
    for _, s in pairs(sessions) do
      if s.tab == tab then
        return s
      end
    end
  end
  return session_by_win(vim.api.nvim_get_current_win())
end

local function focus_session(s)
  if not session_alive(s) then
    return false
  end
  vim.api.nvim_set_current_tabpage(s.tab)
  if s.code_win and vim.api.nvim_win_is_valid(s.code_win) then
    vim.api.nvim_set_current_win(s.code_win)
  end
  return true
end

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
local function test_cases(s)
  tests.save(s.path)
  return tests.read(s.path, s.meta.custom_test_cases)
end

local function current_code(s)
  return table.concat(vim.api.nvim_buf_get_lines(s.code_buf, 0, -1, false), "\n")
end

local function save(s)
  if s.code_buf and vim.api.nvim_buf_is_valid(s.code_buf) then
    vim.api.nvim_buf_call(s.code_buf, function()
      if vim.bo.modified then
        vim.cmd("silent write")
      end
    end)
  end
end

--- Is a problem currently open with a live results panel?
local function ready(s)
  s = s or current_session()
  if s and s.res_buf and vim.api.nvim_buf_is_valid(s.res_buf)
    and s.code_buf and vim.api.nvim_buf_is_valid(s.code_buf) then
    return s
  end
  util.err("no problem is open — use :NeetCode to pick one")
  return nil
end

--- image.nvim refuses from_url until setup() has run. Listing it as a
--- lazy.nvim dependency does not call setup, so we do that ourselves when
--- the user never configured it. `false` means we tried and it is unusable.
local image_mod ---@type table|false|nil

local function get_image()
  if image_mod == false then
    return nil
  end
  if image_mod then
    return image_mod
  end
  if not config.options.ui.images then
    image_mod = false
    return nil
  end
  local ok, image = pcall(require, "image")
  if not ok or type(image) ~= "table" or type(image.from_url) ~= "function" then
    image_mod = false
    return nil
  end
  -- clear() is a cheap setup-guard: missing ids are a no-op on a live backend,
  -- and the first successful call also loads kitty/ueberzug so tmux/magick
  -- failures show up here instead of as a blank hole in the statement.
  if not pcall(image.clear, "neetcode-setup-probe") then
    local setup_ok = pcall(image.setup, {
      hijack_file_patterns = {},
      integrations = {
        markdown = { enabled = false },
        neorg = { enabled = false },
        typst = { enabled = false },
        html = { enabled = false },
        css = { enabled = false },
        org = { enabled = false },
        asciidoc = { enabled = false },
        syslang = { enabled = false },
      },
    })
    if not setup_ok or not pcall(image.clear, "neetcode-setup-probe") then
      image_mod = false
      return nil
    end
  end
  image_mod = image
  return image
end

--- Take down whatever image.nvim is currently drawing for us.
local function clear_images(s)
  for _, img in ipairs(s.drawn or {}) do
    pcall(function()
      img:clear()
    end)
  end
  s.drawn = {}
  local image = image_mod ~= false and image_mod or nil
  if image and s.desc_buf and vim.api.nvim_buf_is_valid(s.desc_buf) then
    for _, img in ipairs(image.get_images({ buffer = s.desc_buf }) or {}) do
      pcall(function()
        img:clear()
      end)
    end
  end
end

--- Draw the statement's diagrams inline. image.nvim reserves the rows itself
--- through `with_virtual_padding`, so the surrounding text is never covered.
--- Anything missing here -- the plugin, a capable terminal, ImageMagick --
--- just leaves the 🖼 line, which still opens the diagram on <CR>.
local function render_images(s)
  if vim.tbl_isempty(s.images or {}) then
    return
  end
  local image = get_image()
  if not image then
    return
  end
  if not (s.desc_win and vim.api.nvim_win_is_valid(s.desc_win)
      and s.desc_buf and vim.api.nvim_buf_is_valid(s.desc_buf)) then
    return
  end

  for row, url in pairs(s.images) do
    pcall(image.from_url, url, {
      window = s.desc_win,
      buffer = s.desc_buf,
      x = 2,
      y = row,
      height = config.options.ui.image_max_height,
      with_virtual_padding = true,
      inline = true,
      namespace = "neetcode",
    }, function(img)
      vim.schedule(function()
        if not img then
          return
        end
        if not (s.desc_buf and vim.api.nvim_buf_is_valid(s.desc_buf)) then
          pcall(function()
            img:clear()
          end)
          return
        end
        table.insert(s.drawn, img)
        pcall(function()
          img:render()
        end)
      end)
    end)
  end
end

local function render_description(s)
  clear_images(s)
  s.folds, s.images, s.links = description.render(
    s.desc_buf, s.problem, s.meta, s.sections,
    { solved = progress.is_solved(s.problem) })
  render_images(s)
end

function M.tests()
  local s = ready()
  if s then tests.open(s.path, s.meta.custom_test_cases) end
end

function M.test_failed()
  local s = ready()
  if not s then return end
  if not s.failed_input then return util.err("no failed submission input available") end
  tests.open(s.path, s.meta.custom_test_cases, s.failed_input)
end

function M.run()
  local s = ready()
  if not s then
    return
  end
  if s.busy then
    return util.notify("already running")
  end
  save(s)

  local cases = test_cases(s)
  s.busy = true
  results.running(s.res_buf, "Running " .. #cases .. " local test case" .. (#cases == 1 and "" or "s"))

  runner.run(s.problem.id, current_code(s), s.lang, s.meta, cases, function(result)
    s.busy = false
    vim.schedule(function()
      if s.res_buf and vim.api.nvim_buf_is_valid(s.res_buf) then
        results.render_run(s.res_buf, result)
      end
    end)
  end)
end

function M.submit()
  local s = ready()
  if not s then
    return
  end
  if s.busy then
    return util.notify("already running")
  end
  save(s)

  s.busy = true
  results.running(s.res_buf, "Submitting to NeetCode")

  api.submit(s.problem.id, current_code(s), s.lang, function(err, data)
    s.busy = false
    vim.schedule(function()
      if not (s.res_buf and vim.api.nvim_buf_is_valid(s.res_buf)) then
        return
      end
      if err then
        return results.render_run(s.res_buf, { ok = false, error = err, cases = {}, passed = 0, total = 0 })
      end

      local failing = data.last_executed_test_case
      s.failed_input = nil
      if (not data.status or data.status.description ~= "Accepted")
        and type(failing) == "table" and type(failing.input) == "string"
        and vim.trim(failing.input) ~= "" then
        s.failed_input = failing.input
      end
      results.render_submit(s.res_buf, data)

      if data.status and data.status.description == "Accepted" then
        util.notify(s.problem.name .. " accepted 🎉")
        -- The backend records the solve itself; mirror it locally so the
        -- roadmap updates without waiting for a refetch.
        progress.mark(s.problem, function() end)
        pcall(render_description, s)
        pcall(function()
          require("neetcode.ui.roadmap").refresh()
        end)
      end
    end)
  end)
end

--- Toggle the open problem as completed on neetcode.io.
function M.toggle_complete()
  local s = ready()
  if not s then
    return
  end
  progress.toggle(s.problem, function(err, solved)
    vim.schedule(function()
      if err then
        return util.err(err)
      end
      util.notify(s.problem.name .. (solved and " marked complete" or " marked incomplete"))
      pcall(render_description, s)
      pcall(function()
        require("neetcode.ui.roadmap").refresh()
      end)
    end)
  end)
end

--- Push the current buffer up to neetcode.io so the web editor matches.
function M.push()
  local s = current_session()
  if not s then
    return util.err("no problem is open — use :NeetCode to pick one")
  end
  save(s)
  api.save_user_code(s.problem.id, s.lang, current_code(s), function(err)
    vim.schedule(function()
      if err then
        util.err("could not sync code: " .. err)
      else
        util.notify("code pushed to neetcode.io")
      end
    end)
  end)
end

local function drop_session(s)
  if not s or not s.problem then
    return
  end
  sessions[s.problem.id] = nil
  if s.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
    s.augroup = nil
  end
end

function M.close(s)
  s = s or current_session()
  if not s or s.closing then
    return
  end
  s.closing = true
  pcall(clear_images, s)
  pcall(save, s)
  local tab = s.tab
  drop_session(s)
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    if #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tab) .. "tabclose")
    else
      -- Last tab cannot be closed; collapse the layout to an empty buffer.
      pcall(vim.api.nvim_set_current_tabpage, tab)
      pcall(vim.cmd, "enew")
      local keep = vim.api.nvim_get_current_win()
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if win ~= keep then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
  end
end

--- Floating windows (LSP hover, signature help, the roadmap, image.nvim,
--- nvim-notify, completion docs, …) share a problem tab but are not part of
--- the three-pane layout. Closing one must not take the problem down with it.
local function is_float(win)
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  return ok and cfg.relative ~= nil and cfg.relative ~= ""
end

local watched = false
local function ensure_watchers()
  if watched then
    return
  end
  watched = true
  local group = vim.api.nvim_create_augroup("NeetCodeProblemLifecycle", { clear = true })
  -- Closing a layout pane (description / code / results) tears the whole tab
  -- down so you are never left with a half-open problem view. Other windows
  -- in the tab are ignored — see is_float().
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if not win or is_float(win) then
        return
      end
      local s = session_by_win(win)
      if s and not s.closing then
        vim.schedule(function()
          if not s.closing then
            M.close(s)
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      vim.schedule(function()
        for id, s in pairs(sessions) do
          if not session_alive(s) then
            s.closing = true
            pcall(clear_images, s)
            sessions[id] = nil
          end
        end
      end)
    end,
  })
end


--- The link under the cursor. A line can hold several -- Find Median links to
--- both "median" and "mean" -- so the column decides which one.
local function link_at(s, row, col)
  local spans = s.links and s.links[row]
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
local function activate(s)
  local cursor = vim.api.nvim_win_get_cursor(s.desc_win)
  local row, col = cursor[1] - 1, cursor[2]

  local url = link_at(s, row, col)
  if url then
    return vim.ui.open(url)
  end

  local section = s.folds and s.folds[row]
  if not section then
    return
  end
  section.open = not section.open
  render_description(s)
  pcall(vim.api.nvim_win_set_cursor, s.desc_win, { row + 1, 0 })
end

local function keymaps(s)
  local keys = config.options.keys.problem
  for _, buf in ipairs({ s.code_buf, s.desc_buf, s.res_buf }) do
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, desc = desc })
    end
    map(keys.run, M.run, "neetcode: run local tests")
    map(keys.submit, M.submit, "neetcode: submit to NeetCode")
    map(keys.tests, M.tests, "neetcode: edit test cases")
    map(keys.test_failed, M.test_failed, "neetcode: add failed submission case")
    map(keys.complete, M.toggle_complete, "neetcode: toggle completed")
    -- A problem tab is one unit: closing a split closes the tab.
    map("<C-w>c", function() M.close(s) end, "neetcode: close problem")
    map("<C-w>q", function() M.close(s) end, "neetcode: close problem")
    map("<C-w>o", function() M.close(s) end, "neetcode: close problem")
  end

  for _, buf in ipairs({ s.desc_buf, s.res_buf }) do
    vim.keymap.set("n", keys.quit, function() M.close(s) end,
      { buffer = buf, silent = true, desc = "neetcode: close problem" })
  end

  for _, lhs in ipairs({ "<CR>", "<Tab>" }) do
    vim.keymap.set("n", lhs, function() activate(s) end,
      { buffer = s.desc_buf, silent = true, desc = "neetcode: open hint or diagram" })
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

--- Quote a YAML scalar when it isn't a plain token (paths with spaces, etc.).
local function yaml_scalar(s)
  if s:match("^%-?[%w_./+=]+$") then
    return s
  end
  return "'" .. s:gsub("'", "''") .. "'"
end

--- Language-server flags from `runner.cpp.cmd`: drop the compiler, `-o` /
--- `{out}` / `{source}`, and the input file, so clangd uses the same language
--- mode the local runner compiles with.
local function clangd_from_cmd(cmd)
  cmd = cmd or {}
  local compiler = cmd[1]
  local flags = {}
  local skip_next = false
  for i, arg in ipairs(cmd) do
    if i == 1 or skip_next then
      skip_next = false
    elseif arg == "-o" then
      skip_next = true
    elseif arg:find("{out}", 1, true) or arg:find("{source}", 1, true) then
      -- combined -o{out}, or the placeholders themselves
    elseif arg:match("%.[cC]$")
      or arg:match("%.[cC][cC]$")
      or arg:match("%.[cC][pP][pP]$")
      or arg:match("%.[cC][xX][xX]$")
    then
      -- source file given as a literal
    else
      table.insert(flags, arg)
    end
  end
  return compiler, flags
end

local function clangd_path()
  return config.options.solutions_dir .. "/.clangd"
end

--- Language-mode flags clangd must see to match the runner (std, stdlib, …).
local function clangd_lang_flags(flags)
  local out = {}
  for _, flag in ipairs(flags or {}) do
    if flag:match("^%-std=") or flag:match("^%-%-std=") or flag:match("^%-stdlib=") then
      table.insert(out, flag)
    end
  end
  return out
end

--- A third-party `.clangd` is incorrect when it would parse with a different
--- language mode than `runner.cpp.cmd`.
local function clangd_disagrees_with_cmd(existing)
  local _, flags = clangd_from_cmd(config.options.runner.cpp.cmd)
  local want_std
  for _, flag in ipairs(clangd_lang_flags(flags)) do
    if not existing:find(flag, 1, true) then
      return true
    end
    want_std = want_std or flag:match("%-std=.+")
  end
  -- Leftover conflicting `-std=` (e.g. c++17 still present while cmd is c++23).
  if want_std then
    for std in existing:gmatch("%-std=[%w%+%d]+") do
      if std ~= want_std then
        return true
      end
    end
  end
  return false
end

--- Rebuild `.clangd` from whatever per-problem headers exist on disk, so the
--- file stays consistent however many problems have been opened.
local function clangd_body()
  local dir = support_dir()
  local compiler, flags = clangd_from_cmd(config.options.runner.cpp.cmd)
  local fragments = {
    "# " .. CLANGD_MARKER .. " -- delete this file to opt out.",
    "CompileFlags:",
  }
  if compiler and compiler ~= "" then
    table.insert(fragments, "  Compiler: " .. yaml_scalar(compiler))
  end
  table.insert(fragments, "  Add:")
  for _, flag in ipairs(flags) do
    table.insert(fragments, "    - " .. yaml_scalar(flag))
  end
  vim.list_extend(fragments, {
    "    - -include",
    "    - " .. yaml_scalar(dir .. "/prelude.h"),
  })

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
        "    - " .. yaml_scalar(path),
      })
    end
  end

  return table.concat(fragments, "\n") .. "\n"
end

local function rebuild_clangd(existing)
  local body = clangd_body()
  if existing ~= body then
    util.write_file(clangd_path(), body)
  end
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

  local existing = util.read_file(clangd_path())
  -- A third-party `.clangd` that already matches `runner.cpp.cmd` is left
  -- alone. Ours, a missing file, or one with the wrong language mode is not.
  if existing
    and not existing:find(CLANGD_MARKER, 1, true)
    and not clangd_disagrees_with_cmd(existing)
  then
    return
  end

  local dir = support_dir()
  util.mkdirp(dir)

  local comments = util.read_file(harness_file("cpp_prelude.h"))
  local stdlib = util.read_file(harness_file("cpp_stdlib.h"))
  if not comments or not stdlib then
    return
  end
  util.write_file(dir .. "/prelude.h", comments .. "\n" .. stdlib .. "\nusing namespace std;\n")

  write_types(dir, problem_id, starter)
  backfill_types(dir)
  rebuild_clangd(existing)
end

--- Seed the solution file: prefer code already saved on neetcode.io, else the
--- official starter code.
local function seed_file(s, path, cb)
  local starter = (s.meta.starterCode or {})[s.lang] or ""

  if s.lang == "cpp" then
    ensure_clangd(s.problem.id, starter)
  end

  if vim.uv.fs_stat(path) then
    return cb()
  end

  api.user_code(s.problem.id, function(err, data)
    local code = nil
    if not err and type(data) == "table" then
      local code_tabs = data.tabs or (data.code and { { code = data.code } })
      if type(code_tabs) == "table" and code_tabs[1] and type(code_tabs[1].code) == "string" then
        if data.lang == nil or data.lang == s.lang then
          code = code_tabs[1].code
        end
      end
    end
    util.write_file(path, (code and code ~= "" and code) or starter)
    vim.schedule(cb)
  end)
end

local function build_windows(s)
  vim.cmd("tabnew")
  s.tab = vim.api.nvim_get_current_tabpage()
  tabs.set(s.tab, s.problem.name)
  sessions[s.problem.id] = s

  -- Left: description. Reuse the tabnew buffer so it isn't left listed as
  -- [No Name]/[Scratch] in the tabline.
  s.desc_win = vim.api.nvim_get_current_win()
  s.desc_buf = vim.api.nvim_get_current_buf()
  vim.bo[s.desc_buf].buftype = "nofile"
  vim.bo[s.desc_buf].bufhidden = "wipe"
  vim.bo[s.desc_buf].swapfile = false
  vim.bo[s.desc_buf].buflisted = false
  vim.bo[s.desc_buf].filetype = "neetcode-problem"
  vim.bo[s.desc_buf].modified = false
  tabs.name_buffer(s.desc_buf, s.problem.name)
  vim.wo[s.desc_win].wrap = true
  vim.wo[s.desc_win].linebreak = true
  vim.wo[s.desc_win].breakindent = true
  -- `breakindent` alone keeps a wrapped line flush with its own indent;
  -- a showbreak string would push every continuation further right.
  vim.wo[s.desc_win].showbreak = ""
  vim.wo[s.desc_win].conceallevel = 2
  vim.wo[s.desc_win].concealcursor = "nvic"
  vim.wo[s.desc_win].number = false
  vim.wo[s.desc_win].relativenumber = false
  vim.wo[s.desc_win].signcolumn = "no"

  -- Right: the solution file itself.
  vim.cmd("botright vsplit " .. vim.fn.fnameescape(s.path))
  s.code_win = vim.api.nvim_get_current_win()
  s.code_buf = vim.api.nvim_get_current_buf()
  vim.bo[s.code_buf].filetype = lang_info.filetype(s.lang)

  -- Below the solution: results.
  vim.cmd("belowright split")
  s.res_win = vim.api.nvim_get_current_win()
  s.res_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(s.res_win, s.res_buf)
  vim.bo[s.res_buf].filetype = "neetcode-results"
  vim.bo[s.res_buf].bufhidden = "wipe"
  vim.bo[s.res_buf].modifiable = false
  vim.wo[s.res_win].number = false
  vim.wo[s.res_win].relativenumber = false
  vim.wo[s.res_win].signcolumn = "no"
  vim.wo[s.res_win].wrap = false

  vim.api.nvim_win_set_width(s.desc_win, math.floor(vim.o.columns * 0.42))
  vim.api.nvim_win_set_height(s.res_win, math.min(14, math.floor(vim.o.lines * 0.35)))

  vim.api.nvim_set_current_win(s.code_win)

  -- Image geometry is in cells, so a resize invalidates it.
  s.augroup = vim.api.nvim_create_augroup("NeetCodeProblemImages_" .. s.problem.id, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = s.augroup,
    buffer = s.desc_buf,
    callback = function()
      for _, img in ipairs(s.drawn or {}) do
        pcall(function()
          img:render()
        end)
      end
    end,
  })
  ensure_watchers()
end

---@param problem table catalog entry
---@param opts table|nil lang
function M.open(problem, opts)
  opts = opts or {}
  local existing = sessions[problem.id]
  if session_alive(existing) then
    focus_session(existing)
    return
  end
  if opening[problem.id] then
    return
  end

  local lang = opts.lang or config.options.lang

  opening[problem.id] = true
  util.notify("loading " .. problem.name .. "…")
  fetch_meta(problem.id, function(err, meta)
    vim.schedule(function()
      if err then
        opening[problem.id] = nil
        return util.err("could not load problem: " .. err)
      end
      if session_alive(sessions[problem.id]) then
        opening[problem.id] = nil
        focus_session(sessions[problem.id])
        return
      end

      local available = meta.availableLanguages or {}
      if #available > 0 and not vim.tbl_contains(available, lang) then
        util.notify(string.format(
          "%s is not available for this problem; falling back to %s",
          lang_info.name(lang), lang_info.name(available[1])))
        lang = available[1]
      end

      local s = {
        problem = problem,
        meta = meta,
        sections = description.sections(meta.description),
        lang = lang,
        path = solution_path(problem, lang),
        busy = false,
        drawn = {},
      }
      util.mkdirp(vim.fs.dirname(s.path))

      seed_file(s, s.path, function()
        if session_alive(sessions[problem.id]) then
          opening[problem.id] = nil
          focus_session(sessions[problem.id])
          return
        end
        build_windows(s)
        opening[problem.id] = nil
        render_description(s)
        keymaps(s)

        local keys = config.options.keys.problem
        vim.bo[s.res_buf].modifiable = true
        vim.api.nvim_buf_set_lines(s.res_buf, 0, -1, false, {
          "",
          string.format("  %s  run local tests      %s  submit to NeetCode", keys.run, keys.submit),
          string.format("  %s  edit test cases      %s  add failed submission case", keys.tests, keys.test_failed),
          "",
          string.format("  %d visible test case(s) · %d hidden",
            #test_cases(s), meta.test_case_count or 0),
          "",
          "  Local runs diff your output against NeetCode's reference solution.",
          "  Submitting runs the full hidden suite in the cloud.",
          "",
          "  <CR> in the statement opens a ▸ hint or a 🖼 diagram.",
        })
        vim.bo[s.res_buf].modifiable = false
        hl.apply(s.res_buf, {
          { 1, 0, 80, "NeetCodeKey" },
          { 2, 0, 100, "NeetCodeKey" },
          { 4, 0, 80, "NeetCodeMuted" },
          { 6, 0, 80, "NeetCodeMuted" },
          { 7, 0, 80, "NeetCodeMuted" },
          { 9, 0, 80, "NeetCodeMuted" },
        })
      end)
    end)
  end)
end

return M
