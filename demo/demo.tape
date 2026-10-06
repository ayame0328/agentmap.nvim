# Demo GIF for the README (v0.1.2). Recorded with vhs (https://github.com/charmbracelet/vhs)
# from replayed, made-up hook records: no Claude Code, nothing personal on screen.
#
#   bash demo/record.sh        (runs vhs in docker; see the comments there)
#
# Timeline (seconds after replay.py starts; see demo/scenario.jsonl). A pause or the gate holds
# the replayed hook exactly as it holds Claude Code, so everything after happens that much later:
#    0  prompt; the parent creates three tasks (TaskCreate) and starts two agents
#       (Survey: no step list -> "~" from elapsed time; Design: "## Steps" -> steps as fact)
#  6.5  Survey reports; 9 Design reports (the light flows back to the parent for 3 s)
#   10  Implement starts and writes its "## Steps"
#   11  the user opens Implement's detail (`3`) and presses `x`              -> " ⏸" (orange)
# 14.2  Implement's next tool call is held by the hook                       -> [PAUSED] (orange),
#       the light on its line stops, its % stops moving
#   18  the user presses `s` and writes an instruction; Ctrl+S resumes Implement (about 9 s
#       paused); the text waits for its end                                  -> " ✎1" (pending)
# 17.8  (+pause) Implement tries to finish ("Needs confirmation"): its SubagentStop hook hands the
#       instruction over and the end is held once; Implement adds the quoting   -> " ✎" (delivered),
#       the detail shows DELIVERED at SubagentStop and the next tool
#   24  `q` closes the detail, `X` turns the gate on for the run              -> " ⏸" on Implement
#   21  (+pause) Implement tries to finish again and waits at the gate         -> [GATE] (orange);
#       its report is already in the detail view (`3`)
#   33  `x` on the box -> Pass (1); `X` turns the gate off; the parent asks the user
#       -> HUMAN CHECK, WAITING (purple light); Implement's detail shows the pauses and the
#          instruction
#   41  the user answers -> HUMAN CHECK DONE (green); Tests run; ~50 the parent tries to end its turn:
#       the notice about the instruction reaches it there (no Claude terminal in the demo), it
#       answers in one line and ends for real at ~52                   -> END [DONE]
# The map is shown from about t = 1.6 (after the hidden setup).

Output demo/agentmap.gif

Set Shell "bash"
Set FontSize 13
Set Width 1600
Set Height 640
Set Padding 12
Set Framerate 12
Set TypingSpeed 80ms
Set Theme "Builtin Dark"

Hide
Type "export TZ=UTC AGENTMAP_DIR=/tmp/agentmap-demo DEMO_CLAUDE_DIR=/tmp/agentmap-demo-claude"
Enter
Type "rm -rf $AGENTMAP_DIR $DEMO_CLAUDE_DIR; (python3 demo/replay.py --root $AGENTMAP_DIR --claude-dir $DEMO_CLAUDE_DIR &); sleep 1; clear; nvim --clean -u demo/init.lua -c AgentMap"
Enter
Sleep 1.5s
Show

# Survey and Design run (one with steps, one estimated from time), then Implement starts
Sleep 9.6s

# Pause Implement: `3` opens its detail view (steps on the right), `x` places the pause.
# Its next tool call (t = 14.2) is held -> [PAUSED], the light stops
Type "3"
Sleep 500ms
Type "x"
Sleep 6s

# Resume it with an instruction: `s` opens the steering menu, 1 = write an instruction (resumes
# it; arrives when it finishes), Ctrl+S sends it. Implement goes on; when it tries to finish, the
# SubagentStop hook hands the text over (its end is held once) and it continues with the quoting
Type "s"
Sleep 800ms
Type "1"
Enter
Sleep 700ms
Type "Quote every field that contains a comma."
Sleep 300ms
Ctrl+S
Sleep 5s

# Gate: close the detail, `X` makes every sub-agent wait before it finishes
Type "q"
Sleep 300ms
Type "X"

# Implement tries to finish again and waits -> [GATE]; open its detail (report, pauses, steering)
Sleep 3.2s
Type "3"
Sleep 2.5s

# `x` on the waiting box: Pass (1) lets it finish; then the gate goes off (`X`)
Type "x"
Sleep 1.2s
Type "1"
Enter
Sleep 1s
Type "q"
Sleep 300ms
Type "X"

# The parent asks the user (HUMAN CHECK, purple). Refresh Implement's detail: steps, pause, steering
Sleep 1.5s
Type "3"
Sleep 4.8s

# Close the side view; the answer arrives, the tests run, the prompt ends
Type "q"
Sleep 300ms
# Scroll the map back to the left edge (the side view had pushed it sideways)
Type "0"
Sleep 13s
