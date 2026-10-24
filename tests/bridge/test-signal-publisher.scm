;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-signal-publisher.scm — the ONE signal topic contract.
;;;
;;; signal-topic builds what the consumers subscribe to
;;; (server/dev-bridge.scm's SIGNAL_TOPIC = localchimera/signals/deficit/#),
;;; and publish-one! carries the scope in the payload, round-tripping
;;; through the codec dev-bridge reads with.

(use-modules (localchimera test harness))
(use-modules )
(use-modules ((localchimera bridge signal-publisher)
              #:select (signal-topic publish-one!))
             ((localchimera bridge codec)
              #:select (json-string->signal))
             (srfi srfi-1))

(display "=== signal-topic: the subscribed shape ===\n")

(check "deficit signal topic"
       (equal? "localchimera/signals/deficit/spec-dev-x"
               (signal-topic '((kind . deficit) (spec-id . "spec-dev-x")))))

(check "spec-less signal topic"
       (equal? "localchimera/signals/surplus"
               (signal-topic '((kind . surplus)))))

;; dev-bridge subscribes localchimera/signals/deficit/# — every deficit topic
;; this door builds lands under that filter
(check "lands under dev-bridge's subscription"
       (string-prefix? "localchimera/signals/deficit/"
                       (signal-topic '((kind . deficit)
                                       (spec-id . "spec-dev-anything")))))

(display "\n=== publish-one!: scope in the payload ===\n")

(define captured '())
(define (capture-fn topic payload)
  (set! captured (cons (cons topic payload) captured)))

(let ((topic (publish-one! capture-fn "commune-a"
                           '((kind . deficit) (spec-id . "spec-dev-x")
                             (title . "a task")))))
  (check "returns the topic" (equal? "localchimera/signals/deficit/spec-dev-x" topic))
  (check "published once" (= 1 (length captured)))
  (let ((signal (json-string->signal (cdar captured))))
    (check "payload carries the scope" (equal? "commune-a" (assq-ref signal 'scope)))
    (check "payload carries the spec-id" (equal? "spec-dev-x" (assq-ref signal 'spec-id)))
    (check "payload carries the title" (equal? "a task" (assq-ref signal 'title)))))

;; a signal that already names its scope is published as-is
(let ((before (length captured)))
  (publish-one! capture-fn "commune-b"
                '((kind . deficit) (spec-id . "spec-y") (scope . "commune-a")))
  (let ((signal (json-string->signal (cdar captured))))
    (check "an existing scope key stands" (equal? "commune-a" (assq-ref signal 'scope)))))

(test-summary!)
