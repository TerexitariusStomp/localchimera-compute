;;; solve/ingest.scm — one form for every limit, read at a different scale.
;;;
;;; playnet.typ §"Worker, soil, and tool: one field": the labour pool's burnout
;;; ratio, the ecological agent's regenerative envelope, the engineered system
;;; nearing its design limit "read together are ONE FORM ... each is the same
;;; convex possibility-tension φ(s) = −w log s, READ AT A DIFFERENT SCALE."
;;;
;;; The planner already computes that one barrier. What it lacked was a way to
;;; SAY the scale, so the scale was encoded in which of four hash tables a
;;; profile was dropped into — and the names carried a pair of choices without
;;; ever naming the two axes:
;;;
;;;     extent \ window   per period (a rate)   whole horizon (a tipping point)
;;;     one located good  *frag-cap*            —
;;;     a spec, anywhere  *frag-spec*           *frag-budget*
;;;     a container       —                     *frag-container*
;;;
;;; Six cells, four tables, two holes — and no way for a bioregion to declare a
;;; recharge envelope (a RATE) and a deforestation tipping point (a TOTAL) at
;;; once, because its record carried one undifferentiated list.
;;;
;;; So a fragility is one record with three orthogonal fields:
;;;
;;;   EXTENT  which draws it measures   (good | spec | contained | within)
;;;   WINDOW  over what they are summed ('rate per period | 'horizon in total)
;;;   SIDE    which way the wall faces  ('ceiling on a draw | 'floor on a level)
;;;
;;; and the grid is filled by combination rather than by adding tables. The
;;; profile itself — (lo hi α w) — is untouched; this says WHERE to read the
;;; pressure and WHICH WAY it is felt, never how the barrier is shaped.
;;;
;;; SIDE is the axis reproduction needed. A ceiling is a limit on what may be
;;; DRAWN — the ecological case, every cell of the grid. A floor is a limit on
;;; what must be HELD — a stock's calamity reserve, a nutrient's bare need — and
;;; it had lived in a table of its own (*frag-floor*) outside the record, so a
;;; reproduction floor and an ecological envelope were "one form read at a
;;; different scale" in the spec and two objects in the code. A floor-sided
;;; fragility on a good routes to the good's reproduction BAND (planner.scm
;;; *band*), where the same profile reads: lo = the wall, [lo,hi] at
;;; quantile α = the margin held above it, w = its steepness — the `held` term.
;;;
;;; ── WITHIN: the scale the planner could not express ─────────────────────────
;;;
;;; `contained` reads the specs mapped into a container AT THE CONTAINER'S OWN
;;; CELL. That is right for an ecological agent whose contents are specs (the
;;; Amazon and its trees) and silent about a limit shared by many PLACES: two
;;; farms inside one watershed pumping one aquifer draw at `water#farm-a@t` and
;;; `water#farm-b@t`, and a fragility on the shed sees neither. Measured: two
;;; plots pump identically with and without the shed's barrier.
;;;
;;; `within` closes that. It sums the named specs over every cell AT OR UNDER a
;;; place in the containment tree, so the commons is felt by the scope that
;;; holds it — which is what playnet.typ §bioregion requires of custody: the
;;; steward is "whoever feels the pull as the draw nears the limit", and an
;;; over-draw must be "felt by exactly the scope that can ease it".
;;;
;;; The walk is the federation's own. `containment-chain` (aggregation/
;;; containment.scm) is what governance uses to find a resource's location and
;;; bioregions.scm to find a scope's shed; asking it whether a container appears
;;; in a place's ancestry is the same question read from the other end, so
;;; there is no second notion of "inside" anywhere in the system.

(define-module (playnet vf formulas fragility)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils records) #:select (define-vf-record vf-record-type vf-record-constructor vf-record-predicate vf-record-accessor))
  #:use-module (playnet vf schemas)
  #:use-module ((playnet vf aggregation containment) #:select (containment-chain))
  #:export (%make-fragility
            fragility-kind
            fragility-key
            make-fragility
            fragility-with-profile
            frag-on-good
            floor-on-good
            frag-rate
            frag-budget
            frag-contained
            frag-within
            pooled-budget
            places-within
            as-fragility
            as-fragilities
            fragility-spec-names
            fragility-specs-of
            ;; the record declarations below define these (define-vf-record; check-record-exports holds the list)
            <fragility> fragility? fragility-profile fragility-extent fragility-window fragility-specs
            fragility-level fragility-note fragility-side))

;; ── the record ─────────────────────────────────────────────────────────────
(define-vf-record <fragility> Fragility
  (profile extent window specs level note side))
  ;; (lo hi alpha w) — the tension's shape, unchanged
  ;; what it measures  (see below)
  ;; 'rate | 'horizon
  ;; for `within`: the specs it covers
  ;; a MEASURED starting level, when the limit is a stock   ; 'ceiling (a limit on a draw) | 'floor (a level to hold)
(define %make-fragility (vf-record-constructor <fragility>))

;; EXTENT is (kind . key):
;;   (good      . "spec#place@t")  one located good, one cell
;;   (spec      . "groundwater")   that spec wherever it is drawn
;;   (contained . "amazon")        the specs mapped into a container, at its cell
;;   (within    . "doon-shed")     everything named, anywhere at or under a place
(define (fragility-kind f) (car (fragility-extent f)))
(define (fragility-key f)  (cdr (fragility-extent f)))

(define* (make-fragility profile #:key (over #f) (window 'rate) (specs '())
                                      (level #f) (note #f) (side 'ceiling))
  (%make-fragility profile over window specs level note side))

;; the same fragility with another profile — what a dilemma's "wall stood aside"
;; horn does to a contested one (its tip pushed out of reach, its extent, window
;; and side untouched, so the spec stays barrier-bounded rather than becoming a
;; free raw). Records are immutable; this is the one way to say "as before, but".
(define (fragility-with-profile f profile)
  (let ((f (as-fragility f)))
    (%make-fragility profile (fragility-extent f) (fragility-window f) (fragility-specs f)
                     (fragility-level f) (fragility-note f) (fragility-side f))))

;; ── the four spellings, as constructors over the one record ─────────────────
;; Each names a cell of the grid, so a call site reads as the scale it means.
(define* (frag-on-good g profile #:optional (note #f))
  "One located good, one cell — a cap on this thing, here, now."
  (make-fragility profile #:over (cons 'good g) #:window 'rate #:note note))

(define* (floor-on-good g profile #:optional (note #f))
  "One located good, one cell — a LEVEL to hold here, now, with a margin: the
   calamity reserve behind a stock. Same profile, read from the other side:
   lo is the wall (never breached), the tip at quantile α of [lo,hi] the margin
   the plan holds while it can, w how hard the margin is defended."
  (make-fragility profile #:over (cons 'good g) #:window 'rate #:note note #:side 'floor))

(define* (frag-rate spec profile #:optional (note #f))
  "A spec wherever drawn, per period — a RATE the draw may not exceed. A
   regenerative envelope is this: what may be taken given what comes back."
  (make-fragility profile #:over (cons 'spec spec) #:window 'rate #:note note))

(define* (frag-budget spec profile #:optional (note #f))
  "A spec's TOTAL draw across the horizon — a tipping point for one spec.
   Unlike a rate, it does not reset: spend it and it is spent."
  (make-fragility profile #:over (cons 'spec spec) #:window 'horizon #:note note))

(define* (frag-contained container profile #:optional (note #f))
  "Everything mapped into an ecological container, summed across the horizon —
   the Amazon feeling its trees logged."
  (make-fragility profile #:over (cons 'contained container) #:window 'horizon #:note note))

(define* (frag-within place specs profile #:key (window 'rate) (note #f))
  "The named SPECS summed over every cell at or under PLACE. With 'rate, a
   shared sustainable yield (the shed's aquifer, per season); with 'horizon, a
   shared tipping point (the shed's standing timber, ever). This is the scale a
   COMMONS is held at — many drawers, one limit."
  (make-fragility profile #:over (cons 'within place) #:window window
                  #:specs specs #:note note))

;; ── the pooled budget: a limit that is a LEVEL, held in custody ─────────────
;; playnet.typ §"Shared budgets and possibility-tension": an agent drawn on by
;; many scopes has one regenerative envelope, and "the budget itself is a STOCK
;; on the surface, with its own gap signal, held in stewardship custody at the
;; scope that speaks for the agent. Every consume or use event from any scope is
;; debited against this one shared stock."
;;
;; `frag-within` alone prices the pooled pressure but takes its headroom from
;; the profile's tip — a governance-set threshold. A pooled BUDGET takes its
;; headroom from a MEASUREMENT instead: metres of head in the aquifer, standing
;; timber in the shed, tonnes of carbon in the soil. The barrier is the same
;; barrier; what changes is that the level is a fact about the world, so a shed
;; already half-drawn starts half-drawn rather than starting at its threshold.
;;
;; Both properties at once, which is the point: a level that falls and rises
;; (the stock), carried at a fixed governance weight (the fragility) so the plan
;; eases off before the wall rather than riding it — the same pairing
;; `*stock-frag-w*` names for a single-place stock, here for a shared one.
(define* (pooled-budget place specs level profile #:key (window 'carry) (note #f))
  "The shared envelope of an agent many scopes draw on, as a measured LEVEL
   over every place at or under PLACE.

   'carry is the stock reading, and the default: the level is required standing
   at EVERY period, so it obeys S[t] = S[0] − draws-to-date + restores-to-date,
   ≥ 0 throughout. Because each period's constraint counts only what has
   happened up to it, the level can be spent forward and rebuilt forward and
   never borrowed backward — playnet.typ's temporal axis is a chain linked only
   forward by storage, with no activity that moves a good from the future to
   the present.

   'horizon states ONE constraint on the whole plan instead, which lets a
   restore in a late period pay for a draw in an early one — an aquifer
   overdrawn in year 1 and recharged in year 5 reads as never overdrawn.
   Fine for a budget that is genuinely only a total; wrong for a level.

   'rate reads the same specs as a per-period yield, with no carry at all."
  (make-fragility profile #:over (cons 'within place) #:window window
                  #:specs specs #:level level #:note note))

;; ── the containment question, asked with the federation's own walk ──────────
(define (places-within container spatials places)
  "Every place in PLACES at or under CONTAINER — the commons' drawers.

   A place is `within` when the container appears in its ancestry, so the
   question is asked with the federation's own upward walk read from the other
   end. There is no downward walk anywhere in the system, and this does not add
   one: `containment-chain` is what governance uses to find a resource's
   location and bioregions.scm to find a scope's shed."
  (let ((resolve (lambda (id) (find (lambda (s) (equal? (spatial-thing-id s) id)) spatials))))
    (filter
     (lambda (p)
       (or (equal? p container)
           (and=> (resolve p)
                  (lambda (self)
                    (any (lambda (a) (equal? (spatial-thing-id a) container))
                         (containment-chain self
                                            #:parent-of spatial-thing-contained-in
                                            #:resolve resolve))))))
     places)))

;; ── back-compatible reading of the old pair shape ───────────────────────────
;; Bioregions and call sites already carry `(spec . (lo hi α w))` pairs, which
;; mean a per-period rate on that spec. They stay legal and are lifted here, so
;; nothing has to be rewritten to gain the record — a list may mix both.
(define (as-fragility x)
  (cond ((fragility? x) x)
        ((and (pair? x) (string? (car x)) (list? (cdr x)))
         (frag-rate (car x) (cdr x) "lifted from a (spec . profile) pair"))
        (else (error "not a fragility" x))))

(define (as-fragilities xs) (map as-fragility (or xs '())))

;; Which bare SPECS a fragility concerns — the question every consumer outside
;; this file actually asks (which goods carry a fragility, for substitution and
;; for conformance). Each extent names its specs differently, and that mapping
;; belongs here rather than at each call site: reading `car` off the list worked
;; only while every entry was a (spec . profile) pair, and breaks the moment one
;; is a record. A `contained` extent names a CONTAINER, not a spec, so it
;; contributes none — its contents are discovered from the containment map.
(define (fragility-spec-names f)
  (let ((f (as-fragility f)))
    (case (fragility-kind f)
      ((spec)      (list (fragility-key f)))
      ((within)    (fragility-specs f))
      ((good)      (let* ((g (fragility-key f)) (i (string-index g #\#)))
                     (list (if i (substring g 0 i) g))))
      (else '()))))

(define (fragility-specs-of xs)
  "Every bare spec named by a list of fragilities, in either shape."
  (delete-duplicates (append-map fragility-spec-names (or xs '()))))

