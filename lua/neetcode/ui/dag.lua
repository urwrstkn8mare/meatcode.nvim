local util = require("neetcode.util")

--- Renders the roadmap as an ASCII DAG.
---
--- Nodes are laid out in ranks (longest-path layering, ordered left-to-right by
--- the coordinates the website uses). Edges are routed through a bitmask grid so
--- that crossings and merges resolve to the correct box-drawing junctions.
local M = {}

local UP, DOWN, LEFT, RIGHT = 1, 2, 4, 8

local JUNCTION = {
  [UP] = "│", [DOWN] = "│", [LEFT] = "─", [RIGHT] = "─",
  [UP + DOWN] = "│",
  [LEFT + RIGHT] = "─",
  [DOWN + LEFT] = "╮",
  [DOWN + RIGHT] = "╭",
  [UP + LEFT] = "╯",
  [UP + RIGHT] = "╰",
  [UP + DOWN + LEFT] = "┤",
  [UP + DOWN + RIGHT] = "├",
  [UP + LEFT + RIGHT] = "┴",
  [DOWN + LEFT + RIGHT] = "┬",
  [UP + DOWN + LEFT + RIGHT] = "┼",
}

local NODE_ROWS = 4
local GAP_ROWS = 3

--- Pick a node width that fits the window.
function M.node_width(avail, ranks, preferred)
  local widest = 1
  for _, row in ipairs(ranks) do
    widest = math.max(widest, #row)
  end
  local gaps = (widest - 1) * 3
  local fit = math.floor((avail - gaps) / widest)
  return math.max(13, math.min(preferred, fit)), widest
end

---@param opts table ranks, edges, width, node_width, progress(name)->done,total, selected
function M.render(opts)
  local ranks = opts.ranks
  local node_w, widest = M.node_width(opts.width - 2, ranks, opts.node_width)
  local h_gap = 3
  local canvas_w = widest * node_w + (widest - 1) * h_gap

  local grid, marks = {}, {}
  local function cell(r, c, ch)
    grid[r] = grid[r] or {}
    grid[r][c] = ch
  end
  local function bits(r, c, mask)
    marks[r] = marks[r] or {}
    marks[r][c] = (marks[r][c] or 0) | mask
  end

  -- ---------------------------------------------------------------- layout
  local positions = {}
  local row = 0
  for ri, rank in ipairs(ranks) do
    local total_w = #rank * node_w + (#rank - 1) * h_gap
    local x = math.floor((canvas_w - total_w) / 2)
    for _, name in ipairs(rank) do
      positions[name] = { row = row, col = x, rank = ri, center = x + math.floor(node_w / 2) }
      x = x + node_w + h_gap
    end
    row = row + NODE_ROWS + (ri < #ranks and GAP_ROWS or 0)
  end
  local total_rows = row

  -- ----------------------------------------------------------------- edges
  -- Which columns each row already has a node box sitting in, so that an edge
  -- spanning more than one rank can be routed around the ranks in between.
  local occupied = {}
  for _, pos in pairs(positions) do
    for r = pos.row, pos.row + NODE_ROWS - 1 do
      occupied[r] = occupied[r] or {}
      table.insert(occupied[r], { pos.col, pos.col + node_w - 1 })
    end
  end

  local function column_free(c, r0, r1)
    if c < 0 or c > canvas_w then
      return false
    end
    for r = r0, r1 do
      for _, range in ipairs(occupied[r] or {}) do
        if c >= range[1] and c <= range[2] then
          return false
        end
      end
    end
    return true
  end

  --- Nearest column to `prefer` that stays clear of every box in r0..r1.
  local function free_column(prefer, r0, r1)
    for delta = 0, canvas_w do
      if column_free(prefer - delta, r0, r1) then
        return prefer - delta
      end
      if column_free(prefer + delta, r0, r1) then
        return prefer + delta
      end
    end
    return prefer
  end

  local function vline(col, r0, r1)
    for r = r0, r1 do
      bits(r, col, UP + DOWN)
    end
  end

  --- Horizontal run that also stitches the corner bits at both ends.
  local function hline(r, from, to)
    if from == to then
      bits(r, from, UP + DOWN)
      return
    end
    local lo, hi = math.min(from, to), math.max(from, to)
    for x = lo + 1, hi - 1 do
      bits(r, x, LEFT + RIGHT)
    end
    bits(r, from, to > from and RIGHT or LEFT)
    bits(r, to, to > from and LEFT or RIGHT)
  end

  for _, edge in ipairs(opts.edges) do
    local p, c = positions[edge[1]], positions[edge[2]]
    if p and c then
      local top = p.row + NODE_ROWS
      local bottom = c.row - 1
      if bottom >= top then
        if c.rank - p.rank <= 1 then
          local mid = top + math.floor((bottom - top) / 2)
          vline(p.center, top, mid - 1)
          bits(mid, p.center, UP)
          hline(mid, p.center, c.center)
          bits(mid, c.center, DOWN)
          vline(c.center, mid + 1, bottom)
        else
          -- Long edge: drop into the first gap, slide into a clear gutter,
          -- descend past the intervening ranks, then approach the child.
          local first_mid = top + math.floor(GAP_ROWS / 2)
          local last_mid = bottom - math.floor(GAP_ROWS / 2)
          local route = free_column(c.center, first_mid, last_mid)

          vline(p.center, top, first_mid - 1)
          bits(first_mid, p.center, UP)
          hline(first_mid, p.center, route)
          bits(first_mid, route, DOWN)

          vline(route, first_mid + 1, last_mid - 1)

          bits(last_mid, route, UP)
          hline(last_mid, route, c.center)
          bits(last_mid, c.center, DOWN)
          vline(c.center, last_mid + 1, bottom)
        end
      end
    end
  end

  for r, cols in pairs(marks) do
    for c, mask in pairs(cols) do
      cell(r, c, JUNCTION[mask] or "·")
    end
  end

  -- ----------------------------------------------------------------- nodes
  local node_spans = {}
  for name, pos in pairs(positions) do
    local done, total = opts.progress(name)
    local complete = total > 0 and done == total
    local group = complete and "NeetCodeNodeDone" or "NeetCodeNodeTodo"
    if opts.selected == name then
      group = "NeetCodeNodeSelected"
    end

    local inner = node_w - 2
    -- util.center truncates anything still too wide for the box.
    local label = (opts.short_names or {})[name] or name

    local count = string.format("%d/%d", done, total)
    local bar_w = math.max(3, inner - 2 - #count - 1)
    local filled = total > 0 and math.floor(bar_w * done / total + 0.5) or 0
    local bar = string.rep("█", filled) .. string.rep("░", bar_w - filled)
    local bar_line = " " .. bar .. " " .. count
    bar_line = util.pad(bar_line, inner)

    local rows = {
      "╭" .. string.rep("─", inner) .. "╮",
      "│" .. util.center(label, inner) .. "│",
      "│" .. bar_line .. "│",
      "╰" .. string.rep("─", inner) .. "╯",
    }

    for i, line in ipairs(rows) do
      local c = pos.col
      for _, ch in ipairs(vim.fn.split(line, "\\zs")) do
        cell(pos.row + i - 1, c, ch)
        c = c + 1
      end
    end

    table.insert(node_spans, {
      name = name,
      row = pos.row,
      col = pos.col,
      width = node_w,
      group = group,
      bar_row = pos.row + 2,
      bar_col = pos.col + 2,
      bar_filled = filled,
      bar_total = bar_w,
    })
  end

  -- ------------------------------------------------------------- serialise
  local lines, byte_index = {}, {}
  for r = 0, total_rows - 1 do
    local cells, offsets, acc = {}, {}, 0
    for c = 0, canvas_w do
      local ch = (grid[r] and grid[r][c]) or " "
      offsets[c] = acc
      acc = acc + #ch
      table.insert(cells, ch)
    end
    offsets[canvas_w + 1] = acc
    byte_index[r] = offsets
    lines[r + 1] = table.concat(cells):gsub("%s+$", "")
  end

  -- Convert cell coordinates to byte columns for extmarks.
  local spans = {}
  local function span(r, c0, c1, group)
    local off = byte_index[r]
    if off then
      table.insert(spans, { r, off[c0] or 0, off[c1] or (off[canvas_w + 1] or 0), group })
    end
  end

  for _, n in ipairs(node_spans) do
    for i = 0, NODE_ROWS - 1 do
      span(n.row + i, n.col, n.col + n.width, n.group)
    end
    span(n.bar_row, n.bar_col, n.bar_col + n.bar_filled, "NeetCodeBarFill")
    span(n.bar_row, n.bar_col + n.bar_filled, n.bar_col + n.bar_total, "NeetCodeBarEmpty")
  end

  for r, cols in pairs(marks) do
    for c in pairs(cols) do
      span(r, c, c + 1, "NeetCodeEdge")
    end
  end

  return {
    lines = lines,
    spans = spans,
    positions = positions,
    node_width = node_w,
    height = total_rows,
  }
end

M.NODE_ROWS = NODE_ROWS
M.GAP_ROWS = GAP_ROWS

return M
