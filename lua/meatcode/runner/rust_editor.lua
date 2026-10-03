--- Non-Cargo rust-analyzer projects with judge context outside solution files.
local config = require("meatcode.config")
local util = require("meatcode.util")
local M = {}
local marker = "Written by meatcode.nvim"
local harness = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness/"
local sysroots = {}
local function absolute(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function helper_path(path)
  local root = absolute(config.options.solutions_dir):gsub("/$", "")
  local id = vim.fn.fnamemodify(path, ":t:r")
  return root .. "/.meatcode/rust/" .. id .. "-" .. vim.fn.sha256(absolute(path)):sub(1, 16) .. ".rs"
end

local function write_changed(path, body)
  if util.read_file(path) == body then return false end
  local ok, err = util.write_file(path, body)
  if not ok then error("could not write Rust editor support: " .. tostring(err)) end
  return true
end

--- Extract the struct/impl blocks documented by the judge, like C++ headers.
--- Only declarations are lifted, never the surrounding explanatory prose.
local function starter_types(starter)
  local comments = {}
  for block in starter:gmatch("/%*.-%*/") do
    block = block:gsub("^/%*+", ""):gsub("%*/$", ""):gsub("\n%s*%*%s?", "\n")
    table.insert(comments, block)
  end
  for line in (starter:gsub("/%*.-%*/", "") .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(comments, line:match("^%s*//%s?(.*)$") or "")
  end
  local body, declarations, names, ordered = table.concat(comments, "\n"), {}, {}, {}
  local pos = 1
  while true do
    local start, finish, name, fields = body:find("%f[%w]struct%s+([%w_]+)%s*(%b{})", pos)
    if not start then break end
    if name ~= "Solution" and not names[name] then
      names[name] = true
      table.insert(ordered, name)
      local prefix = body:sub(1, start - 1):gsub("pub%s*$", "")
      local attrs = {}
      while true do
        local attr_start, _, attr = prefix:find("(#%[[^\n]+%])%s*$")
        if not attr_start then break end
        table.insert(attrs, 1, attr)
        prefix = prefix:sub(1, attr_start - 1)
      end
      table.insert(declarations, table.concat(attrs, "\n") .. "\npub struct " .. name .. " " .. fields)
    end
    pos = finish + 1
  end
  for _, name in ipairs(ordered) do
    for block in body:gmatch("%f[%w]impl%s+" .. name .. "%s*(%b{})") do
      table.insert(declarations, "impl " .. name .. " " .. block)
    end
  end
  return table.concat(declarations, "\n"), ordered
end

local function compiler_flags(cmd)
  local flags, edition, sysroot, skip = {}, "2015", nil, false
  for i = 2, #cmd do
    local arg = cmd[i]
    if skip then
      skip = false
    elseif arg == "-o" then
      skip = true
    elseif not arg:find("{source}", 1, true) and not arg:find("{out}", 1, true) then
      table.insert(flags, arg)
    end
    edition = arg:match("^%-%-edition=(.+)$") or (arg == "--edition" and cmd[i + 1]) or edition
    sysroot = arg:match("^%-%-sysroot=(.+)$") or (arg == "--sysroot" and cmd[i + 1]) or sysroot
  end
  return flags, edition, sysroot
end

local function project(root, path, starter, sysroot, cmd)
  local project_path = root .. "/rust-project.json"
  local existing = util.read_json(project_path)
  local managed = not util.read_file(project_path) or existing and existing._meatcode == marker
  local dir = root .. "/.meatcode/rust"
  local types = assert(util.read_file(harness .. "rust_types.rs"), "missing Rust judge types -- reinstall meatcode.nvim")
  write_changed(dir .. "/types.rs", types)
  local flags, edition = compiler_flags(cmd)
  local paths, seen = {}, {}
  local function add(file)
    file = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
    if not seen[file] and (file == path or vim.uv.fs_stat(file)) then
      seen[file] = true
      table.insert(paths, file)
    end
  end
  for _, file in ipairs(vim.fn.glob(root .. "/*/*.rs", false, true)) do add(file) end
  for _, file in ipairs(managed and existing and existing._meatcode_paths or {}) do add(file) end
  add(path)
  table.sort(paths)
  local include_dirs = { root }
  for _, file in ipairs(paths) do
    if file:sub(1, #root + 1) ~= root .. "/" then
      local parent = vim.fs.dirname(file)
      if not vim.tbl_contains(include_dirs, parent) then table.insert(include_dirs, parent) end
    end
  end
  local crates = {}
  local changed = false
  for _, file in ipairs(paths) do
    local id = vim.fn.fnamemodify(file, ":t:r")
    local helper = helper_path(file)
    local declarations, names = starter_types(file == path and starter or util.read_file(file) or "")
    local body = table.concat({
      "// " .. marker .. "; editor-only judge context.",
      "pub use std::{cell::RefCell, rc::Rc, collections::VecDeque};",
      'mod standard { use super::*; include!("types.rs"); }',
      "pub use self::standard::*;",
      "pub struct Solution;",
      declarations,
      "pub mod prelude { pub mod rust_" .. edition .. " {",
      "pub use std::prelude::rust_" .. edition .. "::*;",
      "pub use super::super::{Solution, Rc, RefCell, VecDeque" .. (#names > 0 and ", " .. table.concat(names, ", ") or "") .. "};",
      "pub use super::super::standard::*;",
      "} }",
      "",
    }, "\n")
    changed = write_changed(helper, body) or changed
    local wrapper = helper:gsub("%.rs$", "-check.rs")
    changed = write_changed(wrapper, table.concat({
      "// " .. marker .. "; rustc check-on-save wrapper.",
      "#[path = " .. vim.json.encode(helper) .. "] mod __meatcode;",
      "use self::__meatcode::*;",
      "include!(" .. vim.json.encode(file) .. ");",
      "",
    }, "\n")) or changed
    local editor_root = helper:gsub("%.rs$", "-editor.rs")
    -- A local prelude keeps Solution in the same crate as its impl. Loading
    -- the solution as a module (not include!) also preserves LSP completion.
    changed = write_changed(editor_root, table.concat({
      "// " .. marker .. "; rust-analyzer-only crate root.",
      "#[path = " .. vim.json.encode(helper) .. "] mod __meatcode;",
      "#[prelude_import] use self::__meatcode::prelude::rust_" .. edition .. "::*;",
      "#[path = " .. vim.json.encode(file) .. "] mod solution;",
      "",
    }, "\n")) or changed
    table.insert(crates, {
      display_name = id, root_module = editor_root, edition = edition, deps = {},
      is_workspace_member = true,
      source = { include_dirs = include_dirs, exclude_dirs = {} },
      build = { label = wrapper, build_file = project_path, target_kind = "lib" },
    })
  end
  if not managed then return end
  local args = vim.deepcopy(flags)
  vim.list_extend(args, { "--crate-name", "meatcode_solution", "--crate-type=lib", "--emit=metadata", "--error-format=json", "-o", dir .. "/check.rmeta", "{label}" })
  changed = write_changed(project_path, vim.json.encode({
    _meatcode = marker, _meatcode_paths = paths, sysroot = sysroot,
    sysroot_src = sysroot .. "/lib/rustlib/src/rust/library",
    crates = crates,
    runnables = { { program = cmd[1], args = args, cwd = root, kind = "flycheck" } },
  })) or changed
  if changed then
    for _, client in ipairs(vim.lsp.get_clients()) do
      if (client.name == "rust_analyzer" or client.name == "rust-analyzer")
        and client.config.root_dir and vim.fs.normalize(client.config.root_dir) == root then
        client:request("rust-analyzer/reloadWorkspace", nil, function(err)
          if err then util.err("could not reload Rust editor project: " .. tostring(err.message)) end
        end)
      end
    end
  end
end

--- Prepare the crate graph before FileType triggers the user's LSP setup.
function M.ensure(path, starter, cb)
  if not config.options.runner.rust.rust_analyzer then return cb() end
  local root = vim.fs.normalize(vim.fn.fnamemodify(config.options.solutions_dir, ":p")):gsub("/$", "")
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local cmd = config.options.runner.rust.cmd
  local _, _, explicit_sysroot = compiler_flags(cmd)
  local function finish(sysroot)
    local ok, err = pcall(project, root, path, starter, sysroot, cmd)
    if not ok then util.err(err) end
    cb()
  end
  if explicit_sysroot or sysroots[cmd[1]] then return finish(explicit_sysroot or sysroots[cmd[1]]) end
  vim.system({ cmd[1], "--print", "sysroot" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 or not result.stdout or vim.trim(result.stdout) == "" then
        util.err("could not find Rust sysroot for rust-analyzer: " .. (result.stderr or ""))
        return cb()
      end
      sysroots[cmd[1]] = vim.trim(result.stdout)
      finish(sysroots[cmd[1]])
    end)
  end)
end

return M
