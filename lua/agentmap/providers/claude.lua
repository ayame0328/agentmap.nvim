-- ============================================================
--  agentmap/providers/claude.lua ... reads Claude Code's records (hook payloads, transcripts, meta.json).
--    Everything Claude-specific lives here (P17).
--
--  1) normalize_hook : collector が書いた hooks.jsonl の 1 行 → 整えた記録（DESIGN §3）
--  2) backfill       : hooks が無い昔のセッションを、Claude の transcript から組み立てる（§5）
--  3) transcript 画面・モデル名・meta.json の読み出し
--
--  親子関係は「推測しない」。使うのは次の 3 つだけ：
--    - PostToolUse(Agent) の tool_response.agentId（呼んだ側 = 親）
--    - Claude 自身の meta.json（toolUseId / parentAgentId / spawnDepth）
--    - transcript の中の Agent 呼び出しの結果（agentId が返ってきた側 = 親）
-- ============================================================
local config = require("agentmap.config")
local util = require("agentmap.util")
local brief = require("agentmap.brief")

local M = { name = "claude" }
local uv = vim.uv or vim.loop

local WRITE_TOOLS = { Write = true, Edit = true, MultiEdit = true, NotebookEdit = true }
local HEAD = 200
local LEAD = 400          -- 親の直前の発言を何文字まで残すか
local REPORT_TAIL = 65536 -- 子の transcript の末尾何バイトから報告を探すか（収集係と同じ）
local NOTE = 120          -- 作業の経過の 1 行（子の text）を何文字まで残すか

-- ---------- 小道具 ----------

local function head(s, n)
  if type(s) ~= "string" then return nil end
  s = s:gsub("[\r\n]", " ")
  n = n or HEAD
  if vim.fn.strchars(s) <= n then return s end
  return vim.fn.strcharpart(s, 0, n)
end

local function tail_path(p, n)
  if type(p) ~= "string" then return nil end
  n = n or 120
  if vim.fn.strchars(p) <= n then return p end
  return "…" .. vim.fn.strcharpart(p, vim.fn.strchars(p) - (n - 1))
end

local function first_line(s, n)
  if type(s) ~= "string" then return nil end
  s = vim.trim(s):match("^[^\n]*") or ""
  return head(s, n or 120)
end

local function decode(line)
  local ok, t = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if ok and type(t) == "table" then return t end
  return nil
end

--- 文字列を 1 行にして n 文字で切る（改行は空白に。前後の空白は落とす）。空なら nil
local function one_line(s, n)
  if type(s) ~= "string" then return nil end
  s = brief.trim((s:gsub("[\r\n]+", " ")))
  if s == "" then return nil end
  return brief.clip(s, n)
end

--- Normalize AskUserQuestion questions into the state's shape (multiSelect -> multi), clipped by brief.LIMITS.
--- AskUserQuestion の questions を state の形にする（multiSelect → multi）。個数と長さは brief.LIMITS で切る
--   hooks（収集係が切った後）でも transcript（切る前）でも同じ形・同じ上限になるようにここで整える
function M.norm_questions(qs)
  local L = brief.LIMITS
  -- 文字列以外（数・null の印など）は捨てる。画面の側は文字列だと思って連結するので、ここで止める
  local function str(x) return type(x) == "string" and x or nil end
  local out = {}
  if type(qs) ~= "table" then return out end
  for qi, q in ipairs(qs) do
    if qi > L.questions then break end
    if type(q) == "table" then
      local opts = {}
      for oi, o in ipairs(type(q.options) == "table" and q.options or {}) do
        if oi > L.options then break end
        if type(o) == "table" then
          opts[#opts + 1] = { label = brief.clip(str(o.label), L.label), description = brief.clip(str(o.description), L.description) }
        end
      end
      out[#out + 1] = {
        question = brief.clip(str(q.question), L.question), header = brief.clip(str(q.header), L.label),
        multi = q.multiSelect == true or q.multi == true, options = opts,
      }
    end
  end
  return out
end

--- 答えの表 { [質問文] = "label" | { "a", "b" } } を、値ごとに上限で切った写しにする
local function norm_answers(a)
  if type(a) ~= "table" then return nil end
  local L = brief.LIMITS.question
  local out = {}
  for k, v in pairs(a) do
    if type(k) == "string" then
      if type(v) == "table" then
        local arr = {}
        for _, x in ipairs(v) do arr[#arr + 1] = type(x) == "string" and brief.clip(x, L) or x end
        out[brief.clip(k, L)] = arr
      elseif v ~= nil then
        out[brief.clip(k, L)] = brief.clip(tostring(v), L)
      end
    end
  end
  return out
end

--- 整えた記録の共通部分をつける
local function mk(event, ts, run_id, src, fields)
  local ev = { v = 1, ts = ts, event = event, run_id = run_id, src = src }
  for k, v in pairs(fields or {}) do ev[k] = v end
  return ev
end

--- meta.json の親の決め方（推測なし）
---   parentAgentId があればそれ。無くて spawnDepth == 1 なら親は ROOT（Claude 自身の記録）
local function meta_parent(meta)
  if type(meta) ~= "table" then return nil end
  if type(meta.parentAgentId) == "string" and meta.parentAgentId ~= "" then return meta.parentAgentId end
  if meta.spawnDepth == 1 then return "ROOT" end
  return nil
end
M._meta_parent = meta_parent

--- Workflow から起動された Agent の transcript / meta.json の場所から Workflow の id を取る（読み込みなし）
---   …/subagents/workflows/<wf_id>/agent-<id>.jsonl → "<wf_id>"
local function wf_of_path(p)
  return type(p) == "string" and p:match("/subagents/workflows/([^/]+)/agent%-") or nil
end
M._wf_of_path = wf_of_path

--- First meaningful line of a prompt (up to 60 chars), skipping workflow preamble lines.
--- 依頼文の最初の意味のある 1 行（60 文字まで）。Workflow の前置き行は飛ばす
function M.prompt_line(txt)
  if type(txt) ~= "string" then return nil end
  for _, l in ipairs(vim.split(txt, "\n", { plain = true })) do
    local t = vim.trim(l)
    if t ~= "" and not t:find("^%[Workflow harness") then return head(t, 60) end
  end
  return nil
end

-- ============================================================
-- 1) hooks.jsonl の 1 行 → 整えた記録
-- ============================================================

--- Normalize one hooks.jsonl record into a list of events.
--- @param rec table collector が書いた 1 行
--- @return table[] 整えた記録（0 件以上）
function M.normalize_hook(rec)
  if type(rec) ~= "table" then return {} end
  local ev = rec.hook_event_name
  local ts = rec._ts or util.iso_now()
  local rid = rec.session_id
  local out = {}
  -- どの指示（prompt_id）から始まった記録かを、全部の記録に付けておく（指示ごとの「流れ」に分けるため）
  local function add(event, fields)
    if fields.prompt_id == nil then fields.prompt_id = rec.prompt_id end
    out[#out + 1] = mk(event, ts, rid, "hook", fields)
  end
  local who = rec.agent_id or "ROOT"

  -- 修正指示の配達の記録（collector --steer が書いた行）。記録係の行ではないので、ほかの記録は作らない
  if type(rec.steer) == "table" then
    local st = rec.steer
    local via = tostring(ev or "") .. (rec.tool_name and (":" .. rec.tool_name) or "")
    for _, sid in ipairs(type(st.ids) == "table" and st.ids or {}) do
      if type(sid) == "string" and sid ~= "" then
        add("steer_delivered", {
          steer_id = sid, agent_id = type(st.target) == "string" and st.target or who,
          via = via, tool_use_id = rec.tool_use_id, mode = st.mode,
        })
      end
    end
    return out
  end

  -- 一時停止の記録（collector --pause が書いた行。DESIGN-v0.1.2-pause §5.1）。これもほかの記録は作らない
  if type(rec.pause) == "table" then
    local p = rec.pause
    local pid = type(p.id) == "string" and p.id ~= "" and p.id or nil
    if not pid then return out end
    local target = type(p.target) == "string" and p.target ~= "" and p.target or who
    if p.phase == "hit" then
      add("pause_hit", {
        pause_id = pid, agent_id = target, kind = p.kind, at = p.at,
        via = tostring(ev or "") .. (rec.tool_name and (":" .. rec.tool_name) or ""),
        tool_use_id = rec.tool_use_id, deadline = p.deadline,
      })
    elseif p.phase == "released" then
      add("pause_released", {
        pause_id = pid, agent_id = target, reason = p.reason, waited_ms = tonumber(p.waited_ms),
        steer_ids = type(p.steer_ids) == "table" and p.steer_ids or nil,
      })
    elseif p.phase == "aborted" then
      add("pause_aborted", { pause_id = pid, agent_id = target, waited_ms = tonumber(p.waited_ms) })
    end
    return out
  end

  if ev == "SessionStart" then
    add("run_started", { cwd = rec.cwd, transcript_path = rec.transcript_path, source = rec.source })
    add("agent_started", { agent_id = "ROOT", cwd = rec.cwd })
  elseif ev == "UserPromptSubmit" then
    if rec.prompt_head then add("run_prompt", { prompt_head = rec.prompt_head, kind = rec.kind, cwd = rec.cwd }) end
  elseif ev == "PreToolUse" then
    if rec.tool_name == "Agent" and rec.tool_use_id then
      local ti = rec.tool_input or {}
      add("agent_spawn_requested", {
        tool_use_id = rec.tool_use_id, parent_id = who, task = ti.description,
        agent_type = ti.subagent_type, model_requested = ti.model, isolation = ti.isolation,
        prompt_head = ti.prompt_head, brief = type(ti.brief) == "table" and ti.brief or nil,
      })
    elseif rec.tool_name == "AskUserQuestion" and rec.tool_use_id then
      -- HUMAN CHECK：質問を出した（聞いた側 = hook の agent_id。無ければ ROOT）
      add("check_asked", {
        tool_use_id = rec.tool_use_id, asker_id = who,
        questions = M.norm_questions((rec.tool_input or {}).questions),
      })
    end
  elseif ev == "PostToolUse" then
    if rec.tool_name == "AskUserQuestion" then
      -- 答えが出た。AskUserQuestion はツールの回数（tool_used）に数えない（ROOT のツール一覧に混ぜない）
      if rec.tool_use_id then
        local qs = M.norm_questions((rec.tool_input or {}).questions)
        add("check_answered", {
          tool_use_id = rec.tool_use_id, asker_id = who,
          answers = norm_answers((rec.tool_response or {}).answers) or {},
          questions = #qs > 0 and qs or nil,
        })
      end
    elseif rec.tool_name == "Agent" then
      local tr = rec.tool_response or {}
      local ti = rec.tool_input or {}
      if tr.agentId then
        add("agent_linked", {
          agent_id = tr.agentId, parent_id = who, source = "post_tool_use",
          tool_use_id = rec.tool_use_id, model = tr.resolvedModel,
          task = tr.description or ti.description, agent_type = ti.subagent_type,
          prompt_head = ti.prompt_head, is_async = tr.isAsync,
          brief = type(ti.brief) == "table" and ti.brief or nil,
        })
        if tr.status ~= "async_launched" then
          add("agent_finished", { agent_id = tr.agentId, duration_ms = rec.duration_ms })
        end
      end
    elseif rec.tool_name then
      local tr = rec.tool_response or {}
      if rec.tool_name == "Workflow" and tr.runId then
        local ti = rec.tool_input or {}
        add("workflow_started", {
          wf_id = tr.runId, parent_id = who, tool_use_id = rec.tool_use_id, name = tr.workflowName,
          task = ti.description or tr.summary, summary = tr.summary, resume_of = ti.resumeFromRunId,
        })
      end
      add("tool_used", {
        agent_id = who, tool_name = rec.tool_name, target = rec.target,
        tool_use_id = rec.tool_use_id, duration_ms = rec.duration_ms, cwd = rec.cwd,
      })
      -- 親経由の修正指示が渡った事実（ROOT などが SendMessage を使った。宛先 to が無ければ作らない。
      -- DESIGN-v0.1.2-steer2 §6.3）。子が読んだかは記録に無いので追わない
      if rec.tool_name == "SendMessage" then
        local ti = rec.tool_input or {}
        local to = type(ti.to) == "string" and ti.to ~= "" and ti.to or nil
        if to then
          add("message_sent", {
            agent_id = who, to = to, head = type(ti.head) == "string" and ti.head or nil,
            summary = type(ti.summary) == "string" and ti.summary or nil, tool_use_id = rec.tool_use_id,
          })
        end
      end
      -- 手順表（TaskCreate / TaskUpdate / TaskList）。進み具合の事実（DESIGN-v0.2 §2.2）
      local ti = rec.tool_input or {}
      if rec.tool_name == "TaskCreate" then
        local task = type(tr.task) == "table" and tr.task or {}
        if task.id ~= nil then
          add("task_created", {
            agent_id = who, task_id = tostring(task.id), subject = task.subject or ti.subject,
            active_form = ti.activeForm,
          })
        end
      elseif rec.tool_name == "TaskUpdate" then
        local sc = type(tr.statusChange) == "table" and tr.statusChange or nil
        local tid = tr.taskId or ti.taskId
        if sc and tid ~= nil and type(sc.to) == "string" then
          add("task_updated", { agent_id = who, task_id = tostring(tid), status_from = sc.from, status_to = sc.to })
        end
      elseif rec.tool_name == "TaskList" and type(tr.tasks) == "table" then
        local tasks = {}
        for _, x in ipairs(tr.tasks) do
          if type(x) == "table" and x.id ~= nil then
            tasks[#tasks + 1] = { id = tostring(x.id), subject = x.subject, status = x.status }
          end
        end
        add("task_listed", { agent_id = who, tasks = tasks })
      end
    end
  elseif ev == "PostToolUseFailure" then
    if rec.tool_name == "Agent" then
      add("agent_failed", { tool_use_id = rec.tool_use_id, error_head = rec.error_head })
    elseif rec.tool_name == "AskUserQuestion" and rec.tool_use_id then
      add("check_abandoned", { tool_use_id = rec.tool_use_id, reason = rec.error_head })
    end
  elseif ev == "SubagentStart" then
    if rec.agent_id then
      local meta = rec.meta or {}
      -- Workflow の Agent は hook の agent_type が "" で届く → meta.json の agentType を使う
      local at = rec.agent_type
      if at == "" then at = nil end
      add("agent_started", {
        agent_id = rec.agent_id, agent_type = at or meta.agentType, cwd = rec.cwd,
        meta_tool_use_id = meta.toolUseId, meta_parent_id = meta_parent(meta), model = meta.model,
        wf_id = meta.wf_id, task = meta.description, phase = meta.workflowPhase,
      })
    end
  elseif ev == "SubagentStop" then
    if rec.agent_id then
      add("agent_finished", {
        agent_id = rec.agent_id, transcript_path = rec.agent_transcript_path, last_head = rec.last_head,
        wf_id = wf_of_path(rec.agent_transcript_path), agent_type = rec.agent_type ~= "" and rec.agent_type or nil,
        report = type(rec.report) == "string" and rec.report ~= "" and rec.report or nil,
      })
    end
  elseif ev == "Stop" then
    add("turn_ended", { last_head = rec.last_head })
  elseif ev == "SessionEnd" then
    add("run_ended", { reason = rec.reason or "unknown" })
  end
  return out
end

-- ============================================================
-- 2) transcript の場所
-- ============================================================

--- Claude's config folder (derived from transcript_path when known).
--- Claude の設定フォルダ。transcript_path が分かっていればそこから逆算する
function M.config_dir(transcript_path)
  if type(transcript_path) == "string" then
    local d = transcript_path:match("^(.*)/projects/")
    if d then return d end
  end
  return config.claude_config_dir()
end

local function root_transcript_of(run)
  if type(run) ~= "table" then return nil end
  local st = run.state or {}
  if st.root_transcript then return st.root_transcript end
  if run.slug and run.sid then
    return M.config_dir() .. "/projects/" .. run.slug .. "/" .. run.sid .. ".jsonl"
  end
  return nil
end

local function subagents_dir(run)
  local rt = root_transcript_of(run)
  if not rt then return nil end
  local sid = run.sid or (run.state and run.state.run_id)
  return util.dirname(rt) .. "/" .. sid .. "/subagents"
end

local function exists(p) return p and uv.fs_stat(p) ~= nil end

--- Transcript path of one agent, or nil.
--- 1 つの Agent の transcript の場所（無ければ nil）
function M.agent_transcript_path(run, agent)
  if type(agent) ~= "table" then return nil end
  if agent.id == "ROOT" then return root_transcript_of(run) end
  if agent.transcript_path and exists(agent.transcript_path) then return agent.transcript_path end
  local sd = subagents_dir(run)
  if not sd then return agent.transcript_path end
  local p = sd .. "/agent-" .. agent.id .. ".jsonl"
  if exists(p) then return p end
  local hits = vim.fn.glob(sd .. "/**/agent-" .. agent.id .. ".jsonl", false, true)
  if hits[1] then return hits[1] end
  return agent.transcript_path
end

--- Incrementally map Agent calls to the message id of their reply in a transcript.
--- transcript の中の「Agent 呼び出し → その返事 1 通の message.id」の対応を、前回の続きから読み足す
---   同じ message.id ＝ 親が 1 通の返事でまとめて起動した Agent（段分けで同じ段にする印）。
---   hooks の記録には message.id が無く、hook の時点では transcript にまだ書かれていないことが多い
---   （2026-09-29 実測：PreToolUse から 0.1〜1.4 秒後に書かれる）ので、後から transcript で引く。
---   idx = { off = 読んだ位置, map = { [tool_use_id] = message.id },
---           lead = { [Agent の tool_use_id] = 直前の発言 }, ask_lead = { [AskUserQuestion の tool_use_id] = 直前の発言 },
---           brief = { [Agent の tool_use_id] = 【目的】【任せる理由】【期待する結果】 } }
---   brief は、収集係が【】を抜く前の版で記録された run（hooks に brief が無い）を後から埋めるため。
---   Agent 呼び出しの行はどうせ decode するので、prompt から読むのに追加の読み込みは要らない
---   「直前の発言」= 同じ返事（message.id が同じ）の、その tool_use より前の最後の text ブロック（400 文字）。
---   実物の transcript は 1 行に 1 ブロックで、同じ返事の text と tool_use は別の行に分かれる（2026-10-01 実測）。
---   そこで assistant の text の行も読み、message.id ごとに最後の text を idx.cur に覚えておく。
---   別の返事の text までは遡らない（遡ると別の話を拾うため。無ければ「無い」）。読むのは増えた分だけ
function M.agent_batches(path, idx)
  idx = idx or { off = 0, map = {} }
  idx.map = idx.map or {}
  idx.lead = idx.lead or {}
  idx.ask_lead = idx.ask_lead or {}
  idx.brief = idx.brief or {}
  local st = type(path) == "string" and uv.fs_stat(path)
  if not st then return idx end
  if st.size < idx.off then idx.off, idx.map, idx.lead, idx.ask_lead, idx.brief, idx.cur = 0, {}, {}, {}, {}, nil end -- 作り直された
  if st.size == idx.off then return idx end
  local f = io.open(path, "rb")
  if not f then return idx end
  f:seek("set", idx.off)
  local data = f:read(st.size - idx.off) or ""
  f:close()
  local pos = 1
  while true do
    local nl = data:find("\n", pos, true)
    if not nl then break end -- 書きかけの最後の行は次回
    if nl > pos then
      local line = data:sub(pos, nl - 1)
      if line:find('"type":"assistant"', 1, true) then
        local is_call = line:find('"tool_use"', 1, true)
            and (line:find('"name":"Agent"', 1, true) or line:find('"name":"Task"', 1, true)
              or line:find('"name":"AskUserQuestion"', 1, true))
        local is_text = line:find('"type":"text"', 1, true)
        if is_call or is_text then
          local t = decode(line)
          local msg = t and t.message
          if type(msg) == "table" and type(msg.id) == "string" and type(msg.content) == "table" then
            if not idx.cur or idx.cur.id ~= msg.id then idx.cur = { id = msg.id } end
            for _, b in ipairs(msg.content) do
              if type(b) == "table" then
                if b.type == "text" and type(b.text) == "string" then
                  local l = one_line(b.text, LEAD)
                  if l then idx.cur.text = l end
                elseif b.type == "tool_use" and type(b.id) == "string" then
                  if b.name == "Agent" or b.name == "Task" then
                    idx.map[b.id] = msg.id
                    if idx.cur.text then idx.lead[b.id] = idx.cur.text end
                    local br = brief.parse_brief(type(b.input) == "table" and b.input.prompt or nil)
                    if br then idx.brief[b.id] = br end
                  elseif b.name == "AskUserQuestion" then
                    if idx.cur.text then idx.ask_lead[b.id] = idx.cur.text end
                  end
                end
              end
            end
          end
        end
      end
    end
    pos = nl + 1
  end
  idx.off = idx.off + pos - 1
  return idx
end

local STEPS_MAX_BYTES = 20 * 1024 * 1024 -- 手順の目印を読む transcript の上限（これより先は読まない）

--- 手順表を items にする：一覧（n, text）に、今までの印（done / start）を番号で当てる。一覧の数を超える印は捨てる
local function build_steps(list, marks)
  local items = {}
  for i, it in ipairs(list) do items[i] = { n = it.n, text = it.text } end
  for _, m in ipairs(marks) do
    local it = items[m.n]
    if it then
      if m.kind == "done" then
        it.done_at = it.done_at or m.ts
      elseif m.kind == "start" then
        it.started_at = it.started_at or m.ts
      end
    end
  end
  return items
end

--- Incrementally read the step list ("## Steps" / "## 手順") and step marks ("Step N done" / "手順 N 完了")
--- from one agent's own transcript (assistant text blocks only).
--- 手順表と済んだ印を、その Agent 自身の transcript の増えた分だけ読む（DESIGN-v0.2 §2.1 B）
---   idx = { off = 読んだ位置, list = 最後の一覧 { {n, text} } | nil, marks = { {n, kind, ts} }（最後の一覧より後）,
---           items = { {n, text, started_at?, done_at?} }（list に marks を当てたもの）, listed_at = ts, truncated = bool|nil }
---   読むのは type == "assistant" の行の text ブロックだけ（tool_use の中身・tool_result・user 行は読まない）。
---   一覧が 2 回以上出たら後の一覧が勝つ（済んだ印は番号で持ち越す）。一覧より前の印は捨てる。
---   20 MB を超えたら、それより先は読まない（idx.truncated = true）
---@return table idx
function M.agent_steps(path, idx)
  idx = idx or { off = 0 }
  idx.off = idx.off or 0
  idx.marks = idx.marks or {}
  idx.items = idx.items or {}
  local st = type(path) == "string" and uv.fs_stat(path)
  if not st then return idx end
  if st.size < idx.off then -- 作り直された
    idx.off, idx.list, idx.marks, idx.items, idx.listed_at, idx.truncated = 0, nil, {}, {}, nil, nil
  end
  if idx.off >= STEPS_MAX_BYTES then
    if st.size > idx.off then idx.truncated = true end
    return idx
  end
  if st.size == idx.off then return idx end
  local upto = math.min(st.size, STEPS_MAX_BYTES)
  local f = io.open(path, "rb")
  if not f then return idx end
  f:seek("set", idx.off)
  local data = f:read(upto - idx.off) or ""
  f:close()
  local changed = false
  local pos = 1
  while true do
    local nl = data:find("\n", pos, true)
    if not nl then break end -- 書きかけの最後の行は次回
    if nl > pos then
      local line = data:sub(pos, nl - 1)
      -- 目印の語（Step / 手順）を含む assistant の text の行だけ decode する（大きな transcript でも軽く）
      if line:find('"type":"assistant"', 1, true) and line:find('"type":"text"', 1, true)
          and (line:find("[Ss][Tt][Ee][Pp]") or line:find("手順", 1, true)) then
        local t = decode(line)
        local msg = t and t.message
        if t and t.type == "assistant" and type(msg) == "table" and type(msg.content) == "table" then
          for _, b in ipairs(msg.content) do
            if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
              for _, e in ipairs(brief.step_events(b.text)) do
                if e.kind == "list" then
                  idx.list = e.items
                  idx.listed_at = t.timestamp
                  -- 済んだ印は番号で持ち越す（新しい一覧の数を超えるものは捨てる）
                  local keep = {}
                  for _, m in ipairs(idx.marks) do
                    if m.n <= #e.items then keep[#keep + 1] = m end
                  end
                  idx.marks = keep
                  changed = true
                elseif idx.list then -- 一覧より前の印は捨てる
                  idx.marks[#idx.marks + 1] = { n = e.n, kind = e.mark, ts = t.timestamp }
                  changed = true
                end
              end
            end
          end
        end
      end
    end
    pos = nl + 1
  end
  idx.off = idx.off + pos - 1
  if upto < st.size then idx.truncated = true end -- 上限より先は読まない
  if changed and idx.list then idx.items = build_steps(idx.list, idx.marks) end
  return idx
end

--- The steps table for the state (a.steps) from an agent_steps index, or nil when there is no list.
---@return table|nil { source = "transcript", listed_at, truncated?, items = { {n, text, started_at?, done_at?} } }
function M.steps_of(idx)
  if type(idx) ~= "table" or not idx.list or #(idx.items or {}) == 0 then return nil end
  local items = {}
  for i, it in ipairs(idx.items) do
    items[i] = { n = it.n, text = it.text, started_at = it.started_at, done_at = it.done_at }
  end
  return { source = "transcript", listed_at = idx.listed_at, truncated = idx.truncated or nil, items = items }
end

--- The report from the last 64 KB of a child's transcript.
--- 子の transcript の末尾 64KB から報告を取る
---   最後の SubagentHandback の input.message。無ければ最後の空でない assistant の text ブロック
--- @return string|nil 報告（2000 文字まで。改行は残す）, "handback"|"text"|nil
function M.agent_report(path)
  if type(path) ~= "string" then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end") or 0
  local off = math.max(0, size - REPORT_TAIL)
  f:seek("set", off)
  local data = f:read("*a") or ""
  f:close()
  if off > 0 then data = data:gsub("^[^\n]*\n", "") end -- 途中から始まる 1 行目は捨てる
  local lines = vim.split(data, "\n", { plain = true })
  local text
  for i = #lines, 1, -1 do
    local l = lines[i]
    if l:find('"type":"assistant"', 1, true) then
      local hb = l:find('"name":"SubagentHandback"', 1, true)
      if hb or (not text and l:find('"type":"text"', 1, true)) then
        local t = decode(l)
        local c = t and type(t.message) == "table" and t.message.content
        if type(c) == "table" then
          for j = #c, 1, -1 do
            local b = c[j]
            if type(b) == "table" then
              if hb and b.type == "tool_use" and b.name == "SubagentHandback" then
                local m = type(b.input) == "table" and b.input.message
                if type(m) == "string" and m:find("%S") then
                  return brief.clip(m, brief.LIMITS.report), "handback"
                end
              elseif not text and b.type == "text" and type(b.text) == "string" and b.text:find("%S") then
                text = b.text
              end
            end
          end
        end
      end
    end
  end
  if text then return brief.clip(text, brief.LIMITS.report), "text" end
  return nil
end

--- Incrementally read the progress notes (text blocks and tool calls) of a child's transcript.
--- 作業の経過（子の text ブロックとツール呼び出し）を、前回の続きから読み足す
---   idx = { off = 読んだ位置, entries = { {ts, kind = "note"|"tool", text | tool, target}, … } }
---   初回はファイルが opts.max_first（1MB）より大きければ末尾だけ読む（ROOT の transcript は 10MB を超えることがある）。
---   entries は opts.max（400）件を超えたら古いものから捨てる。詳細画面を開いたときだけ呼ばれる
function M.agent_notes(path, idx, opts)
  opts = opts or {}
  local max_first = opts.max_first or 1e6
  local max = opts.max or 400
  local note_chars = opts.note_chars or NOTE
  idx = idx or { off = 0, entries = {} }
  idx.entries = idx.entries or {}
  local st = type(path) == "string" and uv.fs_stat(path)
  if not st then return idx end
  if st.size < idx.off then idx.off, idx.entries = 0, {} end -- 作り直された
  if st.size == idx.off then return idx end
  local f = io.open(path, "rb")
  if not f then return idx end
  local from = idx.off
  local skip_first = false
  if from == 0 and st.size > max_first then
    from = st.size - max_first
    skip_first = true
  end
  f:seek("set", from)
  local data = f:read(st.size - from) or ""
  f:close()
  local pos = 1
  if skip_first then
    local nl = data:find("\n", 1, true)
    if not nl then return idx end
    pos = nl + 1
  end
  local ents = idx.entries
  while true do
    local nl = data:find("\n", pos, true)
    if not nl then break end -- 書きかけの最後の行は次回
    if nl > pos then
      local line = data:sub(pos, nl - 1)
      if line:find('"type":"assistant"', 1, true)
          and (line:find('"type":"text"', 1, true) or line:find('"tool_use"', 1, true)) then
        local t = decode(line)
        local msg = t and t.message
        if t and t.type == "assistant" and type(msg) == "table" and type(msg.content) == "table" then
          for _, b in ipairs(msg.content) do
            if type(b) == "table" then
              if b.type == "text" then
                local txt = one_line(b.text, note_chars)
                if txt then ents[#ents + 1] = { ts = t.timestamp, kind = "note", text = txt } end
              elseif b.type == "tool_use" then
                if b.name == "SubagentHandback" then
                  ents[#ents + 1] = { ts = t.timestamp, kind = "note", text = require("agentmap.i18n").t("providers.handback_note") }
                else
                  ents[#ents + 1] = { ts = t.timestamp, kind = "tool", tool = b.name, target = M._tool_target(b.name, b.input) }
                end
              end
            end
          end
        end
      end
    end
    pos = nl + 1
  end
  while #ents > max do table.remove(ents, 1) end
  idx.off = from + pos - 1
  return idx
end

--- Read Claude's meta.json for an agent, or nil.
--- meta.json（Claude 自身が書く Agent の付帯情報）を読む。無ければ nil
---   2 つ目の戻り値は見つけた場所（Workflow の Agent かどうかの判断に使う）
function M.read_meta(run, agent_id)
  if not agent_id or agent_id == "ROOT" then return nil end
  local sd = subagents_dir(run)
  if not sd then return nil end
  local p = sd .. "/agent-" .. agent_id .. ".meta.json"
  if not exists(p) then
    p = vim.fn.glob(sd .. "/workflows/*/agent-" .. agent_id .. ".meta.json", false, true)[1]
      or vim.fn.glob(sd .. "/**/agent-" .. agent_id .. ".meta.json", false, true)[1]
  end
  if not p then return nil end
  return util.json_decode(util.read_file(p)), p
end


--- Sessions that have only a transcript, newest first.
--- transcript だけある session の一覧（新しい順）
function M.list_sessions(slug)
  local dir = M.config_dir() .. "/projects/" .. slug
  local out = {}
  local h = uv.fs_scandir(dir)
  if not h then return out end
  while true do
    local name, typ = uv.fs_scandir_next(h)
    if not name then break end
    if typ == "file" and name:match("%.jsonl$") then
      local p = dir .. "/" .. name
      local st = uv.fs_stat(p)
      out[#out + 1] = {
        session_id = name:gsub("%.jsonl$", ""), path = p,
        mtime = st and st.mtime.sec or 0, size = st and st.size or 0,
      }
    end
  end
  table.sort(out, function(a, b) return a.mtime > b.mtime end)
  return out
end

--- Model of the parent (ROOT), from the last assistant message in the last 64 KB.
--- 親（ROOT）のモデル名：transcript の末尾 64KB から最後の assistant の model を探す
function M.root_model(path)
  if type(path) ~= "string" then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end") or 0
  f:seek("set", math.max(0, size - 65536))
  local data = f:read("*a") or ""
  f:close()
  local lines = vim.split(data, "\n", { plain = true })
  for i = #lines, 1, -1 do
    local l = lines[i]
    if l:find('"type":"assistant"', 1, true) then
      local t = decode(l)
      local m = t and t.message and t.message.model
      if type(m) == "string" and m ~= "" and m ~= "<synthetic>" then return m end
    end
  end
  return nil
end

--- Short model name for display: claude-haiku-4-5-20251001 -> haiku-4-5.
--- 表示用の短いモデル名：claude-haiku-4-5-20251001 → haiku-4-5
function M.model_short(m)
  if type(m) ~= "string" or m == "" then return nil end
  m = m:gsub("^claude%-", "")
  m = m:gsub("%-%d%d%d%d%d%d%d%d$", "")
  return m
end

-- ============================================================
-- 3) transcript から組み立て直す（hooks が無いとき）
-- ============================================================

-- tool_use の中身から、表に出してよい短い「対象」を作る
local function tool_target(name, input)
  if type(input) ~= "table" then return nil end
  if WRITE_TOOLS[name] then return tail_path(input.file_path or input.notebook_path) end
  if name == "Bash" then return first_line(input.command) end
  if name == "Agent" or name == "Task" then return head(input.description, 120) end
  if name == "Read" then return tail_path(input.file_path) end
  if name == "Grep" or name == "Glob" then return head(input.pattern, 120) end
  if name == "WebFetch" then return head(input.url, 120) end
  if name == "WebSearch" then return head(input.query, 120) end
  if name == "AskUserQuestion" then
    -- 人への質問：1 問目の質問文（複数なら「ほか n 問」）。作業の経過で「何を聞いたか」が見えるように
    local qs = type(input.questions) == "table" and input.questions or {}
    local q1 = type(qs[1]) == "table" and qs[1].question or nil
    if type(q1) ~= "string" or not q1:find("%S") then return nil end
    local s = head(q1, 120)
    if #qs > 1 then s = s .. require("agentmap.i18n").t("providers.more_questions", { n = #qs - 1 }) end
    return s
  end
  return nil
end

M._tool_target = tool_target

-- tool_result の中身を文字列に
local function result_text(c)
  if type(c) == "string" then return c end
  if type(c) == "table" then
    local parts = {}
    for _, b in ipairs(c) do
      if type(b) == "table" and b.type == "text" and type(b.text) == "string" then parts[#parts + 1] = b.text end
    end
    return table.concat(parts, "\n")
  end
  return ""
end

-- user 行の本文（文字列 or text ブロック）。tool_result だけの行なら nil
local function user_text(msg)
  local c = msg and msg.content
  if type(c) == "string" then return c end
  if type(c) == "table" then
    local parts = {}
    for _, b in ipairs(c) do
      if type(b) == "table" then
        if b.type == "tool_result" then return nil end
        if b.type == "text" and type(b.text) == "string" then parts[#parts + 1] = b.text end
      end
    end
    if #parts > 0 then return table.concat(parts, "\n") end
  end
  return nil
end

--- Agent 自身の transcript の最初の依頼文の全文（先頭の 20 行までしか見ない）。無ければ nil
local function first_prompt(path)
  if type(path) ~= "string" then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local n, out = 0, nil
  for line in f:lines() do
    n = n + 1
    if n > 20 then break end
    if line:find('"type":"user"', 1, true) then
      local t = decode(line)
      if t and t.type == "user" and not t.isMeta then
        local txt = user_text(t.message)
        if txt then
          out = txt
          break
        end
      end
    end
  end
  f:close()
  return out
end

--- First line of the first prompt in an agent's own transcript.
--- Agent 自身の transcript の最初の依頼文の 1 行目
function M.first_prompt_line(path)
  local txt = first_prompt(path)
  return txt and M.prompt_line(txt) or nil
end

--- Convention fields ([Goal] etc.) of the first prompt in an agent's own transcript, or nil.
--- Agent 自身の transcript の最初の依頼文から【目的】【任せる理由】【期待する結果】を読む。1 つも無ければ nil
---   親の transcript が読めないとき（Workflow の Agent など）の予備。親の transcript にある prompt と同じ文
function M.first_prompt_brief(path)
  return brief.parse_brief(first_prompt(path))
end

--- 1 つの transcript（親でも子でも）を読んで、整えた記録を作る
--- @param path string
--- @param agent_id string "ROOT" か agentId
--- @param sid string session_id
--- @param out table 記録を足していく配列
--- @return table info { first_ts, last_ts, cwd, model, branch, last_text, prompt }
local function scan_transcript(path, agent_id, sid, out)
  local info = {}
  local f = io.open(path, "rb")
  if not f then return info end
  local pending = {} -- tool_use_id → Agent 呼び出しの input
  local wfcall = {} -- tool_use_id → Workflow 呼び出しの input
  local asks = {} -- tool_use_id → AskUserQuestion 呼び出しの input
  local tcreate, tlist, task_ord = {}, {}, 0 -- 手順表：TaskCreate 呼び出し（結果の id を待つ）・TaskList 呼び出し
  local cur -- 今読んでいる返事 { id = message.id, text = その返事の最後の text }（親の直前の発言を取るため）
  local function add(event, ts, fields) out[#out + 1] = mk(event, ts, sid, "transcript", fields) end

  for line in f:lines() do
    local is_a = line:find('"type":"assistant"', 1, true)
    local is_u = line:find('"type":"user"', 1, true)
    if is_a or is_u or not info.first_ts then
      local t = decode(line)
      if t then
        local ts = t.timestamp
        if ts then
          info.first_ts = info.first_ts or ts
          info.last_ts = ts
        end
        info.cwd = info.cwd or t.cwd
        if t.gitBranch and t.gitBranch ~= "" then info.branch = t.gitBranch end
        local msg = t.message
        if t.type == "assistant" and type(msg) == "table" then
          if type(msg.model) == "string" and msg.model ~= "<synthetic>" then info.model = msg.model end
          local mid = type(msg.id) == "string" and msg.id or nil
          if not cur or cur.id ~= mid then cur = { id = mid } end
          for _, b in ipairs(type(msg.content) == "table" and msg.content or {}) do
            if type(b) == "table" then
              if b.type == "text" and type(b.text) == "string" and b.text:find("%S") then
                info.last_text = b.text
                cur.text = one_line(b.text, LEAD)
              elseif b.type == "tool_use" then
                local input = b.input or {}
                if b.name == "Agent" or b.name == "Task" then
                  pending[b.id] = { input = input, lead = cur.text }
                  add("agent_spawn_requested", ts, {
                    tool_use_id = b.id, parent_id = agent_id, task = input.description,
                    agent_type = input.subagent_type, model_requested = input.model,
                    isolation = input.isolation, prompt_head = head(input.prompt),
                    -- 同じ 1 通の返事（message.id）で起動された Agent は同じ段にする
                    batch = mid,
                    brief = brief.parse_brief(input.prompt), lead = cur.text,
                  })
                elseif b.name == "AskUserQuestion" then
                  asks[b.id] = input
                  add("check_asked", ts, {
                    tool_use_id = b.id, asker_id = agent_id, questions = M.norm_questions(input.questions),
                    lead = cur.text,
                  })
                elseif b.name == "Workflow" then
                  wfcall[b.id] = input
                elseif b.name == "TaskCreate" then
                  -- id は結果（toolUseResult.task.id）から。無ければこの transcript 内で出た順に仮に振る
                  task_ord = task_ord + 1
                  tcreate[b.id] = { input = input, ts = ts, ord = task_ord }
                elseif b.name == "TaskUpdate" then
                  if input.taskId ~= nil and type(input.status) == "string" then
                    add("task_updated", ts, { agent_id = agent_id, task_id = tostring(input.taskId), status_to = input.status })
                  end
                elseif b.name == "TaskList" then
                  tlist[b.id] = true
                elseif WRITE_TOOLS[b.name] or b.name == "Bash" then
                  add("tool_used", ts, {
                    agent_id = agent_id, tool_name = b.name, target = tool_target(b.name, input),
                    tool_use_id = b.id, cwd = t.cwd,
                  })
                end
              end
            end
          end
        elseif t.type == "user" and type(msg) == "table" then
          if not info.prompt and not t.isMeta then
            local txt = user_text(msg)
            if txt and not txt:match("^%s*<task%-notification>") and not txt:match("^%s*<command%-") then
              info.prompt = txt
              info.prompt_ts = ts
            end
          end
          -- Agent 呼び出しの結果：返ってきた agentId の親は、この transcript の持ち主
          if type(msg.content) == "table" then
            for _, b in ipairs(msg.content) do
              if type(b) == "table" and b.type == "tool_result" and wfcall[b.tool_use_id] then
                -- Workflow の起動結果：runId が Workflow の id。親はこの transcript の持ち主
                local input = wfcall[b.tool_use_id]
                local tur = type(t.toolUseResult) == "table" and t.toolUseResult or {}
                if type(tur.runId) == "string" then
                  add("workflow_started", ts, {
                    wf_id = tur.runId, parent_id = agent_id, tool_use_id = b.tool_use_id,
                    name = tur.workflowName, task = input.description or head(tur.summary, 120),
                    summary = head(tur.summary, 120), resume_of = input.resumeFromRunId,
                  })
                end
                wfcall[b.tool_use_id] = nil
              elseif type(b) == "table" and b.type == "tool_result" and asks[b.tool_use_id] then
                -- AskUserQuestion の結果：toolUseResult = { questions, answers, annotations }
                local tur = type(t.toolUseResult) == "table" and t.toolUseResult or {}
                if type(tur.answers) == "table" then
                  local qs = M.norm_questions(tur.questions)
                  add("check_answered", ts, {
                    tool_use_id = b.tool_use_id, asker_id = agent_id, answers = norm_answers(tur.answers),
                    questions = #qs > 0 and qs or nil,
                  })
                elseif b.is_error then
                  add("check_abandoned", ts, { tool_use_id = b.tool_use_id, reason = head(result_text(b.content)) })
                end
                asks[b.tool_use_id] = nil
              elseif type(b) == "table" and b.type == "tool_result" and tcreate[b.tool_use_id] then
                local c = tcreate[b.tool_use_id]
                local tur = type(t.toolUseResult) == "table" and t.toolUseResult or {}
                local task = type(tur.task) == "table" and tur.task or {}
                if not b.is_error then
                  add("task_created", c.ts, {
                    agent_id = agent_id, task_id = tostring(task.id or c.ord),
                    subject = brief.clip(type(task.subject) == "string" and task.subject or c.input.subject, brief.LIMITS.step_text),
                    active_form = brief.clip(c.input.activeForm, brief.LIMITS.step_text),
                  })
                end
                tcreate[b.tool_use_id] = nil
              elseif type(b) == "table" and b.type == "tool_result" and tlist[b.tool_use_id] then
                local tur = type(t.toolUseResult) == "table" and t.toolUseResult or {}
                if type(tur.tasks) == "table" then
                  local tasks = {}
                  for _, x in ipairs(tur.tasks) do
                    if type(x) == "table" and x.id ~= nil then
                      tasks[#tasks + 1] = { id = tostring(x.id), subject = brief.clip(x.subject, brief.LIMITS.step_text), status = x.status }
                    end
                  end
                  add("task_listed", ts, { agent_id = agent_id, tasks = tasks })
                end
                tlist[b.tool_use_id] = nil
              elseif type(b) == "table" and b.type == "tool_result" and pending[b.tool_use_id] then
                local input = pending[b.tool_use_id].input
                local lead = pending[b.tool_use_id].lead
                local tur = type(t.toolUseResult) == "table" and t.toolUseResult or {}
                local aid = tur.agentId or result_text(b.content):match("agentId: (%w+)")
                if aid then
                  add("agent_linked", ts, {
                    agent_id = aid, parent_id = agent_id, source = "transcript",
                    tool_use_id = b.tool_use_id, model = tur.resolvedModel,
                    task = tur.description or input.description, agent_type = input.subagent_type,
                    prompt_head = head(input.prompt), is_async = tur.isAsync,
                    brief = brief.parse_brief(input.prompt), lead = lead,
                  })
                  local async = tur.status == "async_launched"
                      or (tur.status == nil and result_text(b.content):find("Async agent launched", 1, true))
                  if not async then
                    add("agent_finished", ts, { agent_id = aid, duration_ms = tur.totalDurationMs })
                  end
                elseif b.is_error then
                  add("agent_failed", ts, { tool_use_id = b.tool_use_id, error_head = head(result_text(b.content)) })
                end
                pending[b.tool_use_id] = nil
              end
            end
          end
        end
      end
    end
  end
  f:close()
  -- 結果の行が無いまま終わった TaskCreate（途中で切れた transcript）は、出た順の仮の id で作る
  local rest = {}
  for _, c in pairs(tcreate) do rest[#rest + 1] = c end
  table.sort(rest, function(x, y) return x.ord < y.ord end)
  for _, c in ipairs(rest) do
    add("task_created", c.ts, {
      agent_id = agent_id, task_id = tostring(c.ord),
      subject = brief.clip(c.input.subject, brief.LIMITS.step_text), active_form = brief.clip(c.input.activeForm, brief.LIMITS.step_text),
    })
  end
  return info
end

--- 手順の目印（## Steps）を transcript の全文に当てて、steps_updated を 1 件足す（無ければ足さない）
local function backfill_steps(path, agent_id, ts, add)
  local ok, idx = pcall(M.agent_steps, path, nil)
  local steps = ok and M.steps_of(idx) or nil
  if steps then add("steps_updated", ts, { agent_id = agent_id, steps = steps }) end
end

--- Rebuild a session without hooks from its transcript.
--- hooks が無い session を transcript から組み立てる
--- @return table[] 時刻順の整えた記録（src = "transcript"）
function M.backfill(session_id, slug)
  local out = {}
  local ok, err = pcall(function()
    local base = M.config_dir() .. "/projects/" .. slug
    local main = base .. "/" .. session_id .. ".jsonl"
    if not exists(main) then return end

    -- 親（ROOT）
    local tmp = {}
    local info = scan_transcript(main, "ROOT", session_id, tmp)
    local t0 = info.first_ts or util.iso_now()
    local function add(event, ts, fields) out[#out + 1] = mk(event, ts, session_id, "transcript", fields) end
    add("run_started", t0, { cwd = info.cwd, transcript_path = main, source = "transcript" })
    add("agent_started", t0, { agent_id = "ROOT", cwd = info.cwd })
    if info.prompt then add("run_prompt", info.prompt_ts or t0, { prompt_head = head(info.prompt) }) end
    vim.list_extend(out, tmp)
    local tl = info.last_ts or t0
    if info.model then add("agent_updated", tl, { agent_id = "ROOT", model = info.model }) end
    if info.branch then add("agent_updated", tl, { agent_id = "ROOT", branch = info.branch }) end
    if info.last_text then add("turn_ended", tl, { last_head = head(info.last_text) }) end
    backfill_steps(main, "ROOT", tl, add)

    -- 子・孫（subagents/**/agent-*.jsonl）
    local run_end = tl
    local files = vim.fn.glob(base .. "/" .. session_id .. "/subagents/**/agent-*.jsonl", false, true)
    for _, p in ipairs(files) do
      local id = p:match("agent%-([%w_%-]+)%.jsonl$")
      if id then
        local meta = util.json_decode(util.read_file(p:gsub("%.jsonl$", ".meta.json"))) or {}
        local sub = {}
        local si = scan_transcript(p, id, session_id, sub)
        local ts0 = si.first_ts or t0
        local wf = wf_of_path(p)
        add("agent_started", ts0, {
          agent_id = id, agent_type = meta.agentType, cwd = si.cwd,
          meta_tool_use_id = meta.toolUseId, meta_parent_id = meta_parent(meta),
          model = si.model or meta.model, wf_id = wf,
          task = meta.description or (wf and si.prompt and M.prompt_line(si.prompt)) or nil,
          phase = meta.workflowPhase,
        })
        vim.list_extend(out, sub)
        local tse = si.last_ts or ts0
        if si.model then add("agent_updated", tse, { agent_id = id, model = si.model }) end
        if si.branch then add("agent_updated", tse, { agent_id = id, branch = si.branch }) end
        backfill_steps(p, id, tse, add)
        add("agent_finished", tse, {
          agent_id = id, transcript_path = p, last_head = head(si.last_text),
          report = (M.agent_report(p)),
        })
        if (util.parse_iso(tse) or 0) > (util.parse_iso(run_end) or 0) then run_end = tse end
      end
    end
    add("run_ended", run_end, { reason = "transcript_end" })
  end)
  if not ok then
    vim.schedule(function()
      vim.notify("AgentMap: " .. require("agentmap.i18n").t("providers.transcript_read_failed", { err = tostring(err) }), vim.log.levels.WARN)
    end)
  end
  -- 時刻順（同じ時刻なら作った順）
  for i, ev in ipairs(out) do ev._o = i end
  table.sort(out, function(a, b)
    local ta, tb = util.parse_iso(a.ts) or 0, util.parse_iso(b.ts) or 0
    if ta ~= tb then return ta < tb end
    return a._o < b._o
  end)
  for _, ev in ipairs(out) do ev._o = nil end
  return out
end

-- ============================================================
-- 4) transcript 画面用
-- ============================================================

local SKIP = {
  attachment = true, ["queue-operation"] = true, ["atis-latch"] = true,
  ["last-prompt"] = true, ["cost-state"] = true, system = true,
}

--- Transcript entries for the transcript view.
--- transcript を画面表示用の一覧にする
--- @return table[] { {kind="user"|"assistant"|"tool_use"|"tool_result"|"thinking"|"notice", ts, model, text, tool, target} }
function M.transcript_entries(path, opts)
  opts = opts or {}
  local max_bytes = opts.max_bytes or (config.get().transcript or {}).max_bytes or 5e6
  local out = {}
  local f = type(path) == "string" and io.open(path, "rb")
  if not f then return out end
  local size = f:seek("end") or 0
  local data
  if size > max_bytes then
    f:seek("set", size - max_bytes)
    data = f:read("*a") or ""
    data = data:gsub("^[^\n]*\n", "") -- 途中から始まる 1 行目は捨てる
    out[#out + 1] = {
      kind = "notice",
      text = require("agentmap.i18n").t("providers.tail_only", { mb = math.floor(max_bytes / 1e6) }),
    }
  else
    f:seek("set", 0)
    data = f:read("*a") or ""
  end
  f:close()

  for line in data:gmatch("[^\n]+") do
    local t = decode(line)
    if t and not SKIP[t.type] and type(t.message) == "table" then
      local ts, msg = t.timestamp, t.message
      if t.type == "user" then
        if type(msg.content) == "string" then
          out[#out + 1] = { kind = "user", ts = ts, text = msg.content }
        elseif type(msg.content) == "table" then
          for _, b in ipairs(msg.content) do
            if type(b) == "table" then
              if b.type == "tool_result" then
                out[#out + 1] = { kind = "tool_result", ts = ts, text = result_text(b.content), tool = b.tool_use_id }
              elseif b.type == "text" then
                out[#out + 1] = { kind = "user", ts = ts, text = b.text }
              end
            end
          end
        end
      elseif t.type == "assistant" and type(msg.content) == "table" then
        for _, b in ipairs(msg.content) do
          if type(b) == "table" then
            if b.type == "text" then
              out[#out + 1] = { kind = "assistant", ts = ts, model = msg.model, text = b.text }
            elseif b.type == "thinking" or b.type == "redacted_thinking" then
              out[#out + 1] = { kind = "thinking", ts = ts, model = msg.model, text = b.thinking or "" }
            elseif b.type == "tool_use" then
              out[#out + 1] = {
                kind = "tool_use", ts = ts, model = msg.model, tool = b.name,
                target = tool_target(b.name, b.input), text = tool_target(b.name, b.input) or "",
              }
            end
          end
        end
      end
    end
  end
  return out
end

return M
