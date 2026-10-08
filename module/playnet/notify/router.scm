;;; module/playnet/notify/router.scm — the notification router.
;;;
;;; Phase 3 of the unified router (docs/notifications/UNIFIED-ROUTER.md).
;;; The single entry point emitters use:
;;;
;;;   (notify aid notification)          — one recipient
;;;   (notify-scope member-aids notif)   — fan-out to a scope's members
;;;
;;; It resolves the recipient's bound channels (playnet notify recipient),
;;; filters by their prefs, dedups by tag ACROSS channels (locked decision
;;; §6: suppress duplicates), renders each channel in ITS style (playnet
;;; notify registry), and hands the rendered notification to that channel's
;;; dumb adapter's `deliver' (Phase 1).
;;;
;;; The routing decision lives in the pure `plan-sends' so it is testable
;;; without a running vat; the actor is a thin shell that performs the
;;; resulting `<-np' sends and threads the dedup memory.

(define-module (playnet notify router)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (playnet notify registry)
  #:use-module (playnet notify rendered)
  #:use-module (playnet notify recipient)
  #:export (accept-by-prefs?
            plan-sends
            ^notify-router))


;;; ── Preference gate ────────────────────────────────────────────────

(define (accept-by-prefs? notification type prefs)
  "Does PREFS admit this NOTIFICATION (of severity TYPE)? Gated by kind
   opt-in (enabled-kinds = #t for all, or a list) and a min-severity floor."
  (let ((kind    (assq-ref notification 'kind))
        (enabled (prefs-enabled-kinds prefs)))
    (and (or (eq? enabled #t) (and (list? enabled) (memq kind enabled) #t))
         (severity>=? type (prefs-min-severity prefs)))))


;;; ── The routing decision (pure) ────────────────────────────────────

(define (plan-sends adapters recent aid notification bindings prefs)
  "Plan delivery of NOTIFICATION to AID. Returns three values:
     sends      — list of (adapter-ref ctx rendered) to dispatch
     new-recent — updated cross-channel dedup memory
     status     — 'delivered | 'suppressed-by-prefs | 'suppressed-duplicate
                  | 'unknown-kind
   ADAPTERS is an alist kind -> adapter-ref. RECENT is a set of (aid . tag)
   already delivered (suppress-duplicates policy). Each binding is rendered
   in its own style; type/tag come from the canonical (terse) render so a
   channel's style can't change the severity or the dedup key."
  (call-with-values (lambda () (render-notification notification 'terse))
    (lambda (type title body tag)
      (cond
       ((not type)
        (values '() recent 'unknown-kind))
       ((not (accept-by-prefs? notification type prefs))
        (values '() recent 'suppressed-by-prefs))
       ((member (cons aid tag) recent)
        (values '() recent 'suppressed-duplicate))
       (else
        (let ((sends
               (filter-map
                (lambda (b)
                  (let ((adapter (assq-ref adapters (binding-kind b))))
                    (and adapter
                         (call-with-values
                           (lambda () (render-notification notification (binding-style b)))
                           (lambda (ty ti bo tg)
                             ;; severity + dedup key are canonical; only the
                             ;; presentation (title/body) is per-style.
                             (list adapter (binding-ctx b)
                                   (rendered-notification type ti bo tag)))))))
                bindings)))
          (values sends (cons (cons aid tag) recent) 'delivered)))))))


;;; ── The router actor ───────────────────────────────────────────────
;;;
;;; registry : ^recipient-registry ref (same vat — resolved via near-call)
;;; adapters : alist  kind -> adapter ref
;;; recent   : dedup memory, a list of (aid . tag)
;;; fallback : #f, or an ^output-sink ref. When a recipient has NO bound
;;;            channels (e.g. before a session has seeded a browser
;;;            binding during the cutover), the notification is handed to
;;;            this legacy sink instead of being dropped.

(define* (^notify-router bcom registry adapters recent #:optional (fallback #f))

  (define (rebuild adapters* recent*)
    (^notify-router bcom registry adapters* recent* fallback))

  (define (perform! sends)
    (for-each (lambda (s) (<-np (car s) 'deliver (cadr s) (caddr s))) sends))

  (define (route1 aid notification rec)
    ;; Returns (values sends new-rec status), honouring the fallback for
    ;; recipients with no bound channels.
    (let ((bindings ($ registry 'bindings-for aid)))
      (if (null? bindings)
          (begin (when fallback (<-np fallback 'print notification))
                 (values '() rec 'fell-back))
          (plan-sends adapters rec aid notification
                      bindings ($ registry 'prefs-for aid)))))

  (methods

    ((notify aid notification)
     (call-with-values (lambda () (route1 aid notification recent))
       (lambda (sends new-recent status)
         (perform! sends)
         (bcom (rebuild adapters new-recent) status))))

    ((notify-scope member-aids notification)
     ;; Fan-out with a SINGLE dedup memory threaded across members, so a
     ;; scope alert reaches every member but never twice on one channel.
     (let loop ((aids member-aids) (rec recent) (acc '()))
       (if (null? aids)
           (begin (perform! acc)
                  (bcom (rebuild adapters rec) (length acc)))
           (call-with-values (lambda () (route1 (car aids) notification rec))
             (lambda (sends new-rec _status)
               (loop (cdr aids) new-rec (append acc sends)))))))

    ;; Clear a tag so the same notification can fire again later (the
    ;; window-based expiry of Phase 5 will call this).
    ((forget aid tag)
     (bcom (rebuild adapters
                    (remove (lambda (p) (equal? p (cons aid tag))) recent))))

    ((set-adapters new-adapters)
     (bcom (rebuild new-adapters recent)))

    ((dedup-count) (length recent))))
