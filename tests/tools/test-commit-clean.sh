#!/usr/bin/env bash
# tests/tools/test-commit-clean.sh — a gated commit commits what passed, merges what moved, stops on a conflict.
#
# tools/dev/commit-clean.py --gate commits files from a tree other sessions share.
# What it promises, each stated against a throwaway repository:
#
#   LANDS     the named files, and only them, are committed; the shared index is clean after
#   MERGES    HEAD moved while the gate ran: the other commit stays, the gate runs again,
#             and the commit holds both changes (the snapshot never reverts a file that moved)
#   STOPS     the moved HEAD changed the same lines: the tool stops, main is where the other
#             commit left it, and nothing of ours is committed
#   REFUSES   a message carrying an attribution trailer; a tree whose gate fails
#
# Run: bash tests/tools/test-commit-clean.sh
set -uo pipefail
TOOL="$(cd "$(dirname "$0")/../.." && pwd)/tools/dev/commit-clean.py"
fails=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1"; echo "    expected: $3"; echo "    got:      $2"; fails=$((fails+1)); fi; }

fresh_repo() {                       # → a repo with a.txt, b.txt committed on main
  R="$(mktemp -d /tmp/cc-test.XXXXXX)"
  git -C "$R" init -q -b main
  git -C "$R" config user.name test; git -C "$R" config user.email test@example.invalid; git -C "$R" config commit.gpgsign false
  printf 'one\ntwo\nthree\n' > "$R/a.txt"; printf 'alpha\nbeta\ngamma\n' > "$R/b.txt"
  git -C "$R" add a.txt b.txt; git -C "$R" commit -q -m base
  echo "$R" > /dev/null
}
tool() { (cd "$R" && python3 "$TOOL" "$@" --gate-wt "$R-gate" --emit-cmd true --boot-cmd true 2>&1); }

echo; echo "── LANDS: the named files and no others ──"
fresh_repo
printf 'one\nTWO\nthree\n' > "$R/a.txt"; printf 'alpha\nbeta\nGAMMA\n' > "$R/b.txt"      # b.txt is another session's
echo "a: change" > "$R/msg"
out="$(tool "$R/msg" a.txt --gate --gate-cmd true; echo "exit=$?")"
check "the tool exits 0, its own verification passed" "$(echo "$out" | tail -1)" "exit=0"
check "the commit holds a.txt alone" "$(git -C "$R" show --name-only --format= HEAD)" "a.txt"
check "b.txt stays a working-tree change, uncommitted" "$(git -C "$R" status --porcelain | grep -v '^??')" " M b.txt"
check "the shared index is clean for the committed path" "$(git -C "$R" diff --cached --name-only)" ""

echo; echo "── MERGES: HEAD moves while the gate runs ──"
fresh_repo
printf 'one\nTWO\nthree\n' > "$R/a.txt"
echo "a: change" > "$R/msg"
# the gate's first run commits to b.txt on main from elsewhere; the second finds HEAD settled
cat > "$R/gate.sh" <<SH
#!/usr/bin/env bash
if [ ! -e "$R/.moved" ]; then
  touch "$R/.moved"
  t=\$(mktemp -d); git -C "$R" worktree add -q --detach "\$t" HEAD
  printf 'alpha\nbeta\nGAMMA\n' > "\$t/b.txt"; git -C "\$t" add b.txt; git -C "\$t" commit -q -m "other session"
  git -C "$R" update-ref refs/heads/main "\$(git -C "\$t" rev-parse HEAD)"; git -C "$R" worktree remove --force "\$t"
fi
echo run >> "$R-gate-runs"
SH
chmod +x "$R/gate.sh"
out="$(tool "$R/msg" a.txt --gate --gate-cmd "bash $R/gate.sh"; echo "exit=$?")"
check "the tool exits 0" "$(echo "$out" | tail -1)" "exit=0"
check "the gate ran twice" "$(wc -l < "$R-gate-runs")" "2"
check "the other session's commit is in the history" "$(git -C "$R" log --format=%s -3 | tr '\n' ',')" "a: change,other session,base,"
check "b.txt keeps the other session's change" "$(git -C "$R" show HEAD:b.txt | tail -1)" "GAMMA"
check "a.txt carries ours" "$(git -C "$R" show HEAD:a.txt | sed -n 2p)" "TWO"

echo; echo "── STOPS: the moved HEAD changed our lines ──"
fresh_repo
printf 'one\nTWO\nthree\n' > "$R/a.txt"
echo "a: change" > "$R/msg"
cat > "$R/gate.sh" <<SH
#!/usr/bin/env bash
if [ ! -e "$R/.moved" ]; then
  touch "$R/.moved"
  t=\$(mktemp -d); git -C "$R" worktree add -q --detach "\$t" HEAD
  printf 'one\nDEUX\nthree\n' > "\$t/a.txt"; git -C "\$t" add a.txt; git -C "\$t" commit -q -m "other session"
  git -C "$R" update-ref refs/heads/main "\$(git -C "\$t" rev-parse HEAD)"; git -C "$R" worktree remove --force "\$t"
fi
SH
out="$(tool "$R/msg" a.txt --gate --gate-cmd "bash $R/gate.sh"; echo "exit=$?")"
check "the tool exits non-zero" "$(echo "$out" | tail -1)" "exit=1"
check "main is where the other commit left it" "$(git -C "$R" log -1 --format=%s)" "other session"
check "a.txt there is theirs" "$(git -C "$R" show HEAD:a.txt | sed -n 2p)" "DEUX"

echo; echo "── REFUSES: a trailer in the message; a failing gate ──"
fresh_repo
printf 'one\nTWO\nthree\n' > "$R/a.txt"
printf 'a: change\n\nCo-Authored-By: Someone <noreply@anthropic.com>\n' > "$R/msg"
out="$(tool "$R/msg" a.txt --gate --gate-cmd true; echo "exit=$?")"
check "a message with an attribution trailer is refused" "$(echo "$out" | tail -1)" "exit=1"
check "nothing was committed" "$(git -C "$R" log --format=%s | tr '\n' ',')" "base,"
echo "a: change" > "$R/msg"
out="$(tool "$R/msg" a.txt --gate --gate-cmd false; echo "exit=$?")"
check "a failing gate commits nothing" "$(git -C "$R" log --format=%s | tr '\n' ',')" "base,"

echo
if [ "$fails" -gt 0 ]; then echo "=== Results: $fails failed ==="; exit 1; fi
echo "=== Results: all passed ==="
