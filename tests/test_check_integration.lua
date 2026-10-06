-- HUMAN CHECK の通し試験（設計書 §12.1 の最終確認）：
--   本物の hooks 形式の記録（hooks_ask.jsonl）→ events.load（reducer）→ 図（graph / renderer）→ 詳細・確認の画面
--   → 見張りで自動更新（答えが記録されたら [DONE]）→ 書き出し（Markdown / Mermaid）を一気通貫で流す。
--   transcript（親・子）は fixtures を一時フォルダに写し、hooks の transcript_path をそこへ向ける
--   （親の直前の発言・子の作業の経過が transcript から読めることも確かめる）。
--   記録の保存先は一時フォルダ（minimal_init.lua が AGENTMAP_DIR を決める）。本物の記録には触らない。
local t = require("t")
local mc = require("mermaid_check")
local here = vim.g.agentmap_test_dir
local FIX = here .. "/fixtures"
vim.o.columns, vim.o.lines = 200, 60

local notes = {}
vim.notify = function(msg, lvl) notes[#notes + 1] = { msg = tostring(msg), lvl = lvl } end

local af = require("agentmap")
local ui = require("agentmap.ui")
local renderer = require("agentmap.renderer")

local function dec(l) return vim.json.decode(l, { luanil = { object = true, array = true } }) end
local raw = vim.fn.readfile(FIX .. "/hooks_ask.jsonl")
local first = dec(raw[1])
local sid = first.session_id
local slug = vim.fn.fnamemodify(vim.fn.fnamemodify(first.transcript_path, ":h"), ":t")

-- transcript を一時フォルダに写し、hooks の transcript_path をそこへ向ける
local CDIR = vim.fn.tempname()
local base = CDIR .. "/projects/" .. slug
vim.fn.mkdir(base .. "/" .. sid .. "/subagents", "p")
vim.fn.writefile(vim.fn.readfile(FIX .. "/transcript_ask.jsonl"), base .. "/" .. sid .. ".jsonl")
vim.fn.writefile(vim.fn.readfile(FIX .. "/agent_report.jsonl"), base .. "/" .. sid .. "/subagents/agent-a2.jsonl")
local function hook_lines(new_sid)
  local out = {}
  for i, l in ipairs(raw) do
    local r = dec(l)
    r.session_id = new_sid or r.session_id
    r.transcript_path = base .. "/" .. sid .. ".jsonl"
    if r.agent_transcript_path then r.agent_transcript_path = base .. "/" .. sid .. "/subagents/agent-a2.jsonl" end
    out[i] = vim.json.encode(r)
  end
  return out
end
local lines = hook_lines()

local root = vim.env.AGENTMAP_DIR
local run_dir = root .. "/projects/" .. slug .. "/runs/" .. sid
vim.fn.mkdir(run_dir, "p")
vim.fn.writefile({ vim.json.encode({ cwd = first.cwd, slug = slug }) }, root .. "/projects/" .. slug .. "/project.json")
local hooks_path = run_dir .. "/hooks.jsonl"
vim.fn.writefile(vim.list_slice(lines, 1, 9), hooks_path) -- 質問を出したところまで（答えはまだ）

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end
local function map_text()
  if not ui.buf or not vim.api.nvim_buf_is_valid(ui.buf) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
end
local function aux_text()
  if not ui.aux_win or not vim.api.nvim_win_is_valid(ui.aux_win) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ui.aux_win), 0, -1, false), "\n")
end
local function bufname() return vim.api.nvim_buf_get_name(0) end
-- 図の中で、ある箱の行に付いている色（highlight group）の一覧
local function hl_in_box(id)
  local r = renderer.rows_of(ui.cache, id)
  local out = {}
  if not r then return out end
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(ui.buf, renderer.ns, { r[1] - 1, 0 }, { r[2] - 1, -1 }, { details = true })) do
    local g = m[4] and m[4].hl_group
    if g then out[g] = true end
  end
  return out
end

-- ------------------------------------------------------------
-- 1. 開く：reducer → 図。質問を出したところなので WAITING（紫）
-- ------------------------------------------------------------
t.run(":AgentMap <sid>", function() vim.cmd("AgentMap " .. sid) end)
t.ok(ui.run and ui.run.sid == sid, "run が開いた")
t.ok(af._watching(), "見張りが動いている")
local s = ui.run.state
t.eq(s.sv, 11, "state の版は 11")
local c = s.checks["check:toolu_Q"]
t.eq(c and c.status, "WAITING", "質問を出したところ：WAITING")
t.eq(c and c.agent_id, "a2", "子 a2 の要確認に結びつく（名前）")
t.eq(c and c.owner_id, "a2", "箱は a2 の後ろ")
t.eq(s.agents.a2.status, "DONE", "要確認で止まった子は DONE のまま")
t.eq(s.agents.a2.ask and s.agents.a2.ask.want, "テストはどこまで書きますか？", "子の要確認（SubagentStop に同封の報告から）")
t.eq(s.agents.a2.brief and s.agents.a2.brief.purpose, "orders を拡張する", "任せた理由（hooks の brief）")
t.eq(s.agents.a2.lead, "設計の確認が要るので実装を任せます", "親の直前の発言（開くときの enrich で親の transcript から）")
t.eq(c and c.lead, "子が要確認で止まったので聞きます", "聞いた側の直前の発言")

local mt = map_text()
t.matches(mt, "HUMAN CHECK", "図に HUMAN CHECK の箱")
t.matches(mt, "%[WAITING%]", "図に [WAITING]")
t.matches(mt, "waiting 1", "見出しに「waiting 1」")
t.matches(mt, "%[WAITING%]purple", "凡例に [WAITING]purple")
t.matches(mt, "%] ask", "子の箱に「ask」の印")
t.matches(mt, "wait 1", "ROOT の箱に「wait 1」")
local rc, ra = renderer.rows_of(ui.cache, "check:toolu_Q"), renderer.rows_of(ui.cache, "a2")
t.ok(rc and ra, "check と子の箱が図にある")
t.ok(rc and ra and rc[3] > ra[3], "check の箱は子の後ろ（右）")
t.ok(hl_in_box("check:toolu_Q").AgentMapWaiting, "WAITING の箱は紫（AgentMapWaiting）")
t.matches(mt, "2 options · Enter opens", "箱の 4 行目：選択肢の数と案内")

-- ------------------------------------------------------------
-- 2. check の箱で Enter → 確認の画面
-- ------------------------------------------------------------
vim.api.nvim_win_set_cursor(0, { rc[1] + 1, rc.starts[rc[1] + 1] + 4 })
t.eq(ui.current_id(), "check:toolu_Q", "カーソルが check の箱")
feed("<CR>")
t.matches(bufname(), "agentmap://check/check:toolu_Q", "Enter で確認の画面")
local at = aux_text()
t.matches(at, "■ HUMAN CHECK #1   %[WAITING%]   asked %d%d:%d%d:%d%d   waiting ", "見出し：WAITING と待ち時間")
t.matches(at, "Asked by%s+ROOT", "聞いた側")
t.matches(at, "Trigger%s+%[1%] 実装：dbt model's \"needs confirmation\"", "きっかけ = 子の要確認（流れの中の番号 [1]）")
t.matches(at, "Linked by%s+the question contains the child's name", "結びつけの根拠")
t.matches(at, "■ Working on %(from the child's report%)\n  orders%.sql の拡張", "子の今の作業")
t.matches(at, "Q1 %[実装：dbt%] テストはどこまで書きますか？", "質問文（先頭の「<子の名前> について：」は落とす：DESIGN §6.3）")
t.matches(at, "1%. 単体のみ  — モデル単位のテストだけ\n      → if chosen: tests/ に追加して終了", "選択肢 1 と選んだ後の進め方")
t.matches(at, "2%. 結合まで  — 下流モデルまで通す\n      → if chosen: seed を作ってから実装", "選択肢 2 と選んだ後の進め方")
t.matches(at, "%(not answered yet; answer in the terminal%)", "答え：まだ")
t.matches(at, "\"子が要確認で止まったので聞きます\"", "聞いた側の直前の発言")
t.matches(at, "t transcript of the asker %(ROOT%)", "案内行")

-- ------------------------------------------------------------
-- 3. 答えの記録を足す → 見張りが気付いて、図は [DONE]・確認の画面に答え
-- ------------------------------------------------------------
local f = assert(io.open(hooks_path, "ab"))
f:write(lines[10] .. "\n")
f:close()
local updated = vim.wait(8000, function()
  local cc = ui.run.state.checks["check:toolu_Q"]
  return cc and cc.status == "ANSWERED" and map_text():find("[DONE]", 1, true) ~= nil
    and aux_text():find('"単体のみ"', 1, true) ~= nil
end, 50)
t.ok(updated, "答えの記録が増えたら自動で更新される（図は [DONE]、確認の画面に答え）")
mt = map_text()
t.matches(mt, "→ 単体のみ", "箱の 4 行目に答え")
t.ok(not mt:find("wait", 1, true), "「wait」の印が消える")
t.ok(not mt:find("] ask", 1, true), "子の「ask」の印が消える（答えが出た）")
t.ok(hl_in_box("check:toolu_Q").AgentMapDone and not hl_in_box("check:toolu_Q").AgentMapWaiting, "答え済みの箱は緑（DONE と同じ色）")
at = aux_text()
t.matches(at, "■ HUMAN CHECK #1   %[DONE%]   asked %d%d:%d%d:%d%d   answered %d%d:%d%d:%d%d   took ", "見出し：DONE と回答までの時間")
t.matches(at, "■ Answer\n  \"単体のみ\"\n  Next step%s+tests/ に追加して終了", "答えと、この後の進め方")
t.matches(at, "1%. 単体のみ[^\n]*← chosen", "選ばれた選択肢に印")

-- ------------------------------------------------------------
-- 4. 子の詳細（任せた内容・人の確認・作業の経過・要確認）、ROOT の詳細（作業の経過に質問文）
-- ------------------------------------------------------------
feed("<BS>")
t.eq(vim.api.nvim_get_current_buf(), ui.buf, "BS で図へ")
t.run(":AgentMapAgent 1", function() vim.cmd("AgentMapAgent 1") end)
t.matches(bufname(), "agentmap://detail/a2", "[1] の詳細")
at = aux_text()
t.matches(at, "■ Task given %(parent's prompt%)", "任せた内容の節")
t.matches(at, "Goal%s+orders を拡張する", "目的")
t.matches(at, "Why delegate%s+設計と実装を分けて並行で進めるため", "任せる理由")
t.matches(at, "Done when%s+orders%.sql とテストが揃うこと", "期待する結果")
t.matches(at, "Parent said%s+\"設計の確認が要るので実装を任せます\"", "親の直前の発言")
t.matches(at, "■ Human checks %(1%)\n  HUMAN CHECK #1  %[DONE%]  \"実装：dbt model について：.-\"  → 単体のみ", "人の確認の行（質問は 40 桁で切る）")
t.matches(at, "■ Progress %(last %d+ of %d+%)", "作業の経過の節")
t.matches(at, "💬 まず既存のモデルを読みます", "子の transcript から発言")
t.matches(at, "Read%s+/tmp/agentmap%-test/ask/models/orders%.sql", "子の transcript からツール")
t.matches(at, "💬 Returned the report", "handback は「Returned the report」")
t.matches(at, "■ Needs confirmation %(this agent stopped to wait for an answer%)", "要確認の節")
t.matches(at, "Asked%s+HUMAN CHECK #1 %[DONE%]%(Enter for details%)", "要確認の節の質問行")
t.run(":AgentMapAgent 0（ROOT）", function() vim.cmd("AgentMapAgent 0") end)
t.matches(bufname(), "agentmap://detail/ROOT", "ROOT の詳細")
at = aux_text()
t.matches(at, "■ Prompt\n  dbt の orders モデルを拡張して、テストも書いて", "ROOT は指示の本文")
t.matches(at, "AskUserQuestion%s+実装：dbt model について：テストはどこまで書きますか？", "ROOT の作業の経過：AskUserQuestion の行に質問文（ツール名も切れない）")
t.matches(at, "Agent%s+実装：dbt model", "ROOT の作業の経過：Agent の行")
t.ok(not at:find("■ Human checks", 1, true), "ROOT には直接の質問が無いので「人の確認」の節は出ない（箱は子の後ろ）")
feed("q")
t.eq(vim.api.nvim_get_current_buf(), ui.buf, "q で図へ")

-- ------------------------------------------------------------
-- 5. 終わり（Stop・SessionEnd）→ 書き出し
-- ------------------------------------------------------------
f = assert(io.open(hooks_path, "ab"))
f:write(lines[11] .. "\n" .. lines[12] .. "\n")
f:close()
t.ok(vim.wait(8000, function() return ui.run.state.ended_at ~= nil end, 50), "SessionEnd に気付く")
t.eq(ui.run.state.checks["check:toolu_Q"].status, "ANSWERED", "答え済みは Stop・SessionEnd でも ANSWERED のまま")

local dir = vim.fn.tempname()
local path
t.run("export markdown", function() path = af.export("markdown", dir .. "/run.md") end)
t.eq(path, dir .. "/run.md", "markdown を書き出した")
local md = path and table.concat(vim.fn.readfile(path), "\n") or ""
t.matches(md, "\n## Human checks %(HUMAN CHECK%)\n", "人の確認の節")
t.matches(md, "\n### HUMAN CHECK #1 %[DONE%]  asked %d%d:%d%d:%d%d  answered %d%d:%d%d:%d%d\n", "#1 は DONE と時刻")
t.matches(md, "%- Trigger: \"Needs confirmation\" from %[1%] 実装：dbt model %(the question names the child%)", "きっかけ")
t.matches(md, "%- Asker's last words: \"子が要確認で止まったので聞きます\"", "聞いた側の直前の発言")
t.matches(md, "\n%- Answer: \"単体のみ\"\n  %- Next step: tests/ に追加して終了\n", "答えと進め方")
t.matches(md, "| Human checks | 1 |", "Run 概要の人の確認")
t.matches(md, "> Goal: orders を拡張する\n> Why delegate: 設計と実装を分けて並行で進めるため\n", "最終成果物に任せた理由")
t.matches(md, "> Needs confirmation %(this agent stopped to wait for an answer%)\n> Working on: orders%.sql の拡張\n", "最終成果物に要確認")
local blocks = mc.blocks(md)
t.eq(#blocks, 1, "mermaid が 1 つ")
t.eq((mc.check(blocks[1] or "")), {}, "Mermaid の形が正しい")
t.matches(blocks[1] or "", "\n  n_a2 %-%-> c_toolu_Q\n", "Mermaid：子の後ろに check")
t.matches(blocks[1] or "", "\n  class c_toolu_Q done\n", "Mermaid：答え済みは done 色")
t.matches(blocks[1] or "", "c_toolu_Q%[\"HUMAN CHECK #35;1<br/>DONE<br/>[^\"]*<br/>→ 単体のみ\"%]", "Mermaid：箱に答え")
local real, out = mc.mmdc(blocks[1] or "")
if real ~= nil then t.ok(real, "本物の mermaid でも読める\n" .. tostring(out)) end
local p_html
t.run("export html", function() p_html = af.export("html", dir .. "/run.html") end)
t.ok(p_html and vim.uv.fs_stat(p_html), "html を書き出した")

-- ------------------------------------------------------------
-- 6. 答えないまま Stop した run → [UNANSWERED]（灰）
-- ------------------------------------------------------------
local sid2 = "ask00000-0000-0000-0000-00000000ab0d"
local run_dir2 = root .. "/projects/" .. slug .. "/runs/" .. sid2
vim.fn.mkdir(run_dir2, "p")
local l2 = hook_lines(sid2)
vim.fn.writefile({ l2[1], l2[2], l2[3], l2[4], l2[5], l2[6], l2[7], l2[8], l2[9], l2[11], l2[12] }, run_dir2 .. "/hooks.jsonl")
t.run(":AgentMap <sid2>", function() vim.cmd("AgentMap " .. sid2) end)
t.ok(ui.run and ui.run.sid == sid2, "答えないまま終わった run が開いた")
local c2 = ui.run.state.checks["check:toolu_Q"]
t.eq(c2 and c2.status, "ABANDONED", "答えないまま Stop → ABANDONED")
t.eq(c2 and c2.end_reason, "turn_ended", "終わりの理由 = turn_ended")
mt = map_text()
t.matches(mt, "%[UNANSWERED%]", "図に [UNANSWERED]")
t.matches(mt, "ended unanswered", "箱の 4 行目")
t.ok(not mt:find("wait", 1, true), "確認待ちの印は無い")
t.matches(mt, "%] ask", "子の「ask」の印は残る（答えが出ていない）")
t.ok(hl_in_box("check:toolu_Q").AgentMapPending, "未回答の箱は灰（AgentMapPending）")
t.run("ui.open_check", function() ui.open_check("check:toolu_Q") end)
at = aux_text()
t.matches(at, "■ HUMAN CHECK #1   %[UNANSWERED%]   asked %d%d:%d%d:%d%d   ended %d%d:%d%d:%d%d %(cancelled with Esc, or the reply ended%)", "見出し（括弧を重ねない文言）")
t.matches(at, "%(ended without an answer: cancelled with Esc, or the reply ended%)", "答えの節（書き出しと同じ文言）")
feed("q")

-- 図のバッファを消したら見張りも止まる
vim.api.nvim_buf_delete(ui.buf, { force = true })
t.ok(not af._watching(), "図を消したら見張りも止まる")

-- エラーを知らせたものが無い
for _, n in ipairs(notes) do
  t.ok(not n.msg:find("エラー:", 1, true) and not n.msg:find("失敗", 1, true), "エラーの知らせ: " .. n.msg)
end

vim.fn.delete(dir, "rf")
vim.fn.delete(CDIR, "rf")
t.done()
