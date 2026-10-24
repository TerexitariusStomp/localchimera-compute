;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/solve/report.scm — a plan, read: the solve's point as VF rows and ledgers.
;;;
;;; The engine (solve/engine) leaves a point x over the columns it built; this
;;; module reads it. `plan->work` and `plan->material` turn the column levels
;;; into VF work Commitments and material rows (Intents for what is needed and
;;; offered, the runs a relocation is), `tension-duals` the dual vector into
;;; the pulls on labour and goods, the ledgers the hours each worker and the
;;; commons gave, `legal-exposure` and `claim-tally` what the law and the
;;; claims saw; `solve-report` and `report-located` print a solve as it stands,
;;; and `report-discrete` the same after the discrete search decided its
;;; configuration. Nothing here changes the world or the program: a report is a
;;; reading of the point against the tables the solve was built from.

(define-module (localchimera solve report)
  #:use-module (localchimera vf formulas flows)
  #:use-module ((localchimera algorithms rollup fixpoint) #:select (crystallize))
  #:use-module (localchimera solve world)
  #:use-module ((localchimera algorithms free-time) #:select (free-time-fraction))   ; free time, stated once
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module ((localchimera solve voice-field) #:select (voice-labform voice-report))
  #:use-module ((localchimera utils units) #:select (convert-unit/strict unit-known? unit->substance convert-unit unit-rate? unit-rate-parts unit-factor %placeholder-unit %count-unit %effort-unit))
  #:use-module (localchimera vf schemas)
  #:use-module (localchimera vf formulas actions)
  #:use-module ((localchimera utils keyed-id) #:select (keyed-id))
  #:use-module (localchimera vf facts located)
  #:use-module (localchimera vf facts work-ids)       ; the work-intent id grammar, re-exported below
  #:use-module (localchimera solve periods)   ; what a period is in wall-clock time
  #:use-module (localchimera solve solver)
  #:use-module (localchimera solve compile)
  #:use-module (localchimera solve engine)
  #:use-module (localchimera solve discrete)
  #:re-export (need-intent-id offer-intent-id materialized-intent-id intent-family-prefix intent-family?)
  #:export (report-located report-discrete solve-report plan->work plan->material tension-duals
            labour-pulls good-pulls good-labour-content worker-ledger social-ledger legal-exposure
            claim-tally topo-order whole-atoms-of ambient-spec? mk-mat-commitment))

;; ── located reporting ────────────────────────────────────────────────────────
(define (report-located)
  (call-with-values solve-located
    (lambda (x forms labform cols goods raws idx)
      (define (lref c) (col-value x idx (col-key c)))          ; a decided column reads its fact
      (format #t "   activity levels (process @ cell):~%")
      (for-each (lambda (c) (when (and (key-process (col-key c)) (> (lref c) 0.05))
                  (format #t "     ~22a ~6,1f~%" (col-key c) (lref c)))) cols)
      (let ((any #f))
        (for-each (lambda (c) (when (and (carry-col? (col-key c)) (> (lref c) 0.5))
                    (unless any (format #t "   moves:~%") (set! any #t))
                    (let ((kt (key-terms (col-key c))))
                      (format #t "     ~6a ~a -> ~a  ~6,1f~%" (assq-ref kt 'good) (car (assq-ref kt 'arc)) (cdr (assq-ref kt 'arc)) (lref c)))))
                  cols))
      (hash-for-each (lambda (g D)
        (let ((dlv (fold (lambda (c a) (let ((fc (assoc g (col-flows c)))) (if fc (+ a (* (cdr fc) (lref c))) a))) (hash-ref *init* g 0.0) cols)))
          (format #t "   demand ~a delivered ~6,1f/~a  (gap ~,2f)~%" g dlv D (max 0.0 (/ (- D dlv) D)))))
        *demand*)
      (let ((m (length forms)))
        (format #t "   [~a backend; ~a columns, ~a forms]~%" *backend* (length cols) m)))))

;; ── OUTPUT CONFORMANCE: the plan → VF work INTENTS and COMMITMENTS ────────────
;; The internal Lab|skill|cell pool is a solver device; the plan's OUTPUT is VF, in
;; the two lifecycle stages a plan actually has:
;;   • a work INTENT — "this process NEEDS E hours of skill s at cell c" (provider
;;     unbound, finished=#f): the planned requirement before anyone is assigned;
;;   • a work COMMITMENT — "worker w WILL do E' of it" (provider bound), each one
;;     `satisfies` its intent. The solve fixes who-works-which, so commitments are
;;     the assignment; intents are what they collectively fulfil.
;; VF matching is TWO-SIDED: a commitment satisfies BOTH a provider-side intent
;; and a receiver-side intent. For `work` that is:
;;   • NEED intent (receiver side)  — "process P NEEDS E hrs of skill s at c"
;;     (inputOf=P, provider unbound); id  ni|proc|skill|cell
;;   • OFFER intent (provider side) — "worker w OFFERS H hrs of skill s at c"
;;     (provider=w, availableQuantity=H);    id  oi|worker|skill|cell
;; the COMMITMENT (provider=w, inputOf=P) `satisfies` the pair (need-id offer-id),
;; and is later `fulfilled` by an EconomicEvent the observer records. ids are
;; deterministic so the links reconstruct; all carry the period's wall-clock.
;; ── which needs are INDIVISIBLE, and into how many acts ─────────────────────
;; `plan/assignment.scm` turns the offer field into a rota and asks its
;; caller how many atomic acts a need is. The engine is the one that knows: a
;; process named to `declare-whole!` is one "that happens a whole number of
;; times", and its per-run labour says how many of those a need's hours are. So
;; the answer is built here rather than by each caller reading the id format and
;; the templates for itself — that is the only DRY place for it, and it keeps
;; `plan-assignment` free of any dependency on the engine.
;;
;; ZERO for a process nobody declared whole, and that is the useful answer, not
;; a missing one: divisible work does not want a rota. Its fractional
;; commitments already say what everyone contributes, and forcing one name onto
;; a week of farming would be less true, not more. Only what one person must
;; carry gets carried by one person.
(define (whole-atoms-of)
  "→ (need hours) → how many indivisible acts that need is; 0 if it is divisible."
  (lambda (need hours)
    (let* ((terms (work-intent-id-terms need))
           (proc  (and terms (assq-ref terms 'subject)))
           (skill (and terms (assq-ref terms 'skill)))
           (tpl   (and proc (template-by-id proc)))
           (per   (and tpl (or (and skill (assoc-ref (proc-skill-labours tpl) skill))
                               (proc-labour tpl)))))
      (if (and proc (hash-ref *whole-procs* proc #f) (real? per) (> per 0.0))
          (max 1 (inexact->exact (round (/ hours per))))
          0))))
(define (mk-need-intent id skill effort proc place begin end)        ; receiver side: the process needs work
  (make-work-intent #:id id #:skill skill #:hours effort #:input-of proc
                    #:has-beginning begin #:has-end end #:at-location place))   ; provider #f
(define (mk-offer-intent id worker skill effort place begin end)     ; provider side: the worker offers work
  (make-work-intent #:id id #:skill skill #:hours effort #:provider worker #:offered? #t
                    #:has-beginning begin #:has-end end #:at-location place))  ; provider=worker, availableQuantity=H
(define (mk-work-commitment id provider skill effort proc place begin end satisfies)
  ;; in-scope-of = the scope of the solve that placed the hour (the head of
  ;; *scope-path*, set by the door that solves for a scope): reach has its fact
  ;; by construction, and the event that fulfils this carries it too.
  (make-work-commitment #:id id #:provider provider #:skill skill #:hours effort #:input-of proc
                        #:has-beginning begin #:has-end end #:at-location place
                        #:in-scope-of (and (pair? *scope-path*) (car *scope-path*))
                        #:satisfies satisfies))  ; satisfies = (need-id offer-id)
;; gather supply (workers) + demand (processes) per located labour good, then build
;; the need + offer intents and the commitments that satisfy both.
(define *work-emission-floor* 0.05)   ; hours. An ACT under three minutes is
;; branch-probability smear off the robust average, never work a person can
;; take up — emitting it would lay a 54-second open shift and present a
;; 54-second offer. The floor reads the PER-PROCESS demand row (the act), so a
;; dust act emits no need, no commitment and no candidate — while a person's
;; thin SHARE of a real act stays emitted: that is the rota's raw material
;; (assign-plan-slots lumps ten 0.03 h shares into one whole slot;
;; test-whole-assignment pins it). The COLUMN keeps its exact value — the
;; solve's arithmetic is untouched.
;; A need is stated once per process, skill and cell: process P wants E hours of the skill
;; at the cell. Several columns of one recipe can stand on one cell (a haul's runs from one
;; origin to several destinations), each asking its own hours of the same need, so the hours
;; of a process add up and the first-seen order stays.
(define (sum-by-process pds)
  "((process . hours) …) with one entry per process, its hours the sum."
  (let loop ((in pds) (out '()))
    (cond ((null? in) (reverse out))
          ((assoc (caar in) out)
           => (lambda (e) (loop (cdr in) (map (lambda (o) (if (eq? o e) (cons (car o) (+ (cdr o) (cdar in))) o)) out))))
          (else (loop (cdr in) (cons (car in) out))))))
(define (plan->work x cols idx)
  (let ((supply (make-hash-table)) (demand (make-hash-table)) (cands (make-hash-table)) (needs '()) (offers '()) (coms '()))
    (for-each (lambda (c)
      (let ((v (col-value x idx (col-key c))) (kt (key-terms (col-key c))))
        (when (> v 1e-4)
          (cond ((worker-col? (col-key c))    ; w|id|skill|cell → supplies Lab|skill|cell
                 (let ((g (caar (col-flows c))))
                   (hash-set! supply g (cons (cons (assq-ref kt 'worker) v) (hash-ref supply g '())))))
                ((process-col? (col-key c))     ; p|proc|cell → consumes Lab|skill|cell at coeff −ℓ
                 (for-each (lambda (fc)
                   (when (lab-good? (car fc))
                     ;; a ride is a run of its mode: the work it asks (a driver, a carrier) is that mode's need
                     (hash-set! demand (car fc) (cons (cons (let ((pr (assq-ref kt 'process))) (or (ride-mode-process pr) pr))
                                                            (* (- (cdr fc)) v))
                                                      (hash-ref demand (car fc) '())))))
                   (col-flows c)))))))
      cols)
    (hash-for-each (lambda (g sup)
      (let* ((dem (filter (lambda (pd) (> (cdr pd) *work-emission-floor*))   ; the act floor: dust acts emit nothing
                          (sum-by-process (hash-ref demand g '()))))
             (tot (fold (lambda (pd a) (+ a (cdr pd))) 0.0 dem))
             (skill (bar-field g 1)) (cl (bar-field g 2)) (place (place-of cl))
             (span (period-span (period-of cl))) (begin (car span)) (end (cdr span)))
        (when (> tot 1e-9)
          (for-each (lambda (pd)                     ; NEED intent per process-need (receiver side)
            (when (> (cdr pd) *work-emission-floor*)
              (set! needs (cons (mk-need-intent (need-intent-id (car pd) skill cl) skill (cdr pd) (car pd) place begin end) needs))))
            dem)
          (for-each (lambda (sw)                     ; OFFER intent per worker (provider side)
            (when (> (cdr sw) 1e-4)
              (set! offers (cons (mk-offer-intent (offer-intent-id (car sw) skill cl) (car sw) skill (cdr sw) place begin end) offers))))
            sup)
          (for-each (lambda (sw)                     ; COMMITMENTS: worker→process, satisfying BOTH intents
            (for-each (lambda (pd)
              (let ((eff (* (cdr sw) (/ (cdr pd) tot))) (nid (need-intent-id (car pd) skill cl)))
                (when (> eff 1e-4)
                  (hash-set! cands nid (cons (list (car sw) eff (offer-intent-id (car sw) skill cl)) (hash-ref cands nid '())))   ; the FIELD: per need, who'd help + share
                  ;; a commitment's id names WHAT it commits (this worker to this need),
                  ;; so a re-solve that restates it restates the same commitment
                  (set! coms (cons (mk-work-commitment (keyed-id "wc" nid (offer-intent-id (car sw) skill cl))
                                                       (car sw) skill eff (car pd) place begin end
                                     (list nid (offer-intent-id (car sw) skill cl))) coms)))))
              dem))
            sup))))
      supply)
    ;; THE RIDER'S OWN HOURS: a rider's time on the way is charged to their own budget
    ;; (the row that bounds supply + transit by their hours), not through a worker
    ;; column, so it is stated here: each ride column at level v is v × the arc's
    ;; transit hours, the number the budget charges, committed to the rider under the
    ;; mode's skill. No need intent stands behind it: it is the mover's own work.
    (for-each
     (lambda (c)
       (let* ((v    (col-value x idx (col-key c))) (kt (key-terms (col-key c)))
              (arc  (assq-ref kt 'arc))
              (info (and arc (hash-ref *ride-info* (assq-ref kt 'process) #f))))   ; (mode . rider)
         (when (and info (> v 1e-4) (not (hash-ref *means-lot* (cdr info) #f)))   ; a means works nothing: a thing is no agent
           (let* ((mode (car info)) (a (car arc)) (b (cdr arc))
                  (hours (* v (arc-hours a b (mrec-manner mode) (mrec-pace mode)))))
             (when (> hours *work-emission-floor*)
               (let ((sp (period-span (period-of a))))
                 (set! coms (cons (mk-work-commitment (keyed-id "wc" "self" (assq-ref kt 'process) a b)
                                                      (cdr info) (or (mrec-skill mode) "ride") hours
                                                      (assq-ref kt 'process) (place-of a) (car sp) (cdr sp) #f)
                                  coms))))))))
     cols)
    ;; third value = the CANDIDATE FIELD: ((need-id . ((worker share offer-id) …)) …) — the offer set, not one provider.
    (values (append (reverse needs) (reverse offers)) (reverse coms) (hash-map->list cons cands))))
;; ── the MATERIAL side: produce / consume / use / pickup / dropoff commitments ──
;; The work commitments say WHO labours; the material commitments say WHAT the
;; processes make and use, and what is carried where — the flows that actually
;; change stock. A production column at level v: one `produce` commitment per output
;; (output-of=process), one `consume` per input (input-of=process) and one `use` per
;; means; a carry column or a haul: a `pickup` at the origin and a `dropoff` at the
;; destination, the two rows of one run. Confirming these records the
;; EconomicEvents the observer folds — so the plan's own realisation draws stock
;; down and the metabolism re-solves on the plan it just enacted, not only on
;; outside shocks. (Labour goods are skipped here — they are the work side.)
(define (ambient-test)
  "(spec → bool): the spec is drawn from the ambient world, a declared boundless raw
   that carries no stock. A declared raw that holds stock is drawn from the stock, as
   any good is. Built once per plan: one pass over the stock rows."
  (let ((stocked (make-hash-table)))
    (hash-for-each (lambda (g q) (when (> q 0.0) (hash-set! stocked (good-spec g) #t))) *cap*)
    (lambda (spec) (and (hash-ref *raws* spec #f) (not (hash-ref stocked spec #f))))))
(define (ambient-spec? spec) ((ambient-test) spec))
;; a good the plan draws from the ambient world (an externality declared in
;; *raws*: air, sunlight) has no stock to resolve, and the constructor tags it so
;; (formulas/flows make-flow-commitment, which also tags a `use`). A `use` row's
;; figure is HOURS of the means engaged: effortQuantity, the field VF gives a use's
;; duration; every other row's is a quantity of its spec in the SPEC's unit — a
;; qualified good (spec/stage!state, spec~aid) is a lot of the bare spec.
(define (mk-mat-commitment ambient? id action spec qty proc place begin end)
  (make-flow-commitment #:id id #:action action #:spec spec
                        #:qty (and (not (memq action occupying-actions)) qty)
                        #:hours (and (memq action occupying-actions) qty)
                        #:unit (hash-ref *spec-units* (bare-spec spec) %placeholder-unit)
                        #:process proc #:place place #:has-beginning begin #:has-end end
                        #:ambient? (ambient? spec)))
;; a material ITEM, before it becomes a commitment, carries the LOCATED goods it
;; touches so we can order the flows by dependency (produce a good before it is
;; consumed; a process consumes before it produces): #(action spec qty proc place
;; to-place begin end consumes-cell produces-cell).
(define (mi-act i) (vector-ref i 0)) (define (mi-cons i) (vector-ref i 8)) (define (mi-prod i) (vector-ref i 9))
(define (mi-proc i) (vector-ref i 3)) (define (mi-spec i) (vector-ref i 1))
;; the VF action an item is committed as: a relocation's cargo rows are consumed and
;; produced as far as the ordering goes, and a pickup and a dropoff as far as the books go
(define (mi-vf i) (or (and (> (vector-length i) 10) (vector-ref i 10)) (vector-ref i 0)))
(define (lgk spec cell) (and cell (lg spec cell)))   ; located-good key, where a cell stands
(define (topo-order items)            ; Kahn's algorithm; a cycle releases its first row left, so every row is placed
  ;; "a precedes b in enaction" is a JOIN: a produces the located good b consumes
  ;; (availability), or a consume precedes its own process's produce — so the graph
  ;; builds from two indexes in O(n+edges), not an O(n²) all-pairs scan (which on a
  ;; national table's ~10³–10⁴ flows was the whole post-solve cost: 22s → 0.02s).
  (let* ((v (list->vector items)) (n (vector-length v))
         (indeg (make-vector n 0)) (adj (make-vector n '()))
         (cons-by-good (make-hash-table))   ; located-good key → indices that CONSUME it (any act)
         (prod-by-pc   (make-hash-table)))  ; (proc . cell) → indices that PRODUCE there
    (define (add-edge i j)
      (unless (= i j)
        (vector-set! adj i (cons j (vector-ref adj i)))
        (vector-set! indeg j (+ 1 (vector-ref indeg j)))))
    (do ((i 0 (+ i 1))) ((= i n))         ; index: who consumes each good, who produces in each (proc,cell)
      (let* ((it (vector-ref v i)) (cc (mi-cons it)))
        (when cc
          (let ((k (lgk (mi-spec it) cc)))
            (hash-set! cons-by-good k (cons i (hash-ref cons-by-good k '())))))
        (when (and (eq? (mi-act it) 'produce) (mi-prod it))   ; verb-meant: the two actions the solve emits
          (let ((k (cons (mi-proc it) (mi-prod it))))
            (hash-set! prod-by-pc k (cons i (hash-ref prod-by-pc k '())))))))
    (do ((i 0 (+ i 1))) ((= i n))         ; edges
      (let* ((it (vector-ref v i)) (pp (mi-prod it)))
        (when pp                            ; (1) availability: producer → every consumer of the same located good
          (for-each (lambda (j) (add-edge i j)) (hash-ref cons-by-good (lgk (mi-spec it) pp) '())))
        (when (and (eq? (mi-act it) 'consume) (mi-cons it))   ; (2) intra-process: consume → its process's produce  ; verb-meant: the two actions the solve emits
          (for-each (lambda (j) (add-edge i j)) (hash-ref prod-by-pc (cons (mi-proc it) (mi-cons it)) '())))))
    (let ((q '()) (out '()) (seen 0) (done (make-vector n #f)))
      (do ((i (- n 1) (- i 1))) ((< i 0)) (when (= 0 (vector-ref indeg i)) (set! q (cons i q))))
      (let loop ()
        (cond
         ((pair? q)
          (let ((i (car q))) (set! q (cdr q))
            (unless (vector-ref done i)
              (vector-set! done i #t) (set! out (cons (vector-ref v i) out)) (set! seen (+ seen 1))
              (for-each (lambda (j) (vector-set! indeg j (- (vector-ref indeg j) 1))
                          (when (= 0 (vector-ref indeg j)) (set! q (cons j q)))) (vector-ref adj i)))
            (loop)))
         ((< seen n)                      ; a closed loop (farm ↔ compost): release the first row left, as emitted
          (set! q (list (let find ((i 0)) (if (vector-ref done i) (find (+ i 1)) i))))
          (loop))))
      (reverse out))))
;; (spec from to) of a carry column, read off the one grammar (located.scm key-terms:
;; the cells are the last two fields, the spec everything between)
(define (carry-key-parts key)
  (let ((kt (key-terms key)))
    (values (assq-ref kt 'good) (car (assq-ref kt 'arc)) (cdr (assq-ref kt 'arc)))))
;; A carry and its mirror — q of one good a→b and q' back b→a in one plan —
;; cancel: what moves is the net, in the net's direction (merge-coeffs reads an
;; arc and its mirror the same way). The books hold a dropoff to its pickup, so
;; a pair emitted whole is a pair they refuse; netted, each carry is one real
;; move. Returns column key → net value, 0 for the losing direction.
(define (net-carries x cols idx)
  (let ((raw (make-hash-table)) (net (make-hash-table)))
    (for-each (lambda (c)
                (when (carry-col? (col-key c))
                  (hash-set! raw (col-key c) (col-value x idx (col-key c)))))
              cols)
    (hash-for-each (lambda (key vv)
                     (call-with-values (lambda () (carry-key-parts key))
                       (lambda (spec from to)
                         (hash-set! net key (max 0.0 (- vv (hash-ref raw (carry-col spec to from) 0.0)))))))
                   raw)
    net))
(define (plan->material x cols idx)
  (let ((items '()) (carry-net (net-carries x cols idx)))
    (for-each (lambda (c)
      (let* ((vv (hash-ref carry-net (col-key c) (col-value x idx (col-key c)))) (kt (key-terms (col-key c))) (arc (assq-ref kt 'arc)))
        (when (> vv 1e-4)
          (cond
            ((assq-ref kt 'process)                  ; production: produce outputs, consume inputs
             (let* ((proc (assq-ref kt 'process))
                    ;; a HOLD's arc between two cells of ONE place (band→band,
                    ;; day→day) is the stock staying put — placement, like the
                    ;; m| rule below, never a material commitment: nobody
                    ;; consumes a thing into where it already is. The held
                    ;; spec's paired rows are elided; a lossy hold's spoil is
                    ;; the pair's NET draw and still lands as a consume.
                    (arc?  (and arc #t))
                    (org   (and arc (car arc)))
                    (dst   (and arc (cdr arc)))
                    (tpl   (template-by-id proc))
                    (held  (if (and arc? (equal? (place-of org) (place-of dst)))
                               (if tpl (proc-relocated tpl) '())
                               '()))
                    ;; a haul between two places is one RUN of its recipe: a Process of its own,
                    ;; whose cargo is picked up at the origin and dropped off at the destination
                    (cargo (if (and arc? tpl (not (equal? (place-of org) (place-of dst)))) (proc-relocated tpl) '()))
                    (run   (and (pair? cargo) (run-id proc org dst)))
                    (net   (make-hash-table)))          ; held spec → Σ coeff (loss shows negative)
               (when run (hash-set! *runs* run proc))
               ;; each flow is dated at ITS OWN cell — a run-spanning process
               ;; boards its inputs at the origin band and lands its output at
               ;; the arrival band, and the record says so (same cell for every
               ;; flow of an ordinary same-band run, so nothing else moves)
               (for-each (lambda (fc)
                 (let ((g (car fc)) (coeff (cdr fc)))
                   ;; a MEANS on a ride between two places is a thing carried: picked up
                   ;; where it stood and dropped off where it lands, the lot itself, whole
                   (let* ((lot (and arc? (not (equal? (place-of org) (place-of dst)))
                                    (pres-good? (good-spec g))
                                    (hash-ref *means-lot* (bar-spec (good-spec g)) #f)))
                          (run (and lot (run-id proc org dst))))
                     (when (and lot (> (abs (* coeff vv)) 1e-4))
                       (hash-set! *runs* run (or (ride-mode-process proc) proc))
                       (let* ((cl (located-cell g)) (sp (period-span (period-of cl)))
                              (qty (* (cdr lot) (abs (* coeff vv)))))
                         (set! items
                               (cons (if (> coeff 0.0)
                                         (vector 'produce (car lot) qty run (place-of cl) #f (car sp) (cdr sp) #f cl (relocating-side 'output))
                                         (vector 'consume (car lot) qty run (place-of cl) #f (car sp) (cdr sp) cl #f (relocating-side 'input)))
                                     items)))))
                   (unless (or (lab-good? g)
                               ;; a presence is where a person (an Agent) or a means IS: the position
                               ;; machinery states that (set-position, the live fix), and VF has no flow
                               ;; that makes it at one place and uses it up at another
                               (pres-good? (good-spec g))
                               ;; the hold's own container occupancy is the same
                               ;; non-event as the pair it elides: the ground was
                               ;; occupied by a thing staying where it is
                               (and (pair? held) (svc-good? (good-spec g))))
                     (let ((spec (good-spec g)) (qty (abs (* coeff vv))))
                       (if (member spec held)
                           (hash-set! net spec (+ (hash-ref net spec 0.0) coeff))
                           (when (> qty 1e-4)
                             (let* ((cl (located-cell g)) (place (place-of cl))
                                    (sp (period-span (period-of cl))) (b (car sp)) (e (cdr sp)))
                               (cond ((> coeff 0.0)
                                      (set! items (cons (vector 'produce spec qty (or run proc) place #f b e #f cl
                                                                (and (member spec cargo) (relocating-side 'output)))
                                                        items)))
                                     ;; a vehicle's or network's service is a means in use: it still exists
                                     ;; afterwards, so the row is a `use` of its own specification
                                     ((svc-good? spec)
                                      (set! items (cons (vector 'use (bar-spec spec) qty (or run proc) place #f b e #f #f) items)))
                                     (else
                                      (set! items (cons (vector 'consume spec qty (or run proc) place #f b e cl #f
                                                                (and (member spec cargo) (relocating-side 'input)))
                                                        items))))))))) ))
                 (col-flows c))
               (hash-for-each (lambda (spec nc)          ; the hold's net draw — spoilage, if any
                                (let ((qty (abs (* nc vv))))
                                  (when (and (< nc 0.0) (> qty 1e-4))
                                    (let* ((sp (period-span (period-of org))))
                                      (set! items (cons (vector 'consume spec qty proc (place-of org) #f (car sp) (cdr sp) org #f) items))))))
                              net)))
            ((carry-col? (col-key c))       ; move: transport/storage from→to (consumes@from, produces@to)
             ;; the key is m|<spec>|<from>|<to>, and a spec may itself carry a `|`
             ;; (Pres|w, Cond|durable, Svc|spec): the cells are the LAST two segments,
             ;; the spec is everything between. A presence carried forward is a
             ;; person or a means staying put — placement (solve-report), not a
             ;; material commitment.
             (call-with-values (lambda () (carry-key-parts (col-key c)))
              (lambda (spec from to)
               ;; a carry between two cells of ONE place (band→band, day→day)
               ;; is the stock staying put — placement, like a presence, never
               ;; a material commitment: nobody moves a thing to where it is
               ;; a relocation is what ex-complex.md shows: a Process whose input is a
               ;; `pickup` at the origin and whose output is a `dropoff` at the destination
               ;; (a Commitment names no destination, and `move` binds to no Process).
               ;; Each carry is the one run of its own, an instance of the mode its manner
               ;; names.
               (unless (or (pres-good? spec)
                           (equal? (place-of from) (place-of to)))
                 (let ((run (run-id spec from to))
                       (sf (period-span (period-of from))) (st (period-span (period-of to)))
                       ;; a means carried between places (a key, a vehicle) is the thing itself that is
                       ;; picked up and dropped off, under its own specification
                       (what (if (svc-good? spec) (bar-spec spec) spec)))
                   (hash-set! *runs* run (bare-run-template))
                   (set! items (cons (vector 'consume what vv run (place-of from) #f (car sf) (cdr sf) from #f (relocating-side 'input)) items))
                   (set! items (cons (vector 'produce what vv run (place-of to) #f (car st) (cdr st) #f to (relocating-side 'output)) items)))))))))) )
      cols)
    ;; rows in dependency order for display (enaction reads the books, not this order);
    ;; each id names the flow it commits (action, spec, process, places, instant), so a
    ;; re-solve that restates a flow keeps its id and two flows never share one
    (let ((seen (make-hash-table)) (ambient? (ambient-test)))
      (map (lambda (it)
             (let* ((key (keyed-id "mc" (mi-vf it) (mi-spec it) (mi-proc it)
                                   (vector-ref it 4) (vector-ref it 5) (vector-ref it 6)))
                    (k   (hash-ref seen key 0)))
               (hash-set! seen key (+ k 1))
               (mk-mat-commitment ambient? (if (= k 0) key (string-append key "#" (number->string (+ k 1))))
                                  (mi-vf it) (mi-spec it) (vector-ref it 2)
                                  (mi-proc it) (vector-ref it 4) (vector-ref it 6) (vector-ref it 7))))
           (topo-order (reverse items))))))

(define (person-offered)                    ; ((id . hours) …): each person's time — what the body leaves when rest is reserved, else the hours offered
  (if (> (fold + 0.0 (map cdr *disposable*)) 1e-9)
      *disposable*
      (reverse (fold (lambda (w acc)
                       (let ((hit (assoc (car w) acc)))
                         (acons (car w) (+ (cadddr w) (if hit (cdr hit) 0.0)) (if hit (alist-delete (car w) acc) acc))))
                     '() *workers*))))
(define (worker-available)                  ; N·T: the people's time, Σ person-offered
  (fold + 0.0 (map cdr (person-offered))))
;; ── ABSTRACT side: the PULLS are the dual of the plan ─────────────────────────
;; ── (labour pulls λ + material/eco pulls μ) + embodied labour + free-time ─────
;; A post-solve pass — no solver change. At the central-path optimum EVERY
;; possibility-tension carries a dual  λ = t / slack  (t = final barrier param),
;; and a located balance's slack is its DELIVERED amount: const + Σ flows·x. The
;; const is the opening stock *init* for a produced good, the draw bound *cap* for
;; a raw (eco) good, and nothing (0) for a labour balance. So ONE pass over the
;; columns yields every pull — cosmic.scm's stationarity
;;     2·w·g / q*  =  Σ[k] ℓ·λ  +  Σ[r] d·μ
;; with BOTH sides read off the same solve: the labour pulls λ(s,c) AND the
;; pulls of material and ecological scarcity μ(g). No second computation — value IS the
;; dual. The embodied labour ℓ̂ of a good (its crystallised SNLT, in hours) is the
;; Leontief integral up the recipe graph — the abstract-labour content that μ
;; reduces to when nothing but labour is scarce. And the social individual's two
;; faces: L = labour actually worked, N·T = total offered time, f = 1 − L/(N·T).
(define (tension-duals x cols idx t)        ; ((balance-name . dual) …): the whole dual vector, off the optimum
  (let ((slack (make-hash-table)))          ; name -> Σ flows·x  (the variable part of the balance's slack)
    (for-each (lambda (c)
      (let ((xc (col-value x idx (col-key c))))               ; a decided column's flows still move the balance
        (for-each (lambda (fc)
          (hash-set! slack (car fc) (+ (hash-ref slack (car fc) 0.0) (* (cdr fc) xc))))
          (col-flows c))))
      cols)
    (hash-map->list (lambda (nm s)          ; slack = const + Σ flows·x ; const = *init* (produced), else *cap* (raw eco), else 0
                      (let ((fc (hash-ref *frag-cap* nm #f)))
                        (if fc               ; a FRAGILITY good: fixed-weight pull w/(s_tip − draw), NOT the swept t/(cap−draw)
                            (cons nm (/ (frag-w fc) (max (+ s (frag-tip fc)) 1e-9)))
                            (let ((c0 (or (hash-ref *init* nm #f) (hash-ref *cap* nm #f) 0.0)))
                              (cons nm (/ t (max (+ s c0) 1e-9)))))))
                    slack)))
(define (labour-pulls duals)               ; ((skill@cell . λ) …): the Σℓλ side — located labour pulls
  (filter-map (lambda (nd) (and (lab-good? (car nd))
                                (cons (string-append (lab-good-skill (car nd)) "@" (lab-good-cell (car nd))) (cdr nd))))
              duals))
(define (good-pulls duals)                 ; ((located-good . μ) …): the Σdμ side — the pulls of material & ecological scarcity
  (filter (lambda (nd) (not (lab-good? (car nd)))) duals))
(define (good-labour-content)               ; ((spec . ℓ̂-hours) …): crystallized SNLT per unit, off the recipe graph
  ;; The one value rollup — `crystallize` (algorithms/rollup/fixpoint.scm): the Leontief
  ;; adjoint iterated to its fixpoint, min across alternative recipes, a joint recipe's
  ;; effort split across its co-products by relative standalone SNLT. The credit pool
  ;; prices claims through the same kernel (rollup.scm `crystallized-snlt-for-spec`), so
  ;; the ℓ̂ the plan reports and the price a claim pays are one number. Embodied
  ;; DEPRECIATION rides in for free: a worn durable's condition is a consumed input good
  ;; (Cond|durable). El| rows are element conservation (close-elements!), never a product.
  (hash-map->list cons
    (crystallize (map (lambda (tpl)
                        (list (proc-labour tpl) (proc-inputs tpl)
                              (filter (lambda (oq) (not (el-good? (car oq)))) (proc-outputs tpl))))
                      *templates*))))
(define (worker-total x cols idx)           ; L: living labour actually worked (Σ worker supply)
  (fold (lambda (c a) (if (worker-col? (col-key c)) (+ a (vector-ref x (hash-ref idx (col-key c)))) a)) 0.0 cols))

;; three ledgers off the people's hours bundles: (direct transport training). EVERY hour a
;; person commits to the plan is real social labour — none of it is "false". The split only
;; says WHERE the time goes: directly making things, getting to where that work is, or
;; forming skills. (NB: "faux frais" is a category of the market FORM — the overhead of
;; circulation, the money-commodity, commercial bookkeeping; the classical accounts count transport
;; itself as productive. A transparent plan has no such sphere: transport is simply the real
;; labour-cost of a spatially-distributed society — a different recipe cost, not waste.)
;; w|… is direct labour (the 1·x) + the transport hours to reach the work (the (hc−1)·x); T|… is training.
(define (person-ledger x idx)               ; ((id direct transport training) …): each person's planned hours, over all their bundles (one per period)
  (reverse
   (fold (lambda (b acc)
           (if (not (list-ref b 4))
               acc                          ; a means' bundle is no person's time
               (let ((direct 0.0) (transport 0.0) (train 0.0) (id (car b)))
                 (for-each (lambda (e)
                   (let* ((key (car e)) (hc (caddr e)) (i (hash-ref idx key #f)) (xv (if i (vector-ref x i) 0.0)))
                     (cond ((worker-col? key) (set! direct (+ direct xv)) (set! transport (+ transport (* (- hc 1.0) xv))))
                           ((train-col? key) (set! train (+ train (* hc xv)))))))
                   (cadddr b))
                 (let ((hit (assoc id acc)))
                   (acons id (if hit
                                 (list (+ direct (cadr hit)) (+ transport (caddr hit)) (+ train (cadddr hit)))
                                 (list direct transport train))
                          (if hit (alist-delete id acc) acc))))))
         '() *supplier-bundles*)))
(define (worker-ledger x idx)               ; the three ledgers over every person: the sum of person-ledger
  (let ((rows (person-ledger x idx)))
    (list (fold + 0.0 (map cadr rows)) (fold + 0.0 (map caddr rows)) (fold + 0.0 (map cadddr rows)))))
(define (person-time x idx)                 ; ((id planned offered) …): every person the plan counts, planned = direct + transport + training
  (let* ((offered (person-offered)) (ledger (person-ledger x idx))
         (ids (append (map car offered) (filter-map (lambda (r) (and (not (assoc (car r) offered)) (car r))) ledger))))
    (map (lambda (id)
           (let ((l (assoc id ledger)) (o (assoc id offered)))
             (list id (if l (+ (cadr l) (caddr l) (cadddr l)) 0.0) (if o (cdr o) 0.0))))
         ids)))
;; the social-individual accounting (L, N·T, free time f) as one block — read
;; off x through IDX, which is what lets the ROBUST report reuse it: the
;; scenario-0 view maps the same canonical column keys to the extensive form's
;; global indices, so the coherent plan's hours are the ones counted.
(define (social-ledger x idx)
  (let* ((ldg (worker-ledger x idx))                            ; (direct transport training)
         (Lp (car ldg)) (transport (cadr ldg)) (train (caddr ldg))
         (spent (+ Lp transport train)) (avail (worker-available))   ; ALL hours drawn from people's budgets
         (f (free-time-fraction spent avail)))
    `((direct-labour     . ,Lp)                ; labour directly making goods (its SNLT lands in the products)
      (transport         . ,transport)        ; the real labour of moving people/things to where they're needed — a genuine cost of spatial distribution, accounted like any other (NOT "overhead")
      (training          . ,train)            ; labour-power formation (amortised into skilled value)
      (available         . ,avail)            ;   N·T: disposable time when rest is reserved, else the hours offered
      (free              . ,(- avail spent))   ;   the realm of freedom: N·T − every hour committed to the plan
      (by-person         . ,(person-time x idx)) ;   ((id planned offered) …): the same ledger per person, summing to spent and available
      (free-time         . ,f))))              ;   f = 1 − (direct + transport + training)/(N·T)
;;; LEGAL EXPOSURE, readable off the plan. A frag form is anonymous — `(frag
;;; const coeffs w)` carries no identity, so in the objective a legal tension is
;;; indistinguishable from an ecological one, which is right: the solver has no
;;; business knowing why a limit is there. Identity lives where the DECLARATION
;;; does, exactly as an ecological fragility is displayed from its catalogue and
;;; not from its form. So the report reads `*legal-frag*` back against the
;;; solution: which acts leaned on law the pack was unsure of, how far, and how
;;; close to what the commune said it would carry.
;;;
;;; Without this the tension is real in the objective and invisible in the
;;; answer, which is the same silence the legal layer keeps producing: a plan
;;; that quietly took a legal risk looks exactly like one that had none to take.
(define (legal-exposure x idx)
  (filter-map
   (lambda (kv)
     (let* ((key (car kv)) (profile (cdr kv)) (i (hash-ref idx key #f)))
       (and i (let ((lvl (vector-ref x i)) (tip (frag-tip profile)))
                (and (> lvl 1e-9)
                     (cons key `((level   . ,lvl)
                                 (tip     . ,tip)
                                 (share   . ,(if (> tip 1e-12) (/ lvl tip) 0.0))
                                 (profile . ,profile))))))))
   (hash-map->list cons *legal-frag*)))

;; ── the claim, read off the plan ─────────────────────────────────────────────
;; A claim column (live.scm claim-recipes, process "claim~spec~aid") consumes the
;; scope's good and the citizen's certificate at the good's crystallized SNLT and
;; produces the citizen's own "spec~aid". Its level is the claim; the credit it
;; draws is the labour-certificate drawdown the spec calls "the running accounting
;; of how much of the citizen's drawable credit has been claimed" — read here, per
;; claim and per citizen, in hours.
(define (claim-col? c) (let ((p (key-process (col-key c)))) (and p (claim-process? p))))
(define (claim-tally x cols idx)
  "((claims . ((aid spec units hours cell) …)) (credit-drawn . ((aid . hours) …)))"
  (let ((rows (filter-map
               (lambda (c)
                 (and (claim-col? c)
                      (let ((v (col-value x idx (col-key c))))
                        (and (> v 1e-6)
                             (let* ((kt    (key-terms (col-key c)))               ; p|claim~spec~aid|cell
                                    (proc  (assq-ref kt 'process))
                                    (o     (spec-owner (claim-process-good proc)))
                                    (hours (fold (lambda (fl a)
                                                   (if (and (credit-good? (good-spec (car fl))) (< (cdr fl) 0.0))
                                                       (- a (* v (cdr fl)))
                                                       a))
                                                 0.0 (col-flows c))))
                               (and o (list (cdr o) (car o) v hours (assq-ref kt 'cell))))))))
               cols))
        (per (make-hash-table)))
    (for-each (lambda (r) (hash-set! per (car r) (+ (hash-ref per (car r) 0.0) (cadddr r)))) rows)
    `((claims . ,rows) (credit-drawn . ,(hash-map->list cons per)))))
;; the voice entry of the report — τ, each column's stance, each part's marginal
;; price — is solve/voice-field.scm's `voice-report`, over the terms and labour hours
;; the assembly kept (*col-terms*, *col-ell*); the engine holds no field arithmetic
(define (solve-report x cols idx t)
  (let ((duals (tension-duals x cols idx t)))                   ; the dual of the plan — computed ONCE
    `((labour-pulls . ,(labour-pulls duals))                  ; λ(s,c) — located labour pulls   ┐ value = the dual:
      (good-pulls   . ,(good-pulls duals))                    ; μ(g)   — material & eco pulls    ┘ Σℓλ + Σdμ, one solve
      (good-value    . ,(good-labour-content))                  ; ℓ̂_spec — embodied SNLT (Leontief); the μ of an unscarce good
      ,@(claim-tally x cols idx)                                ; what each citizen drew, and the certificate it cost
      ,@(if (riders?) `((placement . ,(mover-placement cols x idx))) '())   ; where each person and means stands, per cell
      ,@(let ((lx (legal-exposure x idx)))                       ; acts leaning on law the pack is unsure of
          (if (pair? lx) `((legal . ,lx)) '()))
      ,@(let ((wn (why-not-tally)))                              ; and what stopped the acts that are NOT here
          (if (pair? wn) `((blocked . ,wn)) '()))
      ,@(voice-report *voice-stances* (list->vector (map col-key cols)) *col-terms* *col-ell* x *voice-pushes* *voice-tau*)   ; the field this solve read, and what each part's voice cost at the margin
      (social        . ,(social-ledger x idx)))))               ; L / N·T / free / free-time f

;; the same reading after the discrete search decided its configuration (solve/engine §7)
(define (report-discrete)
  (call-with-values solve-discrete
    (lambda (cfg certified? lb cost k nodes)
      (set! *config* cfg)
      (format #t "   DISCRETE: ~a batch column(s); chose ~a ON~%" k
              (if (eq? cfg 'all) "ALL" (if (null? cfg) "0 (all OFF)" (length cfg))))
      (report-located)
      ;; CERTIFIED means the tree was exhausted — every config either solved or
      ;; provably unable to beat the incumbent — so the gap is 0 by search, and
      ;; `lb` is printed as the root relaxation for scale, not as the residual
      ;; uncertainty. Uncertified means the node budget ran out; then the gap is
      ;; genuine and is the best open node's bound.
      (if certified?
          (format #t "   [discrete: CERTIFIED global over 2^~a configs in ~a node(s); cost ~,3f, root LB ~,3f, gap 0]~%"
                  k nodes cost lb)
          (format #t "   [discrete: node budget ~a exhausted; cost ~,3f, best bound ~,3f, gap ≤ ~,3f]~%"
                  nodes cost lb (max 0.0 (- cost lb)))))))
