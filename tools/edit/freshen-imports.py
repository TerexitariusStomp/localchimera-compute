#!/usr/bin/env python3
"""freshen-imports.py — drop compiled files that are older than a module they import.

    tools/edit/freshen-imports.py [--dry-run]

Guile recompiles a file when its own source is newer than its compiled file. It
does not look at what the file imports, and a compiled file holds more of its
imports than their names: definitions inlined across modules, the layout of a record
it constructs, the module a name was found in when it was compiled. So after a
definition moves, or a record gains a field, an importer that was not itself edited
runs its old compiled file and fails at run time, or reads a field out of place,
while its source is right.

For every compiled file of a source in this tree, this takes the sources the file
reaches by imports (a `(playnet …)` module name anywhere in its text that names a
file here, and the same for each of those in turn) and drops the compiled file when
any of them is newer. The reach is read from the text, so it can only be too wide:
a module named in a comment costs a recompile and nothing else.

tools/test/freshen-ccache.sh runs this after its own check of included fragments, so
`make test` starts from compiled files that match the tree.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TREES = ('module', 'tests', 'tools', 'server', 'hoot')
SPEC = re.compile(r'\((playnet(?:\s+[^\s()#;"]+)+)')


def sources():
    for tree in TREES:
        for d, dirs, files in os.walk(os.path.join(ROOT, tree)):
            dirs[:] = [x for x in dirs if not x.startswith('.') and x != 'node_modules']
            for f in files:
                if f.endswith('.scm'):
                    yield os.path.join(d, f)


def main(argv):
    dry = '--dry-run' in argv
    cache = os.path.join(os.environ.get('XDG_CACHE_HOME') or os.path.expanduser('~/.cache'), 'guile')
    if not os.path.isdir(cache):
        print('freshen-imports: no compile cache, nothing to do')
        return
    mtime, imports = {}, {}
    for src in sources():
        try:
            mtime[src] = os.path.getmtime(src)
            text = open(src, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        found = set()
        for m in SPEC.finditer(text):
            parts = m.group(1).split()
            # the longest prefix that names a file: `(playnet a b #:select …)` and prose alike
            for n in range(len(parts), 1, -1):
                f = os.path.join(ROOT, 'module', *parts[:n]) + '.scm'
                if os.path.isfile(f):
                    found.add(f)
                    break
        found.discard(src)
        imports[src] = found

    newest = {}

    def reach(src):
        """The newest mtime among SRC and all it reaches."""
        if src in newest:
            return newest[src]
        seen, stack, best = {src}, [src], mtime.get(src, 0)
        while stack:
            for dep in imports.get(stack.pop(), ()):
                if dep not in seen:
                    seen.add(dep)
                    best = max(best, mtime.get(dep, 0))
                    stack.append(dep)
        newest[src] = best
        return best

    suffix_root = ROOT + os.sep
    dropped = checked = 0
    for d, dirs, files in os.walk(cache):
        if suffix_root not in d + os.sep:
            continue
        for f in files:
            if not f.endswith('.scm.go'):
                continue
            go = os.path.join(d, f)
            src = (d + os.sep + f[:-3])[(d + os.sep).index(suffix_root):]
            if src not in mtime:
                continue
            checked += 1
            try:
                if reach(src) > os.path.getmtime(go):
                    dropped += 1
                    if not dry:
                        os.remove(go)
            except OSError:
                pass
    print(f'freshen-imports: {checked} compiled file(s) checked, {dropped} older than an import '
          + ('would be dropped' if dry else 'dropped'))


if __name__ == '__main__':
    main(sys.argv[1:])
