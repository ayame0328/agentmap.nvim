-- ============================================================
--  agentmap/events.lua ... loads one run and keeps its state up to date (hooks.jsonl + events.jsonl).
--
--  run = { dir, sid, slug, state, off = { hooks = バイト, events = バイト }, source, provider }
--    load(dir)          … 読み込む（state.json の控えが最新ならそれを使う）
--    poll(run)          … 増えた行だけ読んで状態に足す（自動更新）
--    emit(run, ev)      … Neovim 側の記録（レビューなど）を書いて状態に足す
--    enrich(run)        … 足りない情報（モデル名・親・transcript の場所）を Claude のファイルから補う
--    current_run()      … 今のフォルダの最新の run
--    open_run(sid)      … session_id から run を開く（無ければ transcript から取り込む）
--    import_transcript  … hooks が無い session を transcript から取り込む
--    list_runs()        … run の一覧（hooks あり・取り込み済み・履歴のみ）
-- ============================================================
local config = require("agentmap.config")
local util = require("agentmap.util")
local store = require("agentmap.store")
local state_mod = require("agentmap.state")
local providers = require("agentmap.providers")

local M = {}
local uv = vim.uv or vim.loop

local ROOT_MODEL_RETRY = 3 -- 秒。ROOT のモデル名が取れないとき、次に試すまでの最短の間（記録が増えたときだけ試す）

local function provider_of(run)
  return providers.get(run and run.provider or "claude") or providers.get("claude")
end

-- hooks.jsonl の生の行 → 整えた記録（どれも _fo = 0）
local function normalize_all(recs, prov)
  local out = {}
  for _, rec in ipairs(recs) do
    local ok, evs = pcall(prov.normalize_hook, rec)
    if ok and type(evs) == "table" then
      for _, ev in ipairs(evs) do
        ev._fo = 0
        out[#out + 1] = ev
      end
    end
  end
  return out
end

local function sort_events(list)
  for i, ev in ipairs(list) do ev._i = i end
  table.sort(list, function(a, b)
    local ta, tb = util.parse_iso(a.ts) or 0, util.parse_iso(b.ts) or 0
    if ta ~= tb then return ta < tb end
    if (a._fo or 0) ~= (b._fo or 0) then return (a._fo or 0) < (b._fo or 0) end
    return a._i < b._i
  end)
  for _, ev in ipairs(list) do ev._i = nil end
  return list
end

local function save(run)
  run.state._off = { hooks = run.off.hooks, events = run.off.events }
  pcall(store.write_state, run.dir, run.state)
end

local function parse_dir(dir)
  local slug, sid = dir:match("/projects/([^/]+)/runs/([^/]+)/?$")
  return slug, sid
end

--- Load a run folder.
--- run のフォルダを読み込む
function M.load(dir)
  local slug, sid = parse_dir(dir)
  local run = { dir = dir, sid = sid, slug = slug, provider = "claude", off = { hooks = 0, events = 0 } }
  local hsize, esize = store.size(dir, "hooks.jsonl"), store.size(dir, "events.jsonl")
  run.source = hsize > 0 and "hooks" or (esize > 0 and "transcript" or "empty")

  -- 控え（state.json）が今のファイルの大きさと一致していればそのまま使う
  local cached = store.read_state(dir)
  if type(cached) == "table" and type(cached._off) == "table"
      and cached._off.hooks == hsize and cached._off.events == esize and cached.v == 1
      and cached.sv == state_mod.SV then
    run.state = cached
    run.off = { hooks = hsize, events = esize }
  else
    local prov = provider_of(run)
    local hooks, hoff = store.read_new(dir, "hooks.jsonl", 0)
    local evs, eoff = store.read_new(dir, "events.jsonl", 0)
    local all = normalize_all(hooks, prov)
    for _, ev in ipairs(evs) do
      ev._fo = 1
      all[#all + 1] = ev
    end
    for i, ev in ipairs(all) do ev.seq = i end
    run.state = state_mod.reduce(all, sid)
    run.state.run_id = run.state.run_id or sid
    run.off = { hooks = hoff, events = eoff }
    save(run)
  end
  -- 開始の記録も指示の記録も無い run は、フォルダがわからない → プロジェクトの登録（project.json）から補う
  if not run.state.cwd and slug then
    local pj = store.read_project(slug)
    if type(pj) == "table" and type(pj.cwd) == "string" and pj.cwd ~= "" then run.state.cwd = pj.cwd end
  end
  return run
end

--- Read only what was appended since the last call; true when something changed.
--- 増えた分だけ読んで足す。変化があれば true
function M.poll(run)
  if not run or not run.dir then return false end
  local hsize, esize = store.size(run.dir, "hooks.jsonl"), store.size(run.dir, "events.jsonl")
  if hsize == run.off.hooks and esize == run.off.events then return false end
  if hsize < run.off.hooks or esize < run.off.events then
    -- ファイルが作り直された：最初から読み直す
    local fresh = M.load(run.dir)
    run.state, run.off, run.source = fresh.state, fresh.off, fresh.source
    return true
  end
  local hooks, hoff = store.read_new(run.dir, "hooks.jsonl", run.off.hooks)
  local evs, eoff = store.read_new(run.dir, "events.jsonl", run.off.events)
  local new = normalize_all(hooks, provider_of(run))
  for _, ev in ipairs(evs) do
    ev._fo = 1
    new[#new + 1] = ev
  end
  sort_events(new)
  local seq = run.state.last_seq or 0
  for _, ev in ipairs(new) do
    seq = seq + 1
    ev.seq = seq
    state_mod.apply(run.state, ev)
  end
  run.off = { hooks = hoff, events = eoff }
  if hoff > 0 then run.source = "hooks" elseif eoff > 0 and run.source == "empty" then run.source = "transcript" end
  save(run)
  return #new > 0
end

--- Record an event from Neovim (e.g. a review result) and apply it to the state.
--- Neovim 側で起きたこと（レビュー結果など）を記録して状態に足す
function M.emit(run, ev)
  if not run or not run.dir then return nil end
  M.poll(run) -- 先に追いついておく（自分で書いた分を二重に読まないため）
  ev.v = 1
  ev.ts = ev.ts or util.iso_now()
  ev.run_id = ev.run_id or run.sid
  ev.src = ev.src or "user"
  store.ensure(run.dir)
  store.append_event(run.dir, ev)
  run.off.events = store.size(run.dir, "events.jsonl")
  ev.seq = (run.state.last_seq or 0) + 1
  state_mod.apply(run.state, ev)
  save(run)
  return ev
end

--- Fill in missing information (model, parent, transcript path) from Claude's files.
--- 足りない情報を Claude のファイルから補う（見つかったものだけ記録に残す）
function M.enrich(run)
  if not run or not run.state then return false end
  local prov = provider_of(run)
  local s = run.state
  local changed = false
  local function sys(ev)
    ev.src = "system"
    M.emit(run, ev)
    changed = true
  end
  run._enrich = run._enrich or { tried_meta = {}, tried_tp = {}, tried_model = {}, tried_task = {} }
  local memo = run._enrich
  memo.tried_task = memo.tried_task or {}

  -- ROOT のモデル名（取れるまで試す）
  --   ここが呼ばれるのは記録が増えたときだけ。短い run は数秒で終わり、
  --   終わったあとは記録が増えないので、間隔を空けすぎると取り直す機会が来ない。
  --   そこで間隔は短くし、run が終わった直後の1回は間隔に関係なく必ず試す
  --   （起動直後に開いた・新しい run に自動で切り替えたときに「model: ?」のまま残らないように）。
  local root = s.agents.ROOT
  if root and not root.model then
    local now = uv.now() / 1000
    local just_ended = s.ended_at and not memo.root_model_after_end
    if just_ended then memo.root_model_after_end = true end
    if just_ended or not memo.root_model_at or now - memo.root_model_at >= ROOT_MODEL_RETRY then
      memo.root_model_at = now
      local tp = s.root_transcript or prov.agent_transcript_path(run, root)
      local ok, m = pcall(prov.root_model, tp)
      if ok and m then sys({ event = "agent_updated", agent_id = "ROOT", model = m }) end
    end
  end

  -- 親の同じ 1 通の返事でまとめて起動された印（batch = message.id）と、親の直前の発言（lead）。
  --   どちらも hooks には無いので親の transcript から引く。
  --   読むのは transcript の増えた分だけ（memo.batch_idx に続きの位置を覚える）
  if prov.agent_batches then
    memo.batch_idx = memo.batch_idx or {}
    local read_now = {} -- 1 回の呼び出しで同じ transcript を読むのは 1 度だけ
    local function idx_of(owner_id)
      local p = s.agents[owner_id]
      local path = p and ((owner_id == "ROOT" and (s.root_transcript or prov.agent_transcript_path(run, p)))
        or p.transcript_path)
      if not path then return nil end
      if not read_now[path] then
        read_now[path] = true
        local ok, idx = pcall(prov.agent_batches, path, memo.batch_idx[path])
        if ok and idx then memo.batch_idx[path] = idx end
      end
      return memo.batch_idx[path]
    end
    for _, id in ipairs(s.order) do
      local a = s.agents[id]
      if a and id ~= "ROOT" and (not a.batch or not a.lead or not a.brief) and a.tool_use_id and a.parent_id then
        local idx = idx_of(a.parent_id)
        local b = idx and not a.batch and idx.map[a.tool_use_id] or nil
        local l = idx and not a.lead and idx.lead and idx.lead[a.tool_use_id] or nil
        -- 任せた理由（【目的】など）：収集係が【】を抜く前に記録された run では hooks に無いので、
        -- 親の transcript の Agent 呼び出し（prompt の全文がある）から読み直す。空欄のときだけ
        local br = idx and not a.brief and idx.brief and idx.brief[a.tool_use_id] or nil
        if b or l or br then sys({ event = "agent_updated", agent_id = id, batch = b, lead = l, brief = br }) end
      end
    end
    -- HUMAN CHECK：聞いた側の直前の発言（聞いた側が ROOT なら親の transcript）
    for _, cid in ipairs(s.check_order or {}) do
      local c = s.checks and s.checks[cid]
      if c and not c.lead and c.tool_use_id then
        local idx = idx_of(c.asker_id or "ROOT")
        local l = idx and idx.ask_lead and idx.ask_lead[c.tool_use_id]
        if l then sys({ event = "check_updated", tool_use_id = c.tool_use_id, lead = l }) end
      end
    end
  end

  -- 任せた理由の予備：親の transcript から読めなかった（親が Workflow・親の transcript が無い）Agent は、
  --   その Agent 自身の transcript の最初の依頼文（親の prompt と同じ文）から 1 回だけ読む
  if prov.first_prompt_brief then
    memo.tried_brief = memo.tried_brief or {}
    for _, id in ipairs(s.order) do
      local a = s.agents[id]
      if a and id ~= "ROOT" and a.kind ~= "workflow" and not a.placeholder and not a.brief
          and a.transcript_path and not memo.tried_brief[id] then
        memo.tried_brief[id] = true
        local ok, br = pcall(prov.first_prompt_brief, a.transcript_path)
        if ok and type(br) == "table" then sys({ event = "agent_updated", agent_id = id, brief = br }) end
      end
    end
  end

  -- 子の報告：収集係が SubagentStop で同封できなかったとき（transcript がまだ書き終わっていなかったなど）の予備。
  --   終わった Agent ごとに 1 回だけ、その Agent の transcript の末尾を読む
  if prov.agent_report then
    memo.tried_report = memo.tried_report or {}
    for _, id in ipairs(s.order) do
      local a = s.agents[id]
      if a and id ~= "ROOT" and a.kind ~= "workflow" and not a.placeholder and not a.report
          and a.transcript_path and not memo.tried_report[id]
          and (a.status == "DONE" or a.status == "REWORK" or a.status == "FAILED") then
        memo.tried_report[id] = true
        local ok, rep = pcall(prov.agent_report, a.transcript_path)
        if ok and type(rep) == "string" and rep ~= "" then
          sys({ event = "agent_updated", agent_id = id, report = rep })
        end
      end
    end
  end

  local ids = vim.deepcopy(s.order)
  for _, id in ipairs(ids) do
    local a = s.agents[id]
    if a and id ~= "ROOT" and not a.placeholder and a.kind ~= "workflow" then
      -- Claude の meta.json（toolUseId / parentAgentId / spawnDepth / model / description）を 1 回だけ読む
      --   親が分からないときは親を結ぶ。Workflow の Agent は meta.json の場所から Workflow の id が分かる
      if (not a.parent_id or not a.model or not a.task) and not memo.tried_meta[id] then
        memo.tried_meta[id] = true
        local ok, meta, mpath = pcall(prov.read_meta, run, id)
        if ok and type(meta) == "table" then
          local wf = prov._wf_of_path and prov._wf_of_path(mpath) or nil
          if not a.parent_id then
            local req = meta.toolUseId and s.spawn_requests[meta.toolUseId]
            local parent = (req and req.parent_id)
            if not parent and type(meta.parentAgentId) == "string" and meta.parentAgentId ~= "" then
              parent = meta.parentAgentId
            end
            if not parent and wf then parent = "wf:" .. wf end
            if not parent and prov._meta_parent then parent = prov._meta_parent(meta) end
            if parent then
              sys({
                event = "agent_linked", agent_id = id, parent_id = parent, source = "meta",
                tool_use_id = meta.toolUseId, task = meta.description, agent_type = meta.agentType,
                wf_id = wf,
              })
            end
          end
          -- モデル名は transcript の本物を優先し、meta.json の別名（"opus" など）は取れなかったときの予備
          memo.meta_model = memo.meta_model or {}
          memo.meta_model[id] = meta.model
          if meta.description or wf or meta.workflowPhase then
            sys({
              event = "agent_updated", agent_id = id, task = meta.description,
              wf_id = wf, phase = meta.workflowPhase,
            })
          end
        end
      end
      -- transcript の場所
      if not a.transcript_path and not memo.tried_tp[id] then
        memo.tried_tp[id] = true
        local ok, p = pcall(prov.agent_transcript_path, run, a)
        if ok and p and uv.fs_stat(p) then
          sys({ event = "agent_updated", agent_id = id, transcript_path = p })
        end
      end
      -- モデル名：hooks から取れなかったときだけ、その Agent の transcript から
      a = s.agents[id]
      if a and not a.model and a.transcript_path and not memo.tried_model[id] then
        if a.status ~= "RUNNING" and a.status ~= "PENDING" then memo.tried_model[id] = true end
        local ok, m = pcall(prov.root_model, a.transcript_path)
        if not (ok and m) and memo.tried_model[id] and memo.meta_model then m, ok = memo.meta_model[id], true end
        if ok and m then sys({ event = "agent_updated", agent_id = id, model = m }) end
      end
      a = s.agents[id]
      if a and not a.model and not a.transcript_path and memo.meta_model and memo.meta_model[id]
          and a.status ~= "RUNNING" and a.status ~= "PENDING" then
        sys({ event = "agent_updated", agent_id = id, model = memo.meta_model[id] })
      end
      -- 仕事の名前が無い（Workflow の Agent など）：その Agent の最初の依頼文の 1 行目
      a = s.agents[id]
      if a and not a.task and a.transcript_path and not memo.tried_task[id] and prov.first_prompt_line then
        if a.status ~= "RUNNING" and a.status ~= "PENDING" then memo.tried_task[id] = true end
        local ok, h = pcall(prov.first_prompt_line, a.transcript_path)
        if ok and h then
          sys({ event = "agent_updated", agent_id = id, task = h, name = (not a.name) and h or nil })
        end
      end
    end
  end
  return changed
end

--- Look up the git branch of an agent asynchronously and record it.
--- git のブランチ名を非同期で調べて記録する（詳細画面・書き出しから呼ぶ）
function M.enrich_branch(run, id, cb)
  local a = run and run.state and run.state.agents[id]
  local dir = (a and a.cwd) or (run and run.state and run.state.cwd)
  if not a or a.branch or not dir or vim.fn.isdirectory(dir) == 0 then
    if cb then cb(a and a.branch) end
    return
  end
  vim.system({ "git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" }, { text = true }, function(r)
    vim.schedule(function()
      local b = r.code == 0 and vim.trim(r.stdout or "") or nil
      if b and b ~= "" then
        M.emit(run, { event = "agent_updated", agent_id = id, branch = b, src = "system" })
      end
      if cb then cb(b) end
    end)
  end)
end

-- ---------- run を探す ----------

local function newest_run(slug)
  local rs = store.runs(slug)
  return rs[1]
end

--- Newest run of the current folder (else the newest of all projects), or nil.
--- 今のフォルダの最新の run（無ければ全プロジェクトで最新）。何も無ければ nil
function M.current_run(cwd)
  local slug = store.project_for_cwd(cwd or vim.fn.getcwd())
  if slug then
    local r = newest_run(slug)
    if r then return M.load(r.dir) end
  end
  local best
  for _, p in ipairs(store.project_dirs()) do
    local r = newest_run(p.slug)
    if r and (not best or r.mtime > best.mtime) then best = r end
  end
  if best then
    vim.notify(require("agentmap.i18n").t("events.opening_latest"), vim.log.levels.INFO)
    return M.load(best.dir)
  end
  return nil
end

-- ---------- 指示ごとの流れを探す ----------

-- run のフォルダ → { h, e, st, run }（ファイルの大きさが同じ間は読み直さない）
local flow_memo = {}

--- run の状態を、控えが古ければ作り直してから返す（hooks のある run だけ）
---   一度読み込んだ run は覚えておき、ファイルが増えたら増えた分だけ足す（毎回全部を計算し直さない）
local function fresh_state(dir)
  local h, e = store.size(dir, "hooks.jsonl"), store.size(dir, "events.jsonl")
  local m = flow_memo[dir]
  if m and m.h == h and m.e == e then return m.st end
  if m and m.run and h >= m.h and e >= m.e then
    local ok = pcall(M.poll, m.run)
    if ok then
      m.h, m.e, m.st = h, e, m.run.state
      return m.st
    end
  end
  local st = store.read_state(dir)
  local run = nil
  if not (type(st) == "table" and st.sv == state_mod.SV and type(st._off) == "table"
      and st._off.hooks == h and st._off.events == e) then
    local ok, r = pcall(M.load, dir)
    run = ok and r or nil
    st = run and run.state or nil
  end
  flow_memo[dir] = { h = h, e = e, st = st, run = run }
  return st
end
M._fresh_state = fresh_state

--- slug のプロジェクトの run 一覧。slug が nil なら全プロジェクトの run（新しい順・各行に slug を付ける）
local function runs_of(slug)
  if slug then return store.runs(slug) end
  local all = {}
  for _, p in ipairs(store.project_dirs()) do
    for _, r in ipairs(store.runs(p.slug)) do r.slug = p.slug; all[#all + 1] = r end
  end
  table.sort(all, function(a, b) return a.mtime > b.mtime end)
  return all
end
M.runs_of = runs_of

--- Newest flow (a prompt with at least one real agent).
--- いちばん新しく始まった流れ（本物の Agent が 1 つ以上ある指示）を探す
---   slug = 探すプロジェクト。nil なら記録置き場の全プロジェクトから探す（Neovim を開いたフォルダは関係ない）
---   決め方：流れの開始時刻 → hooks.jsonl の最終更新 → セッション ID の順に大きいもの。動いているかどうかは見ない
---   live = 画面に出している run（あればその状態をそのまま使い、読み直さない）
--- @return table|nil run, table|nil flow, number|nil 見つかった run の最終更新時刻
function M.latest_flow(slug, live)
  local best_r, best_f, bt, bm
  for _, r in ipairs(runs_of(slug)) do
    -- 最後に書かれた時刻が、今見つかっている流れの開始より前の run には、それより新しい流れは無い
    if best_f and r.mtime < bt then break end
    if r.source == "hooks" then
      local is_live = live and live.dir == r.dir and live.state
      local st = is_live and live.state or fresh_state(r.dir)
      local fid = st and state_mod.latest_flow_id(st)
      local f = fid and state_mod.flow_of(st, fid)
      if f then
        local t = util.parse_iso(f.started_at) or 0
        -- 開始時刻が同じなら、あとから書かれた run を新しいと見なす
        if not best_f or t > bt or (t == bt and (r.mtime > bm or (r.mtime == bm and r.sid > best_r.sid))) then
          best_r, best_f, bt, bm = r, f, t, r.mtime
        end
      end
    end
  end
  if not best_r then return nil, nil end
  if live and live.dir == best_r.dir then return live, best_f, bm end
  return M.load(best_r.dir), best_f, bm
end

--- Newest flow over all projects -> run, flow_id; falls back to current_run(cwd), nil.
--- 全プロジェクトでいちばん新しい流れ → run, flow_id。流れがどこにも無ければ current_run(cwd) と nil（セッション全体）
function M.current_flow(cwd)
  local run, f = M.latest_flow(nil)
  if run and f then return run, f.id end
  return M.current_run(cwd), nil
end

--- 保存先の中から session_id の run フォルダを探す
local function find_run_dir(sid)
  for _, p in ipairs(store.project_dirs()) do
    local d = p.dir .. "/runs/" .. sid
    if uv.fs_stat(d) then return d, p.slug end
  end
  return nil
end

--- Claude の transcript の中から session_id のプロジェクト名札を探す
local function find_transcript_slug(sid)
  local base = config.claude_config_dir() .. "/projects"
  local hits = vim.fn.glob(base .. "/*/" .. sid .. ".jsonl", false, true)
  if hits[1] then return util.basename(util.dirname(hits[1])) end
  return nil
end

--- Import a session without hooks from its transcript (reuses an earlier import).
--- hooks が無い session を transcript から取り込む（2 回目以降は取り込み済みを使う）
function M.import_transcript(sid, slug)
  slug = slug or find_transcript_slug(sid)
  if not slug then return nil end
  local dir = store.run_dir(slug, sid)
  local has_hooks = store.size(dir, "hooks.jsonl") > 0
  local already = false
  for _, ev in ipairs((store.read_new(dir, "events.jsonl", 0))) do
    if ev.src == "transcript" then already = true break end
  end
  if not already then
    local evs = provider_of({ provider = "claude" }).backfill(sid, slug)
    if #evs == 0 then return nil end
    store.ensure(dir)
    if has_hooks then
      -- hooks の記録がある run には、親子と開始・終了の骨組みを足さない（二重になるため）
      local keep = {}
      for _, ev in ipairs(evs) do
        if ev.event == "agent_updated" then keep[#keep + 1] = ev end
      end
      evs = keep
    end
    store.append_events(dir, evs)
    local pdir = config.root() .. "/projects/" .. slug
    if not uv.fs_stat(pdir .. "/project.json") then
      local cwd
      for _, ev in ipairs(evs) do if ev.event == "run_started" then cwd = ev.cwd break end end
      util.write_atomic(pdir .. "/project.json",
        util.json_encode({ cwd = cwd, slug = slug, updated_at = util.iso_now() }) or "{}")
    end
  end
  return M.load(dir)
end

--- Open the run of session `sid` (default: current_run()).
--- session_id を指定して開く。省略時は current_run()
function M.open_run(sid)
  if not sid or sid == "" then return M.current_run() end
  local dir = find_run_dir(sid)
  if not dir then
    -- 先頭の数文字だけでも探す
    for _, p in ipairs(store.project_dirs()) do
      for _, r in ipairs(store.runs(p.slug)) do
        if r.sid:sub(1, #sid) == sid then dir = r.dir break end
      end
      if dir then break end
    end
  end
  if dir then return M.load(dir) end
  return M.import_transcript(sid)
end

--- List runs, newest first: recorded by hooks, imported, and history only (transcript only).
--- run の一覧（新しい順）。hooks あり・取り込み済み・履歴のみ（transcript だけ）を合わせる
--- { {sid, slug, dir?, mtime, source = "hooks"|"transcript"|"history", cwd, title, agents, status} }
--- opts.slug を渡すとそのプロジェクトだけ
function M.list_runs(opts)
  opts = opts or {}
  local out, seen = {}, {}
  local projects = store.project_dirs()
  for _, p in ipairs(projects) do
    if not opts.slug or opts.slug == p.slug then
      local pj = store.read_project(p.slug) or {}
      for _, r in ipairs(store.runs(p.slug)) do
        if r.source ~= "empty" then
          local st = (r.source == "hooks" and fresh_state(r.dir)) or store.read_state(r.dir) or {}
          local c = st.counts or {}
          local rows = 0
          -- 指示ごとの流れがあれば、流れ 1 つにつき 1 行
          for _, f in ipairs(type(st.flows) == "table" and st.flows or {}) do
            if (f.agents or 0) > 0 then
              rows = rows + 1
              out[#out + 1] = {
                sid = r.sid, slug = p.slug, dir = r.dir, mtime = r.mtime, source = r.source,
                cwd = st.cwd or pj.cwd, title = f.prompt_head, agents = f.agents, status = f.status,
                started_at = f.started_at, flow_id = f.id, flow_n = f.n, flow_total = #st.flows,
                _key = util.parse_iso(f.started_at),
              }
            end
          end
          if rows == 0 then
            out[#out + 1] = {
              sid = r.sid, slug = p.slug, dir = r.dir, mtime = r.mtime, source = r.source,
              cwd = st.cwd or pj.cwd, title = st.title, agents = c.agents,
              status = st.agents and st.agents.ROOT and st.agents.ROOT.status or nil,
              started_at = st.started_at,
            }
          end
          seen[r.sid] = true
        end
      end
    end
  end
  -- Claude の transcript だけある session（hooks を入れる前の履歴）
  local prov = provider_of({ provider = "claude" })
  local base = config.claude_config_dir() .. "/projects"
  local h = uv.fs_scandir(base)
  while h do
    local name, typ = uv.fs_scandir_next(h)
    if not name then break end
    if typ == "directory" and (not opts.slug or opts.slug == name) then
      for _, sess in ipairs(prov.list_sessions(name)) do
        if not seen[sess.session_id] then
          out[#out + 1] = {
            sid = sess.session_id, slug = name, dir = nil, mtime = sess.mtime,
            source = "history", size = sess.size, -- 言語に依らない符号（表示は common.source_history）
          }
        end
      end
    end
  end
  -- 新しい順。流れの行は指示の時刻、それ以外は最後に書かれた時刻で比べる
  local function key(x) return x._key or x.mtime or 0 end
  table.sort(out, function(a, b)
    local ka, kb = key(a), key(b)
    if ka ~= kb then return ka > kb end
    if (a.mtime or 0) ~= (b.mtime or 0) then return (a.mtime or 0) > (b.mtime or 0) end
    return (a.flow_n or 0) > (b.flow_n or 0)
  end)
  for _, x in ipairs(out) do x._key = nil end
  return out
end

return M
