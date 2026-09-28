#!/usr/bin/env bash
# Append one score line to .orka/ledger.jsonl, or summarise the ledger.
#   score.sh <card> predicted <smart> <dumb> <speed> <cost> "<why this worker>"
#   score.sh <card> actual    <smart> <dumb> <speed> <cost> "<what happened>"
#   score.sh <scope> retro    <smart> <dumb> <speed> <cost> "<lesson>" <reviewer>
#   score.sh --summary        # average actual scores per worker, best smart first
# Scores are 0-100. smart: cleared the hard part. dumb: worst silly mistake (0 = none).
# speed / cost: higher = faster / cheaper. "actual" lines copy worker, time and usage from
# the card's latest attempt; "retro" lines score the orchestrator itself.
set -u
orka=$(cd "$(dirname "$0")/.." && pwd)
ledger="$orka/ledger.jsonl"
if [ "${1:-}" = --summary ]; then
  [ -s "$ledger" ] || { echo "ledger is empty"; exit 0; }
  jq -rs '[.[] | select(.kind == "actual")] | group_by(.worker) | map({
      worker: .[0].worker, runs: length,
      smart: (map(.smart) | add / length | floor), dumb: (map(.dumb) | add / length | floor),
      speed: (map(.speed) | add / length | floor), cost: (map(.cost) | add / length | floor),
      minutes: (map(.seconds // 0) | add / length / 60 | floor)})
    | sort_by(-.smart) | (["WORKER","RUNS","SMART","DUMB","SPEED","COST","AVG_MIN"] | @tsv),
      (.[] | [.worker, .runs, .smart, .dumb, .speed, .cost, .minutes] | @tsv)' "$ledger" | column -t
  exit 0
fi
[ $# -ge 7 ] || { sed -n '2,10p' "$0" >&2; exit 2; }
card=$1 kind=$2 note=$7 by=${8:-orchestrator}
for v in "$3" "$4" "$5" "$6"; do
  [[ $v =~ ^[0-9]+$ ]] && [ "$v" -le 100 ] || { echo "orka: scores must be 0-100, got '$v'" >&2; exit 2; }
done
case $kind in predicted|actual|retro) ;; *) echo "orka: kind must be predicted|actual|retro" >&2; exit 2 ;; esac
meta=null
if [ "$kind" = actual ]; then
  n=$(ls "$orka/runs/$card" 2>/dev/null | sed -n 's/^attempt-//p' | sort -n | tail -1)
  a=${n:+$orka/runs/$card/attempt-$n}
  [ -n "$a" ] && [ -f "$a/meta.json" ] && meta=$(cat "$a/meta.json")
fi
jq -nc --arg card "$card" --arg kind "$kind" --arg note "$note" --arg by "$by" \
  --argjson s "$3" --argjson d "$4" --argjson sp "$5" --argjson c "$6" --argjson m "$meta" \
  '{ts: (now | todate), card: $card, kind: $kind, smart: $s, dumb: $d, speed: $sp, cost: $c, note: $note, by: $by}
   + (if $m == null then {} else {worker: "\($m.cli)/\($m.model)/\($m.effort)", attempts: $m.attempt,
      seconds: $m.seconds, usage: $m.usage} end)' >> "$ledger"
tail -1 "$ledger"
