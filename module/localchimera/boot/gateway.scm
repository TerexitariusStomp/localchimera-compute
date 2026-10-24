;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/boot/gateway.scm — the machine gateway composed: every vat the process starts, in the order each needs the last.
;;;
;;; server/gateway.scm parses the arguments and calls boot-gateway!; this is
;;; the one place every actor of the process is named once. The machine
;;; build is lean beside the old commons world: no earth, no scopes, no
;;; planner service — the machine registry answers offers/jobs/claims per
;;; commune-aid namespace (doors/machine.scm), identity is KERI, settlement
;;; is the machine settlement rail, and the lobby is what every browser tab
;;; connects to.

(define-module (localchimera boot gateway)
  #:use-module ((localchimera boot credentials) #:select (spawn-credential-store!))
  #:use-module ((localchimera boot governance) #:select (spawn-gateway-governance!))
  #:use-module ((localchimera boot grants) #:select (start-pending-grants!))
  #:use-module ((localchimera boot identity) #:select (mirror-key-logs! spawn-oobi-host!))
  #:use-module ((localchimera boot keria) #:select (connect-keria! start-ipex-poller! start-peer-status-writer!))
  #:use-module ((localchimera boot lobby) #:select (open-lobby! register-lobby-on-mesh!))
  #:use-module ((localchimera boot mailbox) #:select (spawn-mailbox!))
  #:use-module ((localchimera boot mesh) #:select (start-mesh!))
  #:use-module ((localchimera boot notify) #:select (spawn-notifications-slim! notify-router))
  #:use-module ((localchimera boot ocapn) #:select (register! spawn-ocapn!))
  #:use-module ((localchimera boot personhood) #:select (announce-enrollments!))
  #:use-module ((localchimera boot repl) #:select (start-repl!))
  #:use-module ((localchimera boot signup) #:select (spawn-signup!))
  #:use-module ((localchimera boot site) #:select (log!))
  #:use-module ((fibers conditions) #:select (make-condition wait-operation))
  #:use-module ((fibers operations) #:select (perform-operation))
  #:use-module (fibers)
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:use-module ((ice-9 exceptions) #:select (exception-irritants exception-message exception-with-message?))
  #:export (boot-gateway!))

;; The boot fiber is the one path to the registration at the very end
;; of this body — the sturdyref every browser tab connects to. When it
;; dies part-way, the vats it already spawned keep the process alive,
;; shepherd reports "running", and the sturdyref file on disk still
;; names the PREVIOUS process: a gateway that answers nothing, for as
;; long as it stands. So a boot that dies leaves with a non-zero
;; status: shepherd respawns it, and a respawn that dies the same way
;; is a failure the box reports instead of one it hides. Said on
;; stderr, since a log write may be exactly what failed.
(define (leaving-on-failure thunk)
  (catch #t
    thunk
    (lambda (key . args)
      (let ((p (current-error-port)))
        (format p "~%gateway boot failed: ~a ~a~%" key
                (if (and (exception-with-message? key)
                         (exception-irritants key))
                    (list (exception-message key)
                          (exception-irritants key))
                    args))
        (force-output p)
        (primitive-exit 1)))))

(define* (boot-gateway! #:key (host "0.0.0.0") (port 9090) (reticulum? #f))
  "Boot the machine-resource gateway listening on HOST:PORT, with the
Reticulum mesh when RETICULUM? (or RETICULUM_BRIDGE_SOCKET). Holds the
process open."
  ;; Reseed the PRNG from the platform: label codes and event ids draw from it,
  ;; and an unseeded state repeats the same draws after every restart.
  (set! *random-state* (random-state-from-platform))

  ;; ── Before fibers: the KERIA tier and the vats that need no scheduler ──
  (connect-keria!)
  ;; Persistence registry, shared across all persistent vats. Spawned fresh
  ;; each start — not itself persisted. Enables far-ref resolution across
  ;; local vats on rehydration.
  (define persistence-vat (spawn-vat #:name "persistence"))
  (define registry (with-vat persistence-vat (spawn ^persistence-registry)))
  (define-values (signup-vat signup-agent) (spawn-signup! registry))

  ;; ── Under fibers (required by the WebSocket netlayer) ──
  (run-fibers
   (lambda ()
     (leaving-on-failure
      (lambda ()
        (start-ipex-poller!)
        ;; the wire
        (define-values (ocapn-vat ws-netlayer mycapn) (spawn-ocapn! host port))
        (define gateway-vat (spawn-vat #:name "gateway"))
        ;; the credential store the personhood and machine doors check
        (define store (spawn-credential-store! gateway-vat))
        ;; governance: five fragments — personhood, delegation, economy,
        ;; federation, machine. No planner, no scopes: scope-roots '() and
        ;; a #f ballot store — machine disputes sortition from the citizen
        ;; registry the service itself keeps.
        (define governance-svc
          (spawn-gateway-governance! #:gateway-vat gateway-vat #:store store))
        ;; custody-grant fulfillment watching (the my-grants door's half)
        (start-pending-grants! gateway-vat store)
        ;; notifications, machine-edition: presence, push, the recipient
        ;; registry and the contact-point desk — none of the scope handlers
        ;; or chat bridges the commons build carried
        (define notify (spawn-notifications-slim! #:gateway-vat gateway-vat))
        (announce-enrollments! store (notify-router notify))
        (define mailbox-mgr (spawn-mailbox! registry))
        ;; the key logs a presented bundle verifies against
        (define oobi-host (spawn-oobi-host! gateway-vat))
        (mirror-key-logs! signup-vat oobi-host '())
        (start-peer-status-writer!)
        ;; the lobby: what every tab connects to
        (define lobby
          (open-lobby! #:host host #:port port #:ocapn-vat ocapn-vat #:mycapn mycapn
                       #:gateway-vat gateway-vat
                       #:signup-agent signup-agent #:notify notify
                       #:mailbox-mgr mailbox-mgr #:governance-svc governance-svc
                       #:oobi-host oobi-host #:store store))
        (start-repl! `((gateway-vat      . ,gateway-vat)
                       (lobby            . ,lobby)
                       (governance-svc   . ,governance-svc)))
        ;; the mesh, registered once the lobby stands
        (start-mesh! #:ocapn-vat ocapn-vat #:gateway-vat gateway-vat #:mycapn mycapn
                     #:reticulum? reticulum?
                     #:on-wired (lambda () (register-lobby-on-mesh! ocapn-vat mycapn lobby)))
        ;; Hold open
        (perform-operation (wait-operation (make-condition))))))))
