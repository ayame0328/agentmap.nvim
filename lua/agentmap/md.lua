-- ============================================================
--  agentmap/md.lua ... bundled Markdown -> HTML converter (DESIGN §10.1, D4).
--    Supports exactly the subset export.to_markdown() writes: front matter,
--    # / ## / ### headings, paragraphs, "- " lists nested by two spaces,
--    "1. " lists, pipe tables, fenced code (```mermaid stays as source text in
--    <pre class="mermaid">), "> " block quotes, "---" rules, **bold**, `code`.
--    The result is one self-contained HTML file: inline CSS, light / dark via
--    prefers-color-scheme, no external resources.
--    Pure Lua except for the optional i18n lookup of the table-of-contents label.
-- ============================================================
local M = {}

-- ------------------------------------------------------------
-- 文字の置き換え
-- ------------------------------------------------------------
local function esc(s)
  return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function esc_attr(s)
  return (esc(s):gsub('"', "&quot;"))
end

--- 行の中の飾り：`code` と **bold**。それ以外は & < > を置き換えるだけ。
--   code の中身は先に印（\2番号\2）に置き換えて守り、太字を付けてから戻す
local function inline(s)
  local codes = {}
  s = tostring(s or ""):gsub("\2", "")
  s = s:gsub("`([^`]*)`", function(c)
    codes[#codes + 1] = "<code>" .. esc(c) .. "</code>"
    return "\2" .. #codes .. "\2"
  end)
  s = esc(s):gsub("%*%*(.-)%*%*", "<strong>%1</strong>")
  return (s:gsub("\2(%d+)\2", function(k) return codes[tonumber(k)] end))
end

-- ------------------------------------------------------------
-- 表
-- ------------------------------------------------------------
local PIPE = "\1"

--- "| a | b \| c |" → { "a", "b | c" }（\| はマスの中の | として残す）
local function split_row(line)
  line = line:gsub("\\|", PIPE):gsub("^%s*|", ""):gsub("|%s*$", "")
  local cells = {}
  for c in (line .. "|"):gmatch("(.-)|") do
    cells[#cells + 1] = (c:gsub("^%s+", ""):gsub("%s+$", ""):gsub(PIPE, "|"))
  end
  return cells
end

local function is_table_sep(line)
  return line ~= nil and line:match("^%s*|[%s:|%-]+|?%s*$") ~= nil and line:find("-", 1, true) ~= nil
end

-- ------------------------------------------------------------
-- CSS（明暗の両方。外部の読み込みはしない）
-- ------------------------------------------------------------
M.CSS = [[
:root {
  --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0;
  --code-bg: #f6f8fa; --quote: #59636e; --accent: #0969da; --row: #f6f8fa;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --border: #3d444d;
    --code-bg: #151b23; --quote: #9198a1; --accent: #4493f8; --row: #151b23;
  }
}
* { box-sizing: border-box; }
html { color-scheme: light dark; }
body {
  margin: 0; background: var(--bg); color: var(--fg);
  font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", "Hiragino Sans", "Yu Gothic UI", Meiryo, sans-serif;
}
main { max-width: 1100px; margin: 0 auto; padding: 24px 16px 48px; }
.meta { color: var(--muted); font-size: 13px; margin: 0 0 8px; }
h1, h2, h3 { line-height: 1.3; margin: 1.6em 0 0.6em; }
h1 { font-size: 1.7em; margin-top: 0.4em; }
h2 { font-size: 1.35em; border-bottom: 1px solid var(--border); padding-bottom: 0.25em; }
h3 { font-size: 1.1em; }
a { color: var(--accent); }
nav.toc { border: 1px solid var(--border); border-radius: 6px; padding: 8px 16px; margin: 16px 0; }
nav.toc p { margin: 4px 0; font-weight: 600; }
nav.toc ul { margin: 4px 0; padding-left: 20px; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.9em;
  background: var(--code-bg); border-radius: 4px; padding: 0.1em 0.35em; }
pre { background: var(--code-bg); border: 1px solid var(--border); border-radius: 6px; padding: 12px;
  overflow-x: auto; line-height: 1.45; }
pre code { background: none; padding: 0; font-size: 13px; }
pre.mermaid { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12px; color: var(--muted); }
.table-wrap { overflow-x: auto; margin: 12px 0; }
table { border-collapse: collapse; font-size: 14px; }
th, td { border: 1px solid var(--border); padding: 4px 10px; text-align: left; vertical-align: top; }
th { background: var(--row); }
blockquote { margin: 8px 0; padding: 4px 14px; color: var(--quote); border-left: 4px solid var(--border); }
blockquote p { margin: 6px 0; }
hr { border: 0; border-top: 1px solid var(--border); margin: 24px 0; }
li { margin: 2px 0; }
@media print { nav.toc { display: none; } pre { white-space: pre-wrap; } }
]]

local function toc_label()
  local ok, i18n = pcall(require, "agentmap.i18n")
  if ok and i18n and i18n.t then return i18n.t("md.toc") end
  return "Contents"
end

local function html_lang()
  local ok, i18n = pcall(require, "agentmap.i18n")
  return ok and i18n and i18n.lang or "en"
end

-- ------------------------------------------------------------
-- 本体
-- ------------------------------------------------------------

--- Convert Markdown (the subset written by export.to_markdown) to a standalone HTML page.
---@param markdown string
---@param opts? { title?: string, toc?: boolean, lang?: string }  toc defaults to true
---@return string html
function M.to_html(markdown, opts)
  opts = opts or {}
  local lines = {}
  for l in (tostring(markdown or ""):gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end

  local body, toc = {}, {}
  local function emit(s) body[#body + 1] = s end
  local i, n = 1, #lines

  -- front matter（--- から --- まで）
  local fm = {}
  if lines[1] == "---" then
    for j = 2, n do
      if lines[j] == "---" then
        for k = 2, j - 1 do
          local key, val = lines[k]:match("^([%w_]+):%s*(.-)%s*$")
          if key then fm[key] = val end
        end
        i = j + 1
        break
      end
    end
  end

  local para = {}
  local function flush_para()
    if #para > 0 then
      emit("<p>" .. table.concat(para, "\n") .. "</p>")
      para = {}
    end
  end

  local first_h1
  local hn = 0

  while i <= n do
    local line = lines[i]
    local fence_lang = line:match("^```(%S*)%s*$")
    if fence_lang then
      flush_para()
      local code = {}
      i = i + 1
      while i <= n and lines[i] ~= "```" do
        code[#code + 1] = lines[i]
        i = i + 1
      end
      i = i + 1 -- 閉じの ```
      local text = esc(table.concat(code, "\n"))
      if fence_lang == "mermaid" then
        emit('<pre class="mermaid">' .. text .. "</pre>")
      elseif fence_lang ~= "" then
        emit('<pre><code class="language-' .. esc_attr(fence_lang) .. '">' .. text .. "</code></pre>")
      else
        emit("<pre><code>" .. text .. "</code></pre>")
      end
    elseif line:match("^%s*$") then
      flush_para()
      i = i + 1
    elseif line:match("^#+%s") and #line:match("^(#+)") <= 6 then
      flush_para()
      local hashes, text = line:match("^(#+)%s+(.-)%s*$")
      local lv = #hashes
      hn = hn + 1
      local id = "sec-" .. hn
      if lv == 1 and not first_h1 then first_h1 = text end
      if lv == 2 then toc[#toc + 1] = { id = id, text = text } end
      emit(("<h%d id=\"%s\">%s</h%d>"):format(lv, id, inline(text), lv))
      i = i + 1
    elseif line:match("^%-%-%-+%s*$") then
      flush_para()
      emit("<hr>")
      i = i + 1
    elseif line:match("^>") then
      flush_para()
      local paras, cur = {}, {}
      while i <= n and lines[i]:match("^>") do
        local inner = lines[i]:gsub("^> ?", "")
        if inner:match("^%s*$") then
          if #cur > 0 then paras[#paras + 1] = cur end
          cur = {}
        else
          cur[#cur + 1] = inline(inner)
        end
        i = i + 1
      end
      if #cur > 0 then paras[#paras + 1] = cur end
      local out = {}
      for _, p in ipairs(paras) do out[#out + 1] = "<p>" .. table.concat(p, "<br>\n") .. "</p>" end
      emit("<blockquote>\n" .. table.concat(out, "\n") .. "\n</blockquote>")
    elseif line:match("^%s*|") and is_table_sep(lines[i + 1]) then
      flush_para()
      local head = split_row(line)
      local t = { '<div class="table-wrap"><table>', "<thead><tr>" }
      for _, c in ipairs(head) do t[#t + 1] = "<th>" .. inline(c) .. "</th>" end
      t[#t + 1] = "</tr></thead>"
      t[#t + 1] = "<tbody>"
      i = i + 2
      while i <= n and lines[i]:match("^%s*|") do
        local row = split_row(lines[i])
        local tr = { "<tr>" }
        for ci = 1, math.max(#row, #head) do tr[#tr + 1] = "<td>" .. inline(row[ci] or "") .. "</td>" end
        tr[#tr + 1] = "</tr>"
        t[#t + 1] = table.concat(tr)
        i = i + 1
      end
      t[#t + 1] = "</tbody></table></div>"
      emit(table.concat(t, "\n"))
    elseif line:match("^%s*[-*] ") or line:match("^%s*%d+%. ") then
      flush_para()
      -- 入れ子の箇条書き：2 字下げで 1 段深くなる
      local stack, out = {}, {}
      while i <= n do
        local l = lines[i]
        local ind, text = l:match("^(%s*)[-*] (.*)$")
        local tag, num = "ul", nil
        if not ind then
          ind, num, text = l:match("^(%s*)(%d+)%. (.*)$")
          tag = "ol"
        end
        if not ind then break end
        local lv = math.floor(#ind / 2)
        local top = stack[#stack]
        if top and lv > top.lv then lv = top.lv + 1 end
        while #stack > 0 and stack[#stack].lv > lv do
          local s = table.remove(stack)
          out[#out + 1] = "</li></" .. s.tag .. ">"
        end
        top = stack[#stack]
        if top and top.lv == lv and top.tag ~= tag then
          table.remove(stack)
          out[#out + 1] = "</li></" .. top.tag .. ">"
          top = stack[#stack]
        end
        if top and top.lv == lv then
          out[#out + 1] = "</li>\n<li>" .. inline(text)
        else
          local open = "<" .. tag
          if tag == "ol" and num and num ~= "1" then open = open .. ' start="' .. num .. '"' end
          out[#out + 1] = (#stack > 0 and "\n" or "") .. open .. ">\n<li>" .. inline(text)
          stack[#stack + 1] = { lv = lv, tag = tag }
        end
        i = i + 1
      end
      while #stack > 0 do
        local s = table.remove(stack)
        out[#out + 1] = "</li></" .. s.tag .. ">"
      end
      emit(table.concat(out, ""))
    else
      para[#para + 1] = inline(line)
      i = i + 1
    end
  end
  flush_para()

  local title = opts.title or fm.title or first_h1 or "AgentMap"
  local head_line = {}
  if fm.title then head_line[#head_line + 1] = esc(fm.title) end
  if fm.date then head_line[#head_line + 1] = esc(fm.date) end

  local doc = {
    "<!doctype html>",
    '<html lang="' .. esc_attr(opts.lang or html_lang()) .. '">',
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    "<title>" .. esc(title) .. "</title>",
    "<style>" .. M.CSS .. "</style>",
    "</head>",
    "<body>",
    "<main>",
  }
  if #head_line > 0 then doc[#doc + 1] = '<p class="meta">' .. table.concat(head_line, " · ") .. "</p>" end
  -- 目次は最初の h1 の直後に置きたいので、本文を h1 の後ろで分ける
  local toc_html
  if opts.toc ~= false and #toc >= 2 then
    local t = { '<nav class="toc">', "<p>" .. esc(toc_label()) .. "</p>", "<ul>" }
    for _, h in ipairs(toc) do t[#t + 1] = ('<li><a href="#%s">%s</a></li>'):format(h.id, inline(h.text)) end
    t[#t + 1] = "</ul>"
    t[#t + 1] = "</nav>"
    toc_html = table.concat(t, "\n")
  end
  local placed = toc_html == nil
  for _, b in ipairs(body) do
    if not placed and not b:match("^<h1") then
      doc[#doc + 1] = toc_html
      placed = true
    end
    doc[#doc + 1] = b
  end
  if not placed then doc[#doc + 1] = toc_html end
  doc[#doc + 1] = "</main>"
  doc[#doc + 1] = "</body>"
  doc[#doc + 1] = "</html>"
  return table.concat(doc, "\n") .. "\n"
end

return M
