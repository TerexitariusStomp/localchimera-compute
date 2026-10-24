;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; pools/labour-fold.scm — ^labour-pool: the federation fold, over labour.
;;;
;;; Lives at each scope. Maintains the availability of agents reachable through
;;; the scope's membership graph, and hands its TOTAL to the scope above.
;;;
;;; It is `^fold-node` (vf/aggregation/fold-node.scm) with labour's three pieces:
;;;
;;;   monoid   pools merged by (agent, skill) — one body, one entry
;;;   writes   agent-changed: refold that agent into this scope's OWN pool
;;;   reads    query / total-hours / entries / by-agent / free, over the total
;;;
;;; so the tree — children kept keyed, retraction by deletion, the parent told
;;; a total rather than a raw event — is the same code that carries taxonomy,
;;; demand and socialized capacity. What is written here is only labour.
;;;
;;; The flow:
;;;   agent updates availability
;;;     → agent-store fires on-agent
;;;     → this scope's node refolds that agent into its OWN pool
;;;     → the sink fires, and the parent scope is handed this scope's new TOTAL
;;;     → … up to the Universal Commune
;;;
;;; Handing up a TOTAL is what makes a refederation two exact messages instead
;;; of a rebuild (fold-node.scm). The total is a KEYED pool — (agent, skill)
;;; entries, a roster: deployment must land commitments on particular bodies,
;;; so identity crosses every scope boundary here, unlike demand's nameless
;;; sums (fold-node.scm has the per-fold disclosure rule).

(define-module (localchimera pools labour-fold)
  #:use-module (localchimera vf formulas actions)
  #:use-module (srfi srfi-1)
  #:use-module (goblins)
  #:use-module (goblins utils hashmap)
  #:use-module (localchimera vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera vf facts availability)
  #:use-module ((localchimera vf facts agent-time) #:select (agent-schedulable-window agent-away-dates reserve-hours))
  #:use-module (localchimera pools availability-pool)
  #:use-module (localchimera vf aggregation fold-node)
  #:use-module ((localchimera solve ingest) #:select (*default-agent-hours*))
  #:export (^labour-pool labour-monoid wire-labour-pool!
            skill-specs-for-agent skill-resources-for-agent
            skill-onhand-delta skill-count-deltas))

(define labour-monoid (make-monoid (make-labour-pool) pool-merge))

;; ── the domain's local refold: one agent, into this scope's OWN pool ────────
;; Clear that agent's prior entries, then re-add one per skill they hold — so a
;; withdrawal (an emptied window, zero hours) and a re-fire of the same agent
;; are both exact. The two readings mirror the solver's, so the roster and a
;; solve see the same people:
;;   hours   a WEEK's: the window's slots summed (window-weekly-hours) — the
;;           one date-free measure a recurring window has, and what the app
;;           ships (one schedule per weekday, net of recurring commitments);
;;           no window at all ⇒ a working day every day, *default-agent-hours*
;;           × 7 (agent-window-hours's fallback, per day of the period); a
;;           DECLARED empty window ⇒ 0 ⇒ withdrawal. Away days (§2c) are
;;           carried on the entry itself (entry-away), since a windowless
;;           agent has no window to net them from; a query with dates
;;           (entry-hours-on) reads them there, and one with a real window
;;           reads them off the dated week agent-schedulable-window already
;;           withdrew.
;;   skills  none declared ⇒ spec-labor — generic labour comes with the person
;;           (the same reading declare-skill's auto-seed states)
(define (refold-agent pool agent skills-for-agent)
  (let* ((aid     (agent-id agent))
         (cleared (pool-withdraw-agent pool aid))
         (aw      (agent-schedulable-window agent))   ; the offer less the person's own sleep span
         (cell    (resolve-cell agent))     ; shared with build-pool-from-agents
         (hours   (reserve-hours agent 7   ; …and inside what their body leaves of the week
                                 (if aw (window-weekly-hours aw) (* 7 *default-agent-hours*)))))
    (if (zero? hours)
        cleared
        (let ((skills (let ((sks (skills-for-agent aid)))
                        (if (null? sks) '("spec-labor") sks))))
          (fold (lambda (sk p) (pool-add p (make-entry aid sk aw cell hours
                                                        (agent-primary-location agent)
                                                        (agent-away-dates agent))))
                cleared skills)))))

(define labour-reads
  `((query       . ,(lambda (pool . args) (apply pool-query pool args)))
    (total-hours . ,(lambda (pool . args) (apply pool-total-hours pool args)))
    (entries     . ,(lambda (pool) (pool-entries pool)))
    (by-agent    . ,(lambda (pool aid) (hashmap-ref (pool-by-agent pool) aid '())))
    (pool        . ,(lambda (pool) pool))
    ;; the residual after deployed agents are subtracted — a read, not a write:
    ;; it answers a question about the total and stores nothing
    (free        . ,(lambda (pool commitments) (pool-free pool commitments)))))

(define labour-writes
  `((agent-changed . ,refold-agent)
    ;; a person who left the scope: every entry of theirs goes, whatever the skill
    (agent-withdrawn . ,pool-withdraw-agent)
    ;; a full local rebuild from agent records — the seed path, folded through
    ;; refold-agent so the seed and the increment state ONE reading of an agent
    (rebuild . ,(lambda (pool agents skills-for-agent)
                  (fold (lambda (a p) (refold-agent p a skills-for-agent))
                        (make-labour-pool) agents)))))

;; A scope's labour aggregate: its OWN pool, with its members' totals held keyed
;; alongside. Spawned like any actor — (spawn ^labour-pool pool callbacks [id]).
(define ^labour-pool
  (fold-aggregate labour-monoid labour-reads labour-writes #:prefix "labour"))


;;; ── The projection: where the time-fold meets the tree-fold ─────────────────
;; Two folds meet at this module. The observer folds EVENTS over time
;; (state × event → state); the federation folds TOTALS over the tree
;; (own ⊕ children). The read that crosses from one to the other is a
;; projection with three layers, and each layer is one definition below:
;;
;;   image      one commutative event → a keyed delta   (skill-onhand-delta)
;;   extension  a whole log → its merged deltas          (skill-count-deltas)
;;   threshold  a merged count → held or not             (skill-specs-for-agent)
;;
;; The law that makes the layers one structure — held by
;; test-labour-projection-law.scm — is that the extension is a per-key
;; HOMOMORPHISM into the keyed-sum monoid the tree already folds:
;;
;;     project (fold log)  =  baseline ⊕ merge (map image log)
;;
;; On the commutative fragment (raise/lower on a skill resource) the two
;; folds therefore commute: the projection is order-free, and an incremental
;; climb — send the delta, skip the per-agent re-clear — is licensed whenever
;; a profile wants it. Everything outside the fragment (update-to,
;; corrections, transfer pairs) has NO image: those events stay in the scope
;; where the log's total order lives, which is the disclosure rule said as
;; algebra. Held-ness is a threshold ON TOP of the homomorphism, not part of
;; it — which is exactly why a revocation (a lower to zero) leaves the roster
;; while the resource and its history remain.

;; A skill is an economic resource conforming to a WORKED spec — one that states
;; an effort unit or that a recipe draws as work (formulas/actions labour?). The
;; readers below are TOLD what labour is (LABOUR?, spec-id → bool, built once per
;; scope by scope-labour? in scope/live); the solver (engine vf-agent-skills)
;; reads the same predicate, so the roster and the solve cannot differ on what a
;; held skill is. The observer's reads keep their wide shape; the filter is here.

(define (mqty m) (if m (measure-has-numerical-value m) 0))

(define (skill-onhand-delta ev labour?)
  "The image of one commutative skill event: ((agent . spec) . ±q) for a
raise/lower on a skill resource (one whose spec LABOUR? admits), #f — no
image — for every other event."
  (and (memq (economic-event-action ev) *adjustment-actions*)
       (labour? (economic-event-resource-conforms-to ev))
       (economic-event-provider ev)
       (economic-event-resource-conforms-to ev)
       (cons (cons (economic-event-provider ev)
                   (economic-event-resource-conforms-to ev))
             (let ((q (mqty (economic-event-resource-quantity ev))))
               (if (eq? (economic-event-action ev) 'lower) (- q) q)))))

(define (skill-count-deltas events labour?)
  "The image's free extension to a whole log: merge ∘ map, in the tree's
keyed-sum monoid — associativity of ⊕ is what makes it order-free."
  (sum-by-key '() (filter-map (lambda (ev) (skill-onhand-delta ev labour?)) events)))

(define (skill-resources-for-agent observer aid labour?)
  "The skill resources AID holds at on-hand > 0: those whose spec LABOUR? admits,
whatever id they carry."
  (filter (lambda (r)
            (and (labour? (economic-resource-conforms-to r))
                 (> (mqty (economic-resource-onhand-quantity r)) 0)))
          ($ observer 'skills-of aid)))

(define (skill-specs-for-agent observer aid labour?)
  "The threshold read: the spec-ids AID holds at on-hand > 0 — the same
reading vf-agent-skills gives the solver, so roster and solve see one truth.
`skills-of` answers a list of ALL the agent's holdings; LABOUR? narrows it
to skills."
  (delete-duplicates
   (filter-map economic-resource-conforms-to
               (skill-resources-for-agent observer aid labour?))))

;;; ── Wiring helper ───────────────────────────────────────────────────────────

(define* (wire-labour-pool! scope-root labour-pool-ref
                            #:key (skills-for-agent-fn #f)
                                  (labour? (lambda (spec) #f))
                                  (parent-pool-ref #f)
                                  (scope-id #f))
  "Wire a scope's labour pool into the federation fold:
     1. agent-store on-agent → this node's agent-changed (a local refold),
        on-agent-removed → agent-withdrawn
     2. this node hands its TOTAL up to PARENT-POOL-REF, keyed by SCOPE-ID
   SCOPE-ID is the key the parent files this subtree under, so it can be
   dropped exactly when the scope refederates (fold-node-reparent!). Call after
   scope-root's rewire-callbacks. SKILLS-FOR-AGENT-FN, else the roster's own
   read under LABOUR? (scope-labour? of the root, which the caller holds; with
   neither, a person's holdings name no skill and they fold as generic labour)."
  (let* ((agent-store ($ scope-root 'agent-store))
         (observer    ($ scope-root 'observer))
         (skills-fn (or skills-for-agent-fn
                        (lambda (aid)
                          (skill-specs-for-agent observer aid labour?)))))
    ($ agent-store 'set-on-agent
       (lambda (agent)
         ($ labour-pool-ref 'agent-changed agent skills-fn)))
    ;; a person removed from the scope leaves its pool with them — optional:
    ;; a store that answers no such method (a minimal mock built before this
    ;; hook existed) simply never removes an agent through it, as before
    (false-if-exception
     ($ agent-store 'set-on-agent-removed
        (lambda (aid) ($ labour-pool-ref 'agent-withdrawn aid))))
    (wire-fold-parent! labour-pool-ref parent-pool-ref scope-id)))
