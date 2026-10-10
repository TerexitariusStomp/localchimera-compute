#!/usr/bin/env bash
# publish-keri-lib.sh — cut the KERI + OpenVTC library out of core as its own repo.
#
# The library lives inside core (module/playnet/keri with its first-person/ profile,
# their support modules and pure tests — the set tools/lint/lint-keri-lib.scm
# --manifest prints). Core stays the place it is developed, so a change that
# crosses the boundary is one commit. This script produces the small,
# focused repository a KERI / OpenVTC contributor clones: the same paths, the
# full history of those paths, nothing else.
#
# git filter-repo is deterministic, so a run over the same core history yields
# the same commits. The cut is also a Guix CHANNEL (guix/gnu/packages/playnet-keri.scm, the
# core's deploy/guix/gnu/packages/playnet-keri.scm renamed), and a channel authenticates
# every commit by its OpenPGP signature. filter-repo writes unsigned commits, so
# a second pass replays each commit the published repository does not hold yet
# on top of its tip, signed with the ops key (`Cut-Source:` names the unsigned
# commit it came from). The signature is reproducible — gpg's clock is frozen at
# the commit's own date and Ed25519 signs deterministically — so the same core
# history over the same published tip gives the same signed commits.
#
# The published history begins unsigned; the channel introduction is the first
# signed commit, which adds .guix-channel and .guix-authorizations (files the
# cut writes itself: the core's own copies name the core's channel). A
# `keyring` branch carries the ops public key, as the core's channel does.
#
# Paths are identical on both sides, which makes a contributor's patch apply
# to core unchanged (tools/dev/keri-lib-take.sh).
#
# This script builds the repository locally and stops. Publishing it
# (rad init / git push) is a separate, deliberate step, printed at the end.
#
# Usage:  tools/dev/publish-keri-lib.sh [OUT_DIR]      (default ../playnet-keri)
# Reads COMMITTED history — commit the library change before cutting.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-${PLAYNET_KERI_LIB_OUT:-$ROOT/../playnet-keri}}"
cd "$ROOT"

command -v git-filter-repo >/dev/null || git filter-repo --version >/dev/null

echo "== gate"
guile --no-auto-compile -e main -s tools/lint/lint-keri-lib.scm

# The manifest, plus the paths these files had before they moved into the
# library, so their history comes along.
#
# THE PATH SET IS PART OF THE CUT'S IDENTITY. filter-repo brings a path's whole
# history, so adding a path that already has history in the core inserts old
# commits and rewrites every commit after them — the cut then diverges from
# what is published and the --ff-only below refuses it. A file created after
# the last published cut adds only new commits and is safe to list.
mapfile -t PATHS < <(guile --no-auto-compile -e main -s tools/lint/lint-keri-lib.scm --manifest)
PATHS+=(
  module/playnet/governance/first-person.scm
  module/playnet/governance/sybil-detect.scm
  module/playnet/governance/personhood-policy.scm
  module/playnet/keri/README.md
  docs/keri
  docs/first-person
  docs/planning/identity/openvtc-parity.md
  docs/planning/identity/keri-openvtc-library-split.md
  tools/lint/openvtc-parity-check.sh
  tools/lint/lint-keri-lib.scm
  deploy/manifests/keri-lib-manifest.scm
  deploy/guix/playnet-keri.scm
  deploy/guix/gnu/packages/playnet-keri.scm
  LICENSE.md
  LICENSE-ADDITIONAL-TERMS.md
)

ARGS=()
for p in "${PATHS[@]}"; do ARGS+=(--path "$p"); done
# The library README sits beside the code in core and at the root outside it.
ARGS+=(--path-rename module/playnet/keri/README.md:README.md)
# The package is the core channel's deploy/guix/gnu/packages/playnet-keri.scm
# (it began at deploy/guix/playnet-keri.scm, so that path's history comes too),
# and the channel directory here is guix/.
ARGS+=(--path-rename deploy/guix/playnet-keri.scm:guix/playnet-keri.scm)
ARGS+=(--path-rename deploy/guix/gnu/packages/playnet-keri.scm:guix/gnu/packages/playnet-keri.scm)

# History from before the cut was first published (2026-09-20) carries the
# project's pseudonymous identities and no other: an author or committer
# outside this set, on a commit older than the publication, is rewritten to the
# ops identity. Every commit since keeps the names it was made under — a
# contributor's patch, taken into the core by tools/dev/keri-lib-take.sh, goes back
# out under its author. (A fixed mapping over a fixed span, so the cut stays
# deterministic.)
IDENTITY_CALLBACK='
ok = {b"ops@playnet.earth", b"omar.vasquez@proton.me",
      b"priya.diallo@proton.me", b"kiraboshi@proton.me"}
published = 1789948800
if int(commit.author_date.split()[0]) < published:
    if commit.author_email not in ok:
        commit.author_name, commit.author_email = b"playnet-ops", b"ops@playnet.earth"
    if commit.committer_email not in ok:
        commit.committer_name, commit.committer_email = b"playnet-ops", b"ops@playnet.earth"
'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "== clone"
git clone --quiet --no-local "$ROOT" "$WORK/cut"
echo "== filter (${#PATHS[@]} paths)"
git -C "$WORK/cut" filter-repo --quiet --force "${ARGS[@]}" \
    --commit-callback "$IDENTITY_CALLBACK"

if [ -d "$OUT/.git" ]; then
  echo "== update $OUT"
else
  echo "== create $OUT"
  mkdir -p "$OUT"
  git clone --quiet "$WORK/cut" "$OUT"
  git -C "$OUT" remote remove origin
fi
git -C "$OUT" fetch --quiet --force "$WORK/cut" HEAD:refs/cut/incoming
[ -z "$(git -C "$OUT" status --porcelain)" ] || { echo "cut: $OUT has uncommitted changes"; exit 1; }

# ── the channel layer: signed commits over the filtered ones ────────────────
SIGNKEY="$(git -C "$ROOT" config user.signingkey)"
[ -n "$SIGNKEY" ] || { echo "cut: the core carries no user.signingkey"; exit 1; }
FPR_SPACED="$(printf '%s' "$SIGNKEY" | sed -E 's/(.{4})/\1 /g; s/ $//')"
GPGWRAP="$WORK/gpg-frozen-clock"
printf '#!/bin/sh\nexec gpg --faked-system-time "${KERI_SIGN_TIME}!" "$@"\n' > "$GPGWRAP"
chmod +x "$GPGWRAP"

# commit_signed DATE MESSAGE-FILE [author env already exported] — one signed
# commit of whatever is staged, its committer clock frozen at DATE (epoch).
commit_signed() {
  local when="$1" msg="$2"
  GIT_COMMITTER_DATE="$when +0000" KERI_SIGN_TIME="$when" \
    git -C "$OUT" -c gpg.program="$GPGWRAP" -c user.signingkey="$SIGNKEY" \
        -c commit.gpgsign=true commit --quiet --allow-empty -F "$msg"
}
ops_identity() {
  export GIT_AUTHOR_NAME=playnet-ops GIT_AUTHOR_EMAIL=ops@playnet.earth
  export GIT_COMMITTER_NAME=playnet-ops GIT_COMMITTER_EMAIL=ops@playnet.earth
}

# The introduction's date follows the published tip it sits on, so its commit id
# depends on nothing the core has done since — the README can name it.
INTRO_DATE=$(( $(git -C "$OUT" log -1 --format=%ct HEAD) + 60 ))

# the keyring branch: the ops public key, unsigned, made once
if ! git -C "$OUT" rev-parse -q --verify refs/heads/keyring >/dev/null; then
  git -C "$ROOT" cat-file -e "keyring:$SIGNKEY.key" || { echo "cut: the core has no keyring:$SIGNKEY.key"; exit 1; }
  # the key file is binary: it goes blob to blob, never through a shell variable
  blob="$(git -C "$ROOT" cat-file blob "keyring:$SIGNKEY.key" | git -C "$OUT" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\t%s.key\n' "$blob" "$SIGNKEY" | git -C "$OUT" mktree)"
  ( ops_identity; export GIT_AUTHOR_DATE="$INTRO_DATE +0000" GIT_COMMITTER_DATE="$INTRO_DATE +0000"
    c="$(printf 'keyring: the ops public key\n' | git -C "$OUT" commit-tree "$tree")"
    git -C "$OUT" update-ref refs/heads/keyring "$c" )
  echo "== keyring branch"
fi

# the introduction: the first signed commit
if ! git -C "$OUT" cat-file -e HEAD:.guix-channel 2>/dev/null; then
  echo "== channel introduction"
  printf '(channel\n  (version 0)\n  (directory "guix"))\n' > "$OUT/.guix-channel"
  printf ';; Commits are signed by these keys; the public keys are on the keyring branch.\n(authorizations\n (version 0)\n ((%s\n   (name "playnet-ops"))))\n' "\"$FPR_SPACED\"" > "$OUT/.guix-authorizations"
  git -C "$OUT" add .guix-channel .guix-authorizations
  printf 'channel: playnet-keri is a Guix channel, its commits signed by the ops key\n\nThe history before this commit is unsigned. From here every commit carries\nan OpenPGP signature, and .guix-authorizations names who may sign.\n' > "$WORK/msg"
  ( ops_identity; export GIT_AUTHOR_DATE="$INTRO_DATE +0000"; commit_signed "$INTRO_DATE" "$WORK/msg" )
fi

# every filtered commit the repository does not hold yet, replayed and signed.
#
# Which ones are new is read from the CORE's history, not from the filtered
# history's ids: the newest cut-<core sha> tag under the published tip names the
# core commit the last cut came from, and everything in the core after it is
# new. (The filtered ids move whenever the core's commit ids do — a rewrite of
# the core's history re-makes commits whose ids filter-repo also quotes inside
# messages — so ancestry against the published tip is not a stable test; a
# repository with no cut tag yet falls back to it.) The old->new maps under
# docs/history/ carry a tag's core commit across such a rewrite.
core_id() {   # a core commit id, as the current history knows it
  local c="$1" n
  for _ in 1 2 3 4 5 6; do
    n="$(cat "$ROOT"/docs/history/*.tsv 2>/dev/null | awk -v o="$c" '$1 == o { print $2; exit }')"
    [ -n "$n" ] || break
    c="$n"
  done
  printf '%s\n' "$c"
}
last_tag="$(git -C "$OUT" describe --tags --match 'cut-*' --abbrev=0 HEAD 2>/dev/null || true)"
NEW_Y=()
if [ -n "$last_tag" ]; then
  last_core="$(core_id "$(git -C "$OUT" tag -l --format='%(contents)' "$last_tag" | grep -o '[0-9a-f]\{40\}' | head -1)")"
  git -C "$ROOT" merge-base --is-ancestor "$last_core" HEAD 2>/dev/null \
    || { echo "cut: $last_tag names core commit ${last_core:0:12}, which is not in this core's history (add its old->new map under docs/history/)"; exit 1; }
  echo "== new since $last_tag (core ${last_core:0:12})"
  declare -A FILTERED
  while read -r old fil; do FILTERED[$old]="$fil"; done < "$WORK/cut/.git/filter-repo/commit-map"
  for c in $(git -C "$ROOT" rev-list --reverse --topo-order --no-merges "$last_core..HEAD"); do
    fil="${FILTERED[$c]:-}"
    [ -n "$fil" ] && [ "${fil//0/}" != "" ] && NEW_Y+=("$fil")   # 000… = the commit left the cut
  done
else
  while read -r y; do NEW_Y+=("$y"); done < <(git -C "$OUT" rev-list --reverse --topo-order --no-merges refs/cut/incoming --not HEAD)
fi
git -C "$OUT" log --format=%B | sed -n 's/^Cut-Source: //p' | sort > "$WORK/replayed"
n=0
for y in "${NEW_Y[@]}"; do
  grep -qx "$y" "$WORK/replayed" && continue
  git -C "$OUT" cherry-pick --no-commit --allow-empty --keep-redundant-commits "$y" >/dev/null
  { git -C "$OUT" log -1 --format=%B "$y"; printf '\nCut-Source: %s\n' "$y"; } > "$WORK/msg"
  IFS='|' read -r an ae ad cn ce cd < <(git -C "$OUT" log -1 --format='%an|%ae|%ad|%cn|%ce|%cd' --date=raw "$y")
  ( export GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad"
    export GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="$ce"
    commit_signed "${cd%% *}" "$WORK/msg" )
  n=$((n + 1))
done
echo "== replayed and signed $n commit(s)"

# the layer adds only the channel files: the tree is the filtered tree plus them
extra="$(git -C "$OUT" diff --name-only refs/cut/incoming HEAD | LC_ALL=C sort | tr '\n' ' ')"
[ "$extra" = ".guix-authorizations .guix-channel " ] || { echo "cut: the signed tree differs from the filtered one: $extra"; exit 1; }
git -C "$OUT" update-ref -d refs/cut/incoming

echo
echo "cut: $(git -C "$OUT" rev-list --count HEAD) commits, $(git -C "$OUT" ls-files | wc -l) files at $OUT"
echo "identities in the cut:"
git -C "$OUT" log --format='    %an <%ae>' | sort | uniq -c | sort -rn
echo "to publish (a deliberate, separate step):"
echo "    cd $OUT && rad init --name playnet-keri --public     # first time"
echo "    cd $OUT && git push rad HEAD:main keyring             # afterwards"
