#!/usr/bin/env bash
# Orka worker adapter: GitHub Copilot CLI. See codex.sh for the adapter contract.
# -s prints only the final message, so stdout is the report. Some models reject an effort
# setting; leave "effort" empty in orka.json for those.
args=(-p "$(cat "$ORKA_PROMPT")" -s --allow-all-tools --allow-all-paths --no-ask-user -C "$ORKA_WT")
[ -n "$ORKA_MODEL" ] && args+=(--model "$ORKA_MODEL")
[ -n "$ORKA_EFFORT" ] && args+=(--reasoning-effort "$ORKA_EFFORT")
copilot "${args[@]}" < /dev/null > "$ORKA_OUT/report.txt"
