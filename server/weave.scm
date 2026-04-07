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
;;;   LIVEKIT_URL        — LiveKit URL (default: ws://localhost:7880)
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
             (weave room)
             (weave meeting))

;;; ── Vat + room manager ────────────────────────────────────────────────────────

(define *vat*            (spawn-vat #:name "weave"))
(define *room-manager*   (with-vat *vat* (spawn ^room-manager)))
(define *meeting-manager* (with-vat *vat* (spawn ^meeting-manager *room-manager*)))

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
               (ws-host (livekit-url)))
          ;; Record occupant in room actor
          (with-vat *vat*
            ($ room-ref 'join! identity display-n role 'named lk-identity))
          (respond-json `((token       . ,token)
                          (livekit_url . ,ws-host)
                          (identity    . ,lk-identity)
                          (room_id     . ,room-id)))))))

;;; ── Meeting API handlers ─────────────────────────────────────────────────────

(define (handle-create-meeting body-alist)
  "POST /api/meetings — create a meeting session with a main LiveKit room."
  (let* ((name      (or (assoc-ref body-alist "name")
                        (assoc-ref body-alist 'name)
                        "Untitled Meeting"))
         (id+ref    (with-vat *vat*
                      ($ *meeting-manager* 'create-meeting! name)))
         (mid       (car id+ref))
         (m-ref     (cdr id+ref))
         (info      (with-vat *vat* ($ m-ref 'get-info)))
         (room-id   (assoc-ref info 'main-room-id)))
    ;; Return both JSON (for curl) and a pipe-encoded header for WASM client
    ;; weave.js fetch.postJSON returns "meeting_id:<mid>|room_id:<rid>"
    (values (build-response
             #:code 200
             #:headers `((content-type . (application/json))
                         (access-control-allow-origin . "*")
                         (x-weave-encoded
                          . ,(string-append "meeting_id:" mid
                                            "|room_id:" room-id))))
            (string->bytevector
             (scm->json-string `((meeting_id   . ,mid)
                                 (main_room_id . ,room-id)
                                 (name         . ,name)
                                 (phase        . "lobby")))
             "UTF-8"))))

(define (handle-get-meeting meeting-id)
  "GET /api/meetings/:id — return current meeting state."
  (let ((m-ref (with-vat *vat* ($ *meeting-manager* 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (let ((info (with-vat *vat* ($ m-ref 'get-info))))
          (respond-json info)))))

(define (handle-dispatch-breakouts meeting-id body-alist)
  "POST /api/meetings/:id/breakouts — dispatch participants into breakout rooms.
   Body: { count: N, identities: [\"id1\", \"id2\", ...] }
   Or:   { assignments: { \"id1\": \"room-id\", ... } } for explicit placement."
  (let ((m-ref (with-vat *vat* ($ *meeting-manager* 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (let* ((custom  (assoc-ref body-alist "assignments"))
               (result
                (if custom
                    ;; Explicit assignment map
                    (let ((pairs (map (lambda (kv) (cons (car kv) (cdr kv)))
                                     (if (list? custom) custom '()))))
                      (with-vat *vat* ($ m-ref 'dispatch-custom! pairs))
                      '())
                    ;; Round-robin assignment
                    (let* ((count (or (assoc-ref body-alist "count") 2))
                           (ids   (or (assoc-ref body-alist "identities") '())))
                      (with-vat *vat*
                        ($ m-ref 'dispatch-breakouts! ids count))))))
          (respond-json `((status   . "dispatched")
                          (breakouts . ,result)))))))

(define (handle-recall-breakouts meeting-id)
  "DELETE /api/meetings/:id/breakouts — recall all participants to main room."
  (let ((m-ref (with-vat *vat* ($ *meeting-manager* 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (begin
          (with-vat *vat* ($ m-ref 'recall!))
          (respond-json `((status . "recalled")))))))

(define (handle-help-signal meeting-id body-alist)
  "POST /api/meetings/:id/help — participant in breakout signals they need help."
  (let ((m-ref (with-vat *vat* ($ *meeting-manager* 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (let* ((identity (or (assoc-ref body-alist "identity") "unknown"))
               (room-id  (or (assoc-ref body-alist "room_id") "")))
          (with-vat *vat* ($ m-ref 'signal-help! identity room-id))
          (respond-json `((status . "received")))))))

(define (handle-get-help-signals meeting-id)
  "GET /api/meetings/:id/help — host polls for pending help signals (draining)."
  (let ((m-ref (with-vat *vat* ($ *meeting-manager* 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (let ((signals (with-vat *vat* ($ m-ref 'get-help-signals))))
          (respond-json `((signals . ,signals)))))))

(define (handle-get-breakout-overview meeting-id)
  "GET /api/meetings/:id/breakouts — host gets current breakout assignments."
  (let ((m-ref (with-vat *vat* ($ *meeting-manager* 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (let* ((breakouts   (with-vat *vat* ($ m-ref 'get-breakouts)))
               (assignments (with-vat *vat* ($ m-ref 'get-all-assignments))))
          (respond-json
           `((breakouts . ,(list->vector
                            (map (lambda (b)
                                   (let* ((room-id (car b))
                                          (lk-name (cdr b))
                                          (members (filter
                                                    (lambda (id+room)
                                                      (string=? (cdr id+room) room-id))
                                                    assignments)))
                                     `((room_id  . ,room-id)
                                       (lk_name  . ,lk-name)
                                       (members  . ,(list->vector
                                                     (map car members))))))
                                 breakouts)))))))))

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
      (('GET "/reflect.js")   (respond-file "reflect.js"  'application/javascript))
      (('GET "/wtf8.wasm")    (respond-file "wtf8.wasm"   'application/wasm))

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

      ;; API: create meeting
      (('POST "/api/meetings")
       (catch #t
         (lambda ()
           (handle-create-meeting (parse-json-body body)))
         (lambda (key . args)
           (format (current-error-port) "create-meeting error: ~a ~a\n" key args)
           (respond-error 500 (format #f "~a" args)))))

      ;; API: dynamic routes — rooms/:id/token, meetings/:id/breakouts, etc.
      ((method path)
       (cond

        ;; POST /api/rooms/:id/token
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

        ;; GET /api/meetings/:id
        ((and (eq? method 'GET)
              (string-prefix? "/api/meetings/" path)
              (= (length (string-split path #\/)) 4))
         (let ((mid (list-ref (string-split path #\/) 3)))
           (handle-get-meeting mid)))

        ;; POST /api/meetings/:id/breakouts — dispatch
        ((and (eq? method 'POST)
              (string-prefix? "/api/meetings/" path)
              (string-suffix? "/breakouts" path))
         (let* ((parts (string-split path #\/))
                (mid   (list-ref parts 3)))
           (catch #t
             (lambda ()
               (handle-dispatch-breakouts mid (parse-json-body body)))
             (lambda (key . args)
               (format (current-error-port) "dispatch-breakouts error: ~a ~a\n" key args)
               (respond-error 500 (format #f "~a" args))))))

        ;; GET /api/meetings/:id/breakouts — overview
        ((and (eq? method 'GET)
              (string-prefix? "/api/meetings/" path)
              (string-suffix? "/breakouts" path))
         (let* ((parts (string-split path #\/))
                (mid   (list-ref parts 3)))
           (handle-get-breakout-overview mid)))

        ;; DELETE /api/meetings/:id/breakouts — recall
        ((and (eq? method 'DELETE)
              (string-prefix? "/api/meetings/" path)
              (string-suffix? "/breakouts" path))
         (let* ((parts (string-split path #\/))
                (mid   (list-ref parts 3)))
           (catch #t
             (lambda () (handle-recall-breakouts mid))
             (lambda (key . args)
               (format (current-error-port) "recall-breakouts error: ~a ~a\n" key args)
               (respond-error 500 (format #f "~a" args))))))

        ;; POST /api/meetings/:id/help — participant signals help
        ((and (eq? method 'POST)
              (string-prefix? "/api/meetings/" path)
              (string-suffix? "/help" path))
         (let* ((parts (string-split path #\/))
                (mid   (list-ref parts 3)))
           (handle-help-signal mid (parse-json-body body))))

        ;; GET /api/meetings/:id/help — host reads signals
        ((and (eq? method 'GET)
              (string-prefix? "/api/meetings/" path)
              (string-suffix? "/help" path))
         (let* ((parts (string-split path #\/))
                (mid   (list-ref parts 3)))
           (handle-get-help-signals mid)))

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

    (run-server weave-handler 'http
                `(#:host ,(or (getenv "WEAVE_HOST") "0.0.0.0")
                  #:port ,port))))

(main)
