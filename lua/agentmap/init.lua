-- ============================================================
--  agentmap ... shows what AI agents (Claude Code) are doing as a map in Neovim.
--    Entry point only: user commands, optional global keys and setup(); the work
--    lives in the other modules, which are loaded when a command is used.
--    setup() is optional: every public function calls it once with {} if needed.
--
--    :AgentMap [session_id [prompt_id]]  open the map of the latest prompt
--    :AgentMapRuns                       list past runs
--    :AgentMapAgent <index|id>           agent details
--    :AgentMapRefresh                    reload
--    :AgentMapExport <format> [path]     export (markdown / html / pdf)
--    :AgentMapReview <index|id> <PASS|RETRY|ESCALATE|SUBMIT> [reason]
--    :AgentMapInstallHooks [path]        register the recording hooks in Claude Code's settings.json
--    :AgentMapImport [session_id]        import a run that has no records from Claude's transcript
-- ============================================================
local M = {}

local function notify(msg, lvl)
  vim.notify("AgentMap: " .. msg, lvl or vim.log.levels.INFO)
end

local function tr(key, vars)
  return require("agentmap.i18n").t(key, vars)
end

-- setup() が一度でも呼ばれたか。呼ばれていなければ、公開関数の入口で setup({}) を呼ぶ
local did_setup = false
local function ensure_setup()
  if not did_setup then M.setup({}) end
end

--- 読み込めなければ nil（理由も返す）
local function try(name)
  local ok, m = pcall(require, name)
  if ok then return m end
  return nil, m
end

--- 読み込めなければ止める（guard の中で使う）
local function need(name)
  local m, err = try(name)
  if not m then error(tr("init.require_failed", { name = name, err = tostring(err) }), 0) end
  return m
end

--- エラーで止まらないように包む。失敗したら知らせる
local function guard(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then notify(tr("init.error", { err = tostring(err) }), vim.log.levels.ERROR) end
    return ok and err or nil
  end
end

-- 見張り（自動更新）
local watch_run, watch_proj
local known_runs = {}

-- 新しい run が始まったら自動で切り替えるか。
--   :AgentMap（最新を開く）で開いたときは true。
--   一覧から選んだ・ID を指定したとき（わざわざ古い run を見ている）は false で、知らせるだけにする。
local follow_latest = true

-- 今見せているもの（新しい流れと比べるため）と、もう知らせた流れ
local shown = nil -- { sid, flow_id, t = 指示の時刻（秒）, mtime = hooks.jsonl の更新時刻 }
local notified = {}

local function short_head(s, n)
  s = tostring(s or ""):gsub("[\r\n]+", " ")
  if vim.fn.strchars(s) <= n then return s end
  return vim.fn.strcharpart(s, 0, n - 1) .. "…"
end

local function list_dir(dir)
  local out = {}
  local fs = vim.uv.fs_scandir(dir)
  while fs do
    local name, t = vim.uv.fs_scandir_next(fs)
    if not name then break end
    if t == "directory" then out[name] = true end
  end
  return out
end

--- 記録置き場の全プロジェクトで見張るもの（projects フォルダからの相対）。ほかのフォルダのセッションの動きにも気付くため
---   "" = projects フォルダ（新しいプロジェクト）、<slug>/runs = 新しい run のフォルダ、
---   新しい順に最大 20 個の run の hooks.jsonl（今見せている run は別に見張るので除く）
local function store_files(except_sid)
  local files = { "" }
  local store, events = try("agentmap.store"), try("agentmap.events")
  if not store or not events or not events.runs_of then return files end
  for _, p in ipairs(store.project_dirs()) do
    files[#files + 1] = p.slug .. "/runs"
  end
  local n = 0
  for _, r in ipairs(events.runs_of(nil)) do
    if r.sid ~= except_sid then
      files[#files + 1] = r.slug .. "/runs/" .. r.sid .. "/hooks.jsonl"
      n = n + 1
      if n >= 20 then break end
    end
  end
  return files
end

--- 全プロジェクトの run の一覧 { ["<slug>/<sid>"] = true }
local function all_run_keys()
  local out = {}
  local store = try("agentmap.store")
  if not store then return out end
  local base = require("agentmap.config").root() .. "/projects/"
  for _, p in ipairs(store.project_dirs()) do
    for sid in pairs(list_dir(base .. p.slug .. "/runs")) do out[p.slug .. "/" .. sid] = true end
  end
  return out
end

local function stop_watch()
  local w = try("agentmap.watch")
  if w then
    w.stop(watch_run)
    w.stop(watch_proj)
  end
  watch_run, watch_proj = nil, nil
end

local show -- 下で定義する（見張りの中から呼ぶため）

--- 同じ run の中で新しい指示の流れが始まったか調べて、追う・知らせる
--- いま見せている流れに、まだ動いているエージェントがいるか。
---   いるあいだは、新しい流れが始まっても自動では切り替えない（知らせるだけ）。
---   別のセッション（作業を頼んでいる Claude Code 自身など）が新しい流れを始めるたびに
---   図が移ると、「どれが終わってどれが動いているか」を最後まで見届けられないため。
---   見ている流れが終わると、次に記録が増えた時点で最新へ切り替わる。
-- 見ている流れが動いていたので、別の流れへの切り替えを見送ったか。
-- 見送ったあと見ている流れが終わったら、その時点で最新を探し直す。
local deferred_switch = false

local function shown_busy(ui)
  local ok, view = pcall(function() return ui.display_state and ui.display_state() end)
  if not ok or type(view) ~= "table" or type(view.agents) ~= "table" then return false end
  for id, a in pairs(view.agents) do
    if id ~= "ROOT" and (a.status == "RUNNING" or a.status == "PENDING" or a.status == "REVIEW") then
      return true
    end
  end
  return false
end

local function check_new_flow(ui)
  local st = try("agentmap.state")
  if not st or not ui.run or not ui.run.state then return end
  local nf = st.latest_flow_id(ui.run.state)
  if not nf or nf == ui.flow_id then return end
  local f = st.flow_of(ui.run.state, nf)
  local cur = ui.flow_id and st.flow_of(ui.run.state, ui.flow_id)
  -- 今見せている流れより前に始まったものなら何もしない
  if cur and f and (f.n or 0) < (cur.n or 0) then return end
  if follow_latest and shown_busy(ui) then
    if not notified[ui.run.sid .. ":" .. nf] then
      notified[ui.run.sid .. ":" .. nf] = true
      notify(tr("init.new_flow_deferred"))
    end
  elseif follow_latest then
    ui.set_flow(nf)
    local util = try("agentmap.util")
    shown = shown or {}
    shown.flow_id = nf
    shown.t = util and util.parse_iso(f and f.started_at) or shown.t
    notify(tr("init.switched_flow", { head = short_head(f and f.prompt_head or "", 30) }))
  elseif not notified[ui.run.sid .. ":" .. nf] then
    notified[ui.run.sid .. ":" .. nf] = true
    notify(tr("init.new_flow_pinned"))
  end
end

--- 図を開いた run の変化を見張る
local function start_watch(run)
  stop_watch()
  deferred_switch = false
  local w = try("agentmap.watch")
  if not w or not run or not run.dir then return end
  local on_proj  -- 下で中身を入れる（見ている流れが終わったとき、ここから呼ぶため）
  watch_run = w.start(run.dir, function()
    local ui, events = try("agentmap.ui"), try("agentmap.events")
    if not ui or not events or not ui.run then return end
    local changed = events.poll(ui.run)
    -- ROOT のモデル名など、hooks に無い情報を Claude のファイルから補う（見つかったときだけ記録）
    if events.enrich then
      local ok, more = pcall(events.enrich, ui.run)
      changed = changed or (ok and more)
    end
    if changed then
      pcall(check_new_flow, ui)
      ui.refresh()
      -- 切り替えを見送っていて、見ている流れが終わったなら、ここで最新を探し直す
      -- すぐには切り替えず、全部終わった画面を少しのあいだ見せてから切り替える
      if deferred_switch and follow_latest and on_proj and not shown_busy(ui) then
        deferred_switch = false
        local shown_sid = ui.run and ui.run.sid
        local delay = need("agentmap.config").get().switch_delay_ms or 15000
        vim.defer_fn(function()
          -- その間にほかの画面へ移っていたら何もしない
          local u = try("agentmap.ui")
          if not follow_latest or not u or not u.run or u.run.sid ~= shown_sid then return end
          if shown_busy(u) then deferred_switch = true return end
          pcall(on_proj)
        end, delay)
      end
    end
  end)

  -- どのフォルダ（プロジェクト）でも、新しい run ができた・ほかの run で新しい指示の流れが始まったら、切り替える（固定中は知らせる）
  local projects_dir = need("agentmap.config").root() .. "/projects"
  known_runs = all_run_keys()
  on_proj = function()
    local now = all_run_keys()
    for key in pairs(now) do
      if not known_runs[key] then
        known_runs = now
        -- 見張るファイルの一覧を作り直す（新しい run の hooks.jsonl も見る）
        w.stop(watch_proj)
        watch_proj = w.start(projects_dir, on_proj, { files = store_files(run.sid) })
        if not follow_latest then
          local sid = key:match("/([^/]+)$") or key
          notify(tr("init.new_run_pinned", { sid = sid:sub(1, 8) }))
          return
        end
        break
      end
    end
    known_runs = now
    local events, ui = try("agentmap.events"), try("agentmap.ui")
    if not events or not ui or not ui.run or not events.latest_flow then return end
    local r, f, mt = events.latest_flow(nil, ui.run)
    if not r or not f or r.sid == ui.run.sid then return end
    local util = need("agentmap.util")
    local t = util.parse_iso(f.started_at) or 0
    mt = mt or 0
    local cur = shown or { t = 0, mtime = 0 }
    if t < (cur.t or 0) or (t == (cur.t or 0) and mt <= (cur.mtime or 0)) then return end
    -- いま見ている流れが動いている間は切り替えない（shown_busy の説明を参照）
    local busy = shown_busy(ui)
    if follow_latest and not busy then
      notify(tr("init.switched_run", { sid = r.sid:sub(1, 8) }))
      show(r, f.id)
    elseif follow_latest and busy then
      deferred_switch = true
      if not notified[r.sid .. ":" .. f.id] then
        notified[r.sid .. ":" .. f.id] = true
        notify(tr("init.new_flow_deferred"))
      end
    elseif not notified[r.sid .. ":" .. f.id] then
      notified[r.sid .. ":" .. f.id] = true
      notify(tr("init.new_flow_pinned"))
    end
  end
  watch_proj = w.start(projects_dir, on_proj, { files = store_files(run.sid) })
end

--- 図が画面から消えたら見張りも止める（また表示されたら再開）
local function watch_buffer(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local group = vim.api.nvim_create_augroup("agentmap", { clear = false })
  vim.api.nvim_clear_autocmds({ group = group, buffer = buf })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufHidden" }, {
    group = group,
    buffer = buf,
    callback = function() stop_watch() end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      local ui = try("agentmap.ui")
      if not watch_run and ui and ui.run then
        local events = try("agentmap.events")
        if events then pcall(events.poll, ui.run) end
        pcall(ui.refresh)
        start_watch(ui.run)
      end
    end,
  })
end

--- 見張っているか（試験用）
function M._following()
  return follow_latest
end

function M._watching()
  return watch_run ~= nil
end

--- run を図にして見せる（flow_id を渡すとその指示の流れだけ。nil ならセッション全体）
function show(run, flow_id)
  local ui = need("agentmap.ui")
  local hl = try("agentmap.renderer")
  if hl and hl.setup_highlights then pcall(hl.setup_highlights) end
  local events = try("agentmap.events")
  if events and events.enrich then pcall(events.enrich, run) end
  ui.open_map(run, flow_id)
  -- 今見せているもの（あとから始まった流れと比べる基準）
  local st, util, store = try("agentmap.state"), try("agentmap.util"), try("agentmap.store")
  local f = flow_id and st and st.flow_of(run.state, flow_id)
  local mt = 0
  if store and run.slug then
    for _, x in ipairs(store.runs(run.slug)) do
      if x.sid == run.sid then mt = x.mtime end
    end
  end
  shown = {
    sid = run.sid, flow_id = flow_id, mtime = mt,
    t = util and util.parse_iso((f and f.started_at) or run.state.started_at) or 0,
  }
  notified = {}
  -- 開いた時点でもうある流れは「新しい流れ」として知らせない
  local latest = st and st.latest_flow_id(run.state)
  if latest then notified[run.sid .. ":" .. latest] = true end
  -- ほかのセッションでもう始まっている流れも同じ（古い流れを固定で開いたとき、既にある流れを「新しい」と言わない）
  if events and events.latest_flow then
    local ok, r2, f2 = pcall(events.latest_flow, nil, run)
    if ok and r2 and f2 then notified[r2.sid .. ":" .. f2.id] = true end
  end
  start_watch(run)
  watch_buffer(ui.buf)
end
M._show = show

--- Open the map of the latest prompt, or of run `sid` (optionally prompt `opts.flow`).
---@param sid? string session id (a prefix is enough)
---@param opts? { follow?: boolean, flow?: string }  follow defaults to "pinned when sid is given, else follow the latest"
function M.open(sid, opts)
  ensure_setup()
  local events = need("agentmap.events")
  if opts and opts.follow ~= nil then
    follow_latest = opts.follow
  else
    follow_latest = not (sid and sid ~= "")
  end
  local run, fid
  if sid and sid ~= "" then
    run = events.open_run(sid)
    if not run then
      notify(tr("init.run_not_found", { sid = sid }), vim.log.levels.WARN)
      return
    end
    local st = need("agentmap.state")
    local f = opts and opts.flow and st.flow_by_prefix(run.state, opts.flow)
    if opts and opts.flow and opts.flow ~= "" and not f then
      notify(tr("init.flow_not_found", { flow = opts.flow }), vim.log.levels.WARN)
    end
    fid = (f and f.id) or st.latest_flow_id(run.state)
  else
    run, fid = events.current_flow()
    if not run then
      notify(tr("init.no_runs"), vim.log.levels.WARN)
      return
    end
  end
  show(run, fid)
end

--- 一覧で選ばれた run を開く（記録が無いものは会話記録から取り込む）
local function open_item(item)
  if not item then return end
  follow_latest = false  -- 一覧から選んだ run は、新しい run が来ても切り替えない
  local events = need("agentmap.events")
  if type(item) == "table" and item.state and item.dir then
    return show(item, need("agentmap.state").latest_flow_id(item.state))
  end
  local sid = type(item) == "string" and item or (item.sid or item.session_id or item.run_id)
  local src = type(item) == "table" and item.source or nil
  local run
  if src == "history" or src == "transcript_only" or item.history_only then
    notify(tr("init.importing"))
    run = events.import_transcript(sid, item.slug)
  else
    run = events.open_run(sid)
  end
  if not run then
    notify(tr("init.run_open_failed", { sid = tostring(sid) }), vim.log.levels.WARN)
    return
  end
  local st = need("agentmap.state")
  local fid = type(item) == "table" and item.flow_id and st.flow_of(run.state, item.flow_id) and item.flow_id
  show(run, fid or st.latest_flow_id(run.state))
end
M._open_item = open_item

--- List past runs and open the chosen one (runs without records are imported from the transcript).
function M.runs()
  ensure_setup()
  local events = need("agentmap.events")
  local runs = events.list_runs() or {}
  if #runs == 0 then
    notify(tr("init.no_runs"), vim.log.levels.WARN)
    return
  end
  local ui = try("agentmap.ui")
  if ui and ui.run_picker then
    ui.run_picker(runs, guard(open_item))
    return
  end
  vim.ui.select(runs, {
    prompt = tr("init.runs_prompt"),
    format_item = function(r)
      local src = r.source or ""
      local i18n = require("agentmap.i18n")
      if src ~= "" and i18n.has("common.source_" .. src) then src = tr("common.source_" .. src) end
      return table.concat({ r.date or r.mtime_text or "", (r.sid or ""):sub(1, 8), r.title or "", src }, "  ")
    end,
  }, guard(open_item))
end

--- 図が開いていなければ、今の run を開く
local function ensure_open()
  local ui = try("agentmap.ui")
  if ui and ui.run then return ui end
  M.open()
  ui = try("agentmap.ui")
  if ui and ui.run then return ui end
  return nil
end

--- Find an agent id from an index ("3", "[3]") or an id (a unique prefix is enough).
---@param state table run state
---@param arg string|number
---@return string|nil agent id
function M.resolve(state, arg)
  if not state or not state.agents then return nil end
  arg = vim.trim(tostring(arg or ""))
  if arg == "" then return nil end
  if arg == "ROOT" or arg == "0" then return state.agents.ROOT and "ROOT" or nil end
  local n = tonumber(arg:match("^%[?(%d+)%]?$") or "")
  if n then
    local st = try("agentmap.state")
    if st and st.by_index then
      local ok, r = pcall(st.by_index, state, n)
      if ok and r then return type(r) == "table" and r.id or r end
    end
    for id, a in pairs(state.agents) do
      if a.index == n then return id end
    end
    return nil
  end
  if state.agents[arg] then return arg end
  local hit
  for id in pairs(state.agents) do
    if id:sub(1, #arg) == arg then
      if hit then return nil end -- 候補が 2 つ以上
      hit = id
    end
  end
  return hit
end

--- Open the details of an agent (index or id); opens the map first if needed.
---@param arg string|number
function M.agent(arg)
  ensure_setup()
  local ui = ensure_open()
  if not ui then return end
  local id = M.resolve(ui.display_state(), arg)
  if not id then
    notify(tr("init.agent_not_found", { arg = tostring(arg) }), vim.log.levels.WARN)
    return
  end
  ui.open_detail(id)
end

--- Reload the run shown in the map.
function M.refresh()
  ensure_setup()
  local ui = try("agentmap.ui")
  if not ui or not ui.run then
    notify(tr("init.map_not_open"), vim.log.levels.WARN)
    return
  end
  local events = need("agentmap.events")
  events.poll(ui.run)
  if events.enrich then pcall(events.enrich, ui.run) end
  ui.refresh()
  notify(tr("init.refreshed"))
end

--- Export the prompt shown in the map (or the latest one). Without `fmt` a picker is shown.
---@param fmt? "markdown"|"html"|"pdf"
---@param path? string output file or folder
function M.export(fmt, path)
  ensure_setup()
  if not fmt or fmt == "" then
    vim.ui.select({ "markdown", "html", "pdf" }, { prompt = tr("init.export_format_prompt") }, guard(function(choice)
      if choice then M.export(choice, path) end
    end))
    return
  end
  local ui = try("agentmap.ui")
  local run = ui and ui.run
  local fid = ui and ui.run and ui.flow_id
  if not run then
    local events = need("agentmap.events")
    run, fid = events.current_flow()
  end
  if not run then
    notify(tr("init.no_runs"), vim.log.levels.WARN)
    return
  end
  local events = try("agentmap.events")
  if events and events.enrich then pcall(events.enrich, run) end
  -- 画面に出している指示の流れだけを書き出す（流れが無ければセッション全体）
  local st = fid and need("agentmap.state").flow_view(run.state, fid) or run.state
  return need("agentmap.export").write(st, fmt, path, run)
end

local VERDICTS = { PASS = true, RETRY = true, ESCALATE = true, SUBMIT = true }

--- Record a review verdict for an agent (the user decides; this only records).
---@param arg string|number agent index or id
---@param verdict string PASS | RETRY | ESCALATE | SUBMIT
---@param ... string reason words
function M.review(arg, verdict, ...)
  ensure_setup()
  verdict = (verdict or ""):upper()
  if not VERDICTS[verdict] then
    notify(tr("init.review_usage"), vim.log.levels.WARN)
    return
  end
  local ui = ensure_open()
  if not ui then return end
  local run = ui.run
  local id = M.resolve(ui.display_state(), arg)
  if not id then
    notify(tr("init.agent_not_found", { arg = tostring(arg) }), vim.log.levels.WARN)
    return
  end
  local reason = table.concat({ ... }, " ")
  local review = need("agentmap.review")
  if verdict == "SUBMIT" then
    review.submit(run, id, reason ~= "" and reason or nil)
  else
    review.record(run, id, verdict, reason ~= "" and reason or nil, "user")
  end
  if ui.refresh then ui.refresh() end
  local shown_st = ui.display_state() or run.state
  local sa = shown_st.agents[id] or run.state.agents[id]
  notify(tr("init.review_recorded", {
    agent = id == "ROOT" and "ROOT" or ("[" .. tostring(sa and sa.index or "?") .. "]"), verdict = verdict,
  }))
end

--- Register the recording hooks in Claude Code's settings.json (shows a diff and asks first).
---@param path? string settings.json to edit (default: config.settings_path())
---@return boolean ok, table info see hooks.install
function M.install_hooks(path)
  ensure_setup()
  local hooks = need("agentmap.hooks")
  local ok, info = hooks.install({ path = (path and path ~= "") and vim.fn.expand(path) or nil })
  return ok, info
end

--- Import a run from Claude's transcript (default: the newest session of the current folder).
---@param sid? string session id
function M.import(sid)
  ensure_setup()
  local events = need("agentmap.events")
  local store, util = try("agentmap.store"), try("agentmap.util")
  local cwd = vim.fn.getcwd()
  local slug = (store and store.project_for_cwd and store.project_for_cwd(cwd))
    or (util and util.slug and util.slug(cwd)) or (cwd:gsub("[^%w]", "-"))
  if not sid or sid == "" then
    local providers = try("agentmap.providers")
    local claude = providers and providers.get and providers.get("claude")
    local list = claude and claude.list_sessions and claude.list_sessions(slug) or {}
    table.sort(list, function(a, b) return (a.mtime or 0) > (b.mtime or 0) end)
    if not list[1] then
      notify(tr("init.no_transcript_here"), vim.log.levels.WARN)
      return
    end
    sid = list[1].session_id
  else
    -- session_id を指定されたときは、今のフォルダに関係なく全プロジェクトから探す
    slug = nil
  end
  notify(tr("init.importing_sid", { sid = sid:sub(1, 8) }))
  local run = events.import_transcript(sid, slug)
  if not run then
    notify(tr("init.import_failed", { sid = sid }), vim.log.levels.WARN)
    return
  end
  show(run)
end

-- ------------------------------------------------------------
-- コマンドとキー
-- ------------------------------------------------------------
local FORMATS = { "markdown", "html", "pdf" }

local function complete_export(arglead, cmdline)
  local n = #vim.split(vim.trim(cmdline), "%s+") - (cmdline:match("%s$") and 0 or 1)
  if n <= 1 then
    return vim.tbl_filter(function(f) return f:find(arglead, 1, true) == 1 end, FORMATS)
  end
  return vim.fn.getcompletion(arglead, "file")
end

local function complete_review(arglead, cmdline)
  local n = #vim.split(vim.trim(cmdline), "%s+") - (cmdline:match("%s$") and 0 or 1)
  if n == 2 then
    return vim.tbl_filter(function(f) return f:find(arglead:upper(), 1, true) == 1 end,
      { "PASS", "RETRY", "ESCALATE", "SUBMIT" })
  end
  return {}
end

--- Register the 8 user commands (also called from plugin/agentmap.lua). Re-registering is harmless.
--- Descriptions are translated at the moment of registration (setup() registers them again).
function M.commands()
  if not did_setup then
    -- setup() 前（plugin/ から）: vim.g.agentmap_lang があればその言語で説明を付ける
    require("agentmap.i18n").setup(vim.g.agentmap_lang)
  end
  local cmd = vim.api.nvim_create_user_command
  cmd("AgentMap", guard(function(o) M.open(o.fargs[1], { flow = o.fargs[2] }) end),
    { nargs = "*", desc = tr("init.cmd_open") })
  cmd("AgentMapRuns", guard(function() M.runs() end),
    { nargs = 0, desc = tr("init.cmd_runs") })
  cmd("AgentMapAgent", guard(function(o) M.agent(o.args) end),
    { nargs = 1, desc = tr("init.cmd_agent") })
  cmd("AgentMapRefresh", guard(function() M.refresh() end),
    { nargs = 0, desc = tr("init.cmd_refresh") })
  cmd("AgentMapExport", guard(function(o) M.export(o.fargs[1], o.fargs[2]) end),
    { nargs = "*", complete = complete_export, desc = tr("init.cmd_export") })
  cmd("AgentMapReview", guard(function(o) M.review(unpack(o.fargs)) end),
    { nargs = "+", complete = complete_review, desc = tr("init.cmd_review") })
  cmd("AgentMapInstallHooks", guard(function(o) M.install_hooks(o.args) end),
    { nargs = "?", complete = "file", desc = tr("init.cmd_install_hooks") })
  cmd("AgentMapImport", guard(function(o) M.import(o.args) end),
    { nargs = "?", desc = tr("init.cmd_import") })
end

local function keymaps()
  local map = vim.keymap.set
  map("n", "<leader>aa", "<Cmd>AgentMap<CR>", { desc = tr("init.key_open") })
  map("n", "<leader>ar", "<Cmd>AgentMapRuns<CR>", { desc = tr("init.key_runs") })
  map("n", "<leader>ae", "<Cmd>AgentMapExport<CR>", { desc = tr("init.key_export") })
end

--- Configure agentmap. Optional (defaults apply without it); may be called again.
---@param opts? table see lua/agentmap/config.lua (M.defaults) and docs/DESIGN.md §4.1
---@return table the module
function M.setup(opts)
  opts = opts or {}
  did_setup = true
  local config = require("agentmap.config")
  local c = config.setup(opts)
  require("agentmap.i18n").setup(c.lang)
  M.commands()
  if c.keymaps and c.keymaps.global == true then keymaps() end

  -- 色の設定（色の組み合わせを変えたときも付け直す）
  local group = vim.api.nvim_create_augroup("agentmap", { clear = true })
  local function hl()
    local r = try("agentmap.renderer")
    if r and r.setup_highlights then pcall(r.setup_highlights) end
  end
  hl()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = hl })
  return M
end

return M
