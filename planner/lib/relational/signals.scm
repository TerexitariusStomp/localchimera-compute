;;; signals.scm — Signal↔Intent (relational tag lookup + ground conversion)
;;;
;;; signal-tag-o is genuinely relational (bidirectional lookup).
;;; Conversion uses project on ground signal data (honest).

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

(define (signal-o kind spec-id qty source signal)
  (== signal `((kind . ,kind) (spec-id . ,spec-id) (qty . ,qty) (source . ,source))))

(define (signal->intent-o signal plan-id intent-fact meta-fact)
  "Convert signal to intent + metadata. Ground computation on signal data."
  (project (signal plan-id)
    (let* ((kind (assq-ref signal 'kind))
           (spec (assq-ref signal 'spec-id))
           (qty (assq-ref signal 'qty))
           (src (assq-ref signal 'source))
           (meta (or (assq-ref signal 'meta) '()))
           (tags (assq kind (map (lambda (t) (cons (cadr t) (caddr t))) *signal-tags*)))
           (tag (if tags (cdr tags) (string-append "tag:plan:" (symbol->string kind))))
           (iid (string-append "sig-" plan-id "-" (symbol->string kind) "-" spec)))
      (fresh ()
        (== intent-fact
            `(intent ,iid
                     ,(case kind ((deficit conservation) 'transfer)
                                 ((replenishment) 'produce)
                                 (else 'transfer))
                     ,spec ,qty "each"
                     ,(assq-ref meta 'due)
                     ,(if (memq kind '(deficit conservation)) 'input #f)
                     ,(if (memq kind '(surplus replenishment)) 'output #f)
                     (,tag) #f))
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
              (status . open) (resolved-at . #f)))))))

(define (intent->signal-o intent-fact meta-fact signal)
  "Reconstruct signal from intent + metadata."
  (project (intent-fact meta-fact)
    (let* ((spec (list-ref intent-fact 3))
           (qty (list-ref intent-fact 4))
           (kind (or (assq-ref meta-fact 'signal-kind) 'unknown))
           (src (or (assq-ref meta-fact 'source) 'intent)))
      (== signal `((kind . ,kind) (spec-id . ,spec) (qty . ,qty)
                   (source . ,src) (meta . ,meta-fact))))))
