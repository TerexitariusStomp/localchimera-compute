#!/usr/bin/env -S guile -L module
!#
;;; server/weave.scm — Weave HTTP server
;;;
;;; Serves static browser assets and the token/room API.
;;; Run from project root: guile -L module server/weave.scm [port]
;;;
;;; Environment variables:
;;;   LIVEKIT_API_KEY    — LiveKit API key
;;;   LIVEKIT_API_SECRET — LiveKit API secret
;;;   LIVEKIT_HOST       — LiveKit server URL (default: http://localhost:7880)
;;;   LIVEKIT_WS_HOST    — LiveKit WebSocket URL for browser SDK (default: ws://localhost:7880)
;;;   WEAVE_PORT         — HTTP port (default: 8081)

(use-modules (web server)
             (web request)
             (web response)
             (web uri)
             (ice-9 match)
             (ice-9 format)
             (ice-9 binary-ports)
             (rnrs bytevectors)
             (ice-9 iconv)
             (json)
             (goblins)
             (goblins actor-lib methods)
             (weave auth)
             (weave livekit)
             (weave room))

;;; ── Vat + room manager ────────────────────────────────────────────────────────

(define *vat*          (spawn-vat #:name "weave"))
(define *room-manager* (with-vat *vat* (spawn ^room-manager)))

;;; ── Static asset paths ───────────────────────────────────────────────────────

(define *assets-dir*
  (let ((here (dirname (or (current-filename)
                           (canonicalize-path "server/weave.scm")))))
    (string-append (dirname here) "/weave")))

(define (asset-path filename)
  (string-append *assets-dir* "/" filename))

(define (read-file-bv path)
  "Read file at PATH as a bytevector, or #f if not found."
  (catch #t
    (lambda ()
      (call-with-input-file path get-bytevector-all
        #:binary #t))
    (lambda _ #f)))

;;; ── Response helpers ─────────────────────────────────────────────────────────

(define (respond-ok content-type body)
  (values (build-response
           #:code 200
           #:headers `((content-type . (,content-type))
                       (access-control-allow-origin . "*")))
          body))

(define (respond-json alist)
  (respond-ok 'application/json
              (string->bytevector (scm->json-string alist) "UTF-8")))

(define (respond-not-found path)
  (values (build-response #:code 404
                          #:headers '((content-type . (text/plain))))
          (string->bytevector (string-append "Not found: " path) "UTF-8")))

(define (respond-error code message)
  (values (build-response #:code code
                          #:headers '((content-type . (application/json))
                                      (access-control-allow-origin . "*")))
          (string->bytevector (scm->json-string `((error . ,message))) "UTF-8")))

(define (respond-file filename content-type)
  (let ((bv (read-file-bv (asset-path filename))))
    (if bv
        (respond-ok content-type bv)
        (respond-not-found filename))))

;;; ── Request parsing ──────────────────────────────────────────────────────────

(define (request-path req)
  (uri-path (request-uri req)))

(define (request-query-params req)
  "Parse query string into an alist of string pairs."
  (let ((q (uri-query (request-uri req))))
    (if (or (not q) (string-null? q))
        '()
        (map (lambda (pair)
               (let ((kv (string-split pair #\=)))
                 (cons (car kv) (if (null? (cdr kv)) "" (cadr kv)))))
             (string-split q #\&)))))

(define (parse-json-body body)
  (catch #t
    (lambda ()
      (json-string->scm (bytevector->string body "UTF-8")))
    (lambda _ '())))

;;; ── API handlers ─────────────────────────────────────────────────────────────

(define (handle-create-room body-alist)
  "POST /api/rooms — create a LiveKit room and register it."
  (let* ((name    (or (assoc-ref body-alist "name")
                      (assoc-ref body-alist 'name)
                      (with-vat *vat* (make-room-id))))
         (_       (livekit-create-room name))          ; create in LiveKit
         (id+ref  (with-vat *vat*
                    ($ *room-manager* 'create-room! name)))
         (id      (car id+ref)))
    (respond-json `((room_id . ,id)
                    (name    . ,name)
                    (status  . "open")))))

(define (handle-get-token room-id params)
  "POST /api/rooms/:id/token — generate a LiveKit access token."
  (let* ((identity  (or (assoc-ref params "identity") "guest"))
         (role-str  (or (assoc-ref params "role") "participant"))
         (role      (string->symbol role-str))
         (display-n (or (assoc-ref params "display_name") identity))
         (room-ref  (with-vat *vat* ($ *room-manager* 'get-room room-id))))
    (if (not room-ref)
        (respond-error 404 (string-append "Room not found: " room-id))
        (let* ((lk-identity (string-append identity "-" room-id))
               (token (make-livekit-token
                       (livekit-api-key) (livekit-api-secret)
                       room-id lk-identity role))
               (ws-host (or (getenv "LIVEKIT_WS_HOST") "ws://localhost:7880")))
          ;; Record occupant in room actor
          (with-vat *vat*
            ($ room-ref 'join! identity display-n role 'named lk-identity))
          (respond-json `((token       . ,token)
                          (livekit_url . ,ws-host)
                          (identity    . ,lk-identity)
                          (room_id     . ,room-id)))))))

;;; ── CORS preflight ───────────────────────────────────────────────────────────

(define (handle-options)
  (values (build-response
           #:code 204
           #:headers '((access-control-allow-origin  . "*")
                       (access-control-allow-methods . "GET, POST, OPTIONS")
                       (access-control-allow-headers . "Content-Type, Authorization")))
          #vu8()))

;;; ── Main request handler ─────────────────────────────────────────────────────

(define (weave-handler request body)
  (let ((method (request-method request))
        (path   (request-path request)))

    (format (current-error-port) "~a ~a\n" method path)

    (match (list method path)
      ;; Static assets
      (('GET "/")             (respond-file "weave.html" 'text/html))
      (('GET "/weave.html")   (respond-file "weave.html" 'text/html))
      (('GET "/weave.js")     (respond-file "weave.js"   'application/javascript))
      (('GET "/weave.css")    (respond-file "weave.css"  'text/css))
      (('GET "/weave.wasm")   (respond-file "weave.wasm" 'application/wasm))

      ;; CORS preflight
      (('OPTIONS _) (handle-options))

      ;; API: create room
      (('POST "/api/rooms")
       (catch #t
         (lambda ()
           (handle-create-room (parse-json-body body)))
         (lambda (key . args)
           (format (current-error-port) "create-room error: ~a ~a\n" key args)
           (respond-error 500 (format #f "~a" args)))))

      ;; API: get token — path /api/rooms/<id>/token
      ((method path)
       (cond
        ((and (eq? method 'POST)
              (string-prefix? "/api/rooms/" path)
              (string-suffix? "/token" path))
         (let* ((mid    (substring path (string-length "/api/rooms/")
                                        (- (string-length path)
                                           (string-length "/token"))))
                (params (parse-json-body body)))
           (catch #t
             (lambda () (handle-get-token mid params))
             (lambda (key . args)
               (format (current-error-port) "get-token error: ~a ~a\n" key args)
               (respond-error 500 (format #f "~a" args))))))

        (else (respond-not-found path)))))))

;;; ── Entry point ──────────────────────────────────────────────────────────────

(define (main)
  (let ((port (string->number
               (or (getenv "WEAVE_PORT")
                   (if (> (length (command-line)) 1)
                       (cadr (command-line))
                       "8081")))))

    (format #t "\n╔══════════════════════════════════════╗\n")
    (format #t "║  Weave server  →  http://0.0.0.0:~a  ║\n" port)
    (format #t "║  LiveKit host  →  ~a\n" (livekit-host))
    (format #t "╚══════════════════════════════════════╝\n\n")

    (run-server weave-handler 'http `(#:port ,port))))

(main)
