;;; test-berlin-live-scope.scm — the LIVE Berlin commune, end to end.
;;;
;;; The gateway's exact path (server/gateway.scm seed block): spawn-scope-root →
;;; seed-berlin-commune! → ($ planner-service 'add-scope! …) → plan-scope. This proves
;;; the running gateway can plan a REAL Berlin/Brandenburg commune under the Universal
;;; Commune, and — the whole point — that it inherits the Berlin shed's real drought
;;; futures + water limit purely by placing its farm `contained-in "berlin"`, with NO
;;; per-commune wiring. The bioregion is registered live (live.scm boot-loads berlin.scm).
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-berlin-live-scope.scm

(use-modules (playnet knowledge recipes berlin-commune-seed) (playnet scope root) (playnet vf schemas) (playnet vf beyond scenario) (srfi srfi-1)
             (playnet scope live)
             (playnet doors service)
             (goblins)
             (goblins vat)
             (goblins utils hashmap)
             (srfi srfi-1)
             (ice-9 format))

(define *pass* 0) (define *fail* 0)
(define (check name ok)
  (if ok (begin (set! *pass* (+ *pass* 1)) (format #t "  ✓ ~a~%" name))
      (begin (set! *fail* (+ *fail* 1)) (format #t "  ✗ ~a~%" name))))

;; live-module internals (the bioregion registry berlin.scm registered into):
(define live-yields   (@@ (playnet knowledge worlds berlin) *berlin-crop-yields*))
(define live-scen-of  (@@ (playnet scope live) scope-bioregion-scenarios))
(define live-frag-of  (@@ (playnet scope live) scope-bioregion-fragilities))
;; a shed's limits are <fragility> RECORDS now, and may still be (spec . profile)
;; pairs — fragility-specs-of reads either, which is what these assertions want.
(define frag-specs-of (@@ (playnet scope live) fragility-specs-of))

(define vat (spawn-vat #:name "berlin-live"))
(define svc (with-vat vat (spawn ^planner-service (hashmap))))

;; ── the gateway's exact seed → register path ──
(define broot (with-vat vat (spawn-scope-root "Berlin")))
(define place
  (with-vat vat
    (let ((p (seed-berlin-commune! broot)))
      ($ svc 'add-scope! "E_commune_Berlin" broot)
      p)))

;; the farm's real containment tree, straight from the seeded store:
(define spatials (with-vat vat ($ ($ broot 'spatial-thing-store) 'all-locations)))
(define scen (live-scen-of spatials))
(define frag (live-frag-of spatials))

;; ── plan the live scope (robust over the inherited Berlin futures) ──
(define floor-kg 9450.0)     ; ~105 people × 90 kg/season — the subsistence floor
(define result
  (with-vat vat
    (plan-scope->alist broot
      #:demand (list (cons "food#berlin-commune-farm@0" (* 3.0 floor-kg)))   ; ask past the floor
      #:repro-floors (list (cons "food#berlin-commune-farm@0" floor-kg))
      #:backend 'native-c)))
(define met (or (assq-ref result 'met) 0))

(format #t "~%── the LIVE Berlin commune, seeded + planned under the UC ──~%")
(format #t "  farm place: ~s   containment depth: ~a locations~%" place (length spatials))
(format #t "  futures inherited by containment: ~a~%" (map planning-scenario-id scen))
(format #t "  limits inherited: ~a~%" (frag-specs-of frag))
(format #t "  plan-scope->alist 'met = ~,3f (demand vs the water/land-bounded harvest)~%" met)

(format #t "~%── assertions ──~%")
(check "the alist carries the demand rows the solve ran on (the plan face's independent-demand flank reads them)"
       (equal? (assq-ref result 'demand)
               (list (cons "food#berlin-commune-farm@0" (* 3.0 floor-kg)))))
(check "seed-berlin-commune! placed the farm and its containment tree"
       (and (equal? place "berlin-commune-farm") (>= (length spatials) 3)))
(check "the seeded grow-recipe yields match the vendored *berlin-crop-yields* (no drift)"
       (every (lambda (cw) (= (cddr cw) (assoc-ref live-yields (car cw))))
              (@@ (playnet knowledge recipes berlin-commune-seed) *berlin-commune-crops*)))
(check "the LIVE scope inherits the Berlin shed's 4 real futures by containment (incl. drought)"
       (and (= (length scen) 4)
            (find (lambda (s) (equal? (planning-scenario-id s) "berlin-drought")) scen)))
(check "…and inherits the shed's water/soil limits — futures + limits from placement alone"
       (equal? (sort (frag-specs-of frag) string<?) '("groundwater" "topsoil")))
(check "plan-scope solved the live scope and produced food toward the demand"
       (> met 0.0))
(check "the harvest is BOUNDED (water + land bind) — not the full ask"
       (< met 0.999))

(format #t "~%════════════════════════════════════════════~%")
(if (= *fail* 0)
    (format #t "  All ~a checks passed — a REAL Berlin/Brandenburg commune, seeded into a live~%  scope-root under the Universal Commune, planned robustly over its own inherited~%  drought futures within its water budget. The gateway's exact seed→register→plan path.~%" *pass*)
    (begin (format #t "  ~a of ~a checks FAILED.~%" *fail* (+ *pass* *fail*)) (exit 1)))
(format #t "════════════════════════════════════════════~%")
