-- ============================================================
--  test_pause_events.lua -- pausing agents on the Neovim side (events.lua, DESIGN-v0.1.2-pause §5.3)
--    request_pause : <run>/pause/<id>.json（0600）と <root>/pause.pending、pause_requested。2 回目は exists
--    resume_pause  : ファイルと .hit.json を消して pause_resumed、印の掃除
--    sweep_pauses  : 宛先が終わった止まれを pause_expired。終わりで止まっている（関門）ものは残す
--    set_gate / gate_on / sync_gate / release_all
--    collector との往復：Neovim が置いた止まれで bin/agentmap-collect --pause が待ち、消すと抜ける
--  記録の保存先は一時フォルダ（minimal_init.lua の AGENTMAP_DIR）。
--  実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_pause_events.lua
--  requires: python3（collector との往復の節。無ければその節だけ SKIP）
-- ============================================================
local t = require("t")
local events = require("agentmap.events")
local state = require("agentmap.state")
local util = require("agentmap.util")
local hooks = require("agentmap.hooks")
require("agentmap.config").setup({})

local ROOT = vim.env.AGENTMAP_DIR
local SID = "c0ffee50-0000-4000-8000-000000000050"
local SLUG = "-tmp-agentmap-test-pause"
local P = "c0ffee51-0000-4000-8000-000000000051"
local A, B, C = "afeed000000000051", "afeed000000000052", "afeed000000000053"
local run_dir = ROOT .. "/projects/" .. SLUG .. "/runs/" .. SID
vim.fn.mkdir(run_dir, "p")
local FLAG = ROOT .. "/pause.pending"
local PDIR = run_dir .. "/pause"

local function iso(sec) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", sec) end
local T0 = os.time() - 600
local function hook(ev, sec, extra)
  local r = { session_id = SID, hook_event_name = ev, cwd = "/tmp/agentmap-test/pause", prompt_id = P,
    transcript_path = "/tmp/agentmap-test/claude/projects/" .. SLUG .. "/" .. SID .. ".jsonl",
    _v = 1, _ts = iso(T0 + sec), _src = "claude_hook" }
  for k, v in pairs(extra or {}) do r[k] = v end
  return vim.json.encode(r)
end
local function append_hooks(lines)
  local f = assert(io.open(run_dir .. "/hooks.jsonl", "ab"))
  for _, l in ipairs(lines) do f:write(l .. "\n") end
  f:close()
end
append_hooks({
  hook("SessionStart", 0, { source = "startup" }),
  hook("UserPromptSubmit", 1, { prompt_head = "work" }),
  hook("SubagentStart", 2, { agent_id = A, agent_type = "general-purpose" }),
  hook("SubagentStart", 3, { agent_id = B, agent_type = "general-purpose" }),
})
local run = events.load(run_dir)
t.eq(run.state.agents[A].status, "RUNNING", "A RUNNING")
local function evs_of(name)
  local out = {}
  for _, e in ipairs(util.json_lines(run_dir .. "/events.jsonl", 0)) do
    if e.event == name then out[#out + 1] = e end
  end
  return out
end
local function exists(p) return vim.uv.fs_stat(p) ~= nil end

-- ---------- 1. request_pause ----------
local id, err = events.request_pause(run, A)
t.ok(id ~= nil, "request_pause returns an id: " .. tostring(err))
t.matches(id or "", "^" .. A .. "%-%d+$", "id = <agent_id>-<ms>")
local pf = PDIR .. "/" .. A .. ".json"
local st = vim.uv.fs_stat(pf)
t.ok(st ~= nil, "pause file written")
t.eq(st and st.mode % 512, 384, "pause file mode 0600")
local body = util.json_decode(util.read_file(pf)) or {}
t.eq({ body.id, body.agent_id, body.at, body.kind, body.auto_resume_s, body.by },
  { id, A, "next", "pause", 600, "nvim" }, "pause file content")
t.ok(#util.read_file(pf) <= 4096, "pause file <= 4 KB")
t.ok(exists(FLAG), "pause.pending flag created")
local req = evs_of("pause_requested")
t.eq(#req, 1, "pause_requested recorded once")
t.eq({ req[1].pause_id, req[1].agent_id, req[1].at, req[1].kind, req[1].auto_resume_s, req[1].src },
  { id, A, "next", "pause", 600, "user" }, "pause_requested fields")
t.eq(req[1].prompt_id, P, "prompt_id = the agent's flow")
t.eq(run.state.pauses[id].status, "REQUESTED", "state: REQUESTED")
t.eq(select(2, events.request_pause(run, A)), "exists", "a second pause for the same agent is refused (exists)")
t.eq(select(2, events.request_pause(run, "wf:x")), "bad_target", "wf: is refused")
t.eq(select(2, events.request_pause(run, "check:toolu_x")), "bad_target", "HUMAN CHECK ids are refused")
t.eq(select(2, events.request_pause(run, "UNKNOWN_PARENT")), "bad_target", "UNKNOWN_PARENT is refused")
t.eq(select(2, events.request_pause(run, "afeed0000nobody")), "bad_target", "unknown agents are refused")
t.eq(select(2, events.request_pause(nil, A)), "no_run", "no run")

-- ---------- 2. resume_pause ----------
t.ok(events.resume_pause(run, A), "resume_pause ok")
t.ok(not exists(pf), "pause file removed")
t.ok(not exists(FLAG), "pause.pending removed (no pause file left)")
local res = evs_of("pause_resumed")
t.eq({ #res, res[1].pause_id, res[1].agent_id, res[1].reason }, { 1, id, A, "user" }, "pause_resumed recorded (reason user)")
t.eq(run.state.pauses[id].status, "RESUMED", "state: RESUMED")
t.eq({ events.resume_pause(run, A) }, { false, "none" }, "resume without a live pause → false, none")
-- 指示つき：steer_id が記録に入る。.hit.json も消す
local id2 = events.request_pause(run, A)
vim.fn.writefile({ '{"id":"' .. id2 .. '","deadline":1}' }, PDIR .. "/" .. A .. ".hit.json")
t.ok(events.resume_pause(run, A, { steer_id = A .. "-77" }), "resume with steer_id")
t.ok(not exists(PDIR .. "/" .. A .. ".hit.json"), ".hit.json removed too")
t.eq(evs_of("pause_resumed")[2].steer_id, A .. "-77", "pause_resumed.steer_id")
t.eq(run.state.pauses[id2].steer_id, A .. "-77", "state: steer_id")
-- hook が先にファイルを消していても記録する
local id3 = events.request_pause(run, A)
os.remove(PDIR .. "/" .. A .. ".json")
t.ok(events.resume_pause(run, A), "resume when the hook already removed the file still records")
t.eq(run.state.pauses[id3].status, "RESUMED", "state: RESUMED")

-- ---------- 3. sweep_pauses ----------
local idb = events.request_pause(run, B, { at = "stop" })
t.ok(idb ~= nil, "pause for B (at stop)")
t.eq(events.sweep_pauses(run), false, "sweep: B still running → nothing")
append_hooks({ hook("SubagentStop", 20, { agent_id = B, last_head = "done" }) })
events.poll(run) -- poll の最後でも sweep_pauses が動く（終わってから 3 秒以上たっている）
t.eq(run.state.pauses[idb].status, "EXPIRED", "target DONE → EXPIRED (from poll)")
t.eq(run.state.pauses[idb].end_reason, "agent_finished", "end_reason agent_finished")
t.ok(not exists(PDIR .. "/" .. B .. ".json"), "expired: file removed")
t.eq(select(2, events.request_pause(run, B)), "finished", "a finished agent cannot be paused")
-- 終わりで止まっている（関門。終わりの記録 → hit の順）ものは消さない
append_hooks({ hook("SubagentStart", 30, { agent_id = C, agent_type = "general-purpose" }) })
events.poll(run)
local idc = events.request_pause(run, C, { at = "stop", kind = "gate" })
append_hooks({
  hook("SubagentStop", 40, { agent_id = C, last_head = "report" }),
  hook("SubagentStop", 40, { agent_id = C, pause = { id = idc, phase = "hit", kind = "gate", at = "stop", target = C } }),
})
events.poll(run)
t.eq(run.state.pauses[idc].status, "PAUSED", "gate hit at SubagentStop: PAUSED")
t.eq(state.display_status(run.state, C), "GATE", "display GATE while the hook holds the end")
t.eq(events.sweep_pauses(run), false, "sweep keeps a pause held at the end (the agent's DONE came before the hit)")
t.ok(exists(PDIR .. "/" .. C .. ".json"), "… and its file")
-- 古い REQUESTED（auto_resume_s + 1 時間）は取り残しとして消す
local idr = events.request_pause(run, "ROOT")
t.ok(idr ~= nil, "pause for ROOT")
t.eq(events.sweep_pauses(run), false, "ROOT's pause is kept while the session goes on")
t.eq(events.sweep_pauses(run, os.time() + 600 + events.PAUSE_STALE_EXTRA + 5), true, "stale REQUESTED pause expired")
t.eq(run.state.pauses[idr].end_reason, "stale", "end_reason stale")
t.eq(run.state.pauses[idc].status, "PAUSED", "the held gate pause is not stale (it is PAUSED)")
t.ok(events.resume_pause(run, C), "pass the gate")
append_hooks({ hook("SubagentStop", 50, { agent_id = C, pause = { id = idc, phase = "released", target = C, reason = "user", waited_ms = 10000 } }) })
events.poll(run)
t.eq({ run.state.pauses[idc].status, run.state.pauses[idc].release_reason, run.state.pauses[idc].waited_ms },
  { "RESUMED", "user", 10000 }, "resumed by the user, waited_ms from the hook")
-- 印の掃除：どこにも止まれファイルが無ければ消す。取り残しのファイルは消してから
vim.fn.mkdir(ROOT .. "/projects/-x/runs/old/pause", "p")
local old = ROOT .. "/projects/-x/runs/old/pause/ROOT.json"
vim.fn.writefile({ '{"id":"ROOT-1","auto_resume_s":600}' }, old)
vim.uv.fs_utime(old, os.time() - 600 - 3700, os.time() - 600 - 3700)
vim.fn.writefile({}, ROOT .. "/projects/-x/runs/old/pause/GATE")
vim.fn.writefile({ "{}" }, ROOT .. "/projects/-x/runs/old/pause/ROOT.hit.json")
vim.fn.writefile({}, FLAG)
t.eq(events._sweep_pause_flag(run), true, "flag removed when only stale files / GATE / .hit.json are left")
t.ok(not exists(old), "a stale pause file of an unopened run is removed")
vim.fn.writefile({ '{"id":"ROOT-2","auto_resume_s":600}' }, old)
vim.fn.writefile({}, FLAG)
t.eq(events._sweep_pause_flag(run), false, "flag kept while another run has a pause file")
os.remove(old)

-- 関門の「直す」：止まっている子（終わりの記録で DONE に見える）への指示は、止まれを消した後に hook が配達する。
-- そのあいだ（と解いた直後）に Neovim の掃除が指示を「届かなかった」として消さない
local Z = "afeed000000000059"
append_hooks({ hook("SubagentStart", 52, { agent_id = Z, agent_type = "general-purpose" }) })
events.poll(run)
local idz = events.request_pause(run, Z, { at = "stop", kind = "gate" })
append_hooks({
  hook("SubagentStop", 53, { agent_id = Z, last_head = "report" }),
  hook("SubagentStop", 53, { agent_id = Z, pause = { id = idz, phase = "hit", kind = "gate", at = "stop", target = Z } }),
})
events.poll(run)
t.eq(state.display_status(run.state, Z), "GATE", "Z waits at the gate (finished long ago by its stop record)")
local sfix = events.request_steer(run, Z, "fix it", { via = "hook" })
t.eq(events.sweep_steers(run), false, "sweep keeps an instruction to an agent held at its end")
events.resume_pause(run, Z, { steer_id = sfix })
append_hooks({ hook("PreToolUse", 54, { agent_id = A, tool_name = "Read", tool_use_id = "toolu_fix" }) })
events.poll(run)
events.sweep_steers(run)
t.ok(exists(run_dir .. "/steer/" .. sfix .. ".json"), "… and right after the pause was removed with it (the hook takes it)")
t.eq(run.state.steers[sfix].status, "PENDING", "the instruction stays PENDING for the hook")
t.eq(events.sweep_steers(run, os.time() + 60), true, "a while after the hand-off it expires like any other")

-- ---------- 4. gate ----------
-- 新しい子 2 つ（RUNNING）、ROOT と終わった子には置かない
local D, E = "afeed000000000054", "afeed000000000055"
append_hooks({
  hook("SubagentStart", 60, { agent_id = D, agent_type = "general-purpose" }),
  hook("SubagentStart", 61, { agent_id = E, agent_type = "general-purpose" }),
})
events.poll(run)
t.eq(events.gate_on(run), false, "gate off by default (pause.gate = false)")
t.ok(events.set_gate(run, true), "set_gate(true)")
t.ok(exists(PDIR .. "/GATE"), "GATE file written")
t.eq(events.gate_on(run), true, "gate_on after set_gate")
t.eq(evs_of("gate_set")[1].on, true, "gate_set on recorded")
local function body_of(x) return util.json_decode(util.read_file(PDIR .. "/" .. x .. ".json") or "") or {} end
-- A は RUNNING のまま（止まれ無し）なので置かれる
t.eq({ body_of(D).at, body_of(D).kind }, { "stop", "gate" }, "gate pause for D (at stop, kind gate)")
t.eq({ body_of(E).at, body_of(E).kind }, { "stop", "gate" }, "gate pause for E")
t.eq(body_of(A).kind, "gate", "gate pause for A (still running)")
t.ok(not exists(PDIR .. "/ROOT.json"), "no gate pause for ROOT")
t.ok(not exists(PDIR .. "/" .. B .. ".json"), "no gate pause for a finished agent")
t.ok(exists(FLAG), "pause.pending while gate pauses exist")
t.eq(events.sync_gate(run), 0, "sync_gate again: nothing new")
-- 新しい子が来たら poll の最後で置く
local F = "afeed000000000056"
append_hooks({ hook("SubagentStart", 70, { agent_id = F, agent_type = "general-purpose" }) })
events.poll(run)
t.eq(body_of(F).kind, "gate", "a new sub-agent gets a gate pause from poll")
-- D は終わりで止まる
local idd = state.pause_of(run.state, D).id
append_hooks({ hook("SubagentStop", 80, { agent_id = D, last_head = "r" }),
  hook("SubagentStop", 80, { agent_id = D, pause = { id = idd, phase = "hit", kind = "gate", at = "stop", target = D } }) })
events.poll(run)
t.eq(state.display_status(run.state, D), "GATE", "D waits at its end")
-- 切る：REQUESTED は gate_off で取り下げ、PAUSED は gate_off で再開
t.ok(events.set_gate(run, false), "set_gate(false)")
t.ok(not exists(PDIR .. "/GATE"), "GATE file removed")
t.eq(events.gate_on(run), false, "gate off")
local ide = run.state.agents[E].pauses[1]
t.eq({ run.state.pauses[ide].status, run.state.pauses[ide].end_reason }, { "EXPIRED", "gate_off" }, "REQUESTED gate pause → EXPIRED gate_off")
t.eq({ run.state.pauses[idd].status, run.state.pauses[idd].release_reason }, { "RESUMED", "gate_off" }, "PAUSED gate pause → RESUMED gate_off")
t.ok(not exists(PDIR .. "/" .. E .. ".json") and not exists(PDIR .. "/" .. D .. ".json"), "gate pause files removed")
t.ok(not exists(FLAG), "pause.pending removed")
-- config の pause.gate = true なら、gate_set の記録が無い run は入っている
local r2dir = ROOT .. "/projects/" .. SLUG .. "/runs/c0ffee52-0000-4000-8000-000000000052"
vim.fn.mkdir(r2dir, "p")
local r2 = events.load(r2dir)
require("agentmap.config").setup({ pause = { gate = true } })
t.eq(events.gate_on(r2), true, "pause.gate = true: gate on for a run without gate_set")
t.eq(events.gate_on(run), false, "… but gate_set off of this run wins")
require("agentmap.config").setup({ pause = false })
t.eq(events.sync_gate(r2), 0, "pause = false: sync_gate does nothing")
require("agentmap.config").setup({})

-- ---------- 5. release_all ----------
local ia = state.pause_of(run.state, A)
if ia then events.resume_pause(run, A) end
local i1 = events.request_pause(run, A)
local i2 = events.request_pause(run, "ROOT")
events.set_gate(run, true) -- E と F（まだ動いている）に関門の止まれ（REQUESTED）
local igf = state.pause_of(run.state, F)
t.ok(igf and igf.kind == "gate", "gate pause for F")
t.ok(state.pause_of(run.state, E) and state.pause_of(run.state, E).kind == "gate", "gate pause for E")
t.eq(events.release_all(run, "nvim_exit"), 4, "release_all: 4 live pauses")
t.eq(run.state.pauses[i1].release_reason, "nvim_exit", "pause → RESUMED nvim_exit")
t.eq(run.state.pauses[i2].release_reason, "nvim_exit", "ROOT → RESUMED nvim_exit")
t.eq({ igf.status, igf.end_reason }, { "EXPIRED", "nvim_exit" }, "REQUESTED gate → EXPIRED nvim_exit")
t.ok(exists(PDIR .. "/GATE"), "GATE is kept (the gate goes on when Neovim opens the run again)")
t.ok(not exists(FLAG), "no pause file left → flag removed")
events.set_gate(run, false)

-- ---------- 6. collector との往復 ----------
if vim.fn.executable("python3") == 1 and vim.fn.executable("bash") == 1 then
  local G = "afeed000000000057"
  append_hooks({ hook("SubagentStart", 100, { agent_id = G, agent_type = "general-purpose" }) })
  events.poll(run)
  local guard = hooks.steer_cmd({ record = "python3 " .. hooks.quote(hooks.collector_path()) .. " --root " .. hooks.quote(ROOT),
    root = ROOT, mode = "deny", pause = { auto_resume_s = 5 } })
  local payload = vim.json.encode({ session_id = SID, cwd = "/tmp/agentmap-test/pause", hook_event_name = "PreToolUse",
    transcript_path = "/tmp/agentmap-test/claude/projects/" .. SLUG .. "/" .. SID .. ".jsonl",
    tool_name = "Read", tool_use_id = "toolu_rt1", agent_id = G, prompt_id = P })
  local function wait_hit(n0)
    return vim.wait(3000, function()
      local ls = util.json_lines(run_dir .. "/hooks.jsonl", 0)
      for i = n0 + 1, #ls do if ls[i].pause and ls[i].pause.phase == "hit" then return true end end
      return false
    end, 50)
  end
  -- 指示なし：止まれ → hook が待つ → 再開 → 何も出さずに抜ける → RESUMED（user, waited_ms）
  local ip = events.request_pause(run, G)
  local n0 = #util.json_lines(run_dir .. "/hooks.jsonl", 0)
  local job = vim.system({ "bash", "-c", guard }, { stdin = payload, text = true })
  t.ok(wait_hit(n0), "round trip: the hook writes a hit line")
  events.poll(run)
  t.eq(run.state.pauses[ip].status, "PAUSED", "round trip: PAUSED after poll")
  t.eq(run.state.pauses[ip].hit_via, "PreToolUse:Read", "round trip: hit_via")
  local t1 = vim.uv.hrtime()
  events.resume_pause(run, G)
  local r = job:wait(3000)
  local ms = (vim.uv.hrtime() - t1) / 1e6
  t.eq({ r.code, r.stdout }, { 0, "" }, "round trip: the hook exits 0 and prints nothing")
  t.ok(ms < 1000, ("round trip: released within 1 s (%d ms)"):format(ms))
  events.poll(run)
  local pp = run.state.pauses[ip]
  t.eq({ pp.status, pp.release_reason }, { "RESUMED", "user" }, "round trip: RESUMED by the user")
  t.ok((pp.waited_ms or 0) > 0, "round trip: waited_ms from the hook")
  -- 指示つき：request_steer → resume_pause(steer_id) の順 → deny と止まっていた時間の 1 行
  local ip2 = events.request_pause(run, G)
  n0 = #util.json_lines(run_dir .. "/hooks.jsonl", 0)
  job = vim.system({ "bash", "-c", guard }, { stdin = payload, text = true })
  t.ok(wait_hit(n0), "round trip with an instruction: hit")
  local sid = events.request_steer(run, G, "use docs/v3", { via = "hook" })
  events.resume_pause(run, G, { steer_id = sid })
  r = job:wait(3000)
  local o = r.stdout ~= "" and vim.json.decode(r.stdout) or {}
  local h = o.hookSpecificOutput or {}
  t.eq(h.permissionDecision, "deny", "round trip with an instruction: deny")
  t.matches(h.permissionDecisionReason or "", "\n%(You were paused by the user for %d+ s before this instruction%.%)\nuse docs/v3\n",
    "round trip with an instruction: the paused-for line, then the text")
  events.poll(run)
  t.eq(run.state.pauses[ip2].steer_id, sid, "round trip with an instruction: pause.steer_id")
  t.eq(run.state.steers[sid].status, "DELIVERED", "round trip with an instruction: the steer is DELIVERED")
  -- 期限：auto_resume_s = 5 → hook が自分で消して抜ける（--max-wait 5）
  -- （5 秒待つので、ここでは .hit.json の期限を過去にして即時を確かめる）
  local ip3 = events.request_pause(run, G)
  vim.fn.writefile({ vim.json.encode({ id = ip3, deadline = os.time() - 1 }) }, PDIR .. "/" .. G .. ".hit.json")
  r = vim.system({ "bash", "-c", guard }, { stdin = payload, text = true }):wait(3000)
  t.eq({ r.code, r.stdout }, { 0, "" }, "past deadline: the hook exits at once")
  events.poll(run)
  t.eq({ run.state.pauses[ip3].status, run.state.pauses[ip3].release_reason }, { "RESUMED", "auto" }, "past deadline: RESUMED auto")
  t.ok(not exists(PDIR .. "/" .. G .. ".json"), "past deadline: the hook removed the pause file")
  events.sweep_pauses(run)
  t.ok(not exists(FLAG), "flag removed after the hook released the last pause")
  -- mode stop（0.1.2 の既定。DESIGN-v0.1.2-steer2 §5・E4）：止まれ＋指示 → resume_pause(steer_id) → 門番は何も出さず抜け、
  -- ファイルは残る。続く SubagentStop の hook がその指示を block で届ける
  local rec = "python3 " .. hooks.quote(hooks.collector_path()) .. " --root " .. hooks.quote(ROOT)
  local guard_s, stop_s = hooks.steer_cmd({ record = rec, root = ROOT, mode = "stop", pause = { auto_resume_s = 5 } })
  t.matches(guard_s, "%-%-mode stop %-%-pause %-%-max%-wait 5$", "mode stop: the guard command")
  local ip4 = events.request_pause(run, G)
  n0 = #util.json_lines(run_dir .. "/hooks.jsonl", 0)
  job = vim.system({ "bash", "-c", guard_s }, { stdin = payload, text = true })
  t.ok(wait_hit(n0), "mode stop round trip: hit")
  local sid4 = events.request_steer(run, G, "write b.txt instead", { via = "hook" })
  t.eq((function()
    for _, e in ipairs(util.json_lines(run_dir .. "/events.jsonl", 0)) do
      if e.event == "steer_requested" and e.steer_id == sid4 then return e.expect end
    end
  end)(), "stop", "mode stop round trip: expect = stop")
  t1 = vim.uv.hrtime()
  events.resume_pause(run, G, { steer_id = sid4 })
  r = job:wait(3000)
  ms = (vim.uv.hrtime() - t1) / 1e6
  t.eq({ r.code, r.stdout }, { 0, "" }, "mode stop round trip: the guard exits 0 and prints nothing (no delivery before a tool)")
  t.ok(ms < 1000, ("mode stop round trip: released within 1 s (%d ms)"):format(ms))
  t.ok(exists(run_dir .. "/steer/" .. sid4 .. ".json"), "mode stop round trip: the instruction file stays")
  local rel
  for _, l in ipairs(util.json_lines(run_dir .. "/hooks.jsonl", n0 > 0 and 0 or 0)) do
    if l.pause and l.pause.phase == "released" and l.pause.id == ip4 then rel = l.pause end
  end
  t.ok(rel ~= nil and rel.steer_ids == nil, "mode stop round trip: released line without steer_ids")
  events.poll(run)
  t.eq(run.state.pauses[ip4].status, "RESUMED", "mode stop round trip: RESUMED")
  t.eq(run.state.steers[sid4].status, "PENDING", "mode stop round trip: the steer is still PENDING (arrives at its end)")
  local stop_payload = vim.json.encode({ session_id = SID, cwd = "/tmp/agentmap-test/pause", hook_event_name = "SubagentStop",
    transcript_path = "/tmp/agentmap-test/claude/projects/" .. SLUG .. "/" .. SID .. ".jsonl",
    agent_id = G, agent_type = "general-purpose", prompt_id = P, stop_hook_active = false, last_assistant_message = "a.txt written." })
  r = vim.system({ "bash", "-c", stop_s }, { stdin = stop_payload, text = true }):wait(3000)
  o = r.stdout ~= "" and vim.json.decode(r.stdout) or {}
  t.eq(o.decision, "block", "mode stop round trip: SubagentStop → decision block")
  t.matches(o.reason or "", "just before you finish:\nwrite b.txt instead\nApply it now", "mode stop round trip: the at-its-end text")
  t.ok(not (o.reason or ""):find("You were paused", 1, true), "mode stop round trip: no paused-for line (this hook did not wait)")
  events.poll(run)
  t.eq(run.state.steers[sid4].status, "DELIVERED", "mode stop round trip: DELIVERED at SubagentStop")
  t.eq(run.state.agents[G].status, "RUNNING", "mode stop round trip: the child keeps working (block reopens it)")
else
  t.skip("python3 / bash not found: collector round trip")
end

t.done()
