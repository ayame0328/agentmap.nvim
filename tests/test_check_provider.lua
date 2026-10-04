-- ============================================================
--  test_check_provider.lua … HUMAN CHECK と「任せた理由・報告」を Claude の記録から読む部分（providers/claude.lua, events.lua）
--    normalize_hook（AskUserQuestion の Pre/Post/Failure、Agent の brief、SubagentStop の report）
--    agent_report / agent_notes / agent_batches の lead・ask_lead
--    backfill（transcript からの取り込み）と enrich（後読み）
--  Claude のフォルダは使わない。transcript は fixtures を一時フォルダに写して読む。
--  実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_check_provider.lua
-- ============================================================
local t = require("t")
local claude = require("agentmap.providers.claude")
local state = require("agentmap.state")
local config = require("agentmap.config")

local FIX = vim.g.agentmap_test_dir .. "/fixtures"
local SID = "ask00000-0000-0000-0000-000000000001"
local SLUG = "-tmp-agentmap-test-ask"
local REPORT_ASK = "## 要確認\n- 今の作業: orders.sql の拡張\n- 止まっている所: テストの範囲が決まらない\n- 確認したいこと: テストはどこまで書きますか？\n- 選択肢:\n  1. 単体のみ → tests/ に追加して終了\n  2. 結合まで → seed を作ってから実装"

local function dec(line) return vim.json.decode(line, { luanil = { object = true, array = true } }) end
local HOOK_LINES = vim.fn.readfile(FIX .. "/hooks_ask.jsonl")
local HOOKS = {}
for i, l in ipairs(HOOK_LINES) do HOOKS[i] = dec(l) end

local function by_event(evs, name)
  local out = {}
  for _, e in ipairs(evs) do if e.event == name then out[#out + 1] = e end end
  return out
end

-- ---------- 1. normalize_hook ----------
local pre = claude.normalize_hook(HOOKS[9])
t.eq(#pre, 1, "PreToolUse(AskUserQuestion) → 1 件")
t.eq(pre[1].event, "check_asked", "check_asked")
t.eq(pre[1].tool_use_id, "toolu_Q", "tool_use_id")
t.eq(pre[1].asker_id, "ROOT", "agent_id が無ければ聞いた側 = ROOT")
t.eq(pre[1].prompt_id, HOOKS[9].prompt_id, "prompt_id が付く")
t.eq(pre[1].questions[1].multi, false, "multiSelect → multi")
t.eq(pre[1].questions[1].multiSelect, nil, "multiSelect の名前は残さない")
t.eq(pre[1].questions[1].options[2].label, "結合まで", "options")

local post = claude.normalize_hook(HOOKS[10])
t.eq(#post, 1, "PostToolUse(AskUserQuestion) → 1 件（tool_used は出さない）")
t.eq(post[1].event, "check_answered", "check_answered")
t.eq(post[1].answers, { ["実装：dbt model について：テストはどこまで書きますか？"] = "単体のみ" }, "answers")
t.eq(#post[1].questions, 1, "questions も付く")

local child = vim.deepcopy(HOOKS[9])
child.agent_id = "a7"
t.eq(claude.normalize_hook(child)[1].asker_id, "a7", "子が聞いたら asker_id = その子")

local fail = claude.normalize_hook({ session_id = SID, hook_event_name = "PostToolUseFailure", tool_name = "AskUserQuestion",
  tool_use_id = "toolu_Q", error_head = "User rejected", _ts = "2026-10-01T10:00:11.000Z" })
t.eq(#fail, 1, "PostToolUseFailure(AskUserQuestion) → 1 件")
t.eq(fail[1].event, "check_abandoned", "check_abandoned")
t.eq(fail[1].reason, "User rejected", "reason = error_head")

local spawn = claude.normalize_hook(HOOKS[3])
t.eq(spawn[1].brief, { purpose = "orders を拡張する", reason = "設計と実装を分けて並行で進めるため", expected = "orders.sql とテストが揃うこと" }, "agent_spawn_requested に brief")
local linked = by_event(claude.normalize_hook(HOOKS[5]), "agent_linked")
t.eq(linked[1].brief and linked[1].brief.reason, "設計と実装を分けて並行で進めるため", "agent_linked に brief")
local stop = claude.normalize_hook(HOOKS[7])
t.eq(stop[1].event, "agent_finished", "SubagentStop → agent_finished")
t.eq(stop[1].report, REPORT_ASK, "agent_finished に report（改行つき）")
local noreport = vim.deepcopy(HOOKS[7]); noreport.report = nil
t.eq(claude.normalize_hook(noreport)[1].report, nil, "report が無ければ付けない")

-- 長すぎる質問は brief.LIMITS で切る（transcript から読んだときと同じ上限）
local qs = claude.norm_questions({ { question = string.rep("あ", 400), header = "h", multiSelect = true,
  options = { {}, {}, {}, {}, {}, {}, { label = "7" } } } })
t.eq(vim.fn.strchars(qs[1].question), 300, "question は 300 文字")
t.eq(#qs[1].options, 6, "option は 6 個まで")
t.eq(qs[1].multi, true, "multi = true")

-- ---------- 2. agent_report ----------
local rep, kind = claude.agent_report(FIX .. "/agent_report.jsonl")
t.eq(rep, REPORT_ASK, "handback の message を取る")
t.eq(kind, "handback", "種類 = handback")
rep, kind = claude.agent_report(FIX .. "/agent_report_text.jsonl")
t.matches(rep, "^## 報告\n%- やったこと: models/orders.sql", "handback が無ければ最後の text")
t.eq(kind, "text", "種類 = text")
t.eq(claude.agent_report(FIX .. "/nope.jsonl"), nil, "ファイルが無ければ nil")

-- ---------- 3. agent_notes（差分読み・上限） ----------
local TMP = vim.fn.tempname()
vim.fn.mkdir(TMP, "p")
local child_lines = vim.fn.readfile(FIX .. "/agent_report.jsonl")
local np = TMP .. "/notes.jsonl"
local function write(path, lines, tail_partial)
  local f = io.open(path, "wb")
  f:write(table.concat(lines, "\n") .. "\n" .. (tail_partial or ""))
  f:close()
end
write(np, vim.list_slice(child_lines, 1, 5), child_lines[6]:sub(1, 30))
local idx = claude.agent_notes(np, nil)
local function summary(entries)
  local out = {}
  for _, e in ipairs(entries) do out[#out + 1] = e.kind == "note" and ("💬" .. e.text) or (e.tool .. " " .. (e.target or "")) end
  return out
end
t.eq(summary(idx.entries), { "💬まず既存のモデルを読みます", "Read /tmp/agentmap-test/ask/models/orders.sql" }, "1 回目：書き終わった行だけ")
write(np, child_lines)
idx = claude.agent_notes(np, idx)
t.eq(summary(idx.entries), {
  "💬まず既存のモデルを読みます", "Read /tmp/agentmap-test/ask/models/orders.sql",
  "💬次に tests/ を確認します", "Bash ls tests/", "Write /tmp/agentmap-test/ask/models/orders.sql",
  "💬テストの範囲が決まらないため確認を求めます", "💬Returned the report",
}, "2 回目：増えた分を足す（時刻順・handback は「報告を返しました」）")
t.eq(idx.entries[1].ts, "2026-10-01T10:00:04.800Z", "ts は transcript の時刻")
local again = claude.agent_notes(np, idx)
t.eq(#again.entries, 7, "増えていなければ同じ")
local small = claude.agent_notes(np, nil, { max = 3 })
t.eq(summary(small.entries), { "Write /tmp/agentmap-test/ask/models/orders.sql",
  "💬テストの範囲が決まらないため確認を求めます", "💬Returned the report" }, "上限を超えたら古いものから捨てる")
local size = vim.fn.getfsize(np)
local tail_only = claude.agent_notes(np, nil, { max_first = #child_lines[#child_lines] + #child_lines[#child_lines - 1] + 10 })
t.eq(summary(tail_only.entries), { "💬Returned the report" }, "大きいファイルは初回だけ末尾から（途中の行は捨てる）")
t.eq(tail_only.off, size, "読んだ位置はファイルの終わり")
-- 作業の経過の AskUserQuestion の行：質問文を出す（1 問目。複数なら「ほか n 問」）。中身が空の行にしない
t.eq(claude._tool_target("AskUserQuestion", { questions = { { question = "テストはどこまで書きますか？" } } }),
  "テストはどこまで書きますか？", "AskUserQuestion の対象 = 1 問目の質問文")
t.eq(claude._tool_target("AskUserQuestion", { questions = { { question = "Q1" }, { question = "Q2" }, { question = "Q3" } } }),
  "Q1 (+2 more)", "複数の質問は 1 問目＋ほか n 問")
t.eq(claude._tool_target("AskUserQuestion", { questions = {} }), nil, "質問が無ければ nil")
t.eq(claude._tool_target("AskUserQuestion", {}), nil, "questions が無ければ nil")
local pidx = claude.agent_notes(FIX .. "/transcript_ask.jsonl", nil)
local ask_entry
for _, e in ipairs(pidx.entries) do if e.tool == "AskUserQuestion" then ask_entry = e end end
t.eq(ask_entry and ask_entry.target, "実装：dbt model について：テストはどこまで書きますか？",
  "親（ROOT）の作業の経過：AskUserQuestion の行に質問文が出る")

-- ---------- 4. agent_batches の lead / ask_lead ----------
local pt_lines = vim.fn.readfile(FIX .. "/transcript_ask.jsonl")
local bp = TMP .. "/parent.jsonl"
write(bp, vim.list_slice(pt_lines, 1, 2)) -- text の行だけ（Agent の行はまだ）
local bidx = claude.agent_batches(bp, nil)
t.eq(bidx.lead.toolu_A, nil, "Agent の行がまだ無い → lead なし")
write(bp, pt_lines)
bidx = claude.agent_batches(bp, bidx)
t.eq(bidx.map.toolu_A, "msg_A", "map（batch）は今までどおり")
t.eq(bidx.lead.toolu_A, "設計の確認が要るので実装を任せます", "lead = 同じ返事の、前の行の text（別の行に分かれていても）")
t.eq(bidx.ask_lead.toolu_Q, "子が要確認で止まったので聞きます", "ask_lead")
t.eq(bidx.brief.toolu_A, { purpose = "orders を拡張する", reason = "設計と実装を分けて並行で進めるため", expected = "orders.sql とテストが揃うこと" },
  "brief = Agent 呼び出しの prompt から（収集係が【】を抜く前の run を後から埋めるため）")
t.eq(claude.first_prompt_brief(FIX .. "/agent_report.jsonl"),
  { purpose = "orders を拡張する", reason = "設計と実装を分けて並行で進めるため", expected = "orders.sql とテストが揃うこと" },
  "first_prompt_brief：子の transcript の最初の依頼文からも同じ brief")
t.eq(claude.first_prompt_brief(TMP .. "/none.jsonl"), nil, "first_prompt_brief：無いファイルは nil")
-- 別の返事の text は拾わない
local other = {}
for i, l in ipairs(pt_lines) do
  other[i] = (l:gsub('"id":"msg_C"', '"id":"msg_X"', 1))
  if l:find("toolu_Q", 1, true) and l:find('"tool_use"', 1, true) then other[i] = l end
end
local oidx = claude.agent_batches(TMP .. "/o.jsonl", nil)
write(TMP .. "/o.jsonl", other)
oidx = claude.agent_batches(TMP .. "/o.jsonl", nil)
t.eq(oidx.ask_lead.toolu_Q, nil, "直前の text が別の返事なら lead なし")

-- ---------- 5. backfill（transcript からの取り込み） ----------
local CDIR = TMP .. "/claude"
local base = CDIR .. "/projects/" .. SLUG
vim.fn.mkdir(base .. "/" .. SID .. "/subagents", "p")
write(base .. "/" .. SID .. ".jsonl", pt_lines)
write(base .. "/" .. SID .. "/subagents/agent-a2.jsonl", child_lines)
config.setup({ claude_config_dir = CDIR })
local evs = claude.backfill(SID, SLUG)
local ca = by_event(evs, "check_asked")
t.eq(#ca, 1, "backfill: check_asked 1 件")
t.eq(ca[1].tool_use_id, "toolu_Q", "check_asked の tool_use_id")
t.eq(ca[1].asker_id, "ROOT", "check_asked の asker")
t.eq(ca[1].lead, "子が要確認で止まったので聞きます", "check_asked に lead")
t.eq(ca[1].questions[1].header, "実装：dbt", "check_asked の questions")
local cans = by_event(evs, "check_answered")
t.eq(#cans, 1, "backfill: check_answered 1 件")
t.eq(cans[1].answers, { ["実装：dbt model について：テストはどこまで書きますか？"] = "単体のみ" }, "check_answered の answers")
local sr = by_event(evs, "agent_spawn_requested")
t.eq(sr[1].brief and sr[1].brief.expected, "orders.sql とテストが揃うこと", "spawn に brief（transcript の prompt 全文から）")
t.eq(sr[1].lead, "設計の確認が要るので実装を任せます", "spawn に lead")
t.eq(by_event(evs, "agent_linked")[1].brief.purpose, "orders を拡張する", "agent_linked に brief")
local fin
for _, e in ipairs(by_event(evs, "agent_finished")) do if e.agent_id == "a2" then fin = e end end
t.eq(fin and fin.report, REPORT_ASK, "子の agent_finished に report（handback）")
local tu = by_event(evs, "tool_used")
for _, e in ipairs(tu) do t.ok(e.tool_name ~= "AskUserQuestion", "AskUserQuestion は tool_used にしない") end
local bs = state.reduce(evs, SID)
local bc = bs.checks["check:toolu_Q"]
t.eq(bc and bc.status, "ANSWERED", "取り込んだ state：ANSWERED")
t.eq(bc and bc.agent_id, "a2", "取り込んだ state：a2 に結びつく")
t.eq(bs.agents.a2.brief_src, "transcript", "brief_src = transcript")
t.eq(bs.agents.a2.report_src, "transcript", "report_src = transcript")
t.eq(bs.agents.a2.lead, "設計の確認が要るので実装を任せます", "取り込んだ state：a2.lead")
t.eq(bs.agents.a2.ask.want, "テストはどこまで書きますか？", "取り込んだ state：a2.ask")

-- ---------- 6. enrich（後読み：lead・check.lead・report を 1 回だけ） ----------
t.run("enrich", function()
  local store = require("agentmap.store")
  local events = require("agentmap.events")
  local dir = store.run_dir(SLUG, SID)
  store.ensure(dir)
  local lines = {}
  for i, l in ipairs(HOOK_LINES) do
    local r = dec(l)
    if r.transcript_path then r.transcript_path = base .. "/" .. SID .. ".jsonl" end
    if r.agent_transcript_path then r.agent_transcript_path = base .. "/" .. SID .. "/subagents/agent-a2.jsonl" end
    r.report = nil -- 収集係が報告を同封できなかった場合
    if r.tool_input then r.tool_input.brief = nil end -- 収集係が【】を抜く前の版で記録された run
    if i <= 11 then lines[#lines + 1] = vim.json.encode(r) end -- SessionEnd の前まで
  end
  vim.fn.writefile(lines, dir .. "/hooks.jsonl")
  local run = events.load(dir)
  local s = run.state
  t.eq(s.agents.a2.report, nil, "hooks だけでは報告なし")
  t.eq(s.agents.a2.brief, nil, "hooks に brief が無ければ brief なし")
  t.eq(s.checks["check:toolu_Q"].link_source, "name", "報告が無くても名前（規則 1）で結びつく")
  events.enrich(run)
  t.eq(s.agents.a2.brief, { purpose = "orders を拡張する", reason = "設計と実装を分けて並行で進めるため", expected = "orders.sql とテストが揃うこと" },
    "enrich: brief を親の transcript の Agent 呼び出しから")
  t.eq(s.agents.a2.brief_src, "transcript", "enrich: brief_src = transcript")
  t.eq(s.agents.a2.lead, "設計の確認が要るので実装を任せます", "enrich: a2.lead")
  t.eq(s.checks["check:toolu_Q"].lead, "子が要確認で止まったので聞きます", "enrich: check.lead")
  t.eq(s.agents.a2.report, REPORT_ASK, "enrich: 報告を子の transcript から")
  t.eq(s.agents.a2.report_src, "transcript", "enrich: report_src = transcript")
  t.eq(s.agents.a2.ask and s.agents.a2.ask.want, "テストはどこまで書きますか？", "enrich: 報告から要確認を作る")
  t.eq(s.checks["check:toolu_Q"].agent_id, "a2", "結びつきはそのまま")
  local n1 = #vim.fn.readfile(dir .. "/events.jsonl")
  events.enrich(run)
  events.enrich(run)
  t.eq(#vim.fn.readfile(dir .. "/events.jsonl"), n1, "2 回目以降は何も書かない（1 回だけ）")
  local again = events.load(dir)
  t.eq(again.state.checks["check:toolu_Q"].lead, "子が要確認で止まったので聞きます", "記録に残る（開き直しても lead）")
  t.eq(again.state.agents.a2.brief and again.state.agents.a2.brief.purpose, "orders を拡張する", "記録に残る（開き直しても brief）")
end)

-- 親の transcript が読めない（Workflow の Agent など）ときは、子の transcript の最初の依頼文から brief
t.run("enrich: 子の transcript から brief", function()
  local store = require("agentmap.store")
  local events = require("agentmap.events")
  local SID2 = "ask00000-0000-0000-0000-000000000002"
  local dir = store.run_dir(SLUG, SID2)
  store.ensure(dir)
  vim.fn.mkdir(base .. "/" .. SID2 .. "/subagents", "p")
  write(base .. "/" .. SID2 .. "/subagents/agent-a2.jsonl", child_lines)
  local lines = {}
  for i, l in ipairs(HOOK_LINES) do
    local r = dec(l)
    r.session_id = SID2
    r.transcript_path = base .. "/missing-" .. SID2 .. ".jsonl" -- 親の transcript は無い
    if r.agent_transcript_path then r.agent_transcript_path = base .. "/" .. SID2 .. "/subagents/agent-a2.jsonl" end
    if r.tool_input then r.tool_input.brief = nil end
    if i <= 11 then lines[#lines + 1] = vim.json.encode(r) end
  end
  vim.fn.writefile(lines, dir .. "/hooks.jsonl")
  local run = events.load(dir)
  t.eq(run.state.agents.a2.brief, nil, "hooks だけでは brief なし")
  events.enrich(run)
  t.eq(run.state.agents.a2.brief, { purpose = "orders を拡張する", reason = "設計と実装を分けて並行で進めるため", expected = "orders.sql とテストが揃うこと" },
    "enrich: 親の transcript が無ければ子の transcript から brief")
  t.eq(run.state.agents.a2.lead, nil, "親の transcript が無いので lead は無いまま（推測しない）")
  local n1 = #vim.fn.readfile(dir .. "/events.jsonl")
  events.enrich(run)
  t.eq(#vim.fn.readfile(dir .. "/events.jsonl"), n1, "子の transcript を読むのは 1 回だけ")
end)

vim.fn.delete(TMP, "rf")
-- ---------- 手順表（Task ツール）と修正指示の配達の記録（v0.2.0） ----------
do
  local base = { session_id = SID, prompt_id = "pv2", _ts = "2026-10-04T09:00:00.000Z", _src = "claude_hook", _v = 1 }
  local function rec(t2) return vim.tbl_extend("force", base, t2) end
  local tc = claude.normalize_hook(rec({ hook_event_name = "PostToolUse", tool_name = "TaskCreate", tool_use_id = "tc",
    tool_input = { subject = "alpha", activeForm = "Doing alpha" }, tool_response = { task = { id = "1", subject = "alpha" } } }))
  t.eq(#tc, 2, "TaskCreate → tool_used + task_created")
  t.eq(tc[1].event, "tool_used", "TaskCreate is also counted as a tool")
  t.eq({ tc[2].event, tc[2].agent_id, tc[2].task_id, tc[2].subject, tc[2].active_form, tc[2].prompt_id },
    { "task_created", "ROOT", "1", "alpha", "Doing alpha", "pv2" }, "task_created fields (ROOT when no agent_id)")
  local nid = claude.normalize_hook(rec({ hook_event_name = "PostToolUse", tool_name = "TaskCreate", tool_use_id = "tc2",
    tool_input = { subject = "x" } }))
  t.eq(#nid, 1, "TaskCreate without task.id → tool_used only")
  local tu = claude.normalize_hook(rec({ hook_event_name = "PostToolUse", tool_name = "TaskUpdate", agent_id = "akid", tool_use_id = "tu",
    tool_input = { taskId = "1", status = "completed" }, tool_response = { taskId = "1", statusChange = { from = "in_progress", to = "completed" } } }))
  t.eq({ tu[2] and tu[2].event, tu[2] and tu[2].agent_id, tu[2] and tu[2].status_from, tu[2] and tu[2].status_to },
    { "task_updated", "akid", "in_progress", "completed" }, "task_updated (agent_id of a sub-agent kept)")
  t.eq(#claude.normalize_hook(rec({ hook_event_name = "PostToolUse", tool_name = "TaskUpdate", tool_use_id = "tu2",
    tool_input = { taskId = "2" } })), 1, "TaskUpdate without statusChange → tool_used only")
  local tl = claude.normalize_hook(rec({ hook_event_name = "PostToolUse", tool_name = "TaskList", tool_use_id = "tl",
    tool_input = {}, tool_response = { tasks = { { id = "1", subject = "alpha", status = "completed" }, { id = 2, status = "pending" } } } }))
  t.eq(tl[2] and tl[2].tasks, { { id = "1", subject = "alpha", status = "completed" }, { id = "2", status = "pending" } }, "task_listed tasks (ids as strings)")
  local sv = claude.normalize_hook(rec({ hook_event_name = "PreToolUse", tool_name = "Write", tool_use_id = "tw", agent_id = "akid",
    steer = { ids = { "akid-1", "akid-2" }, mode = "deny", target = "akid" } }))
  t.eq(#sv, 2, "steer line → one steer_delivered per id, nothing else")
  t.eq({ sv[1].event, sv[1].steer_id, sv[1].agent_id, sv[1].via, sv[1].tool_use_id, sv[1].mode, sv[1].src },
    { "steer_delivered", "akid-1", "akid", "PreToolUse:Write", "tw", "deny", "hook" }, "steer_delivered fields")
  local ss = claude.normalize_hook(rec({ hook_event_name = "SubagentStop", agent_id = "akid", steer = { ids = { "akid-3" }, mode = "block", target = "akid" } }))
  t.eq({ #ss, ss[1].event, ss[1].via }, { 1, "steer_delivered", "SubagentStop" }, "steer line on SubagentStop is not an agent_finished")
end

t.done()
