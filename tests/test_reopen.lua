-- Test: reaching the children of a finished flow (2026-10-01: folding ROOT with - hid the children, and Enter on the
-- first line of the detail view stopped with an error)
--   図：畳んだ箱があると凡例に開き方が出る／畳んだ箱で Enter → 子が図に戻り、詳細が開く
--   詳細：開けない行で Enter → 一番近い開ける行へ移る → もう一度 Enter で子の詳細
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local cfgdir = vim.fn.fnamemodify(here, ":h")
vim.opt.rtp:prepend(cfgdir)
vim.o.columns, vim.o.lines = 200, 50

local fails, passes = 0, 0
local function ok(cond, msg)
  if cond then passes = passes + 1 else
    fails = fails + 1
    io.stderr:write("  NG: " .. msg .. "\n")
  end
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end
local function bufname() return vim.api.nvim_buf_get_name(0) end
-- 画面の文言は英語（既定の言語）。英語の文言そのものは W2 の表で決まるので、ここでは
-- 「要の記号（[+n]・+・Enter）が入っている」「日本語（CJK）が混ざっていない」を見る
local function no_cjk(s) return type(s) == "string" and not s:find("[\227-\233][\128-\191][\128-\191]") end
local function hint_line(text)
  for l in (text .. "\n"):gmatch("(.-)\n") do
    if l:find("[+n]", 1, true) then return l end
  end
end

local state = dofile(here .. "/fixtures/state_small.lua")
local run = { dir = vim.fn.tempname(), sid = state.run_id, state = state }
local ui = require("agentmap.ui")
local notes = {}
vim.notify = function(m) notes[#notes + 1] = m end

ui.open_map(run)
local map_buf = vim.api.nvim_get_current_buf()
local function map_text() return table.concat(vim.api.nvim_buf_get_lines(map_buf, 0, -1, false), "\n") end
ok(not map_text():find("[+n]", 1, true), "畳んでいなければ開き方の案内は出ない")

-- ROOT で - → 畳む。案内が凡例と通知に出る
ok(ui.current_id() == "ROOT", "開いた直後は ROOT")
feed("-")
ok(ui.view.collapsed.ROOT == true, "- で ROOT が畳まれる")
local hl = hint_line(map_text())
ok(hl and hl:find("Enter", 1, true) and hl:find(" + ", 1, true) and no_cjk(hl), "凡例に開き方が英語で出る: " .. tostring(hl))
ok(notes[#notes] and notes[#notes]:find("Enter", 1, true) and notes[#notes]:find("+", 1, true) and no_cjk(notes[#notes]),
  "畳んだときに通知（英語）: " .. tostring(notes[#notes]))

-- 畳んだ ROOT で Enter → 開いて詳細
feed("<CR>")
ok(ui.view.collapsed.ROOT == nil, "Enter で畳みが解ける")
ok(not map_text():find("[+n]", 1, true), "開いたら案内は消える")
ok(bufname():find("agentmap://detail/ROOT", 1, true) ~= nil, "ROOT の詳細が開く: " .. bufname())

-- 詳細の先頭行で Enter → 開ける行へ移る（エラーで止まらない）
vim.api.nvim_win_set_cursor(0, { 1, 0 })
feed("<CR>")
local row = vim.api.nvim_win_get_cursor(0)[1]
ok(row > 1, "開ける行へカーソルが移る（行 " .. row .. "）")
ok(bufname():find("agentmap://detail/ROOT", 1, true) ~= nil, "移っただけで画面は変わらない")
ok(notes[#notes] and notes[#notes]:find("Enter", 1, true) and no_cjk(notes[#notes]), "案内の通知（英語）: " .. tostring(notes[#notes]))
feed("<CR>")
ok(bufname():find("agentmap://detail/ROOT", 1, true) == nil and bufname():find("agentmap://", 1, true) ~= nil,
  "もう一度 Enter で子の画面が開く: " .. bufname())

io.stdout:write(string.format("  %d 件 OK, %d 件 NG\n", passes, fails))
vim.cmd(fails == 0 and "qa!" or "cq!")
