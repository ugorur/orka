#!/usr/bin/env bash
# Set up (or update) Orka in a git project:  bash <skill>/scripts/init.sh [project-dir]
# Creates .orka/ (git-excluded, never committed), copies the runner scripts into .orka/bin so a
# running queue is never affected by skill updates, and reports which worker CLIs are installed.
# Safe to re-run; it never overwrites orka.json, COMMON.md, the ledger or your cards.
set -u
skill=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "orka: $*" >&2; exit 2; }
for bin in git jq; do command -v $bin >/dev/null || die "'$bin' is required"; done
command -v timeout >/dev/null || command -v gtimeout >/dev/null || die "'timeout' is required (macOS: brew install coreutils)"
project=$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null) || die "not a git repository (run 'git init' first; workers need worktrees)"
orka="$project/.orka"

for f in "$orka"/runs/*/attempt-*/running; do
  [ -f "$f" ] && read -r pid _ < "$f" && kill -0 "$pid" 2>/dev/null && die "a worker is running ($f); update .orka/bin after it finishes"
done

mkdir -p "$orka"/{bin/workers,tasks,runs,env,templates}
cp "$skill"/scripts/{orka,run.sh,queue.sh,status.sh,score.sh} "$orka/bin/"
cp "$skill"/scripts/workers/*.sh "$orka/bin/workers/"   # custom adapters you added are kept
cp "$skill"/templates/* "$orka/templates/"
chmod +x "$orka"/bin/orka "$orka"/bin/*.sh "$orka"/bin/workers/*.sh
[ -f "$orka/COMMON.md" ] || cp "$skill/templates/COMMON.md" "$orka/COMMON.md"
[ -f "$orka/decisions.md" ] || printf '# Decisions\n\nOne line per decision: date · decision · who decided · why.\n\n' > "$orka/decisions.md"
[ -f "$orka/backlog.md" ] || printf '# Backlog\n\nWhat the user asked for, in their words. Nothing here runs until the user says go.\n\n' > "$orka/backlog.md"
touch "$orka/ledger.jsonl"

exclude="$(git -C "$project" rev-parse --git-common-dir)/info/exclude"
case $exclude in /*) ;; *) exclude="$project/$exclude" ;; esac
mkdir -p "$(dirname "$exclude")"
grep -qx '/.orka/' "$exclude" 2>/dev/null || echo '/.orka/' >> "$exclude"

echo "Orka home: $orka"
echo "Worker CLIs:"
for a in "$orka"/bin/workers/*.sh; do
  cli=$(basename "$a" .sh)
  if command -v "$cli" >/dev/null; then echo "  $cli: installed"
  else echo "  $cli: not installed"; fi
done
if [ -f "$orka/orka.json" ]; then echo "Team (.orka/orka.json):"; jq -r '.team | to_entries[] | "  \(.key): \(.value.cli) \(.value.model // "") \(.value.effort // "")"' "$orka/orka.json"
else echo "No .orka/orka.json yet: propose a team to the user, then write it (example: .orka/templates/orka.example.json)."; fi
