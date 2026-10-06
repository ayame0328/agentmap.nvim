#!/usr/bin/env bash
# Smoke test: starts Neovim with tests/minimal_init.lua (never the user's init.lua) and checks
# the entry points (DESIGN §9.2):
#   1. 8 commands exist, no global keys by default
#   2. :AgentMap on an empty store only notifies "No recorded runs"
#   3. hooks.install() twice into a temp settings.json → the second run is "no change"
#   4. :checkhealth agentmap runs and its buffer mentions agentmap
#   5. zero configuration: plugin/agentmap.lua registers the commands without setup();
#      vim.g.agentmap_lang is honored; setup({ keymaps = { global = true } }) adds the keys
# 記録の保存先・Claude の設定フォルダ・settings.json はすべて一時フォルダ。本物には触らない。
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
NVIM="${NVIM:-$(command -v nvim || echo "$HOME/.local/bin/nvim")}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

real_settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
sum() { [ -f "$1" ] && sha256sum "$1" | cut -d' ' -f1; }
before_sum="$(sum "$real_settings")"

mkdir -p "$work/claude/projects" "$work/store"
printf '{\n  "keep": "me"\n}\n' > "$work/claude/settings.json"
export CLAUDE_CONFIG_DIR="$work/claude"
export AGENTMAP_DIR="$work/store"
unset AGENTFLOW_DIR

# 判定を書いた Lua を、指定した起動方法で流す。出力は "  OK:" / "  NG:" の行だけのはず
run_check() { # $1 = 説明, $2 = Lua ファイル, 残り = nvim の引数
  local label="$1" file="$2"; shift 2
  local out code
  out="$(cd "$work" && timeout 60 "$NVIM" --headless "$@" "+lua vim.schedule(function() dofile('$file') end)" 2>&1)"; code=$?
  # :checkhealth が headless で出す進み具合の表示は除く
  out="$(printf '%s' "$out" | sed -e 's/Running healthchecks\.\.\.//g' -e 's/checkhealth: checks done//g' -e 's/checkhealth: [0-9]*% checking [A-Za-z0-9_.]*//g')"
  echo "$out"
  if [ $code -ne 0 ]; then echo "  NG: $label (exit $code)"; fail=1; fi
  if [ -n "$(printf '%s\n' "$out" | grep -v '^  OK:' | grep -v '^  NG:' | grep -v '^$')" ]; then
    echo "  NG: $label: 余計な出力がある"; fail=1
  fi
}

# 共通の小道具
cat > "$work/lib.lua" <<'LUA'
local L = { errs = {}, oks = 0, notes = {} }
function L.ok(v, msg) if v then L.oks = L.oks + 1 else L.errs[#L.errs + 1] = msg end end
vim.notify = function(msg, lvl) L.notes[#L.notes + 1] = { msg = tostring(msg), lvl = lvl } end
function L.last() return L.notes[#L.notes] and L.notes[#L.notes].msg or "" end
function L.finish(label)
  io.stdout:write(("  OK: %s %d 件\n"):format(label, L.oks))
  for _, m in ipairs(L.errs) do io.stdout:write("  NG: " .. m .. "\n") end
  io.stdout:flush()
  vim.cmd(#L.errs == 0 and "qa!" or "cq!")
end
L.COMMANDS = { "AgentMap", "AgentMapRuns", "AgentMapAgent", "AgentMapRefresh", "AgentMapExport",
  "AgentMapReview", "AgentMapInstallHooks", "AgentMapImport" }
return L
LUA

# ---------- 1〜4: tests/minimal_init.lua で起動（setup({}) 済み） ----------
cat > "$work/check.lua" <<LUA
local L = dofile("$work/lib.lua")
local ok = L.ok

ok(vim.v.errmsg == "", "起動時のエラー: " .. vim.v.errmsg)
for _, c in ipairs(L.COMMANDS) do
  ok(vim.fn.exists(":" .. c) == 2, "コマンドが無い: " .. c)
end
for _, lhs in ipairs({ "<leader>aa", "<leader>ar", "<leader>ae" }) do
  ok(vim.fn.maparg(lhs, "n") == "", "既定でグローバルキーを作らない: " .. lhs)
end
local desc = vim.api.nvim_get_commands({})["AgentMap"].definition
ok(desc == "AgentMap: open the map of the latest prompt ([session_id [prompt_id]])", "コマンドの説明は英語: " .. tostring(desc))

-- 記録が空のとき :AgentMap は知らせるだけ
local okc, e = pcall(vim.cmd, "AgentMap")
ok(okc, ":AgentMap がエラー: " .. tostring(e))
ok(L.last():find("^AgentMap: No recorded runs%.") ~= nil, ":AgentMap の知らせ: " .. L.last())
ok(vim.v.errmsg == "", ":AgentMap 後のエラー: " .. vim.v.errmsg)

-- hooks の登録（一時フォルダの settings.json）
local path = "$work/claude/settings.json"
local hooks = require("agentmap.hooks")
ok(hooks.default_path() == path, "既定の settings.json は CLAUDE_CONFIG_DIR の下: " .. hooks.default_path())
local ok1, info1 = hooks.install({ path = path, yes = true })
ok(ok1 and info1.changed, "hooks の 1 回目の登録に失敗: " .. L.last())
ok(hooks.status(path) == "installed", "登録状態が installed でない: " .. hooks.status(path))
local ok2, info2 = hooks.install({ path = path, yes = true })
ok(ok2 and not info2.changed, "hooks の 2 回目が変更ありになった")
ok(L.last():find("No change", 1, true) ~= nil, "2 回目は「No change」と知らせる: " .. L.last())
local J = require("agentmap.jsonfmt")
local saved = J.decode(table.concat(vim.fn.readfile(path), "\n"))
ok(#saved.hooks.PreToolUse == 2, "PreToolUse は 2 組（記録と修正指示の配達）でも 2 回目は変更なし")
ok(saved.hooks.PreToolUse[2].hooks[1].command:find("^%[ %-e ") ~= nil, "配達の組はシェルの門番つき")
ok(saved.hooks.PreToolUse[2].hooks[1].command:find("pause.pending", 1, true) ~= nil, "門番は pause.pending を見る（v0.1.2）")
ok(saved.hooks.PreToolUse[2].hooks[1].command:find("steer.pending", 1, true) == nil, "既定の mode stop の門番は steer.pending を見ない（v0.1.2 steer2）")
ok(saved.hooks.PreToolUse[2].hooks[1].command:find("--mode stop", 1, true) ~= nil, "門番の command は --mode stop")
ok(saved.hooks.SubagentStop[1].hooks[1].command:find("--at-stop", 1, true) == nil, "終わりの command に --at-stop は無い")
ok((saved.hooks.PostToolUse[1].matcher or ""):find("SendMessage", 1, true) ~= nil, "PostToolUse に SendMessage")
ok(saved.hooks.SubagentStop[1].hooks[1].command:find("--pause --max-wait 600", 1, true) ~= nil, "終わりの組に --pause --max-wait 600")
ok(saved.hooks.PreToolUse[2].hooks[1].timeout == 630 and saved.hooks.Stop[1].hooks[1].timeout == 630, "配達の組の timeout は 630")
local text = table.concat(vim.fn.readfile(path), "\n")
ok(text:find(hooks.plugin_dir() .. "/bin/agentmap-collect", 1, true) ~= nil, "collector の絶対パス（プラグインの bin/）が入っている")
ok(text:find("--root $work/store", 1, true) ~= nil, "--root に記録の保存先が入っている")
ok(text:find('"keep": "me"', 1, true) ~= nil, "元の設定が残っている")

-- :checkhealth agentmap
local okh, eh = pcall(vim.cmd, "checkhealth agentmap")
ok(okh, ":checkhealth agentmap がエラー: " .. tostring(eh))
local body = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
ok(body:find("agentmap", 1, true) ~= nil, "health の画面に agentmap がある")
ok(body:find("Hooks are registered in", 1, true) ~= nil, "health が登録済みと言う")
ok(body:find("Record store: $work/store (from AGENTMAP_DIR)", 1, true) ~= nil, "health が保存先と出どころを出す")
ok(not body:find("ERROR", 1, true) or body:find("Python not found", 1, true) ~= nil, "health に想定外の ERROR: " .. body)
ok(vim.fn.filereadable(path .. ".agentmap-tmp") == 0, "health は settings.json を書かない")
L.finish("minimal_init で起動")
LUA
run_check "minimal_init" "$work/check.lua" --clean -u "$here/minimal_init.lua"

# ---------- 5: setup() を呼ばない起動（plugin/agentmap.lua だけ） ----------
cat > "$work/init_plain.lua" <<LUA
vim.opt.rtp:prepend("$root")
vim.g.mapleader = " "
vim.g.agentmap_test = true
LUA
cat > "$work/check_plain.lua" <<LUA
local L = dofile("$work/lib.lua")
local ok = L.ok
for _, c in ipairs(L.COMMANDS) do
  ok(vim.fn.exists(":" .. c) == 2, "setup() 無しでもコマンドがある: " .. c)
end
ok(package.loaded["agentmap.ui"] == nil, "起動時に重いモジュールを読まない（agentmap.ui）")
local okc, e = pcall(vim.cmd, "AgentMap")
ok(okc, "setup() 無しの :AgentMap がエラー: " .. tostring(e))
ok(L.last():find("^AgentMap: No recorded runs%.") ~= nil, "setup() 無しでも知らせる: " .. L.last())
ok(vim.fn.maparg("<leader>aa", "n") == "", "setup() 無しでもグローバルキーは無い")
require("agentmap").setup({ keymaps = { global = true } })
for _, lhs in ipairs({ "<leader>aa", "<leader>ar", "<leader>ae" }) do
  ok(vim.fn.maparg(lhs, "n") ~= "", "keymaps.global = true でキーができる: " .. lhs)
end
L.finish("setup() 無しで起動")
LUA
run_check "plain" "$work/check_plain.lua" --clean -u "$work/init_plain.lua"

# vim.g.agentmap_lang = "ja"（setup() に lang が無いときだけ効く）
cat > "$work/init_ja.lua" <<LUA
vim.opt.rtp:prepend("$root")
vim.g.agentmap_lang = "ja"
vim.g.agentmap_test = true
LUA
cat > "$work/check_ja.lua" <<LUA
local L = dofile("$work/lib.lua")
local ok = L.ok
-- 説明に 0x80 を含む文字（「一」など）があると nvim_get_commands が崩して返すので、含まない説明で比べる
local function desc() return vim.api.nvim_get_commands({})["AgentMapRefresh"].definition end
ok(desc() == "AgentMap：読み直す", "plugin/ が vim.g.agentmap_lang で説明を付ける: " .. desc())
pcall(vim.cmd, "AgentMap")
ok(L.last():find("^AgentMap: 記録された run がありません。") ~= nil, "知らせも日本語: " .. L.last())
require("agentmap").setup({ lang = "en" })
ok(desc() == "AgentMap: reload", "setup の lang が vim.g.agentmap_lang より優先: " .. desc())
require("agentmap").setup({})
ok(desc() == "AgentMap：読み直す", "setup に lang が無ければ vim.g.agentmap_lang: " .. desc())
L.finish("vim.g.agentmap_lang")
LUA
run_check "lang" "$work/check_ja.lua" --clean -u "$work/init_ja.lua"

# 本物の settings.json は変わっていない
if [ "$before_sum" != "$(sum "$real_settings")" ]; then
  echo "  NG: 本物の settings.json が変わった！"; fail=1
else
  echo "  OK: 本物の settings.json は変わっていない"
fi
exit $fail
