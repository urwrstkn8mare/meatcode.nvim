local util = require("neetcode.util")
local M = {}

function M.parse(raw)
  local cases, lines = {}, {}
  local function flush()
    local value = vim.trim(table.concat(lines, "\n"))
    if value ~= "" then cases[#cases + 1] = value end
    lines = {}
  end
  for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
    if vim.trim(line) == "---" then flush() else lines[#lines + 1] = line end
  end
  flush()
  return cases
end

function M.read(path, defaults)
  local raw = util.read_file(path .. ".cases")
  if raw ~= nil then return M.parse(raw) end
  local cases = vim.deepcopy(defaults or {})
  vim.list_extend(cases, M.parse(util.read_file(path .. ".tests") or ""))
  return cases
end

function M.save(path)
  local buf = vim.fn.bufnr(path .. ".cases")
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
  end
end

function M.open(path, defaults, input)
  local name = path .. ".cases"
  local buf = vim.fn.bufadd(name)
  vim.fn.bufload(buf)
  if not util.read_file(name) and not vim.bo[buf].modified then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false,
      vim.split(table.concat(M.read(path, defaults), "\n---\n"), "\n", { plain = true }))
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if input then
    for _, case in ipairs(M.parse(table.concat(lines, "\n"))) do
      if case == vim.trim(input) then
        util.notify("test case already exists")
        input = nil
        break
      end
    end
    if input then
      if vim.trim(table.concat(lines, "\n")) ~= "" then
        lines[#lines + 1] = "---"
      else
        lines = {}
      end
      vim.list_extend(lines, vim.split(vim.trim(input), "\n", { plain = true }))
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end
  end
  local width = math.max(1, math.min(90, vim.o.columns - 4))
  local height = math.max(1, math.min(24, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded",
    title = " Test cases · separate with --- · :w saves · :q closes ",
    width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  vim.wo[win].number = true
  if input then
    vim.api.nvim_win_set_cursor(win, { #lines, 0 })
    vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
    util.notify("failed submission case added")
  end
end

return M
