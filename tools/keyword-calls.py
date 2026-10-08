#!/usr/bin/env python3
"""Rewrite positional VF record constructor calls as keyword calls.

    keyword-calls.py FIELDS-FILE [--write] FILE...

FIELDS-FILE lines: `make-x field1 field2 …` (the record's fields, in the
positional order the constructor took). Every `(make-x a1 … an)` whose
positional arity fits is rewritten `(make-x #:field1 a1 …)`, an argument that
is the literal #f dropped. A trailing `#:keyword v …` tail passes through. A
call whose arity does not fit is reported and left as it is.

The scanner understands strings, `#\\` characters, `;` comments, `#| |#`
comments, `#;` datum comments, quote prefixes and nested brackets; each
surviving argument keeps the whitespace and comments that preceded it.
"""
import re, sys

def load_fields(path):
    out = {}
    for line in open(path):
        parts = line.split()
        if parts: out[parts[0]] = parts[1:]
    return out

# ── a scanner over one call's argument region ────────────────────────────────
def skip_ws_comments(s, i):
    n = len(s)
    while i < n:
        c = s[i]
        if c in ' \t\n\r': i += 1
        elif c == ';':
            while i < n and s[i] != '\n': i += 1
        elif s.startswith('#|', i):
            depth = 1; i += 2
            while i < n and depth:
                if s.startswith('#|', i): depth += 1; i += 2
                elif s.startswith('|#', i): depth -= 1; i += 2
                else: i += 1
        else: break
    return i

def datum_end(s, i):
    """End index (exclusive) of the datum starting at s[i] (no leading ws)."""
    n = len(s)
    # prefixes
    while i < n and (s[i] in "'`," or s.startswith(',@', i)):
        i += 2 if s.startswith(',@', i) else 1
    if s.startswith('#;', i):
        return datum_end(s, skip_ws_comments(s, i + 2))
    if i >= n: return i
    c = s[i]
    if c == '"':
        i += 1
        while i < n:
            if s[i] == '\\': i += 2
            elif s[i] == '"': return i + 1
            else: i += 1
        return i
    if s.startswith('#\\', i):
        i += 2
        if i < n: i += 1                      # at least one char
        while i < n and (s[i].isalnum() or s[i] in '-_'): i += 1
        return i
    if c in '([{' or s.startswith('#(', i) or s.startswith('#u8(', i) or s.startswith('#vu8(', i):
        if c == '#': i = s.index('(', i)
        depth = 0
        while i < n:
            ch = s[i]
            if ch == '"':
                i = datum_end(s, i); continue
            if s.startswith('#\\', i):
                i = datum_end(s, i); continue
            if ch == ';':
                while i < n and s[i] != '\n': i += 1
                continue
            if s.startswith('#|', i):
                i = skip_ws_comments(s, i); continue
            if ch in '([{': depth += 1
            elif ch in ')]}':
                depth -= 1
                if depth == 0: return i + 1
            i += 1
        return i
    # atom
    while i < n and s[i] not in ' \t\n\r()[]{}";' and not s.startswith('#|', i):
        i += 1
    return i

def split_args(s, start, end):
    """[(lead, text)] for the arguments in s[start:end]; lead is the whitespace
    and comments before each argument; the trailing lead (before the close
    paren) is returned separately."""
    args = []; i = start
    while True:
        j = skip_ws_comments(s, i)
        if j >= end: return args, s[i:end]
        k = datum_end(s, j)
        args.append((s[i:j], s[j:k]))
        i = k

def rewrite_call(s, head_start, name, fields, report):
    """s[head_start] is the '(' of (name …). Returns (new_text, end) or None."""
    i = head_start + 1 + len(name)
    # find the matching close paren of the call
    depth = 1; j = i; n = len(s)
    while j < n and depth:
        ch = s[j]
        if ch == '"' or s.startswith('#\\', j): j = datum_end(s, j); continue
        if ch == ';':
            while j < n and s[j] != '\n': j += 1
            continue
        if s.startswith('#|', j): j = skip_ws_comments(s, j); continue
        if ch in '([{': depth += 1
        elif ch in ')]}': depth -= 1
        j += 1
    close = j - 1
    args, tail = split_args(s, i, close)
    # a keyword tail passes through
    pos = []; kw_from = len(args)
    for idx, (lead, text) in enumerate(args):
        if text.startswith('#:'): kw_from = idx; break
    pos = args[:kw_from]; kws = args[kw_from:]
    if pos and pos[0][1].startswith('#:'):
        return None                                   # already keyworded
    if len(pos) > len(fields):
        report.append(f"{name}: {len(pos)} positional args, {len(fields)} fields")
        return None
    if len(pos) == 0:
        return None
    out = [s[head_start:i]]
    for (lead, text), field in zip(pos, fields):
        if text == '#f':
            # keep a comment riding in the lead, drop pure whitespace
            if lead.strip(): out.append(lead.rstrip(' \t'))
            continue
        out.append(lead if lead else ' ')
        out.append(f'#:{field} {text}')
    for lead, text in kws:
        out.append(lead if lead else ' '); out.append(text)
    out.append(tail); out.append(')')
    new = ''.join(out)
    # tidy: a line left holding only whitespace collapses
    new = re.sub(r'\n[ \t]*\n', '\n', new)
    # a one-line call grown past the margin breaks into lines of keyword pairs
    # filled to the margin, aligned under the first
    column = head_start - (s.rfind('\n', 0, head_start) + 1)
    if '\n' not in new and column + len(new) > 100:
        pairs = re.split(r' (?=#:)', new[len(s[head_start:i]) + 1:-1])
        left = column + len(s[head_start:i]) + 1
        lines, cur = [], ''
        for p in pairs:
            if cur and left + len(cur) + 1 + len(p) > 100:
                lines.append(cur); cur = p
            else:
                cur = (cur + ' ' + p) if cur else p
        lines.append(cur)
        new = s[head_start:i] + ' ' + ('\n' + ' ' * left).join(lines) + ')'
    return new, close + 1

def rewrite_file(path, fields, write):
    s = open(path).read()
    names = sorted(fields, key=len, reverse=True)
    pat = re.compile(r'\((' + '|'.join(re.escape(n) for n in names) + r')(?=[\s)])')
    out = []; i = 0; report = []; count = 0
    while True:
        m = pat.search(s, i)
        if not m: out.append(s[i:]); break
        out.append(s[i:m.start()])
        # a definition's head, an import or export list, a mention in a
        # comment or a string: left alone
        line_start = s.rfind('\n', 0, m.start()) + 1
        before = s[line_start:m.start()]
        if (re.search(r'\(define\*?\s*$', before) or ';' in before
                or re.search(r'#:(select|export|hide|re-export|replace)\s*$', before)
                or before.count('"') % 2 == 1):
            out.append(s[m.start():m.end()]); i = m.end(); continue
        r = rewrite_call(s, m.start(), m.group(1), fields[m.group(1)], report)
        if r is None:
            out.append(s[m.start():m.end()]); i = m.end()
        else:
            out.append(r[0]); i = r[1]; count += 1
    new = ''.join(out)
    if write and new != s: open(path, 'w').write(new)
    return count, report

if __name__ == '__main__':
    argv = sys.argv[1:]
    write = '--write' in argv
    argv = [a for a in argv if a != '--write']
    fields = load_fields(argv[0])
    total = 0
    for p in argv[1:]:
        c, rep = rewrite_file(p, fields, write)
        total += c
        for r in rep: print(f"{p}: {r}")
        if c: print(f"{p}: {c} call(s)")
    print(f"total: {total}")
