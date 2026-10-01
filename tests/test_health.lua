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

-- 後片付け
for k, v in pairs(saved) do vim.env[k] = v end
config.setup({})
vim.fn.delete(dir, "rf")
t.done()
