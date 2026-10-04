# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org/).
The minor version goes up when the record format (`_v` in `hooks.jsonl`, the state cache version)
changes; records written by older versions stay readable.

## [0.2.0] - unreleased

### Added

- Progress per box: finished steps ÷ all steps as fact; the running step is estimated from the
  typical time of similar past agents (median of your own records per agent type and model) and
  marked `~` (`[RUNNING] ~62.4%`). Boxes without a step list are estimated from elapsed time only
  (at most 95.0%); a parent without a step list shows the plain average of its children (finished
  = 100, not started yet = 0). The detail view lists the steps; exports show the value at export time.
- Step lists: the main agent's TaskCreate / TaskUpdate / TaskList are recorded; sub-agents write
  `## Steps` and `Step N done` (`## 手順` / `手順 N 完了`), read from their transcript.
  The writing convention has a new paragraph for it.
- The map is redrawn once a second while something runs (progress and elapsed time move);
  it stops while the map is hidden or in another tab page.
- A light flows along the line into each running agent (parent → child), back to the parent for
  3 seconds when the agent finishes, and in purple into a HUMAN CHECK that waits for an answer.
  Highlight-only (`AgentMapFlow*`, `AgentMapFlowBack*`, `AgentMapFlowWait*`); no timer runs when
  nothing is lit.
- Steering: `s` on a box or `:AgentMapSteer {n|id} [text]`. Running sub-agents get the text at
  their next tool call (a synchronous `PreToolUse` hook denies it with the text as the reason) or
  when they try to finish (`SubagentStop`); the main agent gets it typed into its `:terminal`;
  a finished agent becomes a redo request to the main agent. When an instruction reaches a
  sub-agent, its parent is told once by the same route (also when two Neovims show the same run:
  the records are checked before a notice is written). Marks `✎n` / `✎` / `✎!` in the
  box, a steering section in the detail view and in exports. Nothing is sent, with a message,
  when the registered hooks are outdated (hooks route only) or when the run has ended (terminal
  route: the Claude in that folder would be another conversation).
- Settings `progress`, `animation` and `steer` (each also accepts `false`).
- `:checkhealth agentmap`: progress history, estimate check, light, steering hook, pending
  steering flag and Claude terminal rows.
- `<root>/progress_log.jsonl` (estimate vs. actual duration, for checking the estimate) and
  `<root>/stats.json` (cached medians).

### Changed

- The `~50%` in a box (finished children ÷ children) is replaced by the new progress value.
- State cache version `SV` 9 (the cache is rebuilt; records are unchanged, `_v` stays 1).
- Hooks: new PostToolUse matcher (TaskCreate, TaskUpdate, TaskList), a second synchronous
  `PreToolUse` registration (a shell guard that returns in about 2 ms when nothing is pending),
  and `SubagentStop` is now synchronous. Existing registrations show as outdated: run
  `:AgentMapInstallHooks` again.
- Verified with Claude Code 2.1.288 and 2.1.289.

### Notes

- In Claude Code 2.1.288 sub-agents cannot use TaskCreate / TaskUpdate; they use the
  `## Steps` convention.
- Steering through hooks is shown to the model as `PreToolUse:<Tool> hook error: …`; stopping an
  agent at its end shows `Stop hook error occurred` in Claude Code's terminal. The main agent may
  ignore hook-delivered instructions depending on the model, so it is steered through its terminal.
- Steering text is stored as written (not redacted).
- `steer.submit_delay_ms` defaults to 300: Claude Code 2.1.289 treats a long line (about 250
  characters, the length of a parent notice) arriving in one write as a paste and leaves it unsent
  in its input box; Enter sent 150 ms or more later submits it. Short lines submit either way.
  Lines to the same terminal are sent one after another, so two instructions in the same second
  do not end up as one line.
- A sub-agent's transcript does not exist until its first message; the step list is now looked for
  again after 2 seconds (was 10), so `## Steps` shows up a few seconds after the agent starts.

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
