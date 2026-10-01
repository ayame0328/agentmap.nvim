-- ============================================================
--  agentmap/stages.lua … 同じ親の子を「段」に分ける（時刻だけで決める）
--
--  決め方：子を開始の早い順に並べ、今の段の全員が終わった時刻（いちばん遅い終了）
--  以降に始まった子から、次の段にする。まだ動いている子（終了なし）がいる段は閉じない。
--  文章の中身から推測はしない。時刻の無い子は最後の段の後ろに付ける。
--  差し戻し（2 回目以降の実行）は見ない：1 回目の時刻だけで段を決める。
--  例外：親の同じ 1 通の返事（transcript の message.id が同じ）でまとめて起動された子は、
--  時刻に関係なく必ず同じ段にする（batch）。Claude は 1 通の中の起動を 1 つずつ順に始めるので、
--  短い子は次の子が始まる前に終わってしまい、時刻だけでは別の段に見えるため。
-- ============================================================
local util = require("agentmap.util")

local M = {}

local OPEN = { PENDING = true, RUNNING = true, REVIEW = true }

--- Agent 1 つ → { id, st, fin, open, batch }
function M.item(a)
  if type(a) ~= "table" then return { id = nil } end
  local at = (a.attempts or {})[1] or {}
  local st = util.parse_iso(at.started_at or a.started_at or a.first_at or a.requested_at)
  local fin = util.parse_iso(at.finished_at or (#(a.attempts or {}) <= 1 and a.finished_at or nil))
  return { id = a.id, st = st, fin = fin, open = (fin == nil) and OPEN[a.status or "PENDING"] == true,
    batch = a.batch }
end

--- items → { {id,...}, ... }（段の並び）
--   同じ batch の子は 1 つの塊にしてから（開始 = 最も早い開始、終了 = 最も遅い終了）時刻の決まりを当てる
function M.split(items)
  local units, by_batch, untimed = {}, {}, {}
  for i, it in ipairs(items or {}) do
    it._o = i
    if it.st then
      local u = it.batch and by_batch[it.batch]
      if not u then
        u = { st = it.st, o = i, fin = -math.huge, members = {} }
        units[#units + 1] = u
        if it.batch then by_batch[it.batch] = u end
      end
      u.members[#u.members + 1] = it
      if it.st < u.st then u.st = it.st end
      local f = it.fin or (it.open and math.huge) or it.st
      if f > u.fin then u.fin = f end
    else
      untimed[#untimed + 1] = it
    end
  end
  local function before(x, y)
    if x.st ~= y.st then return x.st < y.st end
    return (x._o or x.o) < (y._o or y.o)
  end
  table.sort(units, before)
  local out, cur, max_fin = {}, nil, -math.huge
  for _, u in ipairs(units) do
    if cur and u.st >= max_fin then cur = nil end
    if not cur then
      cur = {}
      out[#out + 1] = cur
      max_fin = -math.huge
    end
    table.sort(u.members, before)
    for _, it in ipairs(u.members) do cur[#cur + 1] = it.id end
    u.stage = cur
    if u.fin > max_fin then max_fin = u.fin end
  end
  if #untimed > 0 then
    if #out == 0 then out[1] = {} end
    for _, it in ipairs(untimed) do
      -- 時刻が無くても、同じ batch の仲間がいればその段へ。いなければ最後の段の後ろ
      local u = it.batch and by_batch[it.batch]
      local st = (u and u.stage) or out[#out]
      st[#st + 1] = it.id
    end
  end
  for _, it in ipairs(items or {}) do it._o = nil end
  return out
end

--- HUMAN CHECK（人への確認）1 つ → { id, st, fin, open }
--   聞いた時刻から、答えた（または答えないまま終わった）時刻までを 1 つの要素として段分けに混ぜる。
--   答え待ちの間は段を閉じない（答えが出るまで親は次の子を起動しないので、閉じる理由がない）
function M.item_check(c)
  if type(c) ~= "table" then return { id = nil } end
  return { id = c.id, st = util.parse_iso(c.asked_at), fin = util.parse_iso(c.answered_at or c.ended_at),
    open = (c.status == "WAITING"), batch = nil }
end

--- state の中の ids（同じ親の子）を段に分ける。"check:" で始まる id は HUMAN CHECK として扱う
function M.of(state, ids)
  local items = {}
  for _, id in ipairs(ids or {}) do
    local it
    if type(id) == "string" and id:sub(1, 6) == "check:" then
      local c = state and state.checks and state.checks[id]
      it = M.item_check(c or { id = id })
    else
      local a = state and state.agents and state.agents[id]
      it = M.item(a or { id = id })
    end
    it.id = id
    items[#items + 1] = it
  end
  return M.split(items)
end

return M
