;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; knowledge/thermal.scm — a state is a form; holding it is a store recipe that leaks.
;;;
;;; docs/observation/readings-are-counts.md §1.5 facts 2 and 6: an excess of heat
;;; over the surroundings relaxes toward zero at a rate set by the enclosure, and
;;; what the plan pays to hold it is the loss as it happens. In ValueFlows a state
;;; is a form, so a warmed batch is its own spec (`thermal-form`, catalogues/substances.scm)
;;; and relaxing is a change of form: some of the warmed form becomes the base
;;; form and its heat leaves as `ambient-heat`. That is exactly the shape of the
;;; engine's `store-recipe` — hold a good through a period in a keep-in-place
;;; container and lose a fraction of it — with the loss landing in two named
;;; outputs instead of nowhere, so mass, water and heat all balance under element
;;; closure with nothing added to the engine.
;;;
;;;   relaxation-records  the store-shaped recipe as VF records (procs, flows), the
;;;                       fraction per period from τ = m·c/(U·A) (convert.scm) or
;;;                       stated; no conductance ⇒ no records ⇒ nothing relaxes
;;;   thermal-composition the composition rows a solve needs for a warmed form and
;;;                       the heat carriers, in `plan-from-records #:composition` shape

(define-module (localchimera knowledge catalogues thermal)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera vf schemas)
  #:use-module ((localchimera knowledge dsl shorthand) #:select (rp* out* consume* use*))
  #:use-module (goblins)
  #:use-module ((localchimera knowledge catalogues substances) #:select (thermal-form base-at-ambient-row *contains* *heat-carriers* closure-basis closed-composition time-constant carry-fraction))
  #:export (relaxation-records thermal-composition relaxation-fraction declare-thermal-form!))

(define* (relaxation-fraction #:key fraction tau mass specific-heat ua (period-hours 24.0))
  "The share of a held excess that relaxes in one period: FRACTION as stated, else
   1 − e^(−p/τ) with τ from TAU or from MASS, SPECIFIC-HEAT and UA. 0 when nothing
   is stated (an infinite τ)."
  (cond (fraction fraction)
        ((or tau (and mass specific-heat))
         (- 1.0 (carry-fraction (or tau (time-constant mass specific-heat ua)) period-hours)))
        (else 0.0)))

(define* (relaxation-records warmed base delta-heat enclosure
                             #:key fraction tau mass specific-heat ua (period-hours 24.0)
                             (id #f) (unit "kg") (enclosure-hours 0.01))
  "(values procs flows): WARMED held through a period in ENCLOSURE (a keep-in-place
   spec) with FRACTION of each unit relaxing to BASE, its DELTA-HEAT kWh per unit
   leaving as ambient-heat. A relocation runs one unit per run (compile.scm reads
   pickup/dropoff as the arc, whatever their measure), so the loss is stated per
   unit DELIVERED: f/(1 − f) consumed, the same coming out as base and heat. Per
   unit held, (1 − f) arrives and f relaxes, mass, water and heat balance exactly,
   and a chain of k hops keeps (1 − f)^k. The fraction comes from
   `relaxation-fraction`; zero yields no records: nothing relaxes. BASE #f and
   DELTA-HEAT 0 leave those outputs out: the held stock leaks and nothing is
   named for the loss, the shape a body's nutrient reserve takes."
  (let ((f (relaxation-fraction #:fraction fraction #:tau tau #:mass mass
                                #:specific-heat specific-heat #:ua ua #:period-hours period-hours))
        (pid (or id (string-append "relax." warmed))))
    (if (<= f 0.0)
        (values '() '())
        (let ((loss (/ f (- 1.0 f))))                    ; per unit delivered
        (values
         (list (rp* pid (string-append "Hold " warmed " in " enclosure)))
         (append
         (list (make-recipe-flow #:id (string-append pid ".pu") #:action 'pickup 
                                 #:resource-conforms-to warmed
                                 #:resource-quantity (make-measure 1.0 unit) #:recipe-input-of pid)
               (make-recipe-flow #:id (string-append pid ".do") #:action 'dropoff
                                 #:resource-conforms-to warmed
                                 #:resource-quantity (make-measure 1.0 unit) #:recipe-output-of pid)
               (use* (string-append pid ".enc") enclosure pid enclosure-hours)
               (consume* (string-append pid ".loss") warmed loss pid unit))
          (if base (list (out* (string-append pid ".base") base loss pid unit #:primary #f)) '())
          (if (and delta-heat (> delta-heat 0.0))
              (list (out* (string-append pid ".heat") "ambient-heat" (* loss delta-heat) pid "kWh" #:primary #f))
              '())))))))

;; ── the door: a scope declares a warmed or cooled form ─────────────────────
(define* (declare-thermal-form! rs base specific-heat delta-t enclosure
                                #:key fraction tau mass ua (period-hours 24.0) (contains *contains*))
  "On recipe store RS: the warmed form of BASE as a spec of its own, its row STATED
   on the spec (`thermal-row`), the base's row stated as the frame's zero, and the
   relaxation recipe that holds the form in ENCLOSURE and lets it relax
   (`relaxation-records`, fraction from FRACTION, TAU, or MASS with UA). Returns the
   warmed form's id. Everything a solve and a lint read of the form follows from
   these three statements on the store; nothing is remembered elsewhere."
  (let* ((base-spec (or ($ rs 'get-resource-spec base)
                        (error "declare-thermal-form!: the base is no spec of this scope" base)))
         (unit (or (resource-specification-default-unit-of-resource base-spec) "kg")))
    ;; the base's row as this scope states it stands in front of the table, so a base
    ;; whose composition the scope declared (its formation among it) hands it on
    (call-with-values (lambda () (thermal-form base specific-heat delta-t
                                               #:contains (let ((stated (resource-specification-composition base-spec)))
                                                            (if (pair? stated) (cons (cons base stated) contains) contains))))
      (lambda (id row)
        (when (null? (or (resource-specification-composition base-spec) '()))
          ($ rs 'add-resource-spec (resource-specification-with-composition base-spec (base-at-ambient-row base #:contains contains))))
        ($ rs 'add-resource-spec
           (make-resource-specification #:id id #:name (format #f "~a, ~a~a K" (resource-specification-name base-spec)
                                                   (if (negative? delta-t) "" "+") delta-t) #:default-unit-of-resource unit #:composition row))
        (call-with-values
          (lambda () (relaxation-records id base (assoc-ref row "heat") enclosure
                                         #:fraction fraction #:tau tau #:mass mass #:specific-heat specific-heat
                                         #:ua ua #:period-hours period-hours #:unit unit))
          (lambda (procs flows)
            (for-each (lambda (p) ($ rs 'add-recipe-process p)) procs)
            (for-each (lambda (f) ($ rs 'add-recipe-flow f)) flows)
            (when (pair? procs)
              ($ rs 'add-recipe (make-recipe #:id (string-append "relax." id) #:name (string-append "Hold " id) #:primary-output id
                                             #:recipe-processes (map recipe-process-id procs))))))
        id))))

(define* (thermal-composition base specific-heat delta-t #:key (contains *contains*))
  "((spec (leaf . fraction) …) …) for a solve: the warmed form's rows and the heat
   carriers', so element closure bounds a heater by its electricity and lets a heat
   pump run only on the ambient heat it draws. Returns (values warmed-id rows)."
  (call-with-values (lambda () (thermal-form base specific-heat delta-t #:contains contains))
    (lambda (id row)
      ;; the solve closes the elements and ENERGY (≥ 0: loss allowed, creation refused);
      ;; entropy is PRODUCED and is the lint's reading, never a closure row — so the
      ;; rows go through `closed-composition` with that basis, the one place the rule
      ;; the engine's map obeys is stated
      (values id
              (closed-composition (cons* id base *heat-carriers*)
                                  #:contains (cons (cons id row) contains)
                                  #:tracked (closure-basis))))))
