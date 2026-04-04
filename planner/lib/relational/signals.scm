;;; signals.scm — Signal↔Intent (maximally relational)
;;;
;;; signal-tag-o, signal-action-o, signal-category-o: fully relational
;;;   (bidirectional lookup via conde — no project needed).
;;; Conversion uses project only for string operations (iid generation).

(use-modules (playnet kanren-constraints))

(define *signal-tags*
  '((signal-tag deficit       "tag:plan:deficit")
    (signal-tag surplus       "tag:plan:surplus")
    (signal-tag conservation  "tag:plan:conservation")
    (signal-tag replenishment "tag:plan:replenishment")
    (signal-tag metabolic-debt "tag:plan:metabolic-debt")
    (signal-tag offer         "tag:plan:offer")
    (signal-tag request       "tag:plan:request")))

(define (signal-tag-o kind tag)
  "Relational: relate signal kind ↔ tag string. Any direction."
  (in-list-o `(signal-tag ,kind ,tag) *signal-tags*))

(define (signal-action-o kind action)
  "Relational: relate signal kind ↔ VF action. Any direction.
   'What action does a deficit signal imply?' AND
   'What signal kinds map to transfer?'"
  (conde
    ((== kind 'deficit) (== action 'transfer))
    ((== kind 'conservation) (== action 'transfer))
    ((== kind 'replenishment) (== action 'produce))
    ((== kind 'surplus) (== action 'transfer))
    ((== kind 'metabolic-debt) (== action 'transfer))
    ((== kind 'offer) (== action 'transfer))
    ((== kind 'request) (== action 'transfer))))

(define (signal-category-o kind input-of output-of)
  "Relational: relate signal kind ↔ input/output classification.
   'Is a deficit signal an input or output?' AND
   'What signal kinds are inputs?'"
  (conde
    ((== kind 'deficit) (== input-of 'input) (== output-of #f))
    ((== kind 'conservation) (== input-of 'input) (== output-of #f))
    ((== kind 'replenishment) (== input-of #f) (== output-of 'output))
    ((== kind 'surplus) (== input-of #f) (== output-of 'output))
    ((== kind 'metabolic-debt) (== input-of #f) (== output-of #f))
    ((== kind 'offer) (== input-of #f) (== output-of #f))
    ((== kind 'request) (== input-of #f) (== output-of #f))))

(define (signal-o kind spec-id qty source signal)
  (== signal `((kind . ,kind) (spec-id . ,spec-id) (qty . ,qty) (source . ,source))))

(define (signal->intent-o signal plan-id intent-fact meta-fact)
  "Convert signal to intent + metadata. Relational dispatch for kind->action,
   project only for string ops (iid, tag lookup, meta extraction)."
  (fresh (kind spec qty src tag action input-of output-of rest)
    ;; Relational structure extraction
    (== signal `((kind . ,kind) (spec-id . ,spec) (qty . ,qty) (source . ,src) . ,rest))
    ;; Relational dispatch — works backwards too
    (signal-tag-o kind tag)
    (signal-action-o kind action)
    (signal-category-o kind input-of output-of)
    ;; Ground ops: string concatenation for iid, meta extraction
    (project (kind spec plan-id signal)
      (let* ((meta (or (assq-ref signal 'meta) '()))
             (iid (string-append "sig-" plan-id "-" (symbol->string kind) "-" spec)))
        (fresh ()
          (== intent-fact
              `(intent ,iid ,action ,spec ,qty "each"
                       ,(assq-ref meta 'due) ,input-of ,output-of (,tag) #f))
          (== meta-fact
              `((signal-kind . ,kind) (source . ,src)
                (original-shortfall . ,(assq-ref meta 'original-shortfall))
                (onhand . ,(assq-ref meta 'onhand))
                (nfp . ,(assq-ref meta 'nfp))
                (zone . ,(assq-ref meta 'zone))
                (priority . ,(assq-ref meta 'priority))
                (tor . ,(assq-ref meta 'tor))
                (toy . ,(assq-ref meta 'toy))
                (tog . ,(assq-ref meta 'tog))
                (buffer-zone-id . ,(assq-ref meta 'buffer-zone-id))
                (status . open) (resolved-at . #f))))))))

(define (intent->signal-o intent-fact meta-fact signal)
  "Reconstruct signal from intent + metadata. Relational kind lookup."
  (fresh (kind src spec qty)
    ;; Relational: recover kind from metadata
    (project (meta-fact)
      (fresh ()
        (== kind (or (assq-ref meta-fact 'signal-kind) 'unknown))
        (== src (or (assq-ref meta-fact 'source) 'intent))))
    ;; Relational: extract from intent tuple
    (project (intent-fact)
      (fresh ()
        (== spec (list-ref intent-fact 3))
        (== qty (list-ref intent-fact 4))))
    (== signal `((kind . ,kind) (spec-id . ,spec) (qty . ,qty)
                 (source . ,src) (meta . ,meta-fact)))))
