-- agentmap/ui.lua ... screens: the map tab, the side (aux) window and the back navigation.
--   図 → 詳細 → transcript/diff → BS → 詳細 → BS → 図、を ui.nav（戻り先の積み重ね）で実現する。
local graph = require("agentmap.graph")
local renderer = require("agentmap.renderer")
local keymaps = require("agentmap.keymaps")
local state_mod = require("agentmap.state")
local i18n = require("agentmap.i18n")
local t = i18n.t

local M = {
  run = nil, -- events.load の戻り値 { dir, sid, slug, state, … }
  flow_id = nil, -- 見せている指示（prompt_id）。nil ならセッション全体
  flow_state = nil, -- その指示だけを取り出した見せる用の状態（描き直すたびに作り直す）
  view = { root = "ROOT", collapsed = {} },
  buf = nil, -- 図のバッファ
  tab = nil,
  win = nil,
  aux_win = nil, -- 右側の補助ウィンドウ（詳細・transcript・diff で使い回す）
  aux_bufs = {},
  nav = {}, -- { {kind, id}, … } 補助ウィンドウの戻り先
  cache = nil,
  layout = nil,
}

local VIEWS = {
  detail = "agentmap.views.detail",
  transcript = "agentmap.views.transcript",
  diff = "agentmap.views.diff",
  check = "agentmap.views.check", -- HUMAN CHECK（AskUserQuestion）の詳細
}

local function is_check(id) return type(id) == "string" and id:sub(1, 6) == "check:" end

local function notify(msg, level)
  vim.notify("AgentMap: " .. msg, level or vim.log.levels.INFO)
end

-- 他の担当のモジュールは、無くても落ちないように読み込む
local function try_require(name)
  local ok, m = pcall(require, name)
  if ok and type(m) == "table" then return m end
  return nil
end

local function valid_buf(b) return b and vim.api.nvim_buf_is_valid(b) end
local function valid_win(w) return w and vim.api.nvim_win_is_valid(w) end

local function state() return M.flow_state or (M.run and M.run.state) or nil end

--- The state shown on screen (only the selected prompt's flow when one is selected).
--- 画面に出している状態（指示ごとの流れならその流れだけ）
function M.display_state() return state() end

-- 見せる用の状態を作り直す（元の状態は events.poll で少しずつ増えていくので、毎回ここで取り出す）
local function rebuild()
  M.flow_state = nil
  if M.flow_id and M.run and M.run.state then
    M.flow_state = state_mod.flow_view(M.run.state, M.flow_id)
    if not M.flow_state then M.flow_id = nil end
  end
end

local function agent_of(id)
  local s = state()
  return s and s.agents and s.agents[id] or nil
end

local function check_of(id)
  local s = state()
  return s and s.checks and s.checks[id] or nil
end

--- Map an id on the map (agent, gate:, check:) to the agent an action applies to.
--- 図の id を「その操作の対象の Agent」に直す
---   門（gate:<id>）→ 元の Agent、HUMAN CHECK（check:…）→ 箱が付いている Agent（owner。無ければ聞いた側）。
---   t / d / w / a は Agent にしか意味が無いので、この結果を使う
function M.resolve_agent(id)
  if type(id) ~= "string" then return nil end
  if id:sub(1, 5) == "gate:" then return id:sub(6) end
  if is_check(id) then
    local c = check_of(id)
    if not c then return nil end
    return c.owner_id or c.asker_id or "ROOT"
  end
  return id
end

--- The asker of a HUMAN CHECK id (usually ROOT); for other ids the same as resolve_agent().
--- HUMAN CHECK の id → 質問した側（asker。たいてい ROOT）。check でなければ resolve_agent と同じ
---   確認の画面の t はこちらを使う：質問の前後のやり取りは聞いた側の transcript にしか無い（設計書 §6.2）
function M.check_asker(id)
  if not is_check(id) then return M.resolve_agent(id) end
  local c = check_of(id)
  if not c then return nil end
  return c.asker_id or "ROOT"
end

-- 図を表示しているウィンドウ（今のタブを優先）
local function map_win()
  if not valid_buf(M.buf) then return nil end
  if valid_win(M.win) and vim.api.nvim_win_get_buf(M.win) == M.buf then return M.win end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == M.buf then
      M.win = w
      return w
    end
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == M.buf then
      M.win = w
      return w
    end
  end
  return nil
end

local function set_win_opts(win, opts)
  for k, v in pairs(opts) do
    pcall(vim.api.nvim_set_option_value, k, v, { win = win, scope = "local" })
  end
end

local function scratch_buf(name, ft)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].swapfile = false
  vim.bo[b].modifiable = false
  vim.bo[b].filetype = ft
  pcall(vim.api.nvim_buf_set_name, b, name)
  return b
end

-- ------------------------------------------------------------
-- 図
-- ------------------------------------------------------------
local function create_map_buf(run_id)
  local b = scratch_buf("agentmap://map/" .. tostring(run_id), "agentmap")
  keymaps.attach_map(b)
  local grp = vim.api.nvim_create_augroup("agentmap_ui", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = grp,
    buffer = b,
    callback = function()
      M.buf, M.cache, M.win = nil, nil, nil
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = grp,
    callback = function()
      if valid_buf(M.buf) then pcall(M.refresh, { aux = false }) end
    end,
  })
  return b
end

--- Open the map of `run` (default: the latest flow) and optionally a single prompt `flow_id`.
function M.open_map(run, flow_id)
  if not run then
    local ev = try_require("agentmap.events")
    if ev and ev.current_flow then
      local ok, r, f = pcall(ev.current_flow)
      if ok then run, flow_id = r, f end
    end
  end
  if not run or not run.state then
    notify(t("ui.no_runs_to_show"), vim.log.levels.WARN)
    return nil
  end
  renderer.setup_highlights()
  local old_id = M.run and M.run.state and M.run.state.run_id
  local same = old_id ~= nil and old_id == run.state.run_id and M.flow_id == flow_id
  M.run = run
  M.flow_id = flow_id
  M.flow_state = nil
  if not same then
    M.view = { root = "ROOT", collapsed = {}, mode = M.view.mode }
    M.nav = {}
    M.cache = nil
    M.close_aux() -- 別の run・別の指示に切り替えるとき、前の詳細画面を残さない
  end

  if not valid_buf(M.buf) then
    M.buf = create_map_buf(run.state.run_id)
    M.cache = nil
  elseif not same then
    pcall(vim.api.nvim_buf_set_name, M.buf, "agentmap://map/" .. tostring(run.state.run_id))
  end

  local win = map_win()
  if win then
    vim.api.nvim_set_current_win(win)
  else
    local cfg = graph.util.config()
    local how = cfg.open or "tab"
    if how == "tab" then
      vim.cmd("tabnew")
      local empty = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_buf(0, M.buf)
      if empty ~= M.buf and vim.api.nvim_buf_get_name(empty) == "" and not vim.bo[empty].modified then
        pcall(vim.api.nvim_buf_delete, empty, { force = true })
      end
    elseif how == "vsplit" then
      vim.cmd("vsplit")
      vim.api.nvim_win_set_buf(0, M.buf)
    else
      vim.api.nvim_win_set_buf(0, M.buf)
    end
  end
  M.win = vim.api.nvim_get_current_win()
  M.tab = vim.api.nvim_get_current_tabpage()
  set_win_opts(M.win, {
    wrap = false, number = false, relativenumber = false, signcolumn = "no",
    cursorline = true, list = false, foldcolumn = "0", spell = false,
  })
  if not M.cache then M._place = "ROOT" end
  M.refresh({ aux = false })
  return M.buf
end

--- Switch the prompt (flow) shown within the same run.
--- 同じ run の中で、見せる指示（流れ）を切り替える
function M.set_flow(flow_id)
  if flow_id == M.flow_id then return end
  M.flow_id = flow_id
  M.flow_state = nil
  M.view = { root = "ROOT", collapsed = {}, mode = M.view.mode }
  M.cache = nil
  M._place = "ROOT"
  -- 自動の切り替えで、ほかの窓で作業中のカーソルを図へ動かさない（補助画面にいたときだけ図へ戻す）
  local cur = vim.api.nvim_get_current_win()
  local in_aux = cur == M.aux_win
  M.close_aux()
  if not in_aux and valid_win(cur) then vim.api.nvim_set_current_win(cur) end
  M.refresh({ aux = false })
end

--- Id under the cursor (a box on the map, or the agent of the current side view).
-- カーソル位置の Agent id（図なら箱、補助画面ならその画面の Agent）
function M.current_id()
  local cur = vim.api.nvim_get_current_buf()
  if valid_buf(M.buf) and cur == M.buf then
    local pos = vim.api.nvim_win_get_cursor(0)
    return renderer.node_at(M.cache, pos[1], pos[2])
  end
  local ok, id = pcall(function() return vim.b[cur].agentmap_id end)
  if ok and id then return id end
  local top = M.nav[#M.nav]
  return top and top.id or nil
end

local function cursor_to(win, id)
  local r = renderer.rows_of(M.cache, id)
  if not r then return false end
  local box = M.cache.mode == "box"
  local row = r[1] + (box and 1 or 0)
  -- 全角が混じると行ごとにバイト位置が違うので、その行の開始桁を使う
  local col = (r.starts and r.starts[row] or r[3]) + (box and 4 or 0)
  pcall(vim.api.nvim_win_set_cursor, win, { row, col })
  return true
end

--- Redraw the map. opts.reload re-reads the files; opts.aux = false leaves the side view alone.
-- 図を描き直す。opts.reload = ファイルを読み直す、opts.aux = false で補助画面は触らない
function M.refresh(opts)
  opts = opts or {}
  if not M.run then return end
  if opts.reload then
    local ev = try_require("agentmap.events")
    if ev then
      if ev.poll then pcall(ev.poll, M.run) end
      if ev.enrich then pcall(ev.enrich, M.run) end
    end
  end
  rebuild()
  if not valid_buf(M.buf) then return end
  local win = map_win()
  local keep = nil
  if win and M.cache then
    local pos = vim.api.nvim_win_get_cursor(win)
    keep = renderer.node_at(M.cache, pos[1], pos[2])
  end
  local cfg = graph.util.config()
  if (cfg.open or "tab") == "tab" then
    M.view.width = vim.o.columns - 1
  else
    M.view.width = win and (vim.api.nvim_win_get_width(win) - 1) or 120
  end
  M.layout = graph.layout(state(), M.view)
  M.cache = renderer.render(M.buf, M.layout, M.cache)
  if win then
    local want = M._place or keep
    M._place = nil
    if want then
      local pos = vim.api.nvim_win_get_cursor(win)
      if renderer.node_at(M.cache, pos[1], pos[2]) ~= want or pos[1] <= 3 then
        if not cursor_to(win, want) and want ~= "ROOT" then cursor_to(win, "ROOT") end
      end
    end
  end
  -- 補助画面が詳細なら、新しい状態で作り直す
  if opts.aux ~= false and valid_win(M.aux_win) then
    local top = M.nav[#M.nav]
    if top and (top.kind == "detail" or top.kind == "check") then M._show(top, { keep_cursor = true }) end
  end
end

--- Close the map tab/window and stop watching.
function M.close()
  M.close_aux()
  local buf = M.buf
  if valid_win(M.win) and #vim.api.nvim_list_tabpages() > 1 and M.tab and vim.api.nvim_tabpage_is_valid(M.tab) then
    local nr = vim.api.nvim_tabpage_get_number(M.tab)
    pcall(vim.cmd, "tabclose " .. nr)
  elseif valid_win(M.win) then
    local alt = vim.fn.bufnr("#")
    if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) then
      vim.api.nvim_win_set_buf(M.win, alt)
    else
      vim.api.nvim_win_call(M.win, function() vim.cmd("enew") end)
    end
  end
  -- 図のバッファを消す（監視はこの BufWipeout で止まる）
  if valid_buf(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  for k, b in pairs(M.aux_bufs) do
    if valid_buf(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    M.aux_bufs[k] = nil
  end
  M.buf, M.win, M.tab, M.cache = nil, nil, nil, nil
end

-- ------------------------------------------------------------
-- 右側の補助ウィンドウ（詳細・transcript・diff）
-- ------------------------------------------------------------
local function aux_buf(kind, id)
  local key = kind .. ":" .. id
  local b = M.aux_bufs[key]
  if valid_buf(b) then return b end
  b = scratch_buf("agentmap://" .. kind .. "/" .. id, kind == "diff" and "diff" or ("agentmap_" .. kind))
  keymaps.attach_aux(b, kind)
  vim.b[b].agentmap_id = id
  vim.b[b].agentmap_kind = kind
  M.aux_bufs[key] = b
  return b
end

local function ensure_aux(buf, kind)
  if valid_win(M.aux_win) then
    vim.api.nvim_win_set_buf(M.aux_win, buf)
  else
    local mw = map_win() or vim.api.nvim_get_current_win()
    local cfg = graph.util.config()
    local width = math.max(40, math.floor(vim.o.columns * (cfg.aux_width or 0.45)))
    M.aux_win = vim.api.nvim_open_win(buf, true, { split = "right", win = mw, width = width })
  end
  vim.api.nvim_set_current_win(M.aux_win)
  set_win_opts(M.aux_win, {
    wrap = kind ~= "diff", number = false, relativenumber = false, signcolumn = "no",
    list = false, foldcolumn = "0", spell = false, cursorline = kind == "detail" or kind == "check",
  })
end

--- Show one navigation entry in the side window without changing the back stack.
-- nav の1項目を表示（積み重ねは変えない）
function M._show(entry, opts)
  opts = opts or {}
  local a
  if entry.kind == "check" then
    a = check_of(entry.id)
    if not a then
      notify(t("ui.check_not_found", { id = tostring(entry.id) }), vim.log.levels.WARN)
      return false
    end
  else
    a = agent_of(entry.id)
    if not a then
      notify(t("ui.agent_not_found", { id = tostring(entry.id) }), vim.log.levels.WARN)
      return false
    end
  end
  local mod = try_require(VIEWS[entry.kind])
  if not mod then return false end
  local b = aux_buf(entry.kind, entry.id)
  local back_to = vim.api.nvim_get_current_win()
  ensure_aux(b, entry.kind)
  local width = vim.api.nvim_win_get_width(M.aux_win)
  -- 詳細などの画面には、見せている流れの状態（番号が流れの中の番号）を渡す
  mod.open(setmetatable({ state = state() }, { __index = M.run }), a, b, { width = width })
  if opts.keep_cursor then
    if valid_win(back_to) then vim.api.nvim_set_current_win(back_to) end
    return true
  end
  local row = 1
  if entry.focus == "history" then
    for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if l:find(t("detail.history_marker"), 1, true) then
        row = i
        break
      end
    end
  end
  pcall(vim.api.nvim_win_set_cursor, M.aux_win, { row, 0 })
  return true
end

local function open_view(kind, id)
  if not id then return end
  local focus = nil
  if id:sub(1, 5) == "gate:" then
    id = id:sub(6)
    focus = "history"
  end
  if id == "UNKNOWN_PARENT" then
    notify(t("ui.unknown_parent_info"))
    return
  end
  if id == "START" or id == "END" or id:sub(1, 6) == "stage:" then
    notify(t("ui.pseudo_info"))
    return
  end
  if not M.run then M.open_map() end
  if not M.run then return end
  if is_check(id) then
    -- HUMAN CHECK：詳細なら確認の画面、transcript・diff なら箱が付いている Agent のもの
    if kind == "detail" or kind == "check" then
      if not check_of(id) then
        notify(t("ui.check_not_found", { id = tostring(id) }), vim.log.levels.WARN)
        return
      end
      kind = "check"
    else
      id = M.resolve_agent(id)
      if not id then return end
    end
  elseif not agent_of(id) then
    notify(t("ui.agent_not_found", { id = tostring(id) }), vim.log.levels.WARN)
    return
  end
  if not map_win() then M.open_map(M.run) end
  -- 図から開いたときは、戻り先を積み直す
  if vim.api.nvim_get_current_buf() == M.buf or not valid_win(M.aux_win) then M.nav = {} end
  local top = M.nav[#M.nav]
  local entry = { kind = kind, id = id, focus = focus }
  if not (top and top.kind == kind and top.id == id) then
    table.insert(M.nav, entry)
  else
    top.focus = focus
    entry = top
  end
  M._show(entry)
end

--- Open the detail view of an agent (gate: and check: ids are routed to the right view).
function M.open_detail(id) open_view("detail", id) end
--- Open the transcript view of an agent.
function M.open_transcript(id) open_view("transcript", id) end
--- Open the git diff view of an agent.
function M.open_diff(id) open_view("diff", id) end
--- Open the HUMAN CHECK view.
function M.open_check(id) open_view("check", id) end

--- Open the details of agent number `n`.
-- 番号（[n]）で詳細を開く
function M.open_index(n)
  local s = state()
  local id = s and graph.by_index(s, n)
  if not id then
    notify(t("ui.no_agent_index", { n = n }))
    return
  end
  M.open_detail(id)
end

--- Enter in a side view: open the agent or HUMAN CHECK linked to the current line.
-- 詳細・確認の画面で Enter：行に結びついた Agent（または HUMAN CHECK）の画面へ
function M.follow_link()
  local b = vim.api.nvim_get_current_buf()
  local kind = vim.b[b].agentmap_kind or "detail"
  local mod = try_require(VIEWS[kind] or VIEWS.detail)
  local links = mod and mod.links and mod.links[b] or {}
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local id = links[row]
  if id then
    open_view("detail", id) -- check: で始まれば open_view が確認の画面に振り分ける
    return
  end
  -- 開ける行に乗っていないとき：エラーで止めず、下（無ければ上）の一番近い開ける行へカーソルを運ぶ
  local rows = {}
  for r in pairs(links) do rows[#rows + 1] = r end
  table.sort(rows)
  if #rows == 0 then
    notify(t("ui.nothing_to_open"))
    return
  end
  local to = rows[1]
  for _, r in ipairs(rows) do
    if r > row then to = r break end
    to = r
  end
  vim.api.nvim_win_set_cursor(0, { to, 0 })
  notify(t("ui.moved_to_link"))
end

--- Close the side window.
function M.close_aux()
  if valid_win(M.aux_win) then
    local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(M.aux_win))
    if #wins > 1 then
      pcall(vim.api.nvim_win_close, M.aux_win, true)
    elseif valid_buf(M.buf) then
      vim.api.nvim_win_set_buf(M.aux_win, M.buf)
      M.win = M.aux_win
    end
  end
  M.aux_win = nil
  M.nav = {}
  local mw = map_win()
  if mw then vim.api.nvim_set_current_win(mw) end
end

--- Backspace: previous side view (finally the map); on the map, zoom out one level.
-- BS：補助画面なら1つ前へ（最後は図へ）、図なら部分表示を1段上へ
function M.back()
  local cur = vim.api.nvim_get_current_buf()
  if valid_buf(M.buf) and cur == M.buf then
    local r = M.view.root or "ROOT"
    if r == "ROOT" then
      notify(t("ui.at_top"))
      return
    end
    local a = agent_of(r)
    local p = a and a.parent_id or "ROOT"
    if r == "UNKNOWN_PARENT" or (p ~= "ROOT" and not agent_of(p)) then p = "ROOT" end
    M.view.root = p
    M._place = r
    M.refresh({ aux = false })
    return
  end
  table.remove(M.nav)
  if #M.nav > 0 then
    M._show(M.nav[#M.nav])
  else
    M.close_aux()
  end
end

--- Show only `id` and what is below it (z).
-- z：id から下だけを表示
function M.set_root(id)
  if not id then return end
  if is_check(id) then
    notify(t("ui.zoom_check"))
    return
  end
  if id:sub(1, 5) == "gate:" then id = id:sub(6) end
  if id ~= "ROOT" and id ~= "UNKNOWN_PARENT" and not agent_of(id) then return end
  M.view.root = id
  M._place = id
  M.refresh({ aux = false })
end

--- Expand / collapse the children of `id`. expand = true / false / nil (toggle).
-- + / -：子を開く・畳む。expand = true 開く / false 畳む / nil 反転
function M.toggle(id, expand)
  if not id then return end
  -- 門・HUMAN CHECK の箱では、それが付いている Agent を開く・畳む
  id = M.resolve_agent(id)
  if not id then return end
  local s = state()
  if not s then return end
  local has_kids = #graph.children(s, id) > 0 or (M.layout and M.layout.nodes["gate:" .. id] ~= nil)
    or #graph.checks_of(s, id) > 0 or M.view.collapsed[id]
  if id == "UNKNOWN_PARENT" then has_kids = true end
  if expand == nil then expand = M.view.collapsed[id] == true end
  if expand then
    M.view.collapsed[id] = nil
  elseif has_kids then
    M.view.collapsed[id] = true
  else
    -- 子の無い箱で - を押したら、親を畳む
    local a = agent_of(id)
    local p = a and a.parent_id
    if not p then return end
    M.view.collapsed[p] = true
    id = p
  end
  M._place = id
  M.refresh({ aux = false })
end

--- Switch between the map (box) view and the list (tree) view.
-- v：図 ↔ 一覧
function M.toggle_mode()
  local cur = M.layout and M.layout.mode or "box"
  M.view.mode = cur == "box" and "tree" or "box"
  M.refresh({ aux = false })
  notify(M.view.mode == "box" and t("ui.mode_box") or t("ui.mode_tree"))
end

-- n / p：次・前の箱へ
--   図の並び順（START → ROOT → 段1 → 段2 … → END）で進む。START・END・段の見出しは飛ばす
local function pseudo(id)
  return id == "START" or id == "END" or id:sub(1, 6) == "stage:"
end

--- Move the cursor to the next (delta = 1) or previous (delta = -1) box.
function M.move(delta)
  if not M.cache or not M.cache.node_rows then return end
  local list = {}
  for _, id in ipairs(M.cache.order or {}) do
    if M.cache.node_rows[id] and not pseudo(id) then list[#list + 1] = { id = id } end
  end
  if #list == 0 then
    for id, r in pairs(M.cache.node_rows) do
      if not pseudo(id) then list[#list + 1] = { id = id, r = r } end
    end
    table.sort(list, function(x, y)
      if x.r[1] ~= y.r[1] then return x.r[1] < y.r[1] end
      return x.r[3] < y.r[3]
    end)
  end
  if #list == 0 then return end
  local cur = M.current_id()
  local idx = 0
  for i, e in ipairs(list) do
    if e.id == cur then idx = i end
  end
  local nxt
  if idx == 0 then
    nxt = delta > 0 and 1 or #list
  else
    nxt = (idx - 1 + delta) % #list + 1
  end
  cursor_to(map_win() or 0, list[nxt].id)
end

--- Change this tab's working folder to the agent's worktree (:tcd); opens oil.nvim when loaded.
-- w：その Agent の作業フォルダへ（このタブだけ :tcd）。Oil があれば右側で開く
function M.jump_worktree(id)
  if id and id:sub(1, 5) == "gate:" then id = id:sub(6) end
  local a = agent_of(id)
  local s = state()
  if not a or not s then return end
  local dir = a.worktree or a.cwd or s.cwd
  if not dir or vim.fn.isdirectory(dir) ~= 1 then
    notify(t("ui.dir_not_found", { dir = tostring(dir) }), vim.log.levels.WARN)
    return
  end
  vim.cmd("tcd " .. vim.fn.fnameescape(dir))
  notify(t("ui.tcd_done", { dir = dir }))
  if package.loaded["oil"] then
    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].bufhidden = "wipe"
    ensure_aux(b, "oil")
    M.nav = {}
    pcall(vim.cmd, "Oil " .. vim.fn.fnameescape(dir))
  end
end

-- ------------------------------------------------------------
-- 選択メニュー類
-- ------------------------------------------------------------
--- Pick a past run with vim.ui.select and call on_pick(run).
function M.run_picker(runs, on_pick)
  if not runs or #runs == 0 then
    notify(t("ui.no_past_runs"))
    return
  end
  vim.ui.select(runs, {
    prompt = t("ui.runs_prompt"),
    format_item = function(r)
      local ts = r.flow_id and graph.util.parse_iso(r.started_at)
      local date = r.date or (ts and os.date("%Y-%m-%d %H:%M", math.floor(ts)))
        or (r.mtime and os.date("%Y-%m-%d %H:%M", type(r.mtime) == "table" and r.mtime.sec or r.mtime)) or ""
      local sid = graph.util.short_id(r.sid or r.session_id or r.run_id)
      local parts = { date }
      -- 同じセッションの指示は本文の出だしが似ることがあるので、何番目の指示かを先に出す
      if r.flow_id then parts[#parts + 1] = t("ui.prompt_n", { n = r.flow_n or 0, total = r.flow_total or 0 }) end
      parts[#parts + 1] = graph.util.truncate(r.title or "", 40)
      if r.agents then parts[#parts + 1] = t("ui.agents_count", { n = r.agents }) end
      if r.status then parts[#parts + 1] = "[" .. r.status .. "]" end
      parts[#parts + 1] = sid
      local proj = r.cwd and vim.fn.fnamemodify(r.cwd, ":t") or r.slug
      if proj and proj ~= "" then parts[#parts + 1] = proj end
      if r.source then
        -- 記録には言語に依らない符号（hooks / transcript / history）が入っている。知っている符号だけ訳す
        local key = "common.source_" .. tostring(r.source)
        parts[#parts + 1] = "(" .. (i18n.has(key) and t(key) or tostring(r.source)) .. ")"
      end
      return table.concat(parts, "  ")
    end,
  }, function(choice)
    if choice then on_pick(choice) end
  end)
end

--- Show the list of past runs.
function M.runs()
  local af = try_require("agentmap")
  if af and type(af.runs) == "function" then return af.runs() end
  local ev = try_require("agentmap.events")
  if not ev or not ev.list_runs then
    notify(t("ui.runs_unavailable"), vim.log.levels.WARN)
    return
  end
  M.run_picker(ev.list_runs(), function(r)
    local run = ev.open_run(r.sid or r.session_id)
    if run then M.open_map(run, r.flow_id) end
  end)
end

--- Ask for a format and export the run.
function M.export_menu()
  vim.ui.select({ "markdown", "html", "pdf" }, { prompt = t("ui.export_prompt") }, function(fmt)
    if not fmt then return end
    local af = try_require("agentmap")
    if af and type(af.export) == "function" then return af.export(fmt) end
    local ex = try_require("agentmap.export")
    if ex and ex.write and state() then
      local p = ex.write(state(), fmt)
      if p then notify(t("ui.exported", { path = p })) end
    else
      notify(t("ui.export_unavailable"), vim.log.levels.WARN)
    end
  end)
end

--- Review menu for an agent (submit / PASS / RETRY / ESCALATE / rerun / rename).
function M.review_menu(id)
  if id and id:sub(1, 5) == "gate:" then id = id:sub(6) end
  local a = agent_of(id)
  if not a then return end
  local rv = try_require("agentmap.review")
  if not rv then
    notify(t("ui.review_unavailable"), vim.log.levels.WARN)
    return
  end
  local label = id == "ROOT" and "ROOT" or ("[" .. (a.index or "?") .. "] " .. (a.name or a.task or id))
  local items = { t("ui.review_submit"), "PASS", "RETRY", "ESCALATE", t("ui.review_retry_of"), t("ui.review_rename") }
  local function done() pcall(M.refresh) end
  vim.ui.select(items, { prompt = t("ui.review_prompt", { label = label }) }, function(_, idx)
    if not idx then return end
    if idx == 1 then
      vim.ui.input({ prompt = t("ui.note_prompt") }, function(note)
        if note == nil then return end
        rv.submit(M.run, id, note ~= "" and note or nil)
        done()
      end)
    elseif idx <= 4 then
      local verdict = items[idx]
      vim.ui.input({ prompt = t("ui.reason_prompt", { verdict = verdict }) }, function(reason)
        if reason == nil then return end
        local extra = {}
        if verdict == "ESCALATE" then extra.escalate_to = a.parent_id end
        rv.record(M.run, id, verdict, reason, "user", extra)
        done()
      end)
    elseif idx == 5 then
      vim.ui.input({ prompt = t("ui.retry_of_prompt") }, function(s)
        local n = tonumber(s or "")
        local old = n and graph.by_index(state(), n)
        if not old then
          if s and s ~= "" then notify(t("ui.no_agent_number", { n = s })) end
          return
        end
        rv.mark_retry_of(M.run, id, old)
        done()
      end)
    else
      vim.ui.input({ prompt = t("ui.rename_prompt"), default = a.name or "" }, function(nm)
        if not nm or nm == "" then return end
        local ev = try_require("agentmap.events")
        if ev and ev.emit then
          ev.emit(M.run, { event = "agent_updated", agent_id = id, name = nm })
          done()
        end
      end)
    end
  end)
end

--- Show the key help in a floating window.
-- ? のキー一覧（浮かせた小窓。q / Esc で閉じる）
function M.help()
  local lines = keymaps.help_lines()
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.bo[b].bufhidden = "wipe"
  local width = math.min(w + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(b, true, {
    relative = "editor", width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    style = "minimal", border = "rounded", title = " AgentMap ", title_pos = "center",
  })
  for _, k in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", k, function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = b, nowait = true })
  end
end

return M
