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
--    poll_steps(run)    … 動いている Agent の transcript から手順表（## Steps）を読み足す（DESIGN-v0.2 §2.1）
--    request_steer / mark_steer_sent / cancel_steer / sweep_steers
--                       … 修正指示（steer）の未配達ファイルと記録（DESIGN-v0.2-steer §5.3）
-- ============================================================
local config = require("agentmap.config")
local util = require("agentmap.util")
local store = require("agentmap.store")
local state_mod = require("agentmap.state")
local providers = require("agentmap.providers")

local M = {}
local uv = vim.uv or vim.loop

local brief = require("agentmap.brief")

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
  -- 宛先が終わった未配達の修正指示を片付ける（記録が増えたときだけ。sweep の中の emit から戻ってきたときは呼ばない）
  if #new > 0 and not run._sweeping then pcall(M.sweep_steers, run) end
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

-- ---------- 手順表（## Steps の目印）を読む ----------

-- 秒。transcript の場所が分からなかった Agent を次に探すまでの間。Agent の transcript は始まってから最初の
-- 発言まで（1〜3 秒）存在しないので、最初の tick で見つからないのが普通。長く待つと「## Steps」がその分遅れて出る
local STEPS_PATH_RETRY = 2

--- Read new step lists / step marks from the transcripts of running agents and record changes.
--- 動いている Agent（RUNNING / REVIEW。ROOT を含む）の transcript の増えた分から手順表を読み、
--- 一覧か印が変わったときだけ steps_updated を記録する。終わった Agent は終わった直後に 1 回だけ読んで打ち切る。
--- 大きさが前回と同じ transcript は読まない。enrich の中からは呼ばない（二重読みを避ける）
---@return boolean changed
function M.poll_steps(run)
  if not run or not run.state then return false end
  local prov = provider_of(run)
  if not prov.agent_steps or not prov.steps_of then return false end
  local s = run.state
  run._steps = run._steps or {}
  local now = uv.now() / 1000
  local changed = false
  for _, id in ipairs(vim.deepcopy(s.order)) do
    local a = s.agents[id]
    if a and a.kind ~= "workflow" and not a.placeholder then
      local memo = run._steps[id]
      local live = a.status == "RUNNING" or a.status == "REVIEW"
      local last = (not live) and memo and not memo.final -- 終わった直後の 1 回
      if live or last then
        memo = memo or {}
        run._steps[id] = memo
        local path = (id == "ROOT" and s.root_transcript) or a.transcript_path
        if not path and (not memo.miss_at or now - memo.miss_at >= STEPS_PATH_RETRY) then
          local ok, p = pcall(prov.agent_transcript_path, run, a)
          path = ok and p or nil
          if not (path and uv.fs_stat(path)) then memo.miss_at, path = now, nil end
        end
        path = path or memo.path
        local st = path and uv.fs_stat(path)
        if st then
          if memo.path ~= path then memo.path, memo.idx, memo.size = path, nil, nil end
          if st.size ~= memo.size then
            memo.size = st.size
            local ok, idx = pcall(prov.agent_steps, path, memo.idx)
            if ok and type(idx) == "table" then
              memo.idx = idx
              local steps = prov.steps_of(idx)
              if steps and not vim.deep_equal(steps, a.steps) then
                M.emit(run, { event = "steps_updated", agent_id = id, src = "system", steps = steps })
                changed = true
              end
            end
          end
        end
        if last then memo.final = true end
      end
    end
  end
  return changed
end

-- ---------- 修正指示（steer）----------
--   <root>/projects/<slug>/runs/<sid>/steer/<agent_id|ROOT>-<ms>.json … 未配達（Neovim が書く。0600）
--   <root>/steer.pending                                              … どこかに未配達がある印（Neovim が作って消す）

local STEER_EXPIRE_GRACE = 3 -- 秒。宛先が終わってからこれだけ待って期限切れにする（終わりの hook が配達する間を空ける）

--- run のフォルダから記録の保存先（<root>）を逆算する
local function root_of(run)
  local r = run and run.dir and run.dir:match("^(.*)/projects/[^/]+/runs/[^/]+/?$")
  return r or config.root()
end

local function flag_path(run) return root_of(run) .. "/steer.pending" end
local function steer_dir(run) return run.dir .. "/steer" end

local last_ms = 0
--- 未配達ファイルの名前の <ms>（壁時計のミリ秒。同じ Neovim の中では必ず増える）
local function new_ms()
  local sec, usec = uv.gettimeofday()
  local ms = sec and (sec * 1000 + math.floor(usec / 1000)) or os.time() * 1000
  if ms <= last_ms then ms = last_ms + 1 end
  last_ms = ms
  return ms
end

--- 0600 で書いてから名前を付ける（途中の内容を hook に読ませない）
local function write_private(path, text)
  vim.fn.mkdir(util.dirname(path), "p")
  local tmp = path .. ".tmp." .. tostring(uv.os_getpid())
  local fd, err = uv.fs_open(tmp, "w", 384) -- 0600
  if not fd then return false, err end
  uv.fs_write(fd, text, -1)
  uv.fs_close(fd)
  uv.fs_chmod(tmp, 384)
  local ok, rerr = uv.fs_rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return false, rerr
  end
  return true
end

local function touch_flag(run)
  local p = flag_path(run)
  if uv.fs_stat(p) then return true end
  local fd = uv.fs_open(p, "a", 384)
  if not fd then return false end
  uv.fs_close(fd)
  return true
end

--- 未配達ファイルの名前（<target>-<ms>.json。.delivered.json などは含まない）か
local function is_pending_name(name)
  return name:match("^[%w_%-]+%-%d+%.json$") ~= nil
end

-- 秒。これより古い未配達ファイルは、もう届かないものとして消す（開かれない run に残ると印が消えず、
-- 全セッションの道具の呼び出しごとに Python が起動し続けるため）。道具を使う宛先なら数秒で届くので十分に長い。
-- 消した指示は、その run を開いたときに sweep_steers が EXPIRED にする
local STEER_STALE = 6 * 3600
M.STEER_STALE = STEER_STALE

--- どの run にも未配達ファイルが無ければ <root>/steer.pending を消す。消したら true
local function sweep_flag(run, now)
  local p = flag_path(run)
  if not uv.fs_stat(p) then return false end
  local root = root_of(run)
  now = now or os.time()
  local live = false
  for _, f in ipairs(vim.fn.glob(root .. "/projects/*/runs/*/steer/*.json", false, true)) do
    if is_pending_name(util.basename(f)) then
      local st = uv.fs_stat(f)
      if st and now - st.mtime.sec > STEER_STALE then
        os.remove(f)
      else
        live = true
      end
    end
  end
  if live then return false end
  os.remove(p)
  return true
end
M._sweep_flag = sweep_flag

--- Queue a steering instruction for an agent.
---   via = "hook": writes <run>/steer/<agent_id>-<ms>.json (0600), touches <root>/steer.pending and records
---   steer_requested. via = "terminal": records steer_requested only (the caller sends it, then mark_steer_sent).
---@param run table
---@param agent_id string "ROOT" or an agent id
---@param text string the instruction (clipped to steer.text_max characters)
---@param opts? { via?: "hook"|"terminal", kind?: "steer"|"redo"|"notice", redo_of?: string, notice_of?: string, prompt_id?: string }
---   kind = "notice" with notice_of = <steer_id>: a notice to the parent about an instruction delivered to its
---   sub-agent (DESIGN-v0.2-steer appendix E; created by the UI). The state links them both ways
---   (s.steers[id].notice_of and s.steers[notice_of].notice_id). Before writing, the records are read once
---   more; when the instruction already has a notice (made by this or another Neovim showing the same run)
---   nothing is written and "duplicate" is returned.
---@return string|nil steer_id, string|nil err  err: "no_run" | "bad_target" | "empty" | "duplicate" | write error
function M.request_steer(run, agent_id, text, opts)
  opts = opts or {}
  if not run or not run.dir or not run.state then return nil, "no_run" end
  if type(agent_id) ~= "string" or not agent_id:match("^[%w_%-]+$") then return nil, "bad_target" end
  if type(text) ~= "string" or not text:find("%S") then return nil, "empty" end
  if opts.kind == "notice" and opts.notice_of then
    M.poll(run) -- 別の Neovim が先に知らせを作っていれば、ここで state に入る
    local orig = state_mod.steer_of(run.state, opts.notice_of)
    if orig and orig.notice_id then return nil, "duplicate" end
  end
  local scfg = config.get().steer or {}
  text = brief.clip(text, tonumber(scfg.text_max) or 4000)
  local via = opts.via == "terminal" and "terminal" or "hook"
  local id = agent_id .. "-" .. tostring(new_ms())
  if via == "hook" then
    local body = util.json_encode({ id = id, agent_id = agent_id, text = text, created_at = util.iso_now(),
      by = "nvim", lang = config.get().lang })
    local ok, err = write_private(steer_dir(run) .. "/" .. id .. ".json", body or "")
    if not ok then return nil, tostring(err) end
    touch_flag(run)
  end
  M.emit(run, {
    event = "steer_requested", steer_id = id, agent_id = agent_id, text = text, via = via,
    prompt_id = opts.prompt_id or state_mod.latest_flow_id(run.state),
    kind = opts.kind or "steer", redo_of = opts.redo_of, notice_of = opts.notice_of,
  })
  return id
end

--- Record that a terminal instruction was sent (steer_delivered, via = "terminal").
---@return boolean
function M.mark_steer_sent(run, steer_id)
  local st = run and run.state and state_mod.steer_of(run.state, steer_id)
  if not st then return false end
  M.emit(run, { event = "steer_delivered", steer_id = steer_id, agent_id = st.agent_id, via = "terminal" })
  return true
end

--- Cancel a pending instruction. Removes its file; if the file is gone, a hook already took it and
--- nothing is recorded (returns false, "delivered").
---@return boolean ok, string|nil err
function M.cancel_steer(run, steer_id)
  local st = run and run.state and state_mod.steer_of(run.state, steer_id)
  if not st then return false, "unknown" end
  if st.status ~= "PENDING" then return false, st.status:lower() end
  if st.via ~= "terminal" then
    local ok = os.remove(steer_dir(run) .. "/" .. steer_id .. ".json")
    if not ok then return false, "delivered" end
  end
  M.emit(run, { event = "steer_cancelled", steer_id = steer_id })
  pcall(sweep_flag, run)
  return true
end

--- 宛先が終わったか（終わってから STEER_EXPIRE_GRACE 秒たったか）。理由の符号か nil
local function expire_reason(s, st, now)
  if s.ended_at then return "session_ended" end
  if st.agent_id == "ROOT" then
    -- ROOT は指示の番が終わって、その流れに動いているものが無ければ（止まっている ROOT には hooks で届かない）
    local f = st.prompt_id and state_mod.flow_of(s, st.prompt_id)
    local t = f and f.ended_at and util.parse_iso(f.ended_at)
    if f and f.status == "DONE" and t and now - t >= STEER_EXPIRE_GRACE then return "agent_finished" end
    return nil
  end
  local a = s.agents[st.agent_id]
  if a and (a.status == "DONE" or a.status == "REWORK" or a.status == "FAILED") then
    local t = util.parse_iso(a.finished_at)
    if not t or now - t >= STEER_EXPIRE_GRACE then return "agent_finished" end
  end
  return nil
end

--- Expire pending instructions whose target finished (or whose session ended): remove the file and
--- record steer_expired. Also removes <root>/steer.pending when no pending file is left anywhere.
---@return boolean changed
function M.sweep_steers(run, now)
  if not run or not run.state or not run.dir then return false end
  local s = run.state
  now = now or os.time()
  local changed = false
  run._sweeping = true
  local ok, err = pcall(function()
    for _, sid in ipairs(vim.deepcopy(s.steer_order or {})) do
      local st = s.steers[sid]
      local reason = st and st.status == "PENDING" and expire_reason(s, st, now)
      if reason then
        local gone = true
        if st.via ~= "terminal" then
          local p = steer_dir(run) .. "/" .. sid .. ".json"
          if uv.fs_stat(p) then
            gone = os.remove(p) ~= nil
          else
            -- ファイルが無い：hook が取った（配達の記録が後から来る）なら何もしない
            local taken = uv.fs_stat(steer_dir(run) .. "/" .. sid .. ".delivered.json")
              or #vim.fn.glob(steer_dir(run) .. "/" .. sid .. ".delivering.*", false, true) > 0
            gone = not taken
          end
        end
        if gone then
          M.emit(run, { event = "steer_expired", steer_id = sid, reason = reason })
          changed = true
        end
      end
    end
  end)
  run._sweeping = nil
  if not ok then error(err) end
  -- 印の掃除：何かが変わったとき、未配達が 0 になったとき、開いて最初の 1 回
  local pending = (s.counts and s.counts.steers_pending) or 0
  if changed or (pending == 0 and (run._steer_pending == nil or run._steer_pending > 0)) then
    pcall(sweep_flag, run)
  end
  run._steer_pending = pending
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
