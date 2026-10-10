;;; federation/pending-recompositions.scm
;;;
;;; Cross-gateway recomposition orchestration (deferred task #43).
;;;
;;; The challenge: when a recomposition (merge or split) spans gateways,
;;; the ratifier issues the ratification ACDC locally; D1+D2 already
;;; pushes it via IPEX to each predecessor's gateway. But the
;;; *receiving* end of the predecessor needs to know "the ratification
;;; just arrived — execute the local part of the merge with this SAID
;;; sealed in the successor's icp.a".
;;;
;;; Pattern: a tiny registry of (pattern, action) entries on each
;;; gateway. Coordinators register entries BEFORE the recomposition
;;; ratification arrives ("I expect a ratification matching this
;;; pattern; when it lands, run this action"). The ratification-
;;; arrived-hook (already wired in federation/ipex-policy.scm post-admit-hook for
;;; recomposition-ratification) consults the registry and fires
;;; matching actions.
;;;
;;; Pattern: predicate over the cred — `(lambda (cred) bool)`. Common
;;; shapes:
;;;   (proposal-type-is 'merge-with) — match any merge ratification
;;;   (predecessors-include "E_my_scope_AID") — only ones naming us
;;;   (and-pattern p1 p2 ...) — combine
;;;
;;; Action: thunk receiving the cred — `(lambda (cred) any)`. Typical
;;; body: extract successor-spec from claims, find local scope ref,
;;; call merge-with-parent / split-with-parent on it.
;;;
;;; Why a registry and not a single dispatcher: in v1 we expect at most
;;; a handful of in-flight cross-gateway recompositions at once; a
;;; small list with pattern-matching is cheaper than indexing schemes
;;; and easier to introspect. If concurrency grows, swap for a
;;; (ratification-said → action) hash without changing the public API.

(define-module (playnet federation pending-recompositions)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module ((playnet utils common) #:select (safe-call))
  #:use-module (playnet utils boot-cell)
  ;; cred-claim is the only thing we need from the umbrella — used by
  ;; the cred-aware pattern combinators below. No circular dep: the
  ;; umbrella doesn't import this module.
  #:use-module ((playnet keri acdc) #:select (cred-claim))
  #:use-module ((srfi srfi-1) #:select (every any partition))
  #:use-module (ice-9 format)
  #:export (^pending-recompositions
            spawn-pending-recompositions
            current-pending-recompositions
            ;; Pattern combinators
            proposal-type-is
            predecessors-include
            and-pattern
            any-pattern))

;; ── Boot cell ─────────────────────────────────────────────────────────
;;
;; The gateway sets this at boot to its single ^pending-recompositions
;; ref. The post-admit-hook for recomposition-ratification consults it
;; from inside the notification poll fiber — which is exactly why this
;; is a BOOT CELL (utils/boot-cell.scm), not a parameter: a fiber never
;; sees a parameter set on the boot thread, so the hook read #f forever.

(define current-pending-recompositions (make-boot-cell))

;; ── Pattern combinators ──────────────────────────────────────────────
;;
;; Each combinator returns a predicate `(lambda (cred) bool)`. The
;; cred is a governance-cred alist with claims accessible via
;; (cred-claim cred 'key). The caller builds the predicates with its own
;; credential readers; these combinators take other predicates and combine
;; them — no direct cred access here.

(define (and-pattern . preds)
  "Match iff every PRED matches."
  (lambda (cred)
    (every (lambda (p) (p cred)) preds)))

(define (any-pattern . preds)
  "Match iff at least one PRED matches."
  (lambda (cred)
    (any (lambda (p) (p cred)) preds)))

;; Cred-aware patterns — use cred-claim directly (imported above).

(define (proposal-type-is type)
  "Predicate matching when (cred-claim cred 'proposal-type) = TYPE."
  (lambda (cred)
    (equal? type (cred-claim cred 'proposal-type))))

(define (predecessors-include aid)
  "Predicate matching when (cred-claim cred 'predecessors) contains AID."
  (lambda (cred)
    (let ((preds (cred-claim cred 'predecessors)))
      (and (list? preds) (member aid preds) #t))))

;; ── Actor ────────────────────────────────────────────────────────────

(define-actor (^pending-recompositions bcom entries)
  ;; entries: list of (pattern action) pairs
  (methods
   ((all) entries)
   ((count) (length entries))

   ((register pattern action)
    "Add (PATTERN ACTION) to the registry. Returns the new count.
     Coordinator calls this BEFORE initiating the recomposition;
     hook calls fire-matching when ratification lands."
    (bcom (^pending-recompositions bcom (cons (list pattern action) entries))
          (+ 1 (length entries))))

   ((fire-matching cred)
    "Called by the recomposition-ratification post-admit-hook.
     Walks entries; for each matching pattern, runs the action.
     Returns the count of actions fired. Matched entries are
     removed (one-shot semantics).

     partition runs each predicate exactly once and splits into
     (values matches kept) — replaces the earlier filter+filter+not
     pattern that ran predicates twice (predicate side-effects + 2x
     work)."
    (call-with-values
      (lambda ()
        (partition (lambda (e) (safe-call (lambda () ((car e) cred))))
                   entries))
      (lambda (matches kept)
        (for-each
         (lambda (e)
           (safe-call
            (lambda () ((cadr e) cred))
            (begin
              (format (current-error-port)
                      "[pending-recompositions] action errored for cred ~a~%"
                      cred)
              #f)))
         matches)
        (bcom (^pending-recompositions bcom kept) (length matches)))))

   ((clear!)
    "Drop all entries. Operator escape hatch."
    (bcom (^pending-recompositions bcom '()) 'cleared))))

(define (spawn-pending-recompositions)
  (spawn ^pending-recompositions '()))
