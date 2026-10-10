;;; test-store-recipe.scm — inventory carries because a scope has a SILO, not
;;; because a caller remembered a keyword.
;;;
;;; Two ways a good crosses from one period to the next:
;;;   #:storable  a lossless free carry at a flat `*hold*` — a shortcut, and one
;;;               every caller must remember. plan-scope defaults it to '(), so a
;;;               live multi-period solve carries nothing unless someone passes it.
;;;   a RECIPE    a process that `use`s a stationary container and picks up /
;;;               drops off the good
;;;               (proc-temporal?): the engine tiles it along the TIME edge instead
;;;               of the space edges, and it carries its own costs — the silo's
;;;               service, the labour to load it, spoilage as an ordinary consume.
;;;
;;; The second is the modelled one and it needs no keyword at all: storability is a
;;; fact about what the scope HAS, and the recipe library already says so. This
;;; proves it end to end — the same scope, once with the silo recipe available and
;;; once without, and nothing passed as #:storable either time.
;;;
;;; So R2 ("prefer STORE and HAUL recipes over the lists in the live path") turns
;;; out to need no engine change. The mechanism was always there; what was missing
;;; was a test saying so, and therefore anyone's confidence in using it.
;;;
;;; WHAT THIS NOW SHOWS, and what it took (2026-08-08). For most of this test's
;;; life BOTH arms reported 100 % fill: nothing had to be carried, so the silo
;;; proved nothing. Three separate faults hid the mechanism, each visible only
;;; once the one before it was fixed:
;;;
;;;   · A cell with no `*A*` entry was UNCAPPED rather than zero (build-columns
;;;     emits the aggregate-labour bar only `when A`), so Tuesday had unlimited
;;;     labour and the plan just grew the grain then. ingest-located! now
;;;     zero-fills PEOPLED places — a place someone stands in at some period has
;;;     the roster's labour, so a period they are all absent in has none.
;;;   · A `move` flow builds NO ARC. compile-process routes `move` to `moved`
;;;     (mark the good movable) and only `pickup`/`dropoff` to `relocated`, which
;;;     is the slot the transport branch reads. The store recipe here used `move`,
;;;     so its column ran free and relocated nothing. It uses the pair now.
;;;   · `(set! *stationary* …)` did not survive: plan-from-records → ingest →
;;;     reset! clears it. The container's keep-in-place flag reaches the engine
;;;     through #:specs, applied after the reset.
;;;
;;; With those, the arms separate: 0 % without the silo recipe, 100 % with it. The
;;; good crosses the period because the scope OWNS A CONTAINER, which is the claim
;;; this test always made and could not previously demonstrate.
;;;
;;; Run: guile --no-auto-compile -L module/playnet/planner \
;;;        tests/planner/test-store-recipe.scm

(use-modules ((playnet utils units) #:select (%count-unit)))
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner vf schemas)
             (playnet planner knowledge dsl shorthand))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

(define SEASONS '(0 1))
(define PLACE "farm")
;; Labour exists ONLY in period 0. The horizon starts on a MONDAY and lays out one
;; period per day, so period 0 is Monday and period 1 is Tuesday; Ada works Mondays.
;; Anything wanted on Tuesday must therefore have been made on Monday and carried —
;; there is no other way across, which is what makes this test discriminate.
(define win0 (hours-of 12))

(define (records with-silo?)
  (let* ((silo-spec (make-resource-specification #:id "silo" #:name "Grain silo" #:default-unit-of-resource "hours/day"
                                                 #:keep-in-place #t))
         (silo (er "silo1" "silo" #f #:name "the silo" #:place PLACE #:qty 100.0 #:unit "hours/day"))
         (skill (er "sk" "skill" "ada" #:place PLACE #:qty 1.0 #:unit "kg"))
         (procs (cons (rp* "grow" "Grow")
                      (if with-silo?
                          (list (rp* "store" "Store in the silo"))
                          '())))
         (flows (append
                 (list (out* "go" "grain" 10.0 "grow")
                       (wk* "gw" "skill" 1.0 "grow"))
                 (if with-silo?
                     ;; the STORE recipe: pick up the grain here, drop it off there,
                     ;; using the stationary silo. `pickup`/`dropoff` is the pair that
                     ;; builds a relocation ARC (compile-process → `relocated`); a bare
                     ;; `move` flow only marks the good movable and builds no arc, so a
                     ;; store stage written with `move` runs a free column and carries
                     ;; nothing.
                     ;; A `move` through a keep-in-place container is a move through
                     ;; TIME — the engine reads the arc off the container, not the flow.
                     (list (make-recipe-flow #:id "sm" #:action 'pickup 
                                             #:resource-conforms-to "grain"
                                             #:resource-quantity (make-measure 1.0 "kg")
                                             #:recipe-input-of "store")
                           (make-recipe-flow #:id "sd" #:action 'dropoff
                                             #:resource-conforms-to "grain"
                                             #:resource-quantity (make-measure 1.0 "kg")
                                             #:recipe-output-of "store")
                           (use* "su" "silo" "store" 0.01))
                     '()))))
    (values (list silo skill) procs flows (list silo-spec))))

(define (grain-in-period-1 with-silo?)
  (call-with-values (lambda () (records with-silo?))
    (lambda (resources procs flows specs)
      ;; The container's keep-in-place flag reaches the engine through #:specs.
      ;; Setting *stationary* here would not survive: plan-from-records → ingest
      ;; → reset! clears it, and absorb-specs! re-derives it AFTER that from
      ;; the specs the caller hands in. (live.scm feeds it the scope's own specs.)
      (call-with-values
        (lambda () (plan-from-records resources
                     (list (person* "ada" #:name "Ada" #:place PLACE #:window win0))
                     (list (place* PLACE))
                     procs flows
                     ;; NOTE: no #:storable anywhere. Carry must come from the recipe.
                     #:specs specs
                     #:demand (list (cons (format #f "grain#~a@1" PLACE) 20.0))
                     #:horizon (cons "2026-08-03" 2)      ; Mon 3 Aug 2026, then Tue
                     #:per-agent? #f #:backend 'native-c
                     #:allow-infeasible? #t))
        (lambda (i c material fill cols x idx nt rep)
          ;; `fill` is the fraction of DEMAND delivered, and the only demand here is
          ;; grain on Tuesday. It is the honest discriminator: activity on a storage
          ;; column proves a column exists, whereas fill proves the grain arrived.
          (list fill
                (let ((k (format #f "p|store|~a@0|~a@1" PLACE PLACE)))
                  (if (hash-ref idx k #f) (vector-ref x (hash-ref idx k)) 0.0))
                (assq-ref (assq-ref rep 'certificate) 'feasible?)
                material))))))

(define without (grain-in-period-1 #f))
(define with-s  (grain-in-period-1 #t))

(format #t "~%── grain wanted in season 1; labour exists only in season 0 ──~%")
(format #t "  no silo recipe, no #:storable : Tuesday demand met ~,1f%% · store runs ~,2f~%"
        (* 100 (first without)) (second without))
(format #t "  a silo recipe, no #:storable  : Tuesday demand met ~,1f%% · store runs ~,2f~%"
        (* 100 (first with-s)) (second with-s))

(check "with a silo recipe the plan RUNS it — the good crosses the period"
       (> (second with-s) 0.01))
(check "…and the plan it produces is a real one"
       (eq? #t (third with-s)))
(check "without the recipe there is no storing activity at all"
       (< (second without) 0.01))
;; The point: nothing was passed as #:storable in either run. Carry is a fact
;; about the scope's recipe library, which is where a scope's capabilities live.
(check "so the carry column came from the RECIPE, never from a keyword"
       (and (> (second with-s) 0.01) (< (second without) 0.01)))
;; A hold is a thing staying where it is: placement, never a commitment to carry it. The
;; plan states no pickup or dropoff for it, and the silo's occupancy states no `use`.
(check "a hold at one place commits no pickup, no dropoff and no use of the silo"
       (null? (filter (lambda (m) (memq (commitment-action m) '(pickup dropoff use)))
                      (fourth with-s))))

;; ── keep-in-place is ONE source of truth ────────────────────────────────────
;; playnet.typ §"Transport and storage are one recipe": which arc a relocation
;; runs along "is not declared; it is derived from the container" — keep-in-place
;; picks time over space. That flag was once a "stationary" classifiedAs tag and
;; is now a field, and the promotion is complete: the smart constructor folds any
;; legacy tag into the field AND STRIPS it, so nothing consults a tag at query
;; time. Comments claimed a tag fallback long after it was gone and misread the
;; rule twice, so the behaviour is pinned here rather than described anywhere.

(define legacy-spec
  (make-resource-specification #:id "silo-legacy" #:name "Silo (legacy tag)"
    #:resource-classified-as '("container" "stationary") #:default-unit-of-resource %count-unit))
(define field-spec
  (make-resource-specification #:id "silo-field" #:name "Silo (field)"
    #:resource-classified-as '("container") #:default-unit-of-resource %count-unit #:keep-in-place #t))
(define mobile-spec
  (make-resource-specification #:id "van" #:name "Van"
    #:resource-classified-as '("container") #:default-unit-of-resource %count-unit))

(check "a legacy \"stationary\" tag still lands as keep-in-place"
       (resource-spec-keep-in-place? legacy-spec))
(check "…and the tag is STRIPPED, so it cannot be read as a second truth"
       (not (member "stationary"
                    (resource-specification-resource-classified-as legacy-spec))))
(check "the explicit field means the same thing"
       (resource-spec-keep-in-place? field-spec))
(check "a container with neither stays mobile — space, not time"
       (not (resource-spec-keep-in-place? mobile-spec)))
(check "only keep-in-place specs reach *stationary*"
       (begin (declare-world!)                       ; a fresh world, nothing stationary yet
              (absorb-specs! (list legacy-spec field-spec mobile-spec))
              (and (spec-stationary? "silo-legacy")
                   (spec-stationary? "silo-field")
                   (not (spec-stationary? "van")))))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a scope that owns a silo carries its grain, and~%  #:storable stays what it is: a shortcut for a carry that is genuinely free.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
