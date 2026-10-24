;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-nac.scm — Member, review-link, spatial pull unit tests
;;;
;;; Source: docs/evr/NAC_sepv2.nlogo (`setup`, `decay-links`, `pull-toward-…`)
;;; Run: guile --no-auto-compile -q -L module -L . \
;;;        -l docs/evr/algorithms/tests/test-nac.scm

(use-modules (localchimera test harness)
             (docs evr algorithms nac))

(define (~= a b) (< (abs (- a b)) 1e-9))

(display "\n── NAC: initial-member ──\n")

;; Deterministic samplers so we can pin every field.
(define m
  (initial-member #:starting-rep-variation 0
                  #:starting-aptitude-variation 30
                  #:starting-disp-variation 30
                  #:bad-actor-rate 0.0
                  #:uniform-real (lambda () 0.5)
                  #:uniform-int  (lambda (n) 0)
                  #:gaussian     (lambda (μ σ) μ)))

(check "initial rep = 50"               (= 50 (member-rep m)))
(check "initial culcus = 50"            (= 50 (member-culcus m)))
(check "initial reviewed-aptitude = 50" (= 50 (member-reviewed-aptitude m)))
(check "initial reviewed-disposition = 50" (= 50 (member-reviewed-disposition m)))
(check "initial true-aptitude at μ=50"     (= 50 (member-true-aptitude m)))
(check "initial true-disposition at μ=50"  (= 50 (member-true-disposition m)))
(check "initial opportunity-count = 0"     (= 0 (member-opportunity-count m)))
(check "bad-actor? false when rate = 0"    (not (member-bad-actor? m)))

(define m-bad
  (initial-member #:bad-actor-rate 1.0
                  #:uniform-real (lambda () 0.5)
                  #:uniform-int  (lambda (n) 0)
                  #:gaussian     (lambda (μ σ) μ)))
(check "bad-actor? true when rate = 1.0" (member-bad-actor? m-bad))

;; rep variation: NetLogo `50 + random N` — uniform-int 0..N-1
(define m-rep
  (initial-member #:starting-rep-variation 100
                  #:uniform-real (lambda () 0.5)
                  #:uniform-int  (lambda (n) (- n 1))
                  #:gaussian     (lambda (μ σ) μ)))
(check "rep = 50 + (N-1) when uniform-int returns N-1"
       (= 149 (member-rep m-rep)))

(display "\n── NAC: opportunity-count increment ──\n")
(check "increment by 1"
       (= 1 (member-opportunity-count (increment-opportunity-count m))))
(check "increments compose"
       (= 3 (member-opportunity-count
             (increment-opportunity-count
              (increment-opportunity-count
               (increment-opportunity-count m))))))
(check "increment is non-mutating"
       (= 0 (member-opportunity-count m))) ; original untouched

(display "\n── NAC: review-link aging ──\n")
(define link0 (make-review-link 'a 'b 75 80 0))
(define link1 (age-link link0))
(check "fresh link survives first age-step"
       (and link1 (review-link? link1)))
(check "aged once: age = 1" (= 1 (review-link-age link1)))
(check "aged twice: dies"   (not (age-link link1)))
(check "aging preserves source/target/scores"
       (and (eq? 'a (review-link-source link1))
            (eq? 'b (review-link-target link1))
            (= 75 (review-link-aptitude-score link1))
            (= 80 (review-link-disposition-score link1))))

(display "\n── NAC: spatial pull ──\n")
;; d = 50 ⇒ pull = 0 ⇒ no movement
(check "neutral disposition ⇒ no movement"
       (equal? '(0 0) (pull-step '(0 0) '(10 10) 50)))
;; d < 50 ⇒ pull < 0 ⇒ no movement (NetLogo only applies positive pulls)
(check "negative disposition ⇒ no movement"
       (equal? '(0 0) (pull-step '(0 0) '(10 10) 20)))
;; d = 100 ⇒ pull = 1.0 ⇒ pos' = pos + (target − pos)·0.03
(check "max positive pull moves 3% toward target"
       (let ((p (pull-step '(0 0) '(100 200) 100)))
         (and (~= 3.0 (car p)) (~= 6.0 (cadr p)))))
;; d = 75 ⇒ pull = 0.5 ⇒ pos' = pos + (target − pos)·0.015
(check "half pull moves 1.5%"
       (let ((p (pull-step '(0 0) '(100 200) 75)))
         (and (~= 1.5 (car p)) (~= 3.0 (cadr p)))))
;; Repeated pulls converge toward target (asymptotic).
(check "iterated pull converges toward target"
       (let loop ((p '(0 0)) (n 500))
         (if (zero? n)
             (and (< (abs (- (car  p) 100)) 0.5)
                  (< (abs (- (cadr p) 200)) 0.5))
             (loop (pull-step p '(100 200) 100) (- n 1)))))

(test-summary!)
