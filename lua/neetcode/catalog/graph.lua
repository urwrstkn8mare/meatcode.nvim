--- Topology of the NeetCode roadmap.
---
--- The x/y coordinates are lifted verbatim from the site's bundle (they drive the
--- ngx-graph layout on neetcode.io). We only use them to order nodes left-to-right
--- within a rank, so the TUI mirrors the visual arrangement of the web roadmap.
---
--- The edges are not present in the bundle as data, so they are transcribed here.
--- Unlike the problem catalog, roadmap topology is structural and changes very
--- rarely, so it is pinned rather than scraped.
local M = {}

---@type table<string, {x: integer, y: integer}>
M.coords = {
  ["Arrays & Hashing"] = { x = 0, y = -560 },
  ["Two Pointers"] = { x = -151, y = -358 },
  ["Stack"] = { x = 92, y = -383 },
  ["Binary Search"] = { x = -375, y = -153 },
  ["Sliding Window"] = { x = -118, y = -152 },
  ["Linked List"] = { x = 155, y = -144 },
  ["Trees"] = { x = -128, y = 47 },
  ["Tries"] = { x = -355, y = 243 },
  ["Heap / Priority Queue"] = { x = -203, y = 393 },
  ["Backtracking"] = { x = 96, y = 235 },
  ["Graphs"] = { x = 85, y = 455 },
  ["1-D Dynamic Programming"] = { x = 372, y = 435 },
  ["Intervals"] = { x = -626, y = 612 },
  ["Greedy"] = { x = -346, y = 691 },
  ["Advanced Graphs"] = { x = -101, y = 650 },
  ["2-D Dynamic Programming"] = { x = 194, y = 691 },
  ["Bit Manipulation"] = { x = 490, y = 683 },
  ["Math & Geometry"] = { x = 388, y = 901 },
}

---@type {[1]: string, [2]: string}[]
M.edges = {
  { "Arrays & Hashing", "Two Pointers" },
  { "Arrays & Hashing", "Stack" },
  { "Two Pointers", "Binary Search" },
  { "Two Pointers", "Sliding Window" },
  { "Two Pointers", "Linked List" },
  { "Binary Search", "Trees" },
  { "Sliding Window", "Trees" },
  { "Linked List", "Trees" },
  { "Trees", "Tries" },
  { "Trees", "Heap / Priority Queue" },
  { "Trees", "Backtracking" },
  { "Backtracking", "Graphs" },
  { "Backtracking", "1-D Dynamic Programming" },
  { "Heap / Priority Queue", "Intervals" },
  { "Heap / Priority Queue", "Greedy" },
  { "Heap / Priority Queue", "Advanced Graphs" },
  { "Graphs", "Advanced Graphs" },
  { "Graphs", "2-D Dynamic Programming" },
  { "1-D Dynamic Programming", "2-D Dynamic Programming" },
  { "1-D Dynamic Programming", "Bit Manipulation" },
  { "2-D Dynamic Programming", "Math & Geometry" },
  { "Bit Manipulation", "Math & Geometry" },
}

--- Short labels for narrow terminals.
M.short_names = {
  ["Arrays & Hashing"] = "Arrays & Hash",
  ["Heap / Priority Queue"] = "Heap / PQ",
  ["1-D Dynamic Programming"] = "1-D DP",
  ["2-D Dynamic Programming"] = "2-D DP",
  ["Advanced Graphs"] = "Adv. Graphs",
  ["Bit Manipulation"] = "Bit Manip.",
  ["Math & Geometry"] = "Math & Geo",
}

function M.parents(node)
  local out = {}
  for _, e in ipairs(M.edges) do
    if e[2] == node then
      table.insert(out, e[1])
    end
  end
  return out
end

function M.children(node)
  local out = {}
  for _, e in ipairs(M.edges) do
    if e[1] == node then
      table.insert(out, e[2])
    end
  end
  return out
end

--- Layer the DAG so every node sits strictly below all of its parents, then sort
--- each layer by the site's x coordinate to preserve the familiar arrangement.
---@return string[][] ranks
function M.ranks()
  local depth = {}

  local function resolve(node, seen)
    if depth[node] then
      return depth[node]
    end
    seen = seen or {}
    if seen[node] then
      return 0 -- defensive: the roadmap is acyclic, but never loop forever
    end
    seen[node] = true

    local best = 0
    for _, p in ipairs(M.parents(node)) do
      best = math.max(best, resolve(p, seen) + 1)
    end
    seen[node] = nil
    depth[node] = best
    return best
  end

  local by_rank = {}
  local max_rank = 0
  for name in pairs(M.coords) do
    local d = resolve(name)
    by_rank[d] = by_rank[d] or {}
    table.insert(by_rank[d], name)
    max_rank = math.max(max_rank, d)
  end

  local out = {}
  for i = 0, max_rank do
    local row = by_rank[i] or {}
    table.sort(row, function(a, b)
      return M.coords[a].x < M.coords[b].x
    end)
    table.insert(out, row)
  end
  return out
end

--- Flat, top-to-bottom ordering of every topic (rank order, then x order).
function M.ordered_nodes()
  local out = {}
  for _, row in ipairs(M.ranks()) do
    for _, n in ipairs(row) do
      table.insert(out, n)
    end
  end
  return out
end

return M
