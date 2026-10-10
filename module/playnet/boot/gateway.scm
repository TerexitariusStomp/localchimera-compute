;;; module/playnet/boot/gateway.scm — the gateway composed: every vat the process starts, in the order each needs the last.
;;;
;;; server/gateway.scm parses the arguments and calls boot-gateway!; this is
;;; the one place every actor of the process is named once. Each module of
;;; boot/ stands up one vat or one concern of the planner or gateway vat and
;;; says what it needs; what it returns is threaded here to the next. The
;;; order is the order of need: the KERIA tier and the persistent vats before
;;; fibers, then the wire, earth and the restored scopes, the store and the
;;; planner service, governance and its gates, the notification layer, the
;;; wallet, the key logs, the durable tree under the UC, and last the lobby,
;;; whose registration is what every browser tab connects to.

(define-module (playnet boot gateway)
  #:use-module ((playnet boot ai) #:select (spawn-ai-services! spawn-key-pool!))
  #:use-module ((playnet boot audits) #:select (watch-scopes!))
  #:use-module ((playnet boot bodies) #:select (spawn-bodies!))
  #:use-module ((playnet boot communes) #:select (seed-communes! stand-founding-commune!))
  #:use-module ((playnet boot credentials) #:select (reconcile-planner! spawn-credential-store! wire-credentialing!))
  #:use-module ((playnet boot earth) #:select (refresh-priors! spawn-earth!))
  #:use-module ((playnet boot federation) #:select (federate-founding-commune! serve-federations! write-federation-status!))
  #:use-module ((playnet boot governance) #:select (spawn-gateway-governance!))
  #:use-module ((playnet boot grants) #:select (start-pending-grants!))
  #:use-module ((playnet boot identity) #:select (mirror-key-logs! spawn-oobi-host!))
  #:use-module ((playnet boot keria) #:select (connect-keria! start-ipex-poller! start-peer-status-writer!))
  #:use-module ((playnet boot lobby) #:select (open-lobby! register-lobby-on-mesh!))
  #:use-module ((playnet boot mailbox) #:select (spawn-mailbox!))
  #:use-module ((playnet boot mesh) #:select (start-mesh!))
  #:use-module ((playnet boot monero) #:select (boot-monero!))
  #:use-module ((playnet boot notify) #:select (notify-router notify-telegram-backend spawn-notifications!))
  #:use-module ((playnet boot ocapn) #:select (register! spawn-ocapn!))
  #:use-module ((playnet boot personhood) #:select (announce-enrollments! make-root-recogniser poll-peer-witnesses!
                                                    rehydrate-asks! seed-founders! stand-first-person!))
  #:use-module ((playnet boot planner) #:select (install-planner-gates! spawn-planner! start-plan-tick!))
  #:use-module ((playnet boot repl) #:select (start-repl!))
  #:use-module ((playnet boot restore) #:select (replay-scope-state! restore-scopes!))
  #:use-module ((playnet boot signup) #:select (spawn-signup! spawn-terminal!))
  #:use-module ((playnet boot site) #:select (log! scopes-durable?))
  #:use-module ((playnet boot uc) #:select (poll-remote-scopes! stand-universal-commune!))
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
;; long as it stands. Found live 2026-09-23: an ENOSPC on one log
;; write killed the fiber three seconds before register, and every
;; fresh tab looped on "no object registered with swiss-num" for
;; hours. So a boot that dies leaves with a non-zero status: shepherd
;; respawns it, and a respawn that dies the same way is a failure the
;; box reports instead of one it hides. Said on stderr, since a log
;; write may be exactly what failed.
(define (leaving-on-failure thunk)
  "THUNK run so that an exception leaves the process with status 3."
  (with-exception-handler
   (lambda (e)
     (false-if-exception
      (let ((p (current-error-port)))
        (format p "~%  [gateway] BOOT FAILED — leaving so shepherd respawns: ~a~%"
                (with-exception-handler
                 (lambda (_) (object->string e))
                 (lambda ()
                   (if (exception-with-message? e)
                       (string-append (exception-message e) " "
                                      (object->string (exception-irritants e)))
                       (object->string e)))
                 #:unwind? #t))
        (force-output p)))
     (primitive-exit 3))
   thunk
   #:unwind? #t))

(define* (boot-gateway! #:key (host "0.0.0.0") (port 9090) (reticulum? #f))
  "Boot the gateway listening on HOST:PORT, with the Reticulum mesh when
RETICULUM? (or RETICULUM_BRIDGE_SOCKET). Holds the process open."
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
  (define-values (pool-vat key-pool) (spawn-key-pool!))

  ;; ── Under fibers (required by the WebSocket netlayer) ──
  (run-fibers
   (lambda ()
     (leaving-on-failure
      (lambda ()
        (start-ipex-poller!)
        ;; the wire
        (define-values (ocapn-vat ws-netlayer mycapn) (spawn-ocapn! host port))
        (define gateway-vat (spawn-vat #:name "gateway"))
        ;; earth and the durable scopes
        (define-values (planner-vat earth meeting-scope fc-key fc-aid-early) (spawn-earth! registry))
        (define restored (restore-scopes! gateway-vat planner-vat earth meeting-scope))
        (replay-scope-state! restored)
        ;; the store and the planner
        (define store (spawn-credential-store! planner-vat))
        (define planner-service
          (spawn-planner! #:planner-vat planner-vat #:earth earth #:meeting-scope meeting-scope #:store store))
        (refresh-priors! planner-vat meeting-scope)
        (wire-credentialing! planner-vat meeting-scope store fc-aid-early restored)
        (reconcile-planner! planner-vat meeting-scope store)
        ;; governance and the gates it hands the planner
        (define governance-svc
          (spawn-gateway-governance! #:planner-vat planner-vat #:planner-service planner-service
                                     #:meeting-scope meeting-scope #:store store))
        (define recognise-root! (make-root-recogniser planner-vat governance-svc))
        (install-planner-gates! #:planner-vat planner-vat #:planner-service planner-service
                                #:store store #:governance-svc governance-svc)
        (poll-peer-witnesses! planner-vat governance-svc recognise-root!)
        (start-pending-grants! planner-vat store)
        ;; the restored scopes watched, served and reported
        (define-values (auditors watchers) (watch-scopes! restored))
        (serve-federations! restored mycapn ws-netlayer)
        (start-peer-status-writer!)
        (start-plan-tick! planner-vat planner-service)
        (write-federation-status! auditors watchers)
        ;; how a person is reached
        (define notify
          (spawn-notifications! #:gateway-vat gateway-vat #:planner-vat planner-vat #:meeting-scope meeting-scope))
        (announce-enrollments! store (notify-router notify))
        (define mailbox-mgr (spawn-mailbox! registry))
        (define-values (ai-svc corpus-svc) (spawn-ai-services! gateway-vat pool-vat key-pool))
        (define terminal-svc (spawn-terminal! gateway-vat signup-vat signup-agent))
        ;; the wallet's cap
        (define-values (spend-policy fleet-reconciler)
          (boot-monero! #:gateway-vat gateway-vat #:ocapn-vat ocapn-vat #:mycapn mycapn
                        #:planner-vat planner-vat #:planner-service planner-service
                        #:meeting-scope meeting-scope #:fc-key fc-key #:store store
                        #:key-pool key-pool #:registry registry))
        ;; the key logs
        (define oobi-host (spawn-oobi-host! gateway-vat))
        (spawn-bodies! planner-vat gateway-vat planner-service oobi-host)
        (mirror-key-logs! signup-vat oobi-host restored)
        ;; the durable tree: the UC above, the founding commune and the
        ;; seeded communes under earth, First-Person anchored on it
        (define dev-commune #f)
        (when (scopes-durable?)
          (catch #t
            (lambda ()
              (define-values (scope-graph uc-ref)
                (stand-universal-commune! #:gateway-vat gateway-vat #:planner-service planner-service
                                          #:restored restored))
              (define-values (fc-aid fc-scope)
                (stand-founding-commune! #:planner-vat planner-vat #:earth earth
                                         #:meeting-scope meeting-scope #:planner-service planner-service
                                         #:governance-svc governance-svc #:fc-key fc-key
                                         #:fc-aid-early fc-aid-early #:restored restored))
              (when fc-aid
                (federate-founding-commune! #:planner-vat planner-vat #:planner-service planner-service
                                            #:store store #:fc-aid fc-aid #:fc-scope fc-scope
                                            #:mycapn mycapn #:ws-netlayer ws-netlayer)
                (rehydrate-asks! planner-vat governance-svc)
                (seed-founders! planner-vat store fc-aid fc-scope))
              (set! dev-commune
                    (seed-communes! #:planner-vat planner-vat #:earth earth #:planner-service planner-service))
              (stand-first-person! #:planner-vat planner-vat #:gateway-vat gateway-vat
                                   #:governance-svc governance-svc #:planner-service planner-service
                                   #:store store #:uc-ref uc-ref #:fc-aid fc-aid
                                   #:recognise-root! recognise-root!)
              (poll-remote-scopes! #:gateway-vat gateway-vat #:planner-vat planner-vat
                                   #:governance-svc governance-svc #:scope-graph scope-graph
                                   #:uc-ref uc-ref #:recognise-root! recognise-root!))
            (lambda (key . args)
              (log! "  [gateway] UC bootstrap failed: ~a ~a~%" key args))))
        ;; the lobby: what every tab connects to
        (define lobby
          (open-lobby! #:host host #:port port #:ocapn-vat ocapn-vat #:mycapn mycapn
                       #:gateway-vat gateway-vat #:planner-vat planner-vat
                       #:planner-service planner-service #:meeting-scope meeting-scope
                       #:signup-agent signup-agent #:ai-svc ai-svc #:notify notify
                       #:terminal-svc terminal-svc #:mailbox-mgr mailbox-mgr
                       #:spend-policy spend-policy #:governance-svc governance-svc
                       #:oobi-host oobi-host #:store store #:corpus-svc corpus-svc))
        (start-repl! `((gateway-vat      . ,gateway-vat)
                       (fleet-reconciler . ,fleet-reconciler)
                       (spend-policy     . ,spend-policy)
                       (lobby            . ,lobby)
                       (planner-service  . ,planner-service)
                       (meeting-scope    . ,meeting-scope)
                       (planner-vat      . ,planner-vat)
                       (dev-commune      . ,dev-commune)))
        ;; Register telegram-backend with OCapN — bridge enlivens this sref
        (register! ocapn-vat mycapn (notify-telegram-backend notify) 'websocket "telegram-backend-sref.txt"
                   #:say (lambda (uri) (log! "  telegram-backend sturdyref: ~a~%" uri)))
        ;; the mesh, registered once the lobby stands
        (start-mesh! #:ocapn-vat ocapn-vat #:gateway-vat gateway-vat #:mycapn mycapn
                     #:reticulum? reticulum?
                     #:on-wired (lambda () (register-lobby-on-mesh! ocapn-vat mycapn lobby)))
        ;; Hold open
        (perform-operation (wait-operation (make-condition))))))))
