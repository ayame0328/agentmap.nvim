-- Minimal init for the test suite: loads only this plugin, never the user's init.lua.
--   Used as `nvim --headless --clean -u tests/minimal_init.lua -l tests/test_xxx.lua` (see tests/run.sh).
--   - puts the repository root on 'runtimepath' and tests/ on package.path (so `require("t")` works)
--   - the record store (AGENTMAP_DIR) defaults to a temporary directory; real records and
--     Claude Code's settings.json are never touched
--   - vim.g.agentmap_test = true makes hooks.install() refuse to run without an explicit path
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

vim.opt.rtp:prepend(root)
package.path = here .. "/?.lua;" .. package.path

if not vim.env.AGENTMAP_DIR or vim.env.AGENTMAP_DIR == "" then
  vim.env.AGENTMAP_DIR = vim.fn.tempname() .. "-agentmap"
end
vim.fn.mkdir(vim.env.AGENTMAP_DIR, "p")

vim.g.agentmap_test = true
vim.g.agentmap_test_dir = here -- tests read fixtures from vim.g.agentmap_test_dir .. "/fixtures"
vim.g.mapleader = " "

local ok, err = pcall(function() require("agentmap").setup({}) end)
if not ok then
  io.stderr:write("agentmap.setup() failed: " .. tostring(err) .. "\n")
end
