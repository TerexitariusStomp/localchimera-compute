;;; sne.scm — SNE as a relation
;;;
;;; The computation (recursive embodied labor) is in compute.scm.
;;; This module provides the relational interface: sne-o explores
;;; all recipes via conde, build-sne-index-o computes all at once.

(define-module (playnet deprecated planner relational sne)
  #:use-module (playnet deprecated planner relational compute)
  #:use-module (playnet deprecated planner relational planning-facts)
  #:export (sne-o build-sne-index-o))

(use-modules (playnet deprecated kanren-constraints))

(define (sne-o facts spec-id sne)
  "Relate spec to its SNE. Explores all recipes via conde."
  (fresh (rid rname)
    (recipe-o facts rid rname spec-id)
    (project (facts rid spec-id)
      (== sne (compute-recipe-sne facts rid spec-id '())))))

(define (build-sne-index-o facts index)
  "Compute SNE for all specs at once."
  (project (facts)
    (== index (build-sne-index facts))))
