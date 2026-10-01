# agentmap.nvim

See what your Claude Code agents are doing, as a live map inside Neovim.

![agentmap.nvim: agents run, one stops to ask, the human check turns from purple to green](demo/agentmap.gif)

*The demo replays made-up records (`demo/`); no real session is shown.*

Claude Code can start sub-agents, and those can start their own. agentmap.nvim draws that
work as a map from `START` through stages to `END`: who started whom, what is running, what
has finished, and where a person is needed. It updates while Claude Code works and keeps
every run, so you can open old ones later.

[日本語の説明は README.ja.md](README.ja.md)

## What it shows

- **The map.** Parent, children and grandchildren as boxes, laid out `START ▶ stage 1 ▶ stage 2 ▶ … ▶ END`.
  Agents started together share a stage. Each box shows its status in text *and* color:
  `[PENDING]` grey, `[RUNNING]` yellow, `[WAITING]` purple, `[REVIEW]` blue, `[DONE]` green,
  `[REWORK]` / `[FAILED]` red. One map per prompt you typed.
- **Why, how and what came back.** The detail view of an agent shows why the parent delegated
  the task, the agent's progress (its short notes and the tools it used, in time order),
  the files it changed, and its final report.
- **HUMAN CHECK.** When Claude asks you a question (AskUserQuestion), a purple `[WAITING]` box
  appears in the map, linked to the agent that caused it. It turns green with your answer.
- **Review and rework.** Mark an agent's work as `PASS`, `RETRY` or `ESCALATE` with a reason.
  Reviews are kept as history, and a rerun is shown as a new attempt of the same agent.
- **Export.** Save the map of a prompt as Markdown, HTML or PDF (with a Mermaid diagram and a
  text tree), for a report or a pull request.

### How is it different from other tools?

Other agent monitors for Claude Code (for example
[claude-code-hooks-multi-agent-observability](https://github.com/disler/claude-code-hooks-multi-agent-observability)
and [agents-observe](https://github.com/simple10/agents-observe)) show events in a web page
served by a local server. agentmap.nvim runs **inside Neovim**: no server, no browser, no
extra port. The map opens in a tab next to your code, `t` opens an agent's transcript and
`d` its git diff. Records are plain JSON Lines files on your disk.

## How it works

```
Claude Code ── hooks ──▶ bin/agentmap-collect ──▶ <root>/projects/<project>/runs/<session>/hooks.jsonl
 (unchanged)              (Python 3, stdlib only)                     │
                                                                      ▼
                                              Neovim: :AgentMap reads and watches the file
```

- Claude Code calls a small recorder through its [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks).
  The recorder appends one short line per event and exits. It never prints, never fails,
  and never changes what Claude Code does.
- Almost all hooks run asynchronously, so Claude Code does not wait for them. Only `Stop`
  and `SessionEnd` run synchronously (a few milliseconds), because asynchronous ones were
  lost when Claude Code exited.
- Neovim reads the records. Neovim does not have to be open while Claude Code runs; you can
  look at a run afterwards.

## Requirements

| | Version |
|---|---|
| Neovim | 0.10 or newer |
| Python | 3 (standard library only). `python3`, `python` or `py -3` is used, in that order |
| Claude Code | verified with 2.1.283 – 2.1.286 (see [Compatibility](#compatibility)) |
| OS | Linux, macOS, WSL. Windows-native Neovim is **experimental** |

Optional: `git` (for the diff view), [oil.nvim](https://github.com/stevearc/oil.nvim)
(the `w` key opens the agent's folder in it), a Chromium-based browser for PDF export.
Lists use `vim.ui.select`, so snacks.nvim, telescope, fzf-lua or mini.pick are used if you have
one of them set up for it. No plugin is required.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ayame0328/agentmap.nvim",
  lazy = false,                   -- load at startup (see below)
  opts = {},                      -- lang = "ja" for Japanese
  keys = {
    { "<leader>aa", "<Cmd>AgentMap<CR>",       desc = "AgentMap: open map" },
    { "<leader>ar", "<Cmd>AgentMapRuns<CR>",   desc = "AgentMap: past runs" },
    { "<leader>ae", "<Cmd>AgentMapExport<CR>", desc = "AgentMap: export" },
  },
}
```

`setup()` is optional; the commands work without it. Keep `lazy = false`: with `keys` alone,
lazy.nvim loads the plugin only when one of those keys is pressed, and until then
`:AgentMapInstallHooks` and `:checkhealth agentmap` do not exist. Loading it costs nothing
noticeable (one small file).

Then, once:

1. Run `:AgentMapInstallHooks`. It shows the change to Claude Code's `settings.json` as a diff
   and asks before writing. Your other settings and hooks are kept, the original file is
   saved as `settings.json.bak-<timestamp>`, and running it again changes nothing.
   Run it again after updating the plugin if `:checkhealth agentmap` says the hooks are outdated.
2. Run `:checkhealth agentmap`. It checks Neovim, Python, the recorder, the Claude Code folder,
   the hooks, the record folder and the optional tools.
3. Start a new Claude Code session. Recording starts with that session.
4. Add the [writing convention](#writing-convention) to your `CLAUDE.md` (recommended).

Sessions from before the hooks were installed can be imported from Claude Code's transcripts
with `:AgentMapRuns` or `:AgentMapImport`.

### Try it without Claude Code

```sh
cd ~/.local/share/nvim/lazy/agentmap.nvim      # or wherever the plugin is
python3 demo/replay.py --root /tmp/agentmap-demo --claude-dir /tmp/agentmap-demo-claude &
sleep 1; AGENTMAP_DIR=/tmp/agentmap-demo nvim -c AgentMap
```

The script plays the session from the demo above (about 30 seconds of made-up events)
through the real recorder. The `sleep 1` gives it time to write the first record; without it
`:AgentMap` can run before anything exists and say "No recorded runs" (then just run `:AgentMap` again).

## Usage

### Commands

| Command | What it does |
|---|---|
| `:AgentMap [session_id [prompt_id]]` | Open the map of the latest prompt (follows new runs) |
| `:AgentMapRuns` | Pick a past run |
| `:AgentMapAgent {n\|id}` | Details of an agent |
| `:AgentMapRefresh` | Reload |
| `:AgentMapExport [markdown\|html\|pdf] [path]` | Export the prompt shown in the map |
| `:AgentMapReview {n\|id} {PASS\|RETRY\|ESCALATE\|SUBMIT} [reason]` | Record a review |
| `:AgentMapInstallHooks [settings.json]` | Register the recording hooks in Claude Code |
| `:AgentMapImport [session_id]` | Import a run from a transcript |

### Keys in the map

All keys are local to the map buffer; nothing global is mapped unless you ask for it
(`keymaps = { global = true }` adds `<leader>aa`, `<leader>ar`, `<leader>ae`).

| Key | Action |
|---|---|
| `1`–`9` | Details of agent number n |
| `Enter` | Details of the box under the cursor (a HUMAN CHECK box shows the question) |
| `n` / `p` | Next / previous box |
| `+` / `-` | Expand / collapse children |
| `z` / `BS` | Show only this agent and below / go back up |
| `t` | Transcript of the agent |
| `d` | git diff of the agent |
| `w` | Go to the agent's working folder |
| `a` | Review (submit / PASS / RETRY / ESCALATE / rerun / name) |
| `e` | Export |
| `r` | Reload |
| `R` | Past runs |
| `v` | Switch between map and list |
| `?` | Key list |
| `q` | Close |

In the detail, transcript and diff views: `BS` goes back, `q` closes, `Enter` opens the
agent / parent / HUMAN CHECK on the line, and `t` / `d` / `w` / `a` work as in the map.

When the map is too wide for the window it opens as a list (tree) instead; `v` switches.

### Language

English is the default. For Japanese: `opts = { lang = "ja" }`, or `vim.g.agentmap_lang = "ja"`
before the plugin loads.

## Configuration

All options with their defaults:

```lua
require("agentmap").setup({
  lang = "en",                 -- "en" | "ja"; falls back to vim.g.agentmap_lang when not given
  root = nil,                  -- record folder; nil → $AGENTMAP_DIR → stdpath("data") .. "/agentflow"
  claude_config_dir = nil,     -- Claude Code's folder; nil → $CLAUDE_CONFIG_DIR → ~/.claude
  python = nil,                -- nil → first of "python3", "python", "py -3"; or a string / list
  open = "tab",                -- where the map opens: "tab" | "vsplit" | "current"
  aux_width = 0.45,            -- width of the side view (share of the screen)
  box_w = 26,                  -- inner width of a box
  col_gap = 7,                 -- space between boxes
  mode = "auto",               -- "box" | "tree" | "auto" (tree when the map does not fit)
  poll_ms = 1500,              -- how often files are checked for changes
  debounce_ms = 200,           -- wait before redrawing after a change
  switch_delay_ms = 15000,     -- after a prompt finishes, wait this long before following the next one
  detail = { progress_max = 40, note_chars = 120, report_chars = 4000, lead_chars = 400 },
  transcript = { max_chars = 2000, max_bytes = 5e6, notes_first_bytes = 1e6, notes_max = 400 },
  review = {
    provider = "auto",         -- "auto" | "manual" | name of a registered provider
    rubric = nil,              -- path to your RUBRIC.md; nil → the bundled rubric/RUBRIC.md
  },
  keymaps = { global = false },     -- true adds <leader>aa / <leader>ar / <leader>ae
  hooks = { settings_path = nil },  -- nil → <claude_config_dir>/settings.json
  export = {
    html_command = nil,        -- argv; Markdown on stdin, title as last argument, HTML on stdout
    pdf_command = nil,         -- argv with %{html} %{out} %{title}; nil → PDF export is off
  },
  brief = { markers = nil },   -- reserved (custom markers are planned, see Roadmap)
})
```

The default record folder is named `agentflow` (not `agentmap`) on purpose: it keeps records
from the earlier private version readable. `$AGENTFLOW_DIR` is still read as an old name for
`$AGENTMAP_DIR`.

## Writing convention

agentmap.nvim shows *why* an agent was started and *what it reported* only when Claude writes
them in a fixed form. It does not guess: anything not written this way is shown as `(not written)`.
Paste this into your `CLAUDE.md`:

```markdown
## Delegating to agents (read by agentmap.nvim)

agentmap.nvim reads the headings and item names below mechanically and shows them in Neovim.
Items that are missing are shown as "(not written)"; nothing is guessed.

**Parent (the one that starts an Agent): the first three lines of the prompt**, in this order:

[Goal] what this is for (one line)
[Why delegate] why it is delegated instead of done directly (one line)
[Done when] what has to come back for the task to be finished (one line)

**Child (the started agent): the final report.** When returning with SubagentHandback,
write it inside the message in this form:

## Report
- Done: what was done
- Approach: how it was approached
- Why: why that approach
- Open issues: "none" if there are none

**Child: when a human decision is needed.** A sub-agent cannot ask the user directly.
Stop, and instead of the report write this and finish:

## Needs confirmation
- Working on: what was being done
- Blocked at: where it cannot continue
- Question: the question, in one sentence
- Options:
  1. Name -> what happens after choosing it
  2. Name -> what happens after choosing it

**Parent: asking the user (AskUserQuestion) because of a child's Needs confirmation**

- question: "<description given to the child>: <the child's Question>"
- header: the start of the description (up to 12 characters)
- each option's label is the child's option name, unchanged; end its description with
  "-> if chosen: <what happens next>"
- when asking on your own initiative, use the same form without the "<description>:" part
- after the answer, continue accordingly; when restarting the child, say in [Goal] that "<answer>" was chosen
```

The exact parsing rules are in [docs/writing-convention.md](docs/writing-convention.md).
English and Japanese markers (`【目的】`, `## 報告`, … see
[docs/writing-convention.ja.md](docs/writing-convention.ja.md)) are both always accepted.

## Human checks

A HUMAN CHECK box appears when Claude calls AskUserQuestion. It is linked to the sub-agent whose
description appears in the question (the convention above writes it there), otherwise to the
agent that asked. The box is purple `[WAITING]` until you answer in the terminal, then green
`[DONE]` with your answer, or grey `[UNANSWERED]` if the turn ended without an answer.
`Enter` on the box shows the question, each option with what happens next, and the child's
`Needs confirmation` report.

## Review and verdict providers

Press `a` on an agent (or use `:AgentMapReview`) to record `PASS`, `RETRY` or `ESCALATE` with a
reason. The verdict is always yours. Every review is written to the run's records and to
`<root>/review_log.jsonl`, together with the version of the rubric you used.
The bundled [rubric/RUBRIC.md](rubric/RUBRIC.md) has five questions; point `review.rubric` at your own.

A verdict provider can *propose* a verdict before you choose:

```lua
require("agentmap.review").register("my-judge", {
  -- optional: say whether this provider can run on this machine
  available = function() return vim.fn.executable("my-judge") == 1, "my-judge not found" end,
  -- ctx = { agent, agent_id, state, run, rubric }; call cb({ verdict = "PASS", reason = "..." }) or cb(nil)
  evaluate = function(ctx, cb) cb({ verdict = "PASS", reason = "tests pass" }) end,
})
```

With `review.provider = "auto"` the first available registered provider is used, otherwise you
choose by hand. You still make the final choice; the proposal is logged next to it.

## Export

`:AgentMapExport` (or `e` in the map) writes the prompt shown in the map: an overview, the map as a
Mermaid diagram and as a text tree, every agent with its brief and report, the human checks,
the reviews, the changed files and the tool calls.
Files go to `<root>/projects/<project>/runs/<session>/exports/` unless you give a path.

- **Markdown**: always available.
- **HTML**: a single file with inline CSS (light and dark), converted by a small converter bundled
  in Lua. Set `export.html_command` to use another converter (for example pandoc).
- **PDF**: set `export.pdf_command` to a program that prints HTML to PDF. Examples:

```lua
-- Linux
export = { pdf_command = { "google-chrome", "--headless=new", "--disable-gpu",
  "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
-- macOS
export = { pdf_command = { "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "--headless=new", "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
-- Windows (Edge)
export = { pdf_command = { "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "--headless=new", "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
-- WSL, using Chrome on Windows (paths are converted to Windows form automatically)
export = { pdf_command = { "/mnt/c/Program Files/Google/Chrome/Application/chrome.exe",
  "--headless=new", "--disable-gpu", "--no-pdf-header-footer", "--print-to-pdf=%{out}", "%{html}" } }
```

## Privacy: what is stored

Records stay on your disk, in `<root>` (default `stdpath("data")/agentflow`). Nothing is sent anywhere.

Stored, per event:

- session id, prompt id, agent id and type, working folder, event name, time
- the first 200 characters of your prompt and of each Agent prompt, and the three
  convention lines (`[Goal]` `[Why delegate]` `[Done when]`, up to 300 characters each)
- agent description, type and model
- tool name and its target: the file path for Write / Edit, the first line of a Bash command (up to 120 characters)
- AskUserQuestion questions, options and answers (clipped)
- the child's final report (up to 2000 characters) and the first 200 characters of the last message

Not stored:

- full prompts, tool output, file contents, Read / Grep / web tool calls
- anything that looks like a secret: `api_key=…`, `token: …`, `password=…`, `Bearer …`,
  `sk-…`, `ghp_…`, `github_pat_…`, `AKIA…`, `xox…-`, `AIza…` are replaced with `***` before writing

The detail and transcript views read Claude Code's own transcript files (in `claude_config_dir`)
when you open them; they are not copied. Exports are written only when you ask.
To delete records, delete folders under `<root>/projects/`.

## Containers, WSL and Windows

- **Claude Code in a container** (devcontainer, Docker, a sandbox) and Neovim on the host:
  see [docs/containers.md](docs/containers.md). You need one folder both can see.
- **WSL**: works as on Linux when Neovim and Claude Code both run inside WSL.
- **Windows-native Neovim**: **experimental** in v0.1.0. Hook commands are written for bash
  (Claude Code runs hooks through Git Bash on Windows). Please report what does not work.

## Compatibility

Claude Code's hook input carries no version number, so compatibility is checked by recording
real hook payloads (see `tests/fixtures/`).

| Claude Code | Checked | Notes |
|---|---|---|
| 2.1.283 – 2.1.286 | 2026-10-01 | The real hook payloads in `tests/fixtures/` were captured from 2.1.283 |

Hooks used: `SessionStart`, `UserPromptSubmit`, `PreToolUse` (Agent, AskUserQuestion),
`PostToolUse` (Agent, AskUserQuestion, Write, Edit, MultiEdit, NotebookEdit, Bash, EnterWorktree,
ExitWorktree), `PostToolUseFailure` (Agent, AskUserQuestion), `SubagentStart`, `SubagentStop`,
`Stop`, `SessionEnd`. Unknown events are ignored, so new hook types do not break it.
`PermissionRequest` is not used, so agentmap.nvim can never approve or deny anything.

The record format is versioned (`_v`). Records written by older versions stay readable.

## Status and roadmap

v0.1.0 is the first public release of a tool I built for my own work. I answer issues a few
times a week, without promises.

Planned:

- **Codex** support (the provider layer is ready; only Claude Code is implemented)
- **Custom markers** for the writing convention (`brief.markers`, reserved now)
- Automatic cleanup of old records
- Windows-native Neovim: leave experimental after fixes

Bug reports are most useful with `:checkhealth agentmap` output and a few lines of `hooks.jsonl`
(check them for anything private first). See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
