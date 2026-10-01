-- 図の描画のテスト（箱の図・一覧・差分書き換え・カーソル→Agent）
--   実行: nvim --headless --clean -l tests/test_render.lua
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local cfgdir = vim.fn.fnamemodify(here, ":h:h")
vim.opt.rtp:prepend(cfgdir)

local fails, passes = 0, 0
local function ok(cond, msg)
  if cond then passes = passes + 1 else
    fails = fails + 1
    io.stderr:write("  NG: " .. msg .. "\n")
  end
end

local graph = require("agentmap.graph")
local renderer = require("agentmap.renderer")
local function fixture() return dofile(here .. "/fixtures/state_small.lua") end
local NOW = 1790600000 -- 固定の「今」（経過時間の表示を安定させる）

local function text(L) return table.concat(L.lines, "\n") end
local function row_of(L, pat)
  for i, l in ipairs(L.lines) do if l:find(pat, 1, true) then return i, l end end
end

-- 1. 箱の図（幅 160）
local s = fixture()
local L = graph.layout(s, { width = 160, now = NOW })
ok(L.mode == "box", "幅160では箱の図になる（実際: " .. L.mode .. "）")
local T = text(L)
for _, id in ipairs({ "ROOT", "a1", "a2", "g1", "gate:a2" }) do
  ok(L.nodes[id] ~= nil, "箱がある: " .. id)
end
for _, tag in ipairs({ "[RUNNING]", "[DONE]", "[REWORK]", "[RETRY]" }) do
  ok(T:find(tag, 1, true) ~= nil, "状態の文字がある: " .. tag)
end
for n = 1, 3 do ok(T:find("[" .. n .. "]", 1, true) ~= nil, "番号タグ [" .. n .. "]") end
-- 各子の箱の左隣に ▶ がある（線が子につながっている）
for _, id in ipairs({ "a1", "a2", "g1", "gate:a2" }) do
  local n = L.nodes[id]
  local line = L.lines[n.y + 2 + 1]
  local before = vim.fn.strcharpart(line, 0, vim.fn.strchars(line))
  -- 表示幅で n.x-1 の文字を取る
  local w, ch = 0, nil
  for _, c in ipairs(vim.fn.split(before, "\\zs")) do
    if w == n.x - 1 then ch = c break end
    w = w + vim.fn.strdisplaywidth(c)
  end
  ok(ch == "▶", "子 " .. id .. " の左に ▶（実際: " .. tostring(ch) .. "）")
end
-- ~50% は ROOT の箱だけ。子の無い Agent には % が無い
local r50 = row_of(L, "~50%")
ok(r50 and r50 - 1 >= L.nodes.ROOT.y and r50 - 1 < L.nodes.ROOT.y + 6, "~50% は ROOT の箱の中")
local c50 = 0
for _ in T:gmatch("~50%%") do c50 = c50 + 1 end
ok(c50 == 1, "~50% は1か所だけ（実際: " .. c50 .. "）")
for _, id in ipairs({ "g1", "a2" }) do
  local n = L.nodes[id]
  local found = false
  for _, l in ipairs(n.lines) do if l:find("%%") then found = true end end
  ok(not found, "子の無い " .. id .. " には % を出さない")
end
-- 日本語が混じっても、箱の右端が縦にそろう（表示幅で数える）
for _, id in ipairs({ "a1", "a2", "g1" }) do
  local n = L.nodes[id]
  local widths = {}
  for i = n.y, n.y + 5 do
    local line = L.lines[i + 1]
    local w, right = 0, nil
    for _, c in ipairs(vim.fn.split(line, "\\zs")) do
      w = w + vim.fn.strdisplaywidth(c)
      if w == n.x + n.w then right = c end
    end
    widths[#widths + 1] = right
  end
  local okw = true
  for _, c in ipairs(widths) do if not (c == "│" or c == "┐" or c == "┘" or c == "├" or c == "┤") then okw = false end end
  ok(okw, "箱 " .. id .. " の右の枠が同じ桁（" .. table.concat(vim.tbl_map(tostring, widths), "") .. "）")
end
-- 色：状態ごとの色の印がある
local hls = {}
for _, m in ipairs(L.marks) do hls[m[4]] = true end
for _, h in ipairs({ "AgentMapRunning", "AgentMapDone", "AgentMapRework", "AgentMapEdge", "AgentMapIndex" }) do
  ok(hls[h], "色の印: " .. h)
end

-- 2. 幅が足りなければ一覧（幅 40）
local L2 = graph.layout(fixture(), { width = 40, now = NOW })
ok(L2.mode == "tree", "幅40では一覧になる")
local T2 = text(L2)
ok(T2:find("├─ [1]", 1, true) and T2:find("│  └─ [3]", 1, true) and T2:find("└─ [2]", 1, true), "一覧の枝（├─ └─）")
ok(T2:find("[RETRY]", 1, true) ~= nil, "一覧にもレビュー結果")
for i = 4, #L2.lines do
  ok(vim.fn.strdisplaywidth(L2.lines[i]) <= 40, "一覧の行が幅40に収まる: " .. L2.lines[i])
end

-- 3. 差し戻し先が別の Agent のとき、retry の線と親不明のまとまり
local s3 = fixture()
s3.agents.a4 = { id = "a4", index = 4, name = "実装：やり直し", parent_id = "ROOT", children = {},
  status = "RUNNING", attempts = { { n = 1, retry_of = "a2" } }, model = "claude-opus-5-5" }
table.insert(s3.agents.ROOT.children, "a4")
s3.agents.a2.attempts[1].retried_by = "a4"
s3.agents.u1 = { id = "u1", index = 5, name = "親不明", parent_id = nil, children = {}, status = "RUNNING" }
local L3 = graph.layout(s3, { width = 200, now = NOW })
local T3 = text(L3)
ok(T3:find("└─ retry ─▶ [4]", 1, true) ~= nil, "retry の線が [4] を指す")
local has_retry_edge = false
for _, e in ipairs(L3.edges) do if e.kind == "retry" and e.to == "a4" then has_retry_edge = true end end
ok(has_retry_edge, "edges に retry がある")
ok(L3.nodes.UNKNOWN_PARENT ~= nil and T3:find("UNKNOWN_PARENT", 1, true), "親不明は UNKNOWN_PARENT にまとまる")
ok(T3:find("~33%", 1, true) ~= nil, "ROOT の進捗は 3人中1人 → ~33%")

-- 4. 畳む・部分表示
local L4 = graph.layout(fixture(), { width = 160, now = NOW, collapsed = { a1 = true } })
ok(L4.nodes.g1 == nil and text(L4):find("[+1]", 1, true), "畳むと子が隠れて [+1]")
local L5 = graph.layout(fixture(), { width = 160, now = NOW, root = "a1" })
ok(L5.nodes.ROOT == nil and L5.nodes.a1 and L5.nodes.g1, "部分表示は a1 から下だけ")

-- 5. バッファへ描く：2回目は変わった行だけ書き換える
renderer.setup_highlights()
local buf = vim.api.nvim_create_buf(false, true)
local st = fixture()
local cache = renderer.render(buf, graph.layout(st, { width = 160, now = NOW }), nil)
local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
ok(#got == #L.lines, "初回は全部書く")
local marks = vim.api.nvim_buf_get_extmarks(buf, renderer.ns, 0, -1, {})
ok(#marks > 20, "extmark で色が付いている（" .. #marks .. " 個）")

local calls = {}
local orig = vim.api.nvim_buf_set_lines
vim.api.nvim_buf_set_lines = function(b, a, e, strict, rep)
  calls[#calls + 1] = { a, e, #rep }
  return orig(b, a, e, strict, rep)
end
-- 何も変わらなければ書き換えない
cache = renderer.render(buf, graph.layout(st, { width = 160, now = NOW }), cache)
ok(#calls == 0, "変化なしなら書き換え0回（実際: " .. #calls .. "）")
-- g1 の状態だけ変える
st.agents.g1.status = "FAILED"
local Lc = graph.layout(st, { width = 160, now = NOW })
cache = renderer.render(buf, Lc, cache)
vim.api.nvim_buf_set_lines = orig
local touched = 0
for _, c in ipairs(calls) do touched = touched + (c[2] - c[1]) end
ok(#calls >= 1 and touched <= 3, "状態変更で書き換えた行は少しだけ（" .. touched .. " 行 / " .. #Lc.lines .. " 行）")
local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
ok(table.concat(after, "\n") == table.concat(Lc.lines, "\n"), "書き換え後の中身が新しい図と一致")
ok(table.concat(after, "\n"):find("[FAILED]", 1, true) ~= nil, "[FAILED] が出ている")
-- 印も正しく付け直されている（FAILED の色がある）
local ext = vim.api.nvim_buf_get_extmarks(buf, renderer.ns, 0, -1, { details = true })
local failed_hl = false
for _, e in ipairs(ext) do if e[4].hl_group == "AgentMapFailed" then failed_hl = true end end
ok(failed_hl, "FAILED の色が付いた")

-- 6. カーソル位置 → Agent
local n = Lc.nodes.a2
local row = n.y + 2 -- 箱の中の行（0始まり）
local r2 = renderer.rows_of(cache, "a2")
ok(r2 and r2[1] == n.y + 1, "rows_of が箱の先頭行を返す")
local id = renderer.node_at(cache, row + 1, r2.starts[row + 1] + 5)
ok(id == "a2", "node_at: 箱の中 → a2（実際: " .. tostring(id) .. "）")
-- ROOT の箱は START の右にある（列 → バイト位置に直して聞く）
local rl = after[L.nodes.ROOT.y + 3] or ""
ok(renderer.node_at(cache, L.nodes.ROOT.y + 3, vim.fn.byteidx(rl, L.nodes.ROOT.x + 2)) == "ROOT", "node_at: ROOT の箱")
-- 線の上は同じ行で一番近い箱
local eid = renderer.node_at(cache, L.nodes.a1.y + 3, #after[L.nodes.a1.y + 3] - 1)
ok(eid ~= nil, "node_at: 行末でも近い箱を返す")
ok(renderer.node_at(cache, 1, 0) == nil, "見出しの行は nil")

-- 7. 一覧でも node_at
local bt = vim.api.nvim_create_buf(false, true)
local ct = renderer.render(bt, graph.layout(fixture(), { width = 40, now = NOW }), nil)
local tl = vim.api.nvim_buf_get_lines(bt, 0, -1, false)
local rr
for i, l in ipairs(tl) do if l:find("[3]", 1, true) then rr = i end end
ok(rr and renderer.node_at(ct, rr, #tl[rr] - 1) == "g1", "一覧: [3] の行 → g1")

-- 8. 空っぽの state でも落ちない
local okE = pcall(function() return graph.layout({ run_id = "x", agents = {} }, { width = 80 }) end)
ok(okE, "空の state でも落ちない")

io.write(string.format("test_render: %d ok, %d NG\n", passes, fails))
os.exit(fails == 0 and 0 or 1)
