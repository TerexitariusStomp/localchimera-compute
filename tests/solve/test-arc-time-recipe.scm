;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-arc-time-recipe.scm — recipe arcs split by physics under the table.
;;;
;;; A ride is a transport RECIPE: pickup/dropoff the mover's good, `use` the
;;; mode's vehicle (per-km Svc), `work` its driver (per-km Lab). With a tabled
;;; network time T for the arc, the trip's flows must divide:
;;;
;;;   TIME-spent  — driver work, vehicle use → effective km = T/pace
;;;                 (a congested road costs MORE driver-hours and van-hours)
;;;   DISTANCE-spent — fuel, loss            → true km, unchanged
;;;
;;; and with no table (or no pace) everything collapses to km: strict parity.
;;; Column inspection only — solver-independent, like containment-test.
;;;
;;; Run:  tools/test/run-suite.sh tests/solve/test-arc-time-recipe.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (localchimera solve engine) (localchimera solve ingest) (localchimera solve world))
(use-modules ((localchimera knowledge recipes transport) #:select (mode-recipe)))

(define VPK 0.01)   ; van-hours per km
(define DPK 0.05)   ; driver-hours per km
(define TPK 0.05)   ; transit-hours per km — the mode's nominal pace

(define (setup!)
  ;; Dana rides to B by a driven van: vehicle Svc + a separate driver's Lab.
  (declare-world! #:places '(("A" 0.0 0.0) ("B" 0.0 0.9))   ; ~100 km
                  #:templates '()
                  #:riders (list (list "Dana" "A" '("doctor" "ride") 40.0))
                  #:mode-recipes (list (mode-recipe "van" #:skill "ride" #:pace TPK #:manner "auto"
                                                    #:uses `(("van" . ,VPK)) #:work (cons "driver" DPK))))
  (hash-set! *cap* (lg "Svc|van" (cell "A" 0)) 10.0)
  (hash-set! *cap* (lab-good "driver" (cell "A" 0)) 10.0)
  (hash-set! *demand* (lg "care" (cell "B" 0)) 1.0))

(define (ride-coeffs)
  "(svc-van . lab-driver) coefficients on the ride column A→B."
  (call-with-values build-located
    (lambda (forms labform ncol cols goods raws idx)
      (let ((col (find (lambda (c) (equal? (col-key c) "p|ride.Dana.van|A@0|B@0")) cols)))
        (and col
             (cons (assoc-ref (col-flows col) (lg "Svc|van" (cell "A" 0)))
                   (assoc-ref (col-flows col) (lab-good "driver" (cell "A" 0)))))))))

(define (~= a b) (and a b (< (abs (- a b)) 1e-9)))

;; ── parity: no table ⇒ per-km × true km ─────────────────────────────────────
(setup!)
(define d-km (km (cell "A" 0) (cell "B" 0)))
(define geo (ride-coeffs))
(define c1 (and geo (~= (car geo) (- (* VPK d-km)))
                    (~= (cdr geo) (- (* DPK d-km)))))

;; ── tabled time T ⇒ time-like flows ride T/pace, at the RIDE's manner ────────
(define T (* 1.5 TPK d-km))                                    ; congested: 1.5× nominal
(setup!)
(ingest-travel-times! (list (cons "A|B|auto" T)))
(define cong (ride-coeffs))
(define eff (/ T TPK))                                          ; effective km = T/pace
(define c2 (and cong (~= (car cong) (- (* VPK eff)))
                     (~= (cdr cong) (- (* DPK eff)))))
(define c3 (and cong (< (car cong) (car geo)) (< (cdr cong) (cdr geo))))  ; congestion costs MORE (more negative)

;; ── manner isolation: a pedestrian entry must not touch the van's arc ───────
(setup!)
(ingest-travel-times! (list (cons "A|B|pedestrian" 99.0)))
(define iso (ride-coeffs))
(define c4 (and iso (~= (car iso) (car geo)) (~= (cdr iso) (cdr geo))))

(for-each (lambda (ok label) (format #t "  [~a] ~a~%" (if ok "✓" "✗") label))
          (list c1 c2 c3 c4)
          (list (format #f "no table: use/work flows = per-km × km (~,3f, ~,3f)" (car geo) (cdr geo))
                (format #f "tabled T: use/work flows = per-km × T/pace (~,3f, ~,3f)" (car cong) (cdr cong))
                "congestion raises driver-hours and vehicle-hours"
                "manners are isolated on recipe arcs too"))
(let ((ok (and c1 c2 c3 c4)))
  (format #t "~%  ~a recipe arcs split by physics: time-spent flows ride network time, distance-spent ride km~%~%" (if ok "✓" "✗"))
  (exit (if ok 0 1)))
