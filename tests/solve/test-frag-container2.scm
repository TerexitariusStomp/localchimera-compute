;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-frag-container2.scm — container GRANULARITY and CASCADE-awareness.
;;;
;;; Two claims from the container work, here proven:
;;;   (A) GRANULARITY — container-draw is place-specific, so a fragility on the Amazon feels trees
;;;       logged IN the Amazon, and NOT the same-spec trees logged in the Congo. (The comment said it;
;;;       this tests it.)
;;;   (B) CASCADE — a container goes through `propagate`, so coupling it to another agent (drawing
;;;       soil stresses the Amazon) eats the container's headroom, suppressing its contents' draw.
;;;
;;; Run:  guile --no-auto-compile -L module/localchimera/planner tests/solve/test-frag-container2.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve world)
             (localchimera solve compile)
             (localchimera solve solver))

(define tip 50.0)   ; quantile_0.5(40,60)
(define (log-recipe)
  (compile-recipe (list (rp "log" "Log") (rp "ext" "Extract"))
                  (list (out "a1" "timber"  1.0 "log") (wrk "a2" 0.01 "log") (in "a3" "tree" 1.0 "log")
                        (out "b1" "mineral" 1.0 "ext") (wrk "b2" 0.01 "ext") (in "b3" "soil" 1.0 "ext"))))
(define (avail! place spec) (hash-set! *cap* (lg spec (cell place 0)) 10000.0))
(define (want! place good w)
  (hash-set! *demand* (lg good (cell place 0)) 500.0)
  (hash-set! *desire-weight* (lg good (cell place 0)) w))
(define (V idx k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x-of i) 0.0)))
(define x-of #f)
(define (solve!) (call-with-values build-located
                   (lambda (forms labform ncol cols goods raws idx)
                     (set! x-of (car (call-with-values (lambda () (solve-native forms labform (located-warm cols ncol idx))) list)))
                     idx)))

;; ── (A) GRANULARITY: a fragility on the Amazon, trees in BOTH the Amazon and the Congo ──
(declare-world! #:places '(("amazon" 0.0 0.0) ("congo" 0.0 1.0))
                #:templates (log-recipe))
(hash-set! *A* (cell "amazon" 0) 1e7) (hash-set! *A* (cell "congo" 0) 1e7)
(avail! "amazon" "tree") (avail! "congo" "tree")
;; the extraction recipe draws soil too — give it a source at both places, or the
;; draw enters the account as a free raw (PLANNER_RAW_LINT reports it as STARVED,
;; and CI fails on that: the plan's default is fail-closed). (B) avails it the
;; same way; the granularity claim below is about trees either way.
(avail! "amazon" "soil") (avail! "congo" "soil")
(hash-set! *contained* "amazon" '("tree")) (hash-set! *contained* "congo" '("tree"))
(hash-set! *frag-container* "amazon" (list 40.0 60.0 0.5 50.0))   ; fragility on the AMAZON only, tip 50
(want! "amazon" "timber" 1000.0) (want! "congo" "timber" 1000.0)
(define gidx (solve!))
(define amazon-logged (V gidx "p|log|amazon@0"))
(define congo-logged  (V gidx "p|log|congo@0"))

;; ── (B) CASCADE: the Amazon container coupled to soil (drawing soil stresses the Amazon) ──
(define (run-cascade coupled?)
  (declare-world! #:places '(("amazon" 0.0 0.0)) #:templates (log-recipe))
  (hash-set! *A* (cell "amazon" 0) 1e7)
  (avail! "amazon" "tree") (avail! "amazon" "soil")
  (hash-set! *contained* "amazon" '("tree"))
  (hash-set! *frag-container* "amazon" (list 40.0 60.0 0.5 50.0))   ; tip 50
  (when coupled? (hash-set! *eco-couple* "amazon" (list (cons "soil" 0.5))))   ; drawing soil stresses the Amazon
  (want! "amazon" "timber" 1000.0) (want! "amazon" "mineral" 1000.0)
  (let ((idx (solve!))) (list (V idx "p|log|amazon@0") (V idx "p|ext|amazon@0"))))
(define uncoupled (run-cascade #f))
(define coupled   (run-cascade #t))
(define (tree r)(first r))(define (soil r)(second r))

(format #t "~%── container granularity & cascade ──~%")
(format #t "  (A) Amazon fragility (tip ~a): amazon logged ~,2f , congo logged ~,2f~%" tip amazon-logged congo-logged)
(format #t "  (B) coupled to soil: uncoupled tree ~,2f / coupled tree ~,2f (soil ~,2f)~%" (tree uncoupled) (tree coupled) (soil coupled))

(let* ((a1 (< amazon-logged tip))                       ; the Amazon's own logging is held below its tip
       (a2 (> (- tip amazon-logged) 0.1))               ; …eased off before it
       (a3 (> congo-logged (* 2.0 tip)))                ; the CONGO's trees (same spec!) are NOT constrained by the Amazon's fragility
       (b1 (< (tree coupled) tip))                      ; coupled effective pressure stays under the tip
       (b2 (< (tree coupled) (- (tree uncoupled) 1.0))) ; coupling to soil SUPPRESSES the Amazon's logging (soil eats the headroom)
       (ok (and a1 a2 a3 b1 b2)))
  (format #t "~%  [~a] (A) the Amazon fragility holds its own logging below the tip (~,1f < ~a)~%" (if (and a1 a2) "✓" "✗") amazon-logged tip)
  (format #t "  [~a] (A) GRANULAR: the Congo's same-spec trees are unconstrained by it (~,1f ≫ ~a)~%" (if a3 "✓" "✗") congo-logged tip)
  (format #t "  [~a] (B) CASCADE: coupling to soil suppresses the Amazon's logging (~,1f < ~,1f)~%" (if b2 "✓" "✗") (tree coupled) (tree uncoupled))
  (format #t "~%  ~a container barriers are place-specific (granular) and cascade-aware (propagate composes containment with coupling)~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
