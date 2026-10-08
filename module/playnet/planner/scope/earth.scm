;;; earth.scm — the planetary economic root: ^earth, a durable registry of every
;;; commune's economic scope-root.
;;;
;;; The whole commons is ONE Goblins persistence graph rooted at `earth`. Instead of a
;;; single durable commune (the old `meeting-scope` shortcut, which forced every restored
;;; commune to re-link to Playnet's economy), earth holds a hashmap `scope-aid → ^scope-root`
;;; and IS the persisted root of the planner-vat. Every commune's economic root — its
;;; observer, recipe/agent/spatial stores, its inventory and plans — is reachable from
;;; earth, so ALL of them are captured in planner.syrup and rehydrated on reboot, each with
;;; its OWN state. A new commune is born here (`ensure-commune!`), which is what makes it
;;; durable: hang it off earth and the next persistence churn keeps it. No per-commune
;;; store files, no cross-vat plumbing — one planet, one graph.
;;;
;;; Included by (playnet planner) after scope-root.scm (needs spawn-scope-root + the store
;;; envs). Every `$`/`spawn` here is in the planner-vat — call within it.

;; ^earth — scope-aid → ^scope-root. A persistence-aware actor (its hashmap of scope-root
;; refs serializes; each ^scope-root is itself persistence-aware), so the whole registry
;; rehydrates from the store. bcom returns the method's value (2nd arg) — the codebase's
;; must-return-bcom rule.
(define-module (playnet planner scope earth)
  #:use-module (goblins utils hashmap)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet planner vf schemas)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner scope root)
  #:export (^earth spawn-earth earth-env))

(define-actor (^earth bcom communes)
  #:version 1
  (methods
    ((name) "earth")
    ;; ((aid . root) …) — every commune under earth (for the restore re-wire + scope-list).
    ((all-communes) (hashmap-fold (lambda (aid root acc) (cons (cons aid root) acc)) '() communes))
    ((commune aid)      (hashmap-ref communes aid #f))
    ((has-commune? aid) (and (hashmap-ref communes aid #f) #t))
    ((count)            (hashmap-fold (lambda (_a _r n) (+ n 1)) 0 communes))
    ;; register an ALREADY-spawned root under earth.
    ((add-commune! aid root)
     (bcom (^earth bcom (hashmap-set communes aid root)) root))
    ;; the symmetric op: drop a commune from the roster. For a throwaway/demo
    ;; commune (never handed out a durable AID anyone holds a claim against)
    ;; — a real commune leaves via governance's remove-commune (federation
    ;; membership revocation), never this. Returns the removed root, or #f.
    ((forget-commune! aid)
     (let ((root (hashmap-ref communes aid #f)))
       (bcom (^earth bcom (hashmap-remove communes aid)) root)))
    ;; move a commune from one key to another (single-keyed): the founding commune is
    ;; created under a placeholder before its KERI AID is minted, then rekeyed to the AID
    ;; once known — so the roster is always keyed by real scope-aids, never doubled.
    ((rekey-commune! old new)
     (let ((root (hashmap-ref communes old #f)))
       (if (and root (not (equal? old new)))
           (bcom (^earth bcom (hashmap-set (hashmap-remove communes old) new root)) root)
           (bcom (^earth bcom communes) root))))
    ;; lookup-or-create — the durable onboarding. A commune's economic root is BORN here,
    ;; under earth, so it persists with earth. Returns the root either way (existing or new).
    ;; LAW-PACKS (optional) is the rule-pack folder a NEW root's law starts
    ;; from; an existing root keeps the law it persisted with.
    ((ensure-commune! aid name . maybe-law-packs)
     (let ((existing (hashmap-ref communes aid #f)))
       (if existing
           existing
           (let ((root (spawn-scope-root name
                         #:law-packs (and (pair? maybe-law-packs) (car maybe-law-packs)))))
             (bcom (^earth bcom (hashmap-set communes aid root)) root)))))))

;; A fresh, empty planet — the persist thunk on a TRUE first boot (no store yet).
(define (spawn-earth) (spawn ^earth (hashmap)))

;; The persistence env for the planner-vat rooted at earth: ^earth plus everything a
;; scope-root needs (scope-root-env already composes all the store envs).
(define earth-env
  (make-persistence-env
    `((((vf) ^earth) ,^earth))
    #:extends (list scope-root-env)))
