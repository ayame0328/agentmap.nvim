# Tests

The test suite uses no external framework: each `test_*.lua` is a plain script run by headless
Neovim, each `test_*.sh` is a bash script, and `tests/run.sh` runs them all.

## Running

```sh
bash tests/run.sh            # everything
bash tests/run.sh export     # only tests whose file name contains "export"
make test                    # same as the first line (optional Makefile)
make test T=export
```

Exit code is `0` when every test passes (skipped tests do not count as failures) and `1` otherwise.
The last line looks like:

```
Total: PASS 32 / FAIL 0 / SKIP 0 (18 s)
```

A full run takes about 20 seconds.

### Requirements

| Tool | Needed for | If missing |
|---|---|---|
| Neovim 0.10 or newer | every test | `run.sh` stops with an error |
| Python 3 (`python3`) | `test_collector.sh`, `test_smoke.sh`, `test_hooks_merge.lua` (the hook collector and hook registration) | those tests are reported as `SKIP` |
| `timeout` | per-test time limit (120 s for Lua, 300 s for shell tests) | `gtimeout` or a small `perl` shim is used (macOS); with neither, tests run without a limit |
| `sha256sum` | `test_smoke.sh` | a shim over `shasum -a 256` is used (macOS) |
| `mmdc` (mermaid-cli) | full Mermaid syntax check in the export tests | only the shape of the Mermaid text is checked |

### Which Neovim is used

`run.sh` picks the first of these that is an executable file reporting `NVIM v…`:

1. `$AGENTMAP_TEST_NVIM`
2. `$NVIM`
3. every `nvim` on `PATH`, in order
4. `~/.local/bin/nvim`, `/opt/homebrew/bin/nvim`, `/usr/local/bin/nvim`, `/usr/bin/nvim`, `/snap/bin/nvim`

When you run the tests from a Neovim `:terminal`, `$NVIM` holds the parent Neovim's RPC socket,
not a binary. `run.sh` ignores it in that case, so you do not need to unset or override it.
To test against a specific build, set `AGENTMAP_TEST_NVIM=/path/to/nvim`.

### Isolation

Every test runs in a fresh temporary directory with its own `HOME`, `XDG_CONFIG_HOME`,
`XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `CLAUDE_CONFIG_DIR` and `AGENTMAP_DIR`.
Lua tests start with `nvim --headless --clean -u tests/minimal_init.lua`, so your `init.lua`,
plugins, recorded runs and Claude Code `settings.json` are never read or written. No test depends
on real Claude Code sessions; everything comes from `tests/fixtures/`.

## Writing a test

```lua
-- tests/test_example.lua
local t = require("t")              -- tests/t.lua, on package.path via minimal_init.lua

t.eq(1 + 1, 2, "addition")          -- deep equality
t.ok(vim.fn.has("nvim-0.10") == 1, "Neovim 0.10+")
t.matches("hello world", "^hello", "pattern")
t.run("does not throw", function() require("agentmap.util") end)
if vim.fn.executable("mmdc") == 0 then t.skip("mmdc not installed") end

t.done()                            -- prints the counts, exits 1 on any failure
```

- Fixtures are read from `vim.g.agentmap_test_dir .. "/fixtures"`.
- `vim.g.agentmap_test` is `true`; `hooks.install()` refuses to run without an explicit `path`,
  so a test cannot touch a real `settings.json` by accident.
- A test that needs Python 3 should say `requires: python3` in a comment within its first
  15 lines; `run.sh` then skips it when Python is missing.

## Fixtures

All paths, user names and project names in the fixtures are anonymized
(`/home/user`, `/home/user/work/demo`, project slug `-home-user-work-demo`).

| File | What it is | Source |
|---|---|---|
| `hook_payloads_real.jsonl` | 29 raw hook payloads as Claude Code sends them to the collector: a probe run (ROOT → child → grandchild, 14 lines), a run with the step-list tools `TaskCreate` / `TaskUpdate` / `TaskList` (11 lines), and the `PreToolUse` / `SubagentStop` payloads used by the steering tests (4 lines) | first 14 captured from Claude Code **2.1.283**; the step-list run captured from **2.1.288**; the steering payloads written in the **2.1.288** payload shape; all anonymized |
| `hooks_probe.jsonl` | the probe run's payloads after `bin/agentmap-collect` (other tests refer to its lines by number; keep the order) | generated: `bash tests/test_collector.sh --regen-fixture` |
| `hooks_tasks.jsonl` | the step-list run after `bin/agentmap-collect` | generated: `bash tests/test_collector.sh --regen-fixture` |
| `agent_steps.jsonl` | a sub-agent transcript with a `## Steps` list and a `Step 1 done` mark (plus marks inside tool input / tool results, which must be ignored) | hand-written in the transcript format of Claude Code **2.1.288** |
| `claude_config/` | a fake Claude Code config dir (`projects/<slug>/<session>.jsonl`, `subagents/`, a Workflow run) | transcripts from Claude Code **2.1.283**, anonymized and trimmed |
| `agent_report*.jsonl` | sub-agent transcripts with a parent prompt and a final report (Japanese and English variants) | based on Claude Code **2.1.286** transcripts; the `_en` files are hand-written English versions |
| `convention_cases.jsonl` | writing-convention cases shared by the Lua parser and the Python collector (parity test) | hand-written |
| `hooks_ask.jsonl`, `transcript_ask.jsonl` | a run that stops for a human check (AskUserQuestion) | hand-written in the recorded format |
| `events_review.jsonl` | events for the review reducer | hand-written |
| `state_small.lua`, `state_check.lua`, `transcript_small.jsonl` | small in-memory states for rendering and export (`state_small.lua` also has step lists on ROOT and `[1]`, and steering instructions on `[2]`) | hand-written |

Hook payloads carry no version field, so the Claude Code version is recorded here. When Claude
Code changes its hook or transcript format, capture new payloads, anonymize them the same way and
add a row to this table.

## CI

`.github/workflows/ci.yml` runs `bash tests/run.sh` on `ubuntu-latest` and `macos-latest` with
Neovim `v0.10.4` (oldest supported), `stable` and `nightly`. Nightly failures do not fail the
workflow. Windows is not part of CI for v0.1.0 (Windows-native Neovim is experimental).
