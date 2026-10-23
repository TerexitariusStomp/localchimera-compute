;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-notify-adapters.scm — Phase 1 of the unified router: the render
;;; point moved OUT of the adapters into the sink formatter, leaving the
;;; adapters as dumb consumers of a rendered notification.
;;;
;;; Covers the two new pure pieces:
;;;   • notification-formatter — event alist -> rendered notification
;;;   • the rendered shape + rendered->text (transport-side collapse)
;;;
;;; The adapters themselves are now trivial field-mappers over `<-np'; the
;;; live wiring is exercised end-to-end by the keri-notifications and ipex
;;; integration suites.
;;;
;;; Run: guile -L module tests/notify/test-notify-adapters.scm

(use-modules (playnet test harness)
             (playnet notify rendered)
             (playnet notify registry))

;; sample canonical notifications
(define buf
  '((kind . buffer-status) (spec-id . "tomato") (zone . red)
    (onhand . 3) (tor . 5) (toy . 10) (tog . 20)))
(define buf-green
  '((kind . buffer-status) (spec-id . "tomato") (zone . green) (onhand . 18)))

(display "\n── rendered shape ──\n")
(let ((r (rendered-notification 'alert "Title" "Body" "buf-1")))
  (check "rendered? recognises a rendered alist" (rendered? r) #t)
  (check "rendered? rejects an event alist" (rendered? buf) #f)
  (check "rendered-type"  (rendered-type r) 'alert)
  (check "rendered-title" (rendered-title r) "Title")
  (check "rendered-body"  (rendered-body r) "Body")
  (check "rendered-tag"   (rendered-tag r) "buf-1"))

(display "\n── rendered->text (line-oriented transports) ──\n")
(check "joins title + body"
       (rendered->text (rendered-notification 'info "T" "B" "")) "T\n\nB")
(check "body only when title empty"
       (rendered->text (rendered-notification 'info "" "B" "")) "B")
(check "title only when body empty"
       (rendered->text (rendered-notification 'info "T" "" "")) "T")
(check "passes a bare string through"
       (rendered->text "already text") "already text")

(display "\n── notification-formatter: the ONE render point ──\n")
(let ((terse (notification-formatter 'terse))
      (rich  (notification-formatter 'rich)))
  (check "terse produces a rendered alist" (rendered? (terse buf)) #t)
  (check "terse body"  (rendered-body (terse buf)) "tomato: 3 on hand (red zone)")
  (check "terse title" (rendered-title (terse buf)) "Buffer status")
  (check "terse carries dynamic type (red -> alert)" (rendered-type (terse buf)) 'alert)
  (check "terse dynamic type (green -> info)" (rendered-type (terse buf-green)) 'info)
  (check "terse tag" (rendered-tag (terse buf)) "buffer-tomato")
  (check "rich overrides title" (rendered-title (rich buf)) "Buffer alert: tomato")
  (check "rich body is the multi-line form"
         (rendered-body (rich buf))
         "Buffer status change:\n\n  Item: tomato\n  On hand: 3\n  Zone: red\n  Thresholds: red=5 yellow=10 green=20")
  ;; robustness: unknown kinds and bare strings never break a channel
  (check "unknown kind falls back to info type" (rendered-type (terse '((kind . nope)))) 'info)
  (check "unknown kind falls back to playnet title" (rendered-title (terse '((kind . nope)))) "playnet")
  (check "bare string becomes the body" (rendered-body (terse "ping")) "ping")
  (check "bare string keeps info type" (rendered-type (terse "ping")) 'info))

(test-summary!)
