-- Claude 内部の手伝い役（まぼろしの Agent）と、フォルダをまたいだ「いちばん新しい流れ」の試験。
--   ・終わりの記録（SubagentStop）だけが届き、種類（agent_type）が空の Agent は Claude の内部の手伝い役。
--     図・数・流れ・親不明・書き出し・一覧のどこにも出さない（記録そのものは残る）
--   ・あとから開始や呼び出しの記録が届いたら、普通の Agent になる（終わりが先に届いた本物を失わない）
--   ・Space a a は、Neovim を開いたフォルダに関係なく、全プロジェクトでいちばん新しい流れを開く
--   ・見出しにセッションのフォルダが出る（開始の記録が無いセッションでも）
local t = require("t")
vim.notify = function() end

local fixture = vim.g.agentmap_test_dir .. "/fixtures/hooks_probe.jsonl"
if not vim.uv.fs_stat(fixture) then t.skip("fixture が無い"); t.done() end

local state = require("agentmap.state")
local events = require("agentmap.events")
local claude = require("agentmap.providers.claude")
local util = require("agentmap.util")
local graph = require("agentmap.graph")
local export = require("agentmap.export")
local store = require("agentmap.store")

local lines = vim.fn.readfile(fixture)
local first = vim.json.decode(lines[1])
local slug = vim.fn.fnamemodify(vim.fn.fnamemodify(first.transcript_path, ":h"), ":t")
local root = vim.env.AGENTMAP_DIR
local proj = root .. "/projects/" .. slug
vim.fn.mkdir(proj, "p")
vim.fn.writefile({ vim.json.encode({ cwd = first.cwd, slug = slug }) }, proj .. "/project.json")

local SID = first.session_id
local P1 = "c0ffee02-0000-4000-8000-000000000002"
local CHILD, GRAND = "afeed000000000006", "afeed000000000007"
local TU1, TU2 = "toolu_test0000000000000004", "toolu_test0000000000000005"

local function shift(ts, dt)
  local s = util.parse_iso(ts)
  local whole = math.floor(s + dt)
  local ms = math.floor(((s + dt) - whole) * 1000 + 0.5)
  return os.date("!%Y-%m-%dT%H:%M:%S", whole) .. (".%03dZ"):format(ms)
end
local T0 = first._ts

--- fixture の 2〜11 行目を、別の指示（pid）として作り直す
local function flow_lines(pid, dt, suffix, sid, cwd)
  local out = {}
  for i = 2, 11 do
    local l = lines[i]
    for _, k in ipairs({ CHILD, GRAND, TU1, TU2 }) do l = l:gsub(k, k .. suffix) end
    local d = vim.json.decode(l)
    d.prompt_id = pid
    d._ts = shift(d._ts, dt)
    if sid then d.session_id = sid end
    if cwd then d.cwd = cwd end
    if d.hook_event_name == "UserPromptSubmit" then d.prompt_head = "指示 " .. suffix end
    out[#out + 1] = vim.json.encode(d)
  end
  return out
end

--- Claude 内部の手伝い役の終わりの記録（本物の形：agent_type は空、会話記録のファイルは無い）
local function phantom_stop(id, pid, dt, sid, cwd)
  return vim.json.encode({
    session_id = sid or SID, hook_event_name = "SubagentStop", cwd = cwd or first.cwd,
    prompt_id = pid, agent_id = id, agent_type = "",
    agent_transcript_path = "/nope/subagents/agent-" .. id .. ".jsonl",
    last_head = "このセッションでは下書きを作成済みです", _v = 1, _ts = shift(T0, dt), _src = "claude_hook",
  })
end

local function reduce_lines(list)
  local evs = {}
  for _, l in ipairs(list) do
    for _, ev in ipairs(claude.normalize_hook(type(l) == "string" and vim.json.decode(l) or l)) do evs[#evs + 1] = ev end
  end
  for i, ev in ipairs(evs) do ev.seq = i end
  return state.reduce(evs)
end

local function make_run(pdir, sid, list)
  local d = pdir .. "/runs/" .. sid
  vim.fn.mkdir(d, "p")
  vim.fn.writefile(list, d .. "/hooks.jsonl")
  return d
end

-- ------------------------------------------------------------
-- 1. 記録の読み替え：終わりの記録の種類、指示の記録のフォルダ
-- ------------------------------------------------------------
local stop = vim.json.decode(lines[9])
local e1 = claude.normalize_hook(stop)[1]
t.eq({ e1.event, e1.agent_type }, { "agent_finished", "general-purpose" }, "終わりの記録に種類を載せる")
local e2 = claude.normalize_hook(vim.json.decode(phantom_stop("X", P1, 5)))[1]
t.eq({ e2.event, e2.agent_type }, { "agent_finished", nil }, "種類が空なら載せない")
local e3 = claude.normalize_hook(vim.json.decode(lines[2]))[1]
t.eq({ e3.event, e3.cwd }, { "run_prompt", first.cwd }, "指示の記録にフォルダを載せる")

-- ------------------------------------------------------------
-- 2. まぼろしの Agent は出さない
-- ------------------------------------------------------------
local OTHER = "p0000000-0000-0000-0000-0000000000ff" -- 指示の記録が無い prompt_id（入れ物の流れを作らないことを見る）
local base = { lines[1], lines[2], phantom_stop("X", OTHER, 5), lines[11] }
local s = reduce_lines(base)
t.eq(s.agents.X, nil, "Agent として作らない")
t.eq({ s.counts.agents, s.counts.unknown_parent, s.counts.phantoms }, { 0, 0, 1 }, "数えない（手伝い役として 1 件覚えるだけ）")
t.eq(#s.flows, 1, "手伝い役の記録から流れを作らない")
t.eq(s.flows[1].agents, 0, "流れの Agent は 0")
t.eq(state.latest_flow_id(s), nil, "Agent の無い流れは「最新の流れ」にならない")
local L = graph.layout(s, { width = 200, mode = "box" })
t.eq(L.nodes.UNKNOWN_PARENT, nil, "親不明の箱を出さない")
t.ok(L.lines[1]:find("0 agents", 1, true) ~= nil, "見出しは 0 agents: " .. L.lines[1])
local md = export.to_markdown(s)
t.ok(md:find("| Agents | 0 |", 1, true) ~= nil, "書き出しの Agent 数は 0")
t.ok(md:find("UNKNOWN_PARENT", 1, true) == nil, "書き出しに親不明なし")
-- 同じ手伝い役の終わりが 2 回届いても 1 件
local s1b = reduce_lines({ lines[1], lines[2], phantom_stop("X", P1, 5), phantom_stop("X", P1, 7) })
t.eq({ s1b.counts.agents, s1b.counts.phantoms }, { 0, 1 }, "2 回目の終わりも無視")
t.eq(s1b.phantoms.X.ts, shift(T0, 5), "覚えるのは最初の終わり")

-- ------------------------------------------------------------
-- 3. あとから開始・呼び出しの記録が届いたら普通の Agent
-- ------------------------------------------------------------
local s2 = reduce_lines({ lines[1], lines[2], phantom_stop("X", P1, 5), lines[11] })
state.apply(s2, { event = "agent_started", ts = shift(T0, 8), agent_id = "X", agent_type = "Explore", prompt_id = P1, seq = 100 })
local x = s2.agents.X
t.ok(x ~= nil, "開始が届いたら Agent になる")
t.eq({ x and x.status, x and x.index, x and x.finished_at, x and #x.attempts },
  { "DONE", 1, shift(T0, 5), 1 }, "終わりは先に届いた記録のまま（完了・1 番・1 回目）")
t.eq({ s2.counts.agents, s2.counts.phantoms, s2.flows[1].agents }, { 1, 0, 1 }, "数と流れに入る")
t.eq(state.latest_flow_id(s2), P1, "その流れが最新になる")
-- 呼び出し（PreToolUse）→ 終わり（先に届く）→ 呼び出しの結果（PostToolUse）で結び付く
local s3 = reduce_lines({ lines[1], lines[2], lines[11] })
state.apply(s3, { event = "agent_spawn_requested", ts = shift(T0, 2), tool_use_id = "tu", parent_id = "ROOT",
  task = "調べる", prompt_id = P1, seq = 50 })
state.apply(s3, claude.normalize_hook(vim.json.decode(phantom_stop("X", P1, 5)))[1])
t.eq({ s3.counts.agents, s3.counts.phantoms }, { 1, 1 }, "呼び出しの待ちが 1 つ・終わりは預かり中")
state.apply(s3, { event = "agent_linked", ts = shift(T0, 9), agent_id = "X", parent_id = "ROOT", tool_use_id = "tu",
  prompt_id = P1, agent_type = "Explore", seq = 51 })
local x3 = s3.agents.X
t.eq({ s3.counts.agents, s3.counts.phantoms }, { 1, 0 }, "結び付いたら普通の Agent 1 つ")
t.eq({ x3 and x3.index, x3 and x3.parent_id, x3 and x3.name, x3 and x3.status }, { 1, "ROOT", "調べる", "DONE" },
  "番号・親・名前は呼び出しのまま、状態は完了")

-- ------------------------------------------------------------
-- 4. 預からないもの：種類のある終わり、Workflow の中の終わり
-- ------------------------------------------------------------
local stY = vim.json.decode(phantom_stop("Y", P1, 5)); stY.agent_type = "Explore"
local s4 = reduce_lines({ lines[1], lines[2], stY })
t.eq({ s4.agents.Y and s4.agents.Y.agent_type, s4.agents.Y and s4.agents.Y.status, s4.counts.phantoms },
  { "Explore", "DONE", 0 }, "種類のある終わりは、先に届いても本物の Agent")
local stW = vim.json.decode(phantom_stop("W", P1, 5))
stW.agent_transcript_path = "/x/subagents/workflows/wf_q/agent-W.jsonl"
local s5 = reduce_lines({ lines[1], lines[2], stW })
t.eq({ s5.agents.W and s5.agents.W.parent_id, s5.counts.phantoms }, { "wf:wf_q", 0 }, "Workflow の中の Agent は本物")
-- 本物の fixture そのものは何も変わらない
local sf = reduce_lines(vim.list_slice(lines, 1, 11))
t.eq({ sf.counts.agents, sf.counts.phantoms, sf.counts.unknown_parent }, { 2, 0, 0 }, "普通の記録は今まで通り")

-- ------------------------------------------------------------
-- 5. 前に作った控え（state.json）も作り直して手伝い役を消す
-- ------------------------------------------------------------
local R = "r0000000-0000-0000-0000-00000000000r"
local rdir = make_run(proj, R, { lines[1], lines[2], phantom_stop("X", P1, 5), lines[11] })
local old = events.load(rdir).state
old.sv = 6
old.counts.agents = 1
old.agents.X = { id = "X", index = 1, status = "DONE", parent_id = "UNKNOWN_PARENT" }
old.order[#old.order + 1] = "X"
old.phantoms = nil
store.write_state(rdir, old)
local rl = events.load(rdir)
t.eq({ rl.state.sv, rl.state.counts.agents, rl.state.agents.X }, { state.SV, 0, nil }, "古い控えは作り直して 0 Agent")
local rowR
for _, x2 in ipairs(events.list_runs({ slug = slug })) do if x2.sid == R then rowR = x2 end end
t.eq(rowR and rowR.agents, 0, "一覧の Agent 数も 0（ただの会話）")

-- ------------------------------------------------------------
-- 6. フォルダ：開始の記録が無くても指示の記録から。どちらも無ければ project.json から
-- ------------------------------------------------------------
local s6 = reduce_lines(vim.list_slice(lines, 2, 11))
t.eq(s6.cwd, first.cwd, "開始の記録が無いセッションでも指示の記録のフォルダ")
local Q = "q0000000-0000-0000-0000-00000000000q"
local qdir = make_run(proj, Q, { phantom_stop("Z", P1, 3, Q) })
t.eq(events.load(qdir).state.cwd, first.cwd, "記録にフォルダが無ければプロジェクトのフォルダ")
t.eq(events.load(qdir).state.cwd, first.cwd, "控えから読んでも同じ")

-- ------------------------------------------------------------
-- 7. フォルダをまたいで、いちばん新しい流れ
-- ------------------------------------------------------------
local A = "aaaaaaaa-0000-0000-0000-00000000000a"
make_run(proj, A, vim.list_extend({ lines[1] }, flow_lines("p1111111-0000-0000-0000-000000000001", 60, "a", A)))
vim.wait(20)
local cwd2 = root .. "/work2"
local proj2 = root .. "/projects/-tmp-work2"
vim.fn.mkdir(proj2, "p")
vim.fn.writefile({ vim.json.encode({ cwd = cwd2, slug = "-tmp-work2" }) }, proj2 .. "/project.json")
local D = "dddddddd-0000-0000-0000-00000000000d"
local P9 = "p9000000-0000-0000-0000-000000000009"
make_run(proj2, D, flow_lines(P9, 600, "d", D, cwd2))
vim.wait(20)
-- もっと新しい run だが、手伝い役の終わりしか無い（ただの会話）
local E = "eeeeeeee-0000-0000-0000-00000000000e"
local PE = "pe000000-0000-0000-0000-00000000000e"
local pe = { vim.json.encode({ session_id = E, hook_event_name = "UserPromptSubmit", cwd = cwd2, prompt_id = PE,
  prompt_head = "ただの会話", _v = 1, _ts = shift(T0, 900), _src = "claude_hook" }), phantom_stop("X", PE, 905, E, cwd2) }
make_run(proj2, E, pe)
local r, f, mt = events.latest_flow(nil)
t.eq({ r and r.sid, f and f.id }, { D, P9 }, "全プロジェクトで最新の流れ（手伝い役だけの run は飛ばす）")
local dmt
for _, x2 in ipairs(store.runs("-tmp-work2")) do if x2.sid == D then dmt = x2.mtime end end
t.eq(mt, dmt, "3 つ目の戻り値はその run の最終更新時刻")
local rc, fc = events.current_flow(first.cwd)
t.eq({ rc and rc.sid, fc }, { D, P9 }, "Neovim のフォルダが別のプロジェクトでも同じ")
rc, fc = events.current_flow("/nowhere")
t.eq({ rc and rc.sid, fc }, { D, P9 }, "どこにも無いフォルダでも同じ")
t.ok(graph.layout(state.flow_view(r.state, P9), { width = 200 }).lines[1]:find("work2", 1, true) ~= nil,
  "見出しにセッションのフォルダ")
local P10 = "pa000000-0000-0000-0000-00000000000a"
vim.fn.writefile(flow_lines(P10, 1200, "b", A), proj .. "/runs/" .. A .. "/hooks.jsonl", "a")
r, f = events.latest_flow(nil)
t.eq({ r and r.sid, f and f.id }, { A, P10 }, "元のプロジェクトに新しい流れが来たらそちら")
local orig, calls = state.reduce, 0
state.reduce = function(...) calls = calls + 1; return orig(...) end
events.latest_flow(nil)
events.latest_flow(nil)
state.reduce = orig
t.eq(calls, 0, "ファイルが変わっていなければ計算し直さない")

-- 流れがどこにも無ければ、今のフォルダのいちばん新しい run の全体（今まで通り）
local root3 = vim.fn.tempname() .. "-af3"
vim.env.AGENTMAP_DIR = root3
local proj3 = root3 .. "/projects/-tmp-plain"
vim.fn.mkdir(proj3, "p")
vim.fn.writefile({ vim.json.encode({ cwd = "/tmp/plain", slug = "-tmp-plain" }) }, proj3 .. "/project.json")
make_run(proj3, E, pe)
local r3, f3 = events.current_flow("/tmp/plain")
t.eq({ r3 and r3.sid, f3 }, { E, nil }, "流れが無ければ run 全体")
vim.env.AGENTMAP_DIR = root
vim.fn.delete(root3, "rf")

t.done()
