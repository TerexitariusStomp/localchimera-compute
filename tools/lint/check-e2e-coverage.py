#!/usr/bin/env python3
# tools/lint/check-e2e-coverage.py — the completeness gate.
#
# "Everything has a test" is a claim this script makes mechanical:
#
#   1. DOORS — every ((name …) clause inside a declared-doors form in
#      module/playnet/doors/*.scm that is ever invoked as 'name somewhere
#      (call sites, tests, other doors) is a declared door. Each must be
#      named in at least one tests/**/*.scm file.
#
#   2. HANDLERS — every "camelName" . handler pair in hoot/day-boot.scm's
#      dispatch table must be named in at least one tests/browser/*.mjs
#      or tests/ux/*.mjs.
#
#   3. DELEGATES — every make-*-delegate in module/playnet/delegates.scm
#      must appear in tests/test-delegates.scm AND a tests/parity/*.scm
#      (the parity suite's live leg is what proves the upstream).
#
# Usage: python3 tools/lint/check-e2e-coverage.py [--warn-only]
# Exit 1 when a required name is uncovered. The audit is conservative:
# a candidate never called as 'name drops out rather than being guessed.

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read_all(pattern):
    for p in sorted(ROOT.glob(pattern)):
        yield p, p.read_text(encoding="utf-8", errors="replace")


def kebab_to_camel(s):
    parts = s.split("-")
    return parts[0] + "".join(w.title() for w in parts[1:])


def declared_doors():
    """Door names = ((sym …) clauses in doors/*.scm that are 'sym-called."""
    candidates = set()
    clause = re.compile(r"^\s*\(\(([a-z][a-z0-9-]*)[\s)]", re.M)
    for _, text in read_all("module/playnet/doors/*.scm"):
        candidates.update(clause.findall(text))

    # a candidate counts only when the codebase invokes it as a symbol —
    # this drops let-bindings, record fields and syntax noise the clause
    # regex cannot see.
    corpus = "\n".join(
        t for _, t in list(read_all("module/**/*.scm"))
        + list(read_all("tests/**/*.scm"))
        + list(read_all("server/**/*.scm"))
        + list(read_all("hoot/**/*.scm"))
    )
    return sorted(c for c in candidates if f"'{c}" in corpus)


def door_is_tested(name):
    q = re.compile(rf"['\"]{re.escape(name)}['\"\s)]")
    for _, text in read_all("tests/**/*.scm"):
        if q.search(text):
            return True
    return False


def dispatch_handlers():
    pairs = re.compile(r'\("([a-zA-Z][a-zA-Z0-9]*)"\s*\.\s*,')
    out = set()
    for _, text in read_all("hoot/day-boot.scm"):
        out.update(pairs.findall(text))
    return sorted(out)


def handler_is_tested(name):
    for _, text in list(read_all("tests/browser/*.mjs")) \
            + list(read_all("tests/ux/*.mjs")) \
            + list(read_all("tests/browser/*.js")):
        if name in text:
            return True
    return False


def delegates():
    makers = re.compile(r"\(define\*? \(?(make-[a-z0-9-]+-delegate)")
    for _, text in read_all("module/playnet/delegates.scm"):
        return sorted(set(makers.findall(text)))
    return []


def named_in(pattern, name):
    for _, text in read_all(pattern):
        if name in text:
            return True
    return False


BASELINE = ROOT / "tools/lint/e2e-coverage-baseline.txt"


def main():
    baseline = set()
    if BASELINE.exists():
        baseline = {ln.strip() for ln in BASELINE.read_text().splitlines()
                    if ln.strip() and not ln.startswith("#")}

    uncovered = []

    print("── doors: declared vs tested ──")
    doors = declared_doors()
    miss = 0
    for d in doors:
        ok = door_is_tested(d)
        if not ok:
            miss += 1
            uncovered.append(f"door:{d}")
    print(f"  {len(doors)} declared doors, {miss} untested")

    print("── handlers: dispatch vs browser/ux tests ──")
    handlers = dispatch_handlers()
    miss = 0
    for h in handlers:
        if not handler_is_tested(h):
            miss += 1
            uncovered.append(f"handler:{h}")
    print(f"  {len(handlers)} dispatch handlers, {miss} untested")

    print("── delegates: makers vs wire + parity suites ──")
    dels = delegates()
    miss = 0
    for m in dels:
        wire_ok = named_in("tests/test-delegates.scm", m)
        par_ok = named_in("tests/parity/*.scm", m)
        if not (wire_ok and par_ok):
            miss += 1
            uncovered.append(f"delegate:{m}")
            print(f"  UNCOVERED  {m}  (wire:{wire_ok} parity:{par_ok})")
    print(f"  {len(dels)} delegates, {miss} uncovered")

    uncovered = set(uncovered)
    new_gaps = uncovered - baseline
    closed = baseline - uncovered

    if "--write-baseline" in sys.argv:
        BASELINE.write_text(
            "# e2e coverage debt — names with no test naming them.\n"
            "# The gate fails on any uncovered name NOT listed here;\n"
            "# remove a line when its name gains coverage.\n"
            + "\n".join(sorted(uncovered)) + "\n")
        print(f"\ncheck-e2e-coverage: baseline written — {len(uncovered)} known gaps")
        return 0

    for g in sorted(new_gaps):
        print(f"  NEW-GAP      {g}")
    for c in sorted(closed):
        print(f"  closed       {c} — remove from baseline")

    if new_gaps:
        print(f"\ncheck-e2e-coverage: {len(new_gaps)} NEW uncovered name(s) "
              f"({len(uncovered)} total gaps, baseline {len(baseline)})")
        return 1
    print(f"\ncheck-e2e-coverage: no new gaps "
          f"({len(uncovered)} known, {len(closed)} closable baseline lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
