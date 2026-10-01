-- agentmap/jsonfmt.lua ... order-preserving JSON reader/writer used to edit settings.json safely.
-- 並び順を崩さずに JSON を読み書きする小さな道具。
--   settings.json を書き換えるとき、vim.json だと項目の並びが変わり、
--   空の {} が [] になることがある。本人の設定を壊さないため、自前で読み書きする。
--   書式は Claude Code と同じ（字下げ 2、日本語はそのまま）。
local M = {}

local OBJ_KEY = "__agentmap_obj"
local ARR_KEY = "__agentmap_arr"
local function tr(key, vars) return require("agentmap.i18n").t(key, vars) end

--- New ordered JSON object.
--- 並び順つきの入れ物（JSON のオブジェクト）を作る
function M.object()
  return setmetatable({}, { [OBJ_KEY] = true, order = {} })
end

--- New JSON array (written as [] even when empty).
--- 配列を作る（空でも [] として書き出される）
function M.array(list)
  return setmetatable(list or {}, { [ARR_KEY] = true })
end

--- Ordered object from a list of { key, value } pairs.
--- 並び順つきで作る：M.obj({ {"a", 1}, {"b", 2} })
function M.obj(pairs_list)
  local o = M.object()
  for _, kv in ipairs(pairs_list) do M.set(o, kv[1], kv[2]) end
  return o
end

local function is_obj(t)
  local mt = getmetatable(t)
  if mt and mt[OBJ_KEY] then return true end
  if mt and mt[ARR_KEY] then return false end
  if mt and next(t) == nil then return true end -- vim.empty_dict() など
  if next(t) == nil then return false end
  return not vim.islist(t)
end

--- Keys of an object in output order.
--- 書き出すときの項目の順番
function M.keys(t)
  local mt = getmetatable(t)
  local out, seen = {}, {}
  if mt and mt.order then
    for _, k in ipairs(mt.order) do
      if t[k] ~= nil and not seen[k] then
        out[#out + 1] = k
        seen[k] = true
      end
    end
  end
  local rest = {}
  for k in pairs(t) do
    if not seen[k] then rest[#rest + 1] = k end
  end
  table.sort(rest, function(a, b) return tostring(a) < tostring(b) end)
  vim.list_extend(out, rest)
  return out
end

--- Set a value (new keys go last).
--- 値を入れる（新しい項目は最後に並ぶ）
function M.set(t, k, v)
  local mt = getmetatable(t)
  if t[k] == nil and mt and mt.order then table.insert(mt.order, k) end
  t[k] = v
end

--- Delete a key.
--- 項目を消す
function M.del(t, k)
  t[k] = nil
  local mt = getmetatable(t)
  if mt and mt.order then
    for i = #mt.order, 1, -1 do
      if mt.order[i] == k then table.remove(mt.order, i) end
    end
  end
end

--- Deep copy, keeping key order.
--- 並び順ごと丸ごと複製する（元の入れ物に影響しない）
function M.copy(v)
  if type(v) ~= "table" then return v end
  if v == vim.NIL then return v end
  if is_obj(v) then
    local o = M.object()
    for _, k in ipairs(M.keys(v)) do M.set(o, k, M.copy(v[k])) end
    return o
  end
  local a = M.array()
  for i, x in ipairs(v) do a[i] = M.copy(x) end
  return a
end

-- ------------------------------------------------------------
-- 読み取り
-- ------------------------------------------------------------
local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

--- Decode JSON text into ordered tables. Raises an error with a readable message.
--- JSON の文字を読んで、並び順つきの表にする
function M.decode(s)
  local pos = 1
  local function fail(msg)
    error(tr("jsonfmt.cannot_read", { pos = pos, msg = tr(msg) }), 0)
  end
  local function ws() pos = s:find("[^ \t\r\n]", pos) or (#s + 1) end

  local function str()
    local buf, i = {}, pos + 1
    while true do
      local j = s:find('["\\]', i)
      if not j then fail("jsonfmt.unclosed_string") end
      buf[#buf + 1] = s:sub(i, j - 1)
      if s:sub(j, j) == '"' then
        pos = j + 1
        return table.concat(buf)
      end
      local e = s:sub(j + 1, j + 1)
      if ESC[e] then
        buf[#buf + 1] = ESC[e]
        i = j + 2
      elseif e == "u" then
        local cp = tonumber(s:sub(j + 2, j + 5), 16)
        if not cp then fail("jsonfmt.bad_unicode") end
        i = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
          local lo = tonumber(s:sub(i + 2, i + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        buf[#buf + 1] = utf8_char(cp)
      else
        fail("jsonfmt.bad_escape")
      end
    end
  end

  local value
  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      local o = M.object()
      pos = pos + 1
      ws()
      if s:sub(pos, pos) == "}" then
        pos = pos + 1
        return o
      end
      while true do
        ws()
        if s:sub(pos, pos) ~= '"' then fail("jsonfmt.missing_key") end
        local k = str()
        ws()
        if s:sub(pos, pos) ~= ":" then fail("jsonfmt.missing_colon") end
        pos = pos + 1
        local v = value()
        if o[k] == nil then M.set(o, k, v) else o[k] = v end
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return o end
        if d ~= "," then fail("jsonfmt.missing_comma_brace") end
      end
    elseif c == "[" then
      local a = M.array()
      pos = pos + 1
      ws()
      if s:sub(pos, pos) == "]" then
        pos = pos + 1
        return a
      end
      while true do
        a[#a + 1] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return a end
        if d ~= "," then fail("jsonfmt.missing_comma_bracket") end
      end
    elseif c == '"' then
      return str()
    elseif s:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif s:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif s:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return vim.NIL
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" or not tonumber(num) then fail("jsonfmt.bad_value") end
      pos = pos + #num
      return tonumber(num)
    end
  end

  local v = value()
  ws()
  if pos <= #s then fail("jsonfmt.trailing") end
  return v
end

-- ------------------------------------------------------------
-- 書き出し
-- ------------------------------------------------------------
local function quote(s)
  s = s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    if c == "\b" then return "\\b" end
    if c == "\f" then return "\\f" end
    return ("\\u%04x"):format(c:byte())
  end)
  return '"' .. s .. '"'
end

local function num(n)
  if n ~= n or n == math.huge or n == -math.huge then return "null" end
  if n == math.floor(n) and math.abs(n) < 2 ^ 53 then return ("%d"):format(n) end
  for p = 14, 17 do
    local s = ("%." .. p .. "g"):format(n)
    if tonumber(s) == n then return s end
  end
  return tostring(n)
end

--- Encode with 2-space indentation (Claude Code's format), no trailing newline.
--- 字下げ 2 で書き出す（Claude Code の書式と同じ）。末尾の改行は付けない
function M.encode(v, indent)
  indent = indent or ""
  local tv = type(v)
  if v == nil or v == vim.NIL then return "null" end
  if tv == "boolean" then return tostring(v) end
  if tv == "number" then return num(v) end
  if tv == "string" then return quote(v) end
  if tv ~= "table" then return quote(tostring(v)) end
  local inner = indent .. "  "
  local parts = {}
  if is_obj(v) then
    for _, k in ipairs(M.keys(v)) do
      parts[#parts + 1] = inner .. quote(tostring(k)) .. ": " .. M.encode(v[k], inner)
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  end
  for _, x in ipairs(v) do parts[#parts + 1] = inner .. M.encode(x, inner) end
  if #parts == 0 then return "[]" end
  return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
end

--- True when both values are equal, including key order.
--- 中身が同じか（並び順も含めて比べる）
function M.equal(a, b)
  return M.encode(a) == M.encode(b)
end

return M
