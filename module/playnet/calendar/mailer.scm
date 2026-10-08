;;; mailer.scm — ^mailer actor: an iCalendar invitation, sent by real email.
;;;
;;; Builds the multipart/alternative message with a text/calendar
;;; METHOD:REQUEST part, and hands the finished message to
;;; (playnet interface adapters email)'s send-raw-email!, which owns the
;;; transport (msmtp, sendmail, or PLAYNET_MAIL_DIR) and the CRLF header
;;; assembly (rfc5322-message). The From is the configured sender
;;; (smtp-from), so the ORGANIZER and the envelope agree.
;;; On success, records the send via (playnet calendar invitation).
;;;
;;; KNOWN LIMITATION, inherited rather than introduced: send-raw-email!'s
;;; transport call is synchronous (ice-9 popen, blocking I/O) run directly
;;; inside the method body — the same shape email.scm's send-email! has
;;; always had for every notification channel. It blocks the whole vat for
;;; as long as local mail submission takes, with no timeout. Fixing that is
;;; a vat-wide concern for the notify/email subsystem, not scoped to
;;; calendar invites alone.
;;;
;;; Spawn:
;;;   (define ^mailer-ref (spawn ^mailer))
;;;
;;; Use:
;;;   ($ ^mailer-ref 'send-invitation scope-root
;;;      '((proposal-id . "prop-42") (to . "alice@example.com")
;;;        (title . "Coffee chat")
;;;        (dtstart . "20261020T150000Z") (dtend . "20261020T160000Z")
;;;        (location . "Sofia") (description . "Catch up.")))

(define-module (playnet calendar mailer)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module ((playnet interface adapters email)
                #:select (smtp-from rfc5322-message send-raw-email!))
  #:use-module ((playnet calendar invitation) #:select (create-invitation!))
  #:use-module ((playnet calendar ical) #:select (ical-text))
  #:use-module (ice-9 format)
  #:export (^mailer))

(define (alist-get a key default)
  (let ((pair (assq key a)))
    (if pair (cdr pair) default)))

;; the iCalendar body of the text/calendar part. SUMMARY, LOCATION and
;; DESCRIPTION are TEXT values, escaped by ical-text; the addresses and
;; stamps are not free text and go through as they are.
(define (ical-request uid dtstamp dtstart dtend title from to location description)
  (string-append
   "BEGIN:VCALENDAR\r\n"
   "VERSION:2.0\r\n"
   "PRODID:-//playnet//calendar//EN\r\n"
   "METHOD:REQUEST\r\n"
   "CALSCALE:GREGORIAN\r\n"
   "BEGIN:VEVENT\r\n"
   "UID:" uid "\r\n"
   "DTSTAMP:" dtstamp "\r\n"
   "DTSTART:" dtstart "\r\n"
   "DTEND:" dtend "\r\n"
   "SUMMARY:" (ical-text title) "\r\n"
   "ORGANIZER:mailto:" from "\r\n"
   "ATTENDEE;RSVP=TRUE;PARTSTAT=NEEDS-ACTION:mailto:" to "\r\n"
   (if (string-null? location) "" (string-append "LOCATION:" (ical-text location) "\r\n"))
   (if (string-null? description) "" (string-append "DESCRIPTION:" (ical-text description) "\r\n"))
   "END:VEVENT\r\n"
   "END:VCALENDAR\r\n"))

(define (invitation-message from to title dtstart dtend location description uid)
  "The whole message: headers, then a multipart/alternative with a plain-text
   fallback and the calendar part. Body lines may be LF; rfc5322-message makes
   every break CRLF."
  (let* ((dtstamp  (strftime "%Y%m%dT%H%M%SZ" (gmtime (current-time))))
         (boundary (format #f "playnet-invite-~a-~a" (getpid) (current-time)))
         (body
          (string-append
           "--" boundary "\n"
           "Content-Type: text/plain; charset=utf-8\n\n"
           "You're invited: " title "\n"
           "When:  " dtstart "  ->  " dtend "  (UTC)\n"
           (if (string-null? location) "" (string-append "Where: " location "\n"))
           "\n(Open this message in a calendar-aware mail client to RSVP.)\n\n"
           "--" boundary "\n"
           "Content-Type: text/calendar; charset=utf-8; method=REQUEST\n"
           "Content-Transfer-Encoding: 7bit\n\n"
           (ical-request uid dtstamp dtstart dtend title from to location description)
           "\n--" boundary "--\n")))
    (rfc5322-message #:from from #:to to #:subject title
                     #:headers (list "MIME-Version: 1.0"
                                     (string-append "Content-Type: multipart/alternative; boundary=\""
                                                    boundary "\""))
                     #:body body)))

(define* (^mailer bcom #:key (from (smtp-from)))
  (methods
   ;; EVT: '((proposal-id . U) (to . "alice@example.com") (title . S)
   ;;        (dtstart . D1) (dtend . D2) (location . L) (description . D)).
   ;; PROPOSAL-ID is already the id of a proposal the invite-creation door
   ;; made (proposed-to naming TO directly, member or not) — this sends TO
   ;; the email and then records having sent it.
   [(send-invitation scope-root evt)
    (let* ((proposal-id (alist-get evt 'proposal-id #f))
           (to          (alist-get evt 'to ""))
           (title       (alist-get evt 'title ""))
           (dtstart     (alist-get evt 'dtstart ""))
           (dtend       (alist-get evt 'dtend ""))
           (location    (alist-get evt 'location ""))
           (description (alist-get evt 'description "")))
      (cond
       ((not proposal-id)    (cons 'error 'missing-proposal-id))
       ((string=? to "")     (cons 'error 'missing-to))
       ((string=? dtstart "") (cons 'error 'missing-dtstart))
       ((string=? dtend "")   (cons 'error 'missing-dtend))
       (else
        (let ((uid (string-append proposal-id "@playnet")))
          (send-raw-email! to (invitation-message from to title dtstart dtend
                                                  location description uid))
          (create-invitation! scope-root proposal-id to)
          'ok))))]

   ;; Introspection.
   [(config) `((from . ,from))]))
