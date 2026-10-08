;;; test-federation-tree.scm — fractal parent-level composition
;;;
;;; `^federation-tree` aggregates over child refs that implement the
;;; same method surface as `^federation-result`. A tree's methods
;;; match a result's methods exactly, so a tree can itself be a
;;; child of another tree — fractal composition.
;;;
;;; This suite verifies:
;;;   1. 2-level tree (parent with leaf children) aggregates correctly
;;;   2. 3-level tree (grandparent with tree children) rolls up
;;;      through every level
;;;   3. fr-* dual-shape accessors work on trees without modification
;;;      (structural typing — tree looks like result)
;;;   4. Deficits are tagged with (child . cid) so attribution survives
;;;      across levels
;;;   5. subresult method returns the right child ref by scope id

(setvbuf (current-output-port) 'line)

(use-modules (playnet test harness)
             (playnet deprecated planner)
             (goblins) (goblins vat))

(define vat (spawn-vat))


(with-vat vat

  (display "\n── 1. Two-level tree: parent aggregates over leaf results ──\n")
  ;; Two leaf results:
  ;;   commune-A: coherence 1, residual 0, no deficits
  ;;   commune-B: coherence 1/2, residual 3, one deficit
  ;; Parent tree: mean coherence 3/4, total residual 3.
  (let* ((a (spawn-federation-result
              #:scope 'commune-A
              #:coherence 1
              #:residual 0
              #:deficits '()
              #:surpluses '()))
         (b (spawn-federation-result
              #:scope 'commune-B
              #:coherence 1/2
              #:residual 3
              #:deficits '(((scope-id . commune-B) (spec-id . "apple") (qty . 3)))
              #:surpluses '()))
         (tree (spawn-federation-tree
                 #:scope 'region-north
                 #:children (list a b))))

    (check "tree scope"
           ($ tree 'scope) 'region-north)
    (check "tree children returns refs"
           (length ($ tree 'children)) 2)
    (check "tree residual is sum of children"
           ($ tree 'residual) 3)
    (check "tree coherence is mean"
           (= 3/4 ($ tree 'coherence)))
    (check "tree surpluses empty"
           ($ tree 'surpluses) '())
    (check "tree deficits count"
           (length ($ tree 'deficits)) 1)
    (check "tree deficit tagged with child"
           (assq-ref (car ($ tree 'deficits)) 'child) 'commune-B)
    (check "subresult finds commune-A"
           (eq? ($ tree 'subresult 'commune-A) a))
    (check "subresult finds commune-B"
           (eq? ($ tree 'subresult 'commune-B) b))
    (check "subresult returns #f for unknown child"
           ($ tree 'subresult 'unknown) #f))


  (display "\n── 2. Three-level tree: fractal recursion rolls up ──\n")
  ;; Grandparent → two trees → each with two leaves.
  ;;
  ;;   region-west:
  ;;     zone-A-1: leaf1 (coh 1, res 0), leaf2 (coh 1/2, res 2)
  ;;     zone-A-2: leaf3 (coh 1, res 0)
  ;;
  ;; At zone-A-1: mean coherence = 3/4, residual = 2.
  ;; At zone-A-2: mean coherence = 1,   residual = 0.
  ;; At region-west: mean coherence = (3/4 + 1)/2 = 7/8, residual = 2.
  (let* ((leaf1 (spawn-federation-result
                  #:scope 'leaf1 #:coherence 1 #:residual 0
                  #:deficits '() #:surpluses '()))
         (leaf2 (spawn-federation-result
                  #:scope 'leaf2 #:coherence 1/2 #:residual 2
                  #:deficits '(((scope-id . leaf2) (spec-id . "bread") (qty . 2)))
                  #:surpluses '()))
         (leaf3 (spawn-federation-result
                  #:scope 'leaf3 #:coherence 1 #:residual 0
                  #:deficits '() #:surpluses '()))
         (zone-A-1 (spawn-federation-tree
                     #:scope 'zone-A-1
                     #:children (list leaf1 leaf2)))
         (zone-A-2 (spawn-federation-tree
                     #:scope 'zone-A-2
                     #:children (list leaf3)))
         (region (spawn-federation-tree
                   #:scope 'region-west
                   #:children (list zone-A-1 zone-A-2))))

    (check "mid-level zone-A-1 coherence"
           (= 3/4 ($ zone-A-1 'coherence)))
    (check "mid-level zone-A-1 residual"
           ($ zone-A-1 'residual) 2)
    (check "mid-level zone-A-2 coherence"
           ($ zone-A-2 'coherence) 1)
    (check "top-level region coherence"
           (= 7/8 ($ region 'coherence)))
    (check "top-level region residual"
           ($ region 'residual) 2)
    ;; Deficit attribution through two levels:
    ;; at region, each deficit from zone-A-1's children gets tagged
    ;; with (child . zone-A-1). Underneath, zone-A-1's deficits had
    ;; already been tagged with (child . leaf2). Fractal.
    (let ((defs ($ region 'deficits)))
      (check "region has one deficit"
             (length defs) 1)
      (check "region deficit outer child is zone-A-1"
             (assq-ref (car defs) 'child) 'zone-A-1))
    ;; subresult navigates one level:
    (check "region subresult returns zone-A-1"
           (eq? ($ region 'subresult 'zone-A-1) zone-A-1))
    ;; Two-step navigation:
    (check "two-step subresult: region → zone → leaf"
           (eq? ($ ($ region 'subresult 'zone-A-1) 'subresult 'leaf1)
                leaf1)))


  (display "\n── 3. fr-* accessors work on trees (structural typing) ──\n")
  (let* ((a (spawn-federation-result #:scope 'A #:coherence 1 #:residual 0))
         (b (spawn-federation-result #:scope 'B #:coherence 0 #:residual 5))
         (tree (spawn-federation-tree
                 #:scope 'parent
                 #:children (list a b))))
    (check "fr-scope on tree"
           (fr-scope tree) 'parent)
    (check "fr-coherence on tree"
           (= 1/2 (fr-coherence tree)))
    (check "fr-residual on tree"
           (fr-residual tree) 5)
    (check "fr-harmony on tree (no child has harmony) returns #f"
           (fr-harmony tree) #f))


  (display "\n── 4. Harmony aggregation across tree ──\n")
  (let* ((a (spawn-federation-result
              #:scope 'A #:coherence 1 #:residual 0
              #:harmony '((total . 10))))
         (b (spawn-federation-result
              #:scope 'B #:coherence 1 #:residual 0
              #:harmony '((total . 25))))
         (tree (spawn-federation-tree
                 #:scope 'harmony-parent
                 #:children (list a b))))
    (let ((h ($ tree 'harmony)))
      (check "tree harmony has total"
             (assq-ref h 'total) 35)
      (check "tree harmony per-child preserves entries"
             (length (assq-ref h 'per-child)) 2)))


  (display "\n── 5. as-alist round-trip on a tree ──\n")
  (let* ((a (spawn-federation-result
              #:scope 'alpha #:coherence 1 #:residual 0
              #:deficits '() #:surpluses '()))
         (b (spawn-federation-result
              #:scope 'beta #:coherence 1/2 #:residual 2
              #:deficits '(((scope-id . beta) (spec-id . "x") (qty . 2)))
              #:surpluses '()))
         (tree (spawn-federation-tree
                 #:scope 'gamma
                 #:children (list a b)))
         (alist ($ tree 'as-alist)))
    (check "as-alist scope"
           (assq-ref alist 'scope) 'gamma)
    (check "as-alist coherence"
           (= 3/4 (assq-ref alist 'coherence)))
    (check "as-alist residual"
           (assq-ref alist 'residual) 2)
    (check "as-alist plan is child map"
           (length (assq-ref alist 'plan)) 2)))


(format #t "~%=== Results: ~a passed, ~a failed ===~%" pass-count fail-count)
(exit (if (zero? fail-count) 0 1))
