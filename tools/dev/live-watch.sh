#!/usr/bin/env bash
# tools/dev/live-watch.sh — watch Scheme files and live-reload them.
#
# Usage (from project root):
#   tools/dev/live-watch.sh                # watch ./module
#   tools/dev/live-watch.sh path1 path2 …  # watch the given dirs/files
#
# Pairs with `make serve-dev`. Run the dev server
# in one terminal, this script in another, edit a Scheme file in any
# editor — the matching procedure is replaced in the running browser
# tab without reloading the page. See docs/dev/LIVE_HACKING.md.
#
# Environment overrides (forwarded to tools/dev/live-reload.scm):
#   PLAYNET_REPL_HOST   default 127.0.0.1
#   PLAYNET_REPL_PORT   default 37146
#   PLAYNET_REPL_TIMEOUT_MS  default 1500
#   PLAYNET_NO_REFRESH  if non-empty, skip the trailing (refresh!)
#
# Requires `inotifywait` (linux-only; from inotify-tools / Guix package
# `inotify-tools`). The bootstrap VPS provider's VM has it via the live-watch shepherd
# service's package manifest; on dev laptops install it manually.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RELOAD="$REPO_ROOT/tools/dev/live-reload.scm"

if [[ ! -x "$RELOAD" ]]; then
    echo "live-watch: $RELOAD is not executable; chmod +x it" >&2
    exit 1
fi

if ! command -v inotifywait >/dev/null 2>&1; then
    echo "live-watch: inotifywait not found — install inotify-tools" >&2
    exit 1
fi

# Default to watching ./module if no args supplied.
if [[ $# -eq 0 ]]; then
    set -- "$REPO_ROOT/module"
fi

# Validate watch targets exist.
for tgt in "$@"; do
    if [[ ! -e "$tgt" ]]; then
        echo "live-watch: no such path: $tgt" >&2
        exit 1
    fi
done

cat <<EOF
═══════════════════════════════════════════════════════════════════
  live-watch: watching for *.scm changes
  REPL relay: ${PLAYNET_REPL_HOST:-127.0.0.1}:${PLAYNET_REPL_PORT:-37146}
  paths:
EOF
for tgt in "$@"; do
    printf '    %s\n' "$tgt"
done
echo "  Ctrl-C to stop."
echo "═══════════════════════════════════════════════════════════════════"

# `--format '%w%f'` prints the absolute path of the file that changed.
# `-q` keeps inotifywait quiet about its own startup logging.
# `-m` is monitor mode (don't exit after first event).
# `-r` recurses into subdirectories.
# `-e close_write` fires once the editor finishes writing the file —
# this matches every editor I know (Emacs, Vim, VS Code, …) without
# triggering on partial writes.
# We don't use --include because some inotifywait builds don't have it;
# instead we filter for .scm in the loop.

inotifywait -m -r -q -e close_write --format '%w%f' "$@" \
| while IFS= read -r path; do
    case "$path" in
        *.scm)
            # Compute repo-relative path so live-reload.scm can match
            # it against its route table.
            rel="${path#$REPO_ROOT/}"
            # Skip generated dev sources to avoid an infinite loop if
            # someone edits one of those by mistake.
            case "$rel" in
                browser/.dev/*) continue ;;
            esac
            "$RELOAD" "$rel" || true  # never crash the watch loop
            ;;
        *) ;; # ignore non-Scheme writes (.swp files, .#lockfiles, …)
    esac
done
