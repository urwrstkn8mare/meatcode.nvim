local auth = require("meatcode.api.lintcode_auth")
local client = require("meatcode.api.client")
local config = require("meatcode.config")

local M = {}

local API = "https://apiv1.lintcode.com"
local PAGE_SIZE = 200
local PAGE_DELAY_MS = 150

local LANG_TO_LINTCODE = {
  python = "python3",
  cpp = "cpp",
}

local LINTCODE_TO_LANG = {
  python = "python",
  python2 = "python",
  python3 = "python",
  cpp = "cpp",
}

local function decode(name, cb)
  return function(err, res)
    if err then return cb(err, nil) end
    local ok, body = pcall(vim.json.decode, res.body or "")
    if not ok or type(body) ~= "table" then
      return cb(string.format("%s: bad JSON (HTTP %s)", name, tostring(res.status)), nil)
    end
    if res.status < 200 or res.status >= 300 or body.success == false then
      return cb(string.format("%s: %s", name,
        tostring(body.detail ~= "" and body.detail or body.message or ("HTTP " .. res.status))), nil)
    end
    local data = body.data
    if data == vim.NIL then data = nil end
    cb(nil, data, body)
  end
end

local function request(name, opts, cb)
  opts.headers = vim.tbl_extend("force", auth.headers(), opts.headers or {})
  if opts.method == "POST" then
    opts.headers["Content-Type"] = "application/json"
    opts.headers["Origin"] = "https://www.lintcode.com"
    opts.headers["Referer"] = "https://www.lintcode.com/"
  end
  client.request(opts, decode(name, cb))
end

function M.lang(lang)
  return LANG_TO_LINTCODE[lang] or lang
end

local function tag_names(items)
  local out = {}
  for _, item in ipairs(type(items) == "table" and items or {}) do
    local name = type(item) == "table" and (item.name or item.tag_name) or item
    if type(name) == "string" and name ~= "" then table.insert(out, name) end
  end
  return out
end

local function description(data)
  local blocks = { data.description }
  if type(data.example) == "string" and vim.trim(data.example) ~= "" then
    table.insert(blocks, "**Examples**\n\n" .. data.example)
  end
  local notice = data.new_notice or data.notice
  if type(notice) == "string" and vim.trim(notice) ~= "" then
    table.insert(blocks, "**Notes**\n\n" .. notice)
  end
  if type(data.challenge) == "string" and vim.trim(data.challenge) ~= "" then
    table.insert(blocks, "**Challenge**\n\n" .. data.challenge)
  end
  return table.concat(vim.tbl_filter(function(value)
    return type(value) == "string" and vim.trim(value) ~= ""
  end, blocks), "\n\n")
end

function M.problem(problem_id, lang, cb)
  local id = tostring(problem_id)
  request("problem", {
    url = string.format("%s/v2/api/problems/%s/?lang=2", API, id),
  }, function(err, data)
    if err then return cb(err, nil) end
    if type(data) ~= "table" then return cb("unknown LintCode problem: " .. id, nil) end

    local starter_url = string.format("%s/new/api/problems/%s/reset/?scene=1&language=%s",
      API, id, vim.uri_encode(M.lang(lang), "rfc2396"))
    request("starter code", { url = starter_url }, function(starter_err, starter)
      if starter_err then return cb(starter_err, nil) end
      local available, seen = {}, {}
      for _, remote in ipairs(type(data.accept_languages) == "table" and data.accept_languages or {}) do
        local local_name = LINTCODE_TO_LANG[remote]
        if local_name and not seen[local_name] then
          seen[local_name] = true
          table.insert(available, local_name)
        end
      end
      local code = type(starter) == "table" and starter.code or ""
      cb(nil, {
        provider = "lintcode",
        question_id = id,
        name = data.title or data.unique_name,
        slug = data.unique_name,
        difficulty = ({ [0] = "Naive", "Easy", "Medium", "Hard" })[tonumber(data.level)] or "Unknown",
        paid_only = data.is_locked == true,
        description = description(data),
        starterCode = { [lang] = type(code) == "string" and code or "" },
        availableLanguages = available,
        custom_test_cases = type(data.testcase_sample) == "string" and { data.testcase_sample } or {},
        test_case_count = 0,
        topics = tag_names(data.tags),
        companies = tag_names(data.company_tags),
      })
    end)
  end)
end

--- Resolve the numeric LintCode id using the redirect maintained for LeetCode slugs.
function M.resolve_leetcode_slug(slug, cb)
  client.request({ url = "https://www.lintcode.com/problem/" .. slug .. "/" }, function(err, res)
    if err then return cb(err, nil) end
    local id = res.effective_url and res.effective_url:match("/problem/(%d+)/?$")
    cb(nil, id)
  end)
end

function M.problems(cb)
  local all, page, expected = {}, 1, nil
  local function step()
    local url = string.format("%s/new/api/problems/?_format=new&page_size=%d&page=%d", API, PAGE_SIZE, page)
    request("problem list", { url = url }, function(err, rows, envelope)
      if err then return cb(err, nil) end
      if type(rows) ~= "table" then return cb("LintCode returned an unexpected problem list", nil) end
      vim.list_extend(all, rows)
      expected = expected or tonumber(envelope and envelope.count) or #all
      if #all < expected and #rows > 0 then
        page = page + 1
        return vim.defer_fn(step, PAGE_DELAY_MS)
      end
      cb(nil, all)
    end)
  end
  step()
end

local function poll(submission_id, attempts, cb)
  request("submission result", {
    url = string.format("%s/new/api/submissions/refresh/?id=%s", API, submission_id),
  }, function(err, data)
    if err then return cb(err, nil) end
    if type(data) ~= "table" then return cb("LintCode returned an empty submission result", nil) end
    if data.judge_finished == true or data.judgeFinished == true then return cb(nil, data) end
    if attempts <= 0 then return cb("LintCode did not finish judging the submission", nil) end
    vim.defer_fn(function() poll(submission_id, attempts - 1, cb) end, 1000)
  end)
end

function M.submit(problem_id, code, lang, cb)
  if not auth.is_logged_in() then
    return cb("not logged in to LintCode — run :MeatCode login lintcode", nil)
  end
  request("submission", {
    url = API .. "/new/api/submissions/",
    method = "POST",
    timeout = 60,
    body = vim.json.encode({
      is_test_submission = false,
      problem_id = tonumber(problem_id) or problem_id,
      language = M.lang(lang),
      source = 99,
      code = code,
    }),
  }, function(err, data)
    if err then return cb(err, nil) end
    local id = type(data) == "table" and data.id or data
    if not id then return cb("LintCode rejected the submission", nil) end
    poll(id, math.max(30, math.floor(config.options.timeout or 30)), cb)
  end)
end

return M
