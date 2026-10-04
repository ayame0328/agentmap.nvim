-- ============================================================
--  agentmap/stats.lua ... typical durations from your own past runs (DESIGN-v0.2 §2.5).
--    load(root, opts)  medians of finished agents and finished steps, keyed by
--                      "<agent_type>|<model family>", cached in <root>/stats.json and
--                      re-read only for runs whose state.json changed.
--    expected_ms()     typical duration of a whole agent (T-hat)
--    step_ms()         typical duration of one step (d-hat)
--    log() / evaluate() shadow-run log of the estimates (<root>/progress_log.jsonl)
--    The median is used (not the mean): durations range from seconds to tens of minutes.
-- ============================================================
local M = {}

local util = require("agentmap.util")
local uv = vim.uv or vim.loop

M.VERSION = 1

-- 読み直しの間隔などの既定（opts で上書きできる）
local LOAD_DEFAULTS = { max_runs = 300, recheck_s = 60 }
local CFG_DEFAULTS = { default_ms = 600000, min_samples = 3 }

-- 試験から時計と読み込み回数を見られるように
M.clock = os.time
M._reads = 0 -- state.json を読んだ回数（控えが効いているかの確認用）

-- 根ごとに、最後に一覧を見直した時刻と結果を覚える（毎秒呼ばれても軽くするため）
local mem = {} -- [root] = { S = …, checked_at = 秒 }

--- Clear the in-memory cache (tests).
function M.reset()
  mem = {}
  M._reads = 0
end

-- 設定（config.progress）の写しに既定を足す。渡された表そのものは変えない
local function cfg_of(cfg)
  if cfg == nil then
    local ok, c = pcall(function() return require("agentmap.config").get().progress end)
    cfg = ok and type(c) == "table" and c or {}
  end
  local out = {}
  for k, v in pairs(CFG_DEFAULTS) do out[k] = v end
  for k, v in pairs(cfg) do out[k] = v end
  return out
end

-- ------------------------------------------------------------
-- 鍵
-- ------------------------------------------------------------

--- Model family: the first word of the short model name ("claude-opus-4-1-2025…" -> "opus").
--- Aliases such as "opus" are their own family. nil -> "?".
function M.family(model)
  if type(model) ~= "string" or model == "" then return "?" end
  local m = model:gsub("^claude%-", "")
  local w = m:match("(%a+)")
  return (w and w ~= "") and w:lower() or m
end

--- Statistics key "<agent_type>|<family>". ROOT is "main".
function M.key(agent_type, model)
  return (agent_type or "?") .. "|" .. M.family(model)
end

-- ------------------------------------------------------------
-- 中央値
-- ------------------------------------------------------------
local function median(list)
  local n = #list
  if n == 0 then return nil end
  local xs = vim.list_slice(list, 1, n)
  table.sort(xs)
  if n % 2 == 1 then return xs[(n + 1) / 2] end
  return (xs[n / 2] + xs[n / 2 + 1]) / 2
end
M.median = median

-- ------------------------------------------------------------
-- 1 つの run の標本（state.json から）
-- ------------------------------------------------------------
local function ts(x) return util.parse_iso(x) end

-- 手順の間隔（done_at - started_at）。始まりが無ければ「直前の済んだ時刻 → 一覧を出した時刻」
local function step_samples(a, out, key)
  local function add(st, fin)
    if st and fin and fin >= st then out[#out + 1] = { key, math.floor((fin - st) * 1000) } end
  end
  if type(a.tasks) == "table" and type(a.tasks.items) == "table" then
    for _, it in pairs(a.tasks.items) do
      if type(it) == "table" and it.status == "completed" then
        add(ts(it.started_at) or ts(it.created_at), ts(it.done_at))
      end
    end
  end
  if type(a.steps) == "table" and type(a.steps.items) == "table" then
    local prev = ts(a.steps.listed_at)
    for _, it in ipairs(a.steps.items) do
      local fin = ts(it.done_at)
      if fin then
        add(ts(it.started_at) or prev, fin)
        prev = fin
      end
    end
  end
end

--- Samples of one decoded state.json: { agents = { {key, ms}, … }, steps = { {key, ms}, … } }.
function M.samples_of_state(st)
  local out = { agents = {}, steps = {} }
  if type(st) ~= "table" or type(st.agents) ~= "table" then return out end
  for id, a in pairs(st.agents) do
    if type(a) == "table" and a.kind ~= "workflow" and not a.placeholder then
      local atype = a.agent_type or (id == "ROOT" and "main" or nil)
      local key = M.key(atype, a.model or a.model_requested)
      if a.status == "DONE" and type(a.elapsed_ms) == "number" and a.elapsed_ms > 0 then
        out.agents[#out.agents + 1] = { key, a.elapsed_ms }
      end
      step_samples(a, out.steps, key)
    end
  end
  return out
end

-- ------------------------------------------------------------
-- 集計
-- ------------------------------------------------------------
local function aggregate(S)
  local buckets = { agents = {}, steps = {} }
  local all = { agents = {}, steps = {} }
  for _, smp in pairs(S.samples or {}) do
    for _, kind in ipairs({ "agents", "steps" }) do
      for _, e in ipairs(smp[kind] or {}) do
        local key, ms = e[1], e[2]
        local tkey = key:match("^(.-)|") .. "|*"
        for _, k in ipairs({ key, tkey }) do
          buckets[kind][k] = buckets[kind][k] or {}
          table.insert(buckets[kind][k], ms)
        end
        table.insert(all[kind], ms)
      end
    end
  end
  for _, kind in ipairs({ "agents", "steps" }) do
    S[kind] = {}
    for k, list in pairs(buckets[kind]) do
      S[kind][k] = { n = #list, median_ms = median(list) }
    end
  end
  S.all = {
    agents = { n = #all.agents, median_ms = median(all.agents) },
    steps = { n = #all.steps, median_ms = median(all.steps) },
  }
  return S
end

local function empty_stats()
  return aggregate({ v = M.VERSION, runs = {}, samples = {} })
end

-- 記録の置き場の下にある state.json の一覧（新しい順）{ {dir, mtime}, … }
local function list_runs(root)
  local out = {}
  local projects = root .. "/projects"
  local h = uv.fs_scandir(projects)
  if not h then return out end
  while true do
    local slug, typ = uv.fs_scandir_next(h)
    if not slug then break end
    if typ == "directory" then
      local runs = projects .. "/" .. slug .. "/runs"
      local h2 = uv.fs_scandir(runs)
      while h2 do
        local sid, t2 = uv.fs_scandir_next(h2)
        if not sid then break end
        if t2 == "directory" then
          local dir = runs .. "/" .. sid
          local st = uv.fs_stat(dir .. "/state.json")
          -- mtime は文字列で持つ（stats.json を通しても桁が落ちないように）
          if st then out[#out + 1] = { dir = dir, sec = st.mtime.sec, mtime = st.mtime.sec .. "." .. st.mtime.nsec } end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.sec ~= b.sec then return a.sec > b.sec end
    return a.dir < b.dir
  end)
  return out
end

--- Load (or refresh) the statistics of the record store `root`.
--- The run list is re-scanned at most once per `opts.recheck_s` seconds; only runs whose
--- state.json mtime changed are re-read. The result is cached in <root>/stats.json.
---@param root? string record store (default: config.root())
---@param opts? { max_runs?: integer, recheck_s?: number, skip_dir?: string, now?: number, no_write?: boolean, force?: boolean }
---@return table S { v, updated_at, agents = { [key] = { n, median_ms } }, steps = {…}, all = {…}, runs = { [dir] = mtime } }
function M.load(root, opts)
  opts = vim.tbl_extend("force", LOAD_DEFAULTS, opts or {})
  root = root or require("agentmap.config").root()
  local now = opts.now or M.clock()
  local m = mem[root]
  if m and not opts.force and (now - m.checked_at) < opts.recheck_s then return m.S end

  local S = m and m.S
  if not S then
    local cached = util.json_decode(util.read_file(root .. "/stats.json"))
    if type(cached) == "table" and cached.v == M.VERSION and type(cached.samples) == "table" then
      S = cached
      S.runs = type(S.runs) == "table" and S.runs or {}
    else
      S = { v = M.VERSION, runs = {}, samples = {} }
    end
  end

  local runs = list_runs(root)
  local keep, changed = {}, false
  for i, r in ipairs(runs) do
    if i > opts.max_runs then break end
    keep[r.dir] = true
    if r.dir ~= opts.skip_dir and S.runs[r.dir] ~= r.mtime then
      M._reads = M._reads + 1
      local st = util.json_decode(util.read_file(r.dir .. "/state.json"))
      S.samples[r.dir] = M.samples_of_state(st)
      S.runs[r.dir] = r.mtime
      changed = true
    end
  end
  -- 消えた run・古くて上限から外れた run は落とす
  for dir in pairs(S.runs) do
    if not keep[dir] then
      S.runs[dir], S.samples[dir] = nil, nil
      changed = true
    end
  end
  for dir in pairs(S.samples) do
    if not keep[dir] then
      S.samples[dir] = nil
      changed = true
    end
  end
  if changed or not S.all then
    aggregate(S)
    S.updated_at = util.iso_now()
    if not opts.no_write then
      local js = util.json_encode(S)
      if js then pcall(util.write_atomic, root .. "/stats.json", js) end
    end
  end
  mem[root] = { S = S, checked_at = now }
  return S
end

-- ------------------------------------------------------------
-- 目安
-- ------------------------------------------------------------
local function pick(tbl, key, min)
  local e = tbl and tbl[key]
  if type(e) == "table" and (e.n or 0) >= min and type(e.median_ms) == "number" then return e end
  return nil
end

--- Typical duration of a whole agent (T-hat).
---@param S table|nil result of load() (nil: no history)
---@param cfg? table config.progress (default_ms, min_samples)
---@return number ms, string basis "type+model"|"type"|"all"|"default", integer samples
function M.expected_ms(S, agent_type, model, cfg)
  cfg = cfg_of(cfg)
  local min = cfg.min_samples
  if type(S) == "table" then
    local key = M.key(agent_type, model)
    local e = pick(S.agents, key, min)
    if e then return e.median_ms, "type+model", e.n end
    e = pick(S.agents, (agent_type or "?") .. "|*", min)
    if e then return e.median_ms, "type", e.n end
    e = S.all and S.all.agents
    if type(e) == "table" and (e.n or 0) >= min and e.median_ms then return e.median_ms, "all", e.n end
  end
  return cfg.default_ms, "default", 0
end

--- Typical duration of one step (d-hat) of an agent with `n_steps` steps.
--- Order: step medians of the key → agent median / n_steps, then the same by type, then all, then default.
---@return number ms, string basis, integer samples
function M.step_ms(S, agent_type, model, n_steps, cfg)
  cfg = cfg_of(cfg)
  local min = cfg.min_samples
  n_steps = math.max(1, n_steps or 1)
  if type(S) == "table" then
    for _, lv in ipairs({ { M.key(agent_type, model), "type+model" }, { (agent_type or "?") .. "|*", "type" } }) do
      local e = pick(S.steps, lv[1], min)
      if e then return e.median_ms, lv[2], e.n end
      e = pick(S.agents, lv[1], min)
      if e then return e.median_ms / n_steps, lv[2], e.n end
    end
    local all = S.all or {}
    if type(all.steps) == "table" and (all.steps.n or 0) >= min and all.steps.median_ms then
      return all.steps.median_ms, "all", all.steps.n
    end
    if type(all.agents) == "table" and (all.agents.n or 0) >= min and all.agents.median_ms then
      return all.agents.median_ms / n_steps, "all", all.agents.n
    end
  end
  return cfg.default_ms / n_steps, "default", 0
end

-- ------------------------------------------------------------
-- 影運転の記録と答え合わせ（§2.5・§8.2）
-- ------------------------------------------------------------

--- Path of the shadow-run log.
function M.log_path(root)
  return (root or require("agentmap.config").root()) .. "/progress_log.jsonl"
end

--- Append one estimate record to <root>/progress_log.jsonl ("ts" is filled in when missing).
---@return boolean ok
function M.log(root, entry)
  if type(entry) ~= "table" then return false end
  local e = vim.deepcopy(entry)
  e.ts = e.ts or util.iso_now()
  local js = util.json_encode(e)
  if not js then return false end
  return util.append_line(M.log_path(root), js) and true or false
end

--- Check the logged estimates against the real end times.
--- Truth at time t = 100 * (t - start) / elapsed, start = end - elapsed of the `final` record.
---@return table { n = finished agents with estimates, median_abs_err = points|nil, over90_late_ratio = 0..1|nil }
function M.evaluate(root)
  local rows = util.json_lines(M.log_path(root), 0)
  local by = {} -- [run|agent] = { rows = {}, final = row }
  for _, r in ipairs(rows) do
    if type(r) == "table" and r.agent then
      local k = tostring(r.run) .. "|" .. tostring(r.agent)
      by[k] = by[k] or { rows = {} }
      if r.final then
        by[k].final = r
      elseif type(r.pct) == "number" then
        table.insert(by[k].rows, r)
      end
    end
  end
  local errs, n, reached, late = {}, 0, 0, 0
  for _, g in pairs(by) do
    local f = g.final
    local fin = f and util.parse_iso(f.ts)
    local el = f and tonumber(f.elapsed_ms)
    if fin and el and el > 0 and #g.rows > 0 then
      n = n + 1
      local start = fin - el / 1000
      table.sort(g.rows, function(a, b) return (util.parse_iso(a.ts) or 0) < (util.parse_iso(b.ts) or 0) end)
      local first90
      for _, r in ipairs(g.rows) do
        local t = util.parse_iso(r.ts)
        if t then
          local truth = math.max(0, math.min(100, 100 * (t - start) / (el / 1000)))
          errs[#errs + 1] = math.abs(r.pct - truth)
          if not first90 and r.pct >= 90 then first90 = { r = r, t = t } end
        end
      end
      if first90 then
        local r = first90.r
        local d = tonumber(r.d_hat_ms)
        local expect
        if d and r.n and r.k then
          expect = math.max(0, (r.n - r.k) - (r.f or 0)) * d
        elseif d then
          expect = math.max(0, 1 - r.pct / 100) * d
        end
        if expect then
          reached = reached + 1
          if (fin - first90.t) * 1000 > 2 * expect then late = late + 1 end
        end
      end
    end
  end
  return {
    n = n,
    median_abs_err = median(errs),
    over90_late_ratio = reached > 0 and (late / reached) or nil,
  }
end

M._empty = empty_stats

return M
