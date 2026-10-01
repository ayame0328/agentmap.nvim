-- ============================================================
--  agentmap/export.lua ... write a run as a document (:AgentMapExport markdown|html|pdf).
--    Markdown: overview, map (Mermaid + text tree), agents, reviews, human checks,
--              final outputs, changed files, tool counts.
--    HTML:     the same Markdown through export.html_command (if set) or the
--              bundled agentmap.md converter (single file, no external resources).
--    PDF:      the HTML through the user's export.pdf_command (argv with
--              %{html} %{out} %{title}); without it PDF export is disabled.
--    Wording comes from lang/<lang>/export.lua (English by default).
--    Only the state table is read, so hand-made states can be exported in tests.
-- ============================================================
local M = {}

local i18n = require("agentmap.i18n")
local function tr(key, vars) return i18n.t(key, vars) end

local function notify(msg, lvl)
  vim.notify("AgentMap: " .. msg, lvl or vim.log.levels.INFO)
end

local function try(name)
  local ok, m = pcall(require, name)
  if ok then return m end
end

-- ------------------------------------------------------------
-- 小さな道具
-- ------------------------------------------------------------
local function one_line(s)
  return (tostring(s or ""):gsub("[\r\n\t]+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function cut(s, n)
  s = one_line(s)
  if vim.fn.strchars(s) <= n then return s end
  return vim.fn.strcharpart(s, 0, n - 1) .. "…"
end

--- 表のマスに入れられる形にする（| と改行を消す）
local function cell(s)
  s = one_line(s)
  if s == "" then return "-" end
  return (s:gsub("|", "\\|"))
end

--- ISO 形式の日時 → 秒（UTC）
local function parse_iso(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, se = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  local t = { year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(se), isdst = false }
  local now = os.time()
  local offset = os.difftime(now, os.time(os.date("!*t", now)))
  return os.time(t) + offset
end

local function fmt_dt(iso)
  local t = parse_iso(iso)
  return t and os.date("%Y-%m-%d %H:%M:%S", t) or "-"
end

local function fmt_clock(iso)
  local t = parse_iso(iso)
  return t and os.date("%H:%M", t) or "?"
end

local function fmt_elapsed(ms)
  if not ms or ms < 0 then return "-" end
  local s = math.floor(ms / 1000)
  local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
  if h > 0 then return ("%d:%02d:%02d"):format(h, m, s % 60) end
  return ("%d:%02d"):format(m, s % 60)
end

local function elapsed_ms(a)
  if not a then return nil end
  if a.elapsed_ms then return a.elapsed_ms end
  local s = parse_iso(a.started_at)
  if not s then return nil end
  local e = parse_iso(a.finished_at)
  if not e and (a.status == "RUNNING" or a.status == "REVIEW") then e = os.time() end
  if not e then return nil end
  return (e - s) * 1000
end

local function short(id)
  id = tostring(id or "")
  return id:sub(1, 8)
end

local function model_short(m)
  if not m or m == "" then return nil end
  local claude = try("agentmap.providers.claude")
  if claude and type(claude.model_short) == "function" then
    local ok, r = pcall(claude.model_short, m)
    if ok and r then return r end
  end
  return (m:gsub("^claude%-", ""):gsub("%-%d%d%d%d%d%d%d%d$", ""))
end

local function win_path(p, force)
  local util = try("agentmap.util")
  if util and type(util.win_path) == "function" then
    local ok, r = pcall(util.win_path, p, force)
    if ok then return r end
  end
  local d, rest = p:match("^/mnt/(%a)/(.*)$")
  if d then return d:upper() .. ":\\" .. rest:gsub("/", "\\") end
  local distro = vim.env.WSL_DISTRO_NAME
  if distro and p:sub(1, 1) == "/" then
    return "\\\\wsl.localhost\\" .. distro .. p:gsub("/", "\\")
  end
  return nil
end

-- ------------------------------------------------------------
-- state の読み方（A の state.lua に頼らず、§4 の形だけを見る）
-- ------------------------------------------------------------
local function wf_short(a)
  return (tostring(a.wf_id or a.id or ""):gsub("^wf:", ""):gsub("^wf_", ""):sub(1, 8))
end

local function agent_label(s, id)
  if id == "ROOT" then return "ROOT" end
  local a = s.agents[id]
  if a and a.kind == "workflow" then return "WF " .. wf_short(a) end
  if a and a.index then return "[" .. a.index .. "]" end
  return "[?]"
end

local function name_of(a)
  if a.id == "ROOT" then return "ROOT" end
  if a.kind == "workflow" then return "Workflow " .. wf_short(a) .. (a.wf_name and (" " .. a.wf_name) or "") end
  local n = a.name or a.task or a.agent_type
  if not n or n == "" then n = short(a.id) end
  return one_line(n)
end

local function status_tag(a)
  return "[" .. tostring(a.status or "PENDING") .. "]"
end

--- 客観的な進み具合：子の数のうち終わった数（子が無ければ nil）
local function progress(s, id)
  local kids = (s._kids or {})[id]
  if not kids or #kids == 0 then return nil end
  local done = 0
  for _, k in ipairs(kids) do
    if s.agents[k] and s.agents[k].status == "DONE" then done = done + 1 end
  end
  return ("~%d%%"):format(math.floor(100 * done / #kids))
end

--- 親子の並びを作る：kids[親] = { 子… }（番号順）と、親が分からないもの
local function index_tree(s)
  local pos = {}
  for i, id in ipairs(s.order or {}) do pos[id] = i end
  local ids = {}
  for id in pairs(s.agents or {}) do
    if id ~= "ROOT" and id ~= "UNKNOWN_PARENT" then ids[#ids + 1] = id end
  end
  table.sort(ids, function(x, y)
    local ax, ay = s.agents[x], s.agents[y]
    local ix, iy = ax.index or math.huge, ay.index or math.huge
    if ix ~= iy then return ix < iy end
    local px, py = pos[x] or math.huge, pos[y] or math.huge
    if px ~= py then return px < py end
    return x < y
  end)
  local kids, unknown = {}, {}
  for _, id in ipairs(ids) do
    local p = s.agents[id].parent_id
    if p and p ~= "UNKNOWN_PARENT" and (p == "ROOT" or s.agents[p]) and p ~= id then
      kids[p] = kids[p] or {}
      table.insert(kids[p], id)
    else
      unknown[#unknown + 1] = id
    end
  end
  return kids, unknown, ids
end

--- 木の順番（親 → 子）に { id, depth } を並べる。輪になっていても止まる
local function walk(s, root, fn, seen)
  seen = seen or {}
  local function go(id, depth)
    if seen[id] then return end
    seen[id] = true
    fn(id, depth)
    for _, k in ipairs(s._kids[id] or {}) do go(k, depth + 1) end
  end
  go(root, 0)
  return seen
end

local util_mod = try("agentmap.util")
--- 時刻の順に並べるための秒（util があれば stages と同じ物差しを使う）
local function secs(iso)
  if util_mod and type(util_mod.parse_iso) == "function" then return util_mod.parse_iso(iso) end
  return parse_iso(iso)
end

--- 同じ親の子を、時刻から決めた「段」に分ける（stages.lua）。読めなければ 1 段にまとめる
local stages_mod = try("agentmap.stages")
local function stages_of(s, kids, checks)
  kids, checks = kids or {}, checks or {}
  if #kids == 0 and #checks == 0 then return {} end
  if #checks == 0 then
    if stages_mod then
      local ok, r = pcall(stages_mod.of, s, kids)
      if ok and type(r) == "table" then return r end
    end
    return { kids }
  end
  -- 直接聞いた check を時刻付きの要素として子に混ぜる（設計書 §5.1）。
  -- stages.of が "check:" を受けるかは担当 A の作業次第なので、要素はここで作って split だけ借りる
  if stages_mod and type(stages_mod.item) == "function" and type(stages_mod.split) == "function" then
    local ok, r = pcall(function()
      local items = {}
      for _, k in ipairs(kids) do
        local it = stages_mod.item(s.agents[k] or { id = k })
        it.id = k
        items[#items + 1] = it
      end
      for _, cid in ipairs(checks) do
        local c = s.checks[cid]
        items[#items + 1] = { id = cid, st = secs(c.asked_at), fin = secs(c.answered_at or c.ended_at),
          open = c.status == "WAITING" }
      end
      return stages_mod.split(items)
    end)
    if ok and type(r) == "table" then return r end
  end
  local all = vim.list_extend(vim.list_extend({}, kids), checks)
  return { all }
end

--- 流れ全体が終わったか（END の状態）
local function end_status(state)
  if not state.ended_at then return "PENDING" end
  for id, a in pairs(state.agents or {}) do
    local st = a.status or "PENDING"
    if id ~= "ROOT" and a.kind ~= "workflow" and (st == "PENDING" or st == "RUNNING" or st == "REVIEW") then
      return "PENDING"
    end
  end
  return "DONE"
end

-- ------------------------------------------------------------
-- HUMAN CHECK（AskUserQuestion の記録。設計書 §3.2 の形だけを見る）
--   graph.lua（担当 B）の CHECK_TAG 等には頼らず、ここで完結させる（書き出しは state だけ読むのが決まり）
-- ------------------------------------------------------------
local brief = require("agentmap.brief")

M.CHECK_TAG = { WAITING = "WAITING", ANSWERED = "DONE", ABANDONED = "UNANSWERED" }
local CHECK_CLASS = { WAITING = "waiting", ANSWERED = "done", ABANDONED = "pending" }
-- 終わった理由・結び付けた理由のコード → 文言のキー（記録はコードのまま。表示だけ訳す）
local CHECK_END = {
  turn_ended = "export.end_turn_ended",
  new_prompt = "export.end_new_prompt",
  session_ended = "export.end_session_ended",
  tool_failed = "export.end_tool_failed",
}
local LINK_SOURCE = {
  name = "export.link_name",
  report = "export.link_report",
  report_late = "export.link_report_late",
}

local function is_check(id)
  return type(id) == "string" and id:sub(1, 6) == "check:"
end

local function check_tag(c)
  return "[" .. (M.CHECK_TAG[c.status] or tostring(c.status or "WAITING")) .. "]"
end

--- check の通し番号：state が振った n、無ければ check_order の位置
local function check_n(s, c)
  if c.n then return c.n end
  for i, cid in ipairs(s.check_order or {}) do
    if cid == c.id then return i end
  end
  return "?"
end

local function first_question(c)
  local q = (c.questions or {})[1] or {}
  local text = one_line(q.question or "")
  if q.header and q.header ~= "" and not text:find(one_line(q.header), 1, true) then
    text = one_line(q.header) .. ": " .. text
  end
  return text
end

--- 答えの要約："A" / "A, B" / 自由入力は先頭 30 字。答えが無ければ nil
local function answer_summary(c)
  local parts = {}
  for _, e in ipairs(brief.answered_options(c)) do
    for _, m in ipairs(e.matches or {}) do
      parts[#parts + 1] = m.option and one_line(m.label) or cut(m.label, 30)
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, ", ")
end

--- check の一覧を出てきた順に（check_order にあるもの → 残りを asked_at 順）
local function check_ids(state)
  local checks = state.checks or {}
  local out, seen = {}, {}
  for _, cid in ipairs(state.check_order or {}) do
    if checks[cid] and not seen[cid] then
      seen[cid] = true
      out[#out + 1] = cid
    end
  end
  local rest = {}
  for cid in pairs(checks) do
    if not seen[cid] then rest[#rest + 1] = cid end
  end
  table.sort(rest, function(x, y)
    local ax, ay = secs(checks[x].asked_at) or math.huge, secs(checks[y].asked_at) or math.huge
    if ax ~= ay then return ax < ay end
    return x < y
  end)
  vim.list_extend(out, rest)
  return out
end

--- s._checks[id] = { direct = {cid…}, linked = {cid…} } を作る（設計書 §10）
--   linked：子の要確認から生まれた check（その子の後ろに付く）
--   direct：聞いた側が直接聞いた check（owner の子の段分けに時刻付きで混ざる）
local function index_checks(s)
  local by = {}
  local function slot(id)
    by[id] = by[id] or { direct = {}, linked = {} }
    return by[id]
  end
  for _, cid in ipairs(s._check_ids) do
    local c = s.checks[cid]
    if c.agent_id and s.agents[c.agent_id] then
      table.insert(slot(c.agent_id).linked, cid)
    else
      local owner = c.owner_id or c.asker_id or "ROOT"
      if owner ~= "ROOT" and not s.agents[owner] then owner = "ROOT" end
      table.insert(slot(owner).direct, cid)
    end
  end
  local function by_time(list)
    local pos = {}
    for i, cid in ipairs(list) do pos[cid] = i end
    table.sort(list, function(x, y)
      local ax, ay = secs(s.checks[x].asked_at) or math.huge, secs(s.checks[y].asked_at) or math.huge
      if ax ~= ay then return ax < ay end
      return pos[x] < pos[y]
    end)
  end
  for _, v in pairs(by) do
    by_time(v.direct)
    by_time(v.linked)
  end
  return by
end

local function prepare(state)
  local s = setmetatable({}, { __index = state })
  s.agents = state.agents or {}
  s.checks = state.checks or {}
  s._check_ids = check_ids(state)
  s._checks = index_checks(s)
  s._kids, s._unknown, s._ids = index_tree(s)
  -- 輪になっていて ROOT から辿れないものも、親不明の側に入れて必ず載せる
  local reached = walk(s, "ROOT", function() end)
  for _, u in ipairs(s._unknown) do
    for id in pairs(walk(s, u, function() end)) do reached[id] = true end
  end
  for _, id in ipairs(s._ids) do
    if not reached[id] then
      s._unknown[#s._unknown + 1] = id
      reached[id] = true
    end
  end
  return s
end

local function gates_of(a)
  local out = {}
  for i, at in ipairs(a.attempts or {}) do
    if at.verdict or at.submitted_at then
      out[#out + 1] = { n = at.n or i, at = at }
    end
  end
  if #out == 0 and (a.status == "REVIEW" or a.status == "REWORK") then
    local n = a.attempt or #(a.attempts or {})
    if n == 0 then n = 1 end
    out[1] = { n = n, at = (a.attempts or {})[n] or {} }
  end
  return out
end

local function verdict_of(g, a)
  return g.at.verdict or (a.status == "REWORK" and "RETRY") or "REVIEW"
end

-- ------------------------------------------------------------
-- Mermaid
-- ------------------------------------------------------------

--- Mermaid node id: `prefix` + id with every non-alphanumeric character replaced by "_".
function M.mermaid_id(prefix, id)
  return (prefix .. tostring(id):gsub("[^%w]", "_"))
end

--- Make text safe inside a Mermaid label (" [ ] { } < > | ` # become entity codes).
function M.mermaid_text(s)
  s = one_line(s)
  s = s:gsub("#", "#35;")
  s = s:gsub('"', "#quot;"):gsub("%[", "#91;"):gsub("%]", "#93;")
  s = s:gsub("{", "#123;"):gsub("}", "#125;"):gsub("<", "#lt;"):gsub(">", "#gt;")
  s = s:gsub("|", "#124;"):gsub("`", "#96;")
  return s
end

local CLASS = {
  DONE = "done", RUNNING = "running", REVIEW = "review",
  REWORK = "rework", FAILED = "failed", PENDING = "pending",
  PASS = "done", RETRY = "rework", ESCALATE = "review",
}

--- The map as a Mermaid flowchart (without the ```mermaid fence).
---@param state table
---@param s? table prepared state (internal; omit)
---@return string
function M.mermaid(state, s)
  s = s or prepare(state)
  local lines = { "flowchart LR" }
  local ids, used = {}, {}
  local function nid(id, prefix)
    local key = (prefix or "n_") .. "\0" .. id
    if ids[key] then return ids[key] end
    local base = M.mermaid_id(prefix or "n_", id)
    local x, n = base, 1
    while used[x] do
      n = n + 1
      x = base .. "_" .. n
    end
    used[x] = true
    ids[key] = x
    return x
  end
  local nodes, edges, classes = {}, {}, {}
  local function label(parts)
    local out = {}
    for _, p in ipairs(parts) do
      if p and p ~= "" then out[#out + 1] = M.mermaid_text(p) end
    end
    return table.concat(out, "<br/>")
  end
  local function add_agent(id)
    local a = s.agents[id] or { id = id, status = "RUNNING" }
    local me = nid(id)
    local l1, l2, l3
    if id == "ROOT" then
      l1 = "ROOT " .. short(state.run_id)
      l2 = (model_short(a.model) or "model: ?") .. " · main"
      l3 = state.title and cut(state.title, 40) or nil
    else
      l1 = agent_label(s, id) .. " " .. cut(name_of(a), 30)
      l2 = (model_short(a.model) or "model: ?") .. (a.agent_type and (" · " .. a.agent_type) or "")
      l3 = nil
    end
    local st = tostring(a.status or "PENDING")
    local p = progress(s, id)
    nodes[#nodes + 1] = ("  %s[\"%s\"]"):format(me, label({ l1, l2, l3 or "", st .. (p and (" " .. p) or "") }))
    classes[#classes + 1] = { me, CLASS[st] or "pending" }
    return me
  end

  -- HUMAN CHECK の箱。名前は c_<tool_use_id>（n_ の Agent と混ざらない）
  local function ref(id)
    if is_check(id) then
      local c = s.checks[id] or {}
      return nid(c.tool_use_id or id:sub(7), "c_")
    end
    return nid(id)
  end
  local function add_check(cid)
    local c = s.checks[cid]
    local me = ref(cid)
    local ans = c.status == "ANSWERED" and answer_summary(c) or nil
    nodes[#nodes + 1] = ("  %s[\"%s\"]"):format(me, label({
      "HUMAN CHECK #" .. tostring(check_n(s, c)),
      M.CHECK_TAG[c.status] or tostring(c.status or "WAITING"),
      cut(first_question(c), 40),
      ans and ("→ " .. cut(ans, 30)) or "",
    }))
    classes[#classes + 1] = { me, CHECK_CLASS[c.status] or "pending" }
    return me
  end

  -- 親 → 1 段目は「起動した線」（-->）、段 → 次の段は「順番の線」（==>）。
  -- 段が 2 つ以上ある親は、段ごとに subgraph で囲む（入れ子もそのまま）
  -- 直接聞いた check は段の要素として混ざり、子の要確認から生まれた check は子の後ろ（-->）に付く
  local drawn = {}
  local function tree(id)
    if drawn[id] then return {} end
    drawn[id] = true
    if is_check(id) then
      add_check(id)
      return {}
    end
    local me = add_agent(id)
    local kids = {}
    for _, k in ipairs(s._kids[id] or {}) do
      if not drawn[k] then kids[#kids + 1] = k end
    end
    local own = s._checks[id] or {}
    local stages = stages_of(s, kids, own.direct)
    for k, st in ipairs(stages) do
      if #stages >= 2 then
        nodes[#nodes + 1] = ('  subgraph %s["%s"]'):format(nid(id .. "_" .. k, "s_"),
          M.mermaid_text(tr("export.stage", { k = k })))
      end
      for _, c in ipairs(st) do
        if k == 1 then
          edges[#edges + 1] = ("  %s --> %s"):format(me, ref(c))
        else
          for _, p in ipairs(stages[k - 1]) do
            edges[#edges + 1] = ("  %s ==> %s"):format(ref(p), ref(c))
          end
        end
        tree(c)
      end
      if #stages >= 2 then nodes[#nodes + 1] = "  end" end
    end
    for _, cid in ipairs(own.linked or {}) do
      if not drawn[cid] then
        drawn[cid] = true
        edges[#edges + 1] = ("  %s --> %s"):format(me, add_check(cid))
      end
    end
    return stages
  end
  local n_start, n_end = nid("START"), nid("END")
  nodes[#nodes + 1] = ('  %s["START"]'):format(n_start)
  classes[#classes + 1] = { n_start, "done" }
  local es = end_status(state)
  local root_stages = tree("ROOT")
  nodes[#nodes + 1] = ('  %s["END<br/>%s"]'):format(n_end, es)
  classes[#classes + 1] = { n_end, es == "DONE" and "done" or "pending" }
  table.insert(edges, 1, ("  %s ==> %s"):format(n_start, nid("ROOT")))
  local last = root_stages[#root_stages]
  for _, p in ipairs(last or { "ROOT" }) do
    edges[#edges + 1] = ("  %s ==> %s"):format(ref(p), n_end)
  end
  if #s._unknown > 0 then
    local u = nid("UNKNOWN_PARENT")
    nodes[#nodes + 1] = ("  %s[\"%s\"]"):format(u, "UNKNOWN_PARENT")
    classes[#classes + 1] = { u, "pending" }
    for _, id in ipairs(s._unknown) do
      if not drawn[id] then
        edges[#edges + 1] = ("  %s -.-> %s"):format(u, nid(id))
        tree(id)
      end
    end
  end

  -- レビューの関所（gate）
  for _, id in ipairs(s._ids) do
    local a = s.agents[id]
    for _, g in ipairs(gates_of(a)) do
      local v = verdict_of(g, a)
      local gid = nid(id .. "_" .. g.n, "g_")
      nodes[#nodes + 1] = ("  %s{{\"%s\"}}"):format(gid,
        label({ "Review #" .. g.n, v .. (g.at.decided_by and (" by " .. g.at.decided_by) or "") }))
      classes[#classes + 1] = { gid, CLASS[v] or "review" }
      edges[#edges + 1] = ("  %s --> %s"):format(nid(id), gid)
      if v == "RETRY" then
        local target = g.at.retried_by
        if target and s.agents[target] then
          edges[#edges + 1] = ("  %s -->|RETRY| %s"):format(gid, nid(target))
        else
          edges[#edges + 1] = ("  %s -->|RETRY| %s"):format(gid, nid(id))
        end
      elseif v == "ESCALATE" then
        local target = a.escalated_to or a.parent_id
        if target and (target == "ROOT" or s.agents[target]) then
          edges[#edges + 1] = ("  %s -->|ESCALATE| %s"):format(gid, nid(target))
        end
      end
    end
  end

  vim.list_extend(lines, nodes)
  vim.list_extend(lines, edges)
  vim.list_extend(lines, {
    "  classDef done fill:#d3f5da,stroke:#3fb950,color:#000",
    "  classDef running fill:#fff4c2,stroke:#e3b341,color:#000",
    "  classDef review fill:#dbeafe,stroke:#58a6ff,color:#000",
    "  classDef rework fill:#ffe0de,stroke:#f85149,color:#000",
    "  classDef failed fill:#ffd0cc,stroke:#f85149,stroke-width:3px,color:#000",
    "  classDef pending fill:#eeeeee,stroke:#8b949e,color:#000",
    "  classDef waiting fill:#efe3ff,stroke:#b083f0,color:#000",
  })
  for _, c in ipairs(classes) do
    lines[#lines + 1] = ("  class %s %s"):format(c[1], c[2])
  end
  return table.concat(lines, "\n")
end

-- ------------------------------------------------------------
-- 文字の木（色なし。DESIGN §6.3 と同じ見た目）
-- ------------------------------------------------------------
local function gate_summary(s, a)
  local out = {}
  for _, g in ipairs(gates_of(a)) do
    local v = verdict_of(g, a)
    local t = "Review #" .. g.n .. " [" .. v .. "]"
    if g.at.retried_by and s.agents[g.at.retried_by] then
      t = t .. " → " .. agent_label(s, g.at.retried_by)
    end
    out[#out + 1] = t
  end
  if #out == 0 then return "" end
  return "   ├ " .. table.concat(out, " / ")
end

--- The map as a plain text tree (fallback for viewers without Mermaid).
---@param state table
---@param s? table prepared state (internal; omit)
---@return string
function M.text_tree(state, s)
  s = s or prepare(state)
  local lines = {}
  local function node_text(id)
    local a = s.agents[id] or { id = id, status = "RUNNING" }
    local p = progress(s, id)
    local parts
    if id == "ROOT" then
      parts = { "ROOT", model_short(a.model) or "model: ?", status_tag(a) .. (p and (" " .. p) or ""),
        state.title and cut(state.title, 50) or "" }
    else
      local el = elapsed_ms(a)
      parts = { agent_label(s, id) .. " " .. cut(name_of(a), 30), model_short(a.model) or "model: ?",
        status_tag(a) .. (p and (" " .. p) or ""), el and fmt_elapsed(el) or "" }
    end
    local out = {}
    for _, x in ipairs(parts) do
      if x ~= "" then out[#out + 1] = x end
    end
    return table.concat(out, "  ") .. gate_summary(s, a)
  end
  local go
  local function check_line(cid)
    local c = s.checks[cid]
    local ans = c.status == "ANSWERED" and answer_summary(c) or nil
    return "HUMAN CHECK #" .. tostring(check_n(s, c)) .. " " .. check_tag(c) .. " " ..
      tr("export.tree_check_q", { q = cut(first_question(c), 40) }) ..
      (ans and (" → " .. cut(ans, 30)) or "")
  end
  -- 子の並び：段が 2 つ以上なら「段k」の見出しの下に、その段の子を 1 段深く並べる。
  -- 直接聞いた check は段の要素として、子の要確認から生まれた check はその子の下の最後に並べる
  local function kids_of(id, prefix, seen)
    local kids = {}
    for _, k in ipairs(s._kids[id] or {}) do
      if not seen[k] then kids[#kids + 1] = k end
    end
    local own = s._checks[id] or {}
    local direct, linked = own.direct or {}, own.linked or {}
    local stages = stages_of(s, kids, direct)
    -- 並べる項目：{ stage = k, ids = {…} } か { id = … }
    local entries = {}
    if #stages >= 2 then
      for k, st in ipairs(stages) do entries[#entries + 1] = { stage = k, ids = st } end
    else
      for _, c in ipairs(#direct > 0 and (stages[1] or {}) or kids) do entries[#entries + 1] = { id = c } end
    end
    for _, cid in ipairs(linked) do entries[#entries + 1] = { id = cid } end
    local function item(c, p, last)
      if is_check(c) then
        lines[#lines + 1] = p .. (last and "└─ " or "├─ ") .. check_line(c)
      else
        go(c, p, last, false, seen)
      end
    end
    for ei, e in ipairs(entries) do
      local laste = ei == #entries
      if e.stage then
        lines[#lines + 1] = prefix .. (laste and "└─ " or "├─ ") .. tr("export.stage", { k = e.stage })
        local p2 = prefix .. (laste and "   " or "│  ")
        for i, c in ipairs(e.ids) do item(c, p2, i == #e.ids) end
      else
        item(e.id, prefix, laste)
      end
    end
  end
  go = function(id, prefix, last, top, seen)
    if seen[id] then return end
    seen[id] = true
    if top then
      lines[#lines + 1] = node_text(id)
    else
      lines[#lines + 1] = prefix .. (last and "└─ " or "├─ ") .. node_text(id)
    end
    local next_prefix = top and "" or (prefix .. (last and "   " or "│  "))
    kids_of(id, next_prefix, seen)
  end
  local seen = {}
  go("ROOT", "", true, true, seen)
  lines[#lines + 1] = "END  [" .. end_status(state) .. "]"
  if #s._unknown > 0 then
    lines[#lines + 1] = "UNKNOWN_PARENT"
    for i, id in ipairs(s._unknown) do go(id, "", i == #s._unknown, false, seen) end
  end
  return (table.concat(lines, "\n"):gsub("```", "'''"))
end

-- ------------------------------------------------------------
-- Markdown 全体
-- ------------------------------------------------------------

--- 記録元のコード（hooks / transcript / history）を表示用に。知らないものはそのまま
local function source_text(src)
  if not src or src == "" then return "-" end
  if i18n.has("common.source_" .. src) or i18n.has("common.source_" .. src, "en") then
    return tr("common.source_" .. src)
  end
  return src
end

--- Build the Markdown document for a run.
---@param state table the reduced state (DESIGN §4)
---@param opts? { source?: string }  record source code ("hooks" / "transcript" / "history")
---@return string markdown
function M.to_markdown(state, opts)
  opts = opts or {}
  local s = prepare(state)
  local out = {}
  local function w(line) out[#out + 1] = line or "" end
  local root = s.agents.ROOT or { id = "ROOT" }
  local MISSING = tr("common.missing")

  -- 集計
  local n, done, failed, reviews, reworks = 0, 0, 0, 0, 0
  for _, id in ipairs(s._ids) do
    local a = s.agents[id]
    n = n + 1
    if a.status == "DONE" then done = done + 1 end
    if a.status == "FAILED" then failed = failed + 1 end
    reviews = reviews + (a.review_count or 0)
    reworks = reworks + (a.rework_count or 0)
  end
  local n_checks, n_unanswered = #s._check_ids, 0
  for _, cid in ipairs(s._check_ids) do
    if s.checks[cid].status ~= "ANSWERED" then n_unanswered = n_unanswered + 1 end
  end
  local n_checks_text = n_unanswered > 0 and tr("export.ov_checks_unanswered", { n = n_checks, u = n_unanswered })
    or tr("export.ov_checks_n", { n = n_checks })
  local run_ms
  local st, en = parse_iso(state.started_at), parse_iso(state.ended_at)
  if st then run_ms = ((en or os.time()) - st) * 1000 end
  local title = state.title and cut(state.title, 60) or short(state.run_id)

  w("---")
  w("title: " .. tr("export.doc_title", { id = short(state.run_id) }))
  w("date: " .. os.date("%Y-%m-%d"))
  w("---")
  w()
  w("# " .. tr("export.h1", { title = title }))
  w()

  w("## " .. tr("export.h_overview"))
  w()
  w(tr("export.ov_header"))
  w("|---|---|")
  local run_status
  if state.ended_at then
    run_status = state.end_reason and tr("export.ov_ended_reason", { reason = one_line(state.end_reason) })
      or tr("export.ov_ended_plain")
  else
    run_status = tr("export.ov_running")
  end
  local rows = {
    { "run_id", state.run_id },
    { tr("export.ov_prompt"), state.flow and ("%d/%d  %s"):format(state.flow.n or 0, state.flow.total or 0,
      cut(one_line(state.flow.prompt_head or ""), 80)) or tr("export.ov_whole_session") },
    { tr("export.ov_folder"), state.cwd },
    { tr("export.ov_started"), fmt_dt(state.started_at) },
    { tr("export.ov_ended"), state.ended_at and fmt_dt(state.ended_at) or "-" },
    { tr("export.ov_duration"), run_ms and fmt_elapsed(run_ms) or "-" },
    { tr("export.ov_root_model"), model_short(root.model) or tr("export.ov_not_recorded") },
    { tr("export.ov_agents"), tostring(n) },
    { "DONE / FAILED", done .. " / " .. failed },
    { tr("export.ov_reviews"), tostring(reviews) },
    { tr("export.ov_reworks"), tostring(reworks) },
    { tr("export.ov_checks"), n_checks_text },
    { tr("export.ov_status"), run_status },
    { tr("export.ov_source"), source_text(opts.source or state.source) },
  }
  for _, r in ipairs(rows) do w("| " .. r[1] .. " | " .. cell(r[2]) .. " |") end
  w()

  w("## " .. tr("export.h_map"))
  w()
  w("```mermaid")
  w(M.mermaid(state, s))
  w("```")
  w()
  w(tr("export.text_tree_intro"))
  w()
  w("```text")
  w(M.text_tree(state, s))
  w("```")
  w()
  w(tr("export.progress_note"))
  w()

  w("## " .. tr("export.h_agents"))
  w()
  w(tr("export.agents_header"))
  w("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
  local function verdict_text(at)
    return at.decided_by and tr("export.verdict_by", { verdict = at.verdict, by = at.decided_by }) or at.verdict
  end
  local function agent_row(id)
    local a = s.agents[id] or { id = id }
    local p = progress(s, id)
    local last_v = "-"
    for _, at in ipairs(a.attempts or {}) do
      if at.verdict then last_v = verdict_text(at) end
    end
    local parent
    if id == "ROOT" then
      parent = "-"
    elseif a.parent_id and (a.parent_id == "ROOT" or s.agents[a.parent_id]) then
      parent = agent_label(s, a.parent_id)
    else
      parent = "UNKNOWN_PARENT"
    end
    local wt = {}
    if a.worktree then wt[#wt + 1] = a.worktree end
    if a.branch then wt[#wt + 1] = a.branch end
    local el = elapsed_ms(a)
    w("| " .. table.concat({
      id == "ROOT" and "ROOT" or (a.index and tostring(a.index) or "?"),
      cell(cut(name_of(a), 40)),
      cell(a.placeholder and tr("export.waiting_to_start") or a.id or id),
      cell(id == "ROOT" and "main" or a.agent_type),
      cell(model_short(a.model) or "?"),
      cell(parent),
      cell(status_tag(a) .. (p and (" " .. p) or "")),
      cell(cut(id == "ROOT" and (state.title or "") or (a.task or a.prompt_head or ""), 60)),
      cell(fmt_dt(a.started_at)),
      cell(el and fmt_elapsed(el) or "-"),
      cell(table.concat(wt, " · ")),
      cell(last_v),
      tostring(a.rework_count or 0),
    }, " | ") .. " |")
  end
  agent_row("ROOT")
  for _, id in ipairs(s._ids) do agent_row(id) end
  w()

  w("## " .. tr("export.h_reviews"))
  w()
  local any = false
  for _, id in ipairs(s._ids) do
    local a = s.agents[id]
    local atts = a.attempts or {}
    if (a.review_count or 0) > 0 or #atts > 1 or a.status == "REVIEW" or a.status == "REWORK" then
      any = true
      w(tr("export.rev_agent", { label = agent_label(s, id), name = cut(name_of(a), 40),
        sub = a.review_count or 0, rw = a.rework_count or 0, status = status_tag(a) }))
      for i, at in ipairs(atts) do
        local steps = { tr("export.rev_start", { n = at.n or i, time = fmt_clock(at.started_at) }) }
        if at.retry_of then steps[1] = steps[1] .. tr("export.rev_rerun_of", { label = agent_label(s, at.retry_of) }) end
        if at.finished_at then steps[#steps + 1] = tr("export.rev_finished", { time = fmt_clock(at.finished_at) }) end
        if at.submitted_at then steps[#steps + 1] = tr("export.rev_submitted", { time = fmt_clock(at.submitted_at) }) end
        if at.verdict then
          steps[#steps + 1] = verdict_text(at) ..
            (at.reason and at.reason ~= "" and tr("export.rev_reason", { reason = cut(at.reason, 80) }) or "")
        end
        if at.retried_by and s.agents[at.retried_by] then
          steps[#steps + 1] = tr("export.rev_rerun", { label = agent_label(s, at.retried_by) })
        elseif at.verdict == "RETRY" and atts[i + 1] then
          steps[#steps + 1] = tr("export.rev_rerun", { label = "#" .. (atts[i + 1].n or (i + 1)) })
        end
        w("  - " .. table.concat(steps, " → "))
      end
      if a.escalated_to then w(tr("export.rev_escalated", { label = agent_label(s, a.escalated_to) })) end
    end
  end
  if not any then w(tr("export.rev_none")) end
  w()

  w("## " .. tr("export.h_checks"))
  w()
  local function v_or_missing(v)
    v = v and one_line(v) or ""
    return v ~= "" and v or MISSING
  end
  if #s._check_ids == 0 then
    w(tr("export.chk_none"))
    w()
  end
  for _, cid in ipairs(s._check_ids) do
    local c = s.checks[cid]
    local child = c.agent_id and s.agents[c.agent_id] or nil
    local when = { tr("export.chk_asked", { time = c.asked_at and fmt_dt(c.asked_at):sub(12) or "-" }) }
    if c.status == "ANSWERED" then
      when[#when + 1] = tr("export.chk_answered", { time = c.answered_at and fmt_dt(c.answered_at):sub(12) or "-" })
    elseif c.status == "WAITING" then
      when[#when + 1] = tr("export.chk_waiting")
    else
      when[#when + 1] = tr("export.chk_unanswered")
    end
    w(("### HUMAN CHECK #%s %s  %s"):format(tostring(check_n(s, c)), check_tag(c), table.concat(when, "  ")))
    w()
    local asker = c.asker_id or "ROOT"
    local asker_a = s.agents[asker]
    w(tr("export.chk_asker", { who = asker == "ROOT" and "ROOT"
      or (agent_label(s, asker) .. (asker_a and (" " .. cut(name_of(asker_a), 40)) or "")) }))
    if child then
      local how = LINK_SOURCE[c.link_source]
      w(tr("export.chk_trigger_child", { label = agent_label(s, c.agent_id), name = cut(name_of(child), 40),
        how = how and tr("export.chk_trigger_how", { how = tr(how) }) or "" }))
    else
      w(tr("export.chk_trigger_direct"))
    end
    w(tr("export.chk_lead", { text = c.lead and c.lead ~= "" and tr("export.chk_lead_quote", { text = cut(c.lead, 400) })
      or tr("export.chk_no_lead") }))
    local ask = child and child.ask
    if type(ask) == "table" then
      w(tr("export.chk_child_working", { text = v_or_missing(ask.working) }))
      w(tr("export.chk_child_stuck", { text = v_or_missing(ask.stuck) }))
      w(tr("export.chk_child_want", { text = v_or_missing(ask.want) }))
    end
    local multi_q = #(c.questions or {}) >= 2
    for qi, q in ipairs(c.questions or {}) do
      local head = q.header and q.header ~= "" and ("[" .. one_line(q.header) .. "] ") or ""
      w(tr("export.chk_question", { qn = multi_q and (" Q" .. qi) or "", head = head, text = one_line(q.question or ""),
        multi = q.multi and tr("export.chk_multi") or "" }))
      for oi, o in ipairs(q.options or {}) do
        local body = brief.split_next(o.description)
        local nxt = brief.next_of(c, qi, oi, child)
        w(tr("export.chk_option", { n = oi, label = one_line(o.label or ""),
          body = body and one_line(body) ~= "" and (" — " .. one_line(body)) or "",
          next = nxt and one_line(nxt) or tr("common.missing_next") }))
      end
    end
    if c.status == "ANSWERED" then
      for _, e in ipairs(brief.answered_options(c, child)) do
        local qn = multi_q and (" Q" .. e.qi) or ""
        if #e.matches == 0 then
          w(tr("export.chk_answer_none", { qn = qn }))
        end
        for _, m in ipairs(e.matches) do
          if m.option then
            w(tr("export.chk_answer", { qn = qn, label = one_line(m.label) }))
            w(tr("export.chk_answer_next", { next = m.option.next and one_line(m.option.next) or tr("common.missing_next") }))
          else
            w(tr("export.chk_answer_free", { qn = qn, text = cut(m.label, 300) }))
          end
        end
      end
    elseif c.status == "WAITING" then
      w(tr("export.chk_answer_waiting"))
    else
      w(tr("export.chk_answer_ended", { reason = tr(CHECK_END[c.end_reason] or "export.end_unknown") }))
    end
    w()
  end

  w("## " .. tr("export.h_outputs"))
  w()
  local function quote_lines(text)
    text = tostring(text or "")
    if vim.fn.strchars(text) > 800 then text = vim.fn.strcharpart(text, 0, 799) .. "…" end
    for _, l in ipairs(vim.split(text:gsub("```", "'''"), "\n", { plain = true })) do w("> " .. l) end
  end
  local function quote(label, text)
    w("**" .. label .. "**")
    w()
    quote_lines(text)
    w()
  end
  local function nonempty(x) return type(x) == "string" and x ~= "" end
  --- Agent の成果：任せた内容（目的など）→ 報告の 4 項目／要確認／原文（設計書 §10）
  --   state が作った report_fields / ask をそのまま使う（ここで報告を読み直さない。設計書 §3.1）
  local function agent_out(label, a)
    local b, f, ask = a.brief, a.report_fields, a.ask
    local raw = nonempty(a.report) and a.report or (nonempty(a.last_head) and a.last_head or nil)
    if type(b) ~= "table" and type(f) ~= "table" and type(ask) ~= "table" and not raw then return false end
    w("**" .. label .. "**")
    w()
    local any_part = false
    if type(b) == "table" then
      w(tr("export.out_goal", { text = v_or_missing(b.purpose) }))
      w(tr("export.out_why_delegate", { text = v_or_missing(b.reason) }))
      w(tr("export.out_done_when", { text = v_or_missing(b.expected) }))
      any_part = true
    end
    if type(ask) == "table" then
      if any_part then w(">") end
      w(tr("export.out_ask_head"))
      w(tr("export.out_working", { text = v_or_missing(ask.working) }))
      w(tr("export.out_blocked", { text = v_or_missing(ask.stuck) }))
      w(tr("export.out_question", { text = v_or_missing(ask.want) }))
      local opts_list = {}
      for _, o in ipairs(ask.options or {}) do
        opts_list[#opts_list + 1] = ("%s. %s%s"):format(tostring(o.n or (#opts_list + 1)), one_line(o.name or ""),
          o.next and (" → " .. one_line(o.next)) or "")
      end
      w(tr("export.out_options", { text = #opts_list > 0 and table.concat(opts_list, " / ") or MISSING }))
    elseif type(f) == "table" then
      if any_part then w(">") end
      w(tr("export.out_done", { text = v_or_missing(f.done) }))
      w(tr("export.out_approach", { text = v_or_missing(f.direction) }))
      w(tr("export.out_why", { text = v_or_missing(f.reason) }))
      w(tr("export.out_issues", { text = v_or_missing(f.issues) }))
    elseif raw then
      if any_part then
        w(">")
        w(tr("export.out_raw_intro"))
      end
      quote_lines(raw)
    end
    w()
    return true
  end
  local any_out = false
  if root.last_head and root.last_head ~= "" then
    quote("ROOT", root.last_head)
    any_out = true
  end
  for _, id in ipairs(s._ids) do
    local a = s.agents[id]
    if agent_out(agent_label(s, id) .. " " .. cut(name_of(a), 40), a) then any_out = true end
  end
  if not any_out then
    w(tr("export.out_none"))
    w()
  end

  w("## " .. tr("export.h_files"))
  w()
  local files, forder = {}, {}
  local function add_files(id)
    local a = s.agents[id]
    if not a then return end
    for _, f in ipairs(a.files or {}) do
      if not files[f] then
        files[f] = {}
        forder[#forder + 1] = f
      end
      table.insert(files[f], agent_label(s, id))
    end
  end
  add_files("ROOT")
  for _, id in ipairs(s._ids) do add_files(id) end
  if #forder == 0 then
    w(tr("export.files_none"))
  else
    for _, f in ipairs(forder) do
      local shown = f:find("`", 1, true) and one_line(f) or ("`" .. one_line(f) .. "`")
      w("- " .. shown .. " — " .. table.concat(files[f], " "))
    end
  end
  w()

  w("## " .. tr("export.h_tools"))
  w()
  local tools, tset = {}, {}
  local all = { "ROOT" }
  vim.list_extend(all, s._ids)
  for _, id in ipairs(all) do
    for t in pairs((s.agents[id] or {}).tool_counts or {}) do
      if not tset[t] then
        tset[t] = true
        tools[#tools + 1] = t
      end
    end
  end
  table.sort(tools)
  if #tools == 0 then
    w(tr("export.tools_none"))
  else
    local head = { "Agent" }
    for _, t in ipairs(tools) do head[#head + 1] = cell(t) end
    w("| " .. table.concat(head, " | ") .. " |")
    w("|" .. string.rep("---|", #head))
    for _, id in ipairs(all) do
      local a = s.agents[id]
      if a and a.tool_counts and next(a.tool_counts) then
        local row = { cell(agent_label(s, id) .. (id ~= "ROOT" and (" " .. cut(name_of(a), 20)) or "")) }
        for _, t in ipairs(tools) do row[#row + 1] = tostring(a.tool_counts[t] or 0) end
        w("| " .. table.concat(row, " | ") .. " |")
      end
    end
  end
  w()
  w("---")
  w()
  w(tr("export.footer", { time = os.date("%Y-%m-%d %H:%M:%S") }))
  return table.concat(out, "\n") .. "\n"
end

-- ------------------------------------------------------------
-- ファイルに書き出す
-- ------------------------------------------------------------
local EXT = { markdown = "md", md = "md", html = "html", pdf = "pdf" }

local function default_dir(state, run)
  if run and run.dir then return run.dir .. "/exports" end
  local store, util = try("agentmap.store"), try("agentmap.util")
  if store and util and state.cwd and state.run_id then
    local ok, d = pcall(store.run_dir, util.slug(state.cwd), state.run_id)
    if ok and d then return d .. "/exports" end
  end
  return vim.fn.getcwd()
end

local function write_text(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(text)
  f:close()
  return true
end

local function done_msg(path)
  local wp = win_path(path)
  notify(tr("export.done", { path = path }) .. (wp and ("\n" .. tr("export.from_windows", { path = wp })) or ""))
end

--- export.* の設定（config が読めなければ空）
local function export_opts()
  local config = try("agentmap.config")
  local c = config and type(config.get) == "function" and config.get() or {}
  return type(c.export) == "table" and c.export or {}
end

--- 文字列 1 つでも argv の表でも受ける
local function as_argv(cmd)
  if type(cmd) == "string" and cmd ~= "" then return { cmd } end
  if type(cmd) == "table" and #cmd > 0 then return vim.deepcopy(cmd) end
  return nil
end

--- Markdown → HTML。export.html_command があればそれ（S12）、無ければ同梱の md.lua
---@return string|nil html, string|nil err
local function to_html(md, title)
  local cmd = as_argv(export_opts().html_command)
  if not cmd then
    local ok, res = pcall(function() return require("agentmap.md").to_html(md, { title = title }) end)
    if not ok then return nil, tostring(res) end
    return res
  end
  cmd[#cmd + 1] = title
  local ok, res = pcall(function()
    return vim.system(cmd, { stdin = md, text = true }):wait(60000)
  end)
  if not ok then return nil, tostring(res) end
  if res.code ~= 0 or not res.stdout or res.stdout == "" then
    return nil, ("exit %s\n%s"):format(tostring(res.code), tostring(res.stderr or ""))
  end
  return res.stdout
end

--- Build the argv for export.pdf_command: replaces %{html} %{out} %{title} in every element.
--- When argv[1] starts with /mnt/ (WSL calling a Windows program) the two file paths are
--- converted to Windows form first (S13). Exposed for tests.
---@param cmd string[]|string
---@param html string path of the HTML input
---@param out string path of the PDF to create
---@param title string
---@return string[]|nil
function M.pdf_argv(cmd, html, out, title)
  local argv = as_argv(cmd)
  if not argv then return nil end
  if tostring(argv[1]):sub(1, 5) == "/mnt/" then
    html = win_path(html, true) or html
    out = win_path(out, true) or out
  end
  local vars = { html = html, out = out, title = title }
  for i, a in ipairs(argv) do
    argv[i] = (tostring(a):gsub("%%{(%w+)}", function(name)
      local v = vars[name]
      if v == nil then return nil end
      return v
    end))
  end
  return argv
end

--- Write the run to a file.
---@param state table
---@param fmt "markdown"|"md"|"html"|"pdf"
---@param path? string default: <run>/exports/agentmap-<id8>-<YYYYmmdd-HHMM>.<ext>
---@param run? table the value of events.load (for the folder and the record source; optional)
---@return string|nil path the written file, nil on failure (the reason is notified)
function M.write(state, fmt, path, run)
  fmt = (fmt or "markdown"):lower()
  local ext = EXT[fmt]
  if not ext then
    notify(tr("export.unknown_format", { fmt = fmt }), vim.log.levels.ERROR)
    return nil
  end
  if not state or type(state.agents) ~= "table" then
    notify(tr("export.no_run"), vim.log.levels.WARN)
    return nil
  end
  -- PDF は設定が無ければ何も作らずに知らせる（D4）
  local pdf_cmd = ext == "pdf" and as_argv(export_opts().pdf_command) or nil
  if ext == "pdf" and not pdf_cmd then
    notify(tr("export.pdf_not_configured"), vim.log.levels.WARN)
    return nil
  end
  if not path or path == "" then
    local fl = state.flow and ("-f" .. tostring(state.flow.n or 0)) or ""
    path = ("%s/agentmap-%s%s-%s.%s"):format(default_dir(state, run), short(state.run_id), fl,
      os.date("%Y%m%d-%H%M"), ext)
  else
    path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  end
  local md = M.to_markdown(state, { source = run and run.source })
  local title = tr("export.doc_title", { id = short(state.run_id) })

  if ext == "md" then
    local ok, err = write_text(path, md)
    if not ok then
      notify(tr("export.write_failed", { err = tostring(err) }), vim.log.levels.ERROR)
      return nil
    end
    done_msg(path)
    return path
  end

  local html, herr = to_html(md, title)
  if not html then
    notify(tr("export.html_failed", { err = tostring(herr) }), vim.log.levels.ERROR)
    return nil
  end

  if ext == "html" then
    local ok, err = write_text(path, html)
    if not ok then
      notify(tr("export.write_failed", { err = tostring(err) }), vim.log.levels.ERROR)
      return nil
    end
    done_msg(path)
    return path
  end

  -- PDF：HTML を書き出し先の隣に一時的に置き、使う人のコマンドで印刷する（S13）。
  --   隣に置くのは、Windows の Chrome から /mnt/c/… の方が確実に読めるため
  local tmp_html = path:gsub("%.pdf$", "") .. ".agentmap-print.html"
  local ok, err = write_text(tmp_html, html)
  if not ok then
    notify(tr("export.write_failed", { err = tostring(err) }), vim.log.levels.ERROR)
    return nil
  end
  vim.fn.delete(path) -- 前の PDF が残っていると「できた」と見誤るので消しておく
  local argv = M.pdf_argv(pdf_cmd, tmp_html, path, title)
  local rok, res = pcall(function() return vim.system(argv, { text = true }):wait(120000) end)
  vim.fn.delete(tmp_html)
  if not rok then
    notify(tr("export.pdf_failed", { err = tostring(res) }), vim.log.levels.ERROR)
    return nil
  end
  if res.code ~= 0 then
    notify(tr("export.pdf_failed", { err = ("exit %s\n%s"):format(tostring(res.code), tostring(res.stderr or "")) }),
      vim.log.levels.ERROR)
    return nil
  end
  if not vim.uv.fs_stat(path) then
    notify(tr("export.pdf_no_output", { path = path }), vim.log.levels.ERROR)
    return nil
  end
  done_msg(path)
  return path
end

return M
