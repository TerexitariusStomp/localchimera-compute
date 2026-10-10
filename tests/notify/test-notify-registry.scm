;;; test-notify-registry.scm — golden tests for the ONE notification
;;; registry (Phase 0 of the unified router).
;;;
;;; Locks the folded-together content: terse (former browser), rich
;;; (former email), the terse-fallback for un-overridden styles, the
;;; channel-independent type/tag, dynamic severity, and unknown kinds.
;;;
;;; Run: guile -L module tests/notify/test-notify-registry.scm

(use-modules (playnet test harness)
             (playnet notify registry))

;; Render helper: collapse the (values type title body tag) into a list.
(define (r event style)
  (call-with-values (lambda () (render-notification event style)) list))
(define (r-type e s)  (list-ref (r e s) 0))
(define (r-title e s) (list-ref (r e s) 1))
(define (r-body e s)  (list-ref (r e s) 2))
(define (r-tag e s)   (list-ref (r e s) 3))

;; ── sample canonical notifications ─────────────────────────────────
(define buffer-red
  '((kind . buffer-status) (spec-id . "tomato") (zone . red)
    (onhand . 3) (tor . 5) (toy . 10) (tog . 20)))
(define buffer-green
  '((kind . buffer-status) (spec-id . "tomato") (zone . green)
    (onhand . 18) (tor . 5) (toy . 10) (tog . 20)))
(define adu
  '((kind . adu-shift) (spec-id . "corn") (direction . up) (change-pct . 12)))
(define apply-ev
  '((kind . ipex-apply) (requester . "alice") (schema . "member") (said . "EAB")))
(define due-ev
  '((kind . commitment-due) (id . "c1") (title . "Deliver") (due-date . "2026-08-01")
    (scope . "coop") (action . "ship")))
(define unknown '((kind . no-such-kind)))


(display "\n── terse style (browser wording) ──\n")
(check "buffer terse title" (r-title buffer-red 'terse) "Buffer status")
(check "buffer terse body"  (r-body buffer-red 'terse) "tomato: 3 on hand (red zone)")
(check "adu terse body"     (r-body adu 'terse) "corn: ADU up 12%")
(check "ipex-apply terse body" (r-body apply-ev 'terse) "alice requests member")
(check "commitment terse body" (r-body due-ev 'terse) "Deliver: due 2026-08-01")

(display "\n── rich style (email wording) ──\n")
(check "buffer rich title" (r-title buffer-red 'rich) "Buffer alert: tomato")
(check "buffer rich body"  (r-body buffer-red 'rich)
       "Buffer status change:\n\n  Item: tomato\n  On hand: 3\n  Zone: red\n  Thresholds: red=5 yellow=10 green=20")
(check "ipex-apply rich title" (r-title apply-ev 'rich) "Credential request from alice")
(check "commitment rich body" (r-body due-ev 'rich)
       "A commitment is due:\n\n  Deliver\n  Due: 2026-08-01\n  Scope: coop\n  Action: ship")

(display "\n── un-overridden styles fall back to terse ──\n")
(check "adu rich falls back to terse title" (r-title adu 'rich) (r-title adu 'terse))
(check "adu rich falls back to terse body"  (r-body adu 'rich)  (r-body adu 'terse))
(check "adu markdown falls back to terse body" (r-body adu 'markdown) "corn: ADU up 12%")
(check "buffer markdown title = terse title (no md override)"
       (r-title buffer-red 'markdown) "Buffer status")

(display "\n── type + tag are channel-independent ──\n")
(check "buffer red type = alert (terse)"  (r-type buffer-red 'terse) 'alert)
(check "buffer red type = alert (rich)"   (r-type buffer-red 'rich)  'alert)
(check "buffer green type = info (dynamic)" (r-type buffer-green 'terse) 'info)
(check "buffer green type same in rich"     (r-type buffer-green 'rich)  'info)
(check "buffer tag terse" (r-tag buffer-red 'terse) "buffer-tomato")
(check "buffer tag same across styles" (r-tag buffer-red 'rich) (r-tag buffer-red 'terse))
(check "ipex-apply tag" (r-tag apply-ev 'terse) "ipex-apply-EAB")
(check "commitment tag" (r-tag due-ev 'rich) "due-c1")

(display "\n── unknown kind ──\n")
(check "unknown type is #f"  (r-type unknown 'terse) #f)
(check "unknown title is #f" (r-title unknown 'terse) #f)
(check "unknown body is #f"  (r-body unknown 'rich) #f)

(test-summary!)
