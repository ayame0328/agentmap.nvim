-- Tests for agents launched by the Workflow tool
--   (a) hooks の記録（手で作る）：まとめ役「Workflow …」の箱の下に入る・段に分かれる・数に入らない
--   (b) meta.json・transcript の場所の読み方（一時フォルダに偽の Claude フォルダを作る）
--   本物の Claude のフォルダは読まない。書き込みは一時フォルダ（AGENTMAP_DIR）だけ。
--   （公開前は本物のセッションを取り込む (c) があったが、他の環境では必ず SKIP になるので外した。DESIGN §9.4 / P15）
local t = require("t")
local state = require("agentmap.state")
local claude = require("agentmap.providers.claude")
local graph = require("agentmap.graph")
local stages = require("agentmap.stages")
local events = require("agentmap.events")
local store = require("agentmap.store")
local export = require("agentmap.export")
local mc = require("mermaid_check")
vim.notify = function() end

local function T(n) return string.format("2026-09-29T11:%02d:%02d.000Z", math.floor(n / 60), n % 60) end
local function norm(recs)
  local out = {}
  for _, r in ipairs(recs) do
    for _, ev in ipairs(claude.normalize_hook(r)) do out[#out + 1] = ev end
  end
  return out
end

-- ------------------------------------------------------------
-- (a) hooks の記録
-- ------------------------------------------------------------
local SID = "wfsess-0000"
local WFP = "/fake/projects/-x/" .. SID .. "/subagents/workflows/wf_x/agent-"
local function start(id, ts, meta)
  return { hook_event_name = "SubagentStart", session_id = SID, prompt_id = "P1", _ts = T(ts),
    agent_id = id, agent_type = "", meta = meta }
end
local function stop(id, ts, path)
  return { hook_event_name = "SubagentStop", session_id = SID, prompt_id = "P1", _ts = T(ts),
    agent_id = id, agent_transcript_path = path or (WFP .. id .. ".jsonl"), last_head = "ok" }
end
local recs = {
  { hook_event_name = "SessionStart", session_id = SID, _ts = T(0), cwd = "/w", transcript_path = "/fake/projects/-x/" .. SID .. ".jsonl" },
  { hook_event_name = "UserPromptSubmit", session_id = SID, prompt_id = "P1", _ts = T(1), prompt_head = "Workflow を回して" },
  start("w1", 5, { wf_id = "wf_x", agentType = "workflow-subagent", model = "opus", description = "設計:A",
    workflowPhase = "設計", spawnDepth = 1 }),
}
local ev1 = norm({ recs[3] })
t.eq(ev1[1].agent_type, "workflow-subagent", "hook の agent_type が \"\" でも meta.json の agentType を使う")
t.eq(ev1[1].wf_id, "wf_x", "SubagentStart に Workflow の id")

-- 途中まで（w1 が動いている）
local s = state.reduce(norm(recs))
local W = s.agents["wf:wf_x"]
t.ok(W and W.kind == "workflow", "まとめ役の箱 wf:wf_x ができる")
t.eq(W and W.parent_id, "ROOT", "Workflow を呼んだ Agent が分からない → ROOT の下")
t.eq(W and W.index, nil, "まとめ役に番号は振らない（数字キーは本物の Agent だけ）")
t.eq(s.agents.w1.parent_id, "wf:wf_x", "w1 はまとめ役の下")
t.eq(s.agents.w1.task, "設計:A", "meta.json の description が仕事名")
t.eq(s.agents.w1.phase, "設計", "meta.json の workflowPhase")
t.eq(W and W.status, "RUNNING", "中の Agent が動いている間は RUNNING")
t.eq(s.counts.agents, 1, "まとめ役は Agent の数に入れない")

-- 最後まで：w1 → w2（順番）、w3 は古いデータ（meta なし）で SubagentStop の場所から Workflow が分かる
vim.list_extend(recs, {
  stop("w1", 20),
  start("w2", 21, { wf_id = "wf_x", agentType = "workflow-subagent", model = "opus", description = "実装:B", spawnDepth = 1 }),
  start("w3", 22, nil),
  stop("w2", 40),
  stop("w3", 41),
  -- spawnDepth だけで ROOT と決めていた Agent も、Workflow の場所が分かれば付け替える
  start("w4", 23, { agentType = "workflow-subagent", spawnDepth = 1 }),
  stop("w4", 42),
  { hook_event_name = "Stop", session_id = SID, prompt_id = "P1", _ts = T(50), last_head = "done" },
  { hook_event_name = "SessionEnd", session_id = SID, _ts = T(51), reason = "other" },
})
s = state.reduce(norm(recs))
W = s.agents["wf:wf_x"]
t.eq(s.agents.w3.parent_id, "wf:wf_x", "meta が無くても SubagentStop の transcript の場所で Workflow の下へ")
t.eq(s.agents.w4.parent_id, "wf:wf_x", "spawnDepth だけで ROOT にしていた Agent も Workflow の下へ付け替える")
t.eq(s.counts.agents, 4, "Agent は 4 つ（まとめ役を除く）")
t.eq(s.counts.unknown_parent, 0, "親不明なし")
t.eq(W.status, "DONE", "全員終われば DONE")
t.ok(W.elapsed_ms and W.elapsed_ms > 0, "まとめ役の所要時間は中の Agent の最初〜最後")
t.eq(W.prompt_id, "P1", "まとめ役は最初の子の流れに入る")
t.eq(stages.of(s, graph.children(s, "wf:wf_x")), { { "w1" }, { "w2", "w3", "w4" } }, "Workflow の中が 2 段に分かれる")
local fv = state.flow_view(s, "P1")
t.ok(fv and fv.agents["wf:wf_x"], "指示ごとの流れの表示にもまとめ役が残る")
t.eq(fv and fv.agents["wf:wf_x"].index, nil, "流れの表示でもまとめ役に番号なし")
t.eq(fv and fv.flow.agents, 4, "流れの Agent 数はまとめ役を除く")

local L = graph.layout(s, { width = 400, mode = "box" })
t.ok(L.nodes["wf:wf_x"] and L.nodes.w1 and L.nodes["wf:wf_x"].x < L.nodes.w1.x, "箱の図：まとめ役の右に中の Agent（2 層目）")
t.ok(L.nodes.w2.x > L.nodes.w1.x and L.nodes.w2.x == L.nodes.w4.x, "箱の図：Workflow の中も段に並ぶ")
t.ok(table.concat(L.lines, "\n"):find("Workflow wf_x", 1, true) or table.concat(L.lines, "\n"):find("Workflow x", 1, true),
  "箱にまとめ役の名前")
-- 「段:」の英語は「stage:」（DESIGN §5.4）。phase の値（設計）は記録の中身なので訳さない
t.matches(table.concat(L.lines, "\n"), "· stage: ?設計", "workflowPhase が 2 行目に出る")
local Lt = graph.layout(s, { width = 60, mode = "tree" })
t.matches(table.concat(Lt.lines, "\n"), "Workflow x", "一覧にまとめ役")
local md = export.to_markdown(s)
local blocks = mc.blocks(md)
local errs = mc.check(blocks[1] or "")
t.eq(errs, {}, "Workflow 入りの Mermaid の形が正しい")

-- PostToolUse(Workflow) が届いた場合（今の hooks の登録では届かないが、届けば正確な親が分かる）
local evw = claude.normalize_hook({ hook_event_name = "PostToolUse", session_id = SID, _ts = T(3), agent_id = "aP",
  tool_name = "Workflow", tool_use_id = "tw", tool_input = { description = "d" },
  tool_response = { runId = "wf_z", workflowName = "nm", summary = "sum" } })
t.eq(evw[1].event, "workflow_started", "PostToolUse(Workflow) → workflow_started")
t.eq(evw[1].parent_id, "aP", "呼んだ Agent が親")
t.eq(evw[2] and evw[2].event, "tool_used", "ツールの記録も残す")

-- ------------------------------------------------------------
-- (b) meta.json と transcript を偽の Claude フォルダから読む（enrich）
-- ------------------------------------------------------------
local TMP = vim.fn.tempname()
local SLUG = "-fake-proj"
local SID2 = "wfsess-1111"
local base = TMP .. "/claude/projects/" .. SLUG
local wfdir = base .. "/" .. SID2 .. "/subagents/workflows/wf_y"
vim.fn.mkdir(wfdir, "p")
local function wf(p, s2)
  local f = assert(io.open(p, "wb"))
  f:write(s2)
  f:close()
end
wf(base .. "/" .. SID2 .. ".jsonl", '{"type":"user","timestamp":"' .. T(0) .. '","message":{"role":"user","content":"hi"}}\n')
wf(wfdir .. "/agent-w5.meta.json", '{"agentType":"workflow-subagent","spawnDepth":1,"model":"fable"}')
wf(wfdir .. "/agent-w5.jsonl", table.concat({
  vim.json.encode({ type = "user", timestamp = T(2), promptId = "x", message = { role = "user",
    content = "[Workflow harness — user request] The harness relays the request; this request wins:\n  3つとも実装しようか。" } }),
  vim.json.encode({ type = "assistant", timestamp = T(3), message = { model = "<synthetic>", content = { { type = "text", text = "API Error" } } } }),
}, "\n") .. "\n")
local run0 = { sid = SID2, slug = SLUG, state = { root_transcript = base .. "/" .. SID2 .. ".jsonl" } }
local meta, mpath = claude.read_meta(run0, "w5")
t.eq(meta and meta.model, "fable", "workflows/<wf>/ の下の meta.json も読める")
t.eq(claude._wf_of_path(mpath), "wf_y", "meta.json の場所から Workflow の id")
t.eq(claude.first_prompt_line(wfdir .. "/agent-w5.jsonl"), "3つとも実装しようか。", "依頼文の 1 行目（前置きの行は飛ばす）")
t.eq(claude.prompt_line("\n必ず最初に これを読む\n次の行"), "必ず最初に これを読む", "空行を飛ばして最初の行")

-- hooks.jsonl（古い collector：meta なし・Stop もまだ）→ enrich で Workflow の下へ、モデルと仕事名も補う
local dir = store.run_dir(SLUG, SID2)
store.ensure(dir)
wf(dir .. "/hooks.jsonl", table.concat({
  vim.json.encode({ hook_event_name = "SessionStart", session_id = SID2, _ts = T(0), cwd = "/w",
    transcript_path = base .. "/" .. SID2 .. ".jsonl" }),
  vim.json.encode({ hook_event_name = "SubagentStart", session_id = SID2, _ts = T(2), agent_id = "w5", agent_type = "" }),
  vim.json.encode({ hook_event_name = "SubagentStop", session_id = SID2, _ts = T(4), agent_id = "w5" }),
}, "\n") .. "\n")
local run = events.load(dir)
t.eq(run.state.agents.w5.parent_id, nil, "enrich 前は親不明")
events.enrich(run)
events.enrich(run)
local a5 = run.state.agents.w5
t.eq(a5.parent_id, "wf:wf_y", "enrich：meta.json の場所から Workflow の下へ")
t.eq(a5.task, "3つとも実装しようか。", "enrich：仕事名は Agent 自身の最初の依頼文")
t.eq(a5.model, "fable", "enrich：transcript にモデルが無い（<synthetic>）ときは meta.json のモデル")
t.eq(run.state.agents["wf:wf_y"].parent_id, "ROOT", "まとめ役は ROOT の下")
vim.fn.delete(TMP, "rf")

t.done()
