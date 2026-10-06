-- Steering from the map (DESIGN-v0.2-steer.md §2, §4, §6.1, §6.2; v0.1.2: DESIGN-v0.1.2-steer2 §2,
-- §4, §7.1, §7.5, §8.2): the `s` menu, the instruction window, the route for each kind of box
-- (running agent → hooks, delivered when it tries to finish; ROOT → terminal; finished agent → redo
-- request in the terminal), relay through the main agent (typed into ROOT's terminal for SendMessage),
-- the fallbacks without a terminal, the refusal when the registered hooks use another mode, cancel,
-- :AgentMapSteer [relay], and the notices ("not delivered", "relayed", "not relayed", "arrived at its end"). The events.* functions that write files are replaced with recorders;
-- the terminal is a real :terminal running a small stand-in script named `claude`.
local t = require("t")
local ui = require("agentmap.ui")
local events = require("agentmap.events")
local config = require("agentmap.config")
local hooks = require("agentmap.hooks")
local i18n = require("agentmap.i18n")
local T = i18n.t

-- hooks の登録の確認（settings.json を読む）の差し替え：この試験の CLAUDE_CONFIG_DIR には settings.json が無い
local hooks_status = "installed"
hooks.status = function() return hooks_status end

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
local run = { dir = dir, sid = s.run_id, slug = "-tmp-steer", state = s, off = { hooks = 0, events = 0 } }
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
  t.eq(#menus[#menus].items, 2, "未配達が無く端末も無ければ「書く」と「履歴」の 2 つ（親経由は出ない）")
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
  t.eq(ui.steer_cfg().no_terminal, "stop", "既定は stop（番の終わりに Stop の hook で届ける）")
  local r = ui.steer_send("ROOT", "please stop and summarize")
  t.eq(r, "fallback_hook", "端末が無いので hooks へ")
  local c = last("request")
  t.eq({ c.agent_id, c.text, c.opts.via }, { "ROOT", "please stop and summarize", "hook" }, "ROOT 宛てに hooks で")
  t.ok(noted(ui._st("ui.steer_queued_root_stop")), "番の終わりに届くと知らせた")
  -- v0.1.1 の名前 "hook" は "stop" の別名
  config.get().steer.no_terminal = "hook"
  t.eq(ui.steer_cfg().no_terminal, "stop", "no_terminal = hook は stop として読む")
  t.eq(ui.steer_send("ROOT", "alias"), "fallback_hook", "別名でも同じ")
  config.get().steer.no_terminal = "none"
  local n0 = #calls
  t.eq(ui.steer_send("ROOT", "x"), "none", "no_terminal = none")
  t.eq(#calls, n0, "何も記録しない")
  config.get().steer.no_terminal = "clipboard"
  t.eq(ui.steer_send("ROOT", "copy me"), "clipboard", "no_terminal = clipboard")
  t.eq(vim.fn.getreg('"'), "[AgentMap] copy me", "文をコピーした")
  t.eq(last("request").opts.via, "terminal", "記録は terminal 宛て（PENDING のまま）")
  config.get().steer.no_terminal = "stop"
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

-- 6b. hooks の登録が古い（v0.1.0 の形）：hooks で届ける経路は送らずに知らせる。端末へ送る経路は関係ない
t.run("hooks outdated", function()
  notes = {}
  hooks_status = "outdated"
  local n0 = #calls
  t.eq(ui.steer_send("a1", "will not arrive"), "outdated", "動いている子（hooks）→ 送らない")
  t.eq(#calls, n0, "記録もしない")
  t.ok(noted(T("ui.steer_hooks_outdated")), "「登録が古いので届きません」と知らせた")
  notes = {}
  local before = #read(out1)
  t.eq(ui.steer_send("ROOT", "terminal still works"), "sent", "ROOT を端末へ → 送る")
  vim.wait(3000, function() return #read(out1) > before end, 20)
  t.eq(read(out1)[#read(out1)], "[AgentMap] terminal still works", "端末に届いた")
  t.ok(not noted(T("ui.steer_hooks_outdated")), "端末へ送るときは警告しない")
  config.get().steer.root_via = "hook"
  n0 = #calls
  t.eq(ui.steer_send("ROOT", "x"), "outdated", "ROOT を hooks へ（root_via = hook）→ 送らない")
  t.eq(#calls, n0, "記録もしない")
  config.get().steer.root_via = "terminal"
  -- 登録が無い（missing）も同じ扱い
  hooks_status = "missing"
  t.eq(ui.steer_send("a1", "x"), "outdated", "登録が無くても同じ")
  hooks_status = "installed"
  t.eq(ui.steer_send("a1", "ok now"), "queued", "登録し直せば送れる")
  -- 組は今の形でも、届け方が v0.1.1 の deny のまま（Q22）：hooks の経路は断る、端末の経路は断らない
  local real_features = hooks.features
  hooks.features = function() return { steer = true, pause = true, mode = "deny" } end
  notes = {}
  n0 = #calls
  t.eq(ui.steer_hooks_ok(), false, "登録の mode が設定（stop）と違えば古い扱い")
  t.eq(ui.steer_send("a1", "x"), "outdated", "動いている子（終わり際）→ 送らない")
  t.eq(#calls, n0, "記録もしない")
  t.ok(noted(ui._st("ui.steer_hooks_outdated")), ":AgentMapInstallHooks を案内")
  t.eq(ui.steer_send("ROOT", "still to the terminal"), "sent", "ROOT の端末へは送る")
  config.get().steer.mode = "deny"
  t.eq(ui.steer_hooks_ok(), true, "設定も deny なら一致")
  config.get().steer.mode = nil
  hooks.features = function() return { steer = true, pause = true } end
  t.eq(ui.steer_hooks_ok(), true, "mode が読めない登録は組の一致だけで決める")
  hooks.features = real_features
end)

-- 6b'. 親経由（relay。DESIGN-v0.1.2-steer2 §4・§7.1）：ROOT の端末に「子へ SendMessage で伝えて」と打つ
t.run("relay menu", function()
  menus, picks = {}, {}
  ui.steer_menu("a1")
  t.eq(menus[#menus].items, { T("ui.steer_write"), ui._st("ui.steer_relay"), T("ui.steer_show") },
    "ROOT の直接の子＋端末あり → 2 番目が親経由")
  t.eq(ui.relay_available("a1"), true, "a1 は親経由できる")
  s.agents.g1.status = "RUNNING"
  t.eq(ui.relay_available("g1"), false, "孫には出さない（V41）")
  menus = {}
  ui.steer_menu("g1")
  t.eq(#menus[#menus].items, 2, "孫のメニューは「書く」と「履歴」だけ")
  s.agents.g1.status = "DONE"
  t.eq(ui.relay_available("a2"), false, "終わった箱には出さない（Q21）")
  t.eq(ui.relay_available("ROOT"), false, "ROOT には出さない")
  config.get().steer.relay = "always"
  menus = {}
  ui.steer_menu("a1")
  t.eq(menus[#menus].items[1], ui._st("ui.steer_relay"), "relay = always なら親経由が先")
  config.get().steer.relay = "never"
  menus = {}
  ui.steer_menu("a1")
  t.eq(#menus[#menus].items, 2, "relay = never なら出さない")
  config.get().steer.relay = nil
end)

-- 端末への送信（Enter を遅らせて 1 行ずつ）が全部終わるまで待つ
local term_mod = require("agentmap.term")
local function settle()
  vim.wait(5000, function() return term_mod.pending(tj1) == 0 end, 20)
  vim.wait(100)
end

local A1_EN = '[AgentMap] Tell sub-agent [1] "調査：既存設定の確認" (agent id a1) this, with SendMessage: '
local A1_JA = "[AgentMap] サブエージェント [1]「調査：既存設定の確認」（agent id a1）に SendMessage で次を伝えてください："

t.run("relay send", function()
  notes = {}
  settle()
  local before = #read(out1)
  t.eq(ui.steer_send("a1", "use docs/v3,\nnot v2", nil, { route = "relay" }), "relayed", "親経由で打った")
  vim.wait(3000, function() return #read(out1) > before end, 20)
  t.eq(read(out1)[#read(out1)], A1_EN .. "use docs/v3, not v2", "§4.2 の英語の文が 1 行で届いた")
  local c = last("request")
  t.eq({ c.agent_id, c.text, c.opts.via, c.opts.kind, c.opts.relay_line },
    { "a1", "use docs/v3,\nnot v2", "relay", "steer", A1_EN .. "use docs/v3, not v2" },
    "宛先は子・本文はそのまま・via relay・relay_line は打った全文")
  t.eq(last("sent").id, c.id, "打てたので mark_steer_sent")
  t.ok(noted(ui._st("ui.steer_relay_sent")), "端末を一瞥するよう知らせた")
  t.ok(vim.api.nvim_get_current_buf() == ui.buf, "カーソルは図のまま")
  -- 日本語の UI
  i18n.setup("ja")
  settle()
  before = #read(out1)
  t.eq(ui.steer_send("a1", "v3 を読むこと", nil, { route = "relay" }), "relayed", "日本語")
  vim.wait(3000, function() return #read(out1) > before end, 20)
  t.eq(read(out1)[#read(out1)], A1_JA .. "v3 を読むこと", "§4.2 の日本語の文")
  i18n.setup("en")
  -- 窓から（s → 2 番）
  menus, picks = {}, { 2 }
  ui.steer_menu("a1")
  local b = input_buf()
  t.ok(b ~= nil, "親経由の窓が開いた")
  t.eq(vim.b[b].agentmap_steer_kind, "relay", "窓の種類は relay")
  vim.api.nvim_buf_set_lines(b, 1, -1, false, { "from the window" })
  settle()
  before = #read(out1)
  vim.cmd("write")
  vim.wait(3000, function() return #read(out1) > before end, 20)
  t.eq(read(out1)[#read(out1)], A1_EN .. "from the window", "窓から送った")
  -- :AgentMapSteer 1 relay <本文>
  settle()
  before = #read(out1)
  vim.cmd("AgentMapSteer 1 relay by command")
  vim.wait(3000, function() return #read(out1) > before end, 20)
  t.eq(read(out1)[#read(out1)], A1_EN .. "by command", ":AgentMapSteer 1 relay <本文>")
  t.eq(last("request").opts.via, "relay", "via relay")
  -- 断る：孫・終わった箱
  notes = {}
  local n0 = #calls
  t.eq(ui.steer_send("a2", "x", nil, { route = "relay" }), "not_target", "終わった箱は親経由にしない")
  t.eq(#calls, n0, "記録もしない")
  t.ok(noted(ui._st("ui.steer_relay_not_target")), "知らせた")
  -- hooks の登録が古くても親経由は送れる（端末の経路）
  hooks_status = "outdated"
  t.eq(ui.steer_send("a1", "hooks do not matter", nil, { route = "relay" }), "relayed", "登録が古くても送れる")
  hooks_status = "installed"
end)

-- 6b''. 親が一時停止中（止まれを置いた REQUESTED／止まった PAUSED）：親経由は出さず、理由を知らせる。親は勝手に動かさない。
--       終わり際の経路はそのまま（0.1.2 最終確認の直し 2）
t.run("relay withheld while ROOT is paused", function()
  s.pauses = s.pauses or {}
  s.pause_order = s.pause_order or {}
  s.pauses["ROOT-live"] = { id = "ROOT-live", agent_id = "ROOT", kind = "pause", at = "next", status = "REQUESTED",
    requested_at = "2026-09-28T04:31:00.000Z", auto_resume_s = 600 }
  s.pause_order[#s.pause_order + 1] = "ROOT-live"
  s.agents.ROOT.pause = "ROOT-live"
  for _, status in ipairs({ "REQUESTED", "PAUSED" }) do
    s.pauses["ROOT-live"].status = status
    if status == "PAUSED" then s.pauses["ROOT-live"].hit_at, s.pauses["ROOT-live"].hit_via = "2026-09-28T04:31:05.000Z", "PreToolUse:Bash" end
    t.eq(ui.relay_available("a1"), false, status .. ": 親経由は出さない")
    t.eq(ui.relay_target_ok("a1"), false, status .. ": 宛先としても断る")
    t.eq(ui.relay_root_paused("a1"), true, status .. ": 理由は親の止まれ")
    t.eq(ui.relay_root_paused("g1"), false, status .. ": 孫はもともと出さないので理由にもならない")
    menus, notes = {}, {}
    ui.steer_menu("a1")
    t.eq(menus[#menus].items, { T("ui.steer_write"), T("ui.steer_show") }, status .. ": メニューは「書く」と「履歴」だけ")
    t.eq(menus[#menus].prompt, T("ui.steer_prompt", { label = ui._steer_label("a1") }) .. " " .. ui._st("ui.steer_prompt_root_paused"),
      status .. ": 題に短い理由（組み込みの select でも見える）")
    t.ok(noted(ui._st("ui.steer_relay_root_paused")), status .. ": 選んだ後（取り消しでも）に理由を知らせた")
    notes = {}
    local n0 = #calls
    t.eq(ui.steer_send("a1", "x", nil, { route = "relay" }), "root_paused", status .. ": 親経由の送信は断る")
    t.eq(#calls, n0, status .. ": 記録もしない")
    t.ok(noted(ui._st("ui.steer_relay_root_paused")), status .. ": 断る理由を知らせた")
    notes = {}
    t.eq(ui.steer_input("a1", nil, "relay"), nil, status .. ": 親経由の窓は開かない")
    t.ok(noted(ui._st("ui.steer_relay_root_paused")), status .. ": 窓でも同じ理由")
    t.ok(ui._live_pause("ROOT") ~= nil and ui._live_pause("ROOT").status == status, status .. ": 親の止まれはそのまま（勝手に解かない）")
    notes = {}
    t.eq(ui.steer_send("a1", "still at its end"), "queued", status .. ": 終わり際の経路は使える")
    t.eq(last("request").opts.via, "hook", status .. ": via hook")
  end
  s.pauses["ROOT-live"].status = "RESUMED"
  s.agents.ROOT.pause = nil
  t.eq(ui.relay_available("a1"), true, "親を再開すれば親経由が戻る")
  t.eq(ui.relay_root_paused("a1"), false, "理由も消える")
  menus, notes = {}, {}
  ui.steer_menu("a1")
  t.eq(#menus[#menus].items, 3, "メニューに親経由が戻る")
  t.eq(menus[#menus].prompt, T("ui.steer_prompt", { label = ui._steer_label("a1") }), "題に理由は付かない")
  t.ok(not noted(ui._st("ui.steer_relay_root_paused")), "理由は出ない")
end)

-- 6c. 終わった実行（SessionEnd 済み）：ROOT・やり直しは端末へ送らない（同じフォルダの別の会話に入る）
t.run("run ended", function()
  notes = {}
  menus = {}
  s.ended_at = "2026-09-28T05:00:00.000Z"
  local n0 = #calls
  settle()
  local before = #read(out1)
  ui.steer_menu("ROOT")
  t.eq(#menus, 0, "終わった実行の ROOT にはメニューを出さない")
  t.ok(noted(T("ui.steer_run_ended")), "「この実行は終わっています」と知らせた")
  t.eq(ui.steer_send("ROOT", "x"), "ended", ":AgentMapSteer ROOT も送らない")
  menus = {}
  ui.steer_menu("a2")
  t.eq(#menus, 0, "終わった箱のやり直し依頼もメニューを出さない")
  t.eq(ui.steer_send("a2", "redo me"), "ended", "やり直し依頼も送らない")
  t.eq(#calls, n0, "記録もしない")
  vim.wait(300)
  t.eq(#read(out1), before, "端末には何も打たれていない")
  s.ended_at = nil
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
  settle()
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
  -- state の notice_id だけで分かる場合（別の Neovim が作った知らせ。この Neovim の覚えには無い）
  s.steers["n10"] = { id = "n10", agent_id = "a1", kind = "steer", status = "DELIVERED", text = "x", notice_id = "made-elsewhere" }
  s.steer_order[#s.steer_order + 1] = "n10"
  t.eq(ui.notify_parents(), 0, "state の notice_id が付いていれば作らない")
  -- events が「duplicate」と断ったら数えず、端末にも打たない
  local orig_req = events.request_steer
  events.request_steer = function() return nil, "duplicate" end
  s.steers["n11"] = { id = "n11", agent_id = "a1", kind = "steer", status = "DELIVERED", text = "y" }
  s.steer_order[#s.steer_order + 1] = "n11"
  local before2 = #read(out1)
  t.eq(ui.notify_parents(), 0, "events が duplicate と断れば作らない")
  vim.wait(300)
  t.eq(#read(out1), before2, "端末にも打たない")
  events.request_steer = orig_req
  s.steers, s.steer_order = {}, {}
end)

-- 8c. 親経由の指示：親への知らせは作らない（V44）。「親が渡した」「渡さずに番を終えた」「終わり際に届いた」を 1 回ずつ知らせる
t.run("relay notices", function()
  s.steers, s.steer_order = {}, {}
  ui._seed_expired()
  s.steers["r1"] = { id = "r1", agent_id = "a1", kind = "steer", via = "relay", status = "DELIVERED", text = "x",
    delivered_via = "terminal" }
  local n0 = #calls
  t.eq(ui.notify_parents(), 0, "親経由の指示から親への知らせは作らない")
  t.eq(#calls, n0, "記録もしない")
  notes = {}
  t.eq(ui.notify_relays(), 0, "打っただけではまだ知らせない")
  s.steers.r1.relayed_at = "2026-09-28T04:31:05.000Z"
  s.steers.r1.delivered_via = "SendMessage"
  t.eq(ui.notify_relays(), 1, "親が渡したら 1 回")
  t.ok(noted(ui._st("ui.steer_relayed", { label = ui._steer_label("a1") })), "「親が渡しました」")
  t.eq(ui.notify_relays(), 0, "2 回目は知らせない")
  -- 渡さずに番を終えた
  s.steers["r2"] = { id = "r2", agent_id = "a1", kind = "steer", via = "relay", status = "EXPIRED", end_reason = "not_relayed" }
  notes = {}
  ui.notify_expired()
  t.ok(noted(ui._st("ui.steer_not_relayed", { label = ui._steer_label("a1") })), "「渡さずに番を終えました」")
  t.ok(not noted(T("ui.steer_expired_notice", { label = ui._steer_label("a1") })), "普通の「届かなかった」は出さない")
  -- 終わり際に届いた（hook、mode block）
  s.steers["h1"] = { id = "h1", agent_id = "a1", kind = "steer", via = "hook", status = "DELIVERED", mode = "block",
    delivered_via = "SubagentStop" }
  s.steers["h2"] = { id = "h2", agent_id = "a1", kind = "steer", via = "hook", status = "DELIVERED", mode = "deny",
    delivered_via = "PreToolUse:Write" }
  notes = {}
  t.eq(ui.notify_relays(), 1, "終わり際の配達だけ知らせる（次の道具での配達は知らせない）")
  t.ok(noted(ui._st("ui.steer_delivered_stop", { label = ui._steer_label("a1") })), "「終わり際で届き、続きを始めました」")
  -- 届けたが止められなかった（held = false。state が親の記録から判定）：配達の知らせの後、分かった時点で 1 回、警告で
  s.steers["h3"] = { id = "h3", agent_id = "a1", kind = "steer", via = "hook", status = "DELIVERED", mode = "block",
    delivered_via = "SubagentStop" }
  notes = {}
  t.eq(ui.notify_relays(), 1, "届いた知らせ")
  t.ok(not noted(ui._st("ui.steer_not_held", { label = ui._steer_label("a1") })), "まだ「止められなかった」とは言わない")
  s.steers.h3.held = false
  notes = {}
  t.eq(ui.notify_relays(), 1, "止められなかったと分かったら 1 回")
  t.ok(noted(ui._st("ui.steer_not_held", { label = ui._steer_label("a1") })), "「止められませんでした」")
  t.eq(ui.notify_relays(), 0, "2 回目は知らせない")
  s.steers["h4"] = { id = "h4", agent_id = "a1", kind = "steer", via = "hook", status = "DELIVERED", mode = "block",
    delivered_via = "SubagentStop", held = true }
  notes = {}
  ui.notify_relays()
  t.ok(not noted(ui._st("ui.steer_not_held", { label = ui._steer_label("a1") })), "held = true なら言わない")
  s.steers, s.steer_order = {}, {}
  ui._seed_expired()
end)

-- 8d. 残り時間の目安（進み具合の推定があるときだけ）
t.run("eta", function()
  local progress = require("agentmap.progress")
  local orig = progress.compute
  progress.compute = function() return { pct = 40, estimated = true, basis = "time", expected_ms = 300000, cur_elapsed_ms = 60000 } end
  t.eq(ui._eta_suffix("a1"), ui._st("ui.steer_queued_eta", { left = "4 min" }), "時間の推定から残り 4 min")
  progress.compute = function() return { pct = 40, estimated = true, basis = "tasks", n = 3, k = 1, f = 0.5, expected_ms = 20000 } end
  t.eq(ui._eta_suffix("a1"), ui._st("ui.steer_queued_eta", { left = "30 s" }), "手順の推定から残り 30 s")
  progress.compute = function() return { pct = 66.6, estimated = false, basis = "tasks", n = 3, k = 2, f = 0 } end
  t.eq(ui._eta_suffix("a1"), "", "推定が無ければ付けない")
  progress.compute = function() return { pct = 95, estimated = true, basis = "time", expected_ms = 1000, cur_elapsed_ms = 5000, over = true } end
  t.eq(ui._eta_suffix("a1"), "", "典型時間を超えていれば付けない")
  progress.compute = orig
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
