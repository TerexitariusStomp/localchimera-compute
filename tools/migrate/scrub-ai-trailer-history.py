#!/usr/bin/env python3
"""scrub-ai-trailer-history.py REPO TIP KEY — replay TIP's history, dropping
an AI co-authorship trailer from each commit's message.

REPO may be bare (a scratch clone — never a live working tree); TIP the
commit to replay; KEY the signing key (or '-' to leave the new commits
unsigned). Nothing in REPO's refs is moved: the new tip is printed to
stderr and the old->new map to stdout, and the new commits sit in REPO's
object store until a ref is pointed at them.

A commit whose message carries a `Co-Authored-By: Claude …` line (an
`<…@anthropic.com>` address) or a `Claude-Session: …` line (a
`claude.ai/.../session_…` URL) is re-made with that line dropped; every
descendant follows (its parents changed) and is re-signed, the gpg clock
frozen at its own committer date so the same input yields the same
commits — EXCEPT a commit dated before KEY itself was created, where gpg
refuses outright ("time warp or clock problem") and even a successful
`--ignore-time-conflict` signature fails plain verification afterward
(`Can't check signature: Time conflict" — tested 2026-10-05). For those,
the signature is made at the REAL current time instead (GIT_COMMITTER_DATE
still carries the original historical date; only the detached PGP
signature's own timestamp is "now"), which verifies clean (%G?  = G) at
the cost of exact reproducibility across separate runs for that commit
only — acceptable for a rewrite meant to happen once. Author and
committer are left untouched — this is a message-body edit only. A
commit authored or committed AS Claude (the git identity itself, not a
trailer) is a different, separate case this script does not touch — see
docs/planning/repo-notes-2026-10-02.local.md Tier 9.1/10. Commits before
the first affected one keep their ids. Prints the old->new map (TSV) on
stdout.
"""
import os, re, subprocess, sys

repo, tip, key = sys.argv[1:4]
OPS_N, OPS_E = b'localchimera-ops', b'ops@localchimera.earth'

# The signing key's own creation time: a commit dated before this cannot
# get a frozen-clock signature that later verifies (see module docstring).
KEY_CREATED = None
if key != '-':
    r = subprocess.run(['gpg', '--list-keys', '--with-colons', key],
                        capture_output=True, check=True).stdout
    for line in r.split(b'\n'):
        f = line.split(b':')
        if f[0] == b'pub':
            KEY_CREATED = int(f[5]); break
    if KEY_CREATED is None:
        sys.exit('could not read creation time of key %s' % key)

# Same value-shape patterns as deploy/scripts/git-hooks/prepare-commit-msg
# and pre-push Guard 5/4 — anchored on the trailer's VALUE, not just its key,
# so a sentence of prose that happens to start a line with these words is
# never mistaken for a real trailer (the exact bug that first version of the
# hook hit, caught 2026-10-02).
CO_AUTHORED_RE = re.compile(
    rb'^Co-Authored-By:[^<]*<[^>]*@anthropic\.com>[ \t]*$', re.MULTILINE)
SESSION_RE = re.compile(
    rb'^Claude-Session:[ \t]*https://claude\.ai/(?:code/)?session_[A-Za-z0-9_-]+[ \t]*$',
    re.MULTILINE)

def strip_trailers(msg):
    lines = msg.split(b'\n')
    kept = [l for l in lines
            if not CO_AUTHORED_RE.match(l) and not SESSION_RE.match(l)]
    return b'\n'.join(kept)

wrap = os.path.join(os.path.dirname(os.path.abspath(repo)), 'gpg-frozen-clock')
open(wrap, 'w').write('#!/bin/sh\nexec gpg --faked-system-time "${KERI_SIGN_TIME}!" "$@"\n')
os.chmod(wrap, 0o755)

raw = subprocess.run(['git', '-C', repo, 'log', '--topo-order', '--reverse', '--date=raw',
    '--format=%H%x00%P%x00%T%x00%an%x00%ae%x00%ad%x00%cn%x00%ce%x00%cd%x00%B%x01', tip],
    capture_output=True, check=True).stdout

new = {}; changed = 0; rewritten_trailer = 0; pre_key_signed = 0
for rec in raw.split(b'\x01'):
    rec = rec.lstrip(b'\n')
    if not rec: continue
    h, parents, tree, an, ae, ad, cn, ce, cd, msg = rec.split(b'\x00', 9)
    h = h.decode(); ps = [p for p in parents.decode().split() if p]
    nps = [new[p] for p in ps]
    new_msg = strip_trailers(msg)
    hit = new_msg != msg
    if not hit and nps == ps:
        new[h] = h; continue
    env = dict(os.environ,
               GIT_AUTHOR_NAME=an.decode('utf-8', 'surrogateescape'), GIT_AUTHOR_EMAIL=ae.decode(), GIT_AUTHOR_DATE=ad.decode(),
               GIT_COMMITTER_NAME=cn.decode('utf-8', 'surrogateescape'), GIT_COMMITTER_EMAIL=ce.decode(), GIT_COMMITTER_DATE=cd.decode(),
               KERI_SIGN_TIME=cd.split()[0].decode())
    cd_epoch = int(cd.split()[0])
    pre_key = KEY_CREATED is not None and cd_epoch < KEY_CREATED
    cmd = ['git', '-C', repo]
    if not pre_key: cmd += ['-c', 'gpg.program=' + wrap]
    cmd += ['commit-tree']
    if key != '-': cmd.append('-S' + key)
    cmd.append(tree.decode())
    for p in nps: cmd += ['-p', p]
    r = subprocess.run(cmd, input=new_msg, env=env, capture_output=True)
    if r.returncode: sys.exit('commit-tree failed for %s: %s' % (h, r.stderr.decode()))
    new[h] = r.stdout.decode().strip(); changed += 1
    if hit: rewritten_trailer += 1
    if pre_key: pre_key_signed += 1
for o, n in new.items():
    if o != n: print(o, n, sep='\t')
sys.stderr.write('%d commits re-made (%d carrying a trailer, %d signed at real time — pre-key), tip %s -> %s\n'
                  % (changed, rewritten_trailer, pre_key_signed, tip, new[tip]))
