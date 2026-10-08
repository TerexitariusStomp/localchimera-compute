;;; worlds/feel-the-food.scm — FEEL THE FOOD.
;;;
;;; The principle, first, because the machinery below is only its arithmetic:
;;;
;;;     Food is known by the senses. Look at it, smell it, taste it — in the
;;;     growing, in the checking, in the handing on, in the eating. A date
;;;     printed on a package is a guess made months ago by someone who never met
;;;     this jar. Your nose is here now.
;;;
;;; This is not romanticism, it is the law of the land and the practice of every
;;; rescue network in the city. The Verbraucherzentrale's Leitfaden lists the
;;; criteria as sense-data — appearance and colour (mould, abnormal discolouration,
;;; cloudiness), consistency and surface (slimy, sliming, gas), smell and taste
;;; (musty, rotten, stale, rancid, fishy, soapy). foodsharing's own first rule is
;;; the Augen-Nasen-Mund-Test: share only what you would eat yourself. The
;;; Mindesthaltbarkeitsdatum may be exceeded — the notice at every Verteilstation
;;; says so — and what decides is a person, feeling the food.
;;;
;;; So the sensory check is a real economic act with a real cost, and it belongs
;;; in the plan rather than in a footnote.
;;;
;;; ── WHAT THIS FILE ADDS ──────────────────────────────────────────────────
;;; Nothing new. `formulas/cadence.scm` already carries the inspection model —
;;; the emergent intensity a* = clamp((1/κ)·ln(κD/λℓ), 0, 1), its discrete
;;; lumpy-event twin T* = √(2K/(Dκ)), and the reliance D = φH the plan reads off
;;; its own solve. And `conformance-catalogue.scm` says in as many words that one
;;; profile "serves skills, instruments, and BATCHES alike". Batches were always
;;; the intended third subject; nobody had pointed the machinery at them.
;;;
;;; Pointing it at a batch of food re-indexes the same closed form:
;;;
;;;   for a CREDENTIAL  a* is a fraction of PERIODS  — check every 1/a* periods
;;;   for a BATCH       a* is a fraction of UNITS    — open a*·n of the n units
;;;
;;; with the terms reading:
;;;   D = H·n   the harm a silent miss does, times the units riding on the check
;;;   κ         the drift — here literally PERISHABILITY, how fast this food
;;;             stops being what the last look said it was
;;;   ℓ         the labour of one check: pick it up, look, smell, taste
;;;   λ         the shared inspection-budget shadow price (1 = unconstrained)
;;;
;;; ── THE DESTRUCTIVE PART, WHICH IS THE INTERESTING PART ──────────────────
;;; A sensory check on food is not free like reading a certificate: **you eat the
;;; sample**. The unit you tasted is gone. So a batch inspection is a process with
;;; a YIELD LOSS of exactly the sampled units — which the planner already knows
;;; how to reason about, and which produces the right incentive without anyone
;;; writing it down: sampling one jar out of twelve costs 8 % of the batch, one
;;; out of a hundred costs 1 %, so the plan prefers to inspect in bulk. That is
;;; precisely why the statutory rule is written per BATCH and not per unit.
;;;
;;; ── CHARGENVERMUTUNG : the statutory rule, as data ───────────────────────
;;; The Leitfaden (§8, from the Berliner Mindestanforderungen): for more than 10
;;; units of the same product, open ONE as a sample and smell/taste it — and if
;;; that one is spoiled, **the whole batch is discarded**. One unit's verdict
;;; carries to n. It is a flat rule, indifferent to what the food is.
;;;
;;; Keeping both the statutory rule and the derived rate side by side is the
;;; point: `chargenvermutung-sample` says what Berlin asks, `feel-the-food-sample`
;;; says what the model would choose, and the gap between them is an argument
;;; about a rule rather than an opinion about it.
;;;
;;; ── PROVENANCE ───────────────────────────────────────────────────────────
;;; [DATA]  The Chargenvermutung threshold (>10 → 1) and the sensory criteria:
;;;   VZ Berlin Leitfaden §8, vendored at docs/reference/berlin-food/.
;;; [DATA]  The a* / T* closed forms: formulas/cadence.scm (social-means §1091).
;;; [DRAFT] Every κ, ℓ and H below is a judgment figure. They are the dials a
;;;   steward turns; the mechanism does not depend on their values.

;;; ─── the senses, named ────────────────────────────────────────────────────
;;; The check is not one act but four, and a rule that says "inspect" without
;;; saying which sense is being asked cannot be costed. Kept as data because the
;;; Leitfaden's criteria are grouped exactly this way.
(define-module (playnet planner knowledge worlds feel-the-food)
  #:use-module (playnet planner vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner formulas cadence)
  #:export (*feel-the-food-senses* sense-criteria sense-destructive?
            *feel-the-food-profiles* %feel-the-food-default feel-the-food-profile
            profile-kappa profile-ell profile-harm spec-perishability
            %chargenvermutung-threshold chargenvermutung-sample
            chargenvermutung-condemns? unpresumed-units %chargenvermutung-asserted-rho
            chargenvermutung-asserts-rho sample->implied-rho feel-the-food-rate
            feel-the-food-saturates? *batch-homogeneity* homogeneity
            feel-the-food-sample feel-the-food-verdict seed-feel-the-food!))

(define *feel-the-food-senses*
  '((sight  "Aussehen und Farbe"        (schimmel verfaerbung truebung))
    (touch  "Konsistenz und Oberfläche" (schmierig schleimbildung gasbildung))
    (smell  "Geruch"                    (modrig faul muffig ranzig tranig gaerig fischig seifig))
    (taste  "Geschmack"                 (ranzig gaerig seifig fremdartig))))

(define (sense-criteria sense)
  (let ((row (assq sense *feel-the-food-senses*))) (and row (caddr row))))

;;; SIGHT and SMELL leave the food intact; TASTE consumes it. That distinction is
;;; the whole cost structure: a look is cheap and non-destructive, a taste is the
;;; only sense that certifies a sealed jar and the only one that eats it.
(define (sense-destructive? sense) (eq? sense 'taste))

;;; ─── perishability IS the drift ──────────────────────────────────────────
;;; κ, read straight off the good's own classifier. `vf:perishability:high` on a
;;; leafy green (cold-chain.scm) is not decoration — it is the rate at which what
;;; the last look established stops being true.
;;; (class  κ drift/period  ℓ check-hours  H harm per silent miss)  [DRAFT]
(define *feel-the-food-profiles*
  '((high   0.60 0.02 40.0)
    (medium 0.25 0.02 25.0)
    (low    0.05 0.02 10.0)))

(define %feel-the-food-default 'medium)

(define (feel-the-food-profile class)
  (or (assq class *feel-the-food-profiles*)
      (assq %feel-the-food-default *feel-the-food-profiles*)))

(define (profile-kappa p) (list-ref p 1))
(define (profile-ell   p) (list-ref p 2))
(define (profile-harm  p) (list-ref p 3))

;;; the class off a <resource-specification>'s classifiers, defaulting safely to
;;; the middle rather than the cheapest.
(define (spec-perishability spec)
  (let ((cls (and spec (resource-specification-resource-classified-as spec))))
    (or (and (list? cls)
             (any (lambda (c)
                    (and (string? c)
                         (string-prefix? "vf:perishability:" c)
                         (string->symbol
                          (substring c (string-length "vf:perishability:")))))
                  cls))
        %feel-the-food-default)))

;;; ─── the statutory rule ──────────────────────────────────────────────────
(define %chargenvermutung-threshold 10)

(define (chargenvermutung-sample n)
  "The Leitfaden's rule: above 10 units of one product, open ONE. At or below the
   threshold every unit is judged on its own and nothing is destroyed to certify
   another."
  (if (> n %chargenvermutung-threshold) 1 0))

(define (chargenvermutung-condemns? sample-spoiled?)
  "One spoiled sample condemns the batch — the *Vermutung* itself. The inference
   is the rule's whole content: a verdict on one unit carried to n."
  (and sample-spoiled? #t))

;;; ─── WHERE a* APPLIES, AND WHERE IT DOES NOT ────────────────────────────
;;; Point a* at a batch and it CLAMPS AT 1: check every unit. That is not a
;;; mis-calibration — a* was derived for a check that does not consume what it
;;; checks, and whenever a silent miss costs more than a check, "check them all"
;;; is the right answer.
;;;
;;; And for three of the four senses it IS the right answer, and it is what the
;;; Leitfaden actually instructs: look at everything, smell everything. Sight,
;;; touch and smell leave the food intact, cost seconds, and the guide asks for a
;;; visual and sensory check on ALL loose goods. a* saturating is the model
;;; agreeing with the guide.
;;;
;;; TASTE is the exception, and the only place a sample size arises at all,
;;; because tasting is the only sense that consumes the unit. Two tiers:
;;;
;;;   sight · touch · smell   a* = 1         every unit, nothing lost
;;;   taste                   k of n         the unit tasted is gone
;;;
;;; ── WHAT THE STATUTORY RULE ASSERTS ─────────────────────────────────────
;;; *Chargenvermutung* is batch PRESUMPTION, and the presumption is its whole
;;; content: one producer, one lot, one storage history, so the units are treated
;;; as one object wearing n lids. Under that assumption one taste certifies n.
;;;
;;; Write ρ ∈ [0,1] for how far the presumption reaches, and the rule is exactly
;;; the ρ = 1 CORNER:
;;;
;;;     The Chargenvermutung is not a sample size. It is a claim that ρ = 1.
;;;
;;; Worth saying because it is checkable. Whether a batch is one object is an
;;; empirical question about how it was assembled, and a crate carried out of six
;;; shops is visibly not one object. The rule does not weigh that; it presumes it.
;;;
;;; ── AN HONEST ACCOUNT OF THE ARITHMETIC BELOW ───────────────────────────
;;; `unpresumed-units` is n minus what the presumption covers. It contains no
;;; optimisation and no a*: it is THE ASSUMPTION, COUNTED. It reproduces the
;;; statute at ρ = 1 BY CONSTRUCTION, not by deriving it — an earlier draft of
;;; this file said "the model derives the statute", and that was false. The useful
;;; direction is the converse: given a sample size someone proposes, read off the
;;; ρ it is asserting.
(define (unpresumed-units n rho)
  "The units the presumption does not cover: ⌈(1−ρ)·n + ρ⌉. ρ = 1 gives 1 (the
   statutory corner), ρ = 0 gives n. An assumption counted, not an optimisation."
  (max 1 (inexact->exact (ceiling (+ (* (- 1.0 rho) n) rho)))))

(define %chargenvermutung-asserted-rho 1.0)
(define (chargenvermutung-asserts-rho) %chargenvermutung-asserted-rho)

(define (sample->implied-rho n k)
  "The converse, and the direction that needs no invented numbers: a proposal to
   taste K of N units ASSERTS this ρ. Turns any sampling rule — the statute's, a
   steward's, another jurisdiction's — into the homogeneity claim it is making."
  (if (or (<= n 1) (<= k 0)) 1.0
      (max 0.0 (min 1.0 (/ (- n k) (- n 1.0))))))

;;; ─── a*, kept for what it does say ───────────────────────────────────────
(define* (feel-the-food-rate n class #:optional (lam 1.0))
  "a* for a batch of N units in perishability CLASS. SATURATES at 1 for any harm
   worth caring about — the correct instruction for the NON-DESTRUCTIVE senses,
   and no guidance at all for taste. Kept because the saturation is itself the
   result, and so a steward who lowers the harm or raises the check cost can see
   it stop saturating."
  (let ((p (feel-the-food-profile class)))
    (inspection-intensity (edge-reliance n (profile-harm p))
                          (profile-ell p) (profile-kappa p) lam)))

(define* (feel-the-food-saturates? n class #:optional (lam 1.0))
  (>= (feel-the-food-rate n class lam) 1.0))

;;; how far the presumption reaches. [DRAFT] — and every comparison below turns
;;; on these, so they carry more weight than any other number in this file.
(define *batch-homogeneity*
  '((sealed-lot   1.00)   ; one producer, one lot, one pallet — the law's picture
    (one-shop     0.85)   ; a day's rescue from a single Betrieb
    (mixed-rescue 0.40)   ; a crate assembled from several shops — the real case
    (unknown      0.10))) ; provenance lost; each unit is its own question

(define (homogeneity rho-or-class)
  (cond ((number? rho-or-class) rho-or-class)
        ((assq rho-or-class *batch-homogeneity*) => cadr)
        (else 0.40)))

(define* (feel-the-food-sample n class #:optional (lam 1.0) (batch-kind 'sealed-lot))
  "How many units to TASTE, given how far the presumption reaches. The other
   senses are applied to every unit and cost nothing but seconds."
  (unpresumed-units n (homogeneity batch-kind)))

(define* (feel-the-food-verdict n class #:optional (lam 1.0) (batch-kind 'sealed-lot))
  "→ the statutory sample and the presumption-counted one side by side, EACH WITH
   THE ρ IT ASSERTS. No verdict on the law: the two differ exactly insofar as the
   ρ we assert for this batch differs from the ρ = 1 the rule asserts, and which
   is right is an empirical question about the batch, not a fact this file knows."
  (let* ((stat (chargenvermutung-sample n))
         (ours (feel-the-food-sample n class lam batch-kind))
         (rho (homogeneity batch-kind)))
    `((units . ,n) (class . ,class) (batch-kind . ,batch-kind)
      (statutory-taste . ,stat)
      (statutory-asserts-rho . ,(chargenvermutung-asserts-rho))
      (at-rho . ,rho) (taste-samples . ,ours)
      (our-sample-asserts-rho . ,(sample->implied-rho n ours))
      (raw-a* . ,(feel-the-food-rate n class lam))
      (a*-saturated? . ,(feel-the-food-saturates? n class lam))
      (other-senses . every-unit))))

;;; ─── the check as a PROCESS : sampling is a yield loss ───────────────────
;;; The sampled units are eaten by the checking, so the process consumes N and
;;; produces N − k of a CERTIFIED good, at the labour of k checks. Nothing else
;;; is needed to make the planner treat inspection as the real cost it is — and
;;; the per-unit cost of certainty falls with batch size all by itself.
(define* (seed-feel-the-food! rs
          #:key (id "recipe-feel-the-food")
                (raw "spec-ftf-uncertified") (raw-name "Ungeprüfte Charge")
                (certified "spec-ftf-certified") (certified-name "Geprüfte Charge")
                (unit "each") (batch 100.0) (class 'medium) (batch-kind 'sealed-lot)
                (work "spec-ftf-pruefer") (work-name "Prüfer:in (Sinnesprüfung)")
                (lam 1.0) (sample #f))
  "Seed the sensory check on a batch: BATCH units in, BATCH − k out, k checks of
   labour, where k is the derived sample (or SAMPLE when a caller pins it — pass
   `(chargenvermutung-sample batch)` to plan under the statutory rule instead)."
  (let* ((n (inexact->exact (round batch)))
         (k (or sample (feel-the-food-sample n class lam batch-kind)))
         (p (feel-the-food-profile class))
         (hours (* k (profile-ell p)))
         (out (- batch k)))
    (for-each (lambda (row)
                (apply (lambda (sid sname sunit cls)
                         ($ rs 'add-resource-spec
                            (make-resource-specification #:id sid #:name sname
                                                         #:resource-classified-as cls
                                                         #:default-unit-of-resource sunit)))
                       row))
              (list (list raw raw-name unit
                          (list "food" (string-append "vf:perishability:"
                                                      (symbol->string class))))
                    (list certified certified-name unit '("food"))
                    (list work work-name "hours" '())))
    ($ rs 'add-recipe-process
       (make-recipe-process #:id id #:name "Sinnesprüfung der Charge"
                            #:has-duration (make-duration hours "hours")))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id (string-append id "-in") #:action 'consume #:resource-conforms-to raw
                         #:resource-quantity (make-measure batch unit) #:recipe-input-of id))
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id (string-append id "-work") #:action 'work #:resource-conforms-to work
                         #:effort-quantity (make-measure hours "hours") #:recipe-input-of id))
    ;; the yield loss IS the sample: k units were eaten to certify the rest
    ($ rs 'add-recipe-flow
       (make-recipe-flow #:id (string-append id "-out") #:action 'produce #:resource-conforms-to certified
                         #:resource-quantity (make-measure out unit) #:recipe-output-of id))
    ($ rs 'add-recipe
       (make-recipe #:id id #:name "Sinnesprüfung der Charge" #:primary-output certified
                    #:recipe-processes (list id)))
    `((sample . ,k) (hours . ,hours) (yield . ,(/ out batch)))))
