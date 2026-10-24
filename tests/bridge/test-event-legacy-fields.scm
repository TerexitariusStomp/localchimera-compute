;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-event-legacy-fields.scm — an event that once carried `exclude-from-adu` and
;;; `market-value` still reads.
;;;
;;; The two fields were #f in every production writer and were removed from
;;; <economic-event>. Stored state and the event log are older than the removal, so
;;; both reading paths must take an event that names them:
;;;
;;;   serdes   a portrait is self-describing by field name; a field the type no
;;;            longer has is read past, and the event restores whole;
;;;   codec    a log entry's JSON may state "excludeFromAdu" / "marketValue"; the
;;;            decoder reads the event and the encoder no longer says either, which
;;;            was already so for #f (maybe-pair omits it).
;;;
;;; Run: guile --no-auto-compile -L module tests/bridge/test-event-legacy-fields.scm

(use-modules (localchimera test harness)
             (localchimera vf schemas)
             (localchimera vf serdes)
             (localchimera bridge codec)
             (srfi srfi-1))

(define ev
  (make-economic-event #:id "e1" #:action 'produce #:output-of "p1" #:resource-inventoried-as "r1" #:resource-conforms-to "spec-a" #:resource-classified-as '("tag") #:provider "a1" #:receiver "a1"
                       #:resource-quantity (make-measure 2.0 "kg") #:has-point-in-time "2026-10-05T10:00:00Z" #:created "2026-10-05T10:00:01Z" #:note "a note" #:in-scope-of '("s1")))

;;; ── the portrait ────────────────────────────────────────────────────────────

(define portrait (vf-serialize ev))

(check "a portrait is tagged by type name" (eq? (car portrait) '@vf))

(define legacy
  (append portrait '((exclude-from-adu . #f) (market-value . #f))))

(define restored (vf-deserialize legacy))

(check "a legacy portrait naming the removed fields restores an event"
       (economic-event? restored))
(check "the restored event is the event"
       (and (equal? (economic-event-id restored) "e1")
            (equal? (economic-event-action restored) 'produce)
            (equal? (economic-event-note restored) "a note")
            (equal? (economic-event-in-scope-of restored) '("s1"))))
(check "the current portrait round-trips unchanged"
       (equal? (economic-event-id (vf-deserialize portrait)) "e1"))

;;; ── the log entry's JSON ────────────────────────────────────────────────────

(define json (economic-event->json ev))

(check "the encoder states neither removed field"
       (not (or (assoc "excludeFromAdu" json) (assoc "marketValue" json))))

(define legacy-json (append json '(("excludeFromAdu" . #f) ("marketValue" . 12.5))))
(define decoded (json->economic-event legacy-json))

(check "a legacy entry naming the removed fields decodes to an event"
       (economic-event? decoded))
(check "the decoded event is the event"
       (and (equal? (economic-event-id decoded) "e1")
            (equal? (economic-event-resource-conforms-to decoded) "spec-a")
            (equal? (economic-event-previous-event decoded) #f)))

(test-summary!)
