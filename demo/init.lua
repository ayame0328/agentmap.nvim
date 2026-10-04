-- Minimal Neovim config used to record the README demo (demo/demo.tape).
--   Loads only this plugin. The record store is $AGENTMAP_DIR (filled by demo/replay.py);
--   claude_config_dir is $DEMO_CLAUDE_DIR (the fake transcripts written by replay.py --claude-dir),
--   or an empty folder, so no real Claude Code data is ever read.
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(repo)

vim.o.termguicolors = true
vim.o.laststatus = 0
vim.o.showtabline = 0
vim.o.ruler = false
vim.o.showmode = false
vim.o.shortmess = vim.o.shortmess .. "IF"
vim.o.cmdheight = 1
vim.g.mapleader = " "

require("agentmap").setup({
  root = vim.env.AGENTMAP_DIR,
  claude_config_dir = vim.env.DEMO_CLAUDE_DIR or vim.fn.tempname(),
  open = "current",
  mode = "box",       -- the recording is wide enough for the box map
  box_w = 24,
  col_gap = 5,
  poll_ms = 300,
  debounce_ms = 100,
  keymaps = { global = true },
  -- the demo has no history: with the real default (10 min per agent) the estimate would move
  -- by a tenth of a percent per second; 1 min makes the "~" numbers visibly move in 40 s
  progress = { default_ms = 60000 },
})

-- Register the hooks in the demo's own (throwaway) Claude folder, so the steering route through
-- hooks is "installed" (otherwise `s` refuses: an outdated or missing registration cannot deliver).
-- demo/replay.py plays the same guard the registration describes.
if vim.env.DEMO_CLAUDE_DIR and vim.env.AGENTMAP_DIR then
  vim.fn.mkdir(vim.env.DEMO_CLAUDE_DIR, "p")
  pcall(require("agentmap.hooks").install, {
    path = vim.env.DEMO_CLAUDE_DIR .. "/settings.json", root = vim.env.AGENTMAP_DIR, yes = true, quiet = true,
  })
end
