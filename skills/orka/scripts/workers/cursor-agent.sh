#!/usr/bin/env bash
# Orka worker adapter: Cursor Agent CLI. See codex.sh for the adapter contract.
# Cursor has no reasoning-effort flag; pick a thinking model instead (ORKA_EFFORT is ignored).
args=(-p --force --trust --output-format json --workspace "$ORKA_WT")
[ -n "$ORKA_MODEL" ] && args+=(--model "$ORKA_MODEL")
cursor-agent "${args[@]}" "$(cat "$ORKA_PROMPT")" < /dev/null > "$ORKA_OUT/log.json"
rc=$?
jq -r '.result // empty' "$ORKA_OUT/log.json" > "$ORKA_OUT/report.txt" 2>/dev/null
exit $rc
