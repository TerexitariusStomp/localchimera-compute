;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-federation-pull.scm — decomposition ACROSS VATS, the faithful dual form.
;;;
;;; Two sovereign communes, each its OWN local LP (built by the real located
;;; stack: ingest-records! → build-located), coordinated ONLY by the boundary
;;; good's PULL via `solve-decomposed` (scaled-dual ADMM). Commune A is
;;; flour-rich and SUPPLIES flour; commune B is flour-poor, DRAWS flour and
;;; bakes bread locally to meet its demand. The ADMM drives what is supplied to
;;; what is drawn and returns the dual λ on the boundary — that λ IS the pull
;;; on flour the two communes settle at: separate solves, one scalar across the
;;; vat, converging to the joint optimum.
;;;
;;; The bridge (records → scope-record) that makes this work, and the traps:
;;;   • boundary columns are FREE source/sink recipes build-located emits
;;;     natively — TAKE = produce-from-nothing (+1 in the good's balance),
;;;     GIVE = consume-to-nothing (−1). No solver change, no form surgery.
;;;   • the INTERMEDIATE (flour) crosses, not the finished good: then what is
;;;     drawn is the commune's ONLY source, so the coupling binds. Drawing the
;;;     finished good is a free source the demand-barrier grabs regardless → the
;;;     dual diverges (the coupling never binds). Match bench-decomp: the input
;;;     crosses.
;;;   • flour is #:never-raw so it is not a free raw — B's only flour is what it draws.
;;;
;;; Run:  guile -L module/playnet/planner tests/solve/test-federation-pull.scm
(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet solve engine) (playnet solve decomposed) (playnet solve records)
             (playnet solve compile)
             (playnet vf schemas)
             (playnet knowledge dsl shorthand))

;; `holding` = the shorthand's er; this suite binds `er` to its give recipe below
(define (res spec loc q) (holding (string-append spec "@" loc) spec #f #:place loc #:qty q #:unit "kg"))
(define (place id lat lon) (place* id #:lat lat #:lon lon))
(define (worker id loc) (person* id #:place loc #:tags '("general")))

;; the boundary columns, as trivial recipes the located build emits natively
(define (take-recipe good) (cons (rp "imp" (string-append "take " good))
  (list (out* "if" good 1.0 "imp" #:primary #f))))
(define (give-recipe good) (cons (rp "exp" (string-append "give " good))
  (list (consume* "ef" good 1.0 "exp"))))

;; THE BRIDGE: records → a solve-decomposed scope-record, reusing ingest-records!
;; (the shared plan-from-records prelude) + build-located. give-col / take-col name
;; the boundary column; the ADMM ties them to the peer's under `link`.
(define* (commune-scope resources agents spatials procs flows
                        #:key (demand '()) (never-raw '()) (give-col #f) (take-col #f) (link #f))
  (ingest-records! resources agents spatials procs flows
    #:demand demand #:never-raw never-raw #:per-agent? #f)
  (call-with-values build-located
    (lambda (forms lf ncol cols goods raws idx)
      (let ((ec (and give-col (hash-ref idx give-col #f)))
            (ic (and take-col (hash-ref idx take-col #f))))
        (list (cons 'forms forms) (cons 'labform lf) (cons 'x0 (located-warm cols ncol idx))
              ;; a column that can only give, then one that can only take
              (cons 'crossings (append (if ec (list (cons* ec link 1 0)) '())
                                       (if ic (list (cons* ic link -1 0)) '()))))))))

(define A (place "a-home" 42.70 23.32))
(define B (place "b-home" 42.75 23.40))
(define bake-p (list (rp "bake" "Bake bread")))
(define bake-f (list (out "o" "bread" 1.0 "bake") (in "i" "flour" 1.0 "bake") (wrk "w" 0.1 "bake")))
(define er (give-recipe "flour"))
(define ir (take-recipe "flour"))

;; A: flour-rich, supplies flour (a tiny local bread demand keeps its LP active).
(define scopeA (commune-scope (list (res "flour" "a-home" 300.0)) (list (worker "wa" "a-home"))
                 (list A) (append bake-p (list (car er))) (append bake-f (cdr er))
                 #:demand (list (cons (lg "bread" (cell "a-home" 0)) 5.0)) #:never-raw '("flour")
                 #:give-col "p|exp|a-home@0" #:link "flour"))
;; B: flour-poor, draws flour and bakes bread locally to meet demand 40.
(define scopeB (commune-scope '() (list (worker "wb" "b-home"))
                 (list B) (append bake-p (list (car ir))) (append bake-f (cdr ir))
                 #:demand (list (cons (lg "bread" (cell "b-home" 0)) 40.0)) #:never-raw '("flour")
                 #:take-col "p|imp|b-home@0" #:link "flour"))

(call-with-values (lambda () (solve-decomposed (list scopeA scopeB) #:accel #t #:rho 4.0))
  (lambda (plans met rounds pulls)
    (define pull (hash-ref pulls "flour" 0.0))
    (format #t "~%── THE FAITHFUL DUAL DECOMPOSITION (bridge → solve-decomposed ADMM) ──~%")
    (format #t "   met = ~,1f%%   rounds = ~a~%" met rounds)
    (format #t "   boundary PULL λ(flour A→B) = ~,4f   ← the dual the communes settle at~%" pull)
    (let ((ok (and (> met 98.0) (> (abs pull) 1e-5) (< (abs pull) 1e3))))
      (format #t "~%   [~a] two sovereign communes settle at one pull: A supplies flour, B bakes, demand met~%~%"
              (if ok "OK" "XX"))
      (exit (if ok 0 1)))))
