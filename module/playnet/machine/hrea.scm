;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/machine/hrea.scm — the ValueFlows landing pad for a
;;; compute receipt: hREA (Apache-2.0) is the adopted VF backend; this is
;;; the wire shape a receipt becomes when it lands there, plus the seam
;;; the transport plugs into.
;;;
;;; A receipt is already an accounting fact — it meters seconds/tokens,
;;; names the lender, ties to the job's spec. In ValueFlows vocabulary
;;; that is an EconomicEvent of action 'use (the lender's resource was
;;; used) — or 'work where the commons counts labor contribution — with
;;; resourceQuantity carrying the meter and the receipt's digest riding
;;; as the event's note/tracking identifier.
;;;
;;; WHAT IS HERE:
;;;   • receipt->economic-event — the GraphQL mutation input: action,
;;;     provider, receiver, resourceQuantity, note (the digest), and the
;;;     agreement/spec anchors where the job names them.
;;;   • %hrea-unavailable — the fail-closed transport.
;;;   • record-receipt! — (receipt commune #:key post) → the event id the
;;;     service answers, or 'unavailable when no service is wired.
;;;
;;; Nothing here runs accounting — hREA owns that. This module's whole
;;; job is that the wire it lands is the wire a hREA instance reads.

(define-module (playnet machine hrea)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:use-module (playnet machine receipt)
  #:use-module (playnet machine registry)
  #:export (receipt->economic-event record-receipt! %hrea-unavailable))


(define (%hrea-unavailable . _)
  (error "hrea: no transport injected — service not wired"))


;;; ── the wire shape ───────────────────────────────────────────────────────
;;; hREA's createEconomicEvent input. action 'use for metered resource
;;; draw; the unit vocabulary rides through as the envelope metered it.

(define* (receipt->economic-event receipt #:key (commune-aid #f)
                                   (spec-id #f) (agreement-id #f))
  "The hREA createEconomicEvent payload for a compute receipt."
  (let ((u (receipt-usage receipt)))
    `(("action" . "use")
      ("provider" . ,(receipt-lender-did receipt))
      ("receiver" . ,(or commune-aid ""))
      ("resourceQuantity" . (("hasNumericalValue" . ,(and u (usage-meter-amount u)))
                             ("hasUnit"          . ,(and u (usage-meter-unit u)))))
      ("effortQuantity"   . (("hasNumericalValue" . ,(and u (usage-meter-amount u)))
                             ("hasUnit"          . ,(and u (usage-meter-unit u)))))
      ;; the receipt digest IS the event's tracking handle — the hive's
      ;; reconcile reads it back and finds this same string.
      ("note" . ,(receipt-digest receipt))
      ("resourceConformsTo" . ,(or spec-id ""))
      ("satisfies" . ,(and agreement-id `((("satisfies" . ,agreement-id))))))))


;;; ── the seam ─────────────────────────────────────────────────────────────

(define* (record-receipt! receipt #:key (commune-aid #f) (spec-id #f)
                          (post %hrea-unavailable))
  "Land the receipt's EconomicEvent on the wired hREA; answers the event
   id. post: (lambda (query variables) → parsed-response) — the GraphQL
   call. Absent one: 'unavailable, fail-closed, nothing recorded."
  (let ((resp (post "createEconomicEvent"
                    `(("event" . ,(receipt->economic-event
                                   receipt #:commune-aid commune-aid
                                   #:spec-id spec-id))))))
    (assq-ref resp 'id)))
