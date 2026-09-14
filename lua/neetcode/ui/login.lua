local M = {}

function M.open(snippet, finish)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {
    "NeetCode login", "",
    "1. Open https://neetcode.io and sign in.",
    "2. In browser DevTools, open Application (Chrome) or Storage (Firefox).",
    "3. Open IndexedDB > firebaseLocalStorageDb > firebaseLocalStorage.",
    "4. Expand the auth user value > stsTokenManager > refreshToken.",
    "5. Copy the refreshToken value (without quotes).",
    "6. Return here and press p to paste the token into the login prompt.", "",
    "Alternative: press y to copy the script below, then run it in the",
    "browser console on neetcode.io and copy the token it prints.", "",
    "y: copy script   p: enter token   q: close", "",
  }
  vim.list_extend(lines, vim.split(vim.trim(snippet), "\n", { plain = true }))
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
      require("neetcode.util").notify("login script copied to clipboard")
    else
      require("neetcode.util").notify("script yanked; no clipboard provider available — use the storage steps above")
    end
  end, { buffer = buf, desc = "Copy login script" })
  vim.keymap.set("n", "p", function()
    vim.ui.input({ prompt = "NeetCode refresh token: " }, function(input)
      if input and vim.trim(input) ~= "" then
        close()
        finish(vim.trim(input))
      end
    end)
  end, { buffer = buf, desc = "Enter login token" })
end

return M
