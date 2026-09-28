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
# and appended to the prompt. Do not edit files in .orka/bin while any card is running.
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
wt=$(cd "$wt" && pwd)

out="$orka/runs/$card"
mkdir -p "$out"
n=$(find "$out" -maxdepth 1 -name 'attempt-*' | wc -l)
a="$out/attempt-$((n + 1))"
mkdir -p "$a"

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
echo $$ > "$a/running"
trap 'rm -f "$a/running"' EXIT
start=$(date +%s)
ORKA_WT=$wt ORKA_MODEL=$model ORKA_EFFORT=$effort ORKA_PROMPT="$a/prompt.md" ORKA_OUT=$a \
  "$tbin" --kill-after=60 "${timeout_min}m" bash "$adapter" < /dev/null 2> "$a/err.txt"
rc=$?
end=$(date +%s)
after=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
commits=$(git -C "$wt" rev-list --count "$before..$after" 2>/dev/null || echo 0)
usage=$(cat "$a/usage.json" 2>/dev/null); [ -n "$usage" ] || usage=null
jq -n --arg card "$card" --arg cliv "$cliv" --arg role "$role" --arg cli "$cli" --arg model "$model" --arg effort "$effort" \
  --arg wt "$wt" --arg base "$before" --arg head "$after" --argjson attempt $((n + 1)) --argjson rc $rc --argjson seconds $((end - start)) \
  --argjson started "$start" --argjson commits "${commits:-0}" --argjson usage "$usage" \
  '{card:$card, role:$role, cli:$cli, cliVersion:$cliv, model:$model, effort:$effort, attempt:$attempt, rc:$rc,
    timedOut:($rc==124 or $rc==137), seconds:$seconds, started:$started, commits:$commits,
    worktree:$wt, base:$base, head:$head, usage:$usage}' > "$a/meta.json"
# The orchestrator reads reports; mask obvious secrets a worker may have echoed.
# ponytail: pattern-based, catches KEY=value / Bearer / sk- style only; not a DLP.
[ -f "$a/report.txt" ] && sed -E \
  -e 's/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Za-z0-9_]*[=:][[:space:]]*)[^[:space:]"'\'']+/\1***/g' \
  -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/=-]+/\1***/g' \
  -e 's/(sk|pk|xai)-[A-Za-z0-9_-]{12,}/\1-***/g' \
  -e 's/gh[pousr]_[A-Za-z0-9]{20,}/gh*_***/g' "$a/report.txt" > "$a/report.tmp" && mv "$a/report.tmp" "$a/report.txt"
[ -s "$a/report.txt" ] || echo "orka: worker left no report (see $a/err.txt)" >&2
echo "done $card rc=$rc $((end - start))s commits=$commits -> $a"
exit $rc
