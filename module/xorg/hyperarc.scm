;;; hyperarc.scm — Hyperarc/metagraph/knowledge-base data structures for xorg
;;; Plain tagged S-expression alists — homoiconic, unifiable, serializable.
;;; Hoot/WASM compatible: positional constructors, no keywords, no GOOPS.

(define-module (xorg hyperarc)
  #:use-module (srfi srfi-1)
  #:export (;; Constructors
            make-node make-hyperarc make-metagraph make-kb
            ;; Accessors
            node-id node-value node-meta
            hyperarc-id hyperarc-meta hyperarc-nodes
            metagraph-id metagraph-meta metagraph-arcs
            kb-entries kb-ref kb-keys
            ;; Predicates
            node? hyperarc? metagraph? kb?
            ;; Builders
            kb-add kb-merge
            ;; Traversal
            metagraph-all-nodes metagraph-node-values
            hyperarc-find-node
            ;; ID generation
            make-hyperarc-id))

;;; ── ID generation ──────────────────────────────────────────────────────────

(define *hyperarc-id-counter* 0)

(define (make-hyperarc-id prefix)
  (set! *hyperarc-id-counter* (+ *hyperarc-id-counter* 1))
  (string->symbol
   (string-append (symbol->string prefix) "-"
                  (number->string *hyperarc-id-counter*))))

;;; ── Node ───────────────────────────────────────────────────────────────────
;;; Representation: (node (id . <sym>) (value . <any>) (meta . <alist>))
;;; The value can be any S-expression, including a metagraph (recursive).

(define (make-node id value . rest)
  (let ((meta (if (null? rest) '() (car rest))))
    `(node (id . ,id) (value . ,value) (meta . ,meta))))

(define (node? x)
  (and (pair? x) (eq? (car x) 'node)))

(define (node-id n)
  (let ((entry (assq 'id (cdr n))))
    (and entry (cdr entry))))

(define (node-value n)
  (let ((entry (assq 'value (cdr n))))
    (and entry (cdr entry))))

(define (node-meta n)
  (let ((entry (assq 'meta (cdr n))))
    (and entry (cdr entry))))

;;; ── Hyperarc ───────────────────────────────────────────────────────────────
;;; Representation: (hyperarc (id . <sym>) (meta . <alist>) (nodes . <list>))
;;; Nodes are ordered — by convention head = first, tail = rest.

(define (make-hyperarc id meta nodes)
  `(hyperarc (id . ,id) (meta . ,meta) (nodes . ,nodes)))

(define (hyperarc? x)
  (and (pair? x) (eq? (car x) 'hyperarc)))

(define (hyperarc-id h)
  (let ((entry (assq 'id (cdr h))))
    (and entry (cdr entry))))

(define (hyperarc-meta h)
  (let ((entry (assq 'meta (cdr h))))
    (and entry (cdr entry))))

(define (hyperarc-nodes h)
  (let ((entry (assq 'nodes (cdr h))))
    (and entry (cdr entry))))

;;; ── Metagraph ──────────────────────────────────────────────────────────────
;;; Representation: (metagraph (id . <sym>) (meta . <alist>) (arcs . <list>))
;;; A named collection of hyperarcs. Recursive: node values can be metagraphs.

(define (make-metagraph id meta arcs)
  `(metagraph (id . ,id) (meta . ,meta) (arcs . ,arcs)))

(define (metagraph? x)
  (and (pair? x) (eq? (car x) 'metagraph)))

(define (metagraph-id m)
  (let ((entry (assq 'id (cdr m))))
    (and entry (cdr entry))))

(define (metagraph-meta m)
  (let ((entry (assq 'meta (cdr m))))
    (and entry (cdr entry))))

(define (metagraph-arcs m)
  (let ((entry (assq 'arcs (cdr m))))
    (and entry (cdr entry))))

;;; ── Knowledge base ─────────────────────────────────────────────────────────
;;; Representation: (kb (name . <metagraph>) ...)
;;; An association list of named metagraphs.

(define (make-kb entries)
  (cons 'kb entries))

(define (kb? x)
  (and (pair? x) (eq? (car x) 'kb)))

(define (kb-entries kb)
  (cdr kb))

(define (kb-ref kb name)
  (let ((entry (assq name (cdr kb))))
    (and entry (cdr entry))))

(define (kb-keys kb)
  (map car (cdr kb)))

(define (kb-add kb name metagraph)
  (cons 'kb (cons (cons name metagraph) (cdr kb))))

(define (kb-merge kb1 kb2)
  (cons 'kb (append (cdr kb1) (cdr kb2))))

;;; ── Traversal utilities ────────────────────────────────────────────────────

(define (metagraph-all-nodes mg)
  "Collect all nodes from all arcs in a metagraph (may contain duplicates)."
  (apply append (map hyperarc-nodes (metagraph-arcs mg))))

(define (metagraph-node-values mg)
  "Get all node values from a metagraph."
  (map node-value (metagraph-all-nodes mg)))

(define (hyperarc-find-node ha target-id)
  "Find a node in a hyperarc by its id."
  (let loop ((nodes (hyperarc-nodes ha)))
    (cond
     ((null? nodes) #f)
     ((eq? (node-id (car nodes)) target-id) (car nodes))
     (else (loop (cdr nodes))))))
