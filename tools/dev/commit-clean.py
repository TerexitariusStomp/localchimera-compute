#!/usr/bin/env python3
"""commit-clean.py — commit this session's files through a clean worktree, in a tree other sessions share.

    tools/dev/commit-clean.py MSGFILE [PATH…] [--exclude REGEX]… [--untracked-ok] [--dry-run]
    tools/dev/commit-clean.py --gate MSGFILE PATH… [--emit] [--baseline FILE] [--gate-cmd CMD]
                              [--warm-cmd CMD] [--emit-cmd CMD] [--boot-cmd CMD] [--gate-wt DIR] [--branch REF]
    tools/dev/commit-clean.py --gate --series FILE [same options]

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

--gate commits only a tree that has passed the gate. The named files are snapshotted as
git objects, merged onto the HEAD of the moment (`git merge-tree`: a file another
session committed meanwhile is MERGED with, never reverted by, the snapshot; a conflict
stops the commit before anything moves), checked out in one stable gate worktree, and
there: the generated files are regenerated (`make emit-all`; drift in a file you did
not name stops the commit unless --emit says to take it), the gate is run (`make gate
gate-hoot`), and a throwaway gateway is booted. If HEAD moved while the gate ran, the
merge and the gate run again, up to three times. The commit is then made by `git
commit` (hooks, signing and identity apply), main moves by compare-and-swap, the shared
index is reset for the paths, and the result is verified: the commit holds the named
files and the regenerated ones only, is signed, and carries no attribution trailer.
The suite's known reds are named with --baseline FILE (`make test RED_BASELINE`).
--series FILE gates several commits at once: each line of FILE is `MSGFILE|PATH PATH …`, the
commits in order, their paths disjoint. The union is merged and gated as one tree and then
committed as one commit per line (each holds its own paths and the regenerated files it names,
the rest of the regenerated files going with the last), so a series of independent changes
pays for one gate. The tree that passed is the series' tip; an intermediate commit is the tip
less the later steps, which no gate saw alone.
Limit: another session's UNCOMMITTED hunks in a file you name are committed with it.
A session can therefore work in a worktree of its own and run this from there: the files
it names are its own alone, HEAD there is where its work began, and --branch REF
(default: the checked-out branch) names the branch the commit lands on, merged onto that
branch's tip as it stands.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

GUARDED = ('module/', 'tests/', 'tools/', 'server/', 'hoot/', 'deploy/')
IGNORED_RUNTIME = ('LICENSE.md', 'LICENSE-ADDITIONAL-TERMS.md')   # ignored by path; suites and the attribution check read them
TRAILER = re.compile(r'^(Co-Authored-By:.*anthropic\.com|Claude-Session:\s*https://claude\.ai/(code/)?session_)', re.I | re.M)
DEFAULT_GATE = 'make gate gate-hoot'
DEFAULT_WARM = 'make lint-compile warm-ccache'     # lint-compile checks every live module; warm-ccache compiles each into the cache, so the emits run compiled
DEFAULT_EMIT = 'make emit-all'
DEFAULT_BOOT = 'bash tools/test/boot-smoke.sh'
MAX_ROUNDS = 3
MODULE_NAME = re.compile(r'\(playnet((?: [a-z0-9*+_-]+)+)\)')
INCLUDE = re.compile(r'include-from-path "(playnet/[^"]+\.scm)"')


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
        if state[0] in 'RC' or state[1] in 'RC':
            changed.append(parts[i])
            i += 1
    return list(dict.fromkeys(changed)), untracked


def take_option(args, name, default=None):
    """The value of `--name VALUE` (removed from ARGS), or DEFAULT."""
    if name in args:
        i = args.index(name)
        value = args[i + 1]
        del args[i:i + 2]
        return value
    return default


# ── the gated commit ─────────────────────────────────────────────────────────

def snapshot_tree(head, paths):
    """The tree of HEAD with each of PATHS as it is now in the shared tree, built in a
    scratch index so no index anyone uses is touched."""
    fd, idx = tempfile.mkstemp(prefix='commit-clean-index-')
    os.close(fd)
    os.unlink(idx)
    env = dict(os.environ, GIT_INDEX_FILE=idx)
    try:
        subprocess.check_call(['git', 'read-tree', head], env=env)
        for p in paths:
            if os.path.islink(p):
                oid = subprocess.check_output(['git', 'hash-object', '-w', '--stdin'], input=os.readlink(p).encode()).decode().strip()
                mode = '120000'
            elif os.path.lexists(p):
                oid = git('hash-object', '-w', '--', p).strip()
                mode = '100755' if os.access(p, os.X_OK) else '100644'
            else:
                subprocess.check_call(['git', 'update-index', '--force-remove', '--', p], env=env)
                continue
            subprocess.check_call(['git', 'update-index', '--add', '--cacheinfo', f'{mode},{oid},{p}'], env=env)
        return git('write-tree', env=env).strip()
    finally:
        if os.path.exists(idx):
            os.unlink(idx)


def commit_of(tree, parent, message):
    return git('commit-tree', tree, '-p', parent, '-m', message).strip()


def merged_tree(head0, head_now, mine, mytree):
    """MYTREE rebased onto HEAD_NOW: the snapshot's change since HEAD0 added to what has
    been committed since. Conflicts stop the commit."""
    if head_now == head0:
        return mytree, []
    r = subprocess.run(['git', 'merge-tree', '--write-tree', f'--merge-base={head0}', head_now, mine],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        sys.exit(f'commit-clean: HEAD moved ({head0[:10]} → {head_now[:10]}) and a file you named conflicts '
                 'with what was committed; merge by hand. Nothing was changed.')
    changed = git('diff', '--name-only', head0, head_now).split()
    return r.stdout.splitlines()[0], changed


def gate_worktree(path):
    """The one stable worktree the gate runs in (its .go cache stays warm); created once."""
    path = os.path.abspath(os.path.expanduser(path))
    if not os.path.isdir(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        subprocess.check_call(['git', 'worktree', 'add', '--detach', path, 'HEAD'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    top = subprocess.check_output(['git', '-C', path, 'rev-parse', '--show-toplevel'], text=True).strip()
    if os.path.realpath(top) != os.path.realpath(path):
        sys.exit(f'commit-clean: {path} is not a worktree of its own (toplevel {top}); refusing to clean it')
    return path


def in_worktree(wt, cmd, log):
    """Run the shell CMD in WT, its output to LOG; → exit status."""
    with open(log, 'ab') as f:
        f.write(f'\n$ {cmd}\n'.encode())
        f.flush()
        return subprocess.call(cmd, shell=True, cwd=wt, stdout=f, stderr=subprocess.STDOUT)


def generated_drift(wt):
    """Paths the emits changed in WT: modified or new files git is told of by status."""
    out = subprocess.check_output(['git', '-C', wt, 'status', '--porcelain', '-z', '-uall']).decode().split('\0')
    return sorted({e[3:] for e in out if e and not e.startswith('!!')})


def sweep_stale_go(wt, changed, cache_root):
    """Drop the compiled files a change leaves stale in the gate worktree. Guile trusts a .go
    whose own source is not newer, and a change to a macro, a record's fields or an exported
    constructor reaches the modules that import it by being INLINED into them: their .go stays
    "fresh" and wrong (a stale compiled demo emit made codes that no fresh run made). So the
    .go of every changed module, and of every module that names it, goes; a tree with no
    record of what it last held loses all of them."""
    root = os.path.join(wt, 'module')
    files, uses = {}, {}                  # module path → module names it names; module name → its path
    for dirpath, _, names in os.walk(root):
        for n in names:
            if n.endswith('.scm'):
                path = os.path.relpath(os.path.join(dirpath, n), wt)
                text = open(os.path.join(wt, path), errors='replace').read()
                files[path] = ({'playnet' + m.group(1) for m in MODULE_NAME.finditer(text)},
                               {'module/' + m.group(1) for m in INCLUDE.finditer(text)})
                uses['playnet ' + path[len('module/playnet/'):-4].replace('/', ' ')] = path
    reverse = {}
    for path, (names, includes) in files.items():
        for name in names:
            target = uses.get(name.replace('playnet', 'playnet', 1))
            if target:
                reverse.setdefault(target, set()).add(path)
        for inc in includes:
            reverse.setdefault(inc, set()).add(path)
    stale = set()
    queue = [c for c in changed if c in files or c.startswith('module/')]
    while queue:
        path = queue.pop()
        if path in stale:
            continue
        stale.add(path)
        queue.extend(reverse.get(path, ()))
    found = subprocess.run(['find', cache_root, '-type', 'f', '-name', '*.go', '-path', '*' + wt.rstrip('/') + '/*'],
                           capture_output=True, text=True).stdout.split('\n')
    dropped = 0
    for go in found:
        if not go:
            continue
        rel = go[go.index(wt.rstrip('/')) + len(wt.rstrip('/')) + 1:-3]      # the source path the .go was made from
        if changed is None or rel in stale or not rel.startswith('module/'):
            os.unlink(go)
            dropped += 1
    return dropped


def gated_commit(msg, paths, opts, left, steps=None):
    steps = steps or [(msg, paths)]
    for m, _ in steps:
        if TRAILER.search(open(m).read()):
            sys.exit(f'commit-clean: {m} carries an attribution trailer; the repository keeps them out (CLAUDE.md)')
    branch = opts['branch'] or git('symbolic-ref', 'HEAD').strip()
    top = git('rev-parse', '--show-toplevel').strip()
    wt = gate_worktree(opts['gate_wt'])
    log = os.path.join(wt, '.commit-clean.log')
    open(log, 'wb').close()
    head0 = git('rev-parse', 'HEAD').strip()
    mytree = snapshot_tree(head0, paths)
    mine = commit_of(mytree, head0, 'snapshot')
    head = head0
    for round_ in range(1, MAX_ROUNDS + 1):
        head_now = git('rev-parse', branch).strip()
        tree, upstream = merged_tree(head0, head_now, mine, mytree)
        if upstream:
            meet = sorted(set(upstream) & set(paths))
            print(f'commit-clean: HEAD moved ({head0[:10]} → {head_now[:10]}); merged '
                  + (f'with its changes to: {" ".join(meet)}' if meet else 'cleanly (it touched none of your files)'))
        gate_commit = commit_of(tree, head_now, 'gate')
        previous = git('-C', wt, 'rev-parse', 'HEAD').strip()
        subprocess.check_call(['git', '-C', wt, 'checkout', '-q', '-f', '--detach', gate_commit])
        subprocess.check_call(['git', '-C', wt, 'clean', '-fdq'])
        changed_here = git('diff', '--name-only', previous, gate_commit).split()
        dropped = sweep_stale_go(os.path.realpath(wt), changed_here, opts['cache_root'])
        print(f'commit-clean: {len(changed_here)} file(s) changed in the gate worktree since it last held a tree; {dropped} compiled file(s) dropped')
        for name in IGNORED_RUNTIME:
            if os.path.exists(os.path.join(top, name)):
                shutil.copy2(os.path.join(top, name), os.path.join(wt, name))
        print(f'commit-clean: round {round_}: gate worktree at {head_now[:10]} + {len(paths)} file(s); log {log}')
        # the emits load modules with --no-auto-compile: a module with no fresh .go is INTERPRETED, and
        # the demo recording (ids drawn in load order) differs between the two, so compile first
        if in_worktree(wt, opts['warm_cmd'], log):
            sys.exit(f'commit-clean: compiling the modules failed; see {log}')
        if in_worktree(wt, opts['emit_cmd'], log):
            sys.exit(f'commit-clean: the emits failed; see {log}')
        regenerated = [d for d in generated_drift(wt) if d != '.commit-clean.log']
        drift = [d for d in regenerated if d not in paths]
        if drift and not opts['emit']:
            print('commit-clean: regenerating changed files you did not name:')
            for d in drift:
                print('  ' + d)
            sys.exit('commit-clean: a generated file is stale at this tree. Pass --emit to commit the regenerated files with yours.')
        env_prefix = f'RED_BASELINE={opts["baseline"]} ' if opts['baseline'] else ''
        for label, cmd in (('gate', env_prefix + opts['gate_cmd']), ('boot', opts['boot_cmd'])):
            print(f'commit-clean: {label}: {cmd}')
            if in_worktree(wt, cmd, log):
                tail = subprocess.run(['tail', '-n', '25', log], capture_output=True, text=True).stdout
                sys.exit(f'commit-clean: {label} failed; the tree is left at {wt}\n{tail}')
        head = git('rev-parse', branch).strip()
        if head == head_now:
            break
        print(f'commit-clean: HEAD moved while the gate ran ({head_now[:10]} → {head[:10]}); again')
    else:
        sys.exit('commit-clean: HEAD kept moving; not committing a tree that was not gated')
    # the tree that passed: the gate commit's parent is HEAD_NOW, so the index is reset to it and
    # the working tree stays the gated tree; each step then adds its own paths and commits
    subprocess.check_call(['git', '-C', wt, 'reset', '-q', head_now])
    claimed = set()
    made = []
    for n, (m, step_paths) in enumerate(steps):
        last = n == len(steps) - 1
        mine_here = list(step_paths) + [d for d in regenerated if d in step_paths or (last and d not in claimed and d not in paths)]
        mine_here = [d for i, d in enumerate(mine_here) if d not in mine_here[:i]]
        claimed.update(mine_here)
        for d in mine_here:    # what the emits changed in a file you named is the commit's too
            subprocess.check_call(['git', '-C', wt, 'add', '-A', '--', d])
        subprocess.check_call(['git', '-C', wt, 'commit', '-q', '-F', m])
        made.append((git('-C', wt, 'rev-parse', 'HEAD').strip(), mine_here))
    new = made[-1][0]
    subprocess.check_call(['git', 'update-ref', branch, new, head_now])
    subprocess.run(['git', 'reset', '-q', '--', *paths])
    for d in drift:            # a regenerated file lands in the shared tree unless someone is editing it
        before = subprocess.run(['git', 'show', f'{head_now}:{d}'], capture_output=True)
        here = open(d, 'rb').read() if os.path.exists(d) else None
        if before.returncode == 0 and here == before.stdout and os.path.exists(os.path.join(wt, d)):
            shutil.copy2(os.path.join(wt, d), d)
        else:
            print(f'commit-clean: {d} in the shared tree differs from HEAD; left as it is')
    subprocess.run(['git', 'reset', '-q', '--', *drift])
    # verify the commits
    signs = subprocess.run(['git', 'config', '--bool', 'commit.gpgsign'], capture_output=True, text=True).stdout.strip() == 'true'
    for (c, owned), (m, step_paths) in zip(made, steps):
        held = git('show', '--stat', '--name-only', '--format=', c).split()
        stray = [h for h in held if h not in owned]
        sig = git('log', '-1', '--format=%G?', c).strip()
        trailer = TRAILER.search(git('log', '-1', '--format=%B', c))
        if stray or (signs and sig != 'G') or trailer:
            print(f'commit-clean: VERIFY FAILED on {c[:10]}: stray={stray} signature={sig} trailer={bool(trailer)}')
            sys.exit(1)
    for p in left:
        if p.startswith(GUARDED):
            print('  left out: ' + p)
    for c, _ in made:
        print(f'commit-clean: gated; ' + git('log', '-1', '--format=%h %an %s', c).strip()[:110])
    print(f'commit-clean: {len(paths)} path(s) + {len(drift)} regenerated in {len(made)} commit(s)')


def main(argv):
    dry = '--dry-run' in argv
    untracked_ok = '--untracked-ok' in argv
    gate = '--gate' in argv
    emit = '--emit' in argv
    args = [a for a in argv if a not in ('--dry-run', '--untracked-ok', '--gate', '--emit')]
    series = take_option(args, '--series')
    opts = {
        'emit': emit,
        'baseline': take_option(args, '--baseline'),
        'gate_cmd': take_option(args, '--gate-cmd', DEFAULT_GATE),
        'emit_cmd': take_option(args, '--emit-cmd', DEFAULT_EMIT),
        'warm_cmd': take_option(args, '--warm-cmd', DEFAULT_WARM),
        'boot_cmd': take_option(args, '--boot-cmd', DEFAULT_BOOT),
        'gate_wt': take_option(args, '--gate-wt', '~/.cache/playnet/gate-wt'),
        'branch': take_option(args, '--branch'),
        'cache_root': os.path.expanduser(take_option(args, '--cache-root', '~/.cache/guile')),
    }
    excludes = []
    while '--exclude' in args:
        i = args.index('--exclude')
        excludes.append(re.compile(args[i + 1]))
        del args[i:i + 2]
    if not args and not series:
        sys.exit(__doc__)
    top = git('rev-parse', '--show-toplevel').strip()
    steps = None
    if series:
        steps = []
        for line in open(series).read().splitlines():
            if line.strip():
                m, _, ps = line.partition('|')
                steps.append((os.path.abspath(m.strip()), [os.path.relpath(os.path.abspath(x), top) for x in ps.split()]))
        flat = [p for _, ps in steps for p in ps]
        if len(flat) != len(set(flat)):
            sys.exit('commit-clean: the steps of a series name disjoint paths; ' + ' '.join(sorted({p for p in flat if flat.count(p) > 1})))
        msg, named = steps[0][0], flat
    else:
        msg = os.path.abspath(args[0])
        named = [os.path.relpath(os.path.abspath(a), top) for a in args[1:]]
    os.chdir(top)
    if gate and not named:
        sys.exit('commit-clean: --gate takes the files by name (PATH…); a gated commit is the files you meant')

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
    if gate:
        if steps:
            steps = [(m, [p for p in ps if p in paths]) for m, ps in steps]
        return gated_commit(msg, paths, opts, left, steps)

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
