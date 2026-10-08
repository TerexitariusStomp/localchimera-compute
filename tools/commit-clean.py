#!/usr/bin/env python3
"""commit-clean.py — commit this session's files through a clean worktree, in a tree other sessions share.

    tools/commit-clean.py MSGFILE [PATH…] [--exclude REGEX]… [--untracked-ok] [--dry-run]

Several sessions work in one tree and one index, so `git add` and `git commit` here
would sweep in files another session staged. This commits whole files instead: a
detached worktree at HEAD receives a copy of every changed path that no --exclude
matches, the commit is made there (so the hooks run on exactly what is committed), and
`main` moves to it by compare-and-swap against the HEAD the worktree started from. The
shared index entries for the committed paths are then reset; nothing else in the tree
or the index is touched.

Changed paths are read from `git status`: modified, added, renamed and deleted tracked
files. An UNTRACKED file is one git has never been told of, so status alone does not
offer it and a commit that imports it lands broken on a fresh checkout while every
local gate stays green. The tool therefore refuses to commit while untracked files
exist under module/, tests/, tools/, server/, hoot/ or deploy/, and names them: give
each to git with `git add -N PATH` (it is then committed whole), exclude it, or pass
--untracked-ok when it belongs to another session.

PATH… names what this commit holds, and is the form to prefer in a shared tree: the
commit is those files and no other, and every other changed code file is listed as
left out, so a file of this session that was forgotten is seen. A PATH that is a
directory stands for the changed files under it. With no PATH the commit takes every
changed path, less those an --exclude REGEX finds (another session's files).
--dry-run lists what would be committed and what is left out.
The message is committed as written: the repository's policy keeps attribution
trailers out of it (CLAUDE.md).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

GUARDED = ('module/', 'tests/', 'tools/', 'server/', 'hoot/', 'deploy/')


def git(*args, **kw):
    return subprocess.check_output(['git', *args], text=True, **kw)


def status_paths():
    """→ (changed paths, untracked paths); a rename gives both of its names."""
    parts = subprocess.check_output(['git', 'status', '--porcelain', '-z']).decode().split('\0')
    changed, untracked, i = [], [], 0
    while i < len(parts):
        entry = parts[i]
        i += 1
        if not entry:
            continue
        state, path = entry[:2], entry[3:]
        if state == '??':
            untracked.append(path)
            continue
        changed.append(path)
        if state[0] in 'RC':
            changed.append(parts[i])
            i += 1
    return list(dict.fromkeys(changed)), untracked


def main(argv):
    dry = '--dry-run' in argv
    untracked_ok = '--untracked-ok' in argv
    args = [a for a in argv if a not in ('--dry-run', '--untracked-ok')]
    excludes = []
    while '--exclude' in args:
        i = args.index('--exclude')
        excludes.append(re.compile(args[i + 1]))
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)
    msg = os.path.abspath(args[0])
    top = git('rev-parse', '--show-toplevel').strip()
    named = [os.path.relpath(os.path.abspath(a), top) for a in args[1:]]
    os.chdir(top)

    def excluded(path):
        if any(r.search(path) for r in excludes):
            return True
        return bool(named) and not any(path == n or path.startswith(n.rstrip('/') + '/') for n in named)

    changed, untracked = status_paths()
    paths = [p for p in changed if not excluded(p)]
    unchanged = [n for n in named if not any(p == n or p.startswith(n.rstrip('/') + '/') for p in changed)]
    if unchanged:
        sys.exit('commit-clean: named, and not changed: ' + ' '.join(unchanged))
    left = [p for p in changed if excluded(p)]
    stray = [p for p in untracked if p.startswith(GUARDED) and not excluded(p)]
    if stray and not untracked_ok:
        print('commit-clean: untracked files git has not been told of:')
        for p in stray:
            print('  ' + p)
        sys.exit('commit-clean: `git add -N` each one that belongs to this commit, --exclude it, or pass --untracked-ok')
    if not paths:
        sys.exit('commit-clean: nothing to commit')
    if dry:
        print(f'commit-clean: would commit {len(paths)} path(s); {len(left)} excluded')
        for p in paths:
            print('  + ' + p)
        for p in left:
            print('  - ' + p)
        return

    head = git('rev-parse', 'HEAD').strip()
    branch = git('symbolic-ref', 'HEAD').strip()
    worktree = tempfile.mkdtemp(prefix='commit-clean-')
    os.rmdir(worktree)
    subprocess.check_call(['git', 'worktree', 'add', '--detach', worktree, head],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for p in paths:
            if os.path.lexists(p):
                os.makedirs(os.path.join(worktree, os.path.dirname(p)), exist_ok=True)
                shutil.copy2(p, os.path.join(worktree, p), follow_symlinks=False)
                subprocess.check_call(['git', '-C', worktree, 'add', '--', p])
            else:
                subprocess.run(['git', '-C', worktree, 'rm', '-q', '--', p], capture_output=True)
        subprocess.check_call(['git', '-C', worktree, 'commit', '-q', '-F', msg])
        new = git('-C', worktree, 'rev-parse', 'HEAD').strip()
        # compare-and-swap: main moves only if it is still where this commit started
        subprocess.check_call(['git', 'update-ref', branch, new, head])
        subprocess.run(['git', 'reset', '-q', '--', *paths])
    finally:
        subprocess.run(['git', 'worktree', 'remove', '--force', worktree], capture_output=True)
    for p in left:
        if p.startswith(GUARDED):
            print('  left out: ' + p)
    print(f'commit-clean: {len(paths)} path(s); ' + git('log', '-1', '--format=%h %an %s').strip()[:110])


if __name__ == '__main__':
    main(sys.argv[1:])
