-- Steering from the map (DESIGN-v0.2-steer.md §2, §4, §6.1, §6.2): the `s` menu, the instruction
-- window, the route for each kind of box (running agent → hooks, ROOT → terminal, finished agent →
-- redo request in the terminal), the fallbacks without a terminal, cancel, :AgentMapSteer, and the
-- "not delivered" notice. The events.* functions that write files are replaced with recorders;
-- the terminal is a real :terminal running a small stand-in script named `claude`.
local t = require("t")
local ui = require("agentmap.ui")
local events = require("agentmap.events")
local config = require("agentmap.config")
local i18n = require("agentmap.i18n")
local T = i18n.t

local notes = {}
vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end
local function noted(s)
  for _, m in ipairs(notes) do if m:find(s, 1, true) then return true end end
  return false
end

-- events の差し替え（記録するだけ）
local calls = {}
local seq = 0
events.request_steer = function(run, agent_id, text, opts)
  seq = seq + 1
  local id = agent_id .. "-" .. seq
  calls[#calls + 1] = { fn = "request", agent_id = agent_id, text = text, opts = opts, id = id }
  return id
end
events.mark_steer_sent = function(run, id) calls[#calls + 1] = { fn = "sent", id = id } end
events.cancel_steer = function(run, id) calls[#calls + 1] = { fn = "cancel", id = id } end
local function last(fn)
  for i = #calls, 1, -1 do if calls[i].fn == fn then return calls[i] end end
end

-- vim.ui.select の差し替え：次に選ぶ番号を積んでおく
local picks, menus = {}, {}
vim.ui.select = function(items, opts, cb)
  local labels = {}
  for i, it in ipairs(items) do labels[i] = opts.format_item and opts.format_item(it) or it end
  menus[#menus + 1] = { prompt = opts.prompt, items = labels }
  local n = table.remove(picks, 1)
  cb(n and items[n] or nil, n)
end

local tmp = vim.fn.tempname()
local work = tmp .. "/work"
vim.fn.mkdir(work, "p")
local s = dofile(vim.g.agentmap_test_dir .. "/fixtures/state_small.lua")
s.cwd = work
s.agents.a1.status = "RUNNING" -- 動いている子
s.agents.a1.finished_at = nil
-- a2 は REWORK（終わった箱）
s.agents.a2.finished_at = "2026-09-28T04:28:00.000Z"
s.steers = {}
local dir = vim.env.AGENTMAP_DIR .. "/projects/-tmp-steer/runs/" .. s.run_id
vim.fn.mkdir(dir, "p")
local run = { dir = dir, sid = s.run_id, slug = "-tmp-steer", state = s, off = {} }
ui.open_map(run)

-- 1. 宛先と経路
t.run("target / kind", function()
  t.eq(ui.steer_target("a1"), "a1", "Agent")
  t.eq(ui.steer_target("gate:a2"), "a2", "門は元の Agent")
  t.eq(ui.steer_target("ROOT"), "ROOT", "ROOT")
  for _, id in ipairs({ "check:x", "wf:abc", "UNKNOWN_PARENT", "START", "END", "stage:1", "nope" }) do
    t.eq(ui.steer_target(id), nil, "送れない箱: " .. id)
  end
  t.eq({ ui.steer_kind("ROOT"), ui.steer_kind("a1"), ui.steer_kind("a2") }, { "root", "hook", "redo" },
    "ROOT は端末、動いている子は hooks、終わった子はやり直し依頼")
end)

-- 2. s → 書く → 窓で :w → hooks へ
local function feed(keys)
  vim.cmd("stopinsert")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function input_buf()
  local b = vim.api.nvim_get_current_buf()
  if vim.bo[b].buftype == "acwrite" and vim.b[b].agentmap_steer_target then return b end
end

t.run("menu → window → hook", function()
  picks = { 1 }
  ui.steer_menu("a1")
  t.eq(#menus[#menus].items, 2, "未配達が無ければ「書く」と「履歴」の 2 つ")
  t.eq(menus[#menus].items[1], T("ui.steer_write"), "動いている箱は「指示を書く」")
  local b = input_buf()
  t.ok(b ~= nil, "入力の窓が開いた")
  t.ok(vim.api.nvim_win_get_config(0).relative ~= "", "浮かせた窓")
  t.eq(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1], T("ui.steer_hint"), "1 行目は案内")
  vim.api.nvim_buf_set_lines(b, 1, -1, false, { "資料は docs/v3 を読むこと。", "v2 は古い。" })
  vim.cmd("write")
  vim.wait(200, function() return not vim.api.nvim_buf_is_valid(b) end, 10)
  t.ok(not vim.api.nvim_buf_is_valid(b), ":w で送って窓を閉じた")
  local c = last("request")
  t.eq({ c.agent_id, c.text, c.opts.via, c.opts.kind }, { "a1", "資料は docs/v3 を読むこと。\nv2 は古い。", "hook", "steer" },
    "宛先 a1・本文（案内の行は落とす）・hooks")
  t.ok(noted(T("ui.steer_queued", { label = ui._steer_label("a1") })), "置いたことを知らせた")
end)

t.run("window keys", function()
  local n0 = #calls
  ui.steer_input("a1")
  local b = input_buf()
  vim.api.nvim_buf_set_lines(b, 1, -1, false, { "draft" })
  feed("q")
  t.ok(not vim.api.nvim_buf_is_valid(b), "q で取り消し（窓が閉じる）")
  t.eq(#calls, n0, "取り消したら送らない")
  ui.steer_input("a1")
  b = input_buf()
  feed("<CR>")
  t.eq(#calls, n0, "空なら送らない")
  ui.steer_input("a1")
  b = input_buf()
  vim.api.nvim_buf_set_lines(b, 1, -1, false, { "by ctrl-s" })
  feed("<C-s>")
  vim.wait(200, function() return not vim.api.nvim_buf_is_valid(b) end, 10)
  t.eq(last("request").text, "by ctrl-s", "<C-s> で送る")
  config.get().steer.input = "line"
  local orig = vim.ui.input
  vim.ui.input = function(o, cb) cb("one line") end
  ui.steer_input("a1")
  vim.ui.input = orig
  config.get().steer.input = "window"
  t.eq(last("request").text, "one line", "steer.input = line は vim.ui.input")
end)

-- 3. 取り消し
t.run("cancel", function()
  s.steers["a1-x"] = { id = "a1-x", agent_id = "a1", status = "PENDING", text = "old", requested_at = "2026-09-28T04:30:00.000Z" }
  s.steers["a1-y"] = { id = "a1-y", agent_id = "a1", status = "DELIVERED", text = "done", requested_at = "2026-09-28T04:29:00.000Z" }
  s.agents.a1.steers = { "a1-y", "a1-x" }
  s.steer_order = { "a1-y", "a1-x" }
  picks = { 2 }
  ui.steer_menu("a1")
  t.eq(menus[#menus].items[2], T("ui.steer_cancel_n", { n = 1 }), "未配達があれば「取り消す (1)」")
  t.eq(last("cancel").id, "a1-x", "未配達の 1 件を取り消した")
  s.steers = {}
  s.steer_order = {}
  s.agents.a1.steers = nil
end)

-- 4. ROOT：端末が無い → hooks に落とす
t.run("ROOT without terminal", function()
  notes = {}
  local r = ui.steer_send("ROOT", "please stop and summarize")
  t.eq(r, "fallback_hook", "端末が無いので hooks へ")
  local c = last("request")
  t.eq({ c.agent_id, c.text, c.opts.via }, { "ROOT", "please stop and summarize", "hook" }, "ROOT 宛てに hooks で")
  t.ok(noted(T("ui.steer_no_terminal_hook")), "知らせた")
  config.get().steer.no_terminal = "none"
  local n0 = #calls
  t.eq(ui.steer_send("ROOT", "x"), "none", "no_terminal = none")
  t.eq(#calls, n0, "何も記録しない")
  config.get().steer.no_terminal = "clipboard"
  t.eq(ui.steer_send("ROOT", "copy me"), "clipboard", "no_terminal = clipboard")
  t.eq(vim.fn.getreg('"'), "[AgentMap] copy me", "文をコピーした")
  t.eq(last("request").opts.via, "terminal", "記録は terminal 宛て（PENDING のまま）")
  config.get().steer.no_terminal = "hook"
  config.get().steer.root_via = "hook"
  t.eq(ui.steer_send("ROOT", "via hook"), "queued", "root_via = hook なら端末を探さない")
  config.get().steer.root_via = "terminal"
end)

-- 5. 本物の :terminal（偽の claude）へ
local bin = tmp .. "/bin"
vim.fn.mkdir(bin, "p")
local claude = bin .. "/claude"
vim.fn.writefile({
  "#!/bin/sh",
  "stty -echo 2>/dev/null",
  "echo ready",
  'while IFS= read -r line; do printf "%s\\n" "$line" >> "$OUT"; done',
}, claude)
vim.fn.setfperm(claude, "rwxr-xr-x")
local function open_term(cwd, out)
  vim.cmd("tabnew")
  local b = vim.api.nvim_get_current_buf()
  local job
  if vim.fn.has("nvim-0.11") == 1 then
    job = vim.fn.jobstart({ claude }, { term = true, cwd = cwd, env = { OUT = out } })
  else
    job = vim.fn.termopen({ claude }, { cwd = cwd, env = { OUT = out } })
  end
  vim.wait(5000, function()
    return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("ready", 1, true) ~= nil
  end, 20)
  vim.cmd("tabprevious")
  return b, job
end
local out1 = tmp .. "/t1.out"
local tb1, tj1 = open_term(work, out1)
local function read(p) return vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or {} end

t.run("ROOT to terminal", function()
  notes = {}
  local r = ui.steer_send("ROOT", "use the\nsmaller model")
  t.eq(r, "sent", "端末へ送った")
  vim.wait(3000, function() return #read(out1) >= 1 end, 20)
  t.eq(read(out1)[1], "[AgentMap] use the smaller model", "[AgentMap] ＋本文が 1 行で届いた")
  local c = last("request")
  t.eq({ c.agent_id, c.opts.via, c.opts.kind }, { "ROOT", "terminal", "steer" }, "terminal 宛ての記録")
  t.eq(last("sent").id, c.id, "送れたので mark_steer_sent")
  t.ok(noted(T("ui.steer_sent")), "知らせた")
  t.ok(vim.api.nvim_get_current_buf() == ui.buf, "カーソルは図のまま（端末へ移らない）")
end)

t.run("redo a finished agent", function()
  picks = { 1 }
  ui.steer_menu("a2")
  t.eq(menus[#menus].items[1], T("ui.steer_redo"), "終わった箱は「親にやり直しを頼む」")
  local b = input_buf()
  vim.api.nvim_buf_set_lines(b, 1, -1, false, { "テストも書くこと" })
  vim.cmd("write")
  vim.wait(3000, function() return #read(out1) >= 2 end, 20)
  local line = read(out1)[2] or ""
  t.matches(line, "^%[AgentMap%] Please redo agent %[2%] \"", "やり直し依頼の文（英語の UI）")
  t.ok(line:find("テストも書くこと", 1, true) ~= nil and line:find("id a2", 1, true) ~= nil, "本文と id が入る: " .. line)
  local c = last("request")
  t.eq({ c.agent_id, c.opts.kind, c.opts.redo_of, c.opts.via }, { "ROOT", "redo", "a2", "terminal" }, "ROOT 宛ての redo")
  t.eq(s.agents.a2.status, "REWORK", "差し戻しは記録しない（状態はそのまま）")
end)

t.run("two terminals: pick and remember", function()
  local out2 = tmp .. "/t2.out"
  local _, tj2 = open_term(work, out2)
  menus = {}
  picks = { 2 }
  t.eq(ui.steer_send("ROOT", "which one"), "sent", "選んで送った")
  t.eq(menus[1] and menus[1].prompt, T("ui.steer_pick_terminal"), "同じ点の端末が 2 つなら選ばせる")
  local chosen = ui.term_choice[s.run_id]
  t.ok(chosen ~= nil, "選んだ端末を覚えた")
  menus = {}
  t.eq(ui.steer_send("ROOT", "again"), "sent", "2 回目")
  t.eq(#menus, 0, "2 回目は聞かない")
  vim.wait(3000, function() return #read(out1) + #read(out2) >= 4 end, 20)
  local got = vim.list_extend(vim.deepcopy(read(out1)), read(out2))
  t.ok(vim.tbl_contains(got, "[AgentMap] which one") and vim.tbl_contains(got, "[AgentMap] again"), "どちらかの端末に届いた")
  vim.fn.jobstop(tj2)
end)

-- 6. 断る・無効
t.run("refuse / disabled", function()
  notes = {}
  menus = {}
  ui.steer_menu("check:x")
  t.eq(#menus, 0, "HUMAN CHECK にはメニューを出さない")
  t.ok(noted(T("ui.steer_not_target")), "送れないと知らせた")
  config.get().steer.enabled = false
  ui.steer_menu("a1")
  t.eq(#menus, 0, "steer.enabled = false ならメニューを出さない")
  t.ok(noted(T("ui.steer_disabled")), "無効と知らせた")
  config.get().steer.enabled = true
end)

-- 7. :AgentMapSteer と s キー
t.run("command and key", function()
  vim.cmd("AgentMapSteer 1 from the command line")
  local c = last("request")
  t.eq({ c.agent_id, c.text }, { "a1", "from the command line" }, ":AgentMapSteer 1 <本文>")
  vim.cmd("AgentMapSteer a1")
  local b = input_buf()
  t.ok(b ~= nil, "本文が無ければ入力の窓")
  feed("q")
  -- 図の上の s
  vim.api.nvim_set_current_win(ui.win)
  for _ = 1, 10 do
    if ui.current_id() == "a1" then break end
    ui.move(1)
  end
  t.eq(ui.current_id(), "a1", "カーソルは a1 の箱")
  menus = {}
  picks = {}
  feed("s")
  t.eq(menus[1] and menus[1].prompt, T("ui.steer_prompt", { label = ui._steer_label("a1") }), "図で s を押すとメニュー")
end)

-- 8. 詳細画面の steer: の行で Enter（本文を開く・閉じる）と、履歴へのジャンプ
t.run("follow steer link", function()
  ui.open_detail("a1")
  local detail = require("agentmap.views.detail")
  local b = vim.api.nvim_get_current_buf()
  detail.links = detail.links or {}
  detail.links[b] = detail.links[b] or {}
  detail.links[b][1] = "steer:a1-zz"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- _show が作り直すときにリンクも作り直されるので、ここでは開いた印だけを見る
  ui.follow_link()
  t.eq(ui.steer_expanded["a1-zz"], true, "Enter で本文を開く")
  detail.links[vim.api.nvim_get_current_buf()] = detail.links[vim.api.nvim_get_current_buf()] or {}
  detail.links[vim.api.nvim_get_current_buf()][1] = "steer:a1-zz"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  ui.follow_link()
  t.eq(ui.steer_expanded["a1-zz"], nil, "もう一度で閉じる")
  ui.close_aux()
end)

-- 8b. 子に届いた指示は親にも知らせる（付録 E）
t.run("notice to parent", function()
  s.steers = {
    old = { id = "old", agent_id = "a1", kind = "steer", status = "DELIVERED", text = "before open" },
  }
  s.steer_order = { "old" }
  ui._seed_expired() -- 開いた時点で届いていたものは知らせない
  t.eq(ui.notify_parents(), 0, "開く前に届いた指示は知らせない")
  -- a1（親は ROOT）に届いた → ROOT の端末へ知らせ
  s.steers["n1"] = { id = "n1", agent_id = "a1", kind = "steer", status = "DELIVERED", text = "use docs/v3" }
  s.steer_order[#s.steer_order + 1] = "n1"
  local before = #read(out1)
  t.eq(ui.notify_parents(), 1, "親への知らせを 1 件作った")
  local c = last("request")
  t.eq({ c.agent_id, c.opts.kind, c.opts.notice_of, c.opts.via }, { "ROOT", "notice", "n1", "terminal" },
    "ROOT 宛ての notice は端末へ")
  vim.wait(3000, function() return #read(out1) > before end, 20)
  local line = read(out1)[#read(out1)] or ""
  t.matches(line, "^%[AgentMap%] ", "[AgentMap] で始まる")
  t.ok(line:find("use docs/v3", 1, true) ~= nil and line:find("[1]", 1, true) ~= nil, "本文と子の番号が入る: " .. line)
  t.eq(ui.notify_parents(), 0, "同じ指示では 2 回作らない")
  -- 孫 g1（親は a1、動いている）に届いた → a1 へ hooks で
  s.steers["n2"] = { id = "n2", agent_id = "g1", kind = "steer", status = "DELIVERED", text = "skip tests" }
  s.steer_order[#s.steer_order + 1] = "n2"
  t.eq(ui.notify_parents(), 1, "孫の指示は子の親へ")
  c = last("request")
  t.eq({ c.agent_id, c.opts.kind, c.opts.via }, { "a1", "notice", "hook" }, "親が子エージェントなら hooks")
  -- 親が終わっていれば作らない
  s.agents.a1.status = "DONE"
  s.steers["n3"] = { id = "n3", agent_id = "g1", kind = "steer", status = "DELIVERED", text = "late" }
  s.steer_order[#s.steer_order + 1] = "n3"
  t.eq(ui.notify_parents(), 0, "親が終わっていれば知らせない")
  s.agents.a1.status = "RUNNING"
  -- 知らせ・やり直し・ROOT 宛ての指示からは知らせを作らない
  s.steers["n4"] = { id = "n4", agent_id = "ROOT", kind = "notice", notice_of = "n9", status = "DELIVERED" }
  s.steers["n5"] = { id = "n5", agent_id = "ROOT", kind = "redo", status = "DELIVERED" }
  s.steers["n6"] = { id = "n6", agent_id = "ROOT", kind = "steer", status = "DELIVERED" }
  t.eq(ui.notify_parents(), 0, "知らせ・やり直し・ROOT 宛てからは作らない")
  -- 記録に notice_of がある指示は、もう知らせ済み
  s.steers["n9"] = { id = "n9", agent_id = "a1", kind = "steer", status = "DELIVERED" }
  t.eq(ui.notify_parents(), 0, "記録に知らせがあれば作らない")
  s.steers, s.steer_order = {}, {}
end)

-- 9. 届かなかった指示の知らせ（1 回だけ）
t.run("expired notice", function()
  s.steers["a1-old"] = { id = "a1-old", agent_id = "a1", status = "PENDING" }
  ui._seed_expired()
  notes = {}
  events.sweep_steers = function(r)
    r.state.steers["a1-old"].status = "EXPIRED"
    return true
  end
  t.eq(ui.sweep_steers(), true, "sweep_steers の結果を返す")
  t.ok(noted(T("ui.steer_expired_notice", { label = ui._steer_label("a1") })), "届かなかったと知らせた")
  notes = {}
  ui.sweep_steers()
  t.eq(#notes, 0, "知らせるのは 1 回だけ")
  events.sweep_steers = nil
  t.eq(ui.sweep_steers(), false, "sweep_steers が無くても落ちない")
end)

vim.fn.jobstop(tj1)
local _ = tb1
t.done()
