#!/usr/bin/env bash
# Set up (or update) Orka in a git project:  bash <skill>/scripts/init.sh [project-dir]
# Creates .orka/ (git-excluded, never committed), copies the runner scripts into .orka/bin so a
# running queue is never affected by skill updates, and reports which worker CLIs are installed.
# Run it at the start of every session: it refreshes .orka/bin and .orka/templates from the skill.
# It never overwrites orka.json, COMMON.md (the project section), the ledger or your cards.
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
for f in "$orka"/runs/*/attempt-*/pending; do
  [ -f "$f" ] && die "a subagent attempt is pending ($f); finish or abandon it before updating .orka/bin"
done

mkdir -p "$orka"/{bin/workers,tasks,runs,env,templates}
cp "$skill"/scripts/{orka,run.sh,finish.sh,queue.sh,status.sh,score.sh,lib.sh,rules.md} "$orka/bin/"
cp "$skill"/scripts/workers/*.sh "$orka/bin/workers/"   # custom adapters you added are kept
# Templates: the project may have edited them. .base/ keeps the skill version from the last init,
# so unedited files update silently, edited ones get a 3-way merge, and only real conflicts go to
# the orchestrator (listed below, marked in the file or as <file>.new).
mkdir -p "$orka/templates/.base"
reconcile="" nl=$'\n'
for new in "$skill"/templates/*; do
  f=$(basename "$new"); cur="$orka/templates/$f"; old="$orka/templates/.base/$f"
  if [ ! -f "$cur" ] || { [ -f "$old" ] && cmp -s "$cur" "$old"; }; then cp "$new" "$cur"
  elif cmp -s "$cur" "$new" || { [ -f "$old" ] && cmp -s "$old" "$new"; }; then :
  elif [ -f "$old" ]; then
    git merge-file -q -L project -L previous-skill -L skill "$cur" "$old" "$new" || reconcile="$reconcile  templates/$f: conflict markers to resolve$nl"
  else
    cp "$new" "$cur.new"; reconcile="$reconcile  templates/$f: compare with $f.new (no base to merge against)$nl"
  fi
  cp "$new" "$old"
done
chmod +x "$orka"/bin/orka "$orka"/bin/*.sh "$orka"/bin/workers/*.sh
[ -f "$orka/COMMON.md" ] || cp "$skill/templates/COMMON.md" "$orka/COMMON.md"
# Before v0.3, COMMON.md held a copy of the shared rules above the project section. Drop that copy
# (they now come from bin/rules.md and stay current); keep everything after the project marker.
if grep -q '^## Rules for every card' "$orka/COMMON.md"; then
  marker='<!-- Project-specific rules go below'
  if grep -q "^$marker" "$orka/COMMON.md"; then
    cp "$orka/COMMON.md" "$orka/COMMON.md.bak"
    sed "1,/^$marker/d" "$orka/COMMON.md.bak" > "$orka/COMMON.md"
    echo "Migrated .orka/COMMON.md to project-only rules (old copy: COMMON.md.bak)."
    reconcile="$reconcile  COMMON.md: shared rules moved to bin/rules.md; move project-specific edits of them from COMMON.md.bak$nl"
  else
    echo "warning: .orka/COMMON.md still has its own copy of the shared rules; keep only the project section." >&2
  fi
fi
[ -f "$orka/decisions.md" ] || printf '# Decisions\n\nOne line per decision: date · decision · who decided · why.\n\n' > "$orka/decisions.md"
[ -f "$orka/backlog.md" ] || printf '# Backlog\n\nWhat the user asked for, in their words. Nothing here runs until the user says go.\n\n' > "$orka/backlog.md"
touch "$orka/ledger.jsonl"

exclude="$(git -C "$project" rev-parse --git-common-dir)/info/exclude"
case $exclude in /*) ;; *) exclude="$project/$exclude" ;; esac
mkdir -p "$(dirname "$exclude")"
grep -qx '/.orka/' "$exclude" 2>/dev/null || echo '/.orka/' >> "$exclude"

echo "Orka home: $orka"
if [ -n "$reconcile" ]; then
  echo "Reconcile (orchestrator decides: keep project-specific changes, take the skill's, then delete .new/.bak files):"
  printf '%s' "$reconcile"
fi
echo "Worker CLIs:"
for a in "$orka"/bin/workers/*.sh; do
  cli=$(basename "$a" .sh)
  if command -v "$cli" >/dev/null; then echo "  $cli: installed"
  else echo "  $cli: not installed"; fi
done
if [ -f "$orka/orka.json" ]; then echo "Team (.orka/orka.json):"; jq -r '.team | to_entries[] | "  \(.key): \(.value.cli) \(.value.model // "") \(.value.effort // "")"' "$orka/orka.json"
else echo "No .orka/orka.json yet: propose a team to the user, then write it (example: .orka/templates/orka.example.json)."; fi
