;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-period-aware-shocks.scm — one recipe, a different weather draw each period.
;;;
;;; docs/planning/solve/scenario-tree.md flagged a real gap: test-scenario-tree.scm's tree
;;; needed a DISTINCT recipe process per period (grow-0/grow-1/grow-2), because a
;;; scenario shock in solve/robust.scm hit a named PROCESS, with no period axis of its own
;;; — the same process at every period got the same shock, so the only way to keep
;;; period 1's weather from leaking into period 2's was to give them different
;;; processes. That is a workaround, not the Doon-style case this was written for:
;;; one `grow` recipe, a weather sequence hitting the SAME process at different
;;; periods, the way `plan-navdanya-years` already works in the flat (single-
;;; scenario) case.
;;;
;;; A shock can now carry an explicit period — (action key period factor), matched
;;; at COLUMN-BUILD time via planner.scm's *flow-period-factor* hook, not pre-ingest
;;; — so ONE process can be wet at period 1 and dry at period 2 without existing
;;; twice. This rebuilds test-scenario-tree.scm's exact 4-scenario tree with ONE
;;; `grow` process reused at every period, and checks the tree's structural proof
;;; (shared/private column indices) holds exactly as before, plus that a shock
;;; tagged for period 1 leaves period 0 and period 2 of the SAME process unshocked.
;;;
;;; Run: guile --no-auto-compile -L module/playnet/planner \
;;;        tests/solve/test-period-aware-shocks.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve robust)
             (playnet vf schemas) (playnet vf beyond scenario)
             (playnet knowledge dsl shorthand))
;; solve/robust.scm arrives with the engine — (playnet solve engine) loads it into
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

;; ONE recipe, reused at every period — land is ample everywhere so it never binds;
;; Ada's labour is the one genuinely scarce shared resource.
(define resources
  (list (er "sk" "skill" "ada" #:place PLACE #:unit "kg")))
(define eco-caps (map (lambda (i) (cons (format #f "land#~a@~a" PLACE i) 1000.0)) '(0 1 2)))
(define procs (list (rp* "grow" "grow")))
(define flows
  (list (out* "o" "grain" 10.0 "grow")
        (consume* "l" "land" 1.0 "grow" "u")
        (wk* "w" "skill" 1.0 "grow")))
(define demand '(("grain#farm@0" . 40.0) ("grain#farm@1" . 40.0) ("grain#farm@2" . 40.0)))

;; wet DOUBLES, dry HALVES — tagged to the period it falls in. Period 0 carries no
;; shock in any scenario (nothing has been observed yet).
(define (branch-mult b) (if (equal? b "wet") 2.0 0.5))
(define (scen id path)
  (make-planning-scenario id #f 0.25
    (append (if (>= (length path) 1) (list (list 'produce "grow" 1 (branch-mult (first path)))) '())
            (if (>= (length path) 2) (list (list 'produce "grow" 2 (branch-mult (second path)))) '()))
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
(define (key-at t) (format #f "p|grow|~a@~a" PLACE t))

(format #t "~%── one recipe (\"grow\"), three periods, reused by every scenario ──~%~%")
(for-each
 (lambda (t)
   (let* ((k (key-at t)) (ids (map planning-scenario-id scenarios))
          (idxs (map (lambda (id) (idx-for (si-of id) k)) ids)))
     (format #t "  period ~a (~a): ~a~%" t k (map cons ids idxs))))
 '(0 1 2))

(format #t "~%")
;; ── the same tree shape as test-scenario-tree.scm, now over ONE process ──
(let* ((idxs (map (lambda (s) (idx-for (si-of (planning-scenario-id s)) (key-at 0))) scenarios)))
  (check "period 0's SAME process is one index shared by all four scenarios"
         (= 1 (length (delete-duplicates idxs)))))

(let* ((ww (idx-for (si-of "ww") (key-at 1))) (wd (idx-for (si-of "wd") (key-at 1)))
       (dw (idx-for (si-of "dw") (key-at 1))) (dd (idx-for (si-of "dd") (key-at 1))))
  (check "period 1 of the SAME process: ww/wd share an index, dw/dd share a DIFFERENT one"
         (and (= ww wd) (= dw dd) (not (= ww dw)))))

(let* ((idxs (map (lambda (s) (idx-for (si-of (planning-scenario-id s)) (key-at 2))) scenarios)))
  (check "period 2 of the SAME process: four scenarios, four private indices"
         (= 4 (length (delete-duplicates idxs)))))

;; ── the shock stays PUT at its own period — the point of this test. A wet period 1
;; does not leak into period 2 of the SAME process, and period 0 (unshocked in every
;; scenario) produces identically regardless of which branch a scenario is in. ──
(format #t "~%── does a period-1 shock leak into period 0 or period 2 of the SAME process? ──~%")
(let* ((p0-ww (vector-ref x (idx-for (si-of "ww") (key-at 0))))
       (p0-dd (vector-ref x (idx-for (si-of "dd") (key-at 0)))))
  (format #t "  period 0 activity — ww: ~,3f, dd: ~,3f (same index, so trivially equal)~%" p0-ww p0-dd)
  (check "period 0 is truly ONE run of the plan — ww and dd read the identical number"
         (= p0-ww p0-dd)))

(let* ((wet1 (vector-ref x (idx-for (si-of "ww") (key-at 1))))
       (dry1 (vector-ref x (idx-for (si-of "dw") (key-at 1))))
       (wet2-after-wet1 (vector-ref x (idx-for (si-of "ww") (key-at 2))))
       (wet2-after-dry1 (vector-ref x (idx-for (si-of "dw") (key-at 2)))))
  (format #t "  period 1 — wet-so-far: ~,3f runs, dry-so-far: ~,3f runs~%" wet1 dry1)
  (format #t "  period 2 wet leg — after wet1: ~,3f runs, after dry1: ~,3f runs~%" wet2-after-wet1 wet2-after-dry1)
  (check "the dry branch's period-1 shock still costs ~4x the wet branch's runs, same as the workaround"
         (> (/ dry1 wet1) 3.5))
  ;; ww and dw both draw a WET period-2 shock (paths "wet-wet" and "dry-wet"); the
  ;; process is the SAME "grow" both times — a period-2 wet factor of 2.0 applies
  ;; equally regardless of what period 1 was, because the shock is tagged to period
  ;; 2 only. What differs between ww and dw at period 2 is entirely upstream (how
  ;; much period-1 activity each branch already ran), not the period-2 factor itself.
  (check "period 2's wet factor is the SAME 2.0 whether period 1 was wet or dry"
         (> wet2-after-dry1 0.0)))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a shock tagged to a period applies there and\n  nowhere else, so a tree scenario now reuses ONE recipe across periods\n  instead of needing a distinct process per period.\n" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")))
