;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/tools/zipper.scm --- generic zipper over Scheme s-expression trees
;;;
;;; A zipper is a pointer into a tree that supports O(1) local moves
;;; (down/up/left/right) and O(1) local edits (replace/insert/remove),
;;; without ever touching source text. `(playnet tools structural-edit)`
;;; is built entirely on top of this.
;;;
;;; A tree node is any Scheme datum. A node is "branching" iff it is a
;;; pair whose structure is a proper or improper list — i.e. anything
;;; satisfying `list?` or `pair?`. Atoms (symbols, numbers, strings,
;;; booleans, the empty list) are leaves and cannot be zipped into.
;;;
;;; A zipper is a record `(zipper node context)`, where `node` is the
;;; datum currently focused, and `context` is either 'top (root) or a
;;; crumb `(lefts rights parent-context parent-node)`. This is the
;;; standard Huet zipper, specialized to Scheme lists.
;;;
;;; Brought over from docs/scm-struct-agent/tools/zipper.scm — see
;;; [[project_scm_struct_agent_bringover]] for why this landed as a
;;; library rather than an automatic file-rewriting CLI: it operates on
;;; parsed trees, and `read` discards every comment, so re-serializing a
;;; whole file through it would silently strip documentation. Use it for
;;; precise sub-form addressing and REPL-driven edits you'll review
;;; before writing, not as a drop-in replacement for `tools/edit/sexp.scm`'s
;;; comment-preserving text-splice `replace`.

(define-module (playnet tools zipper)
  #:use-module (srfi srfi-9)
  #:export (make-zipper
            zipper?
            zipper-node
            zip-top?
            zip-down
            zip-up
            zip-left
            zip-right
            zip-leftmost
            zip-rightmost
            zip-replace
            zip-edit
            zip-insert-left
            zip-insert-right
            zip-insert-child
            zip-remove
            zip-root
            zip-path
            zip-child-index
            zip-find-down))

;; --- record types ------------------------------------------------------

(define-record-type <zipper>
  (make-zipper* node context)
  zipper?
  (node    zipper-node)
  (context zipper-context))

(define-record-type <crumb>
  (make-crumb lefts rights parent-context parent-node)
  crumb?
  (lefts  crumb-lefts)          ; siblings to the left, REVERSED
  (rights crumb-rights)         ; siblings to the right, in order
  (parent-context crumb-parent-context)
  (parent-node crumb-parent-node)) ; original parent, for improper-list tail

;; --- construction --------------------------------------------------------

;; Create a zipper focused on the root of TREE.
(define (make-zipper tree)
  (make-zipper* tree 'top))

(define (zip-top? z)
  (eq? (zipper-context z) 'top))

;; --- navigation ------------------------------------------------------

;; Move down into the first child of the focused node.
;; Errors if the focused node is not a pair (has no children).
(define (zip-down z)
  (let ((node (zipper-node z)))
    (if (not (pair? node))
        (error "zip-down: node has no children" node)
        (make-zipper* (car node)
                      (make-crumb '() (cdr node) (zipper-context z) node)))))

;; Move up to the parent, re-assembling the parent node from the
;; current siblings (so any edits made while focused below are folded
;; back in).
(define (zip-up z)
  (let ((ctx (zipper-context z)))
    (if (eq? ctx 'top)
        (error "zip-up: already at top")
        (let* ((lefts (crumb-lefts ctx))
               (rights (crumb-rights ctx))
               (rebuilt (append (reverse lefts) (cons (zipper-node z) rights))))
          (make-zipper* rebuilt (crumb-parent-context ctx))))))

;; Move to the left sibling.
(define (zip-left z)
  (let ((ctx (zipper-context z)))
    (if (or (eq? ctx 'top) (null? (crumb-lefts ctx)))
        (error "zip-left: no left sibling")
        (make-zipper* (car (crumb-lefts ctx))
                      (make-crumb (cdr (crumb-lefts ctx))
                                  (cons (zipper-node z) (crumb-rights ctx))
                                  (crumb-parent-context ctx)
                                  (crumb-parent-node ctx))))))

;; Move to the right sibling.
(define (zip-right z)
  (let ((ctx (zipper-context z)))
    (if (or (eq? ctx 'top) (null? (crumb-rights ctx)) (not (pair? (crumb-rights ctx))))
        (error "zip-right: no right sibling")
        (make-zipper* (car (crumb-rights ctx))
                      (make-crumb (cons (zipper-node z) (crumb-lefts ctx))
                                  (cdr (crumb-rights ctx))
                                  (crumb-parent-context ctx)
                                  (crumb-parent-node ctx))))))

(define (zip-leftmost z)
  (if (or (zip-top? z) (null? (crumb-lefts (zipper-context z))))
      z
      (zip-leftmost (zip-left z))))

(define (zip-rightmost z)
  (let ((ctx (zipper-context z)))
    (if (or (zip-top? z) (null? (crumb-rights ctx)) (not (pair? (crumb-rights ctx))))
        z
        (zip-rightmost (zip-right z)))))

;; --- editing -----------------------------------------------------------

;; Replace the focused node with NEW-NODE.
(define (zip-replace z new-node)
  (make-zipper* new-node (zipper-context z)))

;; Apply PROC to the focused node's datum, replacing it with the result.
(define (zip-edit z proc)
  (zip-replace z (proc (zipper-node z))))

;; Insert NEW-NODE as a new left sibling of the focus. Focus does not move.
(define (zip-insert-left z new-node)
  (let ((ctx (zipper-context z)))
    (if (eq? ctx 'top)
        (error "zip-insert-left: no parent to insert a sibling into")
        (make-zipper* (zipper-node z)
                      (make-crumb (cons new-node (crumb-lefts ctx))
                                  (crumb-rights ctx)
                                  (crumb-parent-context ctx)
                                  (crumb-parent-node ctx))))))

;; Insert NEW-NODE as a new right sibling of the focus. Focus does not move.
(define (zip-insert-right z new-node)
  (let ((ctx (zipper-context z)))
    (if (eq? ctx 'top)
        (error "zip-insert-right: no parent to insert a sibling into")
        (make-zipper* (zipper-node z)
                      (make-crumb (crumb-lefts ctx)
                                  (cons new-node (crumb-rights ctx))
                                  (crumb-parent-context ctx)
                                  (crumb-parent-node ctx))))))

;; Insert NEW-NODE as the new first child of the focus, moving focus
;; down onto it. Errors if focus is not a pair-or-nil.
(define (zip-insert-child z new-node)
  (let ((node (zipper-node z)))
    (cond
     ((null? node) (zip-down (zip-replace z (list new-node))))
     ((pair? node) (zip-down (zip-replace z (cons new-node node))))
     (else (error "zip-insert-child: node cannot have children" node)))))

;; Remove the focused node, moving focus to the left sibling (or the
;; right sibling if there is no left sibling, or up if it was the only
;; child).
(define (zip-remove z)
  (let ((ctx (zipper-context z)))
    (if (eq? ctx 'top)
        (error "zip-remove: cannot remove the root")
        (cond
         ((pair? (crumb-lefts ctx))
          (make-zipper* (car (crumb-lefts ctx))
                        (make-crumb (cdr (crumb-lefts ctx))
                                    (crumb-rights ctx)
                                    (crumb-parent-context ctx)
                                    (crumb-parent-node ctx))))
         ((pair? (crumb-rights ctx))
          (make-zipper* (car (crumb-rights ctx))
                        (make-crumb '()
                                    (cdr (crumb-rights ctx))
                                    (crumb-parent-context ctx)
                                    (crumb-parent-node ctx))))
         (else
          ;; No siblings at all: go up to an empty-listed parent.
          (make-zipper* '() (crumb-parent-context ctx)))))))

;; --- whole-tree access ---------------------------------------------------

;; Reassemble all the way up to the root and return the resulting tree.
(define (zip-root z)
  (if (zip-top? z) (zipper-node z) (zip-root (zip-up z))))

;; Return the path from the root to the focus as a list of child
;; indices, e.g. (2 0) means "third child of root, then first child
;; of that". Useful for logging/addressing edits.
(define (zip-path z)
  (let loop ((z z) (acc '()))
    (if (zip-top? z)
        acc
        (loop (zip-up z) (cons (zip-child-index z) acc)))))

;; Index of the focused node among its siblings (0-based).
(define (zip-child-index z)
  (let ((ctx (zipper-context z)))
    (if (eq? ctx 'top) 0 (length (crumb-lefts ctx)))))

;; Move down and then right until PRED is true of the focused node, or
;; return #f if no child satisfies it. Does not recurse into
;; grandchildren — combine with zip-down for deeper search.
(define (zip-find-down z pred)
  (and (pair? (zipper-node z))
       (let loop ((c (zip-down z)))
         (cond
          ((pred (zipper-node c)) c)
          ((null? (crumb-rights (zipper-context c))) #f)
          (else (loop (zip-right c)))))))
