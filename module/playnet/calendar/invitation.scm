;;; invitation.scm — an invitation's own bookkeeping: sent, and answered when.
;;;
;;; The real state of "did they accept" already has a home: a social invite
;;; is a directed Proposal with a `proposed-to` whitelist (doors/service.scm),
;;; and accepting one promotes the underlying intent to a commitment via the
;;; `accept-invite` door — the SAME path a playnet member's accept takes.
;;; `validate-proposal-acceptance!` (planner/plan/store.scm) checks
;;; `accepting-aid` by plain string membership in `proposed-to`, nothing
;;; cryptographic at that layer — so an external invitee with no AID at all
;;; is proposed-to and accepts by their email address directly, unchanged.
;;;
;;; What that system does NOT carry is "when was this sent" / "when did they
;;; last answer" — useful for a reminder, or for showing "awaiting reply"
;;; before any answer exists at all. This module is only that: a meta row
;;; per invitation, on the SAME scope plan-store #:self-call convention
;;; doors/service.scm's willing-key/willing-by-key already use (set-meta/
;;; get-meta/all-meta — one hashmap, persisted with plan-store itself; no
;;; new actor, no new persistence code).
;;;
;;; The invitation's id IS the proposal-id the invite created — also the
;;; iCal UID (ical.scm's events->vcalendar/event->ical convention: UID is
;;; the thing's own id, "@playnet" suffixed) — so a reply's UID resolves
;;; straight to both the bookkeeping row and the real proposal to accept.

(define-module (playnet calendar invitation)
  #:use-module (goblins)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet utils store-utils) #:select (meta-rows-with-prefix))
  #:export (make-invitation
            invitation?
            invitation-id
            invitation-proposal-id
            invitation-invitee
            invitation-sent-at
            invitation-status
            invitation-last-reply-at
            invitation-with-status
            invitation-meta-key
            create-invitation!
            apply-reply!
            get-invitation
            list-invitations
            list-pending-invitations))

;;; ── Record ──────────────────────────────────────────────────────────

;; Plain alist so it survives syrup serialization the same way every other
;; plan-store meta row does — this never crosses a Goblins actor boundary
;; of its own, but plan-store's #:portrait does, over every row at once.
(define* (make-invitation #:key
                          proposal-id     ; string — also the iCal UID (bare)
                          invitee         ; "email" or AID
                          sent-at         ; ISO 8601 string
                          (status 'pending) ; pending|accepted|declined|tentative
                          (last-reply-at #f))
  `((kind          . invitation)
    (proposal-id   . ,proposal-id)
    (invitee       . ,invitee)
    (sent-at       . ,sent-at)
    (status        . ,status)
    (last-reply-at . ,last-reply-at)))

(define (invitation? v)
  (and (list? v) (eq? 'invitation (and (assq 'kind v) (cdr (assq 'kind v))))))

(define (invitation-id i)            (cdr (assq 'proposal-id i)))
(define (invitation-proposal-id i)   (cdr (assq 'proposal-id i)))
(define (invitation-invitee i)       (cdr (assq 'invitee i)))
(define (invitation-sent-at i)       (cdr (assq 'sent-at i)))
(define (invitation-status i)        (cdr (assq 'status i)))
(define (invitation-last-reply-at i) (cdr (assq 'last-reply-at i)))

(define (invitation-with-status inv new-status reply-at)
  (map (lambda (p)
         (case (car p)
           ((status)        (cons 'status new-status))
           ((last-reply-at) (cons 'last-reply-at reply-at))
           (else            p)))
       inv))

;;; ── Store (scope plan-store meta rows) ───────────────────────────────

(define invitation-meta-prefix "invitation|")

(define (invitation-meta-key proposal-id)
  (string-append invitation-meta-prefix proposal-id))

(define (iso-now)
  (strftime "%Y-%m-%dT%H:%M:%SZ" (gmtime (current-time))))

(define* (create-invitation! scope-root proposal-id invitee)
  "Record that PROPOSAL-ID was just sent to INVITEE, on SCOPE-ROOT's own
   plan-store. The proposal itself already exists (the invite-creation door
   made it, same as a member invite) — this only states when and to whom.
   Returns the invitation alist."
  (let* ((ps  ($ scope-root 'plan-store))
         (inv (make-invitation #:proposal-id proposal-id
                               #:invitee invitee
                               #:sent-at (iso-now))))
    ($ ps 'set-meta (invitation-meta-key proposal-id) inv)
    inv))

(define (get-invitation scope-root proposal-id)
  ($ ($ scope-root 'plan-store) 'get-meta (invitation-meta-key proposal-id)))

(define (list-invitations scope-root)
  (map cdr (meta-rows-with-prefix ($ ($ scope-root 'plan-store) 'all-meta)
                                  invitation-meta-prefix)))

(define (list-pending-invitations scope-root)
  (filter (lambda (i) (eq? (invitation-status i) 'pending))
          (list-invitations scope-root)))

(define* (apply-reply! scope-root proposal-id status)
  "Mark PROPOSAL-ID's invitation row as STATUS (accepted|declined|tentative).
   Returns the updated invitation alist, or #f if no invitation was ever
   recorded for PROPOSAL-ID (a reply to something this scope never sent)."
  (let ((inv (get-invitation scope-root proposal-id)))
    (and inv
         (let ((new (invitation-with-status inv status (iso-now))))
           ($ ($ scope-root 'plan-store) 'set-meta (invitation-meta-key proposal-id) new)
           new))))
