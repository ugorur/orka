#!/usr/bin/env bash
# One line per card: state of its latest attempt. `status.sh` or `status.sh <card>`.
set -u
orka=$(cd "$(dirname "$0")/.." && pwd)

role_history() {
  local wanted=$1 meta
  for meta in "$orka"/runs/*/attempt-*/meta.json; do
    [ -f "$meta" ] || continue
    jq -er --arg role "$wanted" \
      'select(.role == $role and .rc == 0 and .stopped == false and .timedOut == false and
              (.seconds | type == "number")) | (.seconds | floor)' "$meta" 2>/dev/null
  done | sort -n | awk '
    { value[NR] = $1 }
    END {
      count = NR
      if (count == 0) { print "0 0"; exit }
      if (count % 2) median = value[(count + 1) / 2]
      else median = int((value[count / 2] + value[count / 2 + 1]) / 2)
      print count, median
    }'
}

slow_note() {
  local role=$1 elapsed=$2 history count median minutes
  [ -n "$role" ] || return
  history=$(role_history "$role")
  read -r count median <<EOF
$history
EOF
  [ "${count:-0}" -ge 3 ] || return
  [ "$elapsed" -gt $((2 * median)) ] || return
  minutes=$(awk -v seconds="$median" 'BEGIN {
    value = seconds / 60
    if (value == int(value)) printf "%d", value
    else printf "%.1f", value
  }')
  printf ' SLOW (>2x %s median %sm)' "$role" "$minutes"
}

printf '%-28s %-9s %3s %4s %6s %4s  %s\n' CARD STATE TRY RC MIN GIT WORKER
for task in "$orka"/tasks/${1:-*}.md; do
  [ -f "$task" ] || continue
  card=$(basename "$task" .md)
  n=$(ls "$orka/runs/$card" 2>/dev/null | sed -n 's/^attempt-//p' | sort -n | tail -1)
  a=${n:+$orka/runs/$card/attempt-$n}
  if [ -z "$a" ]; then printf '%-28s %-9s\n' "$card" todo; continue; fi
  if [ -f "$a/pending" ]; then
    since=$(jq -r '.started // empty' "$a/pending" 2>/dev/null)
    model=$(jq -r '.model // empty' "$a/pending" 2>/dev/null)
    role=$(jq -r '.role // empty' "$a/pending" 2>/dev/null)
    case $since in ''|*[!0-9]*) since=$(date +%s) ;; esac
    elapsed=$(($(date +%s) - since))
    note=$(slow_note "$role" "$elapsed")
    printf '%-28s %-9s %3s %4s %6s %4s  %s%s\n' "$card" running "${a##*-}" - $((elapsed / 60)) - "subagent/$model" "$note"
    continue
  fi
  pid='' since='' role=''
  [ -f "$a/running" ] && read -r pid since role < "$a/running"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    case $since in ''|*[!0-9]*) since=$(date +%s) ;; esac
    elapsed=$(($(date +%s) - since))
    note=$(slow_note "$role" "$elapsed")
    printf '%-28s %-9s %3s %4s %6s %4s  %s%s\n' "$card" running "${a##*-}" - $((elapsed / 60)) - "$role" "$note"
    continue
  fi
  [ -f "$a/meta.json" ] || { printf '%-28s %-9s %3s\n' "$card" crashed "${a##*-}"; continue; }
  jq -r '[.card, (if .timedOut then "timeout" elif .stopped then "stopped" elif .rc == 0 then "done" else "failed" end),
          .attempt, .rc, (.seconds / 60 | floor), .commits, "\(.cli)/\(.model)/\(.effort)"] |
         "\(.[0]|.[0:28]) \(.[1]) \(.[2]) \(.[3]) \(.[4]) \(.[5]) \(.[6])"' "$a/meta.json" |
    while read -r c s t r m g w; do printf '%-28s %-9s %3s %4s %6s %4s  %s\n' "$c" "$s" "$t" "$r" "$m" "$g" "$w"; done
done
