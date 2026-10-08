;;; ical.scm — the server-side iCalendar protocol: a feed out, a reply in.
;;;
;;; module/playnet/ui/calendar.scm's event->ical/ical-line->pair are UI-layer
;;; pure functions (data in, SXML-adjacent out) shared with the browser's
;;; repl-app surface; this module is neither UI nor browser-facing — it's the
;;; wire format the server-side actors in this directory speak
;;; (federation.scm's cross-org feed, reply-handler.scm's RSVP ingest). It
;;; reuses event->ical/ical-line->pair rather than duplicating them, since
;;; those two really are shared primitives, but states its own two protocol-
;;; level functions here, not in a module charted for UI layout.

(define-module (playnet calendar ical)
  #:use-module ((playnet ui calendar) #:select (event->ical ical-line->pair split-on-newlines))
  #:export (events->vcalendar
            parse-method-reply
            ical-text))

;;; ── TEXT values (RFC 5545 §3.3.11) ───────────────────────────────────────
;;; A SUMMARY, LOCATION or DESCRIPTION is TEXT: a comma, semicolon, backslash
;;; or line break inside it would otherwise end the value early or begin a
;;; new property. Escape them. Only the values the invitation writes go
;;; through here; event->ical's output is a live export and is not changed.

(define (ical-text s)
  (apply string-append
         (map (lambda (c)
                (case c
                  ((#\\) "\\\\") ((#\;) "\\;") ((#\,) "\\,")
                  ((#\newline #\return) "\\n")
                  (else (string c))))
              (string->list s))))

;;; ── A LIST of VEVENTs (cross-org federation) ─────────────────────────────

(define* (events->vcalendar events #:key (name "Playnet Calendar"))
  "Export EVENTS (a list of the same event alists event->ical takes) as one
   iCal VCALENDAR of VEVENT entries, named NAME (X-WR-CALNAME)."
  (string-append
   "BEGIN:VCALENDAR\r\n"
   "VERSION:2.0\r\n"
   "PRODID:-//playnet//calendar//EN\r\n"
   "X-WR-CALNAME:" name "\r\n"
   (apply string-append (map event->ical events))
   "END:VCALENDAR\r\n"))

;;; ── METHOD:REPLY — an invitee's RSVP, read back off their reply ─────────

(define (has-prefix? s prefix)
  (and (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

(define (ical-param-value key param-name)
  "KEY is a property name possibly carrying ;PARAM=VALUE segments (e.g.
   \"ATTENDEE;PARTSTAT=ACCEPTED;RSVP=TRUE\"). PARAM-NAME's value, or #f."
  (let* ((marker (string-append param-name "="))
         (parts  (let loop ((s key) (acc '()))
                   (let ((semi (let find ((i 0))
                                 (cond ((>= i (string-length s)) #f)
                                       ((char=? (string-ref s i) #\;) i)
                                       (else (find (+ i 1)))))))
                     (if semi
                         (loop (substring s (+ semi 1)) (cons (substring s 0 semi) acc))
                         (reverse (cons s acc)))))))
    (let find ((ps parts))
      (cond ((null? ps) #f)
            ((has-prefix? (car ps) marker) (substring (car ps) (string-length marker)))
            (else (find (cdr ps)))))))

(define (parse-method-reply ical-text)
  "Parse a METHOD:REPLY iCalendar body — one invitee's RSVP, naming the
   event's UID, who replied, and their PARTSTAT. Returns
   '((uid . U) (attendee . mailbox) (partstat . accepted|declined|tentative))
   or #f when ICAL-TEXT is not a REPLY, or is missing a UID or an ATTENDEE
   with a PARTSTAT."
  (let* ((lines (split-on-newlines ical-text))
         (in-event #f) (current '()) (method #f))
    (for-each
     (lambda (line)
       (let ((l (if (and (> (string-length line) 0)
                         (char=? (string-ref line (- (string-length line) 1)) #\return))
                    (substring line 0 (- (string-length line) 1))
                    line)))
         (cond
          ((string=? l "BEGIN:VEVENT") (set! in-event #t) (set! current '()))
          ((string=? l "END:VEVENT") (set! in-event #f))
          ((and (not in-event) (has-prefix? l "METHOD:"))
           (set! method (substring l (string-length "METHOD:"))))
          (in-event
           (let ((pair (ical-line->pair l)))
             (when pair (set! current (cons pair current))))))))
     lines)
    (and method (string=? method "REPLY")
         (let* ((uid (assoc-ref current "UID"))
                (att (let find ((ps current))
                       (cond ((null? ps) #f)
                             ((has-prefix? (car (car ps)) "ATTENDEE") (car ps))
                             (else (find (cdr ps)))))))
           (and uid att
                (let* ((key (car att))
                       (val (cdr att))
                       (partstat (ical-param-value key "PARTSTAT"))
                       (mailbox (if (has-prefix? val "mailto:") (substring val 7) val)))
                  (and partstat
                       `((uid . ,uid)
                         (attendee . ,mailbox)
                         (partstat . ,(string->symbol (string-downcase-ascii partstat)))))))))))

(define (string-downcase-ascii s)
  (string-map (lambda (c) (if (and (char>=? c #\A) (char<=? c #\Z))
                              (char-downcase c) c))
              s))

(define (assoc-ref alist key)
  (let ((pair (assoc key alist)))
    (if pair (cdr pair) #f)))
