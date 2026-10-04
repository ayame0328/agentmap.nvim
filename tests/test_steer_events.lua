-- ============================================================
--  test_steer_events.lua -- steering instructions on the Neovim side (events.lua, DESIGN-v0.2-steer §5.3)
--    request_steer : <run>/steer/<id>.json（0600）と <root>/steer.pending、events.jsonl に steer_requested
--    cancel_steer  : 未配達ファイルを消して steer_cancelled。hook が取った後なら何もしない
--    sweep_steers  : 宛先が終わった未配達を steer_expired にしてファイルを消す。印（steer.pending）の掃除
--    mark_steer_sent : 端末へ送った（steer_delivered via terminal）
--    collector との往復：Neovim が書いたファイルを bin/agentmap-collect --steer が配達し、provider が DELIVERED にする
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

t.done()
