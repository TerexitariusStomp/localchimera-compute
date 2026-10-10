;;; plan/accepts.scm — what the plan-store's standing commitments and offers ARE
;;; to a solve: the READ side of the commitment arc, called by plan-scope at
;;; every solve (docs/planning/solve/commitment-horizon.md).
;;;
;;;   commitments-before-solve   expire what closed; accepts → pins, open offers → holds
;;;   commitments-after-solve    the horizon read cached; the unbound floors named;
;;;                              holds the program could not honor lapsed
;;; Behind them: accepts->pins (the VF-terms compile), standing-pins /
;;; standing-holds, cache-horizon-derived!, sweep-floor-escalation!,
;;; lapse-offer! (a lapse is a fact of the offer; the alert announces it).
;;;
;;; Everything here is derived or intrinsic to the solve; the arc carries no
;;; governed numbers — every remaining parameter (max-open, gamma, the
;;; accepting agent's own booking notice) is a question's own default, read
;;; at its own door — and the doors people use (offer-work, present-offers,
;;; accept-regret, the fresh check, the churn meter) live in offers.scm,
;;; which reads THROUGH the solve this module feeds.

(define-module (playnet plan accepts)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet vf schemas)            ; the VF records
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet vf beyond scenario)
  #:use-module ((playnet vf formulas periods) #:select (time->period period-span set-period-span! period-contains?))
  #:use-module ((playnet vf facts located) #:select (good-spec period-of key-terms))
  #:use-module ((playnet vf formulas shocks) #:select (scenario-shocks shock-action shock-key shock-factor))
  #:use-module ((playnet vf facts agent-time) #:select (agent-away-dates))
  #:use-module ((playnet vf formulas counting) #:select (count-process?))   ; a planned count has no column
  #:use-module ((playnet utils clock) #:select (now instant->unix days->seconds seconds->days iso->epoch))
  #:use-module ((playnet plan store)
                #:select (offer-rows offer-window-expired? standing-accepts
                          window-close-epoch))
  #:use-module ((playnet plan horizon-gate) #:select (forcing-ceiling-days horizon-ctx horizon-derived-of))
  #:export (;; the two doors plan-scope crosses: what the standing commitments
            ;; ARE to this solve, and what this solve did to them
            commitments-before-solve commitments-after-solve
            ;; the compile, for the tests that prove it and the trial solve
            accepts->pins
            ;; the deployment half of the two-layer accept (federation/iteration reads it)
            deployment-bindings
            ;; the small shared vocabulary offers.scm reads
            ->epoch scope-part scope-horizon-ctx *support-tolerance*
            open-work-offers
            ;; the dial's data: every floor-defending proc's rung and reach, for the snapshot
            floors->wire))

;; ── the small shared vocabulary of the commitment machinery ─────────────────
;; one coercion for the two clock shapes VF terms carry: ISO strings and
;; unix seconds
(define (->epoch x) (if (string? x) (iso->epoch x) x))
;; a scope part, or #f when the root lacks it (a mock, a minimal scope) —
;; the empty case every reader here treats as "nothing to read", never a
;; swallowed error
(define (scope-part scope-root msg) (false-if-exception ($ scope-root msg)))
;; NUMERICAL tolerances — never policy: below these a quantity is noise
(define *pin-tolerance* 1e-9)              ; hours or units too small to pin
(define *support-tolerance* 1e-6)          ; activity too small to count as live


;; ── standing accepts → #:pins: the VF-terms compile ──────────────────────────
;; docs/planning/solve/commitment-horizon.md: an accepted work commitment is a
;; hand-decided first-stage column. This compiles the plan-store's VF terms
;; (process, place, start, hours) into the solver's pins ((col-key . runs) …):
;; hours divide by the process's work coefficient — the work flow's
;; hours-per-run — so the pin lives in the column's own unit, and accepts
;; landing on one column sum. In-window = unfinished, with the window still
;; open at #:now when a clock is given. Refusals are loud: a work accept
;; naming no process, or a process without a work flow, has no column home,
;; and a silent skip is the silent-ignore failure mode the note forbids.
;; The live door's read of the standing accepts, called per solve from
;; plan-scope's world assembly. SPANS is the REFINED partition
;; (declared-partition — the very periods the solve will tile, sub-day
;; bands included), laid FIRST so each accept's has-beginning lands on
;; THIS solve's periods and accepts->pins drops what falls outside them.
;; A scope-root without a plan-store (mock or minimal) has no accepts to
;; pin — the empty case, not a swallowed error. A work accept naming no
;; process cannot map to a column; it is named on stderr and left out —
;; loud, and never fatal to the accepts that do map.
(define* (standing-pins scope-root recipe-flows spans #:optional (extra '()) (agent-of #f))
  (let* ((ps   (scope-part scope-root 'plan-store))
         (coms (append extra (if ps ($ ps 'all-commitments) '())))
         ;; a pinnable accept names its process — input-of for work,
         ;; output-of for produce; anything else has no column home
         (proc-of (lambda (c) (let ((a (commitment-action c)))
                                (cond ((memq a labour-actions)   (commitment-input-of c))
                                      ((memq a creating-actions) (commitment-output-of c))
                                      (else #f)))))
         ;; a planned count is scheduled by its cadence (counting.scm) and
         ;; has no column in the solve: it books its counter's hours through
         ;; the deployment seed and pins nothing
         (coms (filter (lambda (c) (not (count-process? (proc-of c)))) coms))
         (unmapped (filter (lambda (c)
                             (and (memq (commitment-action c) (append labour-actions creating-actions))
                                  (not (commitment-finished c))
                                  (not (proc-of c))))
                           coms)))
    (for-each (lambda (c)
                (simple-format (current-error-port)
                  "[plan-scope] ~a accept ~a names no process — not pinned~%"
                  (commitment-action c) (commitment-id c)))
              unmapped)
    (let ((i 0))
      (for-each (lambda (sp)
                  (set-period-span! i (car sp) (cdr sp))
                  (set! i (+ i 1)))
                spans))
    (accepts->pins (filter proc-of coms) recipe-flows
                   #:now (instant->unix (now)) #:scope-root scope-root #:agent-of agent-of)))

;; (proc . skill) → hours per run, read off each recipe's own work flow —
;; the divisor that puts hours in the column's unit. Keyed by skill as well
;; as process, work-coeffs' own mirror of produce-coeffs below: a process
;; can carry more than one work flow (rp-meeting's four simultaneous roles
;; — facilitate, note-taking, two participation seats), each its own skill
;; and its own hours-per-run: keying by process alone silently let a later
;; flow's coefficient overwrite an earlier one's.
;;
;; Also aliases (proc . #f) to that one flow's own coefficient, for the
;; UNAMBIGUOUS case: a process with exactly one work flow, which is every
;; process except rp-meeting's — the ordinary work term names no skill at
;; all (resource-conforms-to #f), since nothing has ever needed to say
;; which when there was only one to mean. A process seen with a SECOND,
;; different flow removes its own (proc . #f) alias instead of overwriting
;; it, so a skill-less term against THAT process fails loudly (there is no
;; "the" flow to fall back to) rather than silently picking one — the same
;; silent-ignore failure mode work-term->pin's own doc forbids. Kept as one
;; table, one alias entry per unambiguous process, rather than a parallel
;; structure — work-term->pin stays a single hash-ref either way.
(define (work-coeffs recipe-flows)
  (let ((h (make-hash-table)) (solo? (make-hash-table)))
    (for-each
     (lambda (f)
       (when (and (eq? (recipe-flow-action f) 'work) (recipe-flow-recipe-input-of f))
         (let ((m (recipe-flow-effort-quantity f)))
           (when m
             (let* ((proc  (recipe-flow-recipe-input-of f))
                    (v     (measure-has-numerical-value m)))
               (hash-set! h (cons proc (recipe-flow-resource-conforms-to f)) v)
               (if (hash-ref solo? proc #f)
                   (hash-remove! h (cons proc #f))
                   (begin (hash-set! solo? proc #t)
                          (hash-set! h (cons proc #f) v))))))))
     recipe-flows)
    h))

;; ONE term's landing spot: (col-key . runs), or #f when the term's start
;; falls outside every laid span — outside the horizon, time->period's
;; fallback would mis-place it on period 0, so it is simply not this
;; solve's to pin or hold. Every live world stands on laid spans (engine
;; standing-partition); a period a direct engine caller left unlaid takes the term.
(define (pin-cell proc place beginning runs)
  (let* ((p (time->period beginning))
         (s (period-span p))
         (in-span? (or (not beginning) (not (and (car s) (cdr s)))
                       (period-contains? p beginning))))
    (and in-span?
         (cons (string-append "p|" proc "|" (or place "") "@" (number->string p))
               runs))))

;; ONE work term (an accept's, or a held offer's) → its pin cell, the
;; arithmetic BOTH rungs share. Raises when the term has no column home —
;; no process, or a process without a work flow of this skill (a skill-less
;; term against an ambiguous multi-flow process included — see work-coeffs'
;; own (proc . #f) aliasing) — the silent-ignore failure mode
;; commitment-horizon.md forbids.
(define (work-term->pin coeffs who proc skill hours beginning place)
  (unless proc
    (error "accepts->pins: a work accept names no process — no column home" who))
  (let ((w (hash-ref coeffs (cons proc skill) #f)))
    (unless (and w (> w 0))
      (error "accepts->pins: the process carries no work flow of this skill to turn hours into runs"
             (cons proc skill)))
    (pin-cell proc place beginning (/ hours w))))

;; (proc . spec) → output quantity per run — the produce side's divisor,
;; work-coeffs' sibling for MATERIAL accepts
(define (produce-coeffs recipe-flows)
  (let ((h (make-hash-table)))
    (for-each
     (lambda (f)
       (when (and (output-flow? f) (recipe-flow-recipe-output-of f))
         (let ((m (recipe-flow-resource-quantity f)))
           (when m (hash-set! h (cons (recipe-flow-recipe-output-of f)
                                      (recipe-flow-resource-conforms-to f))
                              (measure-has-numerical-value m))))))
     recipe-flows)
    h))

;; ONE produce term (a material accept: "this much of the good, from this
;; process") → its pin cell: quantity divides by the process's per-run
;; output of that spec.
(define (produce-term->pin pcoeffs who proc spec qty beginning place)
  (unless proc
    (error "accepts->pins: a produce accept names no process — no column home" who))
  (let ((q (hash-ref pcoeffs (cons proc spec) #f)))
    (unless (and q (> q 0))
      (error "accepts->pins: the process carries no produce flow of this spec to turn quantity into runs"
             (cons proc spec)))
    (pin-cell proc place beginning (/ qty q))))

;; cells landing on one column sum; #f cells (out of span) fall away
(define (sum-pin-cells cells)
  (let ((acc (make-hash-table)))
    (for-each (lambda (c)
                (when c (hash-set! acc (car c) (+ (hash-ref acc (car c) 0.0) (cdr c)))))
              cells)
    (hash-fold (lambda (k v a) (cons (cons k v) a)) '() acc)))

;; the processes RECIPE-FLOWS still carry: a record standing on one that has
;; LEFT (a seed migrated the store; the recipe retired) is void by
;; construction — there is no column for it to pin — and reads as such,
;; once, on the log. A record naming a process the store carries but with no
;; flow of its skill stays the fault it is (work-term->pin raises).
(define (carried-processes recipe-flows)
  (let ((h (make-hash-table)))
    (for-each (lambda (f)
                (let ((pi (recipe-flow-recipe-input-of f))
                      (po (recipe-flow-recipe-output-of f)))
                  (when pi (hash-set! h pi #t))
                  (when po (hash-set! h po #t))))
              recipe-flows)
    h))
(define (carried-by? carried proc who)
  (or (not proc) (hash-ref carried proc #f)
      (begin (format (current-error-port)
                     "  [pins] ~a stands on a process the store no longer carries (~a) — void~%"
                     who proc)
             #f)))

;; the processes RECIPE-FLOWS carry a relocation in: a pickup or a dropoff of their own.
;; A haul's column is an ARC (`p|<proc>|<origin>|<destination>`), and the work accept of
;; its driver names the recipe and the origin place and no destination: that accept names
;; no column of the solve, so it pins nothing, and says so once on the log. (A solve that
;; was handed such a pin would refuse it, 'commitment-unplaceable, and lapse the accept.)
(define (hauling-processes recipe-flows)
  (let ((h (make-hash-table)))
    (for-each (lambda (f)
                (when (relocating-action? (recipe-flow-action f))
                  (let ((p (or (recipe-flow-recipe-input-of f) (recipe-flow-recipe-output-of f))))
                    (when p (hash-set! h p #t)))))
              recipe-flows)
    h))
(define (hauls-work? hauling c)
  (and (eq? 'work (commitment-action c))
       (hash-ref hauling (commitment-input-of c) #f)
       (begin (format (current-error-port)
                      "  [pins] ~a is the work of a haul (~a): its column is an arc the accept does not name — not pinned~%"
                      (commitment-id c) (commitment-input-of c))
              #t)))

;; A commitment's provider, away (§2c) on the commitment's own day, does not
;; pin: the rebuild-around-the-gap a declaration makes, so the shift no
;; longer holds a body that will not be there and stands open for the solve
;; to fill some other way, or leave open, on THIS solve and every one after
;; while the declaration stands — self-healing the moment it is lifted,
;; since a pin is recomputed fresh every time rather than struck once. Only
;; a PERSON has a body to be away from; an organisation's or a device's
;; commitment reads as it always did.
(define* (provider-away? scope-root c #:optional (agent-of #f))
  (and scope-root
       (let* ((as  (scope-part scope-root 'agent-store))
              (pid (commitment-provider c))
              ;; the person's record is at their home: a visitor holds none
              ;; here, and AGENT-OF (aid → agent | #f) reads it where it is
              (ag  (and pid (or (and as ($ as 'get-agent pid))
                                (and agent-of (agent-of pid)))))
              (beg (commitment-has-beginning c)))
         (and ag (eq? (agent-type ag) 'person) beg
              (member (substring beg 0 10) (agent-away-dates ag))))))

(define* (accepts->pins commitments recipe-flows #:key (now #f) (scope-root #f) (agent-of #f))
  (define coeffs  (work-coeffs recipe-flows))
  (define pcoeffs (produce-coeffs recipe-flows))
  (define carried (carried-processes recipe-flows))
  (define hauling (hauling-processes recipe-flows))
  (define (carried? c)
    (carried-by? carried (or (commitment-input-of c) (commitment-output-of c)) (commitment-id c)))
  ;; open by the commitment's OWN terms — window-close-epoch, the store's one
  ;; temporal law (a timed end at its minute, a bare date at the END of its
  ;; day). The date-truncating ->epoch read here meant an accept stopped
  ;; pinning for the whole of its last day while standing-accepts, the wire
  ;; and the drift read all still called it standing.
  (define (open-at? c)                    ; no clock, no end, or still open
    (or (not now)
        (let ((u (window-close-epoch (commitment-has-end c)))
              (n (window-close-epoch now)))
          (or (not u) (not n) (> u n)))))
  (sum-pin-cells
   (filter-map
    (lambda (c)
      (and (not (commitment-finished c))
           (open-at? c)
           (carried? c)
           (not (hauls-work? hauling c))
           (not (provider-away? scope-root c agent-of))
           (case (commitment-action c)
             ;; a WORK accept: hours ÷ the work flow's hours-per-run
             ((work)
              (let ((hours (and=> (commitment-effort-quantity c)
                                  measure-has-numerical-value)))
                (and hours (> hours *pin-tolerance*)
                     (work-term->pin coeffs (commitment-id c) (commitment-input-of c)
                                     (commitment-resource-conforms-to c)
                                     hours (commitment-has-beginning c)
                                     (commitment-at-location c)))))
             ;; a MATERIAL accept: quantity ÷ the produce flow's per-run output
             ((produce)
              (let ((qty (and=> (commitment-resource-quantity c)
                                measure-has-numerical-value)))
                (and qty (> qty *pin-tolerance*)
                     (produce-term->pin pcoeffs (commitment-id c) (commitment-output-of c)
                                        (commitment-resource-conforms-to c)
                                        qty (commitment-has-beginning c)
                                        (commitment-at-location c)))))
             (else #f))))
    commitments)))

;; ── the solve's own horizon read, cached for the gate ────────────────────────
;; (commitment-horizon.md: branches-served, the current-solution support
;; read.) A process defends a floor when the recipe graph's upstream
;; closure from a floor-carrying spec reaches it AND the solve's
;; first-stage plan actually runs it. Cached together with each branch's
;; 'duration shocks on the plan-store's "horizon-derived" meta row, which
;; the gate and the offer window read per accept — the ceiling for a
;; floor-defending process is then max_s CP_s over the branches, derived,
;; and the floor-margin knob is gone. A store without set-meta (a mock)
;; skips the cache, never the solve.
(define (cache-horizon-derived! scope-root repro-floors flows scenarios report procs-of-world)
  (let* ((floor-specs (delete-duplicates
                       (filter-map (lambda (rf) (good-spec (car rf))) repro-floors)))
         ;; upstream closure: producers of a floor spec, plus producers of
         ;; what those consume or use, to fixpoint
         (procs (call-with-values
                    (lambda () (upstream-closure flows floor-specs #:inputs drawing-actions))
                  (lambda (_specs procs) procs)))
         (fs (or (assq-ref report 'first-stage-plan) '()))
         (floor-procs (filter (lambda (p) (> (or (assoc-ref fs p) 0) *support-tolerance*)) procs))
         ;; spec → its producing procs, for a yield shock keyed by spec
         (producers (lambda (spec)
                      (delete-duplicates
                       (filter-map (lambda (f)
                                     (and (output-flow? f)
                                          (equal? spec (recipe-flow-resource-conforms-to f))
                                          (recipe-flow-recipe-output-of f)))
                                   flows))))
         ;; each branch's duration factors, per proc: an explicit 'duration
         ;; shock as declared, and — the derivation that replaces a data wait
         ;; — a worse YIELD read as a longer chain: at binding capacity a floor
         ;; takes proportionally more periods to accumulate, so a produce
         ;; factor f < 1 lengthens the defending chain by 1/f. Conservative
         ;; when capacity does not bind (runs parallelise), the safe
         ;; direction for a floor; better yields never shorten below the
         ;; base. The max stands where both name one proc.
         (dur-factors
          (filter-map
           (lambda (s)
             (let ((h (make-hash-table)))
               (define (note! proc f)
                 (hash-set! h proc (max f (hash-ref h proc 1.0))))
               (for-each
                (lambda (sh)
                  (case (shock-action sh)
                    ((duration) (note! (shock-key sh) (shock-factor sh)))
                    ((produce)
                     (let ((f (shock-factor sh)))
                       (when (and (number? f) (> f 0) (< f 1))
                         (for-each (lambda (proc) (note! proc (/ 1.0 f)))
                                   (if (any (lambda (p) (equal? (recipe-process-id p) (shock-key sh)))
                                            procs-of-world)
                                       (list (shock-key sh))
                                       (producers (shock-key sh)))))))
                    (else #f)))
                (scenario-shocks s))
               (let ((fs* (hash-map->list cons h)))
                 (and (pair? fs*) (cons (planning-scenario-id s) fs*)))))
           scenarios)))
    (let* ((ps (scope-part scope-root 'plan-store))
           ;; the rungs stand from the previous solve until the sweep below
           ;; re-derives them — carried so a transition is seen as one
           (standing (or (and=> (horizon-derived-of ps) (lambda (d) (assq-ref d 'rungs))) '()))
           (derived `((floor-procs . ,floor-procs)
                      (floor-specs . ,floor-specs)
                      (duration-factors . ,dur-factors)
                      (rungs . ,standing))))
      (when ps (false-if-exception ($ ps 'set-meta "horizon-derived" derived)))
      derived)))

;; ── the escalation door: the gate's dual, the unaccepted floor ───────────────
;; (commitment-horizon.md, "The gate's dual".) The gate refuses eager
;; accepts; this door refuses SILENCE about the opposite failure: floor
;; work the solve schedules that no person has bound themself to.
;; Refusal-is-default means nobody is obligated — so the coverage gap is
;; surfaced with rising insistence as the forcing point nears, and past
;; it the honest outcome is said out loud. Three rungs, each named ONCE
;; on the alert rail (stderr repeats every solve — the insistence):
;;   floor-unaccepted        — a gap stands, the forcing point is ahead;
;;   floor-reserve-bridge    — the forcing point passed unbound and the
;;                             reserve is now load-bearing for the cycle;
;;   floor-unbound-infeasible — passed unbound with NO reserve behind it:
;;                             "no plan holds the floor", the governance
;;                             event, a famine tail refused its average.
;; The forcing point is the floor's earliest period start minus the
;; process's own forcing ceiling (branch-maxed CP) — conservative: the
;; earliest floor period stands in for per-proc attribution. The clock is the
;; laid spans' own (engine standing-partition lays them from today when the world
;; declares none); a period left unlaid reads the first rung.
;; a scope's horizon context: the reads every ceiling question needs,
;; off the scope's own parts (see horizon-gate.scm's horizon-ctx)
(define (scope-horizon-ctx scope-root nowu)
  (horizon-ctx (scope-part scope-root 'recipe-store)
               (scope-part scope-root 'observer)
               (scope-part scope-root 'plan-store)
               nowu))

;; the current rung per floor-defending proc rides the solve's own row
;; ("horizon-derived" → rungs: ((proc . rung) …)) — ONE derived row per
;; solve; the alert rail announces each transition, once per rung, because
;; the standing fact is what is compared
(define (sweep-floor-escalation! scope-root derived world report nowu)
  (let* ((pins (or (assq-ref world 'pins) '()))
         (fs-plan (or (assq-ref report 'first-stage-plan) '()))
         (insurance (or (assq-ref world 'insurance) '()))
         (repro-floors (or (assq-ref world 'repro-floors) '()))
         (ps  (scope-part scope-root 'plan-store))
         (als (scope-part scope-root 'alert-store))
         (ctx (scope-horizon-ctx scope-root nowu))
         (floor-procs (or (and derived (assq-ref derived 'floor-procs)) '()))
         (floor-specs (or (and derived (assq-ref derived 'floor-specs)) '()))
         (reserve? (any (lambda (row) (member (good-spec (car row)) floor-specs))
                        insurance))
         ;; the earliest floor period's span start, on the laid spans
         (start (fold (lambda (rf acc)
                        (let* ((t (period-of (cadr (string-split (car rf) #\#))))
                               (s (car (period-span t)))
                               (e (and s (iso->epoch s))))
                          (if (and e (or (not acc) (< e acc))) e acc)))
                      #f repro-floors))
         (pinned-runs
          (lambda (proc)
            (fold (lambda (kv acc)
                    (let ((kt (key-terms (car kv))))            ; a pin sits on an act at one cell, never an arc
                      (if (and (not (assq-ref kt 'arc)) (equal? proc (assq-ref kt 'process)))
                          (+ acc (cdr kv)) acc)))
                  0.0 pins)))
         (standing (or (and derived (assq-ref derived 'rungs)) '()))
         (rungs '()) (reaches '()))
    (for-each
     (lambda (proc)
       (let* ((gap (- (or (assoc-ref fs-plan proc) 0) (pinned-runs proc)))
              (cp (or (false-if-exception (forcing-ceiling-days ctx proc)) 0))
              (forcing (and start (- start (days->seconds cp))))
              ;; the CONTINUOUS quantity: days until the forcing point,
              ;; negative once it has passed; #f with no forcing clock
              (days (and forcing (seconds->days (- forcing nowu))))
              ;; the rung is a READING of gap and days — four names on one
              ;; axis, every defending proc on it, bound included
              (rung (floor-rung gap days reserve?)))
         (set! rungs (cons (cons proc rung) rungs))
         (set! reaches (cons (cons proc days) reaches))
         (unless (eq? rung 'floor-bound)
           (simple-format (current-error-port)
             "[floor] ~a: ~a runs of ~a stand unbound~a~%"
             rung gap proc
             (if days (simple-format #f " — forcing point ~a days out" days) "")))
         ;; a transition — to bound too, the one a person most wants to hear
         (when (and als (not (eq? rung (assoc-ref standing proc))))
           ($ als 'push-alert
              `((kind . ,rung) (proc . ,proc) (gap . ,gap)
                (days-to-forcing . ,days) (timestamp . ,nowu))))))
     floor-procs)
    (when ps
      (false-if-exception
       ($ ps 'set-meta "horizon-derived"
          (cons (cons 'rungs rungs)
                (cons (cons 'days-to-forcing reaches)
                      (alist-delete 'days-to-forcing (alist-delete 'rungs derived)))))))))

;; the rung, read off the two quantities — the ONE place the four names
;; meet their axis. GAP is the floor's scheduled runs nobody has bound
;; themself to (≤ 0: the floor is covered — bound, the good reading);
;; DAYS is days to the forcing point (#f: no clock); RESERVE? whether a
;; reserve stands behind the floor's spec.
(define (floor-rung gap days reserve?)
  (cond ((<= gap *support-tolerance*) 'floor-bound)
        ((or (not days) (> days 0)) 'floor-unaccepted)
        (reserve? 'floor-reserve-bridge)
        (else 'floor-unbound-infeasible)))

;; ── expiry: a standing accept whose window closed unworked has ENDED ────────
;; The third way a commitment leaves the decided rung, dated like the other
;; two — the STORE does it, in one turn (expire-commitments), and reports
;; the ids; this announces them. Run before every compile (plan-scope), so
;; an expired accept stops pinning that solve and the drift question sees
;; it. has-end is the window's close; an accept without one is
;; epoch-scoped and never expires here.
(define (expire-commitments! scope-root nowu)
  (let ((ps (scope-part scope-root 'plan-store)))
    (when ps
      (for-each
       (lambda (cid)
         (simple-format (current-error-port)
           "[accept] ~a expired — its window closed unworked~%" cid))
       (or (false-if-exception ($ ps 'expire-commitments nowu)) '())))))

;; ── the offer loop: the BOUNDED rung, live ───────────────────────────────────
;; commitment-horizon.md's lattice, free → bounded → decided. An OFFER is a
;; directed VF proposal with an acceptance window: the work intent it
;; publishes stays an intent while the person decides, and every re-solve
;; HOLDS its column (x ≥ runs, a bar wall via #:holds) so the offer stays
;; certified by the CURRENT solve — certification carried by the hold, not
;; by the solve that emitted it. Accepting rides the ordinary
;; accept-proposal door (gate and all): the promotion finishes the intent,
;; which releases the hold, and the commitment pins the next solve — the
;; bounded rung hands over to the decided one with no extra machinery.
;; A hold lapses TWO ways, both loud, both on the alert rail:
;;   urgency-lapse     — the acceptance window closes unaccepted
;;                       (validate-proposal-acceptance! refuses late accepts
;;                       on its own; the sweep names the lapse once);
;;   feasibility-lapse — a re-solve cannot honor the held walls (plan-scope
;;                       retries without them and names every open offer).
;; A lapsed offer stops holding — the alert IS the release — while the
;; proposal record stays: history, never a silent deletion.

;; the ONE lapse door, from the live side: the store's lapse-offer finishes
;; the intent and dates the fact; this announces it — stderr, and the alert
;; rail once — exactly when the store says the lapse happened NOW (a second
;; call on a finished offer is the store's no-op, so the sweeps carry no
;; memory). Re-presenting the slot re-adds the intent unfinished: a fresh
;; offer is a fresh hold.
(define (lapse-offer! ps als row kind nowu)
  (let ((p (car row)))
    (when (and ps (false-if-exception ($ ps 'lapse-offer (proposal-id p) kind nowu)))
      (simple-format (current-error-port)
        (case kind
          ((offer-lapsed) "[offer] ~a lapsed — the acceptance window closed unaccepted~%")
          (else           "[offer] ~a feasibility-lapsed — the re-solve cannot honor its hold~%"))
        (proposal-id p))
      (when als
        ($ als 'push-alert
           `((kind . ,kind) (proposal . ,(proposal-id p))
             (intent . ,(intent-id (cdr row))) (timestamp . ,nowu)))))))

(define (open-work-offers scope-root)
  "The scope's live offers, nearest window-close first: ((proposal . intent) …)
   for every 'offer proposal whose published work intent is still an intent
   (unaccepted) and whose window is still open. The urgency-lapse door lives
   here: an expired unaccepted offer lapses through the store (its intent
   finishes — it leaves every enumeration by state) and is announced ONCE.
   A store without proposals (a mock, a minimal scope) has no offers."
  (let* ((ps    (scope-part scope-root 'plan-store))
         (rows  (if ps (offer-rows ps) '()))
         (als   (scope-part scope-root 'alert-store))
         (nowu  (instant->unix (now)))
         (expired? (lambda (p) (offer-window-expired? p nowu))))
    (for-each
     (lambda (row)
       (when (expired? (car row)) (lapse-offer! ps als row 'offer-lapsed nowu)))
     rows)
    ;; ROWS was read before the sweep finished the expired ones — the same
    ;; test excludes exactly those, so this call's answer is by state too
    (sort (filter (lambda (row) (not (expired? (car row)))) rows)
          (lambda (a b)
            (let ((ea (and=> (proposal-has-end (car a)) string->number))
                  (eb (and=> (proposal-has-end (car b)) string->number)))
              (cond ((and ea eb) (< ea eb)) (ea #t) (else #f)))))))

;; held offers → #:holds ((col-key . runs) …): the same arithmetic as
;; accepts->pins, over the published intents. Spans are already laid by
;; standing-pins, which runs first in the world assembly.
(define (standing-holds scope-root recipe-flows)
  (let ((coeffs (work-coeffs recipe-flows))
        (carried (carried-processes recipe-flows)))
    (sum-pin-cells
     (filter-map
      (lambda (row)
        (let* ((it (cdr row))
               (hours (and=> (intent-effort-quantity it) measure-has-numerical-value)))
          (and hours (> hours *pin-tolerance*)
               ;; an offered count holds no column (counting.scm)
               (not (count-process? (intent-input-of it)))
               (carried-by? carried (intent-input-of it) (intent-id it))
               (work-term->pin coeffs (intent-id it) (intent-input-of it)
                               (intent-resource-conforms-to it)
                               hours (intent-has-beginning it)
                               (intent-at-location it)))))
      (open-work-offers scope-root)))))

;; the feasibility-lapse door: the re-solve without holds succeeded where
;; the held one could not, so every offer still holding lapses, loudly and
;; once each — the alert releases its wall for every solve after this one.
(define (feasibility-lapse-holds! scope-root)
  (let ((ps (scope-part scope-root 'plan-store))
        (als (scope-part scope-root 'alert-store))
        (nowu (instant->unix (now))))
    ;; the offers that HELD a column: an offered count held none, so a program
    ;; the holds starved leaves it standing
    (for-each (lambda (row) (lapse-offer! ps als row 'offer-infeasible nowu))
              (filter (lambda (row) (not (count-process? (intent-input-of (cdr row)))))
                      (open-work-offers scope-root)))))

;; ── the deployment half: the plan-store's standing bindings as seeds ─────────
;; (commitment-horizon.md: the deployment half of the two-layer accept, and
;; the tentative half of a hold.) SEED = the standing ACCEPTS, provider-bound
;; — the person is consumed from the pool and the slot booked. TENTATIVE =
;; the held OFFERS — the proposed person's slot books while they decide,
;; their pool entry stays — each as the commitment its accept would make
;; (intent->commitment, promotion's own field map). greedy-deploy reads
;; only provider/skill/window/id off a seed. → (values seed tentative).
(define (deployment-bindings plan-store)
  (let* ((nowu (instant->unix (now)))
         (seed (filter (lambda (c) (and (commitment-provider c)
                                        (commitment-resource-conforms-to c)))
                       (standing-accepts plan-store)))
         (tentative
          (filter-map
           (lambda (row)
             (let ((p (car row)) (it (cdr row)))
               (and (not (offer-window-expired? p nowu))
                    (pair? (proposal-proposed-to p))
                    ;; a hold books the slot only, and the skill matters to a
                    ;; CONSUMING seed, so a skill-less offer still books under "any"
                    (intent->commitment it (proposal-id p)
                                        (car (proposal-proposed-to p)) #f
                                        #:resource-conforms-to
                                        (or (intent-resource-conforms-to it) "any")))))
           (offer-rows plan-store))))
    (values seed tentative)))

;; ── the floors, for the wire ─────────────────────────────────────────────────
;; What the escalation door knows, projected for a browser: one row per
;; floor-defending process off the latest solve's horizon-derived row —
;; the rung (a reading), the continuous days-to-forcing it reads (#f: no
;; forcing clock), and the branches' duration factors that stretched its
;; chain. The snapshot carries it as `floors`; how a dial draws "rising
;; insistence" is the UI's, the number is here.
(define (floors->wire plan-store)
  (let* ((d (or (horizon-derived-of plan-store) '()))
         (rungs (or (assq-ref d 'rungs) '()))
         (reach (or (assq-ref d 'days-to-forcing) '()))
         (factors (or (assq-ref d 'duration-factors) '())))
    (map (lambda (proc)
           `((proc . ,proc)
             (rung . ,(assoc-ref rungs proc))                     ; the sweep's own reading, bound included
             (days-to-forcing . ,(assoc-ref reach proc))
             (branch-factors . ,(filter-map
                                 (lambda (b) (let ((f (assoc-ref (cdr b) proc)))
                                               (and f (cons (car b) f))))
                                 factors))))
         (or (assq-ref d 'floor-procs) '()))))

;; ── the two doors plan-scope crosses ────────────────────────────────────────
;; BEFORE the solve: what the standing commitments are to this program. The
;; order is the contract — an accept whose window closed unworked expires
;; first (dated), so it stops pinning THIS solve; the accepts then compile
;; on the refined partition SPANS (the pins compile lays it); the open
;; offers compile to holds on the spans the pins just laid. EXTRA rides a
;; candidate accept through the same compile (the fresh check's trial).
;; → ((pins . …) (holds . …)), the two world entries.
(define* (commitments-before-solve scope-root recipe-flows spans #:optional (extra '()) (agent-of #f))
  (expire-commitments! scope-root (instant->unix (now)))
  (let ((pins (standing-pins scope-root recipe-flows spans extra agent-of)))
    `((pins . ,pins) (holds . ,(standing-holds scope-root recipe-flows)))))

;; AFTER the solve: what this solve did to them. The horizon read is
;; cached for the gate and the offer window (floor-defending procs, the
;; branches' duration factors); the escalation door sweeps it at once —
;; floor work nobody has bound themself to, named; and when the program
;; stood only with its holds freed (HOLDS-FREED?), every offer that was
;; holding lapses, loudly. WORLD is the alist the solve was handed, REPORT
;; the one it returned; PROCS the recipe processes (a yield shock keyed by
;; proc vs by spec).
(define* (commitments-after-solve scope-root world report recipe-flows procs
                                  #:key (holds-freed? #f))
  (when holds-freed? (feasibility-lapse-holds! scope-root))
  (let ((derived (cache-horizon-derived! scope-root
                                         (or (assq-ref world 'repro-floors) '())
                                         recipe-flows
                                         (or (assq-ref world 'scenarios) '())
                                         report procs)))
    (sweep-floor-escalation! scope-root derived world report (instant->unix (now)))
    derived))
