if vim.g.loaded_eetcode then
  return
end
vim.g.loaded_eetcode = true

local SUBCOMMANDS = {
  roadmap = function() require("eetcode").roadmap() end,
  leetcode = function(args) require("eetcode").leetcode(table.concat(args, " ")) end,
  random = function() require("eetcode").random() end,
  daily = function() require("eetcode").daily() end,
  login = function(args)
    require("eetcode").login(args[1], #args > 1 and table.concat(vim.list_slice(args, 2), " ") or nil)
  end,
  logout = function(args) require("eetcode").logout(args[1]) end,
  sync = function() require("eetcode").sync() end,
  status = function() require("eetcode").status() end,
  list = function(args) require("eetcode").set_list(args[1]) end,
  lang = function(args) require("eetcode").set_lang(args[1]) end,
  run = function() require("eetcode").run() end,
  submit = function() require("eetcode").submit() end,
  complete = function() require("eetcode").complete() end,
  reset = function() require("eetcode.ui.problem").reset() end,
  tests = function() require("eetcode.ui.problem").tests() end,
  ["test-failed"] = function() require("eetcode.ui.problem").test_failed() end,
}

vim.api.nvim_create_user_command("EetCode", function(cmd)
  local args = cmd.fargs
  local sub = table.remove(args, 1) or "roadmap"
  local fn = SUBCOMMANDS[sub]
  if not fn then
    return vim.notify("unknown subcommand: " .. sub, vim.log.levels.ERROR, { title = "eetCode" })
  end
  fn(args)
end, {
  nargs = "*",
  desc = "eetCode.nvim problem workflow",
  complete = function(lead, line)
    local parts = vim.split(vim.trim(line), "%s+")
    if #parts <= 1 or (#parts == 2 and lead ~= "") then
      local names = vim.tbl_filter(function(name)
        return name:find(lead, 1, true) == 1
      end, vim.tbl_keys(SUBCOMMANDS))
      table.sort(names)
      return names
    end

    local sub = parts[2]
    local candidates = {}
    if sub == "list" then
      candidates = require("eetcode.catalog").LISTS
    elseif sub == "lang" then
      candidates = require("eetcode.lang").all()
    elseif sub == "login" or sub == "logout" then
      candidates = { "leetcode", "neetcode" }
    end
    return vim.tbl_filter(function(name)
      return name:find(lead, 1, true) == 1
    end, candidates)
  end,
})
