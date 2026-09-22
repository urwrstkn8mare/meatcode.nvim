if vim.g.loaded_meatcode then
  return
end
vim.g.loaded_meatcode = true

local SUBCOMMANDS = {
  home = function() require("meatcode").home() end,
  roadmap = function(args) require("meatcode").roadmap(args[1]) end,
  list = function(args) require("meatcode").list(table.concat(args, " ")) end,
  random = function() require("meatcode").random() end,
  daily = function() require("meatcode").daily() end,
  login = function(args)
    require("meatcode").login(args[1], #args > 1 and table.concat(vim.list_slice(args, 2), " ") or nil)
  end,
  logout = function(args) require("meatcode").logout(args[1]) end,
  lang = function(args) require("meatcode").set_lang(args[1]) end,
}

vim.api.nvim_create_user_command("MeatCode", function(cmd)
  local args = cmd.fargs
  local sub = table.remove(args, 1) or "home"
  local fn = SUBCOMMANDS[sub]
  if not fn then
    return vim.notify("unknown subcommand: " .. sub, vim.log.levels.ERROR, { title = "MeatCode" })
  end
  fn(args)
end, {
  nargs = "*",
  desc = "meatcode.nvim problem workflow",
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
    if sub == "roadmap" then
      candidates = require("meatcode.catalog").LISTS
    elseif sub == "lang" then
      candidates = require("meatcode.lang").all()
    elseif sub == "login" or sub == "logout" then
      candidates = require("meatcode.providers").NAMES
    end
    return vim.tbl_filter(function(name)
      return name:find(lead, 1, true) == 1
    end, candidates)
  end,
})
