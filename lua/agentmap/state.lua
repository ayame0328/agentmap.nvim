-- ============================================================
--  agentmap/state.lua ... folds the records into the current state (pure; no files, no screens).
--
--  ファイルも画面も触らない「計算だけ」の部品。
--    reduce(events)  … 記録の全部から状態を作る
--    apply(s, ev)    … 1 件ずつ足す（画面の自動更新で使う）
--
--  状態の名前：PENDING（依頼だけ出た）/ RUNNING / REVIEW / DONE / REWORK（差し戻し）/ FAILED
--  親が分からない Agent は parent_id = nil のまま（推測で埋めない）。
--  進み具合（~NN%）は「子の完了数 / 子の数」だけ。文章からは読まない。
-- ============================================================
local util = require("agentmap.util")
local brief = require("agentmap.brief")

local M = {}

M.SV = 8 -- 状態の形の版（控え state.json の作り直しの判断に使う）。8 で HUMAN CHECK・任せた理由・報告が増えた

M.STATUSES = { "PENDING", "RUNNING", "REVIEW", "DONE", "REWORK", "FAILED" }
-- HUMAN CHECK（AskUserQuestion）の状態。Agent の状態とは別の箱で持つ（Agent の STATUSES は変えない）
--   WAITING = 質問を出して答え待ち / ANSWERED = 答えが出た / ABANDONED = 答えが無いまま終わった
M.CHECK_STATUSES = { "WAITING", "ANSWERED", "ABANDONED" }
local LINK_GRACE = 1.0 -- 子の終了と質問の時刻の比べに許すずれ（秒）。hooks の到着順のずれ（ACTIVITY_GRACE と同じ考え）
local CLOSED = { DONE = true, REWORK = true, FAILED = true }
local ACTIVE = { PENDING = true, RUNNING = true, REVIEW = true }
local WRITE_TOOLS = { Write = true, Edit = true, MultiEdit = true, NotebookEdit = true }
local TOOLS_MAX = 500
local ACTIVITY_GRACE = 1.0 -- 完了直後 1 秒以内のツール記録は「やり直し」と見なさない（hook の到着順のずれ）

-- ---------- 作る ----------

local function new_agent(id, index, status)
  return {
    id = id, index = index, status = status or "PENDING",
    children = {}, attempts = {}, attempt = 0,
    review_count = 0, rework_count = 0,
    tools = {}, tool_counts = {}, files = {},
  }
end

--- Empty state.
--- 空の状態
function M.new(run_id)
  local s = {
    v = 1, run_id = run_id,
    agents = {}, order = {}, next_index = 1,
    spawn_requests = {}, by_tool_use = {},
    counts = {}, last_seq = 0,
    -- 指示（ユーザーの 1 回の入力）ごとの「流れ」。Agent は a.prompt_id でどれかの流れに属する
    sv = M.SV, flows = {}, prompt_alias = {},
    -- HUMAN CHECK（人への確認）。id = "check:<tool_use_id>"。check_order は出てきた順
    checks = {}, check_order = {},
  }
  s.agents.ROOT = new_agent("ROOT", 0, "PENDING")
  s.order[1] = "ROOT"
  return s
end

-- ---------- 内部の道具 ----------

local function remove_value(list, v)
  for i = #list, 1, -1 do
    if list[i] == v then table.remove(list, i) end
  end
end

local function contains(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

local function get(s, id) return s.agents[id] end
local H = {}

--- Workflow のまとめ役の箱（id = "wf:<wf_id>"）。本物の Agent ではないので番号は振らない
local function get_or_create_workflow(s, id)
  local a = s.agents[id]
  if a then return a, false end
  a = new_agent(id, nil, "RUNNING")
  a.kind = "workflow"
  a.wf_id = id:sub(4)
  a.name = "Workflow " .. a.wf_id:gsub("^wf_", ""):sub(1, 8)
  s.agents[id] = a
  s.order[#s.order + 1] = id
  return a, true
end

--- 無ければ作る（番号は出てきた順）
local function get_or_create(s, id, status)
  local a = s.agents[id]
  if a then return a, false end
  if type(id) == "string" and id:sub(1, 3) == "wf:" then return get_or_create_workflow(s, id) end
  -- 仮の箱に取り込まれて空いた番号があれば、その一番小さいものを使う（番号に穴を作らない）
  local idx
  if type(s.free_index) == "table" and #s.free_index > 0 then
    table.sort(s.free_index)
    idx = table.remove(s.free_index, 1)
  else
    idx = s.next_index
    s.next_index = s.next_index + 1
  end
  a = new_agent(id, idx, status)
  s.agents[id] = a
  s.order[#s.order + 1] = id
  return a, true
end

local set_parent
set_parent = function(s, a, parent_id, source)
  if not parent_id or parent_id == a.id then return end
  if a.parent_id == parent_id then
    a.link_source = a.link_source or source
    return
  end
  if a.parent_id and s.agents[a.parent_id] then
    remove_value(s.agents[a.parent_id].children, a.id)
  end
  a.parent_id = parent_id
  a.link_source = source
  local p = get_or_create(s, parent_id, "PENDING")
  if not contains(p.children, a.id) then p.children[#p.children + 1] = a.id end
  -- 指示の分からない子は、親と同じ流れに入れる（親から子へだけ。逆はしない）
  if not a.prompt_id and p.prompt_id and a.id ~= "ROOT" then a.prompt_id = p.prompt_id end
  -- Workflow のまとめ役だけは、最初の子の流れに入る（子 → 親の受け継ぎはここだけ）
  if p.kind == "workflow" and not p.prompt_id and a.prompt_id then p.prompt_id = a.prompt_id end
  -- Workflow を呼んだ Agent が分からないときは ROOT の下（あとで workflow_started が来れば付け替わる）
  if p.kind == "workflow" and not p.parent_id then set_parent(s, p, "ROOT", "default") end
end

--- Workflow の Agent を、その Workflow のまとめ役の下に付ける
---   親がまだ分からないか、meta.json の spawnDepth だけで ROOT にしていたときだけ付け替える
local function link_workflow(s, a, ev)
  if not ev.wf_id or not a or a.id == "ROOT" or a.kind == "workflow" then return end
  if a.wf_id == nil then a.wf_id = ev.wf_id end
  local wid = "wf:" .. ev.wf_id
  if not a.parent_id or (a.parent_id == "ROOT" and a.link_source == "meta_depth") then
    set_parent(s, a, wid, "workflow")
  end
end

local function fill(a, k, v)
  if a[k] == nil and v ~= nil then a[k] = v end
end

local function cur_attempt(a)
  return a.attempts[a.attempt]
end

local function open_attempt(a, ts, extra)
  local n = #a.attempts + 1
  local at = { n = n, started_at = ts }
  for k, v in pairs(extra or {}) do at[k] = v end
  a.attempts[n] = at
  a.attempt = n
  return at
end

local function secs(ts) return util.parse_iso(ts) end

local function elapsed(from, to)
  local a, b = secs(from), secs(to)
  if a and b and b >= a then return math.floor((b - a) * 1000 + 0.5) end
  return nil
end

--- 依頼だけ出ていた仮の箱（pending:<tool_use_id>）を、本物の Agent に取り込む
local function adopt(s, id, tuid, status_if_new)
  local req = tuid and s.spawn_requests[tuid]
  local ph_id = req and req.placeholder_id
  local ph = ph_id and s.agents[ph_id]
  local a = s.agents[id]
  if ph and ph ~= a then
    if not a then
      -- 仮の箱をそのまま本物に付け替える（番号・並び順・親子をそのまま引き継ぐ）
      s.agents[ph_id] = nil
      ph.id = id
      ph.placeholder = nil
      s.agents[id] = ph
      for i, x in ipairs(s.order) do if x == ph_id then s.order[i] = id end end
      if ph.parent_id and s.agents[ph.parent_id] then
        local ch = s.agents[ph.parent_id].children
        for i, x in ipairs(ch) do if x == ph_id then ch[i] = id end end
      end
      a = ph
    else
      -- 両方あるとき：仮の箱の番号と中身を引き継いで、仮の箱は消す
      for _, k in ipairs({ "name", "task", "agent_type", "model_requested", "isolation", "prompt_head", "prompt_id",
        "brief", "brief_src", "lead" }) do
        fill(a, k, ph[k])
      end
      -- 本物が先に取った番号は返す（SubagentStart → PostToolUse の順で必ずここを通るため、
      -- 返さないと [1] [3] [5] … と番号が飛んで数字キーの半分が使えなくなる）
      if a.index and a.index ~= ph.index then
        s.free_index = s.free_index or {}
        s.free_index[#s.free_index + 1] = a.index
      end
      a.index = ph.index
      if ph.parent_id and s.agents[ph.parent_id] then remove_value(s.agents[ph.parent_id].children, ph_id) end
      local pos
      for i, x in ipairs(s.order) do if x == ph_id then pos = i end end
      remove_value(s.order, id)
      if pos then
        for i, x in ipairs(s.order) do if x == ph_id then s.order[i] = id end end
      else
        s.order[#s.order + 1] = id
      end
      s.agents[ph_id] = nil
      if not a.parent_id and ph.parent_id then set_parent(s, a, ph.parent_id, "spawn_request") end
    end
    req.placeholder_id = nil
    req.agent_id = id
  end
  if not a then a = get_or_create(s, id, status_if_new) end
  local ph = s.phantoms and s.phantoms[id]
  if ph then s.phantoms[id] = nil; H.agent_finished(s, ph) end
  if tuid then
    a.tool_use_id = a.tool_use_id or tuid
    s.by_tool_use[tuid] = id
    if req then fill(a, "batch", req.batch) end
  end
  return a
end

-- ---------- 指示ごとの流れ ----------

local function flow_of(s, id)
  if not id or type(s.flows) ~= "table" then return nil end
  for _, f in ipairs(s.flows) do
    if f.id == id then return f end
  end
  return nil
end
M.flow_of = flow_of

--- お知らせ（task_notification）の prompt_id は、続きになる本物の指示の id に読み替える
local function resolve_pid(s, pid)
  return (s.prompt_alias and s.prompt_alias[pid]) or pid
end

--- 始まった順に並べ直して、番号（n）を振り直す
local function sort_flows(s)
  local key = {}
  for _, f in ipairs(s.flows) do key[f] = secs(f.started_at) or 0 end
  table.sort(s.flows, function(a, b)
    local ta, tb = key[a], key[b]
    if ta ~= tb then return ta < tb end
    return (a.seq or 0) < (b.seq or 0)
  end)
  for i, f in ipairs(s.flows) do f.n = i end
end

--- 流れを探す。無ければ作る（指示の記録より Agent の記録が先に来たときは、本文なしの入れ物だけ作る）
local function ensure_flow(s, pid, ts, head)
  if not pid then return nil end
  s.flows = s.flows or {}
  s.prompt_alias = s.prompt_alias or {}
  pid = resolve_pid(s, pid)
  local f = flow_of(s, pid)
  local moved = false
  if not f then
    s.flow_seq = (s.flow_seq or 0) + 1
    f = { id = pid, started_at = ts, seq = s.flow_seq, agents = 0, status = "RUNNING" }
    s.flows[#s.flows + 1] = f
    moved = true
  end
  fill(f, "prompt_head", head)
  if ts and ts ~= f.started_at then
    local a, b = secs(f.started_at), secs(ts)
    if b and (not a or b < a) then f.started_at = ts; moved = true end
  end
  -- 並べ直すのは、流れが増えたか開始時刻が早まったときだけ（ツールの記録ごとには並べ直さない）
  if moved then sort_flows(s) end
  return f
end

--- Agent をその記録の指示の流れに入れる（最初に決まった流れは変えない）
local function tag(s, a, pid, ts)
  if not a or a.id == "ROOT" or not pid then return end
  pid = resolve_pid(s, pid)
  if a.prompt_id == nil then a.prompt_id = pid end
  if a.prompt_id == pid then ensure_flow(s, pid, ts) end
end

--- 再実行（新しい回を始める）
local function start_rework(s, a, ts, retry_of, trigger)
  local at = open_attempt(a, ts, { retry_of = retry_of, trigger = trigger })
  a.status = "RUNNING"
  a.finished_at = nil
  if retry_of and retry_of ~= a.id and s.agents[retry_of] then
    local old = s.agents[retry_of]
    local last = old.attempts[#old.attempts]
    if not last then last = open_attempt(old, nil) end
    last.retried_by = a.id
    a.retry_of = a.retry_of or retry_of
  end
  return at
end

-- ---------- 任せた理由・報告・HUMAN CHECK の道具 ----------

--- 記録の出どころ → brief_src / report_src の値（hooks で取れたか、transcript から読んだか）
local function src_of(ev)
  return ev.src == "hook" and "hook" or "transcript"
end

--- 任せた理由（【目的】など）と親の直前の発言を、空欄だけ埋める
local function fill_brief(a, ev)
  if a.brief == nil and type(ev.brief) == "table" and next(ev.brief) ~= nil then
    a.brief = ev.brief
    a.brief_src = src_of(ev)
  end
  fill(a, "lead", ev.lead)
end

--- 文字数（バイトではなく文字。UTF-8 の続きのバイトは数えない）
local function nchars(str)
  if type(str) ~= "string" then return 0 end
  local _, n = str:gsub("[^\128-\191]", "")
  return n
end

local function check_secs(c) return secs(c.asked_at or c.answered_at) end

--- check を付ける箱（owner）を決める。前の owner の一覧から外して、新しい owner の a.checks に足す
local function set_owner(s, c, owner_id)
  if not owner_id then return end
  if c.owner_id and c.owner_id ~= owner_id and s.agents[c.owner_id] then
    remove_value(s.agents[c.owner_id].checks or {}, c.id)
  end
  c.owner_id = owner_id
  local o = s.agents[owner_id]
  if not o then o = get_or_create(s, owner_id, "RUNNING") end
  o.checks = o.checks or {}
  if not contains(o.checks, c.id) then o.checks[#o.checks + 1] = c.id end
end

--- check と、要確認を書いた子を結びつける
local function bind(s, c, a, source)
  c.agent_id = a.id
  c.link_source = source
  a.ask_check = c.id
  set_owner(s, c, a.id)
end

--- 同じ流れか（どちらかが分からなければ同じとみなす）
local function same_flow(p1, p2)
  return p1 == nil or p2 == nil or p1 == p2
end

--- 後の方を選ぶ（finished_at が遅い方。同時刻なら番号の大きい方）
local function later(x, y)
  if not x then return true end
  local tx, ty = secs(x.finished_at) or 0, secs(y.finished_at) or 0
  if ty ~= tx then return ty > tx end
  return (y.index or 0) > (x.index or 0)
end

--- 質問（check）を、聞いた側の直接の子のうち「要確認を書いて止まった子」に結びつける（設計書 §3.5）
--   規則 1（名前）：子の名前が質問の header か question にそのまま入っている
--   規則 2（報告）：名前が無ければ、報告に「## 要確認」がある子のうち最後に終わったもの
--   どちらも無ければ結びつけない（聞いた側が直接聞いた質問）
local function link_check(s, c)
  if c.agent_id then return end
  local t = check_secs(c)
  local cands = {}
  for _, id in ipairs(s.order) do
    local a = s.agents[id]
    if a and id ~= "ROOT" and a.kind ~= "workflow" and not a.placeholder
        and a.parent_id == c.asker_id and same_flow(c.prompt_id, a.prompt_id) and a.ask_check == nil then
      local f = secs(a.finished_at)
      if f and t and f <= t + LINK_GRACE then cands[#cands + 1] = a end
    end
  end
  if #cands == 0 then return end
  local best
  for _, a in ipairs(cands) do
    local hit = false
    for _, nm in ipairs({ a.name, a.task }) do
      if type(nm) == "string" and nchars(nm) >= 3 then
        for _, q in ipairs(c.questions or {}) do
          if (type(q.header) == "string" and q.header:find(nm, 1, true))
              or (type(q.question) == "string" and q.question:find(nm, 1, true)) then
            hit = true
          end
        end
      end
    end
    if hit and later(best, a) then best = a end
  end
  if best then return bind(s, c, best, "name") end
  for _, a in ipairs(cands) do
    if a.ask ~= nil and later(best, a) then best = a end
  end
  if best then return bind(s, c, best, "report") end
end

--- 報告が質問より後に届いたとき：その子の要確認を、まだどの子とも結びついていない質問に後から結びつける
--   候補：聞いた側が親・同じ流れ・子の終了（の 1 秒前）以降に聞いた質問。いちばん早く聞いたもの 1 つ
local function link_agent(s, a)
  if a.ask_check or not a.parent_id then return end
  local f = secs(a.finished_at)
  if not f then return end
  local best, bt
  for _, cid in ipairs(s.check_order or {}) do
    local c = s.checks[cid]
    local t = c and check_secs(c)
    if c and c.agent_id == nil and c.asker_id == a.parent_id and same_flow(c.prompt_id, a.prompt_id)
        and t and t >= f - LINK_GRACE and (not bt or t < bt) then
      best, bt = c, t
    end
  end
  if best then bind(s, best, a, "report_late") end
end

--- 報告の原文から 4 項目（## 報告）か要確認（## 要確認）を作り直す。表示側で再パースしないため state で持つ
local function set_report(s, a)
  local r = brief.parse_report(a.report)
  a.report_fields, a.ask = nil, nil
  if r.kind == "report" then
    a.report_fields = { done = r.done, direction = r.direction, reason = r.reason, issues = r.issues }
  elseif r.kind == "ask" then
    a.ask = { working = r.working, stuck = r.stuck, want = r.want, options = r.options or {}, raw = a.report }
  end
  if a.ask and a.ask_check == nil then link_agent(s, a) end
end

--- 報告を入れる。hooks の報告は新しいもので上書き（差し戻し後にもう一度終わったとき、最新の報告を出すため）、
--   transcript から後で読んだ分は空欄のときだけ埋める
local function put_report(s, a, ev)
  local rep = ev.report
  if type(rep) ~= "string" or rep == "" then return end
  if a.report == rep then return end
  if a.report == nil or ev.src == "hook" then
    -- 差し戻しの後にもう一度終わった（前に結びついた質問より後に終わっている）なら、前の結びつけを外す。
    --   こうしないと新しい「## 要確認」が新しい質問と結びつかず、質問が ROOT の直接の箱になる。
    --   前の check はそのまま残す（c.agent_id・a.checks は変えない）
    local prev = a.ask_check and s.checks and s.checks[a.ask_check]
    if prev then
      local f, t = secs(a.finished_at), check_secs(prev)
      if f and t and f > t then a.ask_check = nil end
    end
    a.report = rep
    a.report_src = ev.report_src or src_of(ev)
    set_report(s, a)
  end
end

local function get_check(s, tuid)
  s.checks = s.checks or {}
  s.check_order = s.check_order or {}
  local cid = "check:" .. tuid
  local c = s.checks[cid]
  if not c then
    c = { id = cid, tool_use_id = tuid, status = "WAITING" }
    s.checks[cid] = c
    s.check_order[#s.check_order + 1] = cid
  end
  return c
end

--- 質問の記録（asked / answered 共通）：空欄を埋め、箱を付ける場所を決め、子と結びつける
local function check_common(s, c, ev)
  local asker = ev.asker_id or "ROOT"
  fill(c, "asker_id", asker)
  if c.prompt_id == nil and ev.prompt_id then
    c.prompt_id = resolve_pid(s, ev.prompt_id)
    ensure_flow(s, c.prompt_id, ev.ts)
  end
  if (c.questions == nil or #c.questions == 0) and type(ev.questions) == "table" and #ev.questions > 0 then
    c.questions = ev.questions
  end
  fill(c, "lead", ev.lead)
  if not c.owner_id then set_owner(s, c, c.asker_id) end
  link_check(s, c)
end

--- 答えが無いまま終わった印を付ける（答え待ちのものだけ）
local function abandon(c, ts, reason)
  if c.status ~= "WAITING" then return end
  c.status = "ABANDONED"
  c.ended_at = ts
  c.end_reason = reason
end

local function abandon_where(s, ts, reason, pred)
  for _, cid in ipairs(s.check_order or {}) do
    local c = s.checks[cid]
    if c and c.status == "WAITING" and pred(c) then abandon(c, ts, reason) end
  end
end

-- ---------- 記録ごとの処理 ----------

function H.run_started(s, ev)
  s.cwd = s.cwd or ev.cwd
  s.root_transcript = s.root_transcript or ev.transcript_path
  s.started_at = s.started_at or ev.ts
  s.ended_at, s.end_reason = nil, nil
  fill(s.agents.ROOT, "transcript_path", ev.transcript_path)
end

--- 人の指示ではない入力（裏の Agent の終わりのお知らせ・Agent からの伝言 <agent-message>）
local function is_notice(ev)
  if ev.kind == "task_notification" then return true end
  local h = type(ev.prompt_head) == "string" and ev.prompt_head or ""
  return h:match("^%s*<agent%-message[%s>]") ~= nil
end

function H.run_prompt(s, ev)
  if is_notice(ev) then
    -- 裏で動いた Agent の終わりのお知らせ・伝言：新しい流れは作らず、直前の本物の指示の続きとして扱う
    s.flows = s.flows or {}
    s.prompt_alias = s.prompt_alias or {}
    local same = flow_of(s, ev.prompt_id)
    if same and same.prompted then
      -- 指示の番の途中に差し込まれたお知らせ（prompt_id が今の指示と同じ）：その流れのまま
      return
    end
    local shell
    for i = #s.flows, 1, -1 do
      if s.flows[i].id == ev.prompt_id then shell = table.remove(s.flows, i) end
    end
    local last = s.flows[#s.flows]
    if ev.prompt_id and last and not s.prompt_alias[ev.prompt_id] then
      -- 先に Agent の記録から入れ物が作られていたら、その Agent も直前の指示の流れへ移す
      s.prompt_alias[ev.prompt_id] = last.id
      for _, id in ipairs(s.order) do
        local a = s.agents[id]
        if a and a.prompt_id == ev.prompt_id then a.prompt_id = last.id end
      end
      -- HUMAN CHECK も同じ（お知らせより先に質問の記録が届くと、消えた入れ物の流れを指したままになり図から消える）
      for _, cid in ipairs(s.check_order or {}) do
        local c = s.checks and s.checks[cid]
        if c and c.prompt_id == ev.prompt_id then
          c.prompt_id = last.id
          link_check(s, c) -- 流れが分かったので、子の要確認との結びつけをやり直す
        end
      end
    elseif shell then
      s.flows[#s.flows + 1] = shell -- まとめる先が無い：そのまま残す
    end
    sort_flows(s)
    if ev.kind == "task_notification" then return end
    ev = { prompt_head = ev.prompt_head } -- 伝言は題名の扱いだけ今までどおり
  end
  if ev.prompt_id then
    -- 新しい指示が来た = それより前の指示の番は終わっている（Stop が届かなかったときの保険）
    for _, f in ipairs(s.flows or {}) do
      if f.id ~= ev.prompt_id and not f.ended_at then f.ended_at = ev.ts end
    end
    -- 前の指示の番で答えを待っていた質問は、答えないまま次の指示が来た
    local pid = resolve_pid(s, ev.prompt_id)
    abandon_where(s, ev.ts, "new_prompt", function(c) return c.prompt_id ~= pid end)
    local f = ensure_flow(s, ev.prompt_id, ev.ts, ev.prompt_head)
    if f then f.prompted = true end -- 本物の指示の記録から作られた流れ（入れ物ではない）
  end
  s.cwd = s.cwd or ev.cwd
  s.title = s.title or ev.prompt_head
  fill(s.agents.ROOT, "prompt_head", ev.prompt_head)
  fill(s.agents.ROOT, "task", ev.prompt_head)
end

function H.agent_spawn_requested(s, ev)
  local tuid = ev.tool_use_id
  if not tuid or s.spawn_requests[tuid] then return end
  local req = {
    parent_id = ev.parent_id, task = ev.task, agent_type = ev.agent_type,
    model_requested = ev.model_requested, isolation = ev.isolation, ts = ev.ts,
    batch = ev.batch, -- 親の同じ 1 通の返事で起動された印（message.id）。段分けで使う
    brief = ev.brief, lead = ev.lead,
  }
  s.spawn_requests[tuid] = req
  local known = s.by_tool_use[tuid]
  if known and s.agents[known] then
    -- 本物の Agent が先に見えていた（順番の入れ替わり）
    local a = s.agents[known]
    req.agent_id = known
    tag(s, a, ev.prompt_id, ev.ts)
    if not a.parent_id then set_parent(s, a, ev.parent_id, "spawn_request") end
    for _, k in ipairs({ "task", "agent_type", "model_requested", "isolation", "prompt_head", "batch" }) do
      fill(a, k, ev[k])
    end
    fill(a, "name", ev.task)
    fill_brief(a, ev)
    return
  end
  local ph_id = "pending:" .. tuid
  local a = get_or_create(s, ph_id, "PENDING")
  a.placeholder = true
  a.tool_use_id = tuid
  a.name, a.task, a.agent_type = ev.task, ev.task, ev.agent_type
  a.model_requested, a.isolation, a.prompt_head = ev.model_requested, ev.isolation, ev.prompt_head
  a.requested_at = ev.ts
  a.batch = ev.batch
  fill_brief(a, ev)
  req.placeholder_id = ph_id
  tag(s, a, ev.prompt_id, ev.ts)
  set_parent(s, a, ev.parent_id, "spawn_request")
end

function H.agent_started(s, ev)
  local id = ev.agent_id
  if not id then return end
  local tuid = ev.meta_tool_use_id
  local a
  if id == "ROOT" then
    a = s.agents.ROOT
  else
    a = adopt(s, id, tuid, "PENDING")
    tag(s, a, ev.prompt_id, ev.ts)
    local req = tuid and s.spawn_requests[tuid]
    if req and req.parent_id then
      -- meta.json の toolUseId が依頼の記録と一致 = 正確なつながり
      if not a.parent_id then set_parent(s, a, req.parent_id, "meta") end
      if a.parent_id == req.parent_id and a.link_source == "spawn_request" then a.link_source = "meta" end
    elseif ev.meta_parent_id and ev.meta_parent_id ~= "ROOT" and not a.parent_id then
      set_parent(s, a, ev.meta_parent_id, "meta") -- parentAgentId（はっきり書かれた親）
    end
    link_workflow(s, a, ev)
    if ev.meta_parent_id == "ROOT" and not a.parent_id then
      set_parent(s, a, "ROOT", "meta_depth") -- spawnDepth == 1 だけから決めた親
    end
    fill(a, "task", ev.task)
    fill(a, "name", ev.task)
    fill(a, "phase", ev.phase)
  end
  fill(a, "agent_type", ev.agent_type)
  fill(a, "cwd", ev.cwd)
  fill(a, "model", ev.model)

  if CLOSED[a.status] and a.started_at then
    -- 一度終わった Agent がまた動き出した（再開・差し戻し後の再実行）
    start_rework(s, a, ev.ts, nil, "activity")
  elseif #a.attempts == 0 then
    open_attempt(a, ev.ts)
    a.status = "RUNNING"
  else
    -- 完了の記録が先に届いていた：1 回目の開始時刻を埋めるだけ
    local first = a.attempts[1]
    first.started_at = first.started_at or ev.ts
    if a.status == "PENDING" then a.status = "RUNNING" end
  end
  a.started_at = a.started_at or (a.attempts[1] and a.attempts[1].started_at) or ev.ts
  if a.finished_at and a.status ~= "RUNNING" then
    a.elapsed_ms = a.elapsed_ms or elapsed(a.started_at, a.finished_at)
  end
end

function H.agent_linked(s, ev)
  local id = ev.agent_id
  if not id or id == "ROOT" then return end
  local a = adopt(s, id, ev.tool_use_id, "PENDING")
  tag(s, a, ev.prompt_id, ev.ts) -- 親からの受け継ぎより、記録に書かれた指示を優先する
  if ev.parent_id then set_parent(s, a, ev.parent_id, ev.source or "post_tool_use") end
  link_workflow(s, a, ev)
  if ev.model then a.model = ev.model end -- 実際に使われたモデル（resolvedModel）を優先
  fill(a, "task", ev.task)
  fill(a, "name", ev.task)
  fill(a, "agent_type", ev.agent_type)
  fill(a, "prompt_head", ev.prompt_head)
  fill_brief(a, ev)
  if ev.is_async ~= nil then a.is_async = ev.is_async end
end

function H.agent_finished(s, ev)
  local id = ev.agent_id
  if not id then return end
  if not s.agents[id] and not ev.agent_type and not ev.wf_id then
    s.phantoms = s.phantoms or {}
    s.phantoms[id] = s.phantoms[id] or { event = "agent_finished", agent_id = id, ts = ev.ts, prompt_id = ev.prompt_id,
      transcript_path = ev.transcript_path, duration_ms = ev.duration_ms, report = ev.report, src = ev.src }
    return
  end
  local a, created = get_or_create(s, id, "DONE")
  tag(s, a, ev.prompt_id, ev.ts)
  link_workflow(s, a, ev)
  fill(a, "agent_type", ev.agent_type)
  local cur = cur_attempt(a)
  if created or not cur then
    cur = open_attempt(a, a.started_at)
    cur.finished_at = ev.ts
    cur.last_head = ev.last_head
    if a.status == "PENDING" or a.status == "RUNNING" then a.status = "DONE" end
    a.finished_at = ev.ts
  elseif cur.finished_at then
    if a.status == "REWORK" then
      -- 差し戻しのあと、途中の記録なしでまた完了した → 新しい回を開いてすぐ閉じる
      cur = open_attempt(a, ev.ts, { trigger = "activity" })
      cur.finished_at = ev.ts
      cur.last_head = ev.last_head
      a.status = "DONE"
      a.finished_at = ev.ts
      if ev.last_head then a.last_head = ev.last_head end
    elseif a.status == "FAILED" and a.error_head == "session ended" then
      -- 終了の記録が完了の記録より先に届いた（hooks は非同期なので順番が入れ替わることがある）
      cur.finished_at = ev.ts
      a.status = "DONE"
      a.error_head = nil
      a.finished_at = ev.ts
      if ev.last_head then a.last_head = ev.last_head end
    end
    -- それ以外（同期 Agent の二重の完了通知）は空欄を埋めるだけ
  else
    cur.finished_at = ev.ts
    cur.last_head = ev.last_head
    a.finished_at = ev.ts
    if a.status ~= "REVIEW" then a.status = "DONE" end
    if ev.last_head then a.last_head = ev.last_head end
  end
  fill(a, "transcript_path", ev.transcript_path)
  fill(a, "last_head", ev.last_head)
  fill(a, "duration_ms", ev.duration_ms)
  local st = a.started_at or (a.attempts[1] and a.attempts[1].started_at)
  a.elapsed_ms = elapsed(st, a.finished_at) or a.elapsed_ms or ev.duration_ms
  put_report(s, a, ev)
end

function H.agent_failed(s, ev)
  local a
  if ev.agent_id then
    a = get_or_create(s, ev.agent_id, "FAILED")
  elseif ev.tool_use_id then
    local id = s.by_tool_use[ev.tool_use_id]
        or (s.spawn_requests[ev.tool_use_id] and s.spawn_requests[ev.tool_use_id].placeholder_id)
    a = id and s.agents[id]
  end
  if not a then return end
  tag(s, a, ev.prompt_id, ev.ts)
  a.status = "FAILED"
  a.error_head = ev.error_head or a.error_head
  local cur = cur_attempt(a) or open_attempt(a, a.started_at)
  cur.finished_at = cur.finished_at or ev.ts
  a.finished_at = ev.ts
end

function H.tool_used(s, ev)
  local id = ev.agent_id or "ROOT"
  local a, created = get_or_create(s, id, "RUNNING")
  if created then open_attempt(a, ev.ts) end
  if id ~= "ROOT" then tag(s, a, ev.prompt_id, ev.ts) end
  if CLOSED[a.status] then
    local cur = cur_attempt(a)
    local fin = cur and secs(cur.finished_at)
    local t = secs(ev.ts)
    if not (fin and t and t <= fin + ACTIVITY_GRACE) then
      start_rework(s, a, ev.ts, nil, "activity")
    end
  elseif a.status == "PENDING" then
    a.status = "RUNNING"
    if #a.attempts == 0 then open_attempt(a, ev.ts) end
    a.started_at = a.started_at or ev.ts
  end
  local tools = a.tools
  tools[#tools + 1] = { ts = ev.ts, name = ev.tool_name, target = ev.target, duration_ms = ev.duration_ms }
  if #tools > TOOLS_MAX then table.remove(tools, 1) end
  a.tool_counts[ev.tool_name or "?"] = (a.tool_counts[ev.tool_name or "?"] or 0) + 1
  if WRITE_TOOLS[ev.tool_name] and ev.target and not contains(a.files, ev.target) then
    a.files[#a.files + 1] = ev.target
  end
  if ev.tool_name == "EnterWorktree" then a.entered_worktree = true end
  if ev.cwd and s.cwd and ev.cwd ~= s.cwd then
    a.cwd = ev.cwd
    -- フォルダが違うだけでは worktree と呼ばない（isolation の指定か EnterWorktree の記録があるときだけ）
    if a.isolation == "worktree" or a.entered_worktree then a.worktree = ev.cwd end
  end
end

function H.turn_ended(s, ev)
  if ev.last_head then s.agents.ROOT.last_head = ev.last_head end
  local f = ev.prompt_id and flow_of(s, resolve_pid(s, ev.prompt_id))
  if f then
    f.ended_at = ev.ts
    -- その指示の番の最後の返事（流れごとに持つ。セッション全体の最後の返事と混ぜない）
    if ev.last_head then f.last_head = ev.last_head end
  end
  -- 指示の番が終わった = その番で出した質問に答えは来ない（Esc で取り消したときなど）。
  -- 流れの分からない終わりの記録（transcript から組み立てたとき）なら、答え待ちを全部閉じる
  local pid = ev.prompt_id and resolve_pid(s, ev.prompt_id)
  abandon_where(s, ev.ts, "turn_ended", function(c) return pid == nil or c.prompt_id == nil or c.prompt_id == pid end)
end

function H.run_ended(s, ev)
  s.ended_at = ev.ts
  s.end_reason = ev.reason
  abandon_where(s, ev.ts, "session_ended", function() return true end)
  for _, f in ipairs(s.flows or {}) do f.ended_at = f.ended_at or ev.ts end
  for _, id in ipairs(s.order) do
    local a = s.agents[id]
    if a and id ~= "ROOT" and a.kind ~= "workflow" and (a.status == "PENDING" or a.status == "RUNNING") then
      a.status = "FAILED"
      a.error_head = a.placeholder and "no spawn record" or "session ended" -- 言語に依らない符号（表示で訳す）
      local cur = cur_attempt(a)
      if cur and not cur.finished_at then cur.finished_at = ev.ts end
      a.finished_at = a.finished_at or ev.ts
    end
  end
  local r = s.agents.ROOT
  if r.status ~= "FAILED" then
    r.status = "DONE"
    local cur = cur_attempt(r)
    if cur and not cur.finished_at then cur.finished_at = ev.ts end
    r.finished_at = ev.ts
    r.elapsed_ms = elapsed(r.started_at, ev.ts)
  end
end

function H.agent_updated(s, ev)
  local id = ev.agent_id
  if not id then return end
  local a = get_or_create(s, id, "PENDING")
  for _, k in ipairs({ "model", "cwd", "branch", "worktree", "transcript_path", "task", "phase", "batch" }) do
    fill(a, k, ev[k])
  end
  if ev.name and ev.name ~= "" then a.name = ev.name else fill(a, "name", ev.task) end
  if id == "ROOT" then s.root_transcript = s.root_transcript or ev.transcript_path end
  link_workflow(s, a, ev)
  fill_brief(a, ev)
  -- 後から transcript で読んだ報告は空欄のときだけ（hooks で同封された報告を上書きしない）
  if a.report == nil then put_report(s, a, ev) end
end

-- ---------- HUMAN CHECK（AskUserQuestion）----------

function H.check_asked(s, ev)
  if not ev.tool_use_id then return end
  local c = get_check(s, ev.tool_use_id)
  -- 記録が逆順で届いた（答えが先）ときは状態を変えず、空欄だけ埋める
  fill(c, "asked_at", ev.ts)
  check_common(s, c, ev)
end

function H.check_answered(s, ev)
  if not ev.tool_use_id then return end
  local c = get_check(s, ev.tool_use_id)
  c.answers = ev.answers
  c.answered_at = ev.ts
  -- 答え優先：先に「答えないまま終わった」にしていても、答えが届いたら答え済みにする
  c.status = "ANSWERED"
  c.ended_at, c.end_reason, c.error_head = nil, nil, nil
  check_common(s, c, ev)
end

function H.check_abandoned(s, ev)
  local c = ev.tool_use_id and s.checks and s.checks["check:" .. ev.tool_use_id]
  if not c or c.status ~= "WAITING" then return end
  abandon(c, ev.ts, "tool_failed")
  c.error_head = ev.reason
end

function H.check_updated(s, ev)
  local c = ev.tool_use_id and s.checks and s.checks["check:" .. ev.tool_use_id]
  if not c then return end
  fill(c, "lead", ev.lead)
end

--- Workflow ツールで Workflow が始まった（まとめ役の箱を作り、呼んだ側の下に付ける）
function H.workflow_started(s, ev)
  if not ev.wf_id then return end
  local w = get_or_create(s, "wf:" .. ev.wf_id)
  fill(w, "started_at", ev.ts)
  fill(w, "tool_use_id", ev.tool_use_id)
  fill(w, "wf_name", ev.name)
  fill(w, "task", ev.task)
  fill(w, "summary", ev.summary)
  w.resume_of = ev.resume_of or w.resume_of
  tag(s, w, ev.prompt_id, ev.ts)
  if ev.parent_id then set_parent(s, w, ev.parent_id, "workflow_tool") end
end

function H.review_submitted(s, ev)
  local a = s.agents[ev.agent_id]
  if not a then return end
  local cur = cur_attempt(a) or open_attempt(a, a.started_at)
  cur.submitted_at = ev.ts
  cur.note = ev.note
  a.status = "REVIEW"
  a.review_count = a.review_count + 1
end

function H.review_result(s, ev)
  local a = s.agents[ev.agent_id]
  if not a then return end
  local cur = cur_attempt(a) or open_attempt(a, a.started_at)
  if not cur.submitted_at then
    cur.submitted_at = ev.ts
    a.review_count = a.review_count + 1
  end
  cur.verdict = ev.verdict
  cur.decided_by = ev.decided_by
  cur.reason = ev.reason
  cur.decided_at = ev.ts
  cur.proposed_by = ev.proposed_by
  cur.proposed_verdict = ev.proposed_verdict
  cur.rubric_version = ev.rubric_version
  if ev.verdict == "PASS" then
    a.status = "DONE"
  elseif ev.verdict == "RETRY" then
    a.status = "REWORK"
    a.rework_count = a.rework_count + 1
  elseif ev.verdict == "ESCALATE" then
    a.status = "REVIEW"
    a.escalated_to = ev.escalate_to or a.parent_id
    cur.escalate_to = a.escalated_to
  end
end

function H.rework_started(s, ev)
  local a = s.agents[ev.agent_id]
  if not a then return end
  start_rework(s, a, ev.ts, ev.retry_of, ev.trigger or "user")
end

-- ---------- 集計 ----------

local function recount(s)
  local c = { agents = 0, done = 0, running = 0, review = 0, rework = 0, failed = 0, pending = 0, unknown_parent = 0 }
  local wfs = {}
  for _, id in ipairs(s.order) do
    local a = s.agents[id]
    if a and a.kind == "workflow" then
      wfs[#wfs + 1] = a
    elseif a and id ~= "ROOT" then
      c.agents = c.agents + 1
      local k = a.status:lower()
      c[k] = (c[k] or 0) + 1
      if not a.parent_id then c.unknown_parent = c.unknown_parent + 1 end
    end
  end
  -- 答え待ちの HUMAN CHECK が残っている流れ（流れの状態を決める前に数える）
  local waiting_in = {}
  for _, cid in ipairs(s.check_order or {}) do
    local ck = s.checks and s.checks[cid]
    if ck and ck.status == "WAITING" then waiting_in[ck.prompt_id or ""] = true end
  end
  if type(s.flows) == "table" then
    -- 流れごとの Agent 数と状態
    local cnt, active = {}, {}
    for _, id in ipairs(s.order) do
      local a = s.agents[id]
      local pid = a and id ~= "ROOT" and a.kind ~= "workflow" and a.prompt_id
      if pid then
        cnt[pid] = (cnt[pid] or 0) + 1
        if ACTIVE[a.status] then active[pid] = true end
      end
    end
    local rs = s.agents.ROOT and s.agents.ROOT.status
    for _, f in ipairs(s.flows) do
      f.agents = cnt[f.id] or 0
      if rs == "FAILED" or rs == "REWORK" or rs == "REVIEW" then
        f.status = rs
      else
        -- 人の答え待ちが残っている間は終わっていない（子を裏で動かすと、親の Stop が質問より先に来るため）
        f.status = (active[f.id] or waiting_in[f.id] or not f.ended_at) and "RUNNING" or "DONE"
      end
    end
    c.flows = #s.flows
  end
  local np = 0
  for _ in pairs(s.phantoms or {}) do np = np + 1 end
  c.phantoms = np
  -- HUMAN CHECK：総数・答え待ちの数（全体と流れごと）と、流れの中での通し番号 n（聞いた順）
  c.checks, c.waiting = 0, 0
  local fw, groups, gorder = {}, {}, {}
  for i, cid in ipairs(s.check_order or {}) do
    local ck = s.checks and s.checks[cid]
    if ck then
      c.checks = c.checks + 1
      local key = ck.prompt_id or ""
      if ck.status == "WAITING" then
        c.waiting = c.waiting + 1
        fw[key] = (fw[key] or 0) + 1
      end
      if not groups[key] then groups[key] = {}; gorder[#gorder + 1] = key end
      local g = groups[key]
      g[#g + 1] = { c = ck, t = secs(ck.asked_at), i = i }
    end
  end
  for _, key in ipairs(gorder) do
    local g = groups[key]
    table.sort(g, function(x, y)
      if x.t and y.t and x.t ~= y.t then return x.t < y.t end
      if (x.t == nil) ~= (y.t == nil) then return x.t ~= nil end -- 聞いた時刻の無いものは後ろ
      return x.i < y.i
    end)
    for n, x in ipairs(g) do x.c.n = n end
  end
  for _, f in ipairs(type(s.flows) == "table" and s.flows or {}) do f.waiting = fw[f.id] or 0 end
  -- Workflow のまとめ役：状態と時刻は中の Agent から決める
  for _, w in ipairs(wfs) do
    local kids = {}
    for _, x in ipairs(w.children) do
      if s.agents[x] then kids[#kids + 1] = s.agents[x] end
    end
    local active, failed = false, 0
    local st0, fin0 = nil, nil
    for _, k in ipairs(kids) do
      if ACTIVE[k.status] then active = true end
      if k.status == "FAILED" then failed = failed + 1 end
      local t = secs(k.started_at)
      if t and (not st0 or t < st0[1]) then st0 = { t, k.started_at } end
      local f = secs(k.finished_at)
      if f and (not fin0 or f > fin0[1]) then fin0 = { f, k.finished_at } end
    end
    if active then
      w.status = "RUNNING"
    elseif #kids == 0 then
      w.status = s.ended_at and "DONE" or "RUNNING"
    elseif failed == #kids then
      w.status = "FAILED"
    else
      w.status = "DONE"
    end
    w.first_at = st0 and st0[2] or nil
    local started = w.started_at or w.first_at
    w.finished_at = (w.status ~= "RUNNING" and fin0) and fin0[2] or nil
    w.elapsed_ms = (started and w.finished_at) and elapsed(started, w.finished_at) or nil
  end
  s.counts = c
end

--- Apply one event (broken records are ignored).
--- 1 件足す（壊れた記録は無視する）
function M.apply(s, ev)
  if type(ev) ~= "table" then return s end
  local h = H[ev.event]
  if h then
    local r = s.agents.ROOT
    if r.status == "PENDING" and ev.event ~= "run_ended" then
      r.status = "RUNNING"
      if #r.attempts == 0 then open_attempt(r, ev.ts) end
      r.started_at = r.started_at or ev.ts
    end
    s.started_at = s.started_at or ev.ts
    local ok = pcall(h, s, ev)
    if not ok then s.bad_events = (s.bad_events or 0) + 1 end
  end
  if type(ev.seq) == "number" and ev.seq > s.last_seq then s.last_seq = ev.seq end
  s.updated_at = ev.ts or s.updated_at
  recount(s)
  return s
end

--- Build the state from all events (time order; hooks before events at the same time).
--- 記録の全部から状態を作る。時刻順（同じ時刻なら hooks → events、その中はファイル順）
function M.reduce(events, run_id)
  local list = {}
  for i, ev in ipairs(events or {}) do
    list[i] = { ev = ev, t = util.parse_iso(ev.ts) or 0, fo = ev._fo or 0, i = i }
  end
  table.sort(list, function(a, b)
    if a.t ~= b.t then return a.t < b.t end
    if a.fo ~= b.fo then return a.fo < b.fo end
    return a.i < b.i
  end)
  local rid = run_id
  if not rid then
    for _, x in ipairs(list) do if x.ev.run_id then rid = x.ev.run_id break end end
  end
  local s = M.new(rid)
  for _, x in ipairs(list) do M.apply(s, x.ev) end
  recount(s)
  return s
end

-- ---------- 指示ごとの流れを見る ----------

--- Id of the newest flow that has at least one agent, or nil.
--- いちばん新しく始まった流れ（Agent が 1 つ以上あるもの）の id。無ければ nil
function M.latest_flow_id(s)
  if type(s) ~= "table" or type(s.flows) ~= "table" then return nil end
  local best, bt, bn
  for _, f in ipairs(s.flows) do
    if (f.agents or 0) > 0 then
      local t, n = secs(f.started_at) or 0, f.n or 0
      if not best or t > bt or (t == bt and n > bn) then best, bt, bn = f.id, t, n end
    end
  end
  return best
end

--- Find a flow by a prefix of its prompt_id (only when unique).
--- prompt_id の先頭の数文字から流れを探す（候補が 1 つのときだけ）
function M.flow_by_prefix(s, prefix)
  if type(s) ~= "table" or type(s.flows) ~= "table" or not prefix or prefix == "" then return nil end
  local hit
  for _, f in ipairs(s.flows) do
    if f.id:sub(1, #prefix) == prefix then
      if hit then return nil end
      hit = f
    end
  end
  return hit
end

--- A display copy of the state that contains only one flow (the original is not changed).
--- 1 つの流れだけを取り出した「見せる用」の状態を作る（元の状態は変えない）
---   ROOT は指示の本文を題名にした写し。Agent の番号は流れの中で 1 から振り直す。
---   Agent の id はそのままなので、レビューなどの記録は元の状態に向けて書ける。
function M.flow_view(s, flow_id)
  local f = s and flow_of(s, flow_id)
  if not f then return nil end
  local members, is_member = {}, {}
  for _, id in ipairs(s.order) do
    local a = s.agents[id]
    -- どの指示のものか分からない Agent は、隠さずにどの流れにも出す（hooks の記録なら起きない）
    if a and id ~= "ROOT" and (a.prompt_id == flow_id or a.prompt_id == nil) then
      members[#members + 1] = id
      is_member[id] = true
    end
  end
  table.sort(members, function(x, y)
    local ix, iy = s.agents[x].index or 1e9, s.agents[y].index or 1e9
    if ix ~= iy then return ix < iy end
    return x < y
  end)
  local function copy(a)
    local c = {}
    for k, v in pairs(a) do c[k] = v end
    local ch = {}
    for _, x in ipairs(a.children or {}) do
      if is_member[x] then ch[#ch + 1] = x end
    end
    c.children = ch
    return c
  end
  local v = {}
  for k, val in pairs(s) do v[k] = val end
  v.flows, v.prompt_alias, v.flow_seq, v.phantoms = nil, nil, nil, nil
  v.agents, v.order = {}, { "ROOT" }
  local n = 0
  for _, id in ipairs(members) do
    local c = copy(s.agents[id])
    if c.kind ~= "workflow" then
      n = n + 1
      c.index = n
    end
    v.agents[id] = c
    v.order[#v.order + 1] = id
  end
  v.next_index = n + 1
  -- HUMAN CHECK：この流れのものだけ写す。箱を付ける先（owner）が流れの外なら ROOT に付け替えた写しにする
  local in_flow = {}
  v.checks, v.check_order = {}, {}
  for _, cid in ipairs(s.check_order or {}) do
    local ck = s.checks and s.checks[cid]
    -- どの指示のものか分からない check は、Agent と同じく隠さずにどの流れにも出す
    if ck and (ck.prompt_id == flow_id or ck.prompt_id == nil) then
      local cc = {}
      for k, val in pairs(ck) do cc[k] = val end
      if cc.owner_id ~= "ROOT" and not is_member[cc.owner_id] then cc.owner_id = "ROOT" end
      if cc.agent_id and not is_member[cc.agent_id] then cc.agent_id = nil end
      v.checks[cid] = cc
      v.check_order[#v.check_order + 1] = cid
      in_flow[cid] = true
    end
  end
  local function flow_checks(id)
    local out = {}
    for _, cid in ipairs(v.check_order) do
      if v.checks[cid].owner_id == id then out[#out + 1] = cid end
    end
    return out
  end
  for _, id in ipairs(members) do
    if v.agents[id].checks then v.agents[id].checks = flow_checks(id) end
  end
  local r = copy(s.agents.ROOT)
  r.checks = flow_checks("ROOT")
  if f.prompt_head then
    r.task, r.prompt_head = f.prompt_head, f.prompt_head
  end
  r.started_at = f.started_at
  r.status = f.status or "RUNNING"
  -- 人の答え待ちで RUNNING のままの流れは、親の Stop の時刻を終わりとして出さない（経過時間が止まって見えるため）
  r.finished_at = f.ended_at
  if r.status == "RUNNING" and (f.waiting or 0) > 0 then r.finished_at = nil end
  r.last_head = f.last_head -- この指示の番の最後の返事（無ければ空）
  r.elapsed_ms = (f.ended_at and r.status ~= "RUNNING") and elapsed(f.started_at, f.ended_at) or nil
  v.agents.ROOT = r
  v.title = f.prompt_head or require("agentmap.i18n").t("common.no_prompt")
  v.started_at = f.started_at
  if r.status == "RUNNING" then
    v.ended_at, v.end_reason = nil, nil
  else
    v.ended_at = f.ended_at or s.ended_at
  end
  v.flow = {
    id = f.id, n = f.n, total = #s.flows, prompt_head = f.prompt_head,
    started_at = f.started_at, ended_at = f.ended_at, agents = n,
  }
  recount(v)
  return v
end

-- ---------- 見る道具 ----------

local function by_index_cmp(s)
  return function(x, y)
    local a, b = s.agents[x], s.agents[y]
    return (a and a.index or 1e9) < (b and b.index or 1e9)
  end
end

--- Child ids in display-number order ("UNKNOWN_PARENT" lists agents without a known parent).
--- 子の id 一覧（番号順）。id = "UNKNOWN_PARENT" なら親の分からない Agent
function M.children(s, id)
  local out = {}
  if id == "UNKNOWN_PARENT" then
    for _, x in ipairs(s.order) do
      local a = s.agents[x]
      if a and x ~= "ROOT" and not a.parent_id then out[#out + 1] = x end
    end
  else
    local a = s.agents[id]
    if not a then return out end
    for _, x in ipairs(a.children) do if s.agents[x] then out[#out + 1] = x end end
  end
  table.sort(out, by_index_cmp(s))
  return out
end

--- Ancestor ids, nearest first; ends with "UNKNOWN_PARENT" when the parent is unknown.
--- 親をたどった id 一覧（近い順。自分は含まない）。親が分からなければ "UNKNOWN_PARENT" で終わる
function M.parent_chain(s, id)
  local out, seen = {}, { [id] = true }
  local a = s.agents[id]
  while a and a.id ~= "ROOT" do
    local p = a.parent_id
    if not p then out[#out + 1] = "UNKNOWN_PARENT" break end
    if seen[p] then break end
    seen[p] = true
    out[#out + 1] = p
    a = s.agents[p]
  end
  return out
end

--- Agent with display number `n` (0 is ROOT).
--- 表示番号から Agent を探す（0 は ROOT）
function M.by_index(s, n)
  n = tonumber(n)
  if not n then return nil end
  for _, id in ipairs(s.order) do
    local a = s.agents[id]
    if a and a.index == n then return a end
  end
  return nil
end

--- Progress { done, total, pct } when the agent has children, else nil.
--- 進み具合：子がいるときだけ { done, total, pct }。いなければ nil
function M.progress(s, id)
  local ch = M.children(s, id)
  if #ch == 0 then return nil end
  local done = 0
  for _, x in ipairs(ch) do
    if s.agents[x].status == "DONE" then done = done + 1 end
  end
  return { done = done, total = #ch, pct = math.floor(100 * done / #ch) }
end

--- Number of descendants (for the collapsed [+n] mark).
--- 子孫の数（折りたたみ表示の [+n] 用）
function M.descendants_count(s, id)
  local n, seen = 0, { [id] = true }
  local function walk(x)
    for _, c in ipairs(M.children(s, x)) do
      if not seen[c] then
        seen[c] = true
        n = n + 1
        walk(c)
      end
    end
  end
  walk(id)
  return n
end

--- Rows to show in order { {id, depth, collapsed_count?}, ... }.
--- 表示する順の一覧 { {id, depth, collapsed_count?}, ... }
--- view_root から下だけ。collapsed_set[id] が true の Agent は子を出さない
function M.visible_tree(s, view_root, collapsed_set)
  view_root = view_root or "ROOT"
  collapsed_set = collapsed_set or {}
  local out, seen = {}, {}
  local function walk(id, depth)
    if seen[id] then return end
    seen[id] = true
    local item = { id = id, depth = depth }
    out[#out + 1] = item
    if collapsed_set[id] then
      local n = M.descendants_count(s, id)
      if n > 0 then item.collapsed_count = n end
      return
    end
    for _, c in ipairs(M.children(s, id)) do walk(c, depth + 1) end
  end
  if view_root == "UNKNOWN_PARENT" or s.agents[view_root] then walk(view_root, 0) end
  return out
end

--- Top-level entries: ROOT, plus UNKNOWN_PARENT when needed.
--- 図のいちばん上に並べるもの：ROOT と、親の分からない Agent があれば UNKNOWN_PARENT
function M.roots(s)
  local r = { "ROOT" }
  if #M.children(s, "UNKNOWN_PARENT") > 0 then r[2] = "UNKNOWN_PARENT" end
  return r
end

--- Summary of the whole run.
--- run 全体のまとめ
function M.summary(s)
  recount(s)
  local c = vim.deepcopy(s.counts)
  local reviews, reworks = 0, 0
  for _, id in ipairs(s.order) do
    local a = s.agents[id]
    if a then
      reviews = reviews + (a.review_count or 0)
      reworks = reworks + (a.rework_count or 0)
    end
  end
  c.reviews, c.reworks = reviews, reworks
  c.status = s.agents.ROOT and s.agents.ROOT.status or "PENDING"
  c.started_at, c.ended_at = s.started_at, s.ended_at
  c.elapsed_ms = s.ended_at and elapsed(s.started_at, s.ended_at) or nil
  c.title = s.title
  return c
end

--- Ids of the HUMAN CHECKs attached after a box, in the order asked.
--- その箱（Agent / ROOT）の後ろに付く HUMAN CHECK の id 一覧（聞いた順。実在するものだけ）
function M.checks_of(s, id)
  local a = s and s.agents and s.agents[id]
  local out = {}
  if not a or type(a.checks) ~= "table" then return out end
  local pos = {}
  for i, cid in ipairs(s.check_order or {}) do pos[cid] = i end
  for _, cid in ipairs(a.checks) do
    if s.checks and s.checks[cid] then out[#out + 1] = cid end
  end
  table.sort(out, function(x, y)
    local tx, ty = secs(s.checks[x].asked_at), secs(s.checks[y].asked_at)
    if tx and ty and tx ~= ty then return tx < ty end
    if (tx == nil) ~= (ty == nil) then return tx ~= nil end
    return (pos[x] or 0) < (pos[y] or 0)
  end)
  return out
end

--- HUMAN CHECK by id, or nil.
--- HUMAN CHECK を id から引く。無ければ nil
function M.check_of(s, cid)
  return s and s.checks and s.checks[cid] or nil
end

--- Status label such as "[DONE]".
--- "[DONE]" のような状態の札
function M.status_tag(agent)
  return "[" .. ((agent and agent.status) or "PENDING") .. "]"
end

return M
