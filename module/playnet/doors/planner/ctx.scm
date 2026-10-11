;;; module/playnet/doors/planner/ctx.scm — the planner service's context: what its door fragments share.
;;;
;;; ^planner-service (doors/service.scm) is composed of fragments, each a procedure
;;; from this context to a declared-doors value (docs/planning/codebase-layout.md
;;; §12), as the governance service is of its context and the scope of its own.
;;; The context is one `define-context` (playnet protocol context): the field
;;; list below is the one statement, and the record, `make-planner-ctx`,
;;; `with-planner-ctx` and `planner-ctx-install!` are read off it. It holds three
;;; kinds of thing, each a field by name:
;;;
;;;   the cells a door writes   ph-ok?, witness-door, solve-vat, re-stand: wiring
;;;                             that arrives after the spawn through a setter door
;;;   the helpers the core      the roster, the scope and person gates, the home,
;;;   hands over once it has    the standing terms, the solve queue, the folds and
;;;   them                      descents, the slot and means notices, the steward
;;;                             gate, the readers governance injects
;;;   the solve cache           one <solve-cache> per service (doors/planner/solve-cache)
;;;
;;; `(with-planner-ctx ctx body …)` binds every field under its own name, reading
;;; through the accessor on each use and writing through the setter on `set!`, so
;;; a fragment's clause reads as it did inside the actor and a cell it sets is set
;;; for every other fragment. The body is a body: it may define, a define of a
;;; field's name shadows the field (the core defines its helpers this way, then
;;; hands them over with `planner-ctx-install!`), and the whole stands wherever an
;;; expression may, including as an actor's last form.
;;;
;;; What one fragment alone reads and writes is that fragment's own, defined inside
;;; it above its declared-doors.

(define-module (playnet doors planner ctx)
  #:use-module (srfi srfi-9)
  #:use-module (playnet protocol context)
  #:export (make-planner-ctx planner-ctx? with-planner-ctx planner-ctx-install!
            make-scope-nodes scope-nodes? nodes-labour nodes-means nodes-demand nodes-folksonomy nodes-credit nodes-slack
            nodes-voice nodes-reading nodes-deployment nodes-allocation nodes-solve %fold-kinds %descent-kinds
            planner-ctx-ph-ok? planner-ctx-witness-door planner-ctx-solve-vat
            planner-ctx-re-stand planner-ctx-cache planner-ctx-roster-ref
            planner-ctx-roster-entries planner-ctx-roster-add! planner-ctx-roster-forget!
            planner-ctx-with-scope planner-ctx-with-person planner-ctx-scoped
            planner-ctx-door-read planner-ctx-home-scope-of planner-ctx-adopt-home!
            planner-ctx-set-home-row! planner-ctx-person-events
            planner-ctx-person-observers planner-ctx-standing planner-ctx-world-of*
            planner-ctx-gather planner-ctx-plan-fn* planner-ctx-on-plan
            planner-ctx-resolve-scope! planner-ctx-resolve-one-stale!
            planner-ctx-resolve-stale-scopes! planner-ctx-node-of
            planner-ctx-labour-pool-of planner-ctx-uc planner-ctx-rehang-scope!
            planner-ctx-declared-parent planner-ctx-deployment-table
            planner-ctx-slots-changed! planner-ctx-slots-watch!
            planner-ctx-slots-unwatch! planner-ctx-means-changed!
            planner-ctx-means-rebuild! planner-ctx-means-fold-total
            planner-ctx-steward-admit planner-ctx-steward-ok? planner-ctx-means-criteria
            planner-ctx-scope-community planner-ctx-communes-overlap
            planner-ctx-scope-census planner-ctx-scope-record-of
            planner-ctx-federation-sibling-locations planner-ctx-credit-roots
            planner-ctx-refold-voice! planner-ctx-refold-readings! planner-ctx-rail-hands
            planner-ctx-debts-of planner-ctx-owed-of planner-ctx-settle-of
            planner-ctx-may-steward-of planner-ctx-lent-of planner-ctx-knows-of
            planner-ctx-pool-of planner-ctx-contrary-of
            set-planner-ctx-ph-ok?! set-planner-ctx-witness-door!
            set-planner-ctx-solve-vat! set-planner-ctx-re-stand! set-planner-ctx-cache!
            set-planner-ctx-roster-ref! set-planner-ctx-roster-entries!
            set-planner-ctx-roster-add!! set-planner-ctx-roster-forget!!
            set-planner-ctx-with-scope! set-planner-ctx-with-person!
            set-planner-ctx-scoped! set-planner-ctx-door-read!
            set-planner-ctx-home-scope-of! set-planner-ctx-adopt-home!!
            set-planner-ctx-set-home-row!! set-planner-ctx-person-events!
            set-planner-ctx-person-observers! set-planner-ctx-standing!
            set-planner-ctx-world-of*! set-planner-ctx-gather! set-planner-ctx-plan-fn*!
            set-planner-ctx-on-plan! set-planner-ctx-resolve-scope!!
            set-planner-ctx-resolve-one-stale!! set-planner-ctx-resolve-stale-scopes!!
            set-planner-ctx-node-of! set-planner-ctx-labour-pool-of! set-planner-ctx-uc!
            set-planner-ctx-rehang-scope!! set-planner-ctx-declared-parent!
            set-planner-ctx-deployment-table! set-planner-ctx-slots-changed!!
            set-planner-ctx-slots-watch!! set-planner-ctx-slots-unwatch!!
            set-planner-ctx-means-changed!! set-planner-ctx-means-rebuild!!
            set-planner-ctx-means-fold-total! set-planner-ctx-steward-admit!
            set-planner-ctx-steward-ok?! set-planner-ctx-means-criteria!
            set-planner-ctx-scope-community! set-planner-ctx-communes-overlap!
            set-planner-ctx-scope-census! set-planner-ctx-scope-record-of!
            set-planner-ctx-federation-sibling-locations! set-planner-ctx-credit-roots!
            set-planner-ctx-refold-voice!! set-planner-ctx-refold-readings!!
            set-planner-ctx-rail-hands! set-planner-ctx-debts-of!
            set-planner-ctx-owed-of! set-planner-ctx-settle-of!
            set-planner-ctx-may-steward-of! set-planner-ctx-lent-of!
            set-planner-ctx-knows-of! set-planner-ctx-pool-of!
            set-planner-ctx-contrary-of!))

(define-context planner-ctx
  ;; the cells at their defaults: everyone holds personhood until the gateway
  ;; installs its checker, no witness door, no solve vat, nothing to re-stand;
  ;; the helpers are handed over by `planner-ctx-install!` once the actor has them
  (ph-ok? (lambda (_aid) #t)) witness-door solve-vat (re-stand '()) cache
  roster-ref roster-entries roster-add! roster-forget! with-scope with-person scoped
  door-read home-scope-of adopt-home! set-home-row! person-events person-observers
  standing world-of* gather plan-fn* on-plan resolve-scope! resolve-one-stale!
  resolve-stale-scopes! node-of labour-pool-of uc rehang-scope! declared-parent
  deployment-table slots-changed! slots-watch! slots-unwatch! means-changed!
  means-rebuild! means-fold-total steward-admit steward-ok? means-criteria
  scope-community communes-overlap scope-census scope-record-of
  federation-sibling-locations credit-roots refold-voice! refold-readings! rail-hands
  debts-of owed-of settle-of may-steward-of lent-of knows-of pool-of contrary-of)

;; ── every node a scope stands up, as one record ────────────────────────────
;; Eight folds and three descents; a scope has all eleven from the moment it is
;; wired, the UC roots are one such record, and every read, reparent and
;; wiring walks the record's fields. Wired ⇔ the record exists.
(define-record-type <scope-nodes>
  (make-scope-nodes labour means demand folksonomy credit slack voice reading deployment allocation solve)
  scope-nodes?
  (labour nodes-labour) (means nodes-means) (demand nodes-demand) (folksonomy nodes-folksonomy)
  (credit nodes-credit) (slack nodes-slack) (voice nodes-voice) (reading nodes-reading)
  (deployment nodes-deployment) (allocation nodes-allocation) (solve nodes-solve))
(define %fold-kinds (list nodes-labour nodes-means nodes-demand nodes-folksonomy nodes-credit nodes-slack nodes-voice nodes-reading))
(define %descent-kinds (list nodes-deployment nodes-allocation nodes-solve))
