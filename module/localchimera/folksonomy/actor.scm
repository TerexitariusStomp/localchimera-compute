;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; folksonomy/actor.scm — ^folksonomy actor.
;;;
;;; It is `^fold-node` (vf/aggregation/fold-node.scm) with taxonomy's three pieces
;;; — the same actor that carries labour, demand and socialized capacity:
;;;
;;;   monoid   graphs merged by asserting AID (folksonomy-merge)
;;;   writes   aid-changed / contribute / drop-aid: refold ONE AID into OWN
;;;   reads    template / children / parents / edge-count / by-aid, over the total
;;;
;;; The flow:
;;;   an AID publishes its taxonomy doc (sync-taxonomy on ^lobby-session)
;;;     → the scope's node re-folds that one AID into its OWN graph
;;;     → the sink fires, and the parent scope is handed this scope's new TOTAL
;;;     → … up to the Universal Commune
;;;
;;; Handing up a TOTAL rather than the (aid, edges) event is what keeps a
;;; member's assertions from crossing a scope boundary, and what makes a
;;; refederation two exact messages instead of a rebuild. It stays exact
;;; because both halves are idempotent per AID: `folksonomy-set-aid` clears
;;; that AID first, and `folksonomy-merge` re-asserts rather than re-counts, so
;;; an AID reachable by two paths does not get a louder voice.
;;;
;;; This mirrors "availability lives on the agent; scopes are the medium
;;; through which it propagates upward" (availability-pool.scm).

(define-module (localchimera folksonomy actor)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (localchimera folksonomy graph)
  #:use-module (localchimera vf aggregation fold-node)
  #:use-module (localchimera social lens)
  #:export (^folksonomy folksonomy-monoid wire-folksonomy!))

(define (assq-ref alist key) (let ((p (assq key alist))) (and p (cdr p))))

(define folksonomy-monoid (make-monoid (make-folksonomy) folksonomy-merge))

;; ── the domain's questions, over the total ──────────────────────────────────
;; `template` optionally takes a LENS-AIDS list (or #f = the global cut): the
;; neighbourhood whose assertions count, resolved from a lens NAME upstream
;; (social/lens.scm). The predicate is built HERE — locally in this vat — so
;; only the plain AID list crosses the wire, never a closure.
(define folksonomy-reads
  `((template   . ,(lambda (fk . opt)
                     (folksonomy-template
                      fk #:lens (lens-predicate (and (pair? opt) (car opt))))))
    (edge-count . ,(lambda (fk b n) (folksonomy-edge-count fk b n)))
    (children   . ,(lambda (fk term-id) (folksonomy-children fk term-id)))
    (parents    . ,(lambda (fk term-id) (folksonomy-parents fk term-id)))
    (by-aid     . ,(lambda (fk aid) (hashmap-ref (folksonomy-by-aid fk) aid '())))
    (graph      . ,(lambda (fk) fk))))

;; ── the domain's local refold: one AID, into this scope's OWN graph ─────────
(define folksonomy-writes
  `((aid-changed . ,(lambda (fk aid edges-list term-alist)
                      (folksonomy-set-aid fk aid edges-list term-alist)))
    ;; a whole taxonomy doc (the lobby's sync-taxonomy hands this). Its caller
    ;; wants the new CUT back, not the graph, so the write names its reply.
    (contribute  . (,(lambda (fk aid doc)
                       (let ((parsed (parse-taxonomy-doc doc)))
                         (folksonomy-set-aid fk aid
                                             (assq-ref parsed 'structure)
                                             (assq-ref parsed 'terms))))
                    . ,(lambda (fk) (folksonomy-template fk #:lens (lens-predicate #f)))))
    (drop-aid    . ,(lambda (fk aid) (folksonomy-drop-aid fk aid)))
    ;; full local rebuild from (aid . doc) pairs — the seed path
    (rebuild     . ,(lambda (fk aid+docs) (build-folksonomy aid+docs)))))

;; A scope's taxonomy aggregate: its OWN graph, with its members' totals held
;; keyed alongside. Spawned like any actor — (spawn ^folksonomy fk callbacks [id]).
(define ^folksonomy
  (fold-aggregate folksonomy-monoid folksonomy-reads folksonomy-writes #:prefix "folk"))


;;; ── Wiring helper ────────────────────────────────────────────────────────────

(define* (wire-folksonomy! folksonomy-ref
                           #:key (parent-ref #f) (doc-store #f))
  "Wire a scope's folksonomy into the push pipeline, mirroring
   wire-labour-pool!:
     1. doc-store on-taxonomy → folksonomy aid-changed  (when a store emits)
     2. folksonomy forwards each change up to PARENT-REF's folksonomy
   DOC-STORE is any actor exposing set-on-taxonomy (aid edges terms → ·)."
  (when parent-ref
    ($ folksonomy-ref 'set-parent parent-ref))
  (when doc-store
    ($ doc-store 'set-on-taxonomy
       (lambda (aid edges terms)
         ($ folksonomy-ref 'aid-changed aid edges terms)))))
