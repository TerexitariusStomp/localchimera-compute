;;; module/playnet/tools/structural-edit.scm --- path-addressed structural editing ops
;;;
;;; Zipper-backed paredit-style operations over a tree of forms, as read
;;; by `read`. Every op takes a TREE plus a PATH — a list of 0-based
;;; child indices from the root — and returns a new tree. Nothing here
;;; ever emits text.
;;;
;;; Path convention: the root is the list of top-level forms itself, so
;;; path '(2) means "3rd top-level form", and path '(2 1 0) means "1st
;;; child of 2nd child of the 3rd top-level form".
;;;
;;; These ops fill a real gap: `tools/edit/sexp.scm` only replaces whole
;;; top-level forms by text-splicing (which is why it preserves
;;; comments). These operate BELOW that granularity, inside a form's own
;;; structure — slurp/barf/wrap/splice/raise, the moves paredit gives you
;;; in Emacs. That precision comes at a cost: re-serializing a tree
;;; produced here (via `form->string`/`write`) loses any comments that
;;; lived inside the span you touched, because Guile's `read` discards
;;; them. Treat these as REPL-driven tools for edits you'll review before
;;; writing — see [[project_scm_struct_agent_bringover]] — not as an
;;; automatic file-rewriting pipeline.

(define-module (playnet tools structural-edit)
  #:use-module (playnet tools zipper)
  #:use-module (srfi srfi-1)
  #:export (get-at-path
            replace-at-path
            edit-at-path
            insert-before-at-path
            insert-after-at-path
            append-child-at-path
            wrap-at-path
            splice-at-path
            slurp-forward-at-path
            barf-forward-at-path
            raise-at-path))

;; --- navigation helper ---------------------------------------------------

(define (zip-goto z path)
  (if (null? path)
      z
      (let loop ((z (zip-down z)) (n (car path)))
        (if (zero? n)
            (zip-goto z (cdr path))
            (loop (zip-right z) (- n 1))))))

;; --- whole-node ops --------------------------------------------------

;; Return the datum at PATH, without modifying TREE.
(define (get-at-path tree path)
  (zipper-node (zip-goto (make-zipper tree) path)))

;; Replace the node at PATH with NEW-NODE.
(define (replace-at-path tree path new-node)
  (zip-root (zip-replace (zip-goto (make-zipper tree) path) new-node)))

;; Replace the node at PATH with (PROC current-node).
(define (edit-at-path tree path proc)
  (zip-root (zip-edit (zip-goto (make-zipper tree) path) proc)))

;; --- sibling-insertion ops ---------------------------------------------

;; Insert NEW-NODE as a new sibling immediately before PATH.
(define (insert-before-at-path tree path new-node)
  (zip-root (zip-insert-left (zip-goto (make-zipper tree) path) new-node)))

;; Insert NEW-NODE as a new sibling immediately after PATH.
(define (insert-after-at-path tree path new-node)
  (zip-root (zip-insert-right (zip-goto (make-zipper tree) path) new-node)))

;; Append NEW-NODE as the new last child of the (list) node at PATH.
;; Use this for e.g. adding a new clause to a `cond`/`case` form, or a
;; new top-level form to the end of the file (path '() means "the
;; whole file").
(define (append-child-at-path tree path new-node)
  (edit-at-path tree path
                (lambda (node)
                  (if (list? node)
                      (append node (list new-node))
                      (error "append-child-at-path: not a proper list" node)))))

;; --- shape-changing ops --------------------------------------------------
;; The following operate on the PARENT list of the target, because they
;; change how many siblings exist at that level.

(define (edit-parent-at-path tree path proc)
  (when (null? path)
        (error "edit-parent-at-path: path has no parent (it is the root)"))
  (let ((parent-path (drop-right path 1))
        (idx (last path)))
    (edit-at-path tree parent-path (lambda (parent) (proc parent idx)))))

;; Wrap the node at PATH in (WRAPPER-SYMBOL node). E.g. wrap a bare
;; expression in a `when`, or a value in `(list ...)`.
;; wrap-at-path is a whole-node op (no arity change at the parent), but
;; grouped here since it is conceptually a "shape change" of the node.
(define (wrap-at-path tree path wrapper-symbol)
  (edit-at-path tree path (lambda (node) (list wrapper-symbol node))))

;; Unwrap: the node at PATH must be a proper list. Replace it, in its
;; parent, with its own elements spliced in place. Inverse of a
;; single-element wrap.
(define (splice-at-path tree path)
  (edit-parent-at-path
   tree path
   (lambda (parent idx)
     (let ((child (list-ref parent idx)))
       (unless (list? child)
         (error "splice-at-path: node to splice is not a proper list" child))
       (append (list-head parent idx) child (list-tail parent (+ idx 1)))))))

;; Paredit-style forward slurp: pull the sibling immediately following
;; the node at PATH into the node, as its new last element.
(define (slurp-forward-at-path tree path)
  (edit-parent-at-path
   tree path
   (lambda (parent idx)
     (when (>= (+ idx 1) (length parent))
       (error "slurp-forward-at-path: no following sibling to slurp"))
     (let* ((focus (list-ref parent idx))
            (next  (list-ref parent (+ idx 1))))
       (unless (list? focus)
         (error "slurp-forward-at-path: focus is not a proper list" focus))
       (append (list-head parent idx)
               (list (append focus (list next)))
               (list-tail parent (+ idx 2)))))))

;; Paredit-style forward barf: push the last element of the node at
;; PATH out, making it the node's next sibling instead.
(define (barf-forward-at-path tree path)
  (edit-parent-at-path
   tree path
   (lambda (parent idx)
     (let ((focus (list-ref parent idx)))
       (unless (and (list? focus) (pair? focus))
         (error "barf-forward-at-path: focus has nothing to barf" focus))
       (let* ((n (length focus))
              (last-elem (list-ref focus (- n 1)))
              (new-focus (list-head focus (- n 1))))
         (append (list-head parent idx)
                 (list new-focus last-elem)
                 (list-tail parent (+ idx 1))))))))

;; Raise: replace the PARENT of the node at PATH with the node itself,
;; discarding all its former siblings. Use to eliminate an unnecessary
;; wrapping form (e.g. collapse `(begin (foo))` to `(foo)`).
(define (raise-at-path tree path)
  (when (null? path)
    (error "raise-at-path: node at root has no parent to raise into"))
  (let ((node (get-at-path tree path))
        (parent-path (drop-right path 1)))
    (replace-at-path tree parent-path node)))
