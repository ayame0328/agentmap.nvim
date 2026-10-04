-- The flow light (anim.lua, DESIGN-v0.2 §3): which lines are lit, which cells light up in each
-- frame, the extmarks it sets, and that it stops. The clock is replaced, frames are drawn by hand
-- (anim.step), so every check is a fixed frame.
local t = require("t")
local anim = require("agentmap.anim")
local renderer = require("agentmap.renderer")
local config = require("agentmap.config")

local CFG = anim.cfg({ period = 6, tail = 2, back_ms = 3000 })

-- 1. plan
t.run("plan", function()
  local a = anim.plan(nil, { a1 = "RUNNING", a2 = "DONE", ROOT = "RUNNING" }, 1000, CFG)
  t.eq(a.forward, { "ROOT", "a1" }, "RUNNING の箱は前向き（並びは id 順）")
  t.eq(a.back, {}, "図を開いた直後（前回なし）は戻りの光なし")
  local b = anim.plan({ a1 = "RUNNING", a2 = "RUNNING" }, { a1 = "DONE", a2 = "RUNNING" }, 5000, CFG)
  t.eq(b.forward, { "a2" }, "動いている a2 は前向き")
  t.eq(b.back, { a1 = 8000 }, "RUNNING → DONE で戻りの光（now + 3000）")
  for _, st in ipairs({ "REWORK", "FAILED" }) do
    local c = anim.plan({ x = "RUNNING" }, { x = st }, 0, CFG)
    t.eq(c.back, { x = 3000 }, "RUNNING → " .. st .. " でも戻る")
  end
  local d = anim.plan({ x = "PENDING" }, { x = "DONE" }, 0, CFG)
  t.eq(d.back, {}, "RUNNING を見ていなければ戻らない")
  -- 前回の戻りは期限まで引き継ぐ
  local e = anim.plan({ a1 = "DONE" }, { a1 = "DONE" }, 7999, CFG, { a1 = 8000 })
  t.eq(e.back, { a1 = 8000 }, "期限前は引き継ぐ")
  local f = anim.plan({ a1 = "DONE" }, { a1 = "DONE" }, 8000, CFG, { a1 = 8000 })
  t.eq(f.back, {}, "期限が来たら落ちる")
  local g = anim.plan({ a1 = "DONE" }, { a1 = "RUNNING" }, 7000, CFG, { a1 = 8000 })
  t.eq({ g.forward, g.back }, { { "a1" }, {} }, "また RUNNING になったら前向きだけ")
  local h = anim.plan({ a1 = "DONE" }, {}, 7000, CFG, { a1 = 8000 })
  t.eq(h.back, {}, "画面から消えた箱は戻りの光も消える")
  -- HUMAN CHECK の答え待ち（付録 D：紫で流す）
  local w = anim.plan(nil, { ["check:q1"] = "WAITING", ["check:q2"] = "ANSWERED" }, 0, CFG)
  t.eq(w.wait, { "check:q1" }, "WAITING の HUMAN CHECK は紫の光")
  t.eq(w.forward, {}, "答えた確認は光らない")
  t.ok(anim.is_empty(anim.plan(nil, { a = "DONE", b = "PENDING", c = "REVIEW" }, 0, CFG)), "動いているものが無ければ空")
end)

-- 2. frame
local function path(n, row)
  local p = {}
  for i = 0, n - 1 do p[#p + 1] = { row or 0, i * 3, i * 3 + 3 } end -- 1 セル = "─"（3 バイト）
  return p
end
local function lit(specs)
  local m = {}
  for _, s in ipairs(specs) do m[s[2] / 3] = s[4] end
  return m
end

t.run("frame", function()
  local paths = { a = path(12) }
  local f0 = lit(anim.frame(paths, { forward = { "a" }, wait = {}, back = {} }, 0, CFG))
  t.eq(f0, {
    [0] = "AgentMapFlow1", [6] = "AgentMapFlow1",
    [5] = "AgentMapFlow2", [11] = "AgentMapFlow2",
    [4] = "AgentMapFlow3", [10] = "AgentMapFlow3",
  }, "k=0: 頭が 0 と 6、尾が 5,4 と 11,10")
  local f1 = lit(anim.frame(paths, { forward = { "a" }, wait = {}, back = {} }, 1, CFG))
  t.eq(f1, {
    [1] = "AgentMapFlow1", [7] = "AgentMapFlow1",
    [0] = "AgentMapFlow2", [6] = "AgentMapFlow2",
    [5] = "AgentMapFlow3", [11] = "AgentMapFlow3",
  }, "k=1: 1 セル進む（親→子）")
  local b0 = lit(anim.frame(paths, { forward = {}, wait = {}, back = { a = 1 } }, 0, CFG))
  t.eq(b0, {
    [11] = "AgentMapFlowBack1", [5] = "AgentMapFlowBack1",
    [0] = "AgentMapFlowBack2", [6] = "AgentMapFlowBack2",
    [1] = "AgentMapFlowBack3", [7] = "AgentMapFlowBack3",
  }, "戻りは子の側（終点）から始まる")
  local b1 = lit(anim.frame(paths, { forward = {}, wait = {}, back = { a = 1 } }, 1, CFG))
  t.eq(b1[10], "AgentMapFlowBack1", "戻りは 1 コマで 1 セル親の方へ")
  local w0 = lit(anim.frame(paths, { forward = {}, wait = { "a" }, back = {} }, 0, CFG))
  t.eq({ w0[0], w0[5], w0[4] }, { "AgentMapFlowWait1", "AgentMapFlowWait2", "AgentMapFlowWait3" }, "答え待ちは紫の群")
  -- 前向きと戻りが同じセルなら、戻りが後ろに並ぶ（後勝ち）
  local both = anim.frame({ a = path(12), b = path(12) }, { forward = { "a" }, wait = {}, back = { b = 1 } }, 0, CFG)
  local last_fwd, first_back = 0, math.huge
  for i, s in ipairs(both) do
    if s[4]:find("Back") then first_back = math.min(first_back, i) else last_fwd = i end
  end
  t.ok(last_fwd < first_back, "forward → back の順")
  t.eq(#anim.frame({ a = path(3) }, { forward = { "zz" }, wait = {}, back = {} }, 0, CFG), 0, "線の無い箱は何も光らない")
  local nt = lit(anim.frame(paths, { forward = { "a" }, wait = {}, back = {} }, 0, anim.cfg({ tail = 0 })))
  t.eq(nt, { [0] = "AgentMapFlow1", [6] = "AgentMapFlow1" }, "tail = 0 なら頭だけ")
  -- max_paths：order の先頭から
  local r = anim._restrict({ forward = { "a", "b", "c" }, wait = {}, back = {} }, { a = {}, b = {}, c = {} }, { "c", "b", "a" }, 2)
  t.eq(r.forward, { "c", "b" }, "max_paths を超えたら order の先頭から")
end)

-- 3. cfg（config の false / true / 表）
t.run("cfg", function()
  t.eq(anim.cfg(false).enabled, false, "false は無効")
  t.eq(anim.cfg(true).frame_ms, 100, "true は既定")
  t.eq(anim.cfg({ back_ms = 500 }).back_ms, 500, "表は既定に重ねる")
  t.eq(anim.cfg({ tail = 9, period = 4 }).tail, 3, "尾は period-1 まで")
end)

-- 4. extmark とタイマー（バッファに実際に付ける）
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "ROOT ├──────────┐",
  "                │",
  "                └──▶ [1] child",
})
vim.api.nvim_win_set_buf(0, buf)
local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

-- 線のセル（バイト位置）：├ の後ろの横線 10 セル → 角 → 縦 → 角 → 横 2 → ▶
local function cells()
  local p = {}
  local l1 = before[1]
  local s = l1:find("├", 1, true) - 1
  for i = 0, 11 do p[#p + 1] = { 0, s + i * 3, s + i * 3 + 3 } end
  local c2 = before[2]:find("│", 1, true) - 1
  p[#p + 1] = { 1, c2, c2 + 3 }
  local c3 = before[3]:find("└", 1, true) - 1
  for i = 0, 3 do p[#p + 1] = { 2, c3 + i * 3, c3 + i * 3 + 3 } end
  return p
end
local layout = { mode = "box", paths = { a1 = cells() }, order = { "ROOT", "a1" } }

local now = 100000
anim.clock = function() return now end

local function marks()
  return vim.api.nvim_buf_get_extmarks(buf, renderer.anim_ns, 0, -1, { details = true })
end

t.run("set_anim_marks", function()
  renderer.set_anim_marks(buf, { { 0, 5, 8, "AgentMapFlow1" }, { 2, 0, 999, "AgentMapFlow2" }, { 9, 0, 3, "AgentMapFlow3" } })
  local m = marks()
  t.eq(#m, 2, "行の外は付けない（9 行目）")
  t.eq(m[1][4].priority, 4200, "priority 4200（基本の印より上）")
  t.eq(m[1][4].hl_group, "AgentMapFlow1", "色")
  t.eq(m[2][4].end_col, #before[3], "行末を超える桁は行末まで")
  renderer.set_anim_marks(buf, {})
  t.eq(#marks(), 0, "空を渡すと消える")
end)

t.run("update / step / stop", function()
  anim.reset()
  anim.update(buf, layout, { ROOT = "RUNNING", a1 = "RUNNING" })
  t.ok(anim._running(), "RUNNING の線があればタイマーが動く")
  local m0 = marks()
  t.ok(#m0 > 0, "すぐ 1 コマ目を描く")
  t.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before, "文字は書き換えない")
  local function heads()
    local out = {}
    for _, m in ipairs(marks()) do
      if m[4].hl_group == "AgentMapFlow1" then out[#out + 1] = { m[2], m[3] } end
    end
    return out
  end
  local h1 = heads()
  anim.step()
  local h2 = heads()
  t.ok(not vim.deep_equal(h1, h2), "次のコマで頭が動く")
  -- 子が終わった瞬間：戻りの光
  now = now + 500
  anim.update(buf, layout, { ROOT = "RUNNING", a1 = "DONE" })
  t.ok(anim._running(), "終わった直後は戻りの光で動き続ける")
  local backs = 0
  for _, m in ipairs(marks()) do if m[4].hl_group:find("Back") then backs = backs + 1 end end
  t.ok(backs > 0, "戻りの色（AgentMapFlowBack*）")
  t.eq(anim._state().back.a1, 100500 + 3000, "期限は終わった時刻 + 3000 ms")
  now = now + 2999
  t.ok(anim.step(), "期限前はまだ光る")
  now = now + 1
  t.ok(not anim.step(), "期限が来たら止まる")
  t.ok(not anim._running(), "タイマーが止まる")
  t.eq(#marks(), 0, "光が消える")
  -- 描き直し（同じ状態）でも、終わったものはもう戻らない
  anim.update(buf, layout, { ROOT = "RUNNING", a1 = "DONE" })
  t.ok(not anim._running(), "光る線が無ければタイマーは動かない")
end)

t.run("tree / hidden / disabled", function()
  anim.reset()
  anim.update(buf, { mode = "tree", paths = layout.paths }, { a1 = "RUNNING" })
  t.ok(not anim._running(), "一覧（tree）では光らない")
  -- 図が今のタブに無いときは描かない
  anim.update(buf, layout, { a1 = "RUNNING" })
  t.ok(anim._running(), "box では動く")
  vim.cmd("tabnew")
  t.ok(not anim.step(), "別のタブにいる間は止まる")
  t.ok(not anim._running(), "タイマーも止まる")
  vim.cmd("tabclose")
  anim.update(buf, layout, { a1 = "RUNNING" })
  t.ok(anim._running(), "戻って描き直せば再開")
  anim.stop()
  -- animation = false：タイマーも extmark も作らない
  config.get().animation = false
  anim.reset()
  anim.update(buf, layout, { a1 = "RUNNING" })
  t.ok(not anim._running(), "animation = false ならタイマーを作らない")
  t.eq(#marks(), 0, "extmark も作らない")
  config.get().animation = { enabled = false }
  anim.update(buf, layout, { a1 = "RUNNING" })
  t.ok(not anim._running(), "animation.enabled = false も同じ")
  config.get().animation = nil
end)

t.run("timer runs by itself", function()
  anim.reset()
  config.get().animation = { frame_ms = 20 }
  anim.update(buf, layout, { a1 = "RUNNING" })
  local k0 = anim._state().k
  vim.wait(300, function() return anim._state().k >= k0 + 3 end, 10)
  t.ok(anim._state().k >= k0 + 3, "タイマーがコマを進める")
  anim.stop()
  t.ok(not anim._running(), "stop で止まる")
  config.get().animation = nil
end)

t.run("highlights", function()
  vim.o.background = "dark"
  anim.setup_highlights()
  local d2 = vim.api.nvim_get_hl(0, { name = "AgentMapFlow2" })
  t.eq(d2.fg, tonumber("e3b341", 16), "暗い背景の黄")
  vim.o.background = "light"
  anim.setup_highlights()
  t.eq(vim.api.nvim_get_hl(0, { name = "AgentMapFlow2" }).fg, tonumber("b35c00", 16), "明るい背景では付け直す")
  t.eq(vim.api.nvim_get_hl(0, { name = "AgentMapFlowWait2" }).fg, tonumber("8250df", 16), "答え待ちは紫")
  -- 利用者の色は上書きしない
  vim.api.nvim_set_hl(0, "AgentMapFlowBack2", { fg = "#123456" })
  vim.o.background = "dark"
  anim.setup_highlights()
  t.eq(vim.api.nvim_get_hl(0, { name = "AgentMapFlowBack2" }).fg, tonumber("123456", 16), "利用者の色が勝つ")
  -- 色の少ない端末（headless は UI が無い）では頭を太字＋反転
  vim.o.termguicolors = false
  vim.api.nvim_set_hl(0, "AgentMapFlow1", {})
  anim.setup_highlights()
  local h = vim.api.nvim_get_hl(0, { name = "AgentMapFlow1" })
  t.ok(anim.low_color() and h.reverse == true and h.bold == true, "低色では bold + reverse")
end)

t.done()
