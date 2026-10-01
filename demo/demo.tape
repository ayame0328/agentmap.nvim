# Demo GIF for the README. Recorded with vhs (https://github.com/charmbracelet/vhs)
# from replayed, made-up hook records: no Claude Code, nothing personal on screen.
#
#   bash demo/record.sh        (runs vhs in docker; see the comments there)
#
# Timeline (seconds after replay.py starts; see demo/scenario.jsonl):
#    0  prompt; two agents start (Survey, Design)       -> stage 1, RUNNING (yellow)
#  6.5  Survey reports; 9 Design reports                 -> DONE (green)
#   10  Implement starts; 14 it stops with "Needs confirmation"
#   15  the parent asks the user                         -> HUMAN CHECK, WAITING (purple)
#   22  the user answers                                 -> HUMAN CHECK DONE (green)
# 22.6  Tests start; 27.5 they report; 28.6 the prompt ends -> END [DONE]
# The map is shown from about t = 1.6 (after the hidden setup), so the sleeps below line up
# the key presses with t = 16 (HUMAN CHECK is on screen) and t = 21 (just before the answer).

Output demo/agentmap.gif

Set Shell "bash"
Set FontSize 13
Set Width 1600
Set Height 500
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

# Stage 1 runs, finishes; Implement runs and stops to ask
Sleep 14.5s

# Move to the HUMAN CHECK box and open it while it is WAITING
Type "nnnn"
Sleep 600ms
Enter
Sleep 4s

# Close the side view; the answer arrives, the tests run, the prompt ends
Type "q"
Sleep 300ms
# Scroll the map back to the left edge (the side view had pushed it sideways)
Type "0"
Sleep 9.2s
