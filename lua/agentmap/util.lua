-- ============================================================
--  agentmap/util.lua … 小さな道具（文字幅・時刻・ファイル）
--    どれも他の agentmap ファイルに頼らない。
-- ============================================================
local M = {}
local uv = vim.uv or vim.loop

-- ---------- 文字の幅（日本語は 1 文字 2 マス） ----------

--- 画面上の幅
function M.dw(s)
  return vim.fn.strdisplaywidth(s or "")
end

--- 幅 w に収まるよう切る。切ったら最後を … にする
function M.truncate(s, w)
  s = tostring(s or "")
  if w <= 0 then return "" end
  if M.dw(s) <= w then return s end
  local ell = M.dw("…")
  local out, used = {}, 0
  local n = vim.fn.strchars(s)
  for i = 0, n - 1 do
    local ch = vim.fn.strcharpart(s, i, 1)
    local cw = M.dw(ch)
    if used + cw > w - ell then break end
    out[#out + 1] = ch
    used = used + cw
  end
  return table.concat(out) .. "…"
end

--- 幅 w ちょうどにする（足りなければ空白で埋める）。align は "left"（既定）| "right" | "center"
function M.fit(s, w, align)
  s = tostring(s or ""):gsub("[\r\n\t]", " ")
  if M.dw(s) > w then s = M.truncate(s, w) end
  local pad = w - M.dw(s)
  if pad <= 0 then return s end
  if align == "right" then return string.rep(" ", pad) .. s end
  if align == "center" then
    local l = math.floor(pad / 2)
    return string.rep(" ", l) .. s .. string.rep(" ", pad - l)
  end
  return s .. string.rep(" ", pad)
end

-- ---------- 時刻 ----------

--- 今の時刻（UTC、ミリ秒つき ISO 形式）
function M.iso_now()
  local sec, usec = uv.gettimeofday()
  return os.date("!%Y-%m-%dT%H:%M:%S", sec) .. string.format(".%03dZ", math.floor((usec or 0) / 1000))
end

-- UTC の年月日時分秒 → 1970 年からの秒数（タイムゾーンに左右されない計算）
local function days_from_civil(y, m, d)
  y = (m <= 2) and (y - 1) or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- ISO 形式の時刻 → 秒（小数あり）。読めなければ nil
function M.parse_iso(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, se, rest = s:match("^(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)(.*)$")
  if not y then return nil end
  local frac = 0
  local f = rest:match("^%.(%d+)")
  if f then frac = tonumber("0." .. f) end
  local off = 0
  local sign, oh, om = rest:match("([%+%-])(%d%d):?(%d%d)$")
  if sign then
    off = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "+" and 1 or -1)
  end
  local days = days_from_civil(tonumber(y), tonumber(mo), tonumber(d))
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se) + frac - off
end

--- 経過時間（ミリ秒）→ "0:05" / "12:03" / "1:02:03"
function M.fmt_elapsed(ms)
  if type(ms) ~= "number" or ms < 0 then return "-" end
  local s = math.floor(ms / 1000)
  local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
  s = s % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

--- ISO 時刻 → この PC の時計での "HH:MM:SS"
function M.fmt_clock(iso)
  local t = M.parse_iso(iso)
  if not t then return "-" end
  return os.date("%H:%M:%S", math.floor(t))
end

--- ISO 時刻 → この PC の時計での "YYYY-MM-DD HH:MM"
function M.fmt_datetime(iso)
  local t = M.parse_iso(iso)
  if not t then return "-" end
  return os.date("%Y-%m-%d %H:%M", math.floor(t))
end

--- 長い ID を先頭 8 文字に
function M.short_id(id)
  id = tostring(id or "")
  return id:sub(1, 8)
end

--- フォルダの道のり → Claude と同じ名札（英数字以外は -）
function M.slug(cwd)
  return (tostring(cwd or ""):gsub("[^%w]", "-"))
end

--- WSL の中で動いているか（ふつうの Linux の /mnt/d/… を Windows の道のりと取り違えないため）
function M.is_wsl()
  if (vim.env.WSL_DISTRO_NAME or "") ~= "" or (vim.env.WSL_INTEROP or "") ~= "" then return true end
  return vim.fn.has("wsl") == 1
end

--- WSL の道のりを Windows 形式に直す。WSL の外では nil。
--- force = true なら WSL かどうかを見ない（/mnt/ の Windows のプログラムに渡すと分かっているとき）
function M.win_path(path, force)
  if type(path) ~= "string" then return nil end
  if not force and not M.is_wsl() then return nil end
  local d, rest = path:match("^/mnt/(%a)/(.*)$")
  if d then return d:upper() .. ":\\" .. rest:gsub("/", "\\") end
  local distro = vim.env.WSL_DISTRO_NAME
  if distro and path:sub(1, 1) == "/" then
    return "\\\\wsl.localhost\\" .. distro .. path:gsub("/", "\\")
  end
  return nil
end

-- ---------- 道のり ----------

function M.basename(p)
  return (tostring(p or ""):gsub("/+$", ""):match("([^/]*)$"))
end

function M.dirname(p)
  p = tostring(p or ""):gsub("/+$", "")
  local d = p:match("^(.*)/[^/]*$")
  if d == nil then return "." end
  if d == "" then return "/" end
  return d
end

-- ---------- ファイル ----------

--- 全部読む。無ければ nil
function M.read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

--- 途中で切れないよう、一時ファイルに書いてから名前を付け替える
function M.write_atomic(p, s)
  vim.fn.mkdir(M.dirname(p), "p")
  local tmp = p .. ".tmp." .. tostring(uv.os_getpid())
  local f, err = io.open(tmp, "wb")
  if not f then return false, err end
  f:write(s)
  f:close()
  local ok, rerr = os.rename(tmp, p)
  if not ok then
    os.remove(tmp)
    return false, rerr
  end
  return true
end

--- 1 行追記（O_APPEND で 1 回の write）
function M.append_line(p, s)
  vim.fn.mkdir(M.dirname(p), "p")
  local fd = uv.fs_open(p, "a", 384) -- 0600
  if not fd then return false end
  uv.fs_write(fd, s .. "\n", -1)
  uv.fs_close(fd)
  return true
end

--- from_off バイト目から後ろの「完結した行」を JSON として読む。
--- 最後の行が書きかけ（改行なし）なら読まずに残す。
--- 戻り値：objs（読めた順）, new_off
function M.json_lines(p, from_off)
  from_off = from_off or 0
  local f = io.open(p, "rb")
  if not f then return {}, from_off end
  local size = f:seek("end")
  if size < from_off then from_off = 0 end -- ファイルが作り直された
  f:seek("set", from_off)
  local data = f:read("*a") or ""
  f:close()
  local last_nl = nil
  local i = #data
  while i > 0 do
    if data:byte(i) == 10 then last_nl = i break end
    i = i - 1
  end
  if not last_nl then return {}, from_off end
  local objs = {}
  for line in data:sub(1, last_nl):gmatch("([^\n]*)\n") do
    if line:find("%S") then
      local ok, obj = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(obj) == "table" then objs[#objs + 1] = obj end
    end
  end
  return objs, from_off + last_nl
end

--- JSON にする（失敗したら nil）
function M.json_encode(t)
  local ok, s = pcall(vim.json.encode, t)
  if ok then return s end
  return nil
end

--- JSON を読む（失敗したら nil）
function M.json_decode(s)
  if type(s) ~= "string" or s == "" then return nil end
  local ok, t = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  if ok then return t end
  return nil
end

return M
