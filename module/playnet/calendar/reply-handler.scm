;;; reply-handler.scm — ^reply-handler — ingest METHOD:REPLY iCalendar emails.
;;;
;;; Lifecycle: a Sieve filter on the mailbox (or an IMAP-poll worker, out of
;;; scope for this module) extracts a text/calendar METHOD:REPLY body from
;;; incoming mail and hands it to the actor as a string. That MIME-part
;;; extraction is not in the repo yet (the earlier ingest-reply.sh was never
;;; committed). Wiring it to a signed call on this actor is tools/door-call.scm's
;;; shape, once this actor is itself published as a door — not done here.
;;;
;;; The reply's UID is the proposal-id the invitation was sent under
;;; (mailer.scm sets it that way) — ACCEPTED promotes that SAME proposal
;;; via the real accept-invite door (the identical path a playnet member's
;;; accept takes; validate-proposal-acceptance! checks accepting-aid by
;;; plain membership in proposed-to, so the invitee's email address works
;;; unchanged, no AID needed). DECLINED/TENTATIVE have no promotion door to
;;; call — accept-invite's own code never grew a decline-invite sibling —
;;; so those are recorded only as the invitation's own bookkeeping status.
;;;
;;; accept-invite's call goes through `on`/#:catch, never a synchronous
;;; `catch` around a send: `<-` builds a promise for BOTH a near and a
;;; remote planner-service (confirmed against goblins/core.scm — a plain
;;; `catch #t` around it is inert for a near ref and, for a remote one,
;;; mistakes a torn-down session for "the call failed" — see
;;; feedback_goblins_thread_in_turn.md). `ingest` itself stays synchronous
;;; and returns before the promise resolves — mail ingestion was always
;;; meant to keep draining the inbox rather than wait on the planner.
;;;
;;; Stateless: holds only the refs passed at spawn time, no durable data of
;;; its own — no portrait needed.
;;;
;;; Spawn:
;;;   (define ^reply-ref
;;;     (spawn ^reply-handler planner-service scope-id scope-root))

(define-module (playnet calendar reply-handler)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (ice-9 format)
  #:use-module ((playnet calendar ical) #:select (parse-method-reply))
  #:use-module ((playnet calendar invitation) #:select (apply-reply!))
  #:export (^reply-handler))

(define (^reply-handler bcom planner-service scope-id scope-root)
  (methods
   ;; ical-text is a text/calendar MIME part body. Returns either
   ;;   'ok               — parsed; the reply is recorded (and, if
   ;;                       accepted, a promotion was fired off)
   ;;   (error . <reason>) — parse failed
   [(ingest ical-text)
    (let ((parsed (parse-method-reply ical-text)))
      (if (not parsed)
          (cons 'error 'not-a-reply)
          (let* ((uid         (assq-ref parsed 'uid))
                 ;; mailer.scm writes UID as "<proposal-id>@playnet" (ical.scm's
                 ;; own event->ical convention); strip the suffix back off.
                 (proposal-id (if (string-suffix? "@playnet" uid)
                                   (substring uid 0 (- (string-length uid) 8))
                                   uid))
                 (attendee    (assq-ref parsed 'attendee))
                 (partstat    (assq-ref parsed 'partstat)))
            (format (current-error-port)
                    "[reply-handler] proposal=~a attendee=~a partstat=~a~%"
                    proposal-id attendee partstat)
            (apply-reply! scope-root proposal-id partstat)
            (when (eq? partstat 'accepted)
              (on (<- planner-service 'accept-invite scope-id attendee proposal-id)
                  (lambda (_result)
                    (format (current-error-port)
                            "[reply-handler] accept-invite ~a/~a: promoted~%"
                            proposal-id attendee))
                  #:catch (lambda (err)
                            (format (current-error-port)
                                    "[reply-handler] accept-invite ~a/~a failed: ~a~%"
                                    proposal-id attendee err))))
            'ok)))]

   ;; Introspection helper for debugging.
   [(parse-only ical-text)
    (parse-method-reply ical-text)]))

(define (assq-ref alist key)
  (let ((pair (assq key alist)))
    (if pair (cdr pair) #f)))
