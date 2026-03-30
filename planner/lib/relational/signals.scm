;;; signals.scm — Signal↔Intent conversion as pure relations
;;;
;;; Signal kinds: deficit, surplus, conservation, replenishment
;;; Each maps to a plan tag and an intent fact tuple.
;;; All relational — no store actors, no project.

(use-modules (playnet kanren-constraints))


;;; ── Signal tag relation ───────────────────────────────────────────────────────

(define *signal-tags*
  '((signal-tag deficit       "tag:plan:deficit")
    (signal-tag surplus       "tag:plan:surplus")
    (signal-tag conservation  "tag:plan:conservation")
    (signal-tag replenishment "tag:plan:replenishment")
    (signal-tag metabolic-debt "tag:plan:metabolic-debt")
    (signal-tag offer         "tag:plan:offer")
    (signal-tag request       "tag:plan:request")))

(define (signal-tag-o kind tag)
  "Relate a signal kind symbol to its plan tag string."
  (in-list-o `(signal-tag ,kind ,tag) *signal-tags*))


;;; ── Signal construction/destructuring ─────────────────────────────────────────

(define (signal-o kind spec-id qty source signal)
  "Relate signal components to a signal alist."
  (== signal `((kind . ,kind) (spec-id . ,spec-id) (qty . ,qty) (source . ,source))))

(define (signal-kind-o signal kind)
  (fresh (spec qty src) (signal-o kind spec qty src signal)))

(define (signal-spec-o signal spec-id)
  (fresh (kind qty src) (signal-o kind spec-id qty src signal)))

(define (signal-qty-o signal qty)
  (fresh (kind spec src) (signal-o kind spec qty src signal)))


;;; ── Signal → Intent fact ──────────────────────────────────────────────────────

(define (signal->intent-o signal plan-id intent-fact)
  "Convert a signal to an intent fact tuple."
  (fresh (kind spec-id qty source tag)
    (signal-o kind spec-id qty source signal)
    (signal-tag-o kind tag)
    (conde
      ;; Deficit: need to acquire
      ((== kind 'deficit)
       (== intent-fact
           `(intent ,(string-append "sig-" plan-id "-deficit-" spec-id)
                    transfer ,spec-id ,qty "each" #f #f #f (,tag) #f)))
      ;; Surplus: available to share
      ((== kind 'surplus)
       (== intent-fact
           `(intent ,(string-append "sig-" plan-id "-surplus-" spec-id)
                    transfer ,spec-id ,qty "each" #f #f #f (,tag) #f)))
      ;; Replenishment: buffer needs refilling
      ((== kind 'replenishment)
       (== intent-fact
           `(intent ,(string-append "sig-" plan-id "-replen-" spec-id)
                    produce ,spec-id ,qty "each" #f #f #f (,tag) #f)))
      ;; Conservation: minimum inventory floor
      ((== kind 'conservation)
       (== intent-fact
           `(intent ,(string-append "sig-" plan-id "-conserv-" spec-id)
                    transfer ,spec-id ,qty "each" #f #f #f (,tag) #f))))))


;;; ── Intent fact → Signal ──────────────────────────────────────────────────────

(define (intent->signal-o intent-fact signal)
  "Convert an intent fact tuple back to a signal. Bidirectional."
  (fresh (iid action spec-id qty unit due in-of out-of tags finished kind tag)
    (== intent-fact `(intent ,iid ,action ,spec-id ,qty ,unit ,due ,in-of ,out-of ,tags ,finished))
    ;; Find the signal tag in the tags list
    (membero tag tags)
    (signal-tag-o kind tag)
    (signal-o kind spec-id qty 'intent signal)))
