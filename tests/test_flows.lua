-- 指示（ユーザーの 1 回の入力）ごとの「流れ」の試験（計算と一覧の部分）。
--   ・どの記録にも prompt_id が付く（孫の記録も、始めた指示の id）
--   ・裏で動いた Agent の終わりのお知らせ（task_notification）は新しい流れにしない
--   ・流れだけを取り出した状態：番号を 1 から振り直す、ROOT の写しの状態
--   ・一番新しい流れを、セッションとプロジェクトをまたいで探す
--   ・一覧は流れ 1 つにつき 1 行。prompt_id の無い記録は今まで通りセッション 1 行
local t = require("t")
vim.notify = function() end

local fixture = vim.g.agentmap_test_dir .. "/fixtures/hooks_probe.jsonl"
if not vim.uv.fs_stat(fixture) then t.skip("fixture が無い"); t.done() end

local state = require("agentmap.state")
local events = require("agentmap.events")
local claude = require("agentmap.providers.claude")
local util = require("agentmap.util")
local graph = require("agentmap.graph")

local lines = vim.fn.readfile(fixture)
local first = vim.json.decode(lines[1])
local slug = vim.fn.fnamemodify(vim.fn.fnamemodify(first.transcript_path, ":h"), ":t")
local root = vim.env.AGENTMAP_DIR
local proj = root .. "/projects/" .. slug
vim.fn.mkdir(proj, "p")
vim.fn.writefile({ vim.json.encode({ cwd = first.cwd, slug = slug }) }, proj .. "/project.json")

local P1 = "c0ffee02-0000-4000-8000-000000000002"
local NOTE = "c0ffee03-0000-4000-8000-000000000003"
local CHILD, GRAND = "afeed000000000006", "afeed000000000007"
local TU1, TU2 = "toolu_test0000000000000004", "toolu_test0000000000000005"

local function shift(ts, dt)
  local s = util.parse_iso(ts)
  local whole = math.floor(s + dt)
  local ms = math.floor(((s + dt) - whole) * 1000 + 0.5)
  return os.date("!%Y-%m-%dT%H:%M:%S", whole) .. (".%03dZ"):format(ms)
end

--- fixture の 2〜11 行目（指示 → 子 → 孫 → 終わり）を、別の指示として作り直す
---   pid = 新しい prompt_id、dt = 時刻をずらす秒数、suffix = Agent の id などに付ける印
local function flow_lines(pid, dt, suffix, head, sid, upto)
  local out = {}
  for i = 2, upto or 11 do
    local l = lines[i]
    for _, k in ipairs({ CHILD, GRAND, TU1, TU2 }) do l = l:gsub(k, k .. suffix) end
    local d = vim.json.decode(l)
    d.prompt_id = pid
    d._ts = shift(d._ts, dt)
    if sid then d.session_id = sid end
    if d.hook_event_name == "UserPromptSubmit" then d.prompt_head = head or ("指示 " .. suffix) end
    out[#out + 1] = vim.json.encode(d)
  end
  return out
end

local function with_sid(list, sid)
  local out = {}
  for _, l in ipairs(list) do
    local d = vim.json.decode(l); d.session_id = sid
    out[#out + 1] = vim.json.encode(d)
  end
  return out
end

local function reduce_lines(list)
  local evs = {}
  for _, l in ipairs(list) do
    for _, ev in ipairs(claude.normalize_hook(vim.json.decode(l))) do evs[#evs + 1] = ev end
  end
  for i, ev in ipairs(evs) do ev.seq = i end
  return state.reduce(evs), evs
end

local function make_run(sid, list)
  local d = proj .. "/runs/" .. sid
  vim.fn.mkdir(d, "p")
  vim.fn.writefile(with_sid(list, sid), d .. "/hooks.jsonl")
  return d
end

local function append(sid, list)
  local d = proj .. "/runs/" .. sid
  vim.fn.writefile(with_sid(list, sid), d .. "/hooks.jsonl", "a")
end

-- 1. どの記録にも prompt_id（SessionStart だけは無い）
local _, evs = reduce_lines(lines)
local missing, grand_ok = 0, 0
for _, ev in ipairs(evs) do
  if ev.event ~= "run_started" and not (ev.event == "agent_started" and ev.agent_id == "ROOT") then
    if not ev.prompt_id then missing = missing + 1 end
  end
  if ev.agent_id == GRAND and (ev.event == "agent_linked" or ev.event == "agent_finished") and ev.prompt_id == P1 then
    grand_ok = grand_ok + 1
  end
end
t.eq(missing, 0, "SessionStart 以外の記録に全部 prompt_id が付いている")
t.ok(grand_ok >= 2, "孫の linked / finished も始めた指示の prompt_id")

-- 2. 1 セッション全体：お知らせは流れにならない
local s = reduce_lines(lines)
t.eq(#s.flows, 1, "流れは 1 つ（task_notification は流れを作らない）")
t.eq(s.prompt_alias[NOTE], P1, "お知らせの prompt_id は直前の指示へ読み替え")
t.eq(s.flows[1].agents, 2, "流れの Agent は子と孫の 2 つ")
t.eq(s.flows[1].status, "DONE", "終わった流れは DONE")
t.eq(s.flows[1].ended_at, "2026-09-27T19:23:50.000Z", "お知らせの番の Stop まで同じ指示の続き")
t.eq(s.agents[CHILD].prompt_id, P1, "子の prompt_id")
t.eq(s.agents[GRAND].prompt_id, P1, "孫の prompt_id")
t.eq(state.latest_flow_id(s), P1, "最新の流れ")
t.matches(s.flows[1].prompt_head, "^Use the Agent tool", "流れの題名は指示の本文")

-- 3. 親からの受け継ぎ・順番の入れ替わり
state.apply(s, { event = "agent_linked", agent_id = "NEWKID", parent_id = CHILD, ts = "2026-09-27T19:23:52.000Z" })
t.eq(s.agents.NEWKID.prompt_id, P1, "prompt_id の無い子は親の流れに入る")
local s2 = state.new("x")
state.apply(s2, { event = "agent_started", agent_id = "LATE", prompt_id = "PPP", ts = "2026-09-27T10:00:10.000Z" })
state.apply(s2, { event = "run_prompt", prompt_id = "QQQ", prompt_head = "Q の指示", ts = "2026-09-27T10:00:07.000Z" })
state.apply(s2, { event = "agent_started", agent_id = "QA", prompt_id = "QQQ", ts = "2026-09-27T10:00:08.000Z" })
t.eq(state.flow_of(s2, "PPP").n, 2, "Agent の記録だけ先に来た流れ（時刻が遅い）は 2 番目")
state.apply(s2, { event = "run_prompt", prompt_id = "PPP", prompt_head = "P の指示", ts = "2026-09-27T10:00:05.000Z" })
local fp = state.flow_of(s2, "PPP")
t.eq(fp.prompt_head, "P の指示", "あとから来た指示の本文が入る")
t.eq(fp.started_at, "2026-09-27T10:00:05.000Z", "開始は指示の時刻（早いほう）")
t.eq(fp.n, 1, "並べ直して 1 番目")
t.eq(state.flow_of(s2, "QQQ").n, 2, "もう一方は 2 番目")
-- お知らせより先に Agent の記録が来た場合も、直前の指示にまとめる
state.apply(s2, { event = "agent_started", agent_id = "BG", prompt_id = "NNN", ts = "2026-09-27T10:00:20.000Z" })
state.apply(s2, { event = "run_prompt", prompt_id = "NNN", kind = "task_notification", prompt_head = "<task-id>", ts = "2026-09-27T10:00:21.000Z" })
t.eq(#s2.flows, 2, "お知らせの入れ物は消える")
t.eq(s2.agents.BG.prompt_id, "QQQ", "お知らせの Agent は直前の指示の流れへ")
-- 指示の番の途中に差し込まれたお知らせ（prompt_id が今の指示と同じ。本物の記録で確認済み）は、その流れを消さない
local s5 = state.new("m")
state.apply(s5, { event = "run_prompt", prompt_id = "U1", prompt_head = "一つ目", ts = "2026-09-27T11:00:00.000Z" })
state.apply(s5, { event = "agent_started", agent_id = "B1", prompt_id = "U1", ts = "2026-09-27T11:00:01.000Z" })
state.apply(s5, { event = "run_prompt", prompt_id = "U2", prompt_head = "二つ目", ts = "2026-09-27T11:00:10.000Z" })
state.apply(s5, { event = "agent_started", agent_id = "B2", prompt_id = "U2", ts = "2026-09-27T11:00:11.000Z" })
state.apply(s5, { event = "run_prompt", prompt_id = "U2", kind = "task_notification", prompt_head = "<task-id>", ts = "2026-09-27T11:00:12.000Z" })
t.eq(#s5.flows, 2, "番の途中のお知らせで流れは消えない")
t.eq(s5.agents.B2.prompt_id, "U2", "二つ目の指示の Agent はそのまま")
t.eq(state.latest_flow_id(s5), "U2", "最新は二つ目の指示")
-- Agent からの伝言（<agent-message>）で始まる番は、人の指示ではない：直前の指示の続き
state.apply(s5, { event = "run_prompt", prompt_id = "M1", prompt_head = '<agent-message from="B2">\n完了', ts = "2026-09-27T11:00:20.000Z" })
state.apply(s5, { event = "agent_started", agent_id = "B3", prompt_id = "M1", ts = "2026-09-27T11:00:21.000Z" })
t.eq(#s5.flows, 2, "伝言は流れを作らない")
t.eq(s5.agents.B3.prompt_id, "U2", "伝言の番で始めた Agent は直前の指示の流れ")
t.eq(state.flow_of(s5, "U2").ended_at, nil, "伝言では前の指示を終わりにしない")

-- 4. 2 つの指示：流れだけの状態
local P2 = "p2000000-0000-0000-0000-000000000002"
local two = vim.list_extend(vim.list_slice(lines, 1, 11), flow_lines(P2, 60, "x", "二つ目の指示", nil, 7))
local s3 = reduce_lines(two)
t.eq(#s3.flows, 2, "流れは 2 つ")
local v1 = state.flow_view(s3, P1)
t.eq(v1.agents[CHILD].index, 1, "流れ 1：子は [1]")
t.eq(v1.agents[GRAND].index, 2, "流れ 1：孫は [2]")
t.eq(v1.agents.ROOT.status, "DONE", "流れ 1 の ROOT は DONE（Stop 済み・Agent も完了）")
t.eq(v1.counts.agents, 2, "流れ 1 の数")
t.eq(v1.flow.n, 1, "流れ 1 は 1 番目")
local v2 = state.flow_view(s3, P2)
t.eq(v2.counts.agents, 2, "流れ 2 の数（子と孫）")
t.eq(v2.agents[CHILD .. "x"].index, 1, "流れ 2 の子は [1] に振り直し")
t.eq(v2.agents[GRAND .. "x"].index, 2, "流れ 2 の孫は [2]")
t.eq(s3.agents[CHILD .. "x"].index, 3, "元の状態の番号は変わらない")
t.eq(v2.agents.ROOT.status, "RUNNING", "流れ 2 の ROOT は RUNNING（Stop 前）")
t.eq(v2.title, "二つ目の指示", "題名は指示の本文")
t.eq({ v2.flow.n, v2.flow.total }, { 2, 2 }, "指示 2/2")
t.eq(v2.agents.ROOT.children, { CHILD .. "x" }, "ROOT の子は流れの中の Agent だけ")
t.eq(graph.by_index(v2, 1), CHILD .. "x", "数字キー 1 は流れ 2 の子")
t.ok(v2.agents[CHILD] == nil, "流れ 1 の Agent は出ない")
-- 親が別の流れにいる Agent は「親が分からない」に出る
s3.agents[CHILD .. "x"].prompt_id = P1
local v2b = state.flow_view(s3, P2)
t.eq(graph.unknown_parent_ids(v2b), { GRAND .. "x" }, "親が流れの外なら UNKNOWN_PARENT")
s3.agents[CHILD .. "x"].prompt_id = P2

-- 5. セッションをまたいで一番新しい流れを探す
local A = "aaaaaaaa-0000-0000-0000-00000000000a"
local B = "bbbbbbbb-0000-0000-0000-00000000000b"
make_run(A, vim.list_slice(lines, 1, 11))
vim.wait(20)
make_run(B, vim.list_extend({ lines[1] }, flow_lines(P2, 60, "b")))
local r, f = events.latest_flow(slug)
t.eq({ r and r.sid, f and f.id }, { B, P2 }, "時刻が新しい B の流れ")
local P3 = "p3000000-0000-0000-0000-000000000003"
local orig0, calls0 = state.reduce, 0
state.reduce = function(...) calls0 = calls0 + 1; return orig0(...) end
append(A, flow_lines(P3, 200, "c"))
r, f = events.latest_flow(slug)
state.reduce = orig0
t.eq({ r and r.sid, f and f.id }, { A, P3 }, "A に新しい指示が来たら A")
t.eq(calls0, 0, "一度読んだ run は増えた分だけ足す（全部を計算し直さない）")
local live = events.load(r.dir)
local r2 = events.latest_flow(slug, live)
t.ok(r2 == live, "画面の run が最新なら、その run をそのまま返す")
-- ファイルが変わっていなければ作り直さない
local orig, calls = state.reduce, 0
state.reduce = function(...) calls = calls + 1; return orig(...) end
events.latest_flow(slug)
events.latest_flow(slug)
state.reduce = orig
t.eq(calls, 0, "控えが新しければ計算し直さない")
local rc, fc = events.current_flow(first.cwd)
t.eq({ rc and rc.sid, fc }, { A, P3 }, "current_flow も同じ")

-- 6. 一覧：流れ 1 つにつき 1 行
local list = events.list_runs({ slug = slug })
local rowsA, rowsB = {}, {}
for _, x in ipairs(list) do
  if x.sid == A then rowsA[#rowsA + 1] = x end
  if x.sid == B then rowsB[#rowsB + 1] = x end
end
t.eq(#rowsA, 2, "A は 2 行（指示 2 つ）")
t.eq(#rowsB, 1, "B は 1 行")
t.eq(list[1].flow_id, P3, "新しい順（A の 2 つ目の指示が先頭）")
t.eq(list[1].title, "指示 c", "行の題名は指示の本文")
t.eq({ list[1].flow_n, list[1].flow_total, list[1].agents }, { 2, 2, 2 }, "指示 2/2・Agent 2")
t.eq(rowsA[2].flow_id, P1, "A の古いほうの指示")

-- 7. prompt_id の無い記録（今までの形）：セッション全体のまま
local C = "cccccccc-0000-0000-0000-00000000000c"
local plain = {}
for i = 1, 11 do
  local d = vim.json.decode(lines[i]); d.prompt_id = nil; d._ts = shift(d._ts, 500)
  plain[#plain + 1] = vim.json.encode(d)
end
make_run(C, plain)
local runC = events.load(proj .. "/runs/" .. C)
t.eq(#runC.state.flows, 0, "prompt_id が無ければ流れは無い")
t.eq(state.latest_flow_id(runC.state), nil, "最新の流れも無い")
t.eq(runC.state.counts.agents, 2, "Agent はそのまま数える")
local rowsC = 0
for _, x in ipairs(events.list_runs({ slug = slug })) do
  if x.sid == C then
    rowsC = rowsC + 1
    t.eq(x.flow_id, nil, "流れの印なし")
  end
end
t.eq(rowsC, 1, "prompt_id が無い run は 1 行")
-- 流れのある run が 1 つも無いフォルダで開いても、ほかのプロジェクトのいちばん新しい流れを開く
--（流れがどこにも無いときの「run 全体」は test_phantom.lua で見る）
local proj2 = root .. "/projects/-tmp-plain"
vim.fn.mkdir(proj2 .. "/runs/" .. C, "p")
vim.fn.writefile({ vim.json.encode({ cwd = "/tmp/plain", slug = "-tmp-plain" }) }, proj2 .. "/project.json")
vim.fn.writefile(with_sid(plain, C), proj2 .. "/runs/" .. C .. "/hooks.jsonl")
local rp, fp2 = events.current_flow("/tmp/plain")
t.eq({ rp and rp.sid, fp2 }, { A, P3 }, "フォルダに関係なく、いちばん新しい流れ")
local head = table.concat(graph.layout(runC.state, { width = 160 }).lines, "\n")
t.ok(head:find("agents", 1, true) and not head:find("指示 ", 1, true), "見出しに「指示」は出ない")
local head2 = table.concat(graph.layout(v2, { width = 160 }).lines, "\n")
t.ok(head2:find("prompt 2/2: 二つ目の指示", 1, true), "流れの図の見出しに「指示 2/2」と本文")

-- 古い形の控え（sv なし）は作り直される
local sj = util.json_decode(util.read_file(proj .. "/runs/" .. A .. "/state.json"))
sj.sv = nil
util.write_atomic(proj .. "/runs/" .. A .. "/state.json", util.json_encode(sj))
local ra = events.load(proj .. "/runs/" .. A)
t.eq(ra.state.sv, state.SV, "古い控えは作り直す")
t.eq(#ra.state.flows, 2, "作り直した控えにも流れがある")

t.done()
