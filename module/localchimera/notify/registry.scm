;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/notify/registry.scm — the ONE notification registry.
;;;
;;; Phase 0 of the unified notification router (docs/notifications/
;;; UNIFIED-ROUTER.md). This is the single source of truth for how every
;;; semantic event is presented, replacing the three copies that used to
;;; drift independently:
;;;
;;;   • adapters/browser.scm  %notification-templates   (terse)
;;;   • adapters/email.scm    %email-templates          (rich)
;;;   • backends/scope.scm    scope-alert-formatter     (text strings)
;;;
;;; Author an event ONCE here. `#:type' and `#:tag' are channel-
;;; independent (they belong to the notification). `#:title'/`#:body'
;;; are the terse default; `#:rich-*' overrides email, `#:md-*' overrides
;;; telegram/matrix. A style that does not differ inherits terse for free.
;;;
;;; Callers use `render-notification':
;;;   (render-notification event 'terse)     ; browser, push, sms
;;;   (render-notification event 'rich)      ; email
;;;   (render-notification event 'markdown)  ; telegram, matrix
;;; -> (values type title body tag), or (values #f #f #f #f) for an
;;; unknown kind.

(define-module (localchimera notify registry)
  #:use-module (localchimera push templates)
  #:use-module (localchimera notify rendered)
  #:use-module (ice-9 format)
  #:export (%notify-registry
            render-notification
            notification-formatter
            buffer-zone-type))


;;; ── Channel-independent severity helpers ───────────────────────────

(define (buffer-zone-type event)
  "Buffer alerts are `alert' severity in the red/excess zones, else `info'."
  (let ((zone (assq-ref event 'zone)))
    (if (memq zone '(red excess)) 'alert 'info)))


;;; ── The registry ───────────────────────────────────────────────────
;;;
;;; terse  = former browser bodies (the default everywhere)
;;; rich   = former email bodies (multi-line)
;;; markdown = none yet — telegram/matrix inherit terse until they diverge.

(define %notify-registry
  (make-notification-templates

   ;; ── Planner ────────────────────────────────────────────────────
   `(buffer-status
     #:type       ,buffer-zone-type
     #:tag        "buffer-{spec-id}"
     #:title      "Buffer status"
     #:body       "{spec-id}: {onhand} on hand ({zone} zone)"
     #:rich-title "Buffer alert: {spec-id}"
     #:rich       "Buffer status change:\n\n  Item: {spec-id}\n  On hand: {onhand}\n  Zone: {zone}\n  Thresholds: red={tor} yellow={toy} green={tog}")

   '(adu-shift
     #:type   info
     #:tag    "adu-{spec-id}"
     #:title  "Demand shift"
     #:body   "{spec-id}: ADU {direction} {change-pct}%")

   '(material-sync
     #:type   alert
     #:tag    "material-{spec-id}"
     #:title  "Material shortage"
     #:body   "{spec-id}: {shortage} units short")

   '(unmatched-role
     #:type   alert
     #:tag    "role-{spec-id}"
     #:title  "Unmatched role"
     #:body   "No agent available for {spec-id}")

   ;; ── First-Person: a newcomer asks to be recognised ─────────────
   ;; Told to every recognised person; the tag is the ask's statement
   ;; SAID, so one ask reaches each channel once however it is re-read.
   '(enroll-ask
     #:type       info
     #:tag        "enroll-{said}"
     #:title      "Someone asks to be recognised"
     #:body       "{candidate} asks to be recognised — vouch on your calendar rail if you have met them"
     #:rich-title "Enrollment ask: {candidate}"
     #:rich       "A newcomer asks to be recognised as a person:\n\n  Candidate: {candidate}\n  Commune: {scope}\n\nIf you have met them, vouch on your calendar rail — your signature becomes an edge on their personhood credential.")

   ;; ── IPEX / credentials ─────────────────────────────────────────
   '(ipex-apply
     #:type       info
     #:tag        "ipex-apply-{said}"
     #:title      "Credential requested"
     #:body       "{requester} requests {schema}"
     #:rich-title "Credential request from {requester}"
     #:rich       "A credential has been requested:\n\n  Schema: {schema}\n  Requester: {requester}\n  SAID: {said}")

   '(ipex-offer
     #:type   info
     #:tag    "ipex-offer-{said}"
     #:title  "Credential offered"
     #:body   "{issuer} offered a credential")

   '(ipex-agree
     #:type   normal
     #:tag    "ipex-agree-{said}"
     #:title  "Offer accepted"
     #:body   "{holder} accepted, credential granted")

   '(ipex-admit
     #:type   normal
     #:tag    "ipex-admit-{said}"
     #:title  "Delivery confirmed"
     #:body   "Credential {cred-said} delivered")

   '(ipex-grant
     #:type       normal
     #:tag        "ipex-grant-{said}"
     #:title      "Credential received"
     #:body       "Received {schema} from {issuer}"
     #:rich-title "Credential received"
     #:rich       "You received a credential:\n\n  Schema: {schema}\n  Issuer: {issuer}\n  SAID: {said}")

   ;; ── Calendar ───────────────────────────────────────────────────
   '(commitment-due
     #:type       alert
     #:tag        "due-{id}"
     #:title      "Commitment due"
     #:body       "{title}: due {due-date}"
     #:rich-title "Due: {title}"
     #:rich       "A commitment is due:\n\n  {title}\n  Due: {due-date}\n  Scope: {scope}\n  Action: {action}")

   '(assignment-matched
     #:type       normal
     #:tag        "match-{id}"
     #:title      "Volunteer matched"
     #:body       "{provider-name} matched to {title}"
     #:rich-title "Matched: {provider-name} → {title}"
     #:rich       "A volunteer has been matched:\n\n  {provider-name} matched to {title}\n  {date} at {sh}:{sm}")

   '(event-reminder
     #:type       info
     #:tag        "reminder-{id}"
     #:title      "Upcoming: {title}"
     #:body       "{date} at {sh}:{sm}"
     #:rich-title "Reminder: {title}"
     #:rich       "You have an upcoming event:\n\n  {title}\n  {date} at {sh}:{sm}\n  Location: {location}\n  {description}")

   ;; ── Federation ─────────────────────────────────────────────────
   '(scope-admitted
     #:type   normal
     #:tag    "fed-admit-{scope-aid}"
     #:title  "Federation joined"
     #:body   "{scope-name} admitted")

   '(peer-offline
     #:type   alert
     #:tag    "peer-{peer-aid}"
     #:title  "Peer unreachable"
     #:body   "{peer-name} offline")))


;;; ── Public entry point ─────────────────────────────────────────────

(define* (render-notification event #:optional (style 'terse))
  "Render a canonical notification EVENT (an alist with a 'kind) in STYLE
   (terse | rich | markdown). Returns (values type title body tag), or
   (values #f #f #f #f) for an unknown kind."
  (%notify-registry event style))

(define (notification-formatter style)
  "An ^output-sink formatter that renders an event alist into a rendered
   notification (see `localchimera notify rendered') in STYLE. This is the ONE
   render point for a channel: adapters downstream stay dumb. Unknown
   kinds and bare strings fall back to a generic info notification so no
   channel breaks on data it doesn't recognise."
  (lambda (event)
    (if (string? event)
        (rendered-notification 'info "localchimera" event "")
        (call-with-values (lambda () (render-notification event style))
          (lambda (type title body tag)
            (if type
                (rendered-notification type title body tag)
                (rendered-notification 'info "localchimera"
                                       (format #f "~a" event) "")))))))
