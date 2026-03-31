;;; signals.scm — Signal↔Intent with full metadata preservation
;;;
;;; Complete port of imperative signals.scm. Preserves all metadata:
;;; original-shortfall, resolved-at, onhand, TOR/TOY/TOG, zone, nfp,
;;; priority, buffer-zone-id, status.

(use-modules (playnet kanren-constraints))

(define *signal-tags*
  '((signal-tag deficit       "tag:plan:deficit")
    (signal-tag surplus       "tag:plan:surplus")
    (signal-tag conservation  "tag:plan:conservation")
    (signal-tag replenishment "tag:plan:replenishment")
    (signal-tag metabolic-debt "tag:plan:metabolic-debt")
    (signal-tag reservation-gap "tag:plan:reservation-gap")
    (signal-tag container-bound "tag:plan:container-bound")
    (signal-tag offer         "tag:plan:offer")
    (signal-tag request       "tag:plan:request")))

(define (signal-tag-o kind tag)
  (in-list-o `(signal-tag ,kind ,tag) *signal-tags*))


;;; ── Signal construction ───────────────────────────────────────────────────────

(define (signal-o kind spec-id qty source signal)
  (== signal `((kind . ,kind) (spec-id . ,spec-id) (qty . ,qty) (source . ,source))))

(define (signal-with-meta-o kind spec-id qty source meta signal)
  (== signal `((kind . ,kind) (spec-id . ,spec-id) (qty . ,qty)
               (source . ,source) (meta . ,meta))))


;;; ── Signal → Intent (full metadata) ───────────────────────────────────────────

(define (signal->intent-o signal plan-id intent-fact meta-fact)
  (project (signal plan-id)
    (let* ((kind (assq-ref signal 'kind))
           (spec (assq-ref signal 'spec-id))
           (qty (assq-ref signal 'qty))
           (src (assq-ref signal 'source))
           (sig-meta (or (assq-ref signal 'meta) '()))
           (tag (let ((p (assq kind (map (lambda (t) (cons (cadr t) (caddr t)))
                                          *signal-tags*))))
                  (if p (cdr p) (string-append "tag:plan:" (symbol->string kind)))))
           (iid (string-append "sig-" plan-id "-" (symbol->string kind) "-" spec)))
      (fresh ()
        (== intent-fact
            `(intent ,iid
                     ,(case kind
                        ((deficit) 'transfer)
                        ((surplus) 'transfer)
                        ((replenishment) 'produce)
                        ((conservation) 'transfer)
                        (else 'transfer))
                     ,spec ,qty "each"
                     ,(assq-ref sig-meta 'due)
                     ,(if (memq kind '(deficit conservation)) 'input #f)
                     ,(if (memq kind '(surplus replenishment)) 'output #f)
                     (,tag) #f))
        (== meta-fact
            `((signal-kind . ,kind)
              (source . ,src)
              (original-shortfall . ,(assq-ref sig-meta 'original-shortfall))
              (onhand . ,(assq-ref sig-meta 'onhand))
              (nfp . ,(assq-ref sig-meta 'nfp))
              (zone . ,(assq-ref sig-meta 'zone))
              (priority . ,(assq-ref sig-meta 'priority))
              (tor . ,(assq-ref sig-meta 'tor))
              (toy . ,(assq-ref sig-meta 'toy))
              (tog . ,(assq-ref sig-meta 'tog))
              (buffer-zone-id . ,(assq-ref sig-meta 'buffer-zone-id))
              (status . open)
              (resolved-at . #f)))))))


;;; ── Intent → Signal (reconstruction) ──────────────────────────────────────────

(define (intent->signal-o intent-fact meta-fact signal)
  (project (intent-fact meta-fact)
    (let* ((spec (list-ref intent-fact 3))
           (qty (list-ref intent-fact 4))
           (kind (or (assq-ref meta-fact 'signal-kind) 'unknown))
           (src (or (assq-ref meta-fact 'source) 'intent)))
      (== signal `((kind . ,kind) (spec-id . ,spec) (qty . ,qty)
                   (source . ,src) (meta . ,meta-fact))))))
