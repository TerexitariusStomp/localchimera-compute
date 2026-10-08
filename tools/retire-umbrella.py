#!/usr/bin/env python3
"""retire-umbrella.py — a file that imports an umbrella module imports the modules it uses.

    tools/retire-umbrella.py planner [--dry-run] FILE…
    tools/retire-umbrella.py governance [--dry-run] FILE…

An umbrella ((playnet planner), (playnet governance)) re-exports hundreds of
names from dozens of modules, so a file that imports it states nothing about
what it reads. This rewrites each import of the umbrella into imports of the
modules that DEFINE the names the file mentions:

  1. Guile (tools/umbrella-map.scm) maps every name the umbrella exports to the
     module that defines it.
  2. The file's symbols (comments and strings removed, so prose does not count;
     quoted data does) meet the exported names. A name the file defines itself
     at top level is its own.
  3. Each import form naming the umbrella becomes one import per defining module:
     `(use-modules (playnet planner))` → `(use-modules (A) (B))`,
     `#:use-module (playnet planner)` → one `#:use-module` per module,
     `((playnet planner) #:select (x y))` → a `#:select` per module.

The match over-approximates (a symbol in quoted data counts), which is the safe
direction: a module imported and unused costs nothing, and a name used and not
imported is a failure in a branch a suite may never take. A name Guile cannot
place, or one the umbrella defines itself, is reported and the file is left
alone. --dry-run prints the replacement and writes nothing.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def umbrella_map(name):
    out = subprocess.run(['guile', '--no-auto-compile', '-L', 'module', 'tools/umbrella-map.scm', 'playnet', name],
                         cwd=ROOT, capture_output=True, text=True,
                         env={**os.environ, 'LC_ALL': 'C.UTF-8'}).stdout
    m = {}
    for line in out.splitlines():
        n, _, mod = line.partition('\t')
        m[n] = mod
    return m


def strip(text):
    """The file's code with comments, strings and character literals blanked."""
    text = re.sub(r'#\|.*?\|#', ' ', text, flags=re.S)
    text = re.sub(r'#\\(?:x[0-9a-fA-F]+|[A-Za-z]+|.)', ' ', text)
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
            i += 1
            out.append(' ')
        elif c == ';':
            while i < n and text[i] != '\n':
                i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def mask(text):
    """TEXT with comments, strings and character literals blanked, position for position."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '#' and text.startswith('#|', i):
            j = text.find('|#', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        elif c == '#' and text.startswith('#\\', i):
            for k in range(i, min(n, i + 3)):
                out[k] = ' '
            i += 3
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == '\\' else 1
            for k in range(i, min(n, j + 1)):
                if out[k] != '\n':
                    out[k] = ' '
            i = j + 1
        elif c == ';':
            while i < n and text[i] != '\n':
                out[i] = ' '
                i += 1
        else:
            i += 1
    return ''.join(out)


def sub_code(rx, repl, text):
    """re.sub over the CODE of TEXT: a match is replaced only where the code, not a comment,
    string or quasi-quoted actor key, holds it."""
    code = mask(text)
    pieces, last = [], 0
    for m in rx.finditer(code):
        # the quasi-quoted portrait keys `(((playnet … ) ^actor) …) are data on disk
        if '`' in code[max(0, m.start() - 4):m.start()]:
            continue
        pieces.append(text[last:m.start()])
        pieces.append(repl(m))
        last = m.end()
    pieces.append(text[last:])
    return ''.join(pieces)


TOKEN = re.compile(r"[^\s()'`,\[\]{}]+")
DEFINE = re.compile(r'\(\s*define(?:\*|-syntax|-public|-values)?\s+\(?\s*([^\s()]+)')


def symbols(code):
    return set(TOKEN.findall(code))


def own_definitions(code):
    return set(DEFINE.findall(code))


def rewrite(text, umb, exports):
    """→ (new text, imported modules, unresolved names) or (None, …) when nothing to do."""
    code = strip(text)
    spec = r'\(playnet\s+' + umb + r'\)'
    if not re.search(spec, code):
        return None, [], []
    used = (symbols(code) & set(exports)) - own_definitions(code)
    # names the file's own import lists select are used by definition
    unresolved = sorted(n for n in used if exports[n] in ('', '?', '-'))
    if unresolved:
        return None, [], unresolved
    # the core language is always there
    used = {n for n in used if exports[n] not in ('guile', 'guile-user')}
    mods = sorted({exports[n] for n in used})

    def mod_forms(names=None):
        ms = sorted({exports[n] for n in (names if names is not None else used)})
        return ms

    def sub_select(m):
        body = m.group(1)
        names = re.findall(r"[^\s()]+", body)
        have = [n for n in names if n in exports and exports[n] not in ('', '?', '-', 'guile', 'guile-user')]
        by = {}
        for n in have:
            by.setdefault(exports[n], []).append(n)
        parts = ['((' + mod + ') #:select (' + ' '.join(ns) + '))' for mod, ns in sorted(by.items())]
        return ' '.join(parts)

    # ((playnet planner) #:select (a b)) — one select per defining module
    text = sub_code(re.compile(r'\(\(playnet\s+' + umb + r'\)\s+#:select\s+\(([^)]*)\)\)'), sub_select, text)

    def use_module(m):
        indent = m.group(1)
        ms = mods
        return ('\n').join(indent + '#:use-module (' + mod + ')' for mod in ms)

    text = sub_code(re.compile(r'^([ \t]*)#:use-module\s+\(playnet\s+' + umb + r'\)[ \t]*(?=\n|;)', re.M), use_module, text)

    def use_modules(m):
        return ' '.join('(' + mod + ')' for mod in mods)

    # a bare spec inside (use-modules …) or a spec list
    text = sub_code(re.compile(r'(?<=[\s(])\(playnet\s+' + umb + r'\)(?!\s*#:select)'), use_modules, text)
    return text, mods, []


def main(argv):
    dry = '--dry-run' in argv
    args = [a for a in argv if not a.startswith('--')]
    if len(args) < 2:
        sys.exit(__doc__)
    umb, files = args[0], args[1:]
    exports = umbrella_map(umb)
    if not exports:
        sys.exit('retire-umbrella: Guile gave no export map for (playnet %s)' % umb)
    n = 0
    for f in files:
        p = os.path.join(ROOT, f)
        text = open(p, encoding='utf-8').read()
        new, mods, bad = rewrite(text, umb, exports)
        if bad:
            print(f'SKIP {f}: names with no single defining module: {" ".join(bad[:8])}')
            continue
        if new is None:
            continue
        n += 1
        print(f'{f}: {len(mods)} module(s): ' + ', '.join(m.replace('playnet planner ', '') for m in mods))
        if not dry:
            open(p, 'w', encoding='utf-8').write(new)
    print(f'retire-umbrella: {n} file(s) {"would change" if dry else "rewritten"}')


if __name__ == '__main__':
    main(sys.argv[1:])
