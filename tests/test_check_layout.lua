-- HUMAN CHECK（確認待ち）の図の試験（担当 B：graph.lua）
--   fixtures/state_check.lua：ROOT → [1] → HUMAN CHECK #1（ROOT が直接・答え済み）→ [2] → HUMAN CHECK #2（[2] の後ろ・WAITING）
--   実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_check_layout.lua
local t = require("t")
local here = vim.g.agentmap_test_dir
local graph = require("agentmap.graph")
local renderer = require("agentmap.renderer")

local NOW = 1790600000
local function fixture() return dofile(here .. "/fixtures/state_check.lua") end
local function text(L) return table.concat(L.lines, "\n") end
local function has_mark(L, hl, row_from, row_to)
  for _, m in ipairs(L.marks) do
    if m[4] == hl and (not row_from or (m[1] >= row_from and m[1] <= row_to)) then return true end
  end
  return false
end
local function stage_ids(node)
  local out = {}
  for _, st in ipairs(node.stages) do
    local ids = {}
    for _, m in ipairs(st) do ids[#ids + 1] = m.id end
    out[#out + 1] = table.concat(ids, ",")
  end
  return out
end
local function find(node, id)
  if node.id == id then return node end
  for _, st in ipairs(node.stages or {}) do
    for _, m in ipairs(st) do
      local r = find(m, id)
      if r then return r end
    end
  end
end

-- 1. 段の並び：直接の質問は [1] と [2] の間の段、子の要確認の質問は [2] の最後の段
local s = fixture()
local forest = graph.visible(s, {})
t.eq(stage_ids(forest[1]), { "a1", "check:toolu_B", "a2", "END" }, "ROOT の段：[1] → 直接の HUMAN CHECK → [2] → END")
local a2 = find(forest[1], "a2")
t.eq(stage_ids(a2), { "check:toolu_Q" }, "[2] の後ろに結びついた HUMAN CHECK")
t.eq(find(forest[1], "check:toolu_Q").kind, "check", "ノードの kind は check")

-- 門があるときは check → gate の順
local sg = fixture()
sg.agents.a2.review_count = 1
sg.agents.a2.attempts[1].submitted_at = "2026-10-01T10:00:32.000Z"
t.eq(stage_ids(find(graph.visible(sg, {})[1], "a2")), { "check:toolu_Q", "gate:a2" }, "門より前に HUMAN CHECK")

-- 2. 箱の図
local L = graph.layout(s, { width = 400, now = NOW, mode = "box" })
local T = text(L)
t.ok(L.nodes["check:toolu_B"] and L.nodes["check:toolu_Q"], "HUMAN CHECK の箱が 2 つある")
t.eq(L.nodes["check:toolu_Q"].kind, "check", "nodes の kind")
t.eq(L.nodes["check:toolu_Q"].status, "WAITING", "nodes の status（WAITING）")
t.eq(L.nodes["check:toolu_B"].status, "ANSWERED", "nodes の status（ANSWERED）")
local function edge(from, to, kind)
  for _, e in ipairs(L.edges) do
    if e.from == from and e.to == to and e.kind == kind then return true end
  end
  return false
end
t.ok(edge("a2", "check:toolu_Q", "check"), "子 → その子の後ろの check は kind = check")
t.ok(edge("a1", "check:toolu_B", "seq") and edge("check:toolu_B", "a2", "seq"), "段 → 段の check は seq")

local q = L.nodes["check:toolu_Q"].lines
t.matches(q[1], "^HUMAN CHECK", "1 行目は HUMAN CHECK")
t.matches(q[1], "#2$", "1 行目の右端に通し番号 #2")
t.matches(q[2], "^%[WAITING%]", "2 行目は [WAITING]")
t.matches(q[3], "^実装：dbt: ", "3 行目は header: question")
t.matches(q[3], "テスト", "3 行目に質問の中身（「〜について：」の後ろ）")
t.matches(q[4], "2 options · Enter opens", "4 行目（WAITING）は選択肢の数")
local bq = L.nodes["check:toolu_B"].lines
t.matches(bq[1], "#1$", "#1")
t.matches(bq[2], "^%[DONE%]", "答え済みは [DONE]")
t.matches(bq[3], "^設計: どちらの設計", "header: question")
t.matches(bq[4], "^→ A案", "4 行目に答え")

-- 色：WAITING の箱の枠と 4 行目は AgentMapWaiting、答え済みは AgentMapDone
local nq, nb = L.nodes["check:toolu_Q"], L.nodes["check:toolu_B"]
t.ok(has_mark(L, "AgentMapWaiting", nq.y, nq.y + nq.h - 1), "WAITING の箱に紫の印")
local done_in_b = false
for _, m in ipairs(L.marks) do
  if m[4] == "AgentMapDone" and m[1] == nb.y then done_in_b = true end
end
t.ok(done_in_b, "答え済みの箱の枠は緑（AgentMapDone）")

-- 見出し・凡例
t.matches(L.lines[1], "waiting 1", "見出しに「確認待ち 1」")
t.matches(L.lines[2], "%[WAITING%]purple", "凡例に [WAITING] 紫")
t.ok(L.lines[2]:find("[WAITING]", 1, true) < L.lines[2]:find("[REVIEW]", 1, true), "凡例の [WAITING] は [REVIEW] の前")
t.ok(has_mark(L, "AgentMapWaiting", 0, 1), "見出し・凡例に紫の印")

-- ROOT と [2] の 4 行目の印
t.matches(L.nodes.ROOT.lines[4], "wait 1", "ROOT の 4 行目に「確認待ち1」")
t.matches(L.nodes.a2.lines[4], " ask", "要確認で止まった [2] の 4 行目に「要確認」")
t.ok(not L.nodes.a1.lines[4]:find(" ask", 1, true), "[1] には印が無い")
local na2 = L.nodes.a2
t.ok(has_mark(L, "AgentMapWaiting", na2.y + 4, na2.y + 4), "[2] の「要確認」は紫")

-- 並び順に check が入る（n / p で止まる）
t.eq(L.order, { "START", "ROOT", "a1", "check:toolu_B", "a2", "check:toolu_Q", "END" }, "order に check の id")

-- 3. 答えが出たら印が消え、[DONE] → 答え
local s2 = fixture()
s2.checks["check:toolu_Q"].status = "ANSWERED"
s2.checks["check:toolu_Q"].answered_at = "2026-10-01T10:01:36.000Z"
s2.checks["check:toolu_Q"].answers = { [s2.checks["check:toolu_Q"].questions[1].question] = "単体のみ" }
local L2 = graph.layout(s2, { width = 400, now = NOW, mode = "box" })
t.ok(not L2.nodes.a2.lines[4]:find(" ask", 1, true), "答えが出たら [2] の「要確認」は消える")
t.ok(not L2.nodes.ROOT.lines[4]:find("wait", 1, true), "答え待ちが無ければ ROOT の印も無い")
t.ok(not L2.lines[1]:find("waiting", 1, true), "見出しの「確認待ち」も消える")
t.matches(L2.nodes["check:toolu_Q"].lines[2], "^%[DONE%] 1:05", "回答までの時間")
t.matches(L2.nodes["check:toolu_Q"].lines[4], "^→ 単体のみ", "答え")

-- 複数選択（配列の答え）と自由入力
local s3 = fixture()
s3.checks["check:toolu_B"].answers = { ["どちらの設計で進めますか？"] = { "A案", "B案" } }
t.matches(graph.layout(s3, { width = 400, now = NOW, mode = "box" }).nodes["check:toolu_B"].lines[4], "^→ A案, B案",
  "配列の答えは「A, B」")
s3.checks["check:toolu_B"].answers = { ["どちらの設計で進めますか？"] = string.rep("あ", 40) }
local free = graph.check_info(s3, s3.checks["check:toolu_B"]).answer
t.ok(vim.fn.strdisplaywidth(free) <= 30, "自由入力は先頭 30 桁まで（実際: " .. free .. "）")

-- 未回答のまま終了
local s4 = fixture()
s4.checks["check:toolu_Q"].status = "ABANDONED"
s4.checks["check:toolu_Q"].ended_at = "2026-10-01T10:00:40.000Z"
s4.checks["check:toolu_Q"].end_reason = "turn_ended"
local L4 = graph.layout(s4, { width = 400, now = NOW, mode = "box" })
t.matches(L4.nodes["check:toolu_Q"].lines[2], "^%[UNANSWERED%]", "[UNANSWERED]")
t.matches(L4.nodes["check:toolu_Q"].lines[4], "^ended unanswered", "4 行目")
t.eq(L4.nodes["check:toolu_Q"].status, "ABANDONED", "status")
t.ok(has_mark(L4, "AgentMapPending", L4.nodes["check:toolu_Q"].y, L4.nodes["check:toolu_Q"].y), "枠は灰")

-- 4. 木の一覧
local TL = graph.layout(s, { width = 100, now = NOW, mode = "tree" })
local TT = text(TL)
t.matches(TT, "HUMAN CHECK #1  %[DONE%] → A案", "一覧：答え済みの行")
t.matches(TT, "HUMAN CHECK #2  %[WAITING%]  \"", "一覧：答え待ちの行")
t.ok(TL.nodes["check:toolu_Q"] and TL.nodes["check:toolu_Q"].status == "WAITING", "一覧の nodes にも check")
local qrow, a2row
for i, l in ipairs(TL.lines) do
  if l:find("HUMAN CHECK #2", 1, true) then qrow = i end
  if l:find("[2] 実装", 1, true) then a2row = i end
end
t.ok(qrow and a2row and qrow == a2row + 1, "一覧で #2 は [2] のすぐ下（子として）")
t.matches(TL.lines[a2row], " ask", "一覧の [2] の行にも「要確認」")
local tedge = false
for _, e in ipairs(TL.edges) do
  if e.from == "a2" and e.to == "check:toolu_Q" and e.kind == "check" then tedge = true end
end
t.ok(tedge, "一覧の edges も kind = check")

-- 5. 畳む：check も一緒に隠れる。[+n] の n は Agent の数だけ
local Lc = graph.layout(s, { width = 400, now = NOW, mode = "box", collapsed = { a2 = true } })
t.ok(Lc.nodes["check:toolu_Q"] == nil, "[2] を畳むと後ろの check は隠れる")
t.ok(Lc.nodes["check:toolu_B"] ~= nil, "ROOT 直下の check は残る")
t.matches(Lc.nodes.a2.lines[4], "%[%+0%]", "[+n] は Agent の数（check は数えない）")
local Lr = graph.layout(s, { width = 400, now = NOW, mode = "box", collapsed = { ROOT = true } })
t.ok(Lr.nodes["check:toolu_B"] == nil and Lr.nodes["check:toolu_Q"] == nil, "ROOT を畳むと全部隠れる")
t.matches(Lr.nodes.ROOT.lines[4], "%[%+2%]", "ROOT の [+2]")
-- 子の無い Agent でも、check があれば畳める
local only = fixture()
only.agents.ROOT.checks = {}
only.checks["check:toolu_B"] = nil
only.check_order = { "check:toolu_Q" }
t.ok(graph.visible(only, { collapsed = { a2 = true } })[1].stages[2][1].collapsed_count == 0, "check だけの箱も畳める")

-- 6. 画面に描いて、カーソル位置 → check の id
renderer.setup_highlights()
local buf = vim.api.nvim_create_buf(false, true)
local cache = renderer.render(buf, L, nil)
local r = renderer.rows_of(cache, "check:toolu_Q")
t.ok(r ~= nil, "rows_of で check の箱の位置")
t.eq(renderer.node_at(cache, r[1] + 1, r.starts[r[1] + 1] + 4), "check:toolu_Q", "node_at が check の id を返す")

-- 7. checks_of：a.checks と owner_id から、聞いた順
t.eq(graph.checks_of(s, "ROOT"), { "check:toolu_B" }, "ROOT の checks_of")
t.eq(graph.checks_of(s, "a2"), { "check:toolu_Q" }, "a2 の checks_of")
t.eq(graph.checks_of(s, "a1"), {}, "a1 は無し")
local s5 = fixture()
s5.agents.a2.checks = nil -- a.checks が無くても owner_id から拾う
t.eq(graph.checks_of(s5, "a2"), { "check:toolu_Q" }, "owner_id からも拾う")
-- 流れの写しで owner が ROOT に付け替えられた（agent_id は流れの外）→ ROOT の直接の質問として時刻で並ぶ
local s6 = fixture()
s6.checks["check:toolu_Q"].owner_id = "ROOT"
s6.agents.a2.checks = {}
s6.agents.ROOT.checks = { "check:toolu_B", "check:toolu_Q" }
t.eq(stage_ids(graph.visible(s6, {})[1]), { "a1", "check:toolu_B", "a2", "check:toolu_Q", "END" },
  "owner が ROOT の check は ROOT の段に時刻で混ざる")

-- 8. checks を持たない古い形の state でも落ちない
local old = dofile(here .. "/fixtures/state_small.lua")
t.run("checks の無い state", function()
  local Lo = graph.layout(old, { width = 400, now = NOW, mode = "box" })
  t.ok(not Lo.lines[1]:find("waiting", 1, true), "checks が無ければ見出しに出さない")
end)

t.done()
