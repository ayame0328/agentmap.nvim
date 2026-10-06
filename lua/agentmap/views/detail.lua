-- agentmap/views/detail.lua ... the agent detail view shown in the side window.
--   build() is pure (state -> lines). open() writes the buffer and adds the git branch asynchronously.
local graph = require("agentmap.graph")
local renderer = require("agentmap.renderer")
local brief = require("agentmap.brief")
local H = graph.util
local t = require("agentmap.i18n").t

local M = {}

-- バッファごとの「行 → 子 Agent id / HUMAN CHECK id」の表
M.links = {}

local function label_of(state, id)
  if id == nil then return "[?] UNKNOWN_PARENT" end
  if id == "ROOT" then return "ROOT" end
  local a = state.agents[id]
  if not a then return "[?] " .. tostring(id) end
  return "[" .. (a.index or "?") .. "] " .. (a.name or a.task or H.short_id(id))
end

-- 記録に入っている言語に依らない符号（state.lua の error_head）は表示のときだけ訳す。他はそのまま
local ERROR_CODES = { ["no spawn record"] = "state.error_no_spawn_record", ["session ended"] = "state.error_session_ended" }
local function error_text(e)
  return ERROR_CODES[e] and t(ERROR_CODES[e]) or e
end

local function or_dash(v)
  if v == nil or v == "" then return "-" end
  return tostring(v)
end

-- 1回の試行を「開始 → 完了 → 提出 → 判定 → 再実行」の1行に
local function attempt_line(state, at)
  local parts = { "#" .. (at.n or "?") }
  if at.started_at then parts[#parts + 1] = t("detail.attempt_started", { time = H.fmt_clock(at.started_at) }) end
  if at.finished_at then parts[#parts + 1] = t("detail.attempt_finished", { time = H.fmt_clock(at.finished_at) }) end
  if at.submitted_at then parts[#parts + 1] = t("detail.attempt_submitted", { time = H.fmt_clock(at.submitted_at) }) end
  if at.verdict then
    local v = at.verdict .. " (" .. or_dash(at.decided_by) .. ")"
    if at.reason and at.reason ~= "" then v = v .. " " .. t("common.quote", { text = at.reason }) end
    parts[#parts + 1] = v
  end
  if at.retried_by then parts[#parts + 1] = t("detail.attempt_retried_by", { label = label_of(state, at.retried_by) }) end
  if at.retry_of then parts[#parts + 1] = t("detail.attempt_retry_of", { label = label_of(state, at.retry_of) }) end
  return table.concat(parts, " → ")
end

-- 設定（config.lua の detail / transcript。無いキーはここの既定値）
local DETAIL_DEFAULTS = { progress_max = 40, note_chars = 120, report_chars = 4000, lead_chars = 400 }
local function dcfg()
  local cfg = H.config()
  return setmetatable(type(cfg.detail) == "table" and cfg.detail or {}, { __index = DETAIL_DEFAULTS })
end

-- 表示幅 w で折り返す（views/transcript.lua の wrap と同じ考え方）
local function wrap(text, w)
  local out = {}
  w = math.max(10, w)
  for _, para in ipairs(vim.split(tostring(text or ""), "\n", { plain = true })) do
    if para == "" then
      out[#out + 1] = ""
    else
      local cur, used = {}, 0
      for _, c in ipairs(H.chars(para)) do
        local cw = H.dw(c)
        if used + cw > w and used > 0 then
          out[#out + 1] = table.concat(cur)
          cur, used = {}, 0
        end
        cur[#cur + 1] = c
        used = used + cw
      end
      out[#out + 1] = table.concat(cur)
    end
  end
  return out
end
M.wrap = wrap

local LABEL_W = 16
-- 「ラベル  値」の行。値が長ければ折り返して、2 行目からはラベルの幅だけ字下げする
--   値が無ければ common.missing（推測で埋めない：設計書 §2）
local function kv(b, width, label, value, hl, missing)
  local v = value
  if v == nil or v == "" then v, hl = missing or t("common.missing"), "AgentMapDim" end
  -- 名札が欄の幅以上なら 1 字空けて広げる（"(child's report)Should…" のように値とくっつかないように）
  local lw = math.max(LABEL_W, H.dw(tostring(label or "")) + 1)
  local body = wrap(H.oneline(v), width - 2 - lw)
  for i, l in ipairs(body) do
    local head = i == 1 and ("  " .. H.fit(label, lw)) or string.rep(" ", 2 + lw)
    b:add({ { head }, { l, hl } })
  end
end
M.kv = kv

-- 作業の経過のツール名の列幅。SubagentHandback（16 字）・AskUserQuestion（15 字）が切れずに読めるように
local TOOL_W = 16

-- 💬 が 2 桁で表示できない端末では > にする（列がずれるのを避ける）
local function note_mark()
  return vim.fn.strdisplaywidth("💬") == 2 and "💬" or ">"
end

-- ✓ ▶ が 2 桁で表示される端末では + > にする
local function step_marks()
  local done = vim.fn.strdisplaywidth("✓") == 1 and "✓" or "+"
  local run = vim.fn.strdisplaywidth("▶") == 1 and "▶" or ">"
  return done, run
end

-- 詳細を開いた瞬間の時刻と過去の記録（extra に無ければここで取る）
local function now_and_stats(extra)
  local now = extra.now or os.time()
  local stats = extra.stats
  if stats == nil then
    local ok, st = pcall(function()
      return require("agentmap.stats").load(require("agentmap.config").root())
    end)
    stats = ok and st or nil
  end
  return now, stats
end

local function stat_basis_text(r)
  if not r or not r.stat_basis then return nil end
  if r.stat_basis == "default" then return t("detail.stat_basis_default") end
  local key = ({ ["type+model"] = "detail.stat_basis_type_model", type = "detail.stat_basis_type",
    all = "detail.stat_basis_all" })[r.stat_basis]
  if not key then return nil end
  return t("detail.stat_basis", { n = r.samples or 0, basis = t(key) })
end

--- Progress lines of the detail view (DESIGN-v0.2 §2.6). Returns the status-line part and the
--- second line ("progress 2/3 steps done · step 3 running …"), both plain strings.
function M.progress_lines(state, a, r)
  local head
  if not r then
    head = t("detail.progress_none")
  elseif r.estimated then
    head = t("detail.progress_est", { pct = require("agentmap.progress").pct_text(r) })
  else
    head = t("detail.progress_fact", { pct = require("agentmap.progress").pct_text(r) })
  end
  local body
  if r and (r.basis == "tasks" or r.basis == "steps" or ((r.basis == "done" or r.basis == "failed") and r.n)) then
    body = t("detail.progress_steps", { k = r.k or 0, n = r.n or 0 })
    if r.n_children then
      body = body .. " · " .. t("detail.progress_children", { n = r.n_children })
    elseif r.cur_elapsed_ms and r.expected_ms and r.k and r.n and r.k < r.n then
      body = body .. t(r.over and "detail.progress_over" or "detail.progress_running", { n = r.k + 1,
        elapsed = H.fmt_elapsed(r.cur_elapsed_ms), typical = H.fmt_elapsed(r.expected_ms) })
    end
  elseif r and r.basis == "children" then
    body = t("detail.progress_children", { n = r.n_children or 0 })
  elseif r and r.basis == "time" then
    body = t(r.over and "detail.progress_time_over" or "detail.progress_time", { typical = H.fmt_elapsed(r.expected_ms) })
  end
  local sb = r and r.estimated and stat_basis_text(r)
  if body and sb then body = body .. " · " .. sb end
  return head, body
end

-- 手順の節（■ Steps）。tasks（道具）があればそれ、無ければ steps（目印）
local function step_rows(a)
  local tk = a.tasks
  if type(tk) == "table" and type(tk.items) == "table" and next(tk.items) then
    local ids, seen = {}, {}
    for _, id in ipairs(tk.order or {}) do
      if tk.items[id] and not seen[id] then
        seen[id] = true
        ids[#ids + 1] = id
      end
    end
    local rest = {}
    for id in pairs(tk.items) do
      if not seen[id] then rest[#rest + 1] = id end
    end
    table.sort(rest, function(x, y) return (tonumber(x) or math.huge) < (tonumber(y) or math.huge) end)
    vim.list_extend(ids, rest)
    local rows = {}
    for i, id in ipairs(ids) do
      local it = tk.items[id]
      rows[#rows + 1] = { n = tonumber(id) or i, text = it.subject or it.active_form or ("#" .. id),
        state = it.status == "completed" and "done" or it.status == "in_progress" and "running" or "todo",
        started_at = it.started_at or (it.status ~= "pending" and it.created_at or nil), done_at = it.done_at }
    end
    return rows, "tasks"
  end
  local sp = a.steps
  if type(sp) == "table" and type(sp.items) == "table" and #sp.items > 0 then
    local rows, prev, cur_found = {}, sp.listed_at, false
    for _, it in ipairs(sp.items) do
      local st = "todo"
      if it.done_at then
        st = "done"
      elseif not cur_found then
        st, cur_found = "running", true
      end
      rows[#rows + 1] = { n = it.n, text = it.text, state = st, started_at = it.started_at or (st ~= "todo" and prev or nil),
        done_at = it.done_at }
      if it.done_at then prev = it.done_at end
    end
    return rows, "steps", sp.truncated
  end
  return nil
end

local function hm(iso)
  local s = H.fmt_clock(iso)
  return s == "-" and "--:--" or s:sub(1, 5)
end

local function check_line(state, cid)
  local c = state.checks and state.checks[cid]
  if not c then return nil end
  local ci = graph.check_info(state, c)
  return { { "  " }, { "HUMAN CHECK" .. (ci.n and (" #" .. ci.n) or ""), "AgentMapHeader" }, { "  " },
    { ci.tag, ci.hl }, { "  " .. t("common.quote", { text = H.truncate(ci.question or t("common.no_question"), 40) }), "AgentMapDim" },
    { ci.status == "ANSWERED" and ci.answer and ("  → " .. ci.answer) or "", "AgentMapDone" },
    { "   " .. t("common.enter_for_detail"), "AgentMapDim" } }
end

-- この Agent に関係する HUMAN CHECK（箱が付いているもの＋この Agent の要確認に結びついたもの）
local function checks_for(state, a)
  local out, seen = {}, {}
  for _, cid in ipairs(graph.checks_of(state, a.id)) do
    seen[cid] = true
    out[#out + 1] = cid
  end
  if a.ask_check and not seen[a.ask_check] and state.checks and state.checks[a.ask_check] then
    out[#out + 1] = a.ask_check
  end
  return out
end

--- Build the detail lines of `agent` (pure). Returns { lines, marks, links }.
-- 一時停止 1 件の結果（§6.4）。止まった・再開の文と色
local PAUSE_REASON = { agent_finished = "detail.pause_reason_finished", session_ended = "detail.pause_reason_session",
  gate_off = "detail.pause_reason_gate_off", nvim_exit = "detail.pause_reason_exit",
  stale = "detail.pause_reason_stale" }

local function clock_of(v)
  local tsec = graph.pause_time(v)
  return tsec and os.date("%H:%M:%S", tsec) or "-"
end

--- One line of the "■ Pauses" section (DESIGN-v0.1.2-pause §6.4), without the leading mark.
--- Returns segs, link ("steer:<id>" when resumed with an instruction, else nil) and the line color.
---@param state table
---@param p table a state.pauses entry
---@param i integer position in the agent's list (used when p.n is missing)
---@param now? number seconds
function M.pause_line(state, p, i, now)
  now = now or os.time()
  local kind
  if p.kind == "gate" then
    kind = t("detail.pause_gate")
  elseif p.at == "stop" then
    kind = t("detail.pause_requested_stop")
  else
    kind = t("detail.pause_requested_next")
  end
  local segs = { { "#" .. (p.n or i) .. " " .. clock_of(p.requested_at or p.hit_at) .. " " .. kind } }
  local via = or_dash(p.hit_via)
  local hl, link = "AgentMapPaused", nil
  local function add(text, h) segs[#segs + 1] = { " " .. text, h } end
  local waited = graph.pause_waited_ms(p, now)
  local dur = waited and t("detail.pause_duration", { dur = graph.fmt_duration(waited) }) or ""
  if p.status == "PAUSED" then
    add(t("detail.pause_waiting", { time = clock_of(p.hit_at), via = via, ["until"] = clock_of(p.deadline) }), hl)
  elseif p.status == "REQUESTED" then
    add(t("detail.pause_not_yet"), hl)
  elseif p.status == "RESUMED" then
    hl = "AgentMapDone"
    if p.hit_at then add(t("detail.pause_paused", { time = clock_of(p.hit_at), via = via })) end
    local r, rt = p.release_reason, clock_of(p.released_at)
    if r == "auto" or r == "max_wait" then
      add(t("detail.pause_resumed_auto", { time = rt, min = graph.fmt_duration(waited) }), hl)
    elseif r == "nvim_exit" then
      add(t("detail.pause_resumed_exit", { time = rt }) .. dur, hl)
    elseif r == "gate_off" then
      add(t("detail.pause_resumed_gate_off", { time = rt }) .. dur, hl)
    elseif r == "aborted" then
      hl = "AgentMapRework"
      add(t("detail.pause_aborted", { time = rt }) .. dur, hl)
    elseif p.steer_id then
      local x = type(state.steers) == "table" and state.steers[p.steer_id] or nil
      add(t("detail.pause_resumed_with", { time = rt, n = (x and x.n) or "?" }) .. dur, hl)
      link = "steer:" .. p.steer_id
    else
      add(t("detail.pause_resumed_user", { time = rt }) .. dur, hl)
    end
  else -- EXPIRED
    hl = "AgentMapDim"
    local rk = PAUSE_REASON[p.end_reason]
    add(t("detail.pause_expired", { reason = rk and t(rk) or or_dash(p.end_reason) }), hl)
  end
  return segs, link, hl
end

-- extra = { branch = "…", width = 列数, now = 秒, stats = stats.load() の結果（無ければ読む）,
--           notes = { {ts, kind = "note"|"tool", text, tool, target}, … } | nil（transcript が読めないとき） }
function M.build(state, agent, extra)
  extra = extra or {}
  local cfg = dcfg()
  local width = math.max(40, extra.width or 80)
  local b = renderer.builder()
  local a = agent
  -- 札は表示上の状態（止まっていれば [PAUSED] / [GATE]。DESIGN-v0.1.2-pause §2）
  local st = graph.display_status(state, a.id) or a.status or "PENDING"
  local shl = graph.STATUS_HL[st]
  local nat = #(a.attempts or {})
  local title = a.id == "ROOT" and ("ROOT  " .. (state.title or "")) or label_of(state, a.id)

  b:add({ { "■ ", "AgentMapHeader" }, { title, "AgentMapHeader" }, { "   " },
    { graph.status_tag(st), shl }, { "  attempt " .. (a.attempt or nat) .. "/" .. math.max(nat, a.attempt or 0) } })
  b:add("  ID       " .. or_dash(a.id) .. "      type   " .. or_dash(a.agent_type))
  local model = H.model_short(a.model) or "?"
  b:add(t("detail.model_line", { model = model, req = or_dash(H.model_short(a.model_requested)),
    parent = (a.id == "ROOT" and "-" or label_of(state, a.parent_id)) }),
    a.parent_id and a.parent_id ~= "ROOT" and a.parent_id or nil)
  local now, stats = now_and_stats(extra)
  local pcfg = graph.progress_opts({}).config
  local pr = require("agentmap.progress").compute(state, a.id, { now = now, stats = stats, config = pcfg })
  local el = H.elapsed_ms(a, now)
  local phead, pbody = M.progress_lines(state, a, pr)
  b:add({ { "  status   " }, { graph.status_tag(st), shl }, { "  " .. phead, pr and pr.estimated and "AgentMapRunning" or nil },
    { t("detail.started_elapsed", { start = H.fmt_clock(a.started_at), elapsed = (el and H.fmt_elapsed(el) or "-") }) } })
  if pbody then b:add("  " .. H.fit(t("detail.progress_label"), 9) .. pbody) end
  b:add(t("detail.review_line", { reviews = a.review_count or 0, reworks = a.rework_count or 0 })
    .. (a.escalated_to and t("detail.escalated_to", { label = label_of(state, a.escalated_to) }) or ""))
  b:add("  cwd      " .. or_dash(a.cwd or state.cwd))
  b:add("  worktree " .. or_dash(a.worktree) .. "   branch " .. or_dash(a.branch or extra.branch))
  local tp = a.transcript_path or (a.id == "ROOT" and state.root_transcript) or nil
  b:add("  transcript " .. or_dash(tp))
  if a.error_head then b:add({ { "  error    " .. error_text(a.error_head), "AgentMapFailed" } }) end

  -- 手順（DESIGN-v0.2 §2.6）：✓ 済み / ▶ 実行中 / 空白 まだ
  local rows, src, truncated = step_rows(a)
  if rows then
    local k = 0
    for _, r in ipairs(rows) do if r.state == "done" then k = k + 1 end end
    b:add("")
    b:add({ { t("detail.h_steps", { k = k, n = #rows,
      source = t(src == "tasks" and "detail.steps_source_tasks" or "detail.steps_source_steps") }), "AgentMapHeader" } })
    local mdone, mrun = step_marks()
    local tw = 0
    for _, r in ipairs(rows) do tw = math.max(tw, H.dw(tostring(r.n) .. ". " .. H.oneline(r.text or ""))) end
    tw = math.min(tw, math.max(20, width - 34))
    for _, r in ipairs(rows) do
      local label = H.fit(tostring(r.n) .. ". " .. H.oneline(r.text or ""), tw)
      if r.state == "done" then
        b:add({ { "  " .. mdone .. " ", "AgentMapDone" }, { label .. "  " },
          { hm(r.started_at) .. " → " .. hm(r.done_at), "AgentMapDim" } })
      elseif r.state == "running" then
        local tail = ""
        local cel = r.started_at and H.parse_iso(r.started_at) and math.max(0, (now - H.parse_iso(r.started_at)) * 1000) or nil
        if cel and pr and pr.expected_ms and pr.basis ~= "children" then
          tail = " " .. t(cel > pr.expected_ms and "detail.step_over" or "detail.step_running",
            { elapsed = H.fmt_elapsed(cel), typical = H.fmt_elapsed(pr.expected_ms) })
        end
        b:add({ { "  " .. mrun .. " ", "AgentMapRunning" }, { label .. "  " },
          { hm(r.started_at) .. " → " .. tail, "AgentMapDim" } })
      else
        b:add({ { "    " }, { (label:gsub("%s+$", "")), "AgentMapDim" } })
      end
    end
    if truncated then b:add({ { t("detail.steps_truncated"), "AgentMapDim" } }) end
  end

  -- 任せた内容：親の指示の【目的】【任せる理由】【期待する結果】と、親の直前の発言
  b:add("")
  if a.id == "ROOT" then
    b:add({ { t("detail.h_prompt"), "AgentMapHeader" } })
    for _, l in ipairs(wrap(state.title or a.task or t("common.no_prompt"), width - 4)) do b:add("  " .. l) end
  else
    b:add({ { t("detail.h_brief"), "AgentMapHeader" } })
    local br = type(a.brief) == "table" and a.brief or nil
    if br and (br.purpose or br.reason or br.expected) then
      kv(b, width, t("detail.goal"), br.purpose)
      kv(b, width, t("detail.why_delegate"), br.reason)
      kv(b, width, t("detail.done_when"), br.expected)
    else
      b:add({ { t("detail.no_brief_markers"), "AgentMapDim" } })
      local head = a.prompt_head or a.task
      if head and head ~= "" then
        for _, l in ipairs(wrap(head, width - 6)) do b:add("    " .. l) end
      else
        b:add({ { t("detail.no_prompt_record"), "AgentMapDim" } })
      end
    end
    local lead = a.lead and brief.clip(H.oneline(a.lead), cfg.lead_chars) or nil
    kv(b, width, t("detail.parent_lead"), lead and t("common.quote", { text = lead }) or nil, nil, t("detail.no_lead"))
  end

  b:add("")
  b:add({ { t("detail.h_history"), "AgentMapHeader" } })
  if nat == 0 then
    b:add({ { t("detail.no_record"), "AgentMapDim" } })
  else
    for _, at in ipairs(a.attempts) do
      local hl = at.verdict == "PASS" and "AgentMapDone" or at.verdict == "RETRY" and "AgentMapRework"
        or at.verdict == "ESCALATE" and "AgentMapReview" or nil
      b:add({ { "  " .. attempt_line(state, at), hl } })
    end
  end

  -- 修正指示（DESIGN-v0.2-steer §6.4、DESIGN-v0.1.2-steer2 §7.3）。1 件以上あるときだけ
  local STEER_REASON = { agent_finished = "detail.steer_reason_finished", session_ended = "detail.steer_reason_session",
    no_terminal = "detail.steer_reason_no_terminal", not_relayed = "detail.steer_reason_not_relayed" }
  local function steer_outcome(x)
    if x.via == "relay" and x.status ~= "EXPIRED" and x.status ~= "CANCELLED" then
      -- 親経由: 打った（SENT）→ Claude Code が読んだ（READ）→ ROOT が SendMessage で渡した（RELAYED）
      if x.relayed_at then
        return t("detail.steer_relayed", { time = H.fmt_clock(x.relayed_at),
          parent = x.relayed_by and label_of(state, x.relayed_by) or "ROOT" }), "AgentMapDone"
      elseif x.confirmed_at then
        return t("detail.steer_relay_read", { time = H.fmt_clock(x.confirmed_at) }), "AgentMapWaiting"
      end
      return t("detail.steer_relay_sent", { time = H.fmt_clock(x.delivered_at or x.requested_at) }), "AgentMapWaiting"
    end
    if x.status == "DELIVERED" then
      if x.held == false then
        -- 終わり際に届けたが止められなかった（連続の上限で Claude Code が終わらせた。state が親の記録から判定）
        return t("detail.steer_not_held", { time = H.fmt_clock(x.delivered_at), via = or_dash(x.delivered_via) }), "AgentMapRework"
      elseif x.delivered_via == "UserPromptSubmit" then
        return t("detail.steer_confirmed", { time = H.fmt_clock(x.confirmed_at or x.delivered_at) }), "AgentMapDone"
      elseif x.via == "terminal" or x.delivered_via == "terminal" then
        return t("detail.steer_sent", { time = H.fmt_clock(x.delivered_at) }), "AgentMapDone"
      end
      return t("detail.steer_delivered", { time = H.fmt_clock(x.delivered_at), via = or_dash(x.delivered_via) }), "AgentMapDone"
    elseif x.status == "EXPIRED" then
      local rk = STEER_REASON[x.end_reason]
      local reason = rk and t(rk) or or_dash(x.end_reason)
      if x.end_reason == "not_relayed" then return t("detail.steer_not_relayed", { reason = reason }), "AgentMapRework" end
      return t("detail.steer_expired", { reason = reason }), "AgentMapRework"
    elseif x.status == "CANCELLED" then
      return t("detail.steer_cancelled", { time = H.fmt_clock(x.ended_at) }), "AgentMapDim"
    end
    -- 未配達: いつ届くかは要求時の expect（無い = v0.1.1 の記録 = 次の道具）
    if x.expect == "stop" then return t("detail.steer_pending"), "AgentMapWaiting" end
    return t("detail.steer_pending_next"), "AgentMapWaiting"
  end
  local function squash(v)
    return vim.trim((tostring(v or "")):gsub("%s+", " "))
  end
  local sids = graph.steers_of(state, a.id)
  local expanded = type(extra.steer_expanded) == "table" and extra.steer_expanded or {}
  if #sids > 0 then
    b:add("")
    b:add({ { t("detail.h_steers", { n = #sids }), "AgentMapHeader" } })
    local mk = graph.steer_mark()
    for i, sid in ipairs(sids) do
      local x = state.steers[sid]
      local outcome, hl = steer_outcome(x)
      local body = H.truncate(H.oneline(x.text or t("common.missing")), cfg.note_chars)
      b:add({ { "  " .. mk .. " ", hl }, { "#" .. (x.n or i) .. " " .. H.fmt_clock(x.requested_at) .. "  " },
        { outcome, hl }, { "  " .. t("common.quote", { text = body }), "AgentMapDim" } }, "steer:" .. sid)
      -- ROOT が言い換えて渡したときだけ、渡した文の先頭（同じなら出さない。比べるのは先頭だけ）
      local rh = x.relay_head and squash(x.relay_head) or ""
      if rh ~= "" and squash(x.text):sub(1, #rh) ~= rh then
        b:add({ { t("detail.steer_relay_as", { text = t("common.quote", { text = H.truncate(rh, cfg.note_chars) }) }),
          "AgentMapDim" } }, "steer:" .. sid)
      end
      -- Enter で開いた指示：本文全体と、親経由なら端末に打った文
      if expanded[sid] then
        for _, l in ipairs(vim.split(tostring(x.text or ""), "\n", { plain = true })) do
          b:add({ { "      " .. l, "AgentMapDim" } }, "steer:" .. sid)
        end
        if type(x.relay_line) == "string" and x.relay_line ~= "" then
          b:add({ { t("detail.steer_relay_line", { text = H.oneline(x.relay_line) }), "AgentMapDim" } }, "steer:" .. sid)
        end
      end
      -- 親への知らせ（付録 E）：届いたか・未配達か
      local nt = graph.notice_of(state, sid)
      if nt then
        local no, nhl = steer_outcome(nt)
        b:add({ { t("detail.steer_notice", { parent = label_of(state, nt.agent_id or "ROOT") }), "AgentMapDim" },
          { no, nhl } }, nt.agent_id and nt.agent_id ~= "ROOT" and nt.agent_id or nil)
      end
      -- 配達のあと 60 秒以内に最初に使った道具（作者が「従ったか」を目で確かめるため。§12.2）
      local dt = x.status == "DELIVERED" and H.parse_iso(x.delivered_at)
      if dt then
        for _, tl in ipairs(a.tools or {}) do
          local tt = H.parse_iso(tl.ts)
          if tt and tt >= dt and tt - dt <= 60 then
            b:add({ { t("detail.steer_next_tool", { time = H.fmt_clock(tl.ts),
              tool = (tl.name or "?") .. (tl.target and (" " .. H.oneline(tl.target)) or "") }), "AgentMapDim" } })
            break
          end
        end
      end
    end
  end

  -- 一時停止（DESIGN-v0.1.2-pause §6.4）。1 件以上あるときだけ
  local pids = graph.pauses_of(state, a.id)
  if #pids > 0 then
    b:add("")
    b:add({ { t("detail.h_pauses", { n = #pids }), "AgentMapHeader" } })
    local pmk = graph.pause_mark()
    for i, pid in ipairs(pids) do
      local segs, link, hl = M.pause_line(state, state.pauses[pid], i, now)
      table.insert(segs, 1, { "  " .. pmk .. " ", hl })
      b:add(segs, link)
    end
  end

  -- 人の確認（HUMAN CHECK）：この箱に付いている質問と、まだ質問されていない要確認
  local cids = checks_for(state, a)
  local ask = type(a.ask) == "table" and a.ask or nil
  if #cids > 0 or ask then
    b:add("")
    b:add({ { t("detail.h_checks", { n = #cids }), "AgentMapHeader" } })
    for _, cid in ipairs(cids) do
      local segs = check_line(state, cid)
      if segs then b:add(segs, cid) end
    end
    if ask and not a.ask_check then
      b:add({ { t("detail.ask_not_asked"), "AgentMapWaiting" },
        { t("common.quote", { text = H.oneline(ask.want or t("common.missing")) }) } })
    end
  end

  b:add("")
  local kids = graph.children(state, a.id)
  b:add({ { t("detail.h_children", { n = #kids }), "AgentMapHeader" } })
  if #kids == 0 then b:add({ { t("detail.none"), "AgentMapDim" } }) end
  for _, c in ipairs(kids) do
    local ca = state.agents[c]
    local cst = graph.display_status(state, c) or ca.status or "PENDING"
    b:add({ { "  " }, { "[" .. (ca.index or "?") .. "]", "AgentMapIndex" },
      { " " .. (ca.name or ca.task or H.short_id(c)) .. "  " },
      { graph.status_tag(cst), graph.STATUS_HL[cst] } }, c)
  end

  -- 作業の経過：transcript から読んだ「発言（💬）とツール」を時刻順に。読めなければ hooks の記録だけ
  b:add("")
  local maxn = cfg.progress_max
  local notes = type(extra.notes) == "table" and #extra.notes > 0 and extra.notes or nil
  if notes then
    b:add({ { t("detail.h_progress", { shown = math.min(maxn, #notes), total = #notes }), "AgentMapHeader" } })
    local mark = note_mark()
    for i = math.max(1, #notes - maxn + 1), #notes do
      local n = notes[i]
      if n.kind == "note" then
        b:add({ { "  " .. H.fmt_clock(n.ts) .. "  " }, { mark .. " " .. H.truncate(n.text or "", cfg.note_chars) } })
      else
        b:add({ { "  " .. H.fmt_clock(n.ts) .. "  " .. H.fit(n.tool or "?", TOOL_W) .. " " .. H.oneline(n.target or ""), "AgentMapDim" } })
      end
    end
  else
    local tools = a.tools or {}
    b:add({ { t("detail.h_progress", { shown = math.min(maxn, #tools), total = #tools }), "AgentMapHeader" } })
    if #tools == 0 then
      b:add({ { t("detail.none"), "AgentMapDim" } })
    else
      b:add({ { t("detail.hooks_only"), "AgentMapDim" } })
    end
    for i = math.max(1, #tools - maxn + 1), #tools do
      local tl = tools[i]
      b:add("  " .. H.fmt_clock(tl.ts) .. "  " .. H.fit(tl.name or "?", TOOL_W) .. " " .. H.oneline(tl.target or ""))
    end
  end

  b:add("")
  local files = a.files or {}
  b:add({ { t("detail.h_files", { n = #files }), "AgentMapHeader" } })
  if #files == 0 then b:add({ { t("detail.none"), "AgentMapDim" } }) end
  for _, f in ipairs(files) do b:add("  " .. f) end

  -- 報告（## 報告 の 4 項目）／要確認（## 要確認）／決まりどおりでなければ原文
  b:add("")
  local rf = type(a.report_fields) == "table" and a.report_fields or nil
  if ask then
    b:add({ { t("detail.h_ask"), "AgentMapWaiting" } })
    kv(b, width, t("detail.working_on"), ask.working)
    kv(b, width, t("detail.blocked_at"), ask.stuck)
    kv(b, width, t("detail.question"), ask.want)
    local opts = ask.options or {}
    if #opts == 0 then
      kv(b, width, t("detail.options"), nil)
    else
      for i, o in ipairs(opts) do
        kv(b, width, i == 1 and t("detail.options") or "", (o.n or i) .. ". " .. (o.name or "?")
          .. " → " .. (o.next or t("common.missing_next")))
      end
    end
    local c = a.ask_check and state.checks and state.checks[a.ask_check]
    if c then
      local ci = graph.check_info(state, c)
      b:add({ { "  " .. H.fit(t("detail.asked"), LABEL_W) }, { "HUMAN CHECK" .. (ci.n and (" #" .. ci.n) or "") .. " " },
        { ci.tag, ci.hl }, { t("detail.enter_paren"), "AgentMapDim" } }, c.id)
    else
      b:add({ { "  " .. H.fit(t("detail.asked"), LABEL_W) }, { t("detail.not_asked_yet"), "AgentMapWaiting" } })
    end
  elseif rf then
    b:add({ { t("detail.h_report"), "AgentMapHeader" } })
    kv(b, width, t("detail.done"), rf.done)
    kv(b, width, t("detail.approach"), rf.direction)
    kv(b, width, t("detail.why"), rf.reason)
    kv(b, width, t("detail.open_issues"), rf.issues)
    -- 記録の時点で上限（brief.LIMITS.report 文字）で切られた報告は、最後の項目が途中で終わっている
    if type(a.report) == "string" and vim.fn.strchars(a.report) >= brief.LIMITS.report then
      b:add({ { t("detail.report_truncated"), "AgentMapDim" } })
    end
  else
    local raw = a.report or a.last_head
    if a.id == "ROOT" then
      -- ROOT（自分）は報告の決まりの対象ではないので、最後の返事をそのまま出す
      b:add({ { t("detail.h_last_reply"), "AgentMapHeader" } })
    else
      b:add({ { t("detail.h_report"), "AgentMapHeader" } })
    end
    if raw and raw ~= "" then
      if a.id ~= "ROOT" then
        b:add({ { t("detail.no_report_markers"), "AgentMapDim" } })
      end
      local clipped = brief.clip(raw, cfg.report_chars)
      for _, l in ipairs(wrap(clipped, width - 4)) do b:add("  " .. l) end
      -- 報告は記録の時点で brief.LIMITS.report 文字に切られている。上限ちょうどなら途中で切れたものとみなして知らせる
      if clipped ~= raw or (a.report == raw and vim.fn.strchars(raw) >= brief.LIMITS.report) then
        b:add({ { t("detail.clipped"), "AgentMapDim" } })
      end
    else
      b:add({ { t("detail.not_yet"), "AgentMapDim" } })
    end
  end

  b:add("")
  b:add({ { t("detail.footer"), "AgentMapDim" } })
  return b:result()
end

-- ------------------------------------------------------------
-- 作業の経過（transcript の差分読み）
--   providers の agent_notes（増えた分だけ読む）があればそれを使い、読んだ位置をここで覚えておく。
--   無ければ transcript_entries で末尾だけ読んで作る（担当 A の関数がまだ無くても画面が出るように）
-- ------------------------------------------------------------
M.notes_cache = {} -- [path] = agent_notes の idx（{ off, entries }）

local function provider(run)
  local ok, reg = pcall(require, "agentmap.providers")
  if ok and type(reg) == "table" and type(reg.get) == "function" then
    local ok2, p = pcall(reg.get, run and run.provider or "claude")
    if ok2 and type(p) == "table" then return p end
  end
  local ok3, p = pcall(require, "agentmap.providers.claude")
  if ok3 and type(p) == "table" then return p end
  return nil
end

local function notes_from_entries(entries, max)
  local out = {}
  for _, e in ipairs(entries or {}) do
    if e.kind == "assistant" and e.text and e.text:match("%S") then
      out[#out + 1] = { ts = e.ts, kind = "note", text = H.oneline(e.text) }
    elseif e.kind == "tool_use" then
      if e.tool == "SubagentHandback" then
        out[#out + 1] = { ts = e.ts, kind = "note", text = t("detail.handback_note") }
      else
        out[#out + 1] = { ts = e.ts, kind = "tool", tool = e.tool, target = e.target }
      end
    end
  end
  while #out > max do table.remove(out, 1) end
  return out
end

--- Progress notes of `agent` read from its transcript; nil when the transcript cannot be read.
function M.read_notes(run, agent)
  local tp_ok, tv = pcall(require, "agentmap.views.transcript")
  local path
  if tp_ok and type(tv.path_for) == "function" then
    local ok, r = pcall(tv.path_for, run, agent)
    if ok then path = r end
  end
  path = path or agent.transcript_path
  if not path or vim.fn.filereadable(path) ~= 1 then return nil end
  local tcfg = H.config().transcript or {}
  local first, max = tcfg.notes_first_bytes or 1e6, tcfg.notes_max or 400
  local p = provider(run)
  if p and type(p.agent_notes) == "function" then
    local ok, idx = pcall(p.agent_notes, path, M.notes_cache[path], { max_first = first, max = max })
    if ok and type(idx) == "table" then
      M.notes_cache[path] = idx
      return idx.entries or {}
    end
  end
  if p and type(p.transcript_entries) == "function" then
    local ok, entries = pcall(p.transcript_entries, path, { max_bytes = first })
    if ok and type(entries) == "table" then return notes_from_entries(entries, max) end
  end
  return nil
end

--- Render the detail of `agent` into `buf`; run = { state, dir, … }. Returns the build result.
function M.open(run, agent, buf, opts)
  opts = opts or {}
  local state = run.state
  local notes = M.read_notes(run, agent)
  local res = M.build(state, agent, { branch = opts.branch, now = opts.now, width = opts.width, notes = notes })
  renderer.set_all(buf, res.lines, res.marks)
  M.links[buf] = res.links
  -- ブランチ名は git に聞く（非同期。聞けたら書き直す）
  local dir = agent.cwd or state.cwd
  if not agent.branch and not opts.branch and dir and vim.fn.isdirectory(dir) == 1 then
    pcall(vim.system, { "git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" }, { text = true },
      function(r)
        if r.code ~= 0 then return end
        local br = vim.trim(r.stdout or "")
        if br == "" then return end
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buf) then return end
          if vim.b[buf].agentmap_id ~= agent.id then return end
          local res2 = M.build(state, agent, { branch = br, now = opts.now, width = opts.width, notes = notes })
          renderer.set_all(buf, res2.lines, res2.marks)
          M.links[buf] = res2.links
        end)
      end)
  end
  return res
end

return M
