#!/usr/bin/env bash
# Run one task card on a headless CLI, or prepare it for a native sub-agent, and record the attempt.
#
#   .orka/bin/run.sh <card> <role> [worktree]                   # role from .orka/orka.json
#   .orka/bin/run.sh <card> <cli> <model> <effort> [worktree]   # explicit override
#
# <card> is .orka/tasks/<card>.md. The worktree defaults to <worktreeDir>/<card> and is created
# from the current HEAD on branch orka/<card> if missing. Output: .orka/runs/<card>/attempt-N/
# (report.txt = the worker's final message, meta.json = exit code/seconds/commits/usage). Native
# sub-agents leave pending after preparation; finish.sh writes their meta.json.
# Per-slot values (.orka/env/<slot>.env, slot = card id before the first "-") are exported
# and appended to the prompt. One worker per worktree at a time; review/QA cards pass the
# implementation's worktree. Do not edit files in .orka/bin while any card is running.
set -u
orka=$(cd "$(dirname "$0")/.." && pwd)
project=$(dirname "$orka")
conf="$orka/orka.json"
# shellcheck source=/dev/null
. "$orka/bin/lib.sh"
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
[ "$cli" = subagent ] || [ -x "$adapter" ] || die "no worker adapter $adapter"

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
# A lock whose owner died (runner killed with -9) is never taken over automatically: two runners
# reclaiming it at once could both win. Fail closed and let the orchestrator remove it.
lock="$orka/runs/.locks/$(printf '%s' "$wt" | tr '/ ' '__')"
mkdir -p "$orka/runs/.locks"
tries=0
until ln -s "$$" "$lock" 2>/dev/null; do
  tries=$((tries + 1)); [ $tries -le 20 ] || die "could not lock $wt ($lock)"
  owner=$(readlink "$lock" 2>/dev/null) || continue   # released meanwhile: try again
  kill -0 "$owner" 2>/dev/null && die "a worker (pid $owner) is already running in $wt"
  die "stale lock: pid $owner is gone. Check that no worker is still running in $wt, then: rm $lock"
done
a=
card_lock=
cleanup() {
  [ "$(readlink "$lock" 2>/dev/null)" = "$$" ] && rm -f "$lock"
  [ -n "$a" ] && rm -f "$a/running"
  if [ -n "$card_lock" ] && [ -n "$a" ] &&
     [ "$(readlink "$card_lock" 2>/dev/null)" = "$a/pending" ] && [ ! -f "$a/pending" ]; then
    rm -f "$card_lock"
  fi
}
trap cleanup EXIT

# Native sub-agents outlive this runner. Check pending state only while holding the worktree
# lock, so no worker can slip in between this scan and attempt allocation.
for pending in "$orka"/runs/*/attempt-*/pending; do
  [ -f "$pending" ] || continue
  pending_wt=$(jq -er '.worktree | strings | select(length > 0)' "$pending" 2>/dev/null) \
    || die "invalid pending state in $pending"
  if [ "$pending_wt" = "$wt" ]; then
    pending_card=$(jq -r '.card // "unknown"' "$pending")
    die "subagent card $pending_card is still pending in $wt; finish or abandon it first"
  fi
done

out="$orka/runs/$card"
mkdir -p "$out"
n=$(ls "$out" | sed -n 's/^attempt-\([0-9]*\)$/\1/p' | sort -n | tail -1)
n=$((${n:-0} + 1))
until mkdir "$out/attempt-$n" 2>/dev/null; do n=$((n + 1)); done
a="$out/attempt-$n"

# A native sub-agent may be prepared in a caller-supplied worktree, so the worktree lock alone
# cannot prevent two open attempts for one card. This persistent marker is claimed atomically and
# is released only by finish/--abandon (or cleanup if preparation fails before pending is written).
if [ "$cli" = subagent ]; then
  card_lock="$orka/runs/.locks/card-$card"
  if ! ln -s "$a/pending" "$card_lock" 2>/dev/null; then
    rmdir "$a" 2>/dev/null || true
    a=
    die "subagent card $card already has an open attempt; finish or abandon it first"
  fi
fi

start=$(date +%s)
echo "$$ $start" > "$a/running"

slot=${card%%-*}
envf="$orka/env/$slot.env"
# shellcheck disable=SC1090
if [ -f "$envf" ]; then set -a; . "$envf"; set +a; fi
{
  printf 'ORKA_WORKER — you are a worker on an Orka team. Do this card; do not orchestrate.\n'
  if [ "$cli" = subagent ]; then
    printf 'Your working directory is `%s` — `cd` there in every shell command or use absolute paths; work and commit only there.\n\n' "$wt"
  else
    printf '\n'
  fi
  [ -f "$orka/COMMON.md" ] && { cat "$orka/COMMON.md"; echo; }
  cat "$task"
  printf '\n## Run facts (literal values; your tool shell may not inherit variables)\n'
  printf -- '- Card: `%s` · slot: `%s` · worktree: `%s` · branch: `%s`\n' "$card" "$slot" "$wt" "$(git -C "$wt" branch --show-current)"
  printf -- '- Orka home: `%s` (sub-cards, runner and templates live here)\n' "$orka"
  [ -f "$envf" ] && sed 's/^/- /' "$envf"
} > "$a/prompt.md"

before=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
if [ "$cli" = subagent ]; then
  jq -n --arg card "$card" --arg role "$role" --arg cli "$cli" --arg model "$model" --arg effort "$effort" \
    --arg wt "$wt" --arg base "$before" --argjson started "$start" \
    '{card:$card, role:$role, cli:$cli, model:$model, effort:$effort, worktree:$wt, base:$base, started:$started}' \
    > "$a/pending.tmp" && mv "$a/pending.tmp" "$a/pending" || die "could not write $a/pending"
  printf 'subagent %s attempt %s\n' "$card" "$n"
  printf '  model:    %s\n' "$model"
  printf '  worktree: %s      (the sub-agent must work only here)\n' "$wt"
  printf '  prompt:   %s\n' "$a/prompt.md"
  printf '  report:   %s   (save the sub-agent'"'"'s final message here)\n' "$a/report.txt"
  printf '  then:     .orka/bin/orka finish %s [exit-code]\n' "$card"
  exit 0
fi

timeout_min=$(jq -r '.timeoutMinutes // 120' "$conf")
tbin=$(command -v timeout || command -v gtimeout) || die "'timeout' is required (macOS: brew install coreutils)"
cliv=$(command -v "$cli" >/dev/null && "$cli" --version 2>/dev/null < /dev/null | head -1)
# Workers must not inherit the orchestrator's own agent session (a Claude Code orchestrator exports
# its session id and messaging socket/token to child processes), and empty auth variables would
# override a worker CLI's own login.
unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH \
  CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_SESSION_ATTENDED CLAUDE_PID CLAUDE_EFFORT
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL OPENAI_API_KEY XAI_API_KEY; do
  [ -z "${!v:-}" ] && unset "$v"
done
# timeout runs the worker in its own process group and passes signals on to the whole group,
# so stopping this runner (TERM/INT/HUP) stops the worker too, and we still write meta.json.
ORKA_WT=$wt ORKA_MODEL=$model ORKA_EFFORT=$effort ORKA_PROMPT="$a/prompt.md" ORKA_OUT=$a \
  "$tbin" --kill-after=60 "${timeout_min}m" bash "$adapter" < /dev/null 2> "$a/err.txt" &
wpid=$!
stopped=0
trap 'kill -TERM $wpid 2>/dev/null; stopped=1' TERM INT HUP
# A signal interrupts `wait`; keep waiting until the worker group is really gone.
while :; do wait $wpid; rc=$?; kill -0 $wpid 2>/dev/null || break; done
# Whatever is left in the worker's process group (children that ignored TERM) goes too,
# before the lock and running marker are released.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 -- -"$wpid" 2>/dev/null || break
  kill -TERM -- -"$wpid" 2>/dev/null; sleep 1
done
kill -KILL -- -"$wpid" 2>/dev/null
[ $stopped = 1 ] && [ $rc -eq 0 ] && rc=143   # a cancelled run never counts as success
end=$(date +%s)
after=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
commits=$(git -C "$wt" rev-list --count "$before..$after" 2>/dev/null || echo 0)
usage=null
jq -se 'length == 1 and (.[0] | type == "object")' "$a/usage.json" >/dev/null 2>&1 && usage=$(jq -c '.' "$a/usage.json")
timed_out=0
[ "$stopped" -eq 0 ] && { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; } && timed_out=1
orka_write_meta "$a/meta.json" "$card" "$cliv" "$role" "$cli" "$model" "$effort" "$wt" \
  "$before" "$after" "$n" "$rc" "$((end - start))" "$start" "${commits:-0}" "$usage" "$stopped" "$timed_out" \
  || { echo "orka: could not write $a/meta.json" >&2; [ "$rc" -eq 0 ] && rc=70; }
# The orchestrator reads reports; mask obvious secrets a worker may have echoed.
# ponytail: pattern-based, catches KEY=value / Bearer / sk- style only; not a DLP.
[ -f "$a/report.txt" ] && orka_mask_report "$a/report.txt"
[ -s "$a/report.txt" ] || echo "orka: worker left no report (see $a/err.txt)" >&2
echo "done $card rc=$rc $((end - start))s commits=$commits -> $a"
exit "$rc"
