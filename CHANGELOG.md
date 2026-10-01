# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org/).
The minor version goes up when the record format (`_v` in `hooks.jsonl`, the state cache version)
changes; records written by older versions stay readable.

## [0.1.0] - unreleased

First public release.

### Added

- Live map of Claude Code agents inside Neovim: parent, children and grandchildren laid out as
  `START ▶ stage ▶ … ▶ END`, one map per prompt, updated while Claude Code works. Status in text
  and color: `PENDING`, `RUNNING`, `WAITING`, `REVIEW`, `DONE`, `REWORK`, `FAILED`.
- List (tree) view, switched with `v`, used automatically when the map does not fit.
- Detail view per agent: why it was delegated (`[Goal]` / `[Why delegate]` / `[Done when]`),
  progress notes and tools from its transcript, changed files, final report or "Needs confirmation".
- HUMAN CHECK boxes for AskUserQuestion: purple while waiting for your answer, green when answered,
  linked to the sub-agent that needed the decision.
- Review records (`PASS` / `RETRY` / `ESCALATE`) with history and reruns; a generic rubric
  (`rubric/RUBRIC.md`) and an entry point for verdict providers (`require("agentmap.review").register`).
- Export of a prompt's map to Markdown, HTML (bundled converter, no external tool) and PDF
  (through a command you configure, e.g. headless Chrome or Edge).
- Recorder `bin/agentmap-collect` (Python 3, standard library only) and `:AgentMapInstallHooks`,
  which registers it in Claude Code's `settings.json` after showing a diff; idempotent, keeps a backup.
- Import of sessions recorded before the hooks were installed, from Claude Code's transcripts.
- `:checkhealth agentmap`.
- English and Japanese user interface (`lang = "en" | "ja"`); the writing convention is read in
  both languages, always.
- Transcript (`t`), git diff (`d`) and working-folder (`w`) views for an agent.

### Notes

- Verified with Claude Code 2.1.283 – 2.1.286.
- Windows-native Neovim is experimental.
- The default record folder is `stdpath("data")/agentflow`, and `$AGENTFLOW_DIR` is read as a
  deprecated name for `$AGENTMAP_DIR`, so records from the earlier private version ("AgentFlow")
  keep working. Hooks registered by that version are replaced by `:AgentMapInstallHooks`.
