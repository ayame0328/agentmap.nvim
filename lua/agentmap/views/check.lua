-- agentmap/views/check.lua ... the HUMAN CHECK (AskUserQuestion) detail view shown in the side window.
--   何を聞いたか・なぜ聞いたか（子の「要確認」）・選択肢ごとの進め方・答え、を 1 枚にまとめる。
--   答えはターミナルで入れる（Neovim は表示だけ）。build は純粋（state から行を作るだけ）。
local graph = require("agentmap.graph")
local renderer = require("agentmap.renderer")
local brief = require("agentmap.brief")
local detail = require("agentmap.views.detail")
local H = graph.util
local t = require("agentmap.i18n").t

local M = {}

-- バッファごとの「行 → Agent id」の表（detail と同じ形。Enter で開く）
M.links = {}

-- 結びつけの根拠（state の link_source）を人が読める言い方に（i18n キー）
local LINK_TEXT = {
  name = "check.link_name",
  report = "check.link_report",
  report_late = "check.link_report_late",
}

-- 答えないまま終わった理由（state の end_reason → i18n キー）。見出しの（）の中に入るので括弧を重ねない
local END_TEXT = {
  turn_ended = "check.end_turn_ended",
  new_prompt = "check.end_new_prompt",
  session_ended = "check.end_session_ended",
  tool_failed = "check.end_tool_failed",
}

local function end_text(reason)
  return t(END_TEXT[reason] or "check.end_unknown")
end

local function label_of(state, id)
  if id == nil then return "?" end
  if id == "ROOT" then return "ROOT" end
  local a = state.agents and state.agents[id]
  if not a then return "[?] " .. tostring(id) end
  return "[" .. (a.index or "?") .. "] " .. (a.name or a.task or H.short_id(id))
end

-- その check の指示（流れ）："指示 2/3: 本文"
local function flow_text(state, c)
  if state.flow then
    return t("check.flow", { n = state.flow.n or 0, total = state.flow.total or 0,
      text = H.oneline(state.flow.prompt_head or t("common.no_prompt")) })
  end
  if c.prompt_id and type(state.flows) == "table" then
    for _, f in ipairs(state.flows) do
      if f.id == c.prompt_id then
        return t("check.flow", { n = f.n or 0, total = #state.flows, text = H.oneline(f.prompt_head or t("common.no_prompt")) })
      end
    end
  end
  return nil
end

local function header_line(c, ci)
  local segs = { { "■ HUMAN CHECK" .. (ci.n and (" #" .. ci.n) or ""), "AgentMapHeader" }, { "   " }, { ci.tag, ci.hl } }
  local parts = { t("check.asked_at", { time = H.fmt_clock(c.asked_at) }) }
  local el = ci.elapsed_ms and H.fmt_elapsed(ci.elapsed_ms) or "-"
  if ci.status == "WAITING" then
    parts[#parts + 1] = t("check.waiting_for", { elapsed = el })
  elseif ci.status == "ANSWERED" then
    parts[#parts + 1] = t("check.answered_at", { time = H.fmt_clock(c.answered_at), elapsed = el })
  else
    parts[#parts + 1] = t("check.ended_at", { time = H.fmt_clock(c.ended_at), reason = end_text(c.end_reason) })
  end
  segs[#segs + 1] = { table.concat(parts) }
  return segs
end

--- Build the lines of the HUMAN CHECK view (pure). extra = { width = columns, now = seconds }.
function M.build(state, check, extra)
  extra = extra or {}
  local width = math.max(40, extra.width or 80)
  local kv = function(b, label, value, hl, missing) detail.kv(b, width, label, value, hl, missing) end
  local wrap = detail.wrap
  local b = renderer.builder()
  local c = check or {}
  local ci = graph.check_info(state, c, extra.now)
  local agent = c.agent_id and state.agents and state.agents[c.agent_id] or nil
  local ask = agent and type(agent.ask) == "table" and agent.ask or nil

  b:add(header_line(c, ci))
  local asker = c.asker_id or "ROOT"
  b:add({ { "  " .. H.fit(t("check.asker"), 16) }, { label_of(state, asker) }, { "   " .. t("common.enter_for_detail"), "AgentMapDim" } }, asker)
  if c.agent_id then
    b:add({ { "  " .. H.fit(t("check.trigger"), 16) }, { t("check.trigger_ask", { label = label_of(state, c.agent_id) }) },
      { "   " .. t("common.enter_for_detail"), "AgentMapDim" } }, c.agent_id)
    kv(b, t("check.link"), LINK_TEXT[c.link_source] and t(LINK_TEXT[c.link_source]) or t("check.link_unknown"))
  else
    kv(b, t("check.trigger"), t("check.direct"), "AgentMapDim")
  end
  local ft = flow_text(state, c)
  if ft then kv(b, t("check.prompt"), ft) end
  kv(b, "ID", c.id)

  b:add("")
  b:add({ { t("check.h_lead"), "AgentMapHeader" } })
  if c.lead and c.lead ~= "" then
    for _, l in ipairs(wrap(t("common.quote", { text = H.oneline(c.lead) }), width - 4)) do b:add("  " .. l) end
  else
    b:add({ { t("check.no_lead"), "AgentMapDim" } })
  end

  -- 子の「要確認」から生まれた質問なら、子が書いた事情を先に出す
  if agent then
    b:add("")
    local function para(v)
      if v == nil or v == "" then
        b:add({ { "  " .. t("common.missing"), "AgentMapDim" } })
        return
      end
      for _, l in ipairs(wrap(H.oneline(v), width - 4)) do b:add("  " .. l) end
    end
    b:add({ { t("check.h_working"), "AgentMapHeader" } })
    para(ask and ask.working)
    b:add({ { t("check.h_stuck"), "AgentMapHeader" } })
    para(ask and ask.stuck)
  end

  b:add("")
  b:add({ { t("check.h_question"), "AgentMapHeader" } })
  if ask and ask.want then kv(b, t("check.child_report"), ask.want) end
  local qs = c.questions or {}
  if #qs == 0 then b:add({ { t("check.no_questions"), "AgentMapDim" } }) end
  for qi, q in ipairs(qs) do
    local head = "Q" .. qi .. " " .. ((q.header and q.header ~= "") and ("[" .. q.header .. "] ") or "")
    -- 先頭の「<子の名前> について：」は「きっかけ」の行と重なるので落とす（DESIGN §6.3。表示だけ）
    local qtext = graph.strip_question_prefix(q.question, agent) or t("common.no_question")
    local body = wrap(H.oneline(qtext), width - 4 - H.dw(head))
    for i, l in ipairs(body) do
      b:add({ { "  " }, { i == 1 and head or string.rep(" ", H.dw(head)), i == 1 and "AgentMapIndex" or nil }, { l } })
    end
  end

  -- 選択肢ごとに「選んだらどう進むか」。答えが出ていれば選ばれたものに印
  local answered = brief.answered_options(c, agent)
  local chosen = {}
  for _, e in ipairs(answered) do
    for _, m in ipairs(e.matches or {}) do
      if m.option then chosen[e.qi .. ":" .. m.option.i] = true end
    end
  end
  b:add("")
  b:add({ { t("check.h_options"), "AgentMapHeader" } })
  for qi, q in ipairs(qs) do
    if #qs > 1 then b:add({ { "  Q" .. qi, "AgentMapIndex" } }) end
    local opts = q.options or {}
    if #opts == 0 then b:add({ { t("check.no_options"), "AgentMapDim" } }) end
    for oi, o in ipairs(opts) do
      local desc = brief.split_next(o.description)
      local mark = chosen[qi .. ":" .. oi] and { t("check.chosen"), "AgentMapDone" } or { "" }
      b:add({ { "   " .. oi .. ". " }, { o.label or "?", chosen[qi .. ":" .. oi] and "AgentMapDone" or nil },
        { (desc and desc ~= "") and ("  — " .. H.oneline(desc)) or "", "AgentMapDim" }, mark })
      local nxt = brief.next_of(c, qi, oi, agent)
      if nxt then
        for i, l in ipairs(wrap(t("check.if_chosen", { text = H.oneline(nxt) }), width - 8)) do
          b:add("      " .. (i == 1 and "" or "  ") .. l)
        end
      else
        b:add({ { t("check.no_next"), "AgentMapDim" } })
      end
    end
    if q.multi then b:add({ { t("check.multi"), "AgentMapDim" } }) end
  end

  b:add("")
  b:add({ { t("check.h_answer"), "AgentMapHeader" } })
  if ci.status == "WAITING" then
    b:add({ { t("check.not_answered"), "AgentMapWaiting" } })
  elseif ci.status == "ABANDONED" then
    local why = end_text(c.end_reason)
    if c.end_reason == "tool_failed" and c.error_head then
      why = t("check.reason_detail", { reason = why, detail = H.oneline(c.error_head) })
    end
    b:add({ { t("check.ended_unanswered", { reason = why }), "AgentMapDim" } })
  else
    local any = false
    for _, e in ipairs(answered) do
      local prefix = "  " .. (#answered > 1 and ("Q" .. e.qi .. " → ") or "")
      if #e.labels == 0 then
        if #answered > 1 then b:add({ { prefix .. t("common.no_answer"), "AgentMapDim" } }) end
      else
        any = true
        local quoted = {}
        for _, l in ipairs(e.labels) do quoted[#quoted + 1] = t("common.quote", { text = H.oneline(l) }) end
        b:add({ { prefix }, { table.concat(quoted), "AgentMapDone" } })
        for _, m in ipairs(e.matches or {}) do
          if m.option then
            kv(b, t("check.next_step"), m.option.next, nil, t("common.missing_next"))
          else
            kv(b, t("check.free_text"), m.label)
          end
        end
      end
    end
    if not any then b:add({ { "  " .. t("common.no_answer"), "AgentMapDim" } }) end
  end

  if agent and agent.report and agent.report ~= "" then
    b:add("")
    b:add({ { t("check.h_child_report"), "AgentMapHeader" } })
    for _, l in ipairs(wrap(agent.report, width - 4)) do b:add("  " .. l) end
  end

  b:add("")
  b:add({ { t("check.footer", { label = label_of(state, asker) }), "AgentMapDim" } })
  return b:result()
end

--- Render the HUMAN CHECK `check` of run.state into `buf`.
function M.open(run, check, buf, opts)
  opts = opts or {}
  local res = M.build(run.state, check, { width = opts.width, now = opts.now })
  renderer.set_all(buf, res.lines, res.marks)
  M.links[buf] = res.links
  return res
end

return M
