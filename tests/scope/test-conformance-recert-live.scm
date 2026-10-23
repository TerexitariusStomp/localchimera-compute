;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-conformance-recert-live.scm — the recert schedule, read off a LIVE plan.
;;;
;;; The live-wiring of the inspection work (docs/legal/inspection-in-plan.md): a real
;;; plan-scope->alist solve now emits `conformance-recert` — for every skill the plan
;;; actually leans on, the recert interval its OWN load implies. No toy solve: the load
;;; is folded off the `work` commitments the plan schedules, run through
;;; edge-reliance → reliance->valid-until with the GOVERNED confidence-barrier steepness
;;; (conformance-catalogue.scm) as the miss-harm.
;;;
;;; Three skills at three loads on ONE solve ⇒ three cadences: a heavily-leaned skill
;;; recertifies every period, a moderately-leaned one at a longer interval, a barely-
;;; leaned one not at all (#f, below the reliance floor). The recert interval is in
;;; PERIODS (now=0, period-span=1); an issuer adds its own clock.
;;; Pure solver (no ACDCs) ⇒ no blake3.
;;; Run: guile -L module tests/scope/test-conformance-recert-live.scm

(use-modules (playnet test harness) (playnet test scope)
             (playnet vf schemas) (srfi srfi-1)
             (playnet scope live)
             (goblins) (goblins vat) (srfi srfi-1))

;; every day: the plan stands on TODAY (no partition declared), whatever day that is
(define win (all-week-window "09:00" "17:00"))

;; three trades, three loads: bake leans hard on `baker`, wire moderately on
;; `electrician`, tend barely on `gardener`.
(define procs (list (rp* "bake" "Bake") (rp* "wire" "Wire") (rp* "tend" "Tend")))
(define flows (list (out* "o1" "bread"  1.0 "bake") (wk* "w1" "baker"       1.0 "bake")
                    (out* "o2" "wired"  1.0 "wire") (wk* "w2" "electrician" 0.5 "wire")
                    (out* "o3" "tended" 1.0 "tend") (wk* "w3" "gardener"    0.2 "tend")))
(define recipes (list (make-recipe #:id "bake-r" #:name "Bake" #:primary-output "bread" 
                                   #:recipe-processes '() #:recipe-exchanges '())
                      (make-recipe #:id "wire-r" #:name "Wire" #:primary-output "wired" 
                                   #:recipe-processes '() #:recipe-exchanges '())
                      (make-recipe #:id "tend-r" #:name "Tend" #:primary-output "tended"
                                   #:recipe-processes '() #:recipe-exchanges '())))
(define chain `(("bake-r" ,(list-ref procs 0)) ("wire-r" ,(list-ref procs 1)) ("tend-r" ,(list-ref procs 2))))

(define resources (list (er "r-bkr" "baker" "bkr") (er "r-elc" "electrician" "elc") (er "r-grd" "gardener" "grd")))
(define agents (list (make-agent #:id "bkr" #:type 'person #:primary-location "town"
                                 #:classified-as '() #:availability-window win)
                     (make-agent #:id "elc" #:type 'person #:primary-location "town"
                                 #:classified-as '() #:availability-window win)
                     (make-agent #:id "grd" #:type 'person #:primary-location "town"
                                 #:classified-as '() #:availability-window win)))
(define spatials (list (make-spatial-thing #:id "town" #:lat 40.0 #:long -74.0)))

(define vat (spawn-vat #:name "conformance-recert-live"))
(define recert
  (with-vat vat
    (let ((scope (mock-scope #:resources resources #:agents agents #:spatials spatials
                             #:recipes recipes #:flows flows #:chain chain)))
      (let ((plan (plan-scope->alist scope
                    #:demand '(("bread#town@0" . 6.0)     ; baker load ≈ 6h  (heavy)
                               ("wired#town@0" . 6.0)     ; electrician ≈ 3h (moderate)
                               ("tended#town@0" . 2.0))   ; gardener   ≈ 0.4h (barely)
                    ;; recertification is the subject; bread alone feeds no body
                    ;; under its energy ceiling, so reproduction stays off
                    #:reproduce? #f
                    #:backend 'native-c)))
        (list (assq-ref plan 'met) (assq-ref plan 'conformance-recert))))))

(define met  (car recert))
(define sched (cadr recert))
(define (iv skill) (let ((p (assoc skill sched))) (and p (cdr p))))  ; string keys ⇒ assoc, not assq
(define bkr (iv "baker")) (define elc (iv "electrician")) (define grd (iv "gardener"))

(display "\n── conformance-recert read off a live plan-scope solve (interval in periods) ──\n")
(format #t "  met = ~,2f\n" met)
(format #t "  baker       (≈6h load)  → recert every ~a period(s)\n" (if bkr (format #f "~,2f" bkr) "OPEN"))
(format #t "  electrician (≈3h load)  → recert every ~a period(s)\n" (if elc (format #f "~,2f" elc) "OPEN"))
(format #t "  gardener    (≈0.4h load) → recert ~a\n" (if grd (format #f "every ~,2f" grd) "OPEN (below the reliance floor)"))

(check-pred "the plan solves (demand substantially met)" (> met 0.9))
(check-pred "conformance-recert is emitted, one entry per leaned-on skill" (>= (length sched) 3))
(check-pred "the heavily-leaned skill recertifies (a real interval)" (and (number? bkr) (> bkr 0.0)))
(check-pred "heavier reliance ⇒ sooner recert (baker ≤ electrician)"
            (and (number? bkr) (number? elc) (<= bkr elc)))
(check-pred "the barely-leaned skill is OPEN (below the reliance floor)" (not grd))
(check-pred "every interval is a period count or #f (never negative)"
            (every (lambda (kv) (or (not (cdr kv)) (> (cdr kv) 0.0))) sched))

(display "\n")
(test-summary!)
