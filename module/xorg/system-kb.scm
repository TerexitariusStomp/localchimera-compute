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
            ;; Query relations
            depends-on-o
            layer-o
            file-of-o
            provides-o
            trigger-chain-o
            ;; Convenience (pure Scheme)
            query-depends
            query-layers
            query-what-changes
            query-files-for))

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

;;; ── Query relations ───────────────────────────────────────────────────────
;;; Convenience relations that query across metagraphs.

(define (depends-on-o from-layer to-layer)
  "Direct dependency: from-layer depends on to-layer."
  (fresh (arc n1 n2 id1 id2 m1 m2 mg)
    (kb-o *system-kb* 'dependencies mg)
    (arcs-of-o mg arc)
    (directed-arc-o arc n1 n2)
    (node-o n1 id1 from-layer m1)
    (node-o n2 id2 to-layer m2)))

(define (layer-o name)
  "Is name a known layer in the dependency graph?"
  (fresh (arc n id meta mg nodes)
    (kb-o *system-kb* 'dependencies mg)
    (arcs-of-o mg arc)
    (arc-nodes-o arc n)
    (node-o n id name meta)))

(define (file-of-o layer-name file-path)
  "Relate a layer to one of its source files."
  (fresh (arc n1 n2 id1 id2 m1 m2 mg)
    (kb-o *system-kb* 'files mg)
    (arcs-of-o mg arc)
    (directed-arc-o arc n1 n2)
    (node-o n1 id1 layer-name m1)
    (node-o n2 id2 file-path m2)))

(define (provides-o layer-name capability)
  "What capabilities does a layer provide?"
  (fresh (arc head rest-node mg hid hmeta nodes)
    (kb-o *system-kb* 'provides mg)
    (arcs-of-o mg arc)
    (hyperarc-o arc hid hmeta nodes)
    (fresh (n1 n2 id1 id2 m1 m2 rest)
      (== nodes (cons n1 rest))
      (node-o n1 id1 layer-name m1)
      (membero n2 rest)
      (node-o n2 id2 capability m2))))

(define (trigger-chain-o start end proof)
  "Transitive chain from start to end in the dependency graph."
  (transitive-o *system-kb* 'dependencies start end proof))

;;; ── Pure Scheme convenience queries ───────────────────────────────────────
;;; For use outside miniKanren (e.g., REPL display helpers).

(define (query-depends layer)
  "What does LAYER directly depend on?"
  (run* (q) (depends-on-o layer q)))

(define (query-layers)
  "All known layers."
  (delete-duplicates (run 50 (q) (layer-o q))))

(define (query-what-changes trigger)
  "What can TRIGGER ultimately affect? Returns proof-traced chains."
  (run 20 (q)
    (fresh (proof)
      (trigger-chain-o trigger q proof))))

(define (query-files-for layer)
  "Source files belonging to LAYER."
  (run* (q) (file-of-o layer q)))
