#!/usr/bin/env bash
# One line per card: state of its latest attempt. `status.sh` or `status.sh <card>`.
set -u
orka=$(cd "$(dirname "$0")/.." && pwd)
printf '%-28s %-9s %3s %4s %6s %4s  %s\n' CARD STATE TRY RC MIN GIT WORKER
for task in "$orka"/tasks/${1:-*}.md; do
  [ -f "$task" ] || continue
  card=$(basename "$task" .md)
  n=$(ls "$orka/runs/$card" 2>/dev/null | sed -n 's/^attempt-//p' | sort -n | tail -1)
  a=${n:+$orka/runs/$card/attempt-$n}
  if [ -z "$a" ]; then printf '%-28s %-9s\n' "$card" todo; continue; fi
  if [ -f "$a/running" ] && kill -0 "$(cat "$a/running")" 2>/dev/null; then
    printf '%-28s %-9s %3s %4s %6s %4s\n' "$card" running "${a##*-}" - $(( ($(date +%s) - $(date -r "$a/running" +%s)) / 60 )) -
    continue
  fi
  [ -f "$a/meta.json" ] || { printf '%-28s %-9s %3s\n' "$card" crashed "${a##*-}"; continue; }
  jq -r '[.card, (if .timedOut then "timeout" elif .rc == 0 then "done" else "failed" end),
          .attempt, .rc, (.seconds / 60 | floor), .commits, "\(.cli)/\(.model)/\(.effort)"] |
         "\(.[0]|.[0:28]) \(.[1]) \(.[2]) \(.[3]) \(.[4]) \(.[5]) \(.[6])"' "$a/meta.json" |
    while read -r c s t r m g w; do printf '%-28s %-9s %3s %4s %6s %4s  %s\n' "$c" "$s" "$t" "$r" "$m" "$g" "$w"; done
done
