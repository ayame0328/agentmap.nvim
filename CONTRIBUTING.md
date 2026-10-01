# Contributing

Thanks for taking the time. agentmap.nvim is a personal tool that I maintain in my spare time;
I read issues and pull requests a few times a week and cannot promise a timeline.

## Reporting a bug

Use the "Bug report" issue template. Most useful are:

- the output of `:checkhealth agentmap`
- Neovim version (`nvim --version`), Claude Code version (`claude --version`), OS
  (and whether Neovim runs on Windows directly, in WSL, or with Claude Code in a container)
- a few lines of the run's `hooks.jsonl` around the problem
  (`<root>/projects/<project>/runs/<session_id>/hooks.jsonl`; `:checkhealth agentmap` shows `<root>`)

**Check those lines before posting.** They contain file paths, the start of your prompts and
agent reports. Replace anything private (user names, project names, client names) with
something neutral such as `/home/user/work/demo`.

## Pull requests

- Keep a pull request to one change. For a larger change, open an issue first.
- `bash tests/run.sh` must pass (CI runs it on Linux and macOS with Neovim 0.10 and the latest
  release). Add or update a test for what you change. See [tests/README.md](tests/README.md).
- Test expectations are written as literal English strings, never through the translation tables,
  so that a wrong table entry makes a test fail.
- No new runtime dependencies. The recorder (`bin/agentmap-collect`) uses the Python 3 standard
  library only and must never print or exit non-zero.

### User-facing text

Every message, label and help text goes through the translation tables:

```lua
local t = require("agentmap.i18n").t
vim.notify("AgentMap: " .. t("init.refreshed"))
```

Add the key to both `lua/agentmap/lang/en/*.lua` and `lua/agentmap/lang/ja/*.lua`
(`tests/test_i18n.lua` checks that both have the same keys and placeholders). If you cannot write
the Japanese text, copy the English one and say so in the pull request.
Status words (`RUNNING`, `DONE`, `HUMAN CHECK`, …), command names and key names are not translated.

### Claude Code specifics

Everything that depends on the shape of Claude Code's hook payloads or transcripts lives in
`lua/agentmap/providers/claude.lua` (and, for recording, `bin/agentmap-collect`). When Claude Code
changes a field, read both the old and the new form there, so that old records still open.
New fixtures should be captured from a real Claude Code run (anonymized) and say which version
they come from; `tests/README.md` describes how.

### Writing convention

The convention markers are parsed twice with the same rules: in Lua (`lua/agentmap/brief.lua`) and
in Python (`bin/agentmap-collect`). Change both together and add a case to
`tests/fixtures/convention_cases.jsonl`; `tests/test_brief.lua` and `tests/test_collector.sh` run it
through both parsers.

## Demo GIF

`demo/agentmap.gif` is recorded from made-up records with [vhs](https://github.com/charmbracelet/vhs):
`NVIM_DIR=/path/to/nvim bash demo/record.sh` (needs only docker). The scenario is
`demo/scenario.jsonl`, played by `demo/replay.py` through the real recorder.

## License

By contributing you agree that your contribution is released under the [MIT License](LICENSE).
