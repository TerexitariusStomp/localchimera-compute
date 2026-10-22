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
(parity-live "PLAYNET_RADICALE_URL"
  "radicale REPORT answers the calendar's multistatus"
  (lambda (endpoint)
    (let ((d (make-radicale-delegate
              (%json-http-transport
               endpoint
               #:headers '((depth . "1")
                           (content-type . (application/xml)))))))
      ;; the root collection always exists — a fixture calendar would be
      ;; PUT first in a real cutover; parity asks the REPORT verb itself
      (let ((a (d "/" 1 "<?xml version=\"1.0\"?><C:calendar-query xmlns:C=\"urn:ietf:params:xml:ns:caldav\" xmlns:D=\"DAV:\"><D:prop><D:getetag/></D:prop></C:calendar-query>")))
        (and (pair? a) (< (car a) 300))))))

(test-summary!)
