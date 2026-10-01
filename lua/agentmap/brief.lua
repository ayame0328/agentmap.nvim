-- ============================================================
--  agentmap/brief.lua -- parser for the writing convention (rule 6)
--
--  Reads, in English and Japanese (both always accepted, in any mix):
--    - the parent prompt: [Goal] [Why delegate] [Done when] / 【目的】【任せる理由】【期待する結果】
--    - the child's final report: "## Report" (Done / Approach / Why / Open issues) /
--      "## 報告" (やったこと / 方向 / 理由 / 残った課題), and "## Needs confirmation"
--      (Working on / Blocked at / Question / Options) / "## 要確認" (今の作業 / 止まっている所 /
--      確認したいこと / 選択肢) with numbered options
--    - HUMAN CHECK (AskUserQuestion) option descriptions: "... -> if chosen: next" / "… → 選んだら: next"
--
--  Rules
--    - Pure functions only (plain Lua, no vim.*), so state / views / export / providers and the
--      tests can call it anywhere. The Python collector (bin/agentmap-collect) parses the brief
--      with the same rules (parity test: tests/fixtures/convention_cases.jsonl).
--    - Never guess: an item that is not written by the convention is nil. Showing a
--      "(not written)" placeholder is the caller's job (views / export).
--    - English markers, headings and item names match case-insensitively.
-- ============================================================
local M = {}

--- Markers of the parent prompt. KEYS is Japanese (kept for compatibility), KEYS_EN is English
--- (matched case-insensitively). Both are always accepted.
M.KEYS = { purpose = "【目的】", reason = "【任せる理由】", expected = "【期待する結果】" }
M.KEYS_EN = { purpose = "[Goal]", reason = "[Why delegate]", expected = "[Done when]" }
-- KEYS を決まった順に回すための並び（pairs の順は決まらないため）
local KEY_ORDER = { "purpose", "reason", "expected" }

--- Length limits (characters) shared by the collector, state and the views.
M.LIMITS = {
  brief = 300,       -- 【】の 1 項目
  report = 2000,     -- 報告・要確認の本文
  question = 300,    -- AskUserQuestion の question
  label = 60,        -- option の label
  description = 240, -- option の description
  options = 6,       -- 1 問あたりの option の数
  questions = 4,     -- 1 回あたりの question の数
}

-- 報告・要確認の項目名 → フィールド名。名前は決まり（§2 の 6-2・6-3）の文字そのもの
-- 英語の項目名は小文字で持ち、大文字小文字を無視して比べる（item_line）
local REPORT_ITEMS = { ["やったこと"] = "done", ["方向"] = "direction", ["理由"] = "reason", ["残った課題"] = "issues",
  ["done"] = "done", ["approach"] = "direction", ["why"] = "reason", ["open issues"] = "issues" }
local ASK_ITEMS = { ["今の作業"] = "working", ["止まっている所"] = "stuck", ["確認したいこと"] = "want", ["選択肢"] = "options",
  ["working on"] = "working", ["blocked at"] = "stuck", ["question"] = "want", ["options"] = "options" }
-- 見出しの語 → 種類。英語は小文字で持つ
local HEADINGS = { ["報告"] = "report", ["要確認"] = "ask", ["report"] = "report", ["needs confirmation"] = "ask" }

-- ---------- 文字の道具（UTF-8。LuaJIT には utf8 ライブラリが無いので自前） ----------

--- Trim ASCII whitespace and U+3000 (ideographic space) on both ends.
local function trim(s)
  if type(s) ~= "string" then return s end
  local changed = true
  while changed do
    changed = false
    local a = s:match("^%s+(.*)$")
    if a then s, changed = a, true end
    if s:sub(1, 3) == "\227\128\128" then s, changed = s:sub(4), true end -- U+3000（全角空白）
    local b = s:match("^(.-)%s+$")
    if b then s, changed = b, true end
    if #s >= 3 and s:sub(-3) == "\227\128\128" then s, changed = s:sub(1, -4), true end
  end
  return s
end
M.trim = trim

--- Clip to the first n characters (UTF-8 characters, not bytes), without an ellipsis (same as the collector).
function M.clip(s, n)
  if type(s) ~= "string" or not n then return s end
  local count, i, len = 0, 1, #s
  while i <= len do
    if count == n then return s:sub(1, i - 1) end
    local c = s:byte(i)
    -- 先頭バイトから、その文字が何バイトかを決める（壊れたバイトは 1 バイトとして数える）
    local w = (c >= 0xF0 and 4) or (c >= 0xE0 and 3) or (c >= 0xC0 and 2) or 1
    i = i + w
    count = count + 1
  end
  return s
end

--- 空文字は nil にする（「書かれていない」と同じ扱いにするため）
local function nonempty(s)
  if type(s) ~= "string" then return nil end
  s = trim(s)
  if s == "" then return nil end
  return s
end

-- ---------- 親の指示：【目的】【任せる理由】【期待する結果】 ----------

-- 英語のマーカーを大文字小文字を無視して探す。ASCII の小文字化はバイト位置を変えないので、
-- 小文字にした文で探した位置をそのまま元の文に使える
local function find_ci(lower_text, marker, init)
  return lower_text:find(marker:lower(), init or 1, true)
end

-- 値の終わり：次の改行、次の「【」、次の英語のマーカー（[Goal] [Why delegate] [Done when]）のうち一番近いもの
local function value_end(rest, lower_rest)
  local stop = #rest + 1
  local nl = rest:find("\n", 1, true)
  if nl and nl < stop then stop = nl end
  local br = rest:find("【", 1, true)
  if br and br < stop then stop = br end
  for _, k in ipairs(KEY_ORDER) do
    local m = find_ci(lower_rest, M.KEYS_EN[k])
    if m and m < stop then stop = m end
  end
  return stop
end

--- Extract the three brief fields from a parent prompt. Returns nil when none is written.
---   Markers: [Goal] / 【目的】, [Why delegate] / 【任せる理由】, [Done when] / 【期待する結果】
---   (English case-insensitive). The marker may be anywhere; the earliest occurrence of either
---   language wins. The value runs to the next newline, the next "【" or the next English marker;
---   a leading ":" / "：" is dropped, the value is trimmed and clipped to LIMITS.brief characters.
---@param text string|nil
---@return table|nil  { purpose?, reason?, expected? }
function M.parse_brief(text)
  if type(text) ~= "string" or text == "" then return nil end
  local lower = text:lower()
  local out, any = {}, false
  for _, k in ipairs(KEY_ORDER) do
    -- 日本語と英語のうち、先に出てきた方（指示の先頭 3 行が正なので）
    local s1, e1 = text:find(M.KEYS[k], 1, true)
    local s2, e2 = find_ci(lower, M.KEYS_EN[k])
    local e
    if s1 and (not s2 or s1 < s2) then e = e1 else e = e2 end
    if e then
      local rest = text:sub(e + 1)
      local stop = value_end(rest, lower:sub(e + 1))
      local v = trim(rest:sub(1, stop - 1))
      -- 「【目的】：〜」「[Goal]: …」のように書かれたときのコロンを落とす
      v = v:gsub("^：", ""):gsub("^:", "")
      v = nonempty(v)
      if v then
        out[k] = M.clip(v, M.LIMITS.brief)
        any = true
      end
    end
  end
  return any and out or nil
end

-- ---------- 子の報告：## 報告 / ## 要確認 ----------

--- 見出しの行なら "report" / "ask"、そうでなければ nil。もう 1 つの戻り値は「何かの見出しか」
--   # は 2〜3 個。見出し名の後ろは空か、空白・括弧・コロンで始まるものだけ（「## 報告書」「## Reports」は別物）
--   英語の見出しは大文字小文字を無視する
local function heading_kind(line)
  local hashes, rest = line:match("^%s*(#+)%s*(.-)%s*$")
  if not hashes then return nil, false end
  if #hashes < 2 or #hashes > 3 then return nil, true end
  local lrest = rest:lower()
  for word, kind in pairs(HEADINGS) do
    if lrest:sub(1, #word) == word then
      local after = rest:sub(#word + 1)
      if after == "" or after:match("^%s") or after:sub(1, 3) == "（" or after:sub(1, 1) == "("
          or after:sub(1, 1) == ":" or after:sub(1, 3) == "：" then
        return kind, true
      end
    end
  end
  return nil, true
end

--- 項目の行なら 項目名, 行の残り。名前は items に載っているものだけ
--   書き方："- 項目名:" / "- 項目名：" / "項目名:"（行頭。前の空白・"*"・"・" も可）。英語は "- Done:" など
local function item_line(line, items)
  -- 「- **今の作業**：」のような太字の項目名も受ける（実物の子がこう書いた。2026-10-01）
  local s = trim((line:gsub("%*%*", ""):gsub("__", "")))
  if s:sub(1, 1) == "-" or s:sub(1, 1) == "*" then
    s = trim(s:sub(2))
  elseif s:sub(1, 3) == "・" then
    s = trim(s:sub(4))
  end
  local ls = s:lower() -- 英語の項目名は大文字小文字を無視（ASCII だけ小文字になるのでバイト位置は同じ）
  for name in pairs(items) do
    if ls:sub(1, #name) == name then
      local after = trim(s:sub(#name + 1))
      if after:sub(1, 1) == ":" then return name, trim(after:sub(2)) end
      if after:sub(1, 3) == "：" then return name, trim(after:sub(4)) end
    end
  end
  return nil
end

--- 「名前 → 進め方」を分ける。→ が無ければ next = nil
local function split_arrow(s)
  local a, b = s:find("→", 1, true)
  if not a then a, b = s:find("->", 1, true) end
  if not a then return nonempty(s), nil end
  return nonempty(s:sub(1, a - 1)), nonempty(s:sub(b + 1))
end

--- 選択肢の行なら { n, name, next }。"1. 名前 → 進め方" / "1) 名前 -> 進め方"
local function option_line(line)
  line = line:gsub("%*%*", "")
  local n, body = trim(line):match("^(%d+)[%.%)]%s*(.*)$")
  if not n then
    -- 全角の「１．」「１）」も受ける（日本語入力のまま書かれることがあるため）
    local s = trim(line)
    local digit = s:sub(1, 3)
    local map = { ["１"] = 1, ["２"] = 2, ["３"] = 3, ["４"] = 4, ["５"] = 5, ["６"] = 6, ["７"] = 7, ["８"] = 8, ["９"] = 9 }
    if map[digit] then
      local sep = s:sub(4, 6)
      if sep == "．" or sep == "）" then n, body = map[digit], s:sub(7) end
    end
    if not n then return nil end
  end
  local name, nxt = split_arrow(body)
  if not name then return nil end
  return { n = tonumber(n), name = name, next = nxt }
end

--- 1 つの節（見出しの次の行から、次の見出しの前まで）の項目を読む
local function parse_section(lines, from, to, items)
  local out, cur, buf = {}, nil, nil
  local options, last_opt = nil, nil
  local blanks = 0
  local function flush()
    if cur and cur ~= "options" then
      local v = nonempty(table.concat(buf, " "))
      if v then out[cur] = v end
    end
    cur, buf = nil, nil
  end
  for i = from, to do
    local line = lines[i]
    if trim(line) == "" then
      blanks = blanks + 1
      -- 空行 2 つで本文は終わり（その後ろの地の文を項目に混ぜない）
      if blanks >= 2 then flush(); last_opt = nil end
    else
      blanks = 0
      local name, rest = item_line(line, items)
      if name then
        flush()
        cur, buf = items[name], {}
        if cur == "options" then
          options = options or {}
          last_opt = nil
          -- 「- 選択肢: 1. A → x」のように同じ行に書かれた分も読む
          local o = rest ~= "" and option_line(rest)
          if o then options[#options + 1] = o; last_opt = o end
        elseif rest ~= "" then
          buf[#buf + 1] = rest
        end
      elseif cur == "options" then
        local o = option_line(line)
        if o then
          options[#options + 1] = o
          last_opt = o
        elseif last_opt then
          -- 選択肢の続きの行：進め方（無ければ名前）に足す
          if last_opt.next then last_opt.next = last_opt.next .. " " .. trim(line)
          else last_opt.name = last_opt.name .. " " .. trim(line) end
        end
      elseif cur then
        buf[#buf + 1] = trim(line)
      end
    end
  end
  flush()
  if options then out.options = options end
  return out
end

--- Parse a child's final report. Always returns a table ({ kind = nil, raw = text } when nothing is found).
---   Headings "## Report" / "## 報告" and "## Needs confirmation" / "## 要確認" (2-3 "#", English
---   case-insensitive); the later heading wins. Item names of both languages are accepted under either heading.
--   kind = "report" | "ask" | nil（見出しが無い）。両方の見出しがあれば後に出てきた方
--   report: done, direction, reason, issues / ask: working, stuck, want, options = { {n, name, next} }
function M.parse_report(text)
  local res = { kind = nil, raw = text }
  if type(text) ~= "string" or text == "" then return res end
  local lines = {}
  for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  -- 見出しの位置をすべて集める（どの見出しで節が終わるかを決めるため）
  local heads = {}
  for i, line in ipairs(lines) do
    local kind, is_head = heading_kind(line)
    if is_head then heads[#heads + 1] = { i = i, kind = kind } end
  end
  local pick
  for hi, h in ipairs(heads) do
    if h.kind then pick = hi end -- 後に出てきた方を残す
  end
  if not pick then return res end
  local h = heads[pick]
  local to = heads[pick + 1] and (heads[pick + 1].i - 1) or #lines
  res.kind = h.kind
  local f = parse_section(lines, h.i + 1, to, h.kind == "report" and REPORT_ITEMS or ASK_ITEMS)
  for k, v in pairs(f) do res[k] = v end
  if h.kind == "ask" and not res.options then res.options = {} end
  return res
end

-- ---------- HUMAN CHECK：選択肢と答え ----------

-- 「→ 選んだら:」の言葉の部分。英語は大文字小文字を無視
local NEXT_WORDS = { "選んだら", "if chosen" }

--- Split an option description into the body and the next step.
---   "body -> if chosen: next" / "body → 選んだら: next" (either arrow with either word; "if chosen"
---   is case-insensitive; the colon may be ":" or "："). Arrows not followed by the word are part of
---   the body. Without the marker, returns description, nil.
---@return string|nil body, string|nil next
function M.split_next(description)
  if type(description) ~= "string" then return description, nil end
  for _, arrow in ipairs({ "→", "->" }) do
    local pos = 1
    while true do
      local a, b = description:find(arrow, pos, true)
      if not a then break end
      local after = trim(description:sub(b + 1))
      for _, word in ipairs(NEXT_WORDS) do
        if after:sub(1, #word):lower() == word then
          local rest = trim(after:sub(#word + 1))
          if rest:sub(1, 1) == ":" then rest = rest:sub(2)
          elseif rest:sub(1, 3) == "：" then rest = rest:sub(4) end
          return trim(description:sub(1, a - 1)), nonempty(rest)
        end
      end
      pos = b + 1
    end
  end
  return description, nil
end

--- Find the child's needs-confirmation option that corresponds to an answer label (or nil).
--   優先：名前が完全一致 → 前方一致（どちら向きでも。大文字小文字は無視）→ 番号 i
--   番号は「質問の選択肢の数 n と子の選択肢の数が同じ」ときだけ使う（数が違えば並びが対応しない）。
--   n を渡さなければ番号では探さない（取り違えるよりは「無い」とする）
function M.match_option(ask_options, label, i, n)
  if type(ask_options) ~= "table" then return nil end
  label = nonempty(label)
  if label then
    for _, o in ipairs(ask_options) do
      if trim(o.name or "") == label then return o end
    end
    local l = label:lower()
    for _, o in ipairs(ask_options) do
      local name = nonempty(o.name)
      if name then
        local nm = name:lower()
        if l:sub(1, #nm) == nm or nm:sub(1, #l) == l then return o end
      end
    end
  end
  if i and n and n == #ask_options then return ask_options[i] end
  return nil
end

--- Normalize an answer value to a list: string -> { s }, array -> itself, nil / "" -> {}.
function M.answer_list(v)
  if type(v) == "string" then return v ~= "" and { v } or {} end
  if type(v) == "table" then
    local out = {}
    for _, x in ipairs(v) do
      if x ~= nil and x ~= "" then out[#out + 1] = tostring(x) end
    end
    return out
  end
  return {}
end

--- 答えの表から、その question の答えを引く（キーは question 文。前後の空白違いも許す）
local function answer_of(answers, question)
  if type(answers) ~= "table" or type(question) ~= "string" then return nil end
  if answers[question] ~= nil then return answers[question] end
  local q = trim(question)
  for k, v in pairs(answers) do
    if type(k) == "string" and trim(k) == q then return v end
  end
  return nil
end

--- Match each question's answer labels with its options (see the field list below).
--   戻り値：{ { qi, q = question 文, labels = {…}, option = 最初の答えの選択肢 | nil,
--             matches = { { label, option = … | nil }, … } }, … }（質問の順。答えが無い質問は labels = {}）
--   option = { i, label, description（→ 選んだら より前）, next }。見つからなければ nil（自由入力）
--   agent を渡すと、next が description に無いとき子の要確認から補う（next_of と同じ規則）
function M.answered_options(check, agent)
  local out = {}
  if type(check) ~= "table" or type(check.questions) ~= "table" then return out end
  for qi, q in ipairs(check.questions) do
    local labels = M.answer_list(answer_of(check.answers, q.question))
    local entry = { qi = qi, q = q.question, labels = labels, matches = {} }
    for _, label in ipairs(labels) do
      local found
      for oi, o in ipairs(q.options or {}) do
        if o.label == label or trim(o.label or "") == trim(label) then
          local body = M.split_next(o.description)
          found = { i = oi, label = o.label, description = body, next = M.next_of(check, qi, oi, agent) }
          break
        end
      end
      entry.matches[#entry.matches + 1] = { label = label, option = found }
      if entry.option == nil and found then entry.option = found end
    end
    out[#out + 1] = entry
  end
  return out
end

--- Next step after choosing option option_i of question qi (description marker, then the child's options, else nil).
--   優先：option.description の「→ 選んだら:」→ 結びついた子の要確認の選択肢（match_option）→ nil
function M.next_of(check, qi, option_i, agent)
  local q = type(check) == "table" and type(check.questions) == "table" and check.questions[qi]
  local o = q and type(q.options) == "table" and q.options[option_i]
  if not o then return nil end
  local _, nxt = M.split_next(o.description)
  if nxt then return nxt end
  local ask = type(agent) == "table" and agent.ask
  if type(ask) == "table" and type(ask.options) == "table" then
    local m = M.match_option(ask.options, o.label, option_i, #q.options)
    if m then return m.next end
  end
  return nil
end

return M
