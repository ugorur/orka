#!/usr/bin/env bash
# Shared report masking and attempt metadata helpers for run.sh and finish.sh.

orka_mask_report() {
  local report=$1
  [ -f "$report" ] || return 0
  sed -E \
    -e 's/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Za-z0-9_]*[=:][[:space:]]*)"[^"]*"/\1"***"/g' \
    -e "s/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Za-z0-9_]*[=:][[:space:]]*)'[^']*'/\\1'***'/g" \
    -e 's/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Za-z0-9_]*[=:][[:space:]]*)[^[:space:]"'\'']+/\1***/g' \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1***/g' \
    -e 's/(sk|pk|xai)-[A-Za-z0-9_-]{12,}/\1-***/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{20,}/gh*_***/g' "$report" > "$report.tmp" && mv "$report.tmp" "$report"
}

# Arguments: destination, card, cli version, role, cli, model, effort, worktree,
# base, head, attempt, rc, seconds, started, commits, usage JSON, stopped, timed out.
orka_write_meta() {
  local meta=$1 card=$2 cliv=$3 role=$4 cli=$5 model=$6 effort=$7 wt=$8
  local base=$9 head=${10} attempt=${11} rc=${12} seconds=${13} started=${14}
  local commits=${15} usage=${16} stopped=${17} timed_out=${18}
  jq -n --arg card "$card" --arg cliv "$cliv" --arg role "$role" --arg cli "$cli" \
    --arg model "$model" --arg effort "$effort" --arg wt "$wt" --arg base "$base" --arg head "$head" \
    --argjson attempt "$attempt" --argjson rc "$rc" --argjson seconds "$seconds" \
    --argjson started "$started" --argjson commits "$commits" --argjson usage "$usage" \
    --argjson stopped "$stopped" --argjson timedOut "$timed_out" \
    '{card:$card, role:$role, cli:$cli, cliVersion:$cliv, model:$model, effort:$effort, attempt:$attempt, rc:$rc,
      timedOut:($timedOut == 1), stopped:($stopped == 1), seconds:$seconds, started:$started,
      commits:$commits, worktree:$wt, base:$base, head:$head, usage:$usage}' > "$meta.tmp" && mv "$meta.tmp" "$meta"
}
