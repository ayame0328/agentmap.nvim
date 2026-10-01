-- agentmap/i18n.lua ... UI strings in the configured language (English by default).
--   t("key", { name = "..." }) returns the string for the current language, falling back to
--   English and then to the key itself. Placeholders are written %{name}.
--   Pure Lua on purpose (no vim.* at module level) so brief.lua and tests can use it.
local M = { lang = "en" }

local cache = {}

local function load(lang)
  if cache[lang] == nil then
    local ok, tbl = pcall(require, "agentmap.lang." .. lang)
    cache[lang] = (ok and type(tbl) == "table") and tbl or false
  end
  return cache[lang] or nil
end

--- Select the language ("en" | "ja"). Unknown names fall back to "en". Returns the language in use.
function M.setup(lang)
  if type(lang) ~= "string" or lang == "" then lang = "en" end
  if not load(lang) then lang = "en" end
  M.lang = lang
  return lang
end

--- Translate `key`; `vars` fills %{name} placeholders. A missing key returns the key itself.
function M.t(key, vars)
  local tbl = load(M.lang)
  local s = tbl and tbl[key]
  if s == nil and M.lang ~= "en" then
    local en = load("en")
    s = en and en[key]
  end
  if s == nil then return key end
  if vars then
    s = (s:gsub("%%{([%w_]+)}", function(name)
      local v = vars[name]
      if v == nil then return nil end
      return tostring(v)
    end))
  end
  return s
end

--- True when `key` exists in `lang` (default: the current language).
function M.has(key, lang)
  local tbl = load(lang or M.lang)
  return tbl ~= nil and tbl[key] ~= nil
end

--- Sorted list of keys present in English but missing in `lang` (used by tests and :checkhealth).
function M.missing(lang)
  local en, other, out = load("en"), load(lang), {}
  if not en or not other then return out end
  for k in pairs(en) do
    if other[k] == nil then out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

return M
