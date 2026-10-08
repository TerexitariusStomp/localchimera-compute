;;; aggregation/containment.scm — the OTHER tree, walked once.
;;;
;;; The federation tree is not the only hierarchy this system climbs. Places and
;;; resources carry `contained-in`: a room inside a venue inside a commune, an
;;; oven inside a flat, a farm inside a watershed inside a biosphere. Enough of
;;; the codebase climbs it that the climb kept being written again — each site
;;; with its own id-map, its own cycle guard, its own depth cap, and its own
;;; answer to "what if the parent is missing".
;;;
;;; This is that climb, once:
;;;
;;;   containment-chain   every ancestor, nearest first
;;;   containment-first   the nearest ancestor (or self) an answer can be read from
;;;
;;; Both take PARENT-OF (record → parent id or #f) and RESOLVE (id → record or
;;; #f), so they serve <spatial-thing> and <economic-resource> alike without
;;; either type being named here. Both are cycle-safe: a containment loop (a
;;; malformed graph, or a legitimate DAG traversed twice) terminates at its
;;; first repeat rather than hanging the solve, and a depth cap bounds a chain
;;; nothing else bounds.
;;;
;;; The sibling of aggregation/scope-tree.scm: that walks the tree membership
;;; makes, this walks the tree containment makes.

(define-module (playnet planner aggregation containment)
  #:use-module (srfi srfi-1)
  #:export (containment-chain containment-first))

(define %max-depth 64)

(define* (containment-chain item #:key parent-of resolve (max-depth %max-depth))
  "Every ancestor of ITEM by `contained-in`, NEAREST FIRST. PARENT-OF reads a
   record's parent id; RESOLVE turns an id into a record. Stops at the first id
   that repeats (so a cycle terminates), at a parent that cannot be resolved
   (a container held elsewhere, or a dangling id), or at MAX-DEPTH."
  (let loop ((id (and item (parent-of item))) (seen '()) (acc '()) (d 0))
    (if (or (not id) (member id seen) (>= d max-depth))
        (reverse acc)
        (let ((parent (resolve id)))
          (if (not parent)
              (reverse acc)
              (loop (parent-of parent) (cons id seen) (cons parent acc) (+ d 1)))))))

(define* (containment-first item pred #:key parent-of resolve
                            (include-self? #t) (max-depth %max-depth))
  "The nearest record at or above ITEM for which PRED returns a true value —
   and that value, not the record, since every caller wants what it read (a
   location, a bioregion, a socialized root) rather than where it read it.
   #f when nothing in the chain answers. INCLUDE-SELF? starts at ITEM."
  (let loop ((xs (append (if include-self? (list item) '())
                         (containment-chain item #:parent-of parent-of
                                            #:resolve resolve
                                            #:max-depth max-depth))))
    (and (pair? xs)
         (or (and (car xs) (pred (car xs)))
             (loop (cdr xs))))))
