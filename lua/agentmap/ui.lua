-- agentmap/ui.lua ... screens: the map tab, the side (aux) window and the back navigation,
--   the once-a-second redraw while something runs (progress % and elapsed time move), the flow
--   light (anim.lua), steering (writing an instruction to a box with `s`) and pausing (`x` pauses or
--   resumes a box, `X` turns the gate of the run on and off; DESIGN-v0.1.2-pause).
--   図 → 詳細 → transcript/diff → BS → 詳細 → BS → 図、を ui.nav（戻り先の積み重ね）で実現する。
local graph = require("agentmap.graph")
local renderer = require("agentmap.renderer")
local anim = require("agentmap.anim")
local keymaps = require("agentmap.keymaps")
local state_mod = require("agentmap.state")
local i18n = require("agentmap.i18n")
local t = i18n.t

local M = {
  run = nil, -- events.load の戻り値 { dir, sid, slug, state, … }
  flow_id = nil, -- 見せている指示（prompt_id）。nil ならセッション全体
  flow_state = nil, -- その指示だけを取り出した見せる用の状態（描き直すたびに作り直す）
  view = { root = "ROOT", collapsed = {} },
  buf = nil, -- 図のバッファ
  tab = nil,
  win = nil,
  aux_win = nil, -- 右側の補助ウィンドウ（詳細・transcript・diff で使い回す）
  aux_bufs = {},
  nav = {}, -- { {kind, id}, … } 補助ウィンドウの戻り先
  cache = nil,
  layout = nil,
  clock = os.time, -- 「今」（秒）。試験で差し替える
  term_choice = {}, -- { [sid] = buf } 同点の端末から選んだもの（同じ run では次から聞かない）
  steer_expanded = {}, -- { [steer_id] = true } 詳細画面で本文を全部開いている指示
}

local ticker = nil -- 毎秒の描き直しのタイマー
local log_marks = {} -- { ["<sid>:<id>"] = { last = 秒, running = bool } } 推定の記録（30 秒に 1 回）
local expired_seen = {} -- { [sid] = { [steer_id] = true } } 「届かなかった」と知らせ済み
local notice_done = {} -- { [sid] = { [steer_id] = true } } 親への知らせを作った（または作らないと決めた）指示
local pause_seen = {} -- { [sid] = { [pause_id] = status } } 一時停止の状態の変わり目を知らせ済み
local relay_seen = {} -- { [sid] = { [steer_id] = true } } 「親が渡した」「終わり際に届いた」を知らせ済み

local VIEWS = {
  detail = "agentmap.views.detail",
  transcript = "agentmap.views.transcript",
  diff = "agentmap.views.diff",
  check = "agentmap.views.check", -- HUMAN CHECK（AskUserQuestion）の詳細
}

local function is_check(id) return type(id) == "string" and id:sub(1, 6) == "check:" end

local function notify(msg, level)
  vim.notify("AgentMap: " .. msg, level or vim.log.levels.INFO)
end

-- 一時停止の文（DESIGN-v0.1.2-pause 付録 A）。鍵が言語ファイルに無いあいだは英語の既定の文を使う
-- （鍵は W2 が書く。無い鍵を t() に渡すと鍵の名前がそのまま画面に出るため）
local PAUSE_TEXT = {
  ["ui.pause_prompt"] = "Pause %{label}",
  ["ui.pause_pass"] = "Pass (let it finish)",
  ["ui.pause_fix"] = "Fix: write an instruction (it continues)",
  ["ui.pause_keep_gate"] = "Keep waiting; show the report",
  ["ui.pause_requested"] = "Pause requested for %{label}: stops at its next tool call (auto-resume after %{min})",
  ["ui.pause_requested_stop"] = "Pause requested for %{label}: stops when it finishes (auto-resume after %{min})",
  ["ui.pause_resumed"] = "%{label} resumed",
  ["ui.pause_resumed_with"] = "%{label} resumed with the instruction",
  ["ui.pause_cancelled"] = "Pause request for %{label} withdrawn",
  ["ui.pause_hit"] = "%{label} is paused at %{via} (auto-resume at %{time}): x resume, s instruction",
  ["ui.pause_hit_gate"] = "%{label} waits before finishing (gate): x pass, s fix (passes by itself at %{time})",
  ["ui.pause_auto"] = "%{label} resumed by itself after %{min}",
  ["ui.pause_aborted"] = "The pause of %{label} ended: Claude Code stopped the hook (exit or timeout)",
  ["ui.pause_expired"] = "%{label} finished before it could pause",
  ["ui.pause_not_target"] = "This box cannot be paused (choose a running agent box)",
  ["ui.pause_run_ended"] = "This run has ended; nothing to pause",
  ["ui.pause_disabled"] = "Pausing is off (pause.enabled = false)",
  ["ui.pause_hooks_outdated"] = "The registered hooks have no pause support: run :AgentMapInstallHooks first",
  ["ui.pause_none"] = "%{label} is not paused",
  ["ui.pause_failed"] = "Could not change the pause of %{label}: %{err}",
  ["ui.gate_on"] = "Gate on for this run: every sub-agent waits at its end (x pass / s fix)",
  ["ui.gate_off"] = "Gate off for this run",
}
local function pt(key, vars)
  if i18n.has(key) or i18n.has(key, "en") then return t(key, vars) end
  local s = PAUSE_TEXT[key] or key
  return (s:gsub("%%{([%w_]+)}", function(k)
    local v = vars and vars[k]
    if v == nil then return nil end
    return tostring(v)
  end))
end
M._pt = pt

-- 他の担当のモジュールは、無くても落ちないように読み込む
local function try_require(name)
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then return m end
  return nil
end

local function valid_buf(b) return b and vim.api.nvim_buf_is_valid(b) end
local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end

local function state() return M.flow_state or (M.run and M.run.state) or nil end

--- The state shown on screen (only the selected prompt's flow when one is selected).
--- 画面に出している状態（指示ごとの流れならその流れだけ）
function M.display_state() return state() end

-- 見せる用の状態を作り直す（元の状態は events.poll で少しずつ増えていくので、毎回ここで取り出す）
local function rebuild()
  M.flow_state = nil
  if M.flow_id and M.run and M.run.state then
    M.flow_state = state_mod.flow_view(M.run.state, M.flow_id)
    if not M.flow_state then M.flow_id = nil end
  end
end

local function agent_of(id)
  local s = state()
  return s and s.agents and s.agents[id] or nil
end

local function check_of(id)
  local s = state()
  return s and s.checks and s.checks[id] or nil
end

--- Map an id on the map (agent, gate:, check:) to the agent an action applies to.
--- 図の id を「その操作の対象の Agent」に直す
---   門（gate:<id>）→ 元の Agent、HUMAN CHECK（check:…）→ 箱が付いている Agent（owner。無ければ聞いた側）。
---   t / d / w / a は Agent にしか意味が無いので、この結果を使う
function M.resolve_agent(id)
  if type(id) ~= "string" then return nil end
  if id:sub(1, 5) == "gate:" then return id:sub(6) end
  if is_check(id) then
    local c = check_of(id)
    if not c then return nil end
    return c.owner_id or c.asker_id or "ROOT"
  end
  return id
end

--- The asker of a HUMAN CHECK id (usually ROOT); for other ids the same as resolve_agent().
--- HUMAN CHECK の id → 質問した側（asker。たいてい ROOT）。check でなければ resolve_agent と同じ
---   確認の画面の t はこちらを使う：質問の前後のやり取りは聞いた側の transcript にしか無い（設計書 §6.2）
function M.check_asker(id)
  if not is_check(id) then return M.resolve_agent(id) end
  local c = check_of(id)
  if not c then return nil end
  return c.asker_id or "ROOT"
end

-- 図を表示しているウィンドウ（今のタブを優先）
local function map_win()
  if not valid_buf(M.buf) then return nil end
  if valid_win(M.win) and vim.api.nvim_win_get_buf(M.win) == M.buf then return M.win end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == M.buf then
      M.win = w
      return w
    end
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == M.buf then
      M.win = w
      return w
    end
  end
  return nil
end

-- 図が今のタブページに見えているか（見えていないときは毎秒の描き直しも光も止める）
local function map_visible_here()
  if not valid_buf(M.buf) then return false end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == M.buf then return true end
  end
  return false
end

-- ------------------------------------------------------------
-- 進み具合と毎秒の描き直し（DESIGN-v0.2 §2.7）
-- ------------------------------------------------------------
local PROGRESS_DEFAULTS = { enabled = true, tick_ms = 1000, log = true }

--- Effective progress settings (config.get().progress; false = { enabled = false }).
function M.progress_cfg()
  local ok, config = pcall(require, "agentmap.config")
  local raw = nil
  if ok then raw = config.get().progress end
  if raw == false then return vim.tbl_extend("force", PROGRESS_DEFAULTS, { enabled = false }) end
  if type(raw) ~= "table" then return vim.deepcopy(PROGRESS_DEFAULTS) end
  return vim.tbl_extend("force", PROGRESS_DEFAULTS, raw)
end

--- History of past agents for the estimate (stats.load; nil when the module is missing).
---   The run on screen is skipped: its state.json changes every second.
function M._stats()
  local stats = try_require("agentmap.stats")
  if not stats or not stats.load then return nil end
  local okc, config = pcall(require, "agentmap.config")
  if not okc then return nil end
  local ok, S = pcall(stats.load, config.root(), { skip_dir = M.run and M.run.dir or nil })
  return ok and S or nil
end

--- Status shown for agent `id` in state `s`: "PAUSED" / "GATE" while a pause holds it (the hook
--- waits), else its own status. Uses state.display_status; the same rule is kept here as a fallback.
function M.display_status(s, id)
  if type(s) ~= "table" then return nil end
  if state_mod.display_status then
    local ok, st = pcall(state_mod.display_status, s, id)
    if ok and st then return st end
  end
  for _, p in pairs(type(s.pauses) == "table" and s.pauses or {}) do
    if type(p) == "table" and p.agent_id == id and p.status == "PAUSED" then
      return p.kind == "gate" and "GATE" or "PAUSED"
    end
  end
  local a = s.agents and s.agents[id]
  return a and a.status or nil
end

--- { [id] = status } of the agents and HUMAN CHECK boxes in state `s` (what the light follows).
--- Agents held by a pause are "PAUSED" / "GATE" (not lit).
function M.status_map(s)
  local out = {}
  if type(s) ~= "table" then return out end
  for id, a in pairs(s.agents or {}) do
    if type(a) == "table" and a.status then out[id] = M.display_status(s, id) or a.status end
  end
  for id, c in pairs(type(s.checks) == "table" and s.checks or {}) do
    if type(c) == "table" and c.status then out[c.id or id] = c.status end
  end
  return out
end

local MOVING = { RUNNING = true, PENDING = true, REVIEW = true }

--- True when something on screen changes by itself every second: an agent that is RUNNING,
--- PENDING or REVIEW (ROOT only while a turn (flow) runs), a HUMAN CHECK that waits for an answer,
--- or a steering instruction that waits for delivery.
---@param s table|nil state (usually display_state())
function M.should_tick(s)
  if type(s) ~= "table" then return false end
  -- ROOT はセッションが開いている間ずっと RUNNING なので、指示の番（流れ）が動いているときだけ数える
  -- （DESIGN-v0.2 §2.7。数えないと、待っているだけのセッションや終わった流れを見ている間も毎秒描き直す）
  local function root_turn_running()
    if type(s.flow) == "table" then return s.flow.ended_at == nil end
    if type(s.flows) == "table" and #s.flows > 0 then
      for _, f in ipairs(s.flows) do
        if f.status == "RUNNING" or (f.status == nil and not f.ended_at) then return true end
      end
      return false
    end
    return true -- 流れの記録が無い（古い記録）：今までどおり
  end
  for id, a in pairs(s.agents or {}) do
    if type(a) == "table" then
      if id == "ROOT" then
        if a.status == "RUNNING" and root_turn_running() then return true end
      elseif MOVING[a.status] then
        return true
      end
    end
  end
  for _, c in pairs(type(s.checks) == "table" and s.checks or {}) do
    if type(c) == "table" and c.status == "WAITING" then return true end
  end
  -- 未配達の修正指示：宛先が終わってから数秒後に期限切れにするのは tick の sweep なので、それまで回す
  for _, st in pairs(type(s.steers) == "table" and s.steers or {}) do
    if type(st) == "table" and st.status == "PENDING" then return true end
  end
  -- 止まれ（置いた・止まっている）：止まった・自動で再開したの知らせと、掃除は tick が見る
  for _, p in pairs(type(s.pauses) == "table" and s.pauses or {}) do
    if type(p) == "table" and (p.status == "REQUESTED" or p.status == "PAUSED") then return true end
  end
  return false
end

local function iso(secs)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(secs))
end

-- 推定の答え合わせの記録（progress_log.jsonl。DESIGN-v0.2 §2.5）
--   動いている箱ごとに 30 秒に 1 回と、終わった瞬間に 1 回（final）。見ていた間の分だけ
local function log_progress(s, now)
  if type(s) ~= "table" or not M.run then return end
  local pcfg = M.progress_cfg()
  if pcfg.log == false then return end
  local stats, progress = try_require("agentmap.stats"), try_require("agentmap.progress")
  if not (stats and stats.log and progress and progress.compute) then return end
  local okc, config = pcall(require, "agentmap.config")
  if not okc then return end
  local root = config.root()
  local sid = M.run.sid or (s.run_id) or "?"
  for id, a in pairs(s.agents or {}) do
    if type(a) == "table" and type(id) == "string" and id:sub(1, 3) ~= "wf:" then
      local key = sid .. ":" .. id
      local L = log_marks[key]
      if a.status == "RUNNING" then
        if not L then
          L = {}
          log_marks[key] = L
        end
        L.running = true
        if not L.last or now - L.last >= 30 then
          local ok, r = pcall(progress.compute, s, id, {
            now = now, stats = M.view.stats, config = pcfg, flow_id = M.flow_id,
          })
          if ok and r then
            local extra = { ts = iso(now), run = sid, started_at = a.started_at }
            local e
            if progress.log_entry then
              local ok2, got = pcall(progress.log_entry, s, id, r, extra)
              e = ok2 and got or nil
            end
            e = e or vim.tbl_extend("force", {
              agent = id, type = a.agent_type, model = a.model or a.model_requested,
              basis = r.basis, n = r.n, k = r.k, f = r.f, pct = r.pct,
              stat_basis = r.stat_basis, samples = r.samples, d_hat_ms = r.expected_ms,
            }, extra)
            pcall(stats.log, root, e)
            L.last = now
          end
        end
      elseif L and L.running then
        L.running = false
        if a.status == "DONE" and a.elapsed_ms then
          local facts
          if state_mod.progress_facts then
            local ok, f = pcall(state_mod.progress_facts, s, id)
            facts = ok and f or nil
          end
          pcall(stats.log, root, {
            ts = iso(now), run = sid, agent = id, final = true, elapsed_ms = a.elapsed_ms,
            started_at = a.started_at, n = facts and facts.n or nil, k = facts and facts.k or nil,
          })
        end
      end
    end
  end
end
M._log_progress = log_progress

local function set_win_opts(win, opts)
  for k, v in pairs(opts) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = win, scope = "local" })
  end
end

local function scratch_buf(name, ft)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].swapfile = false
  vim.bo[b].modifiable = false
  vim.bo[b].filetype = ft
  pcall(vim.api.nvim_buf_set_name, b, name)
  return b
end

-- ------------------------------------------------------------
-- 図
-- ------------------------------------------------------------
local function create_map_buf(run_id)
  local b = scratch_buf("agentmap://map/" .. tostring(run_id), "agentmap")
  keymaps.attach_map(b)
  local grp = vim.api.nvim_create_augroup("agentmap_ui", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = grp,
    buffer = b,
    callback = function()
      M.stop_ticker()
      anim.stop()
      M.buf, M.cache, M.win = nil, nil, nil
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = grp,
    callback = function()
      if valid_buf(M.buf) then pcall(M.refresh, { aux = false }) end
    end,
  })
  return b
end

--- Open the map of `run` (default: the latest flow) and optionally a single prompt `flow_id`.
function M.open_map(run, flow_id)
  if not run then
    local ev = try_require("agentmap.events")
    if ev and ev.current_flow then
      local ok, r, f = pcall(ev.current_flow)
      if ok then run, flow_id = r, f end
    end
  end
  if not run or not run.state then
    notify(t("ui.no_runs_to_show"), vim.log.levels.WARN)
    return nil
  end
  renderer.setup_highlights()
  local old_id = M.run and M.run.state and M.run.state.run_id
  local same = old_id ~= nil and old_id == run.state.run_id and M.flow_id == flow_id
  M.run = run
  M.flow_id = flow_id
  M.flow_state = nil
  if not same then
    M.view = { root = "ROOT", collapsed = {}, mode = M.view.mode }
    M.nav = {}
    M.cache = nil
    M.close_aux() -- 別の run・別の指示に切り替えるとき、前の詳細画面を残さない
    anim.reset() -- 前に見ていたものの「終わった瞬間」を新しい図で光らせない
    M.steer_expanded = {}
    M._seed_expired()
    M._seed_pauses()
  end

  if not valid_buf(M.buf) then
    M.buf = create_map_buf(run.state.run_id)
    M.cache = nil
  elseif not same then
    pcall(vim.api.nvim_buf_set_name, M.buf, "agentmap://map/" .. tostring(run.state.run_id))
  end

  local win = map_win()
  if win then
    vim.api.nvim_set_current_win(win)
  else
    local cfg = graph.util.config()
    local how = cfg.open or "tab"
    if how == "tab" then
      vim.cmd("tabnew")
      local empty = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_buf(0, M.buf)
      if empty ~= M.buf and vim.api.nvim_buf_get_name(empty) == "" and not vim.bo[empty].modified then
        pcall(vim.api.nvim_buf_delete, empty, { force = true })
      end
    elseif how == "vsplit" then
      vim.cmd("vsplit")
      vim.api.nvim_win_set_buf(0, M.buf)
    else
      vim.api.nvim_win_set_buf(0, M.buf)
    end
  end
  M.win = vim.api.nvim_get_current_win()
  M.tab = vim.api.nvim_get_current_tabpage()
  set_win_opts(M.win, {
    wrap = false, number = false, relativenumber = false, signcolumn = "no",
    cursorline = true, list = false, foldcolumn = "0", spell = false,
  })
  if not M.cache then M._place = "ROOT" end
  M.refresh({ aux = false })
  return M.buf
end

--- Switch the prompt (flow) shown within the same run.
--- 同じ run の中で、見せる指示（流れ）を切り替える
function M.set_flow(flow_id)
  if flow_id == M.flow_id then return end
  M.flow_id = flow_id
  M.flow_state = nil
  M.view = { root = "ROOT", collapsed = {}, mode = M.view.mode }
  M.cache = nil
  M._place = "ROOT"
  anim.reset()
  -- 自動の切り替えで、ほかの窓で作業中のカーソルを図へ動かさない（補助画面にいたときだけ図へ戻す）
  local cur = vim.api.nvim_get_current_win()
  local in_aux = cur == M.aux_win
  M.close_aux()
  if not in_aux and valid_win(cur) then vim.api.nvim_set_current_win(cur) end
  M.refresh({ aux = false })
end

--- Id under the cursor (a box on the map, or the agent of the current side view).
-- カーソル位置の Agent id（図なら箱、補助画面ならその画面の Agent）
function M.current_id()
  local cur = vim.api.nvim_get_current_buf()
  if valid_buf(M.buf) and cur == M.buf then
    local pos = vim.api.nvim_win_get_cursor(0)
    return renderer.node_at(M.cache, pos[1], pos[2])
  end
  local ok, id = pcall(function() return vim.b[cur].agentmap_id end)
  if ok and id then return id end
  local top = M.nav[#M.nav]
  return top and top.id or nil
end

local function cursor_to(win, id)
  local r = renderer.rows_of(M.cache, id)
  if not r then return false end
  local box = M.cache.mode == "box"
  local row = r[1] + (box and 1 or 0)
  -- 全角が混じると行ごとにバイト位置が違うので、その行の開始桁を使う
  local col = (r.starts and r.starts[row] or r[3]) + (box and 4 or 0)
  pcall(vim.api.nvim_win_set_cursor, win, { row, col })
  return true
end

--- Redraw the map. opts.reload re-reads the files; opts.aux = false leaves the side view alone.
-- 図を描き直す。opts.reload = ファイルを読み直す、opts.aux = false で補助画面は触らない
function M.refresh(opts)
  opts = opts or {}
  if not M.run then return end
  if opts.reload then
    local ev = try_require("agentmap.events")
    if ev then
      if ev.poll then pcall(ev.poll, M.run) end
      if ev.enrich then pcall(ev.enrich, M.run) end
    end
  end
  rebuild()
  if not valid_buf(M.buf) then return end
  local win = map_win()
  local keep = nil
  if win and M.cache then
    local pos = vim.api.nvim_win_get_cursor(win)
    keep = renderer.node_at(M.cache, pos[1], pos[2])
  end
  local cfg = graph.util.config()
  if (cfg.open or "tab") == "tab" then
    M.view.width = vim.o.columns - 1
  else
    M.view.width = win and (vim.api.nvim_win_get_width(win) - 1) or 120
  end
  -- 進み具合（%）の計算に使うもの（graph が progress.compute に渡す）
  M.view.now = M.clock()
  M.view.progress = M.progress_cfg()
  M.view.stats = M._stats()
  M.layout = graph.layout(state(), M.view)
  M.cache = renderer.render(M.buf, M.layout, M.cache)
  -- 矢印の光と毎秒の描き直し（描き直したら、必要に応じて動き出す・止まる）
  local shown = state()
  pcall(anim.update, M.buf, M.layout, M.status_map(shown))
  pcall(log_progress, shown, M.view.now)
  if M.should_tick(shown) and map_visible_here() then
    M.start_ticker()
  else
    M.stop_ticker()
  end
  if win then
    local want = M._place or keep
    M._place = nil
    if want then
      local pos = vim.api.nvim_win_get_cursor(win)
      if renderer.node_at(M.cache, pos[1], pos[2]) ~= want or pos[1] <= 3 then
        if not cursor_to(win, want) and want ~= "ROOT" then cursor_to(win, "ROOT") end
      end
    end
  end
  -- 補助画面が詳細なら、新しい状態で作り直す
  if opts.aux ~= false and valid_win(M.aux_win) then
    local top = M.nav[#M.nav]
    if top and (top.kind == "detail" or top.kind == "check") then M._show(top, { keep_cursor = true }) end
  end
end

--- Close the map tab/window and stop watching.
function M.close()
  M.stop_ticker()
  anim.stop()
  M.close_aux()
  local buf = M.buf
  if valid_win(M.win) and #vim.api.nvim_list_tabpages() > 1 and M.tab and vim.api.nvim_tabpage_is_valid(M.tab) then
    local nr = vim.api.nvim_tabpage_get_number(M.tab)
    pcall(vim.cmd, "tabclose " .. nr)
  elseif valid_win(M.win) then
    local alt = vim.fn.bufnr("#")
    if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) then
      vim.api.nvim_win_set_buf(M.win, alt)
    else
      vim.api.nvim_win_call(M.win, function() vim.cmd("enew") end)
    end
  end
  -- 図のバッファを消す（監視はこの BufWipeout で止まる）
  if valid_buf(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  for k, b in pairs(M.aux_bufs) do
    if valid_buf(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    M.aux_bufs[k] = nil
  end
  M.buf, M.win, M.tab, M.cache = nil, nil, nil, nil
end

-- ------------------------------------------------------------
-- 右側の補助ウィンドウ（詳細・transcript・diff）
-- ------------------------------------------------------------
local function aux_buf(kind, id)
  local key = kind .. ":" .. id
  local b = M.aux_bufs[key]
  if valid_buf(b) then return b end
  b = scratch_buf("agentmap://" .. kind .. "/" .. id, kind == "diff" and "diff" or ("agentmap_" .. kind))
  keymaps.attach_aux(b, kind)
  vim.b[b].agentmap_id = id
  vim.b[b].agentmap_kind = kind
  M.aux_bufs[key] = b
  return b
end

local function ensure_aux(buf, kind)
  if valid_win(M.aux_win) then
    vim.api.nvim_win_set_buf(M.aux_win, buf)
  else
    local mw = map_win() or vim.api.nvim_get_current_win()
    local cfg = graph.util.config()
    local width = math.max(40, math.floor(vim.o.columns * (cfg.aux_width or 0.45)))
    M.aux_win = vim.api.nvim_open_win(buf, true, { split = "right", win = mw, width = width })
  end
  vim.api.nvim_set_current_win(M.aux_win)
  set_win_opts(M.aux_win, {
    wrap = kind ~= "diff", number = false, relativenumber = false, signcolumn = "no",
    list = false, foldcolumn = "0", spell = false, cursorline = kind == "detail" or kind == "check",
  })
end

--- Show one navigation entry in the side window without changing the back stack.
-- nav の1項目を表示（積み重ねは変えない）
function M._show(entry, opts)
  opts = opts or {}
  local a
  if entry.kind == "check" then
    a = check_of(entry.id)
    if not a then
      notify(t("ui.check_not_found", { id = tostring(entry.id) }), vim.log.levels.WARN)
      return false
    end
  else
    a = agent_of(entry.id)
    if not a then
      notify(t("ui.agent_not_found", { id = tostring(entry.id) }), vim.log.levels.WARN)
      return false
    end
  end
  local mod = try_require(VIEWS[entry.kind])
  if not mod then return false end
  local b = aux_buf(entry.kind, entry.id)
  local back_to = vim.api.nvim_get_current_win()
  ensure_aux(b, entry.kind)
  local width = vim.api.nvim_win_get_width(M.aux_win)
  -- 詳細などの画面には、見せている流れの状態（番号が流れの中の番号）を渡す
  mod.open(setmetatable({ state = state() }, { __index = M.run }), a, b, {
    width = width, now = M.clock(), steer_expanded = M.steer_expanded,
  })
  if opts.keep_cursor then
    if valid_win(back_to) then vim.api.nvim_set_current_win(back_to) end
    return true
  end
  local row = 1
  local marker = nil
  if entry.focus == "history" then
    marker = t("detail.history_marker")
  elseif entry.focus == "steers" then
    -- 「■ Steering (2)」の数字の前まで
    marker = (t("detail.h_steers", { n = "" }):gsub("%s*[%(（].*$", ""))
  end
  if marker and marker ~= "" then
    for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if l:find(marker, 1, true) then
        row = i
        break
      end
    end
  end
  pcall(vim.api.nvim_win_set_cursor, M.aux_win, { row, 0 })
  return true
end

local function open_view(kind, id, want_focus)
  if not id then return end
  local focus = want_focus
  if id:sub(1, 5) == "gate:" then
    id = id:sub(6)
    focus = "history"
  end
  if id == "UNKNOWN_PARENT" then
    notify(t("ui.unknown_parent_info"))
    return
  end
  if id == "START" or id == "END" or id:sub(1, 6) == "stage:" then
    notify(t("ui.pseudo_info"))
    return
  end
  if not M.run then M.open_map() end
  if not M.run then return end
  if is_check(id) then
    -- HUMAN CHECK：詳細なら確認の画面、transcript・diff なら箱が付いている Agent のもの
    if kind == "detail" or kind == "check" then
      if not check_of(id) then
        notify(t("ui.check_not_found", { id = tostring(id) }), vim.log.levels.WARN)
        return
      end
      kind = "check"
    else
      id = M.resolve_agent(id)
      if not id then return end
    end
  elseif not agent_of(id) then
    notify(t("ui.agent_not_found", { id = tostring(id) }), vim.log.levels.WARN)
    return
  end
  if not map_win() then M.open_map(M.run) end
  -- 図から開いたときは、戻り先を積み直す
  if vim.api.nvim_get_current_buf() == M.buf or not valid_win(M.aux_win) then M.nav = {} end
  local top = M.nav[#M.nav]
  local entry = { kind = kind, id = id, focus = focus }
  if not (top and top.kind == kind and top.id == id) then
    table.insert(M.nav, entry)
  else
    top.focus = focus
    entry = top
  end
  M._show(entry)
end

--- Open the detail view of an agent (gate: and check: ids are routed to the right view).
function M.open_detail(id) open_view("detail", id) end
--- Open the transcript view of an agent.
function M.open_transcript(id) open_view("transcript", id) end
--- Open the git diff view of an agent.
function M.open_diff(id) open_view("diff", id) end
--- Open the HUMAN CHECK view.
function M.open_check(id) open_view("check", id) end
--- Open the detail view of an agent at its steering section.
function M.open_steers(id) open_view("detail", id, "steers") end

--- Open the details of agent number `n`.
-- 番号（[n]）で詳細を開く
function M.open_index(n)
  local s = state()
  local id = s and graph.by_index(s, n)
  if not id then
    notify(t("ui.no_agent_index", { n = n }))
    return
  end
  M.open_detail(id)
end

--- Enter in a side view: open the agent or HUMAN CHECK linked to the current line.
-- 詳細・確認の画面で Enter：行に結びついた Agent（または HUMAN CHECK）の画面へ
function M.follow_link()
  local b = vim.api.nvim_get_current_buf()
  local kind = vim.b[b].agentmap_kind or "detail"
  local mod = try_require(VIEWS[kind] or VIEWS.detail)
  local links = mod and mod.links and mod.links[b] or {}
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local id = links[row]
  if type(id) == "string" and id:sub(1, 6) == "steer:" then
    -- 修正指示の行：本文全体を開く・閉じる（画面を作り直し、カーソルはその行のまま）
    local sid = id:sub(7)
    M.steer_expanded[sid] = (not M.steer_expanded[sid]) or nil
    local top = M.nav[#M.nav]
    if top then
      local win = vim.api.nvim_get_current_win()
      M._show(top, { keep_cursor = true })
      pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
    end
    return
  end
  if id then
    open_view("detail", id) -- check: で始まれば open_view が確認の画面に振り分ける
    return
  end
  -- 開ける行に乗っていないとき：エラーで止めず、下（無ければ上）の一番近い開ける行へカーソルを運ぶ
  local rows = {}
  for r in pairs(links) do rows[#rows + 1] = r end
  table.sort(rows)
  if #rows == 0 then
    notify(t("ui.nothing_to_open"))
    return
  end
  local to = rows[1]
  for _, r in ipairs(rows) do
    if r > row then to = r break end
    to = r
  end
  vim.api.nvim_win_set_cursor(0, { to, 0 })
  notify(t("ui.moved_to_link"))
end

--- Close the side window.
function M.close_aux()
  if valid_win(M.aux_win) then
    local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(M.aux_win))
    if #wins > 1 then
      pcall(vim.api.nvim_win_close, M.aux_win, true)
    elseif valid_buf(M.buf) then
      vim.api.nvim_win_set_buf(M.aux_win, M.buf)
      M.win = M.aux_win
    end
  end
  M.aux_win = nil
  M.nav = {}
  local mw = map_win()
  if mw then vim.api.nvim_set_current_win(mw) end
end

--- Backspace: previous side view (finally the map); on the map, zoom out one level.
-- BS：補助画面なら1つ前へ（最後は図へ）、図なら部分表示を1段上へ
function M.back()
  local cur = vim.api.nvim_get_current_buf()
  if valid_buf(M.buf) and cur == M.buf then
    local r = M.view.root or "ROOT"
    if r == "ROOT" then
      notify(t("ui.at_top"))
      return
    end
    local a = agent_of(r)
    local p = a and a.parent_id or "ROOT"
    if r == "UNKNOWN_PARENT" or (p ~= "ROOT" and not agent_of(p)) then p = "ROOT" end
    M.view.root = p
    M._place = r
    M.refresh({ aux = false })
    return
  end
  table.remove(M.nav)
  if #M.nav > 0 then
    M._show(M.nav[#M.nav])
  else
    M.close_aux()
  end
end

--- Show only `id` and what is below it (z).
-- z：id から下だけを表示
function M.set_root(id)
  if not id then return end
  if is_check(id) then
    notify(t("ui.zoom_check"))
    return
  end
  if id:sub(1, 5) == "gate:" then id = id:sub(6) end
  if id ~= "ROOT" and id ~= "UNKNOWN_PARENT" and not agent_of(id) then return end
  M.view.root = id
  M._place = id
  M.refresh({ aux = false })
end

--- Expand / collapse the children of `id`. expand = true / false / nil (toggle).
-- + / -：子を開く・畳む。expand = true 開く / false 畳む / nil 反転
function M.toggle(id, expand)
  if not id then return end
  -- 門・HUMAN CHECK の箱では、それが付いている Agent を開く・畳む
  id = M.resolve_agent(id)
  if not id then return end
  local s = state()
  if not s then return end
  local has_kids = #graph.children(s, id) > 0 or (M.layout and M.layout.nodes["gate:" .. id] ~= nil)
    or #graph.checks_of(s, id) > 0 or M.view.collapsed[id]
  if id == "UNKNOWN_PARENT" then has_kids = true end
  if expand == nil then expand = M.view.collapsed[id] == true end
  if expand then
    M.view.collapsed[id] = nil
  elseif has_kids then
    M.view.collapsed[id] = true
  else
    -- 子の無い箱で - を押したら、親を畳む
    local a = agent_of(id)
    local p = a and a.parent_id
    if not p then return end
    M.view.collapsed[p] = true
    id = p
  end
  M._place = id
  M.refresh({ aux = false })
end

--- Switch between the map (box) view and the list (tree) view.
-- v：図 ↔ 一覧
function M.toggle_mode()
  local cur = M.layout and M.layout.mode or "box"
  M.view.mode = cur == "box" and "tree" or "box"
  M.refresh({ aux = false })
  notify(M.view.mode == "box" and t("ui.mode_box") or t("ui.mode_tree"))
end

-- n / p：次・前の箱へ
--   図の並び順（START → ROOT → 段1 → 段2 … → END）で進む。START・END・段の見出しは飛ばす
local function pseudo(id)
  return id == "START" or id == "END" or id:sub(1, 6) == "stage:"
end

--- Move the cursor to the next (delta = 1) or previous (delta = -1) box.
function M.move(delta)
  if not M.cache or not M.cache.node_rows then return end
  local list = {}
  for _, id in ipairs(M.cache.order or {}) do
    if M.cache.node_rows[id] and not pseudo(id) then list[#list + 1] = { id = id } end
  end
  if #list == 0 then
    for id, r in pairs(M.cache.node_rows) do
      if not pseudo(id) then list[#list + 1] = { id = id, r = r } end
    end
    table.sort(list, function(x, y)
      if x.r[1] ~= y.r[1] then return x.r[1] < y.r[1] end
      return x.r[3] < y.r[3]
    end)
  end
  if #list == 0 then return end
  local cur = M.current_id()
  local idx = 0
  for i, e in ipairs(list) do
    if e.id == cur then idx = i end
  end
  local nxt
  if idx == 0 then
    nxt = delta > 0 and 1 or #list
  else
    nxt = (idx - 1 + delta) % #list + 1
  end
  cursor_to(map_win() or 0, list[nxt].id)
end

--- Change this tab's working folder to the agent's worktree (:tcd); opens oil.nvim when loaded.
-- w：その Agent の作業フォルダへ（このタブだけ :tcd）。Oil があれば右側で開く
function M.jump_worktree(id)
  if id and id:sub(1, 5) == "gate:" then id = id:sub(6) end
  local a = agent_of(id)
  local s = state()
  if not a or not s then return end
  local dir = a.worktree or a.cwd or s.cwd
  if not dir or vim.fn.isdirectory(dir) ~= 1 then
    notify(t("ui.dir_not_found", { dir = tostring(dir) }), vim.log.levels.WARN)
    return
  end
  vim.cmd("tcd " .. vim.fn.fnameescape(dir))
  notify(t("ui.tcd_done", { dir = dir }))
  if package.loaded["oil"] then
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].bufhidden = "wipe"
    ensure_aux(b, "oil")
    M.nav = {}
    pcall(vim.cmd, "Oil " .. vim.fn.fnameescape(dir))
  end
end

-- ------------------------------------------------------------
-- 選択メニュー類
-- ------------------------------------------------------------
--- Pick a past run with vim.ui.select and call on_pick(run).
function M.run_picker(runs, on_pick)
  if not runs or #runs == 0 then
    notify(t("ui.no_past_runs"))
    return
  end
  vim.ui.select(runs, {
    prompt = t("ui.runs_prompt"),
    format_item = function(r)
      local ts = r.flow_id and graph.util.parse_iso(r.started_at)
      local date = r.date or (ts and os.date("%Y-%m-%d %H:%M", math.floor(ts)))
        or (r.mtime and os.date("%Y-%m-%d %H:%M", type(r.mtime) == "table" and r.mtime.sec or r.mtime)) or ""
      local sid = graph.util.short_id(r.sid or r.session_id or r.run_id)
      local parts = { date }
      -- 同じセッションの指示は本文の出だしが似ることがあるので、何番目の指示かを先に出す
      if r.flow_id then parts[#parts + 1] = t("ui.prompt_n", { n = r.flow_n or 0, total = r.flow_total or 0 }) end
      parts[#parts + 1] = graph.util.truncate(r.title or "", 40)
      if r.agents then parts[#parts + 1] = t("ui.agents_count", { n = r.agents }) end
      if r.status then parts[#parts + 1] = "[" .. r.status .. "]" end
      parts[#parts + 1] = sid
      local proj = r.cwd and vim.fn.fnamemodify(r.cwd, ":t") or r.slug
      if proj and proj ~= "" then parts[#parts + 1] = proj end
      if r.source then
        -- 記録には言語に依らない符号（hooks / transcript / history）が入っている。知っている符号だけ訳す
        local key = "common.source_" .. tostring(r.source)
        parts[#parts + 1] = "(" .. (i18n.has(key) and t(key) or tostring(r.source)) .. ")"
      end
      return table.concat(parts, "  ")
    end,
  }, function(choice)
    if choice then on_pick(choice) end
  end)
end

--- Show the list of past runs.
function M.runs()
  local af = try_require("agentmap")
  if af and type(af.runs) == "function" then return af.runs() end
  local ev = try_require("agentmap.events")
  if not ev or not ev.list_runs then
    notify(t("ui.runs_unavailable"), vim.log.levels.WARN)
    return
  end
  M.run_picker(ev.list_runs(), function(r)
    local run = ev.open_run(r.sid or r.session_id)
    if run then M.open_map(run, r.flow_id) end
  end)
end

--- Ask for a format and export the run.
function M.export_menu()
  vim.ui.select({ "markdown", "html", "pdf" }, { prompt = t("ui.export_prompt") }, function(fmt)
    if not fmt then return end
    local af = try_require("agentmap")
    if af and type(af.export) == "function" then return af.export(fmt) end
    local ex = try_require("agentmap.export")
    if ex and ex.write and state() then
      local p = ex.write(state(), fmt)
      if p then notify(t("ui.exported", { path = p })) end
    else
      notify(t("ui.export_unavailable"), vim.log.levels.WARN)
    end
  end)
end

--- Review menu for an agent (submit / PASS / RETRY / ESCALATE / rerun / rename).
function M.review_menu(id)
  if id and id:sub(1, 5) == "gate:" then id = id:sub(6) end
  local a = agent_of(id)
  if not a then return end
  local rv = try_require("agentmap.review")
  if not rv then
    notify(t("ui.review_unavailable"), vim.log.levels.WARN)
    return
  end
  local label = id == "ROOT" and "ROOT" or ("[" .. (a.index or "?") .. "] " .. (a.name or a.task or id))
  local items = { t("ui.review_submit"), "PASS", "RETRY", "ESCALATE", t("ui.review_retry_of"), t("ui.review_rename") }
  local function done() pcall(M.refresh) end
  vim.ui.select(items, { prompt = t("ui.review_prompt", { label = label }) }, function(_, idx)
    if not idx then return end
    if idx == 1 then
      vim.ui.input({ prompt = t("ui.note_prompt") }, function(note)
        if note == nil then return end
        rv.submit(M.run, id, note ~= "" and note or nil)
        done()
      end)
    elseif idx <= 4 then
      local verdict = items[idx]
      vim.ui.input({ prompt = t("ui.reason_prompt", { verdict = verdict }) }, function(reason)
        if reason == nil then return end
        local extra = {}
        if verdict == "ESCALATE" then extra.escalate_to = a.parent_id end
        rv.record(M.run, id, verdict, reason, "user", extra)
        done()
      end)
    elseif idx == 5 then
      vim.ui.input({ prompt = t("ui.retry_of_prompt") }, function(s)
        local n = tonumber(s or "")
        local old = n and graph.by_index(state(), n)
        if not old then
          if s and s ~= "" then notify(t("ui.no_agent_number", { n = s })) end
          return
        end
        rv.mark_retry_of(M.run, id, old)
        done()
      end)
    else
      vim.ui.input({ prompt = t("ui.rename_prompt"), default = a.name or "" }, function(nm)
        if not nm or nm == "" then return end
        local ev = try_require("agentmap.events")
        if ev and ev.emit then
          ev.emit(M.run, { event = "agent_updated", agent_id = id, name = nm })
          done()
        end
      end)
    end
  end)
end

--- Show the key help in a floating window.
-- ? のキー一覧（浮かせた小窓。q / Esc で閉じる）
function M.help()
  local lines = keymaps.help_lines()
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.bo[b].bufhidden = "wipe"
  local width = math.min(w + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(b, true, {
    relative = "editor", width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    style = "minimal", border = "rounded", title = " AgentMap ", title_pos = "center",
  })
  for _, k in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", k, function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = b, nowait = true })
  end
end

-- ------------------------------------------------------------
-- 毎秒の描き直し（ticker）
-- ------------------------------------------------------------
--- Start the once-a-second redraw (no-op when it already runs). Interval: progress.tick_ms.
function M.start_ticker()
  if ticker then return end
  local ms = math.max(100, tonumber(M.progress_cfg().tick_ms) or 1000)
  local timer = vim.uv.new_timer()
  if not timer then return end
  ticker = timer
  timer:start(ms, ms, function()
    vim.schedule(function()
      if ticker ~= timer then return end
      local ok, err = pcall(M.tick)
      if not ok then
        M.stop_ticker()
        notify(tostring(err), vim.log.levels.WARN)
      end
    end)
  end)
end

--- Stop the once-a-second redraw.
function M.stop_ticker()
  if ticker then
    pcall(ticker.stop, ticker)
    pcall(ticker.close, ticker)
    ticker = nil
  end
end

--- True while the once-a-second redraw runs (tests).
function M._ticking() return ticker ~= nil end

--- One tick: read new step marks, expire undelivered steering, redraw the map (only changed
--- lines are rewritten). The redraw decides whether the ticker keeps running.
function M.tick()
  if not M.run or not valid_buf(M.buf) or not map_visible_here() then
    M.stop_ticker()
    anim.stop()
    return
  end
  local ev = try_require("agentmap.events")
  if ev and ev.poll_steps then
    local ok, changed = pcall(ev.poll_steps, M.run)
    if ok and changed and ev.enrich then pcall(ev.enrich, M.run) end
  end
  M.sweep_steers()
  M.sweep_pauses()
  M.refresh({ aux = false })
end

-- ------------------------------------------------------------
-- 修正指示（steer。DESIGN-v0.2-steer.md §2・§4・§6、v0.1.2 は DESIGN-v0.1.2-steer2：終わり際＋親経由）
-- ------------------------------------------------------------
-- v0.1.2（DESIGN-v0.1.2-steer2 §9.1）: 子への既定は終わり際（mode stop）。at_stop は廃止（常に on）。
-- no_terminal = "hook" は "stop" の別名
local STEER_DEFAULTS = {
  enabled = true, mode = "stop", relay = "menu", root_via = "terminal", no_terminal = "stop",
  submit_delay_ms = 300, input = "window", text_max = 4000,
}
local STEER_PREFIX = "[AgentMap] " -- 端末へ送る文の先頭（固定。state が「流れの続き」の判定に使う）
local FINISHED = { DONE = true, REWORK = true, FAILED = true }

-- 修正指示の新しい文（DESIGN-v0.1.2-steer2 付録 A）。鍵が言語ファイルに無いあいだは英語の既定の文を使う
local STEER_TEXT = {
  ["ui.steer_write_resume"] = "Write an instruction (resumes it; arrives when it finishes)",
  ["ui.steer_write_gate"] = "Write an instruction (it continues now)",
  ["ui.steer_write_root_stop"] = "Write an instruction (arrives at the end of its turn)",
  ["ui.steer_relay"] = "Write and relay now through the main agent",
  ["ui.steer_prompt_stop"] = "Steer %{label} (at its end)",
  ["ui.steer_prompt_relay"] = "Steer %{label} (relay via the main agent)",
  ["ui.steer_prompt_resume"] = "Steer %{label} (resumes; at its end)",
  ["ui.steer_queued_eta"] = " (about %{left} left at the usual pace)",
  ["ui.steer_resumed_stop"] = "%{label} resumed; the instruction arrives when it tries to finish (x pauses it again)",
  ["ui.steer_queued_root_stop"] = "Steer for the main agent queued; it arrives at the end of its turn (no Claude terminal here)",
  ["ui.steer_relay_sent"] = "Relay typed into the main agent's terminal; it passes the text on with SendMessage (glance at the terminal)",
  ["ui.steer_relay_not_target"] = "Relay works only for a running sub-agent started by the main agent (use the normal route)",
  ["ui.steer_relay_no_terminal"] = "No Claude terminal found; relay is not possible (use the normal route)",
  ["ui.steer_relayed"] = "The main agent passed your instruction on to %{label} (SendMessage)",
  ["ui.steer_not_relayed"] = "The main agent ended its turn without passing your instruction on to %{label}",
  ["ui.steer_delivered_stop"] = "%{label} received your instruction at its end and continues",
  ["steer.relay_en"] = '[AgentMap] Tell sub-agent [%{index}] "%{name}" (agent id %{id}) this, with SendMessage: %{text}',
  ["steer.relay_ja"] = "[AgentMap] サブエージェント [%{index}]「%{name}」（agent id %{id}）に SendMessage で次を伝えてください：%{text}",
}
local function st_text(key, vars)
  if i18n.has(key) or i18n.has(key, "en") then return t(key, vars) end
  local s = STEER_TEXT[key] or key
  return (s:gsub("%%{([%w_]+)}", function(k)
    local v = vars and vars[k]
    if v == nil then return nil end
    return tostring(v)
  end))
end
M._st = st_text

--- Effective steering settings (config.get().steer; false = { enabled = false }).
--- `no_terminal = "hook"` is read as "stop" (its name before 0.1.2); `at_stop` is ignored.
function M.steer_cfg()
  local ok, config = pcall(require, "agentmap.config")
  local raw = nil
  if ok then raw = config.get().steer end
  local cfg
  if raw == false then
    cfg = vim.tbl_extend("force", STEER_DEFAULTS, { enabled = false })
  elseif type(raw) ~= "table" then
    cfg = vim.deepcopy(STEER_DEFAULTS)
  else
    cfg = vim.tbl_extend("force", STEER_DEFAULTS, raw)
  end
  if cfg.no_terminal == "hook" then cfg.no_terminal = "stop" end
  if cfg.relay ~= "never" and cfg.relay ~= "always" then cfg.relay = "menu" end
  cfg.at_stop = nil
  return cfg
end

--- The agent a steering instruction for map id `id` goes to, or nil when the box cannot take one
--- (HUMAN CHECK, Workflow summary wf:, UNKNOWN_PARENT, START/END, stage headers, unknown ids).
function M.steer_target(id)
  if type(id) ~= "string" then return nil end
  if id:sub(1, 5) == "gate:" then id = id:sub(6) end
  if is_check(id) or id:sub(1, 3) == "wf:" or id:sub(1, 6) == "stage:" then return nil end
  if id == "UNKNOWN_PARENT" or id == "START" or id == "END" then return nil end
  local a = agent_of(id) or (M.run and M.run.state and M.run.state.agents and M.run.state.agents[id])
  if not a or a.kind == "workflow" then return nil end
  return id
end

local function label_of(id)
  if id == "ROOT" or id == nil then return "ROOT" end
  local a = agent_of(id) or (M.run and M.run.state and M.run.state.agents and M.run.state.agents[id])
  if not a then return tostring(id) end
  return "[" .. tostring(a.index or "?") .. "] " .. graph.util.truncate(a.name or a.task or id, 40)
end
M._steer_label = label_of

--- How a steering instruction to `id` is delivered: "root" (the terminal), "redo" (a finished
--- agent: ask the main agent in the terminal to redo it) or "hook" (a file a hook hands over when
--- the agent tries to finish; DESIGN-v0.1.2-steer2 §2).
---   A sub-agent held by a pause gets "hook" (also one waiting at its end at the gate: its stop is
---   already recorded, so it looks finished). ROOT paused before a tool call gets "root" (the pause
---   is lifted first, then the terminal; Q23); ROOT paused at its end or with a pause placed gets
---   "hook" (its Stop hook hands the text over).
function M.steer_kind(id)
  local p = M._live_pause(id)
  if id == "ROOT" then
    if not p then return "root" end
    if p.status == "PAUSED" and tostring(p.hit_via or ""):sub(1, 10) == "PreToolUse" then return "root" end
    return "hook"
  end
  if p and p.status == "PAUSED" then return "hook" end
  local a = agent_of(id) or (M.run and M.run.state and M.run.state.agents and M.run.state.agents[id])
  if a and FINISHED[a.status] then return "redo" end
  return "hook"
end

-- 宛先 id の未配達の指示（古い順）
local function pending_of(id)
  local s = M.run and M.run.state
  if not s or type(s.steers) ~= "table" then return {} end
  local ids
  if state_mod.steers_of then
    local ok, r = pcall(state_mod.steers_of, s, id)
    if ok and type(r) == "table" then ids = r end
  end
  if not ids then
    ids = {}
    for sid, st in pairs(s.steers) do
      if st.agent_id == id then ids[#ids + 1] = sid end
    end
    table.sort(ids, function(x, y)
      return tostring(s.steers[x].requested_at or "") < tostring(s.steers[y].requested_at or "")
    end)
  end
  local out = {}
  for _, sid in ipairs(ids) do
    local st = s.steers[sid]
    if st and st.status == "PENDING" then out[#out + 1] = sid end
  end
  return out
end
M._pending_steers = pending_of

-- 「やり直し」の文（UI の言語。i18n の鍵が無ければ英語の既定の文）
local REDO_FALLBACK = {
  en = 'Please redo agent [%{index}] "%{name}" (id %{id}, finished %{time}): %{text}. Use the same delegation; report what changed.',
  ja = "エージェント [%{index}]「%{name}」（id %{id}、%{time} 終了）をやり直してください：%{text}。同じ任せ方で、何が変わったかを報告してください。",
}
function M.redo_text(id, text)
  local a = agent_of(id) or (M.run and M.run.state and M.run.state.agents and M.run.state.agents[id]) or {}
  local fin = a.finished_at and graph.util.parse_iso(a.finished_at)
  local vars = {
    index = a.index or "?",
    name = graph.util.truncate(a.name or a.task or id, 40),
    id = id,
    time = fin and os.date("%H:%M", math.floor(fin)) or "?",
    text = text,
  }
  local lang = i18n.lang == "ja" and "ja" or "en"
  local key = "steer.redo_" .. lang
  local out
  if i18n.has(key) or i18n.has(key, "en") then
    out = t(key, vars)
  else
    out = REDO_FALLBACK[lang]:gsub("%%{([%w_]+)}", function(k) return tostring(vars[k]) end)
  end
  -- 先頭の [AgentMap] は送るときに付ける
  if out:sub(1, #STEER_PREFIX) == STEER_PREFIX then out = out:sub(#STEER_PREFIX + 1) end
  return out
end

local function events_mod()
  local ev = try_require("agentmap.events")
  if not ev or not ev.request_steer then return nil end
  return ev
end

--- True when the hooks registered in Claude Code's settings.json are the current ones and deliver
--- with the configured `steer.mode`. An instruction that goes through hooks (a sub-agent, or ROOT
--- without a terminal) reaches the agent only then: the v0.1.0 registration has no delivery hook,
--- and the v0.1.1 one (`--mode deny`) hands the file over at the next tool call as a tool error,
--- which current models may ignore, so nothing is left for the agent's end (DESIGN-v0.1.2-steer2
--- §8.2, Q22). The terminal routes (ROOT, redo, relay) do not depend on the hooks and are not checked.
--- True as well when the check itself is not possible (hooks module missing).
function M.steer_hooks_ok()
  local hooks = try_require("agentmap.hooks")
  if not hooks or type(hooks.status) ~= "function" then return true end
  -- 今の一時停止の設定で見た登録か、一時停止を外した登録のどちらかと一致すればよい（修正指示だけなら
  -- --pause と長い timeout は要らない）。一時停止を外した形だけで見ると、既定の登録（一時停止の門番＝
  -- PreToolUse の配達用 hook がある）が「余分な組がある」で outdated になり、s が必ず断られる
  local ok, st = pcall(hooks.status)
  if not ok then return true end
  if st ~= "installed" then
    local ok2, st2 = pcall(hooks.status, nil, nil, false)
    if not ok2 then return true end
    if st2 ~= "installed" then return false end
  end
  -- 届け方（--mode）が設定と同じか。features().mode が無い（読めない）ときは組の一致だけで決める
  if type(hooks.features) == "function" then
    local okf, f = pcall(hooks.features)
    if okf and type(f) == "table" and type(f.mode) == "string" and f.mode ~= M.steer_cfg().mode then
      return false
    end
  end
  return true
end

--- True when the run on screen has ended (SessionEnd recorded). Its Claude is gone; a terminal
--- found by folder would belong to another conversation, so nothing is sent to it.
local function run_ended()
  local s = M.run and M.run.state
  return type(s) == "table" and s.ended_at ~= nil
end

local function request(ev, agent_id, text, opts)
  local ok, id, err = pcall(ev.request_steer, M.run, agent_id, text, opts)
  if not ok then return nil, id end
  return id, err
end

local function after_steer()
  pcall(M.refresh, { aux = true })
end

-- 端末が無いとき（steer.no_terminal）。pre(steer_id) は指示を置いた直後に 1 回呼ぶ（止まっている ROOT を解く）
local function no_terminal(ev, cfg, agent_id, hook_text, line, opts, pre)
  local how = cfg.no_terminal or "stop"
  if how == "stop" or how == "hook" then
    if not M.steer_hooks_ok() then
      notify(st_text("ui.steer_hooks_outdated"), vim.log.levels.WARN)
      return "outdated"
    end
    local id = request(ev, agent_id, hook_text, vim.tbl_extend("force", opts, { via = "hook" }))
    if id and pre then pre(id) end
    local own = agent_id == "ROOT" and (opts.kind or "steer") == "steer"
    notify(st_text(own and "ui.steer_queued_root_stop" or "ui.steer_no_terminal_hook"))
    after_steer()
    return id and "fallback_hook" or nil
  elseif how == "clipboard" then
    pcall(vim.fn.setreg, "+", line)
    pcall(vim.fn.setreg, '"', line)
    -- 送れたかは分からないので PENDING のまま（作者が s → 取り消しで消す）
    request(ev, agent_id, hook_text, vim.tbl_extend("force", opts, { via = "terminal" }))
    if pre then pre(nil) end -- 貼り付けた文が読まれるように、止まっている ROOT は解く
    notify(t("ui.steer_no_terminal_clip"))
    after_steer()
    return "clipboard"
  end
  notify(t("ui.steer_no_terminal_none"), vim.log.levels.WARN)
  return "none"
end

-- ROOT の Claude の端末を選ぶ。found(cand, term) か none(cancelled) を 1 回だけ呼ぶ。
-- 同点なら選ばせる（no_pick = true なら選ばせずに none）。前に選んだ端末がまだあればそれを使う
local function pick_terminal(found, none, no_pick)
  local term = try_require("agentmap.term")
  if not term then return none(false) end
  local s = M.run and M.run.state or {}
  local cand, list, tied = term.find(s.cwd or vim.fn.getcwd())
  local sid = M.run and M.run.sid or "?"
  local remembered = M.term_choice[sid]
  if remembered then
    for _, c in ipairs(list or {}) do
      if c.buf == remembered then cand, tied = c, false end
    end
  end
  if cand then return found(cand, term) end
  if tied and list and #list > 0 and not no_pick then
    vim.ui.select(list, {
      prompt = t("ui.steer_pick_terminal"),
      format_item = function(c) return vim.api.nvim_buf_get_name(c.buf) end,
    }, function(choice)
      if not choice then return none(true) end
      M.term_choice[sid] = choice.buf
      found(choice, term)
    end)
    return
  end
  return none(false)
end

--- True when this Neovim has a :terminal running Claude for the run on screen (the best match,
--- or several to pick from). Used to offer "send to the terminal" and "relay" (DESIGN-v0.1.2-steer2 §4.1).
function M.terminal_present()
  local term = try_require("agentmap.term")
  if not term or type(term.find) ~= "function" then return false end
  local s = M.run and M.run.state or {}
  local ok, cand, list = pcall(term.find, s.cwd or vim.fn.getcwd())
  if not ok then return false end
  return cand ~= nil or (type(list) == "table" and #list > 0)
end

-- 端末へ送る。cb(result) は同点の端末を選ばせたときも最後に 1 回呼ぶ。
-- no_pick = true（自動で送る親への知らせ）なら、同点でも選ばせずに落とし先へ。
-- pre(steer_id) は打つ直前（端末が無ければ落とし先で指示を置いた直後）に呼ぶ
local function via_terminal(ev, cfg, agent_id, hook_text, opts, cb, no_pick, pre)
  local line = STEER_PREFIX .. hook_text
  pick_terminal(function(cand, term)
    local id, err = request(ev, agent_id, hook_text, vim.tbl_extend("force", opts, { via = "terminal" }))
    -- 同じ指示の知らせが（別の Neovim で）もう作られていた：端末にも打たない
    if not id and err == "duplicate" then return cb(nil) end
    if pre then pre(nil) end
    local ok = term.send(cand.job, line, { delay_ms = cfg.submit_delay_ms })
    if ok then
      if id and ev.mark_steer_sent then pcall(ev.mark_steer_sent, M.run, id) end
      notify(t("ui.steer_sent"))
      after_steer()
      return cb("sent")
    end
    -- 送れなかった（端末が直前に終わった）。置いた要求は取り消して、落とし先へ
    if id and ev.cancel_steer then pcall(ev.cancel_steer, M.run, id) end
    return cb(no_terminal(ev, cfg, agent_id, hook_text, line, opts, pre))
  end, function(cancelled)
    if cancelled then return cb(nil) end
    return cb(no_terminal(ev, cfg, agent_id, hook_text, line, opts, pre))
  end, no_pick)
end

--- True when box `id` may be steered through the main agent (relay; DESIGN-v0.1.2-steer2 §4.1,
--- V41, Q19/Q21): `steer.relay` is not "never", the run has not ended, and the box is a direct
--- sub-agent of ROOT that has not finished (a grandchild, ROOT itself, a finished box and a box
--- waiting at the gate are not offered). The terminal is checked separately (terminal_present).
function M.relay_target_ok(id)
  if M.steer_cfg().relay == "never" then return false end
  if type(id) ~= "string" or id == "ROOT" or run_ended() then return false end
  local a = M.run and M.run.state and M.run.state.agents and M.run.state.agents[id]
  if type(a) ~= "table" or a.parent_id ~= "ROOT" or FINISHED[a.status] then return false end
  local p = M._live_pause(id)
  if p and p.kind == "gate" and p.status == "PAUSED" then return false end
  return true
end

--- True when the `s` menu offers "relay now through the main agent" for box `id`.
function M.relay_available(id)
  return M.relay_target_ok(id) and M.terminal_present()
end

--- The line typed into the main agent's terminal for a relay, without the leading "[AgentMap] "
--- (steer.relay_en / steer.relay_ja by the UI language; DESIGN-v0.1.2-steer2 §4.2).
function M.relay_text(id, text)
  local a = (M.run and M.run.state and M.run.state.agents and M.run.state.agents[id]) or agent_of(id) or {}
  local term = try_require("agentmap.term")
  local body = term and term.sanitize(text) or tostring(text or "")
  local vars = { index = a.index or "?", name = graph.util.truncate(a.name or a.task or id, 40), id = id, text = body }
  local out = st_text("steer.relay_" .. (i18n.lang == "ja" and "ja" or "en"), vars)
  if out:sub(1, #STEER_PREFIX) == STEER_PREFIX then out = out:sub(#STEER_PREFIX + 1) end
  return out
end

-- 残りの時間の目安（進み具合の推定が時間を出せるときだけ。DESIGN-v0.1.2-steer2 §7.5）。無ければ ""
local function eta_suffix(aid)
  local s = M.run and M.run.state
  local progress = try_require("agentmap.progress")
  if type(s) ~= "table" or not progress or type(progress.compute) ~= "function" then return "" end
  local ok, r = pcall(progress.compute, s, aid, {
    now = M.clock(), stats = M.view and M.view.stats, config = M.progress_cfg(), flow_id = M.flow_id,
  })
  if not ok or type(r) ~= "table" or not r.estimated or r.over then return "" end
  local d, left = tonumber(r.expected_ms), nil
  if d and d > 0 then
    if r.basis == "time" and tonumber(r.cur_elapsed_ms) then
      left = d - r.cur_elapsed_ms
    elseif (r.basis == "tasks" or r.basis == "steps") and tonumber(r.n) and tonumber(r.k) then
      left = (r.n - r.k - (tonumber(r.f) or 0)) * d
    end
  end
  if not left or left < 1000 then return "" end
  local secs = math.floor(left / 1000 + 0.5)
  local txt = secs < 60 and (secs .. " s") or (math.floor(secs / 60 + 0.5) .. " min")
  return st_text("ui.steer_queued_eta", { left = txt })
end
M._eta_suffix = eta_suffix

-- 親経由（relay）：ROOT の端末に「子へ SendMessage で伝えて」と打つ（DESIGN-v0.1.2-steer2 §4）
local function via_relay(ev, cfg, aid, text, prompt_id, done)
  if not M.relay_target_ok(aid) then
    if run_ended() then
      notify(t("ui.steer_run_ended"), vim.log.levels.WARN)
      return done("ended")
    end
    notify(st_text("ui.steer_relay_not_target"), vim.log.levels.WARN)
    return done("not_target")
  end
  pick_terminal(function(cand, term)
    local line = term.sanitize(STEER_PREFIX .. M.relay_text(aid, text))
    local sid = request(ev, aid, text, { via = "relay", relay_line = line, kind = "steer", prompt_id = prompt_id })
    if not sid then
      notify(t("ui.steer_disabled"), vim.log.levels.WARN)
      return done(nil)
    end
    if not term.send(cand.job, line, { delay_ms = cfg.submit_delay_ms }) then
      if ev.cancel_steer then pcall(ev.cancel_steer, M.run, sid) end
      notify(st_text("ui.steer_relay_no_terminal"), vim.log.levels.WARN)
      return done("no_terminal")
    end
    if ev.mark_steer_sent then pcall(ev.mark_steer_sent, M.run, sid) end
    -- 止まっている子は、伝言を次の道具の切れ目で受け取れるように止まれを解く。止まれを置いただけ（REQUESTED）の
    -- 子は取り下げる（残すと次の道具の直前で止まり、伝言は再開まで届かない。hooks の経路と同じ扱い）。関門は残す
    local p = M._live_pause(aid)
    if p and (p.status == "PAUSED" or p.status == "REQUESTED") and p.kind ~= "gate" then
      M._resume_raw(aid, { reason = "user" })
    end
    notify(st_text("ui.steer_relay_sent"))
    after_steer()
    return done("relayed")
  end, function(cancelled)
    if cancelled then return done(nil) end
    notify(st_text("ui.steer_relay_no_terminal"), vim.log.levels.WARN)
    return done("no_terminal")
  end)
end

--- Send a steering instruction `text` for box `id`, choosing the route from the box
--- (DESIGN-v0.1.2-steer2 §2): a sub-agent gets it when it tries to finish (a file its SubagentStop
--- hook hands over; a paused one is resumed first, one waiting at the gate gets it right away);
--- ROOT gets it in its terminal (a ROOT paused before a tool call is resumed first; without a
--- terminal, at the end of its turn); a finished agent is redone by asking ROOT in its terminal.
--- With `opts.route = "relay"` it is typed into ROOT's terminal for ROOT to pass on with SendMessage.
---@param id string agent id (gate: ids are accepted)
---@param text string
---@param cb? fun(result: string|nil) "queued" | "sent" | "relayed" | "fallback_hook" | "clipboard"
---   | "none" | "empty" | "outdated" (hooks route, but the registered hooks are outdated or use another
---   mode: nothing sent) | "ended" (terminal route, but the run has ended: nothing sent)
---   | "no_terminal" / "not_target" (relay not possible) | nil
---@param opts? { route?: "relay" }
---@return string|nil result (nil while waiting for the user to pick a terminal)
function M.steer_send(id, text, cb, opts)
  opts = opts or {}
  local result
  local function done(r)
    result = r
    if cb then cb(r) end
    return r
  end
  local cfg = M.steer_cfg()
  if not cfg.enabled then
    notify(t("ui.steer_disabled"))
    return done(nil)
  end
  local aid = M.steer_target(id)
  if not aid then
    notify(t("ui.steer_not_target"), vim.log.levels.WARN)
    return done(nil)
  end
  text = vim.trim(tostring(text or ""))
  if text == "" then
    notify(t("ui.steer_empty"))
    return done("empty")
  end
  local max = tonumber(cfg.text_max) or 4000
  if vim.fn.strchars(text) > max then text = vim.fn.strcharpart(text, 0, max) end
  local ev = events_mod()
  if not ev or not M.run then
    notify(t("ui.steer_disabled"), vim.log.levels.WARN)
    return done(nil)
  end
  local s = M.run.state
  local prompt_id = M.flow_id or (s and state_mod.latest_flow_id(s)) or nil
  if opts.route == "relay" then
    via_relay(ev, cfg, aid, text, prompt_id, done)
    return result
  end
  local kind = M.steer_kind(aid)
  -- hooks で届ける経路：登録が古い・届け方が違うと終わり際に届かないので、送らずに知らせる（Q22。端末へ送る経路は関係ない）
  if kind == "hook" or (kind == "root" and cfg.root_via == "hook") then
    if not M.steer_hooks_ok() then
      notify(st_text("ui.steer_hooks_outdated"), vim.log.levels.WARN)
      return done("outdated")
    end
  end
  -- 端末へ送る経路：実行が終わっていれば、同じフォルダの別の会話の端末に送ることになるので止める
  if (kind == "root" or kind == "redo") and run_ended() then
    notify(t("ui.steer_run_ended"), vim.log.levels.WARN)
    return done("ended")
  end
  if kind == "hook" then
    local held = M._live_pause(aid)
    local held_status = held and held.status
    -- 関門・ROOT の Stop で止まっている：待っている hook がその場で渡す。PreToolUse で止まっている子：解いて続けさせ、終わり際に届く
    local at_end = held and (held.kind == "gate" or not tostring(held.hit_via or ""):find("^PreToolUse"))
    local sid = request(ev, aid, text, { via = "hook", kind = "steer", prompt_id = prompt_id })
    if not sid then
      notify(t("ui.steer_disabled"), vim.log.levels.WARN)
      return done(nil)
    end
    -- 止まれのある宛先：指示のファイルを置いた**後で**止まれを消す（hook は止まれが消えた後に指示を取りに行く）
    if held and M._resume_raw(aid, { reason = "user", steer_id = sid }) and held_status == "PAUSED" then
      if at_end then
        notify(pt("ui.pause_resumed_with", { label = label_of(aid) }))
      else
        notify(st_text("ui.steer_resumed_stop", { label = label_of(aid) }))
      end
    else
      notify(st_text("ui.steer_queued", { label = label_of(aid) }) .. eta_suffix(aid))
    end
    after_steer()
    return done("queued")
  end
  if kind == "root" then
    local opts2 = { kind = "steer", prompt_id = prompt_id }
    -- 次の道具の直前で止まっている ROOT（Q23）：止まれを解いてから端末へ打つ（端末が無ければ指示を置いてから解く → 番の終わりに届く）
    local pre
    if M._live_pause("ROOT") then
      local released = false
      pre = function(steer_id)
        if released then return end
        released = true
        if M._resume_raw("ROOT", { reason = "user", steer_id = steer_id }) then
          notify(pt("ui.pause_resumed", { label = "ROOT" }))
        end
      end
    end
    if cfg.root_via == "hook" then
      local sid = request(ev, "ROOT", text, vim.tbl_extend("force", opts2, { via = "hook" }))
      if sid and pre then pre(sid) end
      notify(st_text("ui.steer_queued", { label = "ROOT" }))
      after_steer()
      return done("queued")
    end
    via_terminal(ev, cfg, "ROOT", text, opts2, done, false, pre)
    return result
  end
  -- 終わった箱：親（ROOT）の端末へやり直しの依頼。差し戻し（REWORK）は記録しない（親が決める）
  via_terminal(ev, cfg, "ROOT", M.redo_text(aid, text), { kind = "redo", redo_of = aid, prompt_id = prompt_id }, done)
  return result
end

local input_seq = 0

-- 止まれが「終わり際」で握っているか（関門・ROOT の Stop）。PreToolUse で止まっているなら false
local function held_at_end(p)
  return p ~= nil and p.status == "PAUSED" and (p.kind == "gate" or not tostring(p.hit_via or ""):find("^PreToolUse"))
end

-- 入力の窓の題（DESIGN-v0.1.2-steer2 §7.1）
local function input_title(aid, kind, route)
  local label = label_of(aid)
  if route == "relay" then return st_text("ui.steer_prompt_relay", { label = label }) end
  if kind == "root" then
    if M.steer_cfg().root_via ~= "hook" and M.terminal_present() then
      return t("ui.steer_prompt", { label = "ROOT (terminal)" })
    end
    return st_text("ui.steer_prompt_stop", { label = "ROOT" })
  end
  if kind == "redo" then return t("ui.steer_prompt", { label = label }) end
  local p = M._live_pause(aid)
  if held_at_end(p) then return t("ui.steer_prompt", { label = label }) end
  if p and p.status == "PAUSED" then return st_text("ui.steer_prompt_resume", { label = label }) end
  return st_text("ui.steer_prompt_stop", { label = label })
end

--- Open the instruction editor for `id` (a small floating window; steer.input = "line" uses
--- vim.ui.input). <C-s>, :w or <CR> in normal mode sends, q / <Esc> cancels.
---@param on_submit? fun(text: string) default: M.steer_send(id, text, nil, { route = route })
---@param route? "relay" relay through the main agent (DESIGN-v0.1.2-steer2 §4); refused when not possible
---@return integer|nil buf, integer|nil win
function M.steer_input(id, on_submit, route)
  local aid = M.steer_target(id)
  if not aid then
    notify(t("ui.steer_not_target"), vim.log.levels.WARN)
    return nil
  end
  if route == "relay" then
    if not M.relay_target_ok(aid) then
      notify(st_text(run_ended() and "ui.steer_run_ended" or "ui.steer_relay_not_target"), vim.log.levels.WARN)
      return nil
    end
    if not M.terminal_present() then
      notify(st_text("ui.steer_relay_no_terminal"), vim.log.levels.WARN)
      return nil
    end
  end
  on_submit = on_submit or function(text) M.steer_send(aid, text, nil, { route = route }) end
  local cfg = M.steer_cfg()
  local kind = M.steer_kind(aid)
  local title = input_title(aid, kind, route)
  if cfg.input == "line" then
    vim.ui.input({ prompt = title .. ": " }, function(text)
      if text == nil then return end
      on_submit(text)
    end)
    return nil
  end
  local hint = t("ui.steer_hint")
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "acwrite"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  input_seq = input_seq + 1
  pcall(vim.api.nvim_buf_set_name, b, "agentmap://steer/" .. aid .. "/" .. input_seq)
  vim.bo[b].filetype = "markdown"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { hint, "" })
  vim.bo[b].modified = false
  pcall(vim.api.nvim_buf_set_extmark, b, renderer.ns, 0, 0, { end_col = #hint, hl_group = "AgentMapDim" })
  vim.b[b].agentmap_steer_target = aid
  vim.b[b].agentmap_steer_kind = route == "relay" and "relay" or kind
  local width = math.max(20, math.min(80, vim.o.columns - 4))
  local height = math.max(3, math.min(6, vim.o.lines - 4))
  local win = vim.api.nvim_open_win(b, true, {
    relative = "editor", width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal", border = "rounded", title = " " .. title .. " ", title_pos = "center",
  })
  pcall(vim.api.nvim_set_option_value, "wrap", true, { win = win, scope = "local" })
  pcall(vim.api.nvim_win_set_cursor, win, { 2, 0 })
  local finished = false
  local function close(later)
    local function go()
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
      if vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
    if later then vim.schedule(go) else go() end
  end
  local function submit(later)
    if finished then return end
    finished = true
    local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    if lines[1] == hint then table.remove(lines, 1) end
    local text = vim.trim(table.concat(lines, "\n"))
    vim.bo[b].modified = false
    pcall(vim.cmd, "stopinsert")
    close(later)
    if text == "" then
      notify(t("ui.steer_empty"))
      return
    end
    on_submit(text)
  end
  local function cancel()
    if finished then return end
    finished = true
    close(false)
  end
  local o = { buffer = b, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", function() submit(false) end, o)
  vim.keymap.set({ "n", "i" }, "<C-s>", function() submit(true) end, o)
  vim.keymap.set("n", "q", cancel, o)
  vim.keymap.set("n", "<Esc>", cancel, o)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = b,
    callback = function() submit(true) end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() finished = true end,
  })
  pcall(vim.cmd, "startinsert")
  return b, win
end

--- `s` on a box (DESIGN-v0.1.2-steer2 §7.1, Q19): write an instruction (a sub-agent gets it when it
--- tries to finish; a paused one is resumed; ROOT gets it in its terminal, or at the end of its turn
--- without one) or ask the parent to redo a finished box; for a running direct sub-agent of ROOT,
--- when ROOT's terminal is here, also "relay now through the main agent" (first with
--- steer.relay = "always"); cancel pending instructions; show the steering history.
function M.steer_menu(id)
  local cfg = M.steer_cfg()
  if not cfg.enabled then
    notify(t("ui.steer_disabled"))
    return
  end
  local aid = M.steer_target(id)
  if not aid then
    notify(t("ui.steer_not_target"), vim.log.levels.WARN)
    return
  end
  local kind = M.steer_kind(aid)
  -- 終わった実行の ROOT・やり直し：端末へは送らない（別の会話の端末に入る）。書かせる前に止める
  if (kind == "root" or kind == "redo") and run_ended() then
    notify(t("ui.steer_run_ended"), vim.log.levels.WARN)
    return
  end
  local first
  if kind == "redo" then
    first = t("ui.steer_redo")
  elseif kind == "root" then
    local term_ok = cfg.root_via ~= "hook" and M.terminal_present()
    first = (term_ok or cfg.no_terminal ~= "stop") and t("ui.steer_terminal") or st_text("ui.steer_write_root_stop")
  else
    local p = M._live_pause(aid)
    if held_at_end(p) then
      first = st_text("ui.steer_write_gate")
    elseif p and p.status == "PAUSED" then
      first = st_text("ui.steer_write_resume")
    elseif aid == "ROOT" then
      first = st_text("ui.steer_write_root_stop")
    else
      first = t("ui.steer_write")
    end
  end
  local items, acts = { first }, { "write" }
  if M.relay_available(aid) then
    if cfg.relay == "always" then
      table.insert(items, 1, st_text("ui.steer_relay"))
      table.insert(acts, 1, "relay")
    else
      items[#items + 1] = st_text("ui.steer_relay")
      acts[#acts + 1] = "relay"
    end
  end
  local pend = pending_of(aid)
  if #pend > 0 then
    items[#items + 1] = t("ui.steer_cancel_n", { n = #pend })
    acts[#acts + 1] = "cancel"
  end
  items[#items + 1] = t("ui.steer_show")
  acts[#acts + 1] = "show"
  vim.ui.select(items, { prompt = t("ui.steer_prompt", { label = label_of(aid) }) }, function(_, idx)
    local act = idx and acts[idx]
    if act == "write" then
      M.steer_input(aid)
    elseif act == "relay" then
      M.steer_input(aid, nil, "relay")
    elseif act == "cancel" then
      M.steer_cancel(aid)
    elseif act == "show" then
      M.open_steers(aid)
    end
  end)
end

--- Cancel a pending instruction of `id` (asks which one when there are several).
function M.steer_cancel(id)
  local ev = try_require("agentmap.events")
  if not ev or not ev.cancel_steer or not M.run then return end
  local pend = pending_of(id)
  if #pend == 0 then return end
  local function cancel(sid)
    pcall(ev.cancel_steer, M.run, sid)
    notify(t("ui.steer_cancelled"))
    after_steer()
  end
  if #pend == 1 then return cancel(pend[1]) end
  local steers = M.run.state.steers
  vim.ui.select(pend, {
    prompt = t("ui.steer_cancel_n", { n = #pend }),
    format_item = function(sid)
      local st = steers[sid] or {}
      return graph.util.truncate(tostring(st.text or sid):gsub("[\r\n]+", " "), 60)
    end,
  }, function(sid)
    if sid then cancel(sid) end
  end)
end

-- 開いた時点でもう「届かなかった」指示は知らせない
function M._seed_expired()
  local s = M.run and M.run.state
  local sid = M.run and M.run.sid
  if not sid then return end
  local seen, done, relayed = {}, {}, {}
  for k, st in pairs(s and type(s.steers) == "table" and s.steers or {}) do
    if st.status == "EXPIRED" then seen[k] = true end
    -- 開いた時点でもう届いていた指示の知らせは、今さら作らない（見ていない間のことは分からない）
    if st.status == "DELIVERED" then done[k] = true end
    if st.relayed_at or (st.status == "DELIVERED" and st.via ~= "relay") then relayed[k] = true end
  end
  expired_seen[sid] = seen
  notice_done[sid] = done
  relay_seen[sid] = relayed
end

--- Notify (once each) steering instructions that expired without being delivered.
function M.notify_expired()
  local s = M.run and M.run.state
  local sid = M.run and M.run.sid
  if not s or not sid or type(s.steers) ~= "table" then return end
  local seen = expired_seen[sid]
  if not seen then
    M._seed_expired()
    return
  end
  for k, st in pairs(s.steers) do
    if st.status == "EXPIRED" and not seen[k] then
      seen[k] = true
      if st.end_reason == "not_relayed" then
        notify(st_text("ui.steer_not_relayed", { label = label_of(st.agent_id) }), vim.log.levels.WARN)
      else
        notify(t("ui.steer_expired_notice", { label = label_of(st.redo_of or st.agent_id) }), vim.log.levels.WARN)
      end
    end
  end
end

-- 終わり際の配達（Stop / SubagentStop の hook が渡した）か
local function delivered_at_end(st)
  if st.mode == "block" then return true end
  local v = tostring(st.delivered_via or "")
  return v == "Stop" or v == "SubagentStop" or v:find("Stop$") ~= nil
end

--- Notify (once each) what the records show about instructions since the map was opened
--- (DESIGN-v0.1.2-steer2 §7.5): the main agent passed a relayed instruction on (SendMessage), and
--- a sub-agent's instruction was handed over at its end. Silent for what happened before opening.
---@return integer number of notices
function M.notify_relays()
  local s = M.run and M.run.state
  local sid = M.run and M.run.sid
  if not s or not sid or type(s.steers) ~= "table" then return 0 end
  local seen = relay_seen[sid]
  if not seen then
    M._seed_expired()
    return 0
  end
  local n = 0
  for k, st in pairs(s.steers) do
    if type(st) == "table" and not seen[k] then
      if st.via == "relay" and st.relayed_at then
        seen[k] = true
        notify(st_text("ui.steer_relayed", { label = label_of(st.agent_id) }))
        n = n + 1
      elseif st.via ~= "relay" and st.status == "DELIVERED" then
        seen[k] = true
        if st.via == "hook" and (st.kind or "steer") == "steer" and delivered_at_end(st) then
          notify(st_text("ui.steer_delivered_stop", { label = label_of(st.agent_id) }))
          n = n + 1
        end
      end
    end
  end
  return n
end

-- 親への知らせの文（i18n の鍵が無ければ英語の既定の文）。先頭の [AgentMap] は送るときに付ける
local NOTICE_FALLBACK = 'The user sent this instruction directly to your sub-agent [%{index}] "%{name}" (id %{id}): %{text}. If it also affects other sub-agents or your plan, update them.'
function M.notice_text(child_id, text)
  local a = (M.run and M.run.state and M.run.state.agents and M.run.state.agents[child_id]) or agent_of(child_id) or {}
  local vars = {
    index = a.index or "?", name = graph.util.truncate(a.name or a.task or child_id, 40), id = child_id,
    text = text or "",
  }
  local key = "steer.notice_to_parent"
  local out
  if i18n.has(key) or i18n.has(key, "en") then
    out = t(key, vars)
  else
    out = NOTICE_FALLBACK:gsub("%%{([%w_]+)}", function(k) return tostring(vars[k]) end)
  end
  if out:sub(1, #STEER_PREFIX) == STEER_PREFIX then out = out:sub(#STEER_PREFIX + 1) end
  return out
end

--- Tell the parent about instructions that were delivered directly to its sub-agent
--- (DESIGN-v0.2-steer.md appendix E): once per instruction, only for deliveries seen while the
--- map was open, not when the parent has finished. A parent that is ROOT gets it like any ROOT
--- instruction (terminal, else hooks); a parent that is a sub-agent gets it through hooks.
---
--- "Once" is checked in three places, so two Neovims showing the same run still make one notice:
---   1. this Neovim's memory (notice_done): instructions it already handled or decided to skip;
---   2. the state, after catching up with the records (events.poll): an instruction whose
---      `notice_id` is set, or a notice whose `notice_of` names it, was already told, by whoever
---      wrote that record;
---   3. events.request_steer itself, which catches up once more right before writing and refuses
---      a notice for an instruction that already has one ("duplicate").
---@return integer number of notices created
function M.notify_parents()
  local s = M.run and M.run.state
  local sid = M.run and M.run.sid
  if not s or not sid or type(s.steers) ~= "table" then return 0 end
  local ev = events_mod()
  if not ev then return 0 end
  local cfg = M.steer_cfg()
  if not cfg.enabled then return 0 end
  local done = notice_done[sid]
  if not done then
    M._seed_expired()
    return 0
  end
  -- 記録に追いつく：別の Neovim が同じ run を開いて先に知らせを作っていれば、ここで state に入る
  if ev.poll then pcall(ev.poll, M.run) end
  s = M.run.state
  if type(s.steers) ~= "table" then return 0 end
  -- 既に知らせがある指示（state の notice_id、または記録に残った知らせの notice_of）
  for k, st in pairs(s.steers) do
    if st.notice_id then done[k] = true end
    if st.kind == "notice" and st.notice_of then done[st.notice_of] = true end
  end
  local n = 0
  for k, st in pairs(s.steers) do
    -- 親経由（relay）は親自身が渡したので知らせない（V44）
    if st.status == "DELIVERED" and not done[k] and st.via ~= "relay" then
      done[k] = true
      local child = st.agent_id
      local kind = st.kind or "steer"
      local a = child and s.agents and s.agents[child]
      local parent = a and (a.parent_id or "ROOT")
      local pa = parent and s.agents and s.agents[parent]
      if kind == "steer" and child ~= "ROOT" and a and pa and not FINISHED[pa.status]
        and parent ~= "UNKNOWN_PARENT" and parent:sub(1, 3) ~= "wf:" then
        local text = M.notice_text(child, st.text)
        local opts = { kind = "notice", notice_of = k, prompt_id = st.prompt_id }
        local made
        if parent == "ROOT" then
          if cfg.root_via == "hook" then
            made = request(ev, "ROOT", text, vim.tbl_extend("force", opts, { via = "hook" })) ~= nil
          else
            -- 端末が無いときの落とし先（hooks）も request を通るので、二重なら作られない
            local SENT = { sent = true, fallback_hook = true, clipboard = true }
            via_terminal(ev, cfg, "ROOT", text, opts, function(r) made = SENT[r] == true end, true)
          end
        else
          made = request(ev, parent, text, vim.tbl_extend("force", opts, { via = "hook" })) ~= nil
        end
        if made then n = n + 1 end
      end
    end
  end
  return n
end

--- Expire undelivered instructions whose agent finished (events.sweep_steers), tell the user,
--- and pass delivered instructions on to the parent (notify_parents).
---@return boolean changed
function M.sweep_steers()
  local ev = try_require("agentmap.events")
  local changed = false
  if ev and ev.sweep_steers and M.run then
    local ok, r = pcall(ev.sweep_steers, M.run)
    changed = ok and r == true
  end
  M.notify_expired()
  pcall(M.notify_relays)
  local ok, n = pcall(M.notify_parents)
  if ok and n and n > 0 then changed = true end
  return changed
end

-- ------------------------------------------------------------
-- 一時停止と関門（DESIGN-v0.1.2-pause §4・§5.4・§6、付録 D の本人の答え）
--   x  = 止める（次の道具の直前か終わる直前の早い方）／もう 1 回で再開。メニューは出さない。
--        関門で終わる前に止まっている箱（[GATE]）だけ「通す／直す」のメニュー。
--   X  = 見ている run の関門の入／切。
--   止まっている子に s で書いた指示は、止まれを外して続けさせ、終わり際に届く（関門で止まっている子・
--   Stop で止まっている ROOT にはその場で届く。DESIGN-v0.1.2-steer2 §5）。
-- ------------------------------------------------------------
local PAUSE_DEFAULTS = { enabled = true, auto_resume_s = 600, gate = false, release_on_exit = false, notify = true }
local LIVE_PAUSE = { REQUESTED = true, PAUSED = true }

--- Effective pause settings (config.get().pause; false = { enabled = false }).
function M.pause_cfg()
  local ok, config = pcall(require, "agentmap.config")
  local raw = nil
  if ok then raw = config.get().pause end
  if raw == false then return vim.tbl_extend("force", PAUSE_DEFAULTS, { enabled = false }) end
  if type(raw) ~= "table" then return vim.deepcopy(PAUSE_DEFAULTS) end
  return vim.tbl_extend("force", PAUSE_DEFAULTS, raw)
end

--- The live pause (REQUESTED or PAUSED) of agent `id` in the run on screen, or nil.
--- Uses state.pause_of; the same rule is kept here as a fallback.
function M._live_pause(id)
  local s = M.run and M.run.state
  if type(s) ~= "table" or type(id) ~= "string" then return nil end
  if state_mod.pause_of then
    local ok, p = pcall(state_mod.pause_of, s, id)
    if ok then return p end
  end
  if type(s.pauses) ~= "table" then return nil end
  local a = s.agents and s.agents[id]
  local p = a and a.pause and s.pauses[a.pause]
  if type(p) == "table" and LIVE_PAUSE[p.status] then return p end
  for _, q in pairs(s.pauses) do
    if type(q) == "table" and q.agent_id == id and LIVE_PAUSE[q.status] then return q end
  end
  return nil
end

-- events のうち一時停止の関数（W1）。無ければ nil
local function pause_events(fn)
  local ev = try_require("agentmap.events")
  if not ev or type(ev[fn or "request_pause"]) ~= "function" then return nil end
  return ev
end

--- True when the registered hooks can pause: hooks.status() is "installed", which in v0.1.2 also
--- means the delivery hooks carry --pause and a long timeout (steering only needs the (event, matcher) pairs).
function M.pause_hooks_ok()
  local hooks = try_require("agentmap.hooks")
  if not hooks or type(hooks.status) ~= "function" then return true end
  local ok, st = pcall(hooks.status)
  if not ok then return true end
  return st == "installed"
end

-- 秒 → "10:00"（自動再開までの長さ）
local function mmss(secs) return graph.util.fmt_elapsed((tonumber(secs) or 600) * 1000) end

-- ミリ秒 → "10 min" / "2 min 31 s" / "45 s"
local function dur_text(ms)
  local s = math.floor((tonumber(ms) or 0) / 1000 + 0.5)
  local m = math.floor(s / 60)
  s = s % 60
  if m == 0 then return s .. " s" end
  if s == 0 then return m .. " min" end
  return m .. " min " .. s .. " s"
end
M._dur_text = dur_text

-- 時刻（epoch 秒・epoch ミリ秒・ISO の文字列）→ "HH:MM:SS"
local function clock_of(v)
  local secs = type(v) == "number" and v or (type(v) == "string" and graph.util.parse_iso(v)) or nil
  if not secs then return "-" end
  if secs > 1e11 then secs = secs / 1000 end
  return os.date("%H:%M:%S", math.floor(secs))
end

-- 止まった時刻 + 自動再開の秒数（deadline が無いとき）
local function deadline_of(p)
  if p.deadline then return p.deadline end
  local hit = p.hit_at and graph.util.parse_iso(p.hit_at)
  if hit then return hit + (tonumber(p.auto_resume_s) or M.pause_cfg().auto_resume_s or 600) end
  return nil
end

-- events.resume_pause を呼ぶだけ（知らせない）。成功なら true
function M._resume_raw(aid, opts)
  local ev = pause_events("resume_pause")
  if not ev or not M.run then return false end
  local ok, r, err = pcall(ev.resume_pause, M.run, aid, opts or { reason = "user" })
  if ok and r then return true end
  return false, ok and err or r
end

-- 今の止まれの様子を言い直す（:AgentMapPause を重ねて打ったとき）
local function restate(aid, p)
  local cfg = M.pause_cfg()
  local label = label_of(aid)
  if p.status == "PAUSED" then
    if p.kind == "gate" then return notify(pt("ui.pause_hit_gate", { label = label, time = clock_of(deadline_of(p)) })) end
    return notify(pt("ui.pause_hit", { label = label, via = p.hit_via or "?", time = clock_of(deadline_of(p)) }))
  end
  local key = p.at == "stop" and "ui.pause_requested_stop" or "ui.pause_requested"
  notify(pt(key, { label = label, min = mmss(p.auto_resume_s or cfg.auto_resume_s) }))
end

--- Place a pause for box `id`: it stops at its next tool call or when it finishes (at = "next",
--- the default), or only when it finishes (at = "stop"). Refused for boxes that cannot be paused,
--- an ended run, `pause.enabled = false`, and outdated hooks.
---@param id string map id (gate: ids are accepted)
---@param at? "next"|"stop"
---@param opts? { replace?: boolean } withdraw the live pause first (a gate request replaced by a pause)
---@return string|nil pause_id, string|nil err
function M.pause_request(id, at, opts)
  opts = opts or {}
  at = at == "stop" and "stop" or "next"
  local cfg = M.pause_cfg()
  if not cfg.enabled then
    notify(pt("ui.pause_disabled"))
    return nil, "disabled"
  end
  local aid = M.steer_target(id)
  if not aid then
    notify(pt("ui.pause_not_target"), vim.log.levels.WARN)
    return nil, "bad_target"
  end
  if run_ended() then
    notify(pt("ui.pause_run_ended"), vim.log.levels.WARN)
    return nil, "ended"
  end
  local a = M.run and M.run.state and M.run.state.agents and M.run.state.agents[aid]
  if a and aid ~= "ROOT" and FINISHED[a.status] and not M._live_pause(aid) then
    notify(pt("ui.pause_not_target"), vim.log.levels.WARN)
    return nil, "finished"
  end
  if not M.pause_hooks_ok() then
    notify(pt("ui.pause_hooks_outdated"), vim.log.levels.WARN)
    return nil, "outdated"
  end
  local ev = pause_events("request_pause")
  if not ev or not M.run then
    notify(pt("ui.pause_failed", { label = label_of(aid), err = "events.request_pause is missing" }), vim.log.levels.WARN)
    return nil, "unavailable"
  end
  if opts.replace and M._live_pause(aid) then M._resume_raw(aid, { reason = "user" }) end
  local s = M.run.state
  local prompt_id = M.flow_id or (s and state_mod.latest_flow_id(s)) or nil
  local ok, pid, err = pcall(ev.request_pause, M.run, aid, { at = at, kind = "pause", prompt_id = prompt_id })
  if not ok or not pid then
    err = ok and err or pid
    if err == "finished" or err == "bad_target" then
      notify(pt("ui.pause_not_target"), vim.log.levels.WARN)
    elseif err == "ended" then
      notify(pt("ui.pause_run_ended"), vim.log.levels.WARN)
    elseif err == "exists" and M._live_pause(aid) then
      restate(aid, M._live_pause(aid))
    else
      notify(pt("ui.pause_failed", { label = label_of(aid), err = tostring(err) }), vim.log.levels.WARN)
    end
    return nil, tostring(err)
  end
  local key = at == "stop" and "ui.pause_requested_stop" or "ui.pause_requested"
  notify(pt(key, { label = label_of(aid), min = mmss(cfg.auto_resume_s) }))
  after_steer()
  return pid
end

--- Resume box `id` (withdraw a pause that has not stopped it yet; let a gate pass). Allowed even
--- with `pause.enabled = false` or outdated hooks, so a pause can always be undone.
---@param id string
---@param opts? { reason?: string, steer_id?: string, quiet?: boolean }
---@return boolean ok
function M.pause_resume(id, opts)
  opts = opts or {}
  local aid = M.steer_target(id)
  if not aid then
    notify(pt("ui.pause_not_target"), vim.log.levels.WARN)
    return false
  end
  local p = M._live_pause(aid)
  if not p then
    notify(pt("ui.pause_none", { label = label_of(aid) }))
    return false
  end
  -- 状態は記録を書いた瞬間に同じ表の中で変わるので、先に控える
  local was = p.status
  local ok, err = M._resume_raw(aid, { reason = opts.reason or "user", steer_id = opts.steer_id })
  if not ok then
    notify(pt("ui.pause_failed", { label = label_of(aid), err = tostring(err or "events.resume_pause is missing") }),
      vim.log.levels.WARN)
    return false
  end
  if not opts.quiet then
    notify(pt(was == "REQUESTED" and "ui.pause_cancelled" or "ui.pause_resumed", { label = label_of(aid) }))
  end
  after_steer()
  return true
end

--- The menu of a box that waits at its end because of the gate ([GATE]):
--- Pass (let it finish) / Fix (write an instruction; it continues) / Keep waiting (show the report).
function M.gate_menu(id)
  local aid = M.steer_target(id)
  if not aid then return end
  local items = { pt("ui.pause_pass"), pt("ui.pause_fix"), pt("ui.pause_keep_gate") }
  vim.ui.select(items, { prompt = pt("ui.pause_prompt", { label = label_of(aid) }) }, function(_, idx)
    -- the built-in select leaves its list in the message area; clear it so that the notice of the
    -- choice (e.g. "resumed") does not end in a "Press ENTER" prompt
    pcall(vim.cmd, "redraw")
    if idx == 1 then
      M.pause_resume(aid)
    elseif idx == 2 then
      M.steer_input(aid)
    elseif idx == 3 then
      M.open_detail(aid)
    end
  end)
end

--- `x` on a box (appendix D: no menu). No pause → place one (next tool call or the end, whichever
--- comes first). A pause placed or holding it → resume. A box waiting at the gate ([GATE]) → the
--- Pass / Fix menu. A gate request that has not stopped the box yet → replaced by a pause now.
---@param id string map id
function M.pause_toggle(id)
  local aid = M.steer_target(id)
  if not aid then
    notify(pt("ui.pause_not_target"), vim.log.levels.WARN)
    return nil
  end
  local p = M._live_pause(aid)
  if p then
    if p.kind == "gate" and p.status == "PAUSED" then return M.gate_menu(aid) end
    if p.kind == "gate" then return M.pause_request(aid, "next", { replace = true }) end
    return M.pause_resume(aid)
  end
  return M.pause_request(aid, "next")
end

--- :AgentMapPause {n|id} [next|stop]: place a pause at the chosen place. It never resumes (that is
--- :AgentMapResume): on a box that already has one it says how it stands, a gate request or a
--- pause placed for the other place is replaced, and a box waiting at the gate gets the Pass / Fix menu.
---@param id string
---@param at? "next"|"stop"
function M.pause_command(id, at)
  local aid = M.steer_target(id)
  if not aid then
    notify(pt("ui.pause_not_target"), vim.log.levels.WARN)
    return nil
  end
  at = at == "stop" and "stop" or "next"
  local p = M._live_pause(aid)
  if not p then return M.pause_request(aid, at) end
  if p.kind == "gate" and p.status == "PAUSED" then return M.gate_menu(aid) end
  if p.status == "REQUESTED" and (p.kind == "gate" or (p.at or "next") ~= at) then
    return M.pause_request(aid, at, { replace = true })
  end
  restate(aid, p)
  return nil
end

--- True when the gate of the run on screen is on (events.gate_on; else the run's last gate_set,
--- else config pause.gate).
function M.gate_on()
  if not M.run then return false end
  local ev = pause_events("gate_on")
  if ev then
    local ok, on = pcall(ev.gate_on, M.run)
    if ok then return on == true end
  end
  local s = M.run.state
  if type(s) == "table" and s.gate ~= nil then return s.gate == true end
  return M.pause_cfg().gate == true
end

--- `X`: turn the gate of the run on screen on or off (on = nil toggles). While it is on, every
--- running sub-agent waits at its end for Pass (x) or Fix (s). Turning it on needs current hooks.
---@param on? boolean
---@return boolean|nil the new state, nil when refused
function M.toggle_gate(on)
  local cfg = M.pause_cfg()
  if not M.run then
    notify(t("ui.no_runs_to_show"), vim.log.levels.WARN)
    return nil
  end
  if not cfg.enabled then
    notify(pt("ui.pause_disabled"))
    return nil
  end
  if on == nil then on = not M.gate_on() end
  if on and run_ended() then
    notify(pt("ui.pause_run_ended"), vim.log.levels.WARN)
    return nil
  end
  if on and not M.pause_hooks_ok() then
    notify(pt("ui.pause_hooks_outdated"), vim.log.levels.WARN)
    return nil
  end
  local ev = pause_events("set_gate")
  if not ev then
    notify(pt("ui.pause_failed", { label = t("keymaps.desc_gate"), err = "events.set_gate is missing" }), vim.log.levels.WARN)
    return nil
  end
  local ok, r = pcall(ev.set_gate, M.run, on)
  if not ok or r == false then
    notify(pt("ui.pause_failed", { label = t("keymaps.desc_gate"), err = tostring(ok and "write failed" or r) }), vim.log.levels.WARN)
    return nil
  end
  notify(pt(on and "ui.gate_on" or "ui.gate_off"))
  after_steer()
  return on
end

-- 開いた時点の状態を覚える（開く前のことは知らせない）
function M._seed_pauses()
  local s = M.run and M.run.state
  local sid = M.run and M.run.sid
  if not sid then return end
  local seen = {}
  for k, p in pairs(s and type(s.pauses) == "table" and s.pauses or {}) do
    if type(p) == "table" then seen[k] = p.status end
  end
  pause_seen[sid] = seen
end

-- 状態の変わり目 1 つ分の知らせ（知らせないものは nil）
local function pause_message(p)
  local label = label_of(p.agent_id)
  if p.status == "PAUSED" then
    if p.kind == "gate" then
      return pt("ui.pause_hit_gate", { label = label, time = clock_of(deadline_of(p)) })
    end
    return pt("ui.pause_hit", { label = label, via = p.hit_via or "?", time = clock_of(deadline_of(p)) })
  elseif p.status == "RESUMED" then
    local r = p.release_reason
    if r == "auto" or r == "max_wait" then
      local ms = p.waited_ms or ((tonumber(p.auto_resume_s) or M.pause_cfg().auto_resume_s or 600) * 1000)
      return pt("ui.pause_auto", { label = label, min = dur_text(ms) })
    elseif r == "aborted" then
      return pt("ui.pause_aborted", { label = label }), vim.log.levels.WARN
    end
  elseif p.status == "EXPIRED" and p.end_reason == "agent_finished" then
    return pt("ui.pause_expired", { label = label })
  end
  return nil -- 作者自身の操作（再開・取り下げ・関門を切る・Neovim の終了）は、そのとき知らせている
end

--- Notify (once each) the changes of pauses seen since the map was opened: stopped, stopped at
--- the gate, resumed by itself, ended by Claude Code, finished before it could stop.
--- Silent with `pause.notify = false`.
---@return integer number of notices
function M.notify_pauses()
  local s = M.run and M.run.state
  local sid = M.run and M.run.sid
  if not s or not sid or type(s.pauses) ~= "table" then return 0 end
  local seen = pause_seen[sid]
  if not seen then
    M._seed_pauses()
    return 0
  end
  local quiet = M.pause_cfg().notify == false
  local n = 0
  for k, p in pairs(s.pauses) do
    if type(p) == "table" and seen[k] ~= p.status then
      seen[k] = p.status
      if not quiet then
        local msg, lvl = pause_message(p)
        if msg then
          notify(msg, lvl)
          n = n + 1
        end
      end
    end
  end
  return n
end

--- Clean up pauses whose agent finished (events.sweep_pauses), place the gate's pauses on new
--- running sub-agents (events.sync_gate), then notify the changes.
---@return boolean changed
function M.sweep_pauses()
  local changed = false
  local ev = try_require("agentmap.events")
  if ev and M.run then
    if type(ev.sweep_pauses) == "function" then
      local ok, r = pcall(ev.sweep_pauses, M.run)
      changed = changed or (ok and r == true)
    end
    if type(ev.sync_gate) == "function" then
      local ok, n = pcall(ev.sync_gate, M.run)
      changed = changed or (ok and type(n) == "number" and n > 0)
    end
  end
  pcall(M.notify_pauses)
  return changed
end

return M
