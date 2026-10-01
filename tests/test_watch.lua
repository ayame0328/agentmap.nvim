-- Tests for lua/agentmap/watch.lua: when files grow or appear, notify once after things settle.
local t = require("t")
local watch = require("agentmap.watch")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function append(name, s)
  local f = assert(io.open(dir .. "/" .. name, "ab"))
  f:write(s)
  f:close()
end

-- 1. 変更通知あり（ふつうの Linux フォルダ）
local n = 0
local h = watch.start(dir, function() n = n + 1 end, { poll_ms = 300, debounce_ms = 100 })
t.eq(h.mode, "fs_event+poll", "Linux 側では変更通知と確認の両方")
for i = 1, 5 do append("hooks.jsonl", "{}\n") end -- 立て続けに 5 回
t.ok(vim.wait(3000, function() return n >= 1 end, 20), "変化に気付く")
vim.wait(600, function() return false end)
t.eq(n, 1, "立て続けの変化は 1 回にまとめる")
append("events.jsonl", "{}\n")
t.ok(vim.wait(3000, function() return n >= 2 end, 20), "events.jsonl ができたのにも気付く")
watch.stop(h)
watch.stop(h) -- 2 回呼んでもよい
local before = n
append("hooks.jsonl", "{}\n")
vim.wait(800, function() return false end)
t.eq(n, before, "止めた後は知らせない")

-- 2. 確認（polling）だけでも気付く（/mnt/ の下と同じ扱い）
local m = 0
local h2 = watch.start(dir, function() m = m + 1 end, { poll_ms = 200, debounce_ms = 50, no_fs_event = true })
t.eq(h2.mode, "poll", "変更通知なし")
append("hooks.jsonl", "{}\n")
t.ok(vim.wait(3000, function() return m >= 1 end, 20), "確認だけでも気付く")
watch.stop(h2)

-- 3. フォルダの中身（新しい run のフォルダができる）を見る
local k = 0
local h3 = watch.start(dir, function() k = k + 1 end, { files = {}, poll_ms = 200, debounce_ms = 50, no_fs_event = true })
vim.fn.mkdir(dir .. "/new-run", "p")
t.ok(vim.wait(3000, function() return k >= 1 end, 20), "新しいフォルダに気付く")
watch.stop(h3)

-- 4. 知らせ先でエラーが起きても止まらない
local notes = {}
vim.notify = function(msg) notes[#notes + 1] = msg end
local h4 = watch.start(dir, function() error("boom on purpose") end, { poll_ms = 200, debounce_ms = 50 })
append("hooks.jsonl", "{}\n")
t.ok(vim.wait(3000, function() return #notes >= 1 end, 20), "エラーは知らせに変える")
t.matches(notes[1] or "", "^AgentMap: ", "知らせの文は AgentMap: で始まる")
t.matches(notes[1] or "", "boom on purpose", "知らせの文にエラーの中身")
-- 英語（既定の言語）の文言そのものは W2 の表で決まるので、日本語が混ざっていないことだけを見る
t.ok(not (notes[1] or ""):find("[\227-\233][\128-\191][\128-\191]"), "知らせの文は英語: " .. tostring(notes[1]))
watch.stop(h4)

vim.fn.delete(dir, "rf")
t.done()
