;;; SPDX-License-Identifier: AGPL-3.0-or-later
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
(use-modules ((playnet solve keywords) #:select (%solve-keywords solve-keywords-of solve-keyword-kind pick-keywords caps-under)) ((playnet solve plan) #:select (%plan-from-records)) ((playnet scope live) #:select (scope-world)) ((playnet solve engine) #:select (apply-solve-settings!)) (srfi srfi-1) ((ice-9 session) #:select (procedure-arguments)))
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
           (rs (mock-recipe-store #:recipes recipes #:procs procs #:flows flows #:split? #t))
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
;; the one table (solve/keywords.scm) against the doors' OWN arguments, read off
;; each procedure: no private copy of any list stands here
(define (keywords-taken proc)
  (map car (or (assq-ref (procedure-arguments proc) 'keyword) '())))
(define (set= a b) (and (lset<= eq? a b) (lset<= eq? b a)))
(check "ingest-records! reads exactly the world and the held keywords"
       (set= (keywords-taken ingest-records!) (append (solve-keywords-of 'world) (solve-keywords-of 'held))) #t)
(check "apply-solve-settings! writes exactly the settings"
       (set= (keywords-taken apply-solve-settings!) (solve-keywords-of 'setting)) #t)
(check "plan-from-records takes every keyword of the table, and no other"
       (set= (keywords-taken %plan-from-records)
             (filter-map (lambda (r) (and (memq (cadr r) '(world held setting band solve)) (car r))) %solve-keywords)) #t)
(check "every keyword scope-world takes has a kind, and none is a reader's"
       (every (lambda (k) (and (memq (solve-keyword-kind k) '(world held setting band solve scope)) #t)) (keywords-taken scope-world)) #t)
(check "scope-world takes the scope kind whole, but plan-scope's #:solve-in"
       (every (lambda (k) (and (memq k (keywords-taken scope-world)) #t))
              (delete #:solve-in (solve-keywords-of 'scope))) #t)
(check "%world-keywords is the table's world kind" (equal? %world-keywords (solve-keywords-of 'world)) #t)
(check "the held-back keywords are the table's held kind" (equal? %held-back-world-keywords (solve-keywords-of 'held)) #t)

(display "\n── two cap tables on one world merge by one rule ──\n")
;; a located good both name is the own table's; the other's rows stand for the rest
(check "own wins by exact key, under stands for the goods own leaves unnamed"
       (caps-under '(("Svc|a#p" . 2) ("Svc|b#p" . 5)) '(("Svc|a#p" . 9) ("Svc|c#p" . 1)))
       '(("Svc|a#p" . 2) ("Svc|b#p" . 5) ("Svc|c#p" . 1)))
(check "an empty own table is the other's" (caps-under '() '(("Svc|c#p" . 1))) '(("Svc|c#p" . 1)))
(check "an empty other leaves own" (caps-under '(("Svc|a#p" . 2)) '()) '(("Svc|a#p" . 2)))

(test-summary!)
