;;; module/weave/livekit.scm — LiveKit server API client
;;;
;;; Calls the LiveKit RoomService Twirp API for server-side room management.
;;; Participant tokens are generated locally in (weave auth); no API call needed.
;;;
;;; LiveKit Twirp endpoint pattern:
;;;   POST https://<host>/twirp/livekit.RoomService/<Method>
;;;   Content-Type: application/json
;;;   Authorization: Bearer <admin-token>

(define-module (weave livekit)
  #:use-module (weave auth)            ; base64url-encode-bv, livekit-api-key/secret
  #:use-module (web client)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (json)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 iconv)
  #:export (livekit-host
            livekit-create-room
            livekit-delete-room
            livekit-list-rooms
            livekit-list-participants
            livekit-remove-participant
            livekit-send-data))

;;; ── Config ───────────────────────────────────────────────────────────────────

(define (livekit-host)
  "LiveKit server URL, e.g. https://livekit.example.com"
  (or (getenv "LIVEKIT_HOST")
      "http://localhost:7880"))

;;; ── HTTP helper ──────────────────────────────────────────────────────────────

(define (livekit-post method-path body-alist)
  "POST to a LiveKit Twirp method. Returns parsed JSON alist or raises error."
  (let* ((token (make-livekit-admin-token (livekit-api-key) (livekit-api-secret)))
         (url   (string-append (livekit-host) "/twirp/livekit.RoomService/" method-path))
         (body  (string->bytevector (scm->json-string body-alist) "UTF-8")))
    (call-with-values
      (lambda ()
        (http-post url
                   #:body body
                   #:headers `((content-type   . (application/json))
                               (authorization  . ,(string-append "Bearer " token)))))
      (lambda (response body-bv)
        (let ((status (response-code response))
              (body-str (if (bytevector? body-bv)
                            (bytevector->string body-bv "UTF-8")
                            body-bv)))
          (if (= status 200)
              (json-string->scm body-str)
              (error "LiveKit API error" status body-str)))))))

;;; ── Room management ──────────────────────────────────────────────────────────

(define* (livekit-create-room name
                              #:key
                              (empty-timeout 300)
                              (max-participants 50))
  "Create a LiveKit room. Returns the room record alist.
   EMPTY-TIMEOUT: seconds before an empty room is deleted (default 300).
   MAX-PARTICIPANTS: hard cap on concurrent participants."
  (livekit-post "CreateRoom"
                `((name             . ,name)
                  (emptyTimeout     . ,empty-timeout)
                  (maxParticipants  . ,max-participants))))

(define (livekit-delete-room name)
  "Delete a LiveKit room immediately."
  (livekit-post "DeleteRoom" `((room . ,name))))

(define (livekit-list-rooms)
  "List all active LiveKit rooms. Returns a list of room alists."
  (let ((result (livekit-post "ListRooms" '())))
    (or (assoc-ref result "rooms") '())))

(define (livekit-list-participants room-name)
  "List participants in ROOM-NAME. Returns a list of participant alists."
  (let ((result (livekit-post "ListParticipants" `((room . ,room-name)))))
    (or (assoc-ref result "participants") '())))

(define (livekit-remove-participant room-name identity)
  "Forcibly remove IDENTITY from ROOM-NAME."
  (livekit-post "RemoveParticipant"
                `((room     . ,room-name)
                  (identity . ,identity))))

(define* (livekit-send-data room-name data-string
                             #:optional (destination-identities '()))
  "Send DATA-STRING (UTF-8) to participants in ROOM-NAME.
   DESTINATION-IDENTITIES is a list of LiveKit identity strings.
   An empty list broadcasts to everyone in the room.
   DATA-STRING is base64-encoded by the server before sending."
  (let* ((data-bv   (string->bytevector data-string "UTF-8"))
         (b64-data  (base64url-encode-bv data-bv))
         (body      `((room   . ,room-name)
                      (data   . ,b64-data)
                      (kind   . 1))))     ; 1 = RELIABLE
    ;; Add destination_sids only when targeting specific participants
    (livekit-post "SendData"
                  (if (null? destination-identities)
                      body
                      (append body
                              `((destination_identities . ,destination-identities)))))));

