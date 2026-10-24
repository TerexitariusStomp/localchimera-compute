;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/test/planner/worked-example.scm — the bread chain, and the fixtures built on it.
;;;
;;; A three-stage chain (grow → mill → bake) with two rival mills: a cassava mill
;;; that makes the matrix rectangular, so recipe CHOICE falls out of one solve,
;;; and a batch mill that only runs in lots of eighty, so the discrete layer has
;;; something to decide. Between them they exercise every shape the engine has.
;;;
;;; This is data ABOUT a plan, not machinery for making one, which is why it
;;; stands in the test harness rather than in the engine. It is not a demo,
;;; though: the benches and tests that build on `*base-templates*` and the
;;; `setup-*` scenarios share this one fixture library, and changing a number
;;; here moves their numbers too. Each setup-* declares its world through
;;; declare-world! and lays its demand, caps and labour onto the world's tables
;;; (solve/world); compile-recipe runs at load. `parity-assert` runs the
;;; scenarios under both backends and refuses a divergence: the seam's contract.

(define-module (localchimera test planner worked-example)
  #:use-module (ice-9 format)
  #:use-module (localchimera solve world)
  #:use-module ((localchimera solve engine) #:select (declare-world! lg solve-located))
  #:use-module ((localchimera solve compile) #:select (compile-recipe rp in out wrk))
  #:use-module ((localchimera solve solver) #:select (mean-fill flatten set-backend! osqp-available?))
  #:export (*procs* *flows* *base-templates* *millc-template* *millb-template*
            setup-space setup-time setup-recipe setup-batch setup-reserve
            mean-fill-located parity-assert))

(define *procs* (list (rp "grow" "Grow") (rp "mill" "Mill") (rp "bake" "Bake")))
(define *flows*
  (list (out "f1" "grain" 1.0 "grow") (in "f2" "soil"  1.0 "grow") (wrk "f3" 0.5 "grow")
        (out "f4" "flour" 1.0 "mill") (in "f5" "grain" 1.2 "mill") (wrk "f6" 0.3 "mill")
        (out "f7" "bread" 1.0 "bake") (in "f8" "flour" 1.0 "bake") (wrk "f9" 0.5 "bake")))
(define *base-templates* (compile-recipe *procs* *flows*))
;; an ALTERNATIVE flour recipe (cassava, dearer labour) ⇒ two columns make flour
;; ⇒ the matrix is rectangular ⇒ recipe choice falls out of the one solve.
(define *millc-template*
  (car (compile-recipe (list (rp "millc" "Mill cassava"))
         (list (out "g1" "flour" 1.0 "millc") (in "g2" "cassava" 1.0 "millc") (wrk "g3" 1.0 "millc")))))
;; a big batch mill (½ labour, but only in batches ≥80 — the discrete layer)
(define *millb-template*
  (car (compile-recipe (list (rp "millb" "Big mill (batch ≥80)"))
         (list (out "h1" "flour" 1.0 "millb") (in "h2" "grain" 1.2 "millb") (wrk "h3" 0.15 "millb")))))

(define (setup-space tau)
  (declare-world! #:places '(("city" 40.0 -74.0) ("country" 41.0 -74.0))
                  #:templates *base-templates*
                  #:movable '("bread" "flour" "grain") #:tau tau)
  (hash-set! *demand* (lg "bread" "city@0") 100.0)
  (hash-set! *cap* (lg "soil" "city@0") 20.0) (hash-set! *cap* (lg "soil" "country@0") 200.0)
  (hash-set! *A* "city@0" 120.0) (hash-set! *A* "country@0" 70.0))
(define (setup-time t1-labour hold storable?)
  (declare-world! #:places '(("town" 40.0 -74.0)) #:periods '(0 1)
                  #:templates *base-templates*
                  #:movable '("bread" "flour" "grain")
                  #:storable (if storable? '("bread" "flour" "grain") '())
                  #:hold hold)
  (hash-set! *demand* (lg "bread" "town@1") 100.0)
  (hash-set! *cap* (lg "soil" "town@0") 400.0) (hash-set! *cap* (lg "soil" "town@1") 400.0)
  (hash-set! *A* "town@0" 250.0) (hash-set! *A* "town@1" t1-labour))
(define (setup-recipe soil-cap)
  (declare-world! #:places '(("town" 40.0 -74.0))
                  #:templates (append *base-templates* (list *millc-template*)))
  (hash-set! *demand* (lg "bread" "town@0") 100.0)
  (hash-set! *cap* (lg "soil" "town@0") soil-cap) (hash-set! *cap* (lg "cassava" "town@0") 80.0)
  (hash-set! *A* "town@0" 300.0))
(define (setup-batch demand)
  (declare-world! #:places '(("town" 40.0 -74.0))
                  #:templates (append *base-templates* (list *millb-template*)))
  (hash-set! *mbq-procs* "millb" 80.0)
  (hash-set! *demand* (lg "bread" "town@0") demand)
  (hash-set! *cap* (lg "soil" "town@0") 400.0) (hash-set! *A* "town@0" 400.0))


(define (setup-reserve labour)
  (declare-world! #:places '(("town" 40.0 -74.0)) #:templates *base-templates*)
  (hash-set! *demand* (lg "bread" "town@0") 100.0)
  (hash-set! *reserve* (lg "bread" "town@0") (cons 40.0 80.0))  ; want +40 buffer, low priority
  (hash-set! *cap* (lg "soil" "town@0") 1e6) (hash-set! *A* "town@0" labour))

(define (mean-fill-located)
  (call-with-values solve-located
    (lambda (x forms labform cols goods raws idx) (mean-fill (flatten forms) x))))
(define (parity-assert tol)
  (format #t "~%==== PARITY LOCK: native vs OSQP agree on delivered (tol ~a) ====~%" tol)
  (if (not (osqp-available?))
      (format #t "   (OSQP unavailable — native-only; parity not checked)~%")
      (for-each (lambda (named)
        ((cdr named))                                         ; run the setup
        (set-backend! 'native) (let ((fn (mean-fill-located)))
          (set-backend! 'osqp) (let ((fo (mean-fill-located)))
            (let ((ok (< (abs (- fn fo)) tol)))
              (format #t "   ~12a native ~,3f  osqp ~,3f  ~a~%" (car named) fn fo (if ok "OK" "DIVERGE"))
              (unless ok (error "parity violation" (car named) fn fo))))))
        (list (cons "space-cheap" (lambda () (setup-space 0.002)))
              (cons "space-dear"  (lambda () (setup-space 0.04)))
              (cons "time-valley" (lambda () (setup-time 40.0 0.01 #t)))
              (cons "recipe-mix"  (lambda () (setup-recipe 60.0)))))))
