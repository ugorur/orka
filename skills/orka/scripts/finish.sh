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

pending="$a/pending"
state=$(jq -ce 'select(.cli == "subagent" and (.started | type == "number") and
       (.base | type == "string") and (.worktree | type == "string") and (.role | type == "string") and
       (.model | type == "string") and (.effort | type == "string"))' "$pending" 2>/dev/null) || {
  [ -f "$pending" ] && die "invalid pending state in $pending"
  die "subagent attempt for $card was already finished or abandoned"
}
started=$(printf '%s\n' "$state" | jq -r '.started')
base=$(printf '%s\n' "$state" | jq -r '.base')
wt=$(printf '%s\n' "$state" | jq -r '.worktree')
role=$(printf '%s\n' "$state" | jq -r '.role')
model=$(printf '%s\n' "$state" | jq -r '.model')
effort=$(printf '%s\n' "$state" | jq -r '.effort')

# Finalization shares the worktree lock with run.sh. Read the recorded path first, acquire its
# lock, then re-check pending: another finisher may have closed this attempt while we waited.
lock="$orka/runs/.locks/$(printf '%s' "$wt" | tr '/ ' '__')"
mkdir -p "$orka/runs/.locks"
tries=0
until ln -s "$$" "$lock" 2>/dev/null; do
  tries=$((tries + 1)); [ "$tries" -le 20 ] || die "could not lock $wt ($lock)"
  owner=$(readlink "$lock" 2>/dev/null) || continue
  kill -0 "$owner" 2>/dev/null && die "a worker (pid $owner) is already running in $wt"
  die "stale lock: pid $owner is gone. Check that no worker is still running in $wt, then: rm $lock"
done
cleanup() { [ "$(readlink "$lock" 2>/dev/null)" = "$$" ] && rm -f "$lock"; }
trap cleanup EXIT
[ -f "$pending" ] || die "subagent attempt for $card was already finished or abandoned"
[ "$abandon" -eq 1 ] || [ -f "$a/report.txt" ] || die "missing $a/report.txt; save the sub-agent's final message there, or use --abandon"

attempt=${a##*-}
end=$(date +%s)
seconds=$((end - started))
[ "$seconds" -ge 0 ] || seconds=0
worktree_missing=0
if head=$(git -C "$wt" rev-parse HEAD 2>/dev/null); then
  commits=$(git -C "$wt" rev-list --count "$base..$head" 2>/dev/null) \
    || die "cannot count commits from the prepared base in $wt"
elif [ "$abandon" -eq 1 ]; then
  head=$base
  commits=0
  worktree_missing=1
else
  die "cannot read the worktree recorded in $pending"
fi

orka_mask_report "$a/report.txt" || die "could not mask $a/report.txt"
orka_write_meta "$a/meta.json" "$card" "" "$role" subagent "$model" "$effort" "$wt" \
  "$base" "$head" "$attempt" "$rc" "$seconds" "$started" "${commits:-0}" null "$abandon" 0 \
  || die "could not write $a/meta.json"
[ "$worktree_missing" -eq 0 ] || {
  jq '. + {worktreeMissing:true}' "$a/meta.json" > "$a/meta.json.tmp" && mv "$a/meta.json.tmp" "$a/meta.json" \
    || die "could not record missing worktree in $a/meta.json"
}
rm -f "$pending"
card_lock="$orka/runs/.locks/card-$card"
[ "$(readlink "$card_lock" 2>/dev/null)" = "$a/pending" ] && rm -f "$card_lock"
echo "done $card rc=$rc ${seconds}s commits=$commits -> $a"
exit 0
