#!/usr/bin/env bash
# Orka worker adapter: OpenCode. See codex.sh for the adapter contract.
# Model is provider/model; effort maps to --variant (provider-specific: minimal … max).
args=(run --dir "$ORKA_WT" --auto --format json)
[ -n "$ORKA_MODEL" ] && args+=(-m "$ORKA_MODEL")
[ -n "$ORKA_EFFORT" ] && args+=(--variant "$ORKA_EFFORT")
opencode "${args[@]}" "$(cat "$ORKA_PROMPT")" < /dev/null > "$ORKA_OUT/log.jsonl"
rc=$?
# JSON events; keep the text of the last assistant message as the report.
grep -E '^\{' "$ORKA_OUT/log.jsonl" | jq -rs '[.[] | select(.type == "text") | .part.text // empty] | last // empty' \
  > "$ORKA_OUT/report.txt" 2>/dev/null
exit $rc
