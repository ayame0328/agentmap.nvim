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
  eq(state.SV, 12, "SV = 12")
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

-- ---------- 12) 終わりで止めて届けた（block）：その終わりは取り消す ----------
print("[12] steer at stop (block) reopens")
do
  local P1 = "p2100000-0000-4000-8000-000000000001"
  local C = "afeed120000000001"
  local function H(ev, ts, f)
    local r = { session_id = "r12", hook_event_name = ev, prompt_id = P1, _ts = "2026-10-04T11:" .. ts .. ".000Z" }
    for k, v in pairs(f or {}) do r[k] = v end
    return r
  end
  local s = state.new("r12")
  local function feed(rec) for _, e in ipairs(claude.normalize_hook(rec)) do state.apply(s, e) end end
  feed(H("UserPromptSubmit", "00:00", { prompt_head = "go" }))
  feed(H("PreToolUse", "00:01", { tool_name = "Agent", tool_use_id = "tC", tool_input = { description = "child" } }))
  feed(H("SubagentStart", "00:02", { agent_id = C, agent_type = "general-purpose" }))
  -- 1 回目の SubagentStop（記録）→ 同じ hook の配達の行（block）
  feed(H("SubagentStop", "00:10", { agent_id = C, last_head = "first end" }))
  eq(s.agents[C].status, "DONE", "first SubagentStop → DONE")
  feed(H("SubagentStop", "00:10", { agent_id = C, steer = { ids = { C .. "-1" }, mode = "block", target = C } }))
  eq(s.agents[C].status, "RUNNING", "blocked stop → back to RUNNING")
  eq(s.agents[C].finished_at, nil, "… finished_at cleared")
  feed(H("PostToolUse", "00:15", { agent_id = C, tool_name = "Write", tool_use_id = "tw", target = "c.txt" }))
  eq(#s.agents[C].attempts, 1, "work after the blocked stop is not a rework")
  feed(H("SubagentStop", "00:20", { agent_id = C, last_head = "real end" }))
  eq(s.agents[C].status, "DONE", "second SubagentStop → DONE")
  eq(s.agents[C].finished_at, "2026-10-04T11:00:20.000Z", "finished_at = the real end")
  eq(s.agents[C].last_head, "real end", "last_head = the real end")
  -- ROOT の Stop を止めた：その流れは終わっていない
  feed(H("Stop", "00:30", { last_head = "root first" }))
  eq(state.flow_of(s, P1).ended_at, "2026-10-04T11:00:30.000Z", "Stop → flow ended")
  feed(H("Stop", "00:30", { steer = { ids = { "ROOT-1" }, mode = "block", target = "ROOT" } }))
  eq(state.flow_of(s, P1).ended_at, nil, "blocked Stop → flow not ended")
  feed(H("Stop", "00:40", { last_head = "root end" }))
  eq(state.flow_of(s, P1).ended_at, "2026-10-04T11:00:40.000Z", "second Stop → flow ended")
end

-- ---------- 12b) 終わりで止めて届けたのに止められなかった（連続の上限）：親の記録で決着 ----------
print("[12b] blocked stop not held (cap): settled from the parent's records")
do
  local P1 = "p2150000-0000-4000-8000-000000000001"
  local C, D, E2, F, G, K = "afeed125000000001", "afeed125000000002", "afeed125000000003", "afeed125000000004",
    "afeed125000000005", "afeed125000000006"
  local function H(ev, ts, f)
    local r = { session_id = "r12b", hook_event_name = ev, prompt_id = P1, _ts = "2026-10-04T11:" .. ts .. ".000Z" }
    for k, v in pairs(f or {}) do r[k] = v end
    return r
  end
  local s = state.new("r12b")
  local function eq(a, b, msg)
    local same = vim.deep_equal(a, b)
    ok(same, msg .. (same and "" or ("  (got " .. vim.inspect(a) .. ", want " .. vim.inspect(b) .. ")")))
  end
  local function feed(rec) for _, e in ipairs(claude.normalize_hook(rec)) do state.apply(s, e) end end
  local function notice(id, ts) feed(H("UserPromptSubmit", ts, { kind = "task_notification",
    prompt_head = "<task-id>" .. id .. "</task-id> <status>completed</status>" })) end
  feed(H("UserPromptSubmit", "00:00", { prompt_head = "go" }))
  -- 背景の子 C：1 回目の終わり → block → 子の記録が無いまま親にお知らせ = 止められなかった
  feed(H("PreToolUse", "00:01", { tool_name = "Agent", tool_use_id = "tC", tool_input = { description = "child C" } }))
  feed(H("SubagentStart", "00:02", { agent_id = C, agent_type = "general-purpose" }))
  feed(H("SubagentStop", "00:10", { agent_id = C, last_head = "first end" }))
  feed(H("SubagentStop", "00:10", { agent_id = C, steer = { ids = { C .. "-1" }, mode = "block", target = C } }))
  eq(s.agents[C].status, "RUNNING", "C: blocked stop → RUNNING")
  eq(s.agents[C].end_held and s.agents[C].end_held.steer_id, C .. "-1", "C: end_held remembers the instruction")
  eq(s.steers[C .. "-1"].held, nil, "C: held unknown yet")
  notice(C, "00:11")
  eq(s.agents[C].status, "DONE", "C: the parent's notification with no work in between → DONE (not held)")
  eq(s.agents[C].finished_at, "2026-10-04T11:00:10.000Z", "C: finished_at = the first end")
  eq(s.agents[C].attempts[1].finished_at, "2026-10-04T11:00:10.000Z", "C: the attempt is closed at the first end")
  eq(s.steers[C .. "-1"].status, "DELIVERED", "C: the instruction stays DELIVERED (it was handed over)")
  eq(s.steers[C .. "-1"].held, false, "C: … but held = false")
  eq(s.agents[C].end_held, nil, "C: end_held cleared")
  eq(#s.agents[C].attempts, 1, "C: one attempt")
  eq(s.agents[C].elapsed_ms, 8000, "C: elapsed = start → first end")
  notice(C, "00:12")
  eq(s.agents[C].status .. "/" .. tostring(s.steers[C .. "-1"].held), "DONE/false", "C: a second notification changes nothing")
  -- 背景の子 D：block → 道具 → 2 回目の終わり → お知らせ = 止められた（お知らせは何もしない）
  feed(H("PreToolUse", "00:19", { tool_name = "Agent", tool_use_id = "tD", tool_input = { description = "child D" } }))
  feed(H("SubagentStart", "00:20", { agent_id = D, agent_type = "general-purpose" }))
  feed(H("SubagentStop", "00:30", { agent_id = D, last_head = "first end" }))
  feed(H("SubagentStop", "00:30", { agent_id = D, steer = { ids = { D .. "-1" }, mode = "block", target = D } }))
  feed(H("PostToolUse", "00:35", { agent_id = D, tool_name = "Write", tool_use_id = "tw", target = "c.txt" }))
  eq(s.steers[D .. "-1"].held, true, "D: a tool call after the hold → held = true")
  eq(s.agents[D].end_held, nil, "D: end_held cleared by the tool call")
  eq(s.agents[D].status, "RUNNING", "D: still running")
  feed(H("SubagentStop", "00:40", { agent_id = D, last_head = "real end" }))
  notice(D, "00:41")
  eq(s.agents[D].status, "DONE", "D: DONE")
  eq(s.agents[D].finished_at, "2026-10-04T11:00:40.000Z", "D: finished_at = the real end (the notification changes nothing)")
  eq(s.steers[D .. "-1"].held, true, "D: still held")
  -- 背景の子 E：block → 道具なしで 2 回目の終わり（子自身の SubagentStop）= 止められた
  feed(H("PreToolUse", "00:49", { tool_name = "Agent", tool_use_id = "tE", tool_input = { description = "child E" } }))
  feed(H("SubagentStart", "00:50", { agent_id = E2, agent_type = "general-purpose" }))
  feed(H("SubagentStop", "00:55", { agent_id = E2, last_head = "first end" }))
  feed(H("SubagentStop", "00:55", { agent_id = E2, steer = { ids = { E2 .. "-1" }, mode = "block", target = E2 } }))
  feed(H("SubagentStop", "00:58", { agent_id = E2, last_head = "second end" }))
  eq({ s.agents[E2].status, s.agents[E2].finished_at, s.steers[E2 .. "-1"].held, s.agents[E2].end_held },
    { "DONE", "2026-10-04T11:00:58.000Z", true, nil }, "E: its own second SubagentStop → held, finished at the second end")
  notice(E2, "00:59")
  eq(s.agents[E2].finished_at, "2026-10-04T11:00:58.000Z", "E: the notification changes nothing")
  -- 同期の子 F：block → 子の記録が無いまま親の PostToolUse(Agent) = 止められなかった
  feed(H("PreToolUse", "01:00", { tool_name = "Agent", tool_use_id = "tF", tool_input = { description = "sync child F" } }))
  feed(H("SubagentStart", "01:01", { agent_id = F, agent_type = "general-purpose" }))
  feed(H("SubagentStop", "01:10", { agent_id = F, last_head = "first end" }))
  feed(H("SubagentStop", "01:10", { agent_id = F, steer = { ids = { F .. "-1" }, mode = "block", target = F } }))
  eq(s.agents[F].status, "RUNNING", "F: blocked stop → RUNNING")
  feed(H("PostToolUse", "01:11", { tool_name = "Agent", tool_use_id = "tF", duration_ms = 10000,
    tool_input = { description = "sync child F" }, tool_response = { agentId = F, status = "completed" } }))
  eq({ s.agents[F].status, s.agents[F].finished_at, s.steers[F .. "-1"].held },
    { "DONE", "2026-10-04T11:01:10.000Z", false }, "F: the parent's return with no work in between → DONE, not held")
  -- 同期の子 G：block → 道具 → 2 回目の終わり → 親の PostToolUse(Agent) = 止められた
  feed(H("PreToolUse", "01:20", { tool_name = "Agent", tool_use_id = "tG", tool_input = { description = "sync child G" } }))
  feed(H("SubagentStart", "01:21", { agent_id = G, agent_type = "general-purpose" }))
  feed(H("SubagentStop", "01:30", { agent_id = G, last_head = "first end" }))
  feed(H("SubagentStop", "01:30", { agent_id = G, steer = { ids = { G .. "-1" }, mode = "block", target = G } }))
  feed(H("PostToolUse", "01:33", { agent_id = G, tool_name = "Edit", tool_use_id = "te", target = "g.txt" }))
  feed(H("SubagentStop", "01:36", { agent_id = G, last_head = "second end" }))
  feed(H("PostToolUse", "01:37", { tool_name = "Agent", tool_use_id = "tG", duration_ms = 16000,
    tool_input = { description = "sync child G" }, tool_response = { agentId = G, status = "completed" } }))
  eq({ s.agents[G].status, s.agents[G].finished_at, s.steers[G .. "-1"].held },
    { "DONE", "2026-10-04T11:01:36.000Z", true }, "G: held; finished at its own second end")
  -- 止めていない子 K へのお知らせは何もしない（記録の順が入れ替わっても DONE にしない）
  feed(H("PreToolUse", "01:40", { tool_name = "Agent", tool_use_id = "tK", tool_input = { description = "child K" } }))
  feed(H("SubagentStart", "01:41", { agent_id = K, agent_type = "general-purpose" }))
  notice(K, "01:42")
  eq(s.agents[K].status, "RUNNING", "K: a notification alone does not finish an agent")
  notice("afeed125000000099", "01:43")
  eq(s.agents["afeed125000000099"], nil, "unknown id: a notification creates no box")
  -- ROOT の Stop の block は判定しない（親の記録が無い）
  feed(H("Stop", "01:50", { last_head = "root first" }))
  feed(H("Stop", "01:50", { steer = { ids = { "ROOT-1" }, mode = "block", target = "ROOT" } }))
  eq(s.agents.ROOT.end_held, nil, "ROOT: no end_held (not judged)")
  eq(s.steers["ROOT-1"].held, nil, "ROOT: held stays unknown")
end

-- ---------- 13) 一時停止（pause。DESIGN-v0.1.2-pause §5.2） ----------
print("[13] pauses")
do
  local function eq(a, b, msg)
    local same = vim.deep_equal(a, b)
    ok(same, msg .. (same and "" or ("  (got " .. vim.inspect(a) .. ", want " .. vim.inspect(b) .. ")")))
  end
  local P1 = "p2200000-0000-4000-8000-000000000001"
  local P2 = "p2200000-0000-4000-8000-000000000002"
  local A, B = "afeed130000000001", "afeed130000000002"
  local function H(ev, ts, f)
    local r = { session_id = "r13", hook_event_name = ev, prompt_id = P1, _ts = "2026-10-05T12:" .. ts .. ".000Z" }
    for k, v in pairs(f or {}) do r[k] = v end
    return r
  end
  local function U(event, ts, f)
    local e = { v = 1, event = event, ts = "2026-10-05T12:" .. ts .. ".000Z", run_id = "r13", src = "user" }
    for k, v in pairs(f or {}) do e[k] = v end
    return e
  end
  local s = state.new("r13")
  local function feed(rec) for _, e in ipairs(claude.normalize_hook(rec)) do state.apply(s, e) end end
  feed(H("UserPromptSubmit", "00:00", { prompt_head = "go" }))
  feed(H("PreToolUse", "00:01", { tool_name = "Agent", tool_use_id = "tA", tool_input = { description = "a" } }))
  feed(H("SubagentStart", "00:02", { agent_id = A, agent_type = "general-purpose" }))
  feed(H("PreToolUse", "00:03", { tool_name = "Agent", tool_use_id = "tB", tool_input = { description = "b" } }))
  feed(H("SubagentStart", "00:04", { agent_id = B, agent_type = "general-purpose" }))
  eq(state.display_status(s, A), "RUNNING", "no pause: display_status = a.status")
  eq(state.paused_ms(s, A), 0, "no pause: paused_ms = 0")

  -- REQUESTED → PAUSED → RESUMED（指示つき）
  state.apply(s, U("pause_requested", "01:00", { pause_id = A .. "-1", agent_id = A, at = "next", kind = "pause", auto_resume_s = 600, prompt_id = P1 }))
  local p = s.pauses[A .. "-1"]
  eq(p and p.status, "REQUESTED", "pause_requested → REQUESTED")
  eq(s.agents[A].pause, A .. "-1", "a.pause = the live pause")
  eq(s.agents[A].pauses and s.agents[A].pauses[1], A .. "-1", "a.pauses has the id")
  eq(s.counts.pauses .. "/" .. s.counts.paused .. "/" .. s.counts.pause_requested, "1/0/1", "counts: pauses / paused / pause_requested")
  eq(state.display_status(s, A), "RUNNING", "REQUESTED: still RUNNING on the box")
  eq(state.pause_of(s, A) and state.pause_of(s, A).id, A .. "-1", "pause_of: the REQUESTED pause")
  feed(H("PreToolUse", "01:06", { agent_id = A, tool_name = "Read", tool_use_id = "tr1",
    pause = { id = A .. "-1", phase = "hit", kind = "pause", at = "next", target = A, deadline = "2026-10-05T12:11:06Z" } }))
  eq(p.status, "PAUSED", "pause_hit → PAUSED")
  eq({ p.hit_at, p.hit_via, p.tool_use_id, p.deadline }, { "2026-10-05T12:01:06.000Z", "PreToolUse:Read", "tr1", "2026-10-05T12:11:06Z" },
    "hit_at / hit_via / tool_use_id / deadline")
  eq(s.agents[A].status, "RUNNING", "a.status is not changed")
  eq(state.display_status(s, A), "PAUSED", "display_status = PAUSED")
  eq(#s.agents[A].tools, 0, "the pause line is not a tool use")
  eq(s.counts.paused, 1, "counts.paused = 1")
  eq(state.paused_ms(s, A, util.parse_iso("2026-10-05T12:01:16.000Z")), 10000, "paused_ms while PAUSED = now - hit_at")
  state.apply(s, U("steer_requested", "02:00", { steer_id = A .. "-9", agent_id = A, text = "use v3", via = "hook", prompt_id = P1 }))
  state.apply(s, U("pause_resumed", "02:00", { pause_id = A .. "-1", reason = "user", steer_id = A .. "-9" }))
  eq(p.status, "RESUMED", "pause_resumed → RESUMED")
  eq(p.release_reason, "user", "… reason user (Neovim)")
  eq(s.agents[A].pause, nil, "a.pause cleared")
  feed(H("PreToolUse", "02:00", { agent_id = A, tool_name = "Read", tool_use_id = "tr1",
    pause = { id = A .. "-1", phase = "released", target = A, reason = "user", waited_ms = 54000, steer_ids = { A .. "-9" } } }))
  eq({ p.status, p.release_reason, p.waited_ms, p.steer_id }, { "RESUMED", "user", 54000, A .. "-9" }, "pause_released after pause_resumed: waited_ms filled")
  eq(state.display_status(s, A), "RUNNING", "after resume: RUNNING again")
  eq(state.paused_ms(s, A, util.parse_iso("2026-10-05T12:30:00.000Z")), 54000, "paused_ms after resume = released_at - hit_at")

  -- pause_hit が先に来る（pause_requested の記録より前）→ 作って PAUSED。hook が自分で決めた理由（auto）は Neovim に勝つ
  feed(H("PreToolUse", "03:00", { agent_id = B, tool_name = "Bash", tool_use_id = "tb",
    pause = { id = B .. "-2", phase = "hit", kind = "pause", at = "next", target = B } }))
  local q = s.pauses[B .. "-2"]
  eq(q and q.status, "PAUSED", "pause_hit before pause_requested → created as PAUSED")
  state.apply(s, U("pause_requested", "03:00", { pause_id = B .. "-2", agent_id = B, at = "next", kind = "pause", auto_resume_s = 600 }))
  eq(q.status, "PAUSED", "late pause_requested keeps PAUSED")
  eq(q.requested_at, "2026-10-05T12:03:00.000Z", "… and fills requested_at")
  feed(H("PreToolUse", "13:00", { agent_id = B, tool_name = "Bash", tool_use_id = "tb",
    pause = { id = B .. "-2", phase = "released", target = B, reason = "auto", waited_ms = 600000 } }))
  state.apply(s, U("pause_resumed", "13:01", { pause_id = B .. "-2", reason = "nvim_exit" }))
  eq(q.release_reason, "auto", "hook's own reason (auto) wins over Neovim's")
  -- Neovim の具体的な理由（nvim_exit / gate_off）は、hook の「ファイルが消えた（user）」より残す
  state.apply(s, U("pause_requested", "14:00", { pause_id = B .. "-3", agent_id = B, at = "next", kind = "pause" }))
  feed(H("PreToolUse", "14:01", { agent_id = B, tool_name = "Bash", pause = { id = B .. "-3", phase = "hit", kind = "pause", at = "next", target = B } }))
  feed(H("PreToolUse", "14:05", { agent_id = B, tool_name = "Bash", pause = { id = B .. "-3", phase = "released", target = B, reason = "user", waited_ms = 4000 } }))
  state.apply(s, U("pause_resumed", "14:05", { pause_id = B .. "-3", reason = "nvim_exit" }))
  eq(s.pauses[B .. "-3"].release_reason, "nvim_exit", "Neovim's nvim_exit is kept over the hook's user")

  -- aborted → RESUMED（理由 aborted）
  state.apply(s, U("pause_requested", "15:00", { pause_id = B .. "-4", agent_id = B, at = "next", kind = "pause" }))
  feed(H("PreToolUse", "15:01", { agent_id = B, tool_name = "Bash", pause = { id = B .. "-4", phase = "hit", kind = "pause", at = "next", target = B } }))
  feed(H("PreToolUse", "15:21", { agent_id = B, tool_name = "Bash", pause = { id = B .. "-4", phase = "aborted", target = B, waited_ms = 20000 } }))
  eq({ s.pauses[B .. "-4"].status, s.pauses[B .. "-4"].release_reason, s.pauses[B .. "-4"].waited_ms }, { "RESUMED", "aborted", 20000 }, "pause_aborted → RESUMED, aborted")

  -- expired：REQUESTED から。RESUMED は EXPIRED に勝つ（解放が後から来ても RESUMED）
  state.apply(s, U("pause_requested", "16:00", { pause_id = B .. "-5", agent_id = B, at = "stop", kind = "pause" }))
  state.apply(s, U("pause_expired", "16:10", { pause_id = B .. "-5", reason = "agent_finished" }))
  eq({ s.pauses[B .. "-5"].status, s.pauses[B .. "-5"].end_reason }, { "EXPIRED", "agent_finished" }, "pause_expired → EXPIRED with end_reason")
  eq(s.agents[B].pause, nil, "expired: a.pause cleared")
  feed(H("Stop", "16:11", { agent_id = B, pause = { id = B .. "-5", phase = "released", target = B, reason = "user", waited_ms = 100 } }))
  eq({ s.pauses[B .. "-5"].status, s.pauses[B .. "-5"].end_reason }, { "RESUMED", nil }, "RESUMED wins over EXPIRED")
  state.apply(s, U("pause_expired", "16:20", { pause_id = B .. "-5", reason = "session_ended" }))
  eq(s.pauses[B .. "-5"].status, "RESUMED", "pause_expired does nothing to RESUMED")

  -- 関門：SubagentStop の記録（DONE）の後に hit → 箱は GATE。通す（指示なし）→ DONE に戻る
  state.apply(s, U("gate_set", "20:00", { on = true }))
  eq(s.gate, true, "gate_set on → s.gate = true")
  state.apply(s, U("pause_requested", "20:01", { pause_id = A .. "-6", agent_id = A, at = "stop", kind = "gate", prompt_id = P1 }))
  feed(H("SubagentStop", "20:10", { agent_id = A, last_head = "done", report = "## 報告" }))
  eq(s.agents[A].status, "DONE", "the stop record comes first: DONE")
  feed(H("SubagentStop", "20:10", { agent_id = A, pause = { id = A .. "-6", phase = "hit", kind = "gate", at = "stop", target = A } }))
  eq(state.display_status(s, A), "GATE", "gate hit at SubagentStop: GATE although a.status is DONE")
  eq(state.held_at_end(s.pauses[A .. "-6"]), true, "held_at_end")
  eq(s.pauses[A .. "-6"].hit_via, "SubagentStop", "hit_via = SubagentStop (no tool)")
  feed(H("SubagentStop", "20:40", { agent_id = A, pause = { id = A .. "-6", phase = "released", target = A, reason = "user", waited_ms = 30000 } }))
  eq(state.display_status(s, A), "DONE", "pass: DONE again")
  state.apply(s, U("gate_set", "21:00", { on = false }))
  eq(s.gate, false, "gate_set off → false")
  -- 止まれ（PreToolUse）の残りがあっても、終わった箱は DONE のまま
  state.apply(s, U("pause_requested", "21:01", { pause_id = A .. "-7", agent_id = A, at = "next", kind = "pause" }))
  feed(H("PreToolUse", "21:02", { agent_id = A, tool_name = "Read", pause = { id = A .. "-7", phase = "hit", kind = "pause", at = "next", target = A } }))
  eq(state.display_status(s, A), "DONE", "a stale PreToolUse pause on a finished box shows DONE")

  -- ROOT にも止まれ（Stop で止まる）
  state.apply(s, U("pause_requested", "22:00", { pause_id = "ROOT-8", agent_id = "ROOT", at = "next", kind = "pause", prompt_id = P1 }))
  feed(H("Stop", "22:05", { pause = { id = "ROOT-8", phase = "hit", kind = "pause", at = "next", target = "ROOT" } }))
  eq(state.display_status(s, "ROOT"), "PAUSED", "ROOT paused at Stop")
  eq(state.pause_of(s, "ROOT").id, "ROOT-8", "pause_of(ROOT)")

  -- 一覧の順と通し番号、counts
  eq(table.concat(state.pauses_of(s, A), ","), table.concat({ A .. "-1", A .. "-6", A .. "-7" }, ","), "pauses_of: requested order")
  eq(s.pauses[A .. "-1"].n, 1, "n: numbered in the flow")
  eq(s.pauses[A .. "-6"].n, 6, "n follows the requested order across boxes")
  eq(s.counts.pauses, 8, "counts.pauses = 8")
  eq(s.counts.paused, 2, "counts.paused = 2 (A's stale one and ROOT)")

  -- flow_view：この流れの pause だけ。宛先が流れの外なら ROOT に付けた写し
  feed(H("UserPromptSubmit", "30:00", { prompt_id = P2, prompt_head = "second" }))
  feed(H("PreToolUse", "30:01", { prompt_id = P2, tool_name = "Agent", tool_use_id = "tC", tool_input = { description = "c" } }))
  feed(H("SubagentStart", "30:02", { prompt_id = P2, agent_id = "afeed130000000003", agent_type = "general-purpose" }))
  state.apply(s, U("pause_requested", "30:10", { pause_id = A .. "-10", agent_id = A, at = "next", kind = "pause", prompt_id = P2 }))
  local v1 = state.flow_view(s, P1)
  eq(#v1.pause_order, 8, "flow_view(P1): the 8 pauses of flow 1")
  eq(v1.pauses[A .. "-10"], nil, "flow_view(P1): flow 2's pause not copied")
  eq(state.display_status(v1, "ROOT"), "PAUSED", "flow_view: ROOT's live pause shows")
  local v2 = state.flow_view(s, P2)
  eq(#v2.pause_order, 1, "flow_view(P2): 1 pause")
  eq(v2.pauses[A .. "-10"].owner_id, "ROOT", "flow_view(P2): target outside the flow → owner ROOT")
  eq(v2.agents.ROOT.pause, nil, "… but it is not ROOT's live pause")
  eq(state.pause_of(v2, "ROOT"), nil, "pause_of(ROOT) in flow 2 = nil")
  eq(s.pauses[A .. "-10"].owner_id, nil, "flow_view does not change the original")
  eq(state.SV, 12, "SV = 12")
end

-- ---------- 14) 親経由の修正指示（relay）と、終わった子の再開（DESIGN-v0.1.2-steer2 §6.4、E3c） ----------
print("[14] relay / resumed agent")
do
  local FX2 = here .. "/fixtures/hooks_steer2.jsonl"
  local recs = util.json_lines(FX2, 0)
  eq(#recs, 9, "fixture hooks_steer2: 9 lines")
  local CH = "afeed000000000030"
  local P1, P2 = "c0ffee31-0000-4000-8000-000000000031", "c0ffee32-0000-4000-8000-000000000032"
  local function U(event, ts, f)
    local e = { v = 1, event = event, ts = "2026-10-06T09:" .. ts .. ".000Z", src = "user" }
    for k, v in pairs(f or {}) do e[k] = v end
    return e
  end
  local s = state.new("r13")
  local function feed(i) for _, e in ipairs(claude.normalize_hook(recs[i])) do state.apply(s, e) end end
  state.apply(s, U("run_prompt", "00:00", { prompt_id = P1, prompt_head = "start a probe child", src = "hook" }))
  -- 終わり際（stop）の指示：SubagentStop → block の配達 → 続けて働く → もう一度 SubagentStop
  state.apply(s, U("steer_requested", "00:05", { steer_id = CH .. "-1791265400000", agent_id = CH, text = "Write b.txt instead of a.txt.",
    via = "hook", expect = "stop", prompt_id = P1, kind = "steer" }))
  eq(s.steers[CH .. "-1791265400000"].expect, "stop", "steer_requested: expect = stop kept")
  feed(1)
  eq(s.agents[CH].status, "RUNNING", "SubagentStart → RUNNING")
  feed(2)
  eq(s.agents[CH].status, "DONE", "SubagentStop (record) → DONE")
  feed(3)
  eq(s.steers[CH .. "-1791265400000"].status, "DELIVERED", "steer line (mode block) → DELIVERED")
  eq(s.steers[CH .. "-1791265400000"].delivered_via, "SubagentStop", "delivered_via = SubagentStop")
  eq(s.agents[CH].status, "RUNNING", "block at its end → back to RUNNING (it continues)")
  feed(4)
  eq(s.agents[CH].status, "DONE", "second SubagentStop → DONE")
  eq(#s.agents[CH].attempts, 1, "block at the end does not open a new attempt")

  -- 親経由：要求 → 端末に打った（DELIVERED/terminal）→ Claude Code が読んだ → ROOT が SendMessage で渡した
  local RL = '[AgentMap] Tell sub-agent [1] "probe child" (agent id ' .. CH .. ') this, with SendMessage: '
    .. "The word hello is outdated. The file a.txt must contain the word GOODBYE instead."
  local R1 = CH .. "-1791265410000"
  state.apply(s, U("steer_requested", "00:13", { steer_id = R1, agent_id = CH, via = "relay", expect = "parent", relay_line = RL,
    text = "The word hello is outdated. The file a.txt must contain the word GOODBYE instead.", prompt_id = P1, kind = "steer" }))
  local st = s.steers[R1]
  eq(st.status, "PENDING", "relay steer_requested → PENDING")
  eq(st.expect .. "|" .. st.relay_line, "parent|" .. RL, "relay: expect and relay_line kept")
  eq(state.relay_pending(s, CH), 1, "relay_pending = 1 (requested)")
  state.apply(s, U("steer_delivered", "00:13", { steer_id = R1, agent_id = CH, via = "terminal" }))
  eq(st.status .. "/" .. st.delivered_via, "DELIVERED/terminal", "typed into the terminal → DELIVERED/terminal (SENT)")
  eq(state.relay_pending(s, CH), 1, "relay_pending still 1 (typed, not passed on)")
  feed(5) -- UserPromptSubmit "[AgentMap] Tell sub-agent …"
  eq(st.delivered_via, "UserPromptSubmit", "run_prompt with the relay line → READ (UserPromptSubmit)")
  eq(st.confirmed_at, "2026-10-06T09:00:20.000Z", "confirmed_at = the prompt's time")
  eq(#s.flows, 1, "the relay prompt does not start a new flow")
  -- 宛先の違う SendMessage は何もしない
  state.apply(s, U("message_sent", "00:19", { agent_id = "ROOT", to = "someone-else", head = "x", tool_use_id = "tz", src = "hook" }))
  eq(st.relayed_at, nil, "message_sent to another id: nothing")
  feed(6) -- PostToolUse SendMessage → tool_used + message_sent
  eq(st.status .. "/" .. st.delivered_via, "DELIVERED/SendMessage", "message_sent → DELIVERED/SendMessage (RELAYED)")
  eq(st.relayed_at, "2026-10-06T09:00:26.000Z", "relayed_at = the SendMessage time")
  eq(st.relayed_by, "ROOT", "relayed_by = ROOT")
  eq(st.relay_head, "The word hello is outdated. The file a.txt must contain the word GOODBYE instead.", "relay_head = what ROOT sent")
  eq(st.relay_tool_use_id, "toolu_relay0000000000001", "relay_tool_use_id")
  eq(state.relay_pending(s, CH), 0, "relay_pending = 0 after it was passed on")
  eq(s.agents.ROOT.tool_counts.SendMessage, 1, "SendMessage still counted as ROOT's tool")
  -- 同じ id の 2 回目の SubagentStart（終わった子が再開した）→ RUNNING、回が 2 つ → 終わると DONE
  feed(7)
  eq(s.agents[CH].status, "RUNNING", "second SubagentStart of the same id → RUNNING (DONE → RUNNING)")
  eq(#s.agents[CH].attempts, 2, "a new attempt is opened")
  eq(s.agents[CH].attempts[2].trigger, "resumed", "the new attempt's trigger = resumed")
  eq(s.agents[CH].finished_at, nil, "finished_at cleared while it runs again")
  feed(8)
  eq(s.agents[CH].status, "DONE", "then SubagentStop → DONE")
  eq(s.agents[CH].attempts[2].finished_at, "2026-10-06T09:00:40.000Z", "the second attempt closes at the second end")
  eq(#s.agents[CH].attempts, 2, "two attempts")
  -- 内部の Agent（SubagentStart も agent_type も無い SubagentStop）は箱を作らない（E8）
  local n_order = #s.order
  feed(9)
  eq(#s.order, n_order, "an unknown SubagentStop (agent_type \"\") makes no box")
  eq(s.phantoms and s.phantoms["afeed000000000039"] ~= nil, true, "… it is kept as a phantom")

  -- not_relayed：READ のあと渡されずに → steer_expired(not_relayed) は DELIVERED からでも EXPIRED
  local R2 = CH .. "-1791265450000"
  state.apply(s, U("steer_requested", "00:50", { steer_id = R2, agent_id = CH, via = "relay", expect = "parent", relay_line = "[AgentMap] Tell … second",
    text = "second", prompt_id = P1 }))
  state.apply(s, U("steer_delivered", "00:50", { steer_id = R2, agent_id = CH, via = "terminal" }))
  state.apply(s, U("steer_expired", "00:51", { steer_id = R2, reason = "agent_finished" }))
  eq(s.steers[R2].status, "DELIVERED", "another expiry reason does not touch a DELIVERED relay")
  state.apply(s, U("steer_expired", "00:59", { steer_id = R2, reason = "not_relayed" }))
  eq(s.steers[R2].status .. "/" .. tostring(s.steers[R2].end_reason), "EXPIRED/not_relayed", "not_relayed → EXPIRED from DELIVERED")
  eq(state.relay_pending(s, CH), 0, "relay_pending excludes EXPIRED")
  -- 期限切れの後に SendMessage の記録が届いた → 渡したのが事実なので DELIVERED に戻る
  state.apply(s, U("message_sent", "01:00", { agent_id = "ROOT", to = CH, head = "second", tool_use_id = "t2", src = "hook" }))
  eq(s.steers[R2].status .. "/" .. tostring(s.steers[R2].delivered_via), "DELIVERED/SendMessage", "a late SendMessage wins over not_relayed")
  eq(s.steers[R2].end_reason, nil, "end_reason cleared")
  -- 期限切れと生きているものが両方あれば、生きている方に結びつける
  local R6, R7 = CH .. "-1791265460000", CH .. "-1791265461000"
  state.apply(s, U("steer_requested", "01:01", { steer_id = R6, agent_id = CH, via = "relay", relay_line = "a", text = "a", prompt_id = P1 }))
  state.apply(s, U("steer_delivered", "01:01", { steer_id = R6, agent_id = CH, via = "terminal" }))
  state.apply(s, U("steer_expired", "01:02", { steer_id = R6, reason = "not_relayed" }))
  state.apply(s, U("steer_requested", "01:03", { steer_id = R7, agent_id = CH, via = "relay", relay_line = "b", text = "b", prompt_id = P1 }))
  state.apply(s, U("message_sent", "01:04", { agent_id = "ROOT", to = CH, head = "b", tool_use_id = "t6", src = "hook" }))
  eq((s.steers[R6].relayed_at and "R6" or "-") .. (s.steers[R7].relayed_at and "R7" or "-"), "-R7",
    "an expired (not_relayed) one and a live one: the live one is linked")
  -- 手で打った伝言（該当の relay が無い）は何もしない。頼む前の SendMessage は結びつけない
  local R3 = CH .. "-1791265470000"
  state.apply(s, U("message_sent", "01:05", { agent_id = "ROOT", to = CH, head = "manual", tool_use_id = "t3", src = "hook" }))
  state.apply(s, U("steer_requested", "01:10", { steer_id = R3, agent_id = CH, via = "relay", relay_line = "x", text = "third", prompt_id = P1 }))
  eq(s.steers[R3].relayed_at, nil, "a SendMessage before the request is not linked")
  -- 2 件あれば古い方から
  local R4 = CH .. "-1791265480000"
  state.apply(s, U("steer_requested", "01:11", { steer_id = R4, agent_id = CH, via = "relay", relay_line = "y", text = "fourth", prompt_id = P1 }))
  state.apply(s, U("message_sent", "01:20", { agent_id = "ROOT", to = CH, head = "third", tool_use_id = "t4", src = "hook" }))
  eq((s.steers[R3].relayed_at and "R3" or "-") .. (s.steers[R4].relayed_at and "R4" or "-"), "R3-", "two waiting: the oldest is passed on first")
  -- 取り消した relay は結びつけない
  state.apply(s, U("steer_cancelled", "01:21", { steer_id = R4 }))
  state.apply(s, U("message_sent", "01:22", { agent_id = "ROOT", to = CH, head = "fourth", tool_use_id = "t5", src = "hook" }))
  eq(s.steers[R4].status, "CANCELLED", "a cancelled relay stays CANCELLED")
  -- prompt_head が 200 文字で切れて本文が入っていなくても、端末に打った文の先頭が一致すれば READ
  local long = string.rep("n", 150)
  local R5 = CH .. "-1791265490000"
  local RL5 = '[AgentMap] Tell sub-agent [1] "' .. long .. '" (agent id ' .. CH .. ') this, with SendMessage: use docs/v3 please'
  state.apply(s, U("steer_requested", "01:30", { steer_id = R5, agent_id = CH, via = "relay", relay_line = RL5, text = "use docs/v3 please", prompt_id = P1 }))
  state.apply(s, U("steer_delivered", "01:30", { steer_id = R5, agent_id = CH, via = "terminal" }))
  state.apply(s, U("run_prompt", "01:31", { prompt_id = "pX", prompt_head = RL5:sub(1, 200), src = "hook" }))
  eq(s.steers[R5].confirmed_at, "2026-10-06T09:01:31.000Z", "relay READ by the typed line's head (prompt_head cut at 200)")
  eq(state.SV, 12, "SV = 12")
end

-- ---------- 15) 報告を SubagentHandback で返す子（DESIGN-v0.1.2-handback §3.7・§4.4） ----------
print("[15] hand-back sub-agents")
do
  -- (a) H0 の形：0.1.2（この変更の前）の hooks が block を出し → 親に <agent-message>[Subagent hand-back] →
  --     NOT HELD (hand-back)、箱は DONE に戻り、指示は held = false・held_reason = handback
  local recs = util.json_lines(here .. "/fixtures/hooks_handback_h0.jsonl", 0)
  eq(#recs, 9, "fixture hooks_handback_h0: 9 lines")
  local CH = "afeed000000000050"
  local S1, S2 = CH .. "-1791439904492", CH .. "-1791439988059"
  local s = state.new("h0")
  local function U(event, ts, f)
    local e = { v = 1, event = event, ts = "2026-10-08T06:" .. ts .. "Z", src = "user" }
    for k, v in pairs(f or {}) do e[k] = v end
    return e
  end
  local function feed(i) for _, e in ipairs(claude.normalize_hook(recs[i])) do state.apply(s, e) end end
  for i = 1, 5 do feed(i) end
  state.apply(s, U("steer_requested", "11:44.492", { steer_id = S1, agent_id = CH, text = "one", via = "hook", expect = "stop" }))
  state.apply(s, U("steer_requested", "13:08.059", { steer_id = S2, agent_id = CH, text = "two", via = "hook", expect = "stop" }))
  feed(6) feed(7)
  eq(s.agents[CH].status, "RUNNING", "H0: block at its end → RUNNING (end_held)")
  ok(s.agents[CH].end_held ~= nil, "H0: end_held is set")
  feed(8)
  eq(s.agents[CH].status, "DONE", "H0: the hand-back notice settles it → DONE")
  eq(s.agents[CH].end_held, nil, "H0: end_held cleared")
  eq(s.steers[S1].held, false, "H0: the instruction was not held (held = false)")
  eq(s.steers[S1].held_reason, "handback", "H0: held_reason = handback")
  eq(s.steers[S1].status, "DELIVERED", "H0: status stays DELIVERED (shown NOT HELD)")
  eq(s.agents[CH].finished_at, "2026-10-08T06:13:20.000Z", "H0: finished_at = the first end")
  eq(s.agents[CH].handback, true, "H0: the notice marks the child as a hand-back child")
  eq(#s.flows, 1, "H0: the notice does not start a flow")
  feed(9)
  eq(s.agents[CH].status, "DONE", "H0: still DONE after ROOT's Stop")

  -- (b) 新しい記録：permission_mode、agent_handback、skipped、rerouted、再開して 2 回目の終わり
  local C2 = "afeed000000000040"
  local s2 = state.new("hb")
  local function H(ev, ts, f)
    local r = { session_id = "hb", hook_event_name = ev, prompt_id = "q1", _ts = "2026-10-08T07:" .. ts .. "Z" }
    for k, v in pairs(f or {}) do r[k] = v end
    for _, e in ipairs(claude.normalize_hook(r)) do state.apply(s2, e) end
  end
  H("UserPromptSubmit", "00:00.000", { prompt_head = "go", permission_mode = "auto" })
  H("UserPromptSubmit", "00:00.500", { prompt_head = "again", permission_mode = "default", prompt_id = "q0" })
  eq(s2.permission_mode, "auto", "permission_mode = the first value (not overwritten)")
  H("SubagentStart", "00:01.000", { agent_id = C2, agent_type = "general-purpose" })
  eq(s2.agents[C2].handback, nil, "no mark yet: a.handback = nil")
  eq(state.handback_likely(s2, s2.agents[C2]), true, "handback_likely: permission mode auto + no mark → true")
  eq(state.handback_likely(s2, C2), true, "handback_likely also takes an id")
  eq(state.handback_likely(s2, "ROOT"), false, "handback_likely(ROOT) = false")
  s2.agents[C2].agent_type = "fork"
  eq(state.handback_likely(s2, C2), false, "a fork is not hand-back-likely")
  s2.agents[C2].agent_type = "general-purpose"
  local sx = state.new("x")
  state.apply(sx, U("run_prompt", "00:00.000", { prompt_head = "go", permission_mode = "bypassPermissions" }))
  state.apply(sx, U("agent_started", "00:01.000", { agent_id = "z1", agent_type = "general-purpose" }))
  eq(state.handback_likely(sx, "z1"), false, "permission mode other than auto → not likely")
  state.apply(sx, U("agent_handback", "00:02.000", { agent_id = "z1", source = "transcript" }))
  eq(state.handback_likely(sx, "z1"), true, "a mark (agent_handback) wins over the permission mode")
  -- 止まれ：handback の直前で止まる（関門）
  state.apply(s2, U("pause_requested", "00:02.000", { pause_id = C2 .. "-p1", agent_id = C2, at = "stop", kind = "gate" }))
  H("PreToolUse", "00:05.000", { agent_id = C2, tool_name = "SubagentHandback", tool_use_id = "tH",
    pause = { id = C2 .. "-p1", phase = "hit", kind = "gate", at = "stop", target = C2 } })
  H("PreToolUse", "00:05.100", { agent_id = C2, tool_name = "SubagentHandback", tool_use_id = "tH", report = "## Report\n- Done: a.txt" })
  local p = s2.pauses[C2 .. "-p1"]
  eq(p.hit_via, "PreToolUse:SubagentHandback", "pause hit via PreToolUse:SubagentHandback")
  eq(state.held_at_end(p), true, "held_at_end: true at PreToolUse:SubagentHandback")
  eq(state.display_status(s2, C2), "GATE", "display_status: GATE while held before the hand-back")
  eq(s2.agents[C2].handback, true, "agent_handback → a.handback = true")
  eq(s2.agents[C2].handback_report, "## Report\n- Done: a.txt", "a.handback_report = the report about to be handed back")
  eq(s2.agents[C2].status, "RUNNING", "still RUNNING while held")
  H("PreToolUse", "00:09.000", { agent_id = C2, tool_name = "SubagentHandback", tool_use_id = "tH",
    pause = { id = C2 .. "-p1", phase = "released", reason = "user", target = C2, waited_ms = 3900 } })
  eq(state.held_at_end(p), false, "held_at_end: false after release")
  -- 終わり際の指示：SubagentStop で skipped（PENDING のまま）
  local K = C2 .. "-1791500000000"
  state.apply(s2, U("steer_requested", "00:08.000", { steer_id = K, agent_id = C2, text = "write b.txt", via = "hook", expect = "stop" }))
  H("SubagentStop", "00:10.000", { agent_id = C2, agent_type = "general-purpose", report = "## Report\n- Done: a.txt (final)",
    report_via = "handback", permission_mode = "auto" })
  H("SubagentStop", "00:10.050", { agent_id = C2, steer = { ids = { K }, mode = "skipped", reason = "handback", target = C2 } })
  eq(s2.agents[C2].status, "DONE", "skipped: the child is DONE (no end_held)")
  eq(s2.agents[C2].end_held, nil, "skipped: no end_held")
  eq(s2.steers[K].status, "PENDING", "steer_skipped: stays PENDING")
  eq(s2.steers[K].skipped_at, "2026-10-08T07:00:10.050Z", "steer_skipped: skipped_at")
  eq(s2.steers[K].skip_reason, "handback", "steer_skipped: skip_reason = handback")
  eq(s2.agents[C2].handback_report, "## Report\n- Done: a.txt (final)", "SubagentStop's report wins for handback_report")
  eq(s2.counts.steers_pending, 1, "skipped counts as pending")
  -- 自動で親経由に回す：新しい relay（rerouted_from）→ 元は CANCELLED（rerouted）
  local K2 = C2 .. "-1791500000100"
  state.apply(s2, U("steer_requested", "00:11.000", { steer_id = K2, agent_id = C2, text = "write b.txt", via = "relay", expect = "parent",
    relay_line = "[AgentMap] Tell …", rerouted_from = K }))
  state.apply(s2, U("steer_cancelled", "00:11.010", { steer_id = K, reason = "rerouted", rerouted_to = K2 }))
  eq(s2.steers[K2].rerouted_from, K, "steer_requested: rerouted_from")
  eq(s2.steers[K].status, "CANCELLED", "the skipped one → CANCELLED")
  eq(s2.steers[K].end_reason, "rerouted", "cancel reason = rerouted")
  eq(s2.steers[K].rerouted_to, K2, "rerouted_to = the new id")
  eq(s2.steers[K].skip_reason, "handback", "skip_reason is kept")
  -- 親が SendMessage → 子は同じ id で再開（V45）→ 2 回目の handback と終わり
  H("PostToolUse", "00:16.000", { tool_name = "SendMessage", tool_use_id = "tS", tool_input = { to = C2, head = "write b.txt" } })
  eq(s2.steers[K2].relayed_at, "2026-10-08T07:00:16.000Z", "the relay is passed on (RELAYED)")
  H("SubagentStart", "00:16.100", { agent_id = C2, agent_type = "general-purpose" })
  eq(s2.agents[C2].status, "RUNNING", "resumed: DONE → RUNNING")
  eq(#s2.agents[C2].attempts, 2, "resumed: a second attempt")
  H("PreToolUse", "00:20.000", { agent_id = C2, tool_name = "SubagentHandback", tool_use_id = "tH2", report = "## Report\n- Done: b.txt" })
  eq(s2.agents[C2].status, "RUNNING", "second hand-back: still RUNNING until SubagentStop")
  H("SubagentStop", "00:20.400", { agent_id = C2, agent_type = "general-purpose", report = "## Report\n- Done: b.txt", report_via = "handback" })
  eq(s2.agents[C2].status, "DONE", "second agent_finished → DONE")
  eq(s2.agents[C2].attempts[2].finished_at, "2026-10-08T07:00:20.400Z", "the second attempt closes")
  eq(s2.agents[C2].report, "## Report\n- Done: b.txt", "the report is the second one")
  H("UserPromptSubmit", "00:20.450", { prompt_id = "q9", kind = "agent_message", from = C2,
    prompt_head = '<agent-message from="' .. C2 .. '"> [Subagent hand-back] …' })
  eq(s2.agents[C2].status, "DONE", "the notice after a plain hand-back changes nothing")
  eq(s2.steers[K2].held, nil, "… and settles no instruction")
  -- 止まれが handback で終わった子の SubagentStop で消された（released handback_end）
  state.apply(s2, U("pause_requested", "00:21.000", { pause_id = C2 .. "-p2", agent_id = C2, at = "next", kind = "pause" }))
  state.apply(s2, U("pause_resumed", "00:21.500", { pause_id = C2 .. "-p2", agent_id = C2, reason = "user" }))
  H("SubagentStop", "00:21.600", { agent_id = C2, pause = { id = C2 .. "-p2", phase = "released", reason = "handback_end", target = C2 } })
  eq(s2.pauses[C2 .. "-p2"].release_reason, "handback_end", "released handback_end wins over Neovim's reason (hook's own)")
  local p3 = C2 .. "-p3"
  state.apply(s2, U("pause_requested", "00:22.000", { pause_id = p3, agent_id = C2, at = "stop", kind = "gate" }))
  H("SubagentStop", "00:22.100", { agent_id = C2, pause = { id = p3, phase = "released", reason = "handback_end", target = C2 } })
  eq(s2.pauses[p3].status .. "/" .. s2.pauses[p3].release_reason, "RESUMED/handback_end", "REQUESTED → RESUMED (handback_end)")
  -- 期限切れの記録の skip_reason
  local K3 = C2 .. "-1791500000200"
  state.apply(s2, U("steer_requested", "00:23.000", { steer_id = K3, agent_id = C2, text = "late", via = "hook" }))
  state.apply(s2, U("steer_expired", "00:30.000", { steer_id = K3, reason = "agent_finished", skip_reason = "handback" }))
  eq(s2.steers[K3].status .. "/" .. s2.steers[K3].end_reason .. "/" .. tostring(s2.steers[K3].skip_reason),
    "EXPIRED/agent_finished/handback", "steer_expired keeps reason agent_finished and skip_reason handback")
  eq(state.SV, 12, "SV = 12")
end

vim.fn.delete(TMP, "rf")
print(string.format("%d passed, %d failed", passes, fails))
print(fails == 0 and "PASS test_reducer.lua" or "FAIL test_reducer.lua")
if fails > 0 then os.exit(1) end
