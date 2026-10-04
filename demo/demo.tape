# Demo GIF for the README (v0.2.0). Recorded with vhs (https://github.com/charmbracelet/vhs)
# from replayed, made-up hook records: no Claude Code, nothing personal on screen.
#
#   bash demo/record.sh        (runs vhs in docker; see the comments there)
#
# Timeline (seconds after replay.py starts; see demo/scenario.jsonl):
#    0  prompt; the parent creates three tasks (TaskCreate) and starts two agents
#       (Survey: no step list -> "~" from elapsed time; Design: "## Steps" -> steps as fact)
#  6.5  Survey reports; 9 Design reports (the light flows back to the parent for 3 s)
#   10  Implement starts and writes its "## Steps"
#   11  the user presses `s` on Implement and writes a steering instruction  -> " ✎1" (purple)
#   19  Implement's next tool call is stopped and gets the text          -> " ✎"  (green);
#       the parent is told (no terminal here, so through the hooks)
#   22  Implement stops with "Needs confirmation"; 23.5 the parent asks the user
#       -> HUMAN CHECK, WAITING (purple light); the detail view of Implement shows its steps,
#          the instruction and "told the parent"
#   31  the user answers -> HUMAN CHECK DONE (green); Tests run; 37.6 the prompt ends -> END [DONE]
# The map is shown from about t = 1.6 (after the hidden setup); the sleeps below line the key
# presses up with t = 11 (Implement is running) and t = 24.5 (the question is on screen).

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

# Steer Implement: `3` opens its detail view (steps on the right), `s` there opens the steering
# menu, 1 = write an instruction, Ctrl+S sends
Type "3"
Sleep 500ms
Type "s"
Sleep 800ms
Type "1"
Enter
Sleep 700ms
Type "Quote every field that contains a comma."
Sleep 300ms
Ctrl+S

# " ✎1" while it waits; at t = 19 the next tool call delivers it -> " ✎", the parent is told
Sleep 7.8s

# The parent asks the user (HUMAN CHECK, purple). Refresh Implement's detail: steps, steering, notice
Type "3"
Sleep 4.8s

# Close the side view; the answer arrives, the tests run, the prompt ends
Type "q"
Sleep 300ms
# Scroll the map back to the left edge (the side view had pushed it sideways)
Type "0"
Sleep 9.8s
