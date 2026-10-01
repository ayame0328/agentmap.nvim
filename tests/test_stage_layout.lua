-- 段の図の試験：START ▶ ROOT ▶ 段1 [1] ▶ 段2 [2][3][4]（縦に積む）▶ 段3 [5] ▶ END
--   [3] は自分の子 [6] → [7]（2 段）を右に持つ（入れ子の段）
--   実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_stage_layout.lua
local t = require("t")
local graph = require("agentmap.graph")
local renderer = require("agentmap.renderer")
vim.o.columns, vim.o.lines = 400, 60

local NOW = 1790600000
local function T(n) return string.format("2026-09-29T10:%02d:%02d.000Z", math.floor(n / 60), n % 60) end

local function agent(n, parent, st, fin, kids)
  return {
    id = "a" .. n, index = n, name = "step" .. n, agent_type = "general-purpose", model = "claude-opus-5-5",
    task = "task" .. n, parent_id = parent, children = kids or {}, status = "DONE",
    attempts = { { n = 1, started_at = T(st), finished_at = T(fin) } }, attempt = 1,
    review_count = 0, rework_count = 0, started_at = T(st), finished_at = T(fin),
    tools = {}, tool_counts = {}, files = {},
  }
end

local function mk(ended)
  local s = {
    v = 1, run_id = "stagetest-0000", cwd = "/tmp/stage", title = "stage test", started_at = T(0),
    ended_at = ended and T(60) or nil,
    order = { "ROOT", "a1", "a2", "a3", "a4", "a5", "a6", "a7" }, next_index = 8,
    spawn_requests = {}, counts = {}, last_seq = 0,
    agents = {
      ROOT = { id = "ROOT", status = ended and "DONE" or "RUNNING", model = "claude-fable-5-1",
        children = { "a1", "a2", "a3", "a4", "a5" }, attempts = { { n = 1, started_at = T(0) } }, attempt = 1,
        review_count = 0, rework_count = 0, started_at = T(0), tools = {}, tool_counts = {}, files = {} },
      a1 = agent(1, "ROOT", 1, 10),
      a2 = agent(2, "ROOT", 12, 30),
      a3 = agent(3, "ROOT", 12, 40, { "a6", "a7" }),
      a4 = agent(4, "ROOT", 13, 25),
      a5 = agent(5, "ROOT", 41, 50),
      a6 = agent(6, "a3", 14, 20),
      a7 = agent(7, "a3", 22, 35),
    },
  }
  return s
end

-- 1. 箱の図
local L = graph.layout(mk(true), { width = 400, now = NOW, mode = "box" })
t.eq(L.mode, "box", "箱の図")
local N = L.nodes
t.ok(N.START and N.END, "START と END の箱がある")
t.ok(N.START.x < N.ROOT.x, "START は ROOT の左")
t.ok(N.a1.x > N.ROOT.x, "段1 は ROOT の右")
t.ok(N.a1.x < N.a2.x and N.a2.x == N.a3.x and N.a3.x == N.a4.x, "段2 の [2][3][4] は同じ列（縦に積む）")
t.ok(N.a2.y < N.a3.y and N.a3.y < N.a4.y, "段2 は開始順に上から")
t.ok(N.a5.x > N.a4.x and N.END.x > N.a5.x, "段3 [5] → END の順に右へ")
t.ok(N.a6.x > N.a3.x and N.a7.x > N.a6.x, "[3] の子 [6] → [7] は [3] の右（入れ子の段）")
local BW, GAP = 28, 7
t.ok(N.a5.x >= N.a7.x + BW + GAP, "次の段は、いちばん幅の広い子の流れの後ろから始まる")
t.eq(N.END.y + 1, N.ROOT.y + 2, "END は ROOT と同じ高さ")

local function has_edge(from, to, kind)
  for _, e in ipairs(L.edges) do
    if e.from == from and e.to == to and e.kind == kind then return true end
  end
  return false
end
t.ok(has_edge("START", "ROOT", "seq"), "線 START → ROOT（順番）")
t.ok(has_edge("ROOT", "a1", "child"), "線 ROOT → [1]（起動）")
for _, x in ipairs({ "a2", "a3", "a4" }) do t.ok(has_edge("a1", x, "seq"), "線 [1] → " .. x .. "（順番）") end
for _, x in ipairs({ "a2", "a3", "a4" }) do t.ok(has_edge(x, "a5", "seq"), "線 " .. x .. " → [5]（順番）") end
t.ok(has_edge("a5", "END", "seq"), "線 [5] → END")
t.ok(has_edge("a3", "a6", "child"), "線 [3] → [6]（起動）")
t.ok(has_edge("a6", "a7", "seq"), "線 [6] → [7]（入れ子の中の順番）")

-- 文字列の列（表示幅 1 の文字だけの名前にしてあるので、文字の位置 = 列）
local function ch(y, x)
  return vim.fn.strcharpart(L.lines[y + 1] or "", x, 1)
end
for _, id in ipairs({ "ROOT", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "END" }) do
  local n = N[id]
  local cy = n.y + (n.h == 3 and 1 or 2)
  t.eq(ch(cy, n.x - 1), "▶", id .. " の左に ▶")
end
-- 全部の箱の枠が崩れていない（線が箱を上書きしていない）
local LEFT = { ["┌"] = true, ["│"] = true, ["└"] = true }
local RIGHT = { ["┐"] = true, ["│"] = true, ["┘"] = true, ["├"] = true }
local broken = {}
for id, n in pairs(N) do
  for r = n.y, n.y + n.h - 1 do
    if not LEFT[ch(r, n.x)] or not RIGHT[ch(r, n.x + n.w - 1)] then broken[#broken + 1] = id .. "@" .. r end
  end
end
t.eq(broken, {}, "箱の左右の枠がどの行でも残っている")
-- 最後の子から出る線：[2][4] の右端に ├（次の段へ）
t.eq(ch(N.a2.y + 2, N.a2.x + N.a2.w - 1), "├", "[2] の右端から次の段へ出る")
t.eq(ch(N.a7.y + 2, N.a7.x + N.a7.w - 1), "├", "[7]（入れ子の最後）の右端から合流線へ出る")
local seq_mark = false
for _, m in ipairs(L.marks) do if m[4] == "AgentMapEdgeSeq" then seq_mark = true end end
t.ok(seq_mark, "順番の線には AgentMapEdgeSeq の色")
t.eq(L.order, { "START", "ROOT", "a1", "a2", "a3", "a6", "a7", "a4", "a5", "END" }, "並び順は START → 段の順 → END")
t.ok(table.concat(L.lines, "\n"):find("END [DONE]", 1, true), "終わった流れの END は [DONE]")

-- 2. まだ動いている → END は未完了（…）
local s2 = mk(false)
s2.agents.a5.status = "RUNNING"
s2.agents.a5.finished_at = nil
s2.agents.a5.attempts[1].finished_at = nil
local L2 = graph.layout(s2, { width = 400, now = NOW, mode = "box" })
t.eq(L2.nodes.END.status, "PENDING", "動いている Agent があれば END は PENDING")
t.ok(table.concat(L2.lines, "\n"):find("END …", 1, true), "未完了の END は …")
local s3 = mk(true)
s3.agents.a4.status = "RUNNING"
t.eq(graph.layout(s3, { width = 400, now = NOW, mode = "box" }).nodes.END.status, "PENDING",
  "終わりの記録があっても動いている Agent がいれば PENDING")

-- 3. 部分表示（z）には START / END を出さない
local Lz = graph.layout(mk(true), { width = 400, now = NOW, mode = "box", root = "a3" })
t.ok(Lz.nodes.START == nil and Lz.nodes.END == nil and Lz.nodes.a6 and Lz.nodes.a7, "部分表示は START/END なし")

-- 4. 一覧（幅 60）
local Lt = graph.layout(mk(true), { width = 60, now = NOW })
t.eq(Lt.mode, "tree", "幅 60 では一覧")
local tt = table.concat(Lt.lines, "\n")
t.matches(tt, "\n├─ Stage 1", "一覧に Stage 1")
t.matches(tt, "\n│  └─ %[1%]", "段1 の下に [1]")
t.matches(tt, "\n├─ Stage 2", "一覧に Stage 2")
t.matches(tt, "\n│  ├─ %[2%]", "段2 の下に [2]")
t.matches(tt, "\n│  ├─ %[3%] step3[^\n]*\n│  │  ├─ Stage 1  1 agents\n│  │  │  └─ %[6%]", "[3] の中にも 段1 → [6]")
t.matches(tt, "\n│  │  └─ Stage 2  1 agents\n│  │     └─ %[7%]", "[3] の中の 段2 → [7]")
t.matches(tt, "\n└─ Stage 3  1 agents\n   └─ %[5%]", "最後の段 3 に [5]")
t.matches(tt, "\nEND  %[DONE%]", "一覧の最後に END（字下げなし）")

-- 5. バッファに描く：段の行 → 段の見出しの id、状態を 1 つ変えても書き換えは少し
renderer.setup_highlights()
local buf = vim.api.nvim_create_buf(false, true)
local ct = renderer.render(buf, Lt, nil)
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local srow
for i, l in ipairs(lines) do if l:find("Stage 1", 1, true) then srow = i break end end
t.eq(srow and renderer.node_at(ct, srow, #lines[srow] - 1), "stage:ROOT:1", "段の行 → stage:ROOT:1")

local st = mk(true)
local cache = renderer.render(buf, graph.layout(st, { width = 400, now = NOW, mode = "box" }), nil)
local calls = {}
local orig = vim.api.nvim_buf_set_lines
vim.api.nvim_buf_set_lines = function(b, a, e, strict, rep)
  calls[#calls + 1] = { a, e }
  return orig(b, a, e, strict, rep)
end
st.agents.a5.status = "FAILED"
renderer.render(buf, graph.layout(st, { width = 400, now = NOW, mode = "box" }), cache)
vim.api.nvim_buf_set_lines = orig
local touched = 0
for _, c in ipairs(calls) do touched = touched + (c[2] - c[1]) end
t.ok(#calls >= 1 and touched <= 3, "[5] を FAILED にしても書き換えは 3 行以内（" .. touched .. " 行）")

-- 6. n は段の順に進む（START・END は飛ばす）
local ui = require("agentmap.ui")
vim.notify = function() end
local run = { dir = vim.fn.tempname(), sid = "stagetest-0000", state = mk(true) }
ui.view = ui.view or {}
ui.view.mode = "box"
ui.open_map(run)
local seen = { ui.current_id() }
for _ = 1, 8 do
  vim.api.nvim_feedkeys("n", "mx", false)
  seen[#seen + 1] = ui.current_id()
end
t.eq(seen, { "ROOT", "a1", "a2", "a3", "a6", "a7", "a4", "a5", "ROOT" }, "n は START → 段の順 → END を飛ばして一周")

t.done()
