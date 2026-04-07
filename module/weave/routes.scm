;;; module/weave/routes.scm — framework-agnostic Weave request routing.
;;;
;;; Extracted from server/weave.scm so that both the production server
;;; (plain (web server)) and server/weave-dev.scm (Hoot 0.8's
;;; (hoot web-server) with /repl WebSocket proxy) can share one route
;;; table. Handler bodies take an explicit <weave-state> value instead of
;;; closing over file-level globals, so two servers can run concurrently
;;; (dev + prod) without stepping on each other's vats.
;;;
;;; Two adapters are exported:
;;;
;;;   dispatch-weave-request — for (web server): takes method/path/body and
;;;     returns (values response body) for recognised routes, or #f to let
;;;     the caller fall through to static-file handling.
;;;
;;;   weave-hoot-router — for (hoot web-server): takes a (METHOD comp ...)
;;;     route and returns a handler proc, or #f to fall through to the base
;;;     router (which serves static files from #:work-dir and proxies /repl).

(define-module (weave routes)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 match)
  #:use-module (ice-9 binary-ports)
  #:use-module (ice-9 iconv) ; string->bytevector / bytevector->string
  #:use-module (rnrs bytevectors)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (json)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (weave auth)
  #:use-module (weave livekit)
  #:use-module (weave room)
  #:use-module (weave meeting)
  #:export (make-weave-state
            spawn-weave-state
            weave-state?
            weave-state-vat
            weave-state-room-manager
            weave-state-meeting-manager
            weave-state-assets-dir

            dispatch-weave-request
            respond-static-asset
            respond-not-found
            weave-hoot-router))

;;; ── Actor state record ──────────────────────────────────────────────────────

(define-record-type <weave-state>
  (make-weave-state vat room-manager meeting-manager assets-dir)
  weave-state?
  (vat             weave-state-vat)
  (room-manager    weave-state-room-manager)
  (meeting-manager weave-state-meeting-manager)
  (assets-dir      weave-state-assets-dir))

(define (default-assets-dir)
  "Resolve the weave/ static-asset directory relative to this module file."
  (let* ((here (or (current-filename) "module/weave/routes.scm"))
         (mod-dir (dirname here)))
    (string-append (dirname (dirname mod-dir)) "/weave")))

(define* (spawn-weave-state name #:key (assets-dir #f))
  "Spawn a fresh vat + room/meeting managers. ASSETS-DIR overrides the
auto-resolved path to weave/ (used by the dev server to point at
weave/.dev/)."
  (let* ((v  (spawn-vat #:name name))
         (rm (with-vat v (spawn ^room-manager)))
         (mm (with-vat v (spawn ^meeting-manager rm))))
    (make-weave-state v rm mm (or assets-dir (default-assets-dir)))))

;;; ── Response helpers ────────────────────────────────────────────────────────

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

;;; ── Static asset serving ────────────────────────────────────────────────────

(define (read-file-bv path)
  "Read file at PATH as a bytevector, or #f if not found."
  (catch #t
    (lambda ()
      (call-with-input-file path get-bytevector-all
        #:binary #t))
    (lambda _ #f)))

(define (respond-file state filename content-type)
  (let* ((path (string-append (weave-state-assets-dir state) "/" filename))
         (bv   (read-file-bv path)))
    (if bv
        (respond-ok content-type bv)
        (respond-not-found filename))))

(define (respond-static-asset state path)
  "Serve a static asset for PATH (the Weave file set), or #f if PATH is
not a known static path. The (web server) adapter uses this; (hoot
web-server) handles static files itself via #:work-dir."
  (match path
    ("/"            (respond-file state "weave.html" 'text/html))
    ("/weave.html"  (respond-file state "weave.html" 'text/html))
    ("/weave.js"    (respond-file state "weave.js"   'application/javascript))
    ("/weave.css"   (respond-file state "weave.css"  'text/css))
    ("/weave.wasm"  (respond-file state "weave.wasm" 'application/wasm))
    ("/reflect.js"  (respond-file state "reflect.js"  'application/javascript))
    ("/wtf8.wasm"   (respond-file state "wtf8.wasm"   'application/wasm))
    (_              #f)))

;;; ── Request parsing ─────────────────────────────────────────────────────────

(define (parse-json-body body)
  (catch #t
    (lambda ()
      (json-string->scm (bytevector->string body "UTF-8")))
    (lambda _ '())))

;;; ── API handlers ────────────────────────────────────────────────────────────
;;;
;;; All handlers take the <weave-state> as their first argument instead of
;;; closing over file-level globals. Behaviour is otherwise identical to the
;;; pre-refactor server/weave.scm handlers.

(define (handle-create-room state body-alist)
  "POST /api/rooms — create a LiveKit room and register it."
  (let* ((vat     (weave-state-vat state))
         (rm      (weave-state-room-manager state))
         (name    (or (assoc-ref body-alist "name")
                      (assoc-ref body-alist 'name)
                      (with-vat vat (make-room-id))))
         (_       (livekit-create-room name))
         (id+ref  (with-vat vat ($ rm 'create-room! name)))
         (id      (car id+ref)))
    (respond-json `((room_id . ,id)
                    (name    . ,name)
                    (status  . "open")))))

(define (handle-get-token state room-id params)
  "POST /api/rooms/:id/token — generate a LiveKit access token."
  (let* ((vat       (weave-state-vat state))
         (rm        (weave-state-room-manager state))
         (identity  (or (assoc-ref params "identity") "guest"))
         (role-str  (or (assoc-ref params "role") "participant"))
         (role      (string->symbol role-str))
         (display-n (or (assoc-ref params "display_name") identity))
         (room-ref  (with-vat vat ($ rm 'get-room room-id))))
    (if (not room-ref)
        (respond-error 404 (string-append "Room not found: " room-id))
        (let* ((lk-identity (string-append identity "-" room-id))
               (token (make-livekit-token
                       (livekit-api-key) (livekit-api-secret)
                       room-id lk-identity role))
               (ws-host (livekit-url)))
          (with-vat vat
            ($ room-ref 'join! identity display-n role 'named lk-identity))
          (respond-json `((token       . ,token)
                          (livekit_url . ,ws-host)
                          (identity    . ,lk-identity)
                          (room_id     . ,room-id)))))))

(define (handle-create-meeting state body-alist)
  "POST /api/meetings — create a meeting session with a main LiveKit room."
  (let* ((vat       (weave-state-vat state))
         (mm        (weave-state-meeting-manager state))
         (name      (or (assoc-ref body-alist "name")
                        (assoc-ref body-alist 'name)
                        "Untitled Meeting"))
         (id+ref    (with-vat vat ($ mm 'create-meeting! name)))
         (mid       (car id+ref))
         (m-ref     (cdr id+ref))
         (info      (with-vat vat ($ m-ref 'get-info)))
         (room-id   (assoc-ref info 'main-room-id)))
    ;; Dual payload: JSON body for curl and a pipe-encoded x-weave-encoded
    ;; header for the WASM client (weave.js fetch.postJSON).
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

(define (handle-get-meeting state meeting-id)
  "GET /api/meetings/:id — return current meeting state."
  (let* ((vat   (weave-state-vat state))
         (mm    (weave-state-meeting-manager state))
         (m-ref (with-vat vat ($ mm 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (let ((info (with-vat vat ($ m-ref 'get-info))))
          (respond-json info)))))

(define (handle-dispatch-breakouts state meeting-id body-alist)
  "POST /api/meetings/:id/breakouts — dispatch participants into breakout rooms.
Body: { count: N, identities: [\"id1\", \"id2\", ...] }
 Or:   { assignments: { \"id1\": \"room-id\", ... } } for explicit placement."
  (let* ((vat   (weave-state-vat state))
         (mm    (weave-state-meeting-manager state))
         (m-ref (with-vat vat ($ mm 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (let* ((custom  (assoc-ref body-alist "assignments"))
               (result
                (if custom
                    (let ((pairs (map (lambda (kv) (cons (car kv) (cdr kv)))
                                      (if (list? custom) custom '()))))
                      (with-vat vat ($ m-ref 'dispatch-custom! pairs))
                      '())
                    (let* ((count (or (assoc-ref body-alist "count") 2))
                           (ids   (or (assoc-ref body-alist "identities") '())))
                      (with-vat vat
                        ($ m-ref 'dispatch-breakouts! ids count))))))
          (respond-json `((status   . "dispatched")
                          (breakouts . ,result)))))))

(define (handle-recall-breakouts state meeting-id)
  "DELETE /api/meetings/:id/breakouts — recall all participants to main room."
  (let* ((vat   (weave-state-vat state))
         (mm    (weave-state-meeting-manager state))
         (m-ref (with-vat vat ($ mm 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (begin
          (with-vat vat ($ m-ref 'recall!))
          (respond-json `((status . "recalled")))))))

(define (handle-help-signal state meeting-id body-alist)
  "POST /api/meetings/:id/help — participant in breakout signals they need help."
  (let* ((vat   (weave-state-vat state))
         (mm    (weave-state-meeting-manager state))
         (m-ref (with-vat vat ($ mm 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (let* ((identity (or (assoc-ref body-alist "identity") "unknown"))
               (room-id  (or (assoc-ref body-alist "room_id") "")))
          (with-vat vat ($ m-ref 'signal-help! identity room-id))
          (respond-json `((status . "received")))))))

(define (handle-get-help-signals state meeting-id)
  "GET /api/meetings/:id/help — host polls for pending help signals (draining)."
  (let* ((vat   (weave-state-vat state))
         (mm    (weave-state-meeting-manager state))
         (m-ref (with-vat vat ($ mm 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (let ((signals (with-vat vat ($ m-ref 'get-help-signals))))
          (respond-json `((signals . ,signals)))))))

(define (handle-get-breakout-overview state meeting-id)
  "GET /api/meetings/:id/breakouts — host gets current breakout assignments."
  (let* ((vat   (weave-state-vat state))
         (mm    (weave-state-meeting-manager state))
         (m-ref (with-vat vat ($ mm 'get-meeting meeting-id))))
    (if (not m-ref)
        (respond-error 404 (string-append "Meeting not found: " meeting-id))
        (let* ((breakouts   (with-vat vat ($ m-ref 'get-breakouts)))
               (assignments (with-vat vat ($ m-ref 'get-all-assignments))))
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

;;; ── CORS preflight ──────────────────────────────────────────────────────────

(define (handle-options)
  (values (build-response
           #:code 204
           #:headers '((access-control-allow-origin  . "*")
                       (access-control-allow-methods . "GET, POST, OPTIONS")
                       (access-control-allow-headers . "Content-Type, Authorization")))
          #vu8()))

;;; ── Error-wrapped handler invocation ────────────────────────────────────────

(define-syntax-rule (with-error-log tag body ...)
  (catch #t
    (lambda () body ...)
    (lambda (key . args)
      (format (current-error-port) "~a error: ~a ~a\n" tag key args)
      (respond-error 500 (format #f "~a" args)))))

;;; ── Dispatcher for (web server) ─────────────────────────────────────────────

(define (dispatch-weave-request state method path body)
  "Return (values response body) for a recognised API route, or #f if PATH
is not an API/CORS route (caller should try static assets / 404)."
  (match (list method path)
    (('OPTIONS _) (handle-options))

    (('POST "/api/rooms")
     (with-error-log "create-room"
       (handle-create-room state (parse-json-body body))))

    (('POST "/api/meetings")
     (with-error-log "create-meeting"
       (handle-create-meeting state (parse-json-body body))))

    ((method path)
     (cond
      ;; POST /api/rooms/:id/token
      ((and (eq? method 'POST)
            (string-prefix? "/api/rooms/" path)
            (string-suffix? "/token" path))
       (let* ((rid    (substring path
                                 (string-length "/api/rooms/")
                                 (- (string-length path)
                                    (string-length "/token"))))
              (params (parse-json-body body)))
         (with-error-log "get-token"
           (handle-get-token state rid params))))

      ;; GET /api/meetings/:id
      ((and (eq? method 'GET)
            (string-prefix? "/api/meetings/" path)
            (= (length (string-split path #\/)) 4))
       (handle-get-meeting state (list-ref (string-split path #\/) 3)))

      ;; POST /api/meetings/:id/breakouts — dispatch
      ((and (eq? method 'POST)
            (string-prefix? "/api/meetings/" path)
            (string-suffix? "/breakouts" path))
       (let ((mid (list-ref (string-split path #\/) 3)))
         (with-error-log "dispatch-breakouts"
           (handle-dispatch-breakouts state mid (parse-json-body body)))))

      ;; GET /api/meetings/:id/breakouts — overview
      ((and (eq? method 'GET)
            (string-prefix? "/api/meetings/" path)
            (string-suffix? "/breakouts" path))
       (handle-get-breakout-overview state
                                     (list-ref (string-split path #\/) 3)))

      ;; DELETE /api/meetings/:id/breakouts — recall
      ((and (eq? method 'DELETE)
            (string-prefix? "/api/meetings/" path)
            (string-suffix? "/breakouts" path))
       (let ((mid (list-ref (string-split path #\/) 3)))
         (with-error-log "recall-breakouts"
           (handle-recall-breakouts state mid))))

      ;; POST /api/meetings/:id/help
      ((and (eq? method 'POST)
            (string-prefix? "/api/meetings/" path)
            (string-suffix? "/help" path))
       (handle-help-signal state
                           (list-ref (string-split path #\/) 3)
                           (parse-json-body body)))

      ;; GET /api/meetings/:id/help
      ((and (eq? method 'GET)
            (string-prefix? "/api/meetings/" path)
            (string-suffix? "/help" path))
       (handle-get-help-signals state
                                (list-ref (string-split path #\/) 3)))

      (else #f)))))

;;; ── Router for (hoot web-server) ────────────────────────────────────────────
;;;
;;; (hoot web-server) passes routes as (METHOD "comp1" "comp2" ...) lists.
;;; The router returns a handler proc, or #f to fall through to the base
;;; router (which serves static files from #:work-dir and proxies /repl WS).

(define (weave-hoot-router state)
  (lambda (route)
    (match route
      (('OPTIONS . _)
       (lambda (req body) (handle-options)))

      (('POST "api" "rooms")
       (lambda (req body)
         (with-error-log "create-room"
           (handle-create-room state (parse-json-body body)))))

      (('POST "api" "rooms" rid "token")
       (lambda (req body)
         (with-error-log "get-token"
           (handle-get-token state rid (parse-json-body body)))))

      (('POST "api" "meetings")
       (lambda (req body)
         (with-error-log "create-meeting"
           (handle-create-meeting state (parse-json-body body)))))

      (('GET "api" "meetings" mid)
       (lambda (req body) (handle-get-meeting state mid)))

      (('POST "api" "meetings" mid "breakouts")
       (lambda (req body)
         (with-error-log "dispatch-breakouts"
           (handle-dispatch-breakouts state mid (parse-json-body body)))))

      (('GET "api" "meetings" mid "breakouts")
       (lambda (req body) (handle-get-breakout-overview state mid)))

      (('DELETE "api" "meetings" mid "breakouts")
       (lambda (req body)
         (with-error-log "recall-breakouts"
           (handle-recall-breakouts state mid))))

      (('POST "api" "meetings" mid "help")
       (lambda (req body)
         (handle-help-signal state mid (parse-json-body body))))

      (('GET "api" "meetings" mid "help")
       (lambda (req body) (handle-get-help-signals state mid)))

      (_ #f))))
