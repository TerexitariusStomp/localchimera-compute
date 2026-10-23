#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# gather-repos.sh — move the core and its sibling repos under one parent folder.
#
# The core finds each satellite as ../playnet-<name> and the OpenVTC cache as
# ../openvtc-upstream, and `make link-satellites` links them by relative path,
# so the set moves as a unit with every name kept:
#
#   <parent>/playnet  <parent>/playnet-keri  <parent>/playnet-explorer  …
#
#   tools/dev/gather-repos.sh ~/Programs/playnet-repos
#
# A directory that is renamed keeps its inode, so an editor, terminal or agent
# session working inside keeps working; what goes stale is the PATH it holds.
# Each old location therefore stays as a symlink to the new one (the same goes
# for Claude Code's per-project directory, keyed by the core's absolute path,
# so the project's memory follows the move). Delete the links when nothing
# holds the old paths any more. With --no-links there are no links, and the
# script refuses while any process is working inside a repo.
#
# Guile's compile cache is keyed by path too; the first run after the move
# recompiles.
set -euo pipefail

LINKS=1; [ "${1:-}" = "--no-links" ] && { LINKS=0; shift; }
DEST="${1:?usage: gather-repos.sh [--no-links] <new parent folder>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PARENT="$(dirname "$ROOT")"
CORE="$(basename "$ROOT")"

mapfile -t REPOS < <(cd "$PARENT" && ls -d "$CORE" playnet-* openvtc-upstream 2>/dev/null)
echo "[gather] from $PARENT → $DEST:"; printf '           %s\n' "${REPOS[@]}"

mkdir -p "$DEST"; DEST="$(cd "$DEST" && pwd)"
[ "$DEST" != "$PARENT" ] || { echo "[gather] already there"; exit 0; }
for r in "${REPOS[@]}"; do
  [ ! -e "$DEST/$r" ] || { echo "[gather] $DEST/$r exists already"; exit 1; }
done

# ── who is working inside ───────────────────────────────────────────────────
busy=0
for p in /proc/[0-9]*; do
  pid="${p#/proc/}"; [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ] || continue
  cwd="$(readlink "$p/cwd" 2>/dev/null)" || continue
  for r in "${REPOS[@]}"; do
    case "$cwd/" in "$PARENT/$r/"*)
      echo "[gather] pid $pid ($(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-60)) works in $cwd"; busy=1;;
    esac
  done
done
if [ "$busy" = 1 ]; then
  [ "$LINKS" = 1 ] || { echo "[gather] refused — close those first (or leave the old-path links)"; exit 1; }
  echo "[gather] they keep working: each old path stays as a link to the new one"
fi

# ── move ────────────────────────────────────────────────────────────────────
cd "$PARENT"
for r in "${REPOS[@]}"; do
  mv "$r" "$DEST/$r"
  [ "$LINKS" = 0 ] || ln -s "$DEST/$r" "$r"
  echo "[gather] moved $r"
done

# ── Claude Code's project directory follows the core ────────────────────────
key() { printf '%s' "$1" | sed 's#[/.]#-#g'; }
OLD="$HOME/.claude/projects/$(key "$ROOT")"
NEW="$HOME/.claude/projects/$(key "$DEST/$CORE")"
if [ -d "$OLD" ] && [ ! -L "$OLD" ] && [ ! -e "$NEW" ]; then
  mv "$OLD" "$NEW"; [ "$LINKS" = 0 ] || ln -s "$NEW" "$OLD"
  echo "[gather] memory: $(basename "$NEW")"
fi

echo "[gather] done. Still naming the old path, if anything:"
grep -rlsF "$ROOT" "$HOME/.bashrc" "$HOME/.profile" "$HOME/.config/systemd/user" "$HOME/.claude/settings.json" 2>/dev/null | sed 's/^/           /' || true
echo "         next: cd $DEST/$CORE && make check-satellite-pins"
