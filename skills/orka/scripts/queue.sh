#!/usr/bin/env bash
# Run several cards, keeping at most `parallel` (orka.json) workers alive at once.
#   .orka/bin/queue.sh "<card> <role> [worktree]" "<card> <cli> <model> <effort> [worktree]" ...
# Each quoted job is passed to run.sh as-is (no spaces inside paths). Counts every running
# Orka worker, including ones started outside this queue.
set -u
orka=$(cd "$(dirname "$0")/.." && pwd)
max=${ORKA_PARALLEL:-$(jq -r '.parallel // 2' "$orka/orka.json")}
running() {
  local c=0 f
  for f in "$orka"/runs/*/attempt-*/running; do
    [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null && c=$((c + 1))
  done
  echo $c
}
for job in "$@"; do
  read -ra argv <<< "$job"
  while [ "$(running)" -ge "$max" ]; do sleep 20; done
  echo "$(date +%T) start ${argv[0]}"
  "$orka/bin/run.sh" "${argv[@]}" 2>&1 | tail -1 &
  sleep 5 # let run.sh claim its slot before counting again
done
wait
echo "$(date +%T) queue done"
