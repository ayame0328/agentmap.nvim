-- Tests of export.lua: Markdown / HTML / PDF from hand-made states.
--   ・Markdown に 7 つの見出しがある（既定の英語。最後に setup("ja") の日本語も少し確かめる）
--   ・Mermaid の形が正しい（名前は安全な文字だけ・ラベルの記号は置き換え済み・矢印の先は全部宣言済み）
--   ・HTML は同梱の md.lua（export.html_command があればそちら）
--   ・PDF は export.pdf_command が無ければ分かりやすい知らせを出す。あれば %{html} %{out} %{title} を置き換えて呼ぶ
local t = require("t")
local mc = require("mermaid_check")
local export = require("agentmap.export")

-- 知らせ（vim.notify）を横取りして確かめる
local notes = {}
vim.notify = function(msg, lvl) notes[#notes + 1] = { msg = msg, lvl = lvl } end

-- 手で作った state（DESIGN §4 の形）。わざと扱いにくい名前や ID を混ぜる
local function hand_state()
  return {
    v = 1, run_id = "c0ffee01-0000-4000-8000-000000000001", cwd = "/tmp/proj/work",
    title = 'AgentMap "設計" [確認] <テスト>', started_at = "2026-09-28T04:23:38.000Z",
    ended_at = "2026-09-28T04:40:00.000Z", end_reason = "other",
    order = { "ROOT", "a1", "a2", "a3", "pending:toolu_01", "x-y.z", "end" },
    agents = {
      ROOT = { id = "ROOT", status = "DONE", model = "claude-fable-5-1", children = { "a1", "a3" },
        attempts = { { n = 1 } }, last_head = "全部終わりました", tool_counts = { Agent = 2, Bash = 1 },
        files = { "/tmp/proj/work/README.md" } },
      a1 = { id = "a1", index = 1, name = 'probe "child" | pipe', agent_type = "general-purpose",
        model = "claude-haiku-4-5-20251001", parent_id = "ROOT", children = { "a2" }, status = "DONE",
        attempts = {
          { n = 1, started_at = "2026-09-28T04:23:40.000Z", finished_at = "2026-09-28T04:25:00.000Z",
            submitted_at = "2026-09-28T04:25:10.000Z", verdict = "RETRY", decided_by = "user",
            reason = "根拠が無い", retried_by = "a3" },
        },
        review_count = 1, rework_count = 1, started_at = "2026-09-28T04:23:40.000Z",
        finished_at = "2026-09-28T04:25:00.000Z", elapsed_ms = 80000, tool_counts = { Write = 2 },
        files = { "/tmp/proj/work/a.lua", "/tmp/proj/work/README.md" }, last_head = "A を書きました" },
      a2 = { id = "a2", index = 2, name = "grand #1 {x}", agent_type = "Explore", model = "claude-opus-5-5",
        parent_id = "a1", children = {}, status = "DONE", attempts = { { n = 1 } }, last_head = "GRAND" },
      a3 = { id = "a3", index = 3, name = "probe child (retry)", agent_type = "general-purpose",
        parent_id = "ROOT", children = {}, status = "REVIEW", worktree = "/tmp/wt", branch = "feat/x",
        attempts = { { n = 1, retry_of = "a1", submitted_at = "2026-09-28T04:30:00.000Z" } },
        review_count = 1, rework_count = 0, started_at = "2026-09-28T04:26:00.000Z" },
      ["pending:toolu_01"] = { id = "pending:toolu_01", index = 4, placeholder = true, name = "待ち",
        parent_id = "a3", children = {}, status = "PENDING", attempts = {} },
      ["x-y.z"] = { id = "x-y.z", index = 5, name = "親不明 <a>", parent_id = nil, children = {},
        status = "FAILED", error_head = "session ended", attempts = { { n = 1 } } },
      ["end"] = { id = "end", index = 6, name = "予約語の ID", parent_id = "a2", status = "ESCALATE_TEST",
        escalated_to = "a1", attempts = { { n = 1, verdict = "ESCALATE", decided_by = "user" } },
        review_count = 1 },
    },
  }
end

local HEADINGS = { "## Run overview", "## Map", "## Agents", "## Reviews and rework", "## Steering instructions",
  "## Pauses", "## Final outputs", "## Changed files", "## Tool calls" }

local function check_markdown(md, label)
  for _, h in ipairs(HEADINGS) do
    t.ok(md:find("\n" .. h .. "\n", 1, true), label .. ": 見出しがある " .. h)
  end
  local blocks, unclosed = mc.blocks(md)
  t.eq(#blocks, 1, label .. ": mermaid の囲みが 1 つ")
  t.ok(not unclosed, label .. ": mermaid の囲みが閉じている")
  local fences = select(2, md:gsub("\n```", ""))
  t.eq(fences % 2, 0, label .. ": ``` の数が偶数（囲みが釣り合っている）")
  local errs, declared = mc.check(blocks[1] or "")
  t.eq(errs, {}, label .. ": Mermaid の形が正しい")
  return blocks[1] or "", declared
end

-- 1. 手で作った state
local s = hand_state()
local md = export.to_markdown(s, { source = "hooks" })
local mer, declared = check_markdown(md, "手作り state")
t.ok(declared.n_ROOT, "ROOT がある")
t.ok(declared.n_a1 and declared.n_a2 and declared.n_a3, "Agent の箱がある")
t.ok(declared.n_pending_toolu_01, "起動待ちの ID が安全な名前になる")
t.ok(declared.n_x_y_z, "記号入りの ID が安全な名前になる")
t.ok(declared.n_end, "予約語の ID も n_ が付いて安全")
t.ok(declared.n_UNKNOWN_PARENT, "親不明のまとめ役がある")
t.matches(mer, "\n  n_ROOT %-%-> n_a1\n", "ROOT → [1]")
t.matches(mer, "\n  n_a1 %-%-> n_a2\n", "[1] → [2]（孫）")
t.matches(mer, "\n  n_UNKNOWN_PARENT %-%.%-> n_x_y_z\n", "親不明は点線でつなぐ")
t.matches(mer, "g_a1_1{{\"Review #35;1<br/>RETRY by user\"}}", "レビューの関所（# は置き換え）")
t.matches(mer, "g_a1_1 %-%->|RETRY| n_a3", "差し戻し → 再実行した Agent へ")
t.matches(mer, "g_end_1 %-%->|ESCALATE| n_a1", "上位へ相談の矢印")
t.matches(mer, "#quot;child#quot;", "ラベルの \" は #quot; に")
t.matches(mer, "#91;1#93;", "ラベルの [ ] は文字コードに")
t.matches(mer, "classDef done", "色の定義がある")
t.matches(mer, "class n_a3 review", "REVIEW の色")
t.matches(mer, 'n_a1%["[^"]*<br/>DONE 100%.0%%"%]', "DONE の Agent は 100.0%（事実なので ~ なし）")
t.matches(mer, 'n_a3%["[^"]*<br/>REVIEW"%]', "手順表の無い REVIEW には % を出さない")
t.matches(mer, "ROOT c0ffee01", "ROOT に run の短い ID")
t.matches(mer, 'n_ROOT%["[^"]*<br/>DONE 100%.0%%"%]', "終わった ROOT は 100.0%")
t.matches(mer, 'n_x_y_z%["[^"]*<br/>FAILED"%]', "子の無い Agent に % は出さない")
t.matches(md, "```text\nROOT  fable%-5%-1  %[DONE%] 100%.0%%", "文字の木の先頭")
-- ROOT の子は時刻で 2 段（[1] 04:23–04:25 → [3] 04:26〜）に分かれる
t.matches(md, "\n├─ Stage 1\n│  └─ %[1%] probe", "文字の木に Stage 1 と [1]")
t.matches(md, "│     └─ %[2%] grand", "文字の木に孫（段の下で 1 段深い）")
t.matches(md, "\n└─ Stage 2\n   └─ %[3%] probe child", "文字の木に Stage 2 と [3]")
t.matches(md, "\nEND  %[PENDING%]\n", "文字の木の最後に END（[3] が REVIEW 中なので未完了）")
t.matches(mer, 'subgraph s_ROOT_1%["Stage 1"%]', "Mermaid：Stage 1 の囲み")
t.matches(mer, 'subgraph s_ROOT_2%["Stage 2"%]', "Mermaid：Stage 2 の囲み")
t.matches(mer, "\n  end\n", "Mermaid：囲みの終わり")
t.matches(mer, "n_START ==> n_ROOT", "Mermaid：START → ROOT")
t.matches(mer, "n_a1 ==> n_a3", "Mermaid：段1 → 段2 は順番の線")
t.matches(mer, "n_ROOT %-%-> n_a1", "Mermaid：ROOT → 段1 は起動の線")
t.matches(mer, "n_a3 ==> n_END", "Mermaid：最後の段 → END")
t.matches(mer, 'n_END%["END<br/>PENDING"%]', "Mermaid：END の状態")
t.matches(md, "\nUNKNOWN_PARENT\n└─ %[5%]", "文字の木に親不明")
t.matches(md, "Review #1 %[RETRY%] → %[3%]", "文字の木に関所と再実行先")
t.matches(md, "| 1 | probe \"child\" \\| pipe |", "表の | は \\| に")
t.matches(md, "#1 start %d%d:%d%d → finished %d%d:%d%d → submitted %d%d:%d%d → RETRY %(user%) \"根拠が無い\" → rerun %[3%]",
  "レビュー履歴の流れ")
t.matches(md, " %(rerun of %[1%]%)", "再実行元が分かる")
t.matches(md, "`/tmp/proj/work/README.md` — ROOT %[1%]", "変更ファイルと Agent")
t.matches(md, "| Agent | Agent | Bash | Write |", "ツール実行数の見出し")
t.matches(md, "> 全部終わりました", "ROOT の最終メッセージ")
t.matches(md, "| Source | hooks |", "記録元")
t.matches(md, "| Rework | 1 |", "差し戻し回数")
t.matches(md, "\n# AgentMap run record: AgentMap \"設計\" %[確認%] <テスト>\n", "題名の見出し")
t.matches(md, "\n| 4 | 待ち | %(waiting to start%) | ", "起動待ちの ID")
t.matches(md, "\n%- %[1%] probe \"child\" | pipe %(submitted 1, rework 1, now %[DONE%]%)\n", "レビュー履歴の Agent の行")
t.matches(md, "  %- Escalated to: %[1%]", "上位へ相談")
t.matches(md, "| Status | ended %(other%) |", "終わった run の状態")
t.matches(md, "feat/x", "branch")

-- 2. 空に近い state（ROOT だけ）でも壊れない
local md0 = export.to_markdown({ run_id = "r0", agents = { ROOT = { id = "ROOT", status = "RUNNING" } } })
check_markdown(md0, "ROOT だけ")
t.matches(md0, "No tool calls recorded%.", "空のときの文")
t.matches(md0, "No reviews or rework recorded%.", "レビューが無いときの文")
t.matches(md0, "No file changes recorded%.", "変更ファイルが無いときの文")
t.matches(md0, "No final messages recorded%.", "最終成果物が無いときの文")
t.matches(md0, "| Status | running %(at export time%) |", "終わっていない run の状態")
t.matches(md0, "| ROOT model | %? %(not recorded%) |", "model が無い")

-- 3. 親子が輪になっていても止まらず、全員載る
local loop = { run_id = "loop", agents = {
  ROOT = { id = "ROOT", status = "RUNNING" },
  p = { id = "p", index = 1, parent_id = "q", status = "RUNNING" },
  q = { id = "q", index = 2, parent_id = "p", status = "RUNNING" },
} }
local mdl = export.to_markdown(loop)
local _, dl = check_markdown(mdl, "輪")
t.ok(dl.n_p and dl.n_q, "輪の Agent も載る")

-- 4. B の試験用 state（あれば）
local okb, small = pcall(dofile, vim.g.agentmap_test_dir .. "/fixtures/state_small.lua")
if okb and type(small) == "table" then
  local mds = export.to_markdown(small)
  local ms = check_markdown(mds, "state_small")
  t.matches(ms, "n_ROOT %-%-> n_a1", "state_small: ROOT → a1")
  t.matches(ms, "g_a2_1 %-%->|RETRY| n_a2", "state_small: 差し戻しは自分へ戻る")
else
  t.skip("fixtures/state_small.lua が無い")
end


-- 6. 進み具合と手順（DESIGN-v0.2 §2.6）・修正指示（DESIGN-v0.2-steer §6.5）。時計と過去の記録は固定
local NOW = 1790600000
local function iso(sec) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", sec) end
local STATS = { agents = { ["general-purpose|opus"] = { n = 10, median_ms = 360000 } }, steps = {},
  all = { agents = { n = 10, median_ms = 360000 }, steps = { n = 0 } } }
local function prog_state()
  return {
    v = 1, run_id = "feed0001-0000-4000-8000-000000000001", cwd = "/tmp/proj/work", started_at = iso(NOW - 900),
    order = { "ROOT", "a1", "a2" },
    agents = {
      ROOT = { id = "ROOT", status = "RUNNING", model = "claude-fable-5-1", children = { "a1", "a2" },
        attempts = { { n = 1 } }, started_at = iso(NOW - 900) },
      a1 = { id = "a1", index = 1, name = "調査係", agent_type = "general-purpose", model = "claude-opus-5-5",
        parent_id = "ROOT", children = {}, status = "RUNNING", started_at = iso(NOW - 600), attempts = { { n = 1 } },
        tools = { { ts = iso(NOW - 100), name = "Bash", target = "ls" } },
        steps = { source = "transcript", listed_at = iso(NOW - 600), items = {
          { n = 1, text = "Read the current code", done_at = iso(NOW - 400) },
          { n = 2, text = "Write the design", done_at = iso(NOW - 70) },
          { n = 3, text = "Run the tests", started_at = iso(NOW - 60) },
        } } },
      a2 = { id = "a2", index = 2, name = "レビュー係", agent_type = "general-purpose", model = "claude-opus-5-5",
        parent_id = "ROOT", children = {}, status = "DONE", started_at = iso(NOW - 500), finished_at = iso(NOW - 300),
        attempts = { { n = 1 } }, last_head = "OK" },
    },
    steers = {
      ["a1-1"] = { id = "a1-1", agent_id = "a1", text = "資料は docs/v3 を読むこと。", via = "hook", status = "DELIVERED",
        requested_at = iso(NOW - 120), delivered_at = iso(NOW - 100), delivered_via = "PreToolUse:Write" },
      ["ROOT-1"] = { id = "ROOT-1", agent_id = "ROOT", text = "急いで", via = "terminal", status = "DELIVERED",
        requested_at = iso(NOW - 90), delivered_at = iso(NOW - 90), delivered_via = "terminal" },
      ["a2-1"] = { id = "a2-1", agent_id = "a2", text = "テストも", via = "hook", status = "EXPIRED",
        requested_at = iso(NOW - 310), ended_at = iso(NOW - 300), end_reason = "agent_finished" },
      ["a1-2"] = { id = "a1-2", agent_id = "a1", text = "まだ", via = "hook", status = "PENDING", requested_at = iso(NOW - 10) },
    },
    steer_order = { "a2-1", "a1-1", "ROOT-1", "a1-2" },
  }
end
local mdp = export.to_markdown(prog_state(), { now = NOW, stats = STATS })
check_markdown(mdp, "進み具合")
t.matches(mdp, "| %[RUNNING%] ~83%.3%% |", "Agents 表の status に推定の %（2/3 ＋ 60 s / 120 s）")
t.matches(mdp, "| %[DONE%] 100%.0%% |", "DONE は 100.0%")
-- ROOT：手順表なし・子 a1 83.3 と a2 100 の平均 → 91.6
t.matches(mdp, "| ROOT | ROOT | ROOT | main | fable%-5%-1 | %- | %[RUNNING%] ~91%.6%% |", "ROOT は子の平均")
t.matches(mdp, 'n_a1%["[^"]*<br/>RUNNING ~83%.3%%"%]', "Mermaid の札にも同じ値")
t.matches(mdp, "\n> Steps: 2/3 done · Progress: ~83%.3%%\n> ✓ 1%. Read the current code\n> ✓ 2%. Write the design\n> ▶ 3%. Run the tests\n",
  "最終成果物に手順の行")
t.matches(mdp, "\"~\" marks an estimate", "progress_note の新しい文")
t.matches(mdp, "\n## Steering instructions\n", "修正指示の見出し")
t.matches(mdp, "\n%- %[2%] レビュー係 — %d%d:%d%d:%d%d \"テストも\" → not delivered: the agent finished before it could be delivered\n", "届かないまま終了")
t.matches(mdp, "\n%- %[1%] 調査係 — %d%d:%d%d:%d%d \"資料は docs/v3 を読むこと。\" → delivered %d%d:%d%d:%d%d at PreToolUse:Write\n", "hook で配達")
t.matches(mdp, "\n%- ROOT — %d%d:%d%d:%d%d \"急いで\" → sent to the terminal %d%d:%d%d:%d%d\n", "端末へ送信")
t.matches(mdp, "→ pending at export time %(arrives at its next tool call%)\n", "未配達（expect の無い v0.1.1 の記録は次の道具）")
t.matches(mdp, "| Steering | 4 %(1 pending%) |", "概要の行")
-- 親への知らせ（付録 E）：元の指示の下に 1 行。知らせは件数にも独立の行にも入れない
local pn = prog_state()
pn.steers["ROOT-n1"] = { id = "ROOT-n1", agent_id = "ROOT", kind = "notice", notice_of = "a1-1", text = "[AgentMap] notice",
  via = "terminal", status = "DELIVERED", requested_at = iso(NOW - 99), delivered_at = iso(NOW - 99), delivered_via = "terminal" }
table.insert(pn.steer_order, "ROOT-n1")
local mdn = export.to_markdown(pn, { now = NOW, stats = STATS })
t.matches(mdn, "→ delivered %d%d:%d%d:%d%d at PreToolUse:Write\n  %- told the parent ROOT: sent to the terminal %d%d:%d%d:%d%d\n", "親に知らせた行")
t.ok(not mdn:find("[AgentMap] notice", 1, true), "知らせは独立の行にしない")
t.matches(mdn, "| Steering | 4 %(1 pending%) |", "知らせは件数に入れない")
-- 終わり際と親経由（DESIGN-v0.1.2-steer2 §7.4）：4 種の結果の語
local pr = prog_state()
pr.steers["a1-2"].expect = "stop"
pr.steers["a1-3"] = { id = "a1-3", agent_id = "a1", text = "relayed", via = "relay", expect = "parent", status = "DELIVERED",
  requested_at = iso(NOW - 80), delivered_at = iso(NOW - 79), confirmed_at = iso(NOW - 78), relayed_at = iso(NOW - 75),
  relayed_by = "ROOT", delivered_via = "SendMessage", relay_line = "[AgentMap] Tell sub-agent …" }
pr.steers["a1-4"] = { id = "a1-4", agent_id = "a1", text = "typed", via = "relay", expect = "parent", status = "DELIVERED",
  requested_at = iso(NOW - 60), delivered_at = iso(NOW - 59), delivered_via = "terminal" }
pr.steers["a1-5"] = { id = "a1-5", agent_id = "a1", text = "dropped", via = "relay", expect = "parent", status = "EXPIRED",
  requested_at = iso(NOW - 50), delivered_at = iso(NOW - 49), confirmed_at = iso(NOW - 48), end_reason = "not_relayed" }
pr.steers["a1-6"] = { id = "a1-6", agent_id = "a1", text = "unheld", via = "hook", expect = "stop", status = "DELIVERED",
  requested_at = iso(NOW - 40), delivered_at = iso(NOW - 30), delivered_via = "SubagentStop", mode = "block", held = false }
vim.list_extend(pr.steer_order, { "a1-3", "a1-4", "a1-5", "a1-6" })
local mdr = export.to_markdown(pr, { now = NOW, stats = STATS })
t.matches(mdr, "\"まだ\" → pending at export time %(arrives when the agent finishes%)\n", "未配達（終わり際）")
t.matches(mdr, "\"relayed\" → relayed " .. os.date("%H:%M:%S", NOW - 75) .. " by ROOT %(SendMessage%)\n", "親が渡した")
t.matches(mdr, "\"typed\" → sent to the main agent's terminal " .. os.date("%H:%M:%S", NOW - 59) .. ", not relayed yet\n", "打った・まだ渡っていない")
t.matches(mdr, "\"dropped\" → not relayed: the main agent ended its turn\n", "渡らなかった")
t.matches(mdr, "\"unheld\" → delivered " .. os.date("%H:%M:%S", NOW - 30) .. " at SubagentStop, not held %(Claude Code let the agent finish: its end had been held too many times in a row%)\n",
  "届けたが止められなかった")
t.matches(mdr, "| Steering | 8 %(1 pending%) |", "概要の行はそのまま（PENDING だけ数える）")
require("agentmap.i18n").setup("ja")
local mdrj = export.to_markdown(pr, { now = NOW, stats = STATS })
t.matches(mdrj, "書き出し時点で未配達（終わる直前に届く）", "ja: 終わり際")
t.matches(mdrj, "に ROOT が渡した（SendMessage）", "ja: 渡した")
t.matches(mdrj, "渡らなかった: 親が番を終えた", "ja: 渡らなかった")
t.matches(mdrj, "に配達（SubagentStop）、止められず終了（", "ja: 止められなかった")
require("agentmap.i18n").setup("en")
-- 報告を SubagentHandback で返す子（DESIGN-v0.1.2-handback §5.4）：4 種の結果の語と概要の 1 行。担当 W2
local ph = prog_state()
ph.permission_mode = "auto"
ph.steers["a1-2"] = nil
ph.steers["h1"] = { id = "h1", agent_id = "a1", n = 1, text = "skipped", via = "hook", expect = "stop", status = "PENDING",
  requested_at = iso(NOW - 80), skipped_at = iso(NOW - 70), skip_reason = "handback" }
ph.steers["h2"] = { id = "h2", agent_id = "a1", n = 2, text = "moved", via = "hook", expect = "stop", status = "CANCELLED",
  requested_at = iso(NOW - 79), skipped_at = iso(NOW - 70), ended_at = iso(NOW - 69), end_reason = "rerouted", rerouted_to = "h3" }
ph.steers["h3"] = { id = "h3", agent_id = "a1", n = 3, text = "moved", via = "relay", expect = "parent", status = "DELIVERED",
  requested_at = iso(NOW - 69), delivered_at = iso(NOW - 68), delivered_via = "SendMessage", relayed_at = iso(NOW - 60),
  relayed_by = "ROOT", rerouted_from = "h2" }
ph.steers["h4"] = { id = "h4", agent_id = "a1", n = 4, text = "old", via = "hook", expect = "stop", status = "DELIVERED",
  requested_at = iso(NOW - 50), delivered_at = iso(NOW - 40), delivered_via = "SubagentStop", mode = "block",
  held = false, held_reason = "handback" }
ph.steers["h5"] = { id = "h5", agent_id = "a1", n = 5, text = "denied", via = "hook", expect = "stop", status = "DELIVERED",
  requested_at = iso(NOW - 30), delivered_at = iso(NOW - 20), delivered_via = "PreToolUse:SubagentHandback", mode = "deny" }
ph.steer_order = { "a2-1", "a1-1", "ROOT-1", "h1", "h2", "h3", "h4", "h5" }
local mdh = export.to_markdown(ph, { now = NOW, stats = STATS })
local function hclk(sec) return os.date("%H:%M:%S", sec) end
t.matches(mdh, "\"skipped\" → pending at export time %(skipped at its end " .. hclk(NOW - 70)
  .. ": it reports through SubagentHandback%)\n", "skipped（未配達のまま）")
t.matches(mdh, "\"moved\" → cancelled " .. hclk(NOW - 69) .. " %(rerouted through the main agent as #3%)\n", "親経由に回した")
t.matches(mdh, "\"moved\" → relayed " .. hclk(NOW - 60) .. " by ROOT %(SendMessage%) · rerouted from #2\n", "回した先")
t.matches(mdh, "\"old\" → delivered " .. hclk(NOW - 40) .. " at SubagentStop, not held %(hand%-back: it had already reported%)\n",
  "古い記録の決着")
t.matches(mdh, "\"denied\" → delivered " .. hclk(NOW - 20) .. " via PreToolUse:SubagentHandback %(tool result; may be ignored%)\n",
  "deny の任意設定")
t.matches(mdh, "| Permission mode | Sub%-agents report through SubagentHandback %(permission mode auto%) |", "概要の 1 行")
t.matches(mdh, "| Steering | 8 %(1 pending%) |", "skipped は PENDING として数える")
t.ok(not mdr:find("| Permission mode |", 1, true), "auto でない run には概要の行を出さない")
require("agentmap.i18n").setup("ja")
local mdhj = export.to_markdown(ph, { now = NOW, stats = STATS })
t.matches(mdhj, "書き出し時点で未配達（" .. hclk(NOW - 70) .. " 終わり際で見送り：報告を SubagentHandback で返す子）", "ja: skipped")
t.matches(mdhj, "に取り消し（#3 として親経由に回した）", "ja: rerouted")
t.matches(mdhj, "、止められず（報告済みだった）", "ja: not held")
t.matches(mdhj, "| 権限モード | 子は報告を SubagentHandback で返す（権限モード auto） |", "ja: 概要の 1 行")
require("agentmap.i18n").setup("en")
-- 修正指示が 0 件
t.matches(md, "\n## Steering instructions\n\n%(no steering instructions%)\n", "0 件の文")
t.matches(md, "| Steering | 0 %(0 pending%) |", "0 件の概要")
-- ROOT の手順表（TaskCreate）は ROOT の最終成果物に
local ps = prog_state()
ps.agents.ROOT.tasks = { order = { "1", "2" }, items = {
  ["1"] = { id = "1", subject = "Plan", status = "completed" },
  ["2"] = { id = "2", subject = "Delegate", status = "in_progress", started_at = iso(NOW - 700) },
} }
local mdr = export.to_markdown(ps, { now = NOW, stats = STATS })
t.matches(mdr, "\n%*%*ROOT%*%*\n\n> Steps: 1/2 done · Progress: ~91%.6%%\n> ✓ 1%. Plan\n> ▶ 2%. Delegate\n", "ROOT の手順（1/2 ＋ 動いている子 83.3）")
-- 日本語
require("agentmap.i18n").setup("ja")
local mdpj = export.to_markdown(prog_state(), { now = NOW, stats = STATS })
t.matches(mdpj, "\n> 手順: 2/3 済 · 進み具合: ~83%.3%%\n", "日本語: 手順の行")
t.matches(mdpj, "\n## 修正指示\n", "日本語: 修正指示の見出し")
t.matches(mdpj, "| 修正指示 | 4 件（未配達 1） |", "日本語: 概要の行")
require("agentmap.i18n").setup("en")

-- 一時停止（DESIGN-v0.1.2-pause §6.6）：「## Steering instructions」の次に 1 件 1 行。Overview に件数と関門
local function clk(sec) return os.date("%H:%M:%S", sec) end
local function pause_state()
  local x = prog_state()
  x.steers["a1-1"].n = 2
  x.pauses = {
    ["a1-p1"] = { id = "a1-p1", agent_id = "a1", kind = "pause", at = "next", status = "RESUMED", requested_at = iso(NOW - 300),
      hit_at = iso(NOW - 294), hit_via = "PreToolUse:Read", released_at = iso(NOW - 100), release_reason = "user",
      steer_id = "a1-1", waited_ms = 194000 },
    ["a2-p1"] = { id = "a2-p1", agent_id = "a2", kind = "gate", at = "stop", status = "PAUSED", requested_at = iso(NOW - 50),
      hit_at = iso(NOW - 45), hit_via = "SubagentStop", deadline = NOW + 555 },
    ["ROOT-p1"] = { id = "ROOT-p1", agent_id = "ROOT", kind = "pause", at = "stop", status = "RESUMED", requested_at = iso(NOW - 800),
      hit_at = iso(NOW - 790), hit_via = "Stop", released_at = iso(NOW - 190), release_reason = "auto", waited_ms = 600000 },
    ["a1-p2"] = { id = "a1-p2", agent_id = "a1", kind = "pause", at = "next", status = "EXPIRED", requested_at = iso(NOW - 20),
      end_reason = "session_ended" },
  }
  x.pause_order = { "ROOT-p1", "a1-p1", "a2-p1", "a1-p2" }
  return x
end
local mdz = export.to_markdown(pause_state(), { now = NOW, stats = STATS })
check_markdown(mdz, "一時停止")
t.matches(mdz, "\n## Steering instructions\n.-\n## Pauses\n\n", "## Pauses は ## Steering instructions の次")
t.ok(mdz:find("\n- ROOT — " .. clk(NOW - 800) .. " pause → paused " .. clk(NOW - 790) .. " (Stop) → resumed automatically "
  .. clk(NOW - 190) .. " (10 min)\n", 1, true), "自動で再開した行")
t.ok(mdz:find("\n- [1] 調査係 — " .. clk(NOW - 300) .. " pause → paused " .. clk(NOW - 294) .. " (PreToolUse:Read) → resumed by the user "
  .. clk(NOW - 100) .. " with instruction #2\n", 1, true), "指示つきで再開した行")
t.ok(mdz:find("\n- [2] レビュー係 — " .. clk(NOW - 50) .. " gate → waiting at SubagentStop since " .. clk(NOW - 45)
  .. " (at export time)\n", 1, true), "関門で待っている行")
t.ok(mdz:find("\n- [1] 調査係 — " .. clk(NOW - 20) .. " pause → not reached: the session ended\n", 1, true), "止まらず終わった行")
local i_root, i_a1 = mdz:find("\n- ROOT — " .. clk(NOW - 800), 1, true), mdz:find("\n- [1] 調査係 — " .. clk(NOW - 300), 1, true)
t.ok(i_root and i_a1 and i_root < i_a1, "pause_order の順")
t.matches(mdz, "| Pauses | 4 %(1 waiting%) |", "Overview の件数")
t.ok(not mdz:find("| Gate |", 1, true), "関門が切なら Gate の行は無い")
local mz = mc.blocks(mdz)[1] or ""
t.ok(mz ~= "" and not mz:find("PAUSED", 1, true) and not mz:find("GATE", 1, true) and not mz:find("pause", 1, true), "Mermaid には出さない")
local zg = pause_state()
zg.gate = true
local mdg = export.to_markdown(zg, { now = NOW, stats = STATS })
t.matches(mdg, "| Gate | on |\n| Status |", "関門が入なら Gate: on（Status の前）")
zg.gate = nil
require("agentmap.config").setup({ pause = { gate = true } })
t.matches(export.to_markdown(zg, { now = NOW, stats = STATS }), "| Gate | on |", "run に記録が無ければ設定の初期値")
zg.gate = false
t.ok(not export.to_markdown(zg, { now = NOW, stats = STATS }):find("| Gate |", 1, true), "run で切ったなら設定より run の記録")
require("agentmap.config").setup({})
-- 0 件
t.matches(md, "\n## Pauses\n\n%(no pauses%)\n", "0 件の文")
t.matches(md, "| Pauses | 0 %(0 waiting%) |", "0 件の概要")
-- 日本語
require("agentmap.i18n").setup("ja")
local mdzj = export.to_markdown(pause_state(), { now = NOW, stats = STATS })
t.matches(mdzj, "\n## 一時停止\n", "日本語: 見出し")
t.ok(mdzj:find("\n- [2] レビュー係 — " .. clk(NOW - 50) .. " 関門 → " .. clk(NOW - 45) .. " から SubagentStop で待機中（書き出し時点）\n", 1, true),
  "日本語: 待機中の行")
t.matches(mdzj, "| 一時停止 | 4 件（待機中 1） |", "日本語: 概要")
t.matches(export.to_markdown({ run_id = "r0", agents = { ROOT = { id = "ROOT", status = "RUNNING" } } }), "\n## 一時停止\n\n（一時停止なし）\n", "日本語: 0 件")
require("agentmap.i18n").setup("en")

-- 5. ファイルに書き出す（markdown / html / pdf）
local dir = vim.fn.tempname()
local p_md = export.write(s, "markdown", dir .. "/out.md")
t.eq(p_md, dir .. "/out.md", "markdown を書き出した")
local function no_stamp(x) return (x:gsub("Exported: [^\n]*", "")) end
t.eq(no_stamp(table.concat(vim.fn.readfile(p_md), "\n") .. "\n"), no_stamp(export.to_markdown(s, {})),
  "書き出した中身は to_markdown と同じ")
t.matches(notes[#notes] and notes[#notes].msg or "", "^AgentMap: Exported: " .. vim.pesc(dir) .. "/out%.md", "書き出した知らせ")

local p_def = export.write(s, "md", nil, { dir = dir .. "/run" })
t.matches(p_def or "", "^" .. vim.pesc(dir) .. "/run/exports/agentmap%-c0ffee01%-%d+%-%d+%.md$", "既定の書き出し先")

-- HTML：同梱の md.lua（外部の道具は使わない）
local cfg = require("agentmap.config").get()
cfg.export = cfg.export or {}
cfg.export.html_command, cfg.export.pdf_command = nil, nil
local p_html = export.write(s, "html", dir .. "/out.html")
t.eq(p_html, dir .. "/out.html", "html を書き出した")
local html = p_html and table.concat(vim.fn.readfile(p_html), "\n") or ""
t.matches(html, "^<!doctype html>", "HTML になっている")
t.matches(html, "<title>AgentMap run record c0ffee01</title>", "題名が入っている")
t.matches(html, '<h2 id="sec%-%d+">Agents</h2>', "見出しが入っている")
t.ok(html:find("AgentMap \"設計\" [確認] &lt;テスト&gt;", 1, true) ~= nil, "本文の < > は置き換える")
t.matches(html, '<pre class="mermaid">flowchart LR\n', "Mermaid は元の文のまま残す")
t.ok(html:find("n_a1 %-%-&gt; n_a2") ~= nil, "Mermaid の矢印の > は置き換える")
t.matches(html, "prefers%-color%-scheme: dark", "暗い配色にも対応")
t.matches(html, '<nav class="toc">', "目次がある")
t.ok(not html:find("<script", 1, true) and not html:find("<link", 1, true) and not html:find("@import", 1, true)
  and not html:find("https?://") and not html:find("url%("), "外部の読み込みが無い")

-- HTML：export.html_command があればそちら（標準入力に Markdown、最後の引数に題名）
cfg.export.html_command = { "sh", "-c", 'cat > /dev/null; printf "<p>%s</p>" "$1"', "sh" }
local p_html2 = export.write(s, "html", dir .. "/cmd.html")
t.eq(p_html2, dir .. "/cmd.html", "html_command で書き出した")
t.eq(p_html2 and table.concat(vim.fn.readfile(p_html2), "\n"), "<p>AgentMap run record c0ffee01</p>", "html_command の出力をそのまま書く")
cfg.export.html_command = { "sh", "-c", "exit 3" }
notes = {}
t.eq(export.write(s, "html", dir .. "/bad.html"), nil, "html_command が失敗したら nil")
t.matches(notes[#notes] and notes[#notes].msg or "", "HTML conversion failed", "失敗を知らせる")
t.eq(notes[#notes] and notes[#notes].lvl, vim.log.levels.ERROR, "知らせは ERROR")
cfg.export.html_command = nil

-- PDF：export.pdf_command が無いとき（D4）
notes = {}
t.eq(export.write(s, "pdf", dir .. "/out.pdf"), nil, "PDF の設定が無いと nil")
t.matches(notes[#notes] and notes[#notes].msg or "", "PDF export is not configured%. Set export%.pdf_command", "PDF が使えない理由を知らせる")
t.eq(notes[#notes] and notes[#notes].lvl, vim.log.levels.WARN, "知らせは WARN")
t.ok(not vim.uv.fs_stat(dir .. "/out.pdf"), "何も作らない")

-- PDF：export.pdf_command があるとき（本物のブラウザは呼ばず、HTML をそのまま写すコマンドで呼ばれ方を見る）
cfg.export.pdf_command = { "sh", "-c", 'cp "$1" "$2" && printf "%s" "$3" > "$2.title"', "sh", "%{html}", "%{out}", "%{title}" }
notes = {}
t.eq(export.write(s, "pdf", dir .. "/out.pdf"), dir .. "/out.pdf", "PDF の書き出し先を返す")
local pdf_in = table.concat(vim.fn.readfile(dir .. "/out.pdf"), "\n")
t.matches(pdf_in, "^<!doctype html>", "%{html} に HTML のファイルを渡している")
t.matches(pdf_in, "<h2 id=\"sec%-%d+\">Map</h2>", "HTML の中身は書き出しと同じ")
t.eq(table.concat(vim.fn.readfile(dir .. "/out.pdf.title"), "\n"), "AgentMap run record c0ffee01", "%{title} を置き換える")
t.eq(vim.fn.glob(dir .. "/*.agentmap-print.html"), "", "印刷用の一時 HTML は消す")
t.matches(notes[#notes] and notes[#notes].msg or "", "^AgentMap: Exported: .*/out%.pdf", "書き出した知らせ")
-- 失敗するコマンド・PDF を作らないコマンド
cfg.export.pdf_command = { "sh", "-c", "echo broken >&2; exit 2" }
notes = {}
t.eq(export.write(s, "pdf", dir .. "/x.pdf"), nil, "コマンドが失敗したら nil")
t.matches(notes[#notes] and notes[#notes].msg or "", "PDF export failed.*broken", "失敗と標準エラーを知らせる")
cfg.export.pdf_command = { "true" }
notes = {}
t.eq(export.write(s, "pdf", dir .. "/y.pdf"), nil, "PDF ができなければ nil")
t.matches(notes[#notes] and notes[#notes].msg or "", "did not create .*/y%.pdf", "できていないことを知らせる")
cfg.export.pdf_command = nil
-- argv の組み立て：/mnt/ で始まるコマンド（WSL から Windows のプログラム）だけ Windows の道のりにする（S13）
t.eq(export.pdf_argv({ "/mnt/c/Program Files/chrome.exe", "--print-to-pdf=%{out}", "%{html}", "--t=%{title}", "%{nope}" },
  "/mnt/c/tmp/a.html", "/mnt/c/tmp/a.pdf", "T 100%"),
  { "/mnt/c/Program Files/chrome.exe", "--print-to-pdf=C:\\tmp\\a.pdf", "C:\\tmp\\a.html", "--t=T 100%", "%{nope}" },
  "/mnt/ のコマンドは道のりを Windows 形式に")
t.eq(export.pdf_argv({ "chromium", "--print-to-pdf=%{out}", "%{html}" }, "/tmp/a.html", "/tmp/a.pdf", "t"),
  { "chromium", "--print-to-pdf=/tmp/a.pdf", "/tmp/a.html" }, "ふつうのコマンドは道のりそのまま")
t.eq(export.pdf_argv("wkhtmltopdf", "/tmp/a.html", "/tmp/a.pdf", "t"), { "wkhtmltopdf" }, "文字列 1 つのコマンドも受ける")

-- 知らない形式
t.eq(export.write(s, "docx", dir .. "/x.docx"), nil, "知らない形式は nil")

-- 本物の mermaid があれば、そちらでも確かめる
for label, src in pairs({ hand = mer, root_only = mc.blocks(md0)[1], loop = mc.blocks(mdl)[1] }) do
  local real, out = mc.mmdc(src)
  if real == nil then
    t.skip("mermaid-cli（mmdc）が無いので、形の確認だけ")
    break
  end
  t.ok(real, "本物の mermaid でも読める: " .. label .. "\n" .. tostring(out))
end

-- setup({ lang = "ja" }) で今までの日本語の書き出し
require("agentmap.i18n").setup("ja")
local mdj = export.to_markdown(hand_state(), { source = "hooks" })
for _, h in ipairs({ "## Run 概要", "## 構成図", "## Agent 一覧", "## レビュー・差し戻し履歴",
  "## 最終成果物", "## 主な変更ファイル", "## ツール実行数" }) do
  t.ok(mdj:find("\n" .. h .. "\n", 1, true), "日本語: 見出しがある " .. h)
end
t.matches(mdj, "\ntitle: AgentMap 実行記録 c0ffee01\n", "日本語: 題名")
t.matches(mdj, 'subgraph s_ROOT_1%["段1"%]', "日本語: Mermaid の 段1")
t.matches(mdj, "\n├─ 段1\n", "日本語: 文字の木の 段1")
t.matches(mdj, "#1 開始 %d%d:%d%d → 完了 %d%d:%d%d → 提出 %d%d:%d%d → RETRY（user）「根拠が無い」 → 再実行 %[3%]", "日本語: レビュー履歴")
t.matches(mdj, "| 記録元 | hooks |", "日本語: 記録元")
t.eq(mc.check(mc.blocks(mdj)[1] or ""), {}, "日本語でも Mermaid の形が正しい")
t.matches(require("agentmap.md").to_html(mdj), '<html lang="ja">', "日本語: HTML の lang")
require("agentmap.i18n").setup("en")

vim.fn.delete(dir, "rf")
t.done()
