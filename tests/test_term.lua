-- Sending to the Claude terminal (term.lua, DESIGN-v0.2-steer.md §4.1). No real Claude Code:
-- a small script named `claude` runs in a real :terminal and appends every line it receives to a
-- file, so the test sees exactly what Claude Code would have been typed.
local t = require("t")
local term = require("agentmap.term")

-- 1. 名前の読み方（純粋）
t.run("parse / is_claude_cmd", function()
  local d, pid, cmd = term.parse_name("term:///home/user/work//12345:claude --model opus")
  t.eq({ d, pid, cmd }, { "/home/user/work", 12345, "claude --model opus" }, "term://<dir>//<pid>:<cmd>")
  t.eq(term.parse_name("/tmp/file.txt"), nil, "端末でない名前")
  t.ok(term.is_claude_cmd("claude"), "claude")
  t.ok(term.is_claude_cmd("CLAUDE_CONFIG_DIR=/home/u/.claude-x claude"), "環境変数つき")
  t.ok(term.is_claude_cmd("/usr/local/bin/claude --resume"), "フルパス")
  t.ok(not term.is_claude_cmd("CLAUDE_CONFIG_DIR=/x bash"), "環境変数の名前だけでは数えない")
  t.ok(not term.is_claude_cmd("/bin/bash"), "bash は違う")
  t.ok(not term.is_claude_cmd("nvim ~/.claude/settings.json"), "設定フォルダの名前は違う")
  t.eq(term.sanitize("a\nb\r\27[2Jc\td"), "a b [2Jc d", "制御文字は空白に（1 行で送る）")
end)

-- 2. 本物の :terminal で偽の claude を動かす
local tmp = vim.fn.tempname()
local bin = tmp .. "/bin"
local work = tmp .. "/work"
local other = tmp .. "/other"
for _, d in ipairs({ bin, work, other, work .. "/sub" }) do vim.fn.mkdir(d, "p") end
local function fake(name)
  local p = bin .. "/" .. name
  vim.fn.writefile({
    "#!/bin/sh",
    "# test stand-in for Claude Code: write every received line to $OUT",
    "stty -echo 2>/dev/null",
    "echo ready",
    'while IFS= read -r line; do printf "%s\\n" "$line" >> "$OUT"; done',
  }, p)
  vim.fn.setfperm(p, "rwxr-xr-x")
  return p
end
local claude = fake("claude")
local notclaude = fake("helper")

local function open_term(cmd, cwd, out)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  local job
  if vim.fn.has("nvim-0.11") == 1 then
    job = vim.fn.jobstart({ cmd }, { term = true, cwd = cwd, env = { OUT = out } })
  else
    job = vim.fn.termopen({ cmd }, { cwd = cwd, env = { OUT = out } })
  end
  return buf, job
end

local out_work = tmp .. "/work.out"
local out_other = tmp .. "/other.out"
local out_helper = tmp .. "/helper.out"
local b_other, j_other = open_term(claude, other, out_other)
local b_helper = open_term(notclaude, work, out_helper)
local b_work, j_work = open_term(claude, work, out_work)
-- 起動を待つ（"ready" が画面に出る）
local function ready(b)
  return vim.wait(5000, function()
    return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("ready", 1, true) ~= nil
  end, 20)
end
t.ok(ready(b_other) and ready(b_work) and ready(b_helper), "偽の claude が端末で動いた")
t.ok(vim.api.nvim_buf_get_name(b_work):match("^term://.*//%d+:.*claude$") ~= nil,
  "端末の名前は term://<dir>//<pid>:…claude（" .. vim.api.nvim_buf_get_name(b_work) .. "）")

t.run("candidates / find", function()
  local list = term.candidates(work)
  t.eq(#list, 2, "claude の端末だけ（helper は除く）")
  t.eq(list[1].buf, b_work, "cwd が同じ端末が先頭")
  t.eq(list[1].score, 3, "同じフォルダ = 3")
  t.eq(list[2].score, 1, "関係ないフォルダ = 1")
  local sub = term.candidates(work .. "/sub")
  t.eq({ sub[1].buf, sub[1].score }, { b_work, 2 }, "親フォルダ = 2")
  local c, _, tied = term.find(work)
  t.eq({ c and c.buf, tied }, { b_work, false }, "find は一番よいもの")
  local c2, l2, tied2 = term.find(tmp .. "/elsewhere")
  t.eq({ c2, #l2, tied2 }, { nil, 2, true }, "同点なら選ばせる（nil と候補）")
  t.eq(#term.candidates(work, { b_helper }), 0, "引数のバッファだけを見る")
end)

local function read(p)
  if vim.fn.filereadable(p) == 0 then return {} end
  return vim.fn.readfile(p)
end

t.run("send", function()
  local ok = term.send(j_work, "[AgentMap] use docs/v3,\nnot v2")
  t.ok(ok, "送れた")
  vim.wait(3000, function() return #read(out_work) >= 1 end, 20)
  t.eq(read(out_work), { "[AgentMap] use docs/v3, not v2" }, "本文＋Enter が 1 行として届く（改行は空白に）")
  t.eq(read(out_other), {}, "ほかの端末には届かない")
  -- 本文と Enter を分けて送る（submit_delay_ms > 0）
  t.ok(term.send(j_work, "second", { delay_ms = 50 }), "分けて送れた")
  vim.wait(3000, function() return #read(out_work) >= 2 end, 20)
  t.eq(read(out_work)[2], "second", "遅れて Enter が届く")
  -- chansend の呼ばれ方
  local calls = {}
  local orig = vim.fn.chansend
  vim.fn.chansend = function(job, data) calls[#calls + 1] = { job, data } return #data end
  term.send(j_work, "one write")
  vim.fn.chansend = orig
  t.eq(calls, { { j_work, "one write\r" } }, "既定は本文と \\r を 1 回で")
  t.eq({ term.send(j_work, "  \n ") }, { false, "empty" }, "空は送らない")
end)

t.run("dead job", function()
  vim.fn.jobstop(j_other)
  vim.wait(3000, function() return vim.fn.jobwait({ j_other }, 0)[1] ~= -1 end, 20)
  local list = term.candidates(work)
  t.eq(#list, 1, "終わった端末は候補から外れる")
  local ok, err = term.send(j_other, "x")
  t.eq({ ok, err }, { false, "terminal job is not running" }, "終わった端末には送らない")
end)

vim.fn.jobstop(j_work)
local _ = b_other
t.done()
