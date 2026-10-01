-- plugin/agentmap.lua ... registers the :AgentMap* user commands at startup.
--   No setup() call is needed: each command calls setup({}) once on first use.
--   Loading this file only loads lua/agentmap/init.lua and the i18n tables; everything
--   else is loaded when a command runs.
if vim.g.loaded_agentmap then return end
vim.g.loaded_agentmap = 1

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("AgentMap: Neovim 0.10 or newer is required", vim.log.levels.ERROR)
  return
end

require("agentmap").commands()
