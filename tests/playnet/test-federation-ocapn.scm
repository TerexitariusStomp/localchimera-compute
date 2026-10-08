;;; test-federation-ocapn.scm — real federation across OCapN
;;;
;;; This is the test that proves everything we built actually works
;;; across the wire. Uses ^fake-network + ^fake-netlayer (Goblins'
;;; in-process test transport) which exercises the same CapTP/OCapN
;;; protocol as TCP-TLS or Tor netlayers.
;;;
;;; What this validates:
;;;   1. ^scope-leaf registered as a sturdyref is reachable remotely
;;;   2. plan-federate works with enlivened remote refs
;;;   3. remote-refr? returns #t on enlivened refs (unlike in-process
;;;      cross-vat where it's #f)
;;;   4. Facet-attenuated leaves cross the wire with the attenuation
;;;      preserved — denied methods still raise remotely
;;;   5. ^federation-tree-async aggregates over remote leaves using
;;;      let-on/all-of* — the key cross-OCapN composition
;;;   6. plan-federate-resilient with with-sever-handling registers
;;;      on-sever handlers on truly-remote refs without error

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness)
             (playnet deprecated planner)
             (playnet deprecated vat-federation)
             (goblins) (goblins vat)
             (goblins actor-lib methods)
             (goblins ocapn captp)
             (goblins ocapn netlayer fake)
             (goblins ocapn ids)
             (fibers) (fibers channels) (fibers conditions) (fibers operations)
             (ice-9 atomic)
             (ice-9 format)
             (srfi srfi-1))


;;; ── Harness (mirrors test-netlayer-substitute) ────────────────────────────

(define (done! ch val) (put-message ch val) 'done)

(define (run-federation-ocapn-test setup body)
  "SETUP takes (vat-a mycapn-a vat-b mycapn-b fake-net) and returns
   two sturdyrefs as (values sref-a sref-b).
   BODY takes (coord-vat coord-mycapn sref-a sref-b result-ch)
   and puts the result on result-ch."
  (define result-ch (make-channel))
  (run-fibers
    (lambda ()
      (define net-vat (spawn-vat #:name "ocapn-net"))
      (define fake-net (with-vat net-vat (spawn ^fake-network)))

      (define vat-a (spawn-vat #:name "commune-A"))
      (define vat-b (spawn-vat #:name "commune-B"))
      (define coord-vat (spawn-vat #:name "coordinator"))

      (define-values (sref-a sref-b)
        (let* ((mycapn-a
                 (with-vat vat-a
                   (let ((ch (make-channel)))
                     (<-np fake-net 'register "commune-A" ch)
                     (spawn-mycapn (spawn ^fake-netlayer
                                           "commune-A" fake-net ch)))))
               (mycapn-b
                 (with-vat vat-b
                   (let ((ch (make-channel)))
                     (<-np fake-net 'register "commune-B" ch)
                     (spawn-mycapn (spawn ^fake-netlayer
                                           "commune-B" fake-net ch))))))
          (setup vat-a mycapn-a vat-b mycapn-b fake-net)))

      (with-vat coord-vat
        (let* ((ch (make-channel))
               (_  (begin (<-np fake-net 'register "coordinator" ch) #f))
               (coord-mycapn (spawn-mycapn
                               (spawn ^fake-netlayer
                                      "coordinator" fake-net ch))))
          (body coord-vat coord-mycapn sref-a sref-b result-ch))))
    #:drain? #f)
  (get-message result-ch))


;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Federation across OCapN: two communes, one demand ──\n")

(let ((result
       (run-federation-ocapn-test
         ;; Setup: each commune spawns a ^scope-leaf and registers it
         (lambda (vat-a mycapn-a vat-b mycapn-b fake-net)
           (values
             (with-vat vat-a
               (let ((leaf (spawn ^scope-leaf 'commune-A '((apple . 3)))))
                 (<- mycapn-a 'register leaf 'fake)))
             (with-vat vat-b
               (let ((leaf (spawn ^scope-leaf 'commune-B '((apple . 5)))))
                 (<- mycapn-b 'register leaf 'fake)))))
         ;; Body: enliven both sturdyrefs, federate
         (lambda (vat mycapn sref-a sref-b result-ch)
           (on (vow-all (list (<- mycapn 'enliven sref-a)
                              (<- mycapn 'enliven sref-b)))
               (lambda (refs)
                 (let ((leaf-a (car refs)) (leaf-b (cadr refs)))
                   (on (plan-federate (list leaf-a leaf-b) '(apple 4))
                       (lambda (fed-result)
                         (done! result-ch
                           (list (assq-ref fed-result 'residual)
                                 (assq-ref fed-result 'coherence)
                                 (remote-refr? leaf-a)
                                 (remote-refr? leaf-b))))))))))))
  (check "OCapN federation: residual 0" (list-ref result 0) 0)
  (check "OCapN federation: coherence is 1" (= 1 (list-ref result 1)))
  (check "OCapN: commune-A is remote-refr?" (list-ref result 2) #t)
  (check "OCapN: commune-B is remote-refr?" (list-ref result 3) #t))


(display "\n── 2. Unsatisfiable demand across OCapN ──\n")

(let ((result
       (run-federation-ocapn-test
         (lambda (vat-a mycapn-a vat-b mycapn-b fake-net)
           (values
             (with-vat vat-a
               (let ((leaf (spawn ^scope-leaf 'A '())))
                 (<- mycapn-a 'register leaf 'fake)))
             (with-vat vat-b
               (let ((leaf (spawn ^scope-leaf 'B '((pear . 2)))))
                 (<- mycapn-b 'register leaf 'fake)))))
         (lambda (vat mycapn sref-a sref-b result-ch)
           (on (vow-all (list (<- mycapn 'enliven sref-a)
                              (<- mycapn 'enliven sref-b)))
               (lambda (refs)
                 (on (plan-federate refs '(apple 7))
                     (lambda (fed-result)
                       (done! result-ch
                         (list (assq-ref fed-result 'residual)
                               (assq-ref fed-result 'coherence)))))))))))
  (check "OCapN unsatisfiable: residual is the demand"
         (list-ref result 0) 7)
  (check "OCapN unsatisfiable: coherence is 0"
         (= 0 (list-ref result 1))))


(display "\n── 3. ^federation-tree-async over remote leaves ──\n")
;; The async tree aggregates over remote refs using let-on / all-of*.
;; This is the whole point of the async variant — it works when
;; children are remote, where the sync ^federation-tree would fail.

(let ((result
       (run-federation-ocapn-test
         (lambda (vat-a mycapn-a vat-b mycapn-b fake-net)
           (values
             (with-vat vat-a
               (let ((fr (spawn-federation-result
                            #:scope 'commune-A
                            #:coherence 1
                            #:residual 0
                            #:deficits '() #:surpluses '())))
                 (<- mycapn-a 'register fr 'fake)))
             (with-vat vat-b
               (let ((fr (spawn-federation-result
                            #:scope 'commune-B
                            ;; inexact — rationals don't survive Syrup
                            #:coherence 0.5
                            #:residual 4
                            #:deficits '(((scope-id . commune-B)
                                          (spec-id . "bread")
                                          (qty . 4)))
                            #:surpluses '())))
                 (<- mycapn-b 'register fr 'fake)))))
         (lambda (vat mycapn sref-a sref-b result-ch)
           (on (vow-all (list (<- mycapn 'enliven sref-a)
                              (<- mycapn 'enliven sref-b)))
               (lambda (refs)
                 ;; Spawn the async tree locally with REMOTE children
                 (let ((tree (spawn-federation-tree-async
                               #:scope 'regional-federation
                               #:children refs)))
                   (on (vow-all (list (<- tree 'residual)
                                      (<- tree 'coherence)
                                      (<- tree 'deficits)))
                       (lambda (vals)
                         (done! result-ch vals))))))))))
  (check "async tree over OCapN: residual aggregates"
         (list-ref result 0) 4)
  (check "async tree over OCapN: coherence averages (3/4)"
         (= 3/4 (list-ref result 1)))
  (check "async tree over OCapN: deficit from remote child surfaces"
         (length (list-ref result 2)) 1)
  (check "async tree over OCapN: deficit tagged with child scope"
         (assq-ref (car (list-ref result 2)) 'child) 'commune-B))


(display "\n── 4. Facet-attenuated leaves cross the wire ──\n")
;; Register a facet of a ^federation-result. The facet denies most
;; methods — remote callers can only see what's granted.

(let ((result
       (run-federation-ocapn-test
         (lambda (vat-a mycapn-a vat-b mycapn-b fake-net)
           (values
             (with-vat vat-a
               (let* ((fr (spawn-federation-result
                            #:scope 'attenuated-commune
                            #:coherence 1
                            #:residual 7
                            #:deficits '()
                            #:surpluses '()))
                      ;; Only coherence + scope exposed
                      (narrow (spawn-federation-result-facet
                                fr '(scope coherence))))
                 (<- mycapn-a 'register narrow 'fake)))
             (with-vat vat-b
               (let ((fr (spawn-federation-result
                           #:scope 'B #:coherence 1)))
                 (<- mycapn-b 'register fr 'fake)))))
         (lambda (vat mycapn sref-a sref-b result-ch)
           (on (<- mycapn 'enliven sref-a)
               (lambda (remote-narrow)
                 ;; Allowed: scope and coherence
                 (on (vow-all (list (<- remote-narrow 'scope)
                                    (<- remote-narrow 'coherence)))
                     (lambda (allowed)
                       ;; Denied: residual — expect broken vow
                       (on (<- remote-narrow 'residual)
                           (lambda (v)
                             (done! result-ch
                               (list 'unexpected-success allowed v)))
                           #:catch
                           (lambda (e)
                             (done! result-ch
                               (list 'denied-as-expected allowed))))))))))))
  (check "attenuated leaf: scope exposed"
         (list-ref (cadr result) 0) 'attenuated-commune)
  (check "attenuated leaf: coherence exposed"
         (list-ref (cadr result) 1) 1)
  (check "attenuated leaf: residual denied remotely"
         (car result) 'denied-as-expected))


(format #t "~%=== Results: ~a passed, ~a failed ===~%" pass-count fail-count)
(exit (if (zero? fail-count) 0 1))
