-- ============================================================
--  test_steer_events.lua -- steering instructions on the Neovim side (events.lua, DESIGN-v0.2-steer §5.3)
--    request_steer : <run>/steer/<id>.json（0600）と <root>/steer.pending、events.jsonl に steer_requested
--    cancel_steer  : 未配達ファイルを消して steer_cancelled。hook が取った後なら何もしない
--    sweep_steers  : 宛先が終わった未配達を steer_expired にしてファイルを消す。印（steer.pending）の掃除
--    mark_steer_sent : 端末へ送った（steer_delivered via terminal）
--    親経由（via relay。DESIGN-v0.1.2-steer2 §6.5）：ファイルも印も書かない、relay_line と expect、
--      READ のあと親の番が終わって渡されなければ not_relayed、渡せば（SendMessage）期限切れにしない
--    collector との往復：Neovim が書いたファイルを bin/agentmap-collect --steer が配達し、provider が DELIVERED にする
--    報告を SubagentHandback で返す子（DESIGN-v0.1.2-handback）：印①の agent_handback、request_steer(rerouted_from)、
--      cancel_steer(reason = "rerouted")、skipped の期限切れ（agent_finished, skip_reason handback）
--  記録の保存先は一時フォルダ（minimal_init.lua の AGENTMAP_DIR）。
--  実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_steer_events.lua
--  requires: python3（collector との往復の節）
-- ============================================================
local t = require("t")
local events = require("agentmap.events")
local state = require("agentmap.state")
local util = require("agentmap.util")
local hooks = require("agentmap.hooks")

local ROOT = vim.env.AGENTMAP_DIR
local SID = "c0ffee40-0000-4000-8000-000000000040"
local SLUG = "-tmp-agentmap-test-steer"
local P = "c0ffee41-0000-4000-8000-000000000041"
local A, B = "afeed000000000041", "afeed000000000042"
local run_dir = ROOT .. "/projects/" .. SLUG .. "/runs/" .. SID
vim.fn.mkdir(run_dir, "p")
local FLAG = ROOT .. "/steer.pending"
local SDIR = run_dir .. "/steer"

local function iso(sec) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", sec) end
local T0 = os.time() - 600
local function hook(ev, sec, extra)
  local r = { session_id = SID, hook_event_name = ev, cwd = "/tmp/agentmap-test/steer", prompt_id = P,
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

-- ---------- 1. request_steer（hooks 経由） ----------
local id, err = events.request_steer(run, A, "docs/v3 を読むこと", { prompt_id = P })
t.ok(id ~= nil, "request_steer returns an id: " .. tostring(err))
t.matches(id or "", "^" .. A .. "%-%d+$", "id = <agent_id>-<ms>")
local file = SDIR .. "/" .. (id or "?") .. ".json"
local st = vim.uv.fs_stat(file)
t.ok(st ~= nil, "pending file written")
t.eq(st and st.mode % 512, 384, "pending file mode 0600")
local body = util.json_decode(util.read_file(file)) or {}
t.eq({ body.id, body.agent_id, body.text, body.by }, { id, A, "docs/v3 を読むこと", "nvim" }, "file content")
t.ok(vim.uv.fs_stat(FLAG) ~= nil, "steer.pending flag created")
local req = evs_of("steer_requested")
t.eq(#req, 1, "steer_requested recorded once")
t.eq({ req[1].steer_id, req[1].agent_id, req[1].via, req[1].kind, req[1].prompt_id, req[1].src },
  { id, A, "hook", "steer", P, "user" }, "steer_requested fields")
t.eq(run.state.steers[id].status, "PENDING", "state: PENDING")
local id2 = events.request_steer(run, A, "second")
t.ok(id2 ~= id and tonumber(id2:match("%-(%d+)$")) > tonumber(id:match("%-(%d+)$")), "a second request gets a larger ms")
t.eq(evs_of("steer_requested")[2].prompt_id, P, "prompt_id defaults to the latest flow")
t.eq(select(2, events.request_steer(run, "pending:toolu_x", "x")), "bad_target", "targets with odd characters are refused")
t.eq(select(2, events.request_steer(run, A, "  \n ")), "empty", "empty text is refused")
local long = events.request_steer(run, B, string.rep("あ", 5000))
t.eq(vim.fn.strchars(run.state.steers[long].text), 4000, "text clipped to steer.text_max (4000)")

-- ---------- 2. cancel_steer ----------
t.eq(events.cancel_steer(run, id2), true, "cancel_steer → true")
t.eq(vim.uv.fs_stat(SDIR .. "/" .. id2 .. ".json"), nil, "cancel removes the pending file")
t.eq(run.state.steers[id2].status, "CANCELLED", "state: CANCELLED")
t.eq(select(2, events.cancel_steer(run, id2)), "cancelled", "cancel twice → refused")
t.eq(select(2, events.cancel_steer(run, "nope")), "unknown", "cancel an unknown id → refused")

-- ---------- 3. collector との往復（hook が取ったものは取り消せない・DELIVERED になる） ----------
if vim.fn.executable("python3") == 1 then
  local payload = vim.json.decode(hook("PreToolUse", 30, { agent_id = A, tool_name = "Write", tool_use_id = "toolu_w1" }))
  payload._v, payload._ts, payload._src = nil, nil, nil
  payload.tool_input = { file_path = "/tmp/agentmap-test/a.txt" }
  local guard = hooks.steer_cmd({ record = "python3 " .. hooks.quote(hooks.collector_path()) .. " --root " .. hooks.quote(ROOT), root = ROOT, mode = "deny" })
  local r = vim.system({ "bash", "-c", guard }, { stdin = vim.json.encode(payload), text = true }):wait()
  local out = r.stdout ~= "" and vim.json.decode(r.stdout) or {}
  t.matches(((out.hookSpecificOutput or {}).permissionDecisionReason) or "", "docs/v3 を読むこと", "the hook delivers the Neovim-written file")
  t.ok(vim.uv.fs_stat(SDIR .. "/" .. id .. ".delivered.json") ~= nil, "delivered file kept for audit")
  t.eq(select(2, events.cancel_steer(run, id)), "delivered", "cancel after the hook took it → refused, nothing recorded")
  events.poll(run)
  t.eq(run.state.steers[id].status, "DELIVERED", "provider turns the hook line into DELIVERED")
  t.eq(run.state.steers[id].delivered_via, "PreToolUse:Write", "delivered_via")
  t.eq(#evs_of("steer_cancelled"), 1, "only the first cancel was recorded")
else
  t.skip("python3 が無い（collector との往復）")
end

-- ---------- 4. sweep_steers（宛先が終わった） ----------
local idb = events.request_steer(run, B, "B に届くはず")
append_hooks({ hook("SubagentStop", 100, { agent_id = B, last_head = "done" }) })
local fin = T0 + 100
run._sweeping = true -- poll の中の自動の掃除を止めて、時刻を指定して呼ぶ
events.poll(run)
run._sweeping = nil
t.eq(run.state.agents[B].status, "DONE", "B DONE")
t.eq(events.sweep_steers(run, fin + 1), false, "within the grace time (the stop hook may still deliver) → not expired")
t.eq(run.state.steers[idb].status, "PENDING", "still PENDING")
t.eq(events.sweep_steers(run, fin + 10), true, "after the grace time → changed")
t.eq(run.state.steers[idb].status, "EXPIRED", "state: EXPIRED")
t.eq(run.state.steers[idb].end_reason, "agent_finished", "end_reason agent_finished")
t.eq(vim.uv.fs_stat(SDIR .. "/" .. idb .. ".json"), nil, "expired file removed")
t.ok(vim.uv.fs_stat(SDIR .. "/" .. id .. ".delivered.json") ~= nil or vim.fn.executable("python3") == 0, ".delivered.json is not swept")
t.eq(evs_of("steer_expired")[1].reason, "agent_finished", "steer_expired recorded")
-- ファイルが hook に取られている（.delivering.<pid>）なら期限切れにしない（配達の記録が後から来る）
local idc = events.request_steer(run, B, "taken")
os.rename(SDIR .. "/" .. idc .. ".json", SDIR .. "/" .. idc .. ".delivering.123")
t.eq(events.sweep_steers(run, fin + 20), false, "taken by a hook → not expired")
t.eq(run.state.steers[idc].status, "PENDING", "still PENDING while the hook delivers")
os.remove(SDIR .. "/" .. idc .. ".delivering.123")
t.eq(events.sweep_steers(run, fin + 30), true, "file gone without trace → expired")

-- ---------- 5. 印（steer.pending）の掃除 ----------
-- 未配達：A 宛てに long（B 宛て）を除くと… 残っているのは long（B 宛て。B は終わった）だけ → 期限切れで 0 件
t.eq(run.state.steers[long].status, "EXPIRED", "the long one (to B) expired together")
t.eq(vim.uv.fs_stat(FLAG), nil, "no pending file anywhere → flag removed")
local idd = events.request_steer(run, A, "keep the flag")
t.ok(vim.uv.fs_stat(FLAG) ~= nil, "flag back with a new request")
-- 別の run に未配達が残っていれば消さない
local other = ROOT .. "/projects/" .. SLUG .. "/runs/other-session/steer"
vim.fn.mkdir(other, "p")
vim.fn.writefile({ "{}" }, other .. "/ROOT-1790000000000.json")
events.cancel_steer(run, idd)
t.ok(vim.uv.fs_stat(FLAG) ~= nil, "a pending file in another run keeps the flag")
os.remove(other .. "/ROOT-1790000000000.json")
vim.fn.writefile({ "{}" }, other .. "/ROOT-1790000000000.delivered.json")
t.eq(events._sweep_flag(run), true, "only .delivered.json left → flag removed")
-- 開かれない run に古い未配達が取り残された：一定時間を過ぎたら消して印も消す（Python が起動し続けない）
vim.fn.writefile({}, FLAG)
vim.fn.writefile({ "{}" }, other .. "/ROOT-1790000000001.json")
t.eq(events._sweep_flag(run), false, "a fresh pending file in another run keeps the flag")
t.eq(events._sweep_flag(run, os.time() + events.STEER_STALE + 60), true, "a stale pending file no longer keeps the flag")
t.eq(vim.uv.fs_stat(other .. "/ROOT-1790000000001.json"), nil, "… and the stale file is removed")
-- 開いた直後の 1 回：取り残された印を消す
vim.fn.writefile({}, FLAG)
local fresh = events.load(run_dir)
events.sweep_steers(fresh)
t.eq(vim.uv.fs_stat(FLAG), nil, "a stale flag is removed by the first sweep after opening")

-- ---------- 6. 端末へ送った（via terminal） ----------
local idt = events.request_steer(run, "ROOT", "summarize now", { via = "terminal" })
t.eq(vim.uv.fs_stat(SDIR .. "/" .. idt .. ".json"), nil, "terminal: no pending file")
t.eq(run.state.steers[idt].via, "terminal", "terminal: via")
t.eq(events.mark_steer_sent(run, idt), true, "mark_steer_sent → true")
t.eq(run.state.steers[idt].status, "DELIVERED", "terminal: DELIVERED (sent)")
t.eq(run.state.steers[idt].delivered_via, "terminal", "terminal: delivered_via = terminal")
t.eq(events.mark_steer_sent(run, "nope"), false, "mark_steer_sent of an unknown id → false")

-- ---------- 7. ROOT 宛て（hooks へ落とした）：流れが終わって止まっていれば期限切れ ----------
local idr = events.request_steer(run, "ROOT", "for the stopped root")
append_hooks({ hook("Stop", 200, { last_head = "finished" }) })
run._sweeping = true
events.poll(run)
run._sweeping = nil
t.eq(events.sweep_steers(run, T0 + 210), false, "ROOT: the turn ended but A still runs (ROOT may wake up) → kept")
append_hooks({ hook("SubagentStop", 220, { agent_id = A, last_head = "A done" }) })
run._sweeping = true
events.poll(run)
run._sweeping = nil
t.eq(events.sweep_steers(run, T0 + 221), true, "ROOT: the turn ended and nothing runs → expired")
t.eq(run.state.steers[idr].status, "EXPIRED", "ROOT steer EXPIRED")
-- セッションが終わったら全部
local ida = events.request_steer(run, "ROOT", "after the end")
append_hooks({ hook("SessionEnd", 300, { reason = "other" }) })
events.poll(run) -- 記録が増えたので poll の最後に掃除が走る
t.eq(run.state.steers[ida].status, "EXPIRED", "session ended → expired by poll's sweep")
t.eq(run.state.steers[ida].end_reason, "session_ended", "end_reason session_ended")

-- ---------- 8. 親への知らせ（付録 E）：notice_of を記録と state に残す（作るのは UI） ----------
local SID2 = "c0ffee42-0000-4000-8000-000000000042"
local run2_dir = ROOT .. "/projects/" .. SLUG .. "/runs/" .. SID2
vim.fn.mkdir(run2_dir, "p")
vim.fn.writefile({}, run2_dir .. "/events.jsonl")
local run2 = events.load(run2_dir)
local PA, GC = "afeed000000000051", "afeed000000000052"
local function sys(ev) ev.src = "system"; ev.prompt_id = ev.prompt_id or P; return events.emit(run2, ev) end
sys({ event = "run_prompt", prompt_head = "notices" })
sys({ event = "agent_linked", agent_id = PA, parent_id = "ROOT", task = "parent agent" })
sys({ event = "agent_started", agent_id = PA })
sys({ event = "agent_linked", agent_id = GC, parent_id = PA, task = "grandchild" })
sys({ event = "agent_started", agent_id = GC })
local gid = events.request_steer(run2, GC, "use docs/v3")
sys({ event = "steer_delivered", steer_id = gid, agent_id = GC, via = "PreToolUse:Write" })
t.eq(events.sweep_steers(run2), false, "events itself creates no notice (the UI does)")
t.eq(#run2.state.steer_order, 1, "… only the instruction")
-- 同じ run を開いているもう 1 つの Neovim（知らせが作られる前の状態のまま）
local stale = events.load(run2_dir)
t.eq(stale.state.steers[gid].status, "DELIVERED", "the other Neovim sees the delivered instruction")
local nid = events.request_steer(run2, PA, "The user sent this instruction directly to your sub-agent [2] \"grandchild\": use docs/v3.",
  { kind = "notice", notice_of = gid })
-- 二重防止（本人の指定 2026-10-04）：同じ指示の 2 つ目の知らせは、記録を読み直して断る
t.eq(select(2, events.request_steer(run2, PA, "again", { kind = "notice", notice_of = gid })), "duplicate",
  "a second notice for the same instruction is refused")
t.eq(stale.state.steers[gid].notice_id, nil, "the other Neovim has not read the notice yet")
t.eq(select(2, events.request_steer(stale, PA, "again", { kind = "notice", notice_of = gid })), "duplicate",
  "… it catches up with the records before writing and refuses as well")
t.eq(stale.state.steers[gid].notice_id, nid, "… and now knows the notice")
t.eq(#vim.fn.glob(run2_dir .. "/steer/" .. PA .. "-*.json", false, true), 1, "exactly one pending notice file")
t.ok(events.request_steer(run2, PA, "a plain instruction is not a duplicate") ~= nil, "ordinary instructions are not affected")
local nreq
for _, e in ipairs(util.json_lines(run2_dir .. "/events.jsonl", 0)) do
  if e.event == "steer_requested" and e.steer_id == nid then nreq = e end
end
t.eq({ nreq and nreq.kind, nreq and nreq.notice_of, nreq and nreq.agent_id, nreq and nreq.via }, { "notice", gid, PA, "hook" },
  "steer_requested of a notice carries kind / notice_of")
t.eq(run2.state.steers[nid].notice_of, gid, "state: notice.notice_of = the instruction")
t.eq(run2.state.steers[gid].notice_id, nid, "state: instruction.notice_id = the notice (to avoid a second one)")
t.ok(vim.uv.fs_stat(run2_dir .. "/steer/" .. nid .. ".json") ~= nil, "notice to a sub-agent parent: pending file like any instruction")
local reloaded = events.load(run2_dir)
t.eq(reloaded.state.steers[gid].notice_id, nid, "the link survives a reload (rebuilt from events.jsonl)")
-- 記録の順が逆（知らせの記録が先）でも結び付く
local s3 = state.new("x")
state.apply(s3, { event = "steer_requested", steer_id = "n1", agent_id = "ROOT", kind = "notice", notice_of = "c1", ts = "2026-10-04T10:00:01.000Z" })
state.apply(s3, { event = "steer_requested", steer_id = "c1", agent_id = "kid", ts = "2026-10-04T10:00:00.000Z" })
t.eq(s3.steers.n1.notice_of, "c1", "notice first: notice_of kept")
t.eq(s3.steers.c1.notice_id, "n1", "notice first: the instruction still gets notice_id")

-- ---------- 9. 親経由（relay）と expect（DESIGN-v0.1.2-steer2 §6.5） ----------
local SID3 = "c0ffee43-0000-4000-8000-000000000043"
local run3_dir = ROOT .. "/projects/" .. SLUG .. "/runs/" .. SID3
vim.fn.mkdir(run3_dir, "p")
local P3 = "c0ffee44-0000-4000-8000-000000000044"
local C3 = "afeed000000000061"
local function hook3(ev, sec, extra)
  local r = { session_id = SID3, hook_event_name = ev, cwd = "/tmp/agentmap-test/steer", prompt_id = P3,
    transcript_path = "/tmp/agentmap-test/claude/projects/" .. SLUG .. "/" .. SID3 .. ".jsonl",
    _v = 1, _ts = iso(T0 + sec), _src = "claude_hook" }
  for k, v in pairs(extra or {}) do r[k] = v end
  return vim.json.encode(r)
end
local function append3(lines)
  local f = assert(io.open(run3_dir .. "/hooks.jsonl", "ab"))
  for _, l in ipairs(lines) do f:write(l .. "\n") end
  f:close()
end
local function poll3(r) r._sweeping = true; events.poll(r); r._sweeping = nil end
append3({
  hook3("SessionStart", 0, { source = "startup" }),
  hook3("UserPromptSubmit", 1, { prompt_head = "relay work" }),
  hook3("SubagentStart", 2, { agent_id = C3, agent_type = "general-purpose" }),
})
local run3 = events.load(run3_dir)
os.remove(FLAG)
local function evs3(name, sid)
  for _, e in ipairs(util.json_lines(run3_dir .. "/events.jsonl", 0)) do
    if e.event == name and e.steer_id == sid then return e end
  end
end
local RL = '[AgentMap] Tell sub-agent [1] "child" (agent id ' .. C3 .. ') this, with SendMessage: write b.txt instead'
local r1 = events.request_steer(run3, C3, "write b.txt instead", { via = "relay", relay_line = RL })
t.ok(r1 ~= nil, "relay: request_steer returns an id")
t.eq(vim.uv.fs_stat(run3_dir .. "/steer/" .. r1 .. ".json"), nil, "relay: no pending file")
t.eq(vim.uv.fs_stat(FLAG), nil, "relay: no steer.pending flag")
local q1 = evs3("steer_requested", r1) or {}
t.eq({ q1.via, q1.expect, q1.relay_line, q1.prompt_id }, { "relay", "parent", RL, P3 }, "relay: steer_requested carries via / expect parent / relay_line")
t.eq(run3.state.steers[r1].relay_line, RL, "relay: state keeps relay_line")
-- expect：hooks（既定の mode stop）→ stop、端末 → terminal、mode deny → next、ROOT で端末なし（hooks）も mode に従う
local h1 = events.request_steer(run3, C3, "at its end")
t.eq((evs3("steer_requested", h1) or {}).expect, "stop", "hook + mode stop → expect stop")
t.eq(vim.uv.fs_stat(run3_dir .. "/steer/" .. h1 .. ".json") ~= nil, true, "hook: pending file as before")
local tm = events.request_steer(run3, "ROOT", "for root", { via = "terminal" })
t.eq((evs3("steer_requested", tm) or {}).expect, "terminal", "terminal → expect terminal")
require("agentmap.config").setup({ steer = { mode = "deny" } })
local h2 = events.request_steer(run3, C3, "next tool")
t.eq((evs3("steer_requested", h2) or {}).expect, "next", "hook + mode deny → expect next")
require("agentmap.config").setup({})
t.eq(events.cancel_steer(run3, h2), true, "cancel the deny one")
-- relay の取り消し（打つ前）：ファイルが無くても CANCELLED
local r0 = events.request_steer(run3, C3, "never typed", { via = "relay", relay_line = "[AgentMap] x" })
t.eq(events.cancel_steer(run3, r0), true, "relay: cancel before typing → true")
t.eq(run3.state.steers[r0].status, "CANCELLED", "relay: CANCELLED")
-- 打った → DELIVERED/terminal。読まれていなければ、親の番が終わっても期限切れにしない（SENT のまま）
t.eq(events.mark_steer_sent(run3, r1), true, "relay: mark_steer_sent")
t.eq(run3.state.steers[r1].status .. "/" .. run3.state.steers[r1].delivered_via, "DELIVERED/terminal", "relay: typed → DELIVERED/terminal")
append3({ hook3("Stop", 10, { last_head = "waiting for the child" }) })
poll3(run3)
t.eq(events.sweep_steers(run3, T0 + 30), false, "relay not read yet: the turn ended earlier → not expired")
t.eq(run3.state.steers[r1].status, "DELIVERED", "… stays DELIVERED (SENT)")
-- Claude Code が読んだ（新しい番）→ 親が SendMessage せずに番を終えた → 3 秒後に not_relayed
append3({ hook3("UserPromptSubmit", 40, { prompt_id = "c0ffee45-0000-4000-8000-000000000045", prompt_head = RL }) })
poll3(run3)
t.eq(run3.state.steers[r1].confirmed_at, iso(T0 + 40), "relay: READ by Claude Code (confirmed_at)")
t.eq(events.sweep_steers(run3, T0 + 45), false, "READ, the turn has not ended again → kept")
append3({ hook3("Stop", 50, { prompt_id = "c0ffee45-0000-4000-8000-000000000045", last_head = "ok" }) })
poll3(run3)
t.eq(events.sweep_steers(run3, T0 + 51), false, "READ, the turn ended 1 s ago (grace) → kept")
t.eq(events.sweep_steers(run3, T0 + 54), true, "READ, the turn ended without SendMessage → expired")
t.eq(run3.state.steers[r1].status .. "/" .. tostring(run3.state.steers[r1].end_reason), "EXPIRED/not_relayed", "relay: EXPIRED / not_relayed")
local x1 = evs3("steer_expired", r1) or {}
t.eq(x1.reason, "not_relayed", "steer_expired(not_relayed) recorded")
-- もう 1 件（hook の時刻は頼んだ実時刻より後にする。T0 は今の 600 秒前）：READ → SendMessage（PostToolUse の記録）→ 番が終わっても期限切れにしない
local r2 = events.request_steer(run3, C3, "and c.txt", { via = "relay", relay_line = RL:gsub("write b.txt instead", "and c.txt") })
events.mark_steer_sent(run3, r2)
append3({
  hook3("UserPromptSubmit", 690, { prompt_id = "c0ffee46-0000-4000-8000-000000000046", prompt_head = (RL:gsub("write b.txt instead", "and c.txt")) }),
  hook3("PostToolUse", 700, { prompt_id = "c0ffee46-0000-4000-8000-000000000046", tool_name = "SendMessage", tool_use_id = "toolu_sm1",
    tool_input = { to = C3, head = "and c.txt", summary = "c.txt" } }),
  hook3("Stop", 701, { prompt_id = "c0ffee46-0000-4000-8000-000000000046", last_head = "sent" }),
})
poll3(run3)
t.eq(run3.state.steers[r2].delivered_via, "SendMessage", "relay 2: SendMessage → RELAYED")
t.eq(run3.state.steers[r2].relayed_at, iso(T0 + 700), "relay 2: relayed_at")
t.eq(events.sweep_steers(run3, T0 + 760), false, "relay 2: passed on → not expired after the turn ends")
t.eq(run3.state.steers[r2].status, "DELIVERED", "relay 2: stays DELIVERED")
-- 終わり際（stop）の未配達は、宛先が動いている間は残る
t.eq(run3.state.steers[h1].status, "PENDING", "stop: PENDING while the target runs")
t.ok(vim.uv.fs_stat(run3_dir .. "/steer/" .. h1 .. ".json") ~= nil, "stop: the file stays")
-- セッションが終わる：READ 済みで渡っていない relay は not_relayed、読まれていない relay はそのまま
local r3 = events.request_steer(run3, C3, "unread", { via = "relay", relay_line = "[AgentMap] unread" })
events.mark_steer_sent(run3, r3)
local r4 = events.request_steer(run3, C3, "read but not relayed", { via = "relay", relay_line = "[AgentMap] Tell read but not relayed" })
events.mark_steer_sent(run3, r4)
append3({ hook3("UserPromptSubmit", 770, { prompt_id = "c0ffee47-0000-4000-8000-000000000047", prompt_head = "[AgentMap] Tell read but not relayed" }) })
poll3(run3)
t.ok(run3.state.steers[r4].confirmed_at ~= nil, "relay 4: READ")
append3({ hook3("SessionEnd", 780, { reason = "other" }) })
poll3(run3)
events.sweep_steers(run3, T0 + 781)
t.eq(run3.state.steers[r4].end_reason, "not_relayed", "session ended: READ relay → not_relayed")
t.eq(run3.state.steers[r3].status, "DELIVERED", "session ended: unread relay stays SENT (DELIVERED/terminal)")
t.eq(run3.state.steers[h1].end_reason, "session_ended", "session ended: the stop one → session_ended")

-- ---------- 報告を SubagentHandback で返す子（DESIGN-v0.1.2-handback §3.6・§4.2） ----------
do
  local SID4 = "c0ffee48-0000-4000-8000-000000000048"
  local run4_dir = ROOT .. "/projects/" .. SLUG .. "/runs/" .. SID4
  vim.fn.mkdir(run4_dir, "p")
  local H4 = "afeed000000000048"
  local P4 = "c0ffee49-0000-4000-8000-000000000049"
  local TR = vim.fn.tempname() .. "-agent.jsonl"
  local function hook4(ev, sec, extra)
    local r = { session_id = SID4, hook_event_name = ev, cwd = "/tmp/agentmap-test/steer", prompt_id = P4,
      transcript_path = "/tmp/agentmap-test/claude/projects/" .. SLUG .. "/" .. SID4 .. ".jsonl",
      _v = 1, _ts = iso(T0 + sec), _src = "claude_hook" }
    for k, v in pairs(extra or {}) do r[k] = v end
    return vim.json.encode(r)
  end
  local function append4(lines)
    local f = assert(io.open(run4_dir .. "/hooks.jsonl", "ab"))
    for _, l in ipairs(lines) do f:write(l .. "\n") end
    f:close()
  end
  append4({
    hook4("SessionStart", 0, { source = "startup" }),
    hook4("UserPromptSubmit", 1, { prompt_head = "work", permission_mode = "auto" }),
    hook4("SubagentStart", 2, { agent_id = H4, agent_type = "general-purpose" }),
  })
  local run4 = events.load(run4_dir)
  t.eq(run4.state.permission_mode, "auto", "hand-back: s.permission_mode from the first prompt")
  -- 印①：transcript の先頭の固定文を poll_steps が見つけたら agent_handback を 1 回だけ記録する
  vim.fn.writefile(vim.fn.readfile(vim.g.agentmap_test_dir .. "/fixtures/transcript_handback.jsonl"), TR)
  events.emit(run4, { event = "agent_updated", agent_id = H4, transcript_path = TR, src = "system" })
  events.poll_steps(run4)
  local function count(name, dir)
    local n = 0
    for _, e in ipairs(util.json_lines((dir or run4_dir) .. "/events.jsonl", 0)) do if e.event == name then n = n + 1 end end
    return n
  end
  t.eq(count("agent_handback"), 1, "poll_steps: the reminder at the top → agent_handback (source transcript)")
  t.eq(run4.state.agents[H4].handback, true, "poll_steps: a.handback = true")
  vim.fn.writefile({ '{"type":"assistant","message":{"content":[{"type":"text","text":"more"}]}}' }, TR, "a")
  events.poll_steps(run4)
  t.eq(count("agent_handback"), 1, "poll_steps: recorded once")
  -- 終わり際に置いた指示 → collector が skipped → 自動で親経由（rerouted_from）→ 元は CANCELLED（rerouted）
  local k1 = events.request_steer(run4, H4, "write b.txt", { via = "hook" })
  append4({
    hook4("SubagentStop", 600, { agent_id = H4, agent_type = "general-purpose", report = "r", report_via = "handback" }),
    hook4("SubagentStop", 600, { agent_id = H4, steer = { ids = { k1 }, mode = "skipped", reason = "handback", target = H4 } }),
  })
  events.poll(run4)
  t.eq({ run4.state.steers[k1].status, run4.state.steers[k1].skip_reason }, { "PENDING", "handback" }, "skipped: PENDING with skip_reason")
  local k2 = events.request_steer(run4, H4, "write b.txt", { via = "relay", relay_line = "[AgentMap] Tell … write b.txt", rerouted_from = k1 })
  local req
  for _, e in ipairs(util.json_lines(run4_dir .. "/events.jsonl", 0)) do
    if e.event == "steer_requested" and e.steer_id == k2 then req = e end
  end
  t.eq(req and req.rerouted_from, k1, "request_steer: steer_requested carries rerouted_from")
  t.eq(run4.state.steers[k2].rerouted_from, k1, "state: rerouted_from")
  local okc = events.cancel_steer(run4, k1, { reason = "rerouted", rerouted_to = k2 })
  t.ok(okc, "cancel_steer with reason rerouted")
  local can
  for _, e in ipairs(util.json_lines(run4_dir .. "/events.jsonl", 0)) do
    if e.event == "steer_cancelled" and e.steer_id == k1 then can = e end
  end
  t.eq(can and { can.reason, can.rerouted_to }, { "rerouted", k2 }, "steer_cancelled carries reason / rerouted_to")
  t.eq({ run4.state.steers[k1].status, run4.state.steers[k1].end_reason, run4.state.steers[k1].rerouted_to },
    { "CANCELLED", "rerouted", k2 }, "state: CANCELLED (rerouted), rerouted_to")
  t.ok(vim.uv.fs_stat(run4_dir .. "/steer/" .. k1 .. ".json") == nil, "cancel_steer: the skipped file is removed")
  -- 回さなかった skipped は、宛先が終わって 3 秒たてば EXPIRED（agent_finished）＋ skip_reason handback
  local k3 = events.request_steer(run4, H4, "late one", { via = "hook" })
  append4({ hook4("SubagentStop", 600, { agent_id = H4, steer = { ids = { k3 }, mode = "skipped", reason = "handback", target = H4 } }) })
  events.poll(run4)
  t.eq(run4.state.steers[k3].status, "PENDING", "skipped: still PENDING within 3 s of the end")
  events.sweep_steers(run4, T0 + 600 + 4) -- 宛先は T0+600 に終わった
  local ex
  for _, e in ipairs(util.json_lines(run4_dir .. "/events.jsonl", 0)) do
    if e.event == "steer_expired" and e.steer_id == k3 then ex = e end
  end
  t.eq(ex and { ex.reason, ex.skip_reason }, { "agent_finished", "handback" }, "sweep_steers: steer_expired (agent_finished, skip_reason handback)")
  t.eq({ run4.state.steers[k3].status, run4.state.steers[k3].end_reason, run4.state.steers[k3].skip_reason },
    { "EXPIRED", "agent_finished", "handback" }, "state: EXPIRED (agent_finished, handback)")
  t.ok(vim.uv.fs_stat(run4_dir .. "/steer/" .. k3 .. ".json") == nil, "sweep_steers: the file is removed")
  -- skipped でない期限切れには skip_reason を付けない
  local k4 = events.request_steer(run4, H4, "plain", { via = "hook" })
  events.sweep_steers(run4, T0 + 600 + 4)
  for _, e in ipairs(util.json_lines(run4_dir .. "/events.jsonl", 0)) do
    if e.event == "steer_expired" and e.steer_id == k4 then ex = e end
  end
  t.eq({ ex.steer_id, ex.skip_reason }, { k4, nil }, "an ordinary expiry has no skip_reason")
  -- 記録を読むのが子の終わりから 3 秒以上遅れても、poll の中の片付けは skipped を消さない
  -- （図が先に親経由へ回す。ui.sweep_steers → reroute_skipped → sweep_steers の順）
  local H5 = "afeed000000000058"
  append4({ hook4("SubagentStart", 100, { agent_id = H5, agent_type = "general-purpose" }) })
  events.poll(run4)
  local k5 = events.request_steer(run4, H5, "late reader", { via = "hook" })
  append4({
    hook4("SubagentStop", 101, { agent_id = H5, agent_type = "general-purpose", report = "r", report_via = "handback" }),
    hook4("SubagentStop", 101, { agent_id = H5, steer = { ids = { k5 }, mode = "skipped", reason = "handback", target = H5 } }),
    hook4("PostToolUse", 102, { tool_name = "Bash", tool_use_id = "toolu_late" }),
  })
  events.poll(run4) -- 宛先は約 500 秒前に終わっている
  t.eq(run4.state.steers[k5].status, "PENDING", "poll: a skipped instruction is kept even long after the end (left for the relay)")
  t.ok(vim.uv.fs_stat(run4_dir .. "/steer/" .. k5 .. ".json") ~= nil, "poll: its file is kept")
  events.sweep_steers(run4)
  t.eq({ run4.state.steers[k5].status, run4.state.steers[k5].skip_reason }, { "EXPIRED", "handback" },
    "sweep_steers without keep_skipped: expired (after the UI had its chance)")
  os.remove(TR)
end

t.done()
