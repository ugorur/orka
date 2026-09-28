#!/usr/bin/env bash
# Test-only Orka worker adapter: no model, just proves the plumbing.
# Writes a file in the worktree, commits it, and reports what it saw.
cd "$ORKA_WT" || exit 1
echo "fake worker was here: $ORKA_OUT" > FAKE_WORKER.txt
git add FAKE_WORKER.txt && git commit -qm "fake worker" || exit 1
{ echo "fake report"; echo "model=$ORKA_MODEL effort=$ORKA_EFFORT"; echo "prompt_lines=$(wc -l < "$ORKA_PROMPT")"; } > "$ORKA_OUT/report.txt"
[ -n "${ORKA_FAKE_LEAK:-}" ] && echo "$ORKA_FAKE_LEAK" >> "$ORKA_OUT/report.txt"
[ "${ORKA_FAKE_SLEEP:-0}" -gt 0 ] && sleep "$ORKA_FAKE_SLEEP"
exit "${ORKA_FAKE_RC:-0}"
