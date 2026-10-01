-- Tests of agentmap.md, the bundled Markdown -> HTML converter (DESIGN §10.1).
--   書き出しが使う範囲（front matter・見出し・段落・入れ子の箇条書き・番号付き・表・囲みのコード・
--   引用・横線・太字・`code`）だけを、出てくる HTML の文字そのもので確かめる。
local t = require("t")
local md = require("agentmap.md")
require("agentmap.i18n").setup("en")

local function body(html)
  return html:match("<main>\n(.*)\n</main>") or ""
end

-- 1. 文書の形：単体で開ける・外部の読み込みなし・明暗の配色
local h = md.to_html("---\ntitle: Doc T\ndate: 2026-10-01\n---\n\n# Head\n\ntext\n")
t.matches(h, "^<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf%-8\">", "文書の始まり")
t.matches(h, "<title>Doc T</title>", "題名は front matter の title")
t.matches(h, "<style>", "CSS は中に書く")
t.matches(h, "@media %(prefers%-color%-scheme: dark%)", "暗い配色")
t.matches(h, "</main>\n</body>\n</html>\n$", "文書の終わり")
t.ok(not h:find("<script", 1, true) and not h:find("<link", 1, true) and not h:find("https?://")
  and not h:find("url%(") and not h:find("@import", 1, true), "外部の読み込みが無い")
t.matches(h, '<p class="meta">Doc T · 2026%-10%-01</p>', "front matter の見出し行")
t.ok(not body(h):find("title:", 1, true), "front matter は本文に出さない")
t.matches(md.to_html("# Head\n", { title = "Given <T>" }), "<title>Given &lt;T&gt;</title>", "opts.title が優先・置き換え済み")
t.matches(md.to_html("# Only h1\n"), "<title>Only h1</title>", "front matter が無ければ最初の h1")
t.matches(md.to_html("x", { lang = "ja" }), '<html lang="ja">', "opts.lang")

-- 2. 見出し・段落・横線・飾り
local b = body(md.to_html("# A & B\n\n## Two\n\n### Three\n\npara **bold** and `a<b>` & <x>\nnext line\n\n---\n\nafter\n", { toc = false }))
t.eq(b, table.concat({
  '<h1 id="sec-1">A &amp; B</h1>',
  '<h2 id="sec-2">Two</h2>',
  '<h3 id="sec-3">Three</h3>',
  "<p>para <strong>bold</strong> and <code>a&lt;b&gt;</code> &amp; &lt;x&gt;\nnext line</p>",
  "<hr>",
  "<p>after</p>",
}, "\n"), "見出し・段落・横線・飾り")
t.eq(body(md.to_html("`**not bold**` **b `c` d**", { toc = false })),
  "<p><code>**not bold**</code> <strong>b <code>c</code> d</strong></p>", "code の中は太字にしない")

-- 3. 目次：## が 2 つ以上あれば h1 の直後に
local toc = body(md.to_html("# T\n\n## One\n\n## Two `x`\n"))
t.eq(toc, table.concat({
  '<h1 id="sec-1">T</h1>',
  '<nav class="toc">',
  "<p>Contents</p>",
  "<ul>",
  '<li><a href="#sec-2">One</a></li>',
  '<li><a href="#sec-3">Two <code>x</code></a></li>',
  "</ul>",
  "</nav>",
  '<h2 id="sec-2">One</h2>',
  '<h2 id="sec-3">Two <code>x</code></h2>',
}, "\n"), "目次と見出しへのリンク")
t.ok(not md.to_html("# T\n\n## Only\n"):find("<nav", 1, true), "## が 1 つなら目次を出さない")
t.ok(not md.to_html("## A\n\n## B\n", { toc = false }):find("<nav", 1, true), "toc = false")
require("agentmap.i18n").setup("ja")
t.matches(md.to_html("## A\n\n## B\n"), "<p>目次</p>", "日本語の目次")
require("agentmap.i18n").setup("en")

-- 4. 箇条書き：入れ子（2 字下げ）・番号付き・種類の切り替え
local l = body(md.to_html("- a\n- b **x**\n  1. one\n  2. two\n    - deep\n- c\n  - sub\n\nend\n", { toc = false }))
t.eq(l, table.concat({
  "<ul>\n<li>a</li>\n<li>b <strong>x</strong>",
  "<ol>\n<li>one</li>\n<li>two",
  "<ul>\n<li>deep</li></ul></li></ol></li>\n<li>c",
  "<ul>\n<li>sub</li></ul></li></ul>",
  "<p>end</p>",
}, "\n"), "入れ子の箇条書き")
t.eq(body(md.to_html("3. x\n4. y\n", { toc = false })), '<ol start="3">\n<li>x</li>\n<li>y</li></ol>', "1 以外から始まる番号")
t.eq(body(md.to_html("- a\n1. b\n", { toc = false })), "<ul>\n<li>a</li></ul><ol>\n<li>b</li></ol>", "同じ深さで種類が変わる")

-- 5. 表：\| はマスの中の |、列が足りない行は空のマス
local tb = body(md.to_html("| a | b |\n|---|---|\n| 1 \\| 2 | `x\\|y` |\n| only |\n\nafter\n", { toc = false }))
t.eq(tb, table.concat({
  '<div class="table-wrap"><table>',
  "<thead><tr>",
  "<th>a</th>",
  "<th>b</th>",
  "</tr></thead>",
  "<tbody>",
  "<tr><td>1 | 2</td><td><code>x|y</code></td></tr>",
  "<tr><td>only</td><td></td></tr>",
  "</tbody></table></div>",
  "<p>after</p>",
}, "\n"), "表")
t.eq(body(md.to_html("| not a table\nline\n", { toc = false })), "<p>| not a table\nline</p>", "区切り行が無ければ段落")

-- 6. 囲みのコード：mermaid は元の文のまま・言語・中身の置き換え
local cb = body(md.to_html("```mermaid\nflowchart LR\n  a --> b\n```\n\n```text\n<x> & **y**\n```\n\n```\nplain\n```\n", { toc = false }))
t.eq(cb, table.concat({
  '<pre class="mermaid">flowchart LR\n  a --&gt; b</pre>',
  '<pre><code class="language-text">&lt;x&gt; &amp; **y**</code></pre>',
  "<pre><code>plain</code></pre>",
}, "\n"), "囲みのコード")
t.eq(body(md.to_html("```text\n## not heading\n- not list\n```\n", { toc = false })),
  '<pre><code class="language-text">## not heading\n- not list</code></pre>', "コードの中は解釈しない")

-- 7. 引用：行ごとに改行、> だけの行で段落を分ける
local q = body(md.to_html("**L**\n\n> a: 1\n> b: <2>\n>\n> c\n", { toc = false }))
t.eq(q, table.concat({
  "<p><strong>L</strong></p>",
  "<blockquote>\n<p>a: 1<br>\nb: &lt;2&gt;</p>\n<p>c</p>\n</blockquote>",
}, "\n"), "引用")

-- 8. export.to_markdown の出力を丸ごと通しても壊れない（タグの数が釣り合う）
local export = require("agentmap.export")
local s = dofile(vim.g.agentmap_test_dir .. "/fixtures/state_check.lua")
local full = md.to_html(export.to_markdown(s, { source = "hooks" }))
for _, tag in ipairs({ "ul", "ol", "li", "table", "tr", "blockquote", "pre", "p", "h2", "h3", "code" }) do
  local open = select(2, full:gsub("<" .. tag .. "[ >]", ""))
  local close = select(2, full:gsub("</" .. tag .. ">", ""))
  t.eq(open, close, "開きと閉じの数が同じ: " .. tag)
end
t.matches(full, '<pre class="mermaid">flowchart LR\n', "書き出しの Mermaid")
t.matches(full, "<td>Human checks</td><td>2 %(1 unanswered%)</td>", "書き出しの表")

t.done()
