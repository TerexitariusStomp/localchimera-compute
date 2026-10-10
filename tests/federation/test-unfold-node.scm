;;; test-unfold-node.scm — the fold's dual: one router for the whole descent.
;;;
;;; The property the descent has to keep is the SECTION LAW: re-folding a
;;; split's parts reconstructs the value, so routing loses nothing and invents
;;; nothing. And the property it exists FOR is attenuation: each edge carries
;;; exactly the child's slice, so an intermediate scope's share holds nothing
;;; outside its subtree — the roster narrows on the way down as it accumulated
;;; on the way up.

(use-modules (playnet test harness)
             (playnet vf aggregation fold-node)
             (playnet vf aggregation unfold-node)
             (playnet federation descent)
             (playnet federation uc-matching)
             (playnet vf schemas)
             (goblins) (goblins vat)
             (srfi srfi-1))

(define vat (spawn-vat #:name "unfold-node"))

;; items are (key . payload) pairs; the router reads the car
(define (split-for table)
  (route-by-key car (table-child-of table)))

(define (keys-of items) (sort (map car items) string<?))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. The split: partition by claimed key, residual stays own
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. route-by-key — the split most descents are ──\n")

(let* ((split (split-for '(("A" . ("a1" "a2")) ("B" . ("b1")))))
       (value '(("a1" . 1) ("b1" . 2) ("a2" . 3) ("x" . 9)))
       (parts ((split-route split) value '("A" "B"))))
  (check "own keeps what no child claims" (equal? '(("x" . 9)) (car parts)))
  (check "A's slice, in arrival order"
         (equal? '(("a1" . 1) ("a2" . 3)) (cdr (assoc "A" (cdr parts)))))
  (check "B's slice" (equal? '(("b1" . 2)) (cdr (assoc "B" (cdr parts)))))
  (check "a child the route omits reads the split's empty"
         (equal? '() (cdr (assoc "B" (cdr ((split-route split) '(("a1" . 1)) '("A" "B")))))))
  ;; the section law: split then re-fold is the identity (as a multiset)
  (check "section law over list-monoid (multiset of keys)"
         (equal? (keys-of value)
                 (keys-of (split-refold list-monoid split value '("A" "B")))))
  (check "section law over keyed-sum-monoid (summed cells)"
         (equal? (sort (sum-cells value) (lambda (p q) (string<? (car p) (car q))))
                 (sort (sum-cells (split-refold keyed-sum-monoid split value '("A" "B")))
                       (lambda (p q) (string<? (car p) (car q)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. The push: a value descends, and each edge carries only the slice
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. a root value descends; the share narrows per edge ──\n")

(with-vat vat
  (let* ((uc-split  (split-for '(("fedA" . ("a1" "a2")) ("fedB" . ("b1")))))
         (fa-split  (split-for '(("A1" . ("a1")) ("A2" . ("a2")))))
         (leaf-split (split-for '()))
         (uc   (spawn-unfold-node uc-split #:id "uc"))
         (fedA (spawn-unfold-node fa-split #:id "fedA"))
         (fedB (spawn-unfold-node leaf-split #:id "fedB"))
         (a1   (spawn-unfold-node leaf-split #:id "A1"))
         (a2   (spawn-unfold-node leaf-split #:id "A2")))
    (wire-unfold-parent! fedA uc "fedA")
    (wire-unfold-parent! fedB uc "fedB")
    (wire-unfold-parent! a1 fedA "A1")
    (wire-unfold-parent! a2 fedA "A2")
    ($ uc 'set-value '(("a1" . 1) ("b1" . 2) ("a2" . 3) ("stray" . 9)))
    (check "the leaf holds exactly its slice"
           (equal? '(("a1" . 1)) ($ a1 'unfold-value)))
    (check "its sibling holds its own"
           (equal? '(("a2" . 3)) ($ a2 'unfold-value)))
    (check "the other federation never sees the A subtree's items"
           (equal? '(("b1" . 2)) ($ fedB 'unfold-value)))
    (check "a mid node's own is empty when everything routes on"
           (equal? '() ($ fedA 'unfold-own)))
    (check "what no child claims stays at the root's own"
           (equal? '(("stray" . 9)) ($ uc 'unfold-own)))
    ;; the pull: a node's standing share and the parent's split agree
    (check "child-share is what the child was handed"
           (equal? ($ a1 'unfold-value) ($ fedA 'child-share "A1")))
    ;; a garbled node rebuilds from its parent — the pull as an operation
    ($ a1 'set-value '(("garbage" . 0)))
    (unfold-node-rebuild! a1)
    (check "rebuild lands on exactly what the pushes delivered"
           (equal? '(("a1" . 1)) ($ a1 'unfold-value)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Wiring and refederation: two messages, then a redeploy routes anew
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. add-child delivers at once; a mover redeploys exactly ──\n")

(with-vat vat
  (let* ((split (split-for '(("kid" . ("k1")))))
         (root (spawn-unfold-node split #:id "root"))
         (kid  (spawn-unfold-node (split-for '()) #:id "kid")))
    ($ root 'set-value '(("k1" . 7)))
    ($ root 'add-child "kid" kid)
    (check "a child arriving after the deploy is handed its slice at once"
           (equal? '(("k1" . 7)) ($ kid 'unfold-value)))))

(with-vat vat
  ;; a2 moves from fedA to fedB. The reparent is two tree messages PLUS its
  ;; other half: every ancestor whose table named the mover re-binds its
  ;; split, then a redeploy routes along the new tree.
  (let* ((uc   (spawn-unfold-node (split-for '(("fedA" . ("a1" "a2")) ("fedB" . ("b1")))) #:id "uc"))
         (fedA (spawn-unfold-node (split-for '(("A1" . ("a1")) ("A2" . ("a2")))) #:id "fedA"))
         (fedB (spawn-unfold-node (split-for '(("B1" . ("b1")))) #:id "fedB"))
         (a2   (spawn-unfold-node (split-for '()) #:id "A2")))
    (wire-unfold-parent! fedA uc "fedA")
    (wire-unfold-parent! fedB uc "fedB")
    (wire-unfold-parent! a2 fedA "A2")
    ($ uc 'set-value '(("a2" . 5)))
    (check "before the move, the share arrives through fedA"
           (equal? '(("a2" . 5)) ($ a2 'unfold-value)))
    (unfold-node-reparent! a2 "A2" #:from fedA #:to fedB)
    ($ uc 'set-split (split-for '(("fedA" . ("a1")) ("fedB" . ("b1" "a2")))))
    ($ fedB 'set-split (split-for '(("B1" . ("b1")) ("A2" . ("a2")))))
    ($ uc 'set-value '(("a2" . 6)))
    (check "after the reparent and its routing half, it arrives through fedB"
           (equal? '(("a2" . 6)) ($ a2 'unfold-value)))
    (check "and the old parent's share no longer contains the mover at all"
           (equal? '() ($ fedA 'unfold-value)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Coalescing: a burst descends once, carrying the newest value
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. N writes, one fan-out ──\n")

(with-vat vat
  (call-with-values make-fold-coalescer
    (lambda (schedule drain!)
      (let* ((root (spawn-unfold-node (split-for '(("kid" . ("k1")))) #:id "root"))
             (kid  (spawn-unfold-node (split-for '()) #:id "kid"))
             (seen 0))
        ($ root 'add-child "kid" kid)
        ($ kid 'set-on-update (lambda (_v) (set! seen (+ seen 1))))
        ($ root 'set-schedule schedule)
        ($ root 'set-value '(("k1" . 1)))
        ($ root 'set-value '(("k1" . 2)))
        ($ root 'set-value '(("k1" . 3)))
        (check "nothing has fanned out yet" (= seen 0))
        (drain!)
        (check "one descent" (= seen 1))
        (check "carrying the newest value" (equal? '(("k1" . 3)) ($ kid 'unfold-value)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. The labour descent: the roster narrows on the way down
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. deployment — each scope sees only its subtree's commitments ──\n")

(define (lc plan agent) (make-labour-commitment plan agent "baking" #f 4 (string-append "wi:" plan)))

(check "a labour commitment names the plan it serves"
       (equal? "plan-a1" (commitment-destination (lc "plan-a1" "alice"))))

(with-vat vat
  (let* ((uc   (spawn-deployment-node (table-child-of '(("fedA" . ("plan-a1" "plan-a2")) ("fedB" . ("plan-b1")))) #:id "uc"))
         (fedA (spawn-deployment-node (table-child-of '(("A1" . ("plan-a1")) ("A2" . ("plan-a2")))) #:id "fedA"))
         (fedB (spawn-deployment-node (table-child-of '()) #:id "fedB"))
         (a1   (spawn-deployment-node (table-child-of '()) #:id "A1"))
         (a2   (spawn-deployment-node (table-child-of '()) #:id "A2"))
         (deployment (list (lc "plan-a1" "alice") (lc "plan-a2" "bo")
                           (lc "plan-b1" "chandra") (lc "plan-a1" "dai"))))
    (wire-unfold-parent! fedA uc "fedA")
    (wire-unfold-parent! fedB uc "fedB")
    (wire-unfold-parent! a1 fedA "A1")
    (wire-unfold-parent! a2 fedA "A2")
    (deploy! uc deployment)
    (check "the leaf's slice is its plan's commitments, workers named"
           (equal? '("alice" "dai")
                   (map commitment-provider (deployment-of a1))))
    (check "its hours sum on the slice alone" (= 8 (deployed-hours-of a1)))
    (check "the sibling leaf sees only its own worker"
           (equal? '("bo") (map commitment-provider (deployment-of a2))))
    ;; the disclosure property, stated as what a boundary crossing CONTAINS:
    (check "fedB's whole share holds no name from the A subtree"
           (equal? '("chandra")
                   (map commitment-provider ($ fedB 'unfold-value))))
    (check "a routing mid-node retains no one" (equal? '() (deployment-of fedA)))
    ;; and the section law on the real thing: nothing lost, nothing invented
    (check "every commitment lands exactly once"
           (equal? (sort (map commitment-id deployment) string<?)
                   (sort (map commitment-id
                              (append ($ uc 'unfold-own)
                                      (deployment-of fedA) (deployment-of fedB)
                                      (deployment-of a1) (deployment-of a2)))
                         string<?)))))

(test-summary!)
