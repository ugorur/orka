#!/usr/bin/env bash
# Remove merged, clean, unused Orka worktrees without risking work in progress.
#   .orka/bin/prune.sh [--dry-run]
set -u
orka=$(cd "$(dirname "$0")/.." && pwd)
project=$(dirname "$orka")
conf="$orka/orka.json"
die() { echo "orka: $*" >&2; exit 2; }

dry_run=0
case ${1:-} in
  '') ;;
  --dry-run) dry_run=1 ;;
  *) die "usage: prune.sh [--dry-run]" ;;
esac

main=$(cd "$project" && pwd -P) || die "cannot read project checkout $project"
main_head=$(git -C "$main" rev-parse HEAD 2>/dev/null) || die "$main is not a git repository"
main_short=$(git -C "$main" rev-parse --short HEAD)
wtdir=$(jq -r '.worktreeDir // empty' "$conf" 2>/dev/null)
[ -n "$wtdir" ] || wtdir="../$(basename "$project")-wt"
case $wtdir in /*) ;; *) wtdir="$project/$wtdir" ;; esac
if [ -d "$wtdir" ]; then
  wtdir=$(cd "$wtdir" && pwd -P)
else
  wtdir=$(cd "$(dirname "$wtdir")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$wtdir")") \
    || die "cannot resolve worktreeDir $wtdir"
fi

disk_kb() {
  [ -e "$wtdir" ] || { echo 0; return; }
  du -sk "$wtdir" 2>/dev/null | awk '{print $1 + 0}'
}

pending_by() {
  local wt=$1 pending
  for pending in "$orka"/runs/*/attempt-*/pending; do
    [ -f "$pending" ] || continue
    [ "$(jq -r '.worktree // empty' "$pending" 2>/dev/null)" = "$wt" ] || continue
    jq -r '.card // "unknown"' "$pending" 2>/dev/null
    return 0
  done
  return 1
}

locked_by() {
  local lock=$1 owner running pid card
  owner=$(readlink "$lock" 2>/dev/null)
  for running in "$orka"/runs/*/attempt-*/running; do
    [ -f "$running" ] || continue
    read -r pid _ < "$running"
    [ "$pid" = "$owner" ] || continue
    card=${running#"$orka/runs/"}
    echo "${card%%/*}"
    return 0
  done
  echo unknown
  return 0
}

before=$(disk_kb)
echo "worktree disk before: $before KB"

list=$(mktemp "${TMPDIR:-/tmp}/orka-prune.XXXXXX") || die "cannot create temporary file"
held_lock=
cleanup() {
  [ -z "$held_lock" ] || [ "$(readlink "$held_lock" 2>/dev/null)" != "$$" ] || rm -f "$held_lock"
  rm -f "$list"
}
trap cleanup EXIT
git -C "$main" worktree list --porcelain > "$list" || die "cannot list worktrees"
mkdir -p "$orka/runs/.locks"

wt=
branch=
process_worktree() {
  local path=$1 ref=$2 short_branch candidate=0 reason dirty_count card path_lock
  [ -n "$path" ] || return
  [ "$path" != "$main" ] || return

  short_branch=${ref#refs/heads/}
  case $short_branch in orka/*) candidate=1 ;; esac
  case $path in "$wtdir"/*) candidate=1 ;; esac
  [ "$candidate" -eq 1 ] || return

  path_lock="$orka/runs/.locks/$(printf '%s' "$path" | tr '/ ' '__')"
  if card=$(pending_by "$path"); then
    reason="in use by $card"
  elif [ -e "$path_lock" ] || [ -L "$path_lock" ]; then
    card=$(locked_by "$path_lock")
    reason="in use by $card"
  elif [ "$dry_run" -eq 0 ] && ! ln -s "$$" "$path_lock" 2>/dev/null; then
    card=$(locked_by "$path_lock")
    reason="in use by $card"
  else
    [ "$dry_run" -eq 1 ] || held_lock=$path_lock
    # A sub-agent preparation writes pending before releasing this same lock.
    if card=$(pending_by "$path"); then
      reason="in use by $card"
    else
      dirty_count=$(git -C "$path" status --porcelain 2>/dev/null | awk 'END {print NR + 0}')
      if [ "$dirty_count" -gt 0 ]; then
        reason="$dirty_count uncommitted files"
      elif ! git -C "$main" merge-base --is-ancestor "$(git -C "$path" rev-parse HEAD 2>/dev/null)" "$main_head" 2>/dev/null; then
        reason="not merged into $main_short"
      else
        reason=
      fi
    fi
  fi

  if [ -n "$reason" ]; then
    echo "kept $path: $reason"
  elif [ "$dry_run" -eq 1 ]; then
    echo "would remove $path"
  elif git -C "$main" worktree remove "$path"; then
    case $short_branch in
      orka/*) git -C "$main" branch -d "$short_branch" >/dev/null || die "removed $path but could not delete branch $short_branch" ;;
    esac
    echo "removed $path"
  else
    echo "kept $path: git refused removal"
  fi
  [ -z "$held_lock" ] || [ "$(readlink "$held_lock" 2>/dev/null)" != "$$" ] || rm -f "$held_lock"
  held_lock=
}

while IFS= read -r line || [ -n "$line" ]; do
  case $line in
    "worktree "*)
      [ -z "$wt" ] || process_worktree "$wt" "$branch"
      wt=${line#worktree }
      branch=
      ;;
    "branch "*) branch=${line#branch } ;;
    '') [ -z "$wt" ] || process_worktree "$wt" "$branch"; wt=; branch= ;;
  esac
done < "$list"
[ -z "$wt" ] || process_worktree "$wt" "$branch"

[ "$dry_run" -eq 1 ] || git -C "$main" worktree prune
after=$(disk_kb)
freed=$((before - after))
[ "$freed" -ge 0 ] || freed=0
freed_mb=$(awk -v kb="$freed" 'BEGIN {printf "%.1f", kb / 1024}')
echo "worktree disk after: $after KB"
echo "freed: $freed KB ($freed_mb MB)"
