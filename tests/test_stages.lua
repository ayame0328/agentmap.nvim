-- 段分け（stages.lua）の試験：時刻だけで「同時に動いた Agent は同じ段、全員が終わってから始まった Agent は次の段」
--   実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_stages.lua
local t = require("t")
local stages = require("agentmap.stages")

local function T(n) return string.format("2026-09-29T10:%02d:%02d.000Z", math.floor(n / 60), n % 60) end
local function ag(id, st, fin, status, extra)
  local a = { id = id, status = status or (fin and "DONE" or "RUNNING"), started_at = st and T(st) or nil,
    finished_at = fin and T(fin) or nil, attempts = {} }
  if st or fin then a.attempts[1] = { n = 1, started_at = a.started_at, finished_at = a.finished_at } end
  for k, v in pairs(extra or {}) do a[k] = v end
  return a
end
local function of(list)
  local s = { agents = {} }
  local ids = {}
  for _, a in ipairs(list) do
    s.agents[a.id] = a
    ids[#ids + 1] = a.id
  end
  return stages.of(s, ids)
end

-- 1. 順番に 3 つ（重ならない）→ 3 段
t.eq(of({ ag("a", 0, 10), ag("b", 11, 20), ag("c", 21, 30) }), { { "a" }, { "b" }, { "c" } }, "順番に 3 つ → 3 段")

-- 2. 同時に始まった 3 つ → 1 段
t.eq(of({ ag("a", 5, 10), ag("b", 5, 12), ag("c", 5, 30) }), { { "a", "b", "c" } }, "同時開始 → 1 段")

-- 3. 重なり（b は a が終わる前に始まる）→ 同じ段。c は全員の終わり（b の 20）より後 → 次の段
t.eq(of({ ag("a", 0, 10), ag("b", 5, 20), ag("c", 21, 30) }), { { "a", "b" }, { "c" } }, "重なり → 同じ段")
-- a より遅く b より早く終わった後に始まる c も、b が動いている間なら同じ段
t.eq(of({ ag("a", 0, 10), ag("b", 5, 20), ag("c", 15, 30) }), { { "a", "b", "c" } }, "前の段の誰かが動いている間は同じ段")

-- 4. 動いている子（終了なし）がいる段は閉じない
t.eq(of({ ag("a", 0, 10), ag("b", 5, nil, "RUNNING"), ag("c", 100, 110) }), { { "a", "b", "c" } },
  "RUNNING の子がいる段は開いたまま")

-- 5. 開始 == 前の段の最後の終了 → 新しい段（>=）
t.eq(of({ ag("a", 0, 10), ag("b", 10, 20) }), { { "a" }, { "b" } }, "開始が前の終了ちょうど → 次の段")

-- 6. 依頼だけ出た仮の箱（requested_at だけ）は開いたまま
local ph = { id = "p", status = "PENDING", requested_at = T(3), attempts = {} }
t.eq(of({ ag("a", 0, 10), ph, ag("c", 50, 60) }), { { "a", "p", "c" } }, "依頼だけの仮の箱は段を開いたままにする")

-- 7. 時刻の無い子は最後の段の後ろ
t.eq(of({ ag("a", 0, 10), { id = "x", status = "DONE", attempts = {} }, ag("b", 20, 30) }),
  { { "a" }, { "b", "x" } }, "時刻の無い子は最後の段へ")
t.eq(of({ { id = "x", status = "DONE", attempts = {} }, { id = "y", status = "DONE", attempts = {} } }),
  { { "x", "y" } }, "時刻が全部無い → 1 段（今までどおり）")

-- 8. 差し戻し：2 回目の実行が後で始まっても、1 回目の時刻の段に残る
local rw = ag("a", 0, 10, "RUNNING")
rw.attempts[2] = { n = 2, started_at = T(40) }
rw.finished_at = nil
t.eq(of({ rw, ag("b", 12, 20) }), { { "a" }, { "b" } }, "差し戻しの再実行は 1 回目の段のまま")

-- 9. 順番は開始順。同じ開始なら元の並び
t.eq(of({ ag("c", 21, 30), ag("a", 0, 10), ag("b", 0, 10) }), { { "a", "b" }, { "c" } }, "開始順に並べる")

-- 10. 子が無い → 段も無い
t.eq(of({}), {}, "子が無い → 空")

-- 11. ミリ秒まで見る（graph の H.parse_iso は秒で切っていた）
local s = { agents = {
  a = { id = "a", status = "DONE", attempts = { { started_at = "2026-09-29T10:00:00.100Z", finished_at = "2026-09-29T10:00:05.900Z" } } },
  b = { id = "b", status = "DONE", attempts = { { started_at = "2026-09-29T10:00:05.500Z", finished_at = "2026-09-29T10:00:09.000Z" } } },
} }
t.eq(stages.of(s, { "a", "b" }), { { "a", "b" } }, "ミリ秒の重なりも同じ段")

-- 12. 同じ 1 通の返事で起動された子（batch が同じ）は、時刻が重ならなくても同じ段
--   本物の例（2026-09-29 の試し起動）：A は B が始まる前に終わった。時刻だけだと A | B,C に割れる
t.eq(of({ ag("A", 0, 1), ag("B", 2, 30), ag("C", 3, 40) }), { { "A" }, { "B", "C" } }, "batch 無し → 時刻どおり割れる")
t.eq(of({ ag("A", 0, 1, nil, { batch = "msg_1" }), ag("B", 2, 30, nil, { batch = "msg_1" }),
  ag("C", 3, 40, nil, { batch = "msg_1" }) }), { { "A", "B", "C" } }, "同じ batch → 1 段")
-- 次の 1 通（別の batch）は、前の塊が全部終わってから始まれば次の段
t.eq(of({ ag("A", 0, 1, nil, { batch = "m1" }), ag("B", 2, 30, nil, { batch = "m1" }), ag("D", 31, 40, nil, { batch = "m2" }),
  ag("E", 41, 50, nil, { batch = "m2" }) }), { { "A", "B" }, { "D", "E" } }, "別の batch は時刻の決まりで次の段")
-- batch の塊の終わり（最も遅い終了）より前に始まった子は同じ段
t.eq(of({ ag("A", 0, 1, nil, { batch = "m1" }), ag("B", 2, 30, nil, { batch = "m1" }), ag("X", 10, 12) }),
  { { "A", "B", "X" } }, "塊が動いている間に始まった子は同じ段")
-- 仲間が動いている（終了なし）なら塊は開いたまま
t.eq(of({ ag("A", 0, 1, nil, { batch = "m1" }), ag("B", 2, nil, "RUNNING", { batch = "m1" }), ag("Y", 100, 110) }),
  { { "A", "B", "Y" } }, "塊の中に RUNNING → 開いたまま")
-- 時刻の無い仲間は、仲間のいる段へ（最後の段ではなく）
t.eq(of({ ag("A", 0, 1, nil, { batch = "m1" }), { id = "Z", status = "DONE", attempts = {}, batch = "m1" }, ag("B", 20, 30) }),
  { { "A", "Z" }, { "B" } }, "時刻の無い仲間は仲間の段へ")

-- 13. 記録から通しで（2026-09-29 の本物の試し起動と同じ順番・同じ形）。batch は起動依頼の記録に付く
--   （transcript から取り込むときは scan_transcript が付ける。hooks の run は 14 の enrich で後から付く）
--   PreToolUse(A) → SubagentStart(A) → PostToolUse(A, 背景起動) → … → SubagentStop(A) が B の開始より前
do
  local state = require("agentmap.state")
  local claude = require("agentmap.providers.claude")
  local function U(ms) return string.format("2026-09-29T03:31:%06.3fZ", ms / 1000) end
  local function run(with_batch)
    local recs = { { hook_event_name = "SessionStart", session_id = "S", _ts = U(25000), cwd = "/w" },
      { hook_event_name = "UserPromptSubmit", session_id = "S", prompt_id = "P", _ts = U(27000), prompt_head = "go" } }
    local function spawn(tu, aid, t0, desc)
      recs[#recs + 1] = { hook_event_name = "PreToolUse", session_id = "S", prompt_id = "P", _ts = U(t0),
        tool_name = "Agent", tool_use_id = tu, tool_input = { description = desc } }
      recs[#recs + 1] = { hook_event_name = "SubagentStart", session_id = "S", prompt_id = "P", _ts = U(t0 + 10),
        agent_id = aid, agent_type = "general-purpose" }
      recs[#recs + 1] = { hook_event_name = "PostToolUse", session_id = "S", prompt_id = "P", _ts = U(t0 + 20),
        tool_name = "Agent", tool_use_id = tu, tool_response = { agentId = aid, status = "async_launched", isAsync = true } }
    end
    spawn("tuA", "aA", 30000, "probe A")
    recs[#recs + 1] = { hook_event_name = "SubagentStop", session_id = "S", prompt_id = "P", _ts = U(30400), agent_id = "aA" }
    spawn("tuB", "aB", 30600, "probe B")
    spawn("tuC", "aC", 31200, "probe C")
    recs[#recs + 1] = { hook_event_name = "SubagentStop", session_id = "S", prompt_id = "P", _ts = U(37000), agent_id = "aC" }
    recs[#recs + 1] = { hook_event_name = "SubagentStop", session_id = "S", prompt_id = "P", _ts = U(54000), agent_id = "aB" }
    local evs = {}
    for _, r in ipairs(recs) do
      for _, e in ipairs(claude.normalize_hook(r)) do
        if e.event == "agent_spawn_requested" and with_batch then e.batch = "msg_X" end
        evs[#evs + 1] = e
      end
    end
    local st = state.reduce(evs)
    return stages.of(st, st.agents.ROOT.children), st
  end
  t.eq((run(false)), { { "aA" }, { "aB", "aC" } }, "batch 無し：時刻だけだと A が別の段になる")
  local sg, st = run(true)
  t.eq(sg, { { "aA", "aB", "aC" } }, "batch あり：同じ 1 通で起動した 3 つは 1 段")
  t.eq(st.agents.aA.batch, "msg_X", "本物の Agent に batch が引き継がれる（仮の箱から）")
end

-- 14. hooks の run：batch は hooks に無いので、開いたあと（enrich）親の transcript から引く
--   偽の Claude の transcript と hooks.jsonl を一時フォルダに作る（本物のフォルダには触らない）
do
  local events = require("agentmap.events")
  local tmp = vim.fn.tempname() .. "-batch"
  local tp = tmp .. "/claude/projects/-w/S2.jsonl"
  vim.fn.mkdir(vim.fn.fnamemodify(tp, ":h"), "p")
  local tl = {}
  for _, x in ipairs({ { "tuA", "A" }, { "tuB", "B" }, { "tuC", "C" } }) do
    tl[#tl + 1] = vim.json.encode({ type = "assistant", message = { id = "msg_Z", role = "assistant",
      content = { { type = "tool_use", id = x[1], name = "Agent", input = { description = x[2], prompt = "p" } } } } })
  end
  local run_dir = vim.env.AGENTMAP_DIR .. "/projects/-w/runs/S2"
  vim.fn.mkdir(run_dir, "p")
  local function U(ms) return string.format("2026-09-29T03:35:%06.3fZ", ms / 1000) end
  local H = { { hook_event_name = "SessionStart", session_id = "S2", _ts = U(40000), cwd = "/w", transcript_path = tp },
    { hook_event_name = "UserPromptSubmit", session_id = "S2", prompt_id = "P", _ts = U(41000), prompt_head = "go" } }
  local function spawn(tu, aid, t0, t1, desc)
    H[#H + 1] = { hook_event_name = "PreToolUse", session_id = "S2", prompt_id = "P", _ts = U(t0), tool_name = "Agent",
      tool_use_id = tu, tool_input = { description = desc } }
    H[#H + 1] = { hook_event_name = "SubagentStart", session_id = "S2", prompt_id = "P", _ts = U(t0 + 10), agent_id = aid,
      agent_type = "general-purpose" }
    H[#H + 1] = { hook_event_name = "SubagentStop", session_id = "S2", prompt_id = "P", _ts = U(t1), agent_id = aid }
    H[#H + 1] = { hook_event_name = "PostToolUse", session_id = "S2", prompt_id = "P", _ts = U(t1 + 10), tool_name = "Agent",
      tool_use_id = tu, tool_response = { agentId = aid, status = "completed" } }
  end
  -- 2026-09-29 の本物の試し（前面で 3 つ）：A は 45.7〜46.8 秒、B は 51.6 秒から。時刻だけだと A が別の段
  spawn("tuA", "aA", 45724, 46829, "A")
  spawn("tuB", "aB", 51623, 57510, "B")
  spawn("tuC", "aC", 52273, 58414, "C")
  local hl = {}
  for _, r in ipairs(H) do hl[#hl + 1] = vim.json.encode(r) end
  vim.fn.writefile(hl, run_dir .. "/hooks.jsonl")
  -- 1 回目：transcript がまだ書かれていない（hook の時点ではよくある）→ 時刻どおり
  local run = events.load(run_dir)
  events.enrich(run)
  t.eq(stages.of(run.state, run.state.agents.ROOT.children), { { "aA" }, { "aB", "aC" } },
    "transcript が書かれる前は時刻どおり")
  -- 2 回目：transcript が書かれた（最後の行は書きかけ → 次回に読む）
  local f = io.open(tp, "wb")
  f:write(tl[1] .. "\n" .. tl[2] .. "\n" .. tl[3])
  f:close()
  events.enrich(run)
  t.eq({ run.state.agents.aA.batch, run.state.agents.aB.batch, run.state.agents.aC.batch or "nil" },
    { "msg_Z", "msg_Z", "nil" }, "書きかけの最後の行はまだ読まない")
  f = io.open(tp, "ab")
  f:write("\n")
  f:close()
  events.enrich(run)
  t.eq(stages.of(run.state, run.state.agents.ROOT.children), { { "aA", "aB", "aC" } },
    "親の transcript の message.id が同じ → 1 段（hooks の run）")
  local again = events.load(run_dir)
  t.eq(stages.of(again.state, again.state.agents.ROOT.children), { { "aA", "aB", "aC" } }, "開き直しても 1 段（記録に残る）")
  vim.fn.delete(tmp, "rf")
end

-- HUMAN CHECK（"check:" の id）も時刻付きの要素として段分けに混ざる（設計書 §5.2）
do
  local fx = dofile(vim.g.agentmap_test_dir .. "/fixtures/state_check.lua")
  -- [1] が 10 秒に終わる → 11 秒に聞いて答える（asked_at == answered_at）→ 12 秒に [2] が始まる
  t.eq(stages.of(fx, { "a1", "a2", "check:toolu_B" }), { { "a1" }, { "check:toolu_B" }, { "a2" } },
    "check: [1] → HUMAN CHECK → [2] の 3 段（聞いた時刻 == 答えた時刻でも）")
  local it = stages.item_check(fx.checks["check:toolu_Q"])
  t.eq({ it.id, it.open, it.fin, it.batch }, { "check:toolu_Q", true, nil, nil }, "item_check：WAITING は開いたまま・終了なし")

  -- 答え待ち（WAITING）の check がある段は閉じない
  local s = { agents = { a = ag("a", 0, 10), b = ag("b", 100, 110) },
    checks = { ["check:w"] = { id = "check:w", status = "WAITING", asked_at = T(11) } } }
  t.eq(stages.of(s, { "a", "check:w", "b" }), { { "a" }, { "check:w", "b" } }, "check: WAITING の段は閉じない")

  -- 答えが出る前に始まった子は同じ段、答えた後に始まった子は次の段。答えないまま終わったものは ended_at まで
  s.checks["check:w"] = { id = "check:w", status = "ANSWERED", asked_at = T(11), answered_at = T(20) }
  s.agents.c = ag("c", 15, 18)
  s.agents.b = ag("b", 20, 30)
  t.eq(stages.of(s, { "a", "check:w", "c", "b" }), { { "a" }, { "check:w", "c" }, { "b" } },
    "check: 答えるまでに始まった子は同じ段・答えた後の子は次の段")
  s.checks["check:w"] = { id = "check:w", status = "ABANDONED", asked_at = T(11), ended_at = T(25) }
  t.eq(stages.of(s, { "a", "check:w", "b" }), { { "a" }, { "check:w", "b" } }, "check: ABANDONED は ended_at まで")
end

t.done()
