;;; bench-decomp.scm — round-count benchmark for the §10 scope-coordination ADMM.
;;;
;;; A chain of S scopes: scope 0 is a soil-rich "granary", downstream scopes are
;;; soil-poor and must IMPORT grain hop-by-hop along the chain to meet local bread
;;; demand. Grain originates at 0 and must reach S−1 through S−1 boundary links —
;;; a genuine propagating coupling, the case that stresses the pull-coordination.
;;;
;;; Each scope's local vars:  0=imp(grain from s−1)  1=exp(grain to s+1)
;;;                           2=g(local grain)        3=b(local bread)
;;;
;;; Run:  guile --no-auto-compile -q -L module module/playnet/planner/bench-decomp.scm

(use-modules (srfi srfi-1) (ice-9 format))
(use-modules (playnet planner solve engine)
             (playnet planner solve solver))
(define (msx t0) (/ (* 1000.0 (- (get-internal-real-time) t0)) internal-time-units-per-second))

;; The economy comes from ONE shared builder (playnet/test/planner/federated-fixtures.scm).
;; It used to be defined here, and the local copy carried a bug worth naming:
;; scope 0 kept an IMPORT column with nothing upstream, and an unlinked import is
;; grain from nowhere. Every number this bench produced was measured against a
;; chain with a free source at its head — which flatters the coupling, since the
;; granary never has to be the only origin. The shared builder gives a scope only
;; the columns it actually has.
(primitive-load (or (find file-exists?
                      (filter-map (lambda (p)
                                    (and (string? p)
                                         (string-append (dirname p) "/../../test/planner/federated-fixtures.scm")))
                                  (cons (current-filename) (command-line))))
                    "module/playnet/test/planner/federated-fixtures.scm"))

(format #t "~%==== §10 scope-coordination ADMM: baseline vs Anderson ====~%")
(format #t "    S      baseline (rounds/met/ms)      Anderson (rounds/met/ms)~%")
(for-each (lambda (S)
  (let ((scopes (fx-chain S)))
    (let* ((t0 (get-internal-real-time))
           (a  (call-with-values (lambda () (solve-decomposed scopes #:accel #f)) list)) (ta (msx t0))
           (t1 (get-internal-real-time))
           (b  (call-with-values (lambda () (solve-decomposed scopes #:accel #t)) list)) (tb (msx t1)))
      (format #t "    ~3@a     ~4@a / ~5,1f / ~6,0f         ~4@a / ~5,1f / ~6,0f~%"
              S (caddr a) (cadr a) ta (caddr b) (cadr b) tb))))
  '(2 4 8 16))
(newline)
