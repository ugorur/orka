#!/usr/bin/env bash
# Orka worker adapter: Grok CLI. See codex.sh for the adapter contract.
args=(--prompt-file "$ORKA_PROMPT" --cwd "$ORKA_WT" --always-approve --no-plan --output-format json)
[ -n "$ORKA_MODEL" ] && args+=(-m "$ORKA_MODEL")
[ -n "$ORKA_EFFORT" ] && args+=(--reasoning-effort "$ORKA_EFFORT")
grok "${args[@]}" < /dev/null > "$ORKA_OUT/log.json"
rc=$?
jq -r '.text // empty' "$ORKA_OUT/log.json" > "$ORKA_OUT/report.txt" 2>/dev/null
jq -c '{usd: .total_cost_usd, turns: .num_turns}' "$ORKA_OUT/log.json" > "$ORKA_OUT/usage.json" 2>/dev/null
exit $rc
