-- Tests for config.lua accessors (DESIGN §4.1) and health.lua (§8).
--   環境変数は試験の中で付け外しする。本物の Claude の設定フォルダ・settings.json は使わない。
local t = require("t")
local config = require("agentmap.config")

local saved = { AGENTMAP_DIR = vim.env.AGENTMAP_DIR, AGENTFLOW_DIR = vim.env.AGENTFLOW_DIR, CLAUDE_CONFIG_DIR = vim.env.CLAUDE_CONFIG_DIR }
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/claude/projects/-home-user-work-demo/", "p")

-- 1. 記録の保存先の決め方
vim.env.AGENTMAP_DIR, vim.env.AGENTFLOW_DIR = nil, nil
config.setup({})
t.eq(config.root(), vim.fn.stdpath("data") .. "/agentflow", "既定は stdpath(data)/agentflow（フォルダ名は据え置き）")
t.eq(config.root_source(), "default", "出どころ default")
vim.env.AGENTFLOW_DIR = dir .. "/old"
t.eq(config.root(), dir .. "/old", "AGENTFLOW_DIR は旧名として読む")
t.eq(config.root_source(), "AGENTFLOW_DIR", "出どころ AGENTFLOW_DIR")
vim.env.AGENTMAP_DIR = dir .. "/store"
t.eq(config.root(), dir .. "/store", "AGENTMAP_DIR が AGENTFLOW_DIR より先")
t.eq(config.root_source(), "AGENTMAP_DIR", "出どころ AGENTMAP_DIR")
config.setup({ root = dir .. "/set" })
t.eq({ config.root(), config.root_source() }, { dir .. "/set", "setup" }, "setup の root が最優先")
config.setup({ root = "~/agentmap-records" })
t.eq(config.root(), vim.fn.expand("~") .. "/agentmap-records", "setup の root の ~ はホームに展開する")

-- 2. Claude の設定フォルダ
vim.env.CLAUDE_CONFIG_DIR = nil
config.setup({})
t.eq(config.claude_config_dir(), vim.fn.expand("~/.claude"), "既定は ~/.claude")
t.eq(config.claude_config_source(), "default", "出どころ default")
vim.env.CLAUDE_CONFIG_DIR = dir .. "/claude/"
t.eq(config.claude_config_dir(), dir .. "/claude", "CLAUDE_CONFIG_DIR（末尾の / は落とす）")
t.eq(config.claude_config_source(), "CLAUDE_CONFIG_DIR", "出どころ CLAUDE_CONFIG_DIR")
t.eq(config.settings_path(), dir .. "/claude/settings.json", "settings.json はその下")
config.setup({ claude_config_dir = dir .. "/c2" })
t.eq({ config.claude_config_dir(), config.claude_config_source() }, { dir .. "/c2", "setup" }, "setup が最優先")
config.setup({ hooks = { settings_path = dir .. "/s.json" } })
t.eq(config.settings_path(), dir .. "/s.json", "hooks.settings_path")

-- 3. 既定値
config.setup({})
local c = config.get()
t.eq(c.lang, "en", "既定の言語は en")
t.eq(c.keymaps.global, false, "グローバルキーは既定で無し")
t.eq(c.review.provider, "auto", "review.provider")
t.eq(c.export, {}, "export は既定で空（html_command / pdf_command は nil）")
-- v0.1.1 の既定と false / true の正規化（DESIGN-v0.2 §4.1・付録 D、DESIGN-v0.2-steer §8.1）
t.eq({ c.progress.enabled, c.progress.no_steps, c.progress.default_ms, c.progress.min_samples, c.progress.log, c.progress.tick_ms },
  { true, "time", 600000, 3, true, 1000 }, "progress の既定（手順表が無くても時間で推定）")
t.eq({ c.animation.enabled, c.animation.frame_ms, c.animation.period, c.animation.tail, c.animation.back_ms, c.animation.max_paths },
  { true, 100, 6, 2, 3000, 40 }, "animation の既定")
t.eq({ c.steer.enabled, c.steer.mode, c.steer.at_stop, c.steer.root_via, c.steer.no_terminal, c.steer.input },
  { true, "deny", true, "terminal", "hook", "window" }, "steer の既定")
local cf = config.setup({ progress = false, animation = false, steer = false })
t.eq({ cf.progress.enabled, cf.animation.enabled, cf.steer.enabled }, { false, false, false }, "false は { enabled = false }")
t.eq(cf.progress.no_steps, "time", "false でも他の既定は残る")
t.eq(config.setup({ progress = true }).progress.enabled, true, "true は既定のまま有効")
t.eq(config.setup({ progress = { no_steps = "none" } }).progress.default_ms, 600000, "一部だけ渡しても残りは既定")
-- v0.1.2 の一時停止（DESIGN-v0.1.2-pause §8.1、付録 D：release_on_exit の既定は false）
config.setup({})
c = config.get()
t.eq({ c.pause.enabled, c.pause.auto_resume_s, c.pause.gate, c.pause.release_on_exit, c.pause.notify },
  { true, 600, false, false, true }, "pause の既定")
t.eq(config.setup({ pause = false }).pause.enabled, false, "pause = false は { enabled = false }")
t.eq(config.setup({ pause = false }).pause.auto_resume_s, 600, "pause = false でも他の既定は残る")
t.eq(config.setup({ pause = true }).pause.enabled, true, "pause = true は有効")
t.eq(config.setup({ pause = { gate = true } }).pause.auto_resume_s, 600, "一部だけ渡しても残りは既定")
t.eq(config.setup({ pause = { auto_resume_s = 1 } }).pause.auto_resume_s, 5, "auto_resume_s は 5 秒より短くしない")
t.eq(config.setup({ pause = { auto_resume_s = 999999 } }).pause.auto_resume_s, 86400, "auto_resume_s は 86400 秒まで")
t.eq(config.setup({ pause = { auto_resume_s = 1200.7 } }).pause.auto_resume_s, 1200, "auto_resume_s は整数の秒")
t.eq(config.setup({ pause = { auto_resume_s = "x" } }).pause.auto_resume_s, 600, "数でなければ既定")
t.eq(config.defaults.pause.auto_resume_s, 600, "既定の表は書き換えない")
config.setup({})
vim.g.agentmap_lang = "ja"
t.eq(config.setup({}).lang, "ja", "setup に lang が無ければ vim.g.agentmap_lang")
t.eq(config.setup({ lang = "en" }).lang, "en", "setup の lang が優先")
vim.g.agentmap_lang = nil

-- 4. Python の探し方
config.setup({ python = "py -3" })
t.eq(config.python(), { "py", "-3" }, "文字列は空白で分ける")
config.setup({ python = { "/opt/my python/python3" } })
t.eq(config.python(), { "/opt/my python/python3" }, "表はそのまま")
config.setup({})
local py = config.python()
if vim.fn.executable("python3") == 1 then
  t.eq(py, { "python3" }, "python3 があれば python3")
else
  t.skip("python3 が無い PC")
end

-- 5. :checkhealth agentmap（vim.health を差し替えて中身だけ見る）
vim.env.AGENTMAP_DIR, vim.env.AGENTFLOW_DIR = nil, dir .. "/old-store"
vim.env.CLAUDE_CONFIG_DIR = dir .. "/claude"
config.setup({ export = { pdf_command = { "/no/such/chrome", "%{html}" } } })
local got = {}
local real_health = vim.health
vim.health = setmetatable({}, { __index = function(_, k)
  return function(msg) got[#got + 1] = { k, msg } end
end })
local ok, err = pcall(require("agentmap.health").check)
vim.health = real_health
t.ok(ok, "health.check がエラー: " .. tostring(err))
local function find(kind, pat)
  for _, g in ipairs(got) do
    if g[1] == kind and tostring(g[2]):find(pat) then return true end
  end
  return false
end
t.ok(find("start", "^agentmap$"), "見出しは agentmap")
t.ok(find("ok", "^Neovim %d+%.%d+%.%d+$"), "Neovim の版")
t.ok(find("ok", "^Collector: .*/bin/agentmap%-collect$"), "collector の場所")
t.ok(find("ok", "^Claude config dir: .* %(from CLAUDE_CONFIG_DIR%)$"), "Claude の設定フォルダと出どころ")
t.ok(find("error", "^Hooks are not registered in .*settings%.json; run :AgentMapInstallHooks$"), "hooks 未登録は error")
t.ok(find("warn", "^%$AGENTFLOW_DIR is deprecated; rename it to %$AGENTMAP_DIR$"), "旧名の環境変数は warn")
t.ok(find("ok", "^Record store: .*/old%-store %(from AGENTFLOW_DIR%), writable, 0 runs$"), "保存先は書き込み可・run 0 件")
t.ok(find("info", "^export%.html_command not set"), "html_command 未設定は info")
t.ok(find("warn", "^export%.pdf_command: /no/such/chrome is not executable %(optional%)$"), "pdf_command が無ければ warn")
t.ok(find("ok", "^Language: en$"), "言語")
local leftovers = vim.fn.glob(dir .. "/old-store/.agentmap-health-*", false, true)
t.eq(leftovers, {}, "書き込み確認の一時ファイルは残さない")
t.eq(vim.fn.filereadable(dir .. "/claude/settings.json"), 0, "health は settings.json を作らない")

-- 6. v0.1.1 の 6 行（DESIGN-v0.2 §4.2 の 10〜12、DESIGN-v0.2-steer §8.2 の 13〜15）。担当 W2
local function run_health()
  got = {}
  vim.health = setmetatable({}, { __index = function(_, k)
    return function(msg) got[#got + 1] = { k, msg } end
  end })
  local okh, errh = pcall(require("agentmap.health").check)
  vim.health = real_health
  t.ok(okh, "health.check がエラー: " .. tostring(errh))
end
local store = dir .. "/v2-store"
vim.fn.mkdir(store, "p")
vim.env.AGENTMAP_DIR, vim.env.AGENTFLOW_DIR = store, nil
require("agentmap.stats").reset()
config.setup({})
run_health()
t.eq(require("agentmap.health").VERIFIED_CLAUDE_CODE, "2.1.289", "確かめた Claude Code の版")
t.ok(find("warn", "^Progress history: only 0 finished agents; estimates use the default 10:00 until records accumulate$"), "10: 記録が無ければ warn")
t.ok(find("info", "^Estimate check: not enough samples yet %(0 of 20%)$"), "11: 標本が足りなければ info")
t.ok(find("warn", "^Animation: low%-color terminal") or find("ok", "^Animation: on %(frame 100 ms, termguicolors o[nf]+%)$"), "12: 光の行")
t.ok(find("warn", "^Steering settings differ from the registered hook"), "13: 配達の登録が無ければ warn")
t.ok(find("ok", "^No pending steering instructions$"), "14: 未配達なし")
t.ok(find("info", "^No :terminal running claude in this Neovim") or find("info", "^Claude terminal: term module missing"), "15: 端末なし")
t.eq(vim.fn.filereadable(store .. "/stats.json"), 0, "health は stats.json を書かない")

-- 記録が 3 件以上・答え合わせの記録 off・光 off・修正指示 off
local rdir = store .. "/projects/-home-user-work/runs/r1"
vim.fn.mkdir(rdir, "p")
local agents = {}
for i, ms in ipairs({ 60000, 120000, 180000 }) do
  agents["a" .. i] = { id = "a" .. i, agent_type = "general-purpose", model = "claude-opus-5-5", status = "DONE", elapsed_ms = ms }
end
vim.fn.writefile({ vim.json.encode({ agents = agents }) }, rdir .. "/state.json")
require("agentmap.stats").reset()
config.setup({ progress = { log = false }, animation = false, steer = false })
run_health()
t.ok(find("ok", "^Progress history: 3 finished agents in 1 runs %(median 2:00%), 0 step samples$"), "10: 記録があれば ok")
t.ok(find("info", "^Estimate check: logging is off %(progress%.log = false%)$"), "11: 記録 off")
t.ok(find("info", "^Animation: off %(animation%.enabled = false%)$"), "12: 光 off")
t.ok(find("info", "^Steering: off %(steer%.enabled = false%)$"), "13: 修正指示 off")

-- 登録済みの配達 hook（mode と at_stop が設定どおり）／印だけ残っている／未配達がある
local spath = dir .. "/claude/settings.json"
local hooks = require("agentmap.hooks")
config.setup({})
local okd, desired = pcall(hooks.desired, "python3 /x/bin/agentmap-collect --root " .. store, { root = store })
if okd and type(desired) == "table" then
  vim.fn.writefile({ vim.json.encode({ hooks = desired }) }, spath)
  config.setup({})
  run_health()
  t.ok(find("ok", "^Steering: on %(mode deny, at stop on%); sync PreToolUse guard registered$"), "13: 登録が設定どおりなら ok")
  config.setup({ steer = { mode = "context" } })
  run_health()
  t.ok(find("warn", "^Steering settings differ"), "13: mode が違えば warn")
  os.remove(spath)
else
  t.skip("hooks.desired が使えない（W1 の作業中）")
end
config.setup({})
vim.fn.writefile({}, store .. "/steer.pending")
run_health()
t.ok(find("warn", "^Stale steer%.pending flag"), "14: 印だけ残っている")
t.ok(vim.uv.fs_stat(store .. "/steer.pending") ~= nil, "14: health は印を消さない")
vim.fn.mkdir(rdir .. "/steer", "p")
vim.fn.writefile({ "{}" }, rdir .. "/steer/a1-1.json")
vim.fn.writefile({ "{}" }, rdir .. "/steer/a1-0.delivered.json")
run_health()
t.ok(find("info", "^1 pending steering instruction%(s%)$"), "14: 未配達 1 件（配達済みは数えない）")

-- 7. v0.1.2 の 2 行（DESIGN-v0.1.2-pause §8.2 の 16・17）。担当 W2
--   settings.json は手で作る（hooks.lua の作業中でも試せるように、§7.1 の形そのもの）
local function cmd_of(extra) return "'python3' '/x/bin/agentmap-collect' --root '" .. store .. "' --steer --mode deny" .. extra end
local function write_settings(pause_words, timeout)
  local guard = "[ -e '" .. store .. "/steer.pending' ] || [ -e '" .. store .. "/pause.pending' ] || exit 0; exec "
    .. cmd_of(pause_words)
  local function one(command, to) return { { matcher = "", hooks = { { type = "command", command = command, timeout = to } } } } end
  vim.fn.writefile({ vim.json.encode({ hooks = {
    PreToolUse = { { matcher = "*", hooks = { { type = "command", command = guard, timeout = timeout } } } },
    SubagentStop = one(cmd_of(" --at-stop" .. pause_words .. " --record"), timeout),
    Stop = one(cmd_of(" --at-stop" .. pause_words .. " --record"), timeout),
  } }) }, spath)
end
local HM = require("agentmap.health")
write_settings(" --pause --max-wait 600", 630)
config.setup({})
t.eq({ HM.pause_registration(spath, config.get().pause) }, { true, 630 }, "16: --pause と timeout 630 → 合格")
run_health()
t.ok(find("ok", "^Pause: on %(auto%-resume 600 s%); hook timeout 630 registered$"), "16: ok の行")
t.ok(find("ok", "^No pending pauses$"), "17: 止まれなし")
config.setup({ pause = { auto_resume_s = 1200 } })
t.eq(HM.pause_registration(spath, config.get().pause), false, "16: 設定を 1200 秒に伸ばしたのに timeout 630 → 不合格")
run_health()
t.ok(find("warn", "^Pause settings differ from the registered hook %(no %-%-pause or timeout too small%): run :AgentMapInstallHooks$"),
  "16: timeout 不足は warn")
write_settings("", 10) -- v0.1.1 の形
config.setup({})
t.eq(HM.pause_registration(spath, config.get().pause), false, "16: v0.1.1 の登録（--pause 無し・timeout 10）→ 不合格")
run_health()
t.ok(find("warn", "^Pause settings differ"), "16: v0.1.1 の登録は warn")
write_settings(" --pause --max-wait 600", 10)
t.eq(HM.pause_registration(spath, config.get().pause), false, "16: --pause があっても timeout 10 → 不合格")
config.setup({ pause = false })
run_health()
t.ok(find("info", "^Pause: off %(pause%.enabled = false%)$"), "16: 無効なら info")
os.remove(spath)
config.setup({})
run_health()
t.ok(find("warn", "^Pause settings differ"), "16: 登録が無ければ warn")
-- 17. 止まれの印：印だけ／止まれのファイルあり（.hit.json と GATE は数えない）
vim.fn.writefile({}, store .. "/pause.pending")
run_health()
t.ok(find("warn", "^Stale pause%.pending flag %(no pause files%); opening :AgentMap removes it$"), "17: 印だけ残っている")
t.ok(vim.uv.fs_stat(store .. "/pause.pending") ~= nil, "17: health は印を消さない")
vim.fn.mkdir(rdir .. "/pause", "p")
vim.fn.writefile({ "{}" }, rdir .. "/pause/a1.json")
vim.fn.writefile({ "{}" }, rdir .. "/pause/a1.hit.json")
vim.fn.writefile({ "{}" }, rdir .. "/pause/ROOT.json")
vim.fn.writefile({}, rdir .. "/pause/GATE")
run_health()
t.ok(find("info", "^2 pause%(s%) pending or waiting$"), "17: 止まれ 2 件（.hit.json と GATE は数えない）")
os.remove(store .. "/pause.pending")
run_health()
t.ok(find("ok", "^No pending pauses$"), "17: 印が無ければ ok（ファイルが残っていても数えない）")
-- 日本語
require("agentmap.i18n").setup("ja")
config.setup({ lang = "ja", pause = false })
run_health()
t.ok(find("info", "^一時停止: 無効（pause%.enabled = false）$"), "16: 日本語")
require("agentmap.i18n").setup("en")
config.setup({})

-- 後片付け
for k, v in pairs(saved) do vim.env[k] = v end
config.setup({})
vim.fn.delete(dir, "rf")
t.done()
