local auth = require("eetcode.api.leetcode_auth")
local client = require("eetcode.api.client")
local config = require("eetcode.config")

local M = {}

local BASE = "https://leetcode.com"

local DAILY_QUERY = [[
query questionOfToday {
  activeDailyCodingChallengeQuestion {
    date
    link
    question {
      questionId
      questionFrontendId
      title
      titleSlug
      difficulty
      isPaidOnly
    }
  }
}
]]

local PROBLEMS_QUERY = [[
query problemsetQuestionList($skip: Int!, $limit: Int!) {
  problemsetQuestionList: questionList(categorySlug: "", skip: $skip, limit: $limit, filters: {}) {
    total: totalNum
    questions: data {
      questionId
      questionFrontendId
      title
      titleSlug
      difficulty
      isPaidOnly
      status
    }
  }
}
]]

local SUBMISSIONS_QUERY = [[
query submissionList($offset: Int!, $limit: Int!, $lastKey: String) {
  submissionList(offset: $offset, limit: $limit, lastKey: $lastKey) {
    lastKey
    hasNext
    submissions {
      id
      lang
      timestamp
      statusDisplay
      titleSlug
    }
  }
}
]]

local QUESTION_QUERY = [[
query questionData($titleSlug: String!) {
  question(titleSlug: $titleSlug) {
    questionId
    questionFrontendId
    title
    titleSlug
    isPaidOnly
    difficulty
    content
    codeSnippets { lang langSlug code }
    exampleTestcaseList
    metaData
    hints
    topicTags { name slug }
  }
}
]]

local STREAK_QUERY = [[
query getStreakCounter {
  streakCounter {
    streakCount
    daysSkipped
    currentDayCompleted
  }
}
]]

local LANG_TO_LEETCODE = {
  c = "c",
  cpp = "cpp",
  csharp = "csharp",
  java = "java",
  python = "python3",
  javascript = "javascript",
  typescript = "typescript",
  go = "golang",
  ruby = "ruby",
  swift = "swift",
  kotlin = "kotlin",
  rust = "rust",
  scala = "scala",
  dart = "dart",
  sql = "mysql",
}

local LEETCODE_TO_LANG = {}
for local_name, remote_name in pairs(LANG_TO_LEETCODE) do
  LEETCODE_TO_LANG[remote_name] = local_name
end
LEETCODE_TO_LANG.python = "python"
LEETCODE_TO_LANG.python3 = "python"

local function decode_response(name, cb)
  return function(err, res)
    if err then
      return cb(err, nil)
    end
    local ok, decoded = pcall(vim.json.decode, res.body or "")
    if not ok or type(decoded) ~= "table" then
      return cb(string.format("%s: bad JSON (HTTP %s)", name, tostring(res.status)), nil)
    end
    if res.status < 200 or res.status >= 300 then
      local msg = decoded.error or (decoded.errors and decoded.errors[1] and decoded.errors[1].message)
      return cb(string.format("%s: HTTP %d%s", name, res.status,
        msg and (" — " .. tostring(msg)) or ""), nil)
    end
    if decoded.errors and decoded.errors[1] then
      return cb(name .. ": " .. tostring(decoded.errors[1].message), nil)
    end
    cb(nil, decoded)
  end
end

local function request(opts, cb)
  opts.headers = vim.tbl_extend("force", auth.headers(), opts.headers or {})
  client.request(opts, decode_response(opts.name or "LeetCode", cb))
end

local function graphql(name, query, variables, cb)
  request({
    name = name,
    url = BASE .. "/graphql/",
    method = "POST",
    body = vim.json.encode({ query = query, variables = variables or vim.empty_dict() }),
  }, function(err, decoded)
    cb(err, decoded and decoded.data or nil)
  end)
end

function M.lang(lang)
  return LANG_TO_LEETCODE[lang] or lang
end

-- Requests one page at a time rather than one giant call, matching what the
-- site itself does.
local PROBLEMS_PAGE_SIZE = 100
local PROBLEMS_PAGE_DELAY_MS = 200

--- The full LeetCode catalog (~3000 problems), via the GraphQL question list.
--- The legacy REST `/api/problems/algorithms/` endpoint carries the same
--- bulk-export bot-protection risk `/api/submissions/` did.
---@param cb fun(err: string|nil, problems: table[]|nil)
function M.problems(cb)
  local all, skip = {}, 0
  local function step()
    graphql("problem list", PROBLEMS_QUERY, { skip = skip, limit = PROBLEMS_PAGE_SIZE }, function(err, data)
      if err then
        return cb(err, nil)
      end
      local list = data and data.problemsetQuestionList
      if type(list) ~= "table" or type(list.questions) ~= "table" then
        return cb("LeetCode returned an unexpected problem list response", nil)
      end
      vim.list_extend(all, list.questions)
      skip = skip + PROBLEMS_PAGE_SIZE
      if #list.questions > 0 and skip < (tonumber(list.total) or 0) then
        return vim.defer_fn(step, PROBLEMS_PAGE_DELAY_MS)
      end
      cb(nil, all)
    end)
  end
  step()
end

function M.daily(cb)
  graphql("daily problem", DAILY_QUERY, nil, function(err, data)
    cb(err, data and data.activeDailyCodingChallengeQuestion or nil)
  end)
end

function M.streak(cb)
  if not auth.is_logged_in() then
    return cb(nil, nil)
  end
  graphql("streak", STREAK_QUERY, nil, function(err, data)
    cb(err, data and data.streakCounter or nil)
  end)
end

function M.problem(slug, cb)
  graphql("problem", QUESTION_QUERY, { titleSlug = slug }, function(err, data)
    if err then
      return cb(err, nil)
    end
    local q = data and data.question
    if not q or q == vim.NIL then
      return cb("unknown LeetCode problem: " .. slug, nil)
    end

    local starter, available = {}, {}
    local snippets = type(q.codeSnippets) == "table" and q.codeSnippets or {}
    for _, snippet in ipairs(snippets) do
      local lang = LEETCODE_TO_LANG[snippet.langSlug]
      if lang and not starter[lang] then
        starter[lang] = snippet.code
        table.insert(available, lang)
      end
    end

    cb(nil, {
      provider = "leetcode",
      question_id = tostring(q.questionId),
      frontend_id = tostring(q.questionFrontendId),
      name = q.title,
      difficulty = q.difficulty,
      paid_only = q.isPaidOnly == true,
      description = type(q.content) == "string" and q.content or "",
      starterCode = starter,
      availableLanguages = available,
      custom_test_cases = type(q.exampleTestcaseList) == "table" and q.exampleTestcaseList or {},
      hints = type(q.hints) == "table" and q.hints or {},
      topic_tags = type(q.topicTags) == "table" and q.topicTags or {},
      meta_data = type(q.metaData) == "string" and q.metaData or nil,
    })
  end)
end

local function submission_error(decoded)
  if type(decoded) ~= "table" then
    return "empty response"
  end
  return decoded.error or decoded.detail or decoded.message
end

local function check(submission_id, attempts, cb)
  request({
    name = "submission result",
    url = string.format("%s/submissions/detail/%s/check/", BASE, submission_id),
    method = "GET",
    timeout = 30,
  }, function(err, data)
    if err then
      return cb(err, nil)
    end
    if data.state == "SUCCESS" or data.status_code then
      return cb(nil, data)
    end
    if attempts <= 0 then
      return cb("LeetCode did not finish judging the submission", nil)
    end
    vim.defer_fn(function()
      check(submission_id, attempts - 1, cb)
    end, 750)
  end)
end

function M.submit(slug, question_id, code, lang, cb)
  if not auth.is_logged_in() then
    return cb("not logged in to LeetCode — run :EetCode login leetcode", nil)
  end
  request({
    name = "submission",
    url = string.format("%s/problems/%s/submit/", BASE, slug),
    method = "POST",
    timeout = 60,
    headers = { ["Referer"] = string.format("%s/problems/%s/", BASE, slug) },
    body = vim.json.encode({
      lang = M.lang(lang),
      question_id = tostring(question_id),
      typed_code = code,
    }),
  }, function(err, data)
    if err then
      return cb(err, nil)
    end
    local id = data and data.submission_id
    if not id then
      return cb("LeetCode rejected the submission: " .. tostring(submission_error(data)), nil)
    end
    check(id, math.max(10, math.floor((config.options.timeout or 30) * 2)), cb)
  end)
end

--- One page of the account's full submission history (all problems, most
--- recent first), via the same GraphQL endpoint the site itself uses.
---
--- The legacy REST `/api/submissions/` endpoint returns HTTP 403 for
--- non-browser clients under LeetCode's bot protection even with a valid
--- session cookie; this query does not.
---@param offset integer
---@param limit integer
---@param last_key string|nil pagination cursor from the previous page
---@param cb fun(err: string|nil, page: {submissions_dump: table[], has_next: boolean, last_key: string|nil}|nil)
function M.submissions_page(offset, limit, last_key, cb)
  if not auth.is_logged_in() then
    return cb("not logged in to LeetCode — run :EetCode login leetcode", nil)
  end
  graphql("submission history", SUBMISSIONS_QUERY,
    { offset = offset, limit = limit, lastKey = last_key },
    function(err, data)
      if err then
        return cb(err, nil)
      end
      local list = data and data.submissionList
      if type(list) ~= "table" then
        return cb("LeetCode returned an unexpected submission history response", nil)
      end
      local dump = {}
      for _, sub in ipairs(type(list.submissions) == "table" and list.submissions or {}) do
        table.insert(dump, {
          id = tonumber(sub.id),
          lang = sub.lang,
          status_display = sub.statusDisplay,
          title_slug = sub.titleSlug,
          timestamp = tonumber(sub.timestamp),
        })
      end
      cb(nil, { submissions_dump = dump, has_next = list.hasNext == true, last_key = list.lastKey })
    end)
end

return M
