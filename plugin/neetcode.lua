if vim.g.loaded_neetcode then
  return
end
vim.g.loaded_neetcode = true

local SUBCOMMANDS = {
  roadmap = function() require("neetcode").roadmap() end,
  login = function(args) require("neetcode").login(args[1]) end,
  logout = function() require("neetcode").logout() end,
  sync = function() require("neetcode").sync() end,
  status = function() require("neetcode").status() end,
  list = function(args) require("neetcode").set_list(args[1]) end,
  lang = function(args) require("neetcode").set_lang(args[1]) end,
  run = function() require("neetcode").run() end,
  submit = function() require("neetcode").submit() end,
}

vim.api.nvim_create_user_command("NeetCode", function(cmd)
  local args = cmd.fargs
  local sub = table.remove(args, 1) or "roadmap"
  local fn = SUBCOMMANDS[sub]
  if not fn then
    return vim.notify("unknown subcommand: " .. sub, vim.log.levels.ERROR, { title = "neetcode" })
  end
  fn(args)
end, {
  nargs = "*",
  desc = "NeetCode roadmap and problem workflow",
  complete = function(lead, line)
    local parts = vim.split(vim.trim(line), "%s+")
    -- Completing the subcommand itself.
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
      candidates = require("neetcode.catalog").LISTS
    elseif sub == "lang" then
      candidates = require("neetcode.lang").all()
    end
    return vim.tbl_filter(function(name)
      return name:find(lead, 1, true) == 1
    end, candidates)
  end,
})
