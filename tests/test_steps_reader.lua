-- ============================================================
--  test_steps_reader.lua -- reading step lists ("## Steps" / "Step N done") from an agent's own transcript
--    providers/claude.lua: agent_steps（増えた分だけ読む）・steps_of
--    events.lua: poll_steps（変わったときだけ steps_updated を 1 件記録する。終わった Agent は 1 回だけ読む）
--  transcript は fixtures/agent_steps.jsonl を一時フォルダに 2 回に分けて写して読む。本物の Claude のフォルダは使わない。
--  実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_steps_reader.lua
-- ============================================================
local t = require("t")
local claude = require("agentmap.providers.claude")
local events = require("agentmap.events")
local state = require("agentmap.state")
local util = require("agentmap.util")

local FIX = vim.g.agentmap_test_dir .. "/fixtures/agent_steps.jsonl"
local LINES = vim.fn.readfile(FIX)
t.eq(#LINES, 7, "fixture has 7 lines")
local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")
local path = TMP .. "/agent-afeed000000000031.jsonl"

-- ---------- 1. agent_steps：2 回に分けて読む ----------
vim.fn.writefile(vim.list_slice(LINES, 1, 4), path)
local idx = claude.agent_steps(path, nil)
t.eq(#idx.items, 3, "1st read: 3 items")
t.eq(#idx.marks, 0, "1st read: 0 marks (marks inside tool_result are not read)")
t.eq(idx.off, vim.uv.fs_stat(path).size, "1st read: off = file size")
t.eq(idx.items[1].text, "Read the current code", "item text")
t.eq(idx.listed_at, "2026-10-04T10:00:05.000Z", "listed_at = transcript timestamp of the list")
local s1 = claude.steps_of(idx)
t.eq(s1, { source = "transcript", listed_at = "2026-10-04T10:00:05.000Z", items = {
  { n = 1, text = "Read the current code" }, { n = 2, text = "Write the design" }, { n = 3, text = "Run the tests" } } },
  "steps_of: the state shape")
local off1 = idx.off
idx = claude.agent_steps(path, idx)
t.eq(idx.off, off1, "no growth: nothing read")

-- 書きかけの行（改行なし）は次回
local f = assert(io.open(path, "ab"))
f:write(LINES[5]:sub(1, 40))
f:close()
idx = claude.agent_steps(path, idx)
t.eq(idx.off, off1, "an unfinished last line is left for the next read")
vim.fn.writefile(LINES, path)
idx = claude.agent_steps(path, idx)
t.eq(#idx.marks, 1, "2nd read: 1 mark (marks inside tool_use input are not read)")
t.ok(idx.off > off1, "2nd read: off advanced")
t.eq(idx.items[1].done_at, "2026-10-04T10:01:00.000Z", "2nd read: step 1 done_at")
t.eq(idx.items[2].done_at, nil, "2nd read: step 2 not done")

-- 後の一覧が勝つ・印は番号で持ち越す・一覧の数を超える印は捨てる
local function text_line(ts, text)
  return vim.json.encode({ type = "assistant", timestamp = ts, message = { id = "m" .. ts, role = "assistant",
    content = { { type = "text", text = text } } } })
end
vim.fn.writefile({ text_line("2026-10-04T10:02:00.000Z", "Step 3 done"),
  text_line("2026-10-04T10:03:00.000Z", "計画を立て直します。\n## 手順\n1. 読む\n2. 書く") }, path, "a")
idx = claude.agent_steps(path, idx)
t.eq(#idx.items, 2, "a later list replaces the earlier one")
t.eq(idx.items[1].text, "読む", "new list text")
t.eq(idx.items[1].done_at, "2026-10-04T10:01:00.000Z", "done marks carried over by number")
t.eq(#idx.marks, 1, "marks beyond the new list are dropped")
t.eq(idx.listed_at, "2026-10-04T10:03:00.000Z", "listed_at of the new list")
vim.fn.writefile({ text_line("2026-10-04T10:04:00.000Z", "手順 2 開始") }, path, "a")
idx = claude.agent_steps(path, idx)
t.eq(idx.items[2].started_at, "2026-10-04T10:04:00.000Z", "start mark sets started_at")

-- 一覧より前の印は捨てる
local p2 = TMP .. "/agent-early.jsonl"
vim.fn.writefile({ text_line("2026-10-04T11:00:00.000Z", "Step 1 done"),
  text_line("2026-10-04T11:00:01.000Z", "## Steps\n1. a\n2. b") }, p2)
local i2 = claude.agent_steps(p2, nil)
t.eq(#i2.marks, 0, "marks before the first list are dropped")
t.eq(claude.steps_of(claude.agent_steps(TMP .. "/missing.jsonl", nil)), nil, "missing file → no steps")
-- 作り直された（小さくなった）ら最初から
vim.fn.writefile({ text_line("2026-10-04T12:00:00.000Z", "## Steps\n1. only") }, p2)
i2 = claude.agent_steps(p2, i2)
t.eq(#i2.items, 1, "a recreated (smaller) file is read from the start")

-- ---------- 2. events.poll_steps ----------
local SID = "c0ffee30-0000-4000-8000-000000000030"
local SLUG = "-tmp-agentmap-test-steps"
local A = "afeed000000000031"
local run_dir = vim.env.AGENTMAP_DIR .. "/projects/" .. SLUG .. "/runs/" .. SID
vim.fn.mkdir(run_dir, "p")
local function hook(ev, ts, extra)
  local r = { session_id = SID, hook_event_name = ev, cwd = "/tmp/agentmap-test/steps", prompt_id = "p30",
    transcript_path = TMP .. "/" .. SID .. ".jsonl", _v = 1, _ts = ts, _src = "claude_hook" }
  for k, v in pairs(extra or {}) do r[k] = v end
  return vim.json.encode(r)
end
vim.fn.writefile({
  hook("SessionStart", "2026-10-04T10:00:00.000Z", { source = "startup" }),
  hook("UserPromptSubmit", "2026-10-04T10:00:01.000Z", { prompt_head = "steps" }),
  hook("SubagentStart", "2026-10-04T10:00:02.000Z", { agent_id = A, agent_type = "general-purpose" }),
}, run_dir .. "/hooks.jsonl")
local cpath = TMP .. "/child.jsonl"
vim.fn.writefile(vim.list_slice(LINES, 1, 4), cpath)
local run = events.load(run_dir)
t.eq(run.state.agents[A].status, "RUNNING", "child RUNNING")
events.emit(run, { event = "agent_updated", agent_id = A, transcript_path = cpath, src = "system" })
local function count_steps_events()
  local n = 0
  for _, e in ipairs(util.json_lines(run_dir .. "/events.jsonl", 0)) do
    if e.event == "steps_updated" and e.agent_id == A then n = n + 1 end
  end
  return n
end
t.eq(events.poll_steps(run), true, "poll_steps: list found → changed")
t.eq(count_steps_events(), 1, "poll_steps: one steps_updated recorded")
t.eq(#run.state.agents[A].steps.items, 3, "state has the steps")
t.eq(events.poll_steps(run), false, "poll_steps: same size → not changed")
-- 中身が変わらない追記（目印の無い行）では記録しない
vim.fn.writefile({ LINES[6], LINES[7] }, cpath, "a")
t.eq(events.poll_steps(run), false, "poll_steps: grown but no new list/mark → not changed")
t.eq(count_steps_events(), 1, "poll_steps: still one record")
vim.fn.writefile({ LINES[5] }, cpath, "a")
t.eq(events.poll_steps(run), true, "poll_steps: a done mark → changed")
t.eq(run.state.agents[A].steps.items[1].done_at, "2026-10-04T10:01:00.000Z", "state: step 1 done")
t.eq(count_steps_events(), 2, "poll_steps: two records")
-- 終わった：直後の 1 回だけ読む
vim.fn.writefile({ text_line("2026-10-04T10:05:00.000Z", "Step 2 done") }, cpath, "a")
local h = io.open(run_dir .. "/hooks.jsonl", "ab")
h:write(hook("SubagentStop", "2026-10-04T10:05:01.000Z", { agent_id = A, agent_transcript_path = cpath, last_head = "done" }) .. "\n")
h:close()
events.poll(run)
t.eq(run.state.agents[A].status, "DONE", "child DONE")
t.eq(events.poll_steps(run), true, "poll_steps: the last read after the finish picks up the last mark")
t.eq(run.state.agents[A].steps.items[2].done_at, "2026-10-04T10:05:00.000Z", "state: step 2 done")
vim.fn.writefile({ text_line("2026-10-04T10:06:00.000Z", "Step 3 done") }, cpath, "a")
t.eq(events.poll_steps(run), false, "poll_steps: finished agents are not read again")
-- 読み込み直し（state.json の控え）からでも同じ内容なら記録しない
local again = events.load(run_dir)
t.eq(#again.state.agents[A].steps.items, 3, "steps survive state.json")
t.eq(events.poll_steps(again), false, "fresh load: finished agent not read")

-- ---------- 3. backfill（transcript だけの session）に手順表と TaskCreate ----------
local cdir = TMP .. "/claude"
local slug = "-tmp-agentmap-test-bf"
local BSID = "c0ffee31-0000-4000-8000-000000000031"
local base = cdir .. "/projects/" .. slug
vim.fn.mkdir(base, "p")
local function L(o) return vim.json.encode(o) end
vim.fn.writefile({
  L({ type = "user", timestamp = "2026-10-04T13:00:00.000Z", cwd = "/tmp/bf", message = { role = "user", content = "plan it" } }),
  L({ type = "assistant", timestamp = "2026-10-04T13:00:01.000Z", message = { id = "r1", role = "assistant", model = "claude-opus-5-5",
    content = { { type = "tool_use", id = "tc1", name = "TaskCreate", input = { subject = "alpha", description = "secret detail", activeForm = "Doing alpha" } } } } }),
  L({ type = "user", timestamp = "2026-10-04T13:00:02.000Z", toolUseResult = { task = { id = "1", subject = "alpha" } },
    message = { role = "user", content = { { type = "tool_result", tool_use_id = "tc1", content = "Task #1 created" } } } }),
  L({ type = "assistant", timestamp = "2026-10-04T13:00:03.000Z", message = { id = "r2", role = "assistant", model = "claude-opus-5-5",
    content = { { type = "tool_use", id = "tc2", name = "TaskCreate", input = { subject = "beta" } } } } }),
  L({ type = "assistant", timestamp = "2026-10-04T13:00:04.000Z", message = { id = "r3", role = "assistant", model = "claude-opus-5-5",
    content = { { type = "tool_use", id = "tu1", name = "TaskUpdate", input = { taskId = "1", status = "completed" } } } } }),
  L({ type = "assistant", timestamp = "2026-10-04T13:00:05.000Z", message = { id = "r4", role = "assistant", model = "claude-opus-5-5",
    content = { { type = "tool_use", id = "tl1", name = "TaskList", input = {} } } } }),
  L({ type = "user", timestamp = "2026-10-04T13:00:06.000Z", toolUseResult = { tasks = { { id = "1", subject = "alpha", status = "completed" },
    { id = "2", subject = "beta", status = "pending" } } },
    message = { role = "user", content = { { type = "tool_result", tool_use_id = "tl1", content = "…" } } } }),
  L({ type = "assistant", timestamp = "2026-10-04T13:00:07.000Z", message = { id = "r5", role = "assistant", model = "claude-opus-5-5",
    content = { { type = "text", text = "## Steps\n1. one\n2. two\nStep 1 done" } } } }),
}, base .. "/" .. BSID .. ".jsonl")
require("agentmap.config").setup({ claude_config_dir = cdir })
local evs = claude.backfill(BSID, slug)
local bs = state.reduce(evs)
local T = bs.agents.ROOT.tasks
t.eq(T and table.concat(T.order, ","), "1,2", "backfill: tasks 1 (id from toolUseResult) and 2 (no result → order number)")
t.eq(T and T.items["1"].status, "completed", "backfill: TaskUpdate → completed")
t.eq(T and T.items["1"].active_form, "Doing alpha", "backfill: activeForm")
t.eq(T and T.items["2"].subject, "beta", "backfill: subject of the unanswered TaskCreate")
t.eq(T and T.items["2"].status, "pending", "backfill: TaskList status")
t.ok(not vim.json.encode(evs):find("secret detail", 1, true), "backfill: TaskCreate description is not kept")
t.eq(bs.agents.ROOT.steps and #bs.agents.ROOT.steps.items, 2, "backfill: ## Steps → steps_updated")
t.eq(bs.agents.ROOT.steps and bs.agents.ROOT.steps.items[1].done_at, "2026-10-04T13:00:07.000Z", "backfill: done mark")
require("agentmap.config").setup({})

vim.fn.delete(TMP, "rf")
t.done()
