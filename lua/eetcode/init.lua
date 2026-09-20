local nc_auth = require("eetcode.api.auth")
local catalog = require("eetcode.catalog")
local config = require("eetcode.config")
local hl = require("eetcode.ui.highlight")
local lang_info = require("eetcode.lang")
local leetcode = require("eetcode.api.leetcode")
local leetcode_auth = require("eetcode.api.leetcode_auth")
local leetcode_catalog = require("eetcode.catalog.leetcode")
local progress = require("eetcode.progress")
local util = require("eetcode.util")

local M = {}

--- Snippet the user runs in their browser console to obtain a Firebase refresh
--- token. NeetCode has password sign-in disabled, so this is the only way for a
--- headless client to authenticate.
local TOKEN_SNIPPET = [[
(async () => {
  const rows = await new Promise((res, rej) => {
    const r = indexedDB.open('firebaseLocalStorageDb');
    r.onerror = () => rej(r.error);
    r.onsuccess = () => {
      const tx = r.result.transaction('firebaseLocalStorage', 'readonly');
      const g = tx.objectStore('firebaseLocalStorage').getAll();
      g.onsuccess = () => res(g.result); g.onerror = () => rej(g.error);
    };
  });
  let t = rows.map(r => r?.value?.stsTokenManager?.refreshToken).find(Boolean);
  if (!t) {
    const ls = Object.entries(localStorage).find(([k]) => k.startsWith('firebase:authUser:'));
    if (ls) t = JSON.parse(ls[1])?.stsTokenManager?.refreshToken;
  }
  console.log(t || 'NOT FOUND - are you logged in on this tab?');
})()

]]

function M.roadmap()
  require("eetcode.ui.roadmap").open()
end

function M.login(provider, credential)
  if provider ~= "leetcode" and provider ~= "neetcode" then
    return util.err("usage: :EetCode login leetcode|neetcode")
  end

  local function finish(value)
    local login = provider == "leetcode" and leetcode_auth.login or nc_auth.login
    login(value, function(err)
      vim.schedule(function()
        if err then return util.err(provider .. " login failed: " .. err) end
        util.notify("logged in to " .. (provider == "leetcode" and "LeetCode" or "NeetCode"))
        progress.sync(function() end)
      end)
    end)
  end

  if credential and credential ~= "" then return finish(credential) end
  local login_ui = require("eetcode.ui.login")
  if provider == "leetcode" then
    return login_ui.open_leetcode(finish)
  end
  login_ui.open(TOKEN_SNIPPET, finish)
end

function M.logout(provider)
  if provider == "leetcode" then
    leetcode_auth.logout()
  elseif provider == "neetcode" then
    nc_auth.logout()
  else
    return util.err("usage: :EetCode logout leetcode|neetcode")
  end
  util.notify("logged out of " .. (provider == "leetcode" and "LeetCode" or "NeetCode"))
end

function M.sync()
  util.notify("syncing…")
  catalog.sync(function(err)
    if not err then leetcode_catalog.refresh_mappings() end
    vim.schedule(function()
      if err then
        util.err("catalog sync failed: " .. err)
      else
        local cat = catalog.get()
        util.notify(string.format("catalog updated: %d problems (bundle %s)",
          #cat.problems, cat.hash or "?"))
      end
    end)
  end)
  progress.sync(function(err)
    vim.schedule(function()
      if err then
        util.notify("progress not synced: " .. err, vim.log.levels.WARN)
      end
    end)
  end)
end

function M.status()
  local cat = catalog.load()
  local lc = leetcode_catalog.load()
  local s = progress.summary(config.options.list)
  print(table.concat({
    "eetCode.nvim",
    string.format("  NeetCode login %s", nc_auth.is_logged_in() and "yes" or "no"),
    string.format("  LeetCode login %s", leetcode_auth.is_logged_in() and "yes" or "no"),
    string.format("  list           %s", catalog.LIST_LABELS[config.options.list] or config.options.list),
    string.format("  language       %s", lang_info.name(config.options.lang)),
    string.format("  NeetCode       %d problems, %s (%s)",
      cat and #cat.problems or 0, catalog.age_string(), cat and cat.source or "none"),
    string.format("  LeetCode       %d problems", lc and #lc.problems or 0),
    string.format("  roadmap solved %d/%d", s.done, s.total),
    string.format("  solutions      %s", config.options.solutions_dir),
  }, "\n"))
end

function M.set_list(name)
  if not name or name == "" then
    return util.notify("list: " .. (catalog.LIST_LABELS[config.options.list] or config.options.list)
      .. "\navailable: " .. table.concat(catalog.LISTS, ", "))
  end
  if not vim.tbl_contains(catalog.LISTS, name) then
    return util.err("unknown list: " .. tostring(name) ..
      " (expected one of " .. table.concat(catalog.LISTS, ", ") .. ")")
  end
  config.options.list = name
  util.notify("list: " .. (catalog.LIST_LABELS[name] or name))
  pcall(function()
    require("eetcode.ui.roadmap").refresh()
  end)
end

function M.set_lang(name)
  if not name or name == "" then
    return util.notify("language: " .. lang_info.name(config.options.lang))
  end
  if not lang_info.info[name] then
    return util.err("unknown language: " .. tostring(name))
  end
  config.options.lang = name
  util.notify("language: " .. lang_info.name(name))
end

function M.run()
  require("eetcode.ui.problem").run()
end

function M.leetcode(query)
  require("eetcode.ui.leetcode").open(query)
end

local function open_problem(problem)
  vim.schedule(function()
    require("eetcode.ui.problem").open(problem)
  end)
end

function M.random()
  catalog.load()
  leetcode_catalog.refresh_mappings()
  leetcode_catalog.ensure(function(err, cat)
    if err and not cat then
      return vim.schedule(function() util.err("could not load LeetCode problems: " .. err) end)
    end
    local user = leetcode_auth.user()
    local premium = user and user.isPremium == true
    local unsolved, all = {}, {}
    for _, problem in ipairs(cat.problems) do
      if not problem.paid or premium or problem.id then
        table.insert(all, problem)
        if not progress.is_solved(problem) then table.insert(unsolved, problem) end
      end
    end
    local choices = #unsolved > 0 and unsolved or all
    if #choices == 0 then
      return vim.schedule(function() util.err("no accessible LeetCode problems found") end)
    end
    open_problem(choices[math.random(#choices)])
  end)
end

function M.daily()
  catalog.load()
  leetcode_catalog.refresh_mappings()
  leetcode.daily(function(err, daily)
    if err or not daily or not daily.question then
      return vim.schedule(function()
        util.err("could not load LeetCode problem of the day: " .. tostring(err or "empty response"))
      end)
    end
    leetcode_catalog.ensure(function(_, cat)
      local q = daily.question
      local problem = cat and cat.by_leetcode[q.titleSlug] or {
        provider = "leetcode",
        leetcode_id = tostring(q.questionId),
        frontend_id = tostring(q.questionFrontendId),
        name = q.title,
        leetcode = q.titleSlug,
        difficulty = q.difficulty,
        paid = q.isPaidOnly == true,
      }
      open_problem(problem)
    end)
  end)
end

function M.submit()
  require("eetcode.ui.problem").submit()
end

--- Toggle completed for the selected problem list row, or the open problem.
function M.complete()
  if vim.bo.filetype == "eetcode-roadmap-problems" then
    require("eetcode.ui.problems").toggle_complete()
    return
  elseif vim.bo.filetype == "eetcode-leetcode-problems" then
    return util.err("LeetCode progress changes only after an accepted submission")
  end
  require("eetcode.ui.problem").toggle_complete()
end

function M.setup(opts)
  config.setup(opts)
  hl.setup()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("EetCodeHighlights", { clear = true }),
    callback = hl.setup,
  })

  util.mkdirp(config.options.cache_dir)
  util.mkdirp(config.options.solutions_dir)
  return M
end

return M
