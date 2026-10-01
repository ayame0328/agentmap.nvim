-- 指示ごとの「流れ」の画面の試験。
--   ・Space a a（追う）で開いていたら、同じセッションで次の指示の Agent が出た時点でその流れに切り替える
--   ・固定（ID 指定・一覧から）なら切り替えず、1 回だけ知らせる
--   ・一覧の行から開くとその流れ。書き出しも見せている流れだけ
--   ・ほかのセッションで新しい流れが始まったとき（固定なら知らせる、追うなら切り替える）
--   ・ほかのフォルダ（プロジェクト）のセッションでも同じ。見出しにフォルダが出る
local t = require("t")
local notes = {}
vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end
local function count(pat)
  local n = 0
  for _, m in ipairs(notes) do if m:find(pat, 1, true) then n = n + 1 end end
  return n
end

local fixture = vim.g.agentmap_test_dir .. "/fixtures/hooks_probe.jsonl"
if not vim.uv.fs_stat(fixture) then t.skip("fixture が無い"); t.done() end
local af = require("agentmap")
require("agentmap.config").get().poll_ms = 200
require("agentmap.config").get().switch_delay_ms = 1500   -- 試験なので短く
require("agentmap.config").get().debounce_ms = 50
local util = require("agentmap.util")

local lines = vim.fn.readfile(fixture)
local first = vim.json.decode(lines[1])
local slug = vim.fn.fnamemodify(vim.fn.fnamemodify(first.transcript_path, ":h"), ":t")
local root = vim.env.AGENTMAP_DIR
local proj = root .. "/projects/" .. slug
local cwd = root .. "/work"
vim.fn.mkdir(proj, "p")
vim.fn.mkdir(cwd, "p")
vim.fn.writefile({ vim.json.encode({ cwd = cwd, slug = slug }) }, proj .. "/project.json")
vim.fn.chdir(cwd)

local P1 = "c0ffee02-0000-4000-8000-000000000002"
local CHILD, GRAND = "afeed000000000006", "afeed000000000007"
local TU1, TU2 = "toolu_test0000000000000004", "toolu_test0000000000000005"

local function shift(ts, dt)
  local s = util.parse_iso(ts)
  local whole = math.floor(s + dt)
  local ms = math.floor(((s + dt) - whole) * 1000 + 0.5)
  return os.date("!%Y-%m-%dT%H:%M:%S", whole) .. (".%03dZ"):format(ms)
end

--- fixture の from〜upto 行目を、別の指示（pid）として作り直す。Agent の id と説明に suffix を付ける
local function flow_lines(sid, pid, dt, head, suffix, from, upto)
  local out = {}
  for i = from or 2, upto or 11 do
    local l = lines[i]
    for _, k in ipairs({ CHILD, GRAND, TU1, TU2 }) do l = l:gsub(k, k .. suffix) end
    l = l:gsub("probe grandchild", "probe grandchild-" .. suffix):gsub("probe child", "probe child-" .. suffix)
    local d = vim.json.decode(l)
    d.session_id = sid
    d.prompt_id = pid
    d._ts = shift(d._ts, dt)
    if d.hook_event_name == "UserPromptSubmit" then d.prompt_head = head end
    out[#out + 1] = vim.json.encode(d)
  end
  return out
end

local function write(sid, list, mode)
  local d = proj .. "/runs/" .. sid
  vim.fn.mkdir(d, "p")
  vim.fn.writefile(list, d .. "/hooks.jsonl", mode or "")
end

local A = "aaaaaaaa-0000-0000-0000-00000000000a"
local B = "bbbbbbbb-0000-0000-0000-00000000000b"
local P2 = "p2000000-0000-0000-0000-000000000002"
local P3 = "p3000000-0000-0000-0000-000000000003"
local P4 = "p4000000-0000-0000-0000-000000000004"

-- A：1 つ目の指示（子と孫が終わり、Stop まで）
local a1 = {}
for i = 1, 11 do
  local d = vim.json.decode(lines[i]); d.session_id = A
  a1[#a1 + 1] = vim.json.encode(d)
end
write(A, a1)

-- 8. 追う開き方：同じセッションの次の指示に切り替わる
af.open(nil, { follow = true })
local ui = require("agentmap.ui")
t.eq({ ui.run and ui.run.sid, ui.flow_id }, { A, P1 }, "Space a a は A の 1 つ目の指示")
t.ok(af._following(), "追う状態")
-- 次の指示の本文だけ（Agent はまだ）では切り替えない
write(A, flow_lines(A, P2, 60, "二つ目の指示", "x", 2, 2), "a")
vim.wait(800)
t.eq(ui.flow_id, P1, "Agent が出るまでは前の流れのまま")
-- ほかのタブで作業中でも、自動の切り替えでカーソルを図へ動かさない
vim.cmd("tabnew")
local mywin = vim.api.nvim_get_current_win()
write(A, flow_lines(A, P2, 60, nil, "x", 3, 4), "a")
vim.wait(5000, function() return ui.flow_id == P2 end, 50)
t.eq(ui.flow_id, P2, "次の指示の最初の Agent で切り替わった")
t.eq(vim.api.nvim_get_current_win(), mywin, "作業中の窓からカーソルを動かさない")
vim.cmd("tabclose")
t.eq(count("Switched to a new prompt"), 1, "切り替えたことを知らせた")
local l1 = vim.api.nvim_buf_get_lines(ui.buf, 0, 1, false)[1] or ""
t.matches(l1, "prompt 2/2: 二つ目の指示", "見出しに「指示 2/2」と本文")
local body = table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), "\n")
t.ok(body:find("[1]", 1, true) ~= nil, "[1] がある")
t.ok(body:find("[2]", 1, true) == nil, "[2] は無い（1 つ目の指示の Agent は出ない）")
vim.cmd("AgentMapAgent 1")
t.eq(vim.b.agentmap_id, CHILD .. "x", ":AgentMapAgent 1 は今の流れの [1]")
ui.close_aux()

-- 9. 固定：切り替えずに 1 回だけ知らせる
af.open(A)
t.ok(not af._following(), "ID 指定は固定")
t.eq(ui.flow_id, P2, "ID 指定はそのセッションの最新の流れ")
notes = {}
write(A, flow_lines(A, P3, 120, "三つ目の指示", "y", 2, 4), "a")
vim.wait(5000, function() return count("A new flow has started") > 0 end, 50)
write(A, flow_lines(A, P3, 120, nil, "y", 5, 7), "a")
vim.wait(800)
write(A, flow_lines(A, P3, 120, nil, "y", 8, 9), "a")
vim.wait(800)
t.eq(ui.flow_id, P2, "固定なので 2 つ目の指示のまま")
t.eq(count("A new flow has started (:AgentMap opens the latest)"), 1, "知らせるのは 1 回だけ")

-- 10. 一覧の行から開く・書き出しは見せている流れだけ
af._open_item({ sid = A, flow_id = P1, source = "hooks", slug = slug })
t.eq(ui.flow_id, P1, "一覧の行の流れが開く")
t.ok(not af._following(), "一覧から開いたら固定")
local out = vim.fn.tempname() .. ".md"
af.export("markdown", out)
local md = table.concat(vim.fn.readfile(out), "\n")
t.ok(md:find("| Prompt | 1/3 ", 1, true) ~= nil, "書き出しに「Prompt 1/3」")
t.ok(md:find("probe child", 1, true) ~= nil, "1 つ目の指示の Agent がある")
t.ok(md:find("probe child-x", 1, true) == nil and md:find("probe child-y", 1, true) == nil,
  "ほかの指示の Agent は書き出さない")

-- 11. ほかのセッションで新しい流れ：固定なら知らせる、Space a a で移る
notes = {}
local b0 = vim.json.decode(lines[1]); b0.session_id = B
write(B, { vim.json.encode(b0) })
vim.wait(5000, function() return count("A new run has started") > 0 end, 50)
t.eq(count("A new run has started"), 1, "新しい run ができたことを知らせた")
write(B, flow_lines(B, P4, 300, "別セッションの指示", "z", 2, 4), "a")
vim.wait(5000, function() return count("A new flow has started") > 0 end, 50)
t.eq(count("A new flow has started (:AgentMap opens the latest)"), 1, "別セッションの新しい流れを知らせた")
t.eq({ ui.run.sid, ui.flow_id }, { A, P1 }, "固定なので A の 1 つ目の指示のまま")
af.open(nil, { follow = true })
t.eq({ ui.run.sid, ui.flow_id }, { B, P4 }, "Space a a は別セッションの新しい流れ")
t.ok(af._following(), "追う状態に戻る")

-- 追っている間に、A でさらに新しい指示の Agent が出た。
--   いま見ている B の流れはまだ動いているので、切り替えずに知らせるだけ
notes = {}
local P5 = "p5000000-0000-0000-0000-000000000005"
write(A, flow_lines(A, P5, 400, "五つ目の指示", "w", 2, 4), "a")
vim.wait(3000, function() return count("Switching once the current flow finishes") > 0 end, 50)
vim.wait(400)
t.eq({ ui.run.sid, ui.flow_id }, { B, P4 }, "見ている B の流れが動いている間は切り替えない")
t.eq(count("Switching once the current flow finishes"), 1, "新しい流れがあることは1回だけ知らせた")
-- B の流れが終わったら、最新の A の流れへ切り替わる
write(B, flow_lines(B, P4, 300, nil, "z", 5, 11), "a")
vim.wait(5000, function() return ui.run.sid == A end, 50)
t.eq({ ui.run.sid, ui.flow_id }, { A, P5 }, "B が終わったら別セッションの新しい流れへ自動で切り替わった")
t.eq(count("Switched to a new run"), 1, "切り替えたことを知らせた")
-- 次の確認のため、A の五つ目の指示も終わらせておく
write(A, flow_lines(A, P5, 400, nil, "w", 5, 11), "a")
vim.wait(800)

-- 12. 別のフォルダ（プロジェクト）のセッションで新しい流れ：追っていればそちらへ切り替わる。見出しにフォルダ
local cwd2 = root .. "/work2"
local proj2 = root .. "/projects/-tmp-work2"
vim.fn.mkdir(proj2, "p")
vim.fn.writefile({ vim.json.encode({ cwd = cwd2, slug = "-tmp-work2" }) }, proj2 .. "/project.json")
local F = "ffffffff-0000-0000-0000-00000000000f"
local P6 = "p6000000-0000-0000-0000-000000000006"
local f1 = {}
for _, l in ipairs(flow_lines(F, P6, 500, "別プロジェクトの指示", "v", 2, 4)) do
  local d = vim.json.decode(l); d.cwd = cwd2
  f1[#f1 + 1] = vim.json.encode(d)
end
vim.fn.mkdir(proj2 .. "/runs/" .. F, "p")
vim.fn.writefile(f1, proj2 .. "/runs/" .. F .. "/hooks.jsonl")
vim.wait(5000, function() return ui.run.sid == F end, 50)
t.eq({ ui.run.sid, ui.flow_id }, { F, P6 }, "別プロジェクトの新しい流れへ自動で切り替わった")
t.eq(count("Switched to a new run"), 2, "切り替えたことを知らせた")
local l1 = vim.api.nvim_buf_get_lines(ui.buf, 0, 1, false)[1] or ""
t.ok(l1:find("work2", 1, true) ~= nil, "見出しに別プロジェクトのフォルダ: " .. l1)
t.ok(l1:find("prompt 1/1", 1, true) ~= nil, "見出しに「指示 1/1」: " .. l1)

-- 固定で開いているときは、ほかのプロジェクトの新しい流れを 1 回だけ知らせる
af.open(F)
t.ok(not af._following(), "ID 指定で開いたら固定")
local n0 = count("A new flow has started (:AgentMap opens the latest)")
local P7 = "p7000000-0000-0000-0000-000000000007"
write(A, flow_lines(A, P7, 700, "七つ目の指示", "u", 2, 4), "a")
vim.wait(5000, function() return count("A new flow has started (:AgentMap opens the latest)") > n0 end, 50)
vim.wait(600)
t.eq(count("A new flow has started (:AgentMap opens the latest)"), n0 + 1, "別プロジェクトの新しい流れを 1 回だけ知らせた")
t.eq(ui.run.sid, F, "固定なので F のまま")

t.done()
