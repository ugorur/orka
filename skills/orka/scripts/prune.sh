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

running_by() {
  local wt=$1 running pid recorded card
  for running in "$orka"/runs/*/attempt-*/running; do
    [ -f "$running" ] || continue
    read -r pid _ < "$running"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
    [ -f "${running%/running}/worktree" ] || continue
    IFS= read -r recorded < "${running%/running}/worktree"
    [ "$recorded" = "$wt" ] || continue
    card=${running#"$orka/runs/"}
    echo "${card%%/*}"
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

one_line() {
  awk 'NF { if (text == "") text = $0; else text = text "; " $0 }
       END { print text }'
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
  local ignored status_output status_rc suffix git_error git_rc
  [ -n "$path" ] || return
  [ "$path" != "$main" ] || return

  short_branch=${ref#refs/heads/}
  case $short_branch in orka/*) candidate=1 ;; esac
  case $path in "$wtdir"/*) candidate=1 ;; esac
  [ "$candidate" -eq 1 ] || return

  path_lock="$orka/runs/.locks/$(printf '%s' "$path" | tr '/ ' '__')"
  if card=$(running_by "$path"); then
    reason="in use by $card"
  elif card=$(pending_by "$path"); then
    reason="in use by $card"
  elif [ -e "$path_lock" ] || [ -L "$path_lock" ]; then
    card=$(locked_by "$path_lock")
    reason="in use by $card"
  elif [ "$dry_run" -eq 0 ] && ! ln -s "$$" "$path_lock" 2>/dev/null; then
    card=$(locked_by "$path_lock")
    reason="in use by $card"
  else
    [ "$dry_run" -eq 1 ] || held_lock=$path_lock
    # A runner writes its worktree marker, and sub-agent preparation writes pending,
    # before releasing this same lock.
    if card=$(running_by "$path"); then
      reason="in use by $card"
    elif card=$(pending_by "$path"); then
      reason="in use by $card"
    else
      status_output=$(git -C "$path" status --porcelain 2>&1)
      status_rc=$?
      dirty_count=$(printf '%s\n' "$status_output" | awk 'NF {count++} END {print count + 0}')
      if [ "$status_rc" -ne 0 ]; then
        reason=$(printf '%s\n' "$status_output" | one_line)
        [ -n "$reason" ] || reason="git status failed"
      elif [ "$dirty_count" -gt 0 ]; then
        reason="$dirty_count uncommitted files"
      elif ! git -C "$main" merge-base --is-ancestor "$(git -C "$path" rev-parse HEAD 2>/dev/null)" "$main_head" 2>/dev/null; then
        reason="not merged into $main_short"
      else
        status_output=$(git -C "$path" status --porcelain --ignored=matching 2>&1)
        status_rc=$?
        if [ "$status_rc" -ne 0 ]; then
          reason=$(printf '%s\n' "$status_output" | one_line)
          [ -n "$reason" ] || reason="could not inspect ignored files"
        else
          ignored=$(printf '%s\n' "$status_output" | awk '
            /^!! / {
              path = substr($0, 4)
              if (paths == "") paths = path
              else paths = paths ", " path
            }
            END { print paths }
          ')
          reason=
        fi
      fi
    fi
  fi

  suffix=
  [ -z "${ignored:-}" ] || suffix=" (also deleted ignored: $ignored)"
  if [ -n "$reason" ]; then
    printf 'kept %s: %s\n' "$path" "$reason"
  elif [ "$dry_run" -eq 1 ]; then
    printf 'would remove %s%s\n' "$path" "$suffix"
  else
    git_error=$(git -C "$main" worktree remove "$path" 2>&1)
    git_rc=$?
    if [ "$git_rc" -ne 0 ]; then
      git_error=$(printf '%s\n' "$git_error" | one_line)
      [ -n "$git_error" ] || git_error="git refused removal"
      printf 'kept %s: %s\n' "$path" "$git_error"
    else
      git_error=
      git_rc=0
      case $short_branch in
        orka/*)
          git_error=$(git -C "$main" branch -d "$short_branch" 2>&1)
          git_rc=$?
          ;;
      esac
      if [ "$git_rc" -eq 0 ]; then
        printf 'removed %s%s\n' "$path" "$suffix"
      else
        git_error=$(printf '%s\n' "$git_error" | one_line)
        [ -n "$git_error" ] || git_error="git refused branch deletion"
        printf 'kept %s: %s%s\n' "$path" "$git_error" "$suffix"
      fi
    fi
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

if [ "$dry_run" -eq 0 ]; then
  prune_error=$(git -C "$main" worktree prune 2>&1)
  prune_rc=$?
  if [ "$prune_rc" -ne 0 ]; then
    prune_error=$(printf '%s\n' "$prune_error" | one_line)
    [ -n "$prune_error" ] || prune_error="git worktree prune failed"
    echo "orka: $prune_error" >&2
  fi
fi
after=$(disk_kb)
freed=$((before - after))
[ "$freed" -ge 0 ] || freed=0
freed_mb=$(awk -v kb="$freed" 'BEGIN {printf "%.1f", kb / 1024}')
echo "worktree disk after: $after KB"
echo "freed: $freed KB ($freed_mb MB)"
