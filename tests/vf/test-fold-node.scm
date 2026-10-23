;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-fold-node.scm — one aggregator for the whole federation fold.
;;;
;;; The property push has to survive is REFEDERATION, and the reason the old
;;; skeleton could not is that it merged each child's value into one sum on
;;; arrival: a departing subtree's contribution was no longer findable. Keeping
;;; children KEYED makes retraction a deletion, so a commune changing federation
;;; costs two exact messages.
;;;
;;; And because the push and the pull are the same monoid folded in a different
;;; order, a node's standing total and the walk over the live tree are the same
;;; value — which is why a rebuild can never disagree with the increments.

(use-modules (playnet test harness)
             (playnet vf aggregation fold-node)
             (playnet vf aggregation scope-tree)
             (playnet utils hashmap)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1))

(define vat (spawn-vat #:name "fold-node"))

(define (^mock bcom table)
  (lambda (msg . args) (let ((p (assq msg table))) (if p (apply (cdr p) args) (error "mock: no method" msg)))))

(define (node id . own)
  (spawn ^fold-node keyed-sum-monoid id (if (pair? own) (car own) '()) (hashmap) '()))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. The monoid: the keyed sum every federation aggregate turns out to be
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. sum-by-key — one combine for demand, capacity, everything ──\n")

(check "the same cell sums" (equal? '(("bread#town@0" . 5))
                                    (sum-by-key '(("bread#town@0" . 3)) '(("bread#town@0" . 2)))))
(check "different cells stay apart"
       (equal? '(("bread#town@0" . 3) ("bread#hill@0" . 2))
               (sum-by-key '(("bread#town@0" . 3)) '(("bread#hill@0" . 2)))))
(check "empty is the identity"
       (equal? '(("bread#town@0" . 3)) (sum-by-key '(("bread#town@0" . 3)) '())))
;; associativity + commutativity are what make push and pull agree; if these
;; ever fail, the order a fold happens in starts to matter and both break.
(let ((a '(("x" . 1))) (b '(("y" . 2))) (c '(("x" . 3))))
  (check "associative" (equal? (sum-by-key (sum-by-key a b) c)
                               (sum-by-key a (sum-by-key b c))))
  (check "commutative (as a multiset of cells)"
         (equal? (sort (sum-by-key a b) (lambda (p q) (string<? (car p) (car q))))
                 (sort (sum-by-key b a) (lambda (p q) (string<? (car p) (car q)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. The push: a value forwarded up, one link at a time
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. a member's total rises to the root ──\n")

(with-vat vat
  (let* ((fed     (node "fed"))
         (commune (node "commune" '(("bread#town@0" . 1))))
         (leaf    (node "leaf")))
    ($ commune 'set-parent fed)
    ($ leaf 'set-parent commune)
    ($ leaf 'set-own '(("bread#town@0" . 3)))
    (check "the leaf holds its own" (equal? '(("bread#town@0" . 3)) ($ leaf 'fold-total)))
    (check "the commune holds its own + the leaf's (1+3)"
           (equal? '(("bread#town@0" . 4)) ($ commune 'fold-total)))
    (check "and it reached the federation without the federation reading anything"
           (equal? '(("bread#town@0" . 4)) ($ fed 'fold-total)))
    ;; idempotent in the member: the same total twice is not twice the total
    ($ commune 'child-changed "leaf" '(("bread#town@0" . 3)))
    (check "re-delivering a member's total changes nothing"
           (equal? '(("bread#town@0" . 4)) ($ fed 'fold-total)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. REFEDERATION: the property the merged-on-arrival skeleton could not hold
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. a commune changes federation: two messages, both exact ──\n")

(with-vat vat
  (let* ((old-fed (node "old"))
         (new-fed (node "new"))
         (commune (node "commune")))
    ($ commune 'set-parent old-fed)
    ($ commune 'set-own '(("bread#town@0" . 4)))
    (check "before: the old federation answers for it"
           (equal? '(("bread#town@0" . 4)) ($ old-fed 'fold-total)))
    (check "before: the new federation answers for nothing" (null? ($ new-fed 'fold-total)))

    (fold-node-reparent! commune "commune" #:from old-fed #:to new-fed)

    ;; THE point: the old parent is not left holding a sum it can no longer
    ;; explain. Retraction is deletion of a keyed child, not subtraction.
    (check "after: NOTHING of the departed subtree is left behind"
           (null? ($ old-fed 'fold-total)))
    (check "after: the new federation answers for it"
           (equal? '(("bread#town@0" . 4)) ($ new-fed 'fold-total)))
    (check "the commune itself is untouched by the move"
           (equal? '(("bread#town@0" . 4)) ($ commune 'fold-total)))
    ;; and it now pushes to the new parent, not the old one
    ($ commune 'set-own '(("bread#town@0" . 9)))
    (check "later changes reach the new parent" (equal? '(("bread#town@0" . 9)) ($ new-fed 'fold-total)))
    (check "and never the old one" (null? ($ old-fed 'fold-total)))))

;; Leaving the tree entirely, and joining from nowhere, are the same two moves
;; with one side absent.
(with-vat vat
  (let* ((fed (node "fed")) (c (node "c")))
    ($ c 'set-parent fed)
    ($ c 'set-own '(("x" . 2)))
    (fold-node-reparent! c "c" #:from fed #:to #f)
    (check "leaving the tree takes its contribution with it" (null? ($ fed 'fold-total)))
    (fold-node-reparent! c "c" #:from #f #:to fed)
    (check "joining from nowhere delivers it whole" (equal? '(("x" . 2)) ($ fed 'fold-total)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Push and pull are the same fold
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. the walk is the definition; the push is its evaluation ──\n")

;; the same shape, read the other way: scopes with economic roots the walk reads
(define (mk-scope own members)
  (let ((root (spawn ^mock `((demand . ,(lambda () own))))))
    (spawn ^mock `((scope-root . ,(lambda () root))
                   (members    . ,(lambda () members))))))
(define (hm . pairs)
  (fold (lambda (p h) (hashmap-set h (car p) (cdr p))) (hashmap) pairs))

(with-vat vat
  (let* ((leaf-a  (mk-scope '(("bread#town@0" . 3)) (hashmap)))
         (leaf-b  (mk-scope '(("bread#town@0" . 2)) (hashmap)))
         (commune (mk-scope '(("bread#town@0" . 1)) (hm (cons "a" leaf-a) (cons "b" leaf-b))))
         (own-of  (lambda (root) ($ root 'demand)))
         ;; the PULL: walk the live tree and fold
         (pulled  (fold-tree-total keyed-sum-monoid commune own-of))
         ;; the PUSH: the same values delivered link by link
         (n-fed   (node "commune" '(("bread#town@0" . 1))))
         (n-a     (node "a" '(("bread#town@0" . 3))))
         (n-b     (node "b" '(("bread#town@0" . 2)))))
    ($ n-a 'set-parent n-fed) ($ n-a 'set-own '(("bread#town@0" . 3)))
    ($ n-b 'set-parent n-fed) ($ n-b 'set-own '(("bread#town@0" . 2)))
    (check "the pull totals the whole subtree (1+3+2)"
           (equal? '(("bread#town@0" . 6)) pulled))
    (check "the push arrives at the same value — same monoid, different order"
           (equal? pulled ($ n-fed 'fold-total)))

    ;; …so a rebuild from the tree can never disagree with the increments, which
    ;; is what makes the pull a usable repair for a node that drifted or was
    ;; never wired.
    (let ((drifted (node "commune" '(("bread#town@0" . 999)))))
      (fold-node-rebuild! drifted keyed-sum-monoid commune own-of)
      (check "rebuild lands exactly on the walk's value"
             (equal? pulled ($ drifted 'fold-total))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. The walk's awkward cases, handled once for every reading
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. DAGs, cycles and dead branches — one walk, one answer ──\n")

(with-vat vat
  (let* ((shared (mk-scope '(("x" . 4)) (hashmap)))
         (fed-a  (mk-scope '() (hm (cons "s" shared))))
         (fed-b  (mk-scope '() (hm (cons "s" shared))))
         (top    (mk-scope '() (hm (cons "a" fed-a) (cons "b" fed-b))))
         (own-of (lambda (root) ($ root 'demand))))
    (check "a scope reachable by two paths is counted once"
           (equal? '(("x" . 4)) (fold-tree-total keyed-sum-monoid top own-of)))))

(with-vat vat
  ;; a member with no economic root, and one whose root errors: neither sinks it
  (let* ((good   (mk-scope '(("x" . 1)) (hashmap)))
         (rootless (spawn ^mock `((scope-root . ,(lambda () #f))
                                  (members    . ,(lambda () (hashmap))))))
         (broken (spawn ^mock `((scope-root . ,(lambda () (error "down")))
                                (members    . ,(lambda () (hashmap))))))
         (top    (mk-scope '() (hm (cons "g" good) (cons "r" rootless) (cons "b" broken))))
         (own-of (lambda (root) ($ root 'demand))))
    (check "a rootless or down branch drops out, the rest still totals"
           (equal? '(("x" . 1)) (fold-tree-total keyed-sum-monoid top own-of)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Coalescing: a burst of writes costs ONE climb, not one per write
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. many writes, one propagation ──\n")

(with-vat vat
  (call-with-values make-fold-coalescer
    (lambda (schedule drain!)
      (let* ((root (node "root"))
             (mid  (node "mid"))
             (leaf (node "leaf"))
             (climbs 0))
        ;; count what actually reaches the root
        ($ root 'set-on-update (lambda (_) (set! climbs (+ climbs 1))))
        ($ mid 'set-parent root "mid")   ($ mid 'set-schedule schedule)
        ($ leaf 'set-parent mid "leaf")  ($ leaf 'set-schedule schedule)

        ;; five writes at the leaf, back to back
        (for-each (lambda (n) ($ leaf 'set-own `(("bread#town@0" . ,n))))
                  '(1 2 3 4 5))
        (check "nothing has climbed yet — the writes are parked" climbs 0)
        (check "the leaf itself is current all along"
               (equal? '(("bread#town@0" . 5)) ($ leaf 'fold-total)))

        (drain!)
        (check "one drain settles the whole tree" (> climbs 0) #t)
        (check "and the root has the LAST value, not the first"
               (equal? '(("bread#town@0" . 5)) ($ root 'fold-total)))
        (check "five writes cost ONE climb to the root" climbs 1)

        ;; the parked value is always the newest: a write during a parked flush
        ;; overwrites rather than queueing a second climb
        (set! climbs 0)
        ($ leaf 'set-own '(("bread#town@0" . 9)))
        ($ leaf 'set-own '(("bread#town@0" . 11)))
        (drain!)
        (check "still one climb" climbs 1)
        (check "carrying the newest total"
               (equal? '(("bread#town@0" . 11)) ($ root 'fold-total)))))))

;; With no schedule bound, a write climbs inline — the plain behaviour every
;; caller had before, and what the aggregates' own tests still exercise.
(with-vat vat
  (let ((root (node "root")) (leaf (node "leaf")))
    ($ leaf 'set-parent root "leaf")
    ($ leaf 'set-own '(("x" . 2)))
    (check-pred "unscheduled, the climb is immediate"
                (equal? '(("x" . 2)) ($ root 'fold-total)))))

(test-summary!)
