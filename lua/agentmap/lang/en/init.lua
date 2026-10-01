-- agentmap/lang/en/init.lua ... merges core / ui / export into one flat table.
--   A key defined twice is a bug (two workers chose the same name), so it raises an error.
local out = {}
for _, part in ipairs({ "core", "ui", "export" }) do
  local tbl = require("agentmap.lang.en." .. part)
  for k, v in pairs(tbl) do
    if out[k] ~= nil then error(("agentmap i18n: duplicate key %q in en/%s"):format(k, part)) end
    out[k] = v
  end
end
return out
