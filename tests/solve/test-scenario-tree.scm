;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-scenario-tree.scm — a genuine branch structure, not a single split.
;;;
;;; docs/planning/solve/scenario-tree.md: `plan-robust-from-records` already stitches
;;; scenarios by ONE function (remap), and sharing a column's index already IS
;;; non-anticipativity — no explicit equality constraint is ever built. The old
;;; binary (#:first-stage-procs) can only say "shared by every scenario" or
;;; "private to one", so it can express a SINGLE branch point (plant, THEN the
;;; weather resolves once). It cannot express two: a decision at period 1 that
;;; must be identical for every scenario still sharing period 0's weather, yet
;;; free to differ from scenarios in the OTHER period-0 branch — because in the
;;; binary model a column is either global or fully private, nothing between.
;;;
;;; This proves the middle case exists once scenarios carry a #:path. Four
;;; scenarios, two branch points, three periods:
;;;
;;;             period 0            period 1            period 2
;;;   root ──┬── wet  ──┬── wet  (scenario "ww")
;;;          │          └── dry  (scenario "wd")
;;;          └── dry  ──┬── wet  (scenario "dw")
;;;                     └── dry  (scenario "dd")
;;;
;;; Each period uses its OWN growing process (grow-0/1/2) so a scenario's yield
;;; shock on one period's process cannot leak into another's — the shock DSL
;;; (solve/robust.scm) has no period axis of its own, so this is how a period-specific
;;; weather draw is built from it honestly, without inventing one.
;;;
;;; A period-1 decision must be IDENTICAL for ww/wd (both still only know "wet
;;; so far") and identical for dw/dd, while free to differ BETWEEN those two
;;; pairs — not because the numbers happen to agree, but because ww and wd are
;;; LITERALLY the same activity-vector index. The binary model has no shape
;;; that expresses this; the tree's node-sharing is exactly that shape.
;;;
;;; Run: guile --no-auto-compile -L module/localchimera/planner \
;;;        tests/solve/test-scenario-tree.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve robust)
             (localchimera vf schemas) (localchimera vf beyond scenario)
             (localchimera knowledge dsl shorthand))
;; solve/robust.scm arrives with the engine — (localchimera solve engine) loads it into
;; itself and exports its names, so the load that stood here was a second copy
;; of the same text into this module (retired with the engine-as-module arc).

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define PLACE "farm")
(define win (all-week-window "00:00" "10:00"))
(define agents (list (person* "ada" #:name "Ada" #:place PLACE #:window win)))
(define spatials (list (place* PLACE)))

;; a distinct process per period, so a scenario's yield shock on one cannot
;; leak into another — each consumes its OWN land (ample, never the binding
;; constraint) and the ONE shared, genuinely scarce resource: Ada's labour.
(define (land i) (string-append "land-" (number->string i)))
(define (proc i) (string-append "grow-" (number->string i)))
(define resources
  (list (er "sk" "skill" "ada" #:place PLACE #:qty 1.0 #:unit "kg")))
;; PERIOD-SPECIFIC land: an eco-cap at exactly land-i's OWN period, so grow-i can
;; only run at period i — a resource seeded on the record instead only lands at
;; the FIRST period (ingest-stock! injects onhand once), which would let every
;; process run at period 0 regardless of which period it is meant to represent.
(define eco-caps (map (lambda (i) (cons (format #f "~a#~a@~a" (land i) PLACE i) 1000.0)) '(0 1 2)))
(define procs (map (lambda (i) (rp* (proc i) (proc i))) '(0 1 2)))
(define flows
  (append-map
   (lambda (i)
     (list (out* (format #f "o~a" i) "grain" 10.0 (proc i))
           (consume* (format #f "l~a" i) (land i) 1.0 (proc i) "u")
           (wk* (format #f "w~a" i) "skill" 1.0 (proc i))))
   '(0 1 2)))
;; a real desire at every period, so the plan actually chooses how much to grow
;; rather than the barrier's interior residual doing the "producing"
(define demand '(("grain#farm@0" . 40.0) ("grain#farm@1" . 40.0) ("grain#farm@2" . 40.0)))

;; wet DOUBLES a period's yield, dry HALVES it — applied to the process that
;; owns that period only, so period 0 is unshocked in every scenario (nothing
;; has been observed yet — the root's yield cannot depend on a future draw).
(define (branch-mult b) (if (equal? b "wet") 2.0 0.5))
(define (scen id path)
  (make-planning-scenario id #f 0.25
    (append (if (>= (length path) 1) (list (cons (proc 1) (branch-mult (first path)))) '())
            (if (>= (length path) 2) (list (cons (proc 2) (branch-mult (second path)))) '()))
    (string-join path "-then-") path))

(define scenarios
  (list (scen "ww" (list "wet" "wet")) (scen "wd" (list "wet" "dry"))
        (scen "dw" (list "dry" "wet")) (scen "dd" (list "dry" "dry"))))

(call-with-values
  (lambda () (plan-robust-from-records resources agents spatials procs flows
               #:scenarios scenarios #:demand demand #:periods '(0 1 2)
               #:eco-caps eco-caps #:per-agent? #f))
  (lambda (x fs-global rc-global nglobal nscen cols0 first? C)

(define (idx-for si k)
  (if (first? k) (hash-ref fs-global k) (hash-ref rc-global (cons si k))))
(define SI (let ((h (make-hash-table)))
            (let loop ((ss scenarios) (i 0))
              (unless (null? ss) (hash-set! h (planning-scenario-id (car ss)) i) (loop (cdr ss) (+ i 1))))
            h))
(define (si-of id) (hash-ref SI id))

;; grain a scenario actually gets from period t's process — activity × yield,
;; the yield read straight off the SAME shock the scenario carries (not
;; re-derived from the column key), so this is honest about what it measures.
(define (scen-of id) (find (lambda (s) (equal? (planning-scenario-id s) id)) scenarios))
(define (mult-at id t)
  (let ((sh (find (lambda (kv) (equal? (car kv) (proc t))) (planning-scenario-yield-multipliers (scen-of id)))))
    (if sh (cdr sh) 1.0)))
(define (grain-at id t)
  (* 10.0 (mult-at id t) (vector-ref x (idx-for (si-of id) (format #f "p|~a|~a@~a" (proc t) PLACE t)))))

(format #t "~%── the tree: which scenarios share which period's column ──~%~%")
(for-each
 (lambda (t)
   (let* ((k (format #f "p|~a|~a@~a" (proc t) PLACE t))
          (ids (map planning-scenario-id scenarios))
          (idxs (map (lambda (id) (idx-for (si-of id) k)) ids)))
     (format #t "  period ~a (~a): ~a~%" t k
             (map cons ids idxs))))
 '(0 1 2))

(format #t "~%")
;; ── period 0: the ROOT. Nothing has been observed — every scenario shares. ──
(let* ((k0 (format #f "p|~a|~a@0" (proc 0) PLACE))
       (idxs (map (lambda (s) (idx-for (si-of (planning-scenario-id s)) k0)) scenarios)))
  (check "period 0 is ONE index shared by all four scenarios — the tree's root"
         (= 1 (length (delete-duplicates idxs)))))

;; ── period 1: shared WITHIN a first-branch pair, distinct ACROSS pairs. This
;; is the shape the old binary model has no way to express. ──
(let* ((k1 (format #f "p|~a|~a@1" (proc 1) PLACE))
       (ww (idx-for (si-of "ww") k1)) (wd (idx-for (si-of "wd") k1))
       (dw (idx-for (si-of "dw") k1)) (dd (idx-for (si-of "dd") k1)))
  (check "ww and wd (both wet-so-far) share the LITERAL SAME period-1 index"
         (= ww wd))
  (check "dw and dd (both dry-so-far) share the LITERAL SAME period-1 index"
         (= dw dd))
  (check "…but the wet-branch and dry-branch period-1 indices are DIFFERENT"
         (not (= ww dw)))
  (check "so period 1 uses exactly TWO indices across four scenarios — the middle case"
         (= 2 (length (delete-duplicates (list ww wd dw dd))))))

;; ── period 2: the full path has resolved — every leaf is its own index. ──
(let* ((k2 (format #f "p|~a|~a@2" (proc 2) PLACE))
       (idxs (map (lambda (s) (idx-for (si-of (planning-scenario-id s)) k2)) scenarios)))
  (check "period 2 uses FOUR distinct indices — fully resolved, fully private"
         (= 4 (length (delete-duplicates idxs)))))

;; ── the behaviour this structure buys: the plan responds to the branch it is
;; ACTUALLY in, identically for the two scenarios that cannot yet tell which
;; leaf they are headed to. Desire is a fixed target (40 kg): a low-yield
;; branch cannot simply match a high-yield one, so it takes four times the
;; runs to approach the same want — the value of the information the tree
;; carries is exactly that this cost is paid ONLY in the branch that is
;; actually dry, and paid identically by every scenario still inside it,
;; never guessed at by one that has not yet observed which branch it is in. ──
(format #t "~%── period 1, by branch (x is ONE global vector — ww/wd share every number here) ──~%")
(let* ((k1 (format #f "p|~a|~a@1" (proc 1) PLACE))
       (wet-x (vector-ref x (idx-for (si-of "ww") k1)))
       (dry-x (vector-ref x (idx-for (si-of "dw") k1)))
       (wet-g (grain-at "ww" 1)) (dry-g (grain-at "dw" 1)))
  (format #t "  wet-so-far (ww=wd): ~,3f runs → ~,2f kg (of 40 wanted)~%" wet-x wet-g)
  (format #t "  dry-so-far (dw=dd): ~,3f runs → ~,2f kg (of 40 wanted)~%" dry-x dry-g)
  (check "the dry branch needs roughly FOUR TIMES the runs for the same target"
         (> (/ dry-x wet-x) 3.5))
  (check "both branches still approach the 40 kg they each want"
         (and (> wet-g 35.0) (> dry-g 35.0))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — the tree shares a decision with exactly the~%  scenarios that have not yet diverged from it, a shape the binary~%  first-stage/recourse split cannot express at all.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")))
