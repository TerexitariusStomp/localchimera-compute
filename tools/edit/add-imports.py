#!/usr/bin/env python3
"""add-imports.py — a name moved to another module; import that module wherever the name now stands unbound.

    tools/edit/add-imports.py [--dry-run] [--from '(old module)'] '(new module)' NAME…
    tools/edit/add-imports.py [--dry-run] [--from '(old module)'] --map FILE

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
        bash tools/test/own-ccache.sh python3 tools/edit/add-imports.py …
A file that still fails to compile at the end is listed with its error, for a hand
check: a fragment that another file includes has no imports of its own.
"""
import concurrent.futures
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
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


def list_end(text, i):
    """The index just past the `)` closing the list that opens at TEXT[I], read as
    the reader reads it: a `;` comment runs to its line's end and a string to its
    close, whatever parens they hold."""
    depth = 0
    while i < len(text):
        c = text[i]
        if c == ';':
            i = text.find('\n', i)
            if i < 0:
                break
        elif c == '"':
            i = text.find('"', i + 1)
            while i > 0 and text[i - 1] == '\\':
                i = text.find('"', i + 1)
            if i < 0:
                break
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError('unbalanced list at ' + repr(text[i:i + 40]))


def selects(text, mod):
    """Each `(MOD #:select (…))` in TEXT, innermost first: (start, names start, names
    end, end) with the names between the list's parens."""
    out = []
    for m in re.finditer(r'\(' + re.escape(mod) + r'\s+#:select\s+\(', text):
        names_end = list_end(text, m.end() - 1) - 1
        out.append((m.start(), m.end(), names_end, list_end(text, m.start())))
    return out


def names_in(text):
    return re.sub(r';[^\n]*', '', text).split()


def split_selects(text, old, of):
    """An import of OLD selecting moved names keeps its own; the moved go to their modules."""
    for start, ns, ne, end in reversed(selects(text, old)):
        names = names_in(text[ns:ne])
        if not any(n in of for n in names):
            continue
        by = {}
        for n in names:
            by.setdefault(of.get(n, old), []).append(n)
        specs = ['(' + mod + ' #:select (' + ' '.join(ns_) + '))'
                 for mod, ns_ in sorted(by.items(), key=lambda kv: (kv[0] != old, kv[0]))]
        clause = re.search(r'#:use-module\s+$', text[:start])
        if clause:
            line = text.rfind('\n', 0, clause.start()) + 1
            indent = re.match(r'[ \t]*', text[line:]).group(0)
            new = ('\n' + indent).join('#:use-module ' + s for s in specs)
            text = text[:clause.start()] + new + text[end:]
        else:
            text = text[:start] + ' '.join(specs) + text[end:]
    return text


def add_import(text, mod, old, names=()):
    """TEXT with MOD imported, or None when the file has no place for an import. A
    file that imports MOD by `#:select` gains NAMES in that list."""
    if re.search(re.escape(mod) + r'(?!\s*#:select)', text):
        return text
    sel = selects(text, mod)
    if sel and names:
        _, ns, ne, _ = sel[0]
        have = names_in(text[ns:ne])
        more = [n for n in names if n not in have]
        return text[:ne] + ''.join(' ' + n for n in more) + text[ne:]
    if old:
        m = re.search(r'^([ \t]*)#:use-module ' + re.escape(old) + r'[ \t]*(;[^\n]*)?$', text, re.M)
        if m:
            return text[:m.end()] + '\n' + m.group(1) + '#:use-module ' + mod + text[m.end():]
    m = re.search(r'^\(define-module \([^()]+\)[ \t]*$', text, re.M)
    if m:
        return text[:m.end()] + '\n  #:use-module ' + mod + text[m.end():]
    if old:
        # beside OLD inside an import form only: the same name quoted in a
        # `resolve-module` or an `(@ …)` is a reference, not an import
        m = re.search(r'^[ \t]*\((?:use-modules|define-module)\b[^\n]*?' + re.escape(old) + r'(?!\s*#:)', text, re.M)
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
