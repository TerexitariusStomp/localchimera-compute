;;; system-kb.scm — playnet's knowledge of its own structure
;;; Plain facts queried via miniKanren. No hyperarcs — relations all the way.
;;; Hoot/WASM compatible.
;;;
;;; Usage:
;;;   (use-modules (playnet lang system-kb) (playnet lang knowledge) (playnet lang kanren))
;;;   (run* (q) (depends-on-o q 'goblins))
;;;   (run* (proof) (trigger-chain-o 'rad-push 'kernel proof))

(define-module (playnet lang system-kb)
  #:use-module ((srfi srfi-1) #:select (delete-duplicates))
  #:use-module (playnet lang kanren)
  #:use-module (playnet lang knowledge)
  #:export (*system-facts*
            ;; Relations
            depends-on-o file-of-o provides-o
            layer-o trigger-chain-o
            ;; Pure Scheme
            query-depends query-layers query-files-for
            query-provides query-what-changes))


;;; ── Facts ─────────────────────────────────────────────────────────────────────
;;; Plain tagged tuples. One fact per relationship.

(define *system-facts*
  '(;; Dependencies: (depends FROM TO) — FROM depends on TO
    (depends browser evaluator)
    (depends browser actors)
    (depends browser kanren)
    (depends knowledge kanren)
    (depends evaluator actors)
    (depends actors goblins)
    (depends gateway goblins)
    (depends gateway signup-agent)
    (depends signup-agent goblins)
    (depends signup-agent provision)
    (depends provision guix-deploy)
    (depends planner goblins)
    (depends key-pool goblins)
    (depends reticulum goblins)
    (depends goblins guile)
    (depends guile guix)
    (depends guix kernel)
    (depends guix bootloader)
    (depends guix services)
    (depends guix users)
    (depends rad-push radicle-ci)
    (depends radicle-ci guix-deploy)
    (depends guix-deploy guix)

    ;; Files: (file LAYER PATH)
    (file actors "module/playnet/org/actors.scm")
    (file evaluator "module/playnet/lang/evaluator.scm")
    (file browser "module/playnet/org/repl.scm")
    (file browser "hoot/repl.scm")
    (file browser "browser/repl.js")
    (file browser "browser/index.html")
    (file kanren "module/playnet/lang/kanren.scm")
    (file knowledge "module/playnet/lang/knowledge.scm")
    (file system-kb "module/playnet/lang/system-kb.scm")
    (file gateway "server/gateway.scm")
    (file signup-agent "module/playnet/identity/seat.scm")
    (file guix-deploy "deploy/guix/machines.scm")
    (file guix-deploy "deploy/guix/deploy.sh")
    (file provision "deploy/guix/users.scm")
    (file provision "deploy/guix/provision-user.scm")
    (file guix-deploy "deploy/guix/channels.scm")
    (file radicle-ci "deploy/scripts/radicle-ci-hook.sh")
    (file radicle-ci "deploy/guix/radicle-service.scm")
    (file planner "module/playnet/planner.scm")
    (file planner "module/playnet/vf/schemas.scm")
    (file planner "module/playnet/planner/relational/planning-facts.scm")
    (file planner "module/playnet/planner/relational/demand-relation.scm")
    (file planner "module/playnet/planner/relational/plan-relation.scm")
    (file key-pool "module/playnet/ai/key-pool.scm")
    (file reticulum "server/rns-bridge/src/bridge.rs")
    (file services "deploy/guix/playnet-service.scm")

    ;; Provides: (provides LAYER CAPABILITY)
    (provides actors state)
    (provides actors accountability)
    (provides actors revocation)
    (provides evaluator eval-in-browser)
    (provides evaluator metacircular-eval)
    (provides kanren relational-queries)
    (provides kanren unification)
    (provides kanren logic-programming)
    (provides knowledge transitive-closure)
    (provides knowledge proof-traces)
    (provides knowledge pattern-matching)
    (provides goblins capability-security)
    (provides goblins actors)
    (provides goblins ocapn)
    (provides goblins persistence)
    (provides reticulum mesh-networking)
    (provides reticulum lora)
    (provides reticulum transport-agnostic)
    (provides guix declarative-os)
    (provides guix reproducibility)
    (provides guix rollback)))


;;; ── Relations ─────────────────────────────────────────────────────────────────

(define (depends-on-o from to)
  (in-list-o `(depends ,from ,to) *system-facts*))

(define (file-of-o layer path)
  (in-list-o `(file ,layer ,path) *system-facts*))

(define (provides-o layer cap)
  (in-list-o `(provides ,layer ,cap) *system-facts*))

(define (layer-o name)
  "Is NAME a known layer?"
  (fresh (other) (depends-on-o name other)))

(define (trigger-chain-o start end proof)
  "Transitive chain from START to END through dependencies."
  (transitive-o depends-on-o start end proof))


;;; ── Pure Scheme queries ───────────────────────────────────────────────────────

(define (query-depends layer)     (run* (q) (depends-on-o layer q)))
(define (query-layers)            (delete-duplicates (run 50 (q) (layer-o q))))
(define (query-files-for layer)   (run* (q) (file-of-o layer q)))
(define (query-provides layer)    (run* (q) (provides-o layer q)))
(define (query-what-changes trigger)
  (run 20 (q) (fresh (proof) (trigger-chain-o trigger q proof))))
