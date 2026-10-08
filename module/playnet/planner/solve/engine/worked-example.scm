;;; engine/worked-example.scm — the bread chain, and the fixtures built on it.
;;;
;;; A three-stage chain (grow → mill → bake) with two rival mills: a cassava mill
;;; that makes the matrix rectangular, so recipe CHOICE falls out of one solve,
;;; and a batch mill that only runs in lots of eighty, so the discrete layer has
;;; something to decide. Between them they exercise every shape the engine has.
;;;
;;; This is data ABOUT a plan, not machinery for making one — which is why it
;;; lives beside planner.scm rather than inside it. It is not a demo, though:
;;; eleven bench and test files build on `*base-templates*` and the `setup-*`
;;; scenarios, so this is a shared fixture library and changing a number here
;;; moves their numbers too.
;;;
;;; Loaded into the engine module, which it needs — compile-recipe runs at load,
;;; and each setup-* declares its world through declare-world! when invoked.

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
