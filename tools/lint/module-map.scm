#!/usr/bin/env -S guile --no-auto-compile -s
!#
;;; module-map.scm — where every Scheme module is, what reaches it, and which
;;; imports point up the layers.
;;;
;;;   tools/lint/module-map.scm                 the counts, by class
;;;   tools/lint/module-map.scm --lint          each upward import, each unassigned file; exit 1 for an
;;;                                        upward import tools/lint/layers.baseline does not hold, an
;;;                                        unassigned file or a malformed define-module
;;;   tools/lint/module-map.scm --baseline      record today's upward imports as the baseline, when none is new
;;;   tools/lint/module-map.scm --unreached     modules no entry point reaches directly (markdown)
;;;   tools/lint/module-map.scm --write OUT     the map of module/playnet/ (module/playnet/README.md)
;;;
;;; Every .scm file git knows (tracked, or untracked and not ignored) is READ as
;;; data and its forms walked: a `define-module`, a `use-modules`, an `@`
;;; reference, a `resolve-module` of a quoted name. A module named in a comment
;;; or a docstring is therefore never an import. A module named only in a
;;; string, in the Makefile or in guix.scm is unseen here, so "none found" means
;;; "check by hand".
;;;
;;; Where a file belongs is tools/lint/module-layout.scm, which names the tree to
;;; come (docs/planning/codebase-layout.md): a file is linted at the rank of the
;;; directory it will stand in. The baseline holds the upward imports the moves
;;; have yet to resolve; it only shrinks, and goes when it is empty.

(use-modules (ice-9 rdelim) (ice-9 popen) (ice-9 match) (ice-9 format)
             (srfi srfi-1) (srfi srfi-13))

(define %lib      "module/playnet/")
(define %baseline "tools/lint/layers.baseline")
(define %umbrellas '("module/playnet/boot/prelude.scm"
                     "module/playnet/doors/protocol.scm" "module/playnet/org/factories.scm"))


;;; ── reading the tree ────────────────────────────────────────────────────────

(define (tree-files)
  (let ((p (open-pipe* OPEN_READ "git" "ls-files" "-co" "--exclude-standard" "--" "*.scm")))
    (let loop ((acc '()))
      (let ((l (read-line p)))
        (if (eof-object? l)
            (begin (close-pipe p) (sort acc string<?))
            (loop (if (file-exists? l) (cons l acc) acc)))))))

;; Guix files carry G-expressions; read them as plain forms so the rest of the
;; file is still seen.
(for-each (lambda (c tag)
            (read-hash-extend c (lambda (ch port)
                                  (when (and (char=? ch #\$) (eqv? (peek-char port) #\@)) (read-char port))
                                  (list tag (read port)))))
          '(#\~ #\$ #\+) '(gexp ungexp ungexp-native))

(define %unread (list 'unread))
(define *unread* '())                    ; files with a form that does not read

(define (file-forms path)
  "Every top-level form of PATH that reads; a form that does not read ends the file."
  (call-with-input-file path
    (lambda (port)
      (set-port-encoding! port "UTF-8")
      (let loop ((acc '()))
        (let ((form (catch #t (lambda () (read port)) (lambda _ %unread))))
          (cond ((eof-object? form) (reverse acc))
                ((eq? form %unread) (set! *unread* (cons path *unread*)) (reverse acc))
                (else (loop (cons form acc)))))))))

(define (module-name? x) (and (pair? x) (list? x) (every symbol? x)))
(define (name->string name) (string-join (map symbol->string name) " "))

(define (selected opts)
  "The names an import spec's #:select takes, or #f for the whole module."
  (let ((m (memq #:select opts)))
    (and m (pair? (cdr m)) (list? (cadr m))
         (map (lambda (n) (if (pair? n) (car n) n)) (cadr m)))))

(define (spec->import spec)
  (cond ((module-name? spec) (cons spec #f))
        ((and (pair? spec) (module-name? (car spec)) (list? (cdr spec)))
         (cons (car spec) (selected (cdr spec))))
        (else #f)))

(define (module-options opts)
  (let loop ((o opts) (acc '()))
    (match o
      ((#:use-module spec . rest) (loop rest (let ((i (spec->import spec))) (if i (cons i acc) acc))))
      ((#:autoload (? module-name? m) names . rest) (loop rest (cons (cons m (and (list? names) names)) acc)))
      ((_ . rest) (loop rest acc))
      (_ acc))))

(define (form-imports form)
  "Every import FORM states, at any depth: a list of (MODULE-NAME . NAMES-OR-#f)."
  (let walk ((form form) (acc '()))
    (match form
      (('quote . _) acc)
      (('define-module (? module-name?) . opts) (append (module-options opts) acc))
      (('use-modules . specs) (append (filter-map spec->import (filter pair? specs)) acc))
      (((or '@ '@@) (? module-name? m) (? symbol? n)) (cons (cons m (list n)) acc))
      (((or 'resolve-module 'resolve-interface) ('quote (? module-name? m)) . _) (cons (cons m #f) acc))
      ((a . d) (walk d (walk a acc)))
      (_ acc))))

(define (form-module-name forms)
  (any (lambda (f) (match f (('define-module (? module-name? n) . _) n) (_ #f))) forms))

;; A define-module's options are keyword/value pairs. A spec left after its #:use-module
;; keyword (several specs joined by a rewrite) is a syntax error that only the
;; compile of that one module finds, and a module no suite loads hides it.
(define (stray-option opts)
  (let chk ((o opts))
    (match o
      (() #f)
      (((? keyword?) _ . rest) (chk rest))
      (((? keyword?)) #f)
      (_ (car o)))))

(define (header-line path)
  "What the file says it is: its first ;; comment line, after the dash if it has one."
  (call-with-input-file path
    (lambda (port)
      (set-port-encoding! port "UTF-8")
      (let loop ((n 0))
        (let ((l (read-line port)))
          (cond ((or (eof-object? l) (> n 12)) "")
                ((and (string-prefix? ";;" l) (string-any char-alphabetic? l))
                 (let* ((t (string-trim-both (string-trim l #\;)))
                        (i (string-contains t " — ")))
                   (if i (substring t (+ i 3)) t)))
                (else (loop (+ n 1)))))))))


;;; ── the graph ───────────────────────────────────────────────────────────────

(define *module-of* (make-hash-table))   ; file → module name string
(define *file-of*   (make-hash-table))   ; module name string → file
(define *imports*   (make-hash-table))   ; file → ((file . names) …), the tree's own modules only
(define *malformed* '())                   ; ((file module-name stray-form) …)

(define (kind f)
  (cond ((or (string-prefix? "tests/" f) (string-contains f "/tests/") (string-contains f "/test/")
             (string-suffix? "-test.scm" f))             ; a runnable check kept beside what it checks
         'test)
        ((string-contains f "/bench/") 'bench)
        ((or (string-contains f "/deprecated/") (string-contains f "/attic/")) 'retired)
        ((string-prefix? "module/" f) 'lib)
        (else 'entry)))

(define (load-graph! files)
  (let ((raw (make-hash-table)))
    (for-each
     (lambda (f)
       (let* ((forms (file-forms f)) (name (form-module-name forms)))
         (for-each (lambda (form)
                     (match form
                       (('define-module (? module-name? n) . opts)
                        (let ((bad (stray-option opts)))
                          (when bad (set! *malformed* (cons (list f n bad) *malformed*)))))
                       (_ #t)))
                   forms)
         (when name
           (hash-set! *module-of* f (name->string name))
           (hash-set! *file-of* (name->string name) f))
         (hash-set! raw f (append-map form-imports forms))))
     files)
    (for-each
     (lambda (f)
       (let ((seen (make-hash-table)))
         (hash-set! *imports* f
                    (filter-map
                     (lambda (i)
                       (let ((g (hash-ref *file-of* (name->string (car i)))))
                         (and g (not (string=? g f)) (cons g (cdr i)))))
                     (hash-ref raw f '())))))
     files)))

(define (imports-of f) (hash-ref *imports* f '()))

(define (reach roots stop-at-umbrella?)
  (let ((seen (make-hash-table)))
    (let loop ((stack roots))
      (unless (null? stack)
        (let ((f (car stack)))
          (if (hash-ref seen f)
              (loop (cdr stack))
              (begin
                (hash-set! seen f #t)
                (loop (if (and stop-at-umbrella? (member f %umbrellas))
                          (cdr stack)
                          (append (map car (imports-of f)) (cdr stack)))))))))
    seen))

(define *class* (make-hash-table))       ; lib module file → class symbol
(define *importers* (make-hash-table))   ; file → (lib-count . test-count)

(define (classify! files)
  (define (under . prefixes) (filter (lambda (f) (any (lambda (p) (string-prefix? p f)) prefixes)) files))
  (let* ((entry  (under "server/" "hoot/"))
         (direct (reach entry #t))
         (umbra  (reach entry #f))
         (tools  (reach (under "tools/" "deploy/" "docs/") #t))
         (tests  (reach (filter (lambda (f) (eq? (kind f) 'test)) files) #t))
         (bench  (reach (filter (lambda (f) (eq? (kind f) 'bench)) files) #t)))
    (for-each
     (lambda (f)
       (when (and (eq? (kind f) 'lib) (hash-ref *module-of* f))
         (hash-set! *class* f
                    (cond ((hash-ref direct f) 'live)
                          ((hash-ref umbra f)  'umbrella)
                          ((hash-ref tools f)  'tools)
                          ((hash-ref tests f)  'tests)
                          ((hash-ref bench f)  'bench)
                          (else 'none-found)))))
     files)
    (for-each
     (lambda (f)
       (let ((k (kind f)))
         (for-each (lambda (i)
                     (let ((c (hash-ref *importers* (car i) (cons 0 0))))
                       (hash-set! *importers* (car i)
                                  (case k
                                    ((lib entry) (cons (+ 1 (car c)) (cdr c)))
                                    ((test)      (cons (car c) (+ 1 (cdr c))))
                                    (else c)))))
                   (delete-duplicates (imports-of f) (lambda (a b) (string=? (car a) (car b)))))))
     files)))

(define (class-of f)
  (cond ((hash-ref *class* f) => identity)
        ((hash-ref *module-of* f) 'other)
        (else 'fragment)))

(define (class-label c)
  (case c
    ((live) "live") ((umbrella) "umbrella") ((tools) "tools") ((tests) "tests")
    ((bench) "bench") ((none-found) "none found") ((fragment) "fragment (included)")
    (else "")))


;;; ── the layout ──────────────────────────────────────────────────────────────

(define *stays* '())       ; ((name . rank) …): the directories of the tree to come
(define *from*  '())       ; ((old . new) …): a prefix of today's path → a prefix of its path to come
(define *file*  (make-hash-table))   ; today's path → directory to come, or #f (the file goes)
(define *tier*  (make-hash-table))   ; today's path → its own rank
(define *directories* '()) ; ((name rank what) …), in layout order, each name once

(define (load-layout! path)
  (match (call-with-input-file path read)
    (('layout . entries)
     (for-each
      (lambda (e)
        (match e
          (('stays name rank what)
           (set! *stays* (cons (cons name rank) *stays*))
           (set! *directories* (append *directories* (list (list name rank what)))))
          (('from old new) (set! *from* (cons (cons old new) *from*)))
          (('file p new)   (hash-set! *file* p (list new)))
          (('tier p rank what) (hash-set! *tier* p rank))))
      entries))))

(define (playnet-rel f)
  (and (string-prefix? %lib f) (string-suffix? ".scm" f)
       (substring f (string-length %lib) (- (string-length f) 4))))

(define (layer d) (let ((i (string-index d #\/))) (if i (substring d 0 i) d)))

(define (dir-prefix? d p)
  "Is P the directory D or under it?"
  (or (string=? d p) (string-prefix? (string-append d "/") p)))

(define (longest pred alist)
  "The entry of ALIST with the longest key that PRED accepts, or #f."
  (fold (lambda (e best) (if (and (pred (car e)) (or (not best) (> (string-length (car e)) (string-length (car best))))) e best))
        #f alist))

(define (directory-to-come rel)
  "Where today's file REL (under module/playnet/, no .scm) will stand: a directory,
#f when the file goes, or 'unassigned when no form names it."
  (cond ((hash-ref *file* rel) => car)
        ((longest (lambda (old) (string-prefix? (string-append old "/") rel)) *from*)
         => (lambda (e) (let ((moved (let ((rest (substring rel (+ 1 (string-length (car e))))))
                                       (if (string-null? (cdr e)) rest (string-append (cdr e) "/" rest)))))
                          (let ((i (string-rindex moved #\/))) (if i (substring moved 0 i) 'unassigned)))))
        (else (let ((i (string-rindex rel #\/))) (if i (substring rel 0 i) 'unassigned)))))

(define (rank-of dir)
  "The rank of a directory to come: the longest `stays` that holds it, or 'unassigned."
  (let ((e (longest (lambda (name) (dir-prefix? name dir)) *stays*)))
    (if e (cdr e) 'unassigned)))

(define (target f)
  "Where file F belongs: (DIRECTORY . RANK); (DIRECTORY . #f) when it is not linted; #f when the layout does not say."
  (let ((rel (playnet-rel f)))
    (and rel
         (let ((dir (directory-to-come rel)))
           (cond ((eq? dir 'unassigned) #f)
                 ((not dir) (cons (layer rel) #f))
                 (else (let ((r (rank-of dir)))
                         (and (not (eq? r 'unassigned))
                              (cons dir (hash-ref *tier* rel r))))))))))

(define (upward? from to)
  "Does a file of FROM importing a file of TO point up the layers?"
  (let ((ra (cdr from)) (rb (cdr to)))
    (and ra rb
         (not (string=? (layer (car from)) (layer (car to))))
         (or (> rb ra) (and (= ra 4) (= rb 4))))))

(define (linted? f) (and (playnet-rel f) (memq (kind f) '(lib))))

(define (departures files)
  (append-map
   (lambda (f)
     (let ((from (target f)))
       (if (not (and from (linted? f)))
           '()
           (filter-map (lambda (i)
                         (let ((to (and (linted? (car i)) (target (car i)))))
                           (and to (upward? from to) (list f from (car i) to (cdr i)))))
                       (imports-of f)))))
   files))

(define (unassigned files)
  (filter (lambda (f) (and (linted? f) (not (target f)))) files))


;;; ── the reports ─────────────────────────────────────────────────────────────

(define (report-summary files)
  (let ((count (lambda (c) (hash-count (lambda (k v) (eq? v c)) *class*))))
    (format #t "~a .scm files, ~a modules~%" (length files) (hash-count (const #t) *module-of*))
    (for-each (lambda (c) (format #t "  ~12a ~a~%" (class-label c) (count c)))
              '(live umbrella tools tests bench none-found))
    (for-each (lambda (f) (format #t "  read in part: ~a~%" f)) (reverse *unread*))))

(define (departure-key d)
  "One upward import as the baseline spells it: each file by the directory it will
stand in and its name, so a move to that directory leaves the key as it is."
  (define (key f t) (string-append (car t) "/" (basename f ".scm")))
  (match d ((f from g to names) (string-append (key f from) " → " (key g to)))))

(define (read-baseline)
  (if (file-exists? %baseline)
      (call-with-input-file %baseline
        (lambda (port)
          (let loop ((acc '()))
            (let ((l (read-line port)))
              (cond ((eof-object? l) (reverse acc))
                    ((or (string-null? l) (string-prefix? "#" l)) (loop acc))
                    (else (loop (cons l acc))))))))
      '()))

(define (report-lint files write?)
  (let* ((ds (departures files)) (us (unassigned files))
         (held (read-baseline))
         (new (filter (lambda (d) (not (member (departure-key d) held))) ds))
         (gone (filter (lambda (k) (not (member k (map departure-key ds)))) held)))
    (for-each
     (match-lambda
       ((f from g to names)
        (format #t "  ~a~a ~a → ~a ~a~a~%"
                (if (member (departure-key (list f from g to names)) held) "" "NEW ")
                (car from) (playnet-rel f) (car to) (playnet-rel g)
                (if names (format #f "  ~a" names) "  (the whole module)"))))
     ds)
    (for-each (lambda (f) (format #t "  unassigned: ~a~%" f)) us)
    (for-each (match-lambda ((f n bad) (format #t "  malformed define-module: ~a (~a) has a stray form ~s~%" f (name->string n) bad)))
              (reverse *malformed*))
    (for-each (lambda (k) (format #t "  resolved since the baseline: ~a~%" k)) gone)
    (format #t "lint-layers: ~a upward import~:p (~a in ~a, ~a new, ~a resolved), ~a unassigned file~:p, ~a malformed define-module~:p (tools/lint/module-layout.scm)~%"
            (length ds) (- (length ds) (length new)) %baseline (length new) (length gone)
            (length us) (length *malformed*))
    (cond (write?
           ;; the ratchet is on the count: a rename moves a line, a new import adds one
           (when (and (file-exists? %baseline) (> (length ds) (length held)))
             (format #t "~a upward imports, more than the ~a held: the baseline only shrinks; resolve them first~%" (length ds) (length held))
             (exit 1))
           (call-with-output-file %baseline
             (lambda (p)
               (set-port-encoding! p "UTF-8")
               (format p "# The upward imports the moves of docs/planning/codebase-layout.md §9 have yet to~%")
               (format p "# resolve, one per line as the two files' directories to come; `make lint-layers` fails on one not listed~%")
               (format p "# here, `tools/lint/module-map.scm --baseline` records a shrunken set. Empty, it goes.~%")
               (for-each (lambda (d) (format p "~a~%" (departure-key d))) ds)))
           (format #t "~a: ~a upward import~:p recorded~%" %baseline (length ds)))
          ((not (and (null? new) (null? us) (null? *malformed*))) (exit 1)))))

(define (report-unreached files)
  (for-each
   (lambda (c title)
     (let ((fs (filter (lambda (f) (eq? (hash-ref *class* f) c)) files)))
       (format #t "~%### ~a (~a)~%~%" title (length fs))
       (let ((dirs (delete-duplicates (map dirname fs))))
         (for-each
          (lambda (d)
            (format #t "- `~a/`: ~a~%"
                    (if (string-prefix? %lib d) (substring d (string-length %lib)) d)
                    (string-join (map (lambda (f) (format #f "`~a`" (basename f ".scm")))
                                      (filter (lambda (f) (string=? (dirname f) d)) fs))
                                 ", ")))
          dirs))))
   '(umbrella tests tools bench none-found)
   '("Reached from an entry point only through an umbrella module" "Reached only by tests"
     "Reached only by tools" "Reached only by benchmarks" "No importer found")))

(define (cell s) (string-map (lambda (c) (if (char=? c #\|) #\/ c)) s))
(define (clip s n) (if (> (string-length s) n) (string-append (substring s 0 (- n 1)) "…") s))

(define (report-map files port)
  (define lib (filter (lambda (f) (and (playnet-rel f) (eq? (kind f) 'lib))) files))
  (define (rows-of name)
    ;; the rows of the longest `stays` that holds the file's directory to come, so a
    ;; nested one (keri/first-person) takes its rows from its parent
    (filter (lambda (f)
              (let ((t (target f)))
                (and t (cdr t)
                     (let ((e (longest (lambda (n) (dir-prefix? n (car t))) *stays*)))
                       (and e (string=? (car e) name))))))
            lib))
  (format port "# module/playnet/, by what each file is~%~%")
  (format port "Generated by `make module-map` from `tools/lint/module-layout.scm` and the import~%")
  (format port "graph; edit neither this file nor a row of it by hand. The layout and its~%")
  (format port "reasons are `docs/planning/codebase-layout.md`.~%~%")
  (format port "A file imports from its own directory and from ranks below it; the three~%")
  (format port "rank-4 directories (`solve/`, `plan/`, `observation/`) stand beside each other.~%")
  (format port "`make lint-layers` lists the imports that point upward. Each directory here is~%")
  (format port "where its rows WILL stand; \"Today\" is the file's path under `module/playnet/`~%")
  (format port "until the moves of the layout's §9 bring it there.~%~%")
  (format port "\"Reached\" is what reaches the module: *live* from `server/` or `hoot/`, *umbrella*~%")
  (format port "only through an umbrella module, *tests*, *tools*, *bench*, or *none found*.~%")
  (for-each
   (match-lambda
     ((name rank what)
      (let ((fs (rows-of name)))
        (format port "~%## `~a/`~a~%~%~a.~%"
                name (if rank (format #f " (rank ~a)" rank) "") what)
        (cond ((null? fs) #t)
              ((member name '("bench" "deprecated"))
               (format port "~%~a files.~%" (length fs)))
              (else
               (format port "~%| Today | What it is | Reached | Library importers | Test importers |~%|---|---|---|---|---|~%")
               (for-each
                (lambda (f)
                  (let ((n (hash-ref *importers* f (cons 0 0))))
                    (format port "| `~a.scm` | ~a | ~a | ~a | ~a |~%"
                            (playnet-rel f) (cell (clip (header-line f) 110))
                            (class-label (class-of f)) (car n) (cdr n))))
                fs))))))
   *directories*)
  (let ((going (filter (lambda (f) (let ((e (hash-ref *file* (playnet-rel f)))) (and e (not (car e))))) lib)))
    (unless (null? going)
      (format port "~%## Going~%~%A shim, an alias or a tool the layout retires.~%~%")
      (for-each (lambda (f) (format port "- `~a.scm`~%" (playnet-rel f))) going)))
  (let ((us (unassigned files)))
    (unless (null? us)
      (format port "~%## Unassigned~%~%")
      (for-each (lambda (f) (format port "- `~a`~%" f)) us))))


;;; ── the suites: a suite stands in the directory of the module it pins ───────
;;;
;;; tests/<dir>/ is the directory of the module a suite pins (codebase-layout.md
;;; §8): the highest-ranked playnet module it imports, the first among equals.
;;; The boot composes and pins nothing; the harness is no pin; retired code
;;; stands just above the substrate, so a suite reaching it and nothing above
;;; utils/ pins the retired code. A suite importing no playnet module, and a
;;; file a sibling loads by its own path, stand where they are. The directories
;;; named after a tree outside module/playnet/ hold what pins that tree.

(define %standing '("ux" "browser" "integration" "server" "tools" "interop" "fixtures" "_baseline"))

(define (placement-rank m)
  (match m
    (('playnet (or 'boot 'test) . _) #f)
    (('playnet 'deprecated . _) 1/2)
    (('playnet d . rest)
     (let ((r (rank-of (string-append (symbol->string d)
                                      (if (pair? rest) (string-append "/" (symbol->string (car rest))) "")))))
       (and (number? r) r)))
    (_ #f)))

(define (suite-directory f)
  "The directory suite F pins, or #f when no import of its places it."
  (let loop ((imps (imports-of f)) (best #f) (best-r #f))
    (if (null? imps)
        best
        (let* ((m (caar imps)) (r (placement-rank m)))
          (if (and r (or (not best-r) (> r best-r)))
              (loop (cdr imps) (symbol->string (cadr m)) r)
              (loop (cdr imps) best best-r))))))

(define (loaded-siblings f)
  "The files F loads beside itself: (load (string-append (dirname (current-filename)) \"/NAME\"))."
  (let walk ((form (file-forms f)) (acc '()))
    (match form
      (('string-append ('dirname ('current-filename)) (? string? s) . _)
       (cons (string-append (dirname f) s) acc))
      ((a . d) (walk d (walk a acc)))
      (_ acc))))

(define (suites files)
  "Every tests/<dir>/…/*.scm under a directory the rule governs: (FILE DIR DIR-TO-COME-OR-#f)."
  (let* ((ts (filter (lambda (f) (and (string-prefix? "tests/" f) (>= (length (string-split f #\/)) 3))) files))
         (sibs (append-map loaded-siblings ts)))
    (filter-map
     (lambda (f)
       (let ((dir (cadr (string-split f #\/))))
         (and (not (member dir %standing))
              (list f dir (and (not (member f sibs)) (suite-directory f))))))
     ts)))

(define (report-suites files check?)
  (let* ((rows (suites files))
         (astray (filter (lambda (r) (and (caddr r) (not (string=? (cadr r) (caddr r))))) rows)))
    (if check?
        (begin
          (for-each (lambda (r) (format #t "  ~a stands in tests/~a/~%" (car r) (caddr r))) astray)
          (format #t "check-suites: ~a suite~:p read, ~a astray~%" (length rows) (length astray))
          (exit (if (null? astray) 0 1)))
        (for-each (lambda (r) (format #t "~a\t~a~%" (car r) (or (caddr r) "-"))) rows))))

(define (main args)
  (let ((files (tree-files)))
    (load-graph! files)
    (classify! files)
    (load-layout! "tools/lint/module-layout.scm")
    (match (cdr args)
      (() (report-summary files))
      (("--lint") (report-lint files #f))
      (("--baseline") (report-lint files #t))
      (("--unreached") (report-unreached files))
      (("--suites") (report-suites files #f))
      (("--check-suites") (report-suites files #t))
      (("--write" out) (call-with-output-file out (lambda (p) (set-port-encoding! p "UTF-8") (report-map files p))))
      (_ (format (current-error-port) "usage: module-map.scm [--lint | --baseline | --unreached | --suites | --check-suites | --write OUT]~%") (exit 2)))))

(main (command-line))
