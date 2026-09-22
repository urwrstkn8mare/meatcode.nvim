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

--- Snippet the user runs in their browser console on lintcode.com. The access
--- token in `Authorization` headers lives for about eight minutes, so what is
--- wanted is the week-long refresh token (localStorage `@JWT:REFRESH_TOKEN`);
--- the plugin mints access tokens from it. Every JWT in web storage is
--- inspected rather than trusting one key name, and `token_type` in the
--- payload decides which one is the refresh token.
local LINTCODE_SNIPPET = [[
(() => {
  const re = /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g;
  const found = new Set();
  const scan = v => { if (typeof v === 'string') for (const m of v.matchAll(re)) found.add(m[0]); };
  for (const store of [localStorage, sessionStorage]) {
    for (const k of Object.keys(store)) {
      const v = store.getItem(k);
      scan(v);
      try { JSON.parse(v, (_, x) => (scan(x), x)); } catch (e) {}
    }
  }
  scan(document.cookie);
  const claims = t => { try { return JSON.parse(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))); } catch (e) { return {}; } };
  const now = Date.now() / 1000;
  const fresh = [...found].filter(t => (claims(t).exp || 0) > now);
  const t = fresh.find(t => claims(t).token_type === 'refresh') || fresh[0];
  console.log(t ? 'Bearer ' + t : 'NOT FOUND - sign in on this tab, reload, and rerun');
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
  if provider == "neetcode" then
    return login_ui.open({
      label = backend.label,
      steps = {
        "Open https://neetcode.io and sign in.",
        "In browser DevTools, open Application (Chrome) or Storage (Firefox).",
        "Open IndexedDB > firebaseLocalStorageDb > firebaseLocalStorage.",
        "Expand the auth user value > stsTokenManager > refreshToken.",
        "Copy the refreshToken value (without quotes), then press p to paste it.",
      },
      alternative = {
        "Alternative: press y to copy the script below, then run it in the",
        "browser console on neetcode.io and paste the token it prints.",
      },
      prompt = "NeetCode refresh token: ",
      snippet = TOKEN_SNIPPET,
      finish = finish,
    })
  end
  if provider == "lintcode" then
    return login_ui.open({
      label = backend.label,
      steps = {
        "Open https://www.lintcode.com and sign in.",
        "Open the browser console (DevTools > Console).",
        "Press y here to copy the script below, then run it in that console.",
        "Copy the `Bearer eyJ...` line it prints (a week-long refresh token).",
        "Return here and press p to paste it.",
      },
      alternative = {
        "By hand instead: DevTools > Application > Local Storage and copy the",
        "@JWT:REFRESH_TOKEN value. The Authorization header off a network",
        "request also works, but that access token expires in minutes.",
      },
      prompt = "LintCode token: ",
      snippet = LINTCODE_SNIPPET,
      finish = finish,
    })
  end
  login_ui.open_header("leetcode", backend.label, {
    "Open https://leetcode.com and sign in.",
    "Open browser DevTools > Network, then reload the page.",
    "Select a request to leetcode.com.",
    "Under Request Headers, copy the complete Cookie header value.",
    "Return here and press p to paste it.",
  }, "LeetCode Cookie header: ",
    "The cookie must contain both LEETCODE_SESSION and csrftoken.", finish)
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

local function open_problem(problem, source)
  vim.schedule(function()
    if source then util.notify(source) end
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
    local pick = choices[math.random(#choices)]
    local labels = {}
    for _, name in ipairs(providers.NAMES) do
      if providers.available(pick, name) then table.insert(labels, providers.get(name).label) end
    end
    open_problem(pick, string.format("random from merged catalog · %s (%s)",
      pick.name, table.concat(labels, "/")))
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
      open_problem(problem, "LeetCode problem of the day · " .. problem.name)
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
