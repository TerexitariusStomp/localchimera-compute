;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/notify/recipient.scm — the recipient registry.
;;;
;;; Phase 2 of the unified router (docs/notifications/UNIFIED-ROUTER.md).
;;; The genuinely new state the system never had: a map from a person's
;;; KERI AID to the channels they can be reached on, plus per-recipient
;;; preferences. Before this, the three channels each carried their own
;;; unlinked key (push device-id, telegram chat-id, email login) and the
;;; notification sink bound to "whoever announced last". The AID is now
;;; the ONE routing key.
;;;
;;;   <binding> = (kind ctx style)
;;;     kind  ∈ browser | push | telegram | matrix | email | lxmf
;;;     ctx   = the transport destination (inbox ref, push sub, chat-id,
;;;             room-id, email address, lxmf address)
;;;     style ∈ terse | rich | markdown  (which render the channel wants)
;;;
;;;   <prefs> = (enabled-kinds min-severity quiet-hours channel-policy)
;;;
;;; Persistence (locked decision, §6): the DURABLE kinds (email, telegram,
;;; matrix, lxmf) survive restart; browser and push are connect-time live
;;; state rebuilt when a client reconnects. `durable-table' snapshots only
;;; the durable bindings, and the registry tells its keeper each time that
;;; snapshot changes (ON-DURABLE, below): the keeper writes it as a datum
;;; (`recipient-table->datum') and seeds the next boot from it
;;; (`datum->recipient-table'). The registry itself touches no file.

(define-module (playnet notify recipient)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (make-binding binding? binding-kind binding-ctx binding-style
            make-prefs prefs? prefs-enabled-kinds prefs-min-severity
            prefs-quiet-hours prefs-channel-policy default-prefs
            durable-kind? live-kind?
            severity>=?
            recipient-table->datum datum->recipient-table
            ^recipient-registry))


;;; ── Records ────────────────────────────────────────────────────────

(define-record-type <binding>
  (make-binding kind ctx style)
  binding?
  (kind  binding-kind)
  (ctx   binding-ctx)
  (style binding-style))

(define-record-type <prefs>
  (make-prefs enabled-kinds min-severity quiet-hours channel-policy)
  prefs?
  (enabled-kinds  prefs-enabled-kinds)   ; #t = all kinds, or a list of kinds
  (min-severity   prefs-min-severity)    ; info < normal < alert threshold
  (quiet-hours    prefs-quiet-hours)     ; #f, or (start-hour . end-hour)
  (channel-policy prefs-channel-policy)) ; alist kind -> 'always | 'default

(define (default-prefs)
  (make-prefs #t 'info #f '()))


;;; ── Channel taxonomy ───────────────────────────────────────────────

(define %durable-kinds '(email telegram matrix lxmf ntfy))
(define %live-kinds    '(browser push))

(define (durable-kind? k) (and (memq k %durable-kinds) #t))
(define (live-kind? k)    (and (memq k %live-kinds) #t))


;;; ── Severity ordering (for min-severity prefs) ─────────────────────

(define %severity-rank '((info . 0) (normal . 1) (alert . 2)))

(define (severity>=? a b)
  "Is severity A at least as high as B? (info < normal < alert)."
  (>= (or (assq-ref %severity-rank a) 0)
      (or (assq-ref %severity-rank b) 0)))


;;; ── The durable table as a datum ───────────────────────────────────
;;;
;;; What a keeper writes and reads: ((aid (kind ctx style) …) …). Prefs are
;;; live settings and start from the default at each boot.

(define (durable-of table)
  (filter-map
   (lambda (pair)
     (let* ((aid (car pair))
            (e   (cdr pair))
            (durable (filter (lambda (b) (durable-kind? (binding-kind b)))
                             (car e))))
       (and (pair? durable) (cons aid (cons durable (cdr e))))))
   table))

(define (recipient-table->datum durable-table)
  "A durable table (the `durable-table' method's answer) as plain data."
  (map (lambda (pair)
         (cons (car pair)
               (map (lambda (b) (list (binding-kind b) (binding-ctx b) (binding-style b)))
                    (cadr pair))))
       durable-table))

(define (datum->recipient-table datum)
  "The registry table a written datum seeds; anything malformed is left out."
  (filter-map
   (lambda (row)
     (and (pair? row) (string? (car row)) (list? (cdr row))
          (let ((bs (filter-map
                     (lambda (b)
                       (and (list? b) (= 3 (length b))
                            (durable-kind? (car b)) (string? (cadr b)) (symbol? (caddr b))
                            (make-binding (car b) (cadr b) (caddr b))))
                     (cdr row))))
            (and (pair? bs) (cons (car row) (cons bs (default-prefs)))))))
   (if (list? datum) datum '())))


;;; ── The registry actor ─────────────────────────────────────────────
;;;
;;; table: alist  aid-string -> (cons (list <binding> …) <prefs>)
;;; on-durable: #f, or a procedure told the durable table each time a
;;; durable binding is bound or dropped — the keeper's hook.

(define* (^recipient-registry bcom table #:optional (on-durable #f))

  ;; the registry as it stands after a change; a change to a durable
  ;; binding is told to the keeper once it has happened
  ;; REPLY rides as bcom's second argument: a bcom takes effect only as the
  ;; method's return value, so a method that answers something must answer
  ;; it through here.
  (define* (next table* durable? #:optional (reply *unspecified*))
    (when (and durable? on-durable)
      (catch #t (lambda () (on-durable (durable-of table*))) (lambda _ #f)))
    (bcom (^recipient-registry bcom table* on-durable) reply))

  (define (entry aid)
    (or (assoc-ref table aid) (cons '() (default-prefs))))

  (define (put aid new-entry)
    ;; functional alist update: drop any existing aid, cons the new entry
    (acons aid new-entry (remove (lambda (p) (equal? (car p) aid)) table)))

  (define (same-binding? kind ctx)
    (lambda (b) (and (eq? (binding-kind b) kind)
                     (equal? (binding-ctx b) ctx))))

  (methods

    ;; ── Mutators (called via <-np; no reply needed) ────────────────

    ((bind aid kind ctx style)
     ;; Idempotent: replaces any existing binding with the same kind+ctx.
     (let* ((e  (entry aid))
            (bs (cons (make-binding kind ctx style)
                      (remove (same-binding? kind ctx) (car e)))))
       (next (put aid (cons bs (cdr e))) (durable-kind? kind))))

    ((unbind aid kind ctx)
     (let* ((e  (entry aid))
            (bs (remove (same-binding? kind ctx) (car e))))
       (next (put aid (cons bs (cdr e))) (durable-kind? kind))))

    ((unbind-kind aid kind)
     ;; Drop ALL bindings of a kind — e.g. a browser client disconnected.
     (let* ((e  (entry aid))
            (bs (remove (lambda (b) (eq? (binding-kind b) kind)) (car e))))
       (next (put aid (cons bs (cdr e))) (durable-kind? kind))))

    ((set-prefs aid prefs)
     (let ((e (entry aid)))
       (next (put aid (cons (car e) prefs)) #f)))

    ;; ── Erasure ────────────────────────────────────────────────────
    ;; The AID's whole row goes — bindings and prefs — and the keeper
    ;; hears when a durable one stood. Replies the bindings that went as
    ;; plain (kind ctx style) data, so the caller can put down what each
    ;; one pointed at (a push subscription, a spooled mail). Idempotent:
    ;; an unknown AID replies ().
    ((forget aid)
     (let* ((row (assoc-ref table aid))
            (bs  (if row (car row) '())))
       (next (remove (lambda (p) (equal? (car p) aid)) table)
             (any (lambda (b) (durable-kind? (binding-kind b))) bs)
             (map (lambda (b) (list (binding-kind b) (binding-ctx b) (binding-style b))) bs))))

    ;; ── Reads ──────────────────────────────────────────────────────

    ((bindings-for aid) (car (entry aid)))
    ((prefs-for aid)    (cdr (entry aid)))
    ((known? aid)       (and (assoc-ref table aid) #t))
    ((all-aids)         (map car table))
    ((count)            (length table))

    ;; ── Persistence snapshot (durable bindings only) ───────────────
    ;; Live bindings (browser inbox refs, push subs) are connect-time
    ;; state and are intentionally NOT persisted.
    ((durable-table) (durable-of table))))
