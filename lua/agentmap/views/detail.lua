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
-- extra = { branch = "…", width = 列数, now = 秒,
--           notes = { {ts, kind = "note"|"tool", text, tool, target}, … } | nil（transcript が読めないとき） }
function M.build(state, agent, extra)
  extra = extra or {}
  local cfg = dcfg()
  local width = math.max(40, extra.width or 80)
  local b = renderer.builder()
  local a = agent
  local st = a.status or "PENDING"
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
  local pr = graph.progress(state, a.id)
  local el = H.elapsed_ms(a, extra.now)
  b:add({ { "  status   " }, { graph.status_tag(st), shl },
    { t("detail.progress", { value = (pr and ("~" .. pr.pct .. "% (" .. pr.done .. "/" .. pr.total .. ")") or "-") }) },
    { t("detail.started_elapsed", { start = H.fmt_clock(a.started_at), elapsed = (el and H.fmt_elapsed(el) or "-") }) } })
  b:add(t("detail.review_line", { reviews = a.review_count or 0, reworks = a.rework_count or 0 })
    .. (a.escalated_to and t("detail.escalated_to", { label = label_of(state, a.escalated_to) }) or ""))
  b:add("  cwd      " .. or_dash(a.cwd or state.cwd))
  b:add("  worktree " .. or_dash(a.worktree) .. "   branch " .. or_dash(a.branch or extra.branch))
  local tp = a.transcript_path or (a.id == "ROOT" and state.root_transcript) or nil
  b:add("  transcript " .. or_dash(tp))
  if a.error_head then b:add({ { "  error    " .. error_text(a.error_head), "AgentMapFailed" } }) end

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
    local cst = ca.status or "PENDING"
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
