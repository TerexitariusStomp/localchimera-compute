;;; offers.scm — the doors people use on the commitment arc: present an
;;; offer, accept one, price the standing accepts, check a never-held accept,
;;; meter the drift (docs/planning/solve/commitment-horizon.md). Every door here
;;; reads THROUGH the solve (plan-scope->alist) and the read side in
;;; accepts.scm; every number left is a question's own parameter —
;;; max-open on present-offers, gamma on accept-regret — never a standing
;;; governed row.
;;;
;;;   offer-work             a solve row → a directed offer, window = the forcing point
;;;   present-offers         a solve's suggestions → offers, nearest-forcing-first
;;;   accept-regret          the pins' cost: pinned vs freed, per branch, tilted
;;;   make-fresh-check       a never-held accept's trial solve, at the door
;;;   commitment-drift       κ against the lapse and release rates — one read, one clock

(define-module (playnet doors offers)
  #:use-module (playnet vf formulas flows)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (ice-9 format)
  #:use-module (playnet vf schemas)            ; the VF records
  #:use-module ((playnet utils clock) #:select (now instant->unix days->seconds))
  #:use-module ((playnet scope live)
                #:select (plan-scope->plan work-intent clear-intents-by-prefix!))
  #:use-module ((playnet solve engine) #:select (time->period))
  #:use-module ((playnet plan accepts)
                #:select (open-work-offers scope-part scope-horizon-ctx ->epoch *support-tolerance*))
  #:use-module ((playnet plan store)
                #:select (rate-of standing-accepts how-commitments-end window-close-epoch))
  #:use-module ((playnet plan horizon-gate) #:select (forcing-ceiling-days))
  #:use-module ((playnet solve externality) #:select (paired-difference))
  #:use-module ((playnet utils keywords) #:select (kw-without))
  #:export (offer-work present-offers accept-regret entropic-tilt
            plan-hours settled-solves
            suggested-provider-rank persist-open-shifts!
            make-fresh-check commitment-drift)
  #:use-module ((playnet utils catch) #:select (catch* throw* with-throw-handler*)))

(define* (offer-work scope-root wc agent-id #:key (max-open 12) (admit? #f))
  "Present one solve-emitted work row WC (a `work` alist as
   plan-results->alist shapes them: input-of, effort, when, until,
   at-location, conforms-to) to AGENT-ID as a directed VF offer with an
   acceptance window — the presentation door of the bounded rung. The
   published intent carries the row's own terms, so the hold and — on
   accept — the pin land on the very column the solve emitted.

   The window closes at the FORCING POINT and nowhere else: the row's
   own end minus the forcing ceiling — the booking-augmented chain,
   branch-maxed for a floor-defending process, the very number the gate
   reads through the latest solve's \"horizon-derived\" cache. Urgency
   comes only from a real window: a row with no end never expires
   (epoch-scoped, as at the gate), and a row whose forcing point has
   already passed is refused outright. MAX-OPEN bounds simultaneously
   open holds — past it the offer is REFUSED loudly, because holding
   everything is soft mass-freezing; it is this door's own presentation
   parameter, not a standing choice. Re-offering the same slot to the
   same person replaces the standing offer. Returns the proposal id."
  (let* ((ps   ($ scope-root 'plan-store))
         (open (open-work-offers scope-root)))
    (let* ((proc  (row-input-of wc))
           (hours (row-effort wc))
           (iid   (string-append "offer:" agent-id ":" (or proc "?")
                                 "@" (or (row-when wc) "")))
           (pid   (string-append "prop-" iid))
           (fresh? (not (any (lambda (row) (equal? pid (proposal-id (car row)))) open)))
           (nowu  (instant->unix (now))))
      ;; a refusal is this door's own TYPED statement ('offer-refused kind
      ;; msg …): the presentation walk skips a refused row and only a
      ;; refused row — any other raise is a fault and propagates, so a
      ;; plan-store failure can never read as "no offers today"
      (when (and fresh? (>= (length open) max-open))
        (throw* 'offer-refused 'max-open
               "the bound on open holds is reached — accept or lapse standing offers first"
               max-open))
      (unless (and proc hours (> hours 0))
        (throw* 'offer-refused 'malformed-row
               "the row needs a process and positive hours" wc))
      ;; the steward gate: ADMIT? (agent proc → bool), when given, is the
      ;; owners' rule over who may draw the means this process uses — a
      ;; person it refuses is never offered the row (nobody's attention on a
      ;; hold they cannot take up), and the accept door asks it again
      (unless (or (not admit?) (admit? agent-id proc))
        (throw* 'offer-refused 'may-not-steward
               "the means this process draws are lent to others" agent-id proc))
      (let* (;; the forcing point: the row's own end minus the forcing
             ;; ceiling — the same booking-augmented, branch-maxed number
             ;; the gate reads, so window and gate can never disagree
             (until (row-until wc))
             (u* (and until (window-closes-at until)))
             (cp (and u* (or (false-if-exception
                              (forcing-ceiling-days (scope-horizon-ctx scope-root nowu) proc))
                             0)))
             (deadline (and u* (- u* (days->seconds (or cp 0))))))
        (when (and deadline (< deadline nowu))
          (throw* 'offer-refused 'window-passed
                 "the forcing point has passed — the chain no longer fits before the row's end"
                 proc until))
        ;; a fresh offer is a fresh hold: the intent re-adds UNFINISHED, so the
        ;; offer is open again by state; an earlier lapse stays a dated fact
        ;; on the rail — it happened, and the drift read counts it
        (when ($ ps 'get-intent iid) ($ ps 'remove-intent iid))
        ;; provider open — filled at accept
        ($ ps 'add-intent
           (work-intent iid #:name (assq-ref wc 'name)
                        #:proc proc #:skill (row-spec wc)
                        #:hours hours
                        #:from (row-when wc) #:until until
                        #:place (row-place wc)))
        ($ ps 'add-proposal
           (make-proposal #:id pid #:name (or (assq-ref wc 'name) "work offer") #:has-end (and deadline
                                  (number->string (inexact->exact (floor deadline)))) #:created (now) #:purpose 'offer
                          #:publishes (list iid) #:proposed-to (list agent-id)))
        pid))))

;; who a work row is FOR: its own provider where the solve bound one; else
;; the materialization's suggestion — the mi| intent's suggested-provider
;; meta for the row's process, written by materialize-willing! from the
;; willing-gated solve (the FIELD solve emits providers unbound, live.scm)
;; when an UNTIL closes: the store's one temporal law (planning.scm) — a
;; timed boundary at its minute, a bare date at the END of its day. The
;; date-only reading (iso->epoch) made every same-day window count as
;; already expired: a morning solve laid no shifts for the afternoon.
(define (window-closes-at until) (window-close-epoch until))

(define (suggested-provider-rank ps)
  (let ((mi (filter (lambda (i) (string-prefix? "mi|" (or (intent-id i) "")))
                    ($ ps 'all-intents))))
    (lambda (row)
      (or (row-provider row)
          (let ((proc (row-input-of row)))
            (and proc
                 (any (lambda (i)
                        (and (equal? proc (intent-input-of i))
                             (let ((m ($ ps 'get-meta (intent-id i))))
                               (and m (assq-ref m 'suggested-provider)))))
                      mi)))))))
;; the OPEN SHIFTS: every solve's work cells persist as open work intents
;; (ni|proc|skill|cell — the engine's own id grammar, provider unbound).
;; This is the offering's FRONT HALF: with these standing, the snapshot's
;; candidate field has rows, the eligible tier fills for skill-holders,
;; willingness has something to race onto, materialize-willing has needs
;; to suggest for, and the presentation rank has suggestions to direct.
;; Cleared and re-laid per solve, as the mi| suggestions are; a cell an
;; accept already covers is not re-laid — the decided rung is not
;; offered twice. A row without a `work` key (a federated row) states no
;; shifts at all, and the shifts the last own plan laid stand.
(define (persist-open-shifts! root cached)
  (let* ((ps (false-if-exception ($ root 'plan-store))))
    (when (and ps (assq 'work (cdr cached)))
      (clear-intents-by-prefix! ps "ni|")
      (let ((accepted (map commitment-input-of (standing-accepts ps)))
            (nowu (instant->unix (now)))
            (laid 0) (closed 0))
        (for-each
         (lambda (w)
           (let* ((proc  (row-input-of w))
                  (skill (or (row-spec w) "labour"))
                  (place (row-place w))
                  (eff   (row-effort w))
                  (when* (row-when w))
                  (until (row-until w))
                  (cell  (string-append (or place "") "@"
                                        (number->string (time->period when*)))))
             ;; a CLOSED window is never an open shift — offer-work's own
             ;; law at this tier: laying it would invite an accept the
             ;; expiry sweep must immediately unmake (measured: an evening
             ;; accept of a 09:00–17:00 shift self-expired one turn later)
             (when (and proc (number? eff) (> eff 1e-6) (not (member proc accepted))
                        until (let ((u (window-closes-at until))) (and u (<= u nowu))))
               (set! closed (+ closed 1)))
             (when (and proc (number? eff) (> eff 1e-6)
                        (not (member proc accepted))
                        (or (not until)
                            (let ((u (window-closes-at until)))
                              (or (not u) (> u nowu)))))
               (set! laid (+ laid 1))
               ($ ps 'add-intent
                  (work-intent (string-append "ni|" proc "|" skill "|" cell)
                               #:name (assq-ref w 'name)
                               #:proc proc #:skill skill #:hours eff
                               #:from when* #:until until #:point when*
                               #:place place)))))
         (or (assq-ref (cdr cached) 'work) '()))
        ;; what the landing laid, on the log: the number a reader of the
        ;; grid compares against, beside the windows already closed
        (format (current-error-port) "  [open-shifts] laid ~a open shift(s), ~a window(s) already closed, ~a work row(s)~%"
                laid closed (length (or (assq-ref (cdr cached) 'work) '())))))))
;; ── the presentation caller: a solve's suggestions become offers ─────────────
;; The default presentation policy, with the ranking PLUGGABLE. The solve
;; already chose who works which slot (the deployment's provider on each
;; work row); presenting turns those suggestions into directed offers,
;; nearest-forcing-first — the doc's ordering, so the offers whose
;; windows close soonest stand in front. #:rank-fn (row → agent-id | #f)
;; overrides the choice per row (rotation, affinity, anything governance
;; picks); #f skips the row. Self-serve stays open regardless: presenting
;; never gates accepting. The walk STOPS at MAX-OPEN (mass-freezing
;; refused here, not just per offer, same as offer-work's own bound); a
;; single row's refusal (its forcing point passed) skips that row only.
;; A row whose (proc, provider) already carries an unfinished accept is
;; not re-presented — the decided rung is not offered twice.
(define* (present-offers scope-root result #:key (rank-fn #f) (limit #f) (max-open 12)
                         (admit? #f))
  (let* ((ps (scope-part scope-root 'plan-store))
         (coms (if ps (standing-accepts ps) '()))
         (accepted? (lambda (proc agent)
                      (any (lambda (c) (and (equal? proc (commitment-input-of c))
                                            (equal? agent (commitment-provider c))))
                           coms)))
         (rows (sort (or (assq-ref result 'work) '())
                     (lambda (a b)
                       (let ((ua (window-close-epoch (row-until a)))
                             (ub (window-close-epoch (row-until b))))
                         (cond ((and ua ub) (< ua ub)) (ua #t) (else #f)))))))
    (let loop ((rs rows) (out '()))
      (cond ((null? rs) (reverse out))
            ((and limit (>= (length out) limit)) (reverse out))
            ((>= (length (open-work-offers scope-root)) max-open) (reverse out))
            (else
             (let* ((row (car rs))
                    (agent (if rank-fn (rank-fn row) (row-provider row))))
               (if (or (not agent)
                       (not (row-input-of row))
                       (accepted? (row-input-of row) agent))
                   (loop (cdr rs) out)
                   (let ((pid (catch* 'offer-refused
                                (lambda () (offer-work scope-root row agent
                                                       #:admit? admit?))
                                (lambda _ #f))))     ; the door's OWN refusal — skip
                                                     ; the row, walk on; any other
                                                     ; raise is a fault and propagates
                     (loop (cdr rs) (if pid (cons pid out) out))))))))))

;; ── the regret diagnostic: what the standing accepts cost, said in hours ─────
;; (commitment-horizon.md, "minimax regret and the regret-tilt".) The cost
;; of an accept is DEFINED as the here-and-now/wait-and-see gap — regret —
;; and its counterfactual is not "knowing the weather" but "not having
;; committed": the same world solved twice, as it stands and with the pins
;; freed, and the difference reported. Diagnosis only, never a solve
;; change: the number to show a person at the accept door. An accept at
;; the solve's own optimum reads ~zero — the doc's "costs nothing today";
;; the regret appears as the world moves and the pin cannot follow.
;; (The entropic tilt over per-branch regrets stays open pending a
;; per-branch cost read.) OPTS pass to plan-scope->alist (#:demand …);
;; do not pass #:pins — both sides set it.
(define (plan-hours r)
  "The hours a plan alist's work rows sum to — the reading regret and what
   voice displaces are said in."
  (fold (lambda (w acc) (+ acc (or (row-effort w) 0)))
        0.0 (or (assq-ref r 'work) '())))

(define (settled-solves solve base-kw settings)
  "SOLVE-AT for externality's `paired-difference`: setting → result, each result
   solved once and kept for the reading (its rows are read several times),
   every setting after the first warmed from the first's x so the pair stops
   at one settled floor. SETTINGS : ((setting . kw) …), the first the base."
  (let ((seen '()))
    (lambda (setting)
      (or (assoc-ref seen setting)
          (let* ((kw (or (assoc-ref settings setting) (error "settled-solves: no such setting" setting)))
                 (warm (and (pair? seen) (assq-ref (cdar (last-pair seen)) 'x)))
                 (r (apply solve (append kw (if (vector? warm) (list #:warm-x warm) '()) base-kw))))
            (set! seen (cons (cons setting r) seen))
            r)))))

(define* (accept-regret scope-root #:key (gamma 1.0)
                        (solve (lambda kw (apply plan-scope->plan scope-root kw)))
                        #:allow-other-keys #:rest opts)
  "SOLVE : kw → plan alist (the service passes its own door, so both sides
   see the world every solve at this scope sees). Regret is externality's
   one difference: the standing pins against the pins freed."
  (define hours-of plan-hours)
  (define solve-opts (kw-without opts '(#:gamma #:solve)))
  (define solve-at
    (settled-solves solve solve-opts `((pinned . ()) (free . (#:pins ())))))
  (let* ((pinned (solve-at 'pinned))
         (free   (solve-at 'free))
         (fsd (let ((pf (or (assq-ref pinned 'first-stage-plan) '()))
                    (ff (or (assq-ref free 'first-stage-plan) '())))
                (filter-map
                 (lambda (kv)
                   (let ((d (- (cdr kv) (or (assoc-ref ff (car kv)) 0))))
                     (and (> (abs d) *support-tolerance*) (cons (car kv) d))))
                 pf))))
    (let* (;; per-branch regret: the branch's own objective pinned minus free
           (bc-free (or (assq-ref free 'branch-costs) '()))
           (branch-regret
            (filter-map
             (lambda (bp)
               (let ((f (assoc (car bp) bc-free)))
                 (and f (list (car bp) (cadr bp) (- (caddr bp) (caddr f))))))
             (or (assq-ref pinned 'branch-costs) '())))
           (tilt (entropic-tilt branch-regret gamma)))
      `((hours-pinned . ,(hours-of pinned))
        (hours-free   . ,(hours-of free))
        (regret-hours . ,(paired-difference solve-at hours-of 'pinned 'free))
        (met-pinned   . ,(assq-ref pinned 'met))
        (met-free     . ,(assq-ref free 'met))
        (first-stage-delta . ,fsd)
        ;; ((scenario-id prob regret) …) and the tilt q*_ω ∝ p_ω e^{γ·regret_ω}:
        ;; which future these accepts would be most regretted in
        (branch-regret . ,branch-regret)
        (regret-tilt   . ,tilt)
        (gamma         . ,gamma)))))

;; the entropic tilt over per-branch values: q*_ω ∝ p_ω·e^{γ Z_ω}, normalized
;; — the dual representation's worst-case reweighting in closed form. γ→0 is
;; the plain probabilities, γ→∞ concentrates on the worst branch (minimax);
;; over REGRETS rather than raw costs it isolates what these commitments
;; specifically cost in each future (commitment-horizon.md, "the regret-tilt").
(define (entropic-tilt rows gamma)
  (if (null? rows) '()
      (let* ((zmax (apply max (map caddr rows)))          ; shift for numerical safety
             (ws (map (lambda (r) (* (cadr r) (exp (* gamma (- (caddr r) zmax))))) rows))
             (z (apply + ws)))
        (if (<= z 0) '()
            (map (lambda (r w) (cons (car r) (/ w z))) rows ws)))))

;; ── the fresh check: a never-held accept takes its feasibility pass NOW ──────
;; (commitment-horizon.md, certification.) A held offer's wall rode every
;; re-solve; a self-authored accept — slots, share commitments, anything
;; no offer published — was certified by nothing, and its only guard was
;; the NEXT solve's raise: loud but late. make-fresh-check closes that:
;; the candidate rides ONE trial solve as an extra pinned commitment —
;; through the same door the real accept's next solve takes — and the trial's raise
;; (a starved wall, a homeless column) becomes the door's refusal, now.
;; Installed on the plan-store as `set-fresh-check` by the service (the
;; one layer that holds both the scope and the last solve's demand);
;; planning.scm consults it at both accept doors for never-held work
;; intents only. SOLVE-OPTS-THUNK supplies the trial's world per call
;; (the last solve's own demand), so the trial prices the world as it
;; stands at accept time.
(define* (make-fresh-check scope-root #:key (solve-opts-thunk (lambda () '()))
                                            ;; the solve the trial rides: the service hands the door every
                                            ;; plan goes through (its readers — world, demand, standing);
                                            ;; the bare planner only where no service stands
                                            (solve (lambda kw (apply plan-scope->plan scope-root kw))))
  ;; the candidate as the commitment promotion WOULD make — the same field
  ;; map, so the trial solves exactly what the accept would pin
  (define (trial-commitment it)
    (intent->commitment it (string-append "fresh:" (intent-id it))
                        (or (intent-provider it) "candidate") (intent-receiver it)))
  (lambda (intent)
    (catch* #t
      (lambda ()
        (apply solve
               #:extra-accepts (list (trial-commitment intent))
               (solve-opts-thunk))
        #t)
      (lambda (key . args)
        ;; the check answers ONE question — does pinning this make the
        ;; program INFEASIBLE — and only the PROGRAM may say yes. It says
        ;; so in ONE typed voice: 'planner-starvation, the solver's own
        ;; raise-starvation (phase-I, the obstruction door, robust's
        ;; scenario floors, substitute-fixed alike). Every other raise — a
        ;; column this world-slice cannot home, a compile refusal, a world
        ;; too bare to solve — certifies nothing about the accept: it
        ;; passes, named on stderr, and the pin's own raise at the next
        ;; real solve remains the guard. Matching the key instead of the
        ;; prose is what let the obstruction door count at all — its
        ;; message never contained the words the old string-match looked
        ;; for, so a certified obstruction PASSED the check.
        (if (eq? key 'planner-starvation)
            (format #f "fresh-check: the current world cannot carry this accept — ~a"
                    (if (pair? args) (car args) ""))
            (begin
              (format (current-error-port)
                      "  [fresh-check] trial could not speak (~a: ~a) — accept passes to the pin's own guard~%"
                      key args)
              #t))))))

;; ── the drift question: κ against what the commitments actually did ────────
;; (commitment-horizon.md, renegotiation cadence.) The conjecture says the
;; inspection cadence a* should govern how often commitments are
;; renegotiated; before designing on it, the empirical question: does the
;; declaration churn κ PREDICT the rate at which standing commitments come
;; apart? Three rates, ONE read (planning.scm's rate-of) over one source —
;; the store's dated facts — on one clock:
;;   kappa          declaration changes per day   ("decl:…" → (declared . action))
;;   lapse-rate     offer lapses per day          (<proposal-id> → (lapsed . kind))
;;   endings        how the accepts ended, by kind (<commitment-id> → (ended . kind)):
;;                  released (withdrawn), fulfilled (worked), expired (window closed)
;; A commitment COMING APART is a release or an expiry — fulfilment is the
;; decided rung doing its job — so the drift ratio is (released+expired)/κ,
;; beside lapse/κ: the numbers a cadence rule would be stated in. Under the
;; conjecture both ratios are stable across epochs; a ratio that wanders is
;; the conjecture failing, said in data. WINDOW-DAYS and NOW are parameters
;; of the question, not standing choices: ask over a week, ask over an
;; epoch — and ask about an epoch that ENDED months ago (#:at, unix), because
;; the ledger keeps its facts and the series the conjecture is judged on is
;; read off it retroactively, epoch by epoch. (The keyword is `at`, never
;; `now`: a parameter named now shadows the clock it would call.)
(define* (commitment-drift plan-store #:key (window-days 7.0) (at #f))
  (let* ((nowu (or at (instant->unix (now))))
         (kappa   (rate-of plan-store 'declared nowu window-days))
         (lapses  (rate-of plan-store 'lapsed   nowu window-days))
         (endings (how-commitments-end plan-store nowu window-days))
         (apart   (/ (+ (assq-ref endings 'released) (assq-ref endings 'expired))
                     window-days))
         (ratio (lambda (r) (and (> kappa 0) (/ r kappa)))))
    `((window-days . ,window-days)
      (kappa . ,kappa)
      (lapse-rate . ,lapses)
      (endings . ,endings)
      (apart-rate . ,apart)
      (lapse/kappa . ,(ratio lapses))
      (apart/kappa . ,(ratio apart))
      (as-of . ,nowu))))
