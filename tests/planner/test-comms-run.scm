;;; test-comms-run.scm — the full pipeline composed end to end (mock seams, no AI/net).
;;;
;;; Stage 0 (under-satisfied) → Stage 1 (rank by dual × recruitable) → Stage 2
;;; (skeleton) → Stage 3 (fenced restyle) → human gate → publish. Drives it with a
;;; faithful mock completer, a lookup dual-of, a recording publish sink, and a
;;; selective approve? — proving selection, the fence, and the fail-closed gate all
;;; hold through one run.
;;;
;;; Run: guile -L module tests/planner/test-comms-run.scm

(use-modules (playnet test harness) (playnet planner vf schemas) (playnet planner observation states) (srfi srfi-1) (srfi srfi-13))
(define here (dirname (current-filename)))
(define root (dirname (dirname here)))
(define (pl p) (load (string-append root "/module/playnet/planner/" p)))
(use-modules (playnet planner comms plan)) (use-modules (playnet planner comms ai)) (use-modules (playnet planner comms run))

(define* (mk-intent id #:key (action 'produce) (name #f) (classified '()))
  (make-intent #:id id #:action action #:name name #:resource-classified-as classified
               #:in-scope-of '()))
(define* (mk-sat iid desired satisfied #:key (unit "kg"))
  (make-satisfaction-state iid (make-measure desired unit)
                           (make-measure satisfied unit) '() '() #f "plan-1"))

(define i-food  (mk-intent "intent-food" #:name "Community Meal"))          ; short 12, dual 5
(define i-cook  (mk-intent "intent-cook" #:action 'work #:name "cook-hours")); short 2,  dual 2
(define i-hard  (mk-intent "intent-hard" #:action 'use #:name "Aquifer"
                           #:classified '("hard-constraint")))               ; dual 100 but NOT recruitable
(define i-water (mk-intent "intent-water" #:name "Water"))                   ; MET → dropped
(define s-food  (mk-sat "intent-food" 52 40))
(define s-cook  (mk-sat "intent-cook" 8 6 #:unit "hours"))
(define s-hard  (mk-sat "intent-hard" 100 50))
(define s-water (mk-sat "intent-water" 10 10))
(define intents (list i-food i-cook i-hard i-water))
(define sats    (list s-food s-cook s-hard s-water))

(define duals '(("intent-food" . 5.0) ("intent-cook" . 2.0) ("intent-hard" . 100.0)))
(define (dual-of id) (let ((p (assoc id duals))) (and p (cdr p))))
;; a faithful restyle: echo the skeleton with a warm prefix (keeps number + cite)
(define (faithful prompt)
  (let ((i (string-contains prompt "Message:\n")))
    (string-append "🌱 Friends — " (substring prompt (+ i 9)))))
(define sent '())
(define (publish text) (set! sent (cons text sent)) `((ok . #t) (id . "posted")))
(define (approve-food? t) (and (string-contains t "12") #t))   ; approve only the food post

;;; ─── 1. Stage 0→1 selection: ranked, gated by recruitability ───────────────
(display "\n── the run ranks under-satisfied recruitable intents by dual ──\n")
(define recs (run-comms-campaign intents sats #:complete faithful #:dual-of dual-of
                                 #:publish publish #:approve? approve-food?))
(check "met + non-recruitable dropped; recruitable ranked by dual (food>cook)"
       (map car recs) '("intent-food" "intent-cook"))

;;; ─── 2. the entailment fence holds through the whole run ───────────────────
(display "\n── every restyled post still entails its skeleton ──\n")
(check "the food post entails its skeleton (no fabrication end to end)"
       (entails-skeleton? (render-skeleton i-food s-food)
                          (assq-ref (cdr (assoc "intent-food" recs)) 'text)) #t)

;;; ─── 3. the human gate is selective + fail-closed ──────────────────────────
(display "\n── the gate publishes only the approved post ──\n")
(check "the approved (food) post is published"
       (and (assq-ref (cdr (assoc "intent-food" recs)) 'published) #t) #t)
(check "the unapproved (cook) post is HELD, not sent"
       (assq-ref (cdr (assoc "intent-cook" recs)) 'held) #t)
(check "exactly one post reached the publish sink (the approved one)"
       (length sent) 1)
(check "and it carried the shortfall number through to the wire"
       (and (string-contains (car sent) "12") #t) #t)

;;; ─── 4. compose-only (no publish adapter) just composes ────────────────────
(display "\n── with no publish adapter, the run only composes ──\n")
(define composed (run-comms-campaign intents sats #:complete faithful #:dual-of dual-of))
(check "compose-only yields (composed . text) records, nothing sent"
       (and (assq-ref (cdr (assoc "intent-food" composed)) 'composed) #t) #t)

(display "\n")
(test-summary!)
