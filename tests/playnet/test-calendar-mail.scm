;;; test-calendar-mail.scm — the calendar email round-trip, end to end.
;;;
;;; No network, no real mail server: PLAYNET_MAIL_DIR drops each send as a
;;; file, and planner-service is a ^mock answering just accept-invite.
;;;
;;; Run from project root:
;;;   guile -L module tests/playnet/test-calendar-mail.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)
(add-to-load-path "module")

(define %test-mail-dir (string-append "/tmp/playnet-test-mail-" (number->string (getpid))))
(setenv "PLAYNET_MAIL_DIR" %test-mail-dir)

(use-modules (playnet test harness)
             (goblins)
             (goblins vat)
             (srfi srfi-1)
             (ice-9 ftw)
             (ice-9 rdelim)
             (ice-9 regex)
             (playnet calendar ical)
             (playnet interface adapters email)
             (playnet calendar invitation)
             (playnet calendar mailer)
             (playnet calendar reply-handler)
             (playnet planner scope root))

;;; ── ical.scm ─────────────────────────────────────────────────────────────

(let* ((evs (list `((id . "e1") (title . "Standup") (date . "2026-10-05")
                    (sh . 9) (sm . 0) (eh . 9) (em . 30))))
       (vc (events->vcalendar evs #:name "Team")))
  (check-pred "events->vcalendar wraps one VEVENT" (string-contains vc "SUMMARY:Standup"))
  (check-pred "events->vcalendar names the calendar" (string-contains vc "X-WR-CALNAME:Team")))

(let ((reply (string-append "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\n"
                            "UID:prop-42@playnet\r\n"
                            "ATTENDEE;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:alice@example.com\r\n"
                            "END:VEVENT\r\nEND:VCALENDAR\r\n")))
  (check "parse-method-reply reads the uid" (assq-ref (parse-method-reply reply) 'uid) "prop-42@playnet")
  (check "parse-method-reply reads the attendee" (assq-ref (parse-method-reply reply) 'attendee) "alice@example.com")
  (check "parse-method-reply reads the partstat" (assq-ref (parse-method-reply reply) 'partstat) 'accepted)
  (check "a METHOD:REQUEST is not a reply"
         (parse-method-reply "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n") #f))

(define (assq-ref alist key) (let ((p (assq key alist))) (and p (cdr p))))

(define (get-string-all-raw port)
  (let loop ((acc '()))
    (let ((c (read-char port)))
      (if (eof-object? c) (list->string (reverse acc)) (loop (cons c acc))))))

;; RFC 5545 TEXT escaping: a comma, semicolon or line break in a value must
;; not end it early or open a new property
(check "ical-text escapes , ; \\ and newline"
       (ical-text "a,b;c\\d\ne") "a\\,b\\;c\\\\d\\ne")

;;; ── invitation.scm, against a real scope-root's plan-store ──────────────
;;;
;;; Split across several with-vat calls on purpose, not one big one:
;;; with-vat sends its whole body as ONE turn (goblins/vat.scm's
;;; call-with-vat); a reply-handler method that fires `on`/`<-` schedules
;;; its continuation for a LATER turn, which only runs once something
;;; else asks the vat for another turn — so the check after `ingest` needs
;;; its OWN with-vat call to give that continuation a chance to run first.

(define vat (spawn-vat))
(define root #f)
(define ^mailer-ref #f)
(define ^reply-ref #f)
(define accept-calls '())

(with-vat vat
  (set! root (spawn-scope-root "test-commune"))

  (check "no invitations yet" (length (list-invitations root)) 0)

  (define inv (create-invitation! root "prop-1" "bob@example.com"))
  (check "create-invitation! returns a pending invitation" (invitation-status inv) 'pending)
  (check "create-invitation! persists it" (invitation-status (get-invitation root "prop-1")) 'pending)
  (check "list-pending-invitations sees it" (length (list-pending-invitations root)) 1)

  (define updated (apply-reply! root "prop-1" 'accepted))
  (check "apply-reply! marks it accepted" (invitation-status updated) 'accepted)
  (check "apply-reply! persists the change" (invitation-status (get-invitation root "prop-1")) 'accepted)
  (check "accepted drops out of pending" (length (list-pending-invitations root)) 0)
  (check "apply-reply! on an unknown proposal-id is #f" (apply-reply! root "prop-missing" 'accepted) #f)

  (set! ^mailer-ref (spawn ^mailer)))

;;; ── mailer.scm: a real send through the dev file-drop transport ───────

(with-vat vat
  (define result ($ ^mailer-ref 'send-invitation root
                     '((proposal-id . "prop-2") (to . "carla@example.com")
                       (title . "Coffee chat")
                       (dtstart . "20261020T150000Z") (dtend . "20261020T160000Z")
                       (location . "Sofia") (description . "Catch up."))))
  (check "send-invitation returns ok" result 'ok)
  (check "send-invitation recorded the invitation"
         (invitation-status (get-invitation root "prop-2")) 'pending)
  (check "send-invitation refuses a missing proposal-id"
         ($ ^mailer-ref 'send-invitation root '((to . "x@example.com") (dtstart . "a") (dtend . "b")))
         '(error . missing-proposal-id)))

(let ((dropped-files (filter (lambda (f) (string-suffix? ".eml" f))
                             (or (scandir %test-mail-dir) '()))))
  (check "send-invitation dropped exactly one .eml" (length dropped-files) 1)
  (when (pair? dropped-files)
    ;; the raw bytes: no line reader, so CRs survive and the CRLF claim is checkable
    (let* ((raw (call-with-input-file (string-append %test-mail-dir "/" (car dropped-files))
                  get-string-all-raw))
           (bare-lf (string-contains (regexp-substitute/global #f "\r\n" raw 'pre "" 'post) "\n")))
      (check-pred "the dropped mail carries the VEVENT" (string-contains raw "SUMMARY:Coffee chat"))
      (check-pred "the dropped mail carries METHOD:REQUEST" (string-contains raw "method=REQUEST"))
      (check-pred "the dropped mail's UID is the proposal-id" (string-contains raw "UID:prop-2@playnet"))
      (check "every line break in the dropped mail is CRLF" bare-lf #f)
      (check-pred "the From is the configured sender"
                  (string-contains raw (string-append "From: " (smtp-from)))))))

;;; ── reply-handler.scm: ingest a reply, accept-invite fires on the mock ─

(with-vat vat
  (define ^planner-mock
    (spawn ^mock `((accept-invite . ,(lambda (scope-id agent-id proposal-id)
                                        (set! accept-calls (cons (list scope-id agent-id proposal-id)
                                                                 accept-calls))
                                        `((accepted . ,proposal-id)))))))
  (set! ^reply-ref (spawn ^reply-handler ^planner-mock "test-commune" root)))

(define accept-reply
  (string-append "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\n"
                 "UID:prop-2@playnet\r\n"
                 "ATTENDEE;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:carla@example.com\r\n"
                 "END:VEVENT\r\nEND:VCALENDAR\r\n"))

(with-vat vat
  (check "ingest an accepted reply returns ok" ($ ^reply-ref 'ingest accept-reply) 'ok)
  (check "ingest records the invitation as accepted"
         (invitation-status (get-invitation root "prop-2")) 'accepted))

;; a fresh, separate turn: lets the earlier ingest's (on (<- ...) ...)
;; continuation — queued, not yet run — actually run before we look.
(with-vat vat (check "the vat is still alive" (not (not root)) #t))

(with-vat vat
  (check "ingest fired accept-invite on the real door, not a guess at its name"
         accept-calls (list (list "test-commune" "carla@example.com" "prop-2"))))

(define decline-reply
  (string-append "BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nBEGIN:VEVENT\r\n"
                 "UID:prop-1@playnet\r\n"
                 "ATTENDEE;PARTSTAT=DECLINED:mailto:bob@example.com\r\n"
                 "END:VEVENT\r\nEND:VCALENDAR\r\n"))

(with-vat vat
  (check "ingest a declined reply returns ok" ($ ^reply-ref 'ingest decline-reply) 'ok)
  ;; prop-1 was already 'accepted above; a later DECLINED reply still
  ;; overwrites it — last reply wins, same as a member's own reply would
  (check "a second reply still updates the bookkeeping"
         (invitation-status (get-invitation root "prop-1")) 'declined)
  (check "declining calls no door — there isn't one (confirmed, no decline-invite exists)"
         (length accept-calls) 1)
  (check "ingest of garbage is not-a-reply"
         ($ ^reply-ref 'ingest "not even close to ical")
         '(error . not-a-reply)))

;; cleanup
(false-if-exception
 (for-each (lambda (f) (delete-file (string-append %test-mail-dir "/" f)))
           (scandir %test-mail-dir (lambda (f) (not (member f '("." "..")))))))
(false-if-exception (rmdir %test-mail-dir))

(test-summary!)
