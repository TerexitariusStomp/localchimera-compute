#!/usr/bin/env -S guile --no-auto-compile -L module -s
!#
;;; retire-shim.scm — a loader of planner/planner.scm becomes a file that states
;;; what it needs.
;;;
;;;   tools/retire-shim.scm --report <file>…    what each file would import
;;;   tools/retire-shim.scm --apply  <file>…    rewrite it
;;;   tools/retire-shim.scm --needs  <file>     the (use-modules …) alone, for a hand edit
;;;
;;; The shim's surface is a flat union of disjoint interfaces (no two of its
;;; layers export one name — checked): the engine, the compiler, the solver, the
;;; VF records, and the small ones (recipe-response, capacity, stocks,
;;; bioregions, tension-kinds), plus a #:select each of units and clock and the
;;; general-purpose leaks (srfi-1, format, system foreign, rnrs bytevectors).
;;; So "what does this file need from the shim" has a static answer: for each
;;; layer, does the file mention any name the layer exports? Every symbol in the
;;; file counts, quoted data included — an over-approximation, and the safe
;;; direction: a module imported and unused costs nothing, a name used and not
;;; imported is a red in a branch the suite may never take.
;;;
;;; A file that goes on to primitive-load a FRAGMENT (comms/metabolism.scm, a
;;; farm seed, federated-fixtures.scm) is loading text whose free names resolve
;;; through the loader's module — so the fragment's symbols count as the
;;; loader's, transitively.
;;;
;;; The rewrite replaces the load form with one (use-modules …), in place, and
;;; drops the path-finding helper (pdir / sibling / here-rel / root) when the
;;; load was its last reader.

(use-modules (ice-9 match) (ice-9 rdelim) (ice-9 format) (ice-9 regex)
             (srfi srfi-1) (srfi srfi-13))
;; the sources are UTF-8 whatever the locale says (an unset locale reads them as
;; Latin-1 and writes every em-dash back as ???)
(fluid-set! %default-port-encoding "UTF-8")

;;; ── the shim's layers, in the order the use-modules will state them ────────
(define layers
  '((playnet solve engine)
    (playnet solve compile)
    (playnet solve solver)
    (playnet vf schemas)
    (playnet solve recipe-response)
    (playnet vf formulas capacity)
    (playnet vf formulas stocks)
    (playnet knowledge worlds bioregions)
    (playnet vf formulas tension-kinds)))
(define selects
  '(((playnet utils units) convert-unit/strict unit-known? unit->substance convert-unit unit-rate? unit-rate-parts)
    ((playnet utils clock) hhmm->minutes clock-length-minutes clock-overlap-minutes civil->instant instant->civil
                           instant->weekday now timescale instant->unix unix->instant)))
(define general
  '((srfi srfi-1) (ice-9 format) (system foreign) (rnrs bytevectors)))

(define (iface-names m)
  (module-map (lambda (k v) k) (resolve-interface m)))
(define layer-names (map (lambda (m) (cons m (iface-names m))) layers))
(define general-names (map (lambda (m) (cons m (iface-names m))) general))

;;; ── scanning (from tools/sexp.scm) ────────────────────────────────────────
(define (scan-toplevel src)
  (define n (string-length src))
  (let loop ((i 0) (start #f) (depth 0) (acc '()))
    (if (>= i n) (reverse acc)
        (let ((c (string-ref src i)))
          (cond
            ((char=? c #\;)
             (let ((nl (string-index src #\newline i))) (loop (if nl (+ nl 1) n) start depth acc)))
            ((and (char=? c #\#) (< (+ i 1) n) (char=? (string-ref src (+ i 1)) #\|))
             (let scan ((j (+ i 2)))
               (cond ((>= j (- n 1)) (loop n start depth acc))
                     ((and (char=? (string-ref src j) #\|) (char=? (string-ref src (+ j 1)) #\#))
                      (loop (+ j 2) start depth acc))
                     (else (scan (+ j 1))))))
            ((and (char=? c #\#) (< (+ i 1) n) (char=? (string-ref src (+ i 1)) #\\))
             (loop (+ i 3) start depth acc))
            ((char=? c #\")
             (let scan ((j (+ i 1)))
               (cond ((>= j n) (loop n start depth acc))
                     ((char=? (string-ref src j) #\\) (scan (+ j 2)))
                     ((char=? (string-ref src j) #\") (loop (+ j 1) start depth acc))
                     (else (scan (+ j 1))))))
            ((char=? c #\() (loop (+ i 1) (if (= depth 0) i start) (+ depth 1) acc))
            ((char=? c #\))
             (let ((d (- depth 1)))
               (if (= d 0) (loop (+ i 1) #f 0 (cons (cons start (+ i 1)) acc))
                   (loop (+ i 1) start (max d 0) acc))))
            (else (loop (+ i 1) start depth acc)))))))

(define (slurp path) (call-with-input-file path read-string))
(define (read-form text) (catch #t (lambda () (call-with-input-string text read)) (lambda _ #f)))

(define (symbols-in x)
  (let walk ((x x) (acc '()))
    (cond ((symbol? x) (cons x acc))
          ((pair? x) (walk (car x) (walk (cdr x) acc)))
          ((vector? x) (fold walk acc (vector->list x)))
          (else acc))))
(define (strings-in x)
  (let walk ((x x) (acc '()))
    (cond ((string? x) (cons x acc))
          ((pair? x) (walk (car x) (walk (cdr x) acc)))
          ((vector? x) (fold walk acc (vector->list x)))
          (else acc))))

(define (defined-name form)
  (match form
    (((or 'define 'define* 'define-public 'define-syntax 'define-syntax-rule 'define-inlinable) (name . _) . _) name)
    (((or 'define 'define* 'define-public 'define-syntax 'define-syntax-rule 'define-inlinable) name . _) name)
    (('define-record-type name . _) name)
    (('define-values names . _) #f)
    (_ #f)))

;;; ── the load forms ────────────────────────────────────────────────────────
;;; A form loads the shim when its text names planner.scm and its head is a
;;; load; the four-line path search sits INSIDE the load form, so the whole
;;; form goes. A (define pdir …) that only exists to find it goes too — once
;;; nothing else reads pdir.
(define (shim-load? text form)
  (and (pair? form) (memq (car form) '(primitive-load load))
       (or (string-contains text "planner.scm\"")
           (string-contains text "/planner.scm")
           (string-contains text "planner-path")
           ;; the harness went the same way: (playnet test planner prelude)
           (string-contains text "prelude.scm"))))
(define (path-helper? text form)
  (and (pair? form) (eq? (car form) 'define)
       (or (string-contains text "current-filename") (string-contains text "command-line")
           (string-contains text "planner.scm") (string-contains text "(getcwd)"))))

;;; ── fragments a file goes on to load ──────────────────────────────────────
(define (resolve-fragment lit from-dir)
  (let* ((cands (list (string-append from-dir "/" lit)
                      (string-append "module/playnet/test/planner/" lit)
                      (string-append "module/playnet/" lit)
                      (string-append "module/playnet/knowledge/recipes/" lit)
                      (string-append "tests/planner/" lit)
                      (string-append "module/playnet/test/planner/" (basename lit))
                      (string-append "module/playnet/" (basename lit))
                      (string-append "module/playnet/knowledge/recipes/" (basename lit))
                      (string-append "module/playnet/knowledge/" (basename lit))))
         (hit (find file-exists? cands)))
    (and hit (canonicalize-path hit))))

(define (file-symbols path seen)
  "All symbols in PATH plus, transitively, in every .scm fragment it names and
   loads (module files — those with a define-module — stop the walk: their free
   names are their own business)."
  (if (member path seen) '()
      (let* ((src (slurp path))
             (forms (filter-map (lambda (sp) (read-form (substring src (car sp) (cdr sp)))) (scan-toplevel src)))
             (own (append-map symbols-in forms))
             (frags (filter-map
                     (lambda (lit)
                       (and (string-suffix? ".scm" lit)
                            (not (string-contains lit "planner.scm"))
                            (not (string-contains lit "prelude.scm"))
                            (let ((p (resolve-fragment lit (dirname path))))
                              (and p (not (equal? p path))
                                   (not (string-contains (slurp p) "(define-module "))
                                   p))))
                     (append-map strings-in forms))))
        (append own (append-map (lambda (f) (file-symbols f (cons path seen))) frags)))))

;;; ── the import list ───────────────────────────────────────────────────────
(define (needed-imports path)
  (let* ((src (slurp path))
         (spans (scan-toplevel src))
         (forms (filter-map (lambda (sp) (read-form (substring src (car sp) (cdr sp)))) spans))
         (local (filter-map defined-name forms))
         (already (append-map (lambda (f) (if (and (pair? f) (eq? (car f) 'use-modules))
                                             (map (lambda (s) (if (and (pair? s) (pair? (car s))) (car s) s)) (cdr f))
                                             '()))
                              forms))
         (syms (delete-duplicates (lset-difference eq? (file-symbols path '()) local)))
         (uses? (lambda (names) (any (lambda (n) (memq n syms)) names))))
    (append
     (filter-map (lambda (p) (and (uses? (cdr p)) (not (member (car p) already)) (car p))) layer-names)
     (filter-map (lambda (s)
                   (let ((used (filter (lambda (n) (memq n syms)) (cdr s))))
                     (and (pair? used) (not (member (car s) already))
                          `(,(car s) #:select ,used))))
                 selects)
     (filter-map (lambda (p) (and (uses? (cdr p)) (not (member (car p) already)) (car p))) general-names))))

(define (render-use-modules mods)
  (if (null? mods) ""
      (string-append "(use-modules "
                     (string-join (map (lambda (m) (format #f "~s" m)) mods) "\n             ")
                     ")")))

;;; ── the rewrite ───────────────────────────────────────────────────────────
(define (rewrite path apply?)
  (let* ((src (slurp path))
         (spans (scan-toplevel src))
         (tagged (map (lambda (sp) (let ((text (substring src (car sp) (cdr sp))))
                                     (list sp text (read-form text))))
                      spans))
         (loads (filter (lambda (t) (shim-load? (cadr t) (caddr t))) tagged)))
    (cond
     ((null? loads) (format #t "~a: no shim load~%" path))
     (else
      (let* ((mods (let ((m (needed-imports path)))
                     (if (any (lambda (t) (string-contains (cadr t) "prelude.scm")) loads)
                         (cons '(playnet test planner prelude) m)
                         m)))
             ;; drop the load forms; then any path helper nobody reads any more
             (kept (lset-difference eq? tagged loads))
             (rest-text (lambda (ts) (string-join (map cadr ts) "\n")))
             (kept
              (let loop ((kept kept))
                (let ((orphan (find (lambda (t)
                                      (and (path-helper? (cadr t) (caddr t))
                                           (let ((name (defined-name (caddr t))))
                                             (and name
                                                  (not (any (lambda (u) (and (not (eq? u t))
                                                                             (memq name (symbols-in (caddr u)))))
                                                            kept))))))
                                    kept)))
                  (if orphan (loop (delq orphan kept)) kept))))
             (dropped (lset-difference eq? tagged kept))
             (first-drop (car (sort dropped (lambda (a b) (< (car (car a)) (car (car b)))))))
             (out
              (let loop ((ts tagged) (pos 0) (acc '()) (placed #f))
                (cond
                 ((null? ts) (apply string-append (reverse (cons (substring src pos) acc))))
                 (else
                  (let* ((t (car ts)) (sp (car t)) (s (car sp)) (e (cdr sp))
                         (gap (substring src pos s)))
                    (cond
                     ((memq t dropped)
                      (if (eq? t first-drop)
                          (loop (cdr ts) e (cons (render-use-modules mods) (cons gap acc)) #t)
                          ;; swallow the gap before a later dropped form too
                          (loop (cdr ts) e (cons (string-trim-right gap #\newline) acc) placed)))
                     (else (loop (cdr ts) e (cons (substring src s e) (cons gap acc)) placed)))))))))
        (format #t "~a~%  drops ~a form(s); imports ~a~%" path (length dropped)
                (if (null? mods) "(nothing from the shim)" (map (lambda (m) (if (pair? (car m)) (car m) m)) mods)))
        (when apply?
          (call-with-output-file path (lambda (p) (display out p)))))))))

(match (cdr (command-line))
  (("--report" . files) (for-each (lambda (f) (rewrite f #f)) files))
  (("--apply"  . files) (for-each (lambda (f) (rewrite f #t)) files))
  (("--needs" file)     (display (render-use-modules (needed-imports file))) (newline))
  (_ (display "usage: retire-shim.scm --report|--apply <file>…\n" (current-error-port)) (exit 1)))
