;;; plan/horizon-gate.scm — the accept gate: how far out a work commitment may reach.
;;;
;;; docs/planning/solve/commitment-horizon.md, "the gate in one clause": a column is
;;; decided exactly when feasibility forces it, and stays recourse otherwise.
;;; This is the check at the plan-store's accept doors (accept-proposal and
;;; promote-to-commitment, planning.scm): a WORK intent's window may BEGIN at
;;; most the recipe chain's own duration L plus a governed margin out —
;;; locking in far beyond what the work itself forces is recourse destroyed
;;; for nothing, and the standing declaration already provides that stability
;;; for free. The reach is to the window's START (its end for an end-only
;;; intent): the shift's own length is never held against it, so the offer
;;; window offers.scm derives from the same ceiling and this gate bound one
;;; interval from either side.
;;;
;;; The reach is measured against the BOOKING-AUGMENTED critical path when
;;; the gate is given an #:observer: each input of each step is a zero-cost
;;; booking edge feeding its own step, B_i read off the input's own
;;; temporal expressions (the earliest feasible day of any resource
;;; conforming to its spec — MIN over resources, the same combine
;;; alternative suppliers get in the federation fold), so
;;;   CP = max(L, max_{j,i} (B_i + L_suffix(j)))
;;; — the tight form; the flat L + max_i B_i over-permits. Without an
;;; observer the ceiling is the chain duration L alone. A FLOOR-DEFENDING
;;; process reads the branch-maxed form: the latest solve caches which
;;; processes hold reproduction floors and each branch's 'duration shocks
;;; on the plan-store's "horizon-derived" meta row, and the ceiling is
;;; max_s CP_s over those branches — the worst defended branch's longer
;;; chain IS the floor's extra reach, derived. The margin past what the
;;; work strictly forces is the accepting agent's OWN booking notice — the
;;; same booking-notice-days read the ceiling already applies to
;;; recipe-input suppliers, applied here to the person: a lumpy
;;; availability window genuinely reaches further than an always-open
;;; one, derived, never a governed constant.
;;;
;;; The gate's verdict protocol (planning.scm's `gate-accept` callback):
;;;   #t          — the accept passes;
;;;   a string    — refused, the string names why (the door raises with it).
;;; Only `work` intents are gated: a transfer, a custody passage, a social
;;; event carry their own semantics and pass untouched.

(define-module (playnet planner plan horizon-gate)
  #:use-module ((playnet planner formulas actions) #:select (drawing-actions))
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner beyond schedules)
  #:use-module ((playnet utils clock) #:select (now civil->instant instant->weekday seconds->days))
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (make-horizon-gate chain-duration-days
            augmented-ceiling-days booking-notice-days
            forcing-ceiling-days horizon-derived-of horizon-ctx))

;; a <duration> in days; #f duration reads 0 (an undurated process forces
;; nothing beyond the margin)
(define (duration->days d)
  (if (not d) 0
      (let ((v (duration-has-numerical-value d))
            (u (duration-has-unit d)))
        (cond ((not (and (number? v) (string? u))) 0)
              ((member u '("day" "days" "d")) v)
              ((member u '("hour" "hours" "h")) (/ v 24))
              ((member u '("minute" "minutes" "min")) (/ v 1440))
              ((member u '("week" "weeks" "w")) (* v 7))
              (else (error "horizon-gate: a duration unit the gate does not know" u))))))

;; the recipe process chain holding PROC-ID, off the recipe store; #f when
;; no registered chain carries it
(define (chain-of recipe-store proc-id)
  (let loop ((rs ($ recipe-store 'all-recipes)))
    (and (pair? rs)
         (let ((chain ($ recipe-store 'get-process-chain (recipe-id (car rs)))))
           (if (and (pair? chain)
                    (any (lambda (p) (equal? proc-id (recipe-process-id p))) chain))
               chain
               (loop (cdr rs)))))))

;; L for the chain holding PROC-ID: the summed durations, in days — CPM's
;; forward pass over a linear chain.
(define (chain-duration-days recipe-store proc-id)
  (and=> (chain-of recipe-store proc-id)
         (lambda (chain)
           (fold (lambda (p acc) (+ acc (duration->days (recipe-process-has-duration p))))
                 0 chain))))

;; ── booking notice: the input's own temporal expressions, read as days ──────

(define %weekday-index
  '((sunday . 0) (monday . 1) (tuesday . 2) (wednesday . 3)
    (thursday . 4) (friday . 5) (saturday . 6)))

(define (booking-notice-days window now)
  "Days from NOW to WINDOW's earliest feasible day: 0 for an always-open
   (or absent, or day-less) window, the distance to the next scheduled
   weekday for a recurring one, the distance to the earliest future date
   for a specific-date one. #f when no future day exists — a window
   nothing satisfies contributes no edge; feasibility is the solve's
   question, the gate only reads how far a booking forces reach."
  (cond
   ((not window) 0)
   ((availability-window? window)
    (let* ((days (append-map day-schedule-days
                             (or (availability-window-day-schedules window) '())))
           (idxs (filter-map (lambda (d) (assq-ref %weekday-index d)) days)))
      (if (null? idxs) 0
          (let ((wd (instant->weekday now)))
            (let loop ((off 0))
              (cond ((> off 6) #f)
                    ((memv (modulo (+ wd off) 7) idxs) off)
                    (else (loop (+ off 1)))))))))
   ((specific-date-window? window)
    (let loop ((ds (or (specific-date-window-specific-dates window) '())) (best #f))
      (if (null? ds) best
          (let* ((i (false-if-exception
                     (civil->instant (string-append (car ds) "T00:00:00"))))
                 (b (and i (seconds->days (- i now)))))
            (loop (cdr ds)
                  (cond ((not b) best)
                        ((< b -1) best)                       ; a past date holds nothing
                        ((not best) (max 0 b))
                        (else (min best (max 0 b)))))))))
   (else 0)))

;; the booking notice for one SPEC: MIN over the observer's resources
;; conforming to it — any one supplier serves, the same combine
;; alternative suppliers get in the federation fold
(define (spec-booking-days observer spec now)
  (let loop ((rs (or (and observer
                          (false-if-exception ($ observer 'all-resources)))
                     '()))
             (best #f))
    (if (null? rs) best
        (let ((r (car rs)))
          (loop (cdr rs)
                (if (equal? spec (economic-resource-conforms-to r))
                    (let ((b (booking-notice-days
                              (economic-resource-availability-window r) now)))
                      (cond ((not b) best)
                            ((not best) b)
                            (else (min best b))))
                    best))))))

;; ── the booking-augmented critical path — the tight ceiling ─────────────────
;; CP = max(L, max_{j,i} (B_i + L_suffix(j))): each consume/use input of
;; step j is a zero-cost booking edge feeding its own step, L_suffix(j)
;; the chain's remaining duration from step j on. Without an OBSERVER
;; (no booking reads) this is exactly the chain duration. #:factors
;; ((proc-id . f) …) reshapes each step's duration — a branch's own
;; 'duration shocks, so the same pass reads any scenario's chain.
(define* (augmented-ceiling-days recipe-store observer proc-id now
                                 #:key (factors '()))
  (and=> (chain-of recipe-store proc-id)
    (lambda (chain)
      (let* ((durs (map (lambda (p)
                          (* (duration->days (recipe-process-has-duration p))
                             (or (assoc-ref factors (recipe-process-id p)) 1.0)))
                        chain))
             (L (apply + durs)))
        (if (not observer) L
            (let loop ((ps chain) (ds durs) (spent 0) (cp L))
              (if (null? ps) cp
                  (let* ((suffix (- L spent))
                         (inputs (or (false-if-exception
                                      (car ($ recipe-store 'flows-for-process
                                              (recipe-process-id (car ps)))))
                                     '()))
                         (cp* (fold (lambda (f acc)
                                      (let ((b (and (memq (recipe-flow-action f) drawing-actions)
                                                    (recipe-flow-resource-conforms-to f)
                                                    (spec-booking-days
                                                     observer
                                                     (recipe-flow-resource-conforms-to f)
                                                     now))))
                                        (if b (max acc (+ b suffix)) acc)))
                                    cp inputs)))
                    (loop (cdr ps) (cdr ds) (+ spent (car ds)) cp*)))))))))

;; ── the forcing ceiling: CP, branch-maxed for a floor-defending process ─────
;; The one number both doors read — the gate adds its margin on top, the
;; offer window subtracts it from the row's end. DERIVED is the latest
;; solve's own read, cached on the plan-store's meta rail
;; (\"horizon-derived\", written by plan-scope):
;;   ((floor-procs . (proc-id …))                    — branches-served, the
;;      current-solution support read: procs whose chains hold a
;;      reproduction floor and whose first-stage activity is live
;;   (duration-factors . ((scenario-id . ((proc . f) …)) …)))
;;      — each branch's 'duration shocks
;; A floor-defending process reads max_s CP_s over the branches — the
;; worst defended branch's longer chain IS the floor's extra reach,
;; derived, never a governed constant. Everything else (and everything
;; before a first solve) reads the here-and-now chain's CP.
;; the one guarded door to the latest solve's cached horizon read — #f
;; when there is no store, no meta rail, or no solve has run yet
(define (horizon-derived-of plan-store)
  (and plan-store
       (false-if-exception ($ plan-store 'get-meta "horizon-derived"))))

;; the reads every ceiling question needs, gathered ONCE: the recipe store
;; (the chain), the observer (booking notices), the latest solve's cached
;; horizon (branches-served, duration factors) and the instant. Built per
;; question, so the derived read is always the latest solve's.
(define (horizon-ctx recipe-store observer plan-store now)
  (list recipe-store observer (horizon-derived-of plan-store) now))
(define (ctx-recipe-store c) (list-ref c 0)) (define (ctx-observer c) (list-ref c 1))
(define (ctx-derived c)      (list-ref c 2)) (define (ctx-now c)      (list-ref c 3))

(define (forcing-ceiling-days ctx proc-id)
  (let* ((rs (ctx-recipe-store ctx)) (obs (ctx-observer ctx))
         (derived (ctx-derived ctx)) (now (ctx-now ctx))
         (base (or (augmented-ceiling-days rs obs proc-id now) 0)))
    (if (and derived (member proc-id (or (assq-ref derived 'floor-procs) '())))
        (fold (lambda (branch cp)
                (max cp (or (augmented-ceiling-days rs obs proc-id now
                                                    #:factors (cdr branch))
                            0)))
              base
              (or (assq-ref derived 'duration-factors) '()))
        base)))

;; the accepting agent's own booking notice: 0 for an agent with no store,
;; no record, or no window — no lumpiness to widen the reach for
(define (agent-booking-days agent-store agent-id now)
  (or (and agent-store agent-id
           (let ((a (false-if-exception ($ agent-store 'get-agent agent-id))))
             (and a (booking-notice-days (agent-availability-window a) now))))
      0))

(define* (make-horizon-gate recipe-store
                            #:key (observer #f) (plan-store #f)
                                  (agent-store #f)
                                  (now-thunk now))
  "The gate closure the plan-store's accept doors call per intent.
   REACH (days from now to the moment the work BEGINS — the window's
   start; its end when the intent states only an end) must stay within
   the forcing ceiling + the accepting agent's own booking notice — both
   derived, no governed constant. Reach is to the start because the gate
   guards against locking in EARLY: a shift already under way, or one
   that starts within the chain's own lead, is exactly the decision
   feasibility forces now, however long the shift runs. The offer window
   (offers.scm) closes at the row's end minus the same ceiling, so the two
   doors bound one interval from either side — [start − ceiling, end −
   ceiling] — and an offer is acceptable from the moment it is presented. The ceiling is the booking-augmented
   critical path when an OBSERVER supplies the booking reads (the bare
   chain duration without one), branch-maxed over each scenario's own
   'duration shocks for a floor-defending process — both read per accept
   off the latest solve's \"horizon-derived\" meta row when a PLAN-STORE
   is given, so the gate follows the solve with no re-install. The margin
   is the intent's own provider's booking-notice-days against their
   availability window (AGENT-STORE), read the instant of the accept — an
   agent with no window or no store contributes 0, the bare forcing
   ceiling. An unwindowed intent passes (epoch-scoped by default); an
   intent naming no process is the compile's concern (accepts->pins),
   never gated into a refusal here."
  (lambda (intent)
    (if (not (eq? (intent-action intent) 'work)) #t
        (let* ((end   (or (intent-has-end intent) (intent-due intent)))
               (start (intent-has-beginning intent))
               ;; the moment the work begins — the start where one is stated,
               ;; else the end (an end-only intent reaches to its end)
               (at    (or start end))
               (at-i  (and at (if (string? at) (civil->instant at) at))))
          (if (not at-i) #t
              (let* ((nowi  (now-thunk))
                     (reach (seconds->days (- at-i nowi)))
                     (proc  (intent-input-of intent))
                     (L     (or (and proc (forcing-ceiling-days
                                           (horizon-ctx recipe-store observer plan-store nowi)
                                           proc))
                                0))
                     ;; the accepting agent's own booking notice — the same
                     ;; read the ceiling applies to recipe-input suppliers,
                     ;; applied here to the person taking the work
                     (margin (agent-booking-days agent-store (intent-provider intent) nowi))
                     (ceiling (+ L margin)))
                (if (<= reach ceiling) #t
                    (format #f "horizon: the work begins ~,2f days out; the work itself forces ~,3f (booking-augmented chain, branch-maxed) + ~,1f (the provider's own booking notice) = ~,2f — hold it as a standing declaration and accept nearer the forcing point"
                            reach L margin ceiling))))))))
