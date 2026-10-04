-- Tests for lua/agentmap/brief.lua (writing-convention parser), Japanese and English forms,
-- plus the Lua side of the Lua <-> Python parity test (fixtures/convention_cases.jsonl).
--   実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_brief.lua
local t = require("t")
local brief = require("agentmap.brief")

local function chars(s) return vim.fn.strchars(s) end

-- ---------- parse_brief ----------

-- 1. 3 つ揃い（決まりどおり 3 行）
t.eq(brief.parse_brief("【目的】orders を拡張する\n【任せる理由】ファイルが多い\n【期待する結果】テストが通る\n本文…"),
  { purpose = "orders を拡張する", reason = "ファイルが多い", expected = "テストが通る" }, "3 つ揃い")

-- 2. 1 つ欠け → その項目は nil
t.eq(brief.parse_brief("【目的】調べる\n【期待する結果】一覧\n本文"),
  { purpose = "調べる", expected = "一覧" }, "1 つ欠け")

-- 3. キーの直後の全角コロン・半角コロンと前後の空白は落とす
t.eq(brief.parse_brief("【目的】：　調べる　\n【任せる理由】: 多い\n【期待する結果】:一覧"),
  { purpose = "調べる", reason = "多い", expected = "一覧" }, "コロンと空白")

-- 4. 1 行に 2 つ以上（改行が空白にされた prompt_head の形）→ 次の【で切る
t.eq(brief.parse_brief("【目的】既存の dbt モデルを把握する 【任せる理由】ファイルが多い 【期待する結果】一覧"),
  { purpose = "既存の dbt モデルを把握する", reason = "ファイルが多い", expected = "一覧" }, "1 行に 3 つ")

-- 5. 無し → nil。空・nil・中身が空のキーだけ → nil
t.eq(brief.parse_brief("ただの指示です"), nil, "見出し無し → nil")
t.eq(brief.parse_brief(nil), nil, "nil → nil")
t.eq(brief.parse_brief(""), nil, "空 → nil")
t.eq(brief.parse_brief("【目的】\n【任せる理由】　\n本文"), nil, "中身が空 → nil")

-- 6. 300 文字で切る（バイトではなく文字で。… は付けない）
do
  local long = string.rep("あ", 350)
  local b = brief.parse_brief("【目的】" .. long .. "\n【任せる理由】x")
  t.eq(chars(b.purpose), 300, "300 文字で切る")
  t.eq(b.purpose, string.rep("あ", 300), "切った後も壊れた文字が無い")
  t.eq(b.reason, "x", "切っても次の項目は読む")
end

-- 7. 同じキーが 2 回あれば最初の方
t.eq(brief.parse_brief("【目的】A\n本文【目的】B").purpose, "A", "同じキーは最初の方")

-- ---------- parse_report ----------

-- 8. 報告 4 項目
do
  local r = brief.parse_report("前置き\n\n## 報告\n- やったこと: models/ の 12 本を読んだ\n- 方向: 依存の順に整理\n- 理由: 下流から見ると漏れる\n- 残った課題: なし")
  t.eq(r.kind, "report", "報告: kind")
  t.eq({ r.done, r.direction, r.reason, r.issues },
    { "models/ の 12 本を読んだ", "依存の順に整理", "下流から見ると漏れる", "なし" }, "報告: 4 項目")
  t.eq(r.options, nil, "報告には options が無い")
  t.ok(r.raw:find("## 報告", 1, true) ~= nil, "raw は原文のまま")
end

-- 9. 複数行の本文（続きの行は空白でつなぐ）、全角コロン、項目名だけ（- 無し）、1 つ欠け
do
  local r = brief.parse_report("## 報告\n- やったこと：A を直した\n  B も直した\n方向: 小さく\n\n- 理由: 速い\n")
  t.eq(r.done, "A を直した B も直した", "複数行は空白でつなぐ")
  t.eq(r.direction, "小さく", "- 無しの項目名")
  t.eq(r.reason, "速い", "空行 1 つを挟んでも次の項目")
  t.eq(r.issues, nil, "書かれていない項目は nil")
end

-- 10. 空行 2 つで本文は終わり（後ろの地の文を混ぜない）
do
  local r = brief.parse_report("## 報告\n- やったこと: A\n\n\n以上です")
  t.eq(r.done, "A", "空行 2 つで終わり")
end

-- 11. 要確認＋選択肢（→ と -> と 1) の書き方、→ 無し）
do
  local text = "## 要確認\n- 今の作業: orders.sql の拡張\n- 止まっている所: テストの範囲が決まらない\n"
    .. "- 確認したいこと: テストはどこまで書きますか？\n- 選択肢:\n  1. 単体のみ → tests/ に追加して終了\n"
    .. "  2) 結合まで -> seed を作ってから実装\n  3. 保留"
  local r = brief.parse_report(text)
  t.eq(r.kind, "ask", "要確認: kind")
  t.eq({ r.working, r.stuck, r.want }, { "orders.sql の拡張", "テストの範囲が決まらない", "テストはどこまで書きますか？" },
    "要確認: 3 項目")
  t.eq(r.options, {
    { n = 1, name = "単体のみ", next = "tests/ に追加して終了" },
    { n = 2, name = "結合まで", next = "seed を作ってから実装" },
    { n = 3, name = "保留", next = nil },
  }, "選択肢: → / -> / → 無し")
  t.eq(r.done, nil, "要確認には報告の項目が無い")
end

-- 12. 選択肢が無い要確認 → options は空の表
t.eq(brief.parse_report("## 要確認\n- 確認したいこと: どうする？").options, {}, "選択肢無し → {}")

-- 13. 両方あれば後に出てきた方
do
  local r = brief.parse_report("## 報告\n- やったこと: 途中まで\n\n## 要確認\n- 確認したいこと: 続けますか？")
  t.eq(r.kind, "ask", "両方 → 後の要確認")
  t.eq(r.want, "続けますか？", "後の節を読む")
  t.eq(r.done, nil, "前の節は読まない")
  local r2 = brief.parse_report("## 要確認\n- 確認したいこと: X\n## 報告\n- やったこと: 全部")
  t.eq(r2.kind, "report", "両方 → 後の報告")
  t.eq(r2.done, "全部", "後の報告を読む")
end

-- 14. ### も見出し。# 1 個・4 個や「報告書」は見出しではない。次の別の見出しで節が終わる
do
  local r = brief.parse_report("### 報告\n- やったこと: A\n### 補足\n- 理由: これは補足の中")
  t.eq(r.kind, "report", "### も見出し")
  t.eq(r.reason, nil, "別の見出しの後ろは読まない")
  t.eq(brief.parse_report("# 報告\n- やったこと: A").kind, nil, "# 1 個は見出しではない")
  t.eq(brief.parse_report("#### 報告\n- やったこと: A").kind, nil, "# 4 個は見出しではない")
  t.eq(brief.parse_report("## 報告書\n- やったこと: A").kind, nil, "報告書は別物")
  t.eq(brief.parse_report("  ##  報告  \n- やったこと: A").done, "A", "前後の空白可")
  t.eq(brief.parse_report("## 要確認（この Agent は止まりました）\n- 確認したいこと: Q").want, "Q", "見出しの後ろの括弧は可")
end

-- 15. 見出し無し → kind nil、raw だけ。nil → kind nil
do
  local r = brief.parse_report("全部終わりました。\n- やったこと: A")
  t.eq(r.kind, nil, "見出し無し → kind nil")
  t.eq(r.raw, "全部終わりました。\n- やったこと: A", "見出し無しでも raw はある")
  t.eq(r.done, nil, "見出し無しなら項目も読まない")
  t.eq(brief.parse_report(nil), { kind = nil, raw = nil }, "nil → 空の結果")
end

-- 16. 改行が CRLF でも読む
t.eq(brief.parse_report("## 報告\r\n- やったこと: A\r\n- 方向: B").direction, "B", "CRLF")

-- ---------- split_next ----------

t.eq({ brief.split_next("既存の表を使う → 選んだら: 既存の orders を拡張") }, { "既存の表を使う", "既存の orders を拡張" }, "split_next: 基本")
t.eq({ brief.split_next("下流まで→選んだら：seed を作る") }, { "下流まで", "seed を作る" }, "split_next: 空白無し・全角コロン")
t.eq({ brief.split_next("A -> 選んだら: B") }, { "A", "B" }, "split_next: ->")
t.eq({ brief.split_next("A → B（説明の中の矢印）→ 選んだら: C") }, { "A → B（説明の中の矢印）", "C" }, "split_next: 説明の中の → は飛ばす")
t.eq({ brief.split_next("選択肢A です") }, { "選択肢A です", nil }, "split_next: 無し → next nil")
t.eq({ brief.split_next("A → 選んだら:") }, { "A", nil }, "split_next: 中身が空 → nil")
t.eq({ brief.split_next(nil) }, { nil, nil }, "split_next: nil")

-- ---------- match_option ----------

do
  local opts = { { n = 1, name = "単体のみ", next = "x" }, { n = 2, name = "結合まで", next = "y" } }
  t.eq(brief.match_option(opts, "結合まで", 1, 2), opts[2], "完全一致（番号より優先）")
  t.eq(brief.match_option(opts, "単体のみ（推奨）", 2, 2), opts[1], "label が name で始まる")
  t.eq(brief.match_option(opts, "結合", 1, 2), opts[2], "name が label で始まる")
  local en = { { n = 1, name = "Unit only" }, { n = 2, name = "Integration" } }
  t.eq(brief.match_option(en, "unit ONLY", nil, nil), en[1], "大文字小文字は無視")
  t.eq(brief.match_option(opts, "まったく別", 2, 2), opts[2], "見つからなければ番号（個数が同じ）")
  t.eq(brief.match_option(opts, "まったく別", 2, 3), nil, "個数が違えば番号では探さない")
  t.eq(brief.match_option(opts, "まったく別", 2), nil, "個数を渡さなければ番号では探さない")
  t.eq(brief.match_option(nil, "A", 1, 1), nil, "選択肢無し → nil")
end

-- ---------- answer_list ----------

t.eq(brief.answer_list("A"), { "A" }, "answer_list: 文字列")
t.eq(brief.answer_list({ "A", "B" }), { "A", "B" }, "answer_list: 配列")
t.eq(brief.answer_list(nil), {}, "answer_list: nil")
t.eq(brief.answer_list(""), {}, "answer_list: 空文字")

-- ---------- answered_options / next_of ----------

-- 実物（AskUserQuestion の PostToolUse）と同じ形の check
local check = {
  questions = {
    { question = "実装：dbt model について：テストはどこまで書きますか？", header = "実装：dbt", multi = false,
      options = { { label = "単体のみ", description = "モデル単位のテストだけ → 選んだら: tests/ に追加して終了" },
                  { label = "結合まで", description = "下流モデルまで通す" } } },
    { question = "対象の表は？", header = "表", multi = true,
      options = { { label = "orders", description = "注文" }, { label = "users", description = "利用者" } } },
    { question = "まだ答えていない質問", header = "未", multi = false, options = { { label = "X" } } },
  },
  answers = { ["実装：dbt model について：テストはどこまで書きますか？"] = "単体のみ",
              ["対象の表は？"] = { "orders", "その他（自由入力）" } },
}
local agent = { ask = { options = { { n = 1, name = "単体のみ", next = "子の書いた進め方1" },
                                    { n = 2, name = "結合まで", next = "seed を作ってから実装" } } } }

do
  local a = brief.answered_options(check)
  t.eq(#a, 3, "answered_options: 質問の数だけ")
  t.eq(a[1].q, check.questions[1].question, "answered_options: question 文")
  t.eq(a[1].labels, { "単体のみ" }, "answered_options: label")
  t.eq(a[1].option, { i = 1, label = "単体のみ", description = "モデル単位のテストだけ", next = "tests/ に追加して終了" },
    "answered_options: 選んだ選択肢と進め方")
  t.eq(a[2].labels, { "orders", "その他（自由入力）" }, "answered_options: 複数選択")
  t.eq(a[2].option.label, "orders", "answered_options: option は最初の答え")
  t.eq(a[2].matches[2], { label = "その他（自由入力）", option = nil }, "answered_options: 自由入力 → option nil")
  t.eq(a[3].labels, {}, "answered_options: 答えの無い質問 → labels {}")
  t.eq(a[3].option, nil, "answered_options: 答えの無い質問 → option nil")
  t.eq(brief.answered_options(nil), {}, "answered_options: nil → {}")
end

-- next_of の優先：description の「→ 選んだら」→ 子の要確認 → nil
t.eq(brief.next_of(check, 1, 1, agent), "tests/ に追加して終了", "next_of: description が先（子の分より優先）")
t.eq(brief.next_of(check, 1, 2, agent), "seed を作ってから実装", "next_of: description に無ければ子の要確認")
t.eq(brief.next_of(check, 1, 2, nil), nil, "next_of: どちらにも無ければ nil")
t.eq(brief.next_of(check, 2, 1, agent), "子の書いた進め方1", "next_of: 名前が当たらなくても個数が同じなら番号で")
t.eq(brief.next_of(check, 3, 1, agent), nil, "next_of: 名前が当たらず個数も違えば nil")
t.eq(brief.next_of(check, 9, 1, agent), nil, "next_of: 無い質問 → nil")
-- answered_options に agent を渡すと子の要確認から補う
do
  local c2 = vim.deepcopy(check)
  c2.answers[c2.questions[1].question] = "結合まで"
  t.eq(brief.answered_options(c2, agent)[1].option.next, "seed を作ってから実装", "answered_options: agent から進め方を補う")
  t.eq(brief.answered_options(c2)[1].option.next, nil, "answered_options: agent 無しなら補わない")
end

-- ---------- fixture の報告がこの部品で読めること（他の作業者の前提） ----------

do
  local st = dofile(vim.g.agentmap_test_dir .. "/fixtures/state_check.lua")
  local a2 = st.agents.a2
  local r = brief.parse_report(a2.report)
  t.eq(r.kind, "ask", "state_check a2: 要確認")
  for _, k in ipairs({ "working", "stuck", "want", "options" }) do
    t.eq(r[k], a2.ask[k], "state_check a2: ask." .. k .. " が fixture と同じ")
  end
  local r1 = brief.parse_report(st.agents.a1.report)
  t.eq({ r1.done, r1.direction, r1.reason, r1.issues },
    { st.agents.a1.report_fields.done, st.agents.a1.report_fields.direction,
      st.agents.a1.report_fields.reason, st.agents.a1.report_fields.issues }, "state_check a1: report_fields と同じ")
  t.eq(brief.parse_brief(st.agents.a1.prompt_head), st.agents.a1.brief, "state_check a1: brief と同じ")
  -- check:toolu_B の答えから進め方が出る
  local b = brief.answered_options(st.checks["check:toolu_B"])
  t.eq(b[1].option.next, "既存の orders を拡張", "state_check toolu_B: 進め方")
  t.eq(brief.next_of(st.checks["check:toolu_Q"], 1, 2, a2), "seed を作ってから実装", "state_check toolu_Q: 進め方")
end

-- 子の transcript の fixture：handback の message / 最後の text を読む
do
  local function last_report(path)
    local msg, text
    for line in io.lines(path) do
      local d = vim.json.decode(line)
      if d.type == "assistant" then
        for _, b in ipairs(d.message.content) do
          if b.type == "tool_use" and b.name == "SubagentHandback" then msg = b.input.message end
          if b.type == "text" and b.text ~= "" then text = b.text end
        end
      end
    end
    return msg, text
  end
  local dir = vim.g.agentmap_test_dir .. "/fixtures/"
  local m = last_report(dir .. "agent_report.jsonl")
  local r = brief.parse_report(m)
  t.eq(r.kind, "ask", "agent_report.jsonl: handback は要確認")
  t.eq(#r.options, 2, "agent_report.jsonl: 選択肢 2 つ")
  t.eq(brief.parse_brief(vim.json.decode(io.lines(dir .. "agent_report.jsonl")()).message.content).purpose,
    "orders を拡張する", "agent_report.jsonl: 指示の【目的】")
  local m2, txt = last_report(dir .. "agent_report_text.jsonl")
  t.eq(m2, nil, "agent_report_text.jsonl: handback 無し")
  local r2 = brief.parse_report(txt)
  t.eq(r2.kind, "report", "agent_report_text.jsonl: 最後の text は報告")
  t.ok(r2.done and r2.direction and r2.reason and r2.issues, "agent_report_text.jsonl: 4 項目そろう")
end

do -- 実物（2026-10-01）：太字の項目名と全角コロン、太字の選択肢名
  local r = brief.parse_report("## 改善候補\n\n1. **言語の混在**\n   説明\n\n## 要確認\n\n"
    .. "- **今の作業**：README の改善点を特定する\n- **止まっている所**：言語で変わる\n"
    .. "- **確認したいこと**：日本語か英語か\n- **選択肢**：\n"
    .. "  1. **日本語のまま** → 日本語で改善を書く\n  2. **英語に統一** → 全文を英語にする\n")
  t.eq(r.kind, "ask", "太字：要確認として読む")
  t.eq(r.working, "README の改善点を特定する", "太字：今の作業")
  t.eq(r.want, "日本語か英語か", "太字：確認したいこと")
  t.eq(#r.options, 2, "太字：選択肢 2 つ")
  t.eq(r.options[1].name, "日本語のまま", "太字：選択肢の名前から ** を外す")
  t.eq(r.options[2].next, "全文を英語にする", "太字：進め方")
end

-- ============================================================
--  英語の書き方の決まり（D3）と、日本語との混在
-- ============================================================

-- ---------- parse_brief：Python の収集係と同じ例を流す（parity。Python 側は test_collector.sh） ----------
do
  local n = 0
  for line in io.lines(vim.g.agentmap_test_dir .. "/fixtures/convention_cases.jsonl") do
    if line ~= "" then
      local c = vim.json.decode(line, { luanil = { object = true, array = true } })
      n = n + 1
      t.eq(brief.parse_brief(c.prompt), c.brief, "convention_cases: " .. c.name)
    end
  end
  t.ok(n >= 15, "convention_cases は 15 件以上（" .. n .. "）")
end

t.eq(brief.parse_brief("[Goal] A\n[Why delegate] B\n[Done when] C"), { purpose = "A", reason = "B", expected = "C" }, "英語 3 つ揃い")
t.eq(brief.parse_brief("[GoAl] mixed case"), { purpose = "mixed case" }, "英語のマーカーは大文字小文字を無視")
t.eq(brief.parse_brief("[Goal] " .. string.rep("x", 400)).purpose, string.rep("x", 300), "英語も 300 文字で切る")

-- ---------- parse_report：英語の報告（8〜16 の英語版） ----------
do -- 8
  local r = brief.parse_report("Preamble\n\n## Report\n- Done: read the 12 files in models/\n- Approach: sort by dependency\n- Why: reading from downstream misses some\n- Open issues: none")
  t.eq(r.kind, "report", "en 報告: kind")
  t.eq({ r.done, r.direction, r.reason, r.issues },
    { "read the 12 files in models/", "sort by dependency", "reading from downstream misses some", "none" }, "en 報告: 4 項目")
  t.eq(r.options, nil, "en 報告には options が無い")
end
do -- 9
  local r = brief.parse_report("## Report\n- Done：fixed A\n  and B too\nApproach: small steps\n\n- Why: fast\n")
  t.eq(r.done, "fixed A and B too", "en: 複数行は空白でつなぐ・全角コロン")
  t.eq(r.direction, "small steps", "en: - 無しの項目名")
  t.eq(r.reason, "fast", "en: 空行 1 つを挟んでも次の項目")
  t.eq(r.issues, nil, "en: 書かれていない項目は nil")
end
t.eq(brief.parse_report("## Report\n- Done: A\n\n\nThat is all").done, "A", "en: 空行 2 つで終わり") -- 10
do -- 11
  local text = "## Needs confirmation\n- Working on: extending orders.sql\n- Blocked at: test scope undecided\n"
    .. "- Question: How far should the tests go?\n- Options:\n  1. Unit only → add to tests/ and finish\n"
    .. "  2) Integration too -> create a seed first\n  3. Hold"
  local r = brief.parse_report(text)
  t.eq(r.kind, "ask", "en 要確認: kind")
  t.eq({ r.working, r.stuck, r.want }, { "extending orders.sql", "test scope undecided", "How far should the tests go?" },
    "en 要確認: 3 項目")
  t.eq(r.options, {
    { n = 1, name = "Unit only", next = "add to tests/ and finish" },
    { n = 2, name = "Integration too", next = "create a seed first" },
    { n = 3, name = "Hold", next = nil },
  }, "en 選択肢: → / -> / 矢印無し")
end
t.eq(brief.parse_report("## Needs confirmation\n- Question: what now?").options, {}, "en: 選択肢無し → {}") -- 12
do -- 13
  local r = brief.parse_report("## Report\n- Done: halfway\n\n## Needs confirmation\n- Question: continue?")
  t.eq({ r.kind, r.want, r.done }, { "ask", "continue?", nil }, "en: 両方 → 後の要確認")
  local r2 = brief.parse_report("## 要確認\n- 確認したいこと: X\n## Report\n- Done: all")
  t.eq({ r2.kind, r2.done }, { "report", "all" }, "日英の見出しが混ざっても後の方")
end
do -- 14
  t.eq(brief.parse_report("### Report\n- Done: A\n### Notes\n- Why: inside notes").reason, nil, "en: 別の見出しの後ろは読まない")
  t.eq(brief.parse_report("# Report\n- Done: A").kind, nil, "en: # 1 個は見出しではない")
  t.eq(brief.parse_report("#### Report\n- Done: A").kind, nil, "en: # 4 個は見出しではない")
  t.eq(brief.parse_report("## Reports\n- Done: A").kind, nil, "en: Reports は別物")
  t.eq(brief.parse_report("## Reporting\n- Done: A").kind, nil, "en: Reporting は別物")
  t.eq(brief.parse_report("  ##  report  \n- done: A").done, "A", "en: 小文字の見出しと項目・前後の空白")
  t.eq(brief.parse_report("## REPORT\n- OPEN ISSUES: none").issues, "none", "en: 大文字の見出しと項目")
  t.eq(brief.parse_report("## Needs confirmation (this agent stopped)\n- Question: Q").want, "Q", "en: 見出しの後ろの括弧")
  t.eq(brief.parse_report("## Needs confirmation: blocked\n- Question: Q").want, "Q", "en: 見出しの後ろのコロン")
  t.eq(brief.parse_report("## Report（英語）\n- Done: A").done, "A", "en: 見出しの後ろの全角括弧")
  t.eq(brief.parse_report("## Needs confirmations\n- Question: Q").kind, nil, "en: Needs confirmations は別物")
end
do -- 15
  local r = brief.parse_report("All finished.\n- Done: A")
  t.eq({ r.kind, r.done }, { nil, nil }, "en: 見出し無し → kind nil・項目も読まない")
end
t.eq(brief.parse_report("## Report\r\n- Done: A\r\n- Approach: B").direction, "B", "en: CRLF") -- 16
-- 太字の項目名と選択肢名（英語）
do
  local r = brief.parse_report("## Needs confirmation\n\n- **Working on**: README fixes\n- **Question**: Japanese or English?\n"
    .. "- **Options**:\n  1. **Keep Japanese** -> write the fixes in Japanese\n  2. **English** → translate everything\n")
  t.eq({ r.kind, r.working, r.want }, { "ask", "README fixes", "Japanese or English?" }, "en 太字：項目")
  t.eq(r.options, { { n = 1, name = "Keep Japanese", next = "write the fixes in Japanese" },
    { n = 2, name = "English", next = "translate everything" } }, "en 太字：選択肢")
end
-- 項目名の言語は見出しの言語と違ってもよい（どちらの言語でも受ける）
do
  local r = brief.parse_report("## 報告\n- Done: A\n- 方向: B\n- Why: C\n- 残った課題: なし")
  t.eq({ r.done, r.direction, r.reason, r.issues }, { "A", "B", "C", "なし" }, "日本語の見出しに英語の項目")
  local r2 = brief.parse_report("## Needs confirmation\n- 今の作業: X\n- Blocked at: Y\n- 確認したいこと: Z\n- 選択肢:\n  1. P -> q")
  t.eq({ r2.working, r2.stuck, r2.want, #r2.options }, { "X", "Y", "Z", 1 }, "英語の見出しに日本語の項目")
end
-- Done when / Why delegate は報告の項目ではない（Done / Why と取り違えない）
do
  local r = brief.parse_report("## Report\n- Done when: tests pass\n- Why delegate: big")
  t.eq({ r.done, r.reason }, { nil, nil }, "Done when: / Why delegate: は Done / Why ではない")
end

-- ---------- split_next：矢印 2 種 × 言葉 2 種 ----------
t.eq({ brief.split_next("Use the existing table -> if chosen: extend orders") }, { "Use the existing table", "extend orders" }, "split_next: -> if chosen:")
t.eq({ brief.split_next("A → if chosen: B") }, { "A", "B" }, "split_next: → if chosen:")
t.eq({ brief.split_next("A->If Chosen：B") }, { "A", "B" }, "split_next: 大文字・空白無し・全角コロン")
t.eq({ brief.split_next("A -> B (arrow in the body) -> if chosen: C") }, { "A -> B (arrow in the body)", "C" }, "split_next: 本文の中の -> は飛ばす")
t.eq({ brief.split_next("A → 選んだら: B") }, { "A", "B" }, "split_next: → 選んだら（従来どおり）")
t.eq({ brief.split_next("A -> if chosen:") }, { "A", nil }, "split_next: en 中身が空 → nil")
t.eq({ brief.split_next("A -> if you choose: B") }, { "A -> if you choose: B", nil }, "split_next: 別の言い方は読まない")

-- ---------- answered_options / next_of（英語の HUMAN CHECK） ----------
do
  local check_en = {
    questions = { { question = "impl: dbt model: How far should the tests go?", header = "impl", multi = false,
      options = { { label = "Unit only", description = "model-level tests only -> if chosen: add to tests/ and finish" },
                  { label = "Integration too", description = "run through downstream models" } } } },
    answers = { ["impl: dbt model: How far should the tests go?"] = "Unit only" },
  }
  local a = brief.answered_options(check_en)
  t.eq(a[1].option, { i = 1, label = "Unit only", description = "model-level tests only", next = "add to tests/ and finish" },
    "en answered_options: 本文と進め方")
  local agent_en = { ask = { options = { { n = 1, name = "Unit only", next = "x" }, { n = 2, name = "Integration too", next = "create a seed first" } } } }
  t.eq(brief.next_of(check_en, 1, 2, agent_en), "create a seed first", "en next_of: 子の要確認から補う")
end

-- ---------- 英語の子の transcript の fixture ----------
do
  local function last_report(path)
    local msg, text
    for line in io.lines(path) do
      local d = vim.json.decode(line)
      if d.type == "assistant" then
        for _, b in ipairs(d.message.content) do
          if b.type == "tool_use" and b.name == "SubagentHandback" then msg = b.input.message end
          if b.type == "text" and b.text ~= "" then text = b.text end
        end
      end
    end
    return msg, text
  end
  local dir = vim.g.agentmap_test_dir .. "/fixtures/"
  local m = last_report(dir .. "agent_report_en.jsonl")
  local r = brief.parse_report(m)
  t.eq(r.kind, "ask", "agent_report_en.jsonl: handback は Needs confirmation")
  t.eq(r.want, "How far should the tests go?", "agent_report_en.jsonl: Question")
  t.eq(r.options, { { n = 1, name = "Unit only", next = "add to tests/ and finish" },
    { n = 2, name = "Integration too", next = "create a seed first, then implement" } }, "agent_report_en.jsonl: Options")
  t.eq(brief.parse_brief(vim.json.decode(io.lines(dir .. "agent_report_en.jsonl")()).message.content),
    { purpose = "Extend the orders model", reason = "Design and implementation run in parallel", expected = "orders.sql and its tests exist" },
    "agent_report_en.jsonl: 指示の [Goal] [Why delegate] [Done when]")
  local m2, txt = last_report(dir .. "agent_report_text_en.jsonl")
  t.eq(m2, nil, "agent_report_text_en.jsonl: handback 無し")
  local r2 = brief.parse_report(txt)
  t.eq(r2.kind, "report", "agent_report_text_en.jsonl: 最後の text は Report")
  t.eq(r2.issues, "none", "agent_report_text_en.jsonl: Open issues")
  t.ok(r2.done and r2.direction and r2.reason, "agent_report_text_en.jsonl: 4 項目そろう")
end

-- ---------- 手順表：parse_steps / parse_step_marks（DESIGN-v0.2 §2.1 B） ----------
t.eq(brief.parse_steps("了解。\n\n## Steps\n1. Read the current code\n2. Write the design\n3. Run the tests\n\n本文"),
  { items = { { n = 1, text = "Read the current code" }, { n = 2, text = "Write the design" }, { n = 3, text = "Run the tests" } } },
  "## Steps と番号付きの一覧")
t.eq(brief.parse_steps("### 手順\n1) 読む\n2) 書く"), { items = { { n = 1, text = "読む" }, { n = 2, text = "書く" } } }, "### 手順 と 1)")
t.eq(brief.parse_steps("## 手順（案）\n１．読む\n２．書く"), { items = { { n = 1, text = "読む" }, { n = 2, text = "書く" } } }, "全角の番号 １．と 見出しの後ろの（")
t.eq(brief.parse_steps("## STEPS:\n\n  1. a\n  2. b"), { items = { { n = 1, text = "a" }, { n = 2, text = "b" } } },
  "見出しは大小無視・後ろの : 可・見出し直後の空行と行頭の空白は可")
t.eq(brief.parse_steps("## Steps to reproduce\n1. a"), nil, "見出しの後ろに別の語（Steps to …）は見出しではない")
t.eq(brief.parse_steps("# Steps\n1. a"), nil, "# 1 つは見出しにしない")
t.eq(brief.parse_steps("## Steps\n1. a\n3. b"), nil, "番号が飛ぶ塊は無視")
t.eq(brief.parse_steps("## Steps\n2. a\n3. b"), nil, "1 から始まらない塊は無視")
local many = { "## Steps" }
for i = 1, 21 do many[#many + 1] = i .. ". s" .. i end
t.eq(brief.parse_steps(table.concat(many, "\n")), nil, "21 個以上は無視")
many[#many] = nil
t.eq(#brief.parse_steps(table.concat(many, "\n")).items, 20, "20 個までは読む")
local long = brief.parse_steps("## Steps\n1. " .. string.rep("あ", 80))
t.eq(chars(long.items[1].text), 60, "本文は 60 文字で切る")
t.eq(brief.parse_steps("## Steps\n1. a\n2. b\n本文が続く\n3. c"), { items = { { n = 1, text = "a" }, { n = 2, text = "b" } } },
  "項目でない行で一覧は終わる")
t.eq(brief.parse_steps("## Steps\n1. a\n\n## 手順\n1. x\n2. y"), { items = { { n = 1, text = "x" }, { n = 2, text = "y" } } },
  "2 回出たら後の一覧が勝つ")
t.eq(brief.parse_steps("## Steps\n1. a\n\n## Steps\n1. x\n3. y"), { items = { { n = 1, text = "a" } } },
  "後の一覧が壊れていれば前の一覧のまま")
t.eq(brief.parse_steps("ただの文"), nil, "一覧が無ければ nil")
t.eq(brief.parse_steps(nil), nil, "nil → nil")

t.eq(brief.parse_step_marks("Step 2 done"), { { n = 2, kind = "done" } }, "Step 2 done")
t.eq(brief.parse_step_marks("- **手順 2 完了**"), { { n = 2, kind = "done" } }, "- **手順 2 完了**")
t.eq(brief.parse_step_marks("step 2 DONE: tests pass"), { { n = 2, kind = "done" } }, "大小無視・後ろに文が続いてよい")
t.eq(brief.parse_step_marks("Step 3 start"), { { n = 3, kind = "start" } }, "Step 3 start")
t.eq(brief.parse_step_marks("・手順３開始"), { { n = 3, kind = "start" } }, "・と全角の番号、空白なし")
t.eq(brief.parse_step_marks("* Step 1 done\nfoo\nStep 2 done"), { { n = 1, kind = "done" }, { n = 2, kind = "done" } }, "複数の印は出た順")
t.eq(brief.parse_step_marks("Step 2 doneness"), {}, "done の後ろに英字が続けば別の語")
t.eq(brief.parse_step_marks("I finished Step 2 done"), {}, "行頭でなければ印ではない")
t.eq(brief.parse_step_marks("Step two done"), {}, "番号が無ければ印ではない")
t.eq(brief.step_events("Step 1 done\n## Steps\n1. a\nStep 1 done"),
  { { kind = "mark", n = 1, mark = "done" }, { kind = "list", items = { { n = 1, text = "a" } } }, { kind = "mark", n = 1, mark = "done" } },
  "step_events は一覧と印を出た順に返す")

t.done()
