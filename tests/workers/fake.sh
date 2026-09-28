#!/usr/bin/env bash
# Test-only Orka worker adapter: no model, just proves the plumbing.
# Writes a file in the worktree, commits it, and reports what it saw. ORKA_FAKE_* knobs:
# SLEEP seconds, RC exit code, LEAK text appended to the report, TRACE dir to detect overlapping workers,
# BADUSAGE=<text> writes it as usage.json, TRAP=1 exits 0 on TERM, STUBBORN=1 leaves a child that ignores TERM.
cd "$ORKA_WT" || exit 1
if [ -n "${ORKA_FAKE_TRACE:-}" ]; then # a directory: one file per live worker; note any overlap
  mkdir -p "$ORKA_FAKE_TRACE" && touch "$ORKA_FAKE_TRACE/$$"
  set -- "$ORKA_FAKE_TRACE"/[0-9]*
  [ $# -gt 1 ] && touch "$ORKA_FAKE_TRACE/overlap"
fi
echo "fake worker was here: $ORKA_OUT" > FAKE_WORKER.txt
git add FAKE_WORKER.txt && git commit -qm "fake worker" || exit 1
{ echo "fake report"; echo "model=$ORKA_MODEL effort=$ORKA_EFFORT"; echo "prompt_lines=$(wc -l < "$ORKA_PROMPT")"; } > "$ORKA_OUT/report.txt"
[ -n "${ORKA_FAKE_LEAK:-}" ] && echo "$ORKA_FAKE_LEAK" >> "$ORKA_OUT/report.txt"
[ -n "${ORKA_FAKE_BADUSAGE:-}" ] && printf '%b\n' "$ORKA_FAKE_BADUSAGE" > "$ORKA_OUT/usage.json"
if [ -n "${ORKA_FAKE_STUBBORN:-}" ]; then # a child that ignores TERM
  sh -c 'trap "" TERM; exec sleep 39' &
  sleep 0.3 # let it install the trap before anyone signals the group
fi
if [ -n "${ORKA_FAKE_TRAP:-}" ]; then # exit 0 on TERM, like a CLI that shuts down cleanly
  trap 'exit 0' TERM; sleep "$ORKA_FAKE_SLEEP" & wait $!
elif [ "${ORKA_FAKE_SLEEP:-0}" -gt 0 ]; then sleep "$ORKA_FAKE_SLEEP"; fi
[ -n "${ORKA_FAKE_TRACE:-}" ] && rm -f "$ORKA_FAKE_TRACE/$$"
exit "${ORKA_FAKE_RC:-0}"
