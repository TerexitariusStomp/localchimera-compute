;;; module/playnet/boot/lobby.scm — the lobby over everything a session reaches, registered on the wire, and the HTTP door over it.

(define-module (playnet boot lobby)
  #:use-module ((playnet boot notify) #:select (notify-contact-desk notify-presence notify-push-store
                                                notify-recipient-registry notify-vapid-public-b64))
  #:use-module ((playnet boot ocapn) #:select (register!))
  #:use-module ((playnet boot site) #:select (log!))
  #:use-module ((playnet doors lobby) #:select (%default-ice-urls ^lobby ^lobby-session ice-servers-from-urls
                                                seed-pins! seed-taxonomy-docs!))
  #:use-module ((playnet folksonomy pins) #:select (^pins make-pins))
  #:use-module ((playnet folksonomy seed) #:select (seed-folksonomy!))
  #:use-module ((playnet gateway http-door-server) #:select (start-http-door!))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (open-lobby! register-lobby-on-mesh!))

(define* (open-lobby! #:key host port ocapn-vat mycapn gateway-vat planner-vat planner-service
                      meeting-scope signup-agent ai-svc notify terminal-svc mailbox-mgr spend-policy
                      governance-svc oobi-host store corpus-svc)
  "The folksonomy and the pin book seeded, the lobby spawned in GATEWAY-VAT,
registered on the websocket transport (its sturdyref kept at
gateway-sref.txt), and the HTTP door opened over it. Returns the lobby."
  (define presence-actor     (notify-presence notify))
  (define push-store         (notify-push-store notify))
  (define recipient-registry (notify-recipient-registry notify))
  (define contact-desk       (notify-contact-desk notify))
  (define vapid-pub-b64      (notify-vapid-public-b64 notify))
  ;; ── Folksonomy aggregator ───────────────────────────────────────
  ;; The service's UC folksonomy root — the fifth fold through the
  ;; add-scope! door, so per-scope nodes stand under it and move-scope!
  ;; carries taxonomy like every other aggregate. The lobby's
  ;; `sync-taxonomy` contributes each AID's published cut here and
  ;; `template` answers the commons' spine (using is voting).
  (define folksonomy-actor
    (with-vat planner-vat ($ planner-service 'folksonomy-uc)))
  ;; a restart empties the fold; the stored cuts refill it at once
  (with-vat gateway-vat (seed-taxonomy-docs! folksonomy-actor))

  ;; Seed the folksonomy with a first cut from the scope's own
  ;; classifications (folksonomy/seed.scm): specs' resource-classified-as
  ;; → flat terms + edges, contributed as the commons' starting spine.
  (with-vat planner-vat (seed-folksonomy! folksonomy-actor meeting-scope))
  ;; the pin book beside it: citizens' SHARED map lists, folded the same
  ;; way (folksonomy/pins.scm) — one book for the commons
  (define pins-actor
    (with-vat planner-vat (spawn ^pins (make-pins) '() "uc")))
  ;; a restart empties the fold; the stored books refill it at once
  (with-vat gateway-vat (seed-pins! pins-actor))

  ;; The servers a call finds its peers through: PLAYNET_ICE_URLS
  ;; (comma-separated; set it empty for none), else the lobby's default.
  ;; The browser asks the lobby's `ice-servers` door and holds no list.
  (define ice-list
    (ice-servers-from-urls (or (getenv "PLAYNET_ICE_URLS") %default-ice-urls)))

  (define lobby
    (with-vat gateway-vat
      (spawn ^lobby signup-agent ai-svc
             presence-actor terminal-svc mailbox-mgr
             planner-service spend-policy governance-svc
             oobi-host store
             push-store vapid-pub-b64
             folksonomy-actor recipient-registry
             corpus-svc pins-actor
             ice-list contact-desk)))

  ;; Register lobby with OCapN — get sturdyref
  (register! ocapn-vat mycapn lobby 'websocket "gateway-sref.txt"
             #:say (lambda (uri)
                     (log! "~%  playnet OCapN gateway on ws://~a:~a~%" host port)
                     (log! "  sturdyref: ~a~%~%" uri)))

  ;; The HTTP door (module/playnet/doors/http.scm): the same doors
  ;; over POST /api/<object>/<name>, signed by an enrolled device key,
  ;; on loopback — nginx proxies the three /api/ prefixes here. A
  ;; person's HTTP session is the device-tier ^lobby-session
  ;; keri-authenticate-device would spawn, kept warm per person.
  (start-http-door!
   #:port (string->number (or (getenv "PLAYNET_API_PORT") "9091"))
   #:lobby lobby
   #:vat gateway-vat
   #:log log!
   #:spawn-session
   (lambda (person-aid)
     (spawn ^lobby-session person-aid
            terminal-svc mailbox-mgr governance-svc signup-agent
            oobi-host store folksonomy-actor presence-actor
            push-store recipient-registry planner-service
            'device pins-actor #f #f contact-desk)))
  lobby)

(define (register-lobby-on-mesh! ocapn-vat mycapn lobby)
  "LOBBY registered on the Reticulum transport, its sturdyref kept at
gateway-ret-sref.txt; called when the mesh netlayer stands (boot/mesh)."
  (register! ocapn-vat mycapn lobby 'reticulum "gateway-ret-sref.txt"
             #:say (lambda (ret-uri)
                     ;; Extract destination hash from ocapn://<hash>.reticulum/...
                     ;; string-split on #\/ gives ("ocapn:" "" "<hash>.reticulum" ...)
                     (let ((dest-hash
                            (let ((authority (caddr (string-split ret-uri #\/))))
                              (car (string-split authority #\.)))))
                       (log! "  reticulum sturdyref: ~a~%" ret-uri)
                       (log! "  reticulum destination hash: ~a~%~%" dest-hash)))))
