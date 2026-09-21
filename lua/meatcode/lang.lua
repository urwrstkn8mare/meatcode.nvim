--- Language metadata, mirroring the table in neetcode.io's bundle.
local M = {}

M.info = {
  c = { name = "C", ext = "c", ft = "c" },
  cpp = { name = "C++", ext = "cpp", ft = "cpp" },
  csharp = { name = "C#", ext = "cs", ft = "cs" },
  java = { name = "Java", ext = "java", ft = "java" },
  python = { name = "Python", ext = "py", ft = "python" },
  javascript = { name = "JavaScript", ext = "js", ft = "javascript" },
  typescript = { name = "TypeScript", ext = "ts", ft = "typescript" },
  go = { name = "Go", ext = "go", ft = "go" },
  ruby = { name = "Ruby", ext = "rb", ft = "ruby" },
  swift = { name = "Swift", ext = "swift", ft = "swift" },
  kotlin = { name = "Kotlin", ext = "kt", ft = "kotlin" },
  rust = { name = "Rust", ext = "rs", ft = "rust" },
  scala = { name = "Scala", ext = "scala", ft = "scala" },
  dart = { name = "Dart", ext = "dart", ft = "dart" },
  sql = { name = "PostgreSQL", ext = "sql", ft = "sql" },
}

function M.ext(lang)
  local info = M.info[lang]
  return info and info.ext or "txt"
end

function M.filetype(lang)
  local info = M.info[lang]
  return info and info.ft or "text"
end

function M.name(lang)
  local info = M.info[lang]
  return info and info.name or lang
end

function M.all()
  return vim.tbl_keys(M.info)
end

return M
