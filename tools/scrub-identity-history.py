#!/usr/bin/env python3
"""scrub-identity-history.py REPO TIP KEY — replay TIP's history, moving a real identity to the ops one.

Env SCRUB_EMAIL names the address to remove. REPO may be bare (a scratch clone),
TIP the commit to replay, KEY the signing key; nothing in REPO's refs is moved —
the new tip is printed to stderr and the old->new map to stdout, and the new
commits sit in REPO's object store until a ref is pointed at them.

Commits that name GMAIL as author or committer, or carry it in the message, are
re-made with playnet-ops <ops@playnet.earth>; every descendant follows (its
parents changed) and is signed with KEY (or left unsigned when KEY is -), the gpg clock frozen at its own
committer date so the same input yields the same commits. Commits before the
first affected one keep their ids. Prints the old->new map (TSV) on stdout."""
import os, subprocess, sys
repo, tip, key = sys.argv[1:4]
GMAIL = os.environ['SCRUB_EMAIL'].encode()
OPS_N, OPS_E = b'playnet-ops', b'ops@playnet.earth'
wrap = os.path.join(os.path.dirname(os.path.abspath(repo)), 'gpg-frozen-clock')
open(wrap, 'w').write('#!/bin/sh\nexec gpg --faked-system-time "${KERI_SIGN_TIME}!" "$@"\n'); os.chmod(wrap, 0o755)
raw = subprocess.run(['git', '-C', repo, 'log', '--topo-order', '--reverse', '--date=raw',
    '--format=%H%x00%P%x00%T%x00%an%x00%ae%x00%ad%x00%cn%x00%ce%x00%cd%x00%B%x01', tip],
    capture_output=True, check=True).stdout
new = {}; changed = 0; rewritten_ident = 0
for rec in raw.split(b'\x01'):
    rec = rec.lstrip(b'\n')
    if not rec: continue
    h, parents, tree, an, ae, ad, cn, ce, cd, msg = rec.split(b'\x00', 9)
    h = h.decode(); ps = [p for p in parents.decode().split() if p]
    nps = [new[p] for p in ps]
    hit = GMAIL in ae or GMAIL in ce or GMAIL in msg
    if not hit and nps == ps:
        new[h] = h; continue
    if GMAIL in ae: an, ae = OPS_N, OPS_E
    if GMAIL in ce: cn, ce = OPS_N, OPS_E
    if GMAIL in msg: msg = msg.replace(GMAIL, OPS_E)
    env = dict(os.environ, GIT_AUTHOR_NAME=an.decode('utf-8', 'surrogateescape'), GIT_AUTHOR_EMAIL=ae.decode(), GIT_AUTHOR_DATE=ad.decode(),
               GIT_COMMITTER_NAME=cn.decode('utf-8', 'surrogateescape'), GIT_COMMITTER_EMAIL=ce.decode(), GIT_COMMITTER_DATE=cd.decode(),
               KERI_SIGN_TIME=cd.split()[0].decode())
    cmd = ['git', '-C', repo, '-c', 'gpg.program=' + wrap, 'commit-tree']
    if key != '-': cmd.append('-S' + key)       # KEY '-' leaves the commits unsigned (a history that never was)
    cmd.append(tree.decode())
    for p in nps: cmd += ['-p', p]
    r = subprocess.run(cmd, input=msg, env=env, capture_output=True)
    if r.returncode: sys.exit('commit-tree failed for %s: %s' % (h, r.stderr.decode()))
    new[h] = r.stdout.decode().strip(); changed += 1
    if hit: rewritten_ident += 1
for o, n in new.items():
    if o != n: print(o, n, sep='\t')
sys.stderr.write('%d commits re-made (%d carrying the identity), tip %s -> %s\n' % (changed, rewritten_ident, tip, new[tip]))
