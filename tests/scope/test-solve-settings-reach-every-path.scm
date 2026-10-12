;;; test-solve-settings-reach-every-path.scm — a setting the solve is given is set
;;; for the solve, whichever assembly runs it.
;;;
;;; plan-scope hands the engine the governed dials (pref-bound, emp-rho, kappa,
;;; want-as-cap, stock-draw-hours) and the voice field (voice-tau, its pushes,
;;; hours and scope path). The single deterministic assembly sets them after it
;;; ingests; the robust assembly — the one every live scope takes, a bioregion
;;; or the single "deterministic" future — set none, so a governed dial or the
;;; voice field had no effect on a live solve. Also: the world keywords the
;;; robust assembly forwards to a scenario are every one ingest-records! reads.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/scope/test-solve-settings-reach-every-path.scm

(use-modules (playnet solve world) (playnet solve robust) (playnet solve records) ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness) (playnet test scope)
             (playnet vf schemas) (playnet scope live)
             (goblins) (goblins utils hashmap)
             (srfi srfi-1))

;; a dial is a settings field (engine.scm `define-context settings`): the name is
;; read in the engine's module, as the engine reads it
(define-syntax-rule (engine-var name) (eval 'name (resolve-module '(playnet solve engine))))

(define COMMUNE "ECommune") (define PLACE "town")
(define procs (list (make-recipe-process #:id "bake" #:name "Bake")))
(define flows
  (list (make-recipe-flow #:id "bw" #:action 'work #:resource-conforms-to "skill-bake"
                          #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of "bake")
        (make-recipe-flow #:id "bo" #:action 'produce #:resource-conforms-to "bread"
                          #:resource-quantity (make-measure 10.0 "kg") #:recipe-output-of "bake" #:is-primary #t)))
(define recipes (list (make-recipe #:id "bake-recipe" #:name "Bake" #:primary-output "bread" #:recipe-processes (list "bake"))))
(define spatials (list (make-spatial-thing #:id PLACE #:lat 40.0 #:long -74.0)))
(define agents (list (make-agent #:id "baker" #:type 'person #:name "Baker" #:primary-location PLACE
                                 #:classified-as '() #:availability-window (all-week-window "00:00" "23:59"))))
(define resources
  (list (make-economic-resource #:id "sk-baker" #:conforms-to "skill-bake" #:classified-as '()
          #:accounting-quantity (make-measure 1.0 "kg") #:onhand-quantity (make-measure 1.0 "kg")
          #:current-location PLACE #:primary-accountable "baker")))

(define vat (spawn-vat #:name "settings"))
(define (solve . settings)
  (with-vat vat
    (let* ((obs (spawn ^mock `((all-resources . ,(lambda () resources)) (record-event . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes . ,(lambda () recipes))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                 (cons (filter (lambda (f) (equal? (recipe-flow-recipe-input-of f) pid)) flows)
                                       (filter (lambda (f) (equal? (recipe-flow-recipe-output-of f) pid)) flows)))))))
           (root (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs)))
      (apply plan-scope->alist root #:demand '(("bread#town@0" . 5.0)) #:backend 'native-c #:reproduce? #f settings))))

(display "\n── the governed dials and the voice field reach a live solve ──\n")
(solve #:pref-bound 0.37 #:emp-rho 0.11 #:want-as-cap #f #:stock-draw-hours 3.0
       #:voice-tau 0.4 #:voice-pushes '() #:voice-hours (lambda (part) 0.0) #:scope-path '())
(check "pref-bound is the value the solve was given" (engine-var *pref-bound*) 0.37)
(check "emp-rho is the value the solve was given" (engine-var *emp-rho*) 0.11)
(check "want-as-cap is the value the solve was given" (engine-var *want-as-cap?*) #f)
(check "stock-draw-hours is the value the solve was given" (engine-var *stock-draw-hours*) 3.0)
;; the world is the vat's: the solve ran there, so the voice field is read there (solve/world)
(check "the voice field's tau is the value the solve was given" (with-vat vat *voice-tau*) 0.4)
(check "…and its scope path (here empty: no scope stands behind the push)" (with-vat vat *scope-path*) '())

(display "\n── the world a scenario ingests is the world ingest-records! reads ──\n")
(define world-kws %world-keywords)
(define ingest-kws
  '(#:periods #:movable #:storable #:whole #:proc-frag #:tau #:hold #:demand #:eco-caps #:reserve #:backend
    #:eco-frag #:eco-spec-frag #:eco-budget #:eco-container #:eco-couple #:couplings #:eco-prior #:stock-frag
    #:stock-prices #:agent-hours #:agent-skills #:skill-dynamics #:agent-position #:horizon #:period-spans
    #:refine-periods? #:willing? #:legal-forbids? #:legal-decorate #:per-agent? #:desire-weights #:certificates
    #:arc-table #:arc-topology? #:manners #:never-raw #:raws #:resource-suppliers #:span-of #:live-avail #:composition))
(define held-back %held-back-world-keywords)
(check "every keyword ingest-records! reads reaches a scenario's world, or is held back by name"
       (remove (lambda (k) (or (memq k world-kws) (memq k held-back))) ingest-kws) '())
(check "a held-back keyword is one ingest-records! reads and a scenario does not take"
       (every (lambda (k) (and (memq k ingest-kws) (not (memq k world-kws)))) held-back) #t)

(test-summary!)
