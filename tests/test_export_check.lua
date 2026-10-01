-- Tests of export.lua for HUMAN CHECK sections and the delegation / report fields (English by default;
-- section 13 checks the Japanese export with setup("ja")).
--   state は fixtures/state_check.lua（SV=8 の形）。reducer（state.lua）を通さず書き出しだけを確かめる。
local t = require("t")
local mc = require("mermaid_check")
local export = require("agentmap.export")

vim.notify = function() end

local function load()
  return dofile(vim.g.agentmap_test_dir .. "/fixtures/state_check.lua")
end

local s = load()
local md = export.to_markdown(s, { source = "hooks" })

-- 1. 見出し：既存の 7 つは残り、新しい節が「レビュー・差し戻し履歴」の次に入る
for _, h in ipairs({ "## Run overview", "## Map", "## Agents", "## Reviews and rework",
  "## Human checks (HUMAN CHECK)", "## Final outputs", "## Changed files", "## Tool calls" }) do
  t.ok(md:find("\n" .. h .. "\n", 1, true), "見出しがある " .. h)
end
local p_rev = md:find("\n## Reviews and rework\n", 1, true) or 0
local p_chk = md:find("\n## Human checks (HUMAN CHECK)\n", 1, true) or 0
local p_out = md:find("\n## Final outputs\n", 1, true) or 0
t.ok(p_rev < p_chk and p_chk < p_out, "人の確認の節はレビュー履歴の次・最終成果物の前")

-- 2. 人の確認の節：2 件、状態・答え・進め方
local sec = md:sub(p_chk, p_out)
t.eq(select(2, sec:gsub("\n### HUMAN CHECK #", "")), 2, "HUMAN CHECK が 2 件")
t.matches(sec, "\n### HUMAN CHECK #1 %[DONE%]  asked %d%d:%d%d:%d%d  answered %d%d:%d%d:%d%d\n", "#1 は答え済み（DONE）と時刻")
t.matches(sec, "\n### HUMAN CHECK #2 %[WAITING%]  asked %d%d:%d%d:%d%d  waiting\n", "#2 は確認待ち")
t.matches(sec, "%- Asked by: ROOT", "聞いた側")
t.matches(sec, "%- Trigger: asked directly by the asker", "#1 は直接の質問")
t.matches(sec, "%- Trigger: \"Needs confirmation\" from %[2%] 実装：dbt model %(the question names the child%)", "#2 は [2] の要確認から")
t.matches(sec, "%- Asker's last words: \"設計の分かれ道なので先に聞きます\"", "#1 の直前の発言")
t.matches(sec, "%- Asker's last words: %(no preceding message%)", "#2 は直前の発言なし")
t.matches(sec, "%- Working on %(from the child's report%): orders%.sql の拡張", "子の今の作業")
t.matches(sec, "%- Blocked at %(from the child's report%): テストの範囲が決まらない", "子の止まっている所")
t.matches(sec, "%- Question %(from the child's report%): テストはどこまで書きますか？", "子の確認したいこと")
t.matches(sec, "%- Question: %[設計%] どちらの設計で進めますか？", "#1 の質問")
t.matches(sec, "\n  1%. A案 — 既存の表を使う %-> if chosen: 既存の orders を拡張\n", "選択肢と選んだ後の進め方")
t.matches(sec, "\n  2%. B案 — 新しい表を作る %-> if chosen: orders_v2 を新設\n", "選択肢 2")
t.matches(sec, "\n%- Answer: \"A案\"\n  %- Next step: 既存の orders を拡張\n", "答えとこの後の進め方")
t.matches(sec, "\n  1%. 単体のみ — モデル単位のテストだけ %-> if chosen: tests/ に追加して終了\n", "#2 の選択肢")
t.matches(sec, "%- Answer: %(not answered yet; answer in the terminal%)", "#2 は未回答の文")

-- 3. Run 概要
t.matches(md, "| Human checks | 2 %(1 unanswered%) |", "Run 概要に人の確認の回数")

-- 4. Mermaid：c_ ノード・色・線・段
local blocks, unclosed = mc.blocks(md)
t.eq(#blocks, 1, "mermaid の囲みが 1 つ")
t.ok(not unclosed, "mermaid の囲みが閉じている")
local mer = blocks[1] or ""
local errs, declared = mc.check(mer)
t.eq(errs, {}, "Mermaid の形が正しい（mermaid_check）")
t.ok(declared.c_toolu_B and declared.c_toolu_Q, "check の箱が c_<tool_use_id> で宣言される")
t.matches(mer, "c_toolu_Q%[\"HUMAN CHECK #35;2<br/>WAITING<br/>", "#2 の箱の中身（# は置き換え）")
t.matches(mer, "c_toolu_B%[\"HUMAN CHECK #35;1<br/>DONE<br/>[^\"]*<br/>→ A案\"%]", "#1 の箱に答え")
t.matches(mer, "classDef waiting fill:#efe3ff,stroke:#b083f0,color:#000", "waiting の色の定義")
t.matches(mer, "\n  class c_toolu_Q waiting\n", "WAITING は waiting 色")
t.matches(mer, "\n  class c_toolu_B done\n", "ANSWERED は done 色（緑）")
t.matches(mer, "\n  n_a2 %-%-> c_toolu_Q\n", "子の要確認の check は子の後ろ")
t.matches(mer, "\n  n_ROOT %-%-> n_a1\n", "ROOT → 段1 の [1]")
t.matches(mer, "\n  n_a1 ==> c_toolu_B\n", "直接の check は段の要素（[1] の次の段）")
t.matches(mer, "\n  c_toolu_B ==> n_a2\n", "答えてから [2]（次の段）")
t.matches(mer, "\n  n_a2 ==> n_END\n", "最後の段 → END")
t.matches(mer, 'subgraph s_ROOT_3%["Stage 3"%]', "ROOT の子は 3 段（[1] → check → [2]）")
t.ok(not mer:find("n_check", 1, true), "check を Agent の名前（n_）で参照していない")

-- 5. 文字の木
t.matches(md, "\n├─ Stage 1\n│  └─ %[1%] 調査：既存モデル", "文字の木：Stage 1 に [1]")
t.matches(md, "\n├─ Stage 2\n│  └─ HUMAN CHECK #1 %[DONE%] \"どちらの設計で進めますか？\" → A案\n", "文字の木：Stage 2 に直接の check と答え（header が質問に含まれるので重ねない）")
-- header が質問文に含まれないときは「header: question」
local sh = dofile(vim.g.agentmap_test_dir .. "/fixtures/state_check.lua")
sh.checks["check:toolu_B"].questions[1].header = "方針"
t.matches(export.to_markdown(sh), "HUMAN CHECK #1 %[DONE%] \"方針: どちらの設計で進めますか？\"", "header を前に付ける")
t.matches(md, "\n└─ Stage 3\n   └─ %[2%] 実装：dbt model[^\n]*\n      └─ HUMAN CHECK #2 %[WAITING%] \"", "文字の木：[2] の下に確認待ち")

-- 6. 最終成果物：任せた内容と報告／要確認
local out = md:sub(p_out)
t.matches(out, "%*%*%[1%] 調査：既存モデル%*%*\n\n> Goal: 既存の dbt モデルを把握する\n> Why delegate: ファイルが多い\n> Done when: 一覧\n>\n> Done: models/ の 12 本を読んだ\n> Approach: 依存の順に整理\n> Why: 下流から見ると漏れる\n> Open issues: なし\n",
  "[1] の目的と報告 4 項目")
t.matches(out, "> Goal: orders を拡張する\n> Why delegate: %(not written%)\n", "[2] の欠けた項目は (not written)")
t.matches(out, "> Needs confirmation %(this agent stopped to wait for an answer%)\n> Working on: orders%.sql の拡張\n", "[2] は要確認")
t.matches(out, "> Options: 1%. 単体のみ → tests/ に追加して終了 / 2%. 結合まで → seed を作ってから実装", "要確認の選択肢")
t.ok(not out:find("> 調査完了", 1, true), "報告の 4 項目があるときは last_head を出さない")

-- 7. 決まりの見出しが無い報告は原文（800 文字まで）
local s2 = load()
s2.agents.a1.report_fields = nil
s2.agents.a1.report = "ふつうの返事です\n" .. string.rep("あ", 900)
local md2 = export.to_markdown(s2)
t.matches(md2, ">\n> No convention headings %(## Report / ## Needs confirmation%)%. Original text:\n> ふつうの返事です\n", "見出しの無い報告は原文")
t.ok(md2:find(string.rep("あ", 790), 1, true) and not md2:find(string.rep("あ", 800), 1, true), "原文は 800 文字で切る")
-- brief も報告も無い Agent は今までどおり last_head の引用
s2.agents.a1.brief, s2.agents.a1.report = nil, nil
t.matches(export.to_markdown(s2), "%*%*%[1%] 調査：既存モデル%*%*\n\n> 調査完了\n", "何も無ければ last_head")

-- 8. 答えの形：配列（複数選択）・自由入力・未回答のまま終了
local s3 = load()
local B = s3.checks["check:toolu_B"]
B.questions[1].multi = true
B.answers = { ["どちらの設計で進めますか？"] = { "A案", "B案" } }
local Q = s3.checks["check:toolu_Q"]
Q.status, Q.ended_at, Q.end_reason = "ABANDONED", "2026-10-01T10:00:40.000Z", "new_prompt"
local md3 = export.to_markdown(s3)
t.matches(md3, " %(multiple choice%)", "複数選択の印")
t.matches(md3, "%- Answer: \"A案\"\n  %- Next step: 既存の orders を拡張\n%- Answer: \"B案\"\n  %- Next step: orders_v2 を新設\n", "配列の答えは 1 つずつ")
t.matches(md3, "→ A案, B案", "図の答えは「A, B」")
t.matches(md3, "### HUMAN CHECK #2 %[UNANSWERED%]  asked [%d:]+  unanswered", "未回答のまま終わった check")
t.matches(md3, "%(ended without an answer: a new prompt arrived%)", "終わった理由")
t.matches(md3, "| Human checks | 2 %(1 unanswered%) |", "未回答の数")
t.matches(md3, "\n  class c_toolu_Q pending\n", "未回答は灰色")
B.answers = { ["どちらの設計で進めますか？"] = "C案でお願いします" }
local md3b = export.to_markdown(s3)
t.matches(md3b, "%- Answer: %(free text%) \"C案でお願いします\"", "自由入力の答え")
t.eq(mc.check(mc.blocks(md3b)[1] or ""), {}, "答えの形が変わっても Mermaid は正しい")

-- 9. check が無い state：「記録はありません」・既存の形は崩れない
local s4 = load()
s4.checks, s4.check_order = nil, nil
s4.agents.ROOT.checks, s4.agents.a2.checks, s4.agents.a2.ask_check = nil, nil, nil
local md4 = export.to_markdown(s4)
t.matches(md4, "\n## Human checks %(HUMAN CHECK%)\n\nNo human checks recorded%.\n", "check が無いときの文")
t.matches(md4, "| Human checks | 0 |", "Run 概要は 0 回")
t.eq(mc.check(mc.blocks(md4)[1] or ""), {}, "check が無くても Mermaid は正しい")
t.ok(not md4:find("c_toolu", 1, true), "check の箱は出ない")

-- 10. check_order に無い check・owner が実在しない check でも落ちずに ROOT に付く
local s5 = load()
s5.check_order = {}
s5.checks["check:toolu_B"].owner_id = "gone"
local ok5, md5 = pcall(export.to_markdown, s5)
t.ok(ok5, "check_order が空でも書き出せる: " .. tostring(not ok5 and md5 or ""))
if ok5 then
  t.eq(select(2, md5:gsub("\n### HUMAN CHECK #", "")), 2, "check_order に無くても 2 件")
  t.eq(mc.check(mc.blocks(md5)[1] or ""), {}, "Mermaid は正しい")
end

-- 11. ファイルに書き出しても同じ中身
local dir = vim.fn.tempname()
local p = export.write(s, "markdown", dir .. "/chk.md")
t.eq(p, dir .. "/chk.md", "markdown を書き出した")
t.matches(table.concat(vim.fn.readfile(p or ""), "\n"), "## Human checks %(HUMAN CHECK%)", "書き出したファイルに人の確認の節")
vim.fn.delete(dir, "rf")

-- 13. setup({ lang = "ja" }) では今までの日本語の書き出し
require("agentmap.i18n").setup("ja")
local mdj = export.to_markdown(load(), { source = "hooks" })
t.matches(mdj, "\n## 人の確認（HUMAN CHECK）\n", "日本語: 人の確認の節")
t.matches(mdj, "\n### HUMAN CHECK #1 %[DONE%]  聞いた %d%d:%d%d:%d%d  答え %d%d:%d%d:%d%d\n", "日本語: #1 の見出し")
t.matches(mdj, "%- きっかけ: %[2%] 実装：dbt model の「要確認」（質問文に子の名前があった）", "日本語: きっかけ")
t.matches(mdj, "\n  1%. A案 — 既存の表を使う → 選んだら: 既存の orders を拡張\n", "日本語: 選択肢")
t.matches(mdj, "\n%- 答え: 「A案」\n  %- この後の進め方: 既存の orders を拡張\n", "日本語: 答え")
t.matches(mdj, "| 人の確認 | 2 回（未回答 1） |", "日本語: 回数")
t.matches(mdj, "> 目的: orders を拡張する\n> 任せる理由: （書かれていません）\n", "日本語: 欠けた項目")
t.matches(mdj, "> 要確認（この Agent は確認待ちで止まりました）\n> 今の作業: orders%.sql の拡張\n", "日本語: 要確認")
t.matches(mdj, "\n└─ 段3\n", "日本語: 段")
require("agentmap.i18n").setup("en")

-- 12. 本物の mermaid があれば、そちらでも確かめる
local real, outm = mc.mmdc(mer)
if real == nil then
  t.skip("mermaid-cli（mmdc）が無いので、形の確認だけ")
else
  t.ok(real, "本物の mermaid でも読める\n" .. tostring(outm))
end

t.done()
