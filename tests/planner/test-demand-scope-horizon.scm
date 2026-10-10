;;; test-demand-scope-horizon.scm — a declared need's OWN [from,until] widens
;;; a live solve's horizon, with no caller passing #:horizon at all — the last
;;; piece of R4 (docs/planning/solve/time-and-uncertainty.md); and a PLACELESS need
;;; still resolves at its citizen's own home, with no caller passing #:home-of
;;; either — the gap named right after R4 landed.
;;;
;;; demand-fold.scm already folds declared needs into demand cells and
;;; projects them onto whatever periods a solve lays out; what was still
;;; missing was deciding HOW MANY periods to lay out in the first place —
;;; demand-horizon (service.scm) only ever read a caller's own, usually empty,
;;; #:demand override. plan-commune-scope now derives it instead, when a
;;; #:demand-scope is given and no caller #:horizon wins outright:
;;; demand-scope-horizon reads every standing need's own until date — real,
;;; independent of any period — and lays out exactly enough days to reach it.
;;;
;;; The proof mirrors reproduction-terminal-test.scm's own discriminator: a
;;; raw ingredient exists ONLY on the LAST day a declared need's own `until`
;;; names, so nothing but a correctly-widened horizon can produce anything at
;;; all — a plan that stayed single-period would see no ingredient, ever, and
;;; report the need entirely unmet.
;;;
;;; The second proof (§2, below) is the same shape for WHERE rather than WHEN:
;;; a need naming no place used to contribute nothing at all, because nobody
;;; supplied plan-commune-scope a #:home-of. federation-home-of (demand-
;;; fold.scm) closes it the same way demand-scope-horizon closed the period
;;; gap — read fresh off the SAME subtree already being walked, no new
;;; channel, no caller obligation: a citizen's home is exactly what their own
;;; agent record already says.
;;;
;;; Run:  guile -L module -L tests tests/planner/test-demand-scope-horizon.scm

(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test scope)) ; mock-scope-root
(use-modules (playnet test harness)
             (playnet vf schemas)
             (playnet scope live)
             (playnet economy socialization) (playnet keri acdc-store)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define COMMUNE "ECommune")
(define PLACE   "town")
(define TODAY   "2026-09-07")           ; a fixed reference date — deterministic,
(define UNTIL   "2026-09-09")           ; not real wall-clock — UNTIL is 2 days out

;; a NEED slot exactly as declare-need builds it (service.scm) — id "need:AID:SPEC",
;; wanted on exactly ONE day (from = until), so a correctly-derived horizon can
;; satisfy it in full and an incorrect one cannot partially fake a pass. LOC
;; #f is the share face's own "anywhere" default — a need that names no place.
(define* (need aid spec qty on-day #:optional (loc PLACE))
  (make-intent
   #:id (string-append "need:" aid ":" spec)
   #:action 'consume #:name spec #:resource-conforms-to spec
   #:resource-quantity (make-measure qty "kg") #:receiver aid
   #:has-beginning on-day #:has-end on-day
   #:at-location loc #:in-scope-of '()))

(define procs (list (make-recipe-process #:id "bake" #:name "Bake")))
(define flows
  (list (make-recipe-flow #:id "bw" #:action 'work #:resource-conforms-to "skill-bake"
                          #:effort-quantity (make-measure 1.0 %effort-unit) #:recipe-input-of "bake")
        (make-recipe-flow #:id "bi" #:action 'consume #:resource-conforms-to "wheat"
                          #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "bake")
        (make-recipe-flow #:id "bo" #:action 'produce #:resource-conforms-to "bread"
                          #:resource-quantity (make-measure 10.0 "kg") #:recipe-output-of "bake"
                          #:is-primary #t)))
(define recipes (list (make-recipe #:id "bake-recipe" #:name "Bake" #:primary-output "bread"
                                   #:recipe-processes (list "bake"))))
(define spatials (list (make-spatial-thing #:id PLACE #:lat 40.0 #:long -74.0)))
(define win (all-week-window "00:00" "23:59"))
;; Ada declares needs but never grows anything — her only role is to HAVE a
;; registered home, the fact §2 proves a placeless need resolves through.
(define agents (list (make-agent #:id "baker" #:type 'person #:name "Baker" #:primary-location PLACE
                                 #:classified-as '() #:availability-window win)
                     (make-agent #:id "ada" #:type 'person #:name "Ada" #:primary-location PLACE
                                 #:classified-as '() #:availability-window win)))
;; Baker HOLDS skill-bake — the credential a `work` flow gates on, the same
;; shape every other skilled-labour test seeds (an owned economic-resource
;; whose spec is the skill, primary-accountable = the worker).
(define resources
  (list (make-economic-resource #:id "sk-baker" #:conforms-to "skill-bake" #:classified-as '()
          #:accounting-quantity (make-measure 1.0 "kg") #:onhand-quantity (make-measure 1.0 "kg") #:current-location PLACE #:primary-accountable "baker")))

(define vat (spawn-vat #:name "demand-scope-horizon"))

;; WHEAT exists only on UNTIL's own day (an eco-cap keyed to whichever period the
;; derived horizon puts it at) — genuinely un-producible unless the horizon reaches
;; that day at all, the discriminator no assertion-of-a-number could fake.
(define (run n-days-cap)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (obs (spawn ^mock `((all-resources . ,(lambda () resources))
                               (record-event  . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents    . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes       . ,(lambda () recipes))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                 (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                               (equal? (recipe-flow-recipe-output-of f) pid)))
                                               flows) '()))))))
           ;; a plan-store of one standing need and no accepts: the horizon is
           ;; derived from the intent alone, nothing is pinned
           (ps  (spawn ^mock `((all-intents     . ,(lambda () (list (need "ada" "bread" 20.0 UNTIL))))
                               (all-commitments . ,(lambda () '())))))
           (root  (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps))
           (scope (spawn ^mock `((scope-root . ,(lambda () root)) (members . ,(lambda () (hashmap))))))
           ;; wheat explicitly ZERO-capped at every period 0..2 a correctly-derived
           ;; 3-day horizon actually lays out, positive ONLY at n-days-cap — an
           ;; eco-cap keyed to a period that does not exist in the solve is simply
           ;; absent from it (no column to attach to), which would leave wheat
           ;; UNBOUNDED there under the engine's own "no cap entry anywhere ⇒
           ;; unlimited" convention — the explicit zeros are what turn "wrong
           ;; period" into "genuinely unreachable" rather than "accidentally free".
           (caps (map (lambda (t) (cons (format #f "wheat#~a@~a" PLACE t) (if (= t n-days-cap) 100.0 0.0)))
                      '(0 1 2)))
           (result (plan-commune-scope root store COMMUNE
                     #:demand-scope scope #:today TODAY
                     #:eco-caps caps
                     ;; the horizon is the subject; bread alone feeds no body
                     ;; under its energy ceiling, so reproduction stays off
                     #:reproduce? #f
                     #:backend 'native-c)))
      (assq-ref result 'met))))

;; the need's OWN until (2026-09-09) is 2 days past TODAY (2026-09-07), so a
;; correctly-derived horizon reaches period 2 — matching wheat's own cap.
(define met-reached  (run 2))    ; wheat sits where the derived horizon actually goes
(define met-missed   (run 9))    ; wheat sits past ANY horizon a 2-day-out need would derive

(format #t "~%── a declared need's own until, with no caller #:horizon at all ──~%~%")
(format #t "  wheat at the day the horizon SHOULD reach : demand met ~,2f~%" (or met-reached 0.0))
(format #t "  wheat past any day it derives             : demand met ~,2f~%" (or met-missed 0.0))

(check "the horizon reaches the need's OWN until date — bread gets baked there"
       (> met-reached 0.5))
(check "…and it reaches no further than that — wheat placed past it is genuinely unreachable"
       (< met-missed 0.1))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. A placeless need resolves at its citizen's own home, no caller #:home-of
;;; ════════════════════════════════════════════════════════════════════════════

;; ada's need names NO place (loc = #f, the share face's "anywhere"). Single
;; period, wheat ample there — the only question is whether the need reaches
;; the solve AT ALL, which it can only do by resolving through ada's own
;; agent-primary-location (federation-home-of's whole job).
(define (run-placeless)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (obs (spawn ^mock `((all-resources . ,(lambda () resources))
                               (record-event  . ,(lambda (e) "ok")))))
           (as  (spawn ^mock `((all-agents    . ,(lambda () agents)))))
           (sts (spawn ^mock `((all-locations . ,(lambda () spatials)))))
           (rs  (spawn ^mock `((all-recipes       . ,(lambda () recipes))
                               (get-process-chain . ,(lambda (rid) procs))
                               (flows-for-process . ,(lambda (pid)
                                 (cons (filter (lambda (f) (or (equal? (recipe-flow-recipe-input-of f) pid)
                                                               (equal? (recipe-flow-recipe-output-of f) pid)))
                                               flows) '()))))))
           ;; a plan-store of one standing need and no accepts: the horizon is
           ;; derived from the intent alone, nothing is pinned
           (ps  (spawn ^mock `((all-intents     . ,(lambda () (list (need "ada" "bread" 20.0 #f #f))))
                               (all-commitments . ,(lambda () '())))))
           (root  (mock-scope-root #:observer obs #:agent-store as #:spatial-thing-store sts #:recipe-store rs #:plan-store ps))
           (scope (spawn ^mock `((scope-root . ,(lambda () root)) (members . ,(lambda () (hashmap))))))
           (result (plan-commune-scope root store COMMUNE
                     #:demand-scope scope #:periods '(0)
                     #:eco-caps (list (cons (format #f "wheat#~a@0" PLACE) 100.0))
                     #:backend 'native-c)))
      (assq-ref result 'met))))

(define met-placeless (run-placeless))

(format #t "~%── a placeless need, no caller #:home-of at all ──~%~%")
(format #t "  demand met, resolved at ada's own registered home : ~,2f~%" (or met-placeless 0.0))

(check "a need naming no place still reaches the solve — federation-home-of found it"
       (> met-placeless 0.5))

(test-summary!)
