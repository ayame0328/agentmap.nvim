-- agentmap の描画：graph.layout の結果をバッファへ書く
--   前回との差分だけを書き換える（変わっていない行には触らない＝ちらつかない）。
--   色は "agentmap" 名前空間の extmark で付ける。
local M = {}

M.ns = vim.api.nvim_create_namespace("agentmap")

-- 色の定義。default = true なので、色テーマや利用者の設定があればそちらが勝つ
function M.setup_highlights()
  local set = function(name, val)
    val.default = true
    vim.api.nvim_set_hl(0, name, val)
  end
  set("AgentMapPending", { fg = "#8b949e", ctermfg = 245 })
  set("AgentMapRunning", { fg = "#e3b341", ctermfg = 178, bold = true })
  set("AgentMapReview", { fg = "#58a6ff", ctermfg = 75 })
  set("AgentMapDone", { fg = "#3fb950", ctermfg = 71 })
  set("AgentMapRework", { fg = "#f85149", ctermfg = 203 })
  set("AgentMapFailed", { fg = "#f85149", ctermfg = 203, bold = true, underline = true })
  -- HUMAN CHECK の確認待ち（人が動く番）。AI が動いている黄（Running）と見分けるため紫
  set("AgentMapWaiting", { fg = "#d2a8ff", ctermfg = 176, bold = true })
  set("AgentMapEdge", { link = "Comment" })
  set("AgentMapEdgeRetry", { link = "AgentMapRework" })
  set("AgentMapEdgeSeq", { link = "Function" }) -- 段から次の段へ（順番の線）
  set("AgentMapIndex", { link = "Number" })
  set("AgentMapHeader", { link = "Title" })
  set("AgentMapDim", { link = "Comment" })
end

function M.new_cache()
  return { lines = {}, sig = {}, line_map = {}, node_rows = {} }
end

-- 印（{row0, col0, col1, hl}）を行ごとに分け、比較用の文字列も作る
local function group_marks(marks)
  local by_row, sig = {}, {}
  for _, m in ipairs(marks or {}) do
    local r = m[1]
    by_row[r] = by_row[r] or {}
    table.insert(by_row[r], m)
  end
  for r, list in pairs(by_row) do
    local parts = {}
    for _, m in ipairs(list) do parts[#parts + 1] = m[2] .. ":" .. m[3] .. ":" .. m[4] end
    sig[r] = table.concat(parts, ",")
  end
  return by_row, sig
end

local function add_marks(buf, list, lines)
  for _, m in ipairs(list or {}) do
    local line = lines[m[1] + 1] or ""
    local c0 = math.min(m[2], #line)
    local c1 = math.min(m[3], #line)
    if c1 > c0 then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, m[1], c0, { end_col = c1, hl_group = m[4] })
    end
  end
end

-- 各ノードが何行目から何行目にあるか（カーソル移動用、行は1始まり・桁はバイト0始まり）
local function build_node_rows(line_map)
  local rows = {}
  for row, list in pairs(line_map or {}) do
    for _, e in ipairs(list) do
      local r = rows[e[3]]
      if not r then
        r = { row, row, e[1], e[2], starts = {} }
        rows[e[3]] = r
      else
        r[1] = math.min(r[1], row)
        r[2] = math.max(r[2], row)
        r[3] = math.min(r[3], e[1])
        r[4] = math.max(r[4], e[2])
      end
      r.starts[row] = e[1]
    end
  end
  return rows
end

local function with_modifiable(buf, fn)
  local was = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[buf].modifiable = was
  if not ok then error(err) end
end

-- layout（graph.layout の戻り値）をバッファへ。cache を返す（次回の差分用）
function M.render(buf, layout, cache)
  cache = cache or M.new_cache()
  local new = layout.lines or {}
  local by_row, sig = group_marks(layout.marks)
  local old, oldsig = cache.lines or {}, cache.sig or {}
  local n_old, n_new = #old, #new

  with_modifiable(buf, function()
    if n_old == 0 then
      -- 初回は全部書く
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, new)
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
      for r = 0, n_new - 1 do add_marks(buf, by_row[r], new) end
      return
    end
    local text_rows, mark_rows = {}, {}
    local common = math.min(n_old, n_new)
    for r = 0, common - 1 do
      if old[r + 1] ~= new[r + 1] then
        text_rows[#text_rows + 1] = r
        mark_rows[r] = true
      elseif oldsig[r] ~= sig[r] then
        mark_rows[r] = true
      end
    end
    -- 変わった行を、連続した範囲ごとにまとめて書き換える
    local i = 1
    while i <= #text_rows do
      local a = text_rows[i]
      local b = a
      while text_rows[i + 1] == b + 1 do
        i = i + 1
        b = text_rows[i]
      end
      vim.api.nvim_buf_set_lines(buf, a, b + 1, false, vim.list_slice(new, a + 1, b + 1))
      i = i + 1
    end
    -- 行数の増減は末尾だけで処理する
    if n_new > n_old then
      vim.api.nvim_buf_set_lines(buf, n_old, n_old, false, vim.list_slice(new, n_old + 1, n_new))
      for r = n_old, n_new - 1 do mark_rows[r] = true end
    elseif n_new < n_old then
      vim.api.nvim_buf_set_lines(buf, n_new, n_old, false, {})
      -- 消えた行の印が最後の行へ寄ってくるので、最後の行も付け直す
      if n_new > 0 then mark_rows[n_new - 1] = true end
      vim.api.nvim_buf_clear_namespace(buf, M.ns, n_new, -1)
    end
    for r in pairs(mark_rows) do
      vim.api.nvim_buf_clear_namespace(buf, M.ns, r, r + 1)
      add_marks(buf, by_row[r], new)
    end
  end)

  cache.lines = new
  cache.sig = sig
  cache.line_map = layout.line_map or {}
  cache.node_rows = build_node_rows(cache.line_map)
  cache.order = layout.order or {}
  cache.mode = layout.mode
  return cache
end

-- 行 row（1始まり）・桁 col（バイト0始まり）にある Agent の id。
-- 線の上なら同じ行で一番近い箱。何も無ければ nil
function M.node_at(cache, row, col)
  local list = cache and cache.line_map and cache.line_map[row]
  if not list or #list == 0 then return nil end
  local best, bestd = nil, math.huge
  for _, e in ipairs(list) do
    if col >= e[1] and col < e[2] then return e[3] end
    local d = col < e[1] and (e[1] - col) or (col - e[2] + 1)
    if d < bestd then
      best, bestd = e[3], d
    end
  end
  return best
end

-- id の箱の位置 {row_first, row_last, col0, col1, starts = {[行]=その行の開始桁}}（行は1始まり）
function M.rows_of(cache, id)
  return cache and cache.node_rows and cache.node_rows[id] or nil
end

-- 詳細などの画面用：部品（{文字, 色}）の並びから行と印を作る小道具
function M.builder()
  local b = { lines = {}, marks = {}, links = {} }
  function b:add(segs, link)
    if type(segs) == "string" then segs = { { segs } } end
    local parts, pos = {}, 0
    local row = #self.lines
    for _, s in ipairs(segs) do
      local t = (s[1] or ""):gsub("\n", " ")
      if t ~= "" then
        parts[#parts + 1] = t
        if s[2] then self.marks[#self.marks + 1] = { row, pos, pos + #t, s[2] } end
        pos = pos + #t
      end
    end
    self.lines[#self.lines + 1] = table.concat(parts)
    if link then self.links[row + 1] = link end
    return row
  end
  function b:result()
    return { lines = self.lines, marks = self.marks, links = self.links }
  end
  return b
end

-- 全部書き直す（詳細・transcript・diff 用。これらは開くたびに作り直すだけ）
function M.set_all(buf, lines, marks)
  with_modifiable(buf, function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    add_marks(buf, marks, lines or {})
  end)
end

return M
