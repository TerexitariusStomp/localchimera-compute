;;; system-kb.scm — xorg's knowledge of its own structure
;;; Relational facts queryable via miniKanren. Hyperarcs underneath.
;;; Hoot/WASM compatible.
;;;
;;; Usage:
;;;   (use-modules (xorg system-kb) (xorg knowledge) (xorg kanren))
;;;   (run* (q) (depends-on-o 'browser q))
;;;   (run* (proof) (trigger-chain-o 'push-to-main 'kernel proof))

(define-module (xorg system-kb)
  #:use-module (xorg hyperarc)
  #:use-module (xorg kanren)
  #:use-module (xorg knowledge)
  #:use-module (srfi srfi-1)
  #:export (*system-kb*
            ;; Generic
            fact-o
            ;; Named relations
            depends-on-o file-of-o provides-o
            layer-o trigger-chain-o
            ;; Pure Scheme
            query-depends query-layers query-files-for
            query-provides query-what-changes))

;;; ── Fact constructors ─────────────────────────────────────────────────────
;;; Declarative helpers that produce hyperarcs from plain symbols/strings.
;;; The hyperarc structure is implementation detail — callers state facts.

(define (layer-node name)
  (make-node name name '()))

(define (file-node path)
  (make-node (string->symbol path) path '()))

(define (concept-node name)
  (make-node name name '()))

(define (dep from to)
  "FROM depends on TO."
  (make-hyperarc (make-hyperarc-id 'dep) '()
    (list (layer-node from) (layer-node to))))

(define (file-map layer path)
  "LAYER is implemented by PATH."
  (make-hyperarc (make-hyperarc-id 'file) '()
    (list (layer-node layer) (file-node path))))

(define (layer-provides layer . capabilities)
  "LAYER provides CAPABILITIES."
  (make-hyperarc (make-hyperarc-id 'prov) '()
    (cons (layer-node layer) (map concept-node capabilities))))

;;; ── Dependencies ──────────────────────────────────────────────────────────
;;; Directed: head depends on tail.

(define %dependencies
  (make-metagraph 'dependencies '((description . "What depends on what"))
    (list
     (dep 'browser    'evaluator)
     (dep 'browser    'actors)
     (dep 'browser    'kanren)
     (dep 'browser    'hyperarc)
     (dep 'browser    'knowledge)
     (dep 'knowledge  'kanren)
     (dep 'knowledge  'hyperarc)
     (dep 'evaluator  'actors)
     (dep 'actors     'goblins)
     (dep 'relay      'goblins)
     (dep 'relay      'signup-agent)
     (dep 'signup-agent 'goblins)
     (dep 'signup-agent 'provision)
     (dep 'provision  'guix-deploy)
     (dep 'planner    'goblins)
     (dep 'key-pool   'goblins)
     (dep 'reticulum  'goblins)
     (dep 'goblins    'guile)
     (dep 'guile      'guix)
     (dep 'guix       'kernel)
     (dep 'guix       'bootloader)
     (dep 'guix       'services)
     (dep 'guix       'users)
     (dep 'push-to-main 'github-actions)
     (dep 'github-actions 'guix-deploy)
     (dep 'guix-deploy 'guix))))

;;; ── Files ─────────────────────────────────────────────────────────────────
;;; Which source files belong to which layer.

(define %files
  (make-metagraph 'files '((description . "Which files belong to which layer"))
    (list
     (file-map 'actors         "module/xorg/actors.scm")
     (file-map 'evaluator      "module/xorg/evaluator.scm")
     (file-map 'browser        "module/xorg/repl.scm")
     (file-map 'browser        "browser/repl.scm")
     (file-map 'browser        "browser/repl.js")
     (file-map 'browser        "browser/index.html")
     (file-map 'kanren         "module/xorg/kanren.scm")
     (file-map 'hyperarc       "module/xorg/hyperarc.scm")
     (file-map 'knowledge      "module/xorg/knowledge.scm")
     (file-map 'system-kb      "module/xorg/system-kb.scm")
     (file-map 'relay          "server/relay.scm")
     (file-map 'signup-agent   "server/signup-agent.scm")
     (file-map 'guix-deploy    "deploy/guix/machines.scm")
     (file-map 'guix-deploy    "deploy/guix/deploy.sh")
     (file-map 'provision      "deploy/guix/users.scm")
     (file-map 'provision      "deploy/guix/provision-user.scm")
     (file-map 'guix-deploy    "deploy/guix/channels.scm")
     (file-map 'github-actions ".github/workflows/deploy.yml")
     (file-map 'github-actions ".github/workflows/pages.yml")
     (file-map 'planner        "planner/lib/schemas.scm")
     (file-map 'key-pool       "key-pool/key-pool.scm")
     (file-map 'reticulum      "server/reticulum-bridge.py")
     (file-map 'services       "deploy/guix/xorg-service.scm"))))

;;; ── Provides ──────────────────────────────────────────────────────────────
;;; What capabilities each layer provides.

(define %provides
  (make-metagraph 'provides '((description . "What each layer provides"))
    (list
     (layer-provides 'actors     'state 'accountability 'revocation)
     (layer-provides 'evaluator  'eval-in-browser 'metacircular-eval)
     (layer-provides 'kanren     'relational-queries 'unification 'logic-programming)
     (layer-provides 'knowledge  'transitive-closure 'proof-traces 'pattern-matching)
     (layer-provides 'goblins    'capability-security 'actors 'ocapn 'persistence)
     (layer-provides 'reticulum  'mesh-networking 'lora 'transport-agnostic)
     (layer-provides 'guix       'declarative-os 'reproducibility 'rollback))))

;;; ── The knowledge base ────────────────────────────────────────────────────

(define *system-kb*
  (make-kb
   (list (cons 'dependencies %dependencies)
         (cons 'files %files)
         (cons 'provides %provides))))

;;; ── Generic directed-fact relation ────────────────────────────────────────
;;; All three metagraphs share the same convention: head=from, tail=to.
;;; This one relation queries any of them.

(define (fact-o domain from to)
  "FROM relates to TO in DOMAIN (dependencies, files, or provides)."
  (fresh (mg arc n1 n2 id1 id2 m1 m2)
    (kb-o *system-kb* domain mg)
    (arcs-of-o mg arc)
    (directed-arc-o arc n1 n2)
    (node-o n1 id1 from m1)
    (node-o n2 id2 to m2)))

;;; ── Named query relations ───────────────────────────────────────────────
;;; Thin wrappers over fact-o for readability.

(define (depends-on-o from to)  (fact-o 'dependencies from to))
(define (file-of-o layer path)  (fact-o 'files layer path))
(define (provides-o layer cap)  (fact-o 'provides layer cap))

(define (layer-o name)
  "Is NAME a known layer?"
  (fresh (other) (depends-on-o name other)))

(define (trigger-chain-o start end proof)
  "Transitive chain from START to END through dependencies."
  (transitive-o *system-kb* 'dependencies start end proof))

;;; ── Pure Scheme queries ─────────────────────────────────────────────────

(define (query-depends layer)      (run* (q) (depends-on-o layer q)))
(define (query-layers)             (delete-duplicates (run 50 (q) (layer-o q))))
(define (query-files-for layer)    (run* (q) (file-of-o layer q)))
(define (query-provides layer)     (run* (q) (provides-o layer q)))
(define (query-what-changes trigger)
  (run 20 (q) (fresh (proof) (trigger-chain-o trigger q proof))))
