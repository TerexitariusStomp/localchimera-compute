;;; test-household-recipe.scm — the housework recipes: shape, and the claim that
;;; cleaning moves matter without making any.
;;;
;;; Run from repo root:
;;;   guile --no-auto-compile -q -L module \
;;;     tests/scope/test-household-recipe.scm

(use-modules (playnet solve federation-solve))
(use-modules ((playnet utils units) #:select (%effort-unit)))
(use-modules (playnet test harness))
(use-modules (playnet knowledge recipes household) (playnet scope root) (playnet vf schemas) (srfi srfi-1))
(use-modules (playnet knowledge catalogues substances))
(use-modules (goblins) (goblins persistence-store memory)
             (srfi srfi-1))

(display "\n── Setup: household ──\n")

(define vat (spawn-vat #:name "household"))
(define scope (with-vat vat (spawn-scope-root "Household Test")))
(define rs (with-vat vat ($ scope 'recipe-store)))
(with-vat vat (seed-household-recipes rs))
(with-vat vat (seed-household-waste-recipes rs))

;;; ── shape ────────────────────────────────────────────────────────────────────
(define (chain id) (with-vat vat ($ rs 'get-process-chain id)))
(define (flows pid)
  (let ((io (with-vat vat ($ rs 'flows-for-process pid))))
    (append (car io) (cdr io))))
(define (flow-of pid id) (find (lambda (f) (equal? id (recipe-flow-id f))) (flows pid)))
(define (qty f) (and f (recipe-flow-resource-quantity f)
                     (measure-has-numerical-value (recipe-flow-resource-quantity f))))
(define (effort f) (and f (recipe-flow-effort-quantity f)
                        (measure-has-numerical-value (recipe-flow-effort-quantity f))))

(define %recipes
  (append
   '("recipe-hh-living" "recipe-hh-vacuum" "recipe-hh-dust" "recipe-hh-mop"
     "recipe-hh-bathroom" "recipe-hh-dishes-hand" "recipe-hh-dishes-machine"
     "recipe-hh-laundry" "recipe-hh-dry" "recipe-hh-iron" "recipe-hh-tidy"
     "recipe-hh-bedlinen" "recipe-hh-windows" "recipe-hh-plants"
     "recipe-hh-sort" "recipe-hh-pfand")
   (map (lambda (r) (string-append "recipe-hh-bin-" (car r))) *household-bin-runs*)))

(display "\n── every recipe is seeded, each a single step ──\n")
(for-each
 (lambda (id)
   (check-pred (string-append id " seeded as a one-step recipe")
               (= 1 (length (chain id)))))
 %recipes)

(check-pred "vacuuming delivers cleaned floor as its primary output"
            (string=? "spec-hh-floor-cleaned"
                      (recipe-primary-output
                       (with-vat vat ($ rs 'get-recipe "recipe-hh-vacuum")))))

;;; ── two recipes, one deliverable: the choice the plan gets to make ───────────
(display "\n── dishes by hand and by machine make the SAME deliverable ──\n")
(check-pred "both dish recipes name spec-hh-dishes-washed"
            (every (lambda (r)
                     (string=? "spec-hh-dishes-washed"
                               (recipe-primary-output (with-vat vat ($ rs 'get-recipe r)))))
                   '("recipe-hh-dishes-hand" "recipe-hh-dishes-machine")))
(check-pred "the machine trades a person's half hour for 0.15 h of loading"
            (and (= 0.5 (effort (flow-of "rp-hh-dishes-hand" "rf-hh-dh-work")))
                 (= 0.15 (effort (flow-of "rp-hh-dishes-machine" "rf-hh-dm-work")))))
(check-pred "…and buys it with 1 kWh the hand wash does not spend"
            (and (= 1.0 (qty (flow-of "rp-hh-dishes-machine" "rf-hh-dm-power")))
                 (not (flow-of "rp-hh-dishes-hand" "rf-hh-dh-power"))))

;;; ── a `use` states BOTH quantities ───────────────────────────────────────────
;; One dishwasher, engaged two hours — the count without the duration is how two
;; machines once washed 1.33 loads (recipes skill, `use` row).
(display "\n── every `use` states a count AND a duration ──\n")
(define use-flows
  (filter (lambda (f) (eq? 'use (recipe-flow-action f)))
          (append-map flows (map recipe-process-id (append-map chain %recipes)))))
(check-pred "there are `use` flows to check" (>= (length use-flows) 8))
(check-pred "each names how many means are engaged and for how long"
            (every (lambda (f) (and (qty f) (effort f))) use-flows))
(check-pred "the dishwasher is engaged for the whole 2 h cycle"
            (and (= 1 (qty (flow-of "rp-hh-dishes-machine" "rf-hh-dm-machine")))
                 (= 2 (effort (flow-of "rp-hh-dishes-machine" "rf-hh-dm-machine")))))
(check-pred "the drying rack is occupied 12 h while nobody is"
            (and (= 12 (effort (flow-of "rp-hh-dry" "rf-hh-ld-rack")))
                 (= 0.15 (effort (flow-of "rp-hh-dry" "rf-hh-ld-work")))))

;;; ── every process states its hours, except the one that means not to ─────────
(display "\n── durations are claimed, and the one silence is deliberate ──\n")
(define all-procs (append-map chain %recipes))
(check-pred "every operation but `living` states a duration in hours"
            (every (lambda (rp)
                     (let ((d (recipe-process-has-duration rp)))
                       (if (string=? "rp-hh-living" (recipe-process-id rp))
                           (not d)
                           (and d (string=? %effort-unit (duration-has-unit d))
                                (> (duration-has-numerical-value d) 0)))))
                   all-procs))

;;; ── the material claim: housework moves matter, it does not make it ──────────
;; Water leaves as greywater, soap as spent surfactant, soil as waste — mass for
;; mass, and (`check-conservation`) element for element. `living` is the boundary
;; where dirt enters the ledger, and is exempt for exactly that reason.
(display "\n── conservation across every internal housework process ──\n")
(define (substance-flows pid) (balance-flows (flows pid) #:basis? #f))

(define offenders
  (filter-map
   (lambda (rp)
     (let* ((pid (recipe-process-id rp))
            (fs (substance-flows pid))
            (res (and (pair? fs) (not (boundary-process? fs))
                      (check-conservation fs))))
       (and res (pair? res) (cons pid res))))
   all-procs))
(for-each (lambda (o) (format #t "  UNBALANCED ~a: ~s\n" (car o) (cdr o))) offenders)
(check-pred "no housework process conjures or destroys a tracked element"
            (null? offenders))

(check-pred "`living` IS the boundary: it produces dirt and consumes nothing"
            (boundary-process? (substance-flows "rp-hh-living")))

;; `elemental` returns an alist whose order follows the descent, so compare the
;; four tracked fractions rather than the list.
(define (tracked spec)
  (map (lambda (e) (or (assoc-ref (elemental spec) e) 0)) '("C" "N" "P" "K")))

(display "\n── the soil comes off the plate and leaves by the drain or the bin ──\n")
(check-pred "the hand wash lifts 0.25 kg of soil and sends 0.25 kg down the drain"
            (and (= 0.25 (qty (flow-of "rp-hh-dishes-hand" "rf-hh-dh-soil")))
                 (= 0.25 (qty (flow-of "rp-hh-dishes-hand" "rf-hh-dh-waste")))
                 (string=? "spec-hh-drain-solids"
                           (recipe-flow-resource-conforms-to
                            (flow-of "rp-hh-dishes-hand" "rf-hh-dh-waste")))))
(check-pred "…while the vacuum's dust goes in the bin, identically composed"
            (and (string=? "spec-hh-waste"
                           (recipe-flow-resource-conforms-to
                            (flow-of "rp-hh-vacuum" "rf-hh-vac-waste")))
                 (equal? (tracked "spec-hh-waste") (tracked "spec-hh-drain-solids"))))
(check-pred "the 25 L it draws leaves as 25 L of greywater"
            (and (= 25 (qty (flow-of "rp-hh-dishes-hand" "rf-hh-dh-water")))
                 (= 25 (qty (flow-of "rp-hh-dishes-hand" "rf-hh-dh-grey")))))
(check-pred "household waste carries the carbon of the soil it holds"
            (> (or (assoc-ref (elemental "spec-hh-waste") "C") 0) 0))
(check-pred "greywater carries none of it: it is the water, its hydrogen and oxygen and no carbon"
            (let ((row (elemental "spec-hh-greywater")))
              (and (not (assoc-ref row "C")) (assoc-ref row "H") (assoc-ref row "O") #t)))

;;; ── the waste arm ────────────────────────────────────────────────────────────
(display "\n── sorting splits the discards without losing a gram ──\n")
(define sort-out
  (map (lambda (row)
         (cons (car row) (qty (flow-of "rp-hh-sort" (string-append "rf-hh-so-" (car row))))))
       *household-waste-streams*))
(check-pred "the five streams together weigh the discards plus the cleaning waste"
            (< (abs (- (fold + 0 (map cdr sort-out)) (+ 8.0 0.2))) 1e-9))
(check-pred "each stream takes its declared share of the discards"
            (every (lambda (row)
                     (let ((share (cadr row))
                           (got (assoc-ref sort-out (car row))))
                       (< (abs (- got (+ (* share 8.0)
                                         (if (string=? "residual" (car row)) 0.2 0))))
                          1e-9)))
                   *household-waste-streams*))
;; `elemental` returns an alist whose order follows the descent, so compare the
;; four tracked fractions rather than the list.
(define (tracked spec)
  (map (lambda (e) (or (assoc-ref (elemental spec) e) 0)) (quote ("C" "N" "P" "K"))))
(check-pred "the binned cleaning waste goes out as residual, composed identically"
            (equal? (tracked "spec-hh-waste") (tracked "spec-hh-residual")))

(display "\n── a bin run relocates and transforms nothing ──\n")
(check-pred "every run puts out exactly what it took, stream by stream"
            (every (lambda (row)
                     (let* ((s (car row)) (pid (string-append "rp-hh-bin-" s)))
                       (= (qty (flow-of pid (string-append "rf-hh-bin-" s "-in")))
                          (qty (flow-of pid (string-append "rf-hh-bin-" s "-out"))))))
                   *household-bin-runs*))
(check-pred "…and the collected stream is composed exactly as the stream was"
            (every (lambda (row)
                     (let ((s (car row)))
                       (equal? (tracked (string-append "spec-hh-" s))
                               (tracked (string-append "spec-hh-" s "-collected")))))
                   *household-bin-runs*))
(check-pred "glass is the long trip, and carries none of the tracked elements"
            (and (= 0.3 (effort (flow-of "rp-hh-bin-glass" "rf-hh-bin-glass-work")))
                 (every zero? (tracked "spec-hh-glass"))))
(check-pred "paper carries carbon, packaging carries the carbon of its plastics"
            (and (> (or (assoc-ref (elemental "spec-hh-paper") "C") 0) 0)
                 (> (or (assoc-ref (elemental "spec-hh-packaging") "C") 0) 0)))

(display "\n── the deposit return is the one household task that pays ──\n")
(check-pred "20 containers at 25 cents comes back as €5"
            (= 5.0 (qty (flow-of "rp-hh-pfand" "rf-hh-pf-out"))))
(check-pred "…for 0.4 h of somebody's afternoon"
            (= 0.4 (effort (flow-of "rp-hh-pfand" "rf-hh-pf-work"))))
;; Counted, not weighed — a mass fraction against a count is meaningless — so the
;; containers carry no tracked element in either direction and mislead nothing.
(check-pred "the deposit containers stay out of the matter ledger, by unit"
            (every zero? (tracked "spec-hh-deposit-bottles")))

(display "\n── living generates the week's waste, and consumes nothing ──\n")
(check-pred "a household-week discards 24 kg and 12 deposit containers"
            (and (= 24 (qty (flow-of "rp-hh-living" "rf-hh-liv-discards")))
                 (= 12 (qty (flow-of "rp-hh-living" "rf-hh-liv-pfand")))))

(display "\n── the linen cycle closes: made bed → dirty laundry → washed → ironed ──\n")
(check-pred "changing a bed returns 2 kg to the dirty-laundry stream"
            (= 2 (qty (flow-of "rp-hh-bedlinen" "rf-hh-bl-dirty"))))
(check-pred "…which is what the wash consumes"
            (= 5 (qty (flow-of "rp-hh-laundry" "rf-hh-lw-in"))))

(test-summary!)
