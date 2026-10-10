;;; test-inspection-credential.scm — close the credential loop (Slice 4).
;;;
;;; Slices 1–2 made inspection first-class INSIDE the plan: a labour-priced activity
;;; whose cadence emerges from the plan's own reliance, scheduled to a qualified auditor
;;; through build-located. Slice 4 writes that emergent cadence BACK onto the conformance
;;; credential — so the plan's reliance stamps the `valid-until` that governance's own
;;; `custody-cred-live?` gate then enforces. The loop closes on ONE predicate: the writer
;;; (reliance->valid-until) and the reader (custody-cred-live?) are its two ends.
;;;
;;; a* (social-means §1091) is the per-period inspection INTENSITY; 1/a* is the recert
;;; INTERVAL. Heavily-relied edge ⇒ high a* ⇒ short interval; below the reliance floor
;;; (D ≤ λℓ/κ) a* = 0 and the credential is OPEN — a barely-used claim is never worth
;;; recertifying (the Phase-1 floor, now realised as an expiry policy).
;;; Design: docs/legal/inspection-in-plan.md §"The slices" (4).
;;;
;;; Run:  guile -L module/playnet/planner tests/vf/test-inspection-credential.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet vf formulas cadence) (playnet vf facts validity))

;; INDEPENDENT oracle: argmin over [0,1] of J(a) = ℓa + D·e^{−κa} (convex). Non-circular
;; — the closed form is nowhere plugged into itself.
(define (argmin-J ell kappa D)
  (let loop ((i 0) (best 0.0) (bestv +inf.0))
    (if (> i 100000) best
        (let* ((a (/ i 100000.0)) (v (+ (* ell a) (* D (exp (- (* kappa a)))))))
          (if (< v bestv) (loop (+ i 1) a v) (loop (+ i 1) best bestv))))))
(define (≈ a b tol) (< (abs (- a b)) tol))

(define NOW 1000000) (define DAY 86400.0)   ; one-period span = a day
(define ELL 1.0) (define K 1.0)              ; reliance floor at D = ℓ/κ = 1.0

(format #t "~%── the plan's reliance stamps the recert cadence; custody-cred-live? enforces it ──~%")

;; T1 — inspection-intensity IS the real a* (matches the independent argmin), and clamps.
(define t1
  (every (lambda (c)
           (let* ((k (car c)) (D (cadr c)) (l (caddr c))
                  (emp (argmin-J l k D)) (frm (inspection-intensity D l k)))
             (format #t "  κ=~4,2f D=~5,2f ℓ=~4,2f  →  argmin ~5,3f   a* ~5,3f~%" k D l emp frm)
             (≈ emp frm 2.0e-3)))
         '((1.0 2.5 1.0) (0.5 6.0 1.0) (2.0 3.0 0.5) (1.0 1.0 1.0) (1.0 100.0 1.0)))) ; interior … floor … clamp
(format #t "  [~a] inspection-intensity matches the emergent a* at every point (incl. clamps)~%" (if t1 "✓" "✗"))

;; T2 — heavier reliance ⇒ SOONER expiry (shorter recert interval).
(define vus (map (lambda (D) (reliance->valid-until D ELL K NOW DAY)) '(1.5 2.0 2.5)))
(format #t "~%  reliance D = 1.5 2.0 2.5  →  valid-until = ~a (days out: ~a)~%"
        vus (map (lambda (v) (format #f "~,2f" (/ (- v NOW) DAY))) vus))
(define t2 (and (> (car vus) (cadr vus)) (> (cadr vus) (caddr vus))))
(format #t "  [~a] a heavily-relied edge expires sooner (recert interval falls with reliance)~%" (if t2 "✓" "✗"))

;; T3 — below the reliance floor (D ≤ ℓ/κ), the credential is OPEN (no valid-until).
(define open? (reliance->valid-until 0.8 ELL K NOW DAY))
(define floor? (reliance->valid-until 1.0 ELL K NOW DAY))
(format #t "~%  D = 0.8 (below floor) ⇒ valid-until = ~a ;  D = 1.0 (= floor) ⇒ ~a~%" open? floor?)
(define t3 (and (not open?) (not floor?)))
(format #t "  [~a] a barely-relied conformance is never recertified — the credential stays OPEN~%" (if t3 "✓" "✗"))

;; T4 — the LOOP CLOSES: stamp a credential from reliance, then the SAME predicate gates it.
(define base '((said . "EAbc123") (schema . "conformance") (revoked? . #f)
               (claims . ((skill . "electrician") (holder . "did:key:z6Mk...")))))
(define D-hi 2.5)
(define vu (reliance->valid-until D-hi ELL K NOW DAY))
(define cred (cred-with-valid-until base vu))
(define live-now  (custody-cred-live? cred NOW))
(define dead-after (custody-cred-live? cred (+ vu 1)))
(define kept-claim (equal? (cred-claim-of cred 'skill) "electrician"))    ; other claims survive the stamp
(format #t "~%  stamped high-reliance cred: valid-until = ~a (~,2f days)~%" vu (/ (- vu NOW) DAY))
(format #t "  custody-cred-live? @ now = ~a ;  @ past-expiry = ~a ;  skill claim intact = ~a~%"
        live-now dead-after kept-claim)
(define t4 (and live-now (not dead-after) kept-claim))
(format #t "  [~a] the loop closes: reliance→valid-until, then custody-cred-live? enforces the same expiry~%" (if t4 "✓" "✗"))

;; T5 — an OPEN credential (below floor) is live at ANY future time; a shared inspection
;; budget (λ > 1) lengthens the interval, receding to OPEN at the floor.
(define open-cred (cred-with-valid-until base (reliance->valid-until 0.8 ELL K NOW DAY)))
(define open-live-far (custody-cred-live? open-cred (+ NOW (* 3650 DAY))))   ; 10 years out
(define vu-l1 (reliance->valid-until 2.5 ELL K NOW DAY 1.0))
(define vu-l2 (reliance->valid-until 2.5 ELL K NOW DAY 2.0))
(define vu-l4 (reliance->valid-until 2.5 ELL K NOW DAY 4.0))                 ; λ=4 ⇒ D/λ = 0.625 < 1 ⇒ open
(format #t "~%  open cred live 10y out = ~a ;  λ=1 vu ~a  <  λ=2 vu ~a  <  λ=4 vu ~a~%"
        open-live-far vu-l1 vu-l2 vu-l4)
(define t5 (and open-live-far (< vu-l1 vu-l2) (not vu-l4)))
(format #t "  [~a] open creds never lapse; a tighter inspection budget (λ↑) lengthens recert, to OPEN at the floor~%" (if t5 "✓" "✗"))

(define ok (and t1 t2 t3 t4 t5))
(for-each (lambda (tag k) (format #t "  [~a] ~a~%" (if k "✓" "✗") tag))
          '("T1 the derived intensity is the real a*"
            "T2 heavier reliance ⇒ sooner recert"
            "T3 below the floor ⇒ open credential"
            "T4 the loop closes on custody-cred-live?"
            "T5 open never lapses; budget price lengthens recert")
          (list t1 t2 t3 t4 t5))
(format #t "~%  ~a the credential loop is closed: the plan's reliance sets valid-until, governance's gate enforces it~%~%" (if ok "✓" "✗"))
(exit (if ok 0 1))
