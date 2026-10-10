#!/usr/bin/env python3
"""move-module.py — move a Scheme file, and rewrite its name everywhere it is written.

    tools/move-module.py [--dry-run] [--bare] OLD.scm NEW.scm

OLD and NEW are paths under module/ (module/playnet/planner/comms-ai.scm
module/playnet/planner/comms/ai.scm). A Guile module's name is its path, so a
move is four rewrites, done here the same way every time:

  1. `git mv`, so history follows the file as a rename.
  2. The module name, wherever it is written: `(playnet planner comms-ai)`
     becomes `(playnet planner comms ai)` in a define-module, an import, an `@`
     reference, a comment, a doc. The closing paren is part of the match, so
     moving `(playnet planner comms)` leaves `(playnet planner comms ai)` alone.
  3. The path, wherever it is written with a directory in front of it:
     `planner/comms-ai.scm` in an include, the Makefile, a doc, a comment. For a
     planner file this includes the spelling docs and headers use, relative to
     module/playnet/planner/: `labour/pulls.scm`, and `labour/pulls` in a table.
     When the old path also names a directory (`knowledge/recipes`), only the
     spelling with `.scm` is rewritten.
  4. tools/module-layout.scm: the file's own `file` form goes, because the file
     now stands where the form said; a `from` form is removed by hand once its
     directory is empty.

--bare also rewrites the bare file name (`comms-ai.scm` → `comms/ai.scm`) where
no directory precedes it. Use it when the old name is distinctive; leave it off
for a name other directories share (`adapters.scm`).

--dry-run prints each rewrite as file:line and changes nothing. A real run ends
by listing every line that still mentions the old name's stem, for a hand
check: a list that names several files under one prefix (`formulas/counting.scm,
labels.scm`) carries the directory once, and only a reader sees that the second
name moved elsewhere. Generated files (module/playnet/README.md,
browser/) are left to their generators, and docs/history/ is a record.

A move changes which module a name comes from only by its path; when a definition
moves BETWEEN modules, tools/add-imports.py finds its importers with the compiler.
`make test` drops the compiled file of every importer a move leaves stale
(tools/freshen-imports.py), so the gate after a move runs the tree as it stands.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEXT = ('.scm', '.md', '.typ', '.sh', '.py', '.mjs', '.cjs', '.ts', '.txt', '.org', '.json', '.sexp')
SKIP = ('browser/', 'node_modules/', 'docs/history/', 'module/playnet/README.md', 'tools/move-module.py')
LAYOUT = 'tools/module-layout.scm'


def module_name(path):
    assert path.startswith('module/') and path.endswith('.scm'), path
    return path[len('module/'):-len('.scm')].split('/')


def tree_files():
    out = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard'], cwd=ROOT, text=True)
    for f in out.splitlines():
        if f.startswith(SKIP) or not os.path.isfile(os.path.join(ROOT, f)):
            continue
        if f.endswith(TEXT) or os.path.basename(f) in ('Makefile', 'guix.scm'):
            yield f


def rewrites(old, new, bare):
    """[(compiled regex, replacement)] for moving module file OLD to NEW."""
    o, n = module_name(old), module_name(new)
    name = re.compile(r'\(' + r'\s+'.join(map(re.escape, o)) + r'\)')
    # the path below module/playnet/, with any directory spelling in front of it
    orel, nrel = '/'.join(o[1:]) + '.scm', '/'.join(n[1:]) + '.scm'
    path = re.compile(r'(?<![\w-])' + re.escape(orel))
    rs = [(name, '(' + ' '.join(n) + ')'), (path, nrel)]
    if o[:2] == ['playnet', 'planner'] and n[:2] == ['playnet', 'planner'] and len(o) >= 4:
        # the planner-relative spelling of docs and headers: labour/pulls(.scm)
        prel_old, prel_new = '/'.join(o[2:]), '/'.join(n[2:])
        is_dir = os.path.isdir(os.path.join(ROOT, 'module/playnet/planner', prel_old))
        short = re.compile(r'(?<![\w/.-])' + re.escape(prel_old) + (r'(\.scm)' if is_dir else r'(\.scm)?')
                           + r'(?![\w-]|\.ts|\.js)')
        rs.append((short, lambda m: prel_new + (m.group(1) or '')))
    if bare:
        base = re.compile(r'(?<![\w/-])' + re.escape(o[-1] + '.scm'))
        rs.append((base, '/'.join(n[-2:]) + '.scm'))
    return rs


def main(argv):
    dry = '--dry-run' in argv
    bare = '--bare' in argv
    args = [a for a in argv if not a.startswith('--')]
    if len(args) != 2:
        sys.exit(__doc__)
    old, new = args
    if not os.path.isfile(os.path.join(ROOT, old)):
        sys.exit(f'move-module: no such file: {old}')
    if os.path.exists(os.path.join(ROOT, new)):
        sys.exit(f'move-module: already there: {new}')
    rs = rewrites(old, new, bare)
    stem = module_name(old)[-1]
    count = 0
    for f in tree_files():
        p = os.path.join(ROOT, f)
        try:
            text = open(p, encoding='utf-8').read()
        except UnicodeDecodeError:
            continue
        out = text
        for rx, rep in rs:
            out = rx.sub(rep, out)
        if f == LAYOUT:
            # the file's own `file` form goes: it now stands where the form said
            rel = old[len('module/playnet/'):-len('.scm')]
            out = re.sub(r'\n[ \t]*\(file "' + re.escape(rel) + r'" [^\n]*', '', out)
        if out != text:
            before, after = text.splitlines(), out.splitlines()
            if len(before) == len(after):
                for i, (a, b) in enumerate(zip(before, after), 1):
                    if a != b:
                        count += 1
                        print(f'{f}:{i}: {b.strip()[:150]}')
            else:
                count += 1
                print(f'{f}: (lines changed)')
            if not dry:
                open(p, 'w', encoding='utf-8').write(out)
    if dry:
        print(f'move-module: {old} → {new}: {count} line(s) would change (dry run)')
        return
    os.makedirs(os.path.dirname(os.path.join(ROOT, new)), exist_ok=True)
    subprocess.check_call(['git', 'mv', old, new], cwd=ROOT)
    print(f'move-module: {old} → {new}: {count} line(s) rewritten')
    left = subprocess.run(['git', 'grep', '-nE', r'(^|[^\w/-])' + re.escape(stem) + r'(\.scm)?([^\w-]|$)', '--',
                           '.', ':!browser', ':!module/playnet/README.md'],
                          cwd=ROOT, text=True, capture_output=True).stdout.splitlines()
    if left:
        print(f'still naming "{stem}" ({len(left)} lines; check by hand):')
        for line in left[:40]:
            print('  ' + line[:170])


if __name__ == '__main__':
    main(sys.argv[1:])
