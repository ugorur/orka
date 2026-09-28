#!/usr/bin/env bash
# Install the Orka skill for every agent harness on this machine.
#   curl -fsSL https://raw.githubusercontent.com/ugorur/orka/master/install.sh | bash
#   ./install.sh            (from a clone)
#
# Copies skills/orka to ~/.agents/skills/orka — read by Codex, Grok, Gemini CLI, Copilot CLI,
# OpenCode and Amp — and links it into ~/.claude/skills (Claude Code) and ~/.cursor/skills (Cursor).
# User scope on purpose: a copy inside your repo would be checked out into every worker's worktree.
set -eu
repo_url=${ORKA_REPO:-https://github.com/ugorur/orka.git}
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/skills/orka/SKILL.md" ]; then
  src="$here/skills/orka"
else
  command -v git >/dev/null || { echo "orka: git is required" >&2; exit 1; }
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  git clone -q --depth 1 "$repo_url" "$tmp/orka"
  src="$tmp/orka/skills/orka"
fi

dest="$HOME/.agents/skills/orka"
if [ -e "$dest" ] && [ ! -f "$dest/.orka-installed" ]; then
  echo "orka: $dest exists but was not installed by this script; move it away and re-run" >&2
  exit 1
fi
# Stage next to the destination, then swap, so a failed copy never leaves a half-installed skill.
mkdir -p "$(dirname "$dest")"
rm -rf "$dest.new"
cp -R "$src" "$dest.new"
date -u +%FT%TZ > "$dest.new/.orka-installed"
rm -rf "$dest.old"
[ -e "$dest" ] && mv "$dest" "$dest.old"
mv "$dest.new" "$dest"
rm -rf "$dest.old"
echo "installed  $dest"

link() { # link <skills dir> <harness>
  local dir=$1 target="$1/orka"
  if [ -e "$target" ] && [ ! -L "$target" ]; then echo "skipped    $target (exists and is not a link; remove it to let Orka manage it)"; return; fi
  mkdir -p "$dir"
  ln -sfn "$dest" "$target"
  echo "linked     $target ($2)"
}
link "$HOME/.claude/skills" "Claude Code"
[ -d "$HOME/.cursor" ] && link "$HOME/.cursor/skills" "Cursor"

for bin in git jq; do command -v $bin >/dev/null || echo "warning    '$bin' is required at runtime"; done
command -v timeout >/dev/null || command -v gtimeout >/dev/null || echo "warning    'timeout' is required at runtime (macOS: brew install coreutils)"
echo
echo "Done. In your project, ask your agent: \"Use Orka to run this project with a team of agent CLIs.\""
