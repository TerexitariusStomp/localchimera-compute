;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-folksonomy-actor.scm — ^folksonomy up-the-tree propagation.
;;;
;;; Proves the folksonomy rides the SAME scope-tree aggregation path as the
;;; labour pool: a member deep in the tree publishes a cut, and every ancestor
;;; scope's aggregate incorporates it — a child scope's taxonomy and its parent
;;; commune's taxonomy both re-fold, exactly like wire-labour-pool! forwards an
;;; availability change to the parent pool.
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/folksonomy/test-folksonomy-actor.scm

(use-modules (localchimera test harness)
             (localchimera folksonomy actor)
             (localchimera folksonomy graph)
             (goblins)
             (srfi srfi-1))

(define (assq-ref alist key) (let ((p (assq key alist))) (and p (cdr p))))
(define (child-of node label)
  (and node
       (find (lambda (c) (equal? (assq-ref c 'label) label))
             (or (assq-ref node 'children) '()))))

(define doc-food-grain
  '((terms ((id . "term:food") (label . "Food"))
           ((id . "term:grain") (label . "Grain")))
    (structure ((broader . "term:food") (narrower . "term:grain")))))

(define vat (spawn-vat))

(with-vat vat

  ;; A two-level scope tree: a member's local scope, and the parent commune.
  (define commune (spawn ^folksonomy (make-folksonomy) '()))
  (define scope   (spawn ^folksonomy (make-folksonomy) '()))

  ;; Wire scope → commune (the up-the-tree link), as wire-labour-pool! does.
  (wire-folksonomy! scope #:parent-ref commune)

  (display "\n── A member publishes at the leaf scope ──\n")

  ;; The lobby's sync-taxonomy would call this; reply is the new cut.
  (define cut ($ scope 'contribute "AID-1" doc-food-grain))

  (check "leaf scope aggregated the member's edge"
         ($ scope 'edge-count "term:food" "term:grain") 1)
  (check "contribute reply is the extracted template"
         (and (child-of cut "Food") (child-of (child-of cut "Food") "Grain") #t)
         #t)

  (display "\n── The change propagated UP to the commune ──\n")

  (check "parent commune also holds the edge (aggregate of its subtree)"
         ($ commune 'edge-count "term:food" "term:grain") 1)

  (define commune-tpl ($ commune 'template))
  (check "commune's template shows the member's cut"
         (and (child-of (child-of commune-tpl "Food") "Grain") #t) #t)

  (display "\n── A second member at the same scope reinforces ──\n")

  ($ scope 'contribute "AID-2" doc-food-grain)
  (check "leaf scope: food→grain now asserted by 2"
         ($ scope 'edge-count "term:food" "term:grain") 2)
  (check "commune re-folded both members: count 2 as well"
         ($ commune 'edge-count "term:food" "term:grain") 2)

  (display "\n── on-update fires a UI push ──\n")

  (define pushed '())
  ($ scope 'set-on-update
     (lambda (fk) (set! pushed (cons (folksonomy-template fk) pushed))))
  ($ scope 'contribute "AID-3" doc-food-grain)
  (check "on-update delivered a fresh template to the sink"
         (and (pair? pushed)
              (child-of (child-of (car pushed) "Food") "Grain") #t)
         #t)

  (display "\n── A member retracts (drop-aid) propagates up too ──\n")

  ($ scope 'drop-aid "AID-1")
  (check "leaf scope back to 2 asserters"
         ($ scope 'edge-count "term:food" "term:grain") 2)
  (check "commune also dropped that AID"
         ($ commune 'edge-count "term:food" "term:grain") 2)

  (display "\n── template with a lens AID-set weights the cut (Phase 4) ──\n")
  ;; A fresh aggregate with a contested nesting: many put grain under food,
  ;; one neighbour puts it under staples.
  (define f2 (spawn ^folksonomy (make-folksonomy) '()))
  ($ f2 'contribute "AID-a"
     '((terms) (structure ((broader . "food") (narrower . "grain")))))
  ($ f2 'contribute "AID-b"
     '((terms) (structure ((broader . "food") (narrower . "grain")))))
  ($ f2 'contribute "AID-kin"
     '((terms) (structure ((broader . "staples") (narrower . "grain")))))

  (define global ($ f2 'template))              ; no lens → majority (food)
  (check "global cut nests grain under food (2 > 1)"
         (and (child-of (child-of global "food") "grain") #t) #t)

  ;; lens = just my kin, who nests grain under staples
  (define kin ($ f2 'template '("AID-kin")))
  (check "kin-lens cut nests grain under staples (their 1 outweighs food's 0)"
         (and (child-of (child-of kin "staples") "grain") #t) #t)
  (check "kin-lens: food has no grain child (AID-kin never asserted it)"
         (and (child-of kin "food") (child-of (child-of kin "food") "grain")) #f)

  (define everyone ($ f2 'template #f))         ; explicit #f = global
  (check "#f lens is identical to the global cut"
         (and (child-of (child-of everyone "food") "grain") #t) #t)

  (display "\n── adopt: template→doc→contribute closes the loop (Phase 3) ──\n")
  ;; Adopting a cut = the gateway's adopt-lens body: flatten the derived tree to
  ;; my structure edges and contribute them back. My adoption becomes a vote.
  (define f3 (spawn ^folksonomy (make-folksonomy) '()))
  ($ f3 'contribute "AID-x"
     '((terms) (structure ((broader . "food") (narrower . "grain")))))
  (check "before adopt: food→grain asserted by 1 (AID-x)"
         ($ f3 'edge-count "food" "grain") 1)
  (define my-cut (template->doc ($ f3 'template)))     ; what adopt-lens flattens
  ($ f3 'contribute "me" my-cut)                        ; …and contributes back
  (check "after adopt: I am now an asserter too (count 2)"
         ($ f3 'edge-count "food" "grain") 2)
  (check "the adopted cut is stable (still grain under food)"
         (and (child-of (child-of ($ f3 'template) "food") "grain") #t) #t)
  (check "re-adopting my own cut is idempotent (still 2, not 3)"
         (begin ($ f3 'contribute "me" (template->doc ($ f3 'template)))
                ($ f3 'edge-count "food" "grain"))
         2))

(test-summary!)
