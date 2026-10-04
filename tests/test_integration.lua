-- End-to-end test: recorded hook payloads (fixtures/hooks_probe.jsonl, anonymized) -> events.load -> map
-- -> auto refresh by the watcher -> export -> review.
--   記録の保存先は一時フォルダ（minimal_init.lua が AGENTMAP_DIR を決める）。
--   画面の文言は英語（既定の言語）で確かめる。書き出し（export.lua）の見出しは Stage 3 で英語になるので、
--   言語に依らない部分（"| hooks |"、判定と理由）だけを見る。
local t = require("t")
local mc = require("mermaid_check")

local notes = {}
vim.notify = function(msg, lvl) notes[#notes + 1] = { msg = tostring(msg), lvl = lvl } end

local fixture = vim.g.agentmap_test_dir .. "/fixtures/hooks_probe.jsonl"
if not vim.uv.fs_stat(fixture) then
  t.skip("fixtures/hooks_probe.jsonl が無い")
  t.done()
end
for _, m in ipairs({ "agentmap.events", "agentmap.ui", "agentmap.state", "agentmap.review" }) do
  if not pcall(require, m) then
    t.ok(false, m .. " を読み込めない")
    t.done()
  end
end
local af = require("agentmap")
local events = require("agentmap.events")

local lines = vim.fn.readfile(fixture)
local first = vim.json.decode(lines[1])
local sid = first.session_id
local slug = vim.fn.fnamemodify(vim.fn.fnamemodify(first.transcript_path, ":h"), ":t")
local root = vim.env.AGENTMAP_DIR
local run_dir = root .. "/projects/" .. slug .. "/runs/" .. sid
vim.fn.mkdir(run_dir, "p")
vim.fn.writefile({ vim.json.encode({ cwd = first.cwd, slug = slug }) }, root .. "/projects/" .. slug .. "/project.json")

-- 孫が終わったところ（9 行目）まで入れる。子はまだ動いている
local hooks_path = run_dir .. "/hooks.jsonl"
vim.fn.writefile(vim.list_slice(lines, 1, 9), hooks_path)

local CHILD, GRAND = "afeed000000000006", "afeed000000000007"

-- 図を開く
t.run(":AgentMap <sid>", function() vim.cmd("AgentMap " .. sid) end)
local ui = require("agentmap.ui")
t.ok(ui.run and ui.run.sid == sid, "run が開いた")
t.ok(af._watching(), "見張りが動いている")
local s = ui.run.state
t.eq(s.agents[CHILD] and s.agents[CHILD].parent_id, "ROOT", "子の親は ROOT（hook から確定）")
t.eq(s.agents[GRAND] and s.agents[GRAND].parent_id, CHILD, "孫の親は子（hook から確定）")
t.eq(s.agents[GRAND] and s.agents[GRAND].status, "DONE", "孫は DONE")
t.eq(s.agents[CHILD] and s.agents[CHILD].status, "RUNNING", "子はまだ RUNNING")

local function buf_text()
  if not ui.buf or not vim.api.nvim_buf_is_valid(ui.buf) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
end
t.matches(buf_text(), "%[RUNNING%]", "図に [RUNNING]")
t.matches(buf_text(), "%[DONE%]", "図に [DONE]")
t.matches(buf_text(), "%[1%]", "図に [1]")
t.matches(buf_text(), "%[2%]", "図に [2]")
t.matches(buf_text(), "~%d+%.%d%%", "ROOT の進み具合が推定（~nn.n%）で出る")

-- 子が終わった記録を足す → 見張りが気付いて図が変わる
local f = assert(io.open(hooks_path, "ab"))
f:write(lines[10] .. "\n")
f:close()
local updated = vim.wait(6000, function()
  return ui.run.state.agents[CHILD].status == "DONE"
end, 50)
t.ok(updated, "ファイルが増えたら自動で図が更新される（子 → DONE）")

-- Agent の詳細
t.run(":AgentMapAgent 2", function() vim.cmd("AgentMapAgent 2") end)
local names = {}
for _, b in ipairs(vim.api.nvim_list_bufs()) do names[#names + 1] = vim.api.nvim_buf_get_name(b) end
t.matches(table.concat(names, "\n"), "agentmap://detail/", "詳細の画面が開く")

-- レビュー：本人が RETRY
t.run(":AgentMapReview 1 RETRY", function() vim.cmd("AgentMapReview 1 RETRY no evidence") end)
local a1 = ui.run.state.agents[CHILD]
t.eq(a1.status, "REWORK", "RETRY で REWORK")
t.eq(a1.rework_count, 1, "差し戻し 1 回")
t.matches(buf_text(), "%[REWORK%]", "図に [REWORK]")
t.run("使い方の間違い", function() vim.cmd("AgentMapReview 1 MAYBE") end)
t.matches(notes[#notes].msg, "^AgentMap: Usage: :AgentMapReview ", "間違った判定は使い方を知らせる（init.review_usage）")

-- 書き出し
local dir = vim.fn.tempname()
local path
t.run("export markdown", function() path = af.export("markdown", dir .. "/run.md") end)
t.eq(path, dir .. "/run.md", "markdown を書き出した")
local md = path and table.concat(vim.fn.readfile(path), "\n") or ""
local blocks = mc.blocks(md)
t.eq(#blocks, 1, "mermaid が 1 つ")
t.eq((mc.check(blocks[1] or "")), {}, "Mermaid の形が正しい")
t.matches(blocks[1] or "", "n_ROOT %-%-> n_" .. CHILD, "ROOT → 子")
t.matches(blocks[1] or "", "n_" .. CHILD .. " %-%-> n_" .. GRAND, "子 → 孫")
t.matches(blocks[1] or "", "|RETRY|", "差し戻しの矢印")
t.matches(md, "| hooks |", "記録元は hooks")
t.matches(md, "RETRY.-no evidence", "レビュー履歴（判定と理由）")
local real, out = mc.mmdc(blocks[1] or "")
if real ~= nil then t.ok(real, "本物の mermaid でも読める\n" .. tostring(out)) end

local p_html
t.run("export html", function() p_html = af.export("html", dir .. "/run.html") end)
t.ok(p_html and vim.uv.fs_stat(p_html), "html を書き出した")

-- 既定の書き出し先は run の exports/
local p_def
t.run("export 既定の場所", function() p_def = af.export("markdown") end)
t.matches(p_def or "", "^" .. vim.pesc(run_dir) .. "/exports/agentmap%-c0ffee01%-", "既定は run の exports/")

-- 読み直し
t.run(":AgentMapRefresh", function() vim.cmd("AgentMapRefresh") end)
t.eq(notes[#notes].msg, "AgentMap: Reloaded", "読み直しの知らせ（init.refreshed）")

-- 図のバッファを消したら見張りも止まる
local buf = ui.buf
vim.api.nvim_buf_delete(buf, { force = true })
t.ok(not af._watching(), "図を消したら見張りも止まる")

-- エラーを知らせたものが無い
for _, n in ipairs(notes) do
  t.ok(not n.msg:find("Error:", 1, true) and not n.msg:find("エラー:", 1, true), "エラーの知らせ: " .. n.msg)
end

vim.fn.delete(dir, "rf")
t.done()
