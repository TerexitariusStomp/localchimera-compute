;;; remote-transport.scm — Snapshot/hydrate for cross-scope data sync

(use-modules (srfi srfi-1))

(define (snapshot-store plan-store)
  "Serialize a plan-store actor into a portable snapshot alist."
  `((plans . ,($ plan-store 'all-plans))
    (commitments . ,($ plan-store 'all-commitments))
    (intents . ,($ plan-store 'all-intents))
    (claims . ,($ plan-store 'all-claims))))

(define (hydrate-store snapshot plan-store)
  "Hydrate a plan-store actor from a snapshot alist.
   Adds all records from snapshot into the target plan-store."
  (for-each (lambda (p) ($ plan-store 'add-plan p))
            (or (assq-ref snapshot 'plans) '()))
  (for-each (lambda (c) ($ plan-store 'add-commitment c))
            (or (assq-ref snapshot 'commitments) '()))
  (for-each (lambda (i) ($ plan-store 'add-intent i))
            (or (assq-ref snapshot 'intents) '())))
