-- 詳細画面（任せた内容・人の確認・作業の経過・報告）と HUMAN CHECK の画面、画面の行き来の試験（担当 B）
--   実行: nvim --headless --clean -u tests/minimal_init.lua -l tests/test_check_views.lua
local t = require("t")
local here = vim.g.agentmap_test_dir
vim.o.columns, vim.o.lines = 220, 60

local detail = require("agentmap.views.detail")
local checkv = require("agentmap.views.check")
local brief = require("agentmap.brief")

local function fixture() return dofile(here .. "/fixtures/state_check.lua") end
local function text(res) return table.concat(res.lines, "\n") end
local function row_of(res, pat)
  for i, l in ipairs(res.lines) do
    if l:find(pat, 1, true) then return i, l end
  end
end
local function has(res, s, msg) t.ok(text(res):find(s, 1, true) ~= nil, (msg or "") .. "：「" .. s .. "」がある") end
local function hasnt(res, s, msg) t.ok(text(res):find(s, 1, true) == nil, (msg or "") .. "：「" .. s .. "」が無い") end

-- ------------------------------------------------------------
-- 1. 詳細：任せた内容（親の指示）
-- ------------------------------------------------------------
local s = fixture()
local d1 = detail.build(s, s.agents.a1, { width = 100 })
has(d1, "■ Task given (parent's prompt)", "[1]")
t.matches(text(d1), "Goal%s+既存の dbt モデルを把握する", "目的")
t.matches(text(d1), "Why delegate%s+ファイルが多い", "任せる理由")
t.matches(text(d1), "Done when%s+一覧", "期待する結果")
t.matches(text(d1), "Parent said%s+\"まず現状を調べてから設計を決めます\"", "親の直前の発言")
hasnt(d1, "prompt:", "brief が読めたら prompt: 行は出さない")

local d2 = detail.build(s, s.agents.a2, { width = 100 })
t.matches(text(d2), "Why delegate%s+%(not written%)", "欠けた項目は（書かれていません）")
t.matches(text(d2), "Done when%s+%(not written%)", "欠けた項目は（書かれていません）2")
t.matches(text(d2), "Parent said%s+%(nothing said just before%)", "直前の発言が無いとき")

local s0 = fixture()
s0.agents.a1.brief = nil
local d0 = detail.build(s0, s0.agents.a1, { width = 100 })
has(d0, "No convention markers ([Goal] etc.). Start of the prompt:", "brief 無し")
has(d0, "【目的】既存の dbt モデルを把握する", "brief 無しなら指示の先頭をそのまま")

local dr = detail.build(s, s.agents.ROOT, { width = 100 })
has(dr, "■ Prompt", "ROOT")
hasnt(dr, "■ Task given", "ROOT には任せた内容の節を出さない")

-- ------------------------------------------------------------
-- 2. 詳細：人の確認（行リンク = check の id）
-- ------------------------------------------------------------
local hr = row_of(d2, "■ Human checks (1)")
t.ok(hr ~= nil, "[2] に「■ Human checks (1)」")
local qrow = row_of(d2, "HUMAN CHECK #2")
t.ok(qrow and qrow == hr + 1, "人の確認の 1 行目に HUMAN CHECK #2")
t.eq(d2.links[qrow], "check:toolu_Q", "その行のリンクは check の id")
t.matches(d2.lines[qrow], "%[WAITING%]", "状態の札")
local rr = row_of(dr, "HUMAN CHECK #1")
t.eq(dr.links[rr], "check:toolu_B", "ROOT の直接の質問も人の確認に出る")
hasnt(d1, "■ Human checks", "確認の無い Agent には節を出さない")
-- 要確認を書いたのにまだ質問されていない（§14 の 19：箱は作らず、ここで分かるようにする）
local su = fixture()
su.agents.a2.ask_check, su.agents.a2.checks = nil, {}
su.checks["check:toolu_Q"] = nil
su.check_order = { "check:toolu_B" }
local du = detail.build(su, su.agents.a2, { width = 120 })
has(du, "■ Human checks (0)", "未質問")
has(du, "Reported a question, but it has not been asked yet: \"テストはどこまで書きますか？\"", "未質問")
t.matches(text(du), "Asked%s+not asked yet", "要確認の節にも「not asked yet」")

-- ------------------------------------------------------------
-- 3. 詳細：作業の経過（transcript から。note と tool が時刻順に混ざる）
-- ------------------------------------------------------------
local sn = fixture()
sn.agents.a2.transcript_path = here .. "/fixtures/agent_report.jsonl"
local notes = detail.read_notes({ state = sn }, sn.agents.a2)
t.ok(type(notes) == "table" and #notes >= 4, "agent_report.jsonl から作業の経過を読む（件数 " .. tostring(notes and #notes) .. "）")
local kinds, sorted = {}, true
for i, n in ipairs(notes or {}) do
  kinds[n.kind] = true
  if i > 1 and (notes[i - 1].ts or "") > (n.ts or "") then sorted = false end
end
t.ok(kinds.note and kinds.tool, "発言（note）とツール（tool）が両方ある")
t.ok(sorted, "時刻順")
local dn = detail.build(sn, sn.agents.a2, { width = 100, notes = notes })
local prow = row_of(dn, "■ Progress (last ")
t.ok(prow ~= nil, "「■ 作業の経過」の見出し")
hasnt(dn, "■ ツール実行", "旧「ツール実行」の節は無い")
has(dn, "まず既存のモデルを読みます", "子の発言")
t.matches(text(dn), "Read%s+/tmp/agentmap%-test/ask/models/orders%.sql", "ツールの行")
local first_note = row_of(dn, "まず既存のモデルを読みます")
local read_row = row_of(dn, "Read ")
t.ok(first_note < read_row, "発言 → ツールの順（時刻順）")
-- 上限 40 件（直近だけ）
local many = {}
for i = 1, 50 do
  many[i] = { ts = string.format("2026-10-01T10:01:%02d.000Z", i), kind = i % 2 == 0 and "note" or "tool",
    text = "発言" .. i, tool = "Bash", target = "cmd" .. i }
end
local dm = detail.build(sn, sn.agents.a2, { width = 100, notes = many })
has(dm, "■ Progress (last 40 of 50)", "上限")
hasnt(dm, "cmd9 ", "古いものは出さない")
hasnt(dm, "発言10", "古いものは出さない 2")
has(dm, "発言50", "最新は出る")
-- transcript が読めなければ hooks の記録だけ
local dh = detail.build(s, s.agents.a2, { width = 100, notes = nil })
has(dh, "■ Progress (last 1 of 1)", "hooks の記録")
t.matches(text(dh), "Write%s+/tmp/agentmap%-test/chk/models/orders%.sql", "hooks の Write")
t.eq(detail.read_notes({ state = s }, { id = "zz", transcript_path = "/nonexistent/x.jsonl" }), nil, "読めなければ nil")

-- ------------------------------------------------------------
-- 4. 詳細：報告／要確認／原文
-- ------------------------------------------------------------
has(d1, "■ Report", "[1]")
t.matches(text(d1), "Done%s+models/ の 12 本を読んだ", "やったこと")
t.matches(text(d1), "Approach%s+依存の順に整理", "方向")
t.matches(text(d1), "Why%s+下流から見ると漏れる", "理由")
t.matches(text(d1), "Open issues%s+なし", "残った課題")
hasnt(d1, "■ 最終メッセージ", "旧「最終メッセージ」の節は無い")
local sf = fixture()
sf.agents.a1.report_fields.issues = nil
t.matches(text(detail.build(sf, sf.agents.a1, { width = 100 })), "Open issues%s+%(not written%)", "欠けた項目")

has(d2, "■ Needs confirmation (this agent stopped to wait for an answer)", "[2]")
t.matches(text(d2), "Working on%s+orders%.sql の拡張", "今の作業")
t.matches(text(d2), "Blocked at%s+テストの範囲が決まらない", "止まっている所")
t.matches(text(d2), "Question%s+テストはどこまで書きますか？", "確認したいこと")
t.matches(text(d2), "Options%s+1%. 単体のみ → tests/ に追加して終了", "選択肢 1")
has(d2, "2. 結合まで → seed を作ってから実装", "選択肢 2")
local qr2 = row_of(d2, "HUMAN CHECK #2 [WAITING](Enter for details)")
t.ok(qr2 ~= nil and d2.links[qr2] == "check:toolu_Q", "要確認の「質問」行もリンク")

local sr = fixture()
sr.agents.a1.report_fields = nil
sr.agents.a1.report = "調べました。\n12 本ありました。"
local draw = detail.build(sr, sr.agents.a1, { width = 100 })
has(draw, "No convention headings (## Report / ## Needs confirmation). Raw text:", "見出しが無い報告")
has(draw, "  調べました。", "原文 1 行目")
has(draw, "  12 本ありました。", "原文 2 行目（改行を保つ）")
sr.agents.a1.report, sr.agents.a1.last_head = nil, nil
has(detail.build(sr, sr.agents.a1, { width = 100 }), "(nothing yet)", "報告が無いとき")

-- ------------------------------------------------------------
-- 5. HUMAN CHECK の画面
-- ------------------------------------------------------------
local cq = checkv.build(s, s.checks["check:toolu_Q"], { width = 100 })
has(cq, "■ HUMAN CHECK #2", "見出し")
has(cq, "[WAITING]", "状態")
local kr = row_of(cq, "Trigger")
t.matches(cq.lines[kr], "%[2%] 実装：dbt model's \"needs confirmation\"", "きっかけは [2] の要確認")
t.eq(cq.links[kr], "a2", "きっかけの行リンクは [2]")
local ar = row_of(cq, "Asked by")
t.eq(cq.links[ar], "ROOT", "聞いた側の行リンクは ROOT")
has(cq, "the question contains the child's name", "結びつけの根拠")
has(cq, "■ Working on (from the child's report)", "子の事情")
has(cq, "orders.sql の拡張", "今の作業")
has(cq, "■ Blocked at (from the child's report)", "子の事情 2")
has(cq, "Q1 [実装：dbt] テストはどこまで書きますか？", "質問文（先頭の「<子の名前> について：」は落とす：DESIGN §6.3）")
has(cq, "■ Options and what happens after each", "選択肢の節")
has(cq, "1. 単体のみ  — モデル単位のテストだけ", "選択肢 1（→ 選んだら より前）")
has(cq, "→ if chosen: tests/ に追加して終了", "選んだ後の進め方")
has(cq, "→ if chosen: seed を作ってから実装", "選んだ後の進め方 2")
has(cq, "(not answered yet; answer in the terminal)", "WAITING の答え")
has(cq, "■ Child's report (raw)", "子の報告の原文")
has(cq, "(nothing said just before)", "直前の発言なし")

-- description に「→ 選んだら」が無ければ、子の要確認の選択肢から補う
local sx = fixture()
for _, o in ipairs(sx.checks["check:toolu_Q"].questions[1].options) do o.description = "説明だけ" end
local cx = checkv.build(sx, sx.checks["check:toolu_Q"], { width = 100 })
has(cx, "→ if chosen: tests/ に追加して終了", "子の要確認から進め方を補う")
sx.agents.a2.ask = nil
has(checkv.build(sx, sx.checks["check:toolu_Q"], { width = 100 }), "(next step not written)", "どこにも無ければ")

local cb = checkv.build(s, s.checks["check:toolu_B"], { width = 100 })
has(cb, "[DONE]", "答え済み")
has(cb, "answered ", "答えた時刻")
has(cb, "Asked directly (not linked to a child's \"needs confirmation\")", "直接の質問")
has(cb, "\"設計の分かれ道なので先に聞きます\"", "聞いた側の直前の発言")
has(cb, "\"A案\"", "答え")
t.matches(text(cb), "Next step%s+既存の orders を拡張", "この後の進め方")
hasnt(cb, "■ Working on (from the child's report)", "直接の質問には子の事情の節が無い")
hasnt(cb, "■ Child's report (raw)", "直接の質問には原文の節が無い")

local sa = fixture()
sa.checks["check:toolu_B"].answers = { ["どちらの設計で進めますか？"] = { "A案", "B案" } }
sa.checks["check:toolu_B"].questions[1].multi = true
local ca = checkv.build(sa, sa.checks["check:toolu_B"], { width = 100 })
has(ca, "\"A案\"\"B案\"", "配列の答え")
has(ca, "orders_v2 を新設", "2 つ目の答えの進め方")
has(ca, "(multiple choice allowed)", "複数選択の印")
sa.checks["check:toolu_B"].answers = { ["どちらの設計で進めますか？"] = "C案：両方の良いところ" }
local cfree = checkv.build(sa, sa.checks["check:toolu_B"], { width = 100 })
t.matches(text(cfree), "%(free text%)%s+C案：両方の良いところ", "自由入力")

local sb = fixture()
sb.checks["check:toolu_Q"].status = "ABANDONED"
sb.checks["check:toolu_Q"].ended_at = "2026-10-01T10:00:40.000Z"
sb.checks["check:toolu_Q"].end_reason = "new_prompt"
local cab = checkv.build(sb, sb.checks["check:toolu_Q"], { width = 100 })
has(cab, "[UNANSWERED]", "未回答")
has(cab, "(ended without an answer: a new prompt arrived)", "未回答の理由")

-- ------------------------------------------------------------
-- 6. 画面の行き来：図の check の箱で Enter → 確認の画面 → きっかけ行で Enter → [2] の詳細 → BS → t
-- ------------------------------------------------------------
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end
local function bufname() return vim.api.nvim_buf_get_name(0) end
local function buftext() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end
local function goto_line(pat)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find(pat, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return i
    end
  end
end

t.run("画面の行き来", function()
  local st = fixture()
  st.agents.a2.transcript_path = here .. "/fixtures/agent_report.jsonl"
  local run = { dir = vim.fn.tempname(), sid = st.run_id, state = st }
  local ui = require("agentmap.ui")
  local renderer = require("agentmap.renderer")
  local msgs = {}
  vim.notify = function(m) msgs[#msgs + 1] = m end
  ui.view.mode = "box"
  ui.open_map(run)
  t.matches(buftext(), "HUMAN CHECK", "図に HUMAN CHECK の箱")
  t.matches(buftext(), "%[WAITING%]", "図に [WAITING]")
  local map_buf = vim.api.nvim_get_current_buf()

  -- resolve_agent
  t.eq(ui.resolve_agent("check:toolu_Q"), "a2", "resolve_agent：子の後ろの check → その子")
  t.eq(ui.resolve_agent("check:toolu_B"), "ROOT", "resolve_agent：直接の check → 聞いた側")
  t.eq(ui.resolve_agent("gate:a2"), "a2", "resolve_agent：門 → 元の Agent")
  t.eq(ui.resolve_agent("a1"), "a1", "resolve_agent：Agent はそのまま")
  t.eq(ui.resolve_agent("check:none"), nil, "resolve_agent：無い check は nil")

  -- n で check の箱に止まる
  local seen = {}
  for _ = 1, 8 do
    feed("n")
    seen[#seen + 1] = ui.current_id()
  end
  t.ok(vim.tbl_contains(seen, "check:toolu_Q") and vim.tbl_contains(seen, "check:toolu_B"),
    "n で check の箱にも止まる: " .. table.concat(seen, ","))

  local r = renderer.rows_of(ui.cache, "check:toolu_Q")
  vim.api.nvim_win_set_cursor(0, { r[1] + 1, r.starts[r[1] + 1] + 4 })
  t.eq(ui.current_id(), "check:toolu_Q", "カーソル → check の箱")
  feed("<CR>")
  t.matches(bufname(), "agentmap://check/check:toolu_Q", "Enter で確認の画面")
  t.matches(buftext(), "■ HUMAN CHECK #2", "確認の画面の中身")
  t.eq(vim.b.agentmap_kind, "check", "バッファの種類は check")

  goto_line("Trigger")
  feed("<CR>")
  t.matches(bufname(), "agentmap://detail/a2", "きっかけの行で Enter → [2] の詳細")
  t.matches(buftext(), "■ Progress", "[2] の詳細")
  t.matches(buftext(), "まず既存のモデルを読みます", "詳細を開くと transcript から作業の経過を読む")

  -- 詳細の「人の確認」行で Enter → 確認の画面
  goto_line("HUMAN CHECK #2  [WAITING]")
  feed("<CR>")
  t.matches(bufname(), "agentmap://check/check:toolu_Q", "詳細の人の確認の行から確認の画面")
  feed("<BS>")
  t.matches(bufname(), "agentmap://detail/a2", "BS で [2] の詳細へ戻る")
  feed("<BS>")
  t.matches(bufname(), "agentmap://check/check:toolu_Q", "もう一度 BS で確認の画面へ")

  -- 確認の画面の t は「質問した側」の transcript（設計書 §6.2）。箱は [2] に付いているが、質問したのは ROOT
  t.matches(buftext(), "t transcript of the asker %(ROOT%)", "案内行に「質問した側」と書いてある")
  feed("t")
  t.matches(bufname(), "agentmap://transcript/ROOT", "確認の画面で t → 質問した側（ROOT）の transcript")
  feed("<BS>")
  t.matches(bufname(), "agentmap://check/check:toolu_Q", "BS で確認の画面へ")
  t.eq(ui.check_asker("check:toolu_Q"), "ROOT", "check_asker：子の後ろの check でも聞いた側は ROOT")
  t.eq(ui.check_asker("a2"), "a2", "check_asker：Agent はそのまま")
  goto_line("Asked by")
  feed("<CR>")
  t.matches(bufname(), "agentmap://detail/ROOT", "聞いた側の行で Enter → ROOT の詳細")
  feed("q")
  t.eq(vim.api.nvim_get_current_buf(), map_buf, "q で図へ")

  -- 図の check の箱で t → 箱が付いている Agent の transcript
  vim.api.nvim_win_set_cursor(0, { r[1] + 1, r.starts[r[1] + 1] + 4 })
  feed("t")
  t.matches(bufname(), "agentmap://transcript/a2", "図の check の箱で t → [2] の transcript")
  feed("<BS>")
  t.eq(vim.api.nvim_get_current_buf(), map_buf, "BS で図へ")

  -- 図の check の箱で - → 箱が付いている Agent を畳む
  vim.api.nvim_win_set_cursor(0, { r[1] + 1, r.starts[r[1] + 1] + 4 })
  feed("-")
  t.ok(ui.view.collapsed.a2 == true, "check の箱で - → [2] を畳む")
  t.ok(not buftext():find("2 options · Enter opens", 1, true), "畳むと check の箱が隠れる")
  feed("+")
  t.ok(ui.view.collapsed.a2 == nil, "+ で開く")
  t.matches(buftext(), "2 options · Enter opens", "開くと check の箱が戻る")

  -- z は check の箱では断る
  local r2 = renderer.rows_of(ui.cache, "check:toolu_Q")
  vim.api.nvim_win_set_cursor(0, { r2[1] + 1, r2.starts[r2[1] + 1] + 4 })
  feed("z")
  t.eq(ui.view.root, "ROOT", "check の箱で z しても部分表示にしない")

  -- 状態が変わったら（答えが出たら）描き直しで反映。確認の画面も作り直す
  feed("<CR>")
  st.checks["check:toolu_Q"].status = "ANSWERED"
  st.checks["check:toolu_Q"].answered_at = "2026-10-01T10:01:36.000Z"
  st.checks["check:toolu_Q"].answers = { [st.checks["check:toolu_Q"].questions[1].question] = "単体のみ" }
  ui.refresh()
  local aux_text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ui.aux_win), 0, -1, false), "\n")
  t.ok(aux_text:find("\"単体のみ\"", 1, true) ~= nil, "refresh で確認の画面に答えが出る")
  ui.close()
end)


-- ------------------------------------------------------------
-- 点検で見つけた食い違い（2026-10-01）
-- ------------------------------------------------------------
t.run("review fixes: question prefix and label spacing", function()
  local graph = require("agentmap.graph")
  local sv = fixture()
  -- (b) 木の形の一覧でも「<子の名前> について：」を落とす（DESIGN §6.3）
  local ci = graph.check_info(sv, sv.checks["check:toolu_Q"])
  t.eq(ci.question_short, "テストはどこまで書きますか？", "question_short")
  local tl = graph.tree_lines(sv, { root = "ROOT", now = os.time() })
  local tree_text = vim.inspect(tl)
  t.ok(tree_text:find("テストはどこまで書きますか？", 1, true) ~= nil, "tree: 質問が出る")
  t.ok(tree_text:find("実装：dbt model について：テスト", 1, true) == nil, "tree: 先頭の「<名前> について：」は落とす")
  -- (c) 名札が欄の幅以上でも値と 1 字空ける："(child's report)Should…" にならない
  local cq2 = checkv.build(sv, sv.checks["check:toolu_Q"], { width = 100 })
  t.ok(text(cq2):find("(child's report) ", 1, true) ~= nil, "名札のあとに空白")
  t.ok(text(cq2):find("%(child's report%)%S") == nil, "名札と値がくっつかない")
end)


-- ------------------------------------------------------------
-- v0.1.1：進み具合・手順の節（DESIGN-v0.2 §2.6）と修正指示の節（DESIGN-v0.2-steer §6.4）。担当 W2
-- ------------------------------------------------------------
t.run("v0.2 detail: progress, steps, steering", function()
  local NOW = 1790600000
  local function iso(sec) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", sec) end
  local STATS = { agents = { ["general-purpose|opus"] = { n = 10, median_ms = 360000 } }, steps = {},
    all = { agents = { n = 10, median_ms = 360000 }, steps = { n = 0 } } }
  local sp = fixture()
  local a = sp.agents.a1
  a.status, a.finished_at, a.elapsed_ms, a.agent_type, a.model = "RUNNING", nil, nil, "general-purpose", "claude-opus-5-5"
  a.steps = { source = "transcript", listed_at = iso(NOW - 600), items = {
    { n = 1, text = "Read the current code", done_at = iso(NOW - 400) },
    { n = 2, text = "Write the design", done_at = iso(NOW - 70) },
    { n = 3, text = "Run the tests", started_at = iso(NOW - 60) },
  } }
  local dp = detail.build(sp, a, { width = 120, now = NOW, stats = STATS })
  t.matches(text(dp), "status   %[RUNNING%]  progress ~83%.3%% %(estimated%)", "状態の行に推定の %")
  t.matches(text(dp), "\n  progress 2/3 steps done · step 3 running 1:00 %(typical 2:00%) · typical time: median of 10 past agents of the same type and model\n",
    "2 行目：済んだ数と実行中の手順")
  has(dp, "■ Steps (2/3)  source: \"## Steps\" in the transcript", "手順の見出し")
  t.matches(text(dp), "\n  ✓ 1%. Read the current code%s+%d%d:%d%d → %d%d:%d%d\n", "済んだ手順")
  t.matches(text(dp), "\n  ▶ 3%. Run the tests%s+%d%d:%d%d →  %(running 1:00, typical 2:00%)\n", "実行中の手順")
  -- 目安を超えた
  a.steps.items[3].started_at = iso(NOW - 500)
  local dov = detail.build(sp, a, { width = 120, now = NOW, stats = STATS })
  t.matches(text(dov), "step 3 running 8:20 %(longer than typical 2:00%)", "目安超え")
  -- 事実だけ（REVIEW）
  a.status = "REVIEW"
  local df = detail.build(sp, a, { width = 120, now = NOW, stats = STATS })
  t.matches(text(df), "status   %[REVIEW%]  progress 66%.6%%   ", "事実だけなら (estimated) が無い")
  t.matches(text(df), "\n  progress 2/3 steps done\n", "2 行目は済んだ数だけ")
  -- 手順表なし・時間だけ（付録 D）
  local st = fixture()
  local b = st.agents.a1
  b.status, b.finished_at, b.elapsed_ms, b.started_at = "RUNNING", nil, nil, iso(NOW - 120)
  b.agent_type, b.model = "general-purpose", "claude-opus-5-5"
  local dt = detail.build(st, b, { width = 120, now = NOW, stats = STATS })
  t.matches(text(dt), "progress ~33%.3%% %(estimated%)", "時間だけの推定")
  t.matches(text(dt), "\n  progress no step list · estimated from elapsed time %(typical 6:00%)", "手順表なしと分かる文言")
  hasnt(dt, "■ Steps", "手順表が無ければ節を出さない")
  -- 手順表なし・推定もしない（DONE 以外で事実が無い）
  local dn = detail.build(fixture(), fixture().agents.a2, { width = 120, now = NOW, stats = STATS })
  t.ok(text(dn):find("status   %[DONE%]  progress 100%.0%%") ~= nil, "DONE は 100.0%")
  -- 子の平均（ROOT）
  local dr = detail.build(sp, sp.agents.ROOT, { width = 120, now = NOW, stats = STATS })
  t.matches(text(dr), "\n  progress estimated from %d+ child agents", "子の平均から推定")

  -- 修正指示の節
  local ss = fixture()
  ss.steers = {
    ["a1-1"] = { id = "a1-1", agent_id = "a1", text = "資料は docs/v3 を読むこと", via = "hook", status = "DELIVERED",
      requested_at = iso(NOW - 120), delivered_at = iso(NOW - 100), delivered_via = "PreToolUse:Write", n = 1 },
    ["a1-2"] = { id = "a1-2", agent_id = "a1", text = "急いで", via = "hook", status = "PENDING", requested_at = iso(NOW - 10), n = 2 },
    ["a1-3"] = { id = "a1-3", agent_id = "a1", text = "x", via = "hook", status = "EXPIRED", requested_at = iso(NOW - 5),
      end_reason = "agent_finished", n = 3 },
  }
  ss.steer_order = { "a1-1", "a1-2", "a1-3" }
  ss.agents.a1.steers = { "a1-1", "a1-2", "a1-3" }
  ss.agents.a1.tools = { { ts = iso(NOW - 95), name = "Read", target = "docs/v3/a.md" } }
  local ds = detail.build(ss, ss.agents.a1, { width = 140, now = NOW, stats = STATS })
  local mk = require("agentmap.graph").steer_mark()
  has(ds, "■ Steering (3)", "修正指示の見出し")
  t.matches(text(ds), mk .. " #1 %d%d:%d%d:%d%d  DELIVERED %d%d:%d%d:%d%d at PreToolUse:Write  \"資料は docs/v3 を読むこと\"", "配達済み")
  t.matches(text(ds), "→ next tool %d%d:%d%d:%d%d Read docs/v3/a%.md", "配達のあとの最初の道具")
  has(ds, "PENDING (delivered at the next tool call)", "未配達")
  has(ds, "NOT DELIVERED (the agent finished before its next tool call)", "届かないまま終了")
  local hi = row_of(ds, "■ History")
  local si = row_of(ds, "■ Steering (3)")
  local ci = row_of(ds, "■ Human checks")
  t.ok(hi and si and hi < si and (not ci or si < ci), "History の後・Human checks の前")
  local li = row_of(ds, "急いで")
  t.eq(ds.links[li], "steer:a1-2", "行に steer:<id> の印")
  has(ds, "s steer", "footer に s steer")
  hasnt(detail.build(fixture(), fixture().agents.a1, { width = 120, now = NOW, stats = STATS }), "■ Steering", "0 件なら節を出さない")
  -- 親への知らせ（付録 E）：元の指示の下に「親に知らせた（届いた／未配達）」。知らせ自体は独立の行・印にしない
  local sn = fixture()
  sn.steers = {
    ["a1-1"] = { id = "a1-1", agent_id = "a1", text = "docs/v3 を読む", via = "hook", status = "DELIVERED",
      requested_at = iso(NOW - 120), delivered_at = iso(NOW - 100), delivered_via = "PreToolUse:Write", n = 1 },
    ["ROOT-1"] = { id = "ROOT-1", agent_id = "ROOT", kind = "notice", notice_of = "a1-1", text = "[AgentMap] …",
      via = "terminal", status = "DELIVERED", requested_at = iso(NOW - 99), delivered_at = iso(NOW - 99), delivered_via = "terminal" },
    ["a1-2"] = { id = "a1-2", agent_id = "a1", text = "急いで", via = "hook", status = "DELIVERED",
      requested_at = iso(NOW - 50), delivered_at = iso(NOW - 40), delivered_via = "PreToolUse:Bash", n = 2 },
    ["ROOT-2"] = { id = "ROOT-2", agent_id = "ROOT", kind = "notice", notice_of = "a1-2", text = "[AgentMap] …",
      via = "hook", status = "PENDING", requested_at = iso(NOW - 39) },
  }
  sn.steer_order = { "a1-1", "ROOT-1", "a1-2", "ROOT-2" }
  sn.agents.a1.steers = { "a1-1", "a1-2" }
  sn.agents.ROOT.steers = { "ROOT-1", "ROOT-2" }
  local dn2 = detail.build(sn, sn.agents.a1, { width = 140, now = NOW, stats = STATS })
  has(dn2, "■ Steering (2)", "知らせは数えない")
  t.matches(text(dn2), "\n      → told the parent ROOT: SENT to the terminal %d%d:%d%d:%d%d", "親に知らせた（端末へ送信）")
  t.matches(text(dn2), "\n      → told the parent ROOT: PENDING %(delivered at the next tool call%)", "親への知らせが未配達")
  hasnt(detail.build(sn, sn.agents.ROOT, { width = 140, now = NOW, stats = STATS }), "■ Steering", "親の詳細に知らせを独立の指示として出さない")
  local graph = require("agentmap.graph")
  t.eq(graph.steer_marks(sn, sn.agents.ROOT, NOW), {}, "知らせで親の箱に印を増やさない")
  require("agentmap.i18n").setup("ja")
  t.matches(text(detail.build(sn, sn.agents.a1, { width = 140, now = NOW, stats = STATS })), "→ 親 ROOT に知らせた: 未配達", "日本語")
  t.matches(require("agentmap.i18n").t("steer.notice_to_parent", { index = 2, name = "調査係", text = "v3 を読む" }),
    "^%[AgentMap%] The user sent this instruction directly to your sub%-agent %[2%] \"調査係\": v3 を読む%. If it also affects",
    "親への知らせの文（モデル向け。日本語の表でも英文）")
  require("agentmap.i18n").setup("en")
end)

t.run("v0.1.2 detail: pauses", function()
  -- DESIGN-v0.1.2-pause §6.4：「■ Steering」の後・「■ Human checks」の前、1 件以上あるときだけ
  local NOW = 1790600000
  local function iso(sec) return os.date("!%Y-%m-%dT%H:%M:%S.000Z", sec) end
  local function clk(sec) return os.date("%H:%M:%S", sec) end
  local graph = require("agentmap.graph")
  local mk = graph.pause_mark()
  local function base()
    local x = fixture()
    x.pauses, x.pause_order = {}, {}
    for _, a in pairs(x.agents) do a.pauses, a.pause = nil, nil end
    x.agents.a1.status, x.agents.a1.finished_at, x.agents.a1.elapsed_ms = "RUNNING", nil, nil
    return x
  end
  local function put(x, list)
    for i, p in ipairs(list) do
      p.id, p.agent_id, p.n = "a1-" .. i, p.agent_id or "a1", i
      x.pauses[p.id] = p
      x.pause_order[#x.pause_order + 1] = p.id
      x.agents[p.agent_id].pauses = x.agents[p.agent_id].pauses or {}
      table.insert(x.agents[p.agent_id].pauses, p.id)
    end
    return x
  end
  local sp = put(base(), {
    { kind = "pause", at = "next", status = "RESUMED", requested_at = iso(NOW - 3000), hit_at = iso(NOW - 2994),
      hit_via = "PreToolUse:Read", released_at = iso(NOW - 2783), release_reason = "user", waited_ms = 211000, steer_id = "a1-s" },
    { kind = "gate", at = "stop", status = "PAUSED", requested_at = iso(NOW - 100), hit_at = iso(NOW - 96),
      hit_via = "SubagentStop", deadline = iso(NOW + 504) },
    { kind = "pause", at = "stop", status = "RESUMED", requested_at = iso(NOW - 2000), hit_at = iso(NOW - 1995),
      hit_via = "SubagentStop", released_at = iso(NOW - 1395), release_reason = "auto", waited_ms = 600000 },
    { kind = "pause", at = "next", status = "EXPIRED", requested_at = iso(NOW - 1000), end_reason = "agent_finished" },
    { kind = "pause", at = "next", status = "REQUESTED", requested_at = iso(NOW - 5) },
    { kind = "pause", at = "next", status = "RESUMED", requested_at = iso(NOW - 900), hit_at = iso(NOW - 890),
      hit_via = "PreToolUse:Bash", released_at = iso(NOW - 880), release_reason = "aborted" },
    { kind = "gate", at = "stop", status = "RESUMED", requested_at = iso(NOW - 800), hit_at = iso(NOW - 790),
      hit_via = "SubagentStop", released_at = iso(NOW - 760), release_reason = "gate_off" },
    { kind = "pause", at = "next", status = "RESUMED", requested_at = iso(NOW - 700), hit_at = iso(NOW - 690),
      hit_via = "PreToolUse:Edit", released_at = iso(NOW - 645), release_reason = "nvim_exit" },
  })
  sp.pause_order = { "a1-1", "a1-3", "a1-4", "a1-6", "a1-7", "a1-8", "a1-2", "a1-5" }
  sp.steers = { ["a1-s"] = { id = "a1-s", agent_id = "a1", text = "use v3", status = "DELIVERED", n = 2,
    requested_at = iso(NOW - 2790), delivered_at = iso(NOW - 2783), delivered_via = "PreToolUse:Read" } }
  sp.steer_order = { "a1-s" }
  sp.agents.a1.steers = { "a1-s" }
  local d = detail.build(sp, sp.agents.a1, { width = 200, now = NOW })
  -- 取り残しとして取り下げた（sweep_pauses の end_reason = "stale"）も鍵の文で出す（符号のまま出さない）
  local stale_segs = detail.pause_line(sp, { kind = "pause", at = "next", status = "EXPIRED", requested_at = iso(NOW - 9000),
    end_reason = "stale" }, 1, NOW)
  local stale_text = ""
  for _, sg in ipairs(stale_segs) do stale_text = stale_text .. sg[1] end
  t.matches(stale_text, "not reached: nothing reached it for too long %(withdrawn%)$", "end_reason stale は文で出す")
  has(d, "■ Pauses (8)", "節の見出しと件数")
  t.matches(text(d), "\n  " .. vim.pesc(mk) .. " #1 " .. clk(NOW - 3000) .. " requested %(next tool call%) → paused "
    .. clk(NOW - 2994) .. " at PreToolUse:Read → resumed by you " .. clk(NOW - 2783) .. " with instruction #2 %(3 min 31 s%)\n",
    "指示つきで再開した行")
  t.matches(text(d), "\n  " .. vim.pesc(mk) .. " #2 " .. clk(NOW - 100) .. " gate → waiting since " .. clk(NOW - 96)
    .. " at SubagentStop %(auto%-resume at " .. clk(NOW + 504) .. "%)\n", "関門で待っている行")
  t.matches(text(d), "#3 " .. clk(NOW - 2000) .. " requested %(when it finishes%) → paused " .. clk(NOW - 1995)
    .. " at SubagentStop → resumed automatically " .. clk(NOW - 1395) .. " after 10 min\n", "自動で再開した行")
  t.matches(text(d), "#4 " .. clk(NOW - 1000) .. " requested %(next tool call%) → not reached: the agent finished first\n",
    "止まる前に終わった行")
  t.matches(text(d), "#5 " .. clk(NOW - 5) .. " requested %(next tool call%) → not reached yet\n", "まだ止まっていない行")
  t.matches(text(d), "#6 .* → ended " .. clk(NOW - 880) .. ": the hook was stopped %(10 s%)\n", "hook が止められた行")
  t.matches(text(d), "#7 .* gate → paused .* → passed " .. clk(NOW - 760) .. " %(gate turned off%) %(30 s%)\n", "関門を切って通した行")
  t.matches(text(d), "#8 .* → resumed " .. clk(NOW - 645) .. " when Neovim closed %(45 s%)\n", "Neovim 終了で再開した行")
  -- 順番は要求の順（pause_order に依らず requested_at の順）
  local r1, r8, r5 = row_of(d, mk .. " #1 "), row_of(d, mk .. " #8 "), row_of(d, mk .. " #5 ")
  t.ok(r1 and r8 and r5 and r1 < r8 and r8 < r5, "要求の時刻の順")
  -- 指示つきの行は Enter で指示の本文へ（steer:<id>）
  t.eq(d.links[r1], "steer:a1-s", "指示つき再開の行に steer:<id>")
  t.eq(d.links[r5], nil, "ほかの行にはリンクなし")
  -- 位置：Steering の後、Human checks の前
  local si, pi = row_of(d, "■ Steering (1)"), row_of(d, "■ Pauses (8)")
  t.ok(si and pi and si < pi, "Steering の後")
  local sc = put(base(), { { kind = "pause", at = "next", status = "REQUESTED", requested_at = iso(NOW - 5) } })
  local dc = detail.build(sc, sc.agents.a2, { width = 160, now = NOW })
  t.ok(not text(dc):find("■ Pauses", 1, true), "ほかの Agent の止まれは出さない")
  local ci = row_of(d, "■ Human checks")
  t.ok(not ci or pi < ci, "Human checks の前")
  -- 状態の札：止まっていれば [GATE]（a1 は #2 の関門で止まっている）
  sp.agents.a1.pause = "a1-2"
  local dg = detail.build(sp, sp.agents.a1, { width = 200, now = NOW })
  t.matches(dg.lines[1], "%[GATE%]", "見出しの札は [GATE]")
  t.matches(text(dg), "\n  status   %[GATE%]", "状態の行も [GATE]")
  -- 0 件なら節を出さない
  hasnt(detail.build(base(), base().agents.a1, { width = 120, now = NOW }), "■ Pauses", "0 件なら節を出さない")
  -- footer
  has(d, "s steer  x pause", "footer に x pause")
  -- 日本語
  require("agentmap.i18n").setup("ja")
  local dj = detail.build(sp, sp.agents.a1, { width = 200, now = NOW })
  has(dj, "■ 一時停止 (8)", "日本語の見出し")
  t.matches(text(dj), "#1 " .. clk(NOW - 3000) .. " 止まれ（次の道具の直前） → " .. clk(NOW - 2994)
    .. " に PreToolUse:Read で停止 → " .. clk(NOW - 2783) .. " に指示 #2 をつけて再開 %(3 分 31 秒%)", "日本語の行")
  has(dj, "x 一時停止", "日本語の footer")
  require("agentmap.i18n").setup("en")
end)

t.done()
