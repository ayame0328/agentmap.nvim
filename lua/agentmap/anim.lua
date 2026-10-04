-- agentmap/anim.lua ... the light that flows along the lines of the box map.
--   A dot of light (a head and a short tail) runs along the line into every RUNNING agent
--   (parent -> child), along the line into a HUMAN CHECK that waits for an answer (purple), and,
--   for `animation.back_ms` after an agent finishes, backwards along the same line (child -> parent).
--   Only highlight extmarks move (namespace "agentmap_anim", priority 4200); the text is never
--   rewritten. The timer runs only while something is lit and the map is visible in the current tab.
--
--   Pure parts (tested directly): plan(), frame(), cfg().
--   Stateful parts: update() (called at the end of every ui.refresh), stop(), setup_highlights().
--
--   設計: DESIGN-v0.2.md §3（光）、付録 D（HUMAN CHECK の線も紫で流す）
local M = {}

M.DEFAULTS = {
  enabled = true,
  frame_ms = 100, -- 1 コマの長さ
  period = 6, -- 光の点の間隔（セル）
  tail = 2, -- 頭の後ろの尾の長さ（セル）
  back_ms = 3000, -- 子が終わったあと、子→親へ流す時間
  max_paths = 40, -- 同時に光らせる線の上限
}

M.PRIORITY = 4200 -- 基本の印（既定 4096）より上に乗る

local FINISHED = { DONE = true, REWORK = true, FAILED = true }

--- Effective animation settings: config.get().animation merged over the defaults.
--- `false` (or { enabled = false }) turns the light off; `true` or nil means the defaults.
---@param raw? table|boolean override (tests); default: config.get().animation
---@return table
function M.cfg(raw)
  if raw == nil then
    local ok, config = pcall(require, "agentmap.config")
    if ok then raw = config.get().animation end
  end
  if raw == false then return vim.tbl_extend("force", M.DEFAULTS, { enabled = false }) end
  if type(raw) ~= "table" then return vim.deepcopy(M.DEFAULTS) end
  local c = vim.tbl_extend("force", M.DEFAULTS, raw)
  c.period = math.max(1, math.floor(tonumber(c.period) or M.DEFAULTS.period))
  c.tail = math.max(0, math.min(math.floor(tonumber(c.tail) or M.DEFAULTS.tail), c.period - 1))
  c.frame_ms = math.max(16, math.floor(tonumber(c.frame_ms) or M.DEFAULTS.frame_ms))
  return c
end

-- ------------------------------------------------------------
-- 純粋な部分
-- ------------------------------------------------------------

--- Decide which lines are lit, from the previous and the current status of every box.
---   prev_status / cur_status = { [id] = "RUNNING" | "DONE" | "WAITING" | … } (prev nil = the map was
---   just opened: nothing flows back, because the end was not seen).
---   prev_back = the `back` table returned last time (kept until it expires).
---@return table actives { forward = { id, … }, wait = { id, … }, back = { [id] = expires_at_ms } }
function M.plan(prev_status, cur_status, now, cfg, prev_back)
  cfg = cfg or M.DEFAULTS
  cur_status = cur_status or {}
  local forward, wait, back = {}, {}, {}
  for id, st in pairs(cur_status) do
    if st == "RUNNING" then
      forward[#forward + 1] = id
    elseif st == "WAITING" then
      wait[#wait + 1] = id
    end
  end
  table.sort(forward)
  table.sort(wait)
  -- 前回からの戻りの光：期限が来るまで。もう一度 RUNNING になったら前向きに戻す
  for id, exp in pairs(prev_back or {}) do
    if exp > now and cur_status[id] ~= "RUNNING" and cur_status[id] ~= nil then back[id] = exp end
  end
  if prev_status then
    for id, st in pairs(cur_status) do
      if FINISHED[st] and prev_status[id] == "RUNNING" then back[id] = now + (cfg.back_ms or 3000) end
    end
  end
  return { forward = forward, wait = wait, back = back }
end

--- True when nothing is lit.
function M.is_empty(actives)
  return not actives or (#(actives.forward or {}) == 0 and #(actives.wait or {}) == 0 and next(actives.back or {}) == nil)
end

-- 長さ L の線の、コマ k で光るセル。group = "AgentMapFlow" など。reverse = 子→親
local function light(out, path, k, cfg, group, reverse)
  local L = #path
  if L == 0 then return end
  local period = cfg.period
  for i = 0, L - 1 do
    local j = reverse and (L - 1 - i) or i
    local d = (j - k) % period -- 0 = 頭、period-1 = 頭のすぐ後ろ …
    local hl
    if d == 0 then
      hl = group .. "1"
    elseif d >= period - cfg.tail then
      hl = group .. ((period - d) == 1 and "2" or "3")
    end
    if hl then
      local c = path[i + 1]
      out[#out + 1] = { c[1], c[2], c[3], hl }
    end
  end
end

--- Cells to light in frame `k` (0, 1, 2, …; one cell per frame).
---   paths = layout.paths ({ [id] = { {row0, byte0, byte1}, … } }, parent side first).
---   The result is ordered forward → wait → back, so a cell shared with a returning light shows
---   the returning one (later extmarks win at the same priority).
---@return table specs { { row, b0, b1, hl_group }, … }
function M.frame(paths, actives, k, cfg)
  cfg = cfg or M.DEFAULTS
  local out = {}
  if not paths or not actives then return out end
  for _, id in ipairs(actives.forward or {}) do
    if paths[id] then light(out, paths[id], k, cfg, "AgentMapFlow", false) end
  end
  for _, id in ipairs(actives.wait or {}) do
    if paths[id] then light(out, paths[id], k, cfg, "AgentMapFlowWait", false) end
  end
  local back = {}
  for id in pairs(actives.back or {}) do back[#back + 1] = id end
  table.sort(back)
  for _, id in ipairs(back) do
    if paths[id] then light(out, paths[id], k, cfg, "AgentMapFlowBack", true) end
  end
  return out
end

-- 線のある項目だけに絞り、全部で max_paths 本まで（order の順）
local function restrict(actives, paths, order, max)
  local rank = {}
  for i, id in ipairs(order or {}) do rank[id] = i end
  local function by_order(a, b)
    local ra, rb = rank[a] or math.huge, rank[b] or math.huge
    if ra ~= rb then return ra < rb end
    return a < b
  end
  local all = {}
  for _, id in ipairs(actives.forward) do if paths[id] then all[#all + 1] = { id, "forward" } end end
  for _, id in ipairs(actives.wait) do if paths[id] then all[#all + 1] = { id, "wait" } end end
  for id in pairs(actives.back) do if paths[id] then all[#all + 1] = { id, "back" } end end
  table.sort(all, function(x, y)
    if x[1] == y[1] then return x[2] < y[2] end
    return by_order(x[1], y[1])
  end)
  local out = { forward = {}, wait = {}, back = {} }
  for i, e in ipairs(all) do
    if i > max then break end
    if e[2] == "back" then
      out.back[e[1]] = actives.back[e[1]]
    else
      table.insert(out[e[2]], e[1])
    end
  end
  return out
end
M._restrict = restrict

-- ------------------------------------------------------------
-- 色
-- ------------------------------------------------------------
local ours = {} -- 自分が付けた色（背景の明暗が変わったとき、自分のものだけ付け直す）

--- True when the terminal has fewer than 16 colors and no true color (the head is then bold/reverse).
function M.low_color()
  if vim.o.termguicolors then return false end
  local ui = vim.api.nvim_list_uis()[1]
  local n = ui and tonumber(ui.term_colors) or nil
  return n == nil or n < 16
end

local PALETTE = {
  dark = {
    AgentMapFlow1 = { fg = "#ffffff", ctermfg = 231, bold = true },
    AgentMapFlow2 = { fg = "#e3b341", ctermfg = 178 },
    AgentMapFlow3 = { fg = "#8a6d1f", ctermfg = 94 },
    AgentMapFlowBack1 = { fg = "#ffffff", ctermfg = 231, bold = true },
    AgentMapFlowBack2 = { fg = "#3fb950", ctermfg = 71 },
    AgentMapFlowBack3 = { fg = "#1f5a2c", ctermfg = 22 },
    AgentMapFlowWait1 = { fg = "#ffffff", ctermfg = 231, bold = true },
    AgentMapFlowWait2 = { fg = "#d2a8ff", ctermfg = 176 },
    AgentMapFlowWait3 = { fg = "#6e4f99", ctermfg = 96 },
  },
  light = {
    AgentMapFlow1 = { fg = "#000000", ctermfg = 16, bold = true },
    AgentMapFlow2 = { fg = "#b35c00", ctermfg = 130 },
    AgentMapFlow3 = { fg = "#d9a441", ctermfg = 179 },
    AgentMapFlowBack1 = { fg = "#000000", ctermfg = 16, bold = true },
    AgentMapFlowBack2 = { fg = "#1a7f37", ctermfg = 28 },
    AgentMapFlowBack3 = { fg = "#7fd18a", ctermfg = 114 },
    AgentMapFlowWait1 = { fg = "#000000", ctermfg = 16, bold = true },
    AgentMapFlowWait2 = { fg = "#8250df", ctermfg = 97 },
    AgentMapFlowWait3 = { fg = "#c297ff", ctermfg = 183 },
  },
}

--- Define the AgentMapFlow* highlight groups for the current 'background'.
--- A group the user (or a color scheme) defined is left alone; groups this function set earlier
--- are replaced, so switching 'background' updates them.
function M.setup_highlights()
  local pal = PALETTE[vim.o.background == "light" and "light" or "dark"]
  local low = M.low_color()
  for name, val in pairs(pal) do
    val = vim.deepcopy(val)
    if low and name:match("1$") then val = { bold = true, reverse = true } end
    local okc, cur = pcall(vim.api.nvim_get_hl, 0, { name = name, link = true })
    cur = okc and cur or {}
    if vim.tbl_isempty(cur) or (ours[name] and vim.deep_equal(cur, ours[name])) then
      vim.api.nvim_set_hl(0, name, val)
      local ok2, got = pcall(vim.api.nvim_get_hl, 0, { name = name, link = true })
      ours[name] = ok2 and got or nil
    end
  end
end

-- ------------------------------------------------------------
-- タイマーと描画
-- ------------------------------------------------------------
--- Clock in milliseconds (replace in tests).
M.clock = function() return vim.uv.now() end

local S = {
  timer = nil,
  buf = nil,
  paths = nil,
  order = nil,
  actives = nil,
  prev = nil, -- 前回の状態の写し { [id] = status }
  back = {}, -- 戻りの光の期限 { [id] = ms }
  k = 0,
  cfg = nil,
}

local function renderer() return require("agentmap.renderer") end

local function visible_here(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return false end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then return true end
  end
  return false
end

local function stop_timer()
  if S.timer then
    pcall(S.timer.stop, S.timer)
    pcall(S.timer.close, S.timer)
    S.timer = nil
  end
end

local function clear()
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
    pcall(vim.api.nvim_buf_clear_namespace, S.buf, renderer().anim_ns, 0, -1)
  end
end

--- Stop the timer and remove the light (the remembered statuses are kept).
function M.stop()
  stop_timer()
  clear()
  S.actives = nil
end

--- Forget everything (another run or prompt is shown): no returning light for what was seen before.
function M.reset()
  M.stop()
  S.prev, S.back, S.k, S.paths, S.order = nil, {}, 0, nil, nil
end

--- Draw one frame (what the timer does every frame_ms). Returns false when it stopped.
---@param hold? boolean draw the current frame again without advancing (after a redraw)
function M.step(hold)
  if not S.actives then return false end
  local cfg = S.cfg or M.cfg()
  if not cfg.enabled or not visible_here(S.buf) then
    M.stop()
    return false
  end
  -- 戻りの光の期限
  local now = M.clock()
  for id, exp in pairs(S.actives.back) do
    if exp <= now then
      S.actives.back[id] = nil
      S.back[id] = nil
    end
  end
  if M.is_empty(S.actives) then
    M.stop()
    return false
  end
  renderer().set_anim_marks(S.buf, M.frame(S.paths, S.actives, S.k, cfg))
  if not hold then S.k = S.k + 1 end
  return true
end

local function start_timer(cfg)
  if S.timer then return end
  local timer = vim.uv.new_timer()
  if not timer then return end
  S.timer = timer
  timer:start(cfg.frame_ms, cfg.frame_ms, function()
    vim.schedule(function()
      if S.timer ~= timer then return end
      local ok = pcall(M.step)
      if not ok then M.stop() end
    end)
  end)
end

--- Called at the end of every map redraw: decide what is lit and start or stop the timer.
---   status_map = { [id] = status } for the agents and HUMAN CHECK boxes on screen.
---@param buf integer map buffer
---@param layout table graph.layout() result (layout.paths, layout.mode, layout.order)
---@param status_map table
---@param now? number milliseconds (default M.clock())
function M.update(buf, layout, status_map, now)
  local cfg = M.cfg()
  S.cfg = cfg
  if not cfg.enabled then
    M.stop()
    S.prev = nil
    return
  end
  now = now or M.clock()
  local actives = M.plan(S.prev, status_map or {}, now, cfg, S.back)
  S.prev = vim.deepcopy(status_map or {})
  S.back = actives.back
  local paths = (layout and layout.mode == "box" and layout.paths) or {}
  actives = restrict(actives, paths, layout and layout.order, cfg.max_paths or 40)
  if buf ~= S.buf then clear() end
  S.buf, S.paths, S.order = buf, paths, layout and layout.order
  if M.is_empty(actives) or not visible_here(buf) then
    M.stop()
    return
  end
  S.actives = actives
  -- 描き直しで行が置き換わると印が消えるので、すぐ描く。タイマーが動いていれば同じコマを描き直すだけ
  -- （毎秒の描き直しのたびにコマを進めると、光の速さがむらになる）
  M.step(S.timer ~= nil)
  start_timer(cfg)
end

--- True while the light timer runs (tests).
function M._running() return S.timer ~= nil end

--- Internal state (tests).
function M._state() return S end

return M
