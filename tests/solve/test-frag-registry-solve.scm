;;; test-frag-registry-solve.scm — the governance actor → the solver, end to end.
;;;
;;; Closes two gaps at once: (4) the eco-policy comes from the SPAWNED tension-registry ACTOR (not the
;;; pure catalogue->policy function), and (5) it is fed through plan-from-records (the record→plan entry
;;; live.scm uses), whose eco-* keyword pass-throughs were wired but never exercised.
;;;
;;; The climate constraint the actor custodies is a CASCADE: the federation draws co2, and the SAME draw
;;; stresses two driven states — warming (°C) and ocean-acidification (Ω) — through the coupling graph.
;;; Ocean acidification is the tighter wall (tip 0.05 Ω ⇒ co2 < ~185 GtCO2). This test proves the
;;; spawned actor hands the solver that cascade and that it binds a real plan through plan-from-records.
;;;
;;; Run:  guile --no-auto-compile -L module/playnet/planner tests/solve/test-frag-registry-solve.scm

(use-modules (srfi srfi-1) (ice-9 format)
             (goblins) (goblins actor-lib methods) (goblins actor-lib facet))
(use-modules (playnet solve engine)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))
(use-modules (playnet knowledge catalogues tension-registry)    ; brings goblins + ^tension-registry
             (playnet knowledge catalogues eco))      ; *planetary-catalogue* — the catalogue's own module

(define ocean-co2-tip (/ 0.05 0.00027))  ; ocean acidification — the binding cascaded wall ≈ 185.2 GtCO2
;; spawn the registry ACTOR and ask IT for the eco-policy (the governance→solver boundary)
(define policy
  (let ((vat (spawn-vat)))
    (with-vat vat
      (let ((reg (spawn-named "reg" ^tension-registry '(des bar qc frag) *planetary-catalogue*)))
        ($ reg 'eco-policy)))))                       ; (eco-spec-frag eco-budget eco-couple)

;; recipe: emit co2 → widget (co2 cascades to warming + ocean acidification via the coupling graph)
(define procs (list (rp* "emit" "Emit")))
(define flows (list (out* "f1" "widget" 1.0 "emit")
                    (wk* "f2" "emit-skill" 0.001 "emit")
                    (consume* "f3" "co2" 1.0 "emit")))
(define win (all-week-window))
(define agents (list (person* "worker" #:name "Worker" #:window win)))
(define spatials (list (place* "town")))

(define-values (intents coms material fill cols x idx ntot report)
  (plan-from-records '() agents spatials procs flows
    #:demand (list (cons "widget#town@0" 500.0)) #:periods '(0)
    #:agent-skills (lambda (a) '("emit-skill"))
    #:desire-weights (list (cons "widget#town@0" 5000.0))
    #:eco-spec-frag (car policy) #:eco-budget (cadr policy) #:eco-couple (caddr policy)))
(define co2 (let ((i (hash-ref idx "p|emit|town@0" #f))) (if i (vector-ref x i) 0.0)))

(format #t "~%── registry actor → plan-from-records → solve (climate cascade) ──~%")
(format #t "  actor eco-policy budgets:   ~a~%" (map car (cadr policy)))
(format #t "  actor eco-policy couplings: ~a~%" (map (lambda (c) (cons (car c) (cadr c))) (caddr policy)))
(format #t "  co2 drawn: ~,2f   (ocean-acidification wall ≈ ~,1f GtCO2)~%" co2 ocean-co2-tip)

(let* ((c1 (and (assoc "warming" (cadr policy))               ; the actor's policy carries the climate cascade
                (assoc "ocean-acidification" (cadr policy))))
       (c2 (assoc "warming" (caddr policy)))                  ; …driven by the co2 coupling
       (c3 (< co2 ocean-co2-tip))                             ; the tighter wall binds through plan-from-records
       (c4 (> (- ocean-co2-tip co2) 0.3))                     ; …and EASES off before it (soft: a hard bar would sit at ~185.19)
       (c5 (> co2 10.0))                                      ; substantial draw (a limit, not a shutoff)
       (ok (and c1 c2 c3 c4 c5)))
  (format #t "~%  [~a] the spawned actor's eco-policy carries the climate cascade (warming + ocean-acidification)~%" (if c1 "✓" "✗"))
  (format #t "  [~a] …with the co2 → warming/ocean couplings~%" (if c2 "✓" "✗"))
  (format #t "  [~a] it binds through plan-from-records: co2 ~,1f eases below the ocean wall ~,1f~%" (if (and c3 c4) "✓" "✗") co2 ocean-co2-tip)
  (format #t "  [~a] substantial draw — a limit, not a shutoff~%" (if c5 "✓" "✗"))
  (format #t "~%  ~a governance actor → eco-policy → plan-from-records → solve: the cascade, exercised~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
