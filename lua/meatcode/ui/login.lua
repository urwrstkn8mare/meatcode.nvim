local M = {}

--- Script-assisted login. `opts` = { label, steps, alternative, prompt,
--- snippet, finish }: numbered `steps` for the manual route, `alternative`
--- lines describing the console script, and the `snippet` itself.
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  local snippet = vim.trim(opts.snippet)
  local finish = opts.finish
  local lines = { opts.label .. " login", "" }
  for i, step in ipairs(opts.steps) do
    table.insert(lines, i .. ". " .. step)
  end
  table.insert(lines, "")
  vim.list_extend(lines, opts.alternative or {})
  vim.list_extend(lines, { "", "y: copy script   p: paste value   q: close", "" })
  vim.list_extend(lines, vim.split(snippet, "\n", { plain = true }))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.max(1, math.min(90, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", border = "rounded", style = "minimal",
    width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  vim.wo[win].wrap = true
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  vim.keymap.set("n", "q", close, { buffer = buf })
  vim.keymap.set("n", "y", function()
    vim.fn.setreg('"', vim.trim(snippet))
    if vim.fn.has("clipboard") == 1 then
      vim.fn.setreg("+", vim.trim(snippet))
      require("meatcode.util").notify("login script copied to clipboard")
    else
      require("meatcode.util").notify("script yanked; no clipboard provider available — use the storage steps above")
    end
  end, { buffer = buf, desc = "Copy login script" })
  vim.keymap.set("n", "p", function()
    vim.ui.input({ prompt = opts.prompt }, function(input)
      if input and vim.trim(input) ~= "" then
        close()
        finish(vim.trim(input))
      end
    end)
  end, { buffer = buf, desc = "Enter login credential" })
end

--- Header-paste login. `steps` are the numbered instructions, `prompt` labels
--- the input, `required` is an optional trailing caveat.
function M.open_header(provider, label, steps, prompt, required, finish)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = { label .. " login", "" }
  for i, step in ipairs(steps) do
    table.insert(lines, i .. ". " .. step)
  end
  table.insert(lines, "")
  if required then table.insert(lines, required) end
  vim.list_extend(lines, { "", "p: paste value   q: close" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = math.max(1, math.min(78, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", border = "rounded", style = "minimal",
    width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end
  vim.keymap.set("n", "q", close, { buffer = buf })
  vim.keymap.set("n", "p", function()
    vim.ui.input({ prompt = prompt }, function(input)
      if input and vim.trim(input) ~= "" then
        close()
        finish(vim.trim(input))
      end
    end)
  end, { buffer = buf, desc = "Enter " .. provider .. " credential" })
end

return M
