#!/usr/bin/env bash
# Orka worker adapter: Gemini CLI. See codex.sh for the adapter contract. No effort flag.
# Log in interactively once first: an unauthenticated headless run waits for a browser login.
args=(-p "$(cat "$ORKA_PROMPT")" --approval-mode yolo --skip-trust -o json)
[ -n "$ORKA_MODEL" ] && args+=(-m "$ORKA_MODEL")
(cd "$ORKA_WT" && gemini "${args[@]}" < /dev/null) > "$ORKA_OUT/log.json"
rc=$?
jq -r '.response // empty' "$ORKA_OUT/log.json" > "$ORKA_OUT/report.txt" 2>/dev/null
exit $rc
