#!/usr/bin/env bash
# Documentation consistency checks (no Neovim needed):
#   1. The lazy.nvim spec in README.md / README.ja.md loads the plugin at startup (`lazy = false`)
#      or lists its commands in `cmd`. With `keys` alone lazy.nvim defers loading, and
#      :AgentMapInstallHooks / :checkhealth agentmap do not exist until a key is pressed
#      (found in the final check before v0.1.0).
#   2. Every :AgentMap* command named in README.md, README.ja.md and doc/agentmap.txt is
#      registered by lua/agentmap/init.lua, and every registered command is named in README.md.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
fail=0

# 1. lazy.nvim spec = the first ```lua block of each README
for f in README.md README.ja.md; do
  spec="$(awk '/^```lua/{s=1; next} /^```/{if (s) exit} s' "$root/$f")"
  if ! printf '%s\n' "$spec" | grep -q 'ayame0328/agentmap.nvim'; then
    echo "  NG: $f: first lua block is not the lazy.nvim spec"; fail=1
  elif printf '%s\n' "$spec" | grep -q 'keys *=' && ! printf '%s\n' "$spec" | grep -qE 'lazy *= *false|cmd *='; then
    echo "  NG: $f: lazy.nvim spec has keys= but neither lazy = false nor cmd= (commands would be missing until a key is pressed)"; fail=1
  else
    echo "  OK: $f: lazy.nvim spec loads the plugin at startup"
  fi
done

# 2. commands named in the docs <-> commands registered in init.lua
registered="$(grep -oE 'cmd\("AgentMap[A-Za-z]*"' "$root/lua/agentmap/init.lua" | sed -e 's/^cmd("//' -e 's/"$//' | sort -u)"
[ -n "$registered" ] || { echo "  NG: no commands found in lua/agentmap/init.lua"; fail=1; }
for f in README.md README.ja.md doc/agentmap.txt; do
  for c in $(grep -oE ':AgentMap[A-Za-z]*' "$root/$f" | sed 's/^://' | sort -u); do
    if ! printf '%s\n' "$registered" | grep -qx "$c"; then
      echo "  NG: $f names :$c, which init.lua does not register"; fail=1
    fi
  done
  echo "  OK: $f: every :AgentMap* command it names is registered"
done
for c in $registered; do
  if ! grep -qE ":$c([^A-Za-z]|$)" "$root/README.md"; then
    echo "  NG: README.md does not mention :$c"; fail=1
  fi
done
echo "  OK: README.md names every registered command ($(printf '%s\n' "$registered" | wc -l | tr -d ' '))"

exit $fail
