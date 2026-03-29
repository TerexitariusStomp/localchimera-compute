;;; system-kb.scm — xorg's knowledge of its own structure
;;; The system describing itself as hyperarc facts, queryable via miniKanren.
;;; Hoot/WASM compatible.
;;;
;;; Usage:
;;;   (use-modules (xorg system-kb) (xorg knowledge) (xorg kanren))
;;;   (run* (q) (depends-on-o *system-kb* 'browser q))
;;;   (run* (proof) (transitive-o *system-kb* 'dependencies 'push-to-main 'kernel proof))

(define-module (xorg system-kb)
  #:use-module (xorg hyperarc)
  #:use-module (xorg kanren)
  #:use-module (xorg knowledge)
  #:use-module (srfi srfi-1)
  #:export (*system-kb*
            ;; Query helpers
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

;;; ── Node constructors ─────────────────────────────────────────────────────
;;; Thin wrappers for readable KB construction.

(define (layer-node name . meta)
  (make-node name name (if (null? meta) '() (car meta))))

(define (file-node path)
  (make-node (string->symbol path) path '()))

(define (concept-node name)
  (make-node name name '()))

;;; ── Dependency metagraph ──────────────────────────────────────────────────
;;; Directed arcs: head (first node) depends on tail (rest nodes).
;;; Convention matches hyperarc.scm: head = first, tail = rest.

(define %dependencies
  (make-metagraph
   'dependencies
   '((description . "What depends on what"))
   (list
    ;; Browser layer depends on evaluator, actors, kanren, hyperarc, knowledge
    (make-hyperarc 'dep-browser-eval '()
                   (list (layer-node 'browser) (layer-node 'evaluator)))
    (make-hyperarc 'dep-browser-actors '()
                   (list (layer-node 'browser) (layer-node 'actors)))
    (make-hyperarc 'dep-browser-kanren '()
                   (list (layer-node 'browser) (layer-node 'kanren)))
    (make-hyperarc 'dep-browser-hyperarc '()
                   (list (layer-node 'browser) (layer-node 'hyperarc)))
    (make-hyperarc 'dep-browser-knowledge '()
                   (list (layer-node 'browser) (layer-node 'knowledge)))

    ;; Knowledge depends on kanren and hyperarc
    (make-hyperarc 'dep-knowledge-kanren '()
                   (list (layer-node 'knowledge) (layer-node 'kanren)))
    (make-hyperarc 'dep-knowledge-hyperarc '()
                   (list (layer-node 'knowledge) (layer-node 'hyperarc)))

    ;; Evaluator depends on actors
    (make-hyperarc 'dep-eval-actors '()
                   (list (layer-node 'evaluator) (layer-node 'actors)))

    ;; Actors depend on goblins
    (make-hyperarc 'dep-actors-goblins '()
                   (list (layer-node 'actors) (layer-node 'goblins)))

    ;; Relay depends on goblins and signup-agent
    (make-hyperarc 'dep-relay-goblins '()
                   (list (layer-node 'relay) (layer-node 'goblins)))
    (make-hyperarc 'dep-relay-signup '()
                   (list (layer-node 'relay) (layer-node 'signup-agent)))

    ;; Signup-agent depends on goblins and provision
    (make-hyperarc 'dep-signup-goblins '()
                   (list (layer-node 'signup-agent) (layer-node 'goblins)))
    (make-hyperarc 'dep-signup-provision '()
                   (list (layer-node 'signup-agent) (layer-node 'provision)))

    ;; Provision depends on guix-deploy
    (make-hyperarc 'dep-provision-deploy '()
                   (list (layer-node 'provision) (layer-node 'guix-deploy)))

    ;; Planner depends on goblins
    (make-hyperarc 'dep-planner-goblins '()
                   (list (layer-node 'planner) (layer-node 'goblins)))

    ;; Key-pool depends on goblins
    (make-hyperarc 'dep-keypool-goblins '()
                   (list (layer-node 'key-pool) (layer-node 'goblins)))

    ;; Reticulum depends on goblins (OCapN netlayer)
    (make-hyperarc 'dep-reticulum-goblins '()
                   (list (layer-node 'reticulum) (layer-node 'goblins)))

    ;; Goblins depends on guile
    (make-hyperarc 'dep-goblins-guile '()
                   (list (layer-node 'goblins) (layer-node 'guile)))

    ;; Guile runs on guix
    (make-hyperarc 'dep-guile-guix '()
                   (list (layer-node 'guile) (layer-node 'guix)))

    ;; Guix controls the OS
    (make-hyperarc 'dep-guix-kernel '()
                   (list (layer-node 'guix) (layer-node 'kernel)))
    (make-hyperarc 'dep-guix-bootloader '()
                   (list (layer-node 'guix) (layer-node 'bootloader)))
    (make-hyperarc 'dep-guix-services '()
                   (list (layer-node 'guix) (layer-node 'services)))
    (make-hyperarc 'dep-guix-users '()
                   (list (layer-node 'guix) (layer-node 'users)))

    ;; Push-to-main triggers github-actions
    (make-hyperarc 'dep-push-actions '()
                   (list (layer-node 'push-to-main) (layer-node 'github-actions)))

    ;; Github-actions triggers guix-deploy
    (make-hyperarc 'dep-actions-deploy '()
                   (list (layer-node 'github-actions) (layer-node 'guix-deploy)))

    ;; Guix-deploy controls guix
    (make-hyperarc 'dep-deploy-guix '()
                   (list (layer-node 'guix-deploy) (layer-node 'guix))))))

;;; ── Files metagraph ───────────────────────────────────────────────────────
;;; Maps layers to their source files.

(define %files
  (make-metagraph
   'files
   '((description . "Which files belong to which layer"))
   (list
    (make-hyperarc 'files-actors '()
                   (list (layer-node 'actors)
                         (file-node "module/xorg/actors.scm")))
    (make-hyperarc 'files-evaluator '()
                   (list (layer-node 'evaluator)
                         (file-node "module/xorg/evaluator.scm")))
    (make-hyperarc 'files-repl-mod '()
                   (list (layer-node 'browser)
                         (file-node "module/xorg/repl.scm")))
    (make-hyperarc 'files-browser-repl '()
                   (list (layer-node 'browser)
                         (file-node "browser/repl.scm")))
    (make-hyperarc 'files-browser-js '()
                   (list (layer-node 'browser)
                         (file-node "browser/repl.js")))
    (make-hyperarc 'files-browser-html '()
                   (list (layer-node 'browser)
                         (file-node "browser/index.html")))
    (make-hyperarc 'files-kanren '()
                   (list (layer-node 'kanren)
                         (file-node "module/xorg/kanren.scm")))
    (make-hyperarc 'files-hyperarc '()
                   (list (layer-node 'hyperarc)
                         (file-node "module/xorg/hyperarc.scm")))
    (make-hyperarc 'files-knowledge '()
                   (list (layer-node 'knowledge)
                         (file-node "module/xorg/knowledge.scm")))
    (make-hyperarc 'files-system-kb '()
                   (list (layer-node 'system-kb)
                         (file-node "module/xorg/system-kb.scm")))
    (make-hyperarc 'files-relay '()
                   (list (layer-node 'relay)
                         (file-node "server/relay.scm")))
    (make-hyperarc 'files-signup '()
                   (list (layer-node 'signup-agent)
                         (file-node "server/signup-agent.scm")))
    (make-hyperarc 'files-deploy '()
                   (list (layer-node 'guix-deploy)
                         (file-node "deploy/guix/machines.scm")))
    (make-hyperarc 'files-deploy-sh '()
                   (list (layer-node 'guix-deploy)
                         (file-node "deploy/guix/deploy.sh")))
    (make-hyperarc 'files-users '()
                   (list (layer-node 'provision)
                         (file-node "deploy/guix/users.scm")))
    (make-hyperarc 'files-provision '()
                   (list (layer-node 'provision)
                         (file-node "deploy/guix/provision-user.scm")))
    (make-hyperarc 'files-channels '()
                   (list (layer-node 'guix-deploy)
                         (file-node "deploy/guix/channels.scm")))
    (make-hyperarc 'files-ci '()
                   (list (layer-node 'github-actions)
                         (file-node ".github/workflows/deploy.yml")))
    (make-hyperarc 'files-pages '()
                   (list (layer-node 'github-actions)
                         (file-node ".github/workflows/pages.yml")))
    (make-hyperarc 'files-planner '()
                   (list (layer-node 'planner)
                         (file-node "planner/lib/schemas.scm")))
    (make-hyperarc 'files-keypool '()
                   (list (layer-node 'key-pool)
                         (file-node "key-pool/key-pool.scm")))
    (make-hyperarc 'files-reticulum-scm '()
                   (list (layer-node 'reticulum)
                         (file-node "server/reticulum-bridge.py")))
    (make-hyperarc 'files-xorg-service '()
                   (list (layer-node 'services)
                         (file-node "deploy/guix/xorg-service.scm"))))))

;;; ── Provides metagraph ────────────────────────────────────────────────────
;;; What capabilities each layer provides.

(define %provides
  (make-metagraph
   'provides
   '((description . "What each layer provides"))
   (list
    (make-hyperarc 'prov-actors '()
                   (list (layer-node 'actors)
                         (concept-node 'state)
                         (concept-node 'accountability)
                         (concept-node 'revocation)))
    (make-hyperarc 'prov-evaluator '()
                   (list (layer-node 'evaluator)
                         (concept-node 'eval-in-browser)
                         (concept-node 'metacircular-eval)))
    (make-hyperarc 'prov-kanren '()
                   (list (layer-node 'kanren)
                         (concept-node 'relational-queries)
                         (concept-node 'unification)
                         (concept-node 'logic-programming)))
    (make-hyperarc 'prov-knowledge '()
                   (list (layer-node 'knowledge)
                         (concept-node 'transitive-closure)
                         (concept-node 'proof-traces)
                         (concept-node 'pattern-matching)))
    (make-hyperarc 'prov-goblins '()
                   (list (layer-node 'goblins)
                         (concept-node 'capability-security)
                         (concept-node 'actors)
                         (concept-node 'ocapn)
                         (concept-node 'persistence)))
    (make-hyperarc 'prov-reticulum '()
                   (list (layer-node 'reticulum)
                         (concept-node 'mesh-networking)
                         (concept-node 'lora)
                         (concept-node 'transport-agnostic)))
    (make-hyperarc 'prov-guix '()
                   (list (layer-node 'guix)
                         (concept-node 'declarative-os)
                         (concept-node 'reproducibility)
                         (concept-node 'rollback))))))

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
