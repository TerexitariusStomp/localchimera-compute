;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/solve/plan.scm — from records to a plan: the one door, deterministic or robust.
;;;
;;; `plan-from-records` takes a scope's records (resources, agents, spatial
;;; things, recipe processes and flows) and the keywords of a solve, and
;;; returns the plan as VF rows: the deterministic path ingests, builds, solves
;;; (discrete where declared) and reports; given `#:scenarios` it hands the
;;; same records to the robust assembly (solve/robust). `plan-bills` runs the
;;; three tiers of the bill through it. The live service (scope/live) is this
;;; with the record lists gathered from the scope-root actors.

(define-module (playnet solve plan)
  #:use-module ((playnet utils host) #:select (getenv get-internal-real-time internal-time-units-per-second string-contains))
  #:use-module (playnet solve world)
  #:use-module ((playnet solve keywords) #:select (pick-keywords))
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils catch) #:select (catch* throw* with-throw-handler*))
  #:use-module (ice-9 format)
  #:use-module (playnet vf schemas)
  #:use-module (playnet utils keywords)
  #:use-module ((playnet solve externality) #:select (withdrawal-displacement paired-difference))
  #:use-module (playnet solve periods)   ; what a period is in wall-clock time
  #:use-module (playnet solve solver)
  #:use-module (playnet solve engine)
  #:use-module (playnet solve discrete)
  #:use-module (playnet solve ingest)
  #:use-module (playnet solve report)
  #:use-module (playnet solve records)
  #:use-module (playnet solve robust)
  #:export (plan-from-records %plan-from-records plan-bills bills-fold))

(define* (%plan-from-records resources agents spatials recipe-procs recipe-flows
                            #:key (periods '(0)) (movable '()) (storable '()) (whole '()) (proc-frag '()) (tau 0.0) (hold 0.0)
                                  (demand '()) (eco-caps '()) (reserve '()) (backend 'native-c)
                                  (eco-frag '()) (eco-spec-frag #f) (eco-budget '()) (eco-container '()) (eco-couple '()) (couplings '()) (eco-prior '())  ; fragility profiles (located / per-spec rate / cumulative / container), cascade C, manual prior — passed through to ingest-located!
                                  (span-of '())         ; ((resource-id . place) …) — governed pool spans (*span-of*)
                                  (live-avail #f)       ; (resource-id → available | #f) — a live-registry's reservation-aware reading (live-availability)
                                  (stock-frag '())      ; (spec . w) — a limit carried as a LEVEL whose balance is felt at the optimum
                                  (stock-prices '())    ; ((spec . hours/unit) …) — what a drawn stock weighs: its crystallized SNLT
                                  (allow-infeasible? #f)  ; this solve MAY have no answer, and the caller says so
                                  ;; the plan asked backwards (see *acquire*): what may be bought
                                  ;; in and at what price in hours, and the tier held as a wall
                                  (acquire '()) (promote #f)
                                  (agent-hours agent-window-hours) (agent-skills #f) (skill-dynamics #f)
                                  (agent-position (lambda (id t) #f)) (horizon #f) (period-spans #f)
                                  (refine-periods? #t)      ; the partition refines at the roster's clock boundaries (ingest-located!)
                                  (node-budget #f)          ; the search's node budget for THIS solve (else *bnb-nodes*)
                                  (warm-x #f) (tstart #f) (willing? #f)
                                  ;; the standing plan's DECIDED discrete state (report key
                                  ;; `decided`), seeded as the search's first incumbent —
                                  ;; warm-x's twin for the discrete half of a plan
                                  (decided #f)
                                  (legal-forbids? #f) (legal-decorate #f)
                                  ;; per-agent? #t (default): each agent is a located, skill-resolved
                                  ;; labour SUPPLIER (EMP — who-works-which falls out), right for a
                                  ;; scope of named people. #f: one AGGREGATE labour pool per cell —
                                  ;; the natural model when labour is undifferentiated (a national
                                  ;; I-O table has one labour input per sector, not a roster), and far
                                  ;; lighter: the EMP Lab-good/worker-supply columns stall the dense
                                  ;; circular Hessian where the aggregate barrier converges cleanly.
                                  (per-agent? #t)
                                  ;; desire-weights: ((located-good . w_d) …) — priority of each want
                                  ;; in Σ w_d g_d². Absent ⇒ uniform (every want equally loud). The
                                  ;; governed level→weight policy is w_d = (priority-weight ℓ_d).
                                  (desire-weights '())
                                  ;; reproduction FLOORS: ((located-good . floor) …), the good
                                  ;; keyed like #:demand ("spec#place@period"). The deficiency floor
                                  ;; of a reproduction band (nutrition, a stock reserve) — a HARD
                                  ;; minimum, distinct from #:demand (soft desire). Applied as a
                                  ;; deficit on the good's on-hand so its delivered ≥ 0 balance (the
                                  ;; barrier EVERY good already carries) forces the plan to provision
                                  ;; it. No new tension kind. See reproduction-diet-test.
                                  (repro-floors '())
                                  (budgeted-floors '())     ; ((g F Γ) …) — a floor held against ANY Γ sources lost (lay-budgeted-floors)
                                  (maximin? #f)             ; wants judged by the least fraction of a future's achievable value (solve/robust.scm maximin-extend)
                                  ;; reproduction CEILINGS: ((located-good . (cap . w)) …) — the
                                  ;; toxicity edge (UL) of a band, the twin of #:repro-floors on
                                  ;; the other side. Held by a fixed-weight `frag` on the good's
                                  ;; delivered net (build-located), so intake is felt approaching
                                  ;; UL and never crosses it. Bare (located-good . cap) ⇒ w = 1.
                                  (repro-caps '())
                                  ;; INSURANCE reserves: ((located-good lo hi alpha w) …) — the
                                  ;; calamity stock q_r^"res" of §Reproduction labour: a HARD
                                  ;; possibility-tension, not a soft desire. `held` at the good's
                                  ;; level: divergent at `lo` (bare need — never breached), the
                                  ;; margin to quantile_alpha of [lo,hi] held while labour allows
                                  ;; and eroded gracefully as it binds. Distinct from #:reserve
                                  ;; (q_r^"op", the soft buffer — a low-weight `des`, shed first)
                                  ;; and from #:repro-floors (a bar at bare need with no margin).
                                  (insurance '())
                                  ;; whole BANDS: ((located-good lo hi w) …), lo/hi may be #f; either
                                  ;; wall may carry a range, lo as (lo hi alpha) = a floor with a
                                  ;; margin, hi as (lo hi alpha) = a ceiling with a precautionary tip — the
                                  ;; catalogue's own row, both walls at once. The three keywords
                                  ;; above are spellings of one edge each; all four pour into the
                                  ;; one *band* table (repro-bands / apply-repro-bands!).
                                  (bands '())
                                  ;; robust multi-scenario (Phase 3): a list of <planning-scenario>.
                                  ;; ABSENT ⇒ the single deterministic solve below, byte-for-byte
                                  ;; unchanged. PRESENT ⇒ delegate to the robust extensive-form
                                  ;; assembly; first-stage-procs = proc-ids committed before the
                                  ;; uncertainty resolves (shared across scenarios); pins = accepted
                                  ;; commitments as hand-decided first-stage columns; holds = offers
                                  ;; under live consideration, kept available as walls. See solve/robust.scm.
                                  (scenarios '()) (first-stage-procs '()) (pins '()) (holds '())
                                  (arc-table '()) (arc-topology? #f) (manners '()) (never-raw '()) (raws '())
                                  (resource-suppliers '())
                                  (composition '())          ; the chemistry → element rows (ingest-located!)
                                  ;; the scope's ResourceSpecifications — a keep-in-place one is a
                                  ;; storage container, which is what makes a STORE recipe tile
                                  ;; along the time edge instead of across space.
                                  (specs '())
                                  ;; the voice field (solve/voice-field.scm): τ, the scope fold's pushes
                                  ;; ((part . push) …), its hours reader (part → hours), and the
                                  ;; path of scopes this solve stands in (leaf first). τ = 0 ⇒ today.
                                  (voice-tau 0.0) (voice-pushes '()) (voice-hours #f) (scope-path #f)
                                  ;; the other governed dials (scope/policy.scm, the one
                                  ;; registry): stated, each sets its global for this solve;
                                  ;; unstated, the global stands as it is
                                  (pref-bound #f) (emp-rho #f) (kappa #f) (want-as-cap 'unstated) (stock-draw-hours #f)
                                  (certificates '())               ; ((aid . drawable-hours) …): the certificate bundles (*certificates*)
                                  (rest-standard 1)                ; the scope's ratified rest standard (scope/policy.scm), read by ingest's reservation of rest
                                  ;; #:rest keeps the keyword list this call was actually given, so
                                  ;; the robust branch below forwards the WHOLE world instead of a
                                  ;; hand-copied subset of it — the copy that silently lost #:manners
                                  ;; and #:arc-table for every bioregion-placed scope. Still strict:
                                  ;; an unknown keyword raises here, at the boundary callers use.
                                  #:rest opts)
  (when (and (or (pair? pins) (pair? holds)) (null? scenarios))
    ;; a pin or hold the assembly would not read is the silent-ignore failure
    ;; mode the commitment-horizon note forbids — refuse loudly until the
    ;; deterministic path carries them too.
    (error "plan-from-records: #:pins/#:holds require #:scenarios (the robust assembly) — the deterministic path does not read them yet"))
  (if (pair? scenarios)
      (apply robust-plan-report resources agents spatials recipe-procs recipe-flows opts)
      (begin
  ;; the world and the two held keywords, forwarded by KIND off the keyword
  ;; list this call was given (solve/keywords.scm): what the caller stated
  ;; reaches the ingest, what it left unstated takes the ingest's own default,
  ;; the same defaults this door declares
  (apply ingest-records! resources agents spatials recipe-procs recipe-flows
         (pick-keywords opts '(world held)))
  ;; the voice field's inputs and the governed dials, after ingest's reset —
  ;; the settings kind, as the robust assembly applies them
  (apply apply-solve-settings! (pick-keywords opts '(setting)))
  ;; the tier table, the budgeted floors and the reproduction bands, poured as
  ;; every assembly pours them (solve/ingest.scm pour-bands!)
  (when (and (getenv "PLANNER_PD_DEBUG") (pair? budgeted-floors)) (format (current-error-port) "  [budget] laid ~s~%" budgeted-floors))
  (pour-bands! #:repro-floors repro-floors #:budgeted-floors budgeted-floors #:repro-caps repro-caps
               #:insurance insurance #:bands bands #:acquire acquire #:promote promote)
  ;; §7 — THE DISCRETE LAYER, when the recipes call for it. A minimum batch or a
  ;; whole count declared on any process opens the branch-and-bound; it leaves
  ;; the incumbent's config, cuts and fixings in the tables `build-located`
  ;; reads, so the solve below IS the incumbent's program. A scope with neither
  ;; declaration takes this branch as a no-op: `substitute-fixed` with nothing
  ;; fixed returns its arguments, and the solve is the one it always was.
  (parameterize ((*bnb-nodes* (or node-budget (*bnb-nodes*))))   ; this solve's budget: the search and its certificate read it
  (let* ((discrete (and (discrete-declared?)
                        (call-with-values (lambda () (solve-discrete #:seed decided)) list)))
         (decided-now (and discrete (decided-state))))     ; the state THIS search leaves, for the next solve's #:decided
  (call-with-values build-located
    (lambda (forms lf ncol cols goods raws idx)
      ;; warm re-solve (METABOLISM): if a standing x of the same shape is given,
      ;; re-centre from it at a small t — a few Newton steps, not a cold solve.
      (let* ((warm? (and warm-x (= (vector-length warm-x) ncol)))
             (x0 (if warm? warm-x (located-warm cols ncol idx)))
             (ts (cond (tstart tstart) (warm? *metabolism-tstart*) (else 1.0))))
      ;; a DECIDED count is a fact, not a variable (§7): it leaves the program
      ;; here, before the solve, and `col-value` reads it back below
      (call-with-values (lambda () (substitute-fixed forms lf ncol cols idx x0))
        (lambda (forms lf idx x0)
      (let* (;; clear the published verdict first, so `plan-verdict` below reads
             ;; THIS solve's answer rather than whatever the previous one left in
             ;; the global. A backend that publishes nothing leaves `unknown`,
             ;; which is the honest reading of "no verdict was produced".
             (_cert (set-last-certificate! '((feasible? . unknown))))
             (res (call-with-values (lambda () (solve forms lf x0 ts)) list))
             (x (car res)) (tfin (if (>= (length res) 2) (list-ref res 1) 0.02))
             (ntot (if (>= (length res) 4) (list-ref res 3) 0)))
        (call-with-values (lambda () (plan->work x cols idx))
          (lambda (ints coms candidates)
            (values ints coms (plan->material x cols idx)                       ; + the material flows (produce/consume/use/pickup/dropoff)
                    (mean-fill (flatten forms) x) cols x idx ntot
                    (cons (cons 'candidates candidates)                          ; the offer FIELD: per need, the candidate workers + fair shares
                          (cons (cons 'certificate (let ((c (plan-verdict forms tfin)))
                                                     (assert-plan-invariants! c allow-infeasible?)
                                                     ;; what the search proved rides with the
                                                     ;; convex certificate it rests on
                                                     (if discrete (cons (cons 'discrete (discrete-certificate discrete)) c) c)))     ; feasibility + gap ≤ m·t, as data
                                ;; …and what it DECIDED rides as plan state, to be
                                ;; handed back through #:decided on the next solve
                                (append (if decided-now (list (cons 'decided decided-now)) '())
                                        (if (pair? acquire) (acquire-bill x cols idx) '())   ; what the walls made it buy
                                        (solve-report x cols idx tfin))))))))))))))))))    ; +begin/if for the #:scenarios guard, +parameterize for the budget

;; THE THREE BILLS — the plan asked backwards. With everything in ACQUIRE for
;; sale at its price in hours, hold one tier after another as a wall and read
;; what the solve had to buy: rights alone (the floors), rights and needs
;; (held margins at their ease), all three (every want at its ask). Each bill
;; is the cheapest mix at the margin — a floor on what the tier needs and the
;; resource to look at first, never a recipe. A tier whose certificate is
;; infeasible hit a wall nothing sells — an ecological limit, unless named.
(define (bills-fold run)
  "RUN : tier → (bill-rows feasible?). Runs 'none for the residue, then rights,
   needs, wants, each bill net of the residue — externality's one difference
   (`paired-difference`), the tier held against nothing held, with `bill-net` as
   the minus: ((tier (bill . rows) (hours . h) (step . Δh) (feasible? . f)
   (residue . h0) (residue-bill . rows0)) …)."
  (let* ((runs (list (cons 'none (run 'none))))
         (solve-at (lambda (tier)
                     (or (assq-ref runs tier)
                         (let ((r (run tier))) (set! runs (cons (cons tier r) runs)) r))))
         (residue (car (solve-at 'none)))
         (h0 (fold + 0.0 (map caddr residue)))
         (prev 0.0))
    (map (lambda (tier)
           (let* ((bill (paired-difference solve-at car tier 'none #:minus bill-net))
                  (r (solve-at tier))
                  (h (fold + 0.0 (map caddr bill)))
                  (row `(,tier (bill . ,bill) (hours . ,h) (step . ,(- h prev))
                               (feasible? . ,(cadr r)) (residue . ,h0) (residue-bill . ,residue))))
             (set! prev h)
             row))
         '(rights needs wants))))
(define (plan-bills resources agents spatials recipe-procs recipe-flows . kw)
  "The three bills over records (bills-fold): every tier solved with #:allow-infeasible? #t."
  (let ((kw* (kw-without kw '(#:promote #:allow-infeasible?))))
    (bills-fold
     (lambda (tier)
       (call-with-values
           (lambda () (apply plan-from-records resources agents spatials recipe-procs recipe-flows
                             #:promote tier #:allow-infeasible? #t kw*))
         (lambda (ints coms material fill cols x idx ntot report)
           (let ((cert (assq-ref report 'certificate)))
             (list (or (assq-ref report 'bill) '()) (and cert (assq-ref cert 'feasible?))))))))))

;; THE ONE DOOR, on the clock. Every solve — deterministic, robust, a search
;; node's parent program — passes here, and each leaves one line on stderr
;; naming its shape and its wall time: how many futures, periods and columns
;; it carried, how many barrier steps it took, and the seconds the caller's
;; vat was held for. A cadence question ("why did this scope take seven
;; minutes?") is answered by reading the line, never by inference.
(define (plan-from-records resources agents spatials recipe-procs recipe-flows . kw)
  (let* ((t0  (get-internal-real-time))
         (kwv (lambda (k) (let ((m (memq k kw))) (and m (pair? (cdr m)) (cadr m)))))
         (ns  (length (or (kwv #:scenarios) '())))
         (per (let ((p (kwv #:periods)) (h (kwv #:horizon)) (ps (kwv #:period-spans)))
                (cond ((and h (pair? h)) (cdr h)) ((list? ps) (length ps)) ((list? p) (length p)) (else 1)))))
    (call-with-values
        (lambda ()
          ;; a program with no answer names what it was asked to floor and
          ;; to meet — the log then says WHICH standing term, not only that
          ;; one is unmeetable — and the raise goes on to its caller
          (with-throw-handler* 'planner-starvation
            (lambda () (apply %plan-from-records resources agents spatials recipe-procs recipe-flows kw))
            (lambda _
              (format (current-error-port) "  [solve] starved; repro-floors=~s budgeted-floors=~s holds=~s pins=~s~%"
                      (kwv #:repro-floors) (kwv #:budgeted-floors) (kwv #:holds) (kwv #:pins))
              (format (current-error-port) "  [solve] starved; demand=~s~%" (kwv #:demand))
              (format (current-error-port) "  [solve] starved; agents=~s~%"
                      (map (lambda (a) (list (agent-id a) (agent-type a) (agent-primary-location a)))
                           agents))
              (format (current-error-port) "  [solve] starved; procs=~s~%"
                      (map recipe-process-id recipe-procs))
              (format (current-error-port) "  [solve] starved; resources=~s~%"
                      (map (lambda (r) (list (economic-resource-id r) (economic-resource-conforms-to r)
                                             (economic-resource-current-location r)
                                             (and=> (economic-resource-onhand-quantity r) measure-has-numerical-value)))
                           resources)))))
      (lambda (ints coms material fill cols x idx ntot report)
        ;; a plan the certificate refuses names what it was asked to floor:
        ;; the log then says which standing term the program could not
        ;; clear, beside how far it missed
        (let ((c (assq-ref report 'certificate)))
          (when (and (list? c) (eq? #f (assq-ref c 'feasible?)))
            (format (current-error-port) "  [solve] infeasible; repro-floors=~s demand-cells=~a certificate=~s~%"
                    (kwv #:repro-floors) (length (or (kwv #:demand) '()))
                    (filter (lambda (kv) (memq (car kv) '(violation breached worst))) c))))
        ;; PLANNER_COLS_AT=<place>: the columns whose key names that place —
        ;; the direct read of "does anything land there"
        (let ((at (getenv "PLANNER_COLS_AT")))
          (when at
            (format (current-error-port) "  [solve] periods=~s spans=~s floors→~s~%"
                    *periods* (map (lambda (t) (period-span t)) *periods*)
                    (map (lambda (rf) (cons (car rf) (*locate-key* (car rf)))) (or (kwv #:repro-floors) '()))))
          (when at
            (let ((hits (filter (lambda (c) (string-contains (col-key c) at)) cols)))
              (format (current-error-port) "  [solve] ~a column(s) name ~s: ~s~%"
                      (length hits) at (map col-key (list-head hits (min 6 (length hits)))))
              (for-each (lambda (c) (format (current-error-port) "    ~a → flows ~s labour ~a~%" (col-key c) (col-flows c) (col-labour c)))
                        (list-head hits (min 2 (length hits)))))))
        (format (current-error-port)
                "  [solve] futures=~a periods=~a columns=~a x=~a steps=~a~a~a ~,1fs~%"
                (max ns 1) per (length cols) (if (vector? x) (vector-length x) "?") ntot
                (if (assq-ref report 'discrete) " discrete" "")
                (let* ((mm (assq-ref report 'maximin))
                       (c  (or (assq-ref report 'certificate) *last-certificate*))   ; the solve's own, when the report carries it
                       (st (and (list? c) (assq-ref c 'stationarity))))
                  (string-append
                   (if (pair? *budgeted-floors*) (format #f " budgeted=~a" (length *budgeted-floors*)) "")
                   (if (and mm (assq-ref mm 'tau))
                       (format #f " maximin τ=~,2f ~a" (assq-ref mm 'tau)
                               (map (lambda (f) (format #f "~a:~,2f/~,0f/slack ~,1f" (car f) (caddr f) (cadr f) (if (> (length f) 3) (cadddr f) 0.0))) (or (assq-ref mm 'futures) '())))
                       "")
                   (if (list? c)
                       (format #f " cert=~a/~a/stat ~a" (or (assq-ref c 'backend) "?") (if (assq-ref c 'optimal?) "optimal" "NOT-optimal")
                               (if (number? st) (format #f "~,1e" st) "?"))
                       "")
                   (if (kwv #:warm-x) " warm" "")))
                (/ (- (get-internal-real-time) t0) 1.0 internal-time-units-per-second))
        (values ints coms material fill cols x idx ntot report)))))
