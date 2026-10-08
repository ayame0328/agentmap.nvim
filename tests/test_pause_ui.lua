-- Pausing from the map (DESIGN-v0.1.2-pause §5.4, §6.1, §6.5 and appendix D, the user's answers):
-- `x` without a menu (place a pause / resume it), the Pass / Fix menu only for a box waiting at the
-- gate, `X` (gate on / off), a steering instruction to a held agent (instruction first, then the
-- pause is removed; a sub-agent paused before a tool call continues and gets it when it tries to
-- finish, DESIGN-v0.1.2-steer2 §5), steer_kind for a held ROOT (paused before a tool call: the pause
-- is lifted, then the terminal; Q23), the refusals, the notices of the state changes,
-- the commands :AgentMapPause / :AgentMapResume / :AgentMapGate, the light's status map, and the
-- VimLeavePre rule (pause.release_on_exit, default false). The events.* functions that write files
-- are replaced with recorders; the pause state is written into the state directly (contract §13.2).
local t = require("t")
local ui = require("agentmap.ui")
local events = require("agentmap.events")
local config = require("agentmap.config")
local hooks = require("agentmap.hooks")
local keymaps = require("agentmap.keymaps")
local i18n = require("agentmap.i18n")
local T = i18n.t
local P = ui._pt -- 一時停止の文（言語ファイルに鍵が無いあいだは英語の既定の文）

local hooks_status = "installed"
hooks.status = function() return hooks_status end

local notes = {}
vim.notify = function(msg) notes[#notes + 1] = tostring(msg) end
local function noted(s)
  for _, m in ipairs(notes) do if m:find(s, 1, true) then return true end end
  return false
end

-- events の差し替え（呼ばれた順に記録する）
local calls = {}
local seq = 0
local gate = false
local function rec(c) calls[#calls + 1] = c end
events.request_steer = function(run, agent_id, text, opts)
  seq = seq + 1
  local id = agent_id .. "-s" .. seq
  rec({ fn = "request_steer", agent_id = agent_id, text = text, opts = opts, id = id })
  return id
end
events.request_pause = function(run, agent_id, opts)
  seq = seq + 1
  local id = agent_id .. "-p" .. seq
  rec({ fn = "request_pause", agent_id = agent_id, opts = opts, id = id })
  return id
end
events.resume_pause = function(run, agent_id, opts)
  rec({ fn = "resume_pause", agent_id = agent_id, opts = opts })
  return true
end
events.set_gate = function(run, on)
  rec({ fn = "set_gate", on = on })
  gate = on
  return true
end
events.gate_on = function() return gate end
events.sweep_pauses = function() rec({ fn = "sweep_pauses" }) return false end
events.sync_gate = function() rec({ fn = "sync_gate" }) return 0 end
events.release_all = function(run, reason)
  rec({ fn = "release_all", reason = reason })
  return 1
end
local function fns(from)
  local out = {}
  for i = (from or 0) + 1, #calls do out[#out + 1] = calls[i].fn end
  return out
end
local function last(fn)
  for i = #calls, 1, -1 do if calls[i].fn == fn then return calls[i] end end
end

local picks, menus = {}, {}
vim.ui.select = function(items, opts, cb)
  local labels = {}
  for i, it in ipairs(items) do labels[i] = opts.format_item and opts.format_item(it) or it end
  menus[#menus + 1] = { prompt = opts.prompt, items = labels }
  local n = table.remove(picks, 1)
  cb(n and items[n] or nil, n)
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/work", "p")
local s = dofile(vim.g.agentmap_test_dir .. "/fixtures/state_small.lua")
s.cwd = tmp .. "/work"
s.steers, s.steer_order = {}, {}
s.agents.a2.finished_at = "2026-09-28T04:28:00.000Z" -- a2 は REWORK（終わった箱）
local dir = vim.env.AGENTMAP_DIR .. "/projects/-tmp-pause/runs/" .. s.run_id
vim.fn.mkdir(dir, "p")
local run = { dir = dir, sid = s.run_id, slug = "-tmp-pause", state = s, off = { hooks = 0, events = 0 } }

-- 止まれを state に直接書く（契約 §5.2 の形）
local function clear_pauses()
  s.pauses, s.pause_order = {}, {}
  for _, a in pairs(s.agents) do a.pause, a.pauses = nil, nil end
end
local function set_pause(agent_id, status, kind, at, extra)
  local id = agent_id .. "-x" .. (#s.pause_order + 1)
  local p = vim.tbl_extend("force", {
    id = id, agent_id = agent_id, kind = kind or "pause", at = at or "next", status = status,
    requested_at = "2026-09-28T04:30:00.000Z", auto_resume_s = 600,
  }, extra or {})
  s.pauses[id] = p
  s.pause_order[#s.pause_order + 1] = id
  local a = s.agents[agent_id]
  a.pauses = a.pauses or {}
  a.pauses[#a.pauses + 1] = id
  if status == "REQUESTED" or status == "PAUSED" then a.pause = id end
  return p
end
clear_pauses()
ui.open_map(run)
local L1 = ui._steer_label("a1")

-- 1. x：止まれ無し → その場で置く（メニューは出さない）
t.run("x places a pause", function()
  menus, notes = {}, {}
  local n0 = #calls
  local pid = ui.pause_toggle("a1")
  t.eq(#menus, 0, "メニューを出さない（付録 D）")
  t.eq(fns(n0), { "request_pause" }, "request_pause だけ")
  local c = last("request_pause")
  t.eq({ c.agent_id, c.opts.at, c.opts.kind }, { "a1", "next", "pause" }, "次の道具の直前か終わる直前（at=next）")
  t.eq(pid, c.id, "pause_id を返す")
  t.ok(noted(P("ui.pause_requested", { label = L1, min = "10:00" })), "置いたことを知らせる（10:00 後に自動再開）")
  t.ok(ui.pause_toggle("gate:a1") ~= nil, "門の id は元の Agent")
end)

-- 2. x：止まれがある（置いた／止まっている）→ 再開
t.run("x again resumes", function()
  clear_pauses()
  set_pause("a1", "REQUESTED")
  notes = {}
  local n0 = #calls
  ui.pause_toggle("a1")
  t.eq(fns(n0), { "resume_pause" }, "置いただけの止まれは取り下げる")
  t.eq(last("resume_pause").opts.reason, "user", "理由 user")
  t.ok(noted(P("ui.pause_cancelled", { label = L1 })), "取り下げを知らせる")
  clear_pauses()
  set_pause("a1", "PAUSED", "pause", "next", { hit_at = "2026-09-28T04:30:05.000Z", hit_via = "PreToolUse:Read" })
  notes = {}
  n0 = #calls
  ui.pause_toggle("a1")
  t.eq(fns(n0), { "resume_pause" }, "止まっている箱は再開")
  t.ok(noted(P("ui.pause_resumed", { label = L1 })), "再開を知らせる")
  t.eq(#menus, 0, "メニューは出さない")
end)

-- 3. 関門で止まっている箱（[GATE]）だけメニュー：通す／直す／待たせたまま報告を見る
t.run("gate menu", function()
  clear_pauses()
  s.agents.a1.status = "DONE" -- 終わりの記録は止まる前に書かれる（§3.2）
  set_pause("a1", "PAUSED", "gate", "stop", { hit_at = "2026-09-28T04:30:05.000Z", hit_via = "SubagentStop" })
  menus, picks = {}, { 1 }
  local n0 = #calls
  ui.pause_toggle("a1")
  t.eq(menus[1] and menus[1].items, { P("ui.pause_pass"), P("ui.pause_fix"), P("ui.pause_keep_gate") }, "3 つの項目")
  t.eq(fns(n0), { "resume_pause" }, "通す＝再開")
  -- 直す：指示の窓が開き、送ると指示 → 止まれ解除の順
  menus, picks = {}, { 2 }
  ui.pause_toggle("a1")
  local b = vim.api.nvim_get_current_buf()
  t.eq(vim.b[b].agentmap_steer_target, "a1", "直す＝指示の窓")
  t.eq(vim.b[b].agentmap_steer_kind, "hook", "終わりで止まっている子は hooks で届く（やり直し依頼ではない）")
  vim.api.nvim_buf_set_lines(b, 1, -1, false, { "テストも足すこと" })
  n0 = #calls
  vim.cmd("write")
  vim.wait(200, function() return not vim.api.nvim_buf_is_valid(b) end, 10)
  t.eq(fns(n0), { "request_steer", "resume_pause" }, "指示のファイル → 止まれを消す、の順")
  t.eq(last("resume_pause").opts.steer_id, last("request_steer").id, "steer_id を渡す")
  t.ok(noted(P("ui.pause_resumed_with", { label = L1 })), "関門の「直す」はその場で届く（指示つきで再開）")
  -- 待たせたまま報告を見る
  menus, picks = {}, { 3 }
  n0 = #calls
  ui.pause_toggle("a1")
  t.eq(fns(n0), {}, "何も変えない")
  t.eq(vim.b[vim.api.nvim_get_current_buf()].agentmap_kind, "detail", "詳細画面を開く")
  ui.close_aux()
  -- 関門の止まれがまだ止まっていない（REQUESTED）→ 今すぐ止める止まれに置き換える
  s.agents.a1.status = "RUNNING"
  clear_pauses()
  set_pause("a1", "REQUESTED", "gate", "stop")
  menus = {}
  n0 = #calls
  ui.pause_toggle("a1")
  t.eq(fns(n0), { "resume_pause", "request_pause" }, "関門の止まれを外して、次の道具の直前で止める")
  t.eq({ last("request_pause").opts.at, last("request_pause").opts.kind }, { "next", "pause" }, "at=next の pause")
  t.eq(#menus, 0, "メニューは出さない")
end)

-- 4. 止まっている宛先への指示（§5.4）
t.run("steer to a held agent", function()
  clear_pauses()
  set_pause("a1", "PAUSED", "pause", "next", { hit_at = "2026-09-28T04:30:05.000Z", hit_via = "PreToolUse:Read" })
  notes = {}
  local n0 = #calls
  t.eq(ui.steer_send("a1", "v3 を読むこと"), "queued", "hooks で置く")
  t.eq(fns(n0), { "request_steer", "resume_pause" }, "指示 → 止まれ解除の順")
  local r = last("resume_pause")
  t.eq({ r.agent_id, r.opts.reason, r.opts.steer_id }, { "a1", "user", last("request_steer").id }, "理由 user・steer_id")
  t.ok(noted(ui._st("ui.steer_resumed_stop", { label = L1 })), "再開した、指示は終わる直前に届くと知らせる")
  t.ok(not noted(P("ui.pause_resumed_with", { label = L1 })), "「指示つきで再開（その場で届く）」とは言わない")
  -- まだ止まっていない（REQUESTED）：同じ順。知らせは普通の「置いた」
  clear_pauses()
  set_pause("a1", "REQUESTED")
  notes = {}
  n0 = #calls
  ui.steer_send("a1", "x")
  t.eq(fns(n0), { "request_steer", "resume_pause" }, "REQUESTED でも指示 → 解除")
  t.ok(noted(T("ui.steer_queued", { label = L1 })), "普通の「置いた」の知らせ")
  -- 止まれが無ければ今までどおり
  clear_pauses()
  n0 = #calls
  ui.steer_send("a1", "y")
  t.eq(fns(n0), { "request_steer" }, "止まれが無ければ解除しない")
end)

-- 5. ROOT：止まれがある間は hook 経路（端末ではなく）
t.run("ROOT", function()
  clear_pauses()
  t.eq(ui.steer_kind("ROOT"), "root", "ふだんは端末")
  local n0 = #calls
  ui.pause_toggle("ROOT")
  t.eq(last("request_pause").agent_id, "ROOT", "ROOT も止められる（Q17）")
  t.eq(fns(n0), { "request_pause" }, "置いた")
  -- 次の道具の直前で止まっている ROOT（Q23）：止まれを解いてから端末へ。端末が無ければ指示を置いてから解く（番の終わりに届く）
  set_pause("ROOT", "PAUSED", "pause", "next", { hit_at = "2026-09-28T04:30:05.000Z", hit_via = "PreToolUse:Bash" })
  t.eq(ui.steer_kind("ROOT"), "root", "PreToolUse で止まっている ROOT は端末")
  n0 = #calls
  t.eq(ui.steer_send("ROOT", "止めた所から別の方針で"), "fallback_hook", "端末が無いので番の終わりに")
  t.eq(fns(n0), { "request_steer", "resume_pause" }, "指示 → 解除")
  t.eq(last("request_steer").opts.via, "hook", "via hook")
  t.eq(last("resume_pause").opts.steer_id, last("request_steer").id, "steer_id を渡す")
  -- 端末がある（term の差し替え）：解除 → 打つ、の順
  local term = require("agentmap.term")
  local orig_find, orig_send = term.find, term.send
  term.find = function() return { buf = 1, job = 1, score = 3 }, { { buf = 1, job = 1, score = 3 } }, false end
  term.send = function(_, line)
    rec({ fn = "term_send", line = line })
    return true
  end
  events.mark_steer_sent = function() rec({ fn = "mark_steer_sent" }) end
  notes = {}
  n0 = #calls
  t.eq(ui.steer_send("ROOT", "別の方針で"), "sent", "端末へ送った")
  t.eq(fns(n0), { "request_steer", "resume_pause", "term_send", "mark_steer_sent" }, "記録 → 止まれを解く → 打つ")
  t.eq(last("request_steer").opts.via, "terminal", "via terminal")
  t.eq(last("resume_pause").opts.reason, "user", "理由 user")
  t.ok(noted(P("ui.pause_resumed", { label = "ROOT" })), "再開を知らせる")
  term.find, term.send = orig_find, orig_send
  -- 終わり際（Stop）で止まっている ROOT：待っている hook がその場で渡す
  clear_pauses()
  set_pause("ROOT", "PAUSED", "pause", "stop", { hit_at = "2026-09-28T04:30:05.000Z", hit_via = "Stop" })
  t.eq(ui.steer_kind("ROOT"), "hook", "Stop で止まっている ROOT は hook")
  notes = {}
  n0 = #calls
  t.eq(ui.steer_send("ROOT", "ここで直して"), "queued", "hook で置く")
  t.eq(fns(n0), { "request_steer", "resume_pause" }, "指示 → 解除")
  t.ok(noted(P("ui.pause_resumed_with", { label = "ROOT" })), "その場で届く")
  clear_pauses()
  set_pause("ROOT", "REQUESTED")
  t.eq(ui.steer_kind("ROOT"), "hook", "置いただけなら hook（止まる場所で受け取る）")
  clear_pauses()
end)

-- 5b. 止まっている子に親経由（relay）：打った後で止まれを解く（伝言は次の道具の切れ目で届く）。関門の子には出さない
t.run("relay to a paused child", function()
  clear_pauses()
  local term = require("agentmap.term")
  local orig_find, orig_send = term.find, term.send
  term.find = function() return { buf = 1, job = 1, score = 3 }, { { buf = 1, job = 1, score = 3 } }, false end
  term.send = function(_, line)
    rec({ fn = "term_send", line = line })
    return true
  end
  events.mark_steer_sent = function() rec({ fn = "mark_steer_sent" }) end
  set_pause("a1", "PAUSED", "pause", "next", { hit_at = "2026-09-28T04:30:05.000Z", hit_via = "PreToolUse:Read" })
  t.eq(ui.relay_available("a1"), true, "PreToolUse で止まっている子には親経由を出す")
  local n0 = #calls
  t.eq(ui.steer_send("a1", "今すぐ v3 へ", nil, { route = "relay" }), "relayed", "親経由で打った")
  t.eq(fns(n0), { "request_steer", "term_send", "mark_steer_sent", "resume_pause" }, "記録 → 打つ → 止まれを解く")
  t.eq(last("request_steer").opts.via, "relay", "via relay")
  t.eq(last("resume_pause").opts.steer_id, nil, "伝言は hook が渡さないので steer_id は付けない")
  clear_pauses()
  -- 止まれを置いただけ（REQUESTED）：残すと次の道具の直前で止まり伝言が再開まで届かないので取り下げる
  set_pause("a1", "REQUESTED", "pause", "next")
  n0 = #calls
  t.eq(ui.steer_send("a1", "置いただけ", nil, { route = "relay" }), "relayed", "REQUESTED でも親経由で打つ")
  t.eq(fns(n0), { "request_steer", "term_send", "mark_steer_sent", "resume_pause" }, "打った後で止まれを取り下げる")
  clear_pauses()
  -- 関門を置いただけ（REQUESTED gate）は残す（終わる直前で見るため）
  set_pause("a1", "REQUESTED", "gate", "stop")
  n0 = #calls
  t.eq(ui.steer_send("a1", "関門は残す", nil, { route = "relay" }), "relayed", "関門の REQUESTED")
  t.eq(fns(n0), { "request_steer", "term_send", "mark_steer_sent" }, "関門は取り下げない")
  clear_pauses()
  s.agents.a1.status = "DONE"
  set_pause("a1", "PAUSED", "gate", "stop", { hit_at = "2026-09-28T04:30:05.000Z", hit_via = "SubagentStop" })
  t.eq(ui.relay_available("a1"), false, "関門で止まっている子には出さない（s がその場で届く）")
  s.agents.a1.status = "RUNNING"
  clear_pauses()
  term.find, term.send = orig_find, orig_send
end)

-- 5b. 報告を SubagentHandback で返す子（DESIGN-v0.1.2-handback §3.4・§3.5・§5.1・§5.5、付録 D の Q24・Q27）
--     PAUSED（普通の道具の前）に s → 止まれを解いてから親経由。報告の直前（PreToolUse:SubagentHandback）で
--     止まっている子（関門・x）の Fix → relay：通してから親経由（子は報告してから同じ id で再開）、deny：ファイル → 解く
t.run("hand-back sub-agent", function()
  clear_pauses()
  local term = require("agentmap.term")
  local orig_find, orig_send = term.find, term.send
  term.find = function() return { buf = 1, job = 1, score = 3 }, { { buf = 1, job = 1, score = 3 } }, false end
  term.send = function(_, line)
    rec({ fn = "term_send", line = line })
    return true
  end
  events.mark_steer_sent = function() rec({ fn = "mark_steer_sent" }) end
  -- 本物の resume_pause と同じく、記録を書いた瞬間に止まれは RESUMED になる
  local orig_resume = events.resume_pause
  events.resume_pause = function(r, agent_id, opts)
    rec({ fn = "resume_pause", agent_id = agent_id, opts = opts })
    local q = ui._live_pause(agent_id)
    if q then
      q.status = "RESUMED"
      s.agents[agent_id].pause = nil
    end
    return true
  end
  s.agents.a1.handback = true
  -- PAUSED（普通の道具の前）
  set_pause("a1", "PAUSED", "pause", "next", { hit_at = "2026-09-28T04:30:05.000Z", hit_via = "PreToolUse:Read" })
  t.eq(ui.steer_kind("a1"), "relay", "止まっている handback の子も親経由")
  notes = {}
  local n0 = #calls
  t.eq(ui.steer_send("a1", "v3 へ"), "relayed", "親経由で打った")
  t.eq(fns(n0), { "resume_pause", "request_steer", "term_send", "mark_steer_sent" }, "止まれを解いてから親経由")
  t.eq(last("request_steer").opts.via, "relay", "via relay")
  t.ok(noted(ui._st("ui.steer_resumed_relay", { label = L1 })), "§5.5 の知らせ（再開して親経由）")
  clear_pauses()
  -- 関門で報告の直前に止まっている（箱はまだ RUNNING。報告は PreToolUse の記録で読める）
  local g = set_pause("a1", "PAUSED", "gate", "stop", { hit_at = "2026-09-28T04:30:50.000Z", hit_via = "PreToolUse:SubagentHandback" })
  ui._seed_pauses()
  g.status = "REQUESTED"
  ui._seed_pauses()
  g.status = "PAUSED"
  notes = {}
  t.eq(ui.notify_pauses(), 1, "止まったことを 1 回知らせる")
  t.ok(noted(ui._st("ui.pause_hit_hb", { label = L1 })), "報告の直前で止まった（x 通す / s 直す）")
  t.eq(ui.relay_available("a1"), true, "報告の直前の関門は親経由できる（まだ終わっていない）")
  t.eq(ui.steer_kind("a1"), "relay", "Fix は親経由")
  menus, picks = {}, {}
  ui.gate_menu("a1")
  t.eq(menus[#menus].items[2], ui._st("ui.pause_fix_relay_hb"), "関門のメニューの Fix は「通してから親経由」")
  menus = {}
  ui.steer_menu("a1")
  t.eq(menus[#menus].items[1], ui._st("ui.pause_fix_relay_hb"), "s のメニューの 1 番も同じ")
  notes = {}
  n0 = #calls
  t.eq(ui.steer_send("a1", "テストも"), "relayed", "Fix → 親経由")
  t.eq(fns(n0), { "resume_pause", "request_steer", "term_send", "mark_steer_sent" }, "通してから親経由（H9）")
  t.eq(calls[n0 + 1].opts.steer_id, nil, "hook には渡さないので steer_id は付けない")
  t.ok(noted(ui._st("ui.pause_fixed_relay_hb", { label = L1 })), "通した・親経由で渡す・再開する、と知らせた")
  clear_pauses()
  -- deny の設定：今までどおりファイル → 解く（待っている hook がその場で deny で渡す）
  config.get().steer = { handback = "deny" }
  set_pause("a1", "PAUSED", "gate", "stop", { hit_at = "2026-09-28T04:30:50.000Z", hit_via = "PreToolUse:SubagentHandback" })
  t.eq(ui.steer_kind("a1"), "hook", "deny なら hook")
  menus = {}
  ui.gate_menu("a1")
  t.eq(menus[#menus].items[2], P("ui.pause_fix"), "Fix は普通の文")
  n0 = #calls
  t.eq(ui.steer_send("a1", "その場で"), "queued", "置いた")
  t.eq(fns(n0), { "request_steer", "resume_pause" }, "ファイルを置いてから止まれを消す")
  t.eq(calls[n0 + 2].opts.steer_id, calls[n0 + 1].id, "止まれは指示つきで解く")
  config.get().steer = nil
  clear_pauses()
  -- x で報告の直前に止まった（kind pause）も終わり際として扱う
  set_pause("a1", "PAUSED", "pause", "next", { hit_at = "2026-09-28T04:30:50.000Z", hit_via = "PreToolUse:SubagentHandback" })
  menus = {}
  ui.steer_menu("a1")
  t.eq(menus[#menus].items[1], ui._st("ui.pause_fix_relay_hb"), "x の止まれでも「通してから親経由」")
  clear_pauses()
  -- 端末が無い：置いて正直に知らせる（解いてから）
  term.find = function() return nil, {}, false end
  set_pause("a1", "PAUSED", "pause", "next", { hit_at = "2026-09-28T04:30:05.000Z", hit_via = "PreToolUse:Read" })
  t.eq(ui.steer_kind("a1"), "hook", "端末が無ければ置く")
  notes = {}
  n0 = #calls
  t.eq(ui.steer_send("a1", "置く"), "queued", "置いた")
  t.eq(fns(n0), { "request_steer", "resume_pause" }, "置いてから解く")
  t.ok(noted(ui._st("ui.steer_hb_pending", { label = L1 })), "届かない見込みを知らせた")
  clear_pauses()
  s.agents.a1.handback = nil
  events.resume_pause = orig_resume
  term.find, term.send = orig_find, orig_send
end)

-- 6. 断る場合
t.run("refusals", function()
  clear_pauses()
  for _, id in ipairs({ "check:x", "wf:abc", "UNKNOWN_PARENT", "START", "stage:1", "nope" }) do
    notes = {}
    local n0 = #calls
    ui.pause_toggle(id)
    t.eq(#calls, n0, "止められない箱: " .. id)
    t.ok(noted(P("ui.pause_not_target")), "知らせる: " .. id)
  end
  -- 終わった箱（止まれ無し）
  notes = {}
  local n0 = #calls
  ui.pause_toggle("a2")
  t.eq(#calls, n0, "終わった箱は止めない")
  t.ok(noted(P("ui.pause_not_target")), "終わった箱")
  -- hooks の登録が古い：置かない。外すことはできる
  hooks_status = "outdated"
  notes = {}
  n0 = #calls
  ui.pause_toggle("a1")
  t.eq(#calls, n0, "登録が古ければ置かない")
  t.ok(noted(P("ui.pause_hooks_outdated")), ":AgentMapInstallHooks を案内")
  t.eq(ui.toggle_gate(true), nil, "関門も入れない")
  set_pause("a1", "PAUSED")
  n0 = #calls
  ui.pause_toggle("a1")
  t.eq(fns(n0), { "resume_pause" }, "再開は登録に関係なくできる")
  clear_pauses()
  -- 一時停止の条件（--pause・timeout）だけ合わない登録：修正指示は送れる、一時停止だけ断る
  local real_status = hooks.status
  hooks.status = function(_path, _scfg, pcfg) return pcfg == false and "installed" or "outdated" end
  t.eq(ui.steer_hooks_ok(), true, "一時停止の条件だけ合わない登録でも修正指示は届く")
  t.eq(ui.pause_hooks_ok(), false, "その登録では一時停止は断る")
  hooks.status = real_status
  hooks_status = "installed"
  -- pause.enabled = false
  config.get().pause = { enabled = false }
  notes = {}
  n0 = #calls
  ui.pause_toggle("a1")
  t.eq(#calls, n0, "無効なら置かない")
  t.ok(noted(P("ui.pause_disabled")), "無効と知らせる")
  t.eq(ui.toggle_gate(), nil, "関門も")
  config.get().pause = nil
  -- 終わった実行
  s.ended_at = "2026-09-28T05:00:00.000Z"
  notes = {}
  n0 = #calls
  ui.pause_toggle("a1")
  t.eq(#calls, n0, "終わった実行では置かない")
  t.ok(noted(P("ui.pause_run_ended")), "終わっていると知らせる")
  s.ended_at = nil
  -- events.request_pause が断った
  local orig = events.request_pause
  events.request_pause = function() return nil, "exists" end
  notes = {}
  ui.pause_toggle("a1")
  t.ok(#notes == 1, "断られたら 1 回知らせる")
  events.request_pause = orig
end)

-- 7. X：関門の入／切
t.run("gate toggle", function()
  gate = false
  notes = {}
  local n0 = #calls
  t.eq(ui.toggle_gate(), true, "切 → 入")
  t.eq(fns(n0), { "set_gate" }, "set_gate")
  t.eq(last("set_gate").on, true, "on")
  t.ok(noted(P("ui.gate_on")), "入れたと知らせる")
  t.eq(ui.toggle_gate(), false, "入 → 切")
  t.ok(noted(P("ui.gate_off")), "切ったと知らせる")
  t.eq(ui.toggle_gate(false), false, "明示の切")
end)

-- 8. 状態の変わり目の知らせ（§6.5。1 回だけ）
t.run("notices", function()
  clear_pauses()
  ui._seed_pauses()
  local p = set_pause("a1", "REQUESTED")
  notes = {}
  t.eq(ui.notify_pauses(), 0, "置いただけでは知らせない（置いたときに知らせている）")
  p.status, p.hit_at, p.hit_via, p.deadline = "PAUSED", "2026-09-28T04:30:05.000Z", "PreToolUse:Read", "2026-09-28T04:40:05Z"
  t.eq(ui.notify_pauses(), 1, "止まった")
  local clock = os.date("%H:%M:%S", math.floor(require("agentmap.util").parse_iso("2026-09-28T04:40:05Z")))
  t.ok(noted(P("ui.pause_hit", { label = L1, via = "PreToolUse:Read", time = clock })), "どこで止まり、いつ自動再開するか")
  t.eq(ui.notify_pauses(), 0, "同じ状態は 2 回知らせない")
  p.status, p.release_reason, p.waited_ms = "RESUMED", "auto", 600000
  s.agents.a1.pause = nil
  ui.notify_pauses()
  t.ok(noted(P("ui.pause_auto", { label = L1, min = "10 min" })), "自動で再開した")
  local g = set_pause("a1", "PAUSED", "gate", "stop", { hit_at = "2026-09-28T04:41:00.000Z", hit_via = "SubagentStop", deadline = 1790570000 })
  notes = {}
  ui.notify_pauses()
  t.ok(noted(P("ui.pause_hit_gate", { label = L1, time = os.date("%H:%M:%S", 1790570000) })), "関門で止まった（epoch 秒の期限）")
  g.status, g.release_reason = "RESUMED", "aborted"
  notes = {}
  ui.notify_pauses()
  t.ok(noted(P("ui.pause_aborted", { label = L1 })), "hook が止められた")
  local e = set_pause("a1", "REQUESTED")
  ui.notify_pauses()
  e.status, e.end_reason = "EXPIRED", "agent_finished"
  notes = {}
  ui.notify_pauses()
  t.ok(noted(P("ui.pause_expired", { label = L1 })), "止まる前に終わった")
  local u = set_pause("a1", "PAUSED")
  ui.notify_pauses()
  u.status, u.release_reason = "RESUMED", "user"
  notes = {}
  t.eq(ui.notify_pauses(), 0, "自分で再開したものは知らせない（操作のときに知らせた）")
  -- pause.notify = false
  config.get().pause = { notify = false }
  local q = set_pause("a1", "REQUESTED")
  ui.notify_pauses()
  q.status = "PAUSED"
  notes = {}
  t.eq(ui.notify_pauses(), 0, "notify = false なら黙る")
  config.get().pause = nil
  -- 開いた時点でもう止まっていたものは知らせない
  clear_pauses()
  set_pause("a1", "PAUSED")
  ui._seed_pauses()
  t.eq(ui.notify_pauses(), 0, "開く前の状態は知らせない")
  clear_pauses()
end)

-- 9. 光と毎秒の描き直し
t.run("status map / tick", function()
  clear_pauses()
  s.agents.a1.status = "RUNNING"
  set_pause("a1", "PAUSED")
  t.eq(ui.status_map(s).a1, "PAUSED", "止まっている箱は PAUSED（光らない）")
  t.eq(s.agents.a1.status, "RUNNING", "a.status は変えない")
  clear_pauses()
  set_pause("a1", "PAUSED", "gate", "stop")
  t.eq(ui.status_map(s).a1, "GATE", "関門は GATE")
  clear_pauses()
  set_pause("a1", "REQUESTED")
  t.eq(ui.status_map(s).a1, "RUNNING", "置いただけなら RUNNING のまま")
  local quiet = { agents = { ROOT = { status = "RUNNING" } }, flows = { { status = "DONE", ended_at = "x" } },
    pauses = { p = { agent_id = "ROOT", status = "REQUESTED" } } }
  t.ok(ui.should_tick(quiet), "止まれがある間は毎秒見る")
  quiet.pauses.p.status = "RESUMED"
  t.ok(not ui.should_tick(quiet), "終われば見ない")
  local n0 = #calls
  ui.sweep_pauses()
  t.eq(fns(n0), { "sweep_pauses", "sync_gate" }, "掃除と関門の止まれ置き")
  clear_pauses()
end)

-- 10. キーと ? の一覧
t.run("keys", function()
  local function has_map(buf, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == lhs then return true end
    end
    return false
  end
  t.ok(has_map(ui.buf, "x") and has_map(ui.buf, "X"), "図に x と X")
  ui.open_detail("a1")
  t.ok(has_map(vim.api.nvim_get_current_buf(), "x"), "詳細画面にも x")
  ui.close_aux()
  local help = table.concat(keymaps.help_lines(), "\n")
  t.ok(help:find("  x ", 1, true) and help:find("  X ", 1, true), "? の一覧に x と X")
  t.ok(help:find("t / d / w / a / s / x", 1, true), "補助画面の行に x")
  -- 図で x（カーソルを a1 へ）
  vim.api.nvim_set_current_win(ui.win)
  for _ = 1, 10 do
    if ui.current_id() == "a1" then break end
    ui.move(1)
  end
  clear_pauses()
  local n0 = #calls
  vim.api.nvim_feedkeys("x", "x", false)
  t.eq(fns(n0), { "request_pause" }, "図で x を押すと止まれを置く")
  gate = false
  n0 = #calls
  vim.api.nvim_feedkeys("X", "x", false)
  t.eq(fns(n0), { "set_gate" }, "図で X を押すと関門")
end)

-- 11. コマンド
t.run("commands", function()
  clear_pauses()
  local n0 = #calls
  vim.cmd("AgentMapPause 1 stop")
  t.eq({ last("request_pause").agent_id, last("request_pause").opts.at }, { "a1", "stop" }, ":AgentMapPause 1 stop")
  t.eq(fns(n0), { "request_pause" }, "置くだけ")
  set_pause("a1", "REQUESTED", "pause", "stop")
  n0 = #calls
  vim.cmd("AgentMapPause 1 stop")
  t.eq(fns(n0), {}, "同じ止まれを重ねて打っても変えない（今の様子を言うだけ）")
  vim.cmd("AgentMapPause 1")
  t.eq(fns(n0), { "resume_pause", "request_pause" }, "止まる場所を変えると置き直す")
  t.eq(last("request_pause").opts.at, "next", "既定は next")
  n0 = #calls
  vim.cmd("AgentMapResume 1")
  t.eq(fns(n0), { "resume_pause" }, ":AgentMapResume 1")
  notes = {}
  n0 = #calls
  vim.cmd("AgentMapPause 1 later")
  t.eq(fns(n0), {}, "知らない場所は何もしない")
  t.ok(#notes == 1, "使い方を知らせる")
  gate = false
  vim.cmd("AgentMapGate on")
  t.eq(last("set_gate").on, true, ":AgentMapGate on")
  vim.cmd("AgentMapGate")
  t.eq(last("set_gate").on, false, "引数無しは反転")
  vim.cmd("AgentMapGate off")
  t.eq(last("set_gate").on, false, ":AgentMapGate off")
  clear_pauses()
end)

-- 12. Neovim を閉じるとき（Q14：既定は何もしない）
t.run("VimLeavePre", function()
  local af = require("agentmap")
  local n0 = #calls
  t.eq(af._on_exit(), 0, "既定（release_on_exit = false）は何もしない")
  t.eq(fns(n0), {}, "release_all を呼ばない")
  config.get().pause = { release_on_exit = true }
  t.eq(af._on_exit(), 1, "true の人だけ")
  t.eq(last("release_all").reason, "nvim_exit", "理由 nvim_exit")
  config.get().pause = { enabled = false, release_on_exit = true }
  n0 = #calls
  af._on_exit()
  t.eq(fns(n0), {}, "一時停止が無効なら何もしない")
  config.get().pause = nil
  local au = vim.api.nvim_get_autocmds({ group = "agentmap", event = "VimLeavePre" })
  t.ok(#au >= 1, "setup() が VimLeavePre を登録している")
end)

t.done()
