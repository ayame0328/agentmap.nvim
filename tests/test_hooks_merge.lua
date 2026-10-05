-- Tests for hooks.lua. Fixture strings only: the real settings.json is never read or written.
--   ・並びと書式を崩さずに読み書きできる
--   ・他の hooks や設定は残す／自分の古い登録（改名前の agentflow-collect を含む）は置き換える／何度実行しても同じ
--   ・書き換える前に控え（.bak-日時）を作る
--   ・command は '<python>' '<plugin>/bin/agentmap-collect' --root '<root>'（DESIGN §4.2）
--   ・status() は installed / outdated / partial / missing
--   ・v0.1.1：PostToolUse に TaskCreate|TaskUpdate|TaskList、PreToolUse に修正指示の配達（同期・門番つき）の 2 組目、
--     SubagentStop / Stop は同期で --steer --record（DESIGN-v0.2 §2.2、DESIGN-v0.2-steer §7）
local t = require("t")
local J = require("agentmap.jsonfmt")
local hooks = require("agentmap.hooks")

local notes = {}
vim.notify = function(msg, lvl) notes[#notes + 1] = { msg = msg, lvl = lvl } end

local function read(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end
local function write(p, s)
  local f = assert(io.open(p, "wb"))
  f:write(s)
  f:close()
end
local function baks(dir)
  local n = 0
  for name in vim.fs.dir(dir) do
    if name:find("%.bak%-") then n = n + 1 end
  end
  return n
end

local CMD = "python3 /opt/test/bin/agentmap-collect"
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

-- 1. 読み書きで書式が変わらない
local sample = [[
{
  "permissions": {
    "defaultMode": "auto",
    "deny": []
  },
  "env": {},
  "z": 1.5,
  "a": -3,
  "s": "日本語 \"引用\" \\ 改行\n タブ\t",
  "n": null,
  "b": false
}
]]
t.eq(J.encode(J.decode(sample)) .. "\n", sample, "書式と並びを保ったまま読み書きできる")
t.eq(J.decode('"\\u00e9\\ud83d\\ude00"'), "é😀", "\\u の読み取り（サロゲート対も）")
t.ok(not pcall(J.decode, '{"a":1,}'), "壊れた JSON はエラー")

-- 本物の settings.json の代わり：改名前（agentflow-collect）の登録が入った設定の例。
-- 他人の hooks・ほかの設定・日本語の値を含む。本物は読まない（どの PC でも同じ結果にするため）
local LEGACY = "python3 /home/user/.config/nvim/bin/agentflow-collect"
local real_like = [[
{
  "permissions": {
    "allow": [
      "Bash(git status:*)"
    ],
    "defaultMode": "auto"
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 /home/user/.config/nvim/bin/agentflow-collect",
            "async": true,
            "timeout": 10
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo 他人の hook"
          }
        ]
      },
      {
        "matcher": "Agent|Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "python3 /home/user/.config/nvim/bin/agentflow-collect",
            "async": true,
            "timeout": 10
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
]]
t.eq(J.encode(J.decode(real_like)) .. "\n", real_like, "設定の例も書式が変わらない")

-- 2. merge（表の上だけ）
local desired = hooks.desired(CMD)
t.eq(#J.keys(desired), 9, "登録するイベントは 9 個")
t.eq(desired.PostToolUse[1].matcher, "Agent|AskUserQuestion|Write|Edit|MultiEdit|NotebookEdit|Bash|EnterWorktree|ExitWorktree|TaskCreate|TaskUpdate|TaskList", "PostToolUse の対象（手順表の 3 つを含む）")
t.eq(desired.PreToolUse[1].matcher, "Agent|AskUserQuestion", "PreToolUse の 1 組目は Agent と AskUserQuestion（記録）")
t.eq(#desired.PreToolUse, 2, "PreToolUse は 2 組（記録・配達）")
t.eq(desired.PreToolUse[2].matcher, nil, "配達の組は matcher 無し（全部の道具）")
t.eq(desired.PreToolUse[2].hooks[1].async, false, "配達の組は同期（止めるため）")
t.eq(desired.PreToolUse[1].hooks[1].async, true, "記録の組は async のまま")
local root0 = require("agentmap.config").root()
t.eq(desired.PreToolUse[2].hooks[1].command,
  "[ -e " .. hooks.quote(root0 .. "/steer.pending") .. " ] || exit 0; exec " .. CMD .. " --steer --mode deny",
  "配達の command はシェルの門番 → exec で collector --steer")
t.eq(desired.SubagentStop[1].hooks[1].command, CMD .. " --steer --mode deny --at-stop --record", "SubagentStop は記録＋配達")
t.eq(desired.SubagentStop[1].hooks[1].async, false, "SubagentStop は同期")
t.eq(desired.Stop[1].hooks[1].command, CMD .. " --steer --mode deny --at-stop --record", "Stop も記録＋配達")
t.eq(desired.SessionEnd[1].hooks[1].command, CMD, "SessionEnd は記録だけ")
t.eq(#hooks.events(), 10, "events() は 10 件（steer 有効）")
t.eq(#hooks.events({ enabled = false }), 9, "events() は 9 件（steer 無効）")
t.eq(desired.SessionStart[1].matcher, nil, "SessionStart に matcher は付けない")
t.eq(desired.Stop[1].hooks[1].async, false, "Stop は同期（終了時の取りこぼし防止）")
t.eq(desired.SessionEnd[1].hooks[1].async, false, "SessionEnd は同期")
t.eq(desired.PostToolUse[1].hooks[1].async, true, "ほかは async")
t.eq(desired.Stop[1].hooks[1].timeout, 10, "timeout 10 秒")
t.matches(J.encode(desired.Stop[1]), '^{\n  "hooks": %[\n    {\n      "type": "command",\n      "command": ', "項目の並び")

local existing = J.decode([[
{
  "model": "x",
  "hooks": {
    "PostToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo mine" } ] },
      { "matcher": "Agent", "hooks": [ { "type": "command", "command": "python3 /old/agentmap-collect" },
                                       { "type": "command", "command": "echo keep-me" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "command": "python3 /old/agentmap-collect" } ] },
      { "hooks": [ { "type": "command", "command": "notify-send hi" } ] }
    ],
    "TaskCreated": [
      { "hooks": [ { "type": "command", "command": "python3 /old/agentmap-collect" } ] }
    ]
  },
  "after": true
}
]])
local before_text = J.encode(existing)
local merged, changed = hooks.merge(existing, desired)
t.ok(changed, "変更あり")
t.eq(J.encode(existing), before_text, "元の表は変えない")
t.eq(J.keys(merged), { "model", "hooks", "after" }, "上の段の並びはそのまま")
local post = merged.hooks.PostToolUse
t.eq(post[1].hooks[1].command, "echo mine", "他人の hooks は残る")
t.eq(#post[2].hooks, 1, "混ざっていた組から自分の古い分だけ抜く")
t.eq(post[2].hooks[1].command, "echo keep-me", "同じ組の他人の分は残る")
t.eq(post[3].hooks[1].command, CMD, "新しい登録は最後に足す")
t.eq(#post, 3, "PostToolUse は 3 組")
t.eq(#merged.hooks.Notification, 1, "対象外のイベントからは自分の分を消す")
t.eq(merged.hooks.Notification[1].hooks[1].command, "notify-send hi", "他人の分は残る")
t.eq(merged.hooks.TaskCreated, nil, "自分の分しか無かった対象外イベントは消す")
local n_ours = 0
for _, ev in ipairs(J.keys(merged.hooks)) do
  for _, g in ipairs(merged.hooks[ev]) do
    for _, h in ipairs(g.hooks) do
      if h.command:find("agentmap-collect", 1, true) then n_ours = n_ours + 1 end
    end
  end
end
t.eq(n_ours, 10, "自分の分はちょうど 10 個")
local again, changed2 = hooks.merge(merged, desired)
t.ok(not changed2, "2 回目の merge は変更なし")
t.eq(J.encode(again), J.encode(merged), "2 回目の結果も同じ")

-- 3. install（一時ファイル）
local path = dir .. "/settings.json"
-- 改名前の登録が入った設定から始める。古い登録は置き換わり、二重にならないこと
write(path, real_like)
local orig = read(path)
local ok, info = hooks.install({ path = path, cmd = CMD, yes = true })
t.ok(ok and info.changed, "1 回目は書き換える")
t.ok(info.backup and read(info.backup) == orig, "控えは元と同じ中身")
t.eq(baks(dir), 1, "控えは 1 つ")
local after = read(path)
local parsed = J.decode(after)
t.eq(hooks.status(path), "installed", "登録済みと判定")
local orig_parsed = J.decode(orig)
for _, k in ipairs(J.keys(orig_parsed)) do
  if k ~= "hooks" then
    t.eq(J.encode(parsed[k]), J.encode(orig_parsed[k]), "他の設定はそのまま: " .. k)
  end
end
t.eq(vim.list_slice(J.keys(parsed), 1, #J.keys(orig_parsed)), J.keys(orig_parsed), "項目の並びもそのまま")
t.matches(after, "\n$", "末尾に改行")
t.matches(info.diff or "", '%+            "command": "python3 /opt/test/bin/agentmap%-collect"', "差分に追加分が出る")
t.matches(info.diff or "", '%-            "command": "python3 /home/user/%.config/nvim/bin/agentflow%-collect"', "差分に古い登録の削除が出る")
t.ok(not after:find("agentflow-collect", 1, true), "改名前の登録は残らない（記録が二重にならない）")
t.eq(select(2, after:gsub("agentmap%-collect", "")), 10, "新しい登録はちょうど 10 個")
t.ok(after:find("echo 他人の hook", 1, true), "他人の hook は残る")

local ok2, info2 = hooks.install({ path = path, cmd = CMD, yes = true })
t.ok(ok2 and not info2.changed, "2 回目は変更なし")
t.eq(read(path), after, "2 回目はファイルも変わらない")
t.eq(baks(dir), 1, "2 回目は控えを増やさない")
t.matches(notes[#notes].msg, "^AgentMap: No change %(hooks already registered%): ", "変更なしと知らせる")

-- dry_run は書き換えない
local path2 = dir .. "/dry.json"
write(path2, orig)
local ok3, info3 = hooks.install({ path = path2, cmd = CMD, dry_run = true })
t.ok(ok3 and info3.changed and info3.diff, "dry_run は差分だけ返す")
t.eq(read(path2), orig, "dry_run はファイルを変えない")

-- 無いファイルは新しく作る（控えは無し）
local path3 = dir .. "/new/settings.json"
vim.fn.mkdir(dir .. "/new", "p")
local ok4, info4 = hooks.install({ path = path3, cmd = CMD, yes = true })
t.ok(ok4 and info4.changed and not info4.backup, "無ければ新しく作る")
t.eq(hooks.status(path3), "installed", "新しいファイルも登録済み")

-- 壊れた JSON は触らない
local path5 = dir .. "/broken.json"
write(path5, "{ broken")
local ok5 = hooks.install({ path = path5, cmd = CMD, yes = true })
t.ok(not ok5, "壊れた JSON なら書き換えない")
t.eq(read(path5), "{ broken", "壊れたファイルはそのまま")

-- 一部だけ登録されている状態
local part = J.decode(orig)
J.set(part, "hooks", J.obj({ { "Stop", J.array({ J.copy(desired.Stop[1]) }) } }))
write(dir .. "/part.json", J.encode(part) .. "\n")
t.eq(hooks.status(dir .. "/part.json"), "partial", "一部だけなら partial")
t.eq(hooks.status(dir .. "/none.json"), "missing", "ファイルが無ければ missing")

-- 試験中は path 無しでは動かない（本物を書き換えない保険）
t.ok(not pcall(hooks.install, { cmd = CMD, yes = true }), "path 無しは試験中エラー")

-- シンボリックリンクなら先を書き換え、リンクは残す
local target = dir .. "/target.json"
write(target, orig)
vim.uv.fs_symlink(target, dir .. "/link.json")
hooks.install({ path = dir .. "/link.json", cmd = CMD, yes = true })
t.ok(vim.uv.fs_lstat(dir .. "/link.json").type == "link", "リンクはリンクのまま")
t.eq(hooks.status(target), "installed", "リンク先が書き換わる")

-- 4. 改名前の印も「自分の分」
t.ok(hooks.is_ours({ command = LEGACY }), "agentflow-collect も自分の分")
t.ok(hooks.is_ours({ command = CMD }), "agentmap-collect は自分の分")
t.ok(not hooks.is_ours({ command = "echo hi" }), "他人の分は違う")
local legacy_only = J.decode(real_like)
local m2 = hooks.merge(legacy_only, desired)
local legacy_left = 0
for _, ev in ipairs(J.keys(m2.hooks)) do
  for _, g in ipairs(m2.hooks[ev]) do
    for _, h in ipairs(g.hooks) do
      if h.command:find("agentflow-collect", 1, true) then legacy_left = legacy_left + 1 end
    end
  end
end
t.eq(legacy_left, 0, "merge で改名前の登録は全部消える")

-- 5. status: outdated（全イベントに自分の分があるが、matcher の組が違う）
local stale = J.decode(J.encode(J.obj({ { "hooks", hooks.desired(LEGACY) } })))
stale.hooks.PreToolUse[1].matcher = "Agent"   -- AskUserQuestion を足す前の登録
write(dir .. "/stale.json", J.encode(stale) .. "\n")
t.eq(hooks.status(dir .. "/stale.json"), "outdated", "matcher が古ければ outdated")
write(dir .. "/legacy_full.json", J.encode(J.obj({ { "hooks", hooks.desired(LEGACY) } })) .. "\n")
t.eq(hooks.status(dir .. "/legacy_full.json"), "installed", "command の中身は比べない（改名前でも組が同じなら installed）")
local extra = J.decode(J.encode(J.obj({ { "hooks", hooks.desired(CMD) } })))
J.set(extra.hooks, "Notification", J.array({ J.copy(desired.Stop[1]) }))
write(dir .. "/extra.json", J.encode(extra) .. "\n")
t.eq(hooks.status(dir .. "/extra.json"), "outdated", "対象外のイベントに自分の分が残っていれば outdated")
local ok6, info6 = hooks.install({ path = dir .. "/stale.json", cmd = CMD, yes = true, quiet = true })
t.ok(ok6 and info6.changed, "outdated から登録し直せる")
t.eq(hooks.status(dir .. "/stale.json"), "installed", "登録し直すと installed")

-- 6. command の形（DESIGN §4.2, S14）
t.eq(hooks.quote("/a/b-c_d.e"), "/a/b-c_d.e", "安全な文字だけなら囲まない")
t.eq(hooks.quote("/a b/c"), "'/a b/c'", "空白があれば単引用符で囲む")
t.eq(hooks.quote("it's"), "'it'\\''s'", "単引用符は '\\'' にする")
t.eq(hooks.quote('a"b'), "'a\"b'", "二重引用符も囲む")
local plugin = hooks.plugin_dir()
t.eq(hooks.collector_path(), plugin .. "/bin/agentmap-collect", "collector はプラグインの bin/ にある")
t.ok(vim.uv.fs_stat(hooks.collector_path()) ~= nil, "collector が実在する: " .. hooks.collector_path())
t.ok(not plugin:find("\\", 1, true), "区切りは / だけ")
local cmd1 = hooks.default_cmd({ python = { "python3" }, root = "/data/agentflow" })
t.eq(cmd1, "python3 " .. hooks.quote(plugin .. "/bin/agentmap-collect") .. " --root /data/agentflow", "--root 付きの command")
local cmd2 = hooks.default_cmd({ python = { "py", "-3" }, root = "C:\\Users\\A B\\agentflow" })
t.eq(cmd2, "py -3 " .. hooks.quote(plugin .. "/bin/agentmap-collect") .. " --root 'C:/Users/A B/agentflow'",
  "py -3 と、空白・\\ を含む root（/ に直して囲む）")
t.eq(hooks.default_cmd({ python = { "python3" }, root = false }), "python3 " .. hooks.quote(plugin .. "/bin/agentmap-collect"),
  "root = false なら --root を付けない")
local cmd3 = hooks.default_cmd({ python = { "python3" } })
t.ok(cmd3:find("--root " .. hooks.quote(require("agentmap.config").root()), 1, true), "root 省略時は config.root()")
local cmd4 = hooks.default_cmd({ python = { "/opt/my python/bin/python3" }, root = "/r" })
t.matches(cmd4, "^'/opt/my python/bin/python3' ", "空白を含む python も囲む")

-- install({ root = ... }) が command に入る（cmd を渡さない、本当の組み立て）
local path7 = dir .. "/root.json"
write(path7, "{}\n")
local ok7 = hooks.install({ path = path7, root = "/tmp/agentmap-test/store", yes = true, quiet = true })
t.ok(ok7, "root 指定で登録できる")
local saved = J.decode(read(path7))
local c7 = saved.hooks.SessionEnd[1].hooks[1].command
t.matches(c7, "agentmap%-collect", "collector の名前が入る")
t.matches(c7, "%-%-root /tmp/agentmap%-test/store$", "--root が入る")
local ok8, info8 = hooks.install({ path = path7, root = "/tmp/agentmap-test/store", yes = true, quiet = true })
t.ok(ok8 and not info8.changed, "同じ root なら 2 回目は変更なし")
local ok9, info9 = hooks.install({ path = path7, root = false, yes = true, quiet = true })
t.ok(ok9 and info9.changed, "root を外すと変更あり")
t.ok(not J.decode(read(path7)).hooks.SessionEnd[1].hooks[1].command:find("--root", 1, true), "root = false なら --root 無し")
t.matches(saved.hooks.PreToolUse[2].hooks[1].command, "^%[ %-e /tmp/agentmap%-test/store/steer%.pending %] ", "門番は --root の保存先の印を見る")

-- 6b. v0.1.0 の登録（PreToolUse 1 組・Task の matcher 無し）は outdated、登録し直すと installed
local v01 = J.decode(J.encode(J.obj({ { "hooks", hooks.desired(CMD, { steer = false }) } })))
v01.hooks.PostToolUse[1].matcher = "Agent|AskUserQuestion|Write|Edit|MultiEdit|NotebookEdit|Bash|EnterWorktree|ExitWorktree"
write(dir .. "/v01.json", J.encode(v01) .. "\n")
t.eq(hooks.status(dir .. "/v01.json"), "outdated", "v0.1.0 の登録は outdated")
local okv, infov = hooks.install({ path = dir .. "/v01.json", cmd = CMD, yes = true, quiet = true })
t.ok(okv and infov.changed, "v0.1.0 の登録から登録し直せる")
t.eq(hooks.status(dir .. "/v01.json"), "installed", "登録し直すと installed")
local v02 = J.decode(read(dir .. "/v01.json"))
t.eq(#v02.hooks.PreToolUse, 2, "PreToolUse に 2 組目が足される")
local okv2, infov2 = hooks.install({ path = dir .. "/v01.json", cmd = CMD, yes = true, quiet = true })
t.ok(okv2 and not infov2.changed, "PreToolUse が 2 組でも 2 回目は変更なし")
-- 片方だけ（配達の組が消えた）→ outdated → 戻す
local half = J.decode(read(dir .. "/v01.json"))
table.remove(half.hooks.PreToolUse, 2)
write(dir .. "/half.json", J.encode(half) .. "\n")
t.eq(hooks.status(dir .. "/half.json"), "outdated", "配達の組が無ければ outdated")
local okh = hooks.install({ path = dir .. "/half.json", cmd = CMD, yes = true, quiet = true })
t.ok(okh and #J.decode(read(dir .. "/half.json")).hooks.PreToolUse == 2, "足りない組を足し直す")
-- 他人の PreToolUse は残る
local others = J.decode(read(dir .. "/v01.json"))
others.hooks.PreToolUse[#others.hooks.PreToolUse + 1] = J.decode('{ "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo guard-of-someone" } ] }')
write(dir .. "/others.json", J.encode(others) .. "\n")
local oko, infoo = hooks.install({ path = dir .. "/others.json", cmd = CMD, yes = true, quiet = true })
t.ok(oko and not infoo.changed, "他人の PreToolUse があっても自分の 2 組が揃っていれば変更なし")
-- steer.enabled = false → 1 組に戻る（outdated ではなく installed）
local config0 = require("agentmap.config")
config0.setup({ steer = false })
t.eq(#hooks.events(), 9, "steer = false なら events() は 9 件")
t.eq(hooks.status(dir .. "/v01.json"), "outdated", "steer を切ると、配達の組の残った登録は outdated")
local okf, infof = hooks.install({ path = dir .. "/v01.json", cmd = CMD, yes = true, quiet = true })
t.ok(okf and infof.changed, "steer = false で登録し直せる")
local off = J.decode(read(dir .. "/v01.json"))
t.eq(#off.hooks.PreToolUse, 1, "steer = false なら PreToolUse は 1 組")
t.eq(off.hooks.SubagentStop[1].hooks[1].command, CMD, "steer = false なら SubagentStop は記録だけ")
t.eq(off.hooks.SubagentStop[1].hooks[1].async, true, "steer = false なら SubagentStop は async に戻る")
t.eq(off.hooks.Stop[1].hooks[1].async, false, "steer = false でも Stop は同期（記録の取りこぼし防止）")
t.eq(hooks.status(dir .. "/v01.json"), "installed", "steer = false で登録し直すと installed")
-- mode = context / at_stop = false
config0.setup({ steer = { mode = "context", at_stop = false } })
local dctx = hooks.desired(CMD)
t.matches(dctx.PreToolUse[2].hooks[1].command, " %-%-steer %-%-mode context$", "mode = context が門番の command に入る")
t.eq(dctx.SubagentStop[1].hooks[1].command, CMD, "at_stop = false なら SubagentStop は記録だけ")
t.eq(#hooks.events(), 10, "at_stop = false でも PreToolUse の配達は残る")
local g2, s2 = hooks.steer_cmd({ record = CMD, root = "/r x", mode = "deny", at_stop = true })
t.eq(g2, "[ -e '/r x/steer.pending' ] || exit 0; exec " .. CMD .. " --steer --mode deny", "steer_cmd: 門番（空白を含む root は囲む）")
t.eq(s2, CMD .. " --steer --mode deny --at-stop --record", "steer_cmd: 終わりの command")
config0.setup({})

-- 6c. 門番の command を bash で実際に動かす（印が無ければ Python を起動せず何も出さない・あれば配達）
if vim.fn.executable("bash") == 1 and vim.fn.executable("python3") == 1 then
  local sroot = dir .. "/gstore"
  local guard = hooks.steer_cmd({ record = "python3 " .. hooks.quote(hooks.collector_path()) .. " --root " .. hooks.quote(sroot),
    root = sroot, mode = "deny" })
  local payload = vim.json.encode({ session_id = "sg", cwd = "/tmp/g", hook_event_name = "PreToolUse",
    tool_name = "Write", tool_use_id = "tg", agent_id = "a1" })
  local r1 = vim.system({ "bash", "-c", guard }, { stdin = payload, text = true }):wait()
  t.eq({ r1.code, r1.stdout, r1.stderr }, { 0, "", "" }, "門番：印が無ければ exit 0・何も出さない")
  t.eq(vim.fn.isdirectory(sroot), 0, "門番：印が無ければ Python は動かない（保存先も作らない）")
  local sdir = sroot .. "/projects/-tmp-g/runs/sg/steer"
  vim.fn.mkdir(sdir, "p")
  write(sroot .. "/steer.pending", "")
  write(sdir .. "/a1-1790000000000.json", vim.json.encode({ id = "a1-1790000000000", agent_id = "a1", text = "use v3" }))
  local r2 = vim.system({ "bash", "-c", guard }, { stdin = payload, text = true }):wait()
  local out = r2.code == 0 and r2.stdout ~= "" and vim.json.decode(r2.stdout) or {}
  local hso = out.hookSpecificOutput or {}
  t.eq(hso.permissionDecision, "deny", "門番：印があれば collector が deny を返す")
  t.matches(hso.permissionDecisionReason or "", "use v3", "門番：本文が理由に入る")
  t.ok(vim.uv.fs_stat(sdir .. "/a1-1790000000000.delivered.json") ~= nil, "門番：配達済みに名前が変わる")
else
  t.skip("bash / python3 が無い")
end

-- 7. 既定の settings.json の場所は config.settings_path()
local config = require("agentmap.config")
config.setup({ claude_config_dir = "/home/user/.claude-x" })
t.eq(hooks.default_path(), "/home/user/.claude-x/settings.json", "claude_config_dir の下の settings.json")
config.setup({ claude_config_dir = "/home/user/.claude-x", hooks = { settings_path = "/etc/x/settings.json" } })
t.eq(hooks.default_path(), "/etc/x/settings.json", "hooks.settings_path が優先")
config.setup({})

vim.fn.delete(dir, "rf")
t.done()
