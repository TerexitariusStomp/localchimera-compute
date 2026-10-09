;;; module/playnet/identity/oobi-host-mirror.scm — bridge ^kel-store
;;; events into the existing ^oobi-host so scope KELs are served at
;;; the well-known KERI OOBI HTTP endpoints.
;;;
;;; Reuse note: `^oobi-host` (`module/playnet/identity/oobi-host.scm`) and
;;; `serve-static.scm` already serve `/oobi/{aid}` (CESR text stream)
;;; and `/.well-known/keri/oobi/{aid}` (KERI well-known well-known
;;; path) over HTTP, with durable on-disk storage. We do not need a
;;; new HTTP server for autonomous-signer scope KELs — this adapter
;;; is the entire bridge.
;;;
;;; A `^oobi-host-mirror` actor conforms to the kel-store subscriber
;;; protocol (it accepts `'mirror aid event-body`). On each call it
;;; routes the event into the wrapped oobi-host:
;;;
;;;   - icp event → `(put! aid icp-alist sigs)`
;;;   - rot event → `(append-rotation! aid rot-alist sigs)`
;;;
;;; Pass an instance of this actor in `spawn-scope #:witnesses` and
;;; the scope's KEL is automatically mirrored into the oobi-host's
;;; HTTP-visible state.
;;;
;;; The gateway spawns this actor in signup-vat and OOBI-HOST-REF in
;;; gateway-vat (server/gateway.scm: "^oobi-host … Lives in gateway-vat
;;; so ^lobby's keri-authenticate handler can call it synchronously"),
;;; so every call this actor makes on OOBI-HOST-REF is cross-vat and
;;; MUST go through `<-`, never `$` — the same rule as kel-store's own
;;; broadcast to this actor. A same-vat test rig (host and mirror both
;;; spawned in one vat, as an in-process test naturally does) cannot
;;; tell `$` and `<-` apart here; only the gateway's real two-vat
;;; wiring exercises the difference, and `$` failed it silently caught
;;; and logged only as "not-callable … Not in the same vat" — every
;;; scope AID this actor ever mirrored was dropped.

(define-module (playnet identity oobi-host-mirror)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet governance kel-store)
  #:export (^oobi-host-mirror
            spawn-oobi-host-mirror))

(define-actor (^oobi-host-mirror bcom oobi-host-ref)
  (methods
   ((mirror label event-body)
    "Receive a signed KEL event body from a scope's kel-store and
     register it with the wrapped oobi-host. The entry is filed under
     the event's own `i` — the identifier a resolver keys its KEL by
     and the path it fetches, /oobi/{i}. LABEL is the name the scope
     stack passes; for a scope it is the qb64 of the inception key,
     which names the scope internally and is not a KERI identifier.
     Idempotent: oobi-host's own put!/append-rotation! are tolerant of
     replays in practice (put! overwrites; append-rotation! accumulates
     — the caller may want to dedup before re-feeding a full chain)."
    (let* ((inner (or (assoc-ref event-body "icp")
                      (assoc-ref event-body "rot")))
           (aid   (or (kel-event-aid event-body) label))
           (sigs  (or (assoc-ref event-body "sigs") #()))
           (type  (kel-event-type event-body)))
      (cond
       ((not inner) 'no-event)
       ((string=? type "icp")
        (<- oobi-host-ref 'put! aid inner sigs)
        ;; Framed OKEA endpoint replies ride alongside the icp when the
        ;; scope was created with #:endpoint-url (the only moment its
        ;; keypair is in hand to endorse them). Forward them so the OOBI
        ;; body advertises WHERE the AID is, not just WHO (OOBI §3.4).
        (let ((replies (assoc-ref event-body "replies")))
          (when (and (vector? replies) (positive? (vector-length replies)))
            (<- oobi-host-ref 'set-replies! aid replies)))
        ;; Witness receipt streams ride alongside a witnessed (bt>0)
        ;; inception — without them resolvers escrow the KEL. Forward
        ;; so the served OOBI carries them right after the event.
        (let ((receipts (assoc-ref event-body "receipts")))
          (when (and (vector? receipts) (positive? (vector-length receipts)))
            (<- oobi-host-ref 'set-receipts! aid receipts)))
        'icp-registered)
       ((string=? type "rot")
        (<- oobi-host-ref 'append-rotation! aid inner sigs)
        'rotation-appended)
       (else 'unsupported-event))))

   ((oobi-host) oobi-host-ref)))

(define (spawn-oobi-host-mirror oobi-host-ref)
  "Spawn an adapter actor that subscribes to scope kel-stores and
   routes their events into OOBI-HOST-REF for HTTP serving."
  (spawn ^oobi-host-mirror oobi-host-ref))
