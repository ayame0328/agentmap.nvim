-- The once-a-second redraw (ui.tick, DESIGN-v0.2 §2.7): when it runs, that a tick moves the
-- elapsed time by exactly one second with a fixed clock, that it stops when nothing moves or the
-- map is not visible, and the progress log it writes (§2.5).
local t = require("t")
local ui = require("agentmap.ui")
local util = require("agentmap.util")
local config = require("agentmap.config")
vim.notify = function() end

local function fixture() return dofile(vim.g.agentmap_test_dir .. "/fixtures/state_small.lua") end

-- 1. should_tick（純粋）
t.run("should_tick", function()
  local s = fixture()
  for _, a in pairs(s.agents) do a.status = "DONE" end
  t.eq(ui.should_tick(s), false, "全部 DONE なら動かない")
  s.agents.a2.status = "RUNNING"
  t.eq(ui.should_tick(s), true, "RUNNING の子があれば動く")
  s.agents.a2.status = "PENDING"
  t.eq(ui.should_tick(s), true, "PENDING も動く")
  s.agents.a2.status = "REVIEW"
  t.eq(ui.should_tick(s), true, "REVIEW も動く")
  s.agents.a2.status = "DONE"
  s.agents.ROOT.status = "RUNNING"
  t.eq(ui.should_tick(s), true, "ROOT が RUNNING なら動く")
  s.agents.ROOT.status = "PENDING"
  t.eq(ui.should_tick(s), false, "ROOT の PENDING は数えない")
  s.checks = { ["check:q"] = { id = "check:q", status = "WAITING" } }
  t.eq(ui.should_tick(s), true, "答え待ちの HUMAN CHECK だけでも動く（経過時間が進む）")
  s.checks["check:q"].status = "ANSWERED"
  t.eq(ui.should_tick(s), false, "答えたら止まる")
  t.eq(ui.should_tick(nil), false, "状態が無ければ動かない")
end)

-- 2. 時計を固定して tick
local NOW = 1790600000
local now = NOW
ui.clock = function() return now end

local s = fixture()
s.agents.a1.status = "RUNNING"
s.agents.a1.finished_at, s.agents.a1.elapsed_ms = nil, nil
s.agents.a1.started_at = os.date("!%Y-%m-%dT%H:%M:%S.000Z", NOW - 65)
s.agents.a1.attempts[1].finished_at = nil
local dir = vim.env.AGENTMAP_DIR .. "/projects/-tmp-ticker/runs/" .. s.run_id
vim.fn.mkdir(dir, "p")
local run = { dir = dir, sid = s.run_id, slug = "-tmp-ticker", state = s, off = {} }

-- 経過時間（a1 の箱の 4 行目）
local function a1_line()
  for _, l in ipairs(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)) do
    local i = l:find("[RUNNING]", 1, true)
    while i do
      local seg = l:sub(i, i + 40)
      local el = seg:match("%[RUNNING%][^│]-(%d+:%d%d)%s")
      if el and (el == "1:05" or el == "1:06" or el == "1:07") then return el end
      i = l:find("[RUNNING]", i + 1, true)
    end
  end
end

t.run("tick", function()
  ui.open_map(run)
  t.ok(ui.buf ~= nil, "図が開く")
  t.eq(a1_line(), "1:05", "a1 は 65 秒経過")
  t.ok(ui._ticking(), "RUNNING があるので毎秒の描き直しが動く")
  now = NOW + 1
  ui.tick()
  t.eq(a1_line(), "1:06", "1 回の tick で経過時間が 1 秒進む")
  now = NOW + 2
  ui.tick()
  t.eq(a1_line(), "1:07", "もう 1 回で 1:07")
  t.eq(ui.view.now, NOW + 2, "graph に渡す view.now は ui.clock の値")
  t.ok(type(ui.view.progress) == "table", "view.progress（設定）を渡す")
end)

t.run("timer runs by itself", function()
  config.get().progress.tick_ms = 100
  ui.stop_ticker()
  ui.refresh({ aux = false })
  t.ok(ui._ticking(), "refresh で動き出す")
  local calls = 0
  local orig = ui.refresh
  ui.refresh = function(o) calls = calls + 1 return orig(o) end
  vim.wait(500, function() return calls >= 2 end, 10)
  ui.refresh = orig
  t.ok(calls >= 2, "タイマーが tick を呼ぶ（" .. calls .. " 回）")
  config.get().progress.tick_ms = 1000
end)

t.run("stops", function()
  -- 別のタブにいる間は止まる
  vim.cmd("tabnew")
  ui.tick()
  t.eq(ui._ticking(), false, "図が今のタブに無ければ止まる")
  vim.cmd("tabclose")
  ui.refresh({ aux = false })
  t.eq(ui._ticking(), true, "戻って描き直せば再開")
  -- 全部終わったら止まる
  s.agents.a1.status = "DONE"
  s.agents.a1.finished_at = os.date("!%Y-%m-%dT%H:%M:%S.000Z", NOW + 2)
  s.agents.a1.elapsed_ms = 67000
  s.agents.ROOT.status = "DONE"
  now = NOW + 3
  ui.tick()
  t.eq(ui._ticking(), false, "動いているものが無くなったら止まる")
  -- 閉じたら止まる
  s.agents.ROOT.status = "RUNNING"
  ui.refresh({ aux = false })
  t.eq(ui._ticking(), true, "また動き出す")
  ui.close()
  t.eq(ui._ticking(), false, "閉じたら止まる")
end)

-- 3. 推定の記録（progress_log.jsonl）：動いている箱は 30 秒に 1 回、終わった瞬間に final
t.run("progress log", function()
  local stats_ok, stats = pcall(require, "agentmap.stats")
  local prog_ok = pcall(require, "agentmap.progress")
  if not (stats_ok and stats.log and prog_ok) then
    t.skip("stats / progress が無い")
    return
  end
  local logs = {}
  local orig = stats.log
  stats.log = function(root, e) logs[#logs + 1] = e end
  local s2 = fixture()
  s2.run_id = "log-run"
  s2.agents.a2.status = "RUNNING"
  s2.agents.a2.finished_at, s2.agents.a2.elapsed_ms = nil, nil
  s2.agents.a2.started_at = os.date("!%Y-%m-%dT%H:%M:%S.000Z", NOW - 100)
  ui.run = { sid = "log-run", state = s2 }
  ui._log_progress(s2, NOW)
  local n1 = #logs
  t.ok(n1 >= 1, "RUNNING の箱を記録した")
  local e
  for _, x in ipairs(logs) do if x.agent == "a2" then e = x end end
  t.ok(e and e.run == "log-run" and e.pct ~= nil and e.basis ~= nil, "run・agent・pct・basis がある")
  ui._log_progress(s2, NOW + 10)
  t.eq(#logs, n1, "30 秒経つまで書かない")
  ui._log_progress(s2, NOW + 30)
  t.ok(#logs > n1, "30 秒で次の行")
  s2.agents.a2.status = "DONE"
  s2.agents.a2.elapsed_ms = 131000
  local n2 = #logs
  ui._log_progress(s2, NOW + 31)
  local fin = logs[#logs]
  t.ok(#logs == n2 + 1 or (#logs > n2 and fin.final), "終わった瞬間に 1 行")
  t.eq({ fin.agent, fin.final, fin.elapsed_ms }, { "a2", true, 131000 }, "final 行に elapsed_ms")
  local n3 = #logs
  ui._log_progress(s2, NOW + 40)
  local again = 0
  for i = n3 + 1, #logs do if logs[i].agent == "a2" then again = again + 1 end end
  t.eq(again, 0, "final は 1 回だけ")
  config.get().progress.log = false
  s2.agents.a2.status = "RUNNING"
  local n4 = #logs
  ui._log_progress(s2, NOW + 100)
  local a2_new = 0
  for i = n4 + 1, #logs do if logs[i].agent == "a2" then a2_new = a2_new + 1 end end
  t.eq(a2_new, 0, "progress.log = false なら書かない")
  config.get().progress.log = true
  stats.log = orig
  ui.run = nil
end)

local _ = util
t.done()
