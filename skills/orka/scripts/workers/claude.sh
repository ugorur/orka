#!/usr/bin/env bash
# Orka worker adapter: Claude Code. See codex.sh for the adapter contract.
args=(-p --output-format json --dangerously-skip-permissions --no-session-persistence --disable-slash-commands)
[ -n "$ORKA_MODEL" ] && args+=(--model "$ORKA_MODEL")
[ -n "$ORKA_EFFORT" ] && args+=(--effort "$ORKA_EFFORT")
(cd "$ORKA_WT" && claude "${args[@]}" < "$ORKA_PROMPT") > "$ORKA_OUT/log.json"
rc=$?
# Depending on version/settings the JSON is one result object or an array of messages.
res='if type == "array" then (map(select(.type == "result")) | last) else . end'
jq -r "$res | .result // empty" "$ORKA_OUT/log.json" > "$ORKA_OUT/report.txt" 2>/dev/null
jq -c "$res | {usd: .total_cost_usd, turns: .num_turns}" "$ORKA_OUT/log.json" > "$ORKA_OUT/usage.json" 2>/dev/null
exit $rc
