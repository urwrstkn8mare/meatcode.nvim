local providers = require("meatcode.providers")
local problem_catalog = require("meatcode.catalog.problems")
local config = require("meatcode.config")
local description = require("meatcode.ui.description")
local hl = require("meatcode.ui.highlight")
local lang_info = require("meatcode.lang")
local pages = require("meatcode.ui.pages")
local progress = require("meatcode.progress")
local results = require("meatcode.ui.results")
local runner = require("meatcode.runner")
local tabs = require("meatcode.ui.tab")
local tests = require("meatcode.ui.tests")
local util = require("meatcode.util")

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

local function session_key(problem)
  return providers.problem_key(problem)
end

local function meta_cache_path(provider, id)
  return string.format("%s/meta/%s-%s.json", config.options.cache_dir, provider, id)
end

local function union(left, right)
  local out, seen = {}, {}
  for _, list in ipairs({ left or {}, right or {} }) do
    for _, value in ipairs(list) do
      local name = type(value) == "table" and value.name or value
      if type(name) == "string" and name ~= "" and not seen[name:lower()] then
        seen[name:lower()] = true
        table.insert(out, name)
      end
    end
  end
  table.sort(out, function(a, b) return a:lower() < b:lower() end)
  return out
end

local function attach_problem_metadata(problem, meta)
  problem.topics = union(problem.topics, meta.topics)
  problem.companies = union(problem.companies, meta.companies)
end

local function fetch_provider_meta(problem, provider_name, lang, cb, status)
  providers.ensure_id(problem, provider_name, function(resolve_err, id)
    if resolve_err then return cb(resolve_err, nil) end
    if not id then return cb("problem is unavailable on " .. providers.get(provider_name).label, nil) end
    if provider_name == "lintcode" then
      local leetcode_id = providers.id(problem, "leetcode")
      if leetcode_id then problem_catalog.remember_lintcode(leetcode_id, id) end
    end

    local path = meta_cache_path(provider_name, id)
    local cached = util.read_json(path)
    local backend = providers.get(provider_name)
    local has_lang = cached and type(cached.starterCode) == "table"
      and type(cached.starterCode[lang]) == "string"
    local has_sources = provider_name == "neetcode"
      or provider_name == "leetcode"
        and type(cached and cached.editorial_solutions) == "table"
        and cached.editorial_solutions[lang] ~= nil
        and type(cached.community_solutions) == "table"
        and cached.community_solutions[lang] ~= nil
      or provider_name == "lintcode"
        and type(cached and cached.community_solutions) == "table"
        and cached.community_solutions[lang] ~= nil
    if cached and cached.schema == util.META_SCHEMA and has_lang and has_sources then
      if status then status("Using cached " .. backend.label .. " metadata and oracle candidates.") end
      attach_problem_metadata(problem, cached)
      return cb(nil, cached)
    end
    backend.fetch(problem, lang, function(err, meta)
      if err then return cb(err, nil) end
      local function finish(enrich_err)
        if enrich_err then return cb(enrich_err, nil) end
        util.write_json(path, meta)
        attach_problem_metadata(problem, meta)
        cb(nil, meta)
      end
      if backend.enrich then
        backend.enrich(problem, lang, meta, finish, status)
      else
        finish()
      end
    end)
  end)
end

local ORACLE_STAGES = { "reference", "editorial", "community" }

--- Build stage-major candidates. Provider preference only breaks ties inside a
--- stage: a NeetCode reference therefore beats a preferred LeetCode editorial.
local function merge_oracles(base, metas, order, lang)
  base.oracle_candidates = {}
  base.oracle_answers = {}
  for _, stage in ipairs(ORACLE_STAGES) do
    local candidates = {}
    for _, provider_name in ipairs(order) do
      local meta = metas[provider_name]
      if meta then
        local values
        if stage == "reference" then
          local code = type(meta.solutions) == "table" and meta.solutions[lang] or nil
          values = type(code) == "string" and { code } or {}
        elseif stage == "editorial" then
          values = type(meta.editorial_solutions) == "table"
            and meta.editorial_solutions[lang] or {}
        else
          values = type(meta.community_solutions) == "table"
            and meta.community_solutions[lang] or {}
        end
        for _, value in ipairs(type(values) == "table" and values or {}) do
          local code = type(value) == "table" and value.code or value
          if type(code) == "string" and vim.trim(code) ~= "" then
            table.insert(candidates, {
              stage = stage,
              provider = provider_name,
              code = code,
              id = type(value) == "table" and value.id or nil,
            })
          end
        end
      end
    end
    base.oracle_candidates[stage] = candidates
  end
  for _, provider_name in ipairs(order) do
    local meta = metas[provider_name]
    local cases = meta and meta.custom_test_cases or {}
    for i, output in ipairs(meta and meta.expected_outputs or {}) do
      if type(cases[i]) == "string" and type(output) == "string" and output ~= "" then
        table.insert(base.oracle_answers, {
          provider = provider_name, input = cases[i], output = output,
        })
      end
    end
  end
end

--- Fetch just the selected provider's metadata. Its own reference/editorial/
--- community solutions (enriched inside `fetch_provider_meta`) are already
--- enough to open with a working local oracle; the rest of the content chain
--- is optional bonus material fetched later by `augment_oracles` so extra
--- fallback providers never delay getting into the problem.
local function fetch_meta(problem, provider_name, lang, cb, status)
  if status then status("Loading statement, starter and examples from "
      .. providers.get(provider_name).label .. "…") end
  fetch_provider_meta(problem, provider_name, lang, function(err, base)
    if err then return cb(err, base) end
    merge_oracles(base, { [provider_name] = base }, { provider_name }, lang)
    cb(nil, base)
  end, status)
end

--- Fetch the rest of the content fallback chain in the background, after the
--- problem is already open, and re-merge oracle stages across every provider
--- that answers. `on_done` is only called when this actually adds providers.
local function augment_oracles(s, provider_name, lang, on_done)
  local order = providers.candidates(s.problem, "content")
  if not vim.tbl_contains(order, provider_name) then table.insert(order, 1, provider_name) end
  if #order <= 1 then return end
  local metas, index = { [provider_name] = s.meta }, 1
  local function step()
    local name = order[index]
    index = index + 1
    if not name then
      merge_oracles(s.meta, metas, order, lang)
      return on_done()
    end
    if metas[name] then return step() end
    fetch_provider_meta(s.problem, name, lang, function(_, meta)
      if meta then metas[name] = meta end
      step()
    end)
  end
  step()
end

local function solution_path(problem, lang)
  local group = problem.pattern and util.slug(problem.pattern) or "problems"
  local id = assert(providers.filename(problem), "problem has no provider identifier")
  return string.format("%s/%s/%s.%s",
    config.options.solutions_dir, group, util.slug(id), lang_info.ext(lang))
end

--- Extra test cases the user has written, stored alongside the solution.
local function test_cases(s)
  tests.save(s.path)
  return tests.read(s.path, s.meta.custom_test_cases)
end

local function render_ready(s)
  local keys = config.options.keys.problem
  local submit_backend = providers.get(s.submit_provider)
  local oracle = runner.oracle(s.meta, s.lang)
  local local_note = oracle
      and "Local oracle order: reference → editorial → community → statement answers."
    or "No local starter is available; submit to run the hidden suite."
  local entries = {
    { keys.run, "run local tests" },
    { keys.submit, "submit to " .. submit_backend.label },
    { keys.tests, "edit test cases" },
    { keys.test_failed, "add failed submission case" },
    { keys.reset, "reset to starter code" },
    { keys.links, "open a problem link" },
    { keys.configure, "configure provider chains" },
  }
  local key_width, label_width = 0, 0
  for _, entry in ipairs(entries) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(entry[1]))
    label_width = math.max(label_width, vim.fn.strdisplaywidth(entry[2]))
  end
  local lines = { "" }
  local spans = {}
  local columns = 2
  for i = 1, #entries, columns do
    local cells = {}
    for j = 0, columns - 1 do
      local entry = entries[i + j]
      if entry then table.insert(cells, { entry[1], entry[2] }) end
    end
    local line, key_spans = "  ", {}
    for c, cell in ipairs(cells) do
      local start = #line
      line = line .. util.pad(cell[1], key_width) .. "  " .. util.pad(cell[2], label_width)
      table.insert(key_spans, { #lines, start, start + #cell[1], "MeatCodeKey" })
      if c < #cells then line = line .. "      " end
    end
    table.insert(lines, line)
    vim.list_extend(spans, key_spans)
  end
  vim.list_extend(lines, {
    "",
    string.format("  %d visible test case(s) · %d hidden",
      #test_cases(s), s.meta.test_case_count or 0),
    "",
    "  " .. local_note,
    "  Submitting runs the full hidden suite in the cloud.",
    "",
    "  <CR> in the statement opens a hint or diagram.",
  })
  local muted = { #lines - 6, #lines - 4, #lines - 3, #lines - 1 }
  for _, row in ipairs(muted) do table.insert(spans, { row, 0, #lines[row + 1], "MeatCodeMuted" }) end
  vim.bo[s.res_buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.res_buf, 0, -1, false, lines)
  vim.bo[s.res_buf].modifiable = false
  hl.apply(s.res_buf, spans)
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
  util.err("no problem is open — use :MeatCode to pick one")
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
  if not pcall(image.clear, "meatcode-setup-probe") then
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
    if not setup_ok or not pcall(image.clear, "meatcode-setup-probe") then
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
      namespace = "meatcode",
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
    { completions = progress.completion_count(s.problem, s.lang) })
  render_images(s)
end

--- Re-resolve every open session's judge after a chain edit. Content is left
--- alone: switching the statement mid-solve would orphan the WIP solution.
function M.refresh_chains()
  for _, s in pairs(sessions) do
    if session_alive(s) then
      local chain = providers.candidates(s.problem, "submit")
      s.submit_provider = chain[1] or s.content_provider
      if s.res_buf and vim.api.nvim_buf_is_valid(s.res_buf) then
        pcall(render_ready, s)
      end
    end
  end
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
  if not runner.oracle(s.meta, s.lang) then
    return util.err("no local oracle for this problem — submit it instead")
  end
  save(s)

  local cases = test_cases(s)
  s.busy = true
  results.running(s.res_buf, "Running " .. #cases .. " local test case" .. (#cases == 1 and "" or "s"))

  runner.run(providers.filename(s.problem), current_code(s), s.lang, s.meta, cases, function(result)
    s.busy = false
    s.last_oracle = {
      stage = result.oracle_stage, provider = result.oracle_provider, id = result.oracle_id,
    }
    vim.schedule(function()
      if s.res_buf and vim.api.nvim_buf_is_valid(s.res_buf) then
        results.render_run(s.res_buf, result)
      end
    end)
  end, function(message)
    if s.res_buf and vim.api.nvim_buf_is_valid(s.res_buf) then
      results.running(s.res_buf, message)
    end
  end)
end

local function accepted(s)
  local recorded = progress.record_acceptance(s.problem, s.lang)
  util.notify(s.problem.name .. " accepted" .. (recorded and " · completion recorded" or " · already counted today"))
  pcall(render_description, s)
  pcall(function() require("meatcode.ui.roadmap").refresh() end)
  pcall(function() require("meatcode.ui.list").refresh() end)
end

local function revalidate_community(s, submission)
  if not submission.learned or not s.last_oracle
    or s.last_oracle.stage ~= "community" then
    return false
  end
  local cases = test_cases(s)
  table.insert(cases, s.failed_input)
  s.busy = true
  submission.oracle_update = "Revalidating community oracle against the newly learned answer…"
  results.render_submit(s.res_buf, submission)
  runner.revalidate(providers.filename(s.problem), s.lang, s.meta, cases, function(info)
    s.busy = false
    s.last_oracle = info
    if info.stage == "community" then
      submission.oracle_update = info.rejected > 0
          and string.format("Rejected %d community oracle(s); switched to %s community solution.",
            info.rejected, info.provider or "the next")
        or "The current community oracle still passes the newly learned case."
    elseif info.stage == "expected" then
      submission.oracle_update = string.format(
        "Rejected %d community oracle(s); falling back to known answers.", info.rejected)
    else
      submission.oracle_update = string.format(
        "Community oracle replaced by %s %s solution.", info.provider or "local", info.stage)
    end
    if s.res_buf and vim.api.nvim_buf_is_valid(s.res_buf) then
      results.render_submit(s.res_buf, submission)
    end
  end, function(message)
    submission.oracle_update = message .. "…"
    if s.res_buf and vim.api.nvim_buf_is_valid(s.res_buf) then
      results.render_submit(s.res_buf, submission)
    end
  end)
  return true
end

function M.submit()
  local s = ready()
  if not s then return end
  if s.busy then return util.notify("already running") end
  if not providers.available(s.problem, s.submit_provider)
    and not (s.submit_provider == "lintcode" and providers.available(s.problem, "leetcode")) then
    return util.err("this problem is unavailable on " .. providers.get(s.submit_provider).label)
  end
  save(s)

  local backend = providers.get(s.submit_provider)
  s.busy = true
  results.running(s.res_buf, "Submitting to " .. backend.label)

  backend.submit(s.problem, s.meta, current_code(s), s.lang, function(err, data)
    s.busy = false
    vim.schedule(function()
      if not (s.res_buf and vim.api.nvim_buf_is_valid(s.res_buf)) then return end
      if err then
        return results.render_run(s.res_buf, {
          ok = false, error = err, cases = {}, passed = 0, total = 0,
        })
      end
      local submission = backend.normalize_submission(data)
      s.failed_input = type(submission.failed_input) == "string"
        and vim.trim(submission.failed_input) ~= "" and submission.failed_input or nil
      if s.failed_input and runner.learn(
        providers.filename(s.problem), s.failed_input, submission.expected) then
        -- The judge disclosed this answer. Future local runs can grade the same
        -- input even when no executable source survives oracle selection.
        submission.learned = true
      end
      results.render_submit(s.res_buf, submission)
      if submission.accepted then
        accepted(s)
      else
        revalidate_community(s, submission)
      end
    end)
  end)
end


--- Restore the open problem to its starter code and clear its local test files.
local function reset_local(s, starter)
  local ok, err = util.write_file(s.path, starter)
  if not ok then
    return "could not write starter code: " .. tostring(err)
  end

  vim.api.nvim_buf_set_lines(s.code_buf, 0, -1, false,
    vim.split(starter, "\n", { plain = true }))
  vim.bo[s.code_buf].modified = false

  for _, suffix in ipairs({ ".cases", ".tests" }) do
    local path = s.path .. suffix
    local buf = vim.fn.bufnr(path)
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
      vim.bo[buf].modified = false
    end
    if vim.uv.fs_stat(path) then
      local removed, remove_err = vim.uv.fs_unlink(path)
      if not removed then
        return string.format("could not remove %s: %s", suffix, tostring(remove_err))
      end
    end
  end
end

--- Restore the open problem to its starter code.
function M.reset()
  local s = ready()
  if not s then return end
  if s.busy then return util.notify("already running") end

  local starter = (s.meta.starterCode or {})[s.lang] or ""
  local local_err = reset_local(s, starter)
  if local_err then return util.err(local_err) end
  s.failed_input = nil

  render_ready(s)
  pcall(render_description, s)
  pcall(function() require("meatcode.ui.roadmap").refresh() end)
  util.notify(s.problem.name .. " reset to starter code")
end

local function drop_session(s)
  if not s or not s.problem then return end
  sessions[session_key(s.problem)] = nil
end

--- Floating windows (LSP hover, signature help, the roadmap, image.nvim,
--- nvim-notify, completion docs, …) share a problem tab but are not part of
--- the three-pane layout. Closing one must not take the problem down with it.
local function is_float(win)
  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  return ok and cfg.relative ~= nil and cfg.relative ~= ""
end

--- Collapse splits in the current tab and show the page underneath this problem
--- (home / roadmap / topic list). Falls back to an empty buffer when nothing is
--- on the stack — e.g. a problem opened with no MeatCode UI behind it.
local function restore_after_close(tab)
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    pcall(vim.api.nvim_set_current_tabpage, tab)
  end
  local keep = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
    if win ~= keep and not is_float(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if pages.reveal() then
    return
  end
  pcall(vim.cmd, "enew")
  tabs.clear(vim.api.nvim_get_current_tabpage())
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
      -- Refresh / repair the page we landed on (blank scratch after an old clear,
      -- or a stale tab title after solving).
      if pages.buf() then
        pages.reveal()
      end
    else
      restore_after_close(tab)
    end
  elseif pages.depth() > 0 then
    restore_after_close(nil)
  end
end

--- Re-apply the pane proportions against the current terminal size. Called at
--- build time and again on every `VimResized`, so shrinking or growing the
--- terminal keeps the description/editor/results split looking the same
--- instead of leaving the description at its old width and squeezing the
--- editor.
local function relayout(s)
  if vim.api.nvim_win_is_valid(s.desc_win) then
    vim.api.nvim_win_set_width(s.desc_win, math.floor(vim.o.columns * 0.42))
  end
  if vim.api.nvim_win_is_valid(s.res_win) then
    vim.api.nvim_win_set_height(s.res_win, math.min(14, math.floor(vim.o.lines * 0.35)))
  end
end

local watched = false
local function ensure_watchers()
  if watched then
    return
  end
  watched = true
  local group = vim.api.nvim_create_augroup("MeatCodeProblemLifecycle", { clear = true })
  -- A terminal resize changes `columns`/`lines` under every open problem tab;
  -- re-proportion each one and redraw its diagrams (image geometry is in
  -- cells, so it is invalidated by the resize).
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      for _, s in pairs(sessions) do
        relayout(s)
        for _, img in ipairs(s.drawn or {}) do
          pcall(function()
            img:render()
          end)
        end
      end
    end,
  })
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

--- <CR> in the statement: follow the link under the cursor -- an inline link or
--- a diagram -- or toggle the hint accordion under it.
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

--- Automatically fill in the other providers for an open problem: resolve the
--- ids we can derive, pull their (cached) metadata so topics/companies merge,
--- and redraw once anything new lands. Keeps <leader>no honest without making
--- the first paint wait on extra requests.
local function discover_providers(s)
  for _, name in ipairs(providers.NAMES) do
    if not providers.available(s.problem, name) then
      providers.ensure_id(s.problem, name, function(_, id)
        if not id then return end
        if name == "lintcode" then
          local leetcode_id = providers.id(s.problem, "leetcode")
          if leetcode_id then problem_catalog.remember_lintcode(leetcode_id, id) end
        end
        fetch_provider_meta(s.problem, name, s.lang, function()
          vim.schedule(function()
            if s.desc_buf and vim.api.nvim_buf_is_valid(s.desc_buf) then
              pcall(render_description, s)
            end
          end)
        end)
      end)
    end
  end
end

function M.links()
  local s = ready()
  if not s then return end
  require("meatcode.ui.links").open(s.problem)
end

--- The providers actually serving the open problem. The chain is a fallback
--- order, so the provider in use is often not the topmost one: a problem the
--- first choice does not carry falls through to the next.
---@return {content: string, submit: string, name: string}|nil
function M.active()
  local s = current_session()
  if not s then return nil end
  return { content = s.content_provider, submit = s.submit_provider, name = s.problem.name }
end

function M.configure()
  require("meatcode.ui.chains").open()
end

local function keymaps(s)
  local keys = config.options.keys.problem
  for _, buf in ipairs({ s.code_buf, s.desc_buf, s.res_buf }) do
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, desc = desc })
    end
    map(keys.run, M.run, "MeatCode: run local tests")
    map(keys.submit, M.submit, "MeatCode: submit to selected provider")
    map(keys.tests, M.tests, "MeatCode: edit test cases")
    map(keys.test_failed, M.test_failed, "MeatCode: add failed submission case")
    map(keys.reset, M.reset, "MeatCode: reset to starter code")
    map(keys.links, M.links, "MeatCode: open a problem link")
    map(keys.configure, M.configure, "MeatCode: configure provider chains")
    -- A problem tab is one unit: closing a split closes the tab.
    map("<C-w>c", function() M.close(s) end, "MeatCode: close problem")
    map("<C-w>q", function() M.close(s) end, "MeatCode: close problem")
    map("<C-w>o", function() M.close(s) end, "MeatCode: close problem")
  end

  for _, buf in ipairs({ s.desc_buf, s.res_buf }) do
    vim.keymap.set("n", keys.quit, function() M.close(s) end,
      { buffer = buf, silent = true, desc = "MeatCode: close problem" })
  end

  for _, lhs in ipairs({ "<CR>", "<Tab>" }) do
    vim.keymap.set("n", lhs, function() activate(s) end,
      { buffer = s.desc_buf, silent = true, desc = "MeatCode: open hint or diagram" })
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
local CLANGD_MARKER = "Written by meatcode.nvim"
-- Prior names of this plugin. A `.clangd` carrying one of these is ours and
-- must be rewritten so force-includes keep pointing at the current support dir.
local CLANGD_MARKERS = {
  CLANGD_MARKER,
  "Written by eetCode.nvim",
  "Written by neetcode.nvim",
}

local function support_dir()
  return config.options.solutions_dir .. "/.meatcode"
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
  local types = require("meatcode.runner.cpp").starter_types(starter)
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
      local cached = util.read_json(meta_cache_path("leetcode", id))
        or util.read_json(meta_cache_path("neetcode", id))
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
  -- alone. Ours (including pre-rename markers), a missing file, or one with
  -- the wrong language mode is not.
  local managed = false
  if existing then
    for _, marker in ipairs(CLANGD_MARKERS) do
      if existing:find(marker, 1, true) then
        managed = true
        break
      end
    end
  end
  if existing and not managed and not clangd_disagrees_with_cmd(existing) then
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
  local before = existing
  rebuild_clangd(existing)
  if before ~= util.read_file(clangd_path()) then
    vim.schedule(function()
      local bufs = {}
      for _, client in ipairs(vim.lsp.get_clients({ name = "clangd" })) do
        for _, buf in ipairs(vim.lsp.get_buffers_by_client_id(client.id)) do
          bufs[buf] = true
        end
        pcall(function()
          client:stop(true)
        end)
      end
      -- Re-fire FileType so clangd attaches again against the new config.
      vim.schedule(function()
        for buf in pairs(bufs) do
          if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_exec_autocmds, "FileType", {
              buffer = buf,
              modeline = false,
            })
          end
        end
      end)
    end)
  end
end

--- Seed from a provider's saved editor only when that capability exists. Every
--- provider shares the same on-disk solution, and an existing file always wins.
--- The starter code is written and handed back immediately — opening the
--- problem never waits on the saved-code network round trip; if a saved
--- version shows up afterward and the user has not typed anything yet, it is
--- patched into the still-fresh buffer.
local function seed_file(s, path, cb)
  local starter = (s.meta.starterCode or {})[s.lang] or ""
  if s.lang == "cpp" then ensure_clangd(util.slug(providers.filename(s.problem)), starter) end
  if vim.uv.fs_stat(path) then return cb() end

  util.write_file(path, starter)

  local backend = providers.get(s.content_provider)
  if backend.saved_code then
    backend.saved_code(s.problem, s.lang, function(err, data)
      vim.schedule(function()
        if err or not session_alive(s) then return end
        if not (s.code_buf and vim.api.nvim_buf_is_valid(s.code_buf)) then return end
        if vim.bo[s.code_buf].modified then return end
        local code_tabs = type(data) == "table" and (data.tabs or (data.code and { { code = data.code } }))
        local code = type(code_tabs) == "table" and code_tabs[1]
          and type(code_tabs[1].code) == "string"
          and (data.lang == nil or data.lang == s.lang)
          and code_tabs[1].code or nil
        if not (code and code ~= "" and code ~= starter) then return end
        vim.api.nvim_buf_set_lines(s.code_buf, 0, -1, false, vim.split(code, "\n", { plain = true }))
        vim.bo[s.code_buf].modified = false
        util.write_file(path, code)
      end)
    end)
  end

  vim.schedule(cb)
end

local function build_windows(s)
  vim.cmd("tabnew")
  s.tab = vim.api.nvim_get_current_tabpage()
  tabs.set(s.tab, s.problem.name)
  sessions[session_key(s.problem)] = s

  s.desc_win = vim.api.nvim_get_current_win()
  s.desc_buf = vim.api.nvim_get_current_buf()
  vim.bo[s.desc_buf].buftype = "nofile"
  vim.bo[s.desc_buf].bufhidden = "wipe"
  vim.bo[s.desc_buf].swapfile = false
  vim.bo[s.desc_buf].buflisted = false
  vim.bo[s.desc_buf].filetype = "meatcode-problem"
  vim.bo[s.desc_buf].modified = false
  tabs.name_buffer(s.desc_buf, s.problem.name)
  vim.wo[s.desc_win].wrap = true
  vim.wo[s.desc_win].linebreak = true
  vim.wo[s.desc_win].breakindent = true
  vim.wo[s.desc_win].showbreak = ""
  vim.wo[s.desc_win].conceallevel = 2
  vim.wo[s.desc_win].concealcursor = "nvic"
  vim.wo[s.desc_win].number = false
  vim.wo[s.desc_win].relativenumber = false
  vim.wo[s.desc_win].signcolumn = "no"

  vim.cmd("botright vsplit " .. vim.fn.fnameescape(s.path))
  s.code_win = vim.api.nvim_get_current_win()
  s.code_buf = vim.api.nvim_get_current_buf()
  vim.bo[s.code_buf].filetype = lang_info.filetype(s.lang)

  vim.cmd("belowright split")
  s.res_win = vim.api.nvim_get_current_win()
  s.res_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(s.res_win, s.res_buf)
  vim.bo[s.res_buf].filetype = "meatcode-results"
  vim.bo[s.res_buf].bufhidden = "wipe"
  vim.bo[s.res_buf].modifiable = false
  vim.wo[s.res_win].number = false
  vim.wo[s.res_win].relativenumber = false
  vim.wo[s.res_win].signcolumn = "no"
  vim.wo[s.res_win].wrap = false
  relayout(s)
  vim.api.nvim_set_current_win(s.code_win)
  ensure_watchers()
end

local function initial_candidates(problem, forced)
  if forced then return { forced } end
  return providers.candidates(problem, "content")
end

---@param problem table catalog entry
---@param opts table|nil lang, provider, guard (fun():boolean — checked right
---before taking over the screen; a false result quietly drops this open),
---will_show (fun() — called right before the tab/focus switch happens, e.g.
---to close a picker that was left open during prep)
function M.open(problem, opts)
  opts = opts or {}
  local function wanted()
    return not opts.guard or opts.guard()
  end
  local key = session_key(problem)
  if not key then return util.err("problem has no provider identifier") end
  local existing = sessions[key]
  if session_alive(existing) then
    if not wanted() then return end
    if opts.will_show then opts.will_show() end
    focus_session(existing)
    return
  end
  if opening[key] then return end

  local forced = opts.provider
  local candidates = initial_candidates(problem, forced)
  if #candidates == 0 then return util.err("problem has no supported provider") end

  local lang = opts.lang or config.options.lang
  local candidate_index, provider = 0, nil
  opening[key] = true

  local function start_next(last_error)
    candidate_index = candidate_index + 1
    provider = candidates[candidate_index]
    if not provider then
      opening[key] = nil
      return vim.schedule(function()
        util.err("could not load problem: " .. tostring(last_error or "no provider succeeded"))
      end)
    end
    local function status(message)
      vim.schedule(function() util.notify(message) end)
    end
    status("Opening " .. problem.name .. " from " .. providers.get(provider).label .. "…")
    fetch_meta(problem, provider, lang, function(err, meta)
      if err then
        if forced then
          opening[key] = nil
          return vim.schedule(function() util.err("could not load problem: " .. err) end)
        end
        return start_next(err)
      end
      if meta.paid_only and not providers.paid_unlocked(provider) then
        local label = providers.get(provider).label
        if forced then
          opening[key] = nil
          return vim.schedule(function() util.err(problem.name .. " is paid-only on " .. label) end)
        end
        return start_next("paid-only on " .. label)
      end

      vim.schedule(function()
        if session_alive(sessions[key]) then
          opening[key] = nil
          if wanted() then
            if opts.will_show then opts.will_show() end
            focus_session(sessions[key])
          end
          return
        end
        local available = meta.availableLanguages or {}
        if #available > 0 and not vim.tbl_contains(available, lang) then
          util.notify(string.format("%s is unavailable; falling back to %s",
            lang_info.name(lang), lang_info.name(available[1])))
          lang = available[1]
        end

        local selected = vim.deepcopy(problem)
        local submit_chain = providers.candidates(selected, "submit")
        local s = {
          problem = selected,
          content_provider = provider,
          submit_provider = submit_chain[1] or provider,
          meta = meta,
          sections = description.sections(meta.description),
          lang = lang,
          path = solution_path(selected, lang),
          busy = false,
          drawn = {},
        }
        util.mkdirp(vim.fs.dirname(s.path))
        status("Preparing the local solution and language-server support…")
        seed_file(s, s.path, function()
          if session_alive(sessions[key]) then
            opening[key] = nil
            if wanted() then
              if opts.will_show then opts.will_show() end
              focus_session(sessions[key])
            end
            return
          end
          if not wanted() then
            opening[key] = nil
            return
          end
          if opts.will_show then opts.will_show() end
          build_windows(s)
          opening[key] = nil
          render_description(s)
          keymaps(s)
          render_ready(s)
          status("Ready: local runs will resolve reference → editorial → community → statement.")
          discover_providers(s)
          augment_oracles(s, provider, lang, function()
            vim.schedule(function()
              if session_alive(s) and s.res_buf and vim.api.nvim_buf_is_valid(s.res_buf) then
                render_ready(s)
              end
            end)
          end)
        end)
      end)
    end, status)
  end

  start_next()
end
return M
