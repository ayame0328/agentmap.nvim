-- i18n（画面の文言の切り替え）の試験（担当 W2）
--   ・en と ja の表が揃っている（キーと %{…} の差し込み口が同じ）
--   ・t() の引き方（無いキー・差し込み・知らない言語）
--   ・setup("ja") にすると、図の見出し・詳細・HUMAN CHECK の画面が日本語になる（今までと同じ画面）
--   ・既定（en）の箱の中身が箱の幅に収まる
--   実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_i18n.lua
local t = require("t")
local here = vim.g.agentmap_test_dir
local i18n = require("agentmap.i18n")
local en = require("agentmap.lang.en")
local ja = require("agentmap.lang.ja")

-- ------------------------------------------------------------
-- 1. 表が揃っている
-- ------------------------------------------------------------
t.eq(i18n.missing("ja"), {}, "ja に足りないキーは無い")
local extra = {}
for k in pairs(ja) do
  if en[k] == nil then extra[#extra + 1] = k end
end
table.sort(extra)
t.eq(extra, {}, "ja にだけあるキーは無い")

local function holes(s)
  local out = {}
  for name in tostring(s):gmatch("%%{([%w_]+)}") do out[name] = true end
  local list = vim.tbl_keys(out)
  table.sort(list)
  return list
end
local bad = {}
for k, v in pairs(en) do
  if ja[k] ~= nil and not vim.deep_equal(holes(v), holes(ja[k])) then bad[#bad + 1] = k end
end
table.sort(bad)
t.eq(bad, {}, "en と ja で %{…} の差し込み口が同じ")

local nonstr = {}
for _, tbl in ipairs({ en, ja }) do
  for k, v in pairs(tbl) do
    if type(v) ~= "string" then nonstr[#nonstr + 1] = k end
  end
end
t.eq(nonstr, {}, "値はすべて文字列")

-- ui.lua の担当分（W2）は英語の表に日本語を含まない
local ui_en = require("agentmap.lang.en.ui")
local jp_in_en = {}
for k, v in pairs(ui_en) do
  if v:find("[\227-\233][\128-\191][\128-\191]") then jp_in_en[#jp_in_en + 1] = k end
end
table.sort(jp_in_en)
t.eq(jp_in_en, {}, "lang/en/ui.lua に日本語が無い")

-- ------------------------------------------------------------
-- 2. 引き方
-- ------------------------------------------------------------
t.eq(i18n.setup("en"), "en", "setup(\"en\")")
t.eq(i18n.t("nope"), "nope", "無いキーはキーそのもの")
t.eq(i18n.t("init.switched_run", { sid = "x" }), "Switched to a new run: x", "差し込み")
t.eq(i18n.t("ui.agent_not_found"), "Agent not found: %{id}", "値が無い差し込み口はそのまま")
t.eq(i18n.t("common.missing"), "(not written)", "common.missing（英語）")
t.ok(i18n.has("ui.agent_not_found"), "has：ある")
t.ok(not i18n.has("nope"), "has：無い")
t.eq(i18n.setup("xx"), "en", "知らない言語は en")
t.eq(i18n.lang, "en", "知らない言語なら lang は en")
t.eq(i18n.setup(nil), "en", "nil は en")
t.eq(i18n.setup("ja"), "ja", "setup(\"ja\")")
t.eq(i18n.t("common.missing"), "（書かれていません）", "common.missing（日本語）")
t.eq(i18n.t("ui.agent_not_found", { id = "a1" }), "Agent が見つかりません: a1", "日本語の差し込み")
i18n.setup("en")

-- ------------------------------------------------------------
-- 3. 画面：既定（英語）と ja
-- ------------------------------------------------------------
local graph = require("agentmap.graph")
local detail = require("agentmap.views.detail")
local checkv = require("agentmap.views.check")
local keymaps = require("agentmap.keymaps")
local NOW = 1790600000
local function fixture() return dofile(here .. "/fixtures/state_check.lua") end
local function text(res) return table.concat(res.lines, "\n") end
local function has(s, sub, msg) t.ok(s:find(sub, 1, true) ~= nil, msg .. "：「" .. sub .. "」がある") end
local function hasnt(s, sub, msg) t.ok(s:find(sub, 1, true) == nil, msg .. "：「" .. sub .. "」が無い") end

local function screens()
  local s = fixture()
  local L = graph.layout(s, { width = 400, now = NOW, mode = "box" })
  return {
    header = L.lines[1] .. "\n" .. L.lines[2],
    layout = L,
    detail = text(detail.build(s, s.agents.a2, { width = 120 })),
    check = text(checkv.build(s, s.checks["check:toolu_Q"], { width = 120 })),
    help = table.concat(keymaps.help_lines(), "\n"),
  }
end

-- 既定（en）
local E = screens()
has(E.header, "waiting 1", "en の見出し")
has(E.header, "updated ", "en の見出し")
has(E.header, "[WAITING]purple", "en の凡例")
has(E.header, "? keys  v view (map)", "en の凡例")
has(E.detail, "■ Human checks (1)", "en の詳細")
has(E.detail, "■ Needs confirmation (this agent stopped to wait for an answer)", "en の詳細")
has(E.check, "Asked by", "en の HUMAN CHECK")
has(E.check, "■ Options and what happens after each", "en の HUMAN CHECK")
has(E.help, "AgentMap keys (map view)", "en の ? 一覧")
has(E.help, "1-9", "en の ? 一覧")

-- ja：今までの画面と同じ文言
i18n.setup("ja")
local J = screens()
has(J.header, "確認待ち 1", "ja の見出し")
has(J.header, " · 更新 ", "ja の見出し")
has(J.header, "[WAITING]紫 ", "ja の凡例")
has(J.header, "? キー一覧  v 表示切替（図）", "ja の凡例")
hasnt(J.header, "updated", "ja の見出しに英語が残らない")
has(J.detail, "■ 人の確認（1）", "ja の詳細")
has(J.detail, "■ 要確認（この Agent は確認待ちで止まりました）", "ja の詳細")
t.matches(J.detail, "今の作業%s+orders%.sql の拡張", "ja の詳細：今の作業")
t.matches(J.detail, "質問%s+HUMAN CHECK #2 %[WAITING%]（Enter で詳細）", "ja の詳細：質問の行")
has(J.check, "聞いた側", "ja の HUMAN CHECK")
has(J.check, "の「要確認」", "ja の HUMAN CHECK")
has(J.check, "■ 選択肢と、選んだ後の進め方", "ja の HUMAN CHECK")
has(J.check, "→ 選んだら: tests/ に追加して終了", "ja の HUMAN CHECK")
has(J.check, "（まだ答えていません。ターミナルで答えてください）", "ja の HUMAN CHECK")
has(J.help, "AgentMap のキー（図の画面）", "ja の ? 一覧")
has(J.help, "1〜9", "ja の ? 一覧")
local jq = J.layout.nodes["check:toolu_Q"].lines
t.matches(jq[4], "選択肢 2  Enter で詳細", "ja の HUMAN CHECK の箱")
t.matches(J.layout.nodes.ROOT.lines[4], "確認待ち1", "ja の ROOT の箱")
t.matches(J.layout.nodes.a2.lines[4], "要確認", "ja の [2] の箱")
i18n.setup("en")

-- ------------------------------------------------------------
-- 4. 英語は箱の幅に収まる（DESIGN §5.4：日本語より広くしない）
-- ------------------------------------------------------------
local W = 26 -- box_w（config の既定）
local fixed = {
  "graph.group_desc", "graph.no_verdict", "graph.rerun_same", "graph.next_stage", "graph.ended_unanswered",
}
for _, k in ipairs(fixed) do
  local e = i18n.t(k)
  t.ok(vim.fn.strdisplaywidth(e) <= W, k .. " は箱に収まる（" .. e .. "）")
end
local samples = {
  { "graph.options_enter", { n = 4 } }, { "graph.rework_n", { n = 2 } }, { "graph.waiting_n", { n = 3 } },
  { "graph.ask" }, { "graph.group_count", { n = 12 } },
}
for _, c in ipairs(samples) do
  local e = i18n.t(c[1], c[2])
  t.ok(vim.fn.strdisplaywidth(e) <= W, c[1] .. " は箱に収まる（" .. e .. "）")
end
-- 箱の 4 行目の印は日本語より広くしない（状態の札と経過時間の後ろに並ぶため）
for _, c in ipairs({ { "graph.waiting_n", { n = 3 } }, { "graph.ask" } }) do
  local e = i18n.t(c[1], c[2])
  i18n.setup("ja")
  local j = i18n.t(c[1], c[2])
  i18n.setup("en")
  t.ok(vim.fn.strdisplaywidth(e) <= vim.fn.strdisplaywidth(j), c[1] .. " は日本語より広くない（" .. e .. " / " .. j .. "）")
end

-- ------------------------------------------------------------
-- 5. v0.1.2 の一時停止と関門（DESIGN-v0.1.2-pause 付録 A）：鍵が英日そろい、差し込み口が同じ
-- ------------------------------------------------------------
local PAUSE_KEYS = {
  "keymaps.help_pause", "keymaps.help_gate", "keymaps.desc_pause", "keymaps.desc_gate", "keymaps.help_aux_tdwa",
  "graph.legend_orange", "graph.legend_paused",
  "ui.pause_prompt", "ui.pause_next", "ui.pause_stop", "ui.pause_cancel", "ui.pause_resume", "ui.pause_resume_with",
  "ui.pause_keep", "ui.pause_pass", "ui.pause_fix", "ui.pause_keep_gate", "ui.pause_write_instead", "ui.pause_show",
  "ui.pause_requested", "ui.pause_requested_stop", "ui.pause_resumed", "ui.pause_resumed_with", "ui.pause_cancelled",
  "ui.pause_hit", "ui.pause_hit_gate", "ui.pause_auto", "ui.pause_aborted", "ui.pause_expired", "ui.pause_not_target",
  "ui.pause_run_ended", "ui.pause_disabled", "ui.pause_hooks_outdated", "ui.gate_on", "ui.gate_off",
  "detail.h_pauses", "detail.pause_requested_next", "detail.pause_requested_stop", "detail.pause_gate",
  "detail.pause_paused", "detail.pause_waiting", "detail.pause_resumed_user", "detail.pause_resumed_with",
  "detail.pause_resumed_auto", "detail.pause_resumed_exit", "detail.pause_resumed_gate_off", "detail.pause_aborted",
  "detail.pause_expired", "detail.pause_reason_finished", "detail.pause_reason_session", "detail.pause_reason_gate_off", "detail.pause_reason_stale",
  "detail.pause_duration", "detail.footer",
  "export.h_pauses", "export.pause_line", "export.pause_waiting", "export.pause_resumed_user", "export.pause_resumed_with",
  "export.pause_resumed_auto", "export.pause_resumed_exit", "export.pause_resumed_gate_off", "export.pause_aborted",
  "export.pause_expired", "export.pause_requested", "export.pause_none", "export.ov_pauses", "export.ov_gate",
  "health.pause_on", "health.pause_off", "health.pause_outdated", "health.pause_flag_ok", "health.pause_flag_pending",
  "health.pause_flag_stale", "health.hooks_outdated", "init.cmd_pause", "init.cmd_resume", "init.cmd_gate",
}
local miss = {}
for _, k in ipairs(PAUSE_KEYS) do
  if en[k] == nil or ja[k] == nil then miss[#miss + 1] = k end
end
t.eq(miss, {}, "付録 A の鍵が en と ja の両方にある")
t.eq(holes(en["ui.pause_hit"]), { "label", "time", "via" }, "ui.pause_hit の差し込み口")
t.eq(holes(en["detail.pause_waiting"]), { "time", "until", "via" }, "detail.pause_waiting の差し込み口")
t.matches(en["detail.footer"], "s steer  x pause  Enter", "footer に x pause")
t.matches(en["keymaps.help_aux_tdwa"], "steer / pause$", "aux の一覧に pause")
t.matches(en["health.hooks_outdated"], "v0%.1%.2 pauses agents, delivers steering when an agent finishes, and records SendMessage", "古い登録の文を差し替え（steer2）")
-- 箱の札は英語のまま（S9）。日本語でも同じ
i18n.setup("ja")
t.eq(i18n.t("graph.legend_paused"), "[PAUSED] [GATE]", "ja でも札は英語")
i18n.setup("en")
-- 箱の 4 行目に並ぶ札と印は日本語より広くしない（札は英日で同じ。⏸ は言語に依らない）
t.ok(vim.fn.strdisplaywidth("[PAUSED] ~62.4% 12:34") <= 24, "[PAUSED] ~62.4% 12:34 は内側 24 桁に収まる")

-- ------------------------------------------------------------
-- 6. v0.1.2 の終わり際の修正指示と親経由（DESIGN-v0.1.2-steer2 付録 A）
-- ------------------------------------------------------------
local STEER2_KEYS = {
  "keymaps.help_steer", "ui.steer_write", "ui.steer_write_resume", "ui.steer_write_gate", "ui.steer_write_root_stop",
  "ui.steer_relay", "ui.steer_relay_resume", "ui.steer_prompt_stop", "ui.steer_prompt_relay", "ui.steer_prompt_resume",
  "ui.steer_queued", "ui.steer_queued_eta", "ui.steer_resumed_stop", "ui.steer_queued_root_stop", "ui.steer_relay_sent",
  "ui.steer_relay_no_terminal", "ui.steer_relayed", "ui.steer_not_relayed", "ui.steer_delivered_stop",
  "ui.steer_hooks_outdated", "ui.steer_no_terminal_hook",
  "detail.steer_pending", "detail.steer_pending_next", "detail.steer_relay_sent", "detail.steer_relay_read",
  "detail.steer_relayed", "detail.steer_relay_as", "detail.steer_relay_line", "detail.steer_reason_not_relayed",
  "detail.steer_reason_finished", "detail.steer_not_relayed",
  "export.steer_pending", "export.steer_pending_next", "export.steer_relay_sent", "export.steer_relayed", "export.steer_not_relayed",
  "health.steer_on", "health.steer_mode_tool_result", "health.steer_at_stop_ignored", "health.steer_outdated",
  "health.term_ok", "health.term_none", "health.sendmessage_ok", "health.sendmessage_missing", "health.hooks_outdated",
  "steer.relay_en", "steer.relay_ja", "init.steer_usage",
}
local miss2 = {}
for _, k in ipairs(STEER2_KEYS) do
  if en[k] == nil or ja[k] == nil then miss2[#miss2 + 1] = k end
end
t.eq(miss2, {}, "steer2 付録 A の鍵が en と ja の両方にある")
-- 親経由の文（§4.2）：先頭の [AgentMap] は固定、差し込み口は 4 つ、どちらの言語でも同じ文
for _, k in ipairs({ "steer.relay_en", "steer.relay_ja" }) do
  t.eq(holes(en[k]), { "id", "index", "name", "text" }, k .. " の差し込み口")
  t.eq(en[k], ja[k], k .. " は全言語で同じ")
  t.ok(en[k]:sub(1, 11) == "[AgentMap] ", k .. " は [AgentMap] で始まる")
end
t.eq(i18n.t("steer.relay_en", { index = 3, name = "probe child", id = "a1b2", text = "write b.txt instead" }),
  '[AgentMap] Tell sub-agent [3] "probe child" (agent id a1b2) this, with SendMessage: write b.txt instead', "relay_en の全文（E3 の文）")
t.matches(en["steer.relay_ja"], "SendMessage で次を伝えてください：%%{text}$", "relay_ja")
-- 「終わる直前に届く」ことを正直に言う（届くまでに作業が進むことがある）
t.matches(en["ui.steer_queued"], "arrives when the agent tries to finish", "置いたときの通知は終わり際と言う")
t.matches(ja["ui.steer_queued"], "終わろうとした瞬間に届きます", "日本語も終わり際と言う")
t.matches(en["detail.steer_pending"], "^PENDING %(arrives when the agent finishes%)$", "詳細の未配達（stop）")
t.matches(en["detail.steer_pending_next"], "^PENDING %(arrives at its next tool call%)$", "詳細の未配達（deny/context）")
t.eq(holes(en["detail.steer_relayed"]), { "parent", "time" }, "detail.steer_relayed の差し込み口")
t.eq(en["init.steer_usage"], ":AgentMapSteer {n|id} [relay] [text]", "使い方に relay")
-- 箱の印（✎1 / ✎ / ✎!）は変えない。凡例は箱の幅の中で日本語より広くしない
do
  local e = i18n.t("graph.legend_steer")
  i18n.setup("ja")
  local j = i18n.t("graph.legend_steer")
  i18n.setup("en")
  t.ok(vim.fn.strdisplaywidth(e) <= math.max(vim.fn.strdisplaywidth(j), 24), "graph.legend_steer の幅")
end

t.done()
