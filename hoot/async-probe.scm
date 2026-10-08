;;; async-probe.scm — the coordinator-free federated solve, run by the browser build.
;;;
;;; federation/async.scm is plain Scheme over a boundary oracle, so a page can be
;;; a peer: it solves its own scope on the reference core, hears its neighbours
;;; along the links, and speaks only when it has moved. This entry runs the test
;;; chain of scopes as four peers on the simulated network (seeded delays, loss,
;;; repeats) through the browser build and logs the fill percentage, the messages
;;; delivered, and the pull on each link. The native build settles the same
;;; chain at 99.92% met in a few hundred messages (tests/planner/test-federation-async.scm).
;;;
;;; Run:  make hoot-probe-async

(use-modules (hoot ffi) (playnet planner solve engine) (playnet planner solve solver)
             (playnet planner federation async))
(include-from-path "playnet/test/planner/federated-fixtures.scm")

(define-foreign %now "performance" "now" -> f64)
(define-foreign %log "console" "log" f64 -> none)

(define (probe S)
  (let* ((t0 (%now))
         (peers (map (lambda (r) (make-peer (make-boundary-oracle r))) (fx-chain S))))
    (call-with-values (lambda () (simulate peers #:seed 3 #:drop 0.1 #:dup 0.1 #:tick 1.0 #:horizon 3000.0))
      (lambda (settled? time stats peers)
        (let ((cert (assemble-attestations (map (lambda (p) (p 'attest)) peers))))
          (%log (exact->inexact S))
          (%log (- (%now) t0))
          (%log (if (and settled? (cdr (assq 'final? cert))) 1.0 0.0))
          (%log (cdr (assq 'met cert)))
          (%log (exact->inexact (cdr (assq 'delivered stats)))))))))

;; a crossing: two granaries supply one good, two bakers draw it — one pull, settled
;; between four peers (the same economy as tests/planner/federation-crossing-fixture.scm)
(define (scope-forms bcol soil A sign)
  (append (map (lambda (i) (mk-bar 0.0 (list (cons i 1.0)))) '(0 1 2))
          (list (mk-bar soil (list (cons 1 -1.0)))
                (mk-bar A (list (cons 1 -0.3) (cons 2 -0.5)))
                (mk-bar 0.0 (list (cons 1 1.0) (cons 2 -1.0) (cons bcol (* sign -1.0))))
                (mk-des (mk-bar 0.0 (list (cons 2 1.0))) 100.0 1000.0))))
(define (scope-record spec)
  (let ((soil (list-ref spec 1)) (A (list-ref spec 2)) (sign (list-ref spec 3)))
    (list (cons 'forms (scope-forms 0 soil A sign))
          (cons 'labform (list (cons 1 0.3) (cons 2 0.5)))
          (cons 'x0 (make-vector 3 0.1))
          (cons 'crossings (list (cons* 0 "G" sign 0))))))

(define (crossing-probe)
  (let* ((t0 (%now))
         (specs '(("granary-1" 216.0 75.0 1) ("granary-2" 216.0 75.0 1)
                  ("baker-1" 50.4 90.0 -1) ("baker-2" 50.4 90.0 -1)))
         (peers (map (lambda (sp)
                       (let ((master? (equal? (car sp) "granary-1")))
                         (make-peer (make-boundary-oracle (scope-record sp)) #:name (car sp)
                                    #:mastering (if master? '("G") '())
                                    #:members (if master?
                                                  (list (cons "G" (list "granary-2" "baker-1" "baker-2")))
                                                  '()))))
                     specs)))
    (call-with-values (lambda () (simulate peers #:seed 3 #:drop 0.1 #:dup 0.1 #:tick 1.0 #:horizon 3000.0))
      (lambda (settled? time stats peers)
        (let ((cert (assemble-attestations (map (lambda (p) (p 'attest)) peers))))
          (%log 99.0)                             ; the crossing's marker
          (%log (- (%now) t0))
          (%log (if (and settled? (cdr (assq 'final? cert))) 1.0 0.0))
          (%log (cdr (assq 'met cert)))
          (%log (exact->inexact (cdr (assq 'delivered stats)))))))))

(probe 2) (probe 4) (crossing-probe)
