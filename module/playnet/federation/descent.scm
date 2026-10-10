;;; federation/descent.scm — the deployment, walked down the tree it rose from.
;;;
;;; `solve-uc-matching` produces a FLAT deployment at the root: VF commitments,
;;; each naming a worker and the plan it serves. This module is that result's
;;; descent — the labour instance of `unfold-node.scm`, as the labour-fold is
;;; the labour instance of `fold-node.scm`:
;;;
;;;   split    commitments routed by the plan they serve, via a membership
;;;            table naming which child subtree holds each plan
;;;   reads    deployment / deployed-hours, over this scope's OWN slice
;;;   writes   deploy!: a matching round's deployment enters at the root
;;;
;;; ── This is where the roster narrows ───────────────────────────────────────
;;; Going UP, the pool crosses keyed by (agent, skill) — a roster to the UC,
;;; because matching must land commitments on particular bodies (labour-fold).
;;; Going DOWN, each edge carries only the commitments landing in that child's
;;; subtree: a commitment naming a worker travels only along the path to its
;;; leaf, and an intermediate scope's share holds nothing outside its subtree.
;;; The attenuation is the split itself, not a policy over it.
;;;
;;; A module of (playnet federation); consumes `uc-matching`'s result:
;;;   (deploy! root (assoc-ref matching-result 'deployment))

(define-module (playnet federation descent)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet vf aggregation unfold-node)
  #:export (commitment-destination deployment-split ^deployment-descent
            spawn-deployment-node deploy! deployment-of deployed-hours-of))

(define (commitment-destination c)
  "The plan a commitment serves — the routing key of the descent. A labour
   commitment carries its plan id in `planned-within` (and mirrors it in
   `clause-of`); either names the leaf whose rising proposal it answers."
  (or (commitment-planned-within c) (commitment-clause-of c)))

(define (deployment-split child-of)
  "The labour descent's split: a deployment (a list of commitments) routed by
   the plan each serves. CHILD-OF is (plan-id child-ids) → child-id or #f —
   typically `table-child-of` over a membership table read off the same walk
   that seeds the labour fold. A commitment no child claims stays in the
   own-part: this scope is where it lands, or where an unroutable one waits
   to be looked at rather than silently dropped."
  (route-by-key commitment-destination child-of))

(define (%hours c)
  (let ((m (commitment-effort-quantity c)))
    (if m (measure-has-numerical-value m) 0)))

(define deployment-reads
  `((deployment     . ,(lambda (own) own))
    (deployed-hours . ,(lambda (own) (fold (lambda (c a) (+ (%hours c) a)) 0 own)))))

(define (^deployment-descent child-of)
  "The node constructor for one scope's place in the labour descent."
  (unfold-aggregate (deployment-split child-of) deployment-reads '()
                    #:prefix "deployment"))

(define* (spawn-deployment-node child-of #:key (id #f) (parent #f) (on-update #f))
  (spawn-unfold-node (deployment-split child-of)
                     #:id id #:parent parent #:on-update on-update
                     #:reads deployment-reads))

(define (deploy! root deployment)
  "A matching round's flat DEPLOYMENT enters the tree at ROOT and each scope
   receives its slice."
  ($ root 'set-value deployment))

(define (deployment-of node)     ($ node 'deployment))
(define (deployed-hours-of node) ($ node 'deployed-hours))
