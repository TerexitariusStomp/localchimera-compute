;;; test-inspection-scheduled.scm — inspection as SCHEDULED labour through build-located (Slice 2).
;;;
;;; Slice 1 (test-inspection-in-plan.scm) proved the convex MECHANISM in solve-native:
;;; a freshness stock decays, a fragility barrier feels reliance beyond it, inspection
;;; priced as scalar labour regenerates it. What it did NOT do is SCHEDULE that labour —
;;; it never asked "who is qualified, where are they, is there time on the one budget".
;;; This is that slice: inspection as a real `work` recipe over real *workers* through
;;; build-located, so the check is routed to a QUALIFIED auditor at the right cell,
;;; spread by EMP, and drawn from the shared SNLT hour budget it competes with
;;; production for. Design: docs/planning/legal/inspection-in-plan.md §"The slices" (2).
;;;
;;; It is the exact Cond|durable twin (planner.scm:922). A durable's CONDITION is a
;;; storable stock: production WEARS it (a `consume`), maintenance labour RESTORES it
;;; (a `produce`). Here the stock is CONFORMANCE FRESHNESS `Verif|ovenconf`: relying on
;;; the oven's conformance to bake WEARS the freshness (bake `consume`s it), and an
;;; inspection `work` recipe consuming an `auditor` skill RESTORES it (inspect
;;; `produce`s it). No new machinery — the wear→maintenance recurrence, keyed to a
;;; conformance claim instead of a bearing.
;;;
;;;   bake:    use baker → 1 bread,  consume R  Verif|ovenconf   (reliance wears freshness)
;;;   inspect: use auditor          → produce ρ Verif|ovenconf   (recert restores it, NO product)
;;;
;;; Because freshness must balance ≥0 and only inspect produces it, the plan MUST
;;; schedule auditor hours in proportion to how hard production leans on the edge — the
;;; reliance is endogenous, read off the production plan, exactly as build-located
;;; schedules any derived-demand labour.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner \
;;;         tests/planner/test-inspection-scheduled.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine))
(define PER '(0 1 2 3))
(define FRESH "Verif|ovenconf")

;; workers replicated across every period at 40h/period; SPECS = ((id (skills…)) …).
(define (crew . specs)
  (append-map (lambda (t) (map (lambda (s) (list (car s) (cadr s) (cell "town" t) 40.0)) specs)) PER))

;; one located multi-period solve. Returns a column-value accessor V plus the met
;; fraction (bread produced ÷ bread demanded).
(define* (run workers demand #:key (R 1.0) (rho 1.0) (init 0.0))
  (declare-world! #:places '(("town" 0.0 0.0)) #:periods PER
                  #:templates
                    (list (list "bake"    (list (cons "bread" 1.0)) (list (cons FRESH R)) 0.0 (list (cons "baker" 1.0)))
                          (list "inspect" (list (cons FRESH rho))   '()                  0.0 (list (cons "auditor" 1.0))))
                  #:workers workers
                  #:storable (list FRESH))   ; freshness carries forward — a stock, like a durable's condition
  (for-each (lambda (pq) (hash-set! *demand* (lg "bread" (cell "town" (car pq))) (cdr pq))) demand)
  (when (> init 0.0)
    (for-each (lambda (t) (hash-set! *init* (lg FRESH (cell "town" t)) init)) PER))
  (call-with-values solve-located
    (lambda (x forms lf cols goods raws idx)
      (define (V k) (let ((i (hash-ref idx k #f))) (if i (vector-ref x i) 0.0)))
      (let ((made (fold + 0.0 (map (lambda (t) (V (string-append "p|bake|" (cell "town" t)))) PER)))
            (want (fold + 0.0 (map cdr demand))))
        (values V (if (> want 0.0) (/ made want) 0.0))))))

(define (aud-hours V who) (fold + 0.0 (map (lambda (t) (V (string-append "w|" who "|auditor|" (cell "town" t)))) PER)))
(define flat (map (lambda (t) (cons t 10.0)) PER))     ; 10 bread/period

(format #t "~%── inspection is SCHEDULED labour: a qualified auditor, sited, timed, on the one budget ──~%")

;; S1 — inspection is scheduled to the qualified auditor. Separate baker + auditor.
(define-values (V1 met1) (run (crew '("Bak" ("baker")) '("Ins" ("auditor"))) flat))
(define a1 (aud-hours V1 "Ins"))
(format #t "  S1 separate crew:  bread met = ~,2f   auditor hours scheduled = ~,1f~%" met1 a1)

;; S2 — endogenous reliance: raise bread demand ⇒ more auditor hours (no formula; build-located derives it).
(define (aud-for d) (call-with-values
  (lambda () (run (crew '("Bak" ("baker")) '("Ins" ("auditor"))) (map (lambda (t) (cons t d)) PER)))
  (lambda (V _m) (aud-hours V "Ins"))))
(define s2 (map aud-for '(5.0 10.0 15.0)))
(format #t "  S2 reliance:  demand/period 5 10 15  →  auditor hours = ~a~%" (map (lambda (a)(format #f "~,1f" a)) s2))

;; S3 — skill-gating: nobody holds `auditor` ⇒ the conformance can't be verified ⇒ production starves.
(define-values (V3 met3) (run (crew '("Bak" ("baker"))) flat))   ; no auditor in the crew
(format #t "  S3 no auditor:  bread met = ~,2f   (freshness cannot be produced ⇒ starves)~%" met3)

;; S4 — EMP spreads the check across qualified auditors.
(define-values (V4 met4) (run (crew '("Bak" ("baker")) '("In1" ("auditor")) '("In2" ("auditor"))) flat))
(define a4a (aud-hours V4 "In1")) (define a4b (aud-hours V4 "In2"))
(format #t "  S4 two auditors:  In1 = ~,1f   In2 = ~,1f hours (EMP-split)~%" a4a a4b)

;; S5 — shared SNLT budget: one worker holds BOTH skills; inspecting IS baking less.
;; demand 30/period, each bread = 1 baker-h + 1 auditor-h = 2h from ONE 40h budget ⇒ ≤20/period.
(define heavy (map (lambda (t) (cons t 30.0)) PER))
(define-values (Vs mets) (run (crew '("Cel" ("baker" "auditor"))) heavy))               ; one dual-skilled worker
(define-values (Vp metp) (run (crew '("Bak" ("baker")) '("Ins" ("auditor"))) heavy))    ; two single-skilled workers
(format #t "  S5 shared budget:  one dual-skilled worker met = ~,2f   vs two separate met = ~,2f~%" mets metp)

(define c1 (and (> met1 0.95) (> a1 0.0)))                      ; scheduled, and demand met
(define c2 (and (< (car s2) (cadr s2)) (< (cadr s2) (caddr s2)))) ; auditor hours rise with reliance
(define c3 (< met3 0.05))                                       ; no auditor ⇒ production starves
(define c4 (< (abs (- a4a a4b)) 0.15))                          ; two auditors carry ≈ equal load
(define c5 (and (< mets 0.75) (> metp 0.95) (< mets (* 0.8 metp))))  ; shared budget binds; separate does not
(for-each (lambda (tag ok) (format #t "  [~a] ~a~%" (if ok "✓" "✗") tag))
          (list "S1 inspection is scheduled to a qualified auditor — sited, timed, on the plan"
                "S2 reliance drives it: more production ⇒ more auditor hours (endogenous, no formula)"
                "S3 only a qualified auditor can verify — no auditor ⇒ the conformance starves production"
                "S4 EMP spreads the check evenly across qualified auditors"
                "S5 one SNLT budget: a dual-skilled worker inspecting IS baking less")
          (list c1 c2 c3 c4 c5))

(define ok (and c1 c2 c3 c4 c5))
(format #t "~%  ~a inspection is first-class SCHEDULED labour: a `work` recipe over real workers, routed to~%" (if ok "✓" "✗"))
(format #t "    the qualified, spread by EMP, drawn from the one budget — the Cond|durable wear→maintenance twin~%~%")
(exit (if ok 0 1))
