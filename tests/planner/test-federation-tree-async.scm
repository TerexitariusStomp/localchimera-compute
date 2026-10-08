;;; test-federation-tree-async.scm — async fractal tree
;;;
;;; Validates ^federation-tree-async: methods return vows; uses
;;; all-of*/let-on for concurrent fanout; works uniformly whether
;;; children are near or far.
;;;
;;; Single-vat tests (all children near): async tree should still
;;; work correctly; its methods just return vows that resolve in
;;; the same turn. Cross-vat tests verify the "near OR far" claim.
;;; Cross-OCapN tests live in test-federation-ocapn.scm.

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness)
             (playnet deprecated planner)
             (goblins) (goblins vat)
             (fibers) (fibers conditions)
             (ice-9 atomic)
             (ice-9 format))


(define (await-vow vat vow-thunk)
  "Drive a vow to completion from outside a vat."
  (let ((box (make-atomic-box #f))
        (err (make-atomic-box #f))
        (done (make-condition)))
    (with-vat vat
      (on (vow-thunk)
          (lambda (v)
            (atomic-box-set! box v)
            (signal-condition! done))
          #:catch
          (lambda (e)
            (atomic-box-set! err e)
            (signal-condition! done))))
    (wait done)
    (or (atomic-box-ref err)
        (atomic-box-ref box))))


;;; ════════════════════════════════════════════════════════════════════════════

(run-fibers
 (lambda ()

   ;;; ── 1. Single-vat: async tree over two near leaves ──────────────────
   (display "\n── 1. Async tree, near children ──\n")

   (let* ((vat (spawn-vat #:name "async1"))
          (tree (with-vat vat
                  (let ((a (spawn-federation-result
                             #:scope 'commune-A
                             #:coherence 1 #:residual 0
                             #:deficits '() #:surpluses '()))
                        (b (spawn-federation-result
                             #:scope 'commune-B
                             #:coherence 1/2 #:residual 3
                             #:deficits '(((scope-id . commune-B)
                                           (spec-id . "apple")
                                           (qty . 3)))
                             #:surpluses '())))
                    (spawn-federation-tree-async
                      #:scope 'region
                      #:children (list a b))))))
     (check "async: residual aggregates (3)"
            (await-vow vat (lambda () (<- tree 'residual))) 3)
     (check "async: coherence aggregates (3/4)"
            (= 3/4 (await-vow vat (lambda () (<- tree 'coherence)))))
     (check "async: deficits count 1"
            (length (await-vow vat (lambda () (<- tree 'deficits)))) 1)
     (check "async: deficit tagged with child"
            (assq-ref (car (await-vow vat (lambda () (<- tree 'deficits))))
                      'child)
            'commune-B)
     (check "async: scope is sync (not a vow)"
            (await-vow vat (lambda () (<- tree 'scope)))
            'region))


   ;;; ── 2. Cross-vat: async tree holds children in different vats ──────
   (display "\n── 2. Async tree, children in different vats ──\n")
   ;; This is the actual novelty — the tree can aggregate over children
   ;; in distinct vats using <- uniformly. Sync ^federation-tree would
   ;; fail here (its $ calls would error on the far refs).

   (let* ((vat-A   (spawn-vat #:name "async-commune-A"))
          (vat-B   (spawn-vat #:name "async-commune-B"))
          (vat-fed (spawn-vat #:name "async-fed"))
          (a (with-vat vat-A
               (spawn-federation-result
                 #:scope 'commune-A #:coherence 1 #:residual 0
                 #:deficits '() #:surpluses '())))
          (b (with-vat vat-B
               (spawn-federation-result
                 #:scope 'commune-B #:coherence 0 #:residual 5
                 #:deficits '(((scope-id . commune-B)
                               (spec-id . "bread")
                               (qty . 5)))
                 #:surpluses '())))
          (tree (with-vat vat-fed
                  (spawn-federation-tree-async
                    #:scope 'region-cross
                    #:children (list a b)))))
     (check "cross-vat: residual sums"
            (await-vow vat-fed (lambda () (<- tree 'residual))) 5)
     (check "cross-vat: coherence averages"
            (= 1/2 (await-vow vat-fed (lambda () (<- tree 'coherence)))))
     (check "cross-vat: deficit from commune-B surfaces"
            (assq-ref (car (await-vow vat-fed
                                       (lambda () (<- tree 'deficits))))
                      'child)
            'commune-B)
     (check "cross-vat: subresult finds commune-A"
            (eq? (await-vow vat-fed
                            (lambda () (<- tree 'subresult 'commune-A)))
                 a))
     (check "cross-vat: subresult returns #f for unknown"
            (await-vow vat-fed
                       (lambda () (<- tree 'subresult 'unknown)))
            #f))


   ;;; ── 3. as-alist works over cross-vat children ──────────────────────
   (display "\n── 3. as-alist aggregates everything concurrently ──\n")

   (let* ((vat-A   (spawn-vat #:name "al-A"))
          (vat-B   (spawn-vat #:name "al-B"))
          (vat-fed (spawn-vat #:name "al-fed"))
          (a (with-vat vat-A
               (spawn-federation-result
                 #:scope 'alpha #:coherence 1 #:residual 0
                 #:deficits '() #:surpluses '())))
          (b (with-vat vat-B
               (spawn-federation-result
                 #:scope 'beta #:coherence 1/2 #:residual 2
                 #:deficits '(((scope-id . beta) (spec-id . "x") (qty . 2)))
                 #:surpluses '())))
          (tree (with-vat vat-fed
                  (spawn-federation-tree-async
                    #:scope 'gamma
                    #:children (list a b))))
          (alist (await-vow vat-fed (lambda () (<- tree 'as-alist)))))
     (check "as-alist scope"     (assq-ref alist 'scope) 'gamma)
     (check "as-alist residual"  (assq-ref alist 'residual) 2)
     (check "as-alist coherence" (= 3/4 (assq-ref alist 'coherence)))
     (check "as-alist plan has 2 entries"
            (length (assq-ref alist 'plan)) 2))


   ;;; ── 4. Fractal: async tree of async trees ───────────────────────────
   (display "\n── 4. Fractal async: tree of trees across vats ──\n")

   (let* ((vat-1 (spawn-vat #:name "frac-leaf-1"))
          (vat-2 (spawn-vat #:name "frac-leaf-2"))
          (vat-3 (spawn-vat #:name "frac-leaf-3"))
          (vat-mid (spawn-vat #:name "frac-mid"))
          (vat-top (spawn-vat #:name "frac-top"))
          (leaf1 (with-vat vat-1
                   (spawn-federation-result #:scope 'L1 #:coherence 1 #:residual 0)))
          (leaf2 (with-vat vat-2
                   (spawn-federation-result #:scope 'L2 #:coherence 1/2 #:residual 2)))
          (leaf3 (with-vat vat-3
                   (spawn-federation-result #:scope 'L3 #:coherence 1 #:residual 0)))
          (sub (with-vat vat-mid
                 (spawn-federation-tree-async
                   #:scope 'SUB
                   #:children (list leaf1 leaf2))))
          (top (with-vat vat-top
                 (spawn-federation-tree-async
                   #:scope 'TOP
                   #:children (list sub leaf3)))))
     ;; Mean coherence: SUB = (1 + 1/2)/2 = 3/4; TOP = (3/4 + 1)/2 = 7/8
     (check "fractal async: top coherence"
            (= 7/8 (await-vow vat-top (lambda () (<- top 'coherence)))))
     (check "fractal async: top residual"
            (await-vow vat-top (lambda () (<- top 'residual))) 2))


   (format #t "~%=== Results: ~a passed, ~a failed ===~%" pass-count fail-count)
   (primitive-exit (if (zero? fail-count) 0 1))))
