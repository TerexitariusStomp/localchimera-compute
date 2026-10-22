;;; tests/parity/calendar-radicale.scm — calendar ↔ Radicale parity.
;;; The contract the upstream must hold: the iCal our calendar emits IS
;;; the CalDAV body — Radicale stores and serves it verbatim. Invariant
;;; leg pins the bytes; live leg REPORTs against a real server.

(use-modules (playnet test harness)
             (playnet test parity)
             (playnet delegates)
             (playnet calendar ical)
             (srfi srfi-1))

;; ── invariant leg: the byte contract ──────────────────────────────────────
(define fixture-events
  (list '((id . "e-parity") (title . "Parity Check") (date . "2026-11-01")
          (sh . 10) (sm . 0) (eh . 11) (em . 0))))

(define vc (events->vcalendar fixture-events #:name "ParityCal"))
(check "vcalendar carries the fixture's VEVENT"
       (and (string-contains vc "BEGIN:VCALENDAR")
            (string-contains vc "SUMMARY:Parity Check")
            (string-contains vc "END:VCALENDAR") #t) #t)
(check "the PRODID is the stable emitter identity"
       (and (string-contains vc "PRODID:-//playnet//calendar//EN") #t) #t)

;; the REPORT wire a Radicale fetch builds for a fixture range
(let ((w (radicale-report-wire "/cal/commune/" 1 "<c:calendar-query/>")))
  (check "radicale REPORT wire is REPORT + Depth + filter body"
         (and (equal? (cdr (assoc "method" w)) "REPORT")
              (equal? (cdr (assoc "path" w)) "/cal/commune/")
              (and (assoc "body" w) #t)) #t))

;; ── live leg: needs PLAYNET_RADICALE_URL ─────────────────────────────────
(parity-live-delegate "PLAYNET_RADICALE_URL"
  "radicale REPORT answers the calendar's multistatus"
  (lambda (t) (make-radicale-delegate t))
  (lambda (d) (d "/cal/commune/" 1 "<c:calendar-query/>"))
  (lambda (a) (and (pair? a) (< (car a) 300))))

(test-summary!)
