#!/usr/bin/env python3
"""add-imports.py — a name moved to another module; import that module wherever the name now stands unbound.

    tools/add-imports.py [--dry-run] [--from '(old module)'] '(new module)' NAME…
    tools/add-imports.py [--dry-run] [--from '(old module)'] --map FILE

When a definition leaves one module for another, its importers must name the new
module. Text search over-reports (a name in a comment, a quoted symbol, a local of the
same spelling), so this asks the compiler: every .scm file that mentions a moved NAME is
compiled with `-W unbound-variable`, and the import is added only where a moved name is
reported unbound. It repeats until a round changes nothing, since a file can fail to
compile until a module it imports is fixed.

--map FILE gives several destinations at once: lines of `(module spec) NAME…`.
--from names the module the names left. An import of it that selects a moved name
(`((old) #:select (a b))`) is split: the moved names go to a `#:select` of their new
module, each `#:use-module` clause carrying one spec.

The import lands beside the old module's import when the file has one on a line of its
own, else on the line after `(define-module (…)`, else in a `(use-modules …)` form.

Run it inside the test environment so the compiler sees the modules the tree sees:
    guix shell -L deploy/guix -m deploy/manifests/dev-test-manifest.scm -- \\
        bash tools/own-ccache.sh python3 tools/add-imports.py …
A file that still fails to compile at the end is listed with its error, for a hand
check: a fragment that another file includes has no imports of its own.
"""
import concurrent.futures
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TREES = ('module', 'tests', 'tools', 'server', 'hoot')
# a name read (unbound), selected from a module that lacks it (no binding), or
# re-exported by a module that no longer imports it (Undefined)
UNBOUND = re.compile(r"possibly unbound variable `([^']+)'|Unbound variable: (\S+)|no binding `([^']+)' in module|Undefined variable: (\S+)")
ERROR = re.compile(r'no binding|Unbound variable|Undefined variable|no code for module|Syntax error|expected keyword|does not exist')


def module_file(spec):
    return 'module/' + '/'.join(spec.strip('()').split()) + '.scm'


def candidates(names, own):
    rx = re.compile(r"(?<![^\s()'`,])(" + '|'.join(re.escape(n) for n in sorted(names, key=len, reverse=True)) + r')(?![^\s()])')
    out = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', *TREES], cwd=ROOT, text=True)
    for f in out.splitlines():
        if not f.endswith('.scm') or f in own:
            continue
        try:
            text = open(os.path.join(ROOT, f), encoding='utf-8').read()
        except (UnicodeDecodeError, FileNotFoundError):
            continue
        if rx.search(text):
            yield f


def compile_one(f):
    """→ (file, unbound names, first error line or '')"""
    fd, go = tempfile.mkstemp(suffix='.go')
    os.close(fd)
    try:
        r = subprocess.run(['guild', 'compile', '-L', 'module', '-W', 'unbound-variable', '-o', go, f],
                           cwd=ROOT, capture_output=True, text=True)
    finally:
        if os.path.exists(go):
            os.remove(go)
    out = r.stdout + r.stderr
    unbound = {next(x for x in groups if x) for groups in UNBOUND.findall(out)}
    error = ''
    if r.returncode != 0:
        error = next((l.strip() for l in out.splitlines() if ERROR.search(l)), 'failed to compile')
    return f, unbound, error


def split_selects(text, old, of):
    """An import of OLD selecting moved names keeps its own; the moved go to their modules."""
    rx = re.compile(r'(#:use-module\s+)?\(' + re.escape(old) + r'\s+#:select\s+\(([^()]*)\)\)')

    def rep(m):
        names = m.group(2).split()
        if not any(n in of for n in names):
            return m.group(0)
        by = {}
        for n in names:
            by.setdefault(of.get(n, old), []).append(n)
        specs = ['(' + mod + ' #:select (' + ' '.join(ns) + '))'
                 for mod, ns in sorted(by.items(), key=lambda kv: (kv[0] != old, kv[0]))]
        if m.group(1):
            line = text.rfind('\n', 0, m.start()) + 1
            indent = re.match(r'[ \t]*', text[line:]).group(0)
            return ('\n' + indent).join('#:use-module ' + s for s in specs)
        return ' '.join(specs)
    return rx.sub(rep, text)


def add_import(text, mod, old, names=()):
    """TEXT with MOD imported, or None when the file has no place for an import. A
    file that imports MOD by `#:select` gains NAMES in that list."""
    if re.search(re.escape(mod) + r'(?!\s*#:select)', text):
        return text
    sel = re.search(r'\(' + re.escape(mod) + r'\s+#:select\s+\(([^()]*)\)\)', text)
    if sel and names:
        have = sel.group(1).split()
        more = [n for n in names if n not in have]
        return text[:sel.start(1)] + ' '.join(have + more) + text[sel.end(1):]
    if old:
        m = re.search(r'^([ \t]*)#:use-module ' + re.escape(old) + r'[ \t]*(;[^\n]*)?$', text, re.M)
        if m:
            return text[:m.end()] + '\n' + m.group(1) + '#:use-module ' + mod + text[m.end():]
    m = re.search(r'^\(define-module \([^()]+\)[ \t]*$', text, re.M)
    if m:
        return text[:m.end()] + '\n  #:use-module ' + mod + text[m.end():]
    if old:
        m = re.search(r'(?<![#:\w(-])' + re.escape(old) + r'(?!\s*#:)', text)
        if m:
            return text[:m.end()] + ' ' + mod + text[m.end():]
    m = re.search(r'^\(use-modules', text, re.M)
    if m:
        return text[:m.start()] + '(use-modules ' + mod + ')\n' + text[m.start():]
    return None


def main(argv):
    dry = '--dry-run' in argv
    args = [a for a in argv if a != '--dry-run']
    old = None
    if '--from' in args:
        i = args.index('--from')
        old = args[i + 1]
        del args[i:i + 2]
    of = {}
    if '--map' in args:
        for line in open(args[args.index('--map') + 1], encoding='utf-8'):
            m = re.match(r'\s*(\([^()]+\))\s+(.*)', line)
            if m:
                for n in m.group(2).split():
                    of[n] = m.group(1)
    elif len(args) >= 2:
        for n in args[1:]:
            of[n] = args[0]
    if not of:
        sys.exit(__doc__)
    own = {module_file(m) for m in set(of.values())} | ({module_file(old)} if old else set())
    files = sorted(candidates(of, own))
    print(f'add-imports: {len(of)} name(s), {len(files)} file(s) mention one')
    if old and not dry:
        for f in files:
            p = os.path.join(ROOT, f)
            text = open(p, encoding='utf-8').read()
            new = split_selects(text, old, of)
            if new != text:
                open(p, 'w', encoding='utf-8').write(new)
                print(f'  select  {f}')
    todo, failed = files, {}
    for round_no in range(1, 9):
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(compile_one, todo))
        edits, failed, again = 0, {}, []
        for f, unbound, error in results:
            mods = sorted({of[n] for n in unbound if n in of})
            if error:
                failed[f] = error
            if not mods and not error:
                continue
            again.append(f)
            if not mods:
                continue
            p = os.path.join(ROOT, f)
            text = open(p, encoding='utf-8').read()
            new = text
            for mod in mods:
                r = add_import(new, mod, old, sorted(n for n in unbound if of.get(n) == mod))
                if r is None:
                    failed[f] = 'no place for an import of ' + mod
                else:
                    new = r
            if new != text:
                edits += 1
                print(f'  import  {f}  ' + ' '.join(mods))
                if not dry:
                    open(p, 'w', encoding='utf-8').write(new)
        print(f'  round {round_no}: {edits} file(s) {"would change" if dry else "changed"}, {len(failed)} failing')
        todo = again
        if edits == 0 or dry:
            break
    for f, e in sorted(failed.items()):
        print(f'  CHECK {f}: {e[:160]}')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main(sys.argv[1:])
