local catalog = require("meatcode.catalog")
local config = require("meatcode.config")
local hl = require("meatcode.ui.highlight")
local lang_info = require("meatcode.lang")
local leetcode = require("meatcode.api.leetcode")
local problem_catalog = require("meatcode.catalog.problems")
local progress = require("meatcode.progress")
local providers = require("meatcode.providers")
local util = require("meatcode.util")

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

function M.home()
  require("meatcode.ui.home").open()
end

function M.roadmap(list)
  if list and list ~= "" then
    if not vim.tbl_contains(catalog.LISTS, list) then
      return util.err("unknown roadmap: " .. tostring(list)
        .. " (expected one of " .. table.concat(catalog.LISTS, ", ") .. ")")
    end
    config.options.list = list
  end
  require("meatcode.ui.roadmap").open()
end

function M.login(provider, credential)
  local backend = providers.get(provider)
  if not backend then
    return util.err("usage: :MeatCode login " .. table.concat(providers.NAMES, "|"))
  end

  local function finish(value)
    backend.auth.login(value, function(err)
      vim.schedule(function()
        if err then return util.err(provider .. " login failed: " .. err) end
        util.notify("logged in to " .. backend.label)
        progress.sync(function() end)
      end)
    end)
  end

  if credential and credential ~= "" then return finish(credential) end
  local login_ui = require("meatcode.ui.login")
  if provider == "neetcode" then return login_ui.open(TOKEN_SNIPPET, finish) end
  local required = provider == "leetcode"
    and "The cookie must contain both LEETCODE_SESSION and csrftoken."
    or "Copy the complete header; LintCode may use more than one session cookie."
  local host = provider == "leetcode" and "leetcode.com" or "www.lintcode.com"
  login_ui.open_cookie(provider, backend.label, host, required, finish)
end

function M.logout(provider)
  local backend = providers.get(provider)
  if not backend then
    return util.err("usage: :MeatCode logout " .. table.concat(providers.NAMES, "|"))
  end
  backend.auth.logout()
  util.notify("logged out of " .. backend.label)
end

function M.status()
  util.err(":MeatCode status was removed — :MeatCode opens the homepage now")
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

function M.list(query)
  require("meatcode.ui.list").open(query)
end

local function open_problem(problem)
  vim.schedule(function()
    require("meatcode.ui.problem").open(problem)
  end)
end

function M.random()
  catalog.load()
  problem_catalog.refresh_mappings()
  problem_catalog.ensure(function(err, cat)
    if err and not cat then
      return vim.schedule(function() util.err("could not load problems: " .. err) end)
    end
    local unsolved, all = {}, {}
    for _, problem in ipairs(cat.problems) do
      local accessible = false
      for _, name in ipairs(providers.NAMES) do
        local record = problem.providers[name]
        if record and (not record.paid or providers.paid_unlocked(name)) then
          accessible = true
          break
        end
      end
      if accessible then
        table.insert(all, problem)
        if not progress.is_solved(problem) then table.insert(unsolved, problem) end
      end
    end
    local choices = #unsolved > 0 and unsolved or all
    if #choices == 0 then
      return vim.schedule(function() util.err("no accessible problems found") end)
    end
    open_problem(choices[math.random(#choices)])
  end)
end

function M.daily()
  catalog.load()
  problem_catalog.refresh_mappings()
  leetcode.daily(function(err, daily)
    if err or not daily or not daily.question then
      return vim.schedule(function()
        util.err("could not load LeetCode problem of the day: " .. tostring(err or "empty response"))
      end)
    end
    problem_catalog.ensure(function(_, cat)
      local q = daily.question
      local problem = cat and cat.by_provider.leetcode[q.titleSlug] or {
        key = "leetcode:" .. q.titleSlug,
        name = q.title,
        difficulty = q.difficulty,
        providers = {
          leetcode = {
            id = q.titleSlug,
            question_id = tostring(q.questionId),
            frontend_id = tostring(q.questionFrontendId),
            paid = q.isPaidOnly == true,
          },
        },
        topics = {},
        companies = {},
      }
      open_problem(problem)
    end)
  end)
end

function M.setup(opts)
  config.setup(opts)
  hl.setup()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("MeatCodeHighlights", { clear = true }),
    callback = hl.setup,
  })

  util.mkdirp(config.options.cache_dir)
  util.mkdirp(config.options.solutions_dir)
  return M
end

return M
