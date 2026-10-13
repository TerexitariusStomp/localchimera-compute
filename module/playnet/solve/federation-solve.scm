;;; module/playnet/solve/federation-solve.scm — the records→scope-record bridge + a federated solve.
;;;
;;; Turns sovereign communes (each a bag of VF records) into a cross-vat
;;; decomposition: build each commune's OWN located LP with the shared prelude
;;; (`ingest-records!` → `build-located`), give each good that crosses its
;;; crossing column, and hand the lot to `solve-decomposed` (scaled-dual ADMM).
;;; The ADMM drives what is supplied to what is drawn on every good and returns
;;; the dual λ — the PULL on the good, in labour-hours, one number for every
;;; commune that shares it. Separate solves, a scalar across the vat boundary,
;;; converging to the joint optimum.
;;;
;;; Design notes (learned the hard way — see docs/planning/federation/FEDERATED-SOLVE.md):
;;;   • a commune holds ONE column per good that crosses: its draw on the
;;;     crossing, a recipe the located build emits natively (the good entering
;;;     its balance), measured from what the commune can give (solver.scm
;;;     `offset-column`). Whether the commune supplies the good or draws it is
;;;     where the solve leaves that column; nobody states it. No solver change.
;;;   • what the commune can give is read off its own program (`give-bound`):
;;;     what it holds, less what its floors have taken, plus what it can make.
;;;   • let the INTERMEDIATE cross, not the finished good — then the crossing is
;;;     a commune's only source and the coupling binds (a finished good drawn
;;;     across is a free source the demand-barrier grabs regardless, and the
;;;     dual diverges).
;;;   • mark the good #:never-raw so it is not a free raw.
;;;
;;; A module above the engine: it reads the world by name (solve/world) and
;;; the engine's prelude (ingest-records!, build-located, located-warm), its
;;; crossings and solve-decomposed; the compiler's rp and make-recipe-flow.

(define-module (playnet solve federation-solve)
  #:use-module (playnet vf formulas flows)
  #:use-module (playnet solve world)
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf formulas actions)
  #:use-module (playnet vf facts located)
  #:use-module ((playnet solve externality) #:select (withdrawal-displacement paired-difference))
  #:use-module (playnet solve admm-link)
  #:use-module (playnet solve solver)
  #:use-module (playnet solve compile)
  #:use-module (playnet solve engine)
  #:use-module (playnet solve discrete)
  #:use-module (playnet solve decomposed)
  #:use-module (playnet solve ingest)
  #:use-module (playnet solve report)
  #:use-module (playnet solve records)
  #:export (allocate-means-consensus boundary-bounds close-stranded-links commune->scope-record
            crossing-recipe eisenberg-gale-split federated-delivered federated-dilemma federated-flows
            federated-materials federated-per-scope federated-relaxed-scopes federated-result
            federated-scope-pulls federated-solve federated-withdrawal-displacement loose-gives
            records-means-world warm-boundary-flows))

;; the crossing column, as a trivial recipe (process + one flow): the good
;; entering the commune from the crossing, a unit a unit
(define (crossing-recipe good)
  (cons (rp (string-append "cross-" good) (string-append good " across the boundary"))
        (list (make-recipe-flow #:id (string-append "crossf-" good) #:action 'produce #:resource-conforms-to good
                                #:resource-quantity (make-measure 1.0 "kg") #:recipe-output-of (string-append "cross-" good)))))

;; records → a solve-decomposed scope-record. `crossing` is the goods that
;; cross this commune's boundary (the good name IS the link key here, so the
;; communes that share a good meet on it). Reuses ingest-records! + build-located.
;; a located-good demand key "spec#place@period" → (spec place period) triple.

;; REPRODUCTION ACROSS THE BOUNDARY. A commune's per-person subsistence floors
;; (live.scm `scope-consumption`: "<nutrient>|<pid>#<place>@<t>") are applied here
;; exactly as `plan-from-records` applies them — subtracted from the good's `*init*`
;; AFTER ingest seeds it and BEFORE build-located reads it, so the floor becomes a
;; balance the commune's own LP must close.
;;
;; What that buys, and it is the whole point of carrying them this far: a commune
;; whose people cannot be fed from its own production has an unclosable balance,
;; and the ONLY way to close it is across the boundary. So the ADMM's pull λ on
;; the good that crosses is driven by somebody's reproduction floor — not by a demand
;; someone chose to state. A city is many scopes; "free food for everyone in the
;; city" is exactly the claim that every scope's floors close once the boundaries
;; are open, and this is where that claim becomes solvable rather than rhetorical.
;;
;; The floors stay INSIDE the commune that owns the bodies. Nothing about a
;; person crosses the vat boundary — only the good does, and only its pull comes
;; back. That is the same sovereignty the rest of the federated solve keeps, and
;; it is also the answer to the surveillance objection: the neighbouring commune
;; learns a pull, never a plate.
;; The labour side of a commune's record, read off its standing pool instead of
;; shipped agent records. Entries are the pool's alist projections —
;; ((agent . aid) (skill . spec) (window . w) (cell . c) (hours . h)), one per
;; (agent, skill) — so the roster the fold maintains is the roster the solve
;; ingests: hours from the entry, skills from the entry keys, one body per aid.
(define (labour-entries->agents entries)
  (let loop ((es entries) (seen '()) (agents '()))
    (if (null? es) (reverse agents)
        (let* ((e (car es)) (aid (assq-ref e 'agent)))
          (if (member aid seen) (loop (cdr es) seen agents)
              (loop (cdr es) (cons aid seen)
                    ;; the entry's PLACE is the cell the located solve files the
                    ;; hours under — without it the person is remote and their
                    ;; commune's cell stands UNCAPPED (ingest's zero-fill reaches
                    ;; only peopled places), which is the opposite of a bound
                    (cons (make-agent #:id aid #:type 'person #:name aid #:note "" #:image ""
                                      #:primary-location (assq-ref e 'place) #:classified-as '()
                                      #:availability-window (assq-ref e 'window))
                          agents)))))))
(define (labour-entries-skills entries)
  (lambda (a)
    (filter-map (lambda (e) (and (equal? (assq-ref e 'agent) (agent-id a))
                                 (assq-ref e 'skill)))
                entries)))

(define* (commune->scope-record resources agents spatials procs flows
                                #:key (id #f) (demand '()) (never-raw '())
                                      ;; the goods that cross the commune's boundary
                                      (crossing '())
                                      (repro-floors '()) (repro-caps '()) (insurance '()) (bands '())
                                      ;; the fold's standing roster; #f keeps the
                                      ;; record-shipping read (tests, no pool wired)
                                      (labour-entries #f)
                                      ;; the barbell's slope: ((proc-id . (lo hi α w)) …),
                                      ;; engine *proc-frag* — a near-fragile recipe's acts
                                      ;; held in the commune's subproblem as in its own solve
                                      (proc-frag '())
                                      ;; the governed dials and the voice field, as the
                                      ;; engine's keywords (solve/keywords.scm setting kind),
                                      ;; written after ingest as the plain solve writes them
                                      (settings '())
                                      ;; the scope's world beyond its raw records: the
                                      ;; standing caps (the UC allocation, the socialized
                                      ;; Svc| pools) and the governed pool spans — what
                                      ;; the service's world-of reads for every solve
                                      (eco-caps '()) (span-of '())
                                      ;; the plan's dated day(s), (start-iso . n) as
                                      ;; plan-from-records takes it — laid before the
                                      ;; roster is read, so a window's hours are the
                                      ;; hours it holds on the day; #f keeps the
                                      ;; span-less single period (fixtures)
                                      (horizon #f))
  ;; A period here is a WHOLE day. The record carries one crossing column per
  ;; good that crosses — the link key is the good — so the day is the
  ;; denomination a member shares in, and the clock boundaries its roster
  ;; declares stay inside the member's own solve (the descent's), where each
  ;; band has its own columns. A window is read as its hours within the day.
  (define refine? #f)
  (define goods (delete-duplicates crossing))
  (let* ((recipes (map crossing-recipe goods))
         (procs* (append procs (map car recipes)))
         (flows* (append flows (append-map cdr recipes))))
    (if labour-entries
        ;; the entries' windows ride on the synthesized agents, so the default
        ;; #:agent-hours (agent-window-hours) reads them conformantly — period
        ;; intersection and the no-window fallback included
        (ingest-records! resources (labour-entries->agents labour-entries)
          spatials procs* flows*
          #:demand demand #:never-raw never-raw #:per-agent? #f #:proc-frag proc-frag
          #:eco-caps eco-caps #:span-of span-of
          #:horizon horizon #:refine-periods? refine?
          #:agent-skills (labour-entries-skills labour-entries))
        (ingest-records! resources agents spatials procs* flows*
          #:demand demand #:never-raw never-raw #:per-agent? #f #:proc-frag proc-frag
          #:eco-caps eco-caps #:span-of span-of
          #:horizon horizon #:refine-periods? refine?))
    (apply apply-solve-settings! settings)
    ;; the reproduction bands, poured as every solve pours them
    (pour-bands! #:repro-floors repro-floors #:repro-caps repro-caps #:insurance insurance #:bands bands)
    (call-with-values build-located
      (lambda (forms lf ncol cols goods* raws idx)
        ;; THE CROSSING STANDS AT ONE CELL. The draw recipe is laid wherever the
        ;; commune's places and periods lay a recipe; the first of its columns
        ;; by key is the crossing, the same on every build, and the others leave
        ;; the program (`detach-column`): a column nothing agrees on is a source
        ;; from nowhere.
        (let* ((keys (hash-map->list (lambda (k i) k) idx))
               (columns-of (lambda (good)
                             (let ((proc (string-append "cross-" good)))
                               (map (lambda (k) (hash-ref idx k))
                                    (sort (filter (lambda (k) (equal? (key-process k) proc)) keys) string<?)))))
               (held (filter-map (lambda (good)
                                   (let ((cs (columns-of good)))
                                     (and (pair? cs) (cons good cs))))
                                 goods))
               (crossing-cols (map cadr held))
               (forms (fold (lambda (col fs) (detach-column fs col 0.0))
                            forms (append-map cddr held)))
               ;; what the commune holds of the good where the column lands
               (on-hand (lambda (col)
                          (let ((c (find (lambda (c) (= (hash-ref idx (col-key c)) col)) cols)))
                            (fold (lambda (fc a)
                                    (if (> (cdr fc) 0.0) (+ a (max 0.0 (hash-ref *init* (car fc) 0.0))) a))
                                  0.0 (col-flows c)))))
               ;; WHAT THE COMMUNE CAN GIVE of each good, off its own program. A
               ;; good nothing in the commune uses has no balance to read: the
               ;; build writes none for a stock that only stands. What the
               ;; commune holds of it is then what it can give, and the column's
               ;; own wall is that balance. A good the commune makes WITHOUT
               ;; BOUND has no measure, and a crossing nothing measures is not
               ;; one the commune takes part in: its column leaves the program
               ;; (`detach-column`) and the record names it (`unbounded`), the
               ;; way a derived crossing set can reach goods nobody capped.
               (measured (map (lambda (h)
                                (call-with-values (lambda () (give-bound forms ncol (cadr h) #:crossing crossing-cols))
                                  (lambda (G culprit)
                                    (cond ((< G +inf.0) (list h (cons (car h) G) #f))
                                          ((not culprit) (list h (cons (car h) (on-hand (cadr h))) #f))
                                          (else (list h #f (find (lambda (k) (= (hash-ref idx k) culprit)) keys)))))))
                              held))
               (unbounded (filter-map (lambda (m) (and (not (cadr m)) (cons (car (car m)) (caddr m)))) measured))
               (forms (fold (lambda (m fs) (if (cadr m) fs (detach-column fs (cadr (car m)) 0.0)))
                            forms measured))
               (held (filter-map (lambda (m) (and (cadr m) (car m))) measured))
               (gives (filter-map cadr measured))
               (forms (fold (lambda (h g fs) (offset-column fs (cadr h) (cdr g))) forms held gives))
               (x0 (let ((v (located-warm cols ncol idx)))
                     (for-each (lambda (h g)
                                 (vector-set! v (cadr h) (+ (vector-ref v (cadr h)) (cdr g))))
                               held gives)
                     (for-each (lambda (col) (vector-set! v col 5e-10)) (append-map cddr held))
                     v)))
          ;; solve-decomposed reads only forms/labform/x0/crossings; the rest
          ;; rides along so federated-materials can decode this commune's
          ;; post-ADMM plan back into per-location fill (for the desire overlay).
          (list (cons 'forms forms) (cons 'labform lf) (cons 'x0 x0)
                ;; the draw on the crossing, measured from what the commune can
                ;; give; a commune that can give nothing holds a column that
                ;; only takes, its offset nothing
                (cons 'crossings (map (lambda (h g)
                                        (cons* (cadr h) (car h) -1 (if (zero? (cdr g)) 0 (cdr g))))
                                      held gives))
                (cons 'gives gives)
                ;; the crossings the commune cannot measure and so stays out of:
                ;; ((good . culprit-column-key) …)
                (cons 'unbounded unbounded)
                (cons 'scope-id id) (cons 'cols cols) (cons 'idx idx)
                (cons 'repro-floors repro-floors)
                ;; THE FEDERATED SOLVE KEEPS THE RELAXATION. The ADMM's guarantee —
                ;; separate solves settling at one pull, converging to the joint
                ;; optimum — is a convex one: a pull read off a scope's
                ;; branch-and-bound is not that scope's dual, and a consensus over
                ;; such pulls has no convergence to promise. So a commune whose
                ;; recipes declare a minimum batch or a whole count is solved here to
                ;; the digit, and the record says so — the same word the two-stage
                ;; robust path uses for its recourse (`relaxed`) — so a federated plan
                ;; is never mistaken for a decided one. Deciding across a boundary
                ;; (each scope's tree against the standing pull, the pull
                ;; settled again; a Lagrangian relaxation with a duality gap to report)
                ;; is a research thread, and this marker is where it would land.
                (cons 'discrete (if (discrete-declared?) 'relaxed 'none))
                ;; the demand as (spec place period qty) tuples — what location-slacks wants
                (cons 'demand-tuples
                  (filter-map (lambda (d)
                                (let ((t (parse-located-good (car d))))
                                  (and t (append t (list (cdr d)))))) demand))))))))

;; a plan as `federated-solve` answers it, read on the goods that cross:
;; ((good . flow) …), each flow signed — above nothing the commune supplies
;; the good, below it draws
(define (federated-flows rec plan)
  (map (lambda (c) (cons (crossing-key c) (* (crossing-sign c) (vector-ref plan (crossing-col c)))))
       (record-crossings rec)))

;; ── A LOOSE GIVE-BOUND, SAID ────────────────────────────────────────────────
;; The verdict judges a breach against the row's own scale (solver.scm
;; `%feasible-tol` of `form-scale`), and a column measured from G carries G on
;; every row that holds it. So on those rows a breach below %feasible-tol·G
;; reads as noise, in the good's own unit. With G the stock a commune holds
;; that is grams against kilograms. With G a bound propagated through a long
;; chain of makers it can stand above everything that crosses, and the noise
;; with it. This reading names those crossings, after the solve, against what
;; the plan put on the good.
(define* (loose-gives commune-records plans #:key (share 1e-2))
  "((scope-id good G crossed noise) …): the crossings whose give-bound is
   loose. G the most the commune can give of the good (the record's `gives`);
   CROSSED what the plans supply of it together; NOISE = %feasible-tol·G, the
   breach the verdict passes on a row the column stands on. A crossing is named
   when NOISE exceeds SHARE of CROSSED. A good on which nothing crosses names
   nobody: there is no flow for the noise to be read against."
  (let* ((flows (map federated-flows commune-records plans))
         (crossed (lambda (good)
                    (fold (lambda (fs a)
                            (let ((y (assoc-ref fs good))) (if (and y (> y 0.0)) (+ a y) a)))
                          0.0 flows))))
    (append-map
     (lambda (rec)
       (filter-map (lambda (g)
                     (let* ((G (cdr g)) (c (crossed (car g))) (noise (* %feasible-tol G)))
                       (and (> c 1e-9) (> noise (* share c))
                            (list (assq-ref rec 'scope-id) (car g) G c noise))))
                   (or (assq-ref rec 'gives) '())))
     commune-records)))

;; run the ADMM over a list of commune scope-records; returns
;; (values plans met rounds pulls) where pulls is a hash good→λ, the pull on
;; each good. This is the whole cross-vat solve: each record is a sovereign
;; commune's own LP, coupled only by the pulls on what crosses. (A live caller
;; gathers each commune's records from its scope-root's stores — the same four
;; reads plan-scope does — and hands them to commune->scope-record; see
;; service.scm `federated-plan`.) A plan is answered as the recipes mean it: a
;; crossing column reads as the draw it stands for (`record-plan`), so a
;; commune that supplies reads below nothing there, and `federated-flows` says
;; its flow.
(define* (federated-solve commune-records #:key (rho 4.0) (iters 120) (accel #t) (z0 '()))
  (call-with-values
      (lambda () (solve-decomposed commune-records #:rho rho #:iters iters #:accel accel #:z0 z0))
    (lambda (plans met rounds pulls)
      (values (map record-plan commune-records plans) met rounds pulls))))

;; ── the folds feeding the dual: a warm consensus ───────────────────────────
;; What crosses a boundary is bounded before any round runs: a commune that
;; asks more of the good than it holds needs the rest (its demand, net of its
;; own stock — reproduction floors included, since they are demand the commune
;; cannot choose away), and one that holds more than it asks can give the
;; rest. The folds carry both sums; this reads them off the scope records'
;; demand-tuples and resources and hands solve-decomposed its starting flows
;; per good. The fixed point is unchanged — only the distance to it.
(define (crossing-positions commune-records resources-of)
  "((good (on-hand . want) …) …): per good that crosses, in record order, what
   each commune that shares it holds of it and what its stated demand asks."
  (let ((goods (delete-duplicates
                (append-map (lambda (rec) (map crossing-key (record-crossings rec))) commune-records))))
    (map (lambda (good)
           (cons good
                 (filter-map
                  (lambda (rec)
                    (and (any (lambda (c) (equal? (crossing-key c) good)) (record-crossings rec))
                         (let ((res (or (resources-of (assq-ref rec 'scope-id)) '())))
                           (cons (fold (lambda (r a)
                                         (if (equal? good (economic-resource-conforms-to r))
                                             (+ a (measure-has-numerical-value
                                                   (economic-resource-onhand-quantity r)))
                                             a))
                                       0.0 res)
                                 ;; what its demand tuples ask in the goods this one
                                 ;; feeds, read as the good's own unit 1:1 (the crossing
                                 ;; recipe is a unit a unit) — a bound, not a forecast
                                 (fold (lambda (d a) (+ a (or (cadddr d) 0.0))) 0.0
                                       (or (assq-ref rec 'demand-tuples) '()))))))
                  commune-records)))
         goods)))

(define (warm-boundary-flows commune-records resources-of)
  "((good y …) …) — for each good that crosses, a signed flow per commune that
   shares it, in record order: what it holds beyond what it asks, given, and
   what it asks beyond what it holds, drawn, scaled so that what is given is
   what is drawn. RESOURCES-OF: scope-id → resources."
  (map (lambda (g)
         (let* ((nets (map (lambda (p) (- (car p) (cdr p))) (cdr g)))
                (over (fold + 0.0 (map (lambda (n) (if (> n 0.0) n 0.0)) nets)))
                (short (fold + 0.0 (map (lambda (n) (if (< n 0.0) (- n) 0.0)) nets)))
                (F (min over short)))
           (cons (car g)
                 (map (lambda (n)
                        (cond ((and (> n 0.0) (> over 0.0)) (* n (/ F over)))
                              ((and (< n 0.0) (> short 0.0)) (* n (/ F short)))
                              (else 0.0)))
                      nets))))
       (crossing-positions commune-records resources-of)))

;; ── THE FEDERATED DILEMMA — the two horns, read off the folds ───────────────
;; A run that hits its round cap says nothing a federation can act on; two
;; named quantities do. Both stand in the folds BEFORE any round runs, and
;; reading them there is what the 2026-08-08 attempt (history of this file)
;; lacked — it tried to derive the requirement from an uncapped draw and got
;; 843 kg for a 6.25 kg need, because a solve indifferent above its floors
;; does not report a minimum. The folds do:
;;
;;   HORN A — hold the floors: how much must cross for every body to be fed?
;;            = Σ over the communes of (demand − own stock) where that is
;;              positive, the floor-driven deficit the demand fold carries
;;   HORN B — hold the supply: which floors miss, and by how much?
;;            = the stock the communes hold, and need − stock where that is
;;              positive
;;
;; So the dilemma is arithmetic over the bounds, never a solve: a run is a
;; genuine shortfall when need > stock (no allocation exists — divergence is
;; the right answer), and a surplus nobody claimed when need ≤ stock (the
;; pull failed to settle an abundance — a modelling or convergence matter,
;; not an impossibility). The diagnosis federated-repro-test distinguishes by
;; round count is named here by quantity.
(define (boundary-bounds commune-records resources-of)
  "((good need stock) …) per good that crosses: what the communes that share
   it ask beyond what each holds, and what they hold of it together.

   NEED is read off STATED demand (the record's demand-tuples, the demand
   fold's cells). A reproduction floor is stated in the nutrient's own unit
   — kcal of energy, mg of iron — and what that is in kilograms of the good
   runs through the recipe chain, which is the solve; the fold does not
   carry it. So a commune whose only demand is floors reads as need 0 here,
   and federated-dilemma flags that case (`floors-only`) instead of calling
   it covered: the horn it cannot name is named as unnamed."
  (map (lambda (g)
         (list (car g)
               (fold + 0.0 (map (lambda (p) (max 0.0 (- (cdr p) (car p)))) (cdr g)))
               (fold + 0.0 (map car (cdr g)))))
       (crossing-positions commune-records resources-of)))

(define (federated-dilemma commune-records resources-of)
  "The two horns per good that crosses, as the federation can act on them:
   ((good (need . N) (stock . S) (verdict . V) (missing . max(0,N−S))) …)
   V is `shortfall` (need exceeds what the communes hold — no allocation
   exists, and divergence is the right answer), `covered` (the stock covers the
   stated need — a run at its cap is a surplus nobody claimed, a convergence
   or modelling matter), or `floors-only` (a commune states floors and no
   demand: its need is a solve away, and this read does not pretend to it)."
  (let ((floors-only?
         (any (lambda (rec)
                (and (pair? (record-crossings rec))
                     (null? (or (assq-ref rec 'demand-tuples) '()))
                     (pair? (or (assq-ref rec 'repro-floors) '()))))
              commune-records)))
    (map (lambda (b)
           (let ((good (car b)) (n (cadr b)) (st (caddr b)))
             `(,good (need . ,n) (stock . ,st)
                     (verdict . ,(cond (floors-only? 'floors-only)
                                       ((> n (+ st 1e-9)) 'shortfall)
                                       (else 'covered)))
                     (missing . ,(max 0.0 (- n st))))))
         (boundary-bounds commune-records resources-of))))

;; Decode each commune's post-ADMM plan (an x vector from federated-solve's
;; `plans`, in the same order as the scope-records) into the (demand . alist)
;; shape last-solve-ref/location-slacks expects — so build-snapshot emits the
;; FEDERATED per-location demand shortfall, not the isolated one. Returns
;; ((scope-id demand-tuples solve-alist) …); a caller (service.scm federated-plan)
;; caches each via cache-solve!, and the desire overlay then shows a commune's
;; deficit draining to green as the boundary flow fills it.
(define (federated-materials plan cols idx)
  (map (lambda (mc)
         `((action      . ,(commitment-action mc))
           (conforms-to . ,(commitment-resource-conforms-to mc))
           (quantity    . ,(row-figure mc))   ; a use row's figure is its hours
           (at-location . ,(commitment-at-location mc))))
       (plan->material plan cols idx)))

(define (federated-per-scope plans commune-records)
  (map (lambda (plan rec)
         (list (assq-ref rec 'scope-id)
               (assq-ref rec 'demand-tuples)
               `((material . ,(federated-materials plan (assq-ref rec 'cols) (assq-ref rec 'idx)))
                 ;; what the scope puts on each good that crosses, signed: what a
                 ;; record of the handover reads
                 (crossing . ,(federated-flows rec plan))
                 ;; a scope's declared discreteness, kept relaxed by the federated solve
                 ,@(if (eq? 'relaxed (assq-ref rec 'discrete)) '((discrete . relaxed)) '()))))
       plans commune-records))
;; the scopes whose declared discreteness a federated solve kept relaxed
(define (federated-relaxed-scopes commune-records)
  (filter-map (lambda (rec) (and (eq? 'relaxed (assq-ref rec 'discrete)) (assq-ref rec 'scope-id)))
              commune-records))

;;; ─── THE FEDERATED DILEMMA stands — `federated-dilemma`, above ──────────
;;; A run that hits the ADMM's round cap names its two horns by quantity,
;;; read off the folds before any round: HORN A the stated need that must
;;; cross, HORN B the stock that can. The 2026-08-08 attempt read the
;;; requirement off an UNCAPPED draw (843 kg for a 6.25 kg need — a solve
;;; indifferent above its floors reports no minimum) and was rightly left out;
;;; a bound is a fold read, not a solve. What stays a solve is the need, in
;;; kilograms of the good, of a commune that states FLOORS ONLY — a nutrient
;;; floor runs through the recipe chain — and the dilemma names that case
;;; `floors-only` rather than call it covered. The round-count diagnosis federated-repro-test holds
;;; (genuine shortfall vs a surplus nobody claimed) is the same distinction.

;; ═══ THE MEANS CONSENSUS ROW — common capacity allocated across scope solves ═══
;;
;; docs/planning/federation/means-pool-uc-allocation.md §3.2 / patchwork §4a: solve-decomposed
;; couples boundary GOODS (what is supplied = what is drawn, per good); a COMMON MEANS couples
;; scopes through one row of a different shape — Σ_s alloc_s = TOTAL — with a
;; scalar dual. This is that row, run the way uc-matching runs labour: each
;; scope solves ITS OWN world with the means capped at its current allocation,
;; reports the dual on that cap (tension-duals: μ = t / remaining headroom, the
;; marginal social value of one more unit-hour HERE), and the allocation moves
;; toward equal duals — the pooled bar's own optimality condition, recovered
;; across sovereign solves without any scope reading another's records. What
;; crosses the boundary is an allocation in and a scalar out: never a plate.
;;
;; NOT a tautology, though each solve conditions on its allocation: a wrong
;; allocation REFUTES itself — the local solves, each self-consistent given its
;; cap, disagree in their marginals, and that disagreement is what the update
;; consumes. Only the joint optimum's split silences it (μ monotone in alloc ⇒
;; one fixpoint), which the test pins by matching the monolith. One round says
;; nothing; the information is in the differences and the movement — the same
;; two-level shape as solve-decomposed's pulls and uc-matching's subgradient.
;;
;; The update is multiplicative in the duals: x_s ← x_s·(μ_s/μ̄)^(1/e_s), then
;; the row renormalised to hold exactly. e_s is the scope's own elasticity,
;; −Δln μ_s/Δln x_s off its last two probes — so the step is the secant's,
;; Newton's for a power law, bounded to a factor of four a round; the first
;; round, and any round the dual failed to fall with the share, steps by the
;; fixed γ instead. A scope whose dual sits above the mean is starved relative
;; to the rest and gains; below, it cedes. Equal duals are the fixpoint — the
;; pooled bar's single-dual condition — and a CORNER (one scope at min-share)
;; is the KKT inequality showing itself: the loser's dual stays below the
;; winner's, exactly as the monolith leaves a cell undrawn. A warm start is
;; floored at min-share for the same reason the corner is one: a scope with
;; nothing has no column for the means and reads a dual of 0, and it is the
;; dual that has to speak. The dual read is tension-duals' μ = t/remaining at
;; t = 1, so with one interior-point floor shared by every scope, μ is
;; proportional to the desire pull squeezing that scope's cap — the comparison
;; is meaningful across solves. Rest is read per scope, a step small against
;; the scope's own share: a hair of the bar is a lot of a share at the floor.
;;
;; SCOPES: ((id . make-world!) …) where (make-world! alloc) ingests that scope's
;; OWN world with the shared means capped at ALLOC — sovereignty is the caller
;; keeping its records inside the closure — and returns (values x cols idx),
;; solved. SPEC names the means; TOTAL is the commons' bar in the same
;; denomination the caps use (unit-hours over the window).
;; A sovereign scope's world, from its own RECORDS — the live shape of the
;; make-world! closure allocate-means-consensus takes. The records stay inside
;; the closure (sovereignty); the allocation arrives as an eco-cap on the
;; means' Svc| good at the scope's place, exactly as a policy cap does
;; (ingest-located!: "(located-good . cap) — policy overrides stock").
(define* (records-means-world resources agents spatials procs flows spec place
                              #:key (demand '()) (never-raw '()) (raws '())
                                    (proc-frag '()) (eco-caps '()) (span-of '())
                                    (settings '()))
  ;; ECO-CAPS: the scope's standing caps beside the allocation (its other
  ;; allocations, the socialized pools); a standing cap on the good under
  ;; consensus is left out — this run decides it. The allocation is laid
  ;; period-free, `Svc|spec#place`, so it bounds every period the world lays.
  ;; The records are read ONCE, into a world of this closure's own, with the
  ;; first allocation laid as the cap the way every eco-cap is (ingest-located!
  ;; resolves it, retimes it to the refined spans, lays it at every period).
  ;; Each round solves inside a COPY of that world (a build writes its own
  ;; products into the world it reads: *requires*, *col-terms*, *col-ell*)
  ;; with those same cells set to the round's allocation, so the program's
  ;; shape is the ingest's and only the bound moves. The world is one whole
  ;; value, templates included, so a scope's world is a value held across
  ;; the rounds and the ingest is paid once per scope.
  (let ((key (lg (svc-good spec) place))
        (world #f)
        (cells '()))
    (lambda (alloc)
      (unless world
        (set! world
              (call-with-world (make-world)
                (lambda ()
                  (ingest-records! resources agents spatials procs flows
                    #:demand demand #:never-raw never-raw #:raws raws #:per-agent? #f #:proc-frag proc-frag
                    #:span-of span-of
                    #:eco-caps (cons (cons key alloc)
                                     (filter (lambda (c) (not (string-prefix? key (car c)))) eco-caps)))
                  (apply apply-solve-settings! settings)
                  (set! cells (filter (lambda (k) (string-prefix? key k))
                                      (hash-map->list (lambda (k _) k) *cap*)))
                  (current-world)))))
      (call-with-world (copy-world world)
        (lambda ()
          (for-each (lambda (k) (hash-set! *cap* k alloc)) cells)
          (call-with-values build-located
            (lambda (forms lf ncol cols goods raws idx)
              (values (car (call-with-values
                               (lambda () (solve-native forms lf (located-warm cols ncol idx))) list))
                      cols idx))))))))

(define* (allocate-means-consensus scopes spec total
                                   #:key (rounds 40) (gamma 0.5)
                                         (tol 1e-3) (min-share 1e-4)
                                         (init #f)      ; optional starting split, renormalised
                                         (ceilings '()))  ; ((id . max) …): hosting-willingness ceilings — the consent QUANTITY, binding here.
                                                          ;; Σ ceilings < TOTAL is not an error: consent cannot place the whole
                                                          ;; bar, every scope rests at its ceiling, and Σ alloc = Σ ceilings —
                                                          ;; the remainder stays with the commons, unplaced rather than forced.
  (let* ((n (length scopes))
         (svc-pfx (string-append (svc-good spec) "#"))
         ;; one scope's report at its current allocation: the mean dual on its cap
         (probe (lambda (mk-world! alloc)
                  (call-with-values (lambda () (mk-world! alloc))
                    (lambda (x cols idx)
                      (let* ((duals (tension-duals x cols idx 1.0))
                             (mine  (filter (lambda (d) (string-prefix? svc-pfx (car d))) duals)))
                        (if (null? mine) 0.0
                            (/ (fold (lambda (d a) (+ a (cdr d))) 0.0 mine)
                               (length mine))))))))
         (floor (* min-share total))
         ;; A warm start is a place to PROBE from, so every share starts
         ;; interior. A scope the last run left at zero — the row held exactly
         ;; around another's ceiling — has no column for the means at all at
         ;; zero, reads a dual of 0, and a multiplicative update keeps it at
         ;; zero for good: a standing corner would be read back as a ban.
         ;; Floored at min-share, the scope's dual speaks and the row decides.
         (allocs (if init
                     (let* ((in (map (lambda (a) (max a floor)) init))
                            (sc (/ total (fold + 0.0 in))))
                       (list->vector (map (lambda (a) (* a sc)) in)))
                     (make-vector n (/ total n)))))
    ;; the last round's (share . dual) per scope — the second point of a
    ;; secant on how each scope's dual answers its own share
    (define seen (make-vector n #f))
    (let loop ((r 0))
      (let* ((mus  (map (lambda (s i) (probe (cdr s) (vector-ref allocs i)))
                        scopes (iota n)))
             (mu*  (/ (fold + 0.0 mus) n))
             ;; The step toward equal duals. The fixed exponent γ moves a share
             ;; by (μ/μ̄)^γ, which is the right size only where the dual answers
             ;; the share about one-for-one; where the row is starved on every
             ;; side the duals sit within a few percent of each other and that
             ;; step crawls (measured: 247 rounds from a corner to a 5% split).
             ;; Two probes of one scope give its dual's ELASTICITY e = −Δln μ/
             ;; Δln x, and the share that would meet the mean is x·(μ/μ̄)^(1/e):
             ;; a secant in the log–log plane, Newton's step for a power law.
             ;; The step is bounded to a factor of four either way, and γ stands
             ;; wherever the secant has no second point or the dual failed to
             ;; fall with the share.
             (next (map (lambda (mu i)
                          (let* ((x (vector-ref allocs i))
                                 (ratio (/ (max mu 1e-12) (max mu* 1e-12)))
                                 (was (vector-ref seen i))
                                 (e (and was
                                         (> (car was) 0.0) (> (cdr was) 0.0) (> mu 0.0)
                                         (let ((dlx (log (/ x (car was))))
                                               (dlm (log (/ mu (cdr was)))))
                                           (and (> (abs dlx) 1e-9) (< (* dlm dlx) 0.0)
                                                (- (/ dlm dlx))))))
                                 (factor (expt ratio (if e (/ 1.0 e) gamma))))
                            (vector-set! seen i (cons x mu))
                            (max floor (* x (max 0.25 (min 4.0 factor))))))
                        mus (iota n)))
             ;; hold the row exactly WITHIN the willingness ceilings: scale the
             ;; unclamped shares up around the clamped ones (water-filling, at
             ;; most n passes). A ceiling is the consent envelope's quantity —
             ;; placement is where it finally binds (patchwork §4a, step 4's
             ;; note) — so the bar never grants a scope more than it offered.
             (ceil-of (lambda (i) (or (assoc-ref ceilings (car (list-ref scopes i))) total)))
             (next (let fit ((v next) (pass 0))
                     (let* ((clamped (map (lambda (a i) (min a (ceil-of i))) v (iota n)))
                            (fixed   (fold + 0.0 (filter-map (lambda (a i) (and (>= a (ceil-of i)) (ceil-of i)))
                                                             clamped (iota n))))
                            (free    (fold + 0.0 (filter-map (lambda (a i) (and (< a (ceil-of i)) a))
                                                             clamped (iota n)))))
                       (if (or (>= pass n) (< (abs (- (+ fixed free) total)) 1e-9) (= free 0.0))
                           clamped
                           (fit (map (lambda (a i) (if (< a (ceil-of i))
                                                       (* a (/ (max 0.0 (- total fixed)) free))
                                                       a))
                                     clamped (iota n))
                                (+ pass 1))))))
             ;; the step, read against each scope's OWN share: a starved scope
             ;; climbing from the floor moves by a hair of the bar and by a
             ;; lot of itself, and it is the second that says the row is still
             ;; deciding. Against the bar, its first step read as rest.
             (moved (apply max (map (lambda (a i)
                                      (/ (abs (- a (vector-ref allocs i)))
                                         (max (vector-ref allocs i) floor)))
                                    next (iota n)))))
        (for-each (lambda (a i) (vector-set! allocs i a)) next (iota n))
        (if (or (>= (+ r 1) rounds) (< moved tol))
            (values (map (lambda (s i) (cons (car s) (vector-ref allocs i))) scopes (iota n))
                    (map (lambda (s mu) (cons (car s) mu)) scopes mus)
                    (+ r 1))
            (loop (+ r 1)))))))


;;; ─── Stage 4 of truth-telling.md: pulls between scopes, persons never ───
;;; Above the owning scope the strategic actor is the SCOPE. The federated
;;; solve holds the signal already — λ per boundary good is the pull the
;;; crossing balances at — so surfacing a scope's pull to the others is a
;;; read, and what its membership moves in the others is solve/externality.scm's
;;; `withdrawal-displacement` run over scope records instead of a person's rows: the
;;; same three lines one level up.

(define (federated-scope-pulls commune-records plans pulls)
  "Per member scope, the goods it shares, its flow on each in PLANS (signed:
   above nothing it supplies, below it draws) and the pull the good settled
   at: ((scope-id . ((good flow λ) …)) …). λ is the ADMM's dual on that good —
   the marginal displacement of the scope's ask on the scopes that share it;
   #f where a good never settled."
  (map (lambda (rec plan)
         (cons (assq-ref rec 'scope-id)
               (map (lambda (f) (list (car f) (cdr f) (hash-ref pulls (car f) #f)))
                    (federated-flows rec plan))))
       commune-records plans))

(define (federated-delivered rec plan)
  "What a scope's own post-ADMM plan delivered of what it asked — its wants
   (demand-tuples) and its rights (repro-floors), each capped at the ask:
   Σ_spec min(asked, produced). One number, in the scope's own units; the
   `granted` reading a scope-level withdrawal pull differences."
  (let ((mat   (federated-materials plan (assq-ref rec 'cols) (assq-ref rec 'idx)))
        (asked (make-hash-table)))
    (define (ask! spec q) (hash-set! asked spec (+ (hash-ref asked spec 0.0) q)))
    (for-each (lambda (t) (ask! (car t) (cadddr t))) (or (assq-ref rec 'demand-tuples) '()))
    (for-each (lambda (f) (ask! (key-spec (car f)) (cdr f))) (or (assq-ref rec 'repro-floors) '()))
    (hash-fold (lambda (spec q acc)
                 (+ acc (min q (fold (lambda (m a)
                                       (if (and (memq (row-action m) creating-actions)
                                                (equal? (row-spec m) spec))
                                           (+ a (abs (or (row-quantity m) 0)))
                                           a))
                                     0.0 mat))))
               0.0 asked)))

(define (close-stranded-links commune-records)
  "COMMUNE-RECORDS with every crossing column whose good no other record
   shares DETACHED: gone from the record's crossings and from its program
   (`detach-column`), which is then the scope's own. A crossing column is a
   source or a sink in a scope's own LP — only the consensus on the good makes
   it a crossing — so a scope whose partner withdrew would otherwise draw from
   nobody. A withdrawal must leave the others with a closed border, which is
   what the withdrawn scope's absence means."
  (define (goods rec) (map crossing-key (record-crossings rec)))
  (let* ((all (append-map goods commune-records))
         (shared? (lambda (c) (> (count (lambda (g) (equal? g (crossing-key c))) all) 1))))
    (map (lambda (rec)
           (let ((stranded (remove shared? (record-crossings rec))))
             (if (null? stranded) rec
                 (append
                  (list (cons 'crossings (filter shared? (record-crossings rec))))
                  (filter-map
                   (lambda (kv)
                     (case (car kv)
                       ((crossings) #f)
                       ((forms) (cons 'forms (fold (lambda (c fs)
                                                     (detach-column fs (crossing-col c)
                                                                    (if (eqv? (crossing-offset c) 0)
                                                                        0.0
                                                                        (* -1.0 (crossing-sign c) (crossing-offset c)))))
                                                   (cdr kv) stranded)))
                       ((x0) (cons 'x0 (let ((v (vector-copy (cdr kv))))
                                         (for-each (lambda (c) (vector-set! v (crossing-col c) 5e-10)) stranded)
                                         v)))
                       (else kv)))
                   rec)))))
         commune-records)))

(define (federated-result plans commune-records)
  "A federated solve as the withdrawal pull reads it: (plans records
   feasibles) — the plans, the records they were solved over, and, off the
   certificate the solve just wrote, whether EACH scope's own floors closed.
   A scope whose plan is infeasible holds nothing: its produce rows are an
   escape's arithmetic, not a delivery. Call right after federated-solve."
  (let ((lf (assq-ref *last-certificate* 'local-feasible)))
    (list plans commune-records
          (if (and (list? lf) (= (length lf) (length commune-records))) lf
              (map (lambda (_) #t) commune-records)))))

(define* (federated-withdrawal-displacement commune-records scope-id #:key (iters 120) (z0 '()) (base #f))
  "What SCOPE-ID's membership displaces in the other scopes: the value delivered to
   the others in the federation solved WITHOUT it, minus the same read of
   BASE — the standing solve as (plans records feasibles), solved here when
   not given. Exactly solve/externality.scm's `withdrawal-displacement` with a scope record
   for a row and `federated-delivered` for the granted read. ≥ 0 up to
   solver noise for a scope that only draws; a scope that only supplies
   pulls negative — its withdrawal is the others' loss."
  (define (solve recs)
    (let ((recs (close-stranded-links recs)))   ; the withdrawn scope's border is shut, not open
      (call-with-values (lambda () (federated-solve recs #:iters iters #:z0 z0))
        (lambda (plans met rounds pulls) (federated-result plans recs)))))
  (define (granted result owner)
    (fold + 0.0 (map (lambda (plan rec ok?)
                       (if (or (not ok?) (equal? (assq-ref rec 'scope-id) owner)) 0.0
                           (federated-delivered rec plan)))
                     (car result) (cadr result) (caddr result))))
  (withdrawal-displacement solve granted (or base (solve commune-records)) commune-records
                    (lambda (rec) (not (equal? (assq-ref rec 'scope-id) scope-id)))
                    scope-id))

;;; ─── the Eisenberg–Gale door: multi-good folds settled as ONE convex solve ──
;;; truth-telling.md stage 4's last open piece. Competitive equilibrium from
;;; unequal incomes: max Σ_i b_i·log u_i(x_i) over the supplies — budgets as
;;; weights, LINEAR utilities, the goods' pulls as the duals. The engine
;;; already owns every part: a utility is a linear form, the log is the
;;; `frag` kind at fixed weight b_i, a supply is a wall. Strategyproofness
;;; arrives with size (Azevedo–Budish: gains from misreporting shrink like
;;; 1/n), which is the honest claim for a federation of scopes — contained,
;;; not cured, exactly as stage 4 says.
(define* (eisenberg-gale-split goods supplies scopes #:key (budgets #f))
  "GOODS a list of good ids; SUPPLIES ((good . S) …); SCOPES
   ((scope-id . ((good . valuation) …)) …) — each scope's linear utility.
   BUDGETS ((scope-id . b) …), equal when absent. Returns
   (values allocations pulls utilities):
     allocations ((scope-id . ((good . x) …)) …)
     pulls      ((good . p) …)  — p_g = max_i b_i·v_ig/u_i, the E–G duals
     utilities   ((scope-id . u) …)."
  (let* ((n  (length scopes)) (m (length goods))
         (gi (lambda (g) (list-index (lambda (h) (equal? h g)) goods)))
         (col (lambda (i g) (+ (* i m) (gi g))))          ; x_{ig}
         (b-of (lambda (sid) (or (and budgets (assoc-ref budgets sid)) 1.0)))
         (forms '()))
    ;; x ≥ 0
    (do ((j 0 (+ j 1))) ((= j (* n m)))
      (set! forms (cons (mk-bar 0.0 (list (cons j 1.0))) forms)))
    ;; supplies: S_g − Σ_i x_{ig} ≥ 0
    (for-each (lambda (g)
                (set! forms (cons (mk-bar (assoc-ref supplies g)
                                          (map (lambda (i) (cons (col i g) -1.0)) (iota n)))
                                  forms)))
              goods)
    ;; the objective: one fixed-weight log per scope on its own utility
    (for-each (lambda (sc i)
                (let ((vals (filter (lambda (kv) (> (cdr kv) 0.0)) (cdr sc))))
                  (when (pair? vals)
                    (set! forms (cons (mk-frag 0.0 (map (lambda (kv) (cons (col i (car kv)) (cdr kv))) vals)
                                               (b-of (car sc)))
                                      forms)))))
              scopes (iota n))
    (let* ((x0 (make-vector (* n m) 0.0)))
      ;; strictly feasible start: an equal split of every supply
      (for-each (lambda (g)
                  (do ((i 0 (+ i 1))) ((= i n))
                    (vector-set! x0 (col i g) (/ (assoc-ref supplies g) (* 2.0 n)))))
                goods)
      (let* ((x (call-with-values (lambda () (solve-native forms '() x0)) (lambda r (car r))))
             (xof (lambda (i g) (max 0.0 (vector-ref x (col i g)))))
             (u-of (lambda (sc i) (fold + 0.0 (map (lambda (kv) (* (cdr kv) (xof i (car kv)))) (cdr sc)))))
             (us  (map (lambda (sc i) (cons (car sc) (u-of sc i))) scopes (iota n))))
        (values
         (map (lambda (sc i) (cons (car sc) (map (lambda (g) (cons g (xof i g))) goods))) scopes (iota n))
         (map (lambda (g)
                (cons g (fold (lambda (sc i acc)
                                (let ((u (assoc-ref us (car sc))) (v (or (assoc-ref (cdr sc) g) 0.0)))
                                  (if (> u 1e-12) (max acc (/ (* (b-of (car sc)) v) u)) acc)))
                              0.0 scopes (iota n))))
              goods)
         us)))))
