;;; shocks.scm — the shock algebra: what a future does to a coefficient.
;;;
;;; A scenario is a forecast of FULFILLMENT RATIOS, per (action, spec) intent — the
;;; same unit the Observer measures ex-post (committed vs fulfilled). A shock is
;;; (action key factor); a bare (key . factor) is a produce (output-yield) shock —
;;; the crop case. Three channels, each an Observer-measurable ratio:
;;;   (produce KEY r)           OUTPUT yield ×r        (KEY = proc-id | output spec)
;;;   (consume|use|work KEY r)  INPUT intensity ×r     (input-per-output; r>1 a harder
;;;                             year needs more per unit, r<1 more efficient)
;;;   (avail KEY r)             a spec's SUPPLY ×r      (KEY = spec; scales raw availability)
;;; KEY unlisted ⇒ 1.0. A FOURTH form carries a period: (action key t r) applies ×r
;;; to KEY at period t alone, so one `grow` recipe reads "wet at period 1, dry at
;;; period 2" (docs/planning/solve/scenario-tree.md). A KEY may also be LOCATED,
;;; (proc-or-spec . place): one district's harvest, at that district's column.
;;;
;;; Pure — records in, shocks and factors out, no world read. Three readers:
;;;   solve/robust.scm      binds a branch's factors to the build (the weather seam);
;;;   bioregions.scm  lays a shed's tail over its record (tail-beyond-record);
;;;   reading-fold    takes the cautious direction of a witnessed reading.
;;;
;;; docs/antifragile/ is the reference this file answers to, and each of its
;;; tools lands on one definition here (docs/planning/solve/antifragile-sweep.md):
;;;   the ADVERSE DIRECTION (`more-adverse`)  — inference is asymmetric: a
;;;       reading rules a figure down, and a flattering one leaves the map
;;;       where it stands (Darwin College lecture §III);
;;;   the ENVELOPE (`record-envelope`, `tail-beyond-record`) — a forecast is
;;;       at least as extreme as its sample on every channel the sample
;;;       shocks (errors-on-errors: the forecasting paradox);
;;;   the MEAN (`mean-shocks`) — a weighted mean of bounded ratios, the one
;;;       fold behind the certainty-equivalent foil and the Observer's
;;;       calibration.

(define-module (playnet vf formulas shocks)
  #:use-module ((playnet vf facts located) #:select (svc-good svc-good?))
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module ((playnet vf beyond scenario) #:select (make-planning-scenario planning-scenario-id planning-scenario-scenario planning-scenario-probability planning-scenario-yield-multipliers planning-scenario-note planning-scenario-path))
  #:export (normalize-shocks scenario-shocks shock-action shock-key shock-period shock-factor
            shock-spelling same-shock? scenario-factor-on
            more-adverse cautious-reading
            branch-flow-factor branch-avail-factor
            mean-shocks certainty-equivalent-scenario calibrate-shocks observed-shocks
            scenario-with-shocks
            %stress-band flows-factor factor-stress flows-stress tail-scenario?
            record-envelope tail-beyond-record))

;; ── the normal form ──────────────────────────────────────────────────────────
;; ((action key period factor) …); period #f ⇒ every period the process or spec
;; appears at.
(define (normalize-shocks spellings)
  (map (lambda (e)
         (cond ((and (pair? e) (symbol? (car e)) (= (length e) 4))
                (list (car e) (cadr e) (caddr e) (cadddr e)))  ; (action key period factor)
               ((and (pair? e) (symbol? (car e)))
                (list (car e) (cadr e) #f (caddr e)))          ; (action key factor) → every period
               (else (list 'produce (car e) #f (cdr e)))))     ; (key . factor) → produce, every period
       spellings))

(define (scenario-shocks s)
  (normalize-shocks (or (planning-scenario-yield-multipliers s) '())))

(define shock-action car) (define shock-key cadr)
(define shock-period caddr) (define shock-factor cadddr)

;; the normal form back in the DSL: (action key factor) flat, (action key period
;; factor) tagged. BARE-PRODUCE? spells a flat produce shock as the (key . factor)
;; pair a shed's crop table is written in, so an alist reader finds it by crop.
(define* (shock-spelling sh #:key (bare-produce? #f))
  (cond ((shock-period sh) sh)
        ((and bare-produce? (eq? (shock-action sh) 'produce))   ; verb-meant: the shock table's own notation
         (cons (shock-key sh) (shock-factor sh)))
        (else (list (shock-action sh) (shock-key sh) (shock-factor sh)))))

;; two shocks on the same (action key period) speak of the same coefficient
(define (same-shock? a b)
  (and (eq? (shock-action a) (shock-action b))
       (equal? (shock-key a) (shock-key b))
       (eqv? (shock-period a) (shock-period b))))

;; what SHOCKS say of one (action key period): every shock on it multiplies in,
;; and silence is 1.0 — the composition the build applies (branch-flow-factor).
(define (scenario-factor-on shocks action key period)
  (let ((id (list action key period #f)))
    (fold (lambda (sh acc) (if (same-shock? sh id) (* acc (shock-factor sh)) acc))
          1.0 shocks)))

;; A shock names its CHANNEL in the first place of its row: an action of the
;; table (produce · consume · use · work: the flow it scales) or one of the two
;; words of this table's own, `avail` (a raw's supply) and `duration` (how long a
;; run takes, read by plan/accepts and plan/horizon-gate). The two are channels,
;; not actions: no event carries them and the action table has no row for them.

;; ── the adverse direction ────────────────────────────────────────────────────
;; An output's yield and a raw's supply are worse LOWER; an input's intensity
;; and a work's hours are worse HIGHER. Every cautious read in the planner
;; takes its direction from here.
(define (more-adverse action a b)
  (if (memq action '(produce avail)) (min a b) (max a b)))

(define (cautious-reading action nominal reading)
  "The reading as the solve takes it: an output reads no better than the map,
   an input no lighter."
  (more-adverse action nominal (max 0.0 reading)))

;; ── THE WEATHER SEAM: a branch is a coefficient view over one world ──────────
;; Everything a scenario does to the numbers flows through two per-branch
;; factors, both consulted at BUILD time and both identity outside a branch:
;; the flow factor for produce/consume/work coefficients (the tagged and the
;; untagged spellings of one matcher) and the avail factor for a raw's supply
;; CONSTANT (engine build-located). Pruning — lead, reach, batch floors, whole
;; counts — reads the one unshocked world, so every branch carries the same
;; columns: the extensive form's shared structure is a fact of construction.
(define (branch-flow-factor shocks)
  ;; A shock's KEY names what it touches: a process id, a spec id, or a
  ;; LOCATED act (proc . place). Every shock a flow matches multiplies in: a
  ;; site's own yield, the weather's response and a withdrawal compose as the
  ;; independent responses they are (a withdrawal's 0 stays 0).
  ;;
  ;; The build tiles every INPUT as one draw and asks of it as 'consume, a
  ;; used service among them under its "Svc|spec" good. So a `use` shock is
  ;; an input shock on the service draws alone, its spec read through that
  ;; prefix.
  (define (names? k sh proc-id spec)
    (if (eq? (shock-action sh) 'use)
        (and (string? spec) (svc-good? spec)
             (or (equal? k proc-id)
                 (and (string? k) (string=? (svc-good k) spec))))
        (or (equal? k proc-id) (equal? k spec))))
  (define (touches? sh proc-id spec place)
    (let ((k (shock-key sh)))
      (or (names? k sh proc-id spec)
          (and (pair? k) (equal? (cdr k) place) (names? (car k) sh proc-id spec)))))
  (define (asked-as action) (if (eq? action 'use) 'consume action))   ; verb-meant: the shock table's own notation
  (define (factor action proc-id spec t place)
    (fold (lambda (sh acc)
            (if (and (or (not (shock-period sh)) (eqv? (shock-period sh) t))
                     (eq? (asked-as (shock-action sh)) (asked-as action))
                     (touches? sh proc-id spec place))
                (* acc (shock-factor sh))
                acc))
          1.0 shocks))
  (if (null? shocks)
      (lambda (action proc-id spec t place) 1.0)
      factor))

(define (branch-avail-factor shocks)
  ;; a located good's key is "spec#…"; an avail shock names the spec
  (let ((av (filter (lambda (sh) (and (eq? (shock-action sh) 'avail) (not (shock-period sh)))) shocks)))
    (if (null? av)
        (lambda (located-good) 1.0)
        (lambda (located-good)
          (let ((i (string-index located-good #\#)))
            (fold (lambda (sh f)
                    (if (and i (string=? (substring located-good 0 i) (shock-key sh)))
                        (* f (shock-factor sh)) f))
                  1.0 av))))))

;; ── Aggregating shocks: ONE weighted group-mean behind both directions ───────
;; Collapse contributions ((action key period weight factor) …) to shocks, mean =
;; Σ w·f / Σ w per (action key period). A contribution's period is #f for the flat
;; every-period channel or an integer for a period-tagged one, and each keeps its
;; own group: a season-1 shock averaged into "the mean world" stays a season-1
;; shock. The certainty-equivalent (probability-weighted forecast) and the
;; Observer calibration (unweighted history) are this fold under two adapters.
(define (mean-shocks contributions)
  (let ((g (make-hash-table)))                    ; (action key period) → (Σ w·f . Σ w)
    (for-each (lambda (c)
                (let* ((k (list-head c 3)) (w (list-ref c 3)) (f (list-ref c 4))
                       (cur (hash-ref g k '(0.0 . 0.0))))
                  (hash-set! g k (cons (+ (car cur) (* w f)) (+ (cdr cur) w)))))
              contributions)
    (define (order sh) (format #f "~a~a~a" (shock-action sh) (shock-key sh) (or (shock-period sh) "")))
    (map shock-spelling
         (sort (hash-map->list (lambda (k v) (append k (list (/ (car v) (cdr v))))) g)
               (lambda (a b) (string<? (order a) (order b)))))))

;; The naive baseline: a scenario SET collapsed to ONE world at its probability-
;; weighted MEAN shocks — the single point forecast. Its readers are tests, as
;; the FOIL: the mean-yield plan that starves where the robust plan holds.
(define (certainty-equivalent-scenario scenarios)
  (let* ((per (map (lambda (s) (cons (planning-scenario-probability s) (scenario-shocks s))) scenarios))
         (ids (delete-duplicates (append-map (lambda (p) (map (lambda (sh) (list-head sh 3)) (cdr p))) per))))
    (make-planning-scenario "certainty-equivalent" #f 1.0
      (mean-shocks
       (append-map (lambda (p)
                     (map (lambda (id) (append id (list (car p) (apply scenario-factor-on (cdr p) id))))
                          ids))
                   per))
      "naive baseline: the scenario set collapsed to its probability-weighted mean shocks")))

;; ── Observer → scenario CALIBRATION ──────────────────────────────────────────
;; The Observer measures each intent's realized-vs-intended ratio; observations
;; (action spec intended realized) fold into empirical shocks — mean-shocks,
;; UNWEIGHTED. The forecast becomes what the world delivered, per intent.
(define (calibrate-shocks observations)
  (mean-shocks
   (filter-map (lambda (o)
                 (and (> (list-ref o 2) 0.0)                       ; intended > 0
                      (list (list-ref o 0) (list-ref o 1) #f       ; action, spec, every period
                            1.0 (/ (list-ref o 3) (list-ref o 2))))) ; weight 1, ratio realized/intended
               observations)))

;; ── Contrary observations → the world as observed, in every future ──────────
;; A contrary observation (docs/planning/voice/feasibility-follows-the-map.md)
;; is a worker's witnessed reading against a mapped figure: (process action
;; nominal reading). It is calibrate-shocks' own tuple with the PROCESS as the
;; key — the figure it contradicts is one act's coefficient — and it moves the
;; read in the adverse direction alone: a reading that flatters the map leaves
;; it where it stands. Witnesses are equal (the mean, unweighted): two workers
;; who saw the same failure are two witnesses. The shocks fold into EVERY
;; scenario of a solve (live.scm plan-scope): what has been seen is true in
;; each future.
(define (observed-shocks observations)
  "OBSERVATIONS ((process action nominal reading) …) → ((action process factor) …),
   the mean witnessed factor per (process, action), adverse direction only."
  (calibrate-shocks
   (filter-map (lambda (o)
                 (let ((process (list-ref o 0)) (action (list-ref o 1))
                       (nominal (list-ref o 2)) (reading (list-ref o 3)))
                   (and (string? process) (symbol? action) (real? nominal) (real? reading) (> nominal 0.0)
                        (list action process nominal (cautious-reading action nominal reading)))))
               observations)))

(define (scenario-with-shocks s shocks)
  "S with SHOCKS appended to its own: the same future, with what has been
   observed laid over it."
  (if (null? shocks) s
      (make-planning-scenario (planning-scenario-id s) (planning-scenario-scenario s)
                              (planning-scenario-probability s)
                              (append (or (planning-scenario-yield-multipliers s) '()) shocks)
                              (planning-scenario-note s) (planning-scenario-path s))))

;; ── the STRESS a set of shocks delivers to a recipe's own flows ──────────────
;; How far the weather moves each of a recipe's coefficients from the map, on
;; a 0..%stress-band scale: a drought that multiplies its yield by 0.4
;; delivers stress 6 on its output. FLOWS are the recipe's own ((action proc
;; spec) …), and each distinct (action . spec) among them is a CHANNEL — its
;; output, each input, the skill it works. The reading is the matcher's
;; (branch-flow-factor), the one the build applies, so a shock keyed on a
;; process, a spec, a service or a located act reaches every flow it touches
;; and no other. A realized sky and a forecast read through this one
;; function: a record and a future meet on the recipe's own flows. Across the
;; acts that share a channel, and the periods and places the shocks name, the
;; heaviest reading stands.
;;
;; `flows-factor` is the reading itself — per channel, the factor that stands
;; farthest from the map — and `flows-stress` its distance: what the weather
;; ALLOWED of a flow and how hard it PRESSED on it are one number read twice,
;; so the two describe the one world.
(define %stress-band 10.0)
(define (flows-factor shocks flows)
  "→ (((action . spec) . factor) …), one per channel of FLOWS."
  (let ((factor (branch-flow-factor shocks))
        (wheres (delete-duplicates
                 (cons '(#f . #f)
                       (map (lambda (sh)
                              (cons (shock-period sh)
                                    (let ((k (shock-key sh))) (and (pair? k) (cdr k)))))
                            shocks)))))
    (define (farther a b) (if (> (abs (- 1.0 b)) (abs (- 1.0 a))) b a))
    (define (factor-on fl)
      (let* ((action (car fl)) (spec (caddr fl))
             ;; the build asks of a used service under its "Svc|spec" good
             (asked (if (and (eq? action 'use) (string? spec) (not (string-prefix? "Svc|" spec)))
                        (svc-good spec) spec)))
        (fold (lambda (w f) (farther f (factor action (cadr fl) asked (car w) (cdr w))))
              1.0 wheres)))
    (map (lambda (ch)
           (cons ch (fold (lambda (fl f)
                            (if (and (eq? (car fl) (car ch)) (equal? (caddr fl) (cdr ch)))
                                (farther f (factor-on fl)) f))
                          1.0 flows)))
         (delete-duplicates (map (lambda (fl) (cons (car fl) (caddr fl))) flows)))))

(define (factor-stress f) (min %stress-band (* %stress-band (abs (- 1.0 f)))))

(define (flows-stress shocks flows)
  "→ (((action . spec) . stress) …), one per channel of FLOWS."
  (map (lambda (cf) (cons (car cf) (factor-stress (cdr cf)))) (flows-factor shocks flows)))

;; ── the future a floor is defended in without a forecast ─────────────────────
;; A scenario of probability zero carries no weight in the expectation and
;; every wall: the tail, beyond the record. The reserve yields to it
;; (solve/robust.scm) and the margin is laid in it (solve/recipe-response.scm).
(define (tail-scenario? s) (<= (planning-scenario-probability s) 0.0))

;; ── THE TAIL STANDS BEYOND THE RECORD ────────────────────────────────────────
;; A shed's record is a sample, and a sample's worst year is the mildest the
;; worst year can be: every estimate carries an error, the error carries its
;; own, and each layer widens the tails of what is forecast (docs/antifragile/
;; errors-on-errors — "the future is structurally more extreme than the past").
;; So the future a floor is defended in is at least as adverse as anything the
;; record holds, on every channel the record shocks.
(define (record-envelope record)
  "RECORD, one normal-form shock list per recorded future → the shocks of its
   envelope: per (action key period), the most adverse factor any future
   carries, a future silent on it counting as 1.0."
  (let ((ids (delete-duplicates (append-map (lambda (shocks) (map (lambda (sh) (list-head sh 3)) shocks))
                                            record))))
    (filter-map
     (lambda (id)
       (let ((worst (fold (lambda (shocks acc)
                            (more-adverse (car id) acc (apply scenario-factor-on shocks id)))
                          1.0 record)))
         (and (not (= worst 1.0)) (append id (list worst)))))
     ids)))

(define (tail-beyond-record record tail)
  "TAIL (a shock list in the DSL) laid over RECORD's envelope: each stated
   shock stands as written where it is at least as adverse as the record, and
   takes the record's worst where the record is worse; a channel the record
   shocks and the tail leaves unstated enters at the record's worst."
  (let* ((envelope (record-envelope record))
         (stated   (normalize-shocks tail)))
    (define (spell sh) (shock-spelling sh #:bare-produce? #t))
    (append
     (map (lambda (spelling sh)
            (let ((e (find (lambda (e) (same-shock? e sh)) envelope)))
              (if (and e (not (= (shock-factor sh)
                                 (more-adverse (shock-action sh) (shock-factor sh) (shock-factor e)))))
                  (spell e)
                  spelling)))
          tail stated)
     (filter-map (lambda (e)
                   (and (not (find (lambda (sh) (same-shock? sh e)) stated))
                        (spell e)))
                 envelope))))
