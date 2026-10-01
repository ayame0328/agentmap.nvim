-- agentmap/watch.lua ... watches a folder and calls back once things settle (drives auto refresh).
-- フォルダの変化を見張って、変わったら知らせる（画面の自動更新に使う）。
--   ・ファイルの変更通知（fs_event）と、一定間隔での確認（polling）の両方を使う。
--     /mnt/ の下（Windows 側）は変更通知が当てにならないので、確認だけにする
--   ・短い間に何度も変わっても、知らせるのは落ち着いてから 1 回（debounce）
local M = {}

local uv = vim.uv or vim.loop

local function cfg()
  local ok, config = pcall(require, "agentmap.config")
  if ok and type(config.get) == "function" then
    local ok2, c = pcall(config.get)
    if ok2 and type(c) == "table" then return c end
  end
  return {}
end

local function close(h)
  if h and not h:is_closing() then
    pcall(function() h:stop() end)
    h:close()
  end
end

--- 見張る対象の今の状態（大きさと更新時刻）を 1 つの文字にまとめる
local function signature(dir, files)
  local parts = {}
  local names = files
  if not names then names = { "" } end
  for _, name in ipairs(names) do
    local p = name == "" and dir or (dir .. "/" .. name)
    local st = uv.fs_stat(p)
    if st then
      parts[#parts + 1] = ("%s:%d:%d.%d"):format(name, st.size, st.mtime.sec, st.mtime.nsec or 0)
    else
      parts[#parts + 1] = name .. ":-"
    end
  end
  if not files then
    -- フォルダそのものを見張るときは、中身の数も見る（新しい run の出現に気付くため）
    local n = 0
    local fs = uv.fs_scandir(dir)
    while fs do
      local name = uv.fs_scandir_next(fs)
      if not name then break end
      n = n + 1
    end
    parts[#parts + 1] = "n=" .. n
  end
  return table.concat(parts, "|")
end

--- Start watching `dir`; cb is called once changes settle. Returns a handle.
--- 見張りを始める。
---@param dir string 見張るフォルダ
---@param cb fun() 変化があったとき（落ち着いてから）呼ばれる。いつも本体の流れの中で呼ぶ
---@param opts? { files?: string[], poll_ms?: integer, debounce_ms?: integer, no_fs_event?: boolean }
---   files 省略時は hooks.jsonl と events.jsonl。{} を渡すとフォルダの中身そのものを見る
---@return table handle
function M.start(dir, cb, opts)
  opts = opts or {}
  local c = cfg()
  local files = opts.files
  if files == nil then files = { "hooks.jsonl", "events.jsonl" } end
  if #files == 0 then files = nil end
  local handle = {
    dir = dir,
    closed = false,
    fs_event = nil,
    poll = nil,
    debounce = uv.new_timer(),
    mode = "poll",
  }
  local debounce_ms = opts.debounce_ms or c.debounce_ms or 200
  local poll_ms = opts.poll_ms or c.poll_ms or 1500

  local last = signature(dir, files)
  local function fire()
    if handle.closed then return end
    handle.debounce:stop()
    handle.debounce:start(debounce_ms, 0, function()
      vim.schedule(function()
        if handle.closed then return end
        -- 知らせる時点の状態を覚えておき、確認（polling）で同じ変化を二重に知らせない
        last = signature(dir, files)
        local ok, err = pcall(cb)
        if not ok then
          vim.notify("AgentMap: " .. require("agentmap.i18n").t("watch.update_failed", { err = tostring(err) }), vim.log.levels.WARN)
        end
      end)
    end)
  end

  -- 変更通知（Linux 側のフォルダだけ）
  if not opts.no_fs_event and not dir:match("^/mnt/") then
    local ev = uv.new_fs_event()
    if ev then
      local ok, ret = pcall(ev.start, ev, dir, {}, function(err)
        if not err then fire() end
      end)
      if ok and ret then
        handle.fs_event = ev
        handle.mode = "fs_event+poll"
      else
        close(ev)
      end
    end
  end

  -- 一定間隔での確認（変更通知が来ない場合の保険）
  handle.poll = uv.new_timer()
  handle.poll:start(poll_ms, poll_ms, function()
    if handle.closed then return end
    local now = signature(dir, files)
    if now ~= last then
      last = now
      fire()
    end
  end)

  return handle
end

--- Stop watching (safe to call more than once).
--- 見張りをやめる（何度呼んでもよい）
function M.stop(handle)
  if not handle or handle.closed then return end
  handle.closed = true
  close(handle.fs_event)
  close(handle.poll)
  close(handle.debounce)
end

return M
