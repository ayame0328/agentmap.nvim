-- 画面の行き来のテスト
--   図 → Enter → 詳細 → t → transcript → BS → 詳細 → BS → 図
--   z と BS で部分表示の出入り、+ / - で畳む・開く、数字キー、n / p
--   実行: nvim --headless --clean -l tests/test_nav.lua
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local cfgdir = vim.fn.fnamemodify(here, ":h:h")
vim.opt.rtp:prepend(cfgdir)
vim.o.columns, vim.o.lines = 200, 50

local fails, passes = 0, 0
local function ok(cond, msg)
  if cond then passes = passes + 1 else
    fails = fails + 1
    io.stderr:write("  NG: " .. msg .. "\n")
  end
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end
local function bufname() return vim.api.nvim_buf_get_name(0) end
local function buftext() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end

local state = dofile(here .. "/fixtures/state_small.lua")
state.agents.a2.transcript_path = here .. "/fixtures/transcript_small.jsonl"
local run = { dir = vim.fn.tempname(), sid = state.run_id, state = state }

local ui = require("agentmap.ui")
local notes = {}
vim.notify = function(m) notes[#notes + 1] = m end

ui.open_map(run)
ok(bufname():find("agentmap://map/", 1, true) ~= nil, "図のバッファが開く: " .. bufname())
ok(buftext():find("[REWORK]", 1, true) ~= nil, "図に状態の文字")
ok(vim.bo.modifiable == false and vim.bo.buftype == "nofile", "図は書き換え不可の nofile")
ok(ui.current_id() == "ROOT", "開いた直後のカーソルは ROOT（実際: " .. tostring(ui.current_id()) .. "）")
local map_buf = vim.api.nvim_get_current_buf()
ok(vim.fn.maparg("<CR>", "n", false, true).buffer == 1, "Enter はバッファ専用の割り当て")

-- n で次の箱へ、[2] まで進める
local seen = {}
for _ = 1, 6 do
  feed("n")
  seen[#seen + 1] = ui.current_id()
end
ok(vim.tbl_contains(seen, "a1") and vim.tbl_contains(seen, "a2") and vim.tbl_contains(seen, "gate:a2"), "n で箱を順に回る: " .. table.concat(seen, ","))
feed("p")
ok(ui.current_id() ~= nil, "p で前の箱へ")

-- a2 に合わせて Enter → 詳細
local r = require("agentmap.renderer").rows_of(ui.cache, "a2")
vim.api.nvim_win_set_cursor(0, { r[1] + 1, r.starts[r[1] + 1] + 4 })
ok(ui.current_id() == "a2", "カーソル → a2")
feed("<CR>")
ok(bufname():find("agentmap://detail/a2", 1, true) ~= nil, "Enter で詳細: " .. bufname())
ok(buftext():find('RETRY (user) "テストが無い"', 1, true) ~= nil, "詳細に差し戻し履歴")
ok(buftext():find("■ Child agents", 1, true) ~= nil, "詳細に子 Agent の欄")
ok(#vim.api.nvim_tabpage_list_wins(0) == 2, "詳細は右側の補助ウィンドウ（同じタブ）")

-- t → transcript
feed("t")
ok(bufname():find("agentmap://transcript/a2", 1, true) ~= nil, "t で transcript: " .. bufname())
local tt = buftext()
ok(tt:find("▶ USER", 1, true) and tt:find("◀ ASSISTANT", 1, true) and tt:find("⚙ Write", 1, true), "transcript の中身")
ok(#vim.api.nvim_tabpage_list_wins(0) == 2, "transcript も同じ補助ウィンドウ")

-- BS → 詳細 → BS → 図
feed("<BS>")
ok(bufname():find("agentmap://detail/a2", 1, true) ~= nil, "BS で詳細へ戻る: " .. bufname())
feed("<BS>")
ok(vim.api.nvim_get_current_buf() == map_buf, "もう一度 BS で図へ戻る")
ok(#vim.api.nvim_tabpage_list_wins(0) == 1, "補助ウィンドウは閉じる")

-- 数字キー 1 → [1] の詳細、Enter で子 [3] の詳細、BS で [1]
feed("1")
ok(bufname():find("agentmap://detail/a1", 1, true) ~= nil, "1 で [1] の詳細: " .. bufname())
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
for i, l in ipairs(lines) do
  if l:find("[3] 孫", 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }) end
end
feed("<CR>")
ok(bufname():find("agentmap://detail/g1", 1, true) ~= nil, "子の行で Enter → [3] の詳細: " .. bufname())
feed("<BS>")
ok(bufname():find("agentmap://detail/a1", 1, true) ~= nil, "BS で [1] に戻る")
feed("q")
ok(vim.api.nvim_get_current_buf() == map_buf, "q で補助ウィンドウを閉じて図へ")

-- d → diff（git リポジトリでない場所なので、その旨が出る）
vim.api.nvim_win_set_cursor(0, { r[1] + 1, r.starts[r[1] + 1] + 4 })
feed("d")
ok(bufname():find("agentmap://diff/a2", 1, true) ~= nil, "d で diff: " .. bufname())
vim.wait(2000, function() return not buftext():find("取得中", 1, true) end)
ok(buftext():find("Not a git repository", 1, true) ~= nil, "リポジトリでなければその旨を表示")
feed("<BS>")
ok(vim.api.nvim_get_current_buf() == map_buf, "diff から BS で図へ")

-- z（部分表示）と BS
local r1 = require("agentmap.renderer").rows_of(ui.cache, "a1")
vim.api.nvim_win_set_cursor(0, { r1[1] + 1, r1.starts[r1[1] + 1] + 4 })
feed("z")
ok(ui.view.root == "a1", "z で a1 から下だけ表示")
ok(not buftext():find("ROOT  c0ff", 1, true), "部分表示では ROOT の箱が消える")
ok(buftext():find("zoomed:", 1, true) ~= nil, "見出しに部分表示（zoomed:）と出る")
ok(ui.current_id() == "a1", "カーソルは a1 に置かれる")
feed("<BS>")
ok(ui.view.root == "ROOT", "BS で ROOT に戻る")
ok(buftext():find("ROOT  c0ff", 1, true) ~= nil, "ROOT の箱が戻る")
ok(ui.current_id() == "a1", "カーソルは a1 のまま")

-- - で畳む、+ で開く
feed("-")
ok(ui.view.collapsed.a1 == true, "- で a1 を畳む")
ok(buftext():find("[+1]", 1, true) ~= nil and not buftext():find("孫：keymap", 1, true), "畳むと [+1] になり子が消える")
feed("+")
ok(ui.view.collapsed.a1 == nil and buftext():find("孫：keymap", 1, true), "+ で開く")

-- v で一覧に切替、もう一度で図
feed("v")
ok(ui.layout.mode == "tree", "v で一覧")
ok(buftext():find("├─ [1]", 1, true) ~= nil, "一覧の枝が出る")
feed("v")
ok(ui.layout.mode == "box", "もう一度 v で図")

-- 状態が変わったら refresh で反映（変わった行だけ）
state.agents.a2.status = "DONE"
ui.refresh()
ok(buftext():find("~100%", 1, true) ~= nil, "refresh で ROOT の進捗が ~100% に")

-- 9 は無い番号 → 知らせるだけ
feed("9")
ok(vim.api.nvim_get_current_buf() == map_buf, "無い番号では何も開かない")

-- q で図を閉じる
feed("q")
ok(ui.buf == nil, "q で図を閉じる")

io.write(string.format("test_nav: %d ok, %d NG\n", passes, fails))
os.exit(fails == 0 and 0 or 1)
