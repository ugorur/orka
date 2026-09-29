#!/usr/bin/env bash
# Finish a prepared native sub-agent attempt.
#   .orka/bin/finish.sh <card> [exit-code]
#   .orka/bin/finish.sh <card> --abandon
set -u
orka=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=/dev/null
. "$orka/bin/lib.sh"
die() { echo "orka: $*" >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || die "usage: finish.sh <card> [exit-code] | finish.sh <card> --abandon"
card=$1
arg=${2:-0}
abandon=0
if [ "$arg" = --abandon ]; then
  abandon=1
  rc=130
else
  case $arg in ''|*[!0-9]*) die "exit code must be an integer from 0 to 255" ;; esac
  [ "$arg" -le 255 ] || die "exit code must be an integer from 0 to 255"
  rc=$arg
fi

a=
count=0
for pending in "$orka/runs/$card"/attempt-*/pending; do
  [ -f "$pending" ] || continue
  a=${pending%/pending}
  count=$((count + 1))
done
[ "$count" -gt 0 ] || die "no open subagent attempt for $card"
[ "$count" -eq 1 ] || die "more than one open subagent attempt for $card; inspect $orka/runs/$card"
[ "$abandon" -eq 1 ] || [ -f "$a/report.txt" ] || die "missing $a/report.txt; save the sub-agent's final message there, or use --abandon"

pending="$a/pending"
jq -e '.cli == "subagent" and (.started | type == "number") and (.base | type == "string") and
       (.worktree | type == "string") and (.role | type == "string") and (.model | type == "string") and
       (.effort | type == "string")' "$pending" >/dev/null 2>&1 || die "invalid pending state in $pending"
started=$(jq -r '.started' "$pending")
base=$(jq -r '.base' "$pending")
wt=$(jq -r '.worktree' "$pending")
role=$(jq -r '.role' "$pending")
model=$(jq -r '.model' "$pending")
effort=$(jq -r '.effort' "$pending")
attempt=${a##*-}
end=$(date +%s)
seconds=$((end - started))
[ "$seconds" -ge 0 ] || seconds=0
head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || die "cannot read the worktree recorded in $pending"
commits=$(git -C "$wt" rev-list --count "$base..$head" 2>/dev/null) || die "cannot count commits from the prepared base in $wt"

orka_mask_report "$a/report.txt" || die "could not mask $a/report.txt"
orka_write_meta "$a/meta.json" "$card" "" "$role" subagent "$model" "$effort" "$wt" \
  "$base" "$head" "$attempt" "$rc" "$seconds" "$started" "${commits:-0}" null "$abandon" 0 \
  || die "could not write $a/meta.json"
rm -f "$pending"
echo "done $card rc=$rc ${seconds}s commits=$commits -> $a"
exit 0
