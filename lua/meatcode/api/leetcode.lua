local auth = require("meatcode.api.leetcode_auth")
local client = require("meatcode.api.client")
local config = require("meatcode.config")
local examples = require("meatcode.api.examples")
local util = require("meatcode.util")

local M = {}

local SCHEMA = util.META_SCHEMA

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

local QUESTION_ID_QUERY = [[
query questionId($titleSlug: String!) {
  question(titleSlug: $titleSlug) { questionId }
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

local EDITORIAL_QUERY = [[
query editorial($titleSlug: String!) {
  question(titleSlug: $titleSlug) {
    solution { canSeeDetail paidOnly content }
  }
}
]]

local PLAYGROUND_QUERY = [[
query playground($uuid: String!) {
  allPlaygroundCodes(uuid: $uuid) { code langSlug }
}
]]

local COMMUNITY_QUERY = [[
query community($titleSlug: String!) {
  questionSolutions(filters: {
    questionSlug: $titleSlug,
    first: 30,
    skip: 0,
    orderBy: most_votes
  }) {
    solutions { id title solutionTags { name } post { content } }
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
      decoded = nil
    end
    -- An error status is the failure to report even when its body (e.g. an
    -- HTML 500 page) is not JSON.
    if res.status < 200 or res.status >= 300 then
      local msg = decoded and (decoded.error or (decoded.errors and decoded.errors[1] and decoded.errors[1].message))
      return cb(string.format("%s: HTTP %d%s", name, res.status,
        msg and (" — " .. tostring(msg)) or ""), nil)
    end
    if not decoded then
      return cb(string.format("%s: bad JSON (HTTP %s)", name, tostring(res.status)), nil)
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

--- Official editorial implementations, in the editorial's approach order.
--- LeetCode stores the actual code in playgrounds embedded as iframes.
function M.editorial_solutions(slug, lang, cb)
  graphql("editorial", EDITORIAL_QUERY, { titleSlug = slug }, function(err, data)
    if err then return cb(err, nil) end
    local solution = data and data.question and data.question.solution
    if type(solution) ~= "table" or solution.canSeeDetail ~= true
      or type(solution.content) ~= "string" then
      return cb(nil, {})
    end
    local uuids, seen = {}, {}
    for uuid in solution.content:gmatch("/playground/([%w_%-]+)/shared") do
      if not seen[uuid] then
        seen[uuid] = true
        table.insert(uuids, uuid)
      end
    end
    local out, index = {}, 1
    local function step()
      local uuid = uuids[index]
      if not uuid then return cb(nil, out) end
      index = index + 1
      graphql("editorial playground", PLAYGROUND_QUERY, { uuid = uuid }, function(_, payload)
        for _, item in ipairs(type(payload and payload.allPlaygroundCodes) == "table"
          and payload.allPlaygroundCodes or {}) do
          if LEETCODE_TO_LANG[item.langSlug] == lang
            and type(item.code) == "string" and vim.trim(item.code) ~= "" then
            table.insert(out, item.code)
          end
        end
        step()
      end)
    end
    step()
  end)
end

--- Most-voted community implementations, preserving LeetCode's vote ordering.
function M.community_solutions(slug, lang, cb)
  graphql("community solutions", COMMUNITY_QUERY, { titleSlug = slug }, function(err, data)
    if err then return cb(err, nil) end
    local result = data and data.questionSolutions
    local out = {}
    for _, solution in ipairs(type(result and result.solutions) == "table" and result.solutions or {}) do
      local post = solution.post
      local tags = {}
      for _, tag in ipairs(type(solution.solutionTags) == "table" and solution.solutionTags or {}) do
        tags[(tag.name or ""):lower()] = true
      end
      local title = type(solution.title) == "string" and solution.title:lower() or ""
      local labelled = lang == "python"
        and (tags.python == true or tags.python3 == true or title:find("python", 1, true))
        or lang == "cpp"
        and (tags["c++"] == true or tags.cpp == true
          or title:find("c++", 1, true) or title:find("cpp", 1, true))
      for _, code in ipairs(examples.code_blocks(
        type(post) == "table" and post.content or "", lang, labelled and true or false)) do
        table.insert(out, {
          code = code,
          id = tostring(solution.id or ""),
          title = solution.title,
        })
      end
    end
    cb(nil, out)
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

    local topics = {}
    for _, tag in ipairs(type(q.topicTags) == "table" and q.topicTags or {}) do
      if type(tag.name) == "string" and tag.name ~= "" then table.insert(topics, tag.name) end
    end

    local cases = type(q.exampleTestcaseList) == "table" and q.exampleTestcaseList or {}
    local meta_data = type(q.metaData) == "string" and q.metaData or nil
    local decoded = meta_data and select(2, pcall(vim.json.decode, meta_data)) or nil
    -- Design problems name their class in `metaData`; encode/decode pairs
    -- (Codec, ...) do not, and show up as a Python starter implementing
    -- something other than `Solution`.
    local classname = type(decoded) == "table" and type(decoded.classname) == "string"
      and decoded.classname or nil
    local declared = (starter.python or ""):match("\nclass%s+([%w_]+)")
      or (starter.python or ""):match("^class%s+([%w_]+)")
    local class_like = classname ~= nil or (declared ~= nil and declared ~= "Solution")

    -- The statement prints the answer for every example it shows, which is the
    -- only oracle LeetCode publishes. Keep it only when it lines up exactly with
    -- the example inputs: a partial parse would judge a case against the wrong
    -- answer. Premium problems ship an empty statement, so they yield nothing.
    local outputs = examples.leetcode(q.content)
    if #outputs ~= #cases then outputs = {} end

    cb(nil, {
      provider = "leetcode",
      schema = SCHEMA,
      question_id = tostring(q.questionId),
      frontend_id = tostring(q.questionFrontendId),
      name = q.title,
      difficulty = q.difficulty,
      paid_only = q.isPaidOnly == true,
      description = type(q.content) == "string" and q.content or "",
      starterCode = starter,
      availableLanguages = available,
      custom_test_cases = cases,
      expected_outputs = outputs,
      test_case_type = class_like and "class" or "function",
      hints = type(q.hints) == "table" and q.hints or {},
      topics = topics,
      meta_data = meta_data,
    })
  end)
end

--- The internal `questionId` the submit endpoint keys on (not the number shown
--- on the site), for callers that only hold the slug.
function M.question_id(slug, cb)
  graphql("question id", QUESTION_ID_QUERY, { titleSlug = slug }, function(err, data)
    if err then
      return cb(err, nil)
    end
    local q = data and data.question
    local id = type(q) == "table" and q.questionId
    if (type(id) ~= "string" and type(id) ~= "number") or id == "" then
      return cb("unknown LeetCode problem: " .. slug, nil)
    end
    cb(nil, tostring(id))
  end)
end

local function submission_error(decoded)
  if type(decoded) ~= "table" then
    return "empty response"
  end
  return decoded.error or decoded.detail or decoded.message
end

--- Polls the endpoint leetcode.com itself polls. Judging runs `state` PENDING
--- → STARTED → … → SUCCESS; on problems with stated restrictions an AI check
--- (`ai_state` PENDING → STARTED → SUCCESS) then has the final say and can
--- turn passing tests into "Restrictions Failed". The legacy `/check/` only
--- reports the tests, so it answers "Accepted" for code LeetCode rejects.
local function check(submission_id, attempts, cb)
  request({
    name = "submission result",
    url = string.format("%s/submissions/detail/%s/v2/check/", BASE, submission_id),
    method = "GET",
    timeout = 30,
  }, function(err, data)
    if err then
      return cb(err, nil)
    end
    local state, ai_state = data.state, data.ai_state
    if ai_state == "FAILURE" then
      return cb("LeetCode's restrictions check failed to run on the submission", nil)
    end
    if type(state) ~= "string" or state == "FAILURE" or state == "REVOKED" then
      return cb("LeetCode failed to judge the submission (state: "
        .. (type(state) == "string" and state or "none") .. ")", nil)
    end
    if state == "SUCCESS" and ai_state ~= "PENDING" and ai_state ~= "STARTED" then
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
    return cb("not logged in to LeetCode — run :MeatCode login leetcode", nil)
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
    return cb("not logged in to LeetCode — run :MeatCode login leetcode", nil)
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
