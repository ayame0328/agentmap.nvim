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
-- 進み具合（DESIGN-v0.2 §2.6）。決まった値は 9. で確かめる（fixture の版に依らないよう、ここでは形だけ）
--   ROOT は手順表か子の平均で推定（~）、DONE の箱は 100.0%（事実、~ なし）、事実の無い REWORK には出さない
ok(L.nodes.ROOT.lines[4]:find("~%d+%.%d%%") ~= nil, "ROOT の箱に推定の %（実際: " .. L.nodes.ROOT.lines[4] .. "）")
ok(L.nodes.g1.lines[4]:find("[DONE] 100.0%", 1, true) ~= nil, "DONE の箱は 100.0%（実際: " .. L.nodes.g1.lines[4] .. "）")
for _, l in ipairs(L.nodes.a2.lines) do ok(not l:find("%%"), "事実の無い REWORK の a2 には % を出さない: " .. l) end
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
ok(L3.nodes.ROOT.lines[4]:find("~%d+%.%d%%") ~= nil, "ROOT の進み具合は推定（~）")

-- 4. 畳む・部分表示
local L4 = graph.layout(fixture(), { width = 160, now = NOW, collapsed = { a1 = true } })
ok(L4.nodes.g1 == nil and L4.nodes.a1.lines[4]:find("] [+1]", 1, true), "畳むと子が隠れて、札のすぐ後ろに [+1]（実際: " .. L4.nodes.a1.lines[4] .. "）")
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


-- 9. 進み具合（v0.2）：固定の now・固定の stats で決まった値（DESIGN-v0.2 §6 の (b)・§9.3 の 9）
--   fixture を直接書き換える（W1 の fixture の更新を待たない・どちらでも同じ値になる）
local function iso(sec) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", sec) end
local STATS = { agents = { ["general-purpose|opus"] = { n = 10, median_ms = 360000 } }, steps = {},
  all = { agents = { n = 10, median_ms = 360000 }, steps = { n = 0 } } }
local function progress_fixture()
  local p = fixture()
  local a1 = p.agents.a1
  a1.status, a1.finished_at, a1.elapsed_ms = "RUNNING", nil, nil
  a1.attempts[1].finished_at = nil
  a1.steps = { source = "transcript", listed_at = iso(NOW - 600), items = {
    { n = 1, text = "Read the current code", done_at = iso(NOW - 400) },
    { n = 2, text = "Write the design", done_at = iso(NOW - 70) },
    { n = 3, text = "Run the tests", started_at = iso(NOW - 60) },
  } }
  p.agents.ROOT.tasks = { order = { "1", "2" }, items = {
    ["1"] = { id = "1", subject = "Plan", status = "completed", created_at = iso(NOW - 900), done_at = iso(NOW - 800) },
    ["2"] = { id = "2", subject = "Delegate", status = "in_progress", started_at = iso(NOW - 700) },
  } }
  return p
end
local PV = { width = 200, now = NOW, stats = STATS, progress = { enabled = true, no_steps = "time", default_ms = 600000, min_samples = 3 } }
local P = graph.layout(progress_fixture(), PV)
ok(P.nodes.a1.lines[4]:find("[RUNNING] ~83.3% ", 1, true) == 1, "a1：手順 2/3 ＋ 60 s / 120 s → ~83.3%（実際: " .. P.nodes.a1.lines[4] .. "）")
ok(P.nodes.ROOT.lines[4]:find("~91.6%", 1, true) ~= nil, "ROOT：手順 1/2 ＋ 動いている子 83.3 → ~91.6%（実際: " .. P.nodes.ROOT.lines[4] .. "）")
for _, id in ipairs({ "ROOT", "a1", "a2", "g1" }) do
  ok(vim.fn.strdisplaywidth(P.nodes[id].lines[4]) == 24, id .. " の 4 行目は 24 桁")
end
-- W1 の fixture（state_small.lua に steps / tasks が入った版）そのままでも同じ値
local PW = graph.layout(fixture(), PV)
ok(PW.nodes.a1.lines[4]:find("~83.3%", 1, true) ~= nil and PW.nodes.ROOT.lines[4]:find("~91.6%", 1, true) ~= nil,
  "fixture そのまま：a1 ~83.3%・ROOT ~91.6%（実際: " .. PW.nodes.a1.lines[4] .. " / " .. PW.nodes.ROOT.lines[4] .. "）")
ok(P.lines[2]:find("~% estimate (steps/time)", 1, true) ~= nil, "凡例に ~% の意味")
-- 事実だけ（REVIEW：k/n ちょうど）なら ~ が無い
local pf = progress_fixture()
pf.agents.a1.status = "REVIEW"
local PF = graph.layout(pf, PV)
ok(PF.nodes.a1.lines[4]:find("[REVIEW] 66.6%", 1, true) == 1, "事実だけなら ~ 無し（実際: " .. PF.nodes.a1.lines[4] .. "）")
-- progress.enabled = false で箱の % が消える（経過時間は残る）
local PO = graph.layout(progress_fixture(), vim.tbl_extend("force", PV, { progress = { enabled = false } }))
local anypct = false
for _, id in ipairs({ "ROOT", "a1", "g1" }) do
  if PO.nodes[id].lines[4]:find("%%") then anypct = true end
end
ok(not anypct, "progress.enabled = false なら箱に % が無い")
ok(PO.nodes.a1.lines[4]:find("^%[RUNNING%]  %d+:%d%d") == 1, "経過時間は残る（実際: " .. PO.nodes.a1.lines[4] .. "）")
ok(not PO.lines[2]:find("estimate", 1, true), "凡例の ~% も消える")
-- 手順表の無い RUNNING の箱は時間だけで推定（付録 D）
local pt = fixture()
pt.agents.a2.status = "RUNNING"
pt.agents.a2.started_at = iso(NOW - 120)
pt.agents.a2.finished_at, pt.agents.a2.attempts = nil, { { n = 1 } }
pt.agents.a2.review_count, pt.agents.a2.rework_count = 0, 0
local PTm = graph.layout(pt, PV)
ok(PTm.nodes.a2.lines[4]:find("[RUNNING] ~33.3% 2:00", 1, true) == 1, "時間だけ：120 s / 360 s → ~33.3%（実際: " .. PTm.nodes.a2.lines[4] .. "）")

-- 10. 光の通り道（DESIGN-v0.2 §3.2）
local function cell(Lx, e) return Lx.lines[e[1] + 1]:sub(e[2] + 1, e[3]) end
local pa = L.paths.a1
ok(type(pa) == "table" and #pa > 3, "paths.a1 がある")
if pa then
  local first, last = pa[1], pa[#pa]
  ok(first[1] == L.nodes.ROOT.y + 2 and cell(L, first) == "├", "最初は親の右枠の ├（実際: " .. cell(L, first) .. "）")
  local rootline = L.lines[L.nodes.ROOT.y + 3]
  ok(vim.fn.strdisplaywidth(rootline:sub(1, first[2])) == L.nodes.ROOT.x + L.nodes.ROOT.w - 1, "├ のバイト桁は親の右端の桁")
  ok(last[1] == L.nodes.a1.y + 2 and cell(L, last) == "▶", "最後は子の左の ▶（実際: " .. cell(L, last) .. "）")
  local okc = true
  for _, e in ipairs(pa) do
    if not vim.tbl_contains({ "─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "▶" }, cell(L, e)) then okc = false end
    if e[3] - e[2] < 1 or e[3] - e[2] > 3 then okc = false end
  end
  ok(okc, "通り道のセルは全部線の文字（1〜3 バイト）")
end
ok(L.paths.g1 ~= nil and cell(L, L.paths.g1[#L.paths.g1]) == "▶", "孫 g1 にも通り道")
ok(L.paths["gate:a2"] == nil and L.paths.ROOT == nil, "門と START → ROOT には作らない")
-- 段 2 の箱：前の段で一番近い箱の出口から
local s2 = fixture()
s2.agents.a5 = { id = "a5", index = 5, name = "後の段", parent_id = "ROOT", children = {}, status = "RUNNING",
  started_at = "2026-09-28T04:30:00.000Z", attempts = { { n = 1, started_at = "2026-09-28T04:30:00.000Z" } },
  model = "claude-opus-5-5" }
table.insert(s2.agents.ROOT.children, "a5")
table.insert(s2.order, "a5")
local L2b = graph.layout(s2, { width = 300, now = NOW })
local p5 = L2b.paths.a5
ok(p5 ~= nil, "段 2 の a5 に通り道")
if p5 then
  local near
  for _, id in ipairs({ "a1", "a2" }) do
    local n = L2b.nodes[id]
    if not near or math.abs(n.y - L2b.nodes.a5.y) < math.abs(L2b.nodes[near].y - L2b.nodes.a5.y) then near = id end
  end
  ok(p5[1][1] == L2b.nodes[near].y + 2, "始点は前の段で一番近い箱（" .. near .. "）の行")
  ok(cell(L2b, p5[#p5]) == "▶" and p5[#p5][1] == L2b.nodes.a5.y + 2, "終点は a5 の ▶")
end
-- HUMAN CHECK の箱へも（答え待ちの線に紫の光を流すため。付録 D Q6）
local sc = dofile(here .. "/fixtures/state_check.lua")
local LC = graph.layout(sc, { width = 400, now = NOW, mode = "box" })
ok(LC.paths["check:toolu_Q"] ~= nil and cell(LC, LC.paths["check:toolu_Q"][#LC.paths["check:toolu_Q"]]) == "▶", "check の箱にも通り道")
-- 一覧では {}
ok(vim.deep_equal(graph.layout(fixture(), { width = 40, now = NOW }).paths, {}), "一覧（tree）では paths == {}")

-- 11. 修正指示の印（DESIGN-v0.2-steer §6.3）
local mk = graph.steer_mark()
local function with_steers(list)
  local x = fixture()
  x.steers, x.steer_order = {}, {}
  x.agents.a2.steers = {}
  for i, st in ipairs(list) do
    local id = "a2-" .. i
    st.id, st.agent_id = id, "a2"
    x.steers[id] = st
    table.insert(x.steer_order, id)
    table.insert(x.agents.a2.steers, id)
  end
  return x
end
local function line4_marks(Lx, id)
  local row = Lx.nodes[id].y + 4
  local hl = {}
  for _, m in ipairs(Lx.marks) do if m[1] == row then hl[#hl + 1] = m[4] end end
  return Lx.nodes[id].lines[4], hl
end
local Ls = graph.layout(with_steers({ { status = "PENDING" }, { status = "DELIVERED", delivered_at = iso(NOW - 5) } }), { width = 200, now = NOW })
local l4, hl4 = line4_marks(Ls, "a2")
ok(l4:find("[REWORK] " .. mk .. "1", 1, true) == 1, "未配達 1 件 → 札の直後に ✎1（実際: " .. l4 .. "）")
ok(vim.tbl_contains(hl4, "AgentMapWaiting"), "✎1 は紫")
local Ld = graph.layout(with_steers({ { status = "DELIVERED", delivered_at = iso(NOW - 5) } }), { width = 200, now = NOW })
ok(Ld.nodes.a2.lines[4]:find("[REWORK] " .. mk .. " ", 1, true) == 1, "配達済み（60 秒以内）→ ✎（実際: " .. Ld.nodes.a2.lines[4] .. "）")
local Lo = graph.layout(with_steers({ { status = "DELIVERED", delivered_at = iso(NOW - 120) } }), { width = 200, now = NOW })
ok(not Lo.nodes.a2.lines[4]:find(mk, 1, true), "配達から 60 秒を過ぎたら印は消える")
local Le = graph.layout(with_steers({ { status = "EXPIRED" }, { status = "CANCELLED" } }), { width = 200, now = NOW })
local le4, hle = line4_marks(Le, "a2")
ok(le4:find("[REWORK] " .. mk .. "!", 1, true) == 1, "届かないまま終了 → ✎!（実際: " .. le4 .. "）")
ok(vim.tbl_contains(hle, "AgentMapRework"), "✎! は赤")
ok(Ls.lines[2]:find(mk .. " steer", 1, true) ~= nil, "凡例に ✎ steer")
local Lt = graph.layout(with_steers({ { status = "PENDING" } }), { width = 200, now = NOW, mode = "tree" })
local trow
for _, l in ipairs(Lt.lines) do if l:find("[2]", 1, true) then trow = l end end
ok(trow and trow:find(mk .. "1", 1, true) ~= nil, "一覧でも ✎1")

io.write(string.format("test_render: %d ok, %d NG\n", passes, fails))
os.exit(fails == 0 and 0 or 1)
