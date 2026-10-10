;;; module/playnet/tools/edit/scm-index.scm --- symbol index over a tree of top-level forms
;;;
;;; Scope/shadow-aware queries over a list of forms as read by `read`:
;;; where a name is defined, everywhere it's genuinely referenced (not
;;; shadowed by a local binding), and which top-level defines share an
;;; identical body shape (copy-paste candidates). This is architectural
;;; awareness on top of `tools/edit/sexp.scm`'s pure text scanning — use
;;; `find-callers` before changing a signature, `find-duplicate-shapes`
;;; before writing a helper that might already exist.
;;;
;;; Ported from docs/scm-struct-agent/tools/index.scm — see
;;; [[project_scm_struct_agent_bringover]].

(define-module (playnet tools scm-index)
  #:use-module (srfi srfi-1)
  #:export (find-def
            find-callers
            list-defines
            shape-of
            find-duplicate-shapes))

;; Return the top-level index of the (define (NAME ...) ...) or
;; (define NAME ...) form for symbol NAME, or #f if not found.
(define (find-def forms name)
  (let loop ((forms forms) (i 0))
    (cond
     ((null? forms) #f)
     ((defines? (car forms) name) i)
     (else (loop (cdr forms) (+ i 1))))))

(define (defines? form name)
  (and (pair? form)
       (memq (car form) '(define define-public define*))
       (pair? (cdr form))
       (let ((target (cadr form)))
         (eq? name (if (pair? target) (car target) target)))))

;; Return a list of paths (top-level-index . sub-path) at which NAME
;; appears anywhere in FORMS as a genuine reference to the top-level
;; definition of that name — excluding: the definition's own binder
;; slot, any occurrence shadowed by an enclosing lambda parameter,
;; let/let*/letrec/letrec*/named-let binding, or internal (define ...)
;; of the same name, and any occurrence inside quoted data. Recursive
;; self-calls within the definition's own body ARE included, since
;; those are real call sites that need updating on a signature change.
;;
;; This is still a syntactic search, not a fully hygiene-aware
;; analysis: it does not understand macros, `do` loops, `case-lambda`,
;; quasiquote/unquote, or default-value expressions in optional/
;; keyword lambda arguments. Those are rare enough in practice that
;; treating them as generic subforms (no special shadow tracking) is
;; an acceptable approximation — but don't treat this as a real
;; compiler-grade binding analysis for anything safety-critical.
(define (find-callers forms name)
  (append-map
   (lambda (form idx)
     (map (lambda (subpath) (cons idx subpath))
          (occurrences form name)))
   forms (iota (length forms))))

(define binding-forms '(let let* letrec letrec*))

;; Extract the bound symbol names from a lambda/define formals spec:
;; a proper list, an improper (dotted) list ending in a rest-arg
;; symbol, a bare rest-arg symbol, or optional/keyword entries of the
;; form (var default) — default-value expressions are not walked for
;; occurrences (a known, documented limitation above).
(define (flatten-formals formals)
  (cond
   ((symbol? formals) (list formals))
   ((null? formals) '())
   ((pair? formals)
    (let ((h (car formals)))
      (append (cond ((symbol? h) (list h))
                    ((pair? h) (list (car h)))
                    (else '()))
              (flatten-formals (cdr formals)))))
   (else '())))

;; Walk FORM collecting relative paths at which NAME occurs as a
;; genuine (unshadowed) reference. ROOT? marks the outermost call, so
;; the definition's own header slot at path '(1) is recognized and
;; skipped without introducing a shadow (a self-recursive call in the
;; body is a real occurrence, not a shadowed one).
(define (occurrences form name)
  (define (walk node path shadowed? acc root?)
    (cond
     ((and root? (equal? path '(1))) acc)
     ((symbol? node)
      (if (and (eq? node name) (not shadowed?)) (cons (reverse path) acc) acc))
     ((not (pair? node)) acc)
     ((eq? (car node) 'quote) acc)
     ((and (eq? (car node) 'lambda) (pair? (cdr node)))
      (let* ((new-shadow (or shadowed?
                              (and (memq name (flatten-formals (cadr node))) #t))))
        (walk-seq (cddr node) path 2 new-shadow acc)))
     ((and (memq (car node) '(define define-public define*)) (pair? (cdr node)))
      (let* ((target (cadr node))
             (formal-shadow (and (pair? target)
                                  (memq name (flatten-formals (cdr target)))
                                  #t)))
        (cond
         ((pair? target) (walk-seq (cddr node) path 2 (or shadowed? formal-shadow) acc))
         ((pair? (cddr node)) (walk (caddr node) (cons 2 path) (or shadowed? formal-shadow) acc #f))
         (else acc))))
     ((memq (car node) binding-forms)
      (let* ((kind (car node))
             (named? (and (eq? kind 'let) (pair? (cdr node)) (symbol? (cadr node))))
             (loop-name (and named? (cadr node)))
             (bindings-idx (if named? 2 1))
             (bindings (if named? (caddr node) (cadr node)))
             (body-idx (if named? 3 2))
             (body (if named? (cdddr node) (cddr node)))
             (vars (map (lambda (b) (if (pair? b) (car b) b)) bindings))
             (all-shadow (or shadowed? (and (memq name vars) #t)
                              (and named? (eq? loop-name name)))))
        (let loop2 ((bs bindings) (i 0) (running-shadow shadowed?) (acc acc))
          (if (null? bs)
              (walk-seq body path body-idx all-shadow acc)
              (let* ((b (car bs))
                     (val-expr (and (pair? b) (pair? (cdr b)) (cadr b)))
                     (val-shadow (case kind
                                   ((let) shadowed?)
                                   ((let*) running-shadow)
                                   (else all-shadow))) ; letrec, letrec*
                     (acc2 (if val-expr
                               (walk val-expr (cons* 1 i bindings-idx path) val-shadow acc #f)
                               acc))
                     (next-shadow (if (eq? kind 'let*)
                                       (or running-shadow (and (pair? b) (eq? (car b) name)))
                                       running-shadow)))
                (loop2 (cdr bs) (+ i 1) next-shadow acc2))))))
     (else (walk-seq node path 0 shadowed? acc))))

  ;; Walk sibling FORMS (a proper or improper list), whose first
  ;; element sits at START-IDX within the node at PATH. Threads
  ;; SHADOWED? left-to-right so an internal (define X ...) shadows
  ;; subsequent siblings but not earlier ones or itself-as-a-header.
  (define (walk-seq forms path start-idx shadowed? acc)
    (let loop ((forms forms) (i start-idx) (sh shadowed?) (acc acc))
      (if (not (pair? forms))
          acc
          (let* ((form (car forms))
                 (acc2 (walk form (cons i path) sh acc #f))
                 (new-sh (if (and (pair? form)
                                   (memq (car form) '(define define-public define*))
                                   (pair? (cdr form)))
                             (let* ((target (cadr form))
                                    (bname (if (pair? target) (car target) target)))
                               (or sh (eq? bname name)))
                             sh)))
            (loop (cdr forms) (+ i 1) new-sh acc2)))))

  (reverse (walk form '() #f '() #t)))

;; List (name . top-level-index) for every top-level define in FORMS,
;; in file order.
(define (list-defines forms)
  (filter-map
   (lambda (form idx)
     (and (pair? form)
          (memq (car form) '(define define-public define*))
          (let ((target (cadr form)))
            (cons (if (pair? target) (car target) target) idx))))
   forms (iota (length forms))))

;; Abstract a form's "shape": same tree structure with every leaf atom
;; replaced by its type (symbol/number/string/other), so two
;; differently-named functions with identical logic collapse to the
;; same shape. Used to flag likely copy-paste duplication.
(define (shape-of form)
  (cond
   ((pair? form) (cons (shape-of (car form)) (shape-of (cdr form))))
   ((null? form) '())
   ((symbol? form) 'sym)
   ((number? form) 'num)
   ((string? form) 'str)
   (else 'atom)))

;; Return a list of ((name1 . idx1) (name2 . idx2) ...) groups of
;; top-level defines whose bodies (cddr form, i.e. everything after
;; the signature) share an identical shape — candidates for being
;; genuine duplicates that should be unified via extract-function
;; rather than left as two copies.
(define (find-duplicate-shapes forms)
  (let* ((defs (list-defines forms))
         (with-shape (map (lambda (nd)
                             (cons (shape-of (cddr (list-ref forms (cdr nd))))
                                   nd))
                           defs))
         (groups (fold (lambda (entry table)
                          (let* ((key (car entry)) (nd (cdr entry))
                                 (existing (assoc key table)))
                            (if existing
                                (begin (set-cdr! existing (cons nd (cdr existing)))
                                       table)
                                (cons (cons key (list nd)) table))))
                        '() with-shape)))
    (filter-map (lambda (g) (and (> (length (cdr g)) 1) (cdr g))) groups)))
