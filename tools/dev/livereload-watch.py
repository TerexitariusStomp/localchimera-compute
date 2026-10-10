#!/usr/bin/env python3
"""tools/dev/livereload-watch.py — dev live-reload for the day dial.

Polls the mtimes of everything under browser/ and, whenever any file changes,
writes a fresh value into browser/reload-token.txt. app.html (in DEV mode only)
polls that token same-origin and reloads the page when it moves — so editing a
file here repaints the dial in the browser (or the phone, over the dev onion)
with no manual refresh. No inotify dependency; pure stdlib mtime scan.

Usage:  python3 tools/dev/livereload-watch.py [browser_dir]
Stop:   Ctrl-C
"""
import os, sys, time

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else
                       os.path.join(os.path.dirname(__file__), "..", "..", "browser"))
TOKEN = os.path.join(ROOT, "reload-token.txt")
IGNORE_DIRS = {".git", "node_modules"}


def snapshot():
    """Max mtime across browser/, excluding the token file itself and vcs dirs."""
    latest = 0.0
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in IGNORE_DIRS]
        for name in filenames:
            path = os.path.join(dirpath, name)
            if path == TOKEN:
                continue
            try:
                latest = max(latest, os.stat(path).st_mtime)
            except FileNotFoundError:
                pass
    return latest


def main():
    print(f"live-reload: watching {ROOT}")
    last = None
    counter = 0
    while True:
        cur = snapshot()
        if last is None:
            last = cur
        elif cur != last:
            last = cur
            counter += 1
            with open(TOKEN, "w") as f:
                f.write(f"{cur:.6f}-{counter}")
            print(f"  changed -> reload #{counter}")
        time.sleep(0.5)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nlive-reload: stopped")
