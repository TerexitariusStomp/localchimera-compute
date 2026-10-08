;;; module/playnet/utils/hashmap.scm — hashmap helpers missing from Goblins
;;;
;;; Goblins' (goblins utils hashmap) exports hashmap-fold but not
;;; hashmap-keys or hashmap-values. These are needed by the fleet
;;; reconciler and were duplicated from the planner's store-utils.scm.

(define-module (playnet utils hashmap)
  #:use-module (goblins utils hashmap)
  #:export (hashmap-keys
            hashmap-values))

(define (hashmap-keys hm)
  "Return a list of all keys in the hashmap."
  (reverse (hashmap-fold (lambda (k _v acc) (cons k acc)) '() hm)))

(define (hashmap-values hm)
  "Return a list of all values in the hashmap."
  (reverse (hashmap-fold (lambda (_k v acc) (cons v acc)) '() hm)))
