-- agentmap/graph.lua ... builds the map (pure computation, never touches buffers).
--   layout(state, view) で「箱の図（左→右）」か「木の一覧」を作り、
--   行の文字列・色の範囲・カーソル位置→Agent の対応表をまとめて返す。
--   日本語の task 名があるので、幅は必ず表示幅（strdisplaywidth）で数える。
local M = {}
local stages_mod = require("agentmap.stages")
local brief_mod = require("agentmap.brief")
local tr = require("agentmap.i18n").t -- 表示の文言（t は木のノードの変数名に使っているので tr）

-- ------------------------------------------------------------
-- 小道具（表示幅・時刻・設定）
-- ------------------------------------------------------------
local H = {}
M.util = H

function H.dw(s)
  return vim.fn.strdisplaywidth(s or "")
end

function H.chars(s)
  if s == nil or s == "" then return {} end
  return vim.fn.split(s, "\\zs")
end

-- 改行やタブは1文字の空白にする（箱の中で行が崩れないように）
function H.oneline(s)
  s = tostring(s or "")
  s = s:gsub("[\r\n\t]+", " ")
  return s
end

-- 表示幅 w に収まるよう切る。はみ出すときは末尾を「…」にする
function H.truncate(s, w)
  s = H.oneline(s)
  if w <= 0 then return "" end
  if H.dw(s) <= w then return s end
  local out, used = {}, 0
  for _, c in ipairs(H.chars(s)) do
    local cw = H.dw(c)
    if used + cw > w - 1 then break end
    out[#out + 1] = c
    used = used + cw
  end
  return table.concat(out) .. "…"
end

-- 表示幅 w ちょうどにする（切る＋空白で埋める）。align = "right" で右寄せ
function H.fit(s, w, align)
  s = H.truncate(s, w)
  local pad = string.rep(" ", w - H.dw(s))
  if align == "right" then return pad .. s end
  return s .. pad
end

function H.short_id(id)
  id = tostring(id or "")
  return id:sub(1, 8)
end

-- 時差（秒）。os.time(表) は地方時として解釈するので、その補正に使う
local function tz_offset(t)
  t = t or os.time()
  return os.difftime(t, os.time(os.date("!*t", t)))
end

-- "2026-09-28T04:23:40.123Z" → 秒（UTC の通し秒）。読めなければ nil
function H.parse_iso(s)
  if type(s) ~= "string" then return nil end
  local Y, Mo, D, h, mi, se = s:match("^(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)")
  if not Y then return nil end
  local t = os.time({ year = tonumber(Y), month = tonumber(Mo), day = tonumber(D),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(se), isdst = false })
  if not t then return nil end
  local rest = s:sub(20)
  local sign, oh, om = rest:match("([%+%-])(%d%d):?(%d%d)$")
  if sign then
    local off = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "+" and 1 or -1)
    return t + tz_offset(t) - off
  end
  return t + tz_offset(t)
end

-- 時刻を手元の時計で "HH:MM:SS" に
function H.fmt_clock(iso)
  local t = H.parse_iso(iso)
  if not t then return "-" end
  return os.date("%H:%M:%S", t)
end

-- ミリ秒 → "0:05" / "1:02:03"
function H.fmt_elapsed(ms)
  if not ms or ms < 0 then return "" end
  local s = math.floor(ms / 1000)
  local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
  s = s % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- 所要時間。終わっていれば終了−開始、動いていれば今−開始
function H.elapsed_ms(a, now)
  if a.elapsed_ms then return a.elapsed_ms end
  local st = H.parse_iso(a.started_at)
  if not st then return nil end
  local fin = H.parse_iso(a.finished_at)
  if fin then return (fin - st) * 1000 end
  if a.status == "RUNNING" or a.status == "REVIEW" or a.status == "PENDING" then
    return math.max(0, ((now or os.time()) - st) * 1000)
  end
  return nil
end

-- モデル名を短く（提供元のモジュールがあればそちらを使う）
function H.model_short(m)
  if not m or m == "" then return nil end
  local ok, p = pcall(require, "agentmap.providers.claude")
  if ok and type(p) == "table" and type(p.model_short) == "function" then
    local ok2, r = pcall(p.model_short, m)
    if ok2 and r then return r end
  end
  m = m:gsub("^claude%-", ""):gsub("%-%d%d%d%d%d%d%d%d$", "")
  return m
end

local DEFAULTS = { box_w = 26, box_h = 4, col_gap = 7, row_gap = 1, mode = "auto" }
function H.config()
  local ok, c = pcall(require, "agentmap.config")
  local got = {}
  if ok and type(c) == "table" and type(c.get) == "function" then
    local ok2, r = pcall(c.get)
    if ok2 and type(r) == "table" then got = r end
  end
  return setmetatable(got, { __index = DEFAULTS })
end

-- ------------------------------------------------------------
-- 状態（state）の読み方。state.lua に頼らず、§4 の形だけを前提にする
-- ------------------------------------------------------------
M.STATUS_HL = {
  PENDING = "AgentMapPending",
  RUNNING = "AgentMapRunning",
  REVIEW = "AgentMapReview",
  DONE = "AgentMapDone",
  REWORK = "AgentMapRework",
  FAILED = "AgentMapFailed",
  -- 一時停止（DESIGN-v0.1.2-pause §6.3）。橙：黄＝動いている・紫＝人の番・赤＝失敗と見分ける
  PAUSED = "AgentMapPaused",
  GATE = "AgentMapPaused",
}

--- Define the highlight groups owned by graph.lua (currently AgentMapPaused, orange).
--- Uses default = true, so a color scheme or the user's own definition wins.
--- Called from init.lua's hl() on setup / ColorScheme / background change, and once lazily by layout().
--- Not linked to DiagnosticWarn: in Neovim's default scheme that group is yellow, the RUNNING color.
function M.setup_highlights()
  local light = vim.o.background == "light"
  pcall(vim.api.nvim_set_hl, 0, "AgentMapPaused", {
    default = true, bold = true,
    fg = light and "#bc4c00" or "#f0883e",
    ctermfg = light and 166 or 208,
  })
end

-- 色がまだ定義されていなければ定義する（init.lua の hl() から呼ばれる前に図を描いたときの保険）
local function ensure_highlights()
  local ok, got = pcall(vim.api.nvim_get_hl, 0, { name = "AgentMapPaused" })
  if ok and type(got) == "table" and next(got) == nil then M.setup_highlights() end
end
M._ensure_highlights = ensure_highlights

--- Status label such as "[DONE]".
function M.status_tag(status)
  return "[" .. (status or "PENDING") .. "]"
end

-- HUMAN CHECK（AskUserQuestion）の箱の色と札。
--   人の番（WAITING）は紫：黄（RUNNING＝AI が動いている）と見分けるため。答えが出たら DONE と同じ緑
M.CHECK_HL = { WAITING = "AgentMapWaiting", ANSWERED = "AgentMapDone", ABANDONED = "AgentMapPending" }
M.CHECK_TAG = { WAITING = "[WAITING]", ANSWERED = "[DONE]", ABANDONED = "[UNANSWERED]" }

local function is_check_id(id)
  return type(id) == "string" and id:sub(1, 6) == "check:"
end
M.is_check_id = is_check_id

--- Ids of the HUMAN CHECKs attached after a box (agent or ROOT), in the order asked.
--- その箱（Agent / ROOT）の後ろに付く check の id 一覧（聞いた時刻の順）
--   state.lua に頼らず a.checks を見る。a.checks に無くても owner_id がこの箱の check は拾う
--   （流れごとの写しで owner が付け替えられたときに取りこぼさないため）。
--   owner_id が別の箱を指している check は、a.checks に残っていても入れない（二重に描かないため）
function M.checks_of(state, id)
  local checks = state and state.checks
  if type(checks) ~= "table" then return {} end
  local a = state.agents and state.agents[id]
  local out, seen = {}, {}
  local function add(cid)
    local c = checks[cid]
    if c and not seen[cid] and (c.owner_id == nil or c.owner_id == id) then
      seen[cid] = true
      out[#out + 1] = cid
    end
  end
  for _, cid in ipairs(a and a.checks or {}) do add(cid) end
  for _, cid in ipairs(state.check_order or {}) do
    local c = checks[cid]
    if c and c.owner_id == id then add(cid) end
  end
  local pos = {}
  for i, cid in ipairs(out) do pos[cid] = i end
  table.sort(out, function(x, y)
    local tx, ty = H.parse_iso(checks[x].asked_at), H.parse_iso(checks[y].asked_at)
    if tx and ty and tx ~= ty then return tx < ty end
    if (tx == nil) ~= (ty == nil) then return tx ~= nil end
    return pos[x] < pos[y]
  end)
  return out
end

--- Number of HUMAN CHECKs waiting for an answer in the shown state.
--- 見ている範囲で答えを待っている check の数
function M.waiting_count(state)
  local n = 0
  for _, c in pairs(state and state.checks or {}) do
    if c.status == "WAITING" then n = n + 1 end
  end
  return n
end

-- 答えの要約："A" / "A, B" / 選択肢に無い自由入力は先頭 30 字
local function answer_summary(c)
  local q1 = (c.questions or {})[1]
  local answers = type(c.answers) == "table" and c.answers or {}
  local v = q1 and answers[q1.question]
  if v == nil then
    -- 質問文の写しが少し違っても答えは出す（最初に見つかった答え）
    for _, x in pairs(answers) do
      v = x
      break
    end
  end
  local list = brief_mod.answer_list(v)
  if #list == 0 then return nil end
  local labels = {}
  for _, o in ipairs(q1 and q1.options or {}) do labels[o.label or ""] = true end
  local parts = {}
  for _, l in ipairs(list) do
    parts[#parts + 1] = labels[l] and l or H.truncate(l, 30)
  end
  return table.concat(parts, ", ")
end

--- check 1 つの表示用の情報
-- 質問の先頭の「<子の名前> について：」「<name>: 」を落とす区切り（DESIGN §6.3）。長い順に試す
local Q_SEPS = { " について：", " について:", "について：", "について:", " ：", "：", ": " }

--- Display form of a HUMAN CHECK question: when it starts with the linked agent's description (name or task)
--- followed by " について：" / "について:" / ": " / "：", return the remainder; otherwise the whole question.
--- Display only: the binding itself (state.lua) still uses "the question contains the description".
function M.strip_question_prefix(question, agent)
  if type(question) ~= "string" or type(agent) ~= "table" then return question end
  for _, nm in ipairs({ agent.name, agent.task }) do
    if type(nm) == "string" and nm ~= "" and question:sub(1, #nm) == nm then
      local rest = question:sub(#nm + 1)
      for _, sep in ipairs(Q_SEPS) do
        if rest:sub(1, #sep) == sep then
          local r = vim.trim(rest:sub(#sep + 1))
          if r ~= "" then return r end
        end
      end
    end
  end
  return question
end

--- Display information of a HUMAN CHECK: status, tag, highlight, elapsed time, question, answer.
function M.check_info(state, c, now)
  local st = c.status or "WAITING"
  local asked = H.parse_iso(c.asked_at)
  local el
  if asked then
    local fin
    if st == "WAITING" then fin = now or os.time()
    elseif st == "ANSWERED" then fin = H.parse_iso(c.answered_at)
    else fin = H.parse_iso(c.ended_at) end
    if fin then el = math.max(0, (fin - asked) * 1000) end
  end
  local q1 = (c.questions or {})[1] or {}
  local linked = c.agent_id and state and state.agents and state.agents[c.agent_id]
  return {
    status = st, tag = M.CHECK_TAG[st] or ("[" .. st .. "]"), hl = M.CHECK_HL[st] or "AgentMapPending",
    elapsed_ms = el, question = q1.question, header = q1.header, answer = answer_summary(c),
    question_short = M.strip_question_prefix(q1.question, linked),
    n_options = #(q1.options or {}), n = c.n,
  }
end

--- The agent `id` of `state` (a placeholder ROOT when missing).
function M.agent(state, id)
  local a = state and state.agents and state.agents[id]
  if a then return a end
  if id == "ROOT" then return { id = "ROOT", status = "PENDING", children = {} } end
  return nil
end

--- Agent ids in order of first appearance.
-- 初めて出てきた順の id 一覧
function M.order_ids(state)
  local out, seen = {}, {}
  for _, id in ipairs(state.order or {}) do
    if state.agents[id] and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  local rest = {}
  for id in pairs(state.agents or {}) do
    if not seen[id] then rest[#rest + 1] = id end
  end
  table.sort(rest, function(x, y)
    local ax, ay = state.agents[x].index or math.huge, state.agents[y].index or math.huge
    if ax ~= ay then return ax < ay end
    return x < y
  end)
  for _, id in ipairs(rest) do out[#out + 1] = id end
  return out
end

--- Child ids of `id` (listed children first, then agents linked only by parent_id).
-- 子の一覧（children に書かれた順 → parent_id だけで繋がっているものを後ろに）
function M.children(state, id)
  local out, seen = {}, { [id] = true }
  local a = state.agents and state.agents[id]
  for _, c in ipairs(a and a.children or {}) do
    if state.agents[c] and not seen[c] then
      seen[c] = true
      out[#out + 1] = c
    end
  end
  for _, oid in ipairs(M.order_ids(state)) do
    if not seen[oid] and state.agents[oid].parent_id == id then
      seen[oid] = true
      out[#out + 1] = oid
    end
  end
  return out
end

--- Agents whose parent is unknown.
-- 親が分からない Agent（parent_id が無い、または親の記録が無い）
function M.unknown_parent_ids(state)
  local out = {}
  for _, id in ipairs(M.order_ids(state)) do
    local a = state.agents[id]
    if id ~= "ROOT" then
      local p = a.parent_id
      if p == nil or (p ~= "ROOT" and not state.agents[p]) then out[#out + 1] = id end
    end
  end
  return out
end

--- Progress of `id`: finished children / all children, or nil without children.
-- 進捗：子があるときだけ「終わった子 / 全部の子」。本文から推測はしない
function M.progress(state, id)
  local kids = M.children(state, id)
  if #kids == 0 then return nil end
  local done = 0
  for _, c in ipairs(kids) do
    if state.agents[c].status == "DONE" then done = done + 1 end
  end
  return { done = done, total = #kids, pct = math.floor(100 * done / #kids) }
end

--- Agent id with display number `n`.
function M.by_index(state, n)
  for id, a in pairs(state.agents or {}) do
    if a.index == n then return id end
  end
  return nil
end

-- レビューの門を出すか
local function has_gate(a)
  if (a.review_count or 0) > 0 then return true end
  if a.status == "REVIEW" or a.status == "REWORK" then return true end
  for _, at in ipairs(a.attempts or {}) do
    if at.verdict or at.submitted_at then return true end
  end
  return false
end

--- The attempt shown in a review gate.
-- 門に表示する試行（判定の付いた最後の試行。無ければ提出済みの最後、無ければ今の試行）
function M.gate_attempt(a)
  local atts = a.attempts or {}
  for i = #atts, 1, -1 do
    if atts[i].verdict then return atts[i] end
  end
  for i = #atts, 1, -1 do
    if atts[i].submitted_at then return atts[i] end
  end
  return atts[#atts] or { n = a.attempt or 1 }
end

--- Display information of the review gate of agent `a`.
function M.gate_info(state, a)
  local at = M.gate_attempt(a)
  local verdict = at.verdict
  local status = verdict == "PASS" and "DONE" or verdict == "RETRY" and "REWORK" or "REVIEW"
  local info = {
    attempt = at, verdict = verdict, status = status,
    tag = verdict and ("[" .. verdict .. "]") or "[REVIEW]",
    n = at.n or a.review_count or 1,
  }
  if at.retried_by and state.agents[at.retried_by] then
    info.retry_to = at.retried_by
  end
  if verdict == "ESCALATE" then
    info.escalate_to = a.escalated_to or a.parent_id
  end
  return info
end

local ACTIVE = { PENDING = true, RUNNING = true, REVIEW = true }

--- Status of the END node: done when the run has ended and no agent is still running.
--- 流れ全体が終わったか（END の状態）：終わりの記録があり、動いている Agent が 1 つも無い
function M.end_status(state)
  if not state.ended_at then return "PENDING" end
  for id, a in pairs(state.agents or {}) do
    if id ~= "ROOT" and a.kind ~= "workflow" and ACTIVE[a.status or "PENDING"] then return "PENDING" end
  end
  return "DONE"
end

local function flatten(stages)
  local out = {}
  for _, st in ipairs(stages) do
    for _, m in ipairs(st) do out[#out + 1] = m end
  end
  return out
end
M.flatten = flatten

-- check 1 つを段分けの要素に（stages.item_check があればそれ。stages.lua は別の担当なので無くても動く）
local function item_check(c)
  if type(stages_mod.item_check) == "function" then
    local ok, it = pcall(stages_mod.item_check, c)
    if ok and type(it) == "table" then return it end
  end
  local util = require("agentmap.util")
  return { id = c.id, st = util.parse_iso(c.asked_at), fin = util.parse_iso(c.answered_at or c.ended_at),
    open = (c.status == "WAITING"), batch = nil }
end

--- Split a mixed list of agent and check ids into stages.
--- Agent と check が混ざった id 一覧を段に分ける（check も時刻を持つ普通の要素として扱う）
function M.stages_of(state, ids)
  local items = {}
  for _, id in ipairs(ids or {}) do
    local it
    local c = is_check_id(id) and state.checks and state.checks[id]
    if c then
      it = item_check(c)
    else
      it = stages_mod.item(state.agents and state.agents[id] or { id = id })
    end
    it.id = id
    items[#items + 1] = it
  end
  return stages_mod.split(items)
end

--- Build the tree to show; returns the roots (ROOT and, when needed, UNKNOWN_PARENT).
-- 表示する木を作る。戻り値は根の一覧（ROOT と、必要なら UNKNOWN_PARENT）
-- 各ノード = { id, kind = "agent"|"gate"|"group"|"end", stages = { {ノード…}, … }, children = 段を平らにしたもの,
--             collapsed_count }
--   同じ親の子は、時刻から決めた「段」（stages.lua）に分ける。レビューの門はその Agent の最後の段。
--   全体（view.root = ROOT）を見ているときは、ROOT の最後の段に END を置く
function M.visible(state, view)
  view = view or {}
  local collapsed = view.collapsed or {}
  local visited = {}

  local function count_desc(id, seen)
    local n = 0
    for _, c in ipairs(M.children(state, id)) do
      if not seen[c] then
        seen[c] = true
        n = n + 1 + count_desc(c, seen)
      end
    end
    return n
  end

  local function check_node(cid)
    local c = state.checks[cid]
    return { id = cid, kind = "check", check = c, info = M.check_info(state, c, view.now), stages = {}, children = {} }
  end

  local function build(id)
    if visited[id] then return nil end
    visited[id] = true
    local a = M.agent(state, id)
    local node = { id = id, kind = "agent", stages = {}, children = {} }
    local kids = M.children(state, id)
    -- この箱に付く HUMAN CHECK を 2 つに分ける（§5.1）
    --   linked：この Agent 自身の「要確認」から生まれた質問 → この Agent の最後の段（門の前）
    --   direct：聞いた側が直接聞いた質問 → 子と一緒に時刻で段分けする
    local linked, direct = {}, {}
    for _, cid in ipairs(M.checks_of(state, id)) do
      if state.checks[cid].agent_id == id then linked[#linked + 1] = cid else direct[#direct + 1] = cid end
    end
    if collapsed[id] and (#kids > 0 or has_gate(a) or #linked + #direct > 0) then
      node.collapsed_count = count_desc(id, { [id] = true })
      return node
    end
    local mixed = vim.list_extend(vim.list_extend({}, kids), direct)
    for _, ids in ipairs(M.stages_of(state, mixed)) do
      local st = {}
      for _, c in ipairs(ids) do
        local cn
        if is_check_id(c) then cn = check_node(c) else cn = build(c) end
        if cn then st[#st + 1] = cn end
      end
      if #st > 0 then node.stages[#node.stages + 1] = st end
    end
    for _, cid in ipairs(linked) do
      node.stages[#node.stages + 1] = { check_node(cid) }
    end
    if has_gate(a) then
      local gate = { id = "gate:" .. id, kind = "gate", agent_id = id, stages = {}, children = {} }
      gate.info = M.gate_info(state, a)
      node.stages[#node.stages + 1] = { gate }
    end
    node.children = flatten(node.stages)
    return node
  end

  local function build_group()
    local ids = M.unknown_parent_ids(state)
    if #ids == 0 then return nil end
    local g = { id = "UNKNOWN_PARENT", kind = "group", stages = {}, children = {}, count = #ids }
    if collapsed.UNKNOWN_PARENT then
      g.collapsed_count = #ids
      return g
    end
    local st = {}
    for _, id in ipairs(ids) do
      local cn = build(id)
      if cn then st[#st + 1] = cn end
    end
    if #st > 0 then g.stages[1] = st end
    g.children = flatten(g.stages)
    return g
  end

  local root = view.root or "ROOT"
  if root == "UNKNOWN_PARENT" then
    local g = build_group()
    return { g or { id = "UNKNOWN_PARENT", kind = "group", stages = {}, children = {}, count = 0 } }
  end
  if root ~= "ROOT" and not (state.agents and state.agents[root]) then root = "ROOT" end
  local forest = { build(root) }
  if root == "ROOT" then
    local r = forest[1]
    if not r.collapsed_count then
      r.stages[#r.stages + 1] = { { id = "END", kind = "end", status = M.end_status(state), stages = {}, children = {} } }
    end
    local g = build_group()
    if g then forest[#forest + 1] = g end
  end
  return forest
end

-- 段の中に Agent（または Workflow）がいる段の数（END だけ・門だけの段は数えない）
local function agent_stage_count(t)
  local n = 0
  for _, st in ipairs(t.stages or {}) do
    for _, m in ipairs(st) do
      if m.kind == "agent" then
        n = n + 1
        break
      end
    end
  end
  return n
end
M.agent_stage_count = agent_stage_count

-- ------------------------------------------------------------
-- 箱の中身（4行）。各行は { {文字, 色}, ... } の並び
-- ------------------------------------------------------------
local function model_text(a)
  local m = H.model_short(a.model)
  if m then return m end
  local r = H.model_short(a.model_requested)
  if r then return tr("graph.model_requested", { model = r }) end
  return "model: ?"
end

--- Options for progress.compute() taken from the view (DESIGN-v0.2 §2.7):
--- view.now (seconds), view.stats (stats.load()), view.progress (config.progress).
function M.progress_opts(view)
  view = view or {}
  local pcfg = view.progress
  if type(pcfg) ~= "table" then
    local c = H.config().progress
    pcfg = type(c) == "table" and c or {}
  end
  return { now = view.now or os.time(), stats = view.stats, config = pcfg }
end

--- Progress of box `id` for this view (nil: nothing to show). See progress.compute().
function M.box_progress(state, id, view)
  local ok, prog = pcall(require, "agentmap.progress")
  if not ok then return nil end
  local ok2, r = pcall(prog.compute, state, id, M.progress_opts(view))
  if ok2 then return r end
  return nil
end

local function status_segs(state, a, view)
  local st = M.display_status(state, a.id) or a.status or "PENDING"
  local segs = { { M.status_tag(st), M.STATUS_HL[st] or "AgentMapPending" } }
  local opts = M.progress_opts(view)
  local label
  if opts.config.enabled ~= false and a.kind ~= "group" then
    label = require("agentmap.progress").label(M.box_progress(state, a.id, view))
    -- 推定（~）と事実を区別する。幅 24 に収めるため、% があるときは経過時間との間を 1 桁に詰める
    if label then segs[#segs + 1] = { " " .. label } end
  end
  local el = H.elapsed_ms(a, view and view.now)
  if el then segs[#segs + 1] = { (label and " " or "  ") .. H.fmt_elapsed(el) } end
  if (a.rework_count or 0) > 0 then
    segs[#segs + 1] = { tr("graph.rework_n", { n = a.rework_count }), "AgentMapRework" }
  end
  return segs
end

--- Purple marks added to line 4 of a box (waiting / ask).
--- 箱の 4 行目に足す紫の印（§3.7）
--   ROOT：見ている範囲に答え待ちがあれば「確認待ち<n>」
--   子：「## 要確認」を書いて止まった（a.ask）なら「要確認」。結びついた質問に答えが出たら消す
function M.check_marks(state, a)
  if not a then return {} end
  if a.id == "ROOT" then
    local n = M.waiting_count(state)
    if n > 0 then return { { tr("graph.waiting_n", { n = n }), "AgentMapWaiting" } } end
    return {}
  end
  if type(a.ask) == "table" then
    local c = a.ask_check and state.checks and state.checks[a.ask_check]
    if not (c and c.status == "ANSWERED") then return { { tr("graph.ask"), "AgentMapWaiting" } } end
  end
  return {}
end

-- ------------------------------------------------------------
-- 一時停止（DESIGN-v0.1.2-pause §2・§5.2・§6.3）。state.lua の関数があればそれを優先し、
-- 無い間は同じ規則をここで計算する（§13.2 の予備）
-- ------------------------------------------------------------
local LIVE_PAUSE = { REQUESTED = true, PAUSED = true }

local function state_fn(name)
  local ok, st = pcall(require, "agentmap.state")
  if ok and type(st) == "table" and type(st[name]) == "function" then return st[name] end
  return nil
end

--- Pause ids aimed at agent `id`, in request order (state.pauses_of when present).
function M.pauses_of(state, id)
  local all = state and state.pauses
  if type(all) ~= "table" then return {} end
  local f = state_fn("pauses_of")
  if f then
    local ok, r = pcall(f, state, id)
    if ok and type(r) == "table" then
      return vim.tbl_filter(function(pid) return all[pid] ~= nil end, r)
    end
  end
  local out, seen = {}, {}
  local a = state.agents and state.agents[id]
  for _, pid in ipairs(a and a.pauses or {}) do
    if all[pid] and not seen[pid] then
      seen[pid] = true
      out[#out + 1] = pid
    end
  end
  for _, pid in ipairs(state.pause_order or {}) do
    if all[pid] and all[pid].agent_id == id and not seen[pid] then
      seen[pid] = true
      out[#out + 1] = pid
    end
  end
  for pid, x in pairs(all) do
    if x.agent_id == id and not seen[pid] then
      seen[pid] = true
      out[#out + 1] = pid
    end
  end
  table.sort(out, function(x, y)
    local tx, ty = H.parse_iso(all[x].requested_at or all[x].hit_at), H.parse_iso(all[y].requested_at or all[y].hit_at)
    if tx and ty and tx ~= ty then return tx < ty end
    if tx and not ty then return true end
    if ty and not tx then return false end
    return tostring(x) < tostring(y)
  end)
  return out
end

--- The live pause (REQUESTED or PAUSED) of agent `id`, or nil (state.pause_of when present).
function M.pause_of(state, id)
  local all = state and state.pauses
  if type(all) ~= "table" then return nil end
  local f = state_fn("pause_of")
  if f then
    local ok, r = pcall(f, state, id)
    if ok then return r end
  end
  local a = state.agents and state.agents[id]
  local cur = a and a.pause and all[a.pause]
  if cur and LIVE_PAUSE[cur.status] then return cur end
  local best
  for _, pid in ipairs(M.pauses_of(state, id)) do
    local x = all[pid]
    if LIVE_PAUSE[x.status] and (not best or best.status ~= "PAUSED") then best = x end
  end
  return best
end

--- Status shown on the box (§2): "GATE" / "PAUSED" while a pause of the agent is PAUSED,
--- otherwise a.status. a.status itself never changes (progress, elapsed time and the flow light rely on it).
function M.display_status(state, id)
  local a = state and state.agents and state.agents[id]
  local base = a and a.status or "PENDING"
  if type(state) ~= "table" or type(state.pauses) ~= "table" then return base end
  local f = state_fn("display_status")
  if f then
    local ok, r = pcall(f, state, id)
    if ok and type(r) == "string" then return r end
  end
  local p = M.pause_of(state, id)
  -- 終わった箱は、終わる直前（SubagentStop / Stop）で止められているときだけ札を変える
  -- （記録係は終わりの記録を書いてから待つので、止まっている間にもう DONE に見える。state.held_at_end と同じ）
  local closed = base == "DONE" or base == "FAILED" or base == "REWORK"
  local at_end = p and (p.hit_via == "SubagentStop" or p.hit_via == "Stop")
  if p and p.status == "PAUSED" and (not closed or at_end) then return p.kind == "gate" and "GATE" or "PAUSED" end
  return base
end

--- Milliseconds agent `id` spent stopped (PAUSED / RESUMED pauses: (released_at or now) - hit_at),
--- counting only the part after `since` (seconds; nil = all). `now` is in seconds.
--- Without `since`, state.paused_ms is used when present.
function M.paused_ms(state, id, now, since)
  local all = state and state.pauses
  if type(all) ~= "table" then return 0 end
  now = now or os.time()
  if since == nil then
    local f = state_fn("paused_ms")
    if f then
      local ok, r = pcall(f, state, id, now)
      if ok and type(r) == "number" then return math.max(0, r) end
    end
  end
  local sum = 0
  for _, pid in ipairs(M.pauses_of(state, id)) do
    local x = all[pid]
    local h = M.pause_time(x.hit_at)
    -- 流れの写しでは、流れの外の宛先の止まれが ROOT に付く（owner_id）。止まっていたのはその宛先なので数えない
    if x.agent_id ~= nil and x.agent_id ~= id then h = nil end
    if h and (x.status == "PAUSED" or x.status == "RESUMED" or x.status == "EXPIRED") then
      local e = M.pause_time(x.released_at)
      if not e then
        -- 止まったまま終わった（EXPIRED）なら終わりの時刻が分からないので数えない。PAUSED は今まで
        e = x.status == "PAUSED" and now or nil
      end
      if e then
        local s0 = since and math.max(h, since) or h
        if e > s0 then sum = sum + (e - s0) * 1000 end
      end
    end
  end
  return sum
end

--- Readable duration for pause texts: "45 s", "3 min 31 s", "10 min", "1 h 5 min" (localized).
---@param ms number|nil
---@return string
function M.fmt_duration(ms)
  if type(ms) ~= "number" or ms < 0 then return "-" end
  local sec = math.floor(ms / 1000 + 0.5)
  if sec < 60 then return tr("common.dur_s", { s = sec }) end
  local m, s2 = math.floor(sec / 60), sec % 60
  if m >= 60 then return tr("common.dur_hm", { h = math.floor(m / 60), m = m % 60 }) end
  if s2 == 0 then return tr("common.dur_m", { m = m }) end
  return tr("common.dur_ms", { m = m, s = s2 })
end

--- Seconds since the epoch for a pause time field: ISO string or epoch number (the hook's deadline). nil if unreadable.
function M.pause_time(v)
  if type(v) == "number" then return v end
  return H.parse_iso(v)
end

--- Milliseconds pause `p` waited: p.waited_ms, else (released_at or now) - hit_at. nil when it never stopped.
function M.pause_waited_ms(p, now)
  if type(p) ~= "table" then return nil end
  if type(p.waited_ms) == "number" then return p.waited_ms end
  local h = M.pause_time(p.hit_at)
  if not h then return nil end
  local e = M.pause_time(p.released_at) or (p.status == "PAUSED" and (now or os.time())) or nil
  if not e then return nil end
  return math.max(0, e - h) * 1000
end

--- Pause mark for a REQUESTED pause (U+23F8), or "||" where the terminal draws it two cells wide.
function M.pause_mark()
  return vim.fn.strdisplaywidth("⏸") == 1 and "⏸" or "||"
end

--- Orange mark on line 4 of a box while a pause is REQUESTED (not yet reached). PAUSED shows the tag instead.
function M.pause_marks(state, a)
  if not a or type(state) ~= "table" or type(state.pauses) ~= "table" then return {} end
  local p = M.pause_of(state, a.id)
  if p and p.status == "REQUESTED" then return { { " " .. M.pause_mark(), "AgentMapPaused" } } end
  return {}
end

--- Steering mark (U+270E), or "*" where the terminal draws it two cells wide.
function M.steer_mark()
  return vim.fn.strdisplaywidth("✎") == 1 and "✎" or "*"
end

--- True for a "notice" (the parent being told about an instruction sent to its child; steer appendix E).
function M.is_notice(x)
  return type(x) == "table" and x.kind == "notice"
end

-- 知らせが元の指示を指す欄（W1 の名前が決まるまで、ありうる名前を全部見る）
local NOTICE_LINK = { "notice_of", "of", "source_id", "about", "for_steer" }

--- The notice sent to the parent about steer `sid` (the latest one), or nil.
function M.notice_of(state, sid)
  local all = state and state.steers
  if type(all) ~= "table" then return nil end
  local best
  for _, y in pairs(all) do
    if M.is_notice(y) then
      for _, k in ipairs(NOTICE_LINK) do
        if y[k] == sid then
          if not best or (H.parse_iso(y.requested_at) or 0) > (H.parse_iso(best.requested_at) or 0) then best = y end
          break
        end
      end
    end
  end
  return best
end

-- 宛先 id の修正指示の一覧（state.steers_of があればそれ。無ければ同じ形をここで引く）。
--   親への知らせ（kind = "notice"）は入れない：印を増やさず、元の指示の詳細に出す（付録 E）
local function steers_of(state, id)
  local all = state and state.steers
  if type(all) ~= "table" then return {} end
  local ok, st = pcall(require, "agentmap.state")
  if ok and type(st) == "table" and type(st.steers_of) == "function" then
    local ok2, r = pcall(st.steers_of, state, id)
    if ok2 and type(r) == "table" then
      return vim.tbl_filter(function(sid) return all[sid] ~= nil and not M.is_notice(all[sid]) end, r)
    end
  end
  local out, seen = {}, {}
  local a = state.agents and state.agents[id]
  for _, sid in ipairs(a and a.steers or {}) do
    if all[sid] and not seen[sid] and not M.is_notice(all[sid]) then
      seen[sid] = true
      out[#out + 1] = sid
    end
  end
  for _, sid in ipairs(state.steer_order or {}) do
    local x = all[sid]
    if x and x.agent_id == id and not seen[sid] and not M.is_notice(x) then
      seen[sid] = true
      out[#out + 1] = sid
    end
  end
  return out
end
M.steers_of = steers_of

M.STEER_RECENT_S = 60 -- 配達済みの印 ✎ を出しておく秒数

--- True for a relay (via the main agent) that is typed or read but not yet passed on with SendMessage
--- (DESIGN-v0.1.2-steer2 §6.4, the same rule as state.relay_pending: no relayed_at, not EXPIRED / CANCELLED).
function M.relay_waiting(x)
  return type(x) == "table" and x.via == "relay" and x.relayed_at == nil
    and x.status ~= "EXPIRED" and x.status ~= "CANCELLED"
end

--- Steering marks on line 4 of a box (DESIGN-v0.2-steer §6.3, DESIGN-v0.1.2-steer2 §7.2):
--- " ✎n" pending, or a relay not passed on yet (purple), " ✎!" not delivered / not relayed (red),
--- " ✎" delivered (or relayed) within the last 60 s (green), otherwise nothing.
function M.steer_marks(state, a, now)
  if not a or type(state) ~= "table" or type(state.steers) ~= "table" then return {} end
  now = now or os.time()
  local pending, expired, recent = 0, false, false
  for _, sid in ipairs(steers_of(state, a.id)) do
    local x = state.steers[sid]
    if x.status == "PENDING" or M.relay_waiting(x) then
      pending = pending + 1
    elseif x.status == "EXPIRED" then
      expired = true
    elseif x.status == "DELIVERED" then
      local t = H.parse_iso(x.relayed_at or x.delivered_at)
      if t and now - t <= M.STEER_RECENT_S then recent = true end
    end
  end
  local mk = M.steer_mark()
  if pending > 0 then return { { " " .. mk .. pending, "AgentMapWaiting" } } end
  if expired then return { { " " .. mk .. "!", "AgentMapRework" } } end
  if recent then return { { " " .. mk, "AgentMapDone" } } end
  return {}
end

--- The four content lines of a box and its border color.
-- node: visible() のノード。戻り値は4行ぶんの segs と、枠の色
function M.box_spec(node, state, view)
  local lines = {}
  if node.kind == "group" then
    lines[1] = { { "UNKNOWN_PARENT", "AgentMapHeader" } }
    lines[2] = { { tr("graph.group_desc"), "AgentMapDim" } }
    lines[3] = { { tr("graph.group_count", { n = node.count or 0 }), "AgentMapDim" } }
    lines[4] = {}
    return lines, "AgentMapPending", nil
  end
  if node.kind == "gate" then
    local a = M.agent(state, node.agent_id) or {}
    local gi = node.info or M.gate_info(state, a)
    local idx = a.index and ("[" .. a.index .. "]") or ""
    lines[1] = { { "◇ Review #" .. gi.n, nil }, { "", nil, idx } }
    lines[2] = { { gi.tag, M.STATUS_HL[gi.status] } }
    local by = gi.attempt.decided_by and ("by " .. gi.attempt.decided_by) or tr("graph.no_verdict")
    local why = gi.attempt.reason and (" " .. tr("common.quote", { text = gi.attempt.reason })) or ""
    lines[3] = { { by .. why, "AgentMapDim" } }
    if gi.retry_to then
      local t = state.agents[gi.retry_to]
      lines[4] = { { "→ retry ", "AgentMapEdgeRetry" }, { "[" .. (t.index or "?") .. "]", "AgentMapIndex" } }
    elseif gi.verdict == "RETRY" then
      lines[4] = { { tr("graph.rerun_same"), "AgentMapEdgeRetry" } }
    elseif gi.verdict == "ESCALATE" then
      local e = gi.escalate_to and state.agents[gi.escalate_to]
      local lab = gi.escalate_to == "ROOT" and "ROOT" or (e and e.index and ("[" .. e.index .. "]")) or "?"
      lines[4] = { { "→ escalate " .. lab, "AgentMapReview" } }
    elseif gi.verdict == "PASS" then
      lines[4] = { { tr("graph.next_stage"), "AgentMapDone" } }
    else
      lines[4] = {}
    end
    return lines, M.STATUS_HL[gi.status], gi
  end

  if node.kind == "check" then
    local c = node.check or (state.checks or {})[node.id] or {}
    local ci = node.info or M.check_info(state, c, view and view.now)
    lines[1] = { { "HUMAN CHECK", "AgentMapHeader" }, { "", nil, ci.n and ("#" .. ci.n) or "" } }
    lines[2] = { { ci.tag, ci.hl } }
    if ci.elapsed_ms and ci.status ~= "ABANDONED" then lines[2][2] = { " " .. H.fmt_elapsed(ci.elapsed_ms) } end
    -- 決まり（§2 6-4）の「<子の名前> について：」/「<name>: 」は箱の中では重複なので後ろだけ見せる（DESIGN §6.3）
    local q = ci.question_short or ci.question or tr("common.no_question")
    -- 質問文が header で始まっているときは header を前に付けない（「テスト: テスト：A と B …」と重なるため）
    local hd = ci.header and ci.header ~= "" and q:sub(1, #ci.header) ~= ci.header and (ci.header .. ": ") or ""
    lines[3] = { { hd .. q, "AgentMapDim" } }
    if ci.status == "WAITING" then
      lines[4] = { { tr("graph.options_enter", { n = ci.n_options }), "AgentMapWaiting" } }
    elseif ci.status == "ANSWERED" then
      lines[4] = { { "→ " .. (ci.answer or tr("common.no_answer")), "AgentMapDone" } }
    else
      lines[4] = { { tr("graph.ended_unanswered"), "AgentMapDim" } }
    end
    return lines, ci.hl, ci
  end

  if node.kind == "start" or node.kind == "end" then
    local st = node.kind == "start" and "DONE" or (node.status or "PENDING")
    lines[1] = { { node.kind == "start" and "START" or "END", "AgentMapHeader" } }
    if node.kind == "end" then
      lines[1][2] = { " " }
      lines[1][3] = st == "DONE" and { "[DONE]", "AgentMapDone" } or { "…", "AgentMapPending" }
    end
    return lines, M.STATUS_HL[st] or "AgentMapPending", nil
  end

  local a = M.agent(state, node.id)
  local st = a.status or "PENDING"
  if a.kind == "workflow" then
    local n = #M.children(state, node.id)
    lines[1] = { { "Workflow " .. tostring(a.wf_id or ""):gsub("^wf_", ""):sub(1, 8), "AgentMapHeader" } }
    lines[2] = { { (a.wf_name or "workflow") .. " · " .. n .. " agents" } }
    lines[3] = { { "task: " .. (a.task or a.summary or "-"), "AgentMapDim" } }
  elseif node.id == "ROOT" then
    lines[1] = { { "ROOT  " .. H.short_id(state.run_id), "AgentMapHeader" } }
    lines[2] = { { model_text(a) .. " · main" } }
    lines[3] = { { state.title or a.task or "-", "AgentMapDim" } }
  else
    local idx = a.index and ("[" .. a.index .. "]") or ""
    lines[1] = { { a.name or a.task or H.short_id(a.id) }, { "", nil, idx } }
    -- Workflow の工程名（workflowPhase）は種類より前に出す（箱の幅で切れないように）
    local l2 = model_text(a) .. (a.phase and tr("graph.phase", { phase = a.phase }) or "")
      .. (a.agent_type and (" · " .. a.agent_type) or "")
    lines[2] = { { l2 } }
    if a.worktree then table.insert(lines[2], 1, { "⌂ ", "AgentMapReview" }) end
    lines[3] = { { "task: " .. (a.task or a.prompt_head or "-"), "AgentMapDim" } }
  end
  lines[4] = status_segs(state, a, view)
  -- 止まれの印 → 人の番の印 → 修正指示の印の順で、状態の札のすぐ後ろに置く
  -- （経過時間などで幅が足りなくなっても切れないように。DESIGN-v0.1.2-pause §6.3）
  local marks = M.pause_marks(state, a)
  vim.list_extend(marks, M.check_marks(state, a))
  -- 修正指示の印は人の番の印の後ろ（DESIGN-v0.2-steer §6.3）
  vim.list_extend(marks, M.steer_marks(state, a, view and view.now))
  for i, s in ipairs(marks) do table.insert(lines[4], 1 + i, s) end
  if node.collapsed_count then
    -- 畳んだ数は札と印のすぐ後ろへ（% と経過時間で幅が埋まっても [+n] が切れないように）
    table.insert(lines[4], 2 + #marks, { " [+" .. node.collapsed_count .. "]", "AgentMapIndex" })
  end
  -- 枠の色も表示上の状態で（止まっている箱は枠も橙）
  local dst = M.display_status(state, node.id)
  return lines, M.STATUS_HL[dst] or M.STATUS_HL[st] or "AgentMapPending", nil
end

-- segs を表示幅 w に収めて繋げる。{文字, 色, 右寄せ文字} の3つ目があれば右端に置く
local function fit_segs(segs, w)
  local right = nil
  for _, s in ipairs(segs) do
    if s[3] and s[3] ~= "" then right = s[3] end
  end
  local avail = right and (w - H.dw(right) - 1) or w
  local out, used = {}, 0
  for _, s in ipairs(segs) do
    local text = s[1] or ""
    if text ~= "" and used < avail then
      local t = text
      if used + H.dw(t) > avail then t = H.truncate(t, avail - used) end
      out[#out + 1] = { t, s[2] }
      used = used + H.dw(t)
    end
  end
  if right then
    out[#out + 1] = { string.rep(" ", w - used - H.dw(right)) }
    out[#out + 1] = { right, "AgentMapIndex" }
  else
    out[#out + 1] = { string.rep(" ", w - used) }
  end
  return out
end

--- The four lines of an agent's box as plain strings.
-- DESIGN §11 の公開関数：箱の4行を文字列で
function M.box_lines(agent, state, view)
  local cfg = H.config()
  local inner = cfg.box_w - 2
  local node = { id = agent.id, kind = "agent", children = {} }
  local spec = M.box_spec(node, state, view)
  local out = {}
  for i = 1, 4 do
    local parts = {}
    for _, s in ipairs(fit_segs(spec[i], inner)) do parts[#parts + 1] = s[1] end
    out[i] = table.concat(parts)
  end
  return out
end

-- ------------------------------------------------------------
-- キャンバス：1セル = 表示1桁。全角は2セル使い、右半分は "" にする
-- ------------------------------------------------------------
local Canvas = {}
Canvas.__index = Canvas

function Canvas.new()
  return setmetatable({ cells = {}, hl = {}, bits = {}, bithl = {}, maps = {}, maxy = -1 }, Canvas)
end

function Canvas:_row(t, y)
  local r = t[y]
  if not r then
    r = {}
    t[y] = r
  end
  if y > self.maxy then self.maxy = y end
  return r
end

-- 全角文字の片割れを壊さないように、そのセルを空ける
local function clear_cell(r, i)
  if r[i] == "" then r[i - 1] = " " end
  local c = r[i]
  if c and c ~= "" and H.dw(c) == 2 and r[i + 1] == "" then r[i + 1] = " " end
end

function Canvas:put(x, y, text, hl)
  local r = self:_row(self.cells, y)
  local hr = self:_row(self.hl, y)
  local cx = x
  for _, c in ipairs(H.chars(text)) do
    local cw = H.dw(c)
    if cw == 0 then
      -- 結合文字などは前の文字にくっつける
      if r[cx - 1] and r[cx - 1] ~= "" then r[cx - 1] = r[cx - 1] .. c end
    else
      clear_cell(r, cx)
      if cw == 2 then clear_cell(r, cx + 1) end
      r[cx] = c
      hr[cx] = hl
      if cw == 2 then
        r[cx + 1] = ""
        hr[cx + 1] = hl
      end
      cx = cx + cw
    end
  end
  return cx
end

function Canvas:put_segs(x, y, segs)
  local cx = x
  for _, s in ipairs(segs) do
    cx = self:put(cx, y, s[1] or "", s[2])
  end
  return cx
end

-- 線のつながり（上下左右のビット）
local U, D, L, R = 1, 2, 4, 8
local LINE = {
  [L + R] = "─", [L] = "─", [R] = "─",
  [U + D] = "│", [U] = "│", [D] = "│",
  [D + R] = "┌", [D + L] = "┐", [U + R] = "└", [U + L] = "┘",
  [U + D + R] = "├", [U + D + L] = "┤", [D + L + R] = "┬", [U + L + R] = "┴",
  [U + D + L + R] = "┼",
}

function Canvas:bit(x, y, b, hl)
  local r = self:_row(self.bits, y)
  r[x] = bit.bor(r[x] or 0, b)
  local hr = self:_row(self.bithl, y)
  if hl == "AgentMapEdgeRetry" or not hr[x] then hr[x] = hl end
end

-- 横線 xa..xb（両端とも隣へつながる前提。端の外側へはつながない）
function Canvas:hline(y, xa, xb, hl, open_left, open_right)
  if xa > xb then return end
  for x = xa, xb do
    local b = 0
    if x > xa or open_left then b = b + L end
    if x < xb or open_right then b = b + R end
    self:bit(x, y, b, hl)
  end
end

function Canvas:vline(x, ya, yb, hl)
  if ya > yb then ya, yb = yb, ya end
  if ya == yb then return end
  for y = ya, yb do
    local b = 0
    if y > ya then b = b + U end
    if y < yb then b = b + D end
    self:bit(x, y, b, hl)
  end
end

function Canvas:map(y, x0, x1, id)
  local r = self:_row(self.maps, y)
  r[#r + 1] = { x0, x1, id }
end

-- 行の文字列・色（バイト桁）・対応表（バイト桁）に変換
function Canvas:finish()
  -- 線を文字にする（文字が既にあるセルには置かない）
  for y, row in pairs(self.bits) do
    local cr = self:_row(self.cells, y)
    local hr = self:_row(self.hl, y)
    for x, b in pairs(row) do
      if cr[x] == nil or cr[x] == " " then
        cr[x] = LINE[b] or "─"
        hr[x] = self.bithl[y][x] or "AgentMapEdge"
      end
    end
  end
  local lines, marks, line_map = {}, {}, {}
  self.colbyte = {}
  for y = 0, self.maxy do
    local cr = self.cells[y] or {}
    local hr = self.hl[y] or {}
    local maxx = -1
    for x in pairs(cr) do
      if x > maxx then maxx = x end
    end
    local parts, colbyte, pos = {}, {}, 0
    for x = 0, maxx do
      colbyte[x] = pos
      local c = cr[x]
      if c == nil then c = " " end
      if c ~= "" then
        parts[#parts + 1] = c
        pos = pos + #c
      end
    end
    colbyte[maxx + 1] = pos
    self.colbyte[y] = colbyte
    local s = table.concat(parts):gsub("%s+$", "")
    lines[y + 1] = s
    local len = #s
    local function B(x)
      if x > maxx + 1 then return len end
      local v = colbyte[x] or len
      return math.min(v, len)
    end
    -- 同じ色が続くセルをまとめて1つの印にする
    local x = 0
    while x <= maxx do
      local h = hr[x]
      if h then
        local x1 = x
        while x1 + 1 <= maxx and hr[x1 + 1] == h do x1 = x1 + 1 end
        local c0, c1 = B(x), B(x1 + 1)
        if c1 > c0 then marks[#marks + 1] = { y, c0, c1, h } end
        x = x1 + 1
      else
        x = x + 1
      end
    end
    local mr = self.maps[y]
    if mr then
      local list = {}
      for _, m in ipairs(mr) do
        list[#list + 1] = { B(m[1]), math.max(B(m[2]), B(m[1]) + 1), m[3] }
      end
      line_map[y + 1] = list
    end
  end
  return lines, marks, line_map
end

-- ------------------------------------------------------------
-- 見出し（上2行）
-- ------------------------------------------------------------
local HEADER_ROWS = 3 -- 見出し2行＋空行1行

local function short_path(p)
  if not p or p == "" then return "-" end
  local parts = vim.split(p, "/", { trimempty = true })
  if #parts <= 2 then return p end
  return "…/" .. parts[#parts - 1] .. "/" .. parts[#parts]
end

local function summary(state)
  local n = 0
  for id, a in pairs(state.agents or {}) do
    if id ~= "ROOT" and a.kind ~= "workflow" then n = n + 1 end
  end
  return n
end

local function draw_header(cv, state, view, mode)
  local root = M.agent(state, "ROOT")
  local st = M.display_status(state, "ROOT") or root.status or "PENDING"
  local now = view.now or os.time()
  local x = cv:put(0, 0, "AgentMap", "AgentMapHeader")
  x = cv:put(x, 0, "  run " .. H.short_id(state.run_id) .. " · " .. short_path(state.cwd) .. " · ")
  x = cv:put(x, 0, M.status_tag(st), M.STATUS_HL[st])
  x = cv:put(x, 0, " · " .. summary(state) .. " agents")
  local nw = M.waiting_count(state)
  if nw > 0 then x = cv:put(x, 0, tr("graph.h_waiting", { n = nw }), "AgentMapWaiting") end
  x = cv:put(x, 0, tr("graph.h_updated", { time = os.date("%H:%M:%S", now) }))
  if state.flow then
    -- 指示ごとの流れを見ているとき：何番目の指示か（セッションの中で）と、その本文
    x = cv:put(x, 0, tr("graph.h_prompt", { n = state.flow.n or 0, total = state.flow.total or 0 })
      .. H.truncate(H.oneline(state.flow.prompt_head or tr("common.no_prompt")), 30), "AgentMapHeader")
  end
  if view.root and view.root ~= "ROOT" then
    local a = M.agent(state, view.root)
    local lab = view.root == "UNKNOWN_PARENT" and "UNKNOWN_PARENT"
      or ((a and a.index) and ("[" .. a.index .. "] " .. (a.name or a.task or "")) or view.root)
    x = cv:put(x, 0, tr("graph.h_zoomed", { label = H.truncate(lab, 30) }), "AgentMapReview")
  end
  local legend = {
    { "[PENDING]", "AgentMapPending" }, { tr("graph.legend_grey") }, { "[RUNNING]", "AgentMapRunning" }, { tr("graph.legend_yellow") },
    { "[WAITING]", "AgentMapWaiting" }, { tr("graph.legend_purple") },
    { tr("graph.legend_paused"), "AgentMapPaused" }, { tr("graph.legend_orange") },
    { (tr("graph.legend_steer"):gsub("✎", M.steer_mark())), "AgentMapWaiting" }, { " " },
    { "[REVIEW]", "AgentMapReview" }, { tr("graph.legend_blue") },
    { "[DONE]", "AgentMapDone" }, { tr("graph.legend_green") },
    { "[REWORK]", "AgentMapRework" }, { "[FAILED]", "AgentMapFailed" }, { tr("graph.legend_red") },
  }
  if M.progress_opts(view).config.enabled ~= false then
    legend[#legend + 1] = { tr("graph.legend_est"), "AgentMapDim" }
    legend[#legend + 1] = { "   " }
  end
  legend[#legend + 1] = { tr("graph.legend_keys", { mode = mode == "box" and tr("graph.mode_map") or tr("graph.mode_list") }), "AgentMapDim" }
  -- 畳んだ箱があると子が図から消えて見えるので、開き方をここに出す（- を押したことに気づけるように）
  if next(view.collapsed or {}) then
    legend[#legend + 1] = { tr("graph.legend_collapsed"), "AgentMapReview" }
  end
  cv:put_segs(0, 1, legend)
end

-- ------------------------------------------------------------
-- 箱の図（左→右）
-- ------------------------------------------------------------
local function box_layout(state, view, forest, cfg)
  local BW = cfg.box_w + 2 -- 枠込みの幅
  local BH = (cfg.box_h or 4) + 2
  local GAP = cfg.col_gap
  local RG = cfg.row_gap or 1
  local SW, SH = 14, 3 -- START / END の小さい箱
  local HALF = math.floor(GAP / 2)
  local SEQ = "AgentMapEdgeSeq"
  local nodes, order, edges = {}, {}, {}

  local function small(t) return t.kind == "start" or t.kind == "end" end
  -- 枠の色（線を描くときに何度も使うので覚えておく）
  local function border_of(t)
    if not t._bhl then
      local _, bh = M.box_spec(t, state, view)
      t._bhl = bh or "AgentMapPending"
    end
    return t._bhl
  end
  local function has_stages(t) return t.stages and #t.stages > 0 end

  -- 次の段・親の合流線へ出る線が要るか（段の最後の Agent から次へつなぐため）
  local function mark_exit(t, needed)
    t.exit_needed = needed
    local n = #(t.stages or {})
    for k, st in ipairs(t.stages or {}) do
      for _, m in ipairs(st) do mark_exit(m, k < n or (needed and k == n)) end
    end
  end

  local function measure(t)
    t.bw, t.bh = BW, BH
    if small(t) then t.bw, t.bh = SW, SH end
    if not has_stages(t) then
      t.w = t.bw
      t.h = t.bh + ((t.kind == "gate" and t.info and t.info.retry_to) and 1 or 0)
      return
    end
    t.w, t.h = t.bw, t.bh
    for _, st in ipairs(t.stages) do
      local w, h = 0, 0
      for i, m in ipairs(st) do
        measure(m)
        w = math.max(w, m.w)
        h = h + m.h + (i > 1 and RG or 0)
      end
      st.w, st.h = w, h
      t.w = t.w + GAP + w
      t.h = math.max(t.h, h)
    end
    if t.exit_needed then t.w = t.w + GAP end -- 右端の合流線の置き場
  end

  local function place(t, x, top)
    t.x = x
    local off = t.bh == BH and 2 or 1
    if not has_stages(t) then
      t.y = top
      t.cy = t.y + off
      return
    end
    local cx = x + t.bw + GAP
    for _, st in ipairs(t.stages) do
      st.x0 = cx
      local cy = top
      for _, m in ipairs(st) do
        place(m, cx, cy)
        cy = cy + m.h + RG
      end
      st.x1 = cx + st.w
      cx = st.x1 + GAP
    end
    local s1 = t.stages[1]
    t.y = math.floor((s1[1].cy + s1[#s1].cy) / 2) - off
    t.y = math.max(top, math.min(t.y, top + t.h - t.bh))
    t.cy = t.y + off
    -- END は ROOT と同じ高さに置く
    local last = t.stages[#t.stages]
    if #last == 1 and last[1].kind == "end" then
      last[1].y = t.cy - 1
      last[1].cy = t.cy
    end
    if t.exit_needed then t.jx = t.x + t.w - GAP + HALF end
  end

  local top = HEADER_ROWS
  local placed = {}
  for i, root in ipairs(forest) do
    local r = root
    if i == 1 and root.id == "ROOT" and (view.root or "ROOT") == "ROOT" then
      r = { id = "START", kind = "start", stages = { { root } }, children = { root } }
    end
    mark_exit(r, false)
    measure(r)
    place(r, 0, top)
    placed[#placed + 1] = r
    top = top + r.h + RG + 1
  end

  local cv = Canvas.new()
  local width = 0
  local late = {}

  -- 光の通り道（DESIGN-v0.2 §3.2）：箱へ入る線のセルを親側 → ▶ の順に覚え、最後にバイト桁へ直す
  local paths_xy = {}
  local function lit(c) return c.kind == "agent" or c.kind == "check" end
  local function path_new(id)
    local pth = { cells = {}, seen = {} }
    paths_xy[id] = pth
    return pth
  end
  local function pc(pth, cx, cy)
    local k = cx .. ":" .. cy
    if not pth.seen[k] then
      pth.seen[k] = true
      pth.cells[#pth.cells + 1] = { cx, cy }
    end
  end
  local function ph(pth, cy, xa, xb)
    for cx = xa, xb, (xa <= xb and 1 or -1) do pc(pth, cx, cy) end
  end
  local function pv(pth, cx, ya, yb)
    for cy = ya, yb, (ya <= yb and 1 or -1) do pc(pth, cx, cy) end
  end

  local function exit_x(t)
    if has_stages(t) and t.jx then return t.jx end
    return t.x + t.bw
  end

  -- 箱から右へ出る線（葉なら右端に ├ を置く）
  local function out_line(m, to_x, hl)
    local ex = exit_x(m)
    local leaf = not (has_stages(m) and m.jx)
    -- 箱の右端の ├ は、箱を全部描いたあとに置く（あとから描く箱の枠で消えないように）
    if leaf then late[#late + 1] = { m.x + m.bw - 1, m.cy, border_of(m) } end
    cv:hline(m.cy, ex, to_x, hl, leaf, false)
  end

  local function draw_small(t)
    local x, y = t.x, t.y
    local spec, border = M.box_spec(t, state, view)
    cv:put(x, y, "┌" .. string.rep("─", SW - 2) .. "┐", border)
    -- 真ん中に寄せる
    local tw = 0
    for _, sg in ipairs(spec[1]) do tw = tw + H.dw(sg[1]) end
    local lp = math.max(0, math.floor((SW - 2 - tw) / 2))
    cv:put(x, y + 1, "│" .. string.rep(" ", lp), border)
    local ex = cv:put_segs(x + 1 + lp, y + 1, fit_segs(spec[1], SW - 2 - lp - 1))
    cv:put(ex, y + 1, " │", border)
    cv:put(x, y + 2, "└" .. string.rep("─", SW - 2) .. "┘", border)
    for r = y, y + SH - 1 do cv:map(r, x, x + SW, t.id) end
    nodes[t.id] = { id = t.id, kind = t.kind, x = x, y = y, w = SW, h = SH,
      status = t.kind == "start" and "DONE" or (t.status or "PENDING"), lines = M.box_lines_of(spec, SW - 4) }
  end

  local function draw(t)
    local x, y = t.x, t.y
    local gi
    if small(t) then
      draw_small(t)
    else
      local lines, border_hl
      lines, border_hl, gi = M.box_spec(t, state, view)
      cv:put(x, y, "┌" .. string.rep("─", BW - 2) .. "┐", border_hl)
      for i = 1, BH - 2 do
        local segs = fit_segs(lines[i] or {}, BW - 4)
        cv:put(x, y + i, "│ ", border_hl)
        local ex = cv:put_segs(x + 2, y + i, segs)
        cv:put(ex, y + i, " │", border_hl)
      end
      cv:put(x, y + BH - 1, "└" .. string.rep("─", BW - 2) .. "┘", border_hl)
      for r = y, y + BH - 1 do cv:map(r, x, x + BW, t.id) end
      local status = t.kind == "gate" and gi.status or (t.kind == "group" and "PENDING")
        or (t.kind == "check" and gi.status)
        or (M.agent(state, t.id).status or "PENDING")
      nodes[t.id] = {
        id = t.id, kind = t.kind, x = x, y = y, w = BW, h = BH, status = status,
        index = t.kind == "agent" and M.agent(state, t.id).index or nil,
        collapsed_count = t.collapsed_count, lines = M.box_lines_of(lines, BW - 4),
      }
    end
    order[#order + 1] = t.id
    width = math.max(width, x + t.bw)

    if has_stages(t) then
      -- 親 → 1 段目：親の右端 → 縦の幹 → 各子の左に ▶（子を起動した線）
      local s1 = t.stages[1]
      local seq1 = t.kind == "start" or (#s1 == 1 and s1[1].kind == "end")
      local hl1 = seq1 and SEQ or "AgentMapEdge"
      local bus = x + t.bw + HALF
      cv:put(x + t.bw - 1, t.cy, "├", border_of(t))
      cv:hline(t.cy, x + t.bw, bus, hl1, true, false)
      local ymin, ymax = t.cy, t.cy
      for _, c in ipairs(s1) do
        cv:hline(c.cy, bus, c.x - 2, hl1, false, true)
        cv:put(c.x - 1, c.cy, "▶", hl1)
        if t.kind ~= "start" and lit(c) then
          local pth = path_new(c.id)
          pc(pth, x + t.bw - 1, t.cy)
          ph(pth, t.cy, x + t.bw, bus)
          pv(pth, bus, t.cy, c.cy)
          ph(pth, c.cy, bus, c.x - 2)
          pc(pth, c.x - 1, c.cy)
        end
        ymin, ymax = math.min(ymin, c.cy), math.max(ymax, c.cy)
        edges[#edges + 1] = { from = t.id, to = c.id,
          kind = c.kind == "gate" and "gate" or c.kind == "check" and "check" or (seq1 and "seq" or "child") }
      end
      cv:vline(bus, ymin, ymax, hl1)
      -- k 段目 → k+1 段目：前の段の全員の出口 → 縦の幹 → 次の段の全員の左に ▶
      for k = 1, #t.stages - 1 do
        local a, b = t.stages[k], t.stages[k + 1]
        local sb = a.x1 + HALF
        local y0, y1 = math.huge, -math.huge
        for _, m in ipairs(a) do
          out_line(m, sb, SEQ)
          y0, y1 = math.min(y0, m.cy), math.max(y1, m.cy)
        end
        for _, n in ipairs(b) do
          cv:hline(n.cy, sb, n.x - 2, SEQ, false, true)
          cv:put(n.x - 1, n.cy, "▶", SEQ)
          if lit(n) then
            -- 前の段で一番近い箱（同じ距離なら上）の出口から
            local m
            for _, q in ipairs(a) do
              if not m or math.abs(q.cy - n.cy) < math.abs(m.cy - n.cy)
                or (math.abs(q.cy - n.cy) == math.abs(m.cy - n.cy) and q.cy < m.cy) then
                m = q
              end
            end
            local pth = path_new(n.id)
            if has_stages(m) and m.jx then
              ph(pth, m.cy, m.jx, sb)
            else
              pc(pth, m.x + m.bw - 1, m.cy)
              ph(pth, m.cy, m.x + m.bw, sb)
            end
            pv(pth, sb, m.cy, n.cy)
            ph(pth, n.cy, sb, n.x - 2)
            pc(pth, n.x - 1, n.cy)
          end
          y0, y1 = math.min(y0, n.cy), math.max(y1, n.cy)
          for _, m in ipairs(a) do
            edges[#edges + 1] = { from = m.id, to = n.id, kind = n.kind == "gate" and "gate" or "seq" }
          end
        end
        cv:vline(sb, y0, y1, SEQ)
      end
      -- 合流線：最後の段の全員 → 自分の行へ戻って、親の次の段へ
      if t.jx then
        local y0, y1 = t.cy, t.cy
        for _, q in ipairs(t.stages[#t.stages]) do
          out_line(q, t.jx, SEQ)
          y0, y1 = math.min(y0, q.cy), math.max(y1, q.cy)
        end
        cv:vline(t.jx, y0, y1, SEQ)
      end
    end
    -- 差し戻しの線：門の下に「└─ retry ─▶ [k]」
    if t.kind == "gate" and gi and gi.retry_to then
      local target = state.agents[gi.retry_to]
      cv:put(x + 3, y + BH - 1, "┬", "AgentMapEdgeRetry")
      local ex = cv:put(x + 3, y + BH, "└─ retry ─▶ ", "AgentMapEdgeRetry")
      ex = cv:put(ex, y + BH, "[" .. (target.index or "?") .. "]", "AgentMapIndex")
      width = math.max(width, ex)
      edges[#edges + 1] = { from = t.id, to = gi.retry_to, kind = "retry", label = "retry" }
    elseif t.kind == "gate" and gi and gi.escalate_to then
      edges[#edges + 1] = { from = t.id, to = gi.escalate_to, kind = "retry", label = "escalate" }
    end
    for _, st in ipairs(t.stages or {}) do
      for _, c in ipairs(st) do draw(c) end
    end
  end
  for _, r in ipairs(placed) do draw(r) end
  for _, e in ipairs(late) do cv:put(e[1], e[2], "├", e[3]) end

  draw_header(cv, state, view, "box")
  local lines, marks, line_map = cv:finish()
  local paths = {}
  for id, pth in pairs(paths_xy) do
    local list = {}
    for _, c in ipairs(pth.cells) do
      local cb = cv.colbyte[c[2]]
      local b0, b1 = cb and cb[c[1]], cb and cb[c[1] + 1]
      if b0 and b1 and b1 > b0 and b1 <= #(lines[c[2] + 1] or "") then list[#list + 1] = { c[2], b0, b1 } end
    end
    if #list > 0 then paths[id] = list end
  end
  return {
    mode = "box", width = width, height = #lines, nodes = nodes, edges = edges, order = order,
    lines = lines, marks = marks, line_map = line_map, paths = paths,
  }
end

--- Fit box content lines into width `w` as plain strings.
function M.box_lines_of(spec_lines, w)
  local out = {}
  for i = 1, #spec_lines do
    local parts = {}
    for _, s in ipairs(fit_segs(spec_lines[i], w)) do parts[#parts + 1] = s[1] end
    out[i] = table.concat(parts)
  end
  return out
end

-- ------------------------------------------------------------
-- 木の一覧（幅が足りないとき／v で切替）
-- ------------------------------------------------------------
local function tree_segs(t, state, view)
  if t.kind == "stage" then
    return { { tr("graph.stage", { k = t.k }), "AgentMapHeader" }, { tr("graph.stage_count", { n = t.n }), "AgentMapDim" } }
  end
  if t.kind == "end" then
    local st = t.status or "PENDING"
    return { { "END", "AgentMapHeader" }, { "  " }, { M.status_tag(st), M.STATUS_HL[st] } }
  end
  if t.kind == "group" then
    return { { "UNKNOWN_PARENT", "AgentMapHeader" }, { tr("graph.group_tree", { n = t.count or 0 }), "AgentMapDim" } }
  end
  if t.kind == "check" then
    local ci = t.info or M.check_info(state, t.check or {}, view and view.now)
    local segs = { { "HUMAN CHECK" .. (ci.n and (" #" .. ci.n) or "") .. "  ", "AgentMapHeader" }, { ci.tag, ci.hl } }
    if ci.status == "ANSWERED" then
      segs[#segs + 1] = { " → " .. (ci.answer or tr("common.no_answer")), "AgentMapDone" }
    elseif ci.status == "ABANDONED" then
      segs[#segs + 1] = { "  " .. tr("graph.ended_unanswered"), "AgentMapDim" }
    end
    segs[#segs + 1] = { "  " .. tr("common.quote", { text = H.truncate(ci.question_short or ci.question or tr("common.no_question"), 40) }), "AgentMapDim" }
    return segs
  end
  if t.kind == "gate" then
    local a = M.agent(state, t.agent_id) or {}
    local gi = t.info or M.gate_info(state, a)
    local segs = { { "◇ Review #" .. gi.n .. " " }, { gi.tag, M.STATUS_HL[gi.status] } }
    if gi.attempt.decided_by then segs[#segs + 1] = { " by " .. gi.attempt.decided_by, "AgentMapDim" } end
    if gi.retry_to then
      segs[#segs + 1] = { " → retry ", "AgentMapEdgeRetry" }
      segs[#segs + 1] = { "[" .. (state.agents[gi.retry_to].index or "?") .. "]", "AgentMapIndex" }
    elseif gi.verdict == "RETRY" then
      segs[#segs + 1] = { " " .. tr("graph.rerun_same"), "AgentMapEdgeRetry" }
    end
    return segs
  end
  local a = M.agent(state, t.id)
  local segs = {}
  if a.kind == "workflow" then
    segs[#segs + 1] = { "Workflow " .. tostring(a.wf_id or ""):gsub("^wf_", ""):sub(1, 8), "AgentMapHeader" }
    segs[#segs + 1] = { "  " .. (a.wf_name or "workflow") .. "  " }
  elseif t.id == "ROOT" then
    segs[#segs + 1] = { "ROOT", "AgentMapHeader" }
    segs[#segs + 1] = { "  " .. model_text(a) .. "  " }
  else
    if a.index then segs[#segs + 1] = { "[" .. a.index .. "]", "AgentMapIndex" } end
    if a.worktree then segs[#segs + 1] = { " ⌂", "AgentMapReview" } end
    segs[#segs + 1] = { " " .. H.truncate(a.name or a.task or H.short_id(a.id), 28) }
    segs[#segs + 1] = { "  " .. model_text(a) .. "  " }
  end
  for _, s in ipairs(status_segs(state, a, view)) do segs[#segs + 1] = s end
  for _, s in ipairs(M.check_marks(state, a)) do segs[#segs + 1] = s end
  for _, s in ipairs(M.steer_marks(state, a, view and view.now)) do segs[#segs + 1] = s end
  if t.collapsed_count then segs[#segs + 1] = { " [+" .. t.collapsed_count .. "]", "AgentMapIndex" } end
  -- 木の一覧では止まれの印は札と印の並びの最後（DESIGN-v0.1.2-pause §6.3 の「行末」。
  -- 本当の行末は長い task の後ろで幅に切られて見えなくなるので、薄い task の文の手前に置く）
  for _, s in ipairs(M.pause_marks(state, a)) do segs[#segs + 1] = s end
  if t.id == "ROOT" and state.title then segs[#segs + 1] = { "   " .. state.title, "AgentMapDim" } end
  if t.id ~= "ROOT" and a.task and a.task ~= a.name then
    segs[#segs + 1] = { "   " .. a.task, "AgentMapDim" }
  end
  return segs
end

-- 幅 w を超えたぶんを切る
local function clip_segs(segs, w)
  local out, used = {}, 0
  for _, s in ipairs(segs) do
    local t = s[1] or ""
    if used >= w then break end
    if used + H.dw(t) > w then t = H.truncate(t, w - used) end
    out[#out + 1] = { t, s[2] }
    used = used + H.dw(t)
  end
  return out
end

-- 木の一覧での子の並び：Agent のいる段が 2 つ以上なら「段k」の見出しを挟む。END は子に入れない
local function tree_kids(t)
  if t.kind == "stage" then return t.children end
  local out = {}
  local multi = agent_stage_count(t) >= 2
  local k = 0
  for _, st in ipairs(t.stages or {}) do
    local members = {}
    local has_agent = false
    for _, m in ipairs(st) do
      if m.kind ~= "end" then members[#members + 1] = m end
      if m.kind == "agent" then has_agent = true end
    end
    if multi and has_agent then
      k = k + 1
      out[#out + 1] = { id = "stage:" .. t.id .. ":" .. k, kind = "stage", k = k, n = #members, children = members }
    else
      for _, m in ipairs(members) do out[#out + 1] = m end
    end
  end
  if not t.stages then return t.children or {} end
  return out
end

local function tree_layout(state, view, forest, width)
  local cv = Canvas.new()
  local nodes, order, edges = {}, {}, {}
  local y = HEADER_ROWS
  local maxw = 0
  local function walk(t, prefix, is_last, is_root)
    local head = is_root and "" or (prefix .. (is_last and "└─ " or "├─ "))
    local x = cv:put(0, y, head, "AgentMapEdge")
    local segs = clip_segs(tree_segs(t, state, view), math.max(10, width - H.dw(head)))
    local ex = cv:put_segs(x, y, segs)
    maxw = math.max(maxw, ex)
    cv:map(y, x, math.max(ex, x + 1), t.id)
    local status = (t.kind == "gate" or t.kind == "check") and t.info.status
      or ((t.kind == "group" or t.kind == "stage") and "PENDING")
      or (t.kind == "end" and (t.status or "PENDING"))
      or (M.agent(state, t.id).status or "PENDING")
    nodes[t.id] = { id = t.id, kind = t.kind, x = x, y = y, w = ex - x, h = 1, status = status,
      collapsed_count = t.collapsed_count }
    order[#order + 1] = t.id
    y = y + 1
    local child_prefix = is_root and "" or (prefix .. (is_last and "   " or "│  "))
    local kids = tree_kids(t)
    for i, c in ipairs(kids) do
      if c.kind ~= "stage" then
        edges[#edges + 1] = { from = t.id, to = c.id,
          kind = c.kind == "gate" and "gate" or c.kind == "check" and "check" or "child" }
      end
      walk(c, child_prefix, i == #kids, false)
    end
  end
  local end_node
  for _, root in ipairs(forest) do
    walk(root, "", true, true)
    if root.id == "ROOT" then
      local last = root.stages and root.stages[#root.stages]
      if last and #last == 1 and last[1].kind == "end" then end_node = last[1] end
      -- END は ROOT の木のすぐ下に、字下げなしで 1 行
      if end_node then walk(end_node, "", true, true) end
    end
  end
  draw_header(cv, state, view, "tree")
  local lines, marks, line_map = cv:finish()
  return {
    mode = "tree", width = maxw, height = #lines, nodes = nodes, edges = edges, order = order,
    lines = lines, marks = marks, line_map = line_map, paths = {},
  }
end

--- Lines of the list (tree) view only.
-- DESIGN §11 の公開関数：木の一覧だけを作る
function M.tree_lines(state, view)
  view = view or {}
  local L = tree_layout(state, view, M.visible(state, view), view.width or 120)
  return { lines = L.lines, marks = L.marks, line_map = L.line_map }
end

-- ------------------------------------------------------------
-- 入口
-- view = { root = "ROOT"|id, collapsed = {id=true}, mode = "box"|"tree"|"auto", width = 列数, now = 秒,
--          stats = stats.load() の結果, progress = config.progress }
-- 戻り値の paths（box だけ）= { [id] = { {row0, byte0, byte1}, … } }：その箱へ入る線のセル（親側 → ▶）
-- ------------------------------------------------------------
--- Lay out the map (box or tree view): lines, highlights, and the cursor-to-id tables.
function M.layout(state, view)
  state = state or {}
  state.agents = state.agents or {}
  view = view or {}
  local cfg = H.config()
  ensure_highlights()
  local mode = view.mode or cfg.mode or "auto"
  local width = view.width or 120
  local forest = M.visible(state, view)
  if mode ~= "tree" then
    local L = box_layout(state, view, forest, cfg)
    if mode == "box" or L.width <= width then return L end
  end
  return tree_layout(state, view, forest, width)
end

return M
