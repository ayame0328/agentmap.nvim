-- ============================================================
--  test_reducer.lua … 記録 → 状態 の計算（state.lua / providers/claude.lua / events.lua / review.lua）
--  実行: nvim --headless -u NONE -l tests/test_reducer.lua
--  本物の保存先には書かない（AGENTMAP_DIR を一時フォルダにする）
-- ============================================================
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$")
local cfg = vim.fn.fnamemodify(here .. "/..", ":p"):gsub("/$", "")
package.path = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;" .. package.path
vim.opt.rtp:prepend(cfg)

local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")
vim.env.AGENTMAP_DIR = TMP .. "/store"

local fails, passes = 0, 0
local function ok(c, msg)
  if c then
    passes = passes + 1
    print("  ok   " .. msg)
  else
    fails = fails + 1
    print("  FAIL " .. msg)
  end
end
local function eq(a, b, msg) ok(a == b, msg .. (a == b and "" or ("  (got " .. vim.inspect(a) .. ", want " .. vim.inspect(b) .. ")"))) end

local util = require("agentmap.util")
local state = require("agentmap.state")
local claude = require("agentmap.providers.claude")
require("agentmap.config").setup({})

local FIX = here .. "/fixtures/hooks_probe.jsonl"
local SID = "c0ffee01-0000-4000-8000-000000000001"
local CHILD, GRAND = "afeed000000000006", "afeed000000000007"

local function load_hooks(filter)
  local recs = util.json_lines(FIX, 0)
  local evs = {}
  for _, r in ipairs(recs) do
    if not filter or filter(r) then vim.list_extend(evs, claude.normalize_hook(r)) end
  end
  return evs, recs
end

-- ---------- 1) 本物の記録で親子が正しくつながる ----------
print("[1] probe run: exact parent/child")
local evs, recs = load_hooks()
eq(#recs, 14, "fixture has 14 hook records")
local s = state.reduce(evs)
eq(s.run_id, SID, "run_id = session_id")
local c, g = s.agents[CHILD], s.agents[GRAND]
ok(c and g, "child and grandchild exist")
eq(c.parent_id, "ROOT", "child parent = ROOT")
eq(g.parent_id, CHILD, "grandchild parent = child")
eq(c.index, 1, "child index [1]")
eq(g.index, 2, "grandchild index [2]")
eq(c.status, "DONE", "child DONE")
eq(g.status, "DONE", "grandchild DONE")
eq(s.agents.ROOT.status, "DONE", "ROOT DONE after SessionEnd")
eq(c.model, "claude-haiku-4-5-20251001", "child model from resolvedModel")
eq(claude.model_short(c.model), "haiku-4-5", "model_short")
eq(g.last_head, "GRAND", "grandchild last_head")
eq(c.task, "probe child", "child task")
ok(s.agents["pending:toolu_test0000000000000004"] == nil, "placeholder merged away")
eq(#s.agents.ROOT.children, 1, "ROOT has 1 child")
eq(s.title and s.title:sub(1, 20), "Use the Agent tool e", "title from first prompt (not task-notification)")
eq(s.agents.ROOT.last_head, "PARENT-DONE", "ROOT last_head from Stop")
eq(s.counts.agents, 2, "counts.agents = 2")
eq(s.counts.unknown_parent, 0, "no unknown parent")
ok(c.elapsed_ms and c.elapsed_ms > 0, "child elapsed_ms computed")
eq(#state.visible_tree(s, "ROOT", {}), 3, "visible_tree has 3 rows")
eq(state.visible_tree(s, "ROOT", { [CHILD] = true })[2].collapsed_count, 1, "collapsed child hides 1")
eq(state.parent_chain(s, GRAND)[1], CHILD, "parent_chain")
eq(state.by_index(s, 2).id, GRAND, "by_index")
eq(state.status_tag(g), "[DONE]", "status_tag")
eq(state.progress(s, GRAND), nil, "no progress for leaf")
eq(state.progress(s, "ROOT").pct, 100, "ROOT progress 1/1 = 100")

-- ---------- 2) 順番が入れ替わっても同じ結果 ----------
print("[2] out-of-order: link before start, finish before start")
local rev = {}
for i = #evs, 1, -1 do rev[#rev + 1] = evs[i] end
local s2 = state.new(SID)
for _, ev in ipairs(rev) do state.apply(s2, ev) end
eq(s2.agents[GRAND].parent_id, CHILD, "reversed: grandchild parent still exact")
eq(s2.agents[CHILD].parent_id, "ROOT", "reversed: child parent still ROOT")
eq(#s2.agents[CHILD].attempts, 1, "reversed: start after finish is not a rework")
ok(s2.agents[CHILD].started_at ~= nil, "reversed: started_at filled later")
local only = state.new(SID)
state.apply(only, { event = "agent_linked", ts = "2026-01-01T00:00:01Z", agent_id = "x1", parent_id = "ROOT", source = "post_tool_use" })
eq(only.agents.x1.status, "PENDING", "link before start -> PENDING")
state.apply(only, { event = "agent_started", ts = "2026-01-01T00:00:02Z", agent_id = "x1" })
eq(only.agents.x1.status, "RUNNING", "then start -> RUNNING")
eq(only.agents.x1.parent_id, "ROOT", "parent kept")

-- ---------- 3) つながりの記録が無ければ UNKNOWN_PARENT（推測しない） ----------
print("[3] UNKNOWN_PARENT when link records are missing")
local evs3 = load_hooks(function(r)
  return not (r.hook_event_name == "PostToolUse" and r.agent_id == CHILD)
end)
for _, ev in ipairs(evs3) do
  if ev.event == "agent_started" and ev.agent_id == GRAND then
    ev.meta_tool_use_id, ev.meta_parent_id = nil, nil
  end
end
local s3 = state.reduce(evs3)
eq(s3.agents[GRAND].parent_id, nil, "grandchild parent unknown")
eq(s3.counts.unknown_parent, 1, "counts.unknown_parent = 1")
eq(state.roots(s3)[2], "UNKNOWN_PARENT", "roots include UNKNOWN_PARENT")
eq(state.children(s3, "UNKNOWN_PARENT")[1], GRAND, "grandchild listed under UNKNOWN_PARENT")
local ph = s3.agents["pending:toolu_test0000000000000005"]
ok(ph and ph.status == "FAILED" and ph.error_head == "no spawn record", "unlinked placeholder -> FAILED no spawn record at run end")
-- 後からつながりが届けば移る
state.apply(s3, { event = "agent_linked", ts = "2026-09-27T19:30:00Z", agent_id = GRAND, parent_id = CHILD,
  source = "meta", tool_use_id = "toolu_test0000000000000005" })
eq(s3.agents[GRAND].parent_id, CHILD, "late link moves grandchild under child")
eq(s3.counts.unknown_parent, 0, "UNKNOWN_PARENT empty again")
ok(s3.agents["pending:toolu_test0000000000000005"] == nil, "placeholder merged by tool_use_id")
eq(s3.agents[GRAND].index, 2, "grandchild keeps placeholder index")

-- ---------- 4) 進み具合 1/2 → ~50% ----------
print("[4] progress")
local p = state.new("p")
local T = function(n) return string.format("2026-01-01T00:00:%02dZ", n) end
state.apply(p, { event = "run_started", ts = T(0), cwd = "/w" })
for i, id in ipairs({ "a", "b" }) do
  state.apply(p, { event = "agent_spawn_requested", ts = T(i), tool_use_id = "t" .. id, parent_id = "ROOT", task = id })
  state.apply(p, { event = "agent_started", ts = T(i + 2), agent_id = id, meta_tool_use_id = "t" .. id })
end
state.apply(p, { event = "agent_finished", ts = T(9), agent_id = "a" })
local pr = state.progress(p, "ROOT")
eq(pr.done, 1, "done = 1")
eq(pr.total, 2, "total = 2")
eq(pr.pct, 50, "pct = 50 (~50%)")
eq(p.agents.a.parent_id, "ROOT", "meta tool_use_id links to spawn request parent")
eq(p.agents.a.link_source, "meta", "linked via meta toolUseId")

-- ---------- 5) 差し戻し（RETRY）と再実行で履歴が残る ----------
print("[5] review: submit -> RETRY -> rework -> PASS keeps attempts")
local evs5 = load_hooks()
for _, ev in ipairs(util.json_lines(here .. "/fixtures/events_review.jsonl", 0)) do
  ev._fo = 1
  evs5[#evs5 + 1] = ev
end
local s5 = state.reduce(evs5)
local g5 = s5.agents[GRAND]
eq(#g5.attempts, 2, "2 attempts")
eq(g5.attempts[1].verdict, "RETRY", "attempt 1 RETRY kept")
eq(g5.attempts[1].reason, "根拠が無い", "attempt 1 reason kept")
eq(g5.attempts[2].verdict, "PASS", "attempt 2 PASS")
eq(g5.status, "DONE", "status DONE after PASS")
eq(g5.review_count, 2, "review_count 2 (explicit + implicit submission)")
eq(g5.rework_count, 1, "rework_count 1")
local evs5b = load_hooks()
local rv = util.json_lines(here .. "/fixtures/events_review.jsonl", 0)
evs5b[#evs5b + 1] = rv[1]
evs5b[#evs5b + 1] = rv[2]
local s5b = state.reduce(evs5b)
eq(s5b.agents[GRAND].status, "REWORK", "after RETRY only -> REWORK")
-- ESCALATE
state.apply(s5, { event = "review_result", ts = "2026-09-27T19:25:00Z", agent_id = CHILD, verdict = "ESCALATE", decided_by = "user" })
eq(s5.agents[CHILD].status, "REVIEW", "ESCALATE -> REVIEW")
eq(s5.agents[CHILD].escalated_to, "ROOT", "escalated_to defaults to parent")
-- 別の Agent がやり直し
state.apply(s5, { event = "agent_started", ts = "2026-09-27T19:26:00Z", agent_id = "new1" })
state.apply(s5, { event = "rework_started", ts = "2026-09-27T19:26:01Z", agent_id = "new1", retry_of = CHILD, trigger = "user" })
local lastc = s5.agents[CHILD].attempts[#s5.agents[CHILD].attempts]
eq(lastc.retried_by, "new1", "retry_of marks retried_by on the old agent")
-- 差し戻し後にまた動いた（ツール記録）→ 新しい回
local s6 = state.reduce(evs5)
state.apply(s6, { event = "review_result", ts = "2026-09-27T19:27:00Z", agent_id = CHILD, verdict = "RETRY", decided_by = "user" })
state.apply(s6, { event = "tool_used", ts = "2026-09-27T19:28:00Z", agent_id = CHILD, tool_name = "Edit", target = "/w/x.lua" })
eq(s6.agents[CHILD].status, "RUNNING", "activity after RETRY -> RUNNING")
eq(#s6.agents[CHILD].attempts, 2, "activity opened attempt 2")
eq(s6.agents[CHILD].files[1], "/w/x.lua", "edited file recorded")
eq(s6.agents[CHILD].attempts[1].verdict, "RETRY", "attempt 1 verdict not overwritten")

-- ---------- 6) セッションが終わったら動いていた Agent は FAILED ----------
print("[6] run_ended marks RUNNING as FAILED")
local s7 = state.reduce(load_hooks(function(r)
  return not (r.hook_event_name == "SubagentStop" and r.agent_id == GRAND)
end))
eq(s7.agents[GRAND].status, "FAILED", "grandchild without SubagentStop -> FAILED")
eq(s7.agents[GRAND].error_head, "session ended", "error_head = session ended")
eq(s7.agents[CHILD].status, "DONE", "finished child stays DONE")

-- ---------- 7) 同期 Agent：完了が二重に届いても 1 回 ----------
print("[7] sync agent double finish is a no-op")
local s8 = state.new("s")
state.apply(s8, { event = "agent_started", ts = T(1), agent_id = "y" })
state.apply(s8, { event = "agent_finished", ts = T(3), agent_id = "y", last_head = "done" })
for _, ev in ipairs(claude.normalize_hook({ hook_event_name = "PostToolUse", session_id = "s", tool_name = "Agent",
  tool_use_id = "tu", _ts = T(4), duration_ms = 3000,
  tool_response = { agentId = "y", status = "completed", resolvedModel = "claude-opus-5-5" } })) do
  state.apply(s8, ev)
end
eq(#s8.agents.y.attempts, 1, "still 1 attempt")
eq(s8.agents.y.status, "DONE", "DONE")
eq(s8.agents.y.model, "claude-opus-5-5", "model filled from resolvedModel")

-- ---------- 8) events.lua：読み込み・控え・追いつき・レビュー記録 ----------
print("[8] events.load / poll / emit / review.record (temp store)")
local events = require("agentmap.events")
local store = require("agentmap.store")
local review = require("agentmap.review")
local slug = "-tmp-demo"
local dir = store.ensure(store.run_dir(slug, SID))
local lines = vim.fn.readfile(FIX)
vim.fn.writefile(vim.list_slice(lines, 1, 8), dir .. "/hooks.jsonl")
local run = events.load(dir)
eq(run.sid, SID, "run.sid")
eq(run.slug, slug, "run.slug")
eq(run.source, "hooks", "source hooks")
eq(run.state.agents[CHILD].status, "RUNNING", "child RUNNING mid-run")
ok(vim.uv.fs_stat(dir .. "/state.json") ~= nil, "state.json written")
local run_b = events.load(dir)
eq(run_b.state.agents[GRAND].parent_id, CHILD, "cached state.json loads identically")
vim.fn.writefile(vim.list_slice(lines, 9, 14), dir .. "/hooks.jsonl", "a")
eq(events.poll(run), true, "poll sees appended lines")
eq(run.state.agents[CHILD].status, "DONE", "child DONE after poll")
eq(run.state.agents.ROOT.status, "DONE", "ROOT DONE after poll")
eq(events.poll(run), false, "poll without change -> false")
review.submit(run, GRAND, "見てください")
eq(run.state.agents[GRAND].status, "REVIEW", "submit -> REVIEW")
review.record(run, GRAND, "retry", "根拠なし", "user")
eq(run.state.agents[GRAND].status, "REWORK", "record RETRY -> REWORK")
eq(events.poll(run), false, "emitted events not re-applied by poll")
local fresh = events.load(dir)
eq(fresh.state.agents[GRAND].status, "REWORK", "reload from files gives same status")
local log = util.json_lines(vim.env.AGENTMAP_DIR .. "/review_log.jsonl", 0)
eq(#log, 1, "review_log.jsonl has 1 line")
eq(log[1].final, "RETRY", "log final")
eq(log[1].provider, "manual", "log provider manual")
eq(log[1].rubric_version, 1, "log rubric_version")
ok(review.rubric_text():find("# Review rubric", 1, true) ~= nil, "rubric_text reads <plugin>/rubric/RUBRIC.md")
eq(review.rubric_version(), 1, "bundled rubric is version 1")
do -- setup({ review = { rubric = path } }) の RUBRIC.md を読む
  local p = vim.fn.tempname() .. "-RUBRIC.md"
  vim.fn.writefile({ "# My rubric", "version: 7" }, p)
  local config = require("agentmap.config")
  config.setup({ review = { rubric = p } })
  ok(review.rubric_text():find("# My rubric", 1, true) ~= nil, "rubric_text reads review.rubric")
  eq(review.rubric_version(), 7, "custom rubric version")
  config.setup({})
  os.remove(p)
end
local bad = review.record(run, GRAND, "MAYBE", nil, "user")
eq(bad, nil, "invalid verdict rejected")
eq(require("agentmap.store").project_for_cwd("/tmp/demo"), slug, "project_for_cwd by slug")
local cur = events.current_run("/tmp/demo")
eq(cur and cur.sid, SID, "current_run finds newest run")

-- ---------- 9) 小道具 ----------
print("[9] util")
eq(util.fit("abc", 5), "abc  ", "fit pads")
eq(util.dw(util.fit("日本語のテキスト", 7)), 7, "fit Japanese to exact width")
eq(util.fmt_elapsed(65000), "1:05", "fmt_elapsed")
eq(util.parse_iso("1970-01-01T00:01:00.500Z"), 60.5, "parse_iso")
eq(util.slug("/tmp/a.b"), "-tmp-a-b", "slug")
do
  local real = util.is_wsl
  util.is_wsl = function() return true end
  eq(util.win_path("/mnt/c/Users/x"), "C:\\Users\\x", "win_path /mnt/c")
  util.is_wsl = function() return false end
  eq(util.win_path("/mnt/d/data"), nil, "win_path outside WSL: nil (plain Linux /mnt/d is not a Windows drive)")
  eq(util.win_path("/mnt/d/data", true), "D:\\data", "win_path force: converts even outside WSL")
  util.is_wsl = real
end

-- ---------- 10) 手順表（tasks / steps）と進み具合の事実（DESIGN-v0.2 §2.2） ----------
print("[10] tasks / steps / progress_facts")
do
  local P1, P2 = "p1000000-0000-4000-8000-000000000001", "p2000000-0000-4000-8000-000000000002"
  local function E(event, ts, f)
    local e = { v = 1, event = event, ts = "2026-10-04T09:" .. ts .. ".000Z", src = "hook" }
    for k, v in pairs(f or {}) do e[k] = v end
    return e
  end
  -- 実物の hooks（2.1.288 の手順表の session）から
  local trecs = util.json_lines(here .. "/fixtures/hooks_tasks.jsonl", 0)
  eq(#trecs, 11, "hooks_tasks fixture has 11 records")
  local tevs = {}
  for _, r in ipairs(trecs) do vim.list_extend(tevs, claude.normalize_hook(r)) end
  local nc, nu, nl = 0, 0, 0
  for _, e in ipairs(tevs) do
    if e.event == "task_created" then nc = nc + 1 end
    if e.event == "task_updated" then nu = nu + 1 end
    if e.event == "task_listed" then nl = nl + 1 end
  end
  eq(nc, 2, "normalize: 2 task_created")
  eq(nu, 3, "normalize: 3 task_updated (the description-only TaskUpdate adds nothing)")
  eq(nl, 1, "normalize: 1 task_listed")
  local ts = state.reduce(tevs)
  local T = ts.agents.ROOT.tasks
  ok(T ~= nil, "ROOT has tasks")
  eq(T and table.concat(T.order, ","), "1,2", "tasks order")
  eq(T and T.items["1"].status, "completed", "task 1 completed")
  eq(T and T.items["1"].active_form, "Doing alpha", "task 1 active_form")
  eq(T and T.items["1"].started_at, "2026-10-04T09:00:05.000Z", "task 1 started_at = in_progress time")
  eq(T and T.items["1"].done_at, "2026-10-04T09:00:20.000Z", "task 1 done_at")
  eq(T and T.items["2"].status, "in_progress", "task 2 in_progress")
  eq((ts.agents.ROOT.tool_counts or {}).TaskCreate, 2, "Task tools also count as tool_used")
  local pf = state.progress_facts(ts, "ROOT")
  eq(pf and pf.source, "tasks", "facts: source tasks")
  eq(pf and pf.n, 2, "facts: n = 2")
  eq(pf and pf.k, 1, "facts: k = 1")
  eq(pf and pf.cur and pf.cur.started_at, "2026-10-04T09:00:21.000Z", "facts: cur.started_at = in_progress time of task 2")
  eq(pf and pf.cur and pf.cur.text, "beta", "facts: cur.text = subject (no activeForm)")
  eq(pf and pf.all_done_at, nil, "facts: not all done")

  -- 手で作った記録
  local s = state.new("r10")
  local A = "afeed100000000001"
  state.apply(s, E("run_prompt", "00:00", { prompt_id = P1, prompt_head = "first" }))
  state.apply(s, E("task_created", "00:01", { agent_id = nil, task_id = "1", subject = "alpha", prompt_id = P1 }))
  eq(s.agents.ROOT.tasks.items["1"].status, "pending", "task_created → pending")
  eq(s.agents.ROOT.tasks.items["1"].created_at, "2026-10-04T09:00:01.000Z", "task_created → created_at")
  state.apply(s, E("task_updated", "00:02", { task_id = "1", status_from = "pending", status_to = "in_progress", prompt_id = P1 }))
  eq(s.agents.ROOT.tasks.items["1"].started_at, "2026-10-04T09:00:02.000Z", "in_progress → started_at")
  state.apply(s, E("task_updated", "00:09", { task_id = "1", status_from = "in_progress", status_to = "completed", prompt_id = P1 }))
  eq(s.agents.ROOT.tasks.items["1"].done_at, "2026-10-04T09:00:09.000Z", "completed → done_at")
  state.apply(s, E("task_listed", "00:10", { prompt_id = P1, tasks = { { id = "1", subject = "alpha", status = "completed" },
    { id = "7", subject = "seen only in the list", status = "pending" } } }))
  eq(table.concat(s.agents.ROOT.tasks.order, ","), "1,7", "task_listed: unknown id appended to order")
  eq(s.agents.ROOT.tasks.items["7"].subject, "seen only in the list", "task_listed: subject filled")
  state.apply(s, E("task_updated", "00:11", { task_id = "9", status_to = "in_progress", prompt_id = P1 }))
  eq(s.agents.ROOT.tasks.items["9"] and s.agents.ROOT.tasks.items["9"].status, "in_progress", "task_updated for an unknown id creates it")
  -- 2 つ目の流れ（同じセッションで id は通し番号）
  state.apply(s, E("run_prompt", "01:00", { prompt_id = P2, prompt_head = "second" }))
  state.apply(s, E("agent_spawn_requested", "01:01", { tool_use_id = "tu1", parent_id = "ROOT", task = "child", prompt_id = P2 }))
  state.apply(s, E("agent_started", "01:02", { agent_id = A, meta_tool_use_id = "tu1", prompt_id = P2 }))
  state.apply(s, E("task_created", "01:03", { task_id = "10", subject = "second flow", prompt_id = P2 }))
  local v1, v2 = state.flow_view(s, P1), state.flow_view(s, P2)
  eq(v1 and v1.agents.ROOT.tasks and table.concat(v1.agents.ROOT.tasks.order, ","), "1,7,9", "flow_view: ROOT tasks of flow 1 only")
  eq(v2 and v2.agents.ROOT.tasks and table.concat(v2.agents.ROOT.tasks.order, ","), "10", "flow_view: ROOT tasks of flow 2 only")
  eq(#s.agents.ROOT.tasks.order, 4, "flow_view does not change the original")

  -- 目印（## Steps）：丸ごと置き換え
  local steps = { source = "transcript", listed_at = "2026-10-04T09:01:05.000Z", items = {
    { n = 1, text = "read", done_at = "2026-10-04T09:01:30.000Z" },
    { n = 2, text = "write" },
    { n = 3, text = "test" } } }
  state.apply(s, E("steps_updated", "01:31", { agent_id = A, steps = steps, src = "system" }))
  eq(s.agents[A].steps and #s.agents[A].steps.items, 3, "steps_updated sets a.steps")
  local f2 = state.progress_facts(s, A)
  eq(f2 and f2.source, "steps", "facts: source steps")
  eq(f2 and f2.n .. "/" .. f2.k, "3/1", "facts: 1 of 3 done")
  eq(f2 and f2.cur and f2.cur.started_at, "2026-10-04T09:01:30.000Z", "facts: cur.started_at = previous done mark")
  eq(f2 and f2.cur and f2.cur.text, "write", "facts: cur.text")
  state.apply(s, E("steps_updated", "01:40", { agent_id = A, src = "system", steps = { source = "transcript",
    listed_at = "2026-10-04T09:01:39.000Z", items = { { n = 1, text = "only", started_at = "2026-10-04T09:01:39.500Z" } } } }))
  eq(#s.agents[A].steps.items, 1, "steps_updated replaces the whole list")
  eq(state.progress_facts(s, A).cur.started_at, "2026-10-04T09:01:39.500Z", "facts: an explicit start mark wins")
  state.apply(s, E("steps_updated", "01:41", { agent_id = A, src = "system", steps = { source = "transcript",
    listed_at = "2026-10-04T09:01:39.000Z", items = { { n = 1, text = "only" } } } }))
  eq(state.progress_facts(s, A).cur.started_at, "2026-10-04T09:01:39.000Z", "facts: no mark → listed_at")
  state.apply(s, E("steps_updated", "01:50", { agent_id = A, src = "system", steps = { source = "transcript",
    listed_at = "2026-10-04T09:01:39.000Z", items = { { n = 1, text = "only", done_at = "2026-10-04T09:01:49.000Z" } } } }))
  local f3 = state.progress_facts(s, A)
  eq(f3.k == f3.n and f3.all_done_at, "2026-10-04T09:01:49.000Z", "facts: all_done_at when k == n")
  eq(f3.cur, nil, "facts: no running step when all are done")
  -- tasks が steps に勝つ
  state.apply(s, E("task_created", "01:51", { agent_id = A, task_id = "1", subject = "via tool", prompt_id = P2 }))
  eq(state.progress_facts(s, A).source, "tasks", "facts: tasks win over steps")
  eq(state.progress_facts(s, A).cur.started_at, "2026-10-04T09:01:51.000Z", "facts: no in_progress → first open task, from created_at")
  eq(state.progress_facts(s, "nobody"), nil, "facts: unknown id → nil")
  eq(state.progress_facts(state.new("x"), "ROOT"), nil, "facts: no step list → nil")
  -- ROOT の目印は、一覧を書いた時刻の流れにだけ出る
  state.apply(s, E("steps_updated", "01:52", { agent_id = "ROOT", src = "system", steps = { source = "transcript",
    listed_at = "2026-10-04T09:00:30.000Z", items = { { n = 1, text = "root step" } } } }))
  ok(state.flow_view(s, P1).agents.ROOT.steps ~= nil, "flow_view: ROOT steps listed in flow 1 shown in flow 1")
  eq(state.flow_view(s, P2).agents.ROOT.steps, nil, "flow_view: … and not in flow 2")
  eq(state.SV, 9, "SV = 9")
end

-- ---------- 11) 修正指示（steer。DESIGN-v0.2-steer §5.2） ----------
print("[11] steers")
do
  local P1, P2 = "p1100000-0000-4000-8000-000000000001", "p1200000-0000-4000-8000-000000000002"
  local A, B = "afeed110000000001", "afeed110000000002"
  local function E(event, ts, f)
    local e = { v = 1, event = event, ts = "2026-10-04T10:" .. ts .. ".000Z", src = "user" }
    for k, v in pairs(f or {}) do e[k] = v end
    return e
  end
  local s = state.new("r11")
  state.apply(s, E("run_prompt", "00:00", { prompt_id = P1, prompt_head = "first", src = "hook" }))
  state.apply(s, E("agent_spawn_requested", "00:01", { tool_use_id = "tA", parent_id = "ROOT", task = "child A", prompt_id = P1, src = "hook" }))
  state.apply(s, E("agent_started", "00:02", { agent_id = A, meta_tool_use_id = "tA", prompt_id = P1, src = "hook" }))
  state.apply(s, E("steer_requested", "00:10", { steer_id = A .. "-1", agent_id = A, text = "use v3", via = "hook", prompt_id = P1, kind = "steer" }))
  local st = s.steers[A .. "-1"]
  eq(st and st.status, "PENDING", "steer_requested → PENDING")
  eq(s.agents[A].steers and s.agents[A].steers[1], A .. "-1", "a.steers has the id")
  eq(s.counts.steers .. "/" .. s.counts.steers_pending, "1/1", "counts.steers / steers_pending")
  eq(state.pending_steers(s, A), 1, "pending_steers = 1")
  -- hook の配達（provider の形から）
  local dev = claude.normalize_hook({ session_id = "r11", hook_event_name = "PreToolUse", tool_name = "Write", tool_use_id = "tw",
    agent_id = A, prompt_id = P1, steer = { ids = { A .. "-1" }, mode = "deny", target = A }, _ts = "2026-10-04T10:00:20.000Z" })
  eq(#dev, 1, "steer line → 1 event")
  eq(dev[1].event, "steer_delivered", "steer line → steer_delivered")
  for _, e in ipairs(dev) do state.apply(s, e) end
  eq(st.status, "DELIVERED", "steer_delivered → DELIVERED")
  eq(st.delivered_via, "PreToolUse:Write", "delivered_via = PreToolUse:Write")
  eq(st.delivered_at, "2026-10-04T10:00:20.000Z", "delivered_at")
  eq(st.tool_use_id, "tw", "tool_use_id")
  state.apply(s, E("steer_cancelled", "00:21", { steer_id = A .. "-1" }))
  eq(st.status, "DELIVERED", "cancel after delivery is ignored")
  state.apply(s, E("steer_expired", "00:22", { steer_id = A .. "-1", reason = "agent_finished" }))
  eq(st.status, "DELIVERED", "expire after delivery is ignored")
  -- 取り消し・期限切れ
  state.apply(s, E("steer_requested", "00:30", { steer_id = A .. "-2", agent_id = A, text = "x", via = "hook", prompt_id = P1 }))
  state.apply(s, E("steer_cancelled", "00:31", { steer_id = A .. "-2" }))
  eq(s.steers[A .. "-2"].status, "CANCELLED", "steer_cancelled → CANCELLED")
  eq(s.steers[A .. "-2"].ended_at, "2026-10-04T10:00:31.000Z", "cancel ended_at")
  state.apply(s, E("steer_requested", "00:40", { steer_id = A .. "-3", agent_id = A, text = "y", via = "hook", prompt_id = P1 }))
  state.apply(s, E("steer_expired", "00:41", { steer_id = A .. "-3", reason = "agent_finished" }))
  eq(s.steers[A .. "-3"].status, "EXPIRED", "steer_expired → EXPIRED")
  eq(s.steers[A .. "-3"].end_reason, "agent_finished", "end_reason")
  -- 配達の記録が先に届いた（hook が先）→ 作ってから、後の requested で本文が埋まる。取り消しより配達が勝つ
  state.apply(s, E("steer_delivered", "00:50", { steer_id = A .. "-4", agent_id = A, via = "SubagentStop", src = "hook" }))
  eq(s.steers[A .. "-4"].status, "DELIVERED", "delivered before requested: created as DELIVERED")
  state.apply(s, E("steer_requested", "00:49", { steer_id = A .. "-4", agent_id = A, text = "late", via = "hook", prompt_id = P1 }))
  eq(s.steers[A .. "-4"].text, "late", "requested after delivered fills the text")
  eq(s.steers[A .. "-4"].status, "DELIVERED", "… and keeps DELIVERED")
  state.apply(s, E("steer_requested", "00:55", { steer_id = A .. "-5", agent_id = A, text = "z", via = "hook", prompt_id = P1 }))
  state.apply(s, E("steer_cancelled", "00:56", { steer_id = A .. "-5" }))
  state.apply(s, E("steer_delivered", "00:57", { steer_id = A .. "-5", agent_id = A, via = "PreToolUse:Bash", src = "hook" }))
  eq(s.steers[A .. "-5"].status, "DELIVERED", "DELIVERED beats CANCELLED")
  eq(s.steers[A .. "-5"].ended_at, nil, "… and clears ended_at")
  eq(table.concat(state.steers_of(s, A), ","), table.concat({ A .. "-1", A .. "-2", A .. "-3", A .. "-4", A .. "-5" }, ","),
    "steers_of: in requested order")
  eq(s.steers[A .. "-4"].n, 4, "n: numbered by requested_at within the flow")
  -- 知らない宛先：s.steers にだけ置く
  state.apply(s, E("steer_requested", "00:58", { steer_id = "ghost-1", agent_id = "ghost", text = "?", via = "hook", prompt_id = P1 }))
  eq(s.agents.ghost, nil, "unknown target: no agent created")
  eq(state.steers_of(s, "ghost")[1], "ghost-1", "unknown target: steers_of still finds it")
  -- 端末へ送った ROOT 宛ての指示：送った → Claude Code が受け取った（同じ prompt_id の UserPromptSubmit）
  state.apply(s, E("steer_requested", "01:00", { steer_id = "ROOT-1", agent_id = "ROOT", text = "stop and summarize", via = "terminal", prompt_id = P1 }))
  state.apply(s, E("steer_delivered", "01:01", { steer_id = "ROOT-1", agent_id = "ROOT", via = "terminal" }))
  eq(s.steers["ROOT-1"].delivered_via, "terminal", "terminal: delivered_via = terminal (sent)")
  local nflows = #s.flows
  state.apply(s, E("run_prompt", "01:07", { prompt_id = P1, prompt_head = "[AgentMap] stop and   summarize", src = "hook" }))
  eq(s.steers["ROOT-1"].delivered_via, "UserPromptSubmit", "terminal: confirmed by the [AgentMap] prompt")
  eq(s.steers["ROOT-1"].confirmed_at, "2026-10-04T10:01:07.000Z", "terminal: confirmed_at")
  eq(#s.flows, nflows, "[AgentMap] prompt in the same turn: no new flow")
  -- 止まっている ROOT への やり直し依頼：新しい prompt_id でも前の流れの続き
  state.apply(s, E("turn_ended", "01:10", { prompt_id = P1, src = "hook" }))
  state.apply(s, E("steer_requested", "01:20", { steer_id = "ROOT-2", agent_id = "ROOT", text = "add tests", via = "terminal",
    kind = "redo", redo_of = A, prompt_id = P1 }))
  state.apply(s, E("steer_delivered", "01:21", { steer_id = "ROOT-2", agent_id = "ROOT", via = "terminal" }))
  state.apply(s, E("run_prompt", "01:22", { prompt_id = P2, prompt_head = "[AgentMap] Please redo agent [1] \"child A\" (id x, finished 10:00): add tests. Use the same delegation; report what changed.", src = "hook" }))
  eq(#s.flows, nflows, "[AgentMap] prompt with a new prompt_id: no new flow")
  eq(s.prompt_alias[P2], P1, "… it is aliased to the previous flow")
  eq(s.steers["ROOT-2"].delivered_via, "UserPromptSubmit", "redo text contains the body → confirmed")
  state.apply(s, E("agent_spawn_requested", "01:23", { tool_use_id = "tB", parent_id = "ROOT", task = "child A again", prompt_id = P2, src = "hook" }))
  state.apply(s, E("agent_started", "01:24", { agent_id = B, meta_tool_use_id = "tB", prompt_id = P2, src = "hook" }))
  eq(s.agents[B].prompt_id, P1, "the redo agent joins the previous flow")
  -- 一致しない [AgentMap] の指示は何も付けない
  state.apply(s, E("steer_requested", "01:30", { steer_id = "ROOT-3", agent_id = "ROOT", text = "something else", via = "terminal", prompt_id = P1 }))
  state.apply(s, E("steer_delivered", "01:31", { steer_id = "ROOT-3", agent_id = "ROOT", via = "terminal" }))
  state.apply(s, E("run_prompt", "01:32", { prompt_id = P1, prompt_head = "[AgentMap] unrelated", src = "hook" }))
  eq(s.steers["ROOT-3"].delivered_via, "terminal", "no match → not confirmed (no guessing)")
  -- 流れごとの写し
  local P3 = "p1300000-0000-4000-8000-000000000003"
  state.apply(s, E("run_prompt", "02:00", { prompt_id = P3, prompt_head = "third", src = "hook" }))
  state.apply(s, E("steer_requested", "02:01", { steer_id = A .. "-9", agent_id = A, text = "A is outside flow 3", via = "hook", prompt_id = P3 }))
  local v1, v3 = state.flow_view(s, P1), state.flow_view(s, P3)
  ok(v1.steers[A .. "-1"] ~= nil and v1.steers[A .. "-9"] == nil, "flow_view: only the steers of the flow")
  eq(v3.steer_order[1], A .. "-9", "flow_view: flow 3 has its steer")
  eq(v3.steers[A .. "-9"].owner_id, "ROOT", "flow_view: target outside the flow → shown on ROOT")
  eq(state.steers_of(v3, "ROOT")[1], A .. "-9", "steers_of on the view follows owner_id")
  eq(v1.counts.steers, #v1.steer_order, "flow_view: counts per flow")
  eq(s.steers[A .. "-9"].owner_id, nil, "flow_view does not change the original")
end

vim.fn.delete(TMP, "rf")
print(string.format("%d passed, %d failed", passes, fails))
print(fails == 0 and "PASS test_reducer.lua" or "FAIL test_reducer.lua")
if fails > 0 then os.exit(1) end
