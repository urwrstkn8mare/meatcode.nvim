local providers = require("meatcode.providers")
local util = require("meatcode.util")

--- Fuzzy link picker shared by the problem view, drilldown, and finder.
--- Telescope when installed (the plugin already requires it for `:MeatCode
--- list`), otherwise a plain `vim.ui.select` fallback.
local M = {}

local function telescope()
  local modules = {}
  for _, name in ipairs({
    "telescope.pickers", "telescope.finders", "telescope.config",
    "telescope.actions", "telescope.actions.state",
  }) do
    local ok, module = pcall(require, name)
    if not ok then return nil end
    modules[name] = module
  end
  return modules
end

local function fallback(links)
  if #links == 1 then return vim.ui.open(links[1].url) end
  vim.ui.select(links, {
    prompt = "Open link:",
    format_item = function(link) return link.label end,
  }, function(choice)
    if choice then vim.ui.open(choice.url) end
  end)
end

function M.open(problem)
  local links = providers.links(problem or {})
  if #links == 0 then return util.err("this problem has no links") end
  if #links == 1 then return vim.ui.open(links[1].url) end
  local modules = telescope()
  if not modules then return fallback(links) end
  local pickers = modules["telescope.pickers"]
  local finders = modules["telescope.finders"]
  local conf = modules["telescope.config"].values
  local actions = modules["telescope.actions"]
  local action_state = modules["telescope.actions.state"]
  pickers.new({}, {
    prompt_title = "Open link",
    finder = finders.new_table({
      results = links,
      entry_maker = function(link)
        return { value = link, display = link.label, ordinal = link.label .. " " .. link.url }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = false,
    layout_strategy = "cursor",
    layout_config = { width = 60, height = 12 },
    attach_mappings = function(prompt_buf, map)
      local function open_selected()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_buf)
        if entry then vim.ui.open(entry.value.url) end
      end
      map("i", "<CR>", open_selected)
      map("n", "<CR>", open_selected)
      return true
    end,
  }):find()
end

return M
