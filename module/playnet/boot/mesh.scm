;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/boot/mesh.scm — the Reticulum mesh transport, wired when the bridge is reachable.
;;;
;;; Mesh is on with --reticulum or RETICULUM_BRIDGE_SOCKET. SOFT-DEGRADE,
;;; never crash: spawning the netlayer connects to the bridge control socket
;;; immediately, and a down / just-respawned / wrong-perms bridge used to
;;; abort the whole gateway boot — shepherd then crash-looped it until an
;;; operator fixed the socket (observed 2026-06-06: a bridge restart
;;; recreated its socket 0755 → gateway looped on connect EPERM, /ws down
;;; throughout). Now: boot without mesh, retry in a background fiber, wire
;;; everything on success.

(define-module (playnet boot mesh)
  #:use-module ((playnet boot site) #:select (data-path log!))
  #:use-module ((playnet doors lobby) #:select (current-mesh-announcer current-mesh-mailbox))
  #:use-module ((playnet gateway mesh-mailbox) #:select (mesh-delivery-stream! mesh-mailbox-spawn-from-dir))
  #:use-module (fibers)
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:use-module ((ice-9 threads) #:select (call-with-new-thread))
  #:export (start-mesh!))

(define (reticulum-control-path)
  (or (getenv "RETICULUM_BRIDGE_SOCKET")
      "/var/run/reticulum-bridge.sock"))

(define (reticulum-netlayer-constructor)
  "^reticulum-netlayer, resolved at run time: the module is loaded only when
mesh is on."
  (resolve-module '(goblins ocapn netlayer reticulum))
  (module-ref (resolve-interface '(goblins ocapn netlayer reticulum))
              '^reticulum-netlayer))

(define* (start-mesh! #:key ocapn-vat gateway-vat mycapn reticulum? on-wired)
  "The Reticulum netlayer installed into MYCAPN with the mesh mailbox and
its delivery stream, when RETICULUM? or RETICULUM_BRIDGE_SOCKET says so.
ON-WIRED runs once the netlayer stands: now, or from the retry fiber when
the bridge becomes reachable after boot. Nothing when mesh is off."
  (when (or reticulum? (getenv "RETICULUM_BRIDGE_SOCKET"))
    (let ((reticulum-control-path (reticulum-control-path))
          (^reticulum-netlayer (reticulum-netlayer-constructor)))
      (define (try-spawn-reticulum-netlayer)
        (catch #t
          (lambda ()
            (with-vat ocapn-vat
              (spawn ^reticulum-netlayer
                     #:control-path reticulum-control-path)))
          (lambda (key . args)
            (log! "  [gateway] reticulum bridge unreachable (~a ~s) — mesh off, will retry~%"
                  key args)
            #f)))

      (define (wire-reticulum! nl)
        (with-vat ocapn-vat
          (<- mycapn 'install-netlayer nl))
        ;; Wire the relay-announce path: ^lobby-session verifies a
        ;; browser persona's pre-signed announce against its
        ;; KEL-anchored pubkey, then forwards it here (announce-raw!
        ;; → bridge ANNOUNCE_RAW → mesh broadcast).
        (current-mesh-announcer nl)
        ;; Mesh mailbox: ciphertext custody for deliveries to offline
        ;; personas (LXMF step 3). A dedicated SUBSCRIBE connection to
        ;; the bridge streams DELIVERY lines into the mailbox; sessions
        ;; drain their own destinations (derived from the KEL anchor).
        (let ((mesh-mailbox
               (let ((dir (data-path "mesh-mailbox")))
                 (unless (file-exists? dir) (mkdir dir))
                 (with-vat gateway-vat
                   (mesh-mailbox-spawn-from-dir dir)))))
          (current-mesh-mailbox mesh-mailbox)
          ;; Delivery stream with reconnect: the stream returns/raises
          ;; whenever the bridge restarts; without the retry loop
          ;; deliveries silently stopped until a gateway restart.
          ;; A REAL THREAD, not a fiber: mesh-delivery-stream! does
          ;; blocking IO (connect + read-line on a plain port), which
          ;; inside spawn-fiber can wedge a fibers scheduler thread —
          ;; observed stalling the boot before sturdyref registration
          ;; in the mesh e2e harness.
          (call-with-new-thread
           (lambda ()
             (let retry ()
               (catch #t
                 (lambda ()
                   (mesh-delivery-stream!
                    reticulum-control-path
                    (lambda (dest payload)
                      (with-vat gateway-vat
                        (<- mesh-mailbox 'store! dest payload)))))
                 (lambda (key . args)
                   (log! "  [gateway] mesh delivery stream ended: ~a ~s — reconnecting in 5s~%"
                         key args)))
               (sleep 5)
               (retry))))
          (log! "  [gateway] mesh-mailbox + delivery stream wired~%"))
        (log! "  [gateway] Reticulum netlayer installed (control: ~a)~%"
              reticulum-control-path))

      (let ((nl (try-spawn-reticulum-netlayer)))
        (if nl
            (begin (wire-reticulum! nl) (on-wired))
            (spawn-fiber
             (lambda ()
               (let loop ()
                 (sleep 10)
                 (let ((nl (try-spawn-reticulum-netlayer)))
                   (if nl
                       (begin
                         (wire-reticulum! nl)
                         ;; Boot has long since passed the lobby block by
                         ;; now (first retry is t+10s); register it on the
                         ;; mesh ourselves. catch: belt for the freak case
                         ;; the lobby isn't up yet — next gateway restart
                         ;; would still converge.
                         (catch #t
                           on-wired
                           (lambda (key . args)
                             (log! "  [gateway] deferred lobby mesh registration failed: ~a ~s~%"
                                   key args))))
                       (loop)))))))))))
