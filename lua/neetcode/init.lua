local auth = require("neetcode.api.auth")
local catalog = require("neetcode.catalog")
local config = require("neetcode.config")
local hl = require("neetcode.ui.highlight")
local lang_info = require("neetcode.lang")
local progress = require("neetcode.progress")
local util = require("neetcode.util")

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
  require("neetcode.ui.roadmap").open()
end

function M.login(token)
  local function finish(t)
    auth.login(t, function(err)
      vim.schedule(function()
        if err then
          return util.err("login failed: " .. err)
        end
        util.notify("logged in to NeetCode")
        progress.sync(function() end)
      end)
    end)
  end

  if token and token ~= "" then
    return finish(token)
  end

  require("neetcode.ui.login").open(TOKEN_SNIPPET, finish)
end

function M.logout()
  auth.logout()
  util.notify("logged out")
end

function M.sync()
  util.notify("syncing…")
  catalog.sync(function(err)
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
  local s = progress.summary(config.options.list)
  print(table.concat({
    "neetcode.nvim",
    string.format("  logged in     %s", auth.is_logged_in() and "yes" or "no"),
    string.format("  list          %s", catalog.LIST_LABELS[config.options.list] or config.options.list),
    string.format("  language      %s", lang_info.name(config.options.lang)),
    string.format("  catalog       %d problems, %s (%s)",
      cat and #cat.problems or 0, catalog.age_string(), cat and cat.source or "none"),
    string.format("  solved        %d/%d", s.done, s.total),
    string.format("  solutions     %s", config.options.solutions_dir),
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
    require("neetcode.ui.roadmap").refresh()
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
  require("neetcode.ui.problem").run()
end

function M.submit()
  require("neetcode.ui.problem").submit()
end

function M.setup(opts)
  config.setup(opts)
  hl.setup()

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("NeetCodeHighlights", { clear = true }),
    callback = hl.setup,
  })

  util.mkdirp(config.options.cache_dir)
  util.mkdirp(config.options.solutions_dir)
  return M
end

return M
