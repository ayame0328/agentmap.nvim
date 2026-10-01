-- 判定係（review provider）の選び方の試験。
--   Jev が入っている PC と入っていない PC があっても、黙って食い違わないことを確かめる。
local t = require("t")
local R = require("agentmap.review")
local notes = {}
vim.notify = function(m) notes[#notes + 1] = m end

vim.g.agentmap_review_provider = nil
t.eq(R.pick(), "manual", "判定係が何も無い PC は auto → manual")

R.register("jev", { available = function() return false, "jev.py が無い" end, evaluate = function() end })
t.eq(R.pick(), "manual", "Jev が使えない PC なら auto → manual")
t.eq(#notes, 0, "auto のときは警告を出さない")

vim.g.agentmap_review_provider = "jev"
t.eq(R.pick(), "manual", "jev を名指ししても使えなければ manual")
t.ok(notes[1] and notes[1]:find("jev.py が無い", 1, true), "しかも理由つきで知らせる")

R.register("jev", { available = function() return true end, evaluate = function() end })
vim.g.agentmap_review_provider = nil
t.eq(R.pick(), "jev", "Jev が使える PC なら auto → jev")
vim.g.agentmap_review_provider = "manual"
t.eq(R.pick(), "manual", "local.lua で manual に固定できる")

-- 判定係が落ちても、レビューそのものは取り消さない
vim.g.agentmap_review_provider = "boom"
R.register("boom", { evaluate = function() error("通信失敗") end })
local asked = false
R.providers.manual.evaluate = function(_, cb) asked = true; cb(nil) end
R.evaluate({ state = { agents = { x = { id = "x", index = 1 } } } }, "x", function() end)
t.ok(asked, "判定係がエラーでも手動の選択が出る")

t.done()
