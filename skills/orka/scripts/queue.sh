#!/usr/bin/env bash
# Run several cards, keeping at most `parallel` (orka.json) workers alive at once.
#   .orka/bin/queue.sh "<card> <role> [worktree]" "<card> <cli> <model> <effort> [worktree]" ...
# Each quoted job is passed to run.sh as-is (no spaces inside paths). Counts every running
# Orka worker, including ones started by other queues or by hand. Exits non-zero if any job failed.
set -u
orka=$(cd "$(dirname "$0")/.." && pwd)
[ $# -gt 0 ] || { sed -n '2,5p' "$0" >&2; exit 2; }
max=${ORKA_PARALLEL:-$(jq -r '.parallel // 2' "$orka/orka.json")}
lock="$orka/runs/.locks/queue"
mkdir -p "$orka/runs/.locks"
running() {
  local c=0 f pid
  for f in "$orka"/runs/*/attempt-*/running; do
    [ -f "$f" ] || continue
    read -r pid _ < "$f"
    kill -0 "$pid" 2>/dev/null && c=$((c + 1))
  done
  echo $c
}
# Only one queue at a time may count free slots and launch (mkdir is atomic).
take_lock() {
  local owner
  until mkdir "$lock" 2>/dev/null; do
    owner=$(cat "$lock/pid" 2>/dev/null)
    [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null && rm -rf "$lock"
    sleep 2
  done
  echo $$ > "$lock/pid"
}
trap '[ "$(cat "$lock/pid" 2>/dev/null)" = $$ ] && rm -rf "$lock"' EXIT
pids=()
for job in "$@"; do
  read -ra argv <<< "$job"
  take_lock
  while [ "$(running)" -ge "$max" ]; do sleep 10; done
  echo "$(date +%T) start ${argv[0]}"
  "$orka/bin/run.sh" "${argv[@]}" &
  p=$!
  pids+=("$p")
  # Keep the lock until this run has claimed its slot (or already exited).
  while kill -0 "$p" 2>/dev/null && ! grep -qs "^$p " "$orka"/runs/*/attempt-*/running; do sleep 1; done
  rm -rf "$lock"
done
failed=0
for p in "${pids[@]}"; do wait "$p" || failed=$((failed + 1)); done
echo "$(date +%T) queue done ($failed failed)"
[ "$failed" -eq 0 ]
