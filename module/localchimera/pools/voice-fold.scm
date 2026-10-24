;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; pools/voice-fold.scm — ^voice-pool: the scope fold of producer voice.
;;;
;;; docs/planning/voice/voice-follows-work.md ("Where the hand folds"): stances
;;; on parts inside a person's scope fold there; a stance on a part wider than
;;; their scope rises as an aggregate — the hours-weighed sum per part — and
;;; the part's total hours are known at the scope that contains all of it, so
;;; the share is completed there and NO PERSON IS VISIBLE ABOVE THEIR OWN
;;; SCOPE. This is `^fold-node` (vf/aggregation/fold-node.scm) with voice's three
;;; pieces, the sibling of credit-fold.scm:
;;;
;;;   monoid   keyed sums over two kinds of cell, neither keyed by a person:
;;;              ((h . terms) . hours)        validated hours per cell of work,
;;;                                           TERMS the event's (observer
;;;                                           event-terms: process, place,
;;;                                           skill, instant, scope)
;;;              ((num . part-string) . mass) Σ portion · h(owner, part) over
;;;                                           the hands held in this scope
;;;   writes   voice-changed: re-derive this scope's own cells from its
;;;            observer (the one hours fold, keyed by terms) and the standing
;;;            hands its rail holds (HANDS-OF, injected: the planner imports no
;;;            governance)
;;;   reads    pushes — ((part . push) …), push = num / Σ h over the cells the
;;;            part covers, clamped: the one number per part the engine takes
;;;            hours-of — THE reader, part [owner] → Σ h over the cells it
;;;            covers: what the hand, the pushes, the reference and the engine
;;;            all read (solve/voice-field.scm); anonymous over the total
;;;
;;; The arithmetic is solve/voice-field.scm's (hand-portions, stance-masses): OWN
;;; *is* the pure function over the observer's events and the rail's hands, so
;;; the property suite runs against the function and one parity test pins
;;; node = function. A part nobody in the fold has worked has no h cell it
;;; covers and pushes nothing (theorem 8 `no_carried_hours`); a scope stance is
;;; the part with only its scope node, covering every cell of that scope, so
;;; its push is Σ portion · voice-share — producer voice as it stands today
;;; (theorem 10), with nothing built for it.

(define-module (localchimera pools voice-fold)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (localchimera vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera vf facts parts)
  #:use-module (localchimera solve voice-field)
  #:use-module (localchimera vf aggregation fold-node)
  #:use-module ((localchimera vf schemas) #:select (economic-event-provider recipe-process-process-classified-as))
  #:use-module ((localchimera observation observer) #:select (event-terms))
  #:export (voice-monoid scope-own-voice ^voice-pool
            voice-reads voice-writes wire-voice-node!
            voice-pushes voice-hours-of scope-subtree-voice))

(define voice-monoid keyed-sum-monoid)

;; ── this scope's OWN cells ──────────────────────────────────────────────────
(define (scope-own-voice scope-root hands-of)
  "HANDS-OF : scope-root → ((owner part portion) …), the standing hands on this
   scope's rail (validate-hand'ed). The person is read here and only here."
  (let* ((obs ($ scope-root 'observer))
         ;; the tags an event's process carries (VF processClassifiedAs, the
         ;; scope's recipe-store): the same `tag` term the engine reads onto
         ;; the process's columns, so a stance on a tag finds the hours of
         ;; the acts under it — one grammar for a column and for an event
         (rs (false-if-exception ($ scope-root 'recipe-store)))
         (tags-of (lambda (pid)
                    (let* ((rp (and rs pid (false-if-exception ($ rs 'get-recipe-process pid))))
                           (ts (and rp (recipe-process-process-classified-as rp))))
                      (if (list? ts) (filter string? ts) '()))))
         (terms-of (lambda (ev)
                     (let* ((t (event-terms ev)) (ts (tags-of (assq-ref t 'process))))
                       (if (pair? ts) (append t (list (cons 'tag ts))) t))))
         ;; validated hours per (owner . terms): the one fold, keyed by both
         (by-owner-cell ($ obs 'hours-by (lambda (ev) (cons (economic-event-provider ev) (terms-of ev)))))
         (h-cells (sum-cells (map (lambda (kv) (cons (cons 'h (cdar kv)) (cdr kv))) by-owner-cell)))
         (cells-of (lambda (owner)
                     (filter-map (lambda (kv) (and (equal? (caar kv) owner) (> (cdr kv) 0) (cdar kv))) by-owner-cell)))
         ;; THE reader (observer `hours-on`): part [owner] → hours, over this
         ;; scope's own events — the same read `ledger-gross` and so
         ;; `voice-share` make on the widest part
         (hours-of (lambda (π . owner)
                     ($ obs 'hours-on π #:owner (and (pair? owner) (car owner)) #:terms-of terms-of)))
         (rows (or (and hands-of (hands-of scope-root)) '()))
         (masses (stance-masses (hand-portions rows cells-of) hours-of))
         (num-cells (sum-cells (map (lambda (m) (cons (cons 'num (part->string (cadr m))) (caddr m))) masses))))
    (sum-cells (append h-cells num-cells))))

;; ── the reads, over the total ───────────────────────────────────────────────
(define (%covered-hours cells π)
  (fold (lambda (c a) (if (and (eq? (caar c) 'h) (covers? π (cdar c))) (+ a (cdr c)) a)) 0.0 cells))

(define (voice-hours-of cells)
  "The reader over the fold's total: part [owner] → the validated hours in the
   cells the part covers. The total is anonymous, so an owner named here reads
   as everyone — a person's share is read only in their own scope's OWN."
  (lambda (π . _) (%covered-hours cells π)))

(define (voice-pushes cells)
  "((part . push) …) for every part a hand in the fold names: push = its mass
   over the hours of the cells it covers, clamped to [−1, 1]. A part covering
   no worked cell is dropped: it bends nothing until it has hours."
  (filter-map (lambda (c)
                (and (eq? (caar c) 'num)
                     (let* ((π (string->part (cdar c))) (t (%covered-hours cells π)))
                       (and (> t 0.0) (cons π (clamp (/ (cdr c) t)))))))
              cells))

(define voice-reads
  `((cells    . ,(lambda (t) t))
    (pushes   . ,(lambda (t) (voice-pushes t)))
    (hours-of . ,(lambda (t) (voice-hours-of t)))
    (hours    . ,(lambda (t π) (%covered-hours t π)))))

(define voice-writes
  `((voice-changed . ,(lambda (own scope-root hands-of) (scope-own-voice scope-root hands-of)))))

(define ^voice-pool
  (fold-aggregate voice-monoid voice-reads voice-writes #:prefix "voice"))

;; ── the pull: the same fold, as its definition ──────────────────────────────
(define (scope-subtree-voice scope hands-of)
  (fold-tree-total voice-monoid scope (lambda (root) (scope-own-voice root hands-of))))

;; ── wiring ──────────────────────────────────────────────────────────────────
(define* (wire-voice-node! scope-root node #:key (parent #f) (scope-id #f) (hands-of #f))
  "Seed OWN from the scope's observer and rail, refold on every event the
   observer records (a stance door calls `voice-changed` itself), hand the
   TOTAL to PARENT keyed by SCOPE-ID. The refold is an eventual send, as
   credit's is: a listener fires inside the store's own turn."
  (let ((refold (lambda args (<-np node 'voice-changed scope-root hands-of))))
    ($ ($ scope-root 'observer) 'add-event-listener refold))
  ($ node 'voice-changed scope-root hands-of)
  (wire-fold-parent! node parent scope-id))
