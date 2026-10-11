;;; economy/recipe-standing.scm — the response's live adapter: observer → runs → curve.
;;;
;;; solve/recipe-response.scm (planner) is the pure half of metabolism step 1: runs
;;; in, response curve out, read and never stored. This is the other half —
;;; assembling a RUN from what the observer already indexes:
;;;
;;;   claim        the commitment an event `fulfills` (recipe coefficients ×
;;;                solve level) — COMMITMENT-OF is injected: the plan-store
;;;                holds a work commitment's content, the observer the
;;;                target of a material row registered where its events land
;;;   observation  ($ obs 'events-for-process pid) — the run's actual flows,
;;;                invariants already enforced at write time
;;;   stress       what reached the run of its own inputs, and what the
;;;                day's sky did to its output (solve/recipe-response.scm
;;;                run-reading, shocks.scm flows-stress) — the reading a
;;;                future takes of its own shocks, so a record and a future
;;;                meet on the recipe
;;;
;;; Injection is the discipline every view here follows (home-of,
;;; place-scope-of, reach-of): the adapter reads the observer and judges
;;; nothing. `scope-standing` hands out ONE record per recipe — its acts, its
;;; flows, its curves, and beside them the rows, the yield and the runs a
;;; face shows — so the solve and the face read the one record: every future
;;; reads the curves at the stress it delivers (planner/scope/live.scm plan-scope,
;;; solve/recipe-response.scm response-shocks), and the wire reads the rest.

(define-module (playnet economy recipe-standing)
  #:use-module (srfi srfi-1)
  #:use-module (playnet economy socialization)
  #:use-module (playnet credentials declarations)
  #:use-module (playnet keri acdc)
  #:use-module (playnet knowledge recipes store)
  #:use-module (playnet solve recipe-response)
  #:use-module (playnet vf schemas)
  #:use-module (playnet observation states)
  #:use-module (playnet vf beyond scenario)
  #:use-module (srfi srfi-1)
  #:use-module (playnet solve recipe-response)
  #:use-module ((playnet observation observer) #:select (counted-quantity))
  #:use-module ((playnet vf formulas shocks) #:select (scenario-shocks flows-stress))
  #:use-module (goblins)
  #:export (observer-runs realized-scenario live-regime-of scope-standing)
  #:re-export (standing-position))

;; An event that fulfills nothing claims nothing (`unplanned-events` reports
;; it apart) — the one gate the runs and the weather read through, so the
;; two can never disagree about which events count as a recipe's own activity.
(define (claiming-events obs pid)
  (filter economic-event-fulfills
          (if (procedure? obs) (obs 'events-for-process pid) ($ obs 'events-for-process pid))))
;; OBS is the ^observer, or a procedure of the same (msg key) shape — the run
;; table `scope-standing` assembles, so one gate serves both.

(define (claim-tuples obs pids commitment-of)
  "The (action spec intended realized) observation tuples of PIDS' fulfilling
   events — `calibrate-shocks`' own shape — one per commitment fulfilled, its
   events' quantities summed: a claim met by several events (a draw from
   several lots) is one claim. COMMITMENT-OF answers (action spec intended);
   where it leaves the action or the spec unsaid, the event's own stand.
   INTENDED is the claim's measure, and each event answers it in that unit by
   the observer's own rule (`counted-quantity`: hours for a target of time,
   the count otherwise, converted; an event in a unit that does not convert
   answers nothing) — or a bare number, read against the event's figure as
   it stands. One
   reader for the runs (`observer-runs`) and the weather
   (`realized-scenario`), so both read one record."
  (append-map
   (lambda (pid)
     (let ((order '()) (by-claim (make-hash-table)))
       (for-each
        (lambda (e)
          (let* ((cid (economic-event-fulfills e))
                 (c (and commitment-of (commitment-of cid)))
                 (target (and c (caddr c)))
                 (q (cond ((not c) #f)
                          ((measure? target) (counted-quantity e (measure-has-unit target)))
                          (else (or (and=> (economic-event-resource-quantity e) measure-has-numerical-value)
                                    (and=> (economic-event-effort-quantity e) measure-has-numerical-value))))))
            (when (and c q)
              (let ((held (hash-ref by-claim cid #f)))
                (if held
                    (hash-set! by-claim cid (list (car held) (cadr held) (caddr held) (+ (cadddr held) q)))
                    (begin
                      (set! order (cons cid order))
                      (hash-set! by-claim cid
                                 (list (or (car c) (economic-event-action e))
                                       (or (cadr c) (economic-event-resource-conforms-to e))
                                       (if (measure? target) (measure-has-numerical-value target) target)
                                       q))))))))
        (claiming-events obs pid))
       (map (lambda (cid) (hash-ref by-claim cid)) (reverse order))))
   pids))

(define* (observer-runs obs pids #:key commitment-of
                        ;; the sky a run lived under, as a scenario; calm
                        ;; where none is handed in
                        (sky-of (lambda (pid) #f))
                        ;; the act a run is a run OF, as the shock matcher
                        ;; names it; the run's own id where none is handed in
                        (proc-of (lambda (pid) pid)))
  "One RUN per process-id — (pid capture stresses tuples) — from the
   observer's own record, read by `run-reading` (solve/recipe-response.scm): what
   the run made against what its weather allowed (the regret denominator,
   metabolism principle 3: a drought that cut the possible to 50% makes
   5-of-10 a full capture), filed under the flow that weather pressed
   hardest, with the claims behind it. A run with no claim on either side
   of its process yields no row."
  (filter-map
   (lambda (pid)
     (let* ((raw (claim-tuples obs (list pid) commitment-of))
            (sky (sky-of pid))
            (reading (and (pair? raw)
                          (run-reading (proc-of pid) raw (if sky (scenario-shocks sky) '())))))
       (and reading (pair? (caddr reading)) (cons pid reading))))
   pids))

;; ── The realized scenario falls out of the observer ─────────────────────────
;;
;; A scenario is "a forecast of FULFILLMENT RATIOS, per (action, spec) intent
;; — the same unit the Observer measures ex-post" (solve/robust.scm). So the weather
;; a period actually delivered is not a record anyone has to write: it is the
;; period's fulfilling events read as ratios, as a scenario — and
;; `flows-factor` (shocks.scm) reads it exactly as it reads a forecast.
;;
;; Which statistic of the ratios is the one difference from `calibrate-shocks`.
;; A FORECAST reads their mean — what to expect. A JUDGMENT reads their BEST:
;; the regret denominator is "best achievable in its circumstances"
;; (metabolism principle 3), and ex post that is what the best run under that
;; sky achieved. The mean would let one collapsing neighbour drag the sky
;; down and flatter everyone else as antifragile.
;;
;; And a recipe is not its own ONLY weather. Its runs are in the sky like
;; everyone's — the best run of the day may well be its own, and then it
;; reads 100%, robust, as it should — but a key that no OTHER run witnessed
;; is no sky at all (EXCEPT names the recipe's runs): alone on its key,
;; capture and stress would be one number read twice, so the key is left out
;; and the run reads calm there — one stress level, a record still forming.
(define* (realized-scenario obs pids #:key commitment-of (except '()) (id "realized"))
  "The scenario PIDS' runs lived through: per (action, spec), the BEST
   realized/intended ratio among their fulfilling events, as a
   planning-scenario with probability 1 — what the world let the best of
   them do, not what was forecast. A channel only the runs in EXCEPT
   contributed to is left out: no other witness, no sky."
  (let ((best (make-hash-table)) (witnessed (make-hash-table)))
    (for-each (lambda (pid)
                (for-each (lambda (o)
                            (when (> (list-ref o 2) 0.0)
                              (let* ((k (cons (list-ref o 0) (list-ref o 1)))
                                     (r (/ (list-ref o 3) (list-ref o 2))))
                                (hash-set! best k (max r (hash-ref best k 0.0)))
                                (unless (member pid except) (hash-set! witnessed k #t)))))
                          (claim-tuples obs (list pid) commitment-of)))
              pids)
    (make-planning-scenario id #f 1.0
                            (sort (filter-map (lambda (kr) (and (hash-ref witnessed (car kr) #f)
                                                                (list (caar kr) (cdar kr) (cdr kr))))
                                              (hash-map->list cons best))
                                  (lambda (a b) (string<? (format #f "~a~a" (car a) (cadr a))
                                                          (format #f "~a~a" (car b) (cadr b)))))
                            #f)))

;; ── The regime, read as a witnessed fact (metabolism step 2) ─────────────────
;;
;; recipe-response-report reads a level's witnesses at their mean, and
;; attaches a fitted statistic, only under 'statistical; this is where
;; 'statistical comes FROM: a live regime claim stating thin tails AND a
;; stable process for the domain. Absent, lapsed, revoked, or claiming
;; anything else — including honest ignorance — the answer is
;; 'probability-free, because the errors are not symmetric.
(define* (live-regime-of store domain-spec #:optional (now #f))
  (if (any (lambda (c)
             (and (equal? domain-spec (cred-claim c 'domain-spec))
                  (eq? 'thin   (cred-claim c 'tails))
                  (eq? 'stable (cred-claim c 'process))))
           (%live-by-schema store *schema-playnet-regime-claim* now))
      'statistical
      'probability-free))

;; ── The scope's standing, as the gateway injects it ─────────────────────────
;;
;; What a solve takes from the record is each recipe's RESPONSE — the curve
;; of what it captured at each stress delivered — and every future of the
;; solve reads that curve at the stress it delivers to the recipe's own
;; flows: the recipe yields there what its record says it delivers there. The
;; plan leans on a recipe in proportion, future by future, and floors hold in
;; each (docs/playnet.typ, "Character is a measurement"). Where a floor is
;; defended without a forecast, needs rest on a recipe by how far its record
;; reaches beside the others for its output (solve/recipe-response.scm
;; margin-shocks).
;;
;; Everything is in the scope's own stores, read through the doors every
;; other view here uses, at the live record's own grain:
;;
;;   a RUN       is (recipe-process, day). A fulfilling work event carries
;;               `input-of` = the recipe-process id (do-record-effort:
;;               commitment-input-of) and its own instant, so the observer's
;;               events-for-process, split by the event's day, are the runs.
;;   the CLAIM   is the plan-store's commitment (get-commitment): action,
;;               spec, quantity — recipe coefficients × solve level.
;;   the SKY     of a day is `realized-scenario` over that day's runs, the
;;               recipe's own among them, a key only it witnessed left out.
;;
;; Pure reads, no writes.

(define (%event-day e)
  (let ((t (economic-event-has-point-in-time e)))
    (and (string? t) (>= (string-length t) 10) (substring t 0 10))))

(define* (scope-standing root #:key (regime 'probability-free)
                         (regime-of (lambda (rid) regime))
                         (observed '()))
  "The scope's standing, read once:
     ((responses . records)  ONE record per recipe in ROOT's recipe-store,
                             run or not, an alist:
                               id      the recipe
                               procs   its acts
                               flows   its own flows ((action proc spec) …)
                               output  the spec it exists to make
                               curves  ((channel . curve) …) — what a solve
                                       reads, '() before any run
                               rows    recipe-response-report's profile,
                                       one row per channel
                               yield   what it delivers of what the last
                                       day's weather allowed, in [0, 1]: the
                                       curves read at the stress live right
                                       now, the reading a future at that
                                       stress takes
                               runs    the observer log the curves trace
                                       back to, one (day capture stresses
                                       tuples) row per run
      (observed . rows))     the scope's standing contrary observations
                             ((process action nominal reading) …), laid over
                             every future of its solve
   The solve and the face read the one record. REGIME-OF (recipe-id →
   regime) reads the regime per recipe — the gateway hands `live-regime-of`
   over the credential store, so a scope's own claim on a recipe's domain is
   what licenses the mean and the statistic."
  (let* ((rs  ($ root 'recipe-store))
         (obs ($ root 'observer))
         (ps  ($ root 'plan-store))
         ;; the claim an event fulfils: the plan-store's commitment (work,
         ;; a journey), else the target the observer holds for it — a plan's
         ;; material row, a recorded flow, registered where its events land;
         ;; there the event's own action and spec are the claim's
         (commitment-of
          (lambda (cid)
            (let ((c (and cid ($ ps 'get-commitment cid))))
              ;; the claim's MEASURE, as the observer states a target
              ;; (register-commitment): the count where one is stated, else
              ;; the effort
              (if c
                  (let ((m (or (commitment-resource-quantity c) (commitment-effort-quantity c))))
                    (and m (list (commitment-action c) (commitment-resource-conforms-to c) m)))
                  (let ((fs (and cid ($ obs 'get-fulfillment cid))))
                    (and fs (list #f #f (fulfillment-state-total-committed fs))))))))
         ;; recipe → its acts (the chain gather-recipes walks), acts → recipe
         (recipes ($ rs 'all-recipes))
         (procs-of (lambda (r) (map recipe-process-id ($ rs 'get-process-chain (recipe-id r)))))
         (flows-of (lambda (procs)
                     (append-map (lambda (proc)
                                   (let ((io ($ rs 'flows-for-process proc)))
                                     (map (lambda (f) (list (recipe-flow-action f) proc
                                                            (recipe-flow-resource-conforms-to f)))
                                          (append (car io) (cdr io)))))
                                 procs)))
         (recipe-of (let ((h (make-hash-table)))
                      (for-each (lambda (r) (for-each (lambda (p) (hash-set! h p (recipe-id r))) (procs-of r)))
                                recipes)
                      (lambda (proc) (hash-ref h proc #f))))
         ;; the runs: (proc . day) ← every claiming event, by its day
         (runs (make-hash-table))
         (days '()))
    (for-each
     (lambda (r)
       (for-each
        (lambda (proc)
          (let* ((events (claiming-events obs proc))
                 (by-id (let ((h (make-hash-table)))
                          (for-each (lambda (e) (hash-set! h (economic-event-id e) e)) events)
                          h))
                 ;; a correction is no act of its own: it amends the run of
                 ;; the event it corrects, whatever day the books were told
                 (run-day (lambda (e)
                            (let loop ((e e))
                              (let ((orig (and (economic-event-corrects e)
                                               (hash-ref by-id (economic-event-corrects e) #f))))
                                (if orig (loop orig) (%event-day e)))))))
            (for-each (lambda (e)
                        (let ((d (run-day e)))
                          (when d
                            (hash-set! runs (cons proc d) (cons e (hash-ref runs (cons proc d) '())))
                            (unless (member d days) (set! days (cons d days))))))
                      events)))
        (procs-of r)))
     recipes)
    (let* ((last-day (and (pair? days) (last (sort days string<?))))
           ;; a pseudo-observer over the run table, so the weather and the
           ;; runs read (proc . day) keys through the one gate
           (run-obs (lambda (msg key)
                      (if (eq? msg 'events-for-process) (hash-ref runs key '()) '())))
           (all-keys (hash-map->list (lambda (k v) k) runs))
           (run-keys-of-day (lambda (d) (filter (lambda (k) (equal? (cdr k) d)) all-keys)))
           (sky-of (lambda (d except-recipe)
                     (realized-scenario run-obs (run-keys-of-day d) #:commitment-of commitment-of
                                        #:except (filter (lambda (k) (equal? (recipe-of (car k)) except-recipe))
                                                         (run-keys-of-day d))))))
      `((responses
         . ,(map
             (lambda (r)
               (let* ((rid (recipe-id r)) (procs (procs-of r)) (flows (flows-of procs))
                      (runs (map (lambda (run) (cons (cdar run) (cdr run)))     ; (day capture stresses tuples)
                                 (observer-runs run-obs (filter (lambda (k) (member (car k) procs)) all-keys)
                                                #:commitment-of commitment-of
                                                #:sky-of (lambda (k) (sky-of (cdr k) rid))
                                                #:proc-of car)))
                      (rows (recipe-response-report
                             (map (lambda (run) (cons (cadr run) (caddr run))) runs)
                             #:regime (regime-of rid)))
                      (curves (map (lambda (row) (cons (assq-ref row 'channel) (assq-ref row 'curve))) rows)))
                 `((id . ,rid) (procs . ,procs) (flows . ,flows) (output . ,(recipe-deliverable rs r))
                   (curves . ,curves) (rows . ,rows)
                   (yield . ,(if last-day
                                 (response-factor curves
                                                  (flows-stress (scenario-shocks (sky-of last-day rid)) flows))
                                 1.0))
                   (runs . ,runs))))
             recipes))
        (observed . ,observed)))))
