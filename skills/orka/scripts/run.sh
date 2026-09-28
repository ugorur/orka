#!/usr/bin/env bash
# Run one task card on one worker, headless, and record the attempt.
#
#   .orka/bin/run.sh <card> <role> [worktree]                   # role from .orka/orka.json
#   .orka/bin/run.sh <card> <cli> <model> <effort> [worktree]   # explicit override
#
# <card> is .orka/tasks/<card>.md. The worktree defaults to <worktreeDir>/<card> and is created
# from the current HEAD on branch orka/<card> if missing. Output: .orka/runs/<card>/attempt-N/
# (report.txt = the worker's final message, meta.json = timing/exit code/commits/usage).
# Per-slot values (.orka/env/<slot>.env, slot = card id before the first "-") are exported
# and appended to the prompt. One worker per worktree at a time; review/QA cards pass the
# implementation's worktree. Do not edit files in .orka/bin while any card is running.
set -u
orka=$(cd "$(dirname "$0")/.." && pwd)
project=$(dirname "$orka")
conf="$orka/orka.json"
die() { echo "orka: $*" >&2; exit 2; }
[ $# -ge 2 ] || die "usage: run.sh <card> <role> [worktree] | run.sh <card> <cli> <model> <effort> [worktree]"
[ -f "$conf" ] || die "missing $conf (run the Orka bootstrap first)"
card=$1
task="$orka/tasks/$card.md"
[ -f "$task" ] || die "missing card $task"

if jq -e --arg r "$2" '.team[$r]' "$conf" >/dev/null 2>&1; then
  role=$2
  cli=$(jq -r --arg r "$role" '.team[$r].cli' "$conf")
  model=$(jq -r --arg r "$role" '.team[$r].model // ""' "$conf")
  effort=$(jq -r --arg r "$role" '.team[$r].effort // ""' "$conf")
  wt=${3:-}
else
  [ $# -ge 4 ] || die "'$2' is not a role in orka.json; explicit form needs <cli> <model> <effort>"
  role=custom cli=$2 model=$3 effort=$4 wt=${5:-}
fi
adapter="$orka/bin/workers/$cli.sh"
[ -x "$adapter" ] || die "no worker adapter $adapter"

if [ -z "$wt" ]; then
  wtdir=$(jq -r '.worktreeDir // empty' "$conf")
  [ -n "$wtdir" ] || wtdir="../$(basename "$project")-wt"
  case $wtdir in /*) ;; *) wtdir="$project/$wtdir" ;; esac
  wt="$wtdir/$card"
fi
if [ ! -d "$wt" ]; then
  mkdir -p "$(dirname "$wt")"
  git -C "$project" worktree add -q -b "orka/$card" "$wt" HEAD || die "could not create worktree $wt"
fi
# Workers run unrestricted: only ever at the root of a linked (non-main) worktree of this repository.
real() { (cd "$1" 2>/dev/null && pwd -P); }
wt=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) && wt=$(real "$wt") || die "$wt is not inside a git worktree"
gitdir() { real "$(git -C "$1" rev-parse --path-format=absolute "$2" 2>/dev/null)"; }
[ "$(gitdir "$wt" --git-common-dir)" = "$(gitdir "$project" --git-common-dir)" ] || die "$wt is not a worktree of $project"
[ "$(gitdir "$wt" --git-dir)" != "$(gitdir "$wt" --git-common-dir)" ] || die "refusing to run a worker in the main checkout ($wt)"

# One worker per worktree at a time. The lock is a symlink whose target is the owner's pid:
# creating it is atomic and publishes the owner in the same step; only the owner removes it.
# ponytail: two runners reclaiming the same dead lock at the same instant can still race; rare
# (needs a crashed runner plus two simultaneous restarts), fix with a reclaim lock if it ever bites.
lock="$orka/runs/.locks/$(printf '%s' "$wt" | tr '/ ' '__')"
mkdir -p "$orka/runs/.locks"
if ! ln -s "$$" "$lock" 2>/dev/null; then
  owner=$(readlink "$lock" 2>/dev/null)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then die "a worker (pid $owner) is already running in $wt"; fi
  rm -f "$lock"; ln -s "$$" "$lock" 2>/dev/null || die "could not lock $wt"
fi
a=
trap '[ "$(readlink "$lock" 2>/dev/null)" = $$ ] && rm -f "$lock"; [ -n "$a" ] && rm -f "$a/running"' EXIT

out="$orka/runs/$card"
mkdir -p "$out"
n=$(ls "$out" | sed -n 's/^attempt-\([0-9]*\)$/\1/p' | sort -n | tail -1)
n=$((${n:-0} + 1))
until mkdir "$out/attempt-$n" 2>/dev/null; do n=$((n + 1)); done
a="$out/attempt-$n"
start=$(date +%s)
echo "$$ $start" > "$a/running"

slot=${card%%-*}
envf="$orka/env/$slot.env"
# shellcheck disable=SC1090
if [ -f "$envf" ]; then set -a; . "$envf"; set +a; fi
{
  printf 'ORKA_WORKER — you are a worker on an Orka team. Do this card; do not orchestrate.\n\n'
  [ -f "$orka/COMMON.md" ] && { cat "$orka/COMMON.md"; echo; }
  cat "$task"
  printf '\n## Run facts (literal values; your tool shell may not inherit variables)\n'
  printf -- '- Card: `%s` · slot: `%s` · worktree: `%s` · branch: `%s`\n' "$card" "$slot" "$wt" "$(git -C "$wt" branch --show-current)"
  printf -- '- Orka home: `%s` (sub-cards, runner and templates live here)\n' "$orka"
  [ -f "$envf" ] && sed 's/^/- /' "$envf"
} > "$a/prompt.md"

timeout_min=$(jq -r '.timeoutMinutes // 120' "$conf")
tbin=$(command -v timeout || command -v gtimeout) || die "'timeout' is required (macOS: brew install coreutils)"
cliv=$(command -v "$cli" >/dev/null && "$cli" --version 2>/dev/null < /dev/null | head -1)
before=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
# timeout runs the worker in its own process group and passes signals on to the whole group,
# so stopping this runner (TERM/INT/HUP) stops the worker too, and we still write meta.json.
ORKA_WT=$wt ORKA_MODEL=$model ORKA_EFFORT=$effort ORKA_PROMPT="$a/prompt.md" ORKA_OUT=$a \
  "$tbin" --kill-after=60 "${timeout_min}m" bash "$adapter" < /dev/null 2> "$a/err.txt" &
wpid=$!
stopped=0
trap 'kill -TERM $wpid 2>/dev/null; stopped=1' TERM INT HUP
# A signal interrupts `wait`; keep waiting until the worker group is really gone.
while :; do wait $wpid; rc=$?; kill -0 $wpid 2>/dev/null || break; done
[ $stopped = 1 ] && [ $rc -eq 0 ] && rc=143   # a cancelled run never counts as success
end=$(date +%s)
after=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
commits=$(git -C "$wt" rev-list --count "$before..$after" 2>/dev/null || echo 0)
usage=null
jq -se 'length == 1 and (.[0] | type == "object")' "$a/usage.json" >/dev/null 2>&1 && usage=$(jq -c '.' "$a/usage.json")
jq -n --arg card "$card" --arg cliv "$cliv" --arg role "$role" --arg cli "$cli" --arg model "$model" --arg effort "$effort" \
  --arg wt "$wt" --arg base "$before" --arg head "$after" --argjson attempt "$n" --argjson rc "$rc" --argjson seconds $((end - start)) \
  --argjson started "$start" --argjson commits "${commits:-0}" --argjson usage "$usage" --argjson stopped "$stopped" \
  '{card:$card, role:$role, cli:$cli, cliVersion:$cliv, model:$model, effort:$effort, attempt:$attempt, rc:$rc,
    timedOut:($stopped == 0 and ($rc == 124 or $rc == 137)), stopped:($stopped == 1), seconds:$seconds, started:$started,
    commits:$commits, worktree:$wt, base:$base, head:$head, usage:$usage}' > "$a/meta.tmp" && mv "$a/meta.tmp" "$a/meta.json" \
  || { echo "orka: could not write $a/meta.json" >&2; [ "$rc" -eq 0 ] && rc=70; }
# The orchestrator reads reports; mask obvious secrets a worker may have echoed.
# ponytail: pattern-based, catches KEY=value / Bearer / sk- style only; not a DLP.
[ -f "$a/report.txt" ] && sed -E \
  -e 's/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Za-z0-9_]*[=:][[:space:]]*)"[^"]*"/\1"***"/g' \
  -e "s/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Za-z0-9_]*[=:][[:space:]]*)'[^']*'/\\1'***'/g" \
  -e 's/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Za-z0-9_]*[=:][[:space:]]*)[^[:space:]"'\'']+/\1***/g' \
  -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1***/g' \
  -e 's/(sk|pk|xai)-[A-Za-z0-9_-]{12,}/\1-***/g' \
  -e 's/gh[pousr]_[A-Za-z0-9]{20,}/gh*_***/g' "$a/report.txt" > "$a/report.tmp" && mv "$a/report.tmp" "$a/report.txt"
[ -s "$a/report.txt" ] || echo "orka: worker left no report (see $a/err.txt)" >&2
echo "done $card rc=$rc $((end - start))s commits=$commits -> $a"
exit "$rc"
