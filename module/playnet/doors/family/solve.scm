;;; family.scm — a household purse split across its members' needs by harmony.
;;;
;;; The family is the smallest scope where the person is still known, so its
;;; needs are keyed PER MEMBER (`need|person`) and the AID never leaves this
;;; solve (economy/demand-fold.scm: a person is resolved where they are
;;; known, a total is what crosses a fold). Every need is an acquisition recipe
;;; — euros consumed, one need-good produced, an errand's labour — built with
;;; the household file's own flow helpers; the purse is a finite stock of
;;; `spec-eur`; income is the household's real Pfand chain (`rp-hh-living`
;;; pinned to one week, `rp-hh-pfand` cashing the crate). A floor need may
;;; also name a SUBSTANCE (need-substance) it reduces to — the right, per
;;; docs/rights.md, is on what a good delivers, not on the good itself — in
;;; which case `reduction-defs` adds the "eat" edge and the wall lands there.
;;;
;;; Every need carries a KIND — the tension it enters harmony as
;;; (tension-kinds.scm), which is the social statement of how far it may be
;;; sacrificed:
;;;   floor  a right: a hard wall at the stated quantity (#:floors — the need
;;;          comes off the on-hand, the balance holds it). A purse that cannot
;;;          cover the floors has NO plan, and the solve says so. A right
;;;          takes no voice: the wall is free. `family-split`'s `best-effort`
;;;          shows the purse's best use anyway (every floor demoted to
;;;          `held` at a weight above the ladder) — a diagnostic, never a
;;;          plan: a right is still not shaved, the refusal still stands.
;;;   held   a need: wall at zero, at ease at the stated quantity, the slope
;;;          the attached voice (#:insurance (g 0 q 1 v)). It trades at the
;;;          margin like a want and can never be zeroed.
;;;   des    a want: Σ v_d g_d² with v_d the attached voice; can be set aside
;;;          for a finite price, and the quietest rows go first.
;;; The kind decides who can be zeroed; the voice decides the order among
;;; those who can — as the spec weights social desire (playnet.typ §Desire as
;;; harmony, solve/emphasis.scm): a member's attachments are their simplex, one
;;; whole hand = *desire-w0*, scaled by their consumer voice
;;; (family-voice-of). The household is a scope like any other: consumer
;;; voice blends contribution by ability (a member's hours, MEMBERS' hours,
;;; read against the hours their capacity could give, MEMBERS' capacity — a
;;; child's or an elder's reads at the standard, real and never zero), and
;;; citizenship (an equal share of the household's social free time) — the
;;; SAME law observation/account.scm reads for the federation
;;; (household-consumer-voice), never an approximation of it. An undeclared
;;; MEMBERS reads every owner as an equal citizen, unchanged from before.
;;; Person-fairness is not a fourth mechanism beyond voice: each member has
;;; floors and held needs of their own, and that is what keeps them whole.
;;;
;;; Beside the split, `family-externalities` reads each ask for the table:
;;; what a held/des row MOVED from the other members, by leave-one-out
;;; re-solves of the same family-split — the split's own counterfactual, no
;;; second mechanism. Floors are not read: a right's cost to the others is
;;; sanctioned by construction, and the number would only be used against the
;;; medicine.
;;;
;;; Read by tests/family-money-harmony-test.scm and by the dial's family face
;;; through the gateway (`family-split` is JSON-shaped: alists of strings and
;;; numbers only).

(define-module (playnet doors family solve)
  #:use-module ((playnet utils units) #:select (%count-unit))
  #:use-module ((playnet utils catch) #:select (catch* throw*))
  #:use-module (srfi srfi-1)
  #:use-module (playnet solve engine)
  #:use-module (playnet solve compile)
  #:use-module (playnet solve solver)
  #:use-module (playnet vf schemas)
  #:use-module (playnet knowledge recipes household)
  #:use-module ((playnet knowledge catalogues substances) #:select (closure-reduction))   ; the reduction: a form in, the substance a floor reads out
  #:use-module ((playnet solve externality) #:select (withdrawal-displacement))
  #:use-module ((playnet solve emphasis) #:select (emphasis-masses))   ; the spec's law: shares × voice
  #:use-module ((playnet observation account) #:select (household-consumer-voice))   ; the SAME consumer-voice law, no scope tree
  #:export (family-split family-bills family-externalities %family-demo-needs %pfand-per-trip
            need-person need-what need-cost need-want need-voice need-kind need-good
            need-substance need-substance-good need-floor-good
            need-total-by-kind member-person member-capacity member-hours))

;;; A need: (person what €-each wanted voice kind [substance]); voice = the
;;; attached emphasis, the row's total tension mass (a right carries 0: it
;;; takes none), kind ∈ floor | held | des (a five-long row reads as des).
;;; SUBSTANCE, the seventh field, is present only on a floor row whose right
;;; is not on the good it names but on what that good reduces to (docs/
;;; rights.md: "a hard limit written on bread refuses rice"). "groceries" is
;;; a FORM — plain food bought — not the substance a household actually has
;;; a right to, which is nutrition; SUBSTANCE names that row and
;;; reduction-defs (below) inserts the "eat" edge the doc calls the composite
;;; a right really is: claim a form → eat it → the substance the floor reads.
;;; A floor with no SUBSTANCE (medicine — no substitute in this model) walls
;;; its own good directly, exactly as before: the doc sanctions that as the
;;; degenerate case where forcing the form indirectly and forcing it directly
;;; coincide. The demo states its attachments on the face's geometric ladder —
;;; 1, 2, 5, 10, … 1000, three steps to each factor of ten. "all" is the
;;; household: what the four share — food, the roof's running costs, the
;;; connection. One week. Bob (15) and Dennis (9) are at school, Christine
;;; commutes to work, Alice is on a prescription and in physio.
(define %family-demo-needs
  '(;; ── the household ────────────────────────────────────────────────────
    ("all"   "groceries"       12.0 7.0    0 floor "nutrition") ; a day of plain food ×7 — the FORM; the right is on nutrition, what it reduces to
    ("all"   "fresh-produce"    3.0 7.0  100 held)    ; fruit and veg on top of the staples
    ("all"   "household-goods"  8.0 1.0   46 held)    ; soap, paper, bin bags
    ("all"   "internet-phone"  30.0 1.0  215 held)    ; the monthly plan, due this week
    ("all"   "treats"           4.0 3.0   10 des)     ; cake on Sunday, ice cream
    ;; ── alice ───────────────────────────────────────────────────────────
    ("alice" "medicine"        30.0 1.0    0 floor)   ; the prescription
    ("alice" "physio"          25.0 1.0  464 held)    ; the weekly session
    ("alice" "newspaper"        1.5 7.0    5 des)
    ;; ── bob, 15 ─────────────────────────────────────────────────────────
    ("bob"   "schoolbooks"     25.0 2.0  464 held)    ; term starts
    ("bob"   "transit-school"  30.0 1.0  464 held)    ; the student pass
    ("bob"   "phone-credit"    10.0 1.0   10 des)
    ("bob"   "videogame"       50.0 1.0    1 des)
    ;; ── christine ───────────────────────────────────────────────────────
    ("christine" "transit-pass"    40.0 1.0  464 held)    ; the commute to work
    ("christine" "work-lunches"     5.0 5.0   22 des)
    ("christine" "coffee-beans"     9.0 1.0    5 des)
    ("christine" "concert"         35.0 1.0    2 des)
    ;; ── dennis, 9 ───────────────────────────────────────────────────────
    ("dennis" "shoes"           45.0 1.0  215 held)    ; outgrown the last pair
    ("dennis" "swimming"        15.0 2.0  100 des)     ; the lessons
    ("dennis" "birthday-gift"   15.0 1.0   10 des)     ; a friend's party on Saturday
    ("dennis" "videogame"      50.0 1.0    1 des)))

(define (need-person n) (first n))
(define (need-what n) (second n))
(define (need-cost n) (third n))
(define (need-want n) (fourth n))
(define (need-voice n) (fifth n))
(define (need-kind n) (if (> (length n) 5) (sixth n) 'des))
(define (need-substance n) (if (> (length n) 6) (seventh n) #f))
(define (need-good n) (string-append (need-what n) "|" (need-person n)))
(define (need-substance-good n) (and (need-substance n) (string-append (need-substance n) "|" (need-person n))))
;; the row a floor lands on: the substance when the need names one (the right,
;; blind to which form supplied it), its own good otherwise (medicine: no
;; substitute here, so forcing the form indirectly IS forcing the substance)
(define (need-floor-good n) (or (need-substance-good n) (need-good n)))
(define (need-proc n) (string-append "buy-" (need-good n)))

(define (need-total-by-kind needs kind)
  "€ asked by the needs of KIND."
  (fold + 0.0 (map (lambda (n) (* (need-cost n) (need-want n)))
                   (filter (lambda (n) (eq? (need-kind n) kind)) needs))))

;; A member: (person capacity hours) — CAPACITY a_p ∈ [0,1], the contribution-
;; capacity factor (1 = full capacity to labour; a child's, an elder's,
;; anyone's reduced capacity is lower); HOURS the labour they contributed to
;; the household's own reproduction this week. A person absent from the
;; declared MEMBERS reads as an equal citizen — capacity 1, hours 0 — no
;; information is no penalty, same convention solve/emphasis.scm reads a #f voice
;; as (§The credit identity; observation/account.scm household-consumer-voice).
(define (member-person m) (first m))
(define (member-capacity m) (second m))
(define (member-hours m) (third m))

;; The household's own consumer voice — the SAME law the federation reads
;; (playnet.typ §The credit identity, observation/account.scm), not an
;; approximation of it: contribution by ability (hours worked over capacity),
;; citizenship an equal share of the household's own social free
;; time. Undeclared MEMBERS (the default: '()) collapses to the flat voice
;; family-masses always used — every owner, including "all", is an equal
;; citizen — so an unedited ledger's numbers are unchanged. A declared member
;; reads their real v_p^cons; any other owner (the household pseudo-member
;; "all", or a name never declared) reads the mean voice across MEMBERS: the
;; standing an average citizen carries, never privileged or zeroed for want
;; of a row in the table.
(define* (family-voice-of members #:key (per-citizen-hours 40.0))
  (if (null? members)
      (lambda (_) 1.0)
      (let* ((voices (household-consumer-voice members #:per-citizen-hours per-citizen-hours))
             (mean   (/ (fold + 0.0 (map cdr voices)) (length voices))))
        (lambda (owner) (or (assoc-ref voices owner) mean)))))

(define %pfand-per-trip (* %hh-pfand-bottles %hh-pfand-rate))   ; €5

;; A floor is a right, not a term: nothing buys a way out of it, so a purse
;; that cannot cover the floors has NO plan (family-split's `result`, above).
;; That is the correct answer to "is there a plan" — but it throws away what
;; the purse COULD still do, which is worth showing beside the refusal. The
;; best-effort fallback re-solves the SAME needs with every floor DEMOTED to
;; `held` at a weight far above any real voice on the ladder (VOICE_LADDER
;; tops out at 1000 in the face) — so it is served first, without turning the
;; solve's hard infeasibility (floors subtract from on-hand unconditionally)
;; into the bounded kind that can absorb a shortfall. This is read-only
;; information for the face ("here is the best use of the purse we found"),
;; never a plan: `feasible?` on the outer result stays #f regardless.
(define %floor-priority-voice 1e7)
(define (demote-floors needs)
  (map (lambda (n) (if (eq? (need-kind n) 'floor)
                       (list (need-person n) (need-what n) (need-cost n) (need-want n)
                             (need-voice n) 'held)
                       n))
       needs))

(define (acquisition-defs needs)
  (map (lambda (n)
         (let* ((pid (need-proc n))
                (p (hh-process pid (string-append "Buy " (need-what n) " for " (need-person n)) 0.25
                               #:tags '("tag:errand"))))
           (hh-def p
                   (list (hh-work (string-append pid "-work") 0.25 pid)
                         (hh-consume (string-append pid "-eur") "spec-eur" (need-cost n) pid)
                         (hh-produce (string-append pid "-out") (need-good n) 1.0 pid #:primary #t))
                   (string-append "recipe-" pid) (need-what n) (need-good n))))
       needs))

;; A floor need naming a SUBSTANCE gets one more recipe: the reduction docs/
;; rights.md calls the composite a right really is (claim a form → eat it → the
;; substance the floor reads) — catalogues/substances.scm's closure-reduction, the SAME
;; combinator live.scm's `eat` and housing's `live-in` are, over a closure of
;; one row. Costless and instant (the buying errand above already prices and
;; schedules the acquisition) and 1:1, so it moves where the wall sits without
;; moving how much the household buys or spends.
(define (reduction-defs needs)
  (filter-map
   (lambda (n)
     (and (need-substance n)
          (let* ((pid (string-append "eat-" (need-good n)))
                 (red (closure-reduction
                       (hh-process pid (string-append "Eat " (need-what n) " for " (need-person n)) 0)
                       (list (list "" (need-good n) 1.0 %count-unit))
                       (list (cons (need-substance-good n) 1.0)))))
            (hh-def (car red) (cdr red) (string-append "recipe-" pid) (need-what n) (need-substance-good n)))))
   needs))

(define (income-defs)
  (filter (lambda (d) (member (recipe-process-id (car d)) '("rp-hh-living" "rp-hh-pfand")))
          (append household-living-defs household-waste-recipe-defs)))

;; the ledger's masses, as the spec weights social desire (solve/emphasis.scm): a
;; member's attachments are their simplex, one whole hand = *desire-w0*,
;; scaled by their consumer voice (family-voice-of — the SAME law the
;; federation reads, playnet.typ §The credit identity; flat for every owner
;; when MEMBERS is undeclared, exactly as before). A right takes no voice and
;; enters no hand. WEIGHTED? #f spreads each hand evenly — the kinds still
;; hold, so the uniform run is "no ordering among wants", never "no needs".
(define* (family-masses needs weighted? #:key (members '()) (per-citizen-hours 40.0))
  "((person good mass) …) for NEEDS — the one place a ledger becomes weight."
  (emphasis-masses
   (map (lambda (n)
          (list (need-person n) (need-good n)
                (cond ((eq? (need-kind n) 'floor) 0)
                      (weighted? (need-voice n))
                      (else 1))))
        needs)
   (family-voice-of members #:per-citizen-hours per-citizen-hours) *desire-w0*))

;; The best-effort fallback's own masses: as family-masses, but a floor
;; (demoted to `held` by demote-floors) reads %floor-priority-voice instead
;; of the ordinary 0-or-voice branch, regardless of WEIGHTED? — the demotion
;; is a read-only diagnostic, not a re-run of the caller's own weighting.
(define* (best-effort-masses needs weighted? #:key (members '()) (per-citizen-hours 40.0))
  (emphasis-masses
   (map (lambda (n)
          (list (need-person n) (need-good n)
                (cond ((eq? (need-kind n) 'floor) %floor-priority-voice)
                      (weighted? (need-voice n))
                      (else 1))))
        needs)
   (family-voice-of members #:per-citizen-hours per-citizen-hours) *desire-w0*))

;; The household as a world: the purse in stock, one week of living pinned as a
;; fact, LABOUR-H on hand, and every need entered as its kind at its mass
;; (family-masses). TIER, when given, is the bill's tier (engine *promote*):
;; set the moment the world is declared, so the pour below reads the tier
;; table. → the masses used.
(define* (family-world! needs purse #:key (weighted? #t) (labour-h 20.0) (masses #f) (tier #f)
                        (members '()) (per-citizen-hours 40.0))
  (let ((defs (append (acquisition-defs needs) (reduction-defs needs) (income-defs))))
    (declare-world! #:places '(("home" 0.0 0.0))
                    #:templates (compile-recipe (hh-defs-processes defs) (hh-defs-flows defs))))
  (set-promote! tier)
  (hash-set! *init* (lg "spec-eur" (cell "home" 0)) (exact->inexact purse))
  ;; one week of living is a FACT: pinned, it fills the crate once
  (with-col-fixed! (list (cons "p|rp-hh-living|home@0" 1.0)))
  (hash-set! *A* (cell "home" 0) (exact->inexact labour-h))
  (let* ((masses* (or masses (family-masses needs weighted? #:members members #:per-citizen-hours per-citizen-hours)))
         (w (lambda (n) (or (any (lambda (m) (and (equal? (cadr m) (need-good n)) (caddr m))) masses*) 0.0))))
    ;; each need enters as its kind, weighted at its mass
    (apply-repro-bands!
     (repro-bands
      #:floors    (filter-map (lambda (n) (and (eq? (need-kind n) 'floor)
                                               (cons (lg (need-floor-good n) (cell "home" 0)) (exact->inexact (need-want n)))))
                              needs)
      #:insurance (filter-map (lambda (n) (and (eq? (need-kind n) 'held)
                                               (list (lg (need-good n) (cell "home" 0)) 0.0 (exact->inexact (need-want n)) 1.0 (w n))))
                              needs)))
    (for-each (lambda (n)
                (when (eq? (need-kind n) 'des)
                  (hash-set! *demand* (lg (need-good n) (cell "home" 0)) (exact->inexact (need-want n)))
                  (hash-set! *desire-weight* (lg (need-good n) (cell "home" 0)) (w n))))
              needs)
    (set-willing! (lambda (w s c) #t))
    (set-legal-decorate! (lambda (p c) (values #f 0.0 '())))
    (set-backend! (cond-expand (guile 'native-c) (else 'native)))
    masses*))

;;; ── the week asked backwards: the three bills ───────────────────────────────
;;; With euros and hours for sale — a euro at 1/EUR-PER-HOUR hours, an hour at
;;; an hour — hold rights, then needs, then wants as walls and read what each
;;; made the solve buy beyond the purse and the week's hours (engine *acquire*,
;;; bills-fold, docs/planning/socialization/three-bills.md): the fold nets every tier of the
;;; residue a barrier solve buys with nothing held; this reads the two rows the
;;; household has — euros and hours — off each bill.
(define* (family-bills needs purse #:key (weighted? #t) (labour-h 20.0) (eur-per-hour 15.0)
                       (members '()) (per-citizen-hours 40.0))
  "((tiers . (((tier . rights|needs|wants) (eur . €) (hours . h) (step-eur . €) (step-hours . h) (feasible? . bool)) …))
    (eur-per-hour . €) (residue-eur . €) (residue-hours . h))"
  (define eur-row "spec-eur#home@0")
  (define h-row   "Lab|home@0")
  (define (units bill row) (let ((r (assoc row bill))) (if r (cadr r) 0.0)))
  (define (run tier)                       ; → (bill feasible?)
    (family-world! needs purse #:weighted? weighted? #:labour-h labour-h #:tier tier
                   #:members members #:per-citizen-hours per-citizen-hours)
    (set-acquire! `(("spec-eur" . ,(/ 1.0 eur-per-hour)) ("labour" . 1.0)))
    (catch* #t
      (lambda () (located-bill))
      (lambda (key . args)
        (if (memq key '(misc-error planner-starvation)) (list '() #f) (apply throw* key args)))))
  (let* ((rows (bills-fold run))
         (residue (assq-ref (cdar rows) 'residue-bill))
         (prev-e 0.0) (prev-h 0.0))
    `((tiers . ,(map (lambda (row)
                       (let* ((bill (assq-ref (cdr row) 'bill))
                              (e (units bill eur-row)) (h (units bill h-row))
                              (out `((tier . ,(car row)) (eur . ,e) (hours . ,h)
                                     (step-eur . ,(- e prev-e)) (step-hours . ,(- h prev-h))
                                     (feasible? . ,(assq-ref (cdr row) 'feasible?)))))
                         (set! prev-e e) (set! prev-h h)
                         out))
                     rows))
      (eur-per-hour . ,eur-per-hour)
      (residue-eur . ,(units residue eur-row))
      (residue-hours . ,(units residue h-row)))))

(define* (family-split needs purse #:key (weighted? #t) (labour-h 20.0) (masses #f)
                       (members '()) (per-citizen-hours 40.0))
  "Split PURSE euros across NEEDS by harmony. Returns an alist:
     ((feasible? . bool) (floors . €)
      (needs . (((person . p) (what . w) (want . q) (got . x) (met . f) (voice . v) (mass . m) (kind . k) (cost . c)) …))
      (spent . €) (purse . €) (pfand-trips . n) (income . €) (labour-h . h)
      (best-effort . alist-or-#f))
   VOICE is the row's stated attachment, MASS what the solve weighed it at —
   the member's share of their own hand × one whole emphasis (family-masses),
   scaled by their consumer voice (MEMBERS — capacity + hours worked this
   week; playnet.typ §The credit identity, family-voice-of). WEIGHTED? #f
   spreads every hand evenly (the kinds still hold). MASSES, when given, are
   taken as they stand instead of derived from NEEDS — a counterfactual that
   withdraws a row holds the standing weights fixed.
   BEST-EFFORT, present only when FEASIBLE? is #f, is this same alist shape
   for the purse's best use anyway — never a plan, only a diagnostic (see
   demote-floors)."
  (define masses* (family-world! needs purse #:weighted? weighted? #:labour-h labour-h #:masses masses
                                 #:members members #:per-citizen-hours per-citizen-hours))
  (define (w n)
    (or (any (lambda (m) (and (equal? (cadr m) (need-good n)) (caddr m))) masses*) 0.0))
  ;; a purse that cannot cover the floors has no plan. With living pinned the
  ;; presolve RAISES on that (a decided count left a column no value) rather
  ;; than publishing feasible? #f; both read as "no plan" here.
  (define (result x idx feasible?)
    (let* ((col (lambda (p) (if feasible? (col-value x idx (string-append "p|" p "|home@0")) 0.0)))
           (rows (map (lambda (n)
                        (let ((got (col (need-proc n))))
                          `((person . ,(need-person n)) (what . ,(need-what n))
                            (want . ,(need-want n)) (got . ,got)
                            (met . ,(min 1.0 (/ got (need-want n))))   ; satiation: a want is a floor, never a ceiling
                            (voice . ,(need-voice n)) (mass . ,(w n))
                            (kind . ,(need-kind n)) (cost . ,(need-cost n)))))
                      needs))
           (trips (col "rp-hh-pfand")))
      `((feasible? . ,feasible?)
        (floors . ,(need-total-by-kind needs 'floor))
        (needs . ,rows)
        (spent . ,(fold + 0.0 (map (lambda (r) (* (assq-ref r 'cost) (assq-ref r 'got))) rows)))
        (purse . ,(exact->inexact purse))
        (pfand-trips . ,trips)
        (income . ,(* %pfand-per-trip trips))
        (labour-h . ,(exact->inexact labour-h))
        ;; NOT a plan: `feasible?` above stays #f. A purse that cannot cover
        ;; the floors is shown its best possible use anyway — every floor
        ;; demoted to `held` at %floor-priority-voice, so it is served first
        ;; without the wall that made the real solve infeasible. Absent
        ;; whenever there is nothing to demote (feasible, or floor-free).
        (best-effort . ,(and (not feasible?) (any (lambda (n) (eq? (need-kind n) 'floor)) needs)
                             (family-split (demote-floors needs) purse
                                           #:weighted? weighted? #:labour-h labour-h
                                           #:masses (best-effort-masses needs weighted?
                                                      #:members members #:per-citizen-hours per-citizen-hours)))))))
  (catch* #t
    (lambda ()
      (call-with-values located-solve
        (lambda (x forms lf idx)
          (result x idx (not (eq? #f (assq-ref (certificate-of-last-solve) 'feasible?)))))))
    (lambda (key . args)
      ;; 'planner-starvation is the presolve's raise; anything else is a bug
      (if (memq key '(misc-error planner-starvation))
          (result #f #f #f)
          (apply throw* key args)))))

;;; ── the externality display: what each ask moved from the others ────────────
;;; The instrument the table lacked: inflation at a family table is mostly
;;; unseen, not malicious, so before any mechanism CHARGES for a declaration,
;;; show what it displaces. For every held/des row, "moved" is the euros that would
;;; have reached the OTHER members had the row not been asked — the counter-
;;; factual is family-split itself, re-run without the row (solve/externality.scm's
;;; `withdrawal-displacement`, instantiated at one good: euros). By convexity a
;;; withdrawn ask can only free resources, so moved ≥ 0 up to solver noise.

(define (euros-to-others r person)
  "€ a family-split result grants the rows PERSON does not own."
  (fold + 0.0
        (filter-map (lambda (row)
                      (and (not (string=? (assq-ref row 'person) person))
                           (* (assq-ref row 'got) (assq-ref row 'cost))))
                    (assq-ref r 'needs))))

(define* (family-externalities needs purse #:key (weighted? #t) (labour-h 20.0)
                               (members '()) (per-citizen-hours 40.0))
  "What each held/des ask in NEEDS displaces, for the table: leave-one-out re-solves of
   family-split, one per row and one per person (a person's counterfactual
   withdraws all their held/des rows; floors always stay). Returns an alist,
   JSON-shaped like family-split:
     ((feasible? . bool) (purse . €)
      (rows . (((person . p) (what . w) (kind . k) (voice . v) (moved . €)) …))
      (persons . (((person . p) (moved . €)) …)))"
  ;; the counterfactual holds the STANDING weights: a withdrawn row leaves
  ;; the others' masses as the base solve weighed them, so the displacement read is
  ;; the convex one (withdrawal frees resources) and never the re-concentration
  ;; of the withdrawing member's hand on their remaining rows
  (let* ((masses (family-masses needs weighted? #:members members #:per-citizen-hours per-citizen-hours))
         (solve (lambda (ns) (family-split ns purse #:weighted? weighted? #:labour-h labour-h
                                            #:masses masses)))
         (base (solve needs)))
    (if (not (assq-ref base 'feasible?))
        `((feasible? . #f) (purse . ,(exact->inexact purse)) (rows . ()) (persons . ()))
        (let* ((moved-without (lambda (person keep?)
                                (withdrawal-displacement solve euros-to-others base needs keep? person)))
               (asked (filter (lambda (n) (memq (need-kind n) '(held des))) needs)))
          `((feasible? . #t)
            (purse . ,(exact->inexact purse))
            (rows . ,(map (lambda (n)
                            `((person . ,(need-person n)) (what . ,(need-what n))
                              (kind . ,(need-kind n)) (voice . ,(need-voice n))
                              (moved . ,(moved-without (need-person n)
                                                       (lambda (m) (not (eq? m n)))))))
                          asked))
            (persons . ,(map (lambda (p)
                               `((person . ,p)
                                 (moved . ,(moved-without p
                                             (lambda (m) (or (not (string=? (need-person m) p))
                                                             (eq? (need-kind m) 'floor)))))))
                             (delete-duplicates (map need-person asked)))))))))
