# Claude Code in a container, Neovim outside

This page is for setups where Claude Code runs inside a container (a devcontainer, a Docker
container, a sandbox VM) while Neovim runs on the host. If Claude Code and Neovim run on the
same machine and file system, you do not need any of this: `:AgentMapInstallHooks` is enough.

The steps can also be given to Claude Code running in the container, as a task. Make sure it
shows you the change to `settings.json` before writing it.

## What has to be true

| # | Condition |
|---|---|
| A | Where **Claude Code** runs, the hook command (`python3 <path to agentmap-collect>`) can be executed. |
| B | From there, the recorder can write to the record folder. |
| C | Where **Neovim** runs, the same record folder can be read. |

In a container, B and C need **one folder that both sides can see** (a bind mount or a shared volume).
The recorder only appends small files there; Neovim only reads them (plus `events.jsonl` /
`state.json`, which it writes next to the records).

## 1. Find out

1. Which folders are shared between the container and the host, and their path on each side
   (`mount` or `/proc/mounts` inside the container, `devcontainer.json`, `docker inspect <container>`).
2. Which `settings.json` Claude Code reads **inside the container**: `$CLAUDE_CONFIG_DIR/settings.json`,
   or `~/.claude/settings.json` of the container user. Not the file with the same name on the host.
3. Whether the container has Python 3 (`python3 --version`; otherwise `python` or `py -3`).
4. Whether the container can see the plugin folder (where lazy.nvim installed agentmap.nvim). Usually it cannot.
5. Where Neovim runs (Linux, macOS, WSL or Windows-native) and how it sees the shared folder.

## 2. Decide

- **Record folder**: one folder inside the shared mount, for example
  - container: `/workspace/.shared/agentmap/records`
  - host: `~/projects/shared/agentmap/records`

  Do not put it inside a repository you work on, and do not put it on a network drive that
  other people can read.
- **Recorder location**: a copy of `bin/agentmap-collect` in the shared folder, for example
  `/workspace/.shared/agentmap/agentmap-collect`. Keep the file name: the name
  `agentmap-collect` in the hook command is how `:AgentMapInstallHooks` recognises its own hooks
  when it updates or replaces them. Copy it again after updating the plugin.

The examples below use these paths. Replace them with yours.

## 3. Register the hooks in the container's settings.json

Do it from the host's Neovim, giving the host path of the container's `settings.json` (`path`)
and the hook command as the **container** sees it (`cmd`). First look at the diff:

```vim
:lua local ok, r = require("agentmap.hooks").install({ path = vim.fn.expand("~/projects/shared/claude/settings.json"), cmd = "python3 '/workspace/.shared/agentmap/agentmap-collect' --root '/workspace/.shared/agentmap/records'", dry_run = true }); print(r.diff or "no change")
```

Then write it (the original is kept as `settings.json.bak-<timestamp>`; other settings and hooks are left alone;
running it again changes nothing):

```vim
:lua require("agentmap.hooks").install({ path = vim.fn.expand("~/projects/shared/claude/settings.json"), cmd = "python3 '/workspace/.shared/agentmap/agentmap-collect' --root '/workspace/.shared/agentmap/records'" })
```

If the container's `settings.json` is not visible from the host, run the same `install()` with
Neovim inside the container, or add the `hooks` block by hand: run the dry run against a copy
of the file and paste the result.

Instead of `--root`, the record folder can also be set as an environment variable in the
container's `settings.json` (`"env": { "AGENTMAP_DIR": "/workspace/.shared/agentmap/records" }`)
and left out of `cmd`.

Notes:

- `Stop` and `SessionEnd` are registered as synchronous hooks on purpose (otherwise they are lost
  when Claude Code exits). Do not change that.
- `PermissionRequest` and `Notification` are not registered; agentmap.nvim never takes part in permission decisions.

## 4. Point Neovim at the shared folder

In your Neovim config on the host:

```lua
require("agentmap").setup({
  root = vim.fn.expand("~/projects/shared/agentmap/records"),  -- host path of the record folder
  -- optional: lets the detail and transcript views read Claude Code's transcripts,
  -- if the container's Claude folder is also shared
  claude_config_dir = "~/projects/shared/claude",
  -- optional: makes :checkhealth agentmap check the container's settings.json
  hooks = { settings_path = "~/projects/shared/claude/settings.json" },
})
```

## 5. Check

1. Run something small in the container that starts one sub-agent, with a cheap model:

   ```sh
   claude -p "Use the Agent tool once (subagent_type general-purpose, description 'check') with prompt 'reply OK'. Then reply DONE." --model haiku --max-turns 5 < /dev/null
   ```

2. The record folder now has `projects/<name>/runs/<session_id>/hooks.jsonl` with lines from
   `SessionStart` through `Stop` and `SessionEnd`. If not, look at `<record folder>/collector.log`.
3. In Neovim, `:AgentMapRuns` lists the run; opening it shows `ROOT → check`, and `ROOT` is `[DONE]`.
4. `:checkhealth agentmap` reports no errors.
5. Delete the test run from the record folder if you like.

## Known limits

- **Paths differ between the container and the host.** `:AgentMap` still opens the latest run
  (it does not depend on the current folder), and `:AgentMapRuns` always works. The diff view (`d`)
  and "go to folder" (`w`) use the agent's working folder as the container saw it; when the host
  cannot see that path, they cannot open it.
- **Transcripts** (progress notes, `t`, importing old sessions) need `claude_config_dir` to point at
  the container's Claude folder through a shared mount. Without it, the map and the reports still work.
- **Windows-native Neovim** with a Linux container is experimental in v0.1.0. Give `root` as a
  Windows path (forward slashes are fine). Please report what does not work.
- Records contain file names and the start of prompts (see "Privacy" in the README). Keep the record
  folder out of shared drives and out of client repositories.
