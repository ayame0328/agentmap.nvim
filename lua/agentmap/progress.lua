-- ============================================================
--  agentmap/progress.lua ... progress (%) of one box (DESIGN-v0.2 §2.3, appendix D).
--    Fact: finished steps / all steps (TaskCreate/TaskUpdate, or "## Steps" in the transcript).
--    Estimate: only the running step is filled in, from the typical step time of similar
--    past agents (stats.lua), or from running child agents. Estimates are marked `~`,
--    rounded down to 0.1 and capped, so a box never looks further along than it is.
--    Pure: reads the state table, the clock value and the stats passed in; touches no file.
-- ============================================================
local M = {}

local util = require("agentmap.util")

local CFG_DEFAULTS = { enabled = true, default_ms = 600000, min_samples = 3, no_steps = "time" }
M.TIME_CAP = 95.0 -- 経過時間だけの推定の上限
M.RUNNING_CAP = 99.9 -- 動いている箱の上限（100 は終わった箱だけ）

--- Round down to one decimal place (never round up: 2/3 -> 66.6).
function M.floor1(x)
  return math.floor(x * 10 + 1e-7) / 10
end

--- Display form of a compute() result: "~62.4%" (estimated) or "66.6%" (fact). nil -> nil.
function M.label(r)
  if type(r) ~= "table" or type(r.pct) ~= "number" then return nil end
  return (r.estimated and "~" or "") .. ("%.1f"):format(r.pct) .. "%"
end

--- Number part only ("~62.4" / "66.6").
function M.pct_text(r)
  if type(r) ~= "table" or type(r.pct) ~= "number" then return nil end
  return (r.estimated and "~" or "") .. ("%.1f"):format(r.pct)
end

local function cfg_of(c)
  local out = {}
  for k, v in pairs(CFG_DEFAULTS) do out[k] = v end
  for k, v in pairs(type(c) == "table" and c or {}) do out[k] = v end
  return out
end

-- ------------------------------------------------------------
-- 事実（state.progress_facts の契約。W1 の関数があればそれを使う）
-- ------------------------------------------------------------
local function ts(x) return util.parse_iso(x) end

-- state.lua にまだ progress_facts が無いときの同じ形の計算（DESIGN-v0.2 §2.2）
local function local_facts(s, id)
  local a = s and s.agents and s.agents[id]
  if type(a) ~= "table" then return nil end
  local tk = a.tasks
  if type(tk) == "table" and type(tk.items) == "table" then
    local ids, seen = {}, {}
    for _, tid in ipairs(tk.order or {}) do
      if tk.items[tid] and not seen[tid] then
        seen[tid] = true
        ids[#ids + 1] = tid
      end
    end
    for tid in pairs(tk.items) do
      if not seen[tid] then ids[#ids + 1] = tid end
    end
    if #ids > 0 then
      local k, cur, done_at = 0, nil, nil
      for _, tid in ipairs(ids) do
        local it = tk.items[tid]
        if it.status == "completed" then
          k = k + 1
          local d = ts(it.done_at)
          if d and (not done_at or d > ts(done_at)) then done_at = it.done_at end
        elseif it.status == "in_progress" then
          local st = it.started_at or it.created_at
          if not cur or ((ts(st) or math.huge) < (ts(cur.started_at) or math.huge)) then
            cur = { started_at = st, text = it.active_form or it.subject }
          end
        end
      end
      return { source = "tasks", n = #ids, k = k, cur = cur, all_done_at = (k == #ids) and done_at or nil }
    end
  end
  local sp = a.steps
  if type(sp) == "table" and type(sp.items) == "table" and #sp.items > 0 then
    local k, cur, prev_done, last_done = 0, nil, nil, nil
    for _, it in ipairs(sp.items) do
      if it.done_at then
        k = k + 1
        prev_done = it.done_at
        last_done = it.done_at
      elseif not cur then
        cur = { started_at = it.started_at or prev_done or sp.listed_at, text = it.text }
      end
    end
    return { source = "steps", n = #sp.items, k = k, cur = cur, all_done_at = (k == #sp.items) and last_done or nil }
  end
  return nil
end
M._local_facts = local_facts

--- Facts of agent `id`: state.progress_facts (W1) when present, otherwise the same contract here.
function M.facts(s, id)
  local ok, st = pcall(require, "agentmap.state")
  if ok and type(st) == "table" and type(st.progress_facts) == "function" then
    local ok2, f = pcall(st.progress_facts, s, id)
    if ok2 then return f end
  end
  return local_facts(s, id)
end

-- ------------------------------------------------------------
-- 計算
-- ------------------------------------------------------------
local function children(s, id)
  local ok, graph = pcall(require, "agentmap.graph")
  if ok and type(graph.children) == "function" then return graph.children(s, id) end
  return {}
end

-- 止まっていた時間（ms）。DESIGN-v0.1.2-pause §6.3：止まっている間に推定の % が伸びないように、
-- 経過時間から引く。since（秒）があれば、その時刻より後の分だけ
local function paused_ms(s, id, now, since)
  local ok, graph = pcall(require, "agentmap.graph")
  if not ok or type(graph.paused_ms) ~= "function" then return 0 end
  local ok2, r = pcall(graph.paused_ms, s, id, now, since)
  if ok2 and type(r) == "number" then return r end
  return 0
end
M._paused_ms = paused_ms

-- iso から now までの ms。止まっていた時間（その間の分だけ）を引く
local function elapsed_since(iso, now, s, id)
  local t = ts(iso)
  if not t then return nil end
  local el = math.max(0, now - t) * 1000
  if s and id then el = math.max(0, el - paused_ms(s, id, now, t)) end
  return el
end

--- Progress of agent `id` (DESIGN-v0.2 §2.3; appendix D: boxes without a step list are
--- estimated from elapsed time when config.progress.no_steps == "time"). Time spent paused
--- (DESIGN-v0.1.2-pause §6.3) is taken out of the elapsed time used for estimates. A parent without a step
--- list shows the plain average of its children: finished = 100, not yet started (PENDING) = 0.
---@param state table
---@param id string
---@param opts? { now?: number, stats?: table, config?: table, flow_id?: string }
---@return table|nil { pct, estimated, basis = "tasks"|"steps"|"children"|"time"|"done"|"failed",
---   n, k, f, cur_started_at, cur_text, cur_elapsed_ms, expected_ms, stat_basis, samples, over, n_children }
function M.compute(state, id, opts)
  opts = opts or {}
  local seen = opts._seen or {}
  if seen[id] then return nil end
  local a = state and state.agents and state.agents[id]
  if type(a) ~= "table" or a.placeholder then return nil end
  local now = opts.now or os.time()
  local cfg = cfg_of(opts.config)
  local st = a.status or "PENDING"
  local facts = M.facts(state, id)
  if facts and (type(facts.n) ~= "number" or facts.n <= 0) then facts = nil end

  if st == "DONE" then
    return { pct = 100.0, estimated = false, basis = "done", n = facts and facts.n, k = facts and facts.k, f = 0 }
  end
  if st == "FAILED" then
    if not facts then return nil end
    return { pct = M.floor1(100 * facts.k / facts.n), estimated = false, basis = "failed", n = facts.n, k = facts.k, f = 0 }
  end
  if st ~= "RUNNING" then
    if not facts then return nil end
    return { pct = M.floor1(100 * facts.k / facts.n), estimated = false, basis = facts.source,
      n = facts.n, k = facts.k, f = 0 }
  end

  -- RUNNING
  local sub = { now = now, stats = opts.stats, config = opts.config, flow_id = opts.flow_id,
    _seen = setmetatable({ [id] = true }, { __index = seen }) }
  local model = a.model or a.model_requested
  local atype = a.agent_type or (id == "ROOT" and "main" or nil)

  if facts then
    local r = { basis = facts.source, n = facts.n, k = facts.k, f = 0, estimated = false, over = false }
    if facts.k >= facts.n then
      r.pct, r.estimated = M.RUNNING_CAP, true
      return r
    end
    -- 実行中の手順の中身：動いている子がいれば子の平均、いなければ時間
    local kid_sum, kid_n = 0, 0
    for _, c in ipairs(children(state, id)) do
      local ca = state.agents[c]
      if ca and ca.status == "RUNNING" then
        local cr = M.compute(state, c, sub)
        if cr then
          kid_sum = kid_sum + cr.pct
          kid_n = kid_n + 1
        end
      end
    end
    local stats = require("agentmap.stats")
    local d, sb, ns = stats.step_ms(opts.stats, atype, model, facts.n, cfg)
    r.expected_ms, r.stat_basis, r.samples = d, sb, ns
    r.cur_started_at = facts.cur and facts.cur.started_at or nil
    r.cur_text = facts.cur and facts.cur.text or nil
    local el = r.cur_started_at and elapsed_since(r.cur_started_at, now, state, id) or nil
    r.cur_elapsed_ms = el
    if kid_n > 0 then
      r.f = math.min(0.99, kid_sum / kid_n / 100)
      r.n_children = kid_n
    elseif el and d and d > 0 then
      r.f = math.min(0.99, el / d)
      r.over = el > d
    end
    r.estimated = r.f > 0
    r.pct = math.min(M.RUNNING_CAP, M.floor1(100 * (facts.k + r.f) / facts.n))
    return r
  end

  local kids = children(state, id)
  if #kids > 0 then
    local sum, n, est = 0, 0, false
    for _, c in ipairs(kids) do
      local cr = M.compute(state, c, sub)
      local ca = state.agents[c]
      -- 失敗した子は「その子の値」、事実が無ければ 100（その子の分はもう進まない）
      if not cr and ca and ca.status == "FAILED" then
        cr = { pct = 100.0, estimated = false }
      end
      -- まだ始まっていない子（PENDING。起動待ちの仮の箱も）は除かず 0 として平均に入れる
      -- （2026-10-04 本人の決定：子が増える予定が見えているのに進み過ぎに見せない）
      if not cr and ca and (ca.status or "PENDING") == "PENDING" then
        cr = { pct = 0.0, estimated = false }
      end
      if cr then
        sum = sum + cr.pct
        n = n + 1
        if cr.estimated then est = true end
      end
    end
    if n > 0 then
      local pct = M.floor1(sum / n)
      -- 子が全部終わったのに自分はまだ動いている：残りは測れないので、時間だけの推定と同じ上限 95.0
      -- （2026-10-04 本人の決定。95.0 未満なら子の平均のまま）。子が動いている間の上限は 99.9
      local active = false
      for _, c in ipairs(kids) do
        local cs = state.agents[c] and state.agents[c].status or "PENDING"
        if cs == "RUNNING" or cs == "PENDING" or cs == "REVIEW" then active = true end
      end
      local cap = active and M.RUNNING_CAP or M.TIME_CAP
      if pct >= cap then pct, est = cap, true end
      return { pct = pct, estimated = est, basis = "children", n_children = n, f = 0, children_done = not active }
    end
  end

  if cfg.no_steps ~= "time" then return nil end
  local el = elapsed_since(a.started_at, now, state, id)
  if not el then return nil end
  local stats = require("agentmap.stats")
  local T, sb, ns = stats.expected_ms(opts.stats, atype, model, cfg)
  if not T or T <= 0 then return nil end
  return {
    pct = math.min(M.TIME_CAP, M.floor1(100 * el / T)), estimated = true, basis = "time",
    expected_ms = T, stat_basis = sb, samples = ns, cur_elapsed_ms = el, over = el > T, f = 0,
  }
end

--- A record for the shadow-run log (§2.5) built from a compute() result.
function M.log_entry(state, id, r, extra)
  local a = state and state.agents and state.agents[id] or {}
  local e = {
    run = state and state.run_id, agent = id, type = a.agent_type or (id == "ROOT" and "main" or nil),
    model = require("agentmap.stats").family(a.model or a.model_requested),
    basis = r and r.basis, n = r and r.n, k = r and r.k, f = r and r.f, pct = r and r.pct,
    stat_basis = r and r.stat_basis, samples = r and r.samples, d_hat_ms = r and r.expected_ms,
  }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

return M
