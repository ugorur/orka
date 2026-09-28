#!/usr/bin/env bash
# Orka worker adapter: OpenAI Codex CLI.
# Contract (all adapters): env ORKA_WT (worktree), ORKA_MODEL, ORKA_EFFORT (may be empty),
# ORKA_PROMPT (prompt file), ORKA_OUT (attempt dir). Write the worker's final message to
# $ORKA_OUT/report.txt and anything else to $ORKA_OUT/. Exit code = worker exit code.
args=(exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -C "$ORKA_WT" -o "$ORKA_OUT/report.txt")
[ -n "$ORKA_MODEL" ] && args+=(-m "$ORKA_MODEL")
[ -n "$ORKA_EFFORT" ] && args+=(-c "model_reasoning_effort=$ORKA_EFFORT")
[ -n "${ORKA_SEARCH:-}" ] && args=(--search "${args[@]}")
codex "${args[@]}" - < "$ORKA_PROMPT" > "$ORKA_OUT/log.jsonl"
rc=$?
grep -E '^\{' "$ORKA_OUT/log.jsonl" | jq -sc '[.[] | select(.type=="turn.completed") | .usage] |
  {input: (map(.input_tokens // 0) | add), cached: (map(.cached_input_tokens // 0) | add),
   output: (map(.output_tokens // 0) | add)}' > "$ORKA_OUT/usage.json" 2>/dev/null
exit $rc
