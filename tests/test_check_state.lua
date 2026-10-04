-- ============================================================
--  test_check_state.lua … HUMAN CHECK（AskUserQuestion）と「任せた理由・報告」の記録の積み上げ（state.lua）
--    hooks_ask.jsonl を normalize → reduce して、check の状態・番号・子との結びつけ・
--    答えないまま終わったときの扱い・流れごとの写し・state.json の作り直しを確かめる
--  実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_check_state.lua
-- ============================================================
local t = require("t")
local state = require("agentmap.state")
local claude = require("agentmap.providers.claude")

local FIX = vim.g.agentmap_test_dir .. "/fixtures"
local P1 = "a5c00000-0000-0000-0000-000000000001"
local P2 = "a5c00000-0000-0000-0000-000000000002" -- task_notification（P1 の続き）
local CID = "check:toolu_Q"

local function read_hooks(n)
  local out = {}
  for i, line in ipairs(vim.fn.readfile(FIX .. "/hooks_ask.jsonl")) do
    if n and i > n then break end
    out[#out + 1] = vim.json.decode(line, { luanil = { object = true, array = true } })
  end
  return out
end
local HOOKS = read_hooks()

local function norm(recs)
  local evs = {}
  for _, r in ipairs(recs) do vim.list_extend(evs, claude.normalize_hook(r)) end
  return evs
end
local function reduce_lines(list) return state.reduce(norm(list)) end
local function first(n) return vim.list_slice(HOOKS, 1, n) end
local function rec(base, patch, drop)
  local r = vim.deepcopy(base)
  for k, v in pairs(patch) do r[k] = v end
  for _, k in ipairs(drop or {}) do r[k] = nil end
  return r
end

-- ---------- 1. 全部流す：質問 → 答え。子 [a2] の要確認に名前で結びつく ----------
local s = reduce_lines(HOOKS)
local c = s.checks[CID]
t.ok(c ~= nil, "check が 1 つできる")
t.eq(s.check_order, { CID }, "check_order")
t.eq(c.status, "ANSWERED", "答えが出たら ANSWERED")
t.eq(c.n, 1, "通し番号 n = 1")
t.eq(c.asker_id, "ROOT", "聞いた側 = ROOT")
t.eq(c.agent_id, "a2", "要確認を書いた子 a2 に結びつく")
t.eq(c.owner_id, "a2", "箱は a2 の後ろ")
t.eq(c.link_source, "name", "結びつけの根拠 = 名前（question に description が入っている）")
t.eq(c.prompt_id, P1, "お知らせ（task_notification）の流れは元の指示に読み替える")
t.eq(c.asked_at, "2026-10-01T10:00:10.000Z", "asked_at")
t.eq(c.answered_at, "2026-10-01T10:00:12.000Z", "answered_at")
t.eq(c.answers, { ["実装：dbt model について：テストはどこまで書きますか？"] = "単体のみ" }, "answers")
t.eq(c.questions[1].header, "実装：dbt", "header")
t.eq(c.questions[1].multi, false, "multiSelect → multi")
t.eq(#c.questions[1].options, 2, "options 2 つ")
t.eq(c.questions[1].options[1], { label = "単体のみ", description = "モデル単位のテストだけ → 選んだら: tests/ に追加して終了" }, "option の形")
local a2 = s.agents.a2
t.eq(a2.ask_check, CID, "a2.ask_check")
t.eq(a2.checks, { CID }, "a2.checks")
t.eq(s.agents.ROOT.checks or {}, {}, "ROOT には付かない（子に付け替えた）")
t.eq(a2.brief, { purpose = "orders を拡張する", reason = "設計と実装を分けて並行で進めるため", expected = "orders.sql とテストが揃うこと" }, "a2.brief（spawn から）")
t.eq(a2.brief_src, "hook", "brief_src = hook")
t.eq(a2.report_src, "hook", "report_src = hook（SubagentStop に同封）")
t.matches(a2.report, "^## 要確認", "a2.report")
t.eq(a2.report_fields, nil, "要確認のときは report_fields なし")
t.eq(a2.ask.want, "テストはどこまで書きますか？", "a2.ask.want")
t.eq(a2.ask.working, "orders.sql の拡張", "a2.ask.working")
t.eq(a2.ask.stuck, "テストの範囲が決まらない", "a2.ask.stuck")
t.eq(a2.ask.options, { { n = 1, name = "単体のみ", next = "tests/ に追加して終了" }, { n = 2, name = "結合まで", next = "seed を作ってから実装" } }, "a2.ask.options")
t.eq(a2.ask.raw, a2.report, "ask.raw = 原文")
t.eq(s.agents.ROOT.tool_counts.AskUserQuestion, nil, "AskUserQuestion はツール回数に数えない")
t.eq(s.counts.checks, 1, "counts.checks")
t.eq(s.counts.waiting, 0, "counts.waiting = 0")
t.eq(a2.status, "DONE", "要確認で止まった子の状態は DONE のまま")

-- fixture（state_check.lua）と同じ形：check のフィールド名がその中に収まる
local KNOWN = { id = 1, tool_use_id = 1, asker_id = 1, agent_id = 1, owner_id = 1, link_source = 1, prompt_id = 1,
  status = 1, asked_at = 1, answered_at = 1, ended_at = 1, end_reason = 1, questions = 1, answers = 1, lead = 1, n = 1,
  error_head = 1 }
local extra = {}
for k in pairs(c) do if not KNOWN[k] then extra[#extra + 1] = k end end
t.eq(extra, {}, "check のフィールドは設計書 §3.2 のものだけ")
local fx = dofile(FIX .. "/state_check.lua")
local function keys(x) local o = {} for k in pairs(x) do o[#o + 1] = k end table.sort(o) return o end
t.eq(keys(c.questions[1]), keys(fx.checks[CID].questions[1]), "question の形が fixture と同じ")
t.eq(keys(a2.ask), keys(fx.agents.a2.ask), "a2.ask の形が fixture と同じ")

-- ---------- 2. 9 行目まで（質問を出したところ）：WAITING ----------
local s9 = reduce_lines(first(9))
t.eq(s9.checks[CID].status, "WAITING", "質問だけ → WAITING")
t.eq(s9.counts.waiting, 1, "counts.waiting = 1")
t.eq(state.flow_of(s9, P1).waiting, 1, "流れごとの waiting")
t.eq(s9.checks[CID].answers, nil, "答えはまだ無い")

-- ---------- 3. 答えないまま終わる ----------
local function seq(list)
  local st = state.new("sid")
  for _, ev in ipairs(norm(list)) do state.apply(st, ev) end
  return st
end
local stop = HOOKS[11]
local s_stop = seq(vim.list_extend(first(9), { stop }))
t.eq(s_stop.checks[CID].status, "ABANDONED", "Stop で ABANDONED")
t.eq(s_stop.checks[CID].end_reason, "turn_ended", "end_reason = turn_ended")
t.eq(s_stop.checks[CID].ended_at, stop._ts, "ended_at = Stop の時刻")
t.eq(s_stop.counts.waiting, 0, "答え待ちは 0")

local newp = rec(HOOKS[2], { prompt_id = "a5c00000-0000-0000-0000-00000000000f", prompt_head = "別のことをして", _ts = "2026-10-01T10:00:20.000Z" })
local s_new = seq(vim.list_extend(first(9), { newp }))
t.eq(s_new.checks[CID].status, "ABANDONED", "新しい指示で ABANDONED")
t.eq(s_new.checks[CID].end_reason, "new_prompt", "end_reason = new_prompt")

local note = rec(HOOKS[8], { prompt_id = "a5c00000-0000-0000-0000-0000000000ee", _ts = "2026-10-01T10:00:11.000Z" })
local s_note = seq(vim.list_extend(first(9), { note }))
t.eq(s_note.checks[CID].status, "WAITING", "お知らせ（task_notification）では閉じない")

local s_end = seq(vim.list_extend(first(9), { HOOKS[12] }))
t.eq(s_end.checks[CID].status, "ABANDONED", "SessionEnd で ABANDONED")
t.eq(s_end.checks[CID].end_reason, "session_ended", "end_reason = session_ended")

local fail = { session_id = HOOKS[1].session_id, hook_event_name = "PostToolUseFailure", tool_name = "AskUserQuestion",
  tool_use_id = "toolu_Q", error_head = "User rejected", prompt_id = P2, _ts = "2026-10-01T10:00:11.000Z" }
local s_fail = seq(vim.list_extend(first(9), { fail }))
t.eq(s_fail.checks[CID].status, "ABANDONED", "ツール失敗で ABANDONED")
t.eq(s_fail.checks[CID].end_reason, "tool_failed", "end_reason = tool_failed")
t.eq(s_fail.checks[CID].error_head, "User rejected", "失敗の理由")

-- 答え優先：ABANDONED の後に答えが届いたら ANSWERED
local late_ans = rec(HOOKS[10], { _ts = "2026-10-01T10:00:13.500Z" })
local s_late = seq(vim.list_extend(first(9), { stop, late_ans }))
t.eq(s_late.checks[CID].status, "ANSWERED", "ABANDONED の後に答え → ANSWERED")
t.eq(s_late.checks[CID].end_reason, nil, "終わりの理由は消える")

-- 逆順：答えが質問より先に届いた
local s_rev = seq(vim.list_extend(first(8), { HOOKS[10], HOOKS[9] }))
local cr = s_rev.checks[CID]
t.eq(cr.status, "ANSWERED", "逆順でも ANSWERED のまま")
t.eq(cr.asked_at, HOOKS[9]._ts, "後から来た質問で asked_at を埋める")
t.eq(cr.agent_id, "a2", "逆順でも a2 に結びつく")
t.eq(#s_rev.check_order, 1, "check は 1 つだけ")

-- ---------- 4. 結びつけの規則 ----------
local function with_question(q, header)
  local list = first(8)
  local pre = vim.deepcopy(HOOKS[9])
  pre.tool_input.questions[1].question = q
  pre.tool_input.questions[1].header = header
  list[#list + 1] = pre
  return list
end
-- 規則 2：名前は無いが、子の報告に「## 要確認」がある
local s_r2 = reduce_lines(with_question("テストはどこまで書きますか？", "テスト"))
t.eq(s_r2.checks[CID].agent_id, "a2", "規則 2：名前なしでも要確認の子に結びつく")
t.eq(s_r2.checks[CID].link_source, "report", "link_source = report")

-- 候補なし：子の報告が普通の「## 報告」で、名前も無い → 聞いた側が直接聞いた質問
local list = with_question("どちらの設計にしますか？", "設計")
list[7] = rec(list[7], { report = "## 報告\n- やったこと: x\n- 方向: y\n- 理由: z\n- 残った課題: なし" })
local s_direct = reduce_lines(list)
local cd = s_direct.checks[CID]
t.eq(cd.agent_id, nil, "候補なし → agent_id = nil")
t.eq(cd.owner_id, "ROOT", "owner = ROOT")
t.eq(cd.link_source, nil, "link_source = nil")
t.eq(s_direct.agents.ROOT.checks, { CID }, "ROOT.checks に入る")
t.eq(s_direct.agents.a2.report_fields, { done = "x", direction = "y", reason = "z", issues = "なし" }, "## 報告 → report_fields")
t.eq(s_direct.agents.a2.ask, nil, "## 報告のときは ask なし")

-- 子がまだ動いている（質問より後に終わる）→ 候補にしない
list = with_question("実装：dbt model について：テストは？", "実装：dbt")
table.remove(list, 7) -- SubagentStop を消す
list[#list + 1] = rec(HOOKS[7], { _ts = "2026-10-01T10:00:20.000Z" })
local s_run = reduce_lines(list)
t.eq(s_run.checks[CID].agent_id, nil, "質問より後に終わった子には結びつけない")

-- 後付け：報告（要確認）が質問より後に transcript から届いた
list = with_question("テストはどこまで書きますか？", "テスト")
list[7] = rec(list[7], {}, { "report" })
local s_lt = seq(list)
t.eq(s_lt.checks[CID].agent_id, nil, "報告が届く前は結びつかない")
state.apply(s_lt, { event = "agent_updated", agent_id = "a2", report = HOOKS[7].report, src = "system", ts = "2026-10-01T10:00:11.000Z" })
t.eq(s_lt.checks[CID].agent_id, "a2", "後から届いた要確認で結びつく")
t.eq(s_lt.checks[CID].link_source, "report_late", "link_source = report_late")
t.eq(s_lt.checks[CID].owner_id, "a2", "箱は a2 に移る")
t.eq(s_lt.agents.ROOT.checks, {}, "ROOT の一覧から外れる")
t.eq(s_lt.agents.a2.report_src, "transcript", "後読みの report_src = transcript")
-- hooks の報告は後読みの報告で上書きしない
state.apply(s, { event = "agent_updated", agent_id = "a2", report = "## 報告\n- やったこと: 別", src = "system" })
t.matches(s.agents.a2.report, "^## 要確認", "agent_updated は空欄のときだけ報告を埋める")

-- ---------- 4b. 差し戻しの後にもう一度「## 要確認」→ 新しい質問と結びつけ直す（前の check はそのまま） ----------
local ASK2 = "## 要確認\n- 今の作業: テストの追加\n- 止まっている所: seed が無い\n- 確認したいこと: seed を作りますか？\n- 選択肢:\n  1. 作る → seeds/ に追加\n  2. 作らない → 既存の表で代用"
local function rerun(report2)
  local list = first(10) -- 質問 1 に答えが出たところまで
  list[#list + 1] = rec(HOOKS[6], { tool_use_id = "toolu_W2", _ts = "2026-10-01T10:00:15.000Z" }) -- a2 がまた動く（再実行）
  list[#list + 1] = rec(HOOKS[7], { report = report2, _ts = "2026-10-01T10:00:18.000Z" }) -- もう一度終わる
  local q2 = vim.deepcopy(HOOKS[9])
  q2.tool_use_id, q2._ts = "toolu_Q2", "2026-10-01T10:00:20.000Z"
  q2.tool_input.questions[1].question = "実装：dbt model について：seed を作りますか？"
  list[#list + 1] = q2
  return seq(list)
end
local s_re = rerun(ASK2)
local a2r = s_re.agents.a2
t.eq(a2r.attempt, 2, "再実行で 2 回目")
t.eq(a2r.ask and a2r.ask.want, "seed を作りますか？", "新しい要確認が report から作られる")
t.eq(a2r.ask_check, "check:toolu_Q2", "新しい要確認は新しい質問と結びつく")
t.eq(s_re.checks["check:toolu_Q2"].agent_id, "a2", "質問 2 の agent_id = a2")
t.eq(s_re.checks["check:toolu_Q2"].link_source, "name", "質問 2 も名前で結びつく")
t.eq(s_re.checks["check:toolu_Q2"].owner_id, "a2", "質問 2 の箱は a2 の後ろ")
t.eq(s_re.checks["check:toolu_Q2"].status, "WAITING", "質問 2 は答え待ち")
t.eq(a2r.checks, { CID, "check:toolu_Q2" }, "a2.checks に両方（出てきた順）")
t.eq(s_re.checks[CID].agent_id, "a2", "前の check はそのまま a2 に結びついている")
t.eq(s_re.checks[CID].status, "ANSWERED", "前の check は答え済みのまま")
t.eq(s_re.agents.ROOT.checks or {}, {}, "質問 2 が ROOT の直接の箱にならない")
t.eq(s_re.counts.waiting, 1, "答え待ち 1")
t.eq({ s_re.checks[CID].n, s_re.checks["check:toolu_Q2"].n }, { 1, 2 }, "通し番号は聞いた順")
-- 再実行の後が普通の「## 報告」なら、要確認は消え、前の質問との結びつけ（ask_check）も外れる
local s_ok = rerun("## 報告\n- やったこと: seed を作った\n- 方向: 結合まで\n- 理由: 指示どおり\n- 残った課題: なし")
t.eq(s_ok.agents.a2.ask, nil, "報告に変わったら要確認なし")
t.eq(s_ok.agents.a2.report_fields and s_ok.agents.a2.report_fields.done, "seed を作った", "報告の 4 項目")
t.ok(s_ok.agents.a2.ask_check ~= CID, "前の質問（#1）との結びつけは外れる")
t.eq(s_ok.checks[CID].agent_id, "a2", "前の check 自体は残る")
t.eq(s_ok.checks["check:toolu_Q2"].agent_id, "a2", "質問文に名前があれば規則 1 で結びつく（結びつけが外れているので候補になる）")
t.eq(s_ok.agents.a2.ask_check, "check:toolu_Q2", "結びつけ先は新しい質問")

-- ---------- 5. 任せた理由・直前の発言 ----------
local s_sp = reduce_lines(first(3))
local ph = s_sp.agents["pending:toolu_A"]
t.eq(ph and ph.brief and ph.brief.purpose, "orders を拡張する", "起動依頼だけの仮の箱にも brief")
local s_ad = reduce_lines(first(5))
t.eq(s_ad.agents.a2.brief.expected, "orders.sql とテストが揃うこと", "本物に取り込んでも brief が残る")
state.apply(s_ad, { event = "agent_updated", agent_id = "a2", lead = "設計の確認が要るので実装を任せます", src = "system" })
t.eq(s_ad.agents.a2.lead, "設計の確認が要るので実装を任せます", "agent_updated で lead")
state.apply(s, { event = "check_updated", tool_use_id = "toolu_Q", lead = "子が要確認で止まったので聞きます" })
t.eq(s.checks[CID].lead, "子が要確認で止まったので聞きます", "check_updated で lead")
state.apply(s, { event = "check_updated", tool_use_id = "toolu_Q", lead = "別" })
t.eq(s.checks[CID].lead, "子が要確認で止まったので聞きます", "lead は空欄のときだけ")

-- ---------- 6. 番号・流れごとの写し・checks_of ----------
local function ask(tuid, ts, pid, q)
  return { session_id = "sid", hook_event_name = "PreToolUse", tool_name = "AskUserQuestion", tool_use_id = tuid,
    prompt_id = pid, _ts = ts, tool_input = { questions = { { question = q or ("Q " .. tuid), header = "H", options = {} } } } }
end
local function prompt(pid, ts, head)
  return { session_id = "sid", hook_event_name = "UserPromptSubmit", prompt_id = pid, prompt_head = head, _ts = ts }
end
local function ans(tuid, ts, pid)
  return { session_id = "sid", hook_event_name = "PostToolUse", tool_name = "AskUserQuestion", tool_use_id = tuid,
    prompt_id = pid, _ts = ts, tool_response = { answers = { ["Q " .. tuid] = { "A", "B" } } } }
end
local recs = {
  prompt("pA", "2026-10-01T11:00:00.000Z", "指示 A"),
  ask("t2", "2026-10-01T11:00:05.000Z", "pA"),
  ask("t1", "2026-10-01T11:00:03.000Z", "pA"),
  ans("t1", "2026-10-01T11:00:04.000Z", "pA"),
  ans("t2", "2026-10-01T11:00:06.000Z", "pA"),
  prompt("pB", "2026-10-01T11:01:00.000Z", "指示 B"),
  ask("t3", "2026-10-01T11:01:05.000Z", "pB"),
}
local sf = seq(recs) -- 届いた順（時刻の順ではない）に積む：check_order は届いた順、n と checks_of は聞いた時刻の順
t.eq({ sf.checks["check:t1"].n, sf.checks["check:t2"].n, sf.checks["check:t3"].n }, { 1, 2, 1 }, "n は流れごとに聞いた順で 1 から")
t.eq(sf.checks["check:t2"].answers["Q t2"], { "A", "B" }, "配列の答えもそのまま持つ")
t.eq(state.checks_of(sf, "ROOT"), { "check:t1", "check:t2", "check:t3" }, "checks_of は聞いた順")
t.eq(state.check_of(sf, "check:t3").status, "WAITING", "check_of")
t.eq(state.check_of(sf, "check:none"), nil, "check_of（無い id）")
t.eq(state.flow_of(sf, "pA").waiting, 0, "流れ A の答え待ち 0")
t.eq(state.flow_of(sf, "pB").waiting, 1, "流れ B の答え待ち 1")
local va = state.flow_view(sf, "pA")
t.eq(va.check_order, { "check:t2", "check:t1" }, "flow_view は流れの check だけ写す（届いた順のまま）")
t.eq(va.checks["check:t3"], nil, "他の流れの check は写さない")
t.eq(va.agents.ROOT.checks, { "check:t2", "check:t1" }, "写しの ROOT.checks も流れの分だけ")
t.eq(state.checks_of(va, "ROOT"), { "check:t1", "check:t2" }, "写しでも checks_of は聞いた順")
t.eq(va.counts.checks, 2, "写しの counts.checks")
local vb = state.flow_view(sf, "pB")
t.eq(vb.check_order, { "check:t3" }, "流れ B の写し")
t.eq(vb.counts.waiting, 1, "写しの counts.waiting")
t.eq(sf.agents.ROOT.checks, { "check:t2", "check:t1", "check:t3" }, "元の state は変えない（出てきた順のまま）")
-- 流れ A の質問は、流れ B の指示が来たときにはもう答え済みなので閉じない
t.eq(sf.checks["check:t1"].status, "ANSWERED", "答え済みは新しい指示でも ANSWERED のまま")

-- 流れの中の子に結びついた check は、写しでもその子に付く
local s_fv = reduce_lines(HOOKS)
local v1 = state.flow_view(s_fv, P1)
t.eq(v1.check_order, { CID }, "hooks_ask の流れに check が入る")
t.eq(v1.checks[CID].owner_id, "a2", "写しでも owner = a2")
t.eq(v1.agents.a2.checks, { CID }, "写しの a2.checks")

-- ---------- 7. state.json の作り直し（SV = 9） ----------
t.eq(state.SV, 9, "SV = 9")
t.eq(state.CHECK_STATUSES, { "WAITING", "ANSWERED", "ABANDONED" }, "CHECK_STATUSES")
t.eq(state.new("x").checks, {}, "new に checks")
t.eq(state.new("x").check_order, {}, "new に check_order")
t.run("events.load が古い state.json を捨てる", function()
  local store = require("agentmap.store")
  local events = require("agentmap.events")
  local dir = store.run_dir("-tmp-agentmap-test-ask", "ask00000-0000-0000-0000-000000000001")
  store.ensure(dir)
  vim.fn.writefile(vim.fn.readfile(FIX .. "/hooks_ask.jsonl"), dir .. "/hooks.jsonl")
  local h = store.size(dir, "hooks.jsonl")
  -- SV 7 の控え（中身は空っぽ）。大きさは一致しているが版が古い → 作り直す
  store.write_state(dir, { v = 1, sv = 7, run_id = "old", agents = { ROOT = { id = "ROOT" } }, order = { "ROOT" },
    _off = { hooks = h, events = 0 } })
  local run = events.load(dir)
  t.eq(run.state.sv, 9, "作り直した state は SV 9")
  t.ok(run.state.checks[CID] ~= nil, "作り直した state に check がある")
  t.eq(run.state.checks[CID].status, "ANSWERED", "作り直した check は ANSWERED")
  local again = events.load(dir)
  t.eq(again.state.checks[CID].agent_id, "a2", "控え（SV 9）から読み直しても同じ")
end)


-- ---------- 子を裏で動かす形：親の Stop が質問より先に来る。答え待ちの間は流れを終わりにしない ----------
t.run("background child: WAITING keeps the flow running", function()
  local graph = require("agentmap.graph")
  local stop1 = rec(HOOKS[11], { prompt_id = P1, _ts = "2026-10-01T10:00:05.000Z" })
  local list = vim.list_slice(HOOKS, 1, 5)
  list[#list + 1] = stop1
  vim.list_extend(list, vim.list_slice(HOOKS, 6, 9)) -- 子の要確認 → お知らせ → 親が質問（まだ答えていない）
  local sw = reduce_lines(list)
  t.eq(sw.checks[CID].status, "WAITING", "質問は答え待ち")
  t.eq(sw.flows[1].status, "RUNNING", "答え待ちがある流れは RUNNING（親の Stop が先に来ていても）")
  local v = state.flow_view(sw, P1)
  t.eq(v.agents.ROOT.status, "RUNNING", "流れの ROOT は DONE にしない")
  t.eq(v.ended_at, nil, "流れの終わりの時刻を付けない")
  t.eq(graph.end_status(v), "PENDING", "END は DONE にしない")
  t.eq(graph.waiting_count(v), 1, "答え待ち 1")
  -- 答えが出て、親の番が終わったら DONE に戻る
  vim.list_extend(list, vim.list_slice(HOOKS, 10, 11))
  local sd = reduce_lines(list)
  t.eq(sd.checks[CID].status, "ANSWERED", "答えが出た")
  t.eq(sd.flows[1].status, "DONE", "答えが出て Stop が来たら DONE")
  t.eq(state.flow_view(sd, P1).agents.ROOT.status, "DONE", "ROOT も DONE")
end)

t.done()
