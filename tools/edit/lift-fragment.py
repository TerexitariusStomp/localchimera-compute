#!/usr/bin/env python3
"""lift-fragment.py — turn a planner include-fragment into a real module.

    tools/edit/lift-fragment.py utils/store-utils.scm "(localchimera utils store-utils)" \
        ["#:use-module (localchimera utils clock)"]

Mechanical half of the conversion documented in schemas.scm's header:

  1. read the fragment's top-level definitions -> an explicit #:export list
  2. give it a define-module, after its leading comment block
  3. in every umbrella that included it: add the #:use-module, move the names
     it now provides from #:export to #:re-export, drop the include

Why the move is required: #:export cannot carry an imported binding — Guile
raises "Unbound variable" at module init. And the #:use-module has to go IN the
define-module form, because #:re-export is processed at define-module time; an
import placed later in the file arrives after the re-export has already failed.

Three details that bite. Wrapping the name lists uses break_on_hyphens=False:
textwrap otherwise splits `*action-definitions*` at a hyphen and you get two
bogus exports and a very confusing "Unbound variable: *action-". Names are
removed from #:export token-wise rather than line-wise, so inline comments in
those lists survive. And every write is checked by `assert_reads` — these are
text edits to a structure, and the reader is the only honest acceptance test.

Verification is NOT this script's job. Run the suite against a baseline of the
same tests before the change — several planner tests fail for unrelated reasons
under bare guile, and only a before/after comparison separates those out.
"""
import os, re, sys, textwrap

# path -> the module it defines. A dict rather than a list because prune_hollow
# has to ask the LIVE module system what each umbrella publishes, and pairing
# the two by list index broke the moment a third umbrella joined.
UMBRELLAS = {
    "module/localchimera/boot/prelude.scm":       "(localchimera boot prelude)",
    "module/localchimera/deprecated/planner.scm": "(localchimera deprecated planner)",
    "module/localchimera/deprecated/federation-a.scm": "(localchimera deprecated federation-a)",
}

def defined_names(path):
    """Top-level names bound by the fragment, in source order, deduped."""
    import subprocess
    scm = r'''
(use-modules (ice-9 match) (srfi srfi-1))
(define names (quote ()))
(call-with-input-file (cadr (command-line)) (lambda (p)
  (let loop ()
    (let ((f (read p)))
      (unless (eof-object? f)
        (set! names (append names (match f
          ;; (define-actor (^name bcom . args) …) binds ^name — miss this and the
          ;; module silently exports everything EXCEPT its actor constructors.
          ;; define-syntax-rule is here for the same reason: keys/bran-custody.scm's
          ;; with-host-vault-key went unexported, and the umbrella's #:export of
          ;; it became a hollow slot that resolved right up to first expansion.
          (((quote define-actor) (? pair? s) . _) (list (car s)))
          (((or (quote define) (quote define*) (quote define-public)
                (quote define-syntax) (quote define-syntax-rule)
                (quote define-inlinable)) (? pair? s) . _) (list (car s)))
          (((or (quote define) (quote define*) (quote define-public)
                (quote define-syntax) (quote define-syntax-rule)
                (quote define-inlinable)) (? symbol? n) . _) (list n))
          (((quote define-values) (? pair? ns) . _) (filter symbol? ns))
          (((quote define-record-type) tn ctor pred . fs)
           (append (if (symbol? tn) (list tn) (quote ()))
                   (if (pair? ctor) (list (car ctor)) (quote ()))
                   (if (symbol? pred) (list pred) (quote ()))
                   (append-map (lambda (x) (if (pair? x) (filter symbol? (cdr x)) (quote ()))) fs)))
          (_ (quote ())))))
        (loop))))))
(for-each (lambda (n) (format #t "~a~%" n)) (delete-duplicates names))
'''
    out = subprocess.run(["guile","--no-auto-compile","-c",scm,path],
                         capture_output=True, text=True)
    names = [l.strip() for l in out.stdout.split("\n") if l.strip()]
    if not names:
        raise SystemExit("lift-fragment: read no definitions from %s\n%s"
                         % (path, out.stderr.strip()))
    return names

def wrap(names, indent):
    return ("\n"+indent).join(textwrap.wrap(" ".join(names), 74,
                                            break_on_hyphens=False,
                                            break_long_words=False))

def block(src, kw):
    """(start, open-paren, close-paren) of a `kw (...)` clause.

    Depth counting must skip what is not structure: `;` comments, "strings",
    and #\\( char literals. The #:re-export blocks here are full of prose like
    `;; kanren-constraints run forms (work with the` — today those comment
    parens happen to balance (25/25 in planner.scm), so naive counting lands on
    the right paren by luck. One unbalanced comment paren and it silently picks
    the wrong terminator, truncating an export list mid-name."""
    i = src.index(kw); j = src.index("(", i); d = 0; k = j
    while k < len(src):
        c = src[k]
        if c == ";":
            k = src.find("\n", k)
            if k < 0: break
        elif c == '"':
            k += 1
            while k < len(src) and src[k] != '"':
                k += 2 if src[k] == "\\" else 1
        elif c == "#" and src[k+1:k+2] == "\\":
            k += 2  # #\( — a character, not a paren
        elif c == "(":
            d += 1
        elif c == ")":
            d -= 1
            if d == 0: return i, j, k
        k += 1
    raise SystemExit("unbalanced " + kw)

def assert_reads(path, what):
    """Refuse to leave a file that no longer parses.

    Every write here is a text edit to a structure, so the reader is the only
    honest acceptance test. Cheap enough to run on every write — the whole tree
    round-trips in under 3 seconds (`make lint-parens`)."""
    import subprocess
    r = subprocess.run(
        ["guile", "--no-auto-compile", "-c",
         '(call-with-input-file (cadr (command-line))'
         '  (lambda (p) (let loop () (unless (eof-object? (read p)) (loop)))))',
         path], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit("lift-fragment: %s left %s unparsable — NOT written:\n%s"
                         % (what, path, r.stderr.strip()))


def sift_block(src, kw, take, indent):
    """Partition a `kw (…)` name list: TAKE(name) decides what leaves.

    Returns (new-src, taken). Token-wise, so a `foo bar ; why` line keeps its
    comment; and the comment is what makes this delicate. The closing paren sits
    at `k`, immediately after the block's last character — so if the last line
    ENDS in a comment, splicing `src[k:]` back on welds the paren into the prose
    and the form never closes. That is not hypothetical: lifting
    solve/recipe-response.scm emptied the block's final line, leaving

        ;; the comparator (solve/recipe-response.scm): character computed from runs))

    which Guile reports 20 lines later as "unexpected end of input", pointing at
    the end of the file rather than at the damage. A comment cannot be the last
    thing before a closing paren, so break the line when one is."""
    i, j, k = block(src, kw)
    out, taken = [], []
    for line in src[j + 1:k].split("\n"):
        code, sep, com = line.partition(";")
        keep = []
        for t in code.split():
            (taken if take(t) else keep).append(t)
        nc = " ".join(keep)
        if nc and com:  out.append(indent + nc + " " + sep + com)
        elif nc:        out.append(indent + nc)
        elif com:       out.append(indent + sep + com)
    body = "\n".join(out).lstrip()
    if ";" in body.rsplit("\n", 1)[-1]:
        body += "\n" + indent
    return src[:j + 1] + body + src[k:], taken


def add_module_header(path, modname, imports, names):
    src = open(path).read()
    # A file that ALREADY carries a define-module gets no second one. This runs
    # before the unbound-variable check, so a lift that fails that check has
    # nonetheless written a header — and re-running it after fixing the imports
    # left narrate.scm with two define-module forms, the live one being whichever
    # came second. Refuse instead: the caller wants the header EDITED, not added.
    if re.search(r'^\(define-module ', src, re.M):
        raise SystemExit(
            "lift-fragment: %s already has a define-module. A previous run wrote "
            "it (the\n  header is added before the unbound check, so a failed "
            "lift still leaves one).\n  Edit that header's #:use-module list "
            "rather than lifting again." % path)
    lines = src.split("\n")
    # after the leading ;;; comment block and any blank lines
    i = 0
    while i < len(lines) and (lines[i].startswith(";") or not lines[i].strip()):
        i += 1
    imp = ("\n  " + "\n  ".join(imports)) if imports else ""
    header = ("(define-module %s%s\n  #:export (%s))\n"
              % (modname, imp, wrap(names, "            ")))
    lines.insert(i, header)
    open(path, "w").write("\n".join(lines))
    assert_reads(path, "add_module_header")

def update_umbrella(umb, modname, provided, include_path, note):
    src = open(umb).read()
    if include_path not in src:
        return False
    # 1. names this module now provides leave #:export ...
    src, moved = sift_block(src, "#:export (", lambda t: t in provided, " " * 12)
    # 2. ... and arrive in #:re-export, which an umbrella may not have yet —
    # federation-a.scm publishes everything through one #:export block and
    # never needed a second. Open one rather than failing on its absence.
    if moved and "#:re-export (" not in src:
        i, j, _k = block(src, "#:export (")
        src = src[:i] + "#:re-export ()\n  " + src[i:]
    if moved:
        i, j, k = block(src, "#:re-export (")
        src = (src[:j+1] + src[j+1:k].rstrip()
               + "\n              ;; " + note + "\n"
               + " "*14 + wrap(sorted(set(moved)), " "*14) + src[k:])
    # 3. import it, inside the define-module so #:re-export sees it
    m = re.search(r"\(define-module \([^)]*\)\n", src)
    src = src[:m.end()] + "  #:use-module %s\n" % modname + src[m.end():]
    # 4. drop the include
    src = src.replace('(include-from-path "%s")\n' % include_path, "", 1)
    open(umb, "w").write(src)
    assert_reads(umb, "update_umbrella")
    return True

def unbound(path):
    """Names the lifted module reaches for and no longer has.

    A fragment that fragment-leaves.scm calls a LEAF needs no sibling FRAGMENT —
    it says nothing about the umbrella's own imports, which the fragment used to
    inherit for free and a module does not. So every lift ends here, and the
    answer is the module's #:use-module list.
    """
    import subprocess, tempfile, os
    # NOT #:output-file "/dev/null" — compile-file writes atomically via
    # mkstemp("<output>.XXXXXX"), so /dev/null asks for /dev/null.XXXXXX in /
    # and dies with "Permission denied" BEFORE emitting a single warning. That
    # failure looks exactly like success here: zero regexp matches, "no unbound
    # variables", a green lift that is not green. Give it a writable path.
    fd, tmp = tempfile.mkstemp(suffix=".go")
    os.close(fd)
    try:
        out = subprocess.run(
            ["guile", "--no-auto-compile", "-L", "module", "-c",
             '(compile-file "%s" #:output-file "%s"'
             ' #:opts (list #:warnings (list (quote unbound-variable))))' % (path, tmp)],
            capture_output=True, text=True)
    finally:
        os.path.exists(tmp) and os.remove(tmp)
    if "unbound variable" not in out.stderr and out.returncode != 0:
        raise SystemExit("lift-fragment: %s does not compile at all:\n%s"
                         % (path, out.stderr.strip()))
    return sorted(set(re.findall(r"unbound variable `([^']+)'", out.stderr)))

KNOWN_HOLLOW = set()   # EMPTY, and it should stay that way.
# It once held 27 names the umbrellas #:export'd and could not deliver —
# covariance-view accessors for a record whose fields had been renamed, and
# federation-config / netter-state / perf-log families whose defining files live
# under deprecated/ and are included only by the deprecated umbrella. All were
# dropped by --prune-hollow. If this set needs an entry again, prefer fixing the
# export.

def exported_but_unbound():
    """Names an umbrella promises and cannot deliver.

    Guile does not complain when #:export names something the module never
    defines — it makes an unbound variable slot and every importer sees the
    name resolve, right up until the first call. That is exactly how a lifted
    module's `define-actor` constructor can vanish and the umbrella still load.
    """
    import subprocess
    # FOUR modules, not two. (localchimera scope live) and (localchimera doors
    # service) re-export planner names too, and this check was blind to them
    # for the whole first half of the lift arc — it reported "clean" while live
    # carried a hollow #:export of holding-capacity, which shadowed the real
    # binding for anyone importing live after planner and took out 9 suites.
    scm = '''
(for-each
 (lambda (m)
   (module-for-each
    (lambda (k v) (unless (variable-bound? v) (format #t "~a~%" k)))
    (module-public-interface (resolve-module m))))
 (list (quote (localchimera boot prelude)) (quote (localchimera deprecated planner))
       (quote (localchimera scope live)) (quote (localchimera doors service))))
'''
    out = subprocess.run(["guile","--no-auto-compile","-L","module","-c",scm],
                         capture_output=True, text=True)
    return sorted(set(l.strip() for l in out.stdout.split("\n") if l.strip())
                  - KNOWN_HOLLOW)

def refuse_if_primitive_loaded(frag, path):
    """A primitive-loaded file may not become a module. `define-module` switches
    the current module for the REST OF THE LOAD and does not switch back, so the
    caller's remaining top-level forms land in the new module — silently, until
    the first name resolves in the wrong namespace. planner/planner.scm:118 does
    exactly this to utils/capacity.scm.

    Lifting such a file means moving its callers off primitive-load first."""
    import subprocess
    base = frag.split("/")[-1]
    # FILE-oriented, not line-oriented. planner/planner.scm:3559 spreads one
    # load over four lines:
    #     (primitive-load
    #       (or (and=> (current-filename) (lambda (f) (string-append (dirname f)
    #                                                  "/recipe-response.scm")))
    # A per-line grep sees `primitive-load` and the filename as unrelated hits
    # and reports the fragment as safe. It is not: lifting it captured the rest
    # of the monolith's load and took 17 suites down.
    files = subprocess.run(
        ["grep", "-rl", "--include=*.scm", "-e", "primitive-load", "-e", r"(load ",
         "module", "tests"], capture_output=True, text=True).stdout.split()
    # The name must sit at a path boundary — "propagation.scm" is not a hit on
    # tests/solve/test-box-propagation.scm — AND it must carry enough of its
    # directory to be the right file. Matching the basename alone refused to lift
    # relational/federation.scm because an attic test loads
    # knowledge/recipes/federation.scm: a different file with the same name, and
    # a refusal that reads exactly like a real one. A load form naming the file
    # with NO directory at all is genuinely ambiguous, so that still counts.
    parent = frag.split("/")[-2] if "/" in frag else None
    qualified = re.compile(r'[/"]' + re.escape(parent + "/" + base)) if parent else None
    # ["/] — the name may be the tail of a (string-append dir "/name.scm"), which
    # is the commonest form of all and which a leading-quote-only pattern misses
    # entirely: legal/gate.scm loaded legal-registry-actor.scm that way and this
    # check waved the lift through into a live capture trap.
    bare = re.compile(r'["/]' + re.escape(base) + r'"')
    def hits(f):
        if bare.search(f):
            return True
        return bool(qualified.search(f)) if qualified else bool(
            re.search(r'[/"]' + re.escape(base), f))
    callers = sorted(p for p in files
                     if not p.endswith(path)
                     and any(hits(f) for f in load_forms(p)))
    if callers:
        raise SystemExit(
            "lift-fragment: %s is primitive-loaded by:\n  %s\n"
            "A define-module in a primitive-loaded file captures the rest of the\n"
            "caller's load. Move those callers to #:use-module first."
            % (frag, "\n  ".join(callers)))

def included_files():
    """Fragments an umbrella still pulls in textually."""
    out = set()
    for umb in UMBRELLAS:
        out |= set(re.findall(r'\(include-from-path "([^"]+)"\)', open(umb).read()))
    return sorted(out)


def _label(umb):
    """Both umbrellas basename to "planner.scm". Report the part that differs —
    the same collision silently overwrote one umbrella's scan results with the
    other's when a shell loop used `basename` for its output filename."""
    return umb.replace("module/localchimera/", "").replace(".scm", "")


def includes_of(umb):
    """Fragments THIS umbrella still pulls in textually."""
    return set(re.findall(r'\(include-from-path "([^"]+)"\)', open(umb).read()))


def code_spans(src):
    """The index ranges of SRC that are CODE — outside `;` comments and
    "strings".

    A load-form scanner must never START a form inside a comment. Guile comments
    do not balance their parens, so a balanced scan begun inside one runs to
    wherever the file happens to close and swallows everything between. That is
    not hypothetical: prelude.scm shows its own bootstrap expression in a `;;;`
    header comment, and one pass replaced the file's whole body — the two
    primitive-loads that give ~40 suites the engine — with a single line."""
    out, i, n, start = [], 0, len(src), 0
    while i < n:
        c = src[i]
        if c == ";":
            out.append((start, i))
            j = src.find("\n", i)
            i = n if j < 0 else j + 1
            start = i
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            i = j + 1
        elif c == "#" and src[i+1:i+2] == "\\":
            i += 3
        else:
            i += 1
    out.append((start, n))
    return out


def in_code(spans, k):
    return any(a <= k < b for a, b in spans)


def load_forms(path):
    """Every balanced `(primitive-load …)` / `(load …)` form in PATH, as text.

    Asking "does this file contain the string primitive-load AND the basename
    somewhere?" is the wrong question and over-reports badly: a COMMENT saying
    "the monolith primitive-loads stocks.scm" enrolled planner.scm as a caller,
    and its (include-from-path "…/demand-priority.scm") then matched the name —
    so a fragment nothing loads was reported as unliftable. Scan for the form
    and look inside it."""
    src = open(path).read()
    spans = code_spans(src)
    out, i, n = [], 0, len(src)
    head = re.compile(r'\((?:primitive-load|load)\s')
    while i < n:
        m = head.search(src, i)
        while m and not in_code(spans, m.start()):    # never begin inside a comment
            m = head.search(src, m.start() + 1)
        if not m:
            break
        k, d = m.start(), 0
        j = k
        while j < n:
            c = src[j]
            if c == ";":
                nl = src.find("\n", j); j = nl if nl >= 0 else n; continue
            if c == '"':
                j += 1
                while j < n and src[j] != '"':
                    j += 2 if src[j] == "\\" else 1
            elif c == "#" and src[j+1:j+2] == "\\":
                j += 2
            elif c == "(":
                d += 1
            elif c == ")":
                d -= 1
                if d == 0:
                    j += 1; break
            j += 1
        out.append(src[k:j])
        i = max(j, k + 1)
    return out


def overrides_for(umb, names):
    """{name: [files]} — names this umbrella both IMPORTS and has redefined by a
    fragment it still includes. Per-umbrella on purpose: collisions() is
    umbrella-agnostic and over-reports, e.g. conformance-helpers is imported
    only by the main umbrella while planning-facts.scm is included only by the
    deprecated one, so its three "collisions" are not conflicts at all."""
    want, hits = set(names), {}
    for rel in sorted(includes_of(umb)):
        p = "module/" + rel
        if not os.path.exists(p):
            continue
        for n in re.findall(r'^\(define(?:\*|-inlinable|-syntax|-public)?\s+\(?([^\s()]+)',
                            open(p).read(), re.M):
            if n in want:
                hits.setdefault(n, []).append(rel)
    return hits


def hollow_in(modname):
    """Names MODNAME's public interface promises but has no binding for."""
    import subprocess
    out = subprocess.run(
        ["guile", "--no-auto-compile", "-L", "module", "-c",
         # ~%% not ~% — this string goes through Python %-formatting first, and
         # a bare ~% makes '%"' an invalid format character.
         '(module-for-each (lambda (k v) (unless (variable-bound? v)'
         ' (format #t "~a~%%" k))) (module-public-interface (resolve-module (quote %s))))'
         % modname],
        capture_output=True, text=True)
    return sorted({l.strip() for l in out.stdout.split("\n") if l.strip()})


def prune_hollow():
    """Drop every name an umbrella #:exports and cannot deliver.

    Guile does not complain about these — it makes an unbound variable slot, and
    every importer resolves the name right up until the first call. Deleting
    them turns a mystery at call time into an ordinary unbound-variable error at
    the point of use, which is strictly better.

    Safe because it only removes names the LIVE module reports as unbound: if a
    definition is restored the name simply stops being hollow and is left alone.
    Names removed here are still available from wherever they are actually
    defined — the deprecated umbrella, or the monolith."""
    for umb, modname in UMBRELLAS.items():
        dead = set(hollow_in(modname))
        if not dead:
            print("  %-22s clean" % _label(umb))
            continue
        src = open(umb).read()
        removed = []
        for kw in ("#:export (", "#:re-export ("):
            if kw not in src:
                continue
            src, gone = sift_block(src, kw, lambda t: t in dead, " " * 12)
            removed += gone
        open(umb, "w").write(src)
        assert_reads(umb, "prune_hollow")
        print("  %-22s dropped %d: %s" % (_label(umb), len(removed),
                                          " ".join(sorted(set(removed)))))


def module_exports(modname):
    import subprocess
    out = subprocess.run(["guile", "--no-auto-compile", "-L", "module", "-c",
                          '(module-for-each (lambda (k v) (format #t "~a " k))'
                          ' (module-public-interface (resolve-module (quote %s))))' % modname],
                         capture_output=True, text=True)
    return out.stdout.split()


def fix_overrides(modname):
    """Make a lifted module's overridden names #:select'd out of each umbrella
    that redefines them, and returned to #:export so the LOCAL definition is
    what that umbrella publishes.

    Hand-rolling this six times is what motivated the command: each time meant
    re-pasting a paren scanner into a throwaway script, and one of those copies
    silently ate a neighbouring block of the #:re-export list."""
    names = module_exports(modname)
    if not names:
        raise SystemExit("fix-overrides: %s exports nothing (is it loadable?)" % modname)
    touched = False
    for umb in UMBRELLAS:
        src = open(umb).read()
        plain = "  #:use-module %s\n" % modname
        if plain not in src:
            continue                      # this umbrella does not import it
        over = overrides_for(umb, names)
        if not over:
            print("  %s: no override conflict" % _label(umb))
            continue
        keep = [n for n in names if n not in over]
        why = sorted({f.split("/")[-1] for fs in over.values() for f in fs})
        src = src.replace(
            plain,
            "  ;; #:select — %s redefine%s %d of these names over lifted facts;\n"
            "  ;; importing them all would make those local definitions dead code.\n"
            "  #:use-module (%s\n                #:select (%s))\n"
            % (", ".join(why), "" if len(why) == 1 else "", len(over),
               modname, wrap(keep, " " * 25)), 1)
        src = _move_names(src, sorted(over), modname)
        open(umb, "w").write(src)
        assert_reads(umb, "fix_overrides")
        print("  %s: %d overridden -> #:export, %d kept"
              % (_label(umb), len(over), len(keep)))
        touched = True
    if not touched:
        print("  nothing to do")


def _move_names(src, names, modname):
    """Take NAMES out of #:re-export and put them into #:export."""
    src, moved = sift_block(src, "#:re-export (", lambda t: t in names, " " * 14)
    if moved:
        i, j, k = block(src, "#:export (")
        src = (src[:j + 1]
               + ";; local definitions that override %s\n            " % modname
               + wrap(sorted(set(moved)), " " * 12) + "\n            "
               + src[j + 1:])
    return src


def collisions(frag, names):
    """Names this fragment defines that a STILL-INCLUDED fragment also defines.

    The override trap: relational/compute.scm deliberately redefines
    routing-geometry with a different signature, relying on include order to
    win. Lift the earlier file and #:re-export publishes the IMPORTED binding —
    the local define becomes dead code, and it surfaces as a runtime type error
    rather than a load error. Nine of these existed; one had a failing test.

    Not fatal: the fix is #:select around the overridden names in the umbrella
    that includes the redefiner, leaving them in #:export. But never lift
    without looking."""
    want, hits = set(names), {}
    for rel in included_files():
        p = "module/" + rel
        if not os.path.exists(p) or p.endswith(frag):
            continue
        for n in re.findall(r'^\(define(?:\*|-inlinable|-syntax|-public)?\s+\(?([^\s()]+)',
                            open(p).read(), re.M):
            if n in want:
                hits.setdefault(n, []).append(rel)
    return hits


def main():
    # --unbound <path>… : just report free names, lift nothing. Use it to
    # re-check an already-lifted module after editing its #:use-module list.
    if sys.argv[1] == "--unbound":
        for p in sys.argv[2:]:
            missing = unbound(p)
            print("%-58s %s" % (p, missing if missing else "clean"))
        return
    # --fix-overrides "(localchimera ddmrp buffers)"
    # Run AFTER a lift whose pre-flight reported an OVERRIDE COLLISION.
    if sys.argv[1] == "--fix-overrides":
        for m in sys.argv[2:]:
            print(m)
            fix_overrides(m)
        return
    # --scan : every unbound name both umbrellas carry. Do this FIRST, before
    # any lifting — it finds in one pass what lifts surface one file at a time.
    # --prune-hollow : drop #:export names the umbrella cannot deliver.
    if sys.argv[1] == "--prune-hollow":
        prune_hollow()
        return
    if sys.argv[1] == "--scan":
        for umb in UMBRELLAS:
            names = unbound(umb)
            print("%-40s %s" % (umb, names if names else "clean"))
        return
    frag, modname = sys.argv[1], sys.argv[2]
    imports = sys.argv[3:]
    path = "module/localchimera/" + frag
    refuse_if_primitive_loaded(frag, path)
    names = defined_names(path)
    print("%s -> %s : %d names" % (frag, modname, len(names)))
    clash = collisions(frag, names)
    if clash:
        print("  OVERRIDE COLLISION (%d) — these names are ALSO defined by a file\n"
              "  the umbrella still includes. #:re-export will publish this module's\n"
              "  version and make the other definition dead code:" % len(clash))
        for n, where in sorted(clash.items()):
            print("    %-34s also in %s" % (n, ", ".join(where)))
    add_module_header(path, modname, imports, names)
    for umb in UMBRELLAS:
        if update_umbrella(umb, modname, set(names), "localchimera/" + frag,
                           "from " + modname):
            print("  updated " + umb)
    hollow = exported_but_unbound()
    if hollow:
        print("  EXPORTED BUT UNBOUND in an umbrella (%d) — a name left in "
              "#:export that the module never got: %s" % (len(hollow), hollow))
    missing = unbound(path)
    if missing:
        print("  STILL UNBOUND (%d) — add the #:use-module that provides each:"
              % len(missing))
        print("    " + wrap(missing, "    "))
    else:
        print("  no unbound variables")


# Guarded so the analysis helpers — load_forms, includes_of, overrides_for,
# hollow_in — can be imported and asked questions without the script running a
# conversion as a side effect of being read.
if __name__ == "__main__":
    main()
