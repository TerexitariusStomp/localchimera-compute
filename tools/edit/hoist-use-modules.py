#!/usr/bin/env python3
"""hoist-use-modules.py — a module states its imports in its define-module.

    tools/edit/hoist-use-modules.py [--check] FILE…

A module that says `(use-modules …)` at top level, after its `define-module`,
imports at run time: Guile resolves it as the file loads, and Hoot's
whole-program compile refuses it ("No run-time module registry"), so the module
cannot be part of a page's wasm. This moves each such form's specs into the
`define-module` as `#:use-module` clauses, in the order the file stated them
(define-module's own first, then each top-level form's, top to bottom), which is
the order Guile used them in.

Forms are found by a scanner that knows `;` comments, `"strings"` and `#\\x`
characters, so a paren in prose is never counted, and a scan never starts inside
a comment. A `use-modules` that is not at top level (inside a `when`, a
`cond-expand`) is left where it stands and named. Every write is read back by
Guile (tools/lint/lint-parens.scm) before it replaces the file.

--check reports what would move and writes nothing; it exits 1 when a file
still has a top-level `use-modules` after its `define-module`.
"""
import os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def skip_atom(s, i):
    """Index just past the comment, string or character literal at I, or I when none starts there."""
    c = s[i]
    if c == ';':
        j = s.find('\n', i)
        return len(s) if j < 0 else j
    if c == '"':
        j = i + 1
        while j < len(s) and s[j] != '"':
            j += 2 if s[j] == '\\' else 1
        return j + 1
    if c == '#' and i + 1 < len(s) and s[i + 1] == '\\':
        j = i + 3
        while j < len(s) and (s[j].isalnum() or s[j] == '-'):
            j += 1
        return j
    if c == '#' and i + 1 < len(s) and s[i + 1] == '|':
        j = s.find('|#', i + 2)
        return len(s) if j < 0 else j + 2
    return i


def form_end(s, i):
    """Index just past the balanced form opening at I (s[I] == '(')."""
    depth, j = 0, i
    while j < len(s):
        k = skip_atom(s, j)
        if k != j:
            j = k
            continue
        if s[j] in '([':
            depth += 1
        elif s[j] in ')]':
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    raise ValueError("unbalanced form")


def top_level_forms(s):
    """(start, end) of every top-level parenthesised form, in order."""
    out, j = [], 0
    while j < len(s):
        k = skip_atom(s, j)
        if k != j:
            j = k
            continue
        if s[j] == '(':
            e = form_end(s, j)
            out.append((j, e))
            j = e
        else:
            j += 1
    return out


def specs_of(body):
    """The clauses a use-modules body holds: [(comment lines before it, spec text, trailing comment)]."""
    out, pending, j = [], [], 0
    while j < len(body):
        c = body[j]
        if c == ';':
            e = skip_atom(body, j)
            text = body[j:e].rstrip()
            # a comment on the line of the spec just read belongs to that spec
            if out and '\n' not in body[out[-1][3]:j]:
                out[-1] = (out[-1][0], out[-1][1], text, out[-1][3])
            else:
                pending.append(text)
            j = e
        elif c == '(':
            e = form_end(body, j)
            out.append((pending, body[j:e], "", e))
            pending, j = [], e
        elif c.isspace():
            j += 1
        else:
            raise ValueError("a use-modules clause that is no list: " + body[j:j + 30])
    if pending:                       # a comment after the last spec, on a line of its own
        out.append((pending, None, "", len(body)))
    return [(before, spec, after) for before, spec, after, _ in out]


def hoist(src):
    """SRC with each top-level use-modules after its define-module moved into it; (text, moved, left)."""
    forms = top_level_forms(src)
    heads = [(a, b, src[a + 1:b].split(None, 1)[0] if src[a + 1:b].split() else "") for a, b in forms]
    mods = [(a, b) for a, b, h in heads if h == "define-module"]
    if len(mods) != 1:
        return src, 0, 0
    ma, mb = mods[0]
    uses = [(a, b) for a, b, h in heads if h == "use-modules" and a > mb]
    nested = src.count("(use-modules") - sum(1 for a, b, h in heads if h == "use-modules")
    if not uses:
        return src, 0, nested
    lines, moved = [], 0
    for a, b in uses:
        for before, spec, after in specs_of(src[a + len("(use-modules"):b - 1]):
            lines.extend("  " + c for c in before)
            if spec is not None:
                lines.append("  #:use-module " + spec + ("   " + after if after else ""))
                moved += 1
    # a comment can never be the last thing before a closing paren
    tail = "\n  " if lines and (lines[-1].lstrip().startswith(";") or ";" in lines[-1].split(")")[-1]) else ""
    out, last = [], 0
    out.append(src[:mb - 1] + "\n" + "\n".join(lines) + tail + ")")
    last = mb
    for a, b in uses:
        chunk = src[last:a]
        end = b
        # the form's own line goes with it when nothing else stands on it
        if (chunk == "" or chunk.endswith("\n")) and src[end:end + 1] == "\n":
            end += 1
        out.append(chunk)
        last = end
    out.append(src[last:])
    return "".join(out), moved, nested


def reads(path):
    r = subprocess.run(["guile", "--no-auto-compile", os.path.join(ROOT, "tools/lint/lint-parens.scm"), path],
                       capture_output=True, text=True)
    return r.returncode == 0 and "0 unreadable" in r.stdout


def main(argv):
    check = "--check" in argv
    files = [a for a in argv if not a.startswith("--")]
    stale = 0
    for path in files:
        src = open(path, encoding="utf-8").read()
        try:
            new, moved, nested = hoist(src)
        except ValueError as e:
            print(f"{path}: {e}")
            stale += 1
            continue
        if nested:
            print(f"{path}: {nested} use-modules inside another form, left where it stands")
        if not moved:
            continue
        stale += 1
        if check:
            print(f"{path}: {moved} import(s) stated after define-module")
            continue
        fd, tmp = tempfile.mkstemp(suffix=".scm", dir=os.path.dirname(path))
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new)
        if not reads(tmp):
            os.unlink(tmp)
            print(f"{path}: the hoisted file does not read; left untouched")
            sys.exit(2)
        os.replace(tmp, path)
        print(f"{path}: {moved} import(s) moved into define-module")
    return 1 if check and stale else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
