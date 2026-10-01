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

vim.fn.delete(TMP, "rf")
print(string.format("%d passed, %d failed", passes, fails))
print(fails == 0 and "PASS test_reducer.lua" or "FAIL test_reducer.lua")
if fails > 0 then os.exit(1) end
