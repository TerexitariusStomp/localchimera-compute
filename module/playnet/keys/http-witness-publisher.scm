;;; module/playnet/keys/http-witness-publisher.scm — kel-store
;;; subscriber that POSTs every event to remote witness URLs.
;;;
;;; Same protocol as ^scope-witness and ^oobi-host-mirror: receives
;;; `'mirror aid event-body` from a kel-store and side-effects. Here
;;; the side effect is `keri-publish-event!` which POSTs the body to
;;; each URL in KERI_WITNESS_PUSH_URLS. Best-effort; logs failures.
;;;
;;; Drop into `spawn-scope #:witnesses '(...)` alongside any in-vat
;;; mirrors to get cross-internet KEL distribution out of the box.

(define-module (playnet keys http-witness-publisher)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet keri witness-publisher)
  #:export (^http-witness-publisher
            spawn-http-witness-publisher))

(define-actor (^http-witness-publisher bcom)
  (methods
   ((mirror aid event-body)
    "Forward every signed KEL event to each witness URL in
     KERI_WITNESS_PUSH_URLS via HTTP POST. Returns the list of URLs
     that accepted (HTTP 2xx)."
    (keri-publish-event! aid event-body))))

(define (spawn-http-witness-publisher)
  "Spawn an HTTP witness publisher actor. URLs are read from the env
   var KERI_WITNESS_PUSH_URLS at each event (so the env can be edited
   live without respawning). Empty / unset → no-op."
  (spawn ^http-witness-publisher))
