;;; index-utils.scm — Shared utilities for building query indexes
;;;
;;; Pattern: build a hashmap of (key -> list-of-ids), then query by key.

(use-modules (srfi srfi-1) (goblins utils hashmap))

(define (build-index items id-fn key-fns)
  "Generic index builder. items: list. id-fn: item -> id.
   key-fns: alist of (index-name . (item -> key-or-#f)).
   Returns alist of (index-name . hashmap-of-key->id-list)."
  (let ((indexes (map (lambda (kf) (cons (car kf) (hashmap))) key-fns)))
    (for-each
      (lambda (item)
        (let ((id (id-fn item)))
          (for-each
            (lambda (kf-entry idx-entry)
              (let* ((key-fn (cdr kf-entry))
                     (key (key-fn item)))
                (when key
                  (let* ((idx (cdr idx-entry))
                         (existing (hashmap-ref idx key '())))
                    (set-cdr! idx-entry
                      (hashmap-set idx key (cons id existing)))))))
            key-fns indexes)))
      items)
    indexes))

(define (index-query index-alist index-name key items-map)
  "Query an index: look up key in named index, resolve IDs from items-map."
  (let ((idx (assq-ref index-alist index-name)))
    (if (not idx) '()
        (filter-map (lambda (id) (hashmap-ref items-map id #f))
                    (hashmap-ref idx key '())))))
