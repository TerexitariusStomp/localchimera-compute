;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; hoot/day-boot.scm — the dial's capability spine (slim Hoot program)
;;;
;;; app.html is the shell: the whole UI is the d3 instrument. This
;;; program is everything the page cannot do alone — the Goblins vat,
;;; the CapTP websocket to the gateway, KERI signup/unlock + challenge
;;; authentication (with the persona-bound Reticulum identity riding
;;; along, as in the repl app), the lobby's transcribe / ai-complete
;;; services, and the planner's scope snapshot (real intents and
;;; commitments for the dial's calendar) — and NOTHING else: no SXML,
;;; no tabs, no rendering. It fills the seam the dial already reads
;;; (the seam's handlers / data) via day-boot.js.
;;;
;;; Built by `make browser/day-boot.wasm`; loaded by browser/day-boot.js
;;; with a small user_imports object (see that file for the contract).

(use-modules (hoot ffi)
             ((hoot typed-arrays) #:select (bytevector->uint8array))
             (goblins)
             (goblins ocapn captp)
             (goblins actor-lib methods)
             (goblins actor-lib on)
             (goblins ocapn netlayer websocket)
             (goblins ocapn ids)
             ((goblins utils hashmap) #:select (make-hashmap hashmap-set hashmap-fold))
             ((goblins contrib base64)
              #:select (base64-decode base64-encode base64-url-alphabet))
             ;; k-of-n secret sharing, for handing pieces of your passcode to
             ;; people you trust (see "recovery friends" below)
             ((playnet crypto shamir)
              #:select (shamir-split shamir-combine))
             ;; how one of those shares looks as a line a person can carry —
             ;; shared with the server side, and tested there
             ((playnet crypto recovery-share)
              #:select (share->line line->share))
             (goblins abstract-types)
             ;; the one vocabulary a contact's tag and a vouch's kind are read in
             ((playnet social relationship-kinds) #:select (normalize-rel))
             (srfi srfi-1)
             (ice-9 match)
             ;; importing crypto-primitives-browser installs the noble.js
             ;; FFI backend, so signify-portable works on first call
             ((playnet keri crypto-primitives)
              #:select (keri-crypto-random-bytes))
             (playnet keri crypto-primitives)
             (playnet keri crypto-primitives-browser)
             ((playnet keri signify-portable)
              #:select (bran->signing-keypair
                        bran->next-keypair
                        bran->rotation-keypair
                        bran->reticulum-seed
                        public-key->aid-prefix
                        next-key-digest
                        build-icp
                        build-rot
                        event-sn
                        event-first-next-digest
                        sign-event
                        sign-bytes
                        event-first-key
                        oobi-endpoint-replies-for-icp
                        oobi-endpoint-replies-for-rot
                        scm->json-canonical
                        json-read-ordered
                        recompute-event-said
                        ed25519-keypair-public))
             ;; the encryption key a person's inception event anchors — what a
             ;; card is sealed to
             ((playnet keri reticulum-binding) #:select (kel-reticulum-pub))
             ;; the key log in hand: a passcode's chain of keys, the log's own
             ;; verification, the rotation that retires it — pure, tested natively
             ((playnet identity kel)
              #:select (kel-icp kel-aid kel-k0 kel-rotations kel-depth kel-last-event
                        make-kel entry->kel kel-well-formed? kel-events
                        passcode-keypair keypair-key passcode-base kel-current-keypair
                        passcode-opens? kel-verifies? rotations-verify?
                        anchored-key-hex receipt->json retirement-rotation))
             ((playnet utils hex) #:select (bv->hex))
             ((playnet keri cesr) #:select (cesr-bytes->qb64 cesr-qb64->bytes))
             ;; a row of the wire, and the snapshot as the page reads it — shared
             ;; with the demo recorder, so a recording is what a gateway sends
             (playnet wire rows)
             ((playnet wire snapshot) #:select (fold-snapshots))
             ;; Shared SAID derivation — the SAME code the server uses, so a
             ;; stance we sign here derives the identical SAID there. Without
             ;; this the client could only blind-sign whatever SAID the server
             ;; handed down; with it we re-derive from the claims we are
             ;; agreeing to before signing.
             ((playnet keri said-portable)
              #:select (compute-said install-said-blake3!))
             ((rnrs bytevectors) #:select (string->utf8 utf8->string bytevector-length)))

;; said-portable's default resolves blake3 through an FFI module-ref, which does
;; not exist under Hoot/WASM — so hand it the noble.js-backed implementation
;; that crypto-primitives-browser just installed.
(install-said-blake3! keri-crypto-blake3-256)

;;; ── FFI: the contract with day-boot.js ─────────────────────────────────
(define-foreign gateway-sref
  "urlParams" "gatewaySref"
  -> (ref string))
(define-foreign %seam-status!
  "seam" "status"
  (ref string) -> none)
;; the trace is where a DIAGNOSTIC goes; status is the DOOR (every string
;; on it is a door state to the page — see seam-trace! below)
(define-foreign %seam-trace!
  "seam" "trace"
  (ref string) -> none)
(define-foreign %seam-data!
  "seam" "data"
  (ref string) -> none)
(define-foreign seam-set-handler!
  "seam" "setHandler"
  (ref string) (ref extern) -> none)
(define-foreign %seam-chat-message!
  "seam" "chatMessage"
  (ref string) (ref string) -> none)
(define-foreign %seam-connect-ask!
  "seam" "connectAsk"
  (ref string) (ref string) -> none)
(define-foreign %seam-slots-changed!
  "seam" "slotsChanged"
  (ref string) -> none)
(define-foreign %seam-scope!
  "seam" "setScope"
  (ref string) -> none)
(define-foreign %seam-aid!
  "seam" "aid"
  (ref string) -> none)
(define-foreign %seam-scopes!
  "seam" "scopes"
  (ref string) -> none)
(define-foreign %seam-walkie-state!
  "seam" "walkieState"
  (ref string) -> none)
;; ── WebRTC for the dial's live walkie (audio, camera, screen) ─────────
;; Every pc carries a mic sender and a video sender from its first offer, so
;; nothing renegotiates: muting is an `enabled` flip, the camera is STOPPED and
;; started (its sender stays, empty while it is off), and screen share is a
;; replaceTrack onto the same sender.
(define-foreign rtc-new-pc        "webRTC" "newPc"        -> (ref extern))
(define-foreign rtc-set-ice       "webRTC" "setIce"       (ref string) -> none)
(define-foreign rtc-mic-get       "webRTC" "micGet"       (ref extern) -> none)
(define-foreign rtc-mic-enabled   "webRTC" "micEnabled"   i32 -> none)
(define-foreign rtc-add-mic       "webRTC" "addMic"       (ref extern) -> none)
(define-foreign rtc-cam-get       "webRTC" "camGet"       (ref extern) -> none)
(define-foreign rtc-cam-stop      "webRTC" "camStop"      -> none)
(define-foreign rtc-add-cam       "webRTC" "addCam"       (ref extern) -> none)
(define-foreign rtc-screen-get    "webRTC" "screenGet"    (ref extern) -> none)
(define-foreign rtc-screen-stop   "webRTC" "screenStop"   -> none)
(define-foreign rtc-replace-video "webRTC" "replaceVideo" (ref extern) i32 -> none)
(define-foreign rtc-peer-video    "webRTC" "peerVideo"    (ref string) i32 -> none)
(define-foreign rtc-on-remote-media "webRTC" "onRemoteMedia" (ref extern) (ref string) -> none)
(define-foreign rtc-drop-media    "webRTC" "dropMedia"    (ref string) -> none)
(define-foreign rtc-drop-all-media "webRTC" "dropAllMedia" -> none)
(define-foreign rtc-on-ice        "webRTC" "onIce"        (ref extern) (ref extern) -> none)
(define-foreign rtc-add-ice       "webRTC" "addIce"       (ref extern) (ref string) -> none)
(define-foreign rtc-offer         "webRTC" "offer"        (ref extern) (ref extern) -> none)
;; `answer` takes a CALLBACK, exactly as `offer` above does — the SDP comes
;; back through it. Declared `(ref string)` the answering side threw
;; "type check failed / predicate string? / origin rtc-answer" on the external
;; it was handed, so no peer could ever answer an offer and no call could
;; complete. Signalling looked healthy: the offer crossed the gateway fine and
;; the offerer even grew a remote tile, because `ontrack` fires when the offer
;; is applied — the media just never flowed.
(define-foreign rtc-answer        "webRTC" "answer"       (ref extern) (ref extern) -> none)
(define-foreign rtc-set-remote    "webRTC" "setRemote"    (ref extern) (ref string) -> none)
(define-foreign rtc-close-pc      "webRTC" "closePc"      (ref extern) -> none)
(define-foreign %seam-call!
  "seam" "callCallback"
  (ref extern) (ref string) -> none)
;; Hoot FFI `-> none` returns ZERO values; goblins' on-handler wrapper
;; (match (apply handler args) …) needs exactly ONE. An on-handler whose
;; tail is a bare void-FFI call returns zero values → "wrong number of
;; arguments (0)" at goblins/core.scm:2038. Wrap so every call yields #t.
(define-foreign %seam-contacts!
  "seam" "contacts"
  (ref string) -> none)
(define-foreign %seam-taxonomy!
  "seam" "taxonomy"
  (ref string) -> none)
(define-foreign %seam-grants!
  "seam" "grants"
  (ref string) -> none)
(define (seam-status! s)        (%seam-status! s) #t)
;; a diagnostic on the boot trace — it never touches the door state
(define (seam-trace! s)         (%seam-trace! s) #t)
(define (seam-data! j)          (%seam-data! j) #t)
(define (seam-contacts! j)      (%seam-contacts! j) #t)
(define (seam-taxonomy! j)      (%seam-taxonomy! j) #t)
(define (seam-grants! j)        (%seam-grants! j) #t)
(define (seam-chat-message! a b)(%seam-chat-message! a b) #t)
(define (seam-slots-changed! s) (%seam-slots-changed! s) #t)
(define (seam-scope! s)         (%seam-scope! s) #t)
(define (seam-scopes! j)        (%seam-scopes! j) #t)
(define (seam-walkie-state! s)  (%seam-walkie-state! s) #t)
(define (seam-call! cb s)       (%seam-call! cb s) #t)
(define-foreign time-iso-now
  "time" "isoNow"
  -> (ref string))
;; localStorage — the KEL lives here (see "the KEL" below)
(define-foreign ls-get-item
  "localStorage" "getItem"
  (ref string) -> (ref null string))
(define-foreign ls-set-item
  "localStorage" "setItem"
  (ref string) (ref string) -> none)
(define-foreign ls-remove-item
  "localStorage" "removeItem"
  (ref string) -> none)
(define-foreign get-location-origin
  "location" "getOrigin"
  -> (ref string))
;; Reticulum (rns-wasm) — the persona-bound mesh identity
;; the mesh's size ceiling, named by the page's video budget (mesh-plan.ts)
(define-foreign mesh-max-peers
  "mesh" "maxPeers"
  -> i32)
(define-foreign ret-has-identity?
  "reticulum" "hasIdentity"
  -> i32)
(define-foreign ret-load-from-seed
  "reticulum" "loadFromSeed"
  (ref extern) -> i32)
(define-foreign ret-public-key-hex
  "reticulum" "publicKeyHex"
  -> (ref string))
(define-foreign ret-dest-hash-hex
  "reticulum" "destHashHex"
  -> (ref string))
(define-foreign ret-lxmf-dest-hash-hex
  "reticulum" "lxmfDestHashHex"
  -> (ref string))
;; sealing to another person's anchored key, and opening what was sealed to
;; ours: text in, hex ciphertext out, and back; "" when it cannot be done
(define-foreign ret-seal-text-for
  "reticulum" "sealTextFor"
  (ref string) (ref string) -> (ref string))
(define-foreign ret-open-text
  "reticulum" "openText"
  (ref string) -> (ref string))
;; the device key (browser/lib/device-key.js): a per-device Ed25519 key the
;; root authorizes once (docs/planning/identity/device-keys.md). The key never crosses
;; into this vat — signing is a JS call with a callback; only the public half
;; comes over, as bytes.
(define-foreign %device-load
  "device" "load"
  (ref extern) -> none)                 ; cb(status-string): "ok:<tier>" | "err:…"
(define-foreign %device-pub
  "device" "pub"
  -> (ref extern))                      ; Uint8Array(32) once loaded
(define-foreign %device-sign
  "device" "sign"
  (ref extern) (ref extern) -> none)    ; (bytes, cb(Uint8Array(64) | null))
(define-foreign %device-seal
  "device" "seal"
  (ref extern) (ref extern) -> none)    ; (bytes, cb(blob-string | null))
(define-foreign %device-open
  "device" "open"
  (ref string) (ref extern) -> none)    ; (blob, cb(Uint8Array | null))
(define-foreign time-epoch-seconds
  "time" "epochSeconds"
  -> (ref string))

;;; ── state ───────────────────────────────────────────────────────────────
(define *vat*     (spawn-vat #:name "dial"))
(define *mycapn*  #f)
(define *lobby*   #f)
(define *secret*  #f)   ; in-memory keypair, never stored
;; how the AID is proven in this session: 'root (the passcode's own key is in
;; *secret*) or 'device (a device key the root authorized signs for it, over
;; the FFI). Everyday acts sign either way; rotation, enrolling a device and
;; splitting the passcode need 'root.
(define *tier*    #f)
(define *aid*     #f)
(define *session* #f)   ; AID-bound session cap from keri-authenticate
(define *planner* #f)
(define *scope*   #f)   ; the scope the snapshot came from — journeys land here
;; the ONE door the signed identity crosses to the dial: every reader of
;; "which rows are MINE" derives from this fact, never from a device hint —
;; a stale localStorage id painted another person's commitments as yours
(define (set-aid! a) (set! *aid* a) (%seam-aid! a))

;; a deterministic, valid handle from an AID — frictionless signup gives
;; no name, so we mint the gateway's username key from the AID itself
;; (the user sets a real display-name later, in settings).
(define (aid->handle aid)
  (let* ((lc (string-downcase (if (string? aid) aid "")))
         (cs (filter (lambda (c) (or (char-alphabetic? c) (char-numeric? c)))
                     (string->list lc)))
         (n  (min 12 (length cs))))
    (string-append "u" (list->string (take cs n)))))

;; syrup → plain data (same shape repl.scm uses for CapTP results)
(define (denormalize-syrup x)
  (cond
   ;; <tagged 'user-record (label data)> is the wire's generic record
   ;; envelope: the inner tagged still wants its own decode (found live —
   ;; a 'vec riding inside one wrote "caps":<record> and broke the
   ;; envelope reply's JSON write)
   ((and (tagged? x) (eq? 'user-record (tagged-label x)))
    (let ((d (tagged-data x)))
      (denormalize-syrup (make-tagged (car d) (cadr d)))))
   ((and (tagged? x) (eq? 'pair (tagged-label x)))
    (let ((d (tagged-data x)))
      (cons (denormalize-syrup (car d))
            (denormalize-syrup (cadr d)))))
   ((and (tagged? x) (eq? 'vec (tagged-label x)))
    (list->vector (map denormalize-syrup (tagged-data x))))
   ((pair? x)
    (cons (denormalize-syrup (car x)) (denormalize-syrup (cdr x))))
   ((vector? x)
    (list->vector (map denormalize-syrup (vector->list x))))
   (else x)))

;; a syrup vector or list, decoded, as a list
(define (->plain-list x) (->list (denormalize-syrup x)))

;;; ── the lobby services, as dial handlers ────────────────────────────────
;; every handler takes its arguments plus a JS callback (ref extern);
;; the reply is always a single string through seam-call!.

(define (reply! cb s) (seam-call! cb (if (string? s) s "")))

;;; ── the KEL: the controller's own log ───────────────────────────────────
;; Every event in a person's KEL is authored here, in this vat: the icp at
;; signup, each rot from the REPL. The controller keeps what it wrote. The
;; log is public, signed, and self-verifying, so it is also the whole of
;; what a commune needs to seat this identity — a gateway is one reader of
;; it, never its keeper. Held as the same ordered-JSON value shape the
;; recovery file carries:
;;
;;   {"icp": <event>, "sigs": [..], "rotations": [{"rot": <event>, "sigs": [..]}, …]}
;;
;; Field order inside an event is the event: SAID and signature are both
;; over the serialized bytes, so the store round-trips through
;; scm->json-canonical / json-read-ordered and nothing else.
(define %kel-key "pn.id.kel")
(define *kel* #f)
;; The passcode itself, for as long as a passcode session is open in this tab:
;; the acts that need the passcode rather than a key derived from it (splitting
;; it among recovery friends, adopting rotations made elsewhere) reach it here
;; without asking the person to type it again.
(define *bran* #f)

(define (kel-save! kel)
  (set! *kel* kel)
  (ls-set-item %kel-key (scm->json-canonical kel)))

(define (kel-load!)
  (let ((raw (ls-get-item %kel-key)))
    (set! *kel*
          (and (string? raw) (positive? (string-length raw))
               (with-exception-handler
                (lambda (_) #f)
                (lambda ()
                  (let ((kel (json-read-ordered raw)))
                    (and (kel-well-formed? kel) kel)))
                #:unwind? #t)))))



(kel-load!)

;; planner/lobby calls share one reply envelope: (ok . v) | (error . msg)
;; | anything-else. planner-call sends, then dispatches — ON-OK receives v
;; and is responsible for the success reply; errors reply for you.
;; run THUNK, the success branch of a planner call. A handler that throws on a
;; reply it did not expect (a number the writer cannot carry, a field of another
;; shape) would leave its promise unsettled and the sheet waiting; here it
;; answers with the failure, in words the sheet can show.
(define (reply-or-err! cb thunk)
  (with-exception-handler
   (lambda (_) (reply! cb "err:the reply could not be read"))
   thunk
   #:unwind? #t))

(define-syntax planner-call
  ;; a MACRO, not a procedure: SEND must be spliced inside `with-vat` so the
  ;; `(<- …)` runs inside the vat turn (a current syscaller exists). As a
  ;; procedure it would evaluate SEND at the call site — outside any turn.
  (syntax-rules ()
    ((_ cb send on-ok)
     (with-vat *vat*
       (on send
           (lambda (result)
             (match (denormalize-syrup result)
               (('ok . v)                (reply-or-err! cb (lambda () (on-ok v))))
               ((or ('error . (? string? m)) ('error (? string? m))) (reply! cb (string-append "err:" m)))
               (_                        (reply! cb "err:refused"))))
           #:catch (lambda _ (reply! cb "err:planner unreachable")))))))

;; The AI the commons pays for is asked from the seat: the session answers
;; within its budget, and "" — signed out, over budget, no keys — is the
;; browser's cue to work on-device.
(define (handle-transcribe wav-b64 cb)
  (if (not *session*)
      (reply! cb "")
      (with-vat *vat*
        (on (<- *session* 'transcribe wav-b64)
            (lambda (text) (reply! cb (if (string? text) text "")))
            #:catch (lambda _ (reply! cb ""))))))

(define (handle-ai system user model cb)
  (if (not *session*)
      (reply! cb "")
      (with-vat *vat*
        (on (<- *session* 'ai-complete system user model)
            (lambda (text) (reply! cb (if (string? text) text "")))
            #:catch (lambda _ (reply! cb ""))))))

;; a picture, read at the seat (session see-part / see). A message larger than
;; any the connection has carried is answered by nothing at all
;; (deploy/UPSTREAM-ISSUES.md §14), so each picture crosses in parts of this
;; size, one after the other, and the read follows the last of them. The gateway
;; takes a part of sixteen kilobytes at the most (gateway/evidence.scm %part-chars);
;; the bridge sends a round figure under that bound, and test-see-door reads
;; this line to hold it there. IMAGES arrives as the pictures' base64 joined by
;; newlines.
(define %picture-send-chars 16000)
(define *upload-seq* 0)

(define (string-parts s n)
  (let loop ((i 0) (acc '()))
    (if (>= i (string-length s))
        (reverse acc)
        (let ((j (min (string-length s) (+ i n))))
          (loop j (cons (substring s i j) acc))))))

(define (split-lines s)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length s))
           (reverse (if (> i start) (cons (substring s start i) acc) acc)))
          ((char=? (string-ref s i) #\newline)
           (loop (+ i 1) (+ i 1) (if (> i start) (cons (substring s start i) acc) acc)))
          (else (loop (+ i 1) start acc)))))

;; Send PARTS of a picture to the gateway one after the other, in order. SEND
;; takes one part and makes its call (a promise); once the door has taken it the
;; next goes, and DONE runs after the last. A door that refuses, or a call that
;; fails, replies for the caller. SEND and DONE run inside the vat turn, where
;; a call on the gateway may be made.
(define (send-parts! cb parts send done)
  (with-vat *vat*
    (let loop ((rest parts))
      (if (null? rest)
          (done)
          (on (send (car rest))
              (lambda (r)
                (match (denormalize-syrup r)
                  (('ok . _) (loop (cdr rest)))
                  ((or ('error . (? string? m)) ('error (? string? m))) (reply! cb (string-append "err:" m)))
                  (_ (reply! cb "err:the picture could not be sent"))))
              #:catch (lambda _ (reply! cb "err:the picture could not be sent")))))))

(define (handle-see images system user fulfills cb)
  (cond
   ((not *session*) (reply! cb ""))
   (else
    (set! *upload-seq* (+ *upload-seq* 1))
    (let* ((upload (string-append "up-" (number->string *upload-seq*)))
           (pics (split-lines (arg-str images)))
           ;; every part of every picture, in order: (index . part)
           (parts (let loop ((ps pics) (i 0) (acc '()))
                    (if (null? ps) (reverse acc)
                        (loop (cdr ps) (+ i 1)
                              (append (reverse (map (lambda (p) (cons i p))
                                                    (string-parts (car ps) %picture-send-chars)))
                                      acc))))))
      (send-parts! cb parts
                   (lambda (ip) (<- *session* 'see-part upload (car ip) (cdr ip)))
                   (lambda ()
                     (on (<- *session* 'see upload (arg-str system) (arg-str user)
                             (or *scope* "") (arg-str fulfills))
                         (lambda (text) (reply! cb (if (string? text) text "")))
                         #:catch (lambda _ (reply! cb "")))))))))

;; the week's unplanned photo reads (session allotment)
(define (handle-allotment cb)
  (if (not *session*)
      (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'allotment)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

;; corpus search (docs/planning/faces/corpus-guile-native.md phase 4) — DOMAIN is
;; a domain slug ("permaculture") for the recipes face's own scoped search,
;; or "" for every built domain merged (the federation corpus tab). Not
;; AID/scope-attributed and free to answer, so this goes straight through
;; *lobby*, never through *session*.
(define (handle-corpus-search domain query limit cb)
  (if (not *lobby*)
      (reply! cb (scm->json-canonical `(("hits" . ,(list->vector '())))))
      (with-vat *vat*
        (on (<- *lobby* 'corpus-search (if (string-null? domain) #f domain) query
               (let ((n (arg-num limit))) (if (> n 0) n 8)))
            (lambda (r)
              (reply! cb
                      (scm->json-canonical
                       (if (assq-ref r 'error)
                           `(("hits" . ,(list->vector '())) ("error" . ,(assq-ref r 'error)))
                           `(("hits" . ,(list->vector
                                         (map (lambda (h)
                                                `(("domain"  . ,(or (assq-ref h 'domain) ""))
                                                  ("text"    . ,(assq-ref h 'text))
                                                  ("heading" . ,(or (assq-ref h 'heading) ""))
                                                  ("source"  . ,(assq-ref h 'source))
                                                  ("title"   . ,(assq-ref h 'title))
                                                  ("author"  . ,(or (assq-ref h 'author) ""))
                                                  ("score"   . ,(exact->inexact (assq-ref h 'score)))))
                                              (assq-ref r 'hits)))))))))
            #:catch (lambda _ (reply! cb (scm->json-canonical `(("hits" . ,(list->vector '())) ("error" . "corpus search unreachable")))))))))

;; the ValueFlows lint over records, against the current scope's specs and
;; units — the log and share-bar passes ask it inside their conform check
(define (handle-lint-records scope records-json cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   (else
    (planner-call cb (<- *planner* 'lint-records
                        (if (and (string? scope) (not (string-null? scope))) scope (or *scope* ""))
                        (if (string? records-json) records-json "[]"))
                  (lambda (v) (reply! cb (if (string? v) v "[]")))))))

(define (handle-corpus-domains cb)
  (if (not *lobby*)
      (reply! cb (scm->json-canonical `(("domains" . ,(list->vector '())))))
      (with-vat *vat*
        (on (<- *lobby* 'corpus-domains)
            (lambda (r)
              (reply! cb (scm->json-canonical
                          `(("domains" . ,(list->vector (or (assq-ref r 'domains) '())))))))
            #:catch (lambda _ (reply! cb (scm->json-canonical `(("domains" . ,(list->vector '()))))))))))

;; the orb asks the planner for the CURRENT plan, briefly: solve-brief returns
;; a wire-safe STRING summary (satisfaction, the social ledger, the loudest
;; pulls, the certificate) that the orb narrates. NON-BINDING — a read, never a
;; change — so it carries no AID and gates only on a planner + a chosen scope.
;; OVERRIDES-JSON is a JSON string ("{}" = current plan, or a what-if like
;; {"eco-caps":…,"reserve":…,"demand":…}). Hoot has no JSON reader, so we
;; forward the raw string; solve-brief (Guile) parses it. NON-BINDING.
(define (handle-solve overrides-json cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((not *scope*)   (reply! cb "err:no scope yet"))
   (else
    (planner-call cb (<- *planner* 'solve-brief *scope*
                        (if (string? overrides-json) overrides-json "{}"))
                  (lambda (brief) (reply! cb (if (string? brief) brief "")))))))

;;; ── accept / decline: the phase handshake, carried to the plan ──────────
;; a proposal accepted on the dial is accepted IN THE PLAN: the planner's
;; accept-assignment binds the Intent to you (acting-as = your AID), and
;; the refreshed snapshot brings it back as a commitment.

(define (assignment! method scope-id intent-id cb)
  (cond
   ((not *session*) (reply! cb "err:sign in first"))
   ((or (not (string? intent-id)) (string=? intent-id ""))
    (reply! cb "err:this proposal has no planner id"))
   (else
    (planner-call cb (<- *session* method scope-id intent-id)
                  (lambda (_) (fetch-snapshot!) (reply! cb "ok"))))))

(define (handle-commit scope-id intent-id cb)
  (assignment! 'accept-assignment scope-id intent-id cb))
(define (handle-decline scope-id intent-id cb)
  (assignment! 'decline-assignment scope-id intent-id cb))

;; the presentation caller's mirror: accept a DIRECTED WORK OFFER — the
;; bounded rung's proposal (offers.scm offer-work) — through the gated
;; accept-work-offer door, where the worker is the PROVIDER. The refreshed
;; snapshot returns the commitment and the offer leaves the proposals.
(define (handle-accept-work-offer scope-id proposal-id cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((or (not (string? proposal-id)) (string=? proposal-id ""))
    (reply! cb "err:this offer has no planner id"))
   (else
    (planner-call cb (<- *session* 'accept-work-offer scope-id proposal-id)
                  (lambda (_) (fetch-snapshot!) (reply! cb "ok"))))))

;; the offer-side opt-in, from the dial: an option, not a bind —
;; express-willingness stamps (worker skill cell), materialize-willing
;; races the willing onto open needs, the refreshed snapshot carries
;; the result back. WILLING? is "yes" | "no" (withdraw / reject).
(define (handle-willing scope-id spec cell willing? cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((or (not (string? spec)) (string=? spec ""))
    (reply! cb "err:this proposal has no skill key"))
   (else
    (planner-call
     cb (<- *session* 'express-willingness scope-id spec cell
            (and (string? willing?) (string=? willing? "yes")))
     (lambda (_)
       ;; materialize always reports ok — the willing is recorded either way
       (with-vat *vat*
         (on (<- *planner* 'materialize-willing scope-id)
             (lambda (_) (fetch-snapshot!) (reply! cb "ok"))
             #:catch (lambda _ (fetch-snapshot!) (reply! cb "ok")))))))))

;; availability: the dial's light-blue arcs → the agent's planner availability
;; window. JSON is an array of {start:"HH:MM", end:"HH:MM", days:[name…]} (one
;; per arc); the planner parses it server-side (like solve-brief) and rebuilds
;; the agent's <availability-window>, so the matcher only offers work that fits.
;; leaving a thing in a shared container, and taking one out — the VF pair, over
;; the planner's `drop-event`. ACTION is "dropoff" | "pickup"; QTY arrives as a
;; string (every handler argument does) and is parsed here, since the service
;; wants a number and a refusal is better than a zero. A fresh snapshot follows
;; the write, so the map's containers and their contents redraw from the ledger
;; rather than from what the click hoped would happen.
(define (handle-drop-event action container-id spec qty unit resource-id mine? cb)
  (let ((q (and (string? qty) (string->number qty))))
    (cond
     ((not *planner*) (reply! cb "err:sign in first"))
     ((not *scope*)   (reply! cb "err:no scope yet"))
     ((or (not (string? container-id)) (string=? container-id ""))
      (reply! cb "err:no container"))
     ((not (and (number? q) (> q 0))) (reply! cb "err:how much?"))
     (else
      (planner-call
       cb (<- *planner* 'drop-event *scope* action container-id *aid*
              spec q unit resource-id ""
              ;; the claim, and only when it is made: "mine" says the person
              ;; leaving this holds the rights to it. Anything else leaves the
              ;; thing owned by nobody, which is what putting something down
              ;; means on its own.
              (if (equal? mine? "mine") *aid* ""))
       (lambda (rid)
         (fetch-snapshot!)
         (reply! cb (if (string? rid) rid "ok"))))))))

;; who you are, as the reproduction floors and the diet read it: a JSON array
;; of typed tags ("sex:F" "age:34" "pregnant:1" "diet:vegan" "allergy:nuts")
;; written onto your own agent record, replacing the profile tags it held
(define (handle-set-profile json cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((not *scope*)   (reply! cb "err:no scope yet"))
   (else
    (planner-call cb (<- *session* 'set-profile *scope* (if (string? json) json "[]"))
      (lambda (v) (reply! cb "ok"))))))

(define (handle-set-availability json cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((not *scope*)   (reply! cb "err:no scope yet"))
   (else
    (planner-call cb (<- *session* 'set-availability-ranges *scope*
                        (if (string? json) json "[]"))
                  (lambda (_) (reply! cb "ok"))))))

;; social invite: the planner mints a directed proposal (receiver = invitee);
;; we also signal the invitee's online session (best-effort) so their dial
;; re-fetches and sees it now — offline, the snapshot's proposed-to filter
;; surfaces it on their next sign-in. t0/t1 are ISO datetimes for the event day.
(define (handle-invite invitee label t0-iso t1-iso cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((not *scope*)   (reply! cb "err:no scope yet"))
   ((or (not (string? invitee)) (string=? invitee "")) (reply! cb "err:no invitee"))
   (else
    (planner-call cb (<- *session* 'invite-contact *scope* invitee
                        (if (string? label) label "event")
                        (if (string? t0-iso) t0-iso "") (if (string? t1-iso) t1-iso ""))
      (lambda (_)
        (when *lobby*                                  ; best-effort live ping
          (with-vat *vat* (<-np *lobby* 'signal invitee *aid* "invite" "")))
        (reply! cb "ok"))))))

;; the invitee accepts a social invite → accept-proposal (whitelist-validated);
;; the event becomes a commitment for both and the snapshot refreshes. The
;; seam's two arguments, the scope and the proposal, as every accept takes them.
(define (handle-accept-invite scope-id proposal-id cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((or (not (string? proposal-id)) (string=? proposal-id ""))
    (reply! cb "err:this invite has no planner id"))
   (else
    (planner-call cb (<- *session* 'accept-invite scope-id proposal-id)
      (lambda (_) (fetch-snapshot!) (reply! cb "ok"))))))

;; a journey on the dial is a journey IN THE PLAN: begin mints a Commitment
;; and the pickup event, end records the dropoff that fulfills it — the
;; observer pairs the two into an arc-observation and the planner's
;; transport coefficients learn from this very walk (solve/routing.scm's table).
;; PHASE is "begin" or "end"; CID threads the commitment between the two.
(define (handle-journey phase from to mode cid cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((not *scope*)   (reply! cb "err:no scope yet"))
   (else
    (planner-call
     cb (if (and (string? phase) (string=? phase "end"))
            (<- *session* 'journey-end *scope* cid from to mode)
            (<- *session* 'journey-begin *scope* from to mode))
     (lambda (v)
       (reply! cb (string-append
                   "ok:" (or (and (pair? v) (alist-ref v 'commitment)) ""))))))))

;; The day is the FOLD over every membership: one snapshot per commune,
;; keyed by scope id. The union standpoint (earth) reads them all; the
;; dialed scope keeps its own plan artifacts. Records carry their scope
;; on the wire, so the dial facets the union instead of switching worlds.
(define *snaps* '())

(define (note-snap! sid snap)
  (set! *snaps* (cons (cons sid (denormalize-syrup snap))
                      (remove (lambda (p) (equal? (car p) sid)) *snaps*)))
  (push-merged!))

(define *last-merged* #f)
(define (deliver-merged! json)
  (unless (and (string? *last-merged*) (string=? json *last-merged*))
    (set! *last-merged* json)
    (seam-data! json)))

(define (push-merged!)
  ;; the dialed scope leads (its rows paint first, and the per-scope
  ;; artifacts — plan, matter, inventory, credit, recipes — are its own);
  ;; every other membership's records ride behind, scope-tagged. Each snapshot
  ;; arrives as the page's rows already, and which arms gather across the
  ;; memberships is what the snapshot's own table says (wire/snapshot.scm
  ;; fold-snapshots): while the dialed scope's snapshot is still in flight its
  ;; own arms ride absent (the dial reads absent as "no solve yet"), never a
  ;; neighbour's.
  ;; deliver only what CHANGED the fold: the roster walk (fetch-scopes!)
  ;; merges every commune's snapshot in turn, and once the empty ones start
  ;; arriving the merge stops moving — each of those used to reach the
  ;; dial as a full re-render of an identical day
  (let ((prim-pair (assoc *scope* *snaps*)))
    (deliver-merged!
     (scm->json-canonical
      (fold-snapshots (if (pair? prim-pair) (cdr prim-pair) '())
                      (map cdr (remove (lambda (p) (eq? p prim-pair)) *snaps*)))))))

;; Fetch each membership's snapshot in turn — the dialed scope first, so the
;; day paints fast, then the rest of the federation folds in as it arrives.
(define (fetch-scopes! cap ids)
  (when (pair? ids)
    (on (<- cap 'scope-snapshot (car ids) #f *aid*)
        (lambda (snap)
          (when snap (note-snap! (car ids) snap))
          (fetch-scopes! cap (cdr ids)))
        ;; a failed snapshot NAMES itself and the walk continues — a silent
        ;; skip here read as "connected, demo forever" (found live)
        #:catch (lambda _
                  (seam-trace! (string-append "seat:snap-fail " (car ids)))
                  (fetch-scopes! cap (cdr ids))))))

;; The seat's context, fetched ONCE when the seat is taken (and again when
;; the roster can change — join): the commune's taxonomy cut, your grants,
;; the planner cap and the scope roster. Every later refresh is a snapshot
;; only (fetch-snapshot!): the spine runs its vat on the main thread, and each
;; payload crossing the FFI is a marshalling pass the page waits on, so what
;; has not changed is not re-fetched.
(define *scope-ids* '())
(define (fetch-snapshot!)
  (cond
   ((not *lobby*) #f)
   ((and *planner* (pair? *scope-ids*))
    (let ((chosen (if (and *scope* (member *scope* *scope-ids*)) *scope* (car *scope-ids*))))
      (set! *scope* chosen)
      (watch-slots!)
      (with-vat *vat*
        (fetch-scopes! *planner* (cons chosen (remove (lambda (i) (equal? i chosen))
                                                      *scope-ids*))))))
   (else (fetch-seat!))))
(define (fetch-seat!)
  (when *lobby*
    ;; the seat's optional reads may not take the seat down: each speaks
    ;; through its own on/#:catch, and a synchronous throw in either is
    ;; caught here so the ROSTER fetch below always runs
    (when *session*
      (%caught (lambda () (fetch-taxonomy!)) "seat:taxonomy-threw")
      (%caught (lambda () (fetch-my-grants!)) "seat:grants-threw"))
    (with-vat *vat*
      (on (let*-on ((cap    (<- *lobby* 'planner))
                    (scopes (begin (set! *planner* cap) (<- cap 'scope-list))))
            (let* ((sc  (denormalize-syrup scopes))
                   (ids (filter string? (map (lambda (s) (alist-ref s 'id)) sc))))
              (seam-trace! (string-append "seat:roster " (number->string (length ids))))
              (set! *scope-ids* ids)
              ;; hand the dial every commune under the UC for the switcher
              (seam-scopes!
               (scm->json-canonical
                (list->vector
                 (map (lambda (s)
                        `(("id"   . ,(or (alist-ref s 'id) ""))
                          ("name" . ,(or (alist-ref s 'name) ""))
                          ;; the GEOGRAPHIC path (earth → region → commune) for the crumb
                          ("path" . ,(list->vector
                                      (map (lambda (p) `(("id"   . ,(or (alist-ref p 'id) ""))
                                                         ("name" . ,(or (alist-ref p 'name) ""))))
                                           (or (alist-ref s 'path) '()))))))
                      sc))))
              ;; the choice is read AFTER the app has spoken: seam-scopes!
              ;; answers SYNCHRONOUSLY — the device's remembered commune
              ;; (recallScope → setScope) lands in *scope* during the call —
              ;; so a `recalled` computed before it overwrote the recall with
              ;; the roster's first commune on every boot. RECALLED is the
              ;; only thing that paints the UI: a genuinely fresh visitor's
              ;; browser stays on earth — the whole commons (crumb.js's own
              ;; root, unselected) — but CHOSEN still gives every scope-gated
              ;; door somewhere real to write through until they dial one,
              ;; same as before.
              (let* ((recalled (and *scope* (member *scope* ids) *scope*))
                     (chosen   (or recalled (and (pair? ids) (car ids)))))
                (when chosen (set! *scope* chosen) (watch-slots!))
                (when recalled (seam-scope! recalled))
                ;; every membership, dialed scope first — the AID rides along
                ;; so each snapshot includes social invites directed at us
                (when chosen
                  (seam-trace! (string-append "seat:fetching, dialed " chosen))
                  (fetch-scopes! cap (cons chosen (remove (lambda (i) (equal? i chosen))
                                                          ids)))))
              #t))
          ;; nothing to do on success — the body above already reported every
          ;; status and kicked off fetch-scopes! itself. A fulfilled-handler
          ;; here (there was one) fires on EVERY successful roster fetch, so
          ;; whatever it names overwrites the real status right after it —
          ;; this is what "connected, but shows commune unreachable" was
          ;; (found live): the vow resolved fine, then its own success
          ;; handler stomped the door state to "seat:roster-broken", which
          ;; id.ts reads as unlocked-but-unreachable.
          #f
          ;; a broken or thrown seat NAMES itself: this chain going silent is
          ;; exactly "connected, but only demo data" (found live), and a
          ;; symptom with no name cannot be reported
          #:catch (lambda _
                    (seam-trace! "seat:roster-broken")
                    ;; no roster = no seat: the door IS shut, and says so in
                    ;; the one family id.ts reads as shut
                    (seam-status! "error:seat roster unreachable")
                    #f)))))

;; run THUNK; on any throw, say LABEL on the status trace and move on —
;; #:unwind? #t is the whole point: the handler runs OUTSIDE the raise
;; continuation, so the seat's remaining steps proceed
(define (%caught thunk label)
  (with-exception-handler
   (lambda (e) (seam-trace! label) #f)
   thunk
   #:unwind? #t))

;;; ── Contacts: the client-synced contact book, to the dial ────────────────
;; `list-contacts`/`sync-contacts` on the AID-bound session read/write a
;; per-AID file (doors/lobby.scm). A row is {alias, aid, rel, online} and what
;; stands between the two people: `rel` is the kind the person tags the
;; contact with (their own label, one vocabulary — relationship-kinds.scm);
;; `online` is best-effort presence; `recognised`, `mine`, `theirs` and `ask`
;; are the gateway's `relationships` reading of the credentials, and
;; `verified` is the book's own note that the contact's key log was checked.
(define (contact-aid* c)
  (let ((p (or (alist-ref c 'prefix #f) (alist-ref c 'aid #f) "")))
    (if (string? p) p "")))
(define (contact->wire c online-names relation card)
  (let ((alias (str-field c 'alias))
        (aid   (contact-aid* c))
        (ask   (alist-ref relation 'ask #f))
        (theirs-card (alist-ref card 'card #f))
        (given (alist-ref card 'given #f)))
    `(("alias"  . ,alias)
      ("aid"    . ,aid)
      ("rel"    . ,(normalize-rel (alist-ref c 'rel #f)))
      ;; online if the gateway sees a connected session under this contact's
      ;; AID (dial peers announce by AID) or display-name (repl peers by name),
      ;; OR the record already carries it (a mesh-resolved contact may).
      ("online" . ,(if (or (member aid online-names)
                           (member alias online-names)
                           (alist-ref c 'online #f)) #t #f))
      ("recognised" . ,(if (alist-ref relation 'recognised #f) #t #f))
      ("verified"   . ,(if (alist-ref c 'verified #f) #t #f))
      ;; a vouch is present only while it stands
      ,@(let ((m (str-field relation 'mine #f)))   (if m `(("mine" . ,m)) '()))
      ,@(let ((t (str-field relation 'theirs #f))) (if t `(("theirs" . ,t)) '()))
      ;; the card they gave, opened here with this identity's own key: its
      ;; content as the JSON text its giver wrote, "" when this device cannot
      ;; open it; and when our own card to them was made
      ,@(if (string? theirs-card) `(("card" . ,(open-card theirs-card))) '())
      ,@(if (string? given) `(("given" . ,given)) '())
      ,@(if (pair? ask)
            `(("ask" . (("said"   . ,(str-field ask 'said))
                        ("count"  . ,(int-field ask 'count 0))
                        ("quorum" . ,(int-field ask 'quorum 1))
                        ("signed" . ,(if (alist-ref ask 'signed #f) #t #f)))))
            '()))))

(define *contacts* #f)   ; cached raw contact book — the book changes rarely;
                         ; presence changes often, and re-maps it in memory.
(define *relations* '()) ; the last `relationships` reading, rows keyed by 'aid
(define *cards* '())     ; the last `cards` reading, rows keyed by 'aid
(define (row-of rows aid)
  (or (find (lambda (r) (equal? aid (alist-ref r 'aid #f))) rows) '()))
(define (push-contacts! cs online-names)
  (seam-contacts!
   (scm->json-canonical
    (list->vector (map (lambda (c)
                         (let ((aid (contact-aid* c)))
                           (contact->wire c online-names (row-of *relations* aid) (row-of *cards* aid))))
                       cs)))))

;; a card's wire is {from,to,at,sealed,said,sig}; its content is what SEALED
;; opens to under this identity's own encryption key
(define (open-card wire)
  (let ((o (with-exception-handler (lambda (e) #f)
             (lambda () (json-read-ordered wire)) #:unwind? #t)))
    (let ((sealed (and (pair? o) (assoc-ref o "sealed"))))
      (if (string? sealed) (ret-open-text sealed) ""))))

;; a promise's answer, read plain, handed to K — DEFAULT where there is no
;; promise or it breaks
(define (then-value promise default k)
  (if (not promise)
      (k default)
      (with-vat *vat*
        (on promise
            (lambda (v) (k (denormalize-syrup v)))
            #:catch (lambda _ (k default))))))

;; THEN is a thunk run once the fetch settles (success or fail) — used at
;; sign-in to announce presence only AFTER the book is cached, so the broadcast
;; announce triggers re-maps in memory instead of forcing a cold re-fetch.
(define (fetch-contacts*! then)
  (when (and *session* *lobby*)
    ;; the reads go out together; the book lands once the others have settled.
    ;; A gateway that cannot answer one of them leaves the rows as the rest
    ;; has them.
    (with-vat *vat*
      (let ((book   (<- *session* 'list-contacts))
            ;; what stands between the person and each contact, in
            ;; credentials and in cards
            (rels   (and *scope* (<- *session* 'relationships *scope*)))
            (cards  (<- *session* 'cards))
            (online (<- *lobby* 'online-users)))
        (then-value online '()
          (lambda (names)
            (then-value rels #f
              (lambda (r)
                (match r (('ok . rows) (set! *relations* (filter pair? (->list rows)))) (_ #f))
                (then-value cards #f
                  (lambda (c)
                    (match c (('ok . rows) (set! *cards* (filter pair? (->list rows)))) (_ #f))
                    (with-vat *vat*
                      (on book
                          (lambda (raw)
                            (set! *contacts* (->plain-list raw))   ; cache the book
                            (push-contacts! *contacts* (filter string? (->list names)))
                            (then))
                          #:catch (lambda _ (then))))))))))))))
(define (fetch-contacts!) (fetch-contacts*! (lambda () #t)))

;;; ── Folksonomy: the commune's aggregated classification cut, to the dial ─────
;; `folksonomy-template` on the AID-bound session returns the scope's weighted
;; DAG extracted to one legible tree: {id,label,children,count} over FLAT
;; term-ids (folksonomy.md). The dial feeds it straight to rebuildSpine via the
;; `dial.taxonomy` channel — structure, on its own cadence, not the per-tick
;; `dial.data` demand channel. Empty cut (fresh commons) → JS guards on empty
;; children and keeps the current spine, so this never flickers.
(define (tax-node->wire n)
  `(("id"       . ,(or (alist-ref n 'id) ""))
    ("label"    . ,(or (alist-ref n 'label) ""))
    ("count"    . ,(or (alist-ref n 'count) 0))
    ("children" . ,(list->vector
                    (map tax-node->wire (->list (alist-ref n 'children '())))))))
;; The CF lens for the spine (folksonomy.md Phase 4): a name the gateway
;; resolves against THIS AID's contact rel graph — "friends"/"family"/"commons"/
;; "me"/… weight the cut toward that neighbourhood; #f = the global cut. The
;; contacts filter UI sets it via the `taxonomyLens` handler and the spine
;; re-derives toward how your people carve the world.
(define *tax-lens* #f)
(define (fetch-taxonomy!)
  (when (and *session* *lobby*)
    (with-vat *vat*
      (on (<- *session* 'folksonomy-template *tax-lens*)
          (lambda (raw)
            (let ((tree (denormalize-syrup raw)))
              (when (pair? tree)
                (seam-taxonomy! (scm->json-canonical (tax-node->wire tree))))))
          #:catch (lambda _ #f)))))
(define (handle-taxonomy-lens name cb)
  (set! *tax-lens* (if (and (string? name) (not (string=? name ""))) name #f))
  (fetch-taxonomy!)
  (reply! cb "ok"))

;; ── temporary socialization ─────────────────────────────────────────────────
;; declare an owned means, then socialize it (client-signed, like the stance
;; path: server hands a preimage, the browser re-derives the SAID and signs it
;; with the resident key, server verifies + issues), list your grants, recall.
;; The AID is the session's — owner is non-spoofable.
(define (soc-ar a k) (let ((p (assq k a))) (and p (cdr p))))
;; ── signing as this identity ─────────────────────────────────────────────
;; K receives the 64-byte signature (or #f when nothing can sign): the KEL key
;; in a root session, synchronously; the device key in a device session,
;; through the JS callback (WebCrypto and WebAuthn are async by nature).
(define (can-sign?) (or (and *secret* #t) (eq? *tier* 'device)))
(define (sign-as-self! bv k)
  (cond
   (*secret* (k (sign-bytes bv *secret*)))
   ((eq? *tier* 'device)
    (%device-sign (bytevector->uint8array bv)
                  (procedure->external
                   (lambda (sig)
                     (let ((bv (uint8array->bytevector sig)))
                       (k (and (= 64 (bytevector-length bv)) bv))))))
    #t)
   (else (k #f))))
;; the CESR "0B" form over a SAID's UTF-8 — what every server-side verifier reads
(define (sign-said-as-self! said k)
  (sign-as-self! (string->utf8 said)
                 (lambda (sig) (k (and sig (cesr-bytes->qb64 "0B" sig))))))
(define (fetch-my-grants!)
  (when (and *session* *lobby*)
    (with-vat *vat*
      (on (<- *session* 'my-grants)
          (lambda (raw)
            ;; TWO REPLY CONVENTIONS live on this seam, and they differ by one
            ;; cons: the planner service wraps with `(cons 'ok x)` (so
            ;; planner-call's `('ok . v)` is right for it), while the GOVERNANCE
            ;; service — my-grants, socialize-preimage, desocialize — replies
            ;; `(list 'ok x)`. Read a governance reply with `('ok . gs)` and gs
            ;; becomes a list holding the payload: empty grants gave `(())`, and
            ;; `list-ref` then hit `car` of `()`; a non-empty list quietly put a
            ;; whole list where each field belonged.
            (match (denormalize-syrup raw)
              (('ok gs)
               (seam-grants!
                (scm->json-canonical
                 (list->vector
                  (map (lambda (g)   ; (said spec holder until qty kind eligible)
                         (list (cons "id"    (list-ref g 0))
                               (cons "spec"  (list-ref g 1))
                               (cons "to"    (list-ref g 2))
                               (cons "until" (list-ref g 3))
                               (cons "qty"   (list-ref g 4))
                               (cons "kind"  (if (> (length g) 5) (list-ref g 5) "use"))
                               (cons "eligible" (if (> (length g) 6) (list-ref g 6) ""))))
                       gs)))))
              (_ #f)))
          #:catch (lambda _ #f)))))
;; Everything a citizen writes INTO a scope — their slots, their position —
;; shares one guard: signed in, and a scope chosen. A MACRO for the same reason
;; planner-call is one: SEND stays unevaluated until it is inside the vat turn.
(define-syntax scoped-call
  (syntax-rules ()
    ((_ cb send on-ok)
     (cond
      ((not *session*) (reply! cb "err:sign in first"))
      ((not *scope*)   (reply! cb "err:no scope yet"))
      (else (planner-call cb send on-ok))))))

;; the coercions the dial's FFI edge needs: every argument arrives as a string,
;; and "" reads as absent.
(define (arg-num v) (if (string? v) (or (string->number v) 0) v))
(define (arg-str v) (if (string? v) v ""))
;; a flag however the page spelled it: a boolean, a number, or "yes"/"true"/"1"
(define (arg-bool v)
  (cond ((boolean? v) v)
        ((number? v) (not (zero? v)))
        ((string? v) (and (member v '("yes" "true" "1")) #t))
        (else #f)))
(define (arg-opt v) (and (string? v) (not (string-null? v)) v))

;; slots: capacity + need as ONE expression (free-association port). The
;; arcs JSON is the same {start,end,days[]} convention the calendar's
;; availability always spoke; note/emoji ride the record's own note/image.
;; The scope rides in explicitly here: a means is declared into the scope it is
;; being offered to, which the socialize flow picks per grant.
;; CATS is a JSON array of folksonomy term-ids (the classify pass's
;; suggestion, or the citizen's own tags) — the slot's classification for
;; the match ring's affinity scoring. "" declares untagged, as ever.
;; the write standpoint is the spine's *scope*, stated once (scoped-call) —
;; the same door declare-need and both retires cross. Taking a scope from
;; the caller let the earth standpoint (scope null) declare an offer into
;; scope "" while the need beside it landed in *scope*, where retire-means
;; then could not find it.
(define (handle-declare-means spec qty unit loc arcs note emoji name cats criteria cb)
  (scoped-call cb (<- *session* 'declare-means *scope* spec
                     (arg-num qty)
                     (or (arg-opt unit) "each")
                     (arg-opt loc)
                     (arg-str arcs) (arg-str note) (arg-str emoji) (arg-str name)
                     (arg-str cats) (arg-str criteria))
    (lambda (_) (reply! cb "ok"))))

;; CRITERIA is one JSON object — the matcher-only sidecar (the eligibility
;; rule, divisibility, an online link, a priority); "" declares none.
;; TENSION ("floor" | "held" | "des", "" = des) and VOICE (the attached
;; emphasis — the row's total tension mass, "" = nothing attached) are the
;; need's kind and weight (tension-terms.scm) — the last two of the variadic
;; tail, after name, cats and the criteria sidecar.
(define (handle-declare-need spec qty unit loc arcs note emoji from until name cats criteria tension voice cb)
  (scoped-call cb (<- *session* 'declare-need *scope* spec
                     (arg-num qty)
                     (if (string? unit) unit "each")
                     (arg-str loc) (arg-str arcs) (arg-str note) (arg-str emoji)
                     (arg-str from) (arg-str until) (arg-str name) (arg-str cats)
                     (arg-str criteria) (arg-str tension) (arg-num voice))
    (lambda (_) (reply! cb "ok"))))

;; the declaration-time displacement chip: what one unit of SPEC currently displaces
;; elsewhere in the plan, off the scope's last solve (lobby need-displacement). Read
;; in the âï¸ editor BEFORE a level is stated; a scope with no solve yet
;; reads nothing and the chip stays silent.
(define (handle-need-displacement spec qty cb)
  (scoped-call cb (<- *session* 'need-displacement *scope* spec (arg-num qty))
    (lambda (v)
      (reply! cb (scm->json-canonical
                  (if (alist-ref v 'read?)
                      `(("read" . #t)
                        ("perUnit" . ,(alist-ref v 'per-unit 0))
                        ("moved" . ,(alist-ref v 'moved 0))
                        ;; the burn-meter's read of this spec, when kept solves
                        ;; have read it: solves counted + mean moved
                        ,@(let ((h (alist-ref v 'honesty)))
                            (if h `(("honesty" . (("sigma" . ,(alist-ref h 'sigma 0))
                                                  ("radiusWholeHand" . ,(alist-ref h 'radius-whole-hand 0))
                                                  ,@(let ((tol (alist-ref h 'solve-tolerance)))
                                                      (if tol `(("solveTolerance" . ,tol)) '())))))
                                '()))
                        ,@(let ((l (alist-ref v 'lately)))
                            (if l `(("lately" . (("solves" . ,(alist-ref l 'solves 0))
                                                 ("meanMoved" . ,(alist-ref l 'mean-moved 0)))))
                                '())))
                      '(("read" . #f))))))))

;; the constitution's gate: ratify SPEC as KIND ("floor" | "held"; "des"
;; withdraws), and read the scope's grants
(define (handle-ratify-kind spec kind cb)
  (scoped-call cb (<- *session* 'ratify-kind *scope* spec (arg-str kind))
    (lambda (_) (reply! cb "ok"))))
(define (handle-ratified-kinds cb)
  (scoped-call cb (<- *session* 'ratified-kinds *scope*)
    (lambda (v)
      (reply! cb (scm->json-canonical
                  (list->vector
                   (map (lambda (g)
                          `(("spec" . ,(alist-ref g 'spec ""))
                            ("kind" . ,(alist-ref g 'kind "des"))
                            ("by" . ,(alist-ref g 'by ""))
                            ("at" . ,(alist-ref g 'at ""))))
                        (or (alist-ref v 'grants) '()))))))))

;; stage 3: audit the scope's ratified kinds (any member may; the auditor is
;; named on every finding), and read the record. Findings ride as JSON rows
;; {spec, who, kind, declared, observed, verdict, rate, by, at}.
(define (finding->wire f)
  `(("spec" . ,(alist-ref f 'spec "")) ("who" . ,(alist-ref f 'who ""))
    ("kind" . ,(alist-ref f 'kind "")) ("declared" . ,(alist-ref f 'declared 0))
    ("observed" . ,(alist-ref f 'observed 0)) ("verdict" . ,(alist-ref f 'verdict ""))
    ("rate" . ,(alist-ref f 'rate 1)) ("by" . ,(alist-ref f 'by "")) ("at" . ,(alist-ref f 'at ""))))
(define (handle-audit-kinds cb)
  (scoped-call cb (<- *session* 'audit-kinds *scope*)
    (lambda (v)
      (reply! cb (scm->json-canonical
                  `(("examined" . ,(alist-ref v 'examined 0)) ("padded" . ,(alist-ref v 'padded 0))
                    ("findings" . ,(list->vector (map finding->wire (or (alist-ref v 'findings) '()))))))))))
(define (handle-audits cb)
  (scoped-call cb (<- *session* 'audits *scope*)
    (lambda (v)
      (reply! cb (scm->json-canonical (list->vector (map finding->wire (or (alist-ref v 'findings) '()))))))))

;; the burn-meter entire: the scope's moved-distribution over its kept solves
(define (handle-externality-history cb)
  (scoped-call cb (<- *session* 'externality-history *scope*)
    (lambda (v)
      (reply! cb (scm->json-canonical
                  `(("solves" . ,(alist-ref v 'solves 0))
                    ("meanTotal" . ,(alist-ref v 'mean-total 0))
                    ("specs" . ,(list->vector
                                 (map (lambda (s)
                                        `(("spec" . ,(alist-ref s 'spec ""))
                                          ("solves" . ,(alist-ref s 'solves 0))
                                          ("meanMoved" . ,(alist-ref s 'mean-moved 0))
                                          ("lastMu" . ,(alist-ref s 'last-mu 0))))
                                      (or (alist-ref v 'specs) '()))))))))))

(define (handle-retire-need spec cb)
  (scoped-call cb (<- *session* 'retire-need *scope* spec)
    (lambda (_) (reply! cb "ok"))))
;; the offer side's withdrawal — a lower to zero, record + history standing
(define (handle-retire-means spec cb)
  (scoped-call cb (<- *session* 'retire-means *scope* spec)
    (lambda (_) (reply! cb "ok"))))

;; ── payouts: "send N XMR of my claim to ⟨address⟩" ─────────────────────────
;; The member never holds a key: the claim is a record, the wallet is the
;; commons', the gateway's runner moves the coins under the policy. These
;; three ride the session AID like every other slot write.
(define (handle-request-payout address xmr due note cb)
  (scoped-call cb (<- *session* 'request-payout *scope* address (arg-num xmr) due note)
    (lambda (_) (reply! cb "ok"))))
;; the member's payouts and what the commons owes them: the my-payouts table's
;; reply (doors/record-rows.scm), as it arrives
(define (handle-my-payouts cb)
  (scoped-call cb (<- *session* 'my-payouts *scope*)
    (lambda (v) (reply! cb (scm->json-canonical v)))))
;; the citizen's order book (service my-claims)
(define (handle-my-claims cb)
  (scoped-call cb (<- *session* 'my-claims *scope*)
    (lambda (v) (reply! cb (scm->json-canonical v)))))
;; the citizen's credit, dated (service my-credit-history)
(define (handle-my-credit-history cb)
  (scoped-call cb (<- *session* 'my-credit-history *scope*)
    (lambda (v) (reply! cb (scm->json-canonical v)))))
;; what every source says of a spec: the reading fold's rows and drift (service readings-of)
(define (handle-scope-readings spec cb)
  (scoped-call cb (<- *session* 'scope-readings *scope* (arg-str spec))
    (lambda (v) (reply! cb (scm->json-canonical v)))))
(define (handle-retire-payout id cb)
  (scoped-call cb (<- *session* 'retire-payout *scope* id)
    (lambda (_) (reply! cb "ok"))))

;; the history behind the fold: every reading of a spec between two instants, and
;; their fold, each row in the fold's own shape (service readings-between)
(define (handle-readings-between spec from until cb)
  (scoped-call cb (<- *session* 'readings-between *scope* (arg-str spec) (arg-str from) (arg-str until))
    (lambda (v) (reply! cb (scm->json-canonical v)))))
;; ── purchases for the commons: "I bought this for us" ──────────────────────
;; What the commons then owes rides my-payouts' "owed" list above — minted as
;; a debt through governance's own accept-reimbursement once the commune
;; accepts (governance/scope.scm), not this call.
;; replies the purchase EVENT's id (not a bare "ok") — the claim that
;; follows carries it as triggered-by, tying the signed word to the
;; recorded raise it speaks about
(define (handle-record-purchase spec qty unit money-spec cost where note receipt donation cb)
  (scoped-call cb (<- *session* 'record-purchase *scope* spec (arg-num qty) unit money-spec
                      (arg-num cost) where note receipt (string=? donation "yes"))
    (lambda (v) (reply! cb (or (alist-ref v 'event) "ok")))))

;; ── skills: the citizen's own labour-power ──────────────────────────────────
;; declare/revoke ride the session AID (self-only, non-spoofable); the scope's
;; labour fold refolds on the write, so the roster the UC matches over moves
;; with the dial. my-skills answers the held set, one spec-id per line.
(define (handle-declare-skill spec cb)
  (scoped-call cb (<- *session* 'declare-skill *scope* (arg-str spec))
    (lambda (_) (reply! cb "ok"))))
(define (handle-revoke-skill spec cb)
  (scoped-call cb (<- *session* 'revoke-skill *scope* (arg-str spec))
    (lambda (_) (reply! cb "ok"))))
(define (handle-my-skills cb)
  (scoped-call cb (<- *session* 'my-skills *scope*)
    (lambda (v)
      (let ((skills (let ((p (assq 'skills v))) (if p (cdr p) '()))))
        (reply! cb (fold (lambda (s acc)
                           (if (string-null? acc) s
                               (string-append acc "\n" s)))
                         "" skills))))))

;; ── the profile's standing: what the record shows for each held skill ─────
;; Hours cross as strings, the inbox's own convention.
(define (handle-my-skill-standing cb)
  (scoped-call cb (<- *session* 'my-skill-standing *scope*)
    (lambda (v)
      (reply! cb (scm->json-canonical
                  (list->vector
                   (map (lambda (r)
                          `(("skill"     . ,(str-field r 'skill))
                            ("held"      . ,(if (alist-ref r 'held #f) #t #f))
                            ("hours"     . ,(wire-value 'num (alist-ref r 'hours 0) #f))
                            ("events"    . ,(alist-ref r 'events 0))
                            ("witnessed" . ,(alist-ref r 'witnessed 0))
                            ("attesters" . ,(alist-ref r 'attesters 0))
                            ("witnessedHours" . ,(wire-value 'num (alist-ref r 'witnessed-hours 0) #f))
                            ("competence" . ,(wire-value 'num (alist-ref r 'competence 0) #f))
                            ("pending"
                             . ,(list->vector
                                 (map (lambda (p)
                                        `(("count"  . ,(alist-ref p 'count 0))
                                          ("quorum" . ,(alist-ref p 'quorum 1))))
                                      (->list (alist-ref r 'pending '())))))))
                        (->list (alist-ref v 'standing '())))))))))

;; ── live / expected position ────────────────────────────────────────────────
;; Where the citizen IS at PERIOD (0 = now, any t > 0 = a declared future). The
;; planner reads it as the commute origin for their labour and the cell their
;; reproduction floors sit in (planner.scm agent-position), so moving moves both
;; what they can reach and what the plan brings to them. Raw coordinates go to
;; `set-position-latlon`, which snaps them to the scope's nearest known place
;; server-side — the stored fact is a place id, never a trace. An empty PLACE
;; clears that period back to the citizen's home.
(define (handle-set-position period place cb)
  (scoped-call cb (<- *session* 'set-position *scope* (arg-num period) (arg-opt place))
    (lambda (_) (reply! cb "ok"))))

(define (handle-set-position-here period lat lon cb)
  (scoped-call cb (<- *session* 'set-position-latlon *scope* (arg-num period)
                      (arg-num lat) (arg-num lon))
    (lambda (place) (reply! cb (if (string? place) place "ok")))))

;; Whether the citizen shares where they are: live, here or off, declared once
;; at their home (a lease behind it: a fix counts while fresh). The reply is the
;; mode's name.
(define (handle-set-location-sharing mode cb)
  (scoped-call cb (<- *session* 'set-location-sharing *scope* (arg-str mode))
    (lambda (m) (reply! cb (if (symbol? m) (symbol->string m) "ok")))))

(define (handle-location-sharing cb)
  (scoped-call cb (<- *session* 'location-sharing *scope*)
    (lambda (m) (reply! cb (if (symbol? m) (symbol->string m) "undeclared")))))

;; The citizen's registered HOME: the agent record's primary location, the
;; floor every position rule falls back to. A known place id, or an empty
;; PLACE with coordinates for the citizen's own place:AID:home; the id comes back.
(define (handle-set-home place lat lon cb)
  (scoped-call cb (<- *session* 'set-home *scope* (arg-str place) (arg-num lat) (arg-num lon))
    (lambda (v)
      (fetch-snapshot!)
      (reply! cb (let ((id (and (pair? v) (alist-ref v 'place)))) (if (string? id) id "ok"))))))

;; the dwelling you live in, typed for the housing closure; the snapshot
;; re-fetch brings the resource into the scope's view
(define (handle-declare-dwelling place area rooms warmth-winter warmth-summer beds attests certified rent tenure cb)
  (scoped-call cb (<- *session* 'declare-dwelling *scope* (arg-str place) (arg-num area) (arg-num rooms)
                      (arg-num warmth-winter) (arg-num warmth-summer) (arg-num beds)
                      (arg-str attests) (arg-bool certified) (arg-num rent) (arg-str tenure))
    (lambda (v)
      (fetch-snapshot!)
      (reply! cb (let ((id (and (pair? v) (alist-ref v 'resource)))) (if (string? id) id "ok"))))))

;; a new place by name (+ optional coordinates): the id comes back, so the
;; slot's WHERE can take it at once; the snapshot re-fetch brings the place
;; itself into the scope's location list
(define (handle-declare-place name lat lon address parent cb)
  (scoped-call cb (<- *session* 'declare-place *scope* (arg-str name) (arg-num lat) (arg-num lon)
                      (arg-str address) (arg-str parent))
    (lambda (v)
      (fetch-snapshot!)
      (reply! cb (let ((id (and (pair? v) (alist-ref v 'id)))) (if (string? id) id "ok"))))))

;; the slot doors: a person's own slots, the scope's fold, the scope's pool as
;; the map reads it, and the match ring's one read
(define (handle-our-slots cb)
  (scoped-call cb (<- *session* 'our-slots *scope* *scope*)
    (lambda (v) (reply! cb (scm->json-canonical v)))))
(define (handle-my-slots cb)
  (scoped-call cb (<- *session* 'my-slots *scope*)
    (lambda (v) (reply! cb (scm->json-canonical v)))))
(define (handle-slots-at cb)
  (scoped-call cb (<- *session* 'slots-at *scope*)
    (lambda (v) (reply! cb (scm->json-canonical v)))))
(define (handle-match-slots cb)
  (scoped-call cb (<- *session* 'match-slots *scope*)
    (lambda (v) (reply! cb (scm->json-canonical v)))))
;; ELIGIBLE: the owner's steward rule — the slot criteria JSON ("" = anyone),
;; forwarded verbatim on both legs so the signed SAID and the issued one agree
(define (handle-socialize commune spec qty until movable rt cf res kind ref eligible cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (let ((q  (if (string? qty) (or (string->number qty) 0) qty))
            (mv (string=? movable "yes")))
        (with-vat *vat*
          (on (<- *session* 'socialize-preimage commune spec q until mv rt cf res kind ref eligible)
              (lambda (p0)
                ;; governance service → `(list 'ok fields)`; see fetch-my-grants!.
                ;; Bound as `('ok . f)` every `soc-ar` lookup returned #f, so the
                ;; SAID was computed over blanks and the signature could not
                ;; verify — socialization failed with a signature error whose
                ;; cause was this cons.
                (match (denormalize-syrup p0)
                  (('ok f)
                   (sign-said-as-self!
                     (compute-said (soc-ar f 'issuer) (soc-ar f 'holder) (soc-ar f 'schema)
                                   (soc-ar f 'claims) (or (soc-ar f 'edges) '()))
                    (lambda (sig)
                     (with-vat *vat*
                     (on (<- *session* 'socialize-signed commune spec q until mv rt cf res kind ref sig eligible)
                         (lambda (r0)
                           (match (denormalize-syrup r0)
                             (('ok . _) (fetch-my-grants!) (reply! cb "ok"))
                             ((or ('error . (? string? m)) ('error (? string? m))) (reply! cb (string-append "err:" m)))
                             (_ (reply! cb "err:socialize refused"))))
                         #:catch (lambda _ (reply! cb "err:socialize unreachable")))))))
                  ((or ('error . (? string? m)) ('error (? string? m))) (reply! cb (string-append "err:" m)))
                  (_ (reply! cb "err:preimage refused"))))
              #:catch (lambda _ (reply! cb "err:preimage unreachable")))))))
(define (handle-recall said cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'desocialize said)
        (lambda (_) (fetch-my-grants!) (reply! cb "ok")))))

;; ── the scope's declarations, spoken as a governor ──────────────────────
;; Three signed statements a scope makes about itself (federation-flow-map.md
;; §7.4): where a pool stands (span), what it hosts and up to how much
;; (hosting willingness), what regime a recipe's domain is in (regime
;; claim). The governance service issues the credential idempotently and
;; replies (ok said); the refusal for a speaker who is no governor comes
;; back as its error text. `until` "" or absent is open-ended.
(define (scope-declare cb send)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb send (lambda (_) (reply! cb "ok")))))
(define (handle-declare-span scope rid place until cb)
  (scope-declare cb (<- *session* 'declare-span scope rid place (arg-opt until))))
(define (handle-declare-hosting scope spec ceiling until cb)
  (scope-declare cb (<- *session* 'declare-hosting scope spec (arg-num ceiling) (arg-opt until))))
(define (handle-claim-regime scope recipe tails process until cb)
  (scope-declare cb (<- *session* 'claim-regime scope recipe tails process (arg-opt until))))

;; ── purchase claims: "I gave the commons this" — the reimbursement
;; primary, client-signed exactly like socialize above. Replying the
;; claim's own SAID (not just "ok") since a member needs it to hand to
;; whoever calls accept-reimbursement.
(define (handle-purchase-claim commune spec qty unit due res ref trig cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (let ((q (if (string? qty) (or (string->number qty) 0) qty)))
        (with-vat *vat*
          (on (<- *session* 'purchase-claim-preimage commune spec q unit due res ref trig)
              (lambda (p0)
                (match (denormalize-syrup p0)
                  (('ok f)
                   (sign-said-as-self!
                     (compute-said (soc-ar f 'issuer) (soc-ar f 'holder) (soc-ar f 'schema)
                                   (soc-ar f 'claims) (or (soc-ar f 'edges) '()))
                    (lambda (sig)
                     (with-vat *vat*
                     (on (<- *session* 'purchase-claim-signed commune spec q unit due res ref trig sig)
                         (lambda (r0)
                           (match (denormalize-syrup r0)
                             (('ok said) (reply! cb said))
                             ((or ('error . (? string? m)) ('error (? string? m))) (reply! cb (string-append "err:" m)))
                             (_ (reply! cb "err:purchase-claim refused"))))
                         #:catch (lambda _ (reply! cb "err:purchase-claim unreachable")))))))
                  ((or ('error . (? string? m)) ('error (? string? m))) (reply! cb (string-append "err:" m)))
                  (_ (reply! cb "err:preimage refused"))))
              #:catch (lambda _ (reply! cb "err:preimage unreachable")))))))

;; ── accepting a grant or a reimbursement — the commune's own word, no
;; new signature (the caller's session identity is already the proof).
(define (handle-accept-socialization commune grant-said cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'accept-socialization commune grant-said)
        (lambda (_) (reply! cb "ok")))))
(define (handle-accept-reimbursement commune claim-said cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'accept-reimbursement commune claim-said)
        (lambda (_) (reply! cb "ok")))))

;; Shared tail of the taxonomy write handlers: fire the send, and on success
;; optionally re-fetch the cut, then reply ok (else err). MAKE-PROMISE is a thunk
;; so the (<- …) is created inside the vat turn, as Goblins needs. REFETCH? is #t
;; for ADOPT (you want to see the cut you adopted) but #f for PUBLISH: your local
;; edit is your working view — the vote is cast server-side and the aggregate
;; reconciles on the next refresh, rather than snapping your tweak back to the
;; consensus the instant you make it ("using is voting", not "using loses to the
;; seed's tiebreak").
(define (reply-after-taxonomy cb make-promise refetch?)
  (with-vat *vat*
    (on (make-promise)
        (lambda (_) (when refetch? (fetch-taxonomy!)) (reply! cb "ok"))
        #:catch (lambda _ (reply! cb "err")))))
;; Adopt the cut you're looking at (the current lens's) as YOUR published
;; taxonomy — closes the loop: your adoption becomes a vote in the aggregate.
;; The gateway does template->doc + publish; we just re-fetch so the spine
;; reflects the (slightly shifted) cut.
(define (handle-adopt-cut cb)
  (if (not *session*)
      (reply! cb "err:sign in first")
      (reply-after-taxonomy cb (lambda () (<- *session* 'adopt-lens *tax-lens*)) #t)))
;; Publish the current spine as MY taxonomy cut (edit-republish). WIRE is the
;; parser-free flattening main.js sends — lines of `T<tab>id<tab>label` and
;; `E<tab>broader<tab>narrower`. We parse it into a taxonomy doc and route it
;; through the SAME sync-taxonomy path (persist + contribute) — no new server
;; method, no JSON parser needed.
(define %wire-nl  (integer->char 10))   ; #\tab / #\newline as values — avoid any
(define %wire-tab (integer->char 9))    ; named-char reader gaps in the Hoot build
(define (handle-publish-spine wire cb)
  (if (not *session*)
      (reply! cb "err:sign in first")
      (let loop ((lines (string-split (if (string? wire) wire "") %wire-nl))
                 (terms '()) (edges '()))
        (if (null? lines)
            (reply-after-taxonomy cb
              (lambda () (<- *session* 'sync-taxonomy
                             (list (cons 'terms (reverse terms))
                                   (cons 'structure (reverse edges)))))
              #f)   ; publish keeps the local edit; the vote reconciles on refresh
            (let ((f (string-split (car lines) %wire-tab)))
              (cond
               ((and (>= (length f) 3) (string=? (car f) "T"))
                (loop (cdr lines)
                      (cons (list (cons 'id (list-ref f 1)) (cons 'label (list-ref f 2)))
                            terms)
                      edges))
               ((and (>= (length f) 3) (string=? (car f) "E"))
                (loop (cdr lines) terms
                      (cons (list (cons 'broader (list-ref f 1))
                                  (cons 'narrower (list-ref f 2)))
                            edges)))
               (else (loop (cdr lines) terms edges))))))))

;; live presence: the gateway broadcasts the online set to this inbox on every
;; connect/leave. The book hasn't changed — only who's online — and that set
;; rides in the message, so we just re-map the CACHED book against it: no disk
;; read, no extra RPC. (Cold start before the cache lands → one full fetch.)
(define *inbox* #f)
(define (^dial-inbox _bcom)
  (methods
   ((presence-update users)
    (let ((online (filter string? (->plain-list users))))
      (if *contacts*
          (push-contacts! *contacts* online)
          (fetch-contacts!)))
    #t)
   ;; WebRTC signaling relayed by the gateway → the live walkie mesh
   ((webrtc-signal from-name signal-type signal-data)
    (walkie-route-signal from-name signal-type signal-data)
    #t)
   ;; the gateway pushes a room's roster on every join/leave in it — this is
   ;; how a peer who arrives AFTER us gets meshed without anyone polling.
   ((room-roster room members)
    (walkie-apply-roster! room (filter string? (->plain-list members)))
    #t)))
(define (announce-presence!)
  (when (and *lobby* *aid*)
    (unless *inbox* (set! *inbox* (spawn ^dial-inbox)))
    (with-vat *vat*
      (on (<- *lobby* 'announce *aid* *inbox*)
          (lambda (_users) #t)
          #:catch (lambda _ #f)))))

;; every change to the book is one shape: read the gateway's copy, rewrite it
;; with EDIT (book → book), sync it back, and read it again for the page. K
;; hears "ok" or the refusal.
(define (edit-book* edit k)
  (if (not *session*)
      (k "err:sign in first")
      (with-vat *vat*
        (on (<- *session* 'list-contacts)
            (lambda (raw)
              (let ((updated (edit (->plain-list raw))))
                (with-vat *vat*
                  (on (<- *session* 'sync-contacts updated)
                      (lambda (_) (fetch-contacts!) (k "ok"))
                      #:catch (lambda _ (fetch-contacts!) (k "err:contacts unreachable"))))))
            #:catch (lambda _ (k "err:contacts unreachable"))))))
(define (edit-book! edit cb) (edit-book* edit (lambda (s) (reply! cb s))))

;; tag: the kind the person knows a contact as, written into the book. The tag
;; is the person's own label; a vouch is its own act (handle-fp-vouch).
(define (handle-set-contact-rel aid rel cb)
  (edit-book!
   (lambda (cs)
     (map (lambda (c)
            (if (string=? (contact-aid* c) aid)
                (cons (cons 'rel (normalize-rel rel))
                      (filter (lambda (kv) (not (eq? (car kv) 'rel))) c))
                c))
          cs))
   cb))

;; connect: someone enters the book. Their key is checked against what the
;; commune holds: ^oobi-host keeps a key log only once it has verified it
;; (signup-agent's witness-kel!), so a log held for the AID is a checked key.
;; A person the commune holds no log for enters the book unchecked, and the
;; row says so.
(define (key-held? aid k)
  (if (not *lobby*) (k #f)
      (with-vat *vat*
        (on (<- *lobby* 'fetch-icp aid)
            (lambda (entry) (k (pair? (denormalize-syrup entry))))
            #:catch (lambda _ (k #f))))))
(define (valid-aid-shape? aid)
  (and (string? aid) (= (string-length aid) 44)))
(define (handle-contact-check aid cb)
  (cond
   ((not (valid-aid-shape? aid)) (reply! cb "err:that is not a person's identifier"))
   ;; with no commune reached there is no one to ask: the key is unread, which
   ;; is a different thing from a commune that holds no log for it
   ((not *lobby*) (reply! cb "err:not connected"))
   (else (key-held? aid (lambda (held?) (reply! cb (if held? "ok:checked" "ok:unchecked")))))))
(define (handle-contact-connect aid alias oobi my-name at cb)
  (cond
   ((not *session*) (reply! cb "err:sign in first"))
   ((not (valid-aid-shape? aid)) (reply! cb "err:that is not a person's identifier"))
   ((equal? aid *aid*) (reply! cb "err:that is you"))
   (else
    (key-held? aid
      (lambda (held?)
        (edit-book*
         (lambda (cs)
           (let ((entry `((alias . ,(if (and (string? alias) (not (string=? alias ""))) alias
                                        (string-append (substring aid 0 8) "…")))
                          (prefix . ,aid)
                          (oobi . ,(if (string? oobi) oobi ""))
                          (added-at . ,at)
                          (verified . ,held?)
                          (rel . ,(normalize-rel #f)))))
             (if (any (lambda (c) (string=? (contact-aid* c) aid)) cs)
                 ;; already known: the key check is what a second connect renews
                 (map (lambda (c)
                        (if (string=? (contact-aid* c) aid)
                            (cons (cons 'verified held?)
                                  (filter (lambda (kv) (not (eq? (car kv) 'verified))) c))
                            c))
                      cs)
                 (append cs (list entry)))))
         (lambda (r)
           (when (and (equal? r "ok") *lobby*)       ; best-effort: they may connect back
             (with-vat *vat* (<-np *lobby* 'signal aid *aid* "connect"
                                   (if (string? my-name) my-name ""))))
           (reply! cb (if (equal? r "ok") (if held? "ok:checked" "ok:unchecked") r)))))))))

;; ── contact points: a way to reach you, told to this commune ─────────────
;; The credential is built here exactly as the gateway rebuilds it
;; ((playnet keri first-person credentials) make-contact-point-credential): symbol-keyed
;; claims into compute-said, KIND and STYLE as symbols, a fresh blinding
;; nonce — so the SAID signed here is the SAID the gateway derives from the
;; wire. The person is authoritative for every field, so there is no preimage
;; to fetch: build, sign, present.
(define %schema-contact-point "playnet-contact-point/v1")
(define (sym->str x) (cond ((symbol? x) (symbol->string x)) ((string? x) x) (else "")))
(define (reach-style kind) (if (string=? kind "email") "rich" "terse"))
(define (handle-reach-present kind value at cb)
  (cond
   ((not *session*) (reply! cb "err:sign in first"))
   ((or (string=? kind "") (string=? value "")) (reply! cb "err:a contact point has a kind and a destination"))
   (else
    (let* ((u (cesr-bytes->qb64 "0A" (keri-crypto-random-bytes 16)))
           (style (reach-style kind))
           (claims `((u . ,u) (kind . ,(string->symbol kind)) (ctx . ,value)
                     (style . ,(string->symbol style)) (issued-at . ,at) (expires-at . #f)))
           (said (compute-said *aid* *aid* %schema-contact-point claims '())))
      (sign-said-as-self! said
        (lambda (sig)
          (if (not sig)
              (reply! cb "err:could not sign")
              (let ((wire (scm->json-canonical
                           `(("said" . ,said) ("issuer" . ,*aid*) ("holder" . ,*aid*)
                             ("claims" . (("u" . ,u) ("kind" . ,kind) ("ctx" . ,value)
                                          ("style" . ,style) ("issued-at" . ,at)
                                          ("expires-at" . null)))
                             ("sig" . ,sig)))))
                (with-vat *vat*
                  (planner-call cb (<- *session* 'present-contact-point wire)
                    (lambda (state) (reply! cb "ok:pending"))))))))))))
(define (handle-reach-confirm kind value code cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'confirm-contact-point (string->symbol kind) value code)
        (lambda (_) (reply! cb "ok")))))
(define (handle-reach-withdraw kind value cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'withdraw-contact-point (string->symbol kind) value)
        (lambda (_) (reply! cb "ok")))))
;; this device's browser notifications: the commune's Web Push key, and the
;; subscription the browser made with it, held by the commune under this
;; device's id (ui/app/push.ts)
(define (handle-push-key cb)
  (if (not *lobby*) (reply! cb "")
      (planner-call cb (<- *lobby* 'vapid-public-key)
        (lambda (k) (reply! cb (if (string? k) k ""))))))
(define (handle-push-register device-id subscription cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'register-push device-id subscription)
        (lambda (r) (reply! cb (if (string? r) r "ok"))))))
(define (handle-push-unregister device-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'unregister-push device-id)
        (lambda (_) (reply! cb "ok")))))
;; what this commune delivers on, and which of your points it holds
(define (handle-reach-read cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (with-vat *vat*
       (then-value (<- *session* 'my-contact-points) #f
        (lambda (v)
          (if (not (pair? v))
              (reply! cb "err:unreachable")
              (reply! cb (scm->json-canonical
                          `(("delivers" . ,(list->vector
                                            (map sym->str
                                                 (->list (alist-ref v 'delivers '())))))
                            ("points" . ,(list->vector
                                          (filter-map
                                           (lambda (p)
                                             (let ((p (->list p)))
                                               (and (= 3 (length p))
                                                    `(("kind" . ,(sym->str (car p)))
                                                      ("value" . ,(if (string? (cadr p)) (cadr p) ""))
                                                      ("state" . ,(sym->str (caddr p)))))))
                                           (->list (alist-ref v 'points '()))))))))))))))

;; ── cards: how to reach you, handed to one contact ───────────────────────
;; The content is sealed here to the receiver's own encryption key and the
;; card's identifier signed, so the commune carries a card it can tell is
;; yours and cannot read (identity/cards.scm). The key is read from the
;; receiver's own log — the latest one it anchors — and the log is verified
;; to be the one their identifier names (kel-verifies?), so the key sealed
;; to is theirs whoever served the log.
(define %schema-card "playnet-card/v1")
(define (handle-card-give aid content at cb)
  (cond
   ((not (and *session* *lobby*)) (reply! cb "err:sign in first"))
   ((zero? (ret-has-identity?)) (reply! cb "err:this device cannot seal a card yet"))
   (else
    (with-vat *vat*
     (then-value (<- *lobby* 'fetch-icp aid) #f
      (lambda (entry)
        (let ((key (anchored-key-hex entry aid)))
          (if (not key)
              (reply! cb "err:their identity carries no key to seal a card to")
              (let ((sealed (ret-seal-text-for key content)))
                (if (string=? sealed "")
                    (reply! cb "err:the card could not be sealed")
                    (let ((said (compute-said *aid* aid %schema-card
                                              `((at . ,at) (sealed . ,sealed)) '())))
                      (sign-said-as-self! said
                        (lambda (sig)
                          (if (not sig)
                              (reply! cb "err:could not sign")
                              (with-vat *vat*
                                (planner-call cb
                                  (<- *session* 'give-card aid
                                      (scm->json-canonical
                                       `(("from" . ,*aid*) ("to" . ,aid) ("at" . ,at)
                                         ("sealed" . ,sealed) ("said" . ,said) ("sig" . ,sig))))
                                  (lambda (_)
                                    (when *lobby*      ; best-effort: their row reads it now
                                      (with-vat *vat* (<-np *lobby* 'signal aid *aid* "card" "")))
                                    (fetch-contacts!)
                                    (reply! cb "ok"))))))))))))))))))
(define (handle-card-withdraw aid cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'withdraw-card aid)
        (lambda (_)
          (when *lobby* (with-vat *vat* (<-np *lobby* 'signal aid *aid* "card" "")))
          (fetch-contacts!)
          (reply! cb "ok")))))

;; forget: the contact leaves the book. What was signed stands until withdrawn.
(define (handle-contact-forget aid cb)
  (edit-book!
   (lambda (cs) (filter (lambda (c) (not (string=? (contact-aid* c) aid))) cs))
   cb))

;; every handler ends in its reply (the worker bridge hands each one a resolver)
(define (handle-contacts-refresh cb) (fetch-contacts!) (reply! cb "ok"))

;; the captain's log — the per-AID document, synced whole as a JSON string
;; (local-first in the page; the session's sync-log/list-log pair is the
;; backup, the same shape as the contact book).
;; the pin book — map lists. "sync"/"list" are the log's shape (a JSON
;; string, per AID); "ourLists" and "ourPins" read the commune's fold and
;; hand back JSON the dial's pins.ts reads directly.
(define (handle-pins op arg cb)
  (define (row->json-alist row keys)
    (map (lambda (k) (cons (symbol->string k) (or (alist-ref row k) "")))
         keys))
  ;; a fold read → a JSON array of rows, KEYS each; a failed read is empty
  (define (fold-read cb promise keys)
    (with-vat *vat*
      (on promise
          (lambda (raw)
            (reply! cb (scm->json-canonical
                        (list->vector
                         (map (lambda (r) (row->json-alist (denormalize-syrup r) keys))
                              (->list (denormalize-syrup raw)))))))
          #:catch (lambda _ (reply! cb "[]")))))
  (cond
   ((not *session*)
    (reply! cb (if (and (string? op) (string=? op "sync")) "err:sign in first" "")))
   ((and (string? op) (string=? op "sync"))
    (with-vat *vat*
      (on (<- *session* 'sync-pins arg)
          (lambda (_) (reply! cb "ok"))
          #:catch (lambda _ (reply! cb "err:pins sync failed")))))
   ((and (string? op) (string=? op "ourLists"))
    (fold-read cb (<- *session* 'our-pin-lists) '(id label emoji places by)))
   ((and (string? op) (string=? op "ourPins"))
    (fold-read cb (<- *session* 'our-pins arg) '(list subject count)))
   (else
    (with-vat *vat*
      (on (<- *session* 'list-pins)
          (lambda (raw) (reply! cb (if (string? raw) raw "")))
          #:catch (lambda _ (reply! cb "")))))))

(define (handle-log op json cb)
  (cond
   ((not *session*)
    (reply! cb (if (and (string? op) (string=? op "list")) "" "err:sign in first")))
   ((and (string? op) (string=? op "sync"))
    (with-vat *vat*
      (on (<- *session* 'sync-log json)
          (lambda (_) (reply! cb "ok"))
          #:catch (lambda _ (reply! cb "err:log sync failed")))))
   (else
    (with-vat *vat*
      (on (<- *session* 'list-log)
          (lambda (raw) (reply! cb (if (string? raw) raw "")))
          #:catch (lambda _ (reply! cb "")))))))

;; the schedule of counts (planner count-schedule): each target with its cadence
(define (handle-count-schedule regime cb)
  (scoped-call cb (<- *session* 'count-schedule *scope* (arg-str regime))
    (lambda (v) (reply! cb (scm->json-canonical v)))))

;; lay the counts that are due as directed work offers (planner plan-counts)
(define %laid-count-wire
  '(("proposal" proposal str) ("target" target str) ("counter" counter str)
    ("regime" regime str) ("hours" hours num)))
(define (handle-plan-counts regime counter at-most cb)
  (scoped-call cb (<- *session* 'plan-counts *scope* (arg-str regime)
                      (arg-str counter)
                      (and (arg-opt at-most) (arg-num at-most)))
    (lambda (v)
      (fetch-snapshot!)                     ; an offer laid for this person shows at once
      (reply! cb (scm->json-canonical
                  `(("laid" . ,(list->vector
                                (map (lambda (l) (wire-row l %laid-count-wire))
                                     (->list (alist-ref v 'laid)))))
                    ("due" . ,(alist-ref v 'due))
                    ,@(let ((why (alist-ref v 'refused #f)))
                        (if (string? why) `(("refused" . ,why)) '()))))))))

;; the code a stock is known by, for its label (planner label-stock)
(define (handle-label-stock resource cb)
  (scoped-call cb (<- *session* 'label-stock *scope* (arg-str resource))
    (lambda (v)
      (when (assoc-ref v "minted")
        (fetch-snapshot!))                  ; the stock's row now carries its code
      (reply! cb (scm->json-canonical v)))))

;; what a label names: the thing and what is in it, each an inventory row
(define (handle-read-label code cb)
  (scoped-call cb (<- *session* 'read-label *scope* (arg-str code))
    (lambda (v) (reply! cb (scm->json-canonical v)))))

;; the scope as this device holds a copy of it, as one text (planner scope-replica):
;; "" where it could not be read, so the device keeps the copy it has
(define (handle-scope-replica cb)
  (if (or (not *session*) (not *scope*))
      (reply! cb "")
      (with-vat *vat*
        (on (<- *session* 'scope-replica *scope*)
            (lambda (r)
              (match (denormalize-syrup r)
                (('ok . (? string? text)) (reply! cb text))
                (_ (reply! cb ""))))
            #:catch (lambda _ (reply! cb ""))))))

;; the counts of a stock, newest first, as a member reads them to contest one
;; (planner count-history)
(define (handle-count-history resource limit cb)
  (scoped-call cb (<- *session* 'count-history *scope* (arg-str resource)
                      (and (arg-opt limit) (arg-num limit)))
    (lambda (v) (reply! cb (scm->json-canonical v)))))

;; the contests open in the scope, as they stand to this seat (governance contests)
(define (handle-contests cb)
  (scoped-call cb (<- *session* 'contests *scope*)
    (lambda (v) (reply! cb (scm->json-canonical v)))))

;; a counter's picture, attached to the contest of their count: sent on in
;; parts, in order, and joined at the gateway, which holds it until the ballot
;; settles (session evidence-part)
(define (handle-attach-evidence ballot hash picture cb)
  (let* ((parts (string-parts (arg-str picture) %picture-send-chars))
         (n     (length parts)))
    (cond
     ((not *session*) (reply! cb "err:sign in first"))
     ((zero? n)       (reply! cb "err:no picture to attach"))
     (else
      (send-parts! cb (let loop ((ps parts) (i 0))
                        (if (null? ps) '() (cons (cons i (car ps)) (loop (cdr ps) (+ i 1)))))
                   (lambda (ip) (<- *session* 'evidence-part (arg-str ballot) (arg-str hash) (car ip) n (cdr ip)))
                   (lambda () (reply! cb "ok")))))))

;; the picture held for a contest, joined from its parts: "" when none is held
;; or this seat may not see it (session evidence-chunk)
(define (handle-contest-evidence ballot cb)
  (if (not *session*)
      (reply! cb "")
      (with-vat *vat*
        (let fetch ((i 0) (acc '()))
          (on (<- *session* 'evidence-chunk (arg-str ballot) i)
              (lambda (r)
                (match (denormalize-syrup r)
                  (('ok . al)
                   (let ((part  (alist-ref al 'part ""))
                         (total (alist-ref al 'total 1)))
                     (if (and (string? part) (< (+ i 1) (if (number? total) total 1)))
                         (fetch (+ i 1) (cons part acc))
                         (reply! cb (apply string-append (reverse (cons (if (string? part) part "") acc)))))))
                  (_ (reply! cb ""))))
              #:catch (lambda _ (reply! cb "")))))))

;; a count of a stock the books hold: the difference from the ledger lands as
;; a raise or lower on that stock (planner count-stock). A count is a number;
;; an empty figure is refused here, since "" and zero are different counts.
(define (handle-count-stock resource counted unit technique place when fulfills evidence note cb)
  (let ((n (if (string? counted) (string->number counted) counted)))
    (if (not (and (number? n) (>= n 0)))
        (reply! cb "err:a count is a number, zero or more")
        (scoped-call cb (<- *session* 'count-stock *scope* (arg-str resource) n (arg-str unit)
                            (arg-str technique) (arg-str place) (arg-str when)
                            (arg-str fulfills) (arg-str evidence) (arg-str note))
          (lambda (v)
            (fetch-snapshot!)               ; the stock and the lived layer answer right away
            (reply! cb (scm->json-canonical v)))))))

;; a log suggestion becomes a ledger fact: the planner's log-observe records
;; a SELF-scoped EconomicEvent (provider = receiver = the signed-in AID) on
;; the scope's observer. Replies "ok:<event-id>".
(define (handle-log-observe action spec qty unit note when cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((not *scope*)   (reply! cb "err:no scope yet"))
   (else
    (planner-call cb (<- *session* 'log-observe *scope*
                        action spec (or (string->number qty) 1) unit note when)
      (lambda (v)
        (fetch-snapshot!)                 ; the lived layer answers right away
        (reply! cb (string-append "ok:" (or (alist-ref v 'event) ""))))))))

;;; ── the confirmation mile: a planned block records what happened ────────
;; The two doors onto live.scm's realisation path: a committed work block
;; records its effort as the work event FULFILLING it (record-effort), and a
;; schedule material row records the produce/consume/pickup/dropoff/use that realises it
;; (record-flow — named by its press's token, so a repeat of the press returns the
;; standing event instead of recording it again). Both refetch the snapshot, so the
;; lived layer answers on the calendar right where the plan asked.

(define (handle-record-effort scope-id cid qty unit tap cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((or (not (string? cid)) (string=? cid ""))
    (reply! cb "err:this block has no commitment id"))
   (else
    ;; the hours are what the member said: a text that is not a number is
    ;; answered, never replaced by a default of one hour
    (let ((hours (string->number qty)))
      (if (not hours)
          (reply! cb "err:the hours are not a number")
          (planner-call cb (<- *session* 'record-effort
                              (if (string=? scope-id "") *scope* scope-id)
                              cid hours unit
                              (and (string? tap) (not (string=? tap "")) tap))   ; the press's own token; "" from a caller with none
            (lambda (v)
              (fetch-snapshot!)
              (reply! cb (string-append "ok:" (if (string? v) v ""))))))))))

(define (handle-record-flow scope-id action spec qty total place when proc note row-id tap cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   (else
    (planner-call cb (<- *planner* 'record-flow
                        (if (string=? scope-id "") *scope* scope-id)
                        action spec (or (string->number qty) 1)
                        (or (string->number total) (string->number qty) 1)
                        place when proc note
                        (and (string? row-id) (not (string=? row-id "")) row-id)   ; the schedule's row id; "" from a caller with none
                        (and (string? tap) (not (string=? tap "")) tap))             ; the press's own token; "" from a caller with none
      (lambda (v)
        (fetch-snapshot!)
        (reply! cb (string-append "ok:" (or (alist-ref v 'event-id) ""))))))))

;;; ── the witness ceremony: co-sign a peer's work from your OWN key ────────
;; The k-of-n trust floor, driven from the browser: OPEN asks peers to
;; witness a lived work event; INBOX lists what you may co-sign; ATTEST signs
;; the ceremony's statement SAID with the key that never leaves this vat —
;; the same 0B shape the KERI challenge path already proves server-side. At
;; quorum the scope's single-signer credential strengthens to multisig.

(define (handle-witness-open scope-id event-id cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   (else
    (planner-call cb (<- *session* 'witness-open
                        (if (string=? scope-id "") *scope* scope-id)
                        event-id)
      (lambda (v) (reply! cb (string-append "ok:" (or (alist-ref v 'said) ""))))))))

;; contesting work: the record says it happened, a member says it did not —
;; opens the ballot contest:<event-id> the scope settles at its close; answers
;; the ballot's id
(define (handle-contest-work scope-id event-id reason cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   (else
    (planner-call cb (<- *session* 'contest-work
                        (if (string=? scope-id "") *scope* scope-id)
                        (arg-str event-id) (arg-str reason))
      (lambda (v) (reply! cb (if (and (pair? v) (string? (car v))) (car v) "ok")))))))

(define (handle-witness-inbox cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   (else
    (planner-call cb (<- *session* 'witness-inbox *scope*)
      (lambda (v)
        (reply! cb (scm->json-canonical
                    (list->vector
                     (map (lambda (r)
                            ;; kind says what is being vouched for: "work"
                            ;; (a peer's lived effort — skill/hours filled)
                            ;; or "enroll" (a candidate's personhood —
                            ;; worker holds the candidate AID, sponsor the
                            ;; introducing PHC-holder).
                            `(("said"    . ,(str-field r 'said))
                              ("kind"    . ,(let ((k (alist-ref r 'kind)))
                                              (cond ((symbol? k) (symbol->string k))
                                                    ((string? k) k)
                                                    (else "work"))))
                              ("worker"  . ,(str-field r 'worker))
                              ("sponsor" . ,(str-field r 'sponsor))
                              ("skill"   . ,(str-field r 'skill))
                              ("hours"   . ,(wire-value 'num (alist-ref r 'hours) #f))
                              ("count"   . ,(alist-ref r 'count 0))
                              ("quorum"  . ,(alist-ref r 'quorum 1))
                              ;; may I sign it, and do I already vouch for them
                              ("eligible" . ,(if (alist-ref r 'eligible #t) #t #f))
                              ("vouched"  . ,(if (alist-ref r 'vouched #f) #t #f))))
                          (->list (alist-ref v 'requests '())))))))))))

(define (handle-witness-attest said cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((not (string? said)) (reply! cb "err:no statement to sign"))
   (else
    (sign-said-as-self! said (lambda (sig)
      (with-vat *vat*
        (planner-call cb (<- *session* 'witness-attest *scope* said sig)
          (lambda (v)
            (fetch-contacts!)
            (reply! cb (string-append "ok:" (or (alist-ref v 'status) "")))))))))))

;;; ── bodies: a legal body declared, stewarded, incepted k-of-n ───────────
;; docs/legal/bodies.md. Each handler is one session door (identity/
;; doors/body.scm); a structure crosses as the JSON string it is, and a reply
;; with a body in it comes back as JSON. The one act done HERE is the
;; signature: the statement is fetched, signed with this seat's own key
;; (sign-said-as-self!, the witness-attest shape), and handed back.
(define (body-json-reply cb)
  (lambda (v) (reply! cb (string-append "ok:" (scm->json-canonical v)))))
(define (handle-body-declare scope-id body cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'declare-body (if (string? scope-id) scope-id (or *scope* ""))
                          (if (string? body) body "{}"))
        (body-json-reply cb))))
(define (handle-body-add-steward id aid cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'body-add-steward id aid)
        (lambda (_) (reply! cb "ok")))))
(define (handle-body-open-ceremony id k cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'body-open-ceremony id (if (number? k) (inexact->exact (round k)) 1))
        (body-json-reply cb))))
(define (handle-body-sign id what cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'body-sign-preimage id what)
        (lambda (p)
          (let ((said (and (pair? p) (assoc-ref p "said"))))
            (if (not (string? said))
                (reply! cb "err:nothing to sign")
                (sign-said-as-self! said (lambda (sig)
                  (if (not sig)
                      (reply! cb "err:this device holds no key to sign with")
                      (with-vat *vat*
                        (planner-call cb (<- *session* 'body-sign-signed id what said sig)
                          (body-json-reply cb))))))))))))
(define (handle-body-read id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'body id)
        (lambda (v) (reply! cb (scm->json-canonical v))))))
(define (handle-bodies-read scope-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'my-bodies (if (string? scope-id) scope-id (or *scope* "")))
        (lambda (v) (reply! cb (scm->json-canonical v))))))
(define (handle-body-hold id holding cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'body-present-holding id (if (string? holding) holding "{}"))
        (lambda (v) (reply! cb (string-append "ok:" (if (string? v) v "")))))))
(define (handle-body-admit scope-id id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'body-admit (if (string? scope-id) scope-id (or *scope* "")) id)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

;;; ── the device key: cold root, hot device keys ──────────────────────────
;; docs/planning/identity/device-keys.md. The root authorizes THIS device's key with a
;; device-authorization credential it signs; the device keeps the wire
;; (localStorage) and from then on signs in and signs with its own key.
(define %device-key "pn.device.wire")
(define %schema-device-authorization "playnet-device-authorization/v1")
(define (device-wire) (let ((w (ls-get-item %device-key)))
                        (and (string? w) (positive? (string-length w)) w)))
(define (device-aid-of-pub pub-bv) (cesr-bytes->qb64 "B" pub-bv))

;; the credential, built here exactly as the gateway rebuilds it: symbol-keyed
;; claims into compute-said, so the SAID the root signs is the SAID the
;; gateway derives from the wire.
(define (handle-enroll-device label tier cb)
  (cond
   ((not *session*) (reply! cb "err:sign in first"))
   ((not *secret*)  (reply! cb "err:the passcode authorizes a device — sign in with it"))
   ((not (member tier '("hardware" "software"))) (reply! cb "err:unknown device tier"))
   (else
    (let* ((pub    (uint8array->bytevector (%device-pub)))
           (dev    (device-aid-of-pub pub))
           (now    (or (string->number (time-epoch-seconds)) 0))
           (label  (if (string? label) label ""))
           (claims `((person-aid . ,*aid*) (device-aid . ,dev) (label . ,label)
                     (tier . ,tier) (enrolled-at . ,now) (expires-at . #f)
                     (active . #t)))
           (said   (compute-said *aid* dev %schema-device-authorization claims '())))
      (sign-said-as-self! said
        (lambda (sig)
          (let ((wire (scm->json-canonical
                       `(("said" . ,said) ("schema" . ,%schema-device-authorization)
                         ("issuer" . ,*aid*) ("holder" . ,dev)
                         ("claims" . (("person-aid" . ,*aid*) ("device-aid" . ,dev)
                                      ("label" . ,label) ("tier" . ,tier)
                                      ("enrolled-at" . ,now) ("expires-at" . null)
                                      ("active" . #t)))
                         ("sig" . ,sig)))))
            (with-vat *vat*
              (on (<- *session* 'enroll-device wire)
                  (lambda (r)
                    (match (denormalize-syrup r)
                      ('ok (ls-set-item %device-key wire)
                           (seal-mesh-seed! (lambda () (reply! cb "ok"))))
                      (('error (? string? m) . _) (reply! cb (string-append "err:" m)))
                      (_ (reply! cb "err:enroll refused"))))
                  #:catch (lambda _ (reply! cb "err:enroll unreachable")))))))))))

;; the persona's mesh identity (anchored in the icp, derived from the bran)
;; rides along on this device, sealed under the device's own seal key, so a
;; device session announces as the persona and not as an anonymous node.
;; An OUTSIDE interface — a bot, a script, another app — enrolled as a device
;; of this person: it generated its own key and showed its B-prefixed AID;
;; the root here signs the authorization, with a doors allowlist so it holds
;; only the doors it needs (comma-separated; "" = every device door). Software
;; tier: the key lives wherever that interface keeps it. Revocation is the
;; same devices list as any other device.
(define (handle-enroll-external-device device-aid label doors cb)
  (cond
   ((not *session*) (reply! cb "err:sign in first"))
   ((not *secret*)  (reply! cb "err:the passcode authorizes a device — sign in with it"))
   ((not (and (string? device-aid) (= 44 (string-length device-aid))
              (char=? (string-ref device-aid 0) #\B)))
    (reply! cb "err:a device AID is 44 characters and starts with B"))
   (else
    (let* ((now    (or (string->number (time-epoch-seconds)) 0))
           (label  (if (string? label) label ""))
           ;; DOORS: door names separated by commas, "" for every device door
           (doors  (if (string? doors)
                       (filter (lambda (d) (not (string-null? d)))
                               (map string-trim-both (string-split doors #\,)))
                       '()))
           (base   `((person-aid . ,*aid*) (device-aid . ,device-aid) (label . ,label)
                     (tier . "software") (enrolled-at . ,now) (expires-at . #f)
                     (active . #t)))
           (claims (if (null? doors) base (append base `((doors . ,doors)))))
           (said   (compute-said *aid* device-aid %schema-device-authorization claims '())))
      (sign-said-as-self! said
        (lambda (sig)
          (let ((wire (scm->json-canonical
                       `(("said" . ,said) ("schema" . ,%schema-device-authorization)
                         ("issuer" . ,*aid*) ("holder" . ,device-aid)
                         ("claims" . ,(append
                                       `(("person-aid" . ,*aid*) ("device-aid" . ,device-aid)
                                         ("label" . ,label) ("tier" . "software")
                                         ("enrolled-at" . ,now) ("expires-at" . null)
                                         ("active" . #t))
                                       (if (null? doors) '()
                                           `(("doors" . ,(list->vector doors))))))
                         ("sig" . ,sig)))))
            (with-vat *vat*
              (on (<- *session* 'enroll-device wire)
                  (lambda (r)
                    (match (denormalize-syrup r)
                      ('ok (reply! cb "ok"))
                      (('error (? string? m) . _) (reply! cb (string-append "err:" m)))
                      (_ (reply! cb "err:enroll refused"))))
                  #:catch (lambda _ (reply! cb "err:enroll unreachable")))))))))))

(define %device-mesh-key "pn.device.mesh")
(define (seal-mesh-seed! k)
  (if (not *mesh-seed*)
      (k)
      (begin
        (%device-seal (bytevector->uint8array *mesh-seed*)
                      (procedure->external
                       (lambda (blob)
                         (when (and (string? blob) (positive? (string-length blob)))
                           (ls-set-item %device-mesh-key blob))
                         (k))))
        #t)))
(define (open-mesh-seed! k)
  (let ((blob (ls-get-item %device-mesh-key)))
    (if (not (and (string? blob) (positive? (string-length blob))))
        (k)
        (begin
          (%device-open blob
                        (procedure->external
                         (lambda (bytes)
                           (let ((seed (uint8array->bytevector bytes)))
                             (when (= 64 (bytevector-length seed))
                               (set! *mesh-seed* seed)
                               (when (not (zero? (ret-has-identity?)))
                                 (ret-load-from-seed (bytevector->uint8array seed)))))
                           (k))))
          #t))))

;; sign in with the device key: the wire in hand names the AID; JS loads the
;; key (a touch, on the hardware tier); the seat is taken as a device session.
;; A root session already open stays — the passcode outranks the device.
(define (handle-unlock-device cb)
  (let ((wire (device-wire)))
    (cond
     (*secret* (reply! cb (string-append "ok:" (or *aid* ""))))
     ((not wire) (reply! cb "err:no device key here"))
     (else
      (let* ((w (with-exception-handler (lambda (_) #f)
                  (lambda () (json-read-ordered wire)) #:unwind? #t))
             (aid (and (pair? w) (assoc-ref w "issuer"))))
        (if (not (string? aid))
            (reply! cb "err:device record unreadable")
            (%device-load
             (procedure->external
              (lambda (status)
                (cond
                 ((and (string? status) (>= (string-length status) 3)
                       (string=? (substring status 0 3) "ok:"))
                  (set-aid! aid)
                  (set! *tier* 'device)
                  (set! *secret* #f)
                  (let ((k0 (or (and *kel* (equal? (kel-aid *kel*) aid) (kel-k0 *kel*)) "")))
                    (open-mesh-seed!
                     (lambda () (take-seat! (lambda (s) (reply! cb (with-k0 s k0))))))))
                 (else (reply! cb (if (string? status) status "err:device key unavailable")))))))))))))

(define (handle-tier cb)
  (reply! cb (case *tier* ((root) "root") ((device) "device") (else ""))))

(define (handle-devices cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (with-vat *vat*
        (on (<- *session* 'my-devices)
            (lambda (r)
              (let ((ds (->list (denormalize-syrup r))))
                (reply! cb (scm->json-canonical
                            (list->vector
                             (map (lambda (d)
                                    (map (lambda (kv)
                                           (cons (car kv)
                                                 (if (eq? (cdr kv) #f) 'null (cdr kv))))
                                         d))
                                  ds))))))
            #:catch (lambda _ (reply! cb "err:devices unreachable"))))))

(define (handle-revoke-device said cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (with-vat *vat*
        (on (<- *session* 'revoke-device said)
            (lambda (r)
              (match (denormalize-syrup r)
                ('ok (reply! cb "ok"))
                (('error (? string? m) . _) (reply! cb (string-append "err:" m)))
                (_ (reply! cb "err:revoke refused"))))
            #:catch (lambda _ (reply! cb "err:revoke unreachable"))))))

;;; ── KERI: unlock, signup, authenticate ──────────────────────────────────
;; the bran never leaves this vat; the page only ever sees status strings.

;; Prove the AID to the commune and take the session cap. A root session
;; signs the nonce with the KEL key (keri-authenticate); a device session
;; signs it with the device key and presents the root's authorization
;; (keri-authenticate-device). What follows the cap is the same either way.
(define (authenticate! report)            ; report: (lambda (string) ...)
  (with-vat *vat*
    (on (<- *lobby* 'keri-challenge *aid*)
        (lambda (nonce)
          (if (not (string? nonce))
              (report "err:no nonce from gateway")
              (sign-as-self! (string->utf8 nonce)
                (lambda (raw)
                  (if (not raw)
                      (report "err:nothing here can sign")
                      ;; the device key answers from JS, outside any vat turn —
                      ;; the message is sent from inside with-vat, where a
                      ;; syscaller exists
                      (let ((sig (cesr-bytes->qb64 "0B" raw)))
                        (with-vat *vat*
                          (on (if (eq? *tier* 'device)
                                  (<- *lobby* 'keri-authenticate-device *aid*
                                      (or (device-wire) "") sig nonce)
                                  (<- *lobby* 'keri-authenticate *aid* sig nonce))
                              (lambda (result)
                                (cond
                                 ((and (pair? result) (eq? 'ok (car result)))
                                  (set! *session* (cadr result))
                                  (set! *scope-ids* '())   ; a fresh seat re-reads its roster
                                  (fetch-seat!)
                                  ;; cache the book FIRST, then announce — so the
                                  ;; broadcast our announce triggers re-maps in memory
                                  ;; instead of cold-fetching the book again.
                                  (fetch-contacts*! announce-presence!)
                                  (report (string-append "ok:" *aid*)))
                                 ((and (pair? result) (eq? 'error (car result))
                                       (pair? (cdr result)) (string? (cadr result)))
                                  (report (string-append "err:" (cadr result))))
                                 (else (report "err:authentication refused"))))
                              #:catch (lambda _ (report "err:authenticate failed")))))))))
        #:catch (lambda _ (report "err:challenge failed"))))))

(define (reticulum-extra-locs)
  (let ((dest (ret-dest-hash-hex))
        (mail (ret-lxmf-dest-hash-hex)))
    (append
     (if (and (string? dest) (positive? (string-length dest)))
         (list (cons "reticulum" (string-append "reticulum://" dest)))
         '())
     (if (and (string? mail) (positive? (string-length mail)))
         (list (cons "lxmf" (string-append "lxmf://" mail)))
         '()))))

;; persona-bound mesh identity: derive from bran + inception key (k0
;; labels the seed — stable across rotations), load into rns-wasm
(define *mesh-seed* #f)   ; the persona's mesh seed, while a root session holds it
(define (bind-reticulum! bran k0)
  (when (and (string? bran) (string? k0) (positive? (string-length k0)))
    (set! *mesh-seed* (bran->reticulum-seed bran k0))
    (when (not (zero? (ret-has-identity?)))
      (ret-load-from-seed (bytevector->uint8array *mesh-seed*)))))

;; "ok:<aid>|<k0>" is the reply every door ends on: the page stores the
;; hint from it. Appending k0 means a "different identity" sign-in (empty
;; k0 passed) stores a complete, reusable hint — matching what signup
;; stores. The same suffix rides on "local:" and "unregistered:".
(define (with-k0 s k0)
  (if (and (string? s) (>= (string-length s) 3)
           (member (substring s 0 3) '("ok:" "loc" "unr")))
      (string-append s "|" k0)
      s))

;; Take a seat at the commune. Two acts, in order:
;;   1. WITNESS — the log in hand goes to the gateway on its own terms
;;      (witness-kel): a new AID lands whole, a known one is levelled up
;;      with the rotations it lacks. No seat is implied; every gateway is a
;;      witness-of-record for every AID it has seen.
;;   2. LEVEL DOWN — if the gateway holds rotations this device lacks
;;      (made from another device), adopt them once they verify as this
;;      log's continuation; the passcode in hand must still open the log.
;;   3. SEAT — has-seat? → challenge-auth under the current key; else the
;;      commune has never seated this AID → "unregistered:", and the chip
;;      offers to join (handle-join: a seat, nothing more).
;; Three outcomes reach REPORT:
;;   ok:<aid>            seated
;;   unregistered:<aid>  witnessed here, no seat yet
;;   local:<aid>         no commune reachable; unlocked, reading the cached day
(define (take-seat! report)
  (cond
   ((not *lobby*) (report (string-append "local:" *aid*)))
   ((not (and *kel* (equal? (kel-aid *kel*) *aid*)))
    ;; no log in hand for this AID: a device seats on its authorization,
    ;; a root session on its passcode
    (if (eq? *tier* 'device) (seat-if-held! report) (authenticate! report)))
   (else
    (witness-log!
     (lambda ()
       (if (eq? *tier* 'device)
           ;; a device key holds no passcode to check the log against; it
           ;; witnesses the log it carries and seats on its authorization
           (seat-if-held! report)
           (with-vat *vat*
             (on (<- *lobby* 'fetch-icp *aid*)
                 (lambda (entry-raw)
                   (let ((entry (denormalize-syrup entry-raw)))
                     (if (pair? entry)
                         (level-down-then-seat! entry report)
                         (authenticate! report))))
                 #:catch (lambda _ (authenticate! report))))))
     report))))

;; The log in hand goes to the gateway on its own terms (witness-kel):
;; every seat, from every tier, leaves the gateway holding the log it
;; is a witness-of-record for. A founder seated before the gateway kept
;; logs, signing in from a device key ever since, is how a witnessed
;; commune came to hold no log for its own founder. THEN runs on a
;; witnessed log; a refusal reaches REPORT.
(define (witness-log! then report)
  (with-vat *vat*
    (on (<- *lobby* 'witness-kel *aid*
            (kel-icp *kel*) (assoc-ref *kel* "sigs")
            (list->vector (kel-rotations *kel*)))
        (lambda (w)
          (if (and (pair? w) (eq? 'error (car w)) (pair? (cdr w)) (string? (cadr w)))
              (report (string-append "err:the commune refused your log: " (cadr w)))
              (then)))
        #:catch (lambda _ (report "err:could not reach the commune's witness")))))

;; Rotations the commune holds beyond the log here were made from another
;; device. They are adopted when they verify as this log's continuation —
;; only the keys the log committed to could have signed them. The passcode in
;; hand must then still open the log: one that no longer does was replaced
;; (a passcode change elsewhere), and this session ends where it stands.
(define (level-down-then-seat! entry report)
  (let* ((theirs   (let ((r (alist-ref entry 'rotations))) (if (pair? r) r '())))
         (d-mine   (kel-depth *kel*))
         (d-theirs (length theirs)))
    (cond
     ((> d-theirs d-mine)
      (let ((longer (make-kel (kel-icp *kel*) (assoc-ref *kel* "sigs") theirs)))
        (cond
         ((not (rotations-verify? *aid* (kel-last-event *kel*) (drop theirs d-mine)))
          (report "err:this commune holds a log for your identity that does not verify"))
         (else
          (kel-save! longer)
          (cond
           ((and *bran* (passcode-opens? longer *bran*))
            (set! *secret* (kel-current-keypair longer *bran*))
            (seat-if-held! report))
           (else
            (set! *secret* #f) (set! *bran* #f) (set! *tier* #f)
            (report "err:your passcode was changed on another device — sign in with the new one")))))))
     (else (seat-if-held! report)))))

(define (seat-if-held! report)
  (with-vat *vat*
    (on (<- *lobby* 'has-seat *aid*)
        (lambda (seated?)
          (if seated?
              (authenticate! report)
              (report (string-append "unregistered:" *aid*))))
        #:catch (lambda _ (authenticate! report)))))

;; unlock with the passcode and nothing else: the identity is the one the
;; passcode itself names. The log this device holds, when the passcode opens
;; it; else the log the commune holds under the passcode's first key
;; (find-icp), kept here once it verifies and the passcode opens it. From
;; there it is the unlock below, by the AID the log names.
(define (unlock-by-passcode! bran cb)
  (let ((first-key (keypair-key (passcode-keypair bran 0))))
    (cond
     ((and *kel* (passcode-opens? *kel* bran))
      (handle-unlock bran (kel-aid *kel*) first-key cb))
     ((not *lobby*)
      (reply! cb "err:no log of this identity here, and no commune to ask — open your recovery file"))
     (else
      (with-vat *vat*
        (on (<- *lobby* 'find-icp first-key)
            (lambda (entry-raw)
              (let* ((entry (denormalize-syrup entry-raw))
                     (found (and (pair? entry) (entry->kel entry))))
                (cond
                 ((not found)
                  (reply! cb "err:this commune holds no identity for that passcode — check it, or paste the identifier, or open your recovery file"))
                 ((not (kel-verifies? found))
                  (reply! cb "err:the log this commune holds for that passcode does not verify"))
                 ((not (passcode-opens? found bran))
                  (reply! cb "err:that passcode was replaced by a newer one"))
                 (else
                  (kel-save! found)
                  (handle-unlock bran (kel-aid found) first-key cb)))))
            #:catch (lambda _ (reply! cb "err:could not ask the commune for your log"))))))))

;; unlock: the passcode against the log this device holds. No gateway in
;; the loop — the passcode derives its chain of keys, the log says how far
;; along it the identity is, and a wrong passcode fails against the key in
;; force. When the log here is not opened by the passcode and a commune is
;; in reach, its log is asked for: a device with no log yet keeps it from
;; then on, and a device whose log is behind (the passcode was changed
;; elsewhere) catches up to the one the new passcode opens. K0 is what the
;; page remembers of the first key; the log decides. An empty AID is the
;; passcode alone (unlock-by-passcode! above).
(define (handle-unlock bran aid k0 cb)
  (cond
   ((< (string-length bran) 21) (reply! cb "err:passcode is 21+ characters"))
   ((or (not (string? aid)) (string=? aid "")) (unlock-by-passcode! bran cb))
   (else
    (let* ((first-key (keypair-key (passcode-keypair bran 0)))
           (reply-ok (lambda (s) (reply! cb (with-k0 s first-key))))
           ;; the log in hand, when it is THIS identity's
           (kel (and *kel* (equal? (kel-aid *kel*) aid) *kel*))
           (unlock-with!
            (lambda (kel)
              (set-aid! aid)
              (set! *bran* bran)
              (set! *tier* 'root)
              (set! *secret* (or (and kel (kel-current-keypair kel bran))
                                 (passcode-keypair bran 0)))
              (bind-reticulum! bran first-key)
              (take-seat! reply-ok))))
      (cond
       ((and kel (passcode-opens? kel bran)) (unlock-with! kel))
       ((not *lobby*)
        (reply! cb (if kel
                       "err:wrong passcode for this identity"
                       "err:no log of this identity here, and no commune to ask")))
       (else
        (with-vat *vat*
          (on (<- *lobby* 'fetch-icp aid)
              (lambda (entry-raw)
                (let* ((entry (denormalize-syrup entry-raw))
                       (fetched (and (pair? entry) (entry->kel entry))))
                  (cond
                   ((and fetched (equal? aid (kel-aid fetched))
                         (kel-verifies? fetched) (passcode-opens? fetched bran))
                    (kel-save! fetched)
                    (unlock-with! fetched))
                   ((or kel fetched) (reply! cb "err:wrong passcode for this identity"))
                   ;; no log here or there: the commune's challenge decides
                   (else (unlock-with! #f)))))
              #:catch (lambda _
                        (if kel
                            (reply! cb "err:wrong passcode for this identity")
                            (unlock-with! #f)))))))))))

;;; ── changing the passcode ───────────────────────────────────────────────
;; The passcode is the root of the identity's keys, so changing it is two
;; rotations made as one act:
;;   1. the key the log is committed to next — the current passcode's — is
;;      revealed, committing in turn to the NEW passcode's first key;
;;   2. the new passcode's first key is revealed, committing to its second,
;;      and anchoring the mesh identity the new passcode derives.
;; After the second the key in force is the new passcode's and so is the
;; key committed to next: the old passcode signs nothing and can rotate
;; nothing. The identifier is the inception's digest and stays what it was.
;; Both rotations go to the commune together (witness-kel verifies the run
;; and keeps it whole), and the log here is replaced only once it has them.
;;
;; passcodeCheck answers whether a passcode opens the identity in hand —
;; asked before a new passcode is shown, so nothing is shown to a guess.
(define (handle-passcode-check bran cb)
  (reply! cb (cond ((not *kel*) "err:no identity here")
                   ((passcode-opens? *kel* bran) "ok")
                   (else "err:wrong passcode for this identity"))))

;; forgetMe: the commune erases every record of its own keyed by this
;; identity, the link between identity and person last (identity/forget.scm,
;; the session's forget-me door); the reply is the receipt — what went, by
;; kind and count, and what stays — as JSON. With RETIRE "retire" a terminal
;; rotation goes first: the key the log committed to is revealed and NO next
;; key is named, so the log is closed — it can never rotate again, no new
;; key can take the identity over, and there is no recovery from it (KERI:
;; an identifier that cannot be rotated is non-transferable, and
;; abandoned). The key it revealed is still the passcode's, and still
;; signs: retiring closes the future of the identity, it does not disown
;; what the passcode holds. The commune verifies the event as it verifies
;; any rotation and refuses every rotation after it; the log in hand is
;; saved with it before the forget, so a forget that stops partway leaves
;; this device's log level with the commune's. The page then forgets what
;; this device held.
(define (handle-forget-me bran retire cb)
  (cond
   ((not *lobby*)   (reply! cb "err:forgetting needs the commune in reach"))
   ((not *session*) (reply! cb "err:sign in with your passcode first"))
   ((not *kel*)     (reply! cb "err:no identity here"))
   ((not (passcode-opens? *kel* bran)) (reply! cb "err:wrong passcode for this identity"))
   ((equal? retire "retire") (retire-identity! bran (lambda () (forget-me! cb)) cb))
   (else (forget-me! cb))))

(define (forget-me! cb)
  (with-vat *vat*
    (on (<- *session* 'forget-me)
        (lambda (r-raw)
          (let ((r (denormalize-syrup r-raw)))
            (if (and (pair? r) (eq? 'error (car r)))
                (reply! cb (string-append "err:" (if (and (pair? (cdr r)) (string? (cadr r)))
                                                     (cadr r) "the commune refused")))
                (reply! cb (receipt->json r)))))
        #:catch (lambda _ (reply! cb "err:could not reach the commune")))))

(define (retire-identity! bran k cb)
  (let* ((kel *kel*) (aid (kel-aid kel)))
    (call-with-values
     (lambda () (retirement-rotation kel bran))
     (lambda (rots closed)
       (with-vat *vat*
         (on (<- *lobby* 'witness-kel aid (kel-icp kel) (assoc-ref kel "sigs")
                 (list->vector rots))
             (lambda (w)
               (if (and (pair? w) (eq? 'error (car w)))
                   (reply! cb (string-append "err:the commune refused the retirement: "
                                             (if (and (pair? (cdr w)) (string? (cadr w)))
                                                 (cadr w) "no reason given")))
                   (begin (kel-save! closed) (k))))
             #:catch (lambda _ (reply! cb "err:could not reach the commune's witness"))))))))

(define (handle-change-passcode current new cb)
  (cond
   ((not *lobby*) (reply! cb "err:changing your passcode needs the commune in reach"))
   ((not *kel*)   (reply! cb "err:no identity here"))
   ((< (string-length new) 21) (reply! cb "err:passcode is 21+ characters"))
   ((string=? new current) (reply! cb "err:the new passcode is the current one"))
   ((not (passcode-opens? *kel* current)) (reply! cb "err:wrong passcode for this identity"))
   (else
    (let ((aid (kel-aid *kel*)))
      (with-vat *vat*
        (on (<- *lobby* 'fetch-icp aid)
            (lambda (entry-raw)
              (let* ((entry (denormalize-syrup entry-raw))
                     (held  (and (pair? entry)
                                 (let ((r (alist-ref entry 'rotations))) (if (pair? r) (length r) 0)))))
                (cond
                 ((not held)
                  (reply! cb "err:this commune holds no log for your identity — join it first"))
                 ;; a rotation is made on the whole log: one that moved on
                 ;; elsewhere is caught up by signing in, not rotated past
                 ((> held (kel-depth *kel*))
                  (reply! cb "err:your log moved on from another device — sign in again, then change the passcode"))
                 (else (change-passcode! aid current new cb)))))
            #:catch (lambda _ (reply! cb "err:could not reach the commune"))))))))

(define (change-passcode! aid current new cb)
  (let* ((kel      *kel*)
         (depth    (kel-depth kel))
         (kp-out   (passcode-keypair current (+ 1 (- depth (passcode-base kel current)))))
         (kp-in    (passcode-keypair new 0))
         (kp-next  (passcode-keypair new 1))
         (first-in (keypair-key kp-in))
         (prior    (kel-last-event kel))
         ;; a refusal leaves the mesh identity the current passcode's
         (undo     (lambda (msg)
                     (bind-reticulum! current (keypair-key (passcode-keypair current 0)))
                     (reply! cb msg))))
    (call-with-values
     (lambda ()
       (build-rot aid (assoc-ref prior "d")
                  #:keys  (list (keypair-key kp-out))
                  #:nkeys (list (next-key-digest (ed25519-keypair-public kp-in)))
                  #:sn    (+ depth 1)))
     (lambda (json1 _said1 rot1)
       ;; the new passcode's mesh identity, bound now so its key can be anchored
       (bind-reticulum! new first-in)
       (let* ((ret-pub (ret-public-key-hex))
              (anchors (if (and (string? ret-pub) (positive? (string-length ret-pub)))
                           (list (list (cons "playnet-reticulum-pub" ret-pub)))
                           '())))
         (call-with-values
          (lambda ()
            (build-rot aid (assoc-ref rot1 "d")
                       #:keys  (list first-in)
                       #:nkeys (list (next-key-digest (ed25519-keypair-public kp-next)))
                       #:sn    (+ depth 2)
                       #:anchors anchors))
          (lambda (json2 _said2 rot2)
            (let* ((rots (append (kel-rotations kel)
                                 (list (cons rot1 (vector (sign-event json1 kp-out)))
                                       (cons rot2 (vector (sign-event json2 kp-in))))))
                   (next (make-kel (kel-icp kel) (assoc-ref kel "sigs") rots)))
              (with-vat *vat*
                (on (<- *lobby* 'witness-kel aid (kel-icp kel) (assoc-ref kel "sigs")
                        (list->vector rots))
                    (lambda (w)
                      (cond
                       ((and (pair? w) (eq? 'error (car w)))
                        (undo (string-append "err:the commune refused the change: "
                                             (if (and (pair? (cdr w)) (string? (cadr w))) (cadr w) "no reason given"))))
                       (else
                        (kel-save! next)
                        (set-aid! aid)
                        (set! *bran* new)
                        (set! *tier* 'root)
                        (set! *secret* kp-in)
                        ;; where this identity is reached, endorsed under the new key
                        (with-vat *vat*
                          (on (<- *lobby* 'register-oobi-replies aid
                                  (list->vector
                                   (oobi-endpoint-replies-for-rot
                                    rot2 (string-append (get-location-origin) "/")
                                    kp-in (time-iso-now) #:extra-locs (reticulum-extra-locs))))
                              (lambda (_) #f) #:catch (lambda (_) #f)))
                        ;; the seat again, under the key now in force
                        (authenticate! (lambda (s) (reply! cb (with-k0 s first-in)))))))
                    #:catch (lambda _ (undo "err:could not reach the commune's witness"))))))))))))

;; join: a seat in this commune's universal commune for the identity in
;; hand — the log was witnessed on the way in (take-seat!), so this is the
;; membership row and nothing else. Then the endpoint replies are endorsed
;; under the current key and the challenge runs as usual.
(define (handle-join name email cb)
  (cond
   ((not *lobby*)  (reply! cb "err:not connected"))
   ((not *kel*)    (reply! cb "err:no identity to bring"))
   ((not *secret*) (reply! cb "err:unlock first"))
   (else
    (let* ((aid   (kel-aid *kel*))
           (rots  (kel-rotations *kel*))
           (replies
            (list->vector
             (if (null? rots)
                 (oobi-endpoint-replies-for-icp
                  (kel-icp *kel*) (string-append (get-location-origin) "/")
                  *secret* (time-iso-now) #:extra-locs (reticulum-extra-locs))
                 (oobi-endpoint-replies-for-rot
                  (car (last rots)) (string-append (get-location-origin) "/")
                  *secret* (time-iso-now) #:extra-locs (reticulum-extra-locs))))))
      (with-vat *vat*
        (on (<- *lobby* 'join (if (string? name) name "") email aid)
            (lambda (result)
              (cond
               ((eq? 'ok result)
                (set-aid! aid)
                (with-vat *vat*
                  (on (<- *lobby* 'register-oobi-replies aid replies)
                      (lambda (_) #f) #:catch (lambda (_) #f)))
                (authenticate! (lambda (s) (reply! cb s))))
               ;; another device with this bran took the seat first
               ;; (same icp, same AID): it is there already — take it
               ((and (pair? result) (eq? 'error (car result))
                     (pair? (cdr result)) (string? (cadr result))
                     (let ((m (cadr result)) (w "AID already registered"))
                       (and (>= (string-length m) (string-length w))
                            (string=? (substring m 0 (string-length w)) w))))
                (set-aid! aid)
                (authenticate! (lambda (s) (reply! cb s))))
               ((and (pair? result) (eq? 'error (car result))
                     (pair? (cdr result)) (string? (cadr result)))
                (reply! cb (string-append "err:" (cadr result))))
               (else (reply! cb "err:join refused"))))
            #:catch (lambda _ (reply! cb "err:join failed"))))))))

;;; ── recovery friends ────────────────────────────────────────────────────
;; The passcode is the only key and cannot be reset — so the answer to losing
;; it is not a reset, it is other people. Split it k-of-n and hand a piece to
;; each of a few people you trust: any k of them together can hand it back,
;; and fewer than k learn nothing at all (that is Shamir's guarantee, not a
;; policy we enforce).
;;
;; THE PIECES NEVER TOUCH A GATEWAY. They are produced here, shown here, and
;; carried to each person however you already talk to them. A commune that
;; held every piece could reconstruct your passcode, which would undo the one
;; property this whole design exists for — so it is never offered them. The
;; cost is that delivery is yours to do; the gain is that the trust is exactly
;; where you put it, in the people you chose.
;;
;; A piece is one line, self-describing:  pnr1.<aid>.<index>.<k>.<data>
;; It carries the AID because recovery has to know whose identity it is
;; opening — and the person holding it was chosen by you, so it tells them
;; nothing about you they did not already know.
;; split: N pieces needing K of them. Replies a JSON array of lines, in the
;; order the caller listed its people, so the page can put each beside a name.
(define (handle-guardian-split k-str n-str cb)
  (let ((k (string->number k-str))
        (n (string->number n-str)))
    (cond
     ((not *bran*) (reply! cb "err:unlock first"))
     ((not (and (integer? k) (integer? n) (>= k 2) (>= n k) (<= n 12)))
      (reply! cb "err:pick 2 or more people, and a threshold no larger"))
     (else
      (let* ((aid (or *aid* (and *kel* (kel-aid *kel*))))
             ;; the splitting's TAG: the same few random characters on every
             ;; piece cut in this act, so pieces from two splittings — which
             ;; interpolate into a confident wrong passcode — refuse to mix
             ;; at recovery instead
             (tag (base64-encode (keri-crypto-random-bytes 3)
                                 #:alphabet base64-url-alphabet #:padding? #f))
             (shares (shamir-split (string->utf8 *bran*) k n)))
        (reply! cb
          (scm->json-canonical
           (list->vector
            (map (lambda (sh)
                   (share->line aid tag (car sh) (cadr sh) (caddr sh)))
                 shares)))))))))

;; recover: k pieces back in, in any order. Returns "ok:<aid>|<bran>" so the
;; page can unlock with it exactly as if the passcode had been typed — the
;; same door, reached by a different road.
(define (handle-guardian-recover lines-json cb)
  (let* ((parsed (with-exception-handler
                  (lambda (_) #f)
                  (lambda ()
                    (let ((v (json-read-ordered lines-json)))
                      (and (vector? v)
                           (map line->share (vector->list v)))))
                  #:unwind? #t)))
    (cond
     ((or (not parsed) (memq #f parsed) (null? parsed))
      (reply! cb "err:one of those pieces is not a recovery piece"))
     (else
      (let ((aids (delete-duplicates (map car parsed)))
            (tags (delete-duplicates (map cadr parsed))))
        (cond
         ((> (length aids) 1)
          (reply! cb "err:those pieces belong to different identities"))
         ;; pieces from two splittings interpolate into a full-length WRONG
         ;; passcode with no complaint — so mixing is refused with the fix
         ((> (length tags) 1)
          (reply! cb "err:those pieces come from different splittings — use pieces that were made together"))
         ((< (length parsed) (cadddr (car parsed)))
          (reply! cb (string-append
                      "err:that is " (number->string (length parsed))
                      " of the " (number->string (cadddr (car parsed)))
                      " pieces needed")))
         (else
          (with-exception-handler
           (lambda (_) (reply! cb "err:those pieces do not fit together"))
           (lambda ()
             ;; a share is a PROPER list (index threshold data) — shamir-combine
             ;; reads it with car/cadr/caddr; parsed is (aid tag idx k data)
             (let* ((shares (map (lambda (p) (list (caddr p) (cadddr p) (list-ref p 4)))
                                 parsed))
                    (bran (utf8->string (shamir-combine shares))))
               (reply! cb (string-append "ok:" (car aids) "|" bran))))
           #:unwind? #t))))))))

;; the log, out and in: the recovery file carries it beside the passcode
(define (handle-kel-export cb)
  (reply! cb (if *kel* (scm->json-canonical *kel*) "")))

;; import: a KEL from a recovery file becomes this device's log. Replies
;; "ok:<aid>|<k0>" so the page can store the hint before unlocking.
(define (handle-kel-import json cb)
  (let ((kel (with-exception-handler
              (lambda (_) #f)
              (lambda () (let ((k (json-read-ordered json)))
                           (and (kel-well-formed? k) k)))
              #:unwind? #t)))
    (cond
     ((not kel) (reply! cb "err:not a playnet identity log"))
     (else
      (kel-save! kel)
      (reply! cb (string-append "ok:" (kel-aid kel) "|" (kel-k0 kel)))))))

;; signup: derive keys, anchor the reticulum pubkey in the ICP, sign — and
;; the identity exists, here, in the log this device now keeps. Nothing in
;; the icp comes from a server. With a commune reachable it is registered
;; at once (signup-with-icp), the OOBI endpoint replies endorsed (web + mesh
;; locations through one BADA-verified channel), and the seat taken. With
;; none, the identity is made all the same and replies "local:AID|K0": the
;; commune, when one appears, is one this identity has not met yet, and
;; take-seat! → unregistered → handle-join is the door it walks through.
;; Reply on success: "ok:AID|K0" or "local:AID|K0" — the page stores the hint.
(define (handle-signup name email bran cb)
  (cond
   ((< (string-length bran) 21) (reply! cb "err:passcode is 21+ characters"))
   (else
    (let* ((kp  (bran->signing-keypair bran))
           (nkp (bran->next-keypair bran))
           (kq  (public-key->aid-prefix (ed25519-keypair-public kp)))
           (nq  (next-key-digest (ed25519-keypair-public nkp))))
      ;; bind mesh identity FIRST so its pubkey can anchor in the icp
      (bind-reticulum! bran kq)
      (let* ((ret-pub (ret-public-key-hex))
             (anchors (if (and (string? ret-pub)
                               (positive? (string-length ret-pub)))
                          (list (list (cons "playnet-reticulum-pub" ret-pub)))
                          '()))
             (extra-locs (reticulum-extra-locs)))
        (call-with-values
         (lambda () (build-icp #:keys (list kq) #:nkeys (list nq)
                               #:anchors anchors))
         (lambda (icp-json _said icp-alist)
           (let* ((sigs (vector (sign-event icp-json kp)))
                  (aid  (cdr (assoc "i" icp-alist)))
                  ;; no name supplied → mint a handle from the AID
                  (uname (if (and (string? name) (not (string=? name "")))
                             name (aid->handle aid)))
                  (k0   (event-first-key icp-alist))
                  (replies
                   (list->vector
                    (oobi-endpoint-replies-for-icp
                     icp-alist
                     (string-append (get-location-origin) "/")
                     kp (time-iso-now)
                     #:extra-locs extra-locs))))
             (set! *bran* bran)
             (set! *tier* 'root)
             (if (not *lobby*)
               ;; no commune: the identity is made, kept, and unlocked
               (begin
                 (kel-save! (make-kel icp-alist sigs '()))
                 (set! *secret* kp)
                 (set-aid! aid)
                 (reply! cb (string-append "local:" aid "|" k0)))
             (with-vat *vat*
               (on (<- *lobby* 'signup-with-icp uname email aid icp-alist sigs)
                   (lambda (result)
                     (cond
                      ((eq? 'ok result)
                       (set! *secret* kp)
                       (set-aid! aid)
                       ;; the controller keeps what it wrote
                       (kel-save! (make-kel icp-alist sigs '()))
                       ;; ship the endorsed endpoint replies (fire+forget)
                       (with-vat *vat*
                         (on (<- *lobby* 'register-oobi-replies aid replies)
                             (lambda (_) #f)
                             #:catch (lambda (_) #f)))
                       ;; the page stores the hint, then we authenticate
                       (reply! cb (string-append "ok:" aid "|" k0))
                       (authenticate! seam-status!))
                      ;; the agent's refusals carry their reason —
                      ;; (error "username already registered: …") etc.
                      ((and (pair? result) (eq? 'error (car result))
                            (pair? (cdr result)) (string? (cadr result)))
                       (reply! cb (string-append "err:" (cadr result))))
                      (else (reply! cb "err:signup refused"))))
                   #:catch (lambda _ (reply! cb "err:signup failed")))))))))))))

;;; ── profile (settings): the AID's own display-name + email ──────────────
(define (handle-profile-get cb)
  (if (not *session*)
      (reply! cb "err:sign in first")
      (with-vat *vat*
        (on (<- *session* 'profile)
            (lambda (p)
              (let ((p (denormalize-syrup p)))
                (reply! cb (scm->json-canonical
                            `(("name"  . ,(or (and (pair? p) (alist-ref p 'display-name)) ""))
                              ("email" . ,(or (and (pair? p) (alist-ref p 'email)) "")))))))
            #:catch (lambda _ (reply! cb "err:profile unreachable"))))))

(define (handle-profile-set name email cb)
  (if (not *session*)
      (reply! cb "err:sign in first")
      (with-vat *vat*
        (on (<- *session* 'update-profile (if (string? name) name "")
                (if (string? email) email ""))
            (lambda (r)
              (reply! cb (if (eq? 'ok (denormalize-syrup r)) "ok" "err:refused")))
            #:catch (lambda _ (reply! cb "err:profile unreachable"))))))

;;; ── First-Person: personhood, vouch, enrollment ─────────────────────────
;; the gateway returns (ok . v) | (error . msg); planner-call settles them.
(define (handle-set-scope id cb)
  ;; dial another commune, or earth (null/"") — the union standpoint. Earth
  ;; keeps the last commune as the WRITE standpoint (My lands at a leaf) and
  ;; the dial's own facet widens to the whole fold; a commune leads the merge
  ;; from cache at once, then refreshes every membership.
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((or (not (string? id)) (string=? id ""))
    (push-merged!) (reply! cb "ok"))
   (else (set! *scope* id) (seam-scope! id) (watch-slots!) (push-merged!)
         (fetch-snapshot!) (reply! cb "ok"))))

(define (handle-fp-status cb)
  (if (or (not *session*) (not *scope*)) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'fp-status *scope*)
        (lambda (v)
          (reply! cb (scm->json-canonical
                      `(("person" . ,(if (and (pair? v) (alist-ref v 'person)) #t #f))
                        ("scope"  . ,(or (and (pair? v) (alist-ref v 'scope)) ""))
                        ;; what the sheet may offer: the founding act only
                        ;; while nobody is recognised; how many could witness
                        ("governor" . ,(if (and (pair? v) (alist-ref v 'governor)) #t #f))
                        ("bootstrapped" . ,(if (and (pair? v) (alist-ref v 'bootstrapped)) #t #f))
                        ("verified" . ,(let ((n (and (pair? v) (alist-ref v 'verified-count))))
                                         (if (number? n) n 0))))))))))

;; the caller's own ask: none · collecting (n of k, who signed, who already
;; vouches for them) · finalized — read from the ceremony, the same on every
;; device
(define (handle-fp-my-ceremony cb)
  (if (or (not *session*) (not *scope*)) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'fp-my-ceremony *scope*)
        (lambda (v)
          (let ((st (and (pair? v) (alist-ref v 'state))))
            (reply! cb (scm->json-canonical
                        `(("state"  . ,(cond ((symbol? st) (symbol->string st))
                                             ((string? st) st) (else "none")))
                          ("count"  . ,(let ((n (and (pair? v) (alist-ref v 'count)))) (if (number? n) n 0)))
                          ("quorum" . ,(let ((n (and (pair? v) (alist-ref v 'quorum)))) (if (number? n) n 0)))
                          ("witnesses" . ,(list->vector (filter string? (->list (and (pair? v) (alist-ref v 'witnesses))))))
                          ("vouchers"  . ,(list->vector (filter string? (->list (and (pair? v) (alist-ref v 'vouchers))))))))))))))

;; ── vouching: your word, in your signature ───────────────────────────────
;; The client-signed pair (the socialize shape): the gateway hands back the
;; VRC's preimage, we re-derive its SAID and sign with the resident key, the
;; gateway rebuilds from the same args and issues iff the signature is ours.
;; AT is the bridge's clock stamp — Hoot is clock-free — folded into the SAID
;; so a re-vouch after a recall is a fresh credential. A session that cannot
;; sign takes the bare fp-vouch: the same credential, unsigned. K gets "ok"
;; or "err:…".
;; ── a client-signed act, whole ────────────────────────────────────────────
;; Every statement a citizen makes in their own name (a vouch, a coworker's
;; word on a skill) crosses the same way: with no resident key the UNSIGNED
;; door; else PREIMAGE hands back the SAID-relevant fields, this browser
;; re-derives the SAID and signs it with its own key, and SIGNED lands it.
;; UNSIGNED / PREIMAGE : () → a send; SIGNED : sig → a send. K hears
;; "ok" or "err:…", WHAT naming the act in a refusal.
(define (client-signed-act! what unsigned preimage signed k)
  (define (landed r)
    (match (denormalize-syrup r)
      (('ok . _) (k "ok"))
      ((or ('error . (? string? m)) ('error (? string? m))) (k (string-append "err:" m)))
      (_ (k (string-append "err:" what " refused")))))
  (define (unreachable _) (k (string-append "err:" what " unreachable")))
  (cond
   ((or (not *session*) (not *scope*)) (k "err:sign in first"))
   ((not (can-sign?))
    (with-vat *vat* (on (unsigned) landed #:catch unreachable)))
   (else
    (with-vat *vat*
      (on (preimage)
          (lambda (p0)
            (match (denormalize-syrup p0)
              (('ok f)
               (sign-said-as-self!
                (compute-said (soc-ar f 'issuer) (soc-ar f 'holder) (soc-ar f 'schema)
                              (soc-ar f 'claims) (or (soc-ar f 'edges) '()))
                (lambda (sig)
                  (if (not sig) (k "err:could not sign")
                      (on (signed sig) landed #:catch unreachable)))))
              ((or ('error . (? string? m)) ('error (? string? m))) (k (string-append "err:" m)))
              (_ (k "err:preimage refused"))))
          #:catch (lambda _ (k "err:preimage unreachable")))))))

(define (vouch! subject-aid rel at k)
  (let ((rel (normalize-rel rel)))
    (client-signed-act! "vouch"
      (lambda () (<- *session* 'fp-vouch *scope* subject-aid rel))
      (lambda () (<- *session* 'fp-vouch-preimage *scope* subject-aid rel at))
      (lambda (sig) (<- *session* 'fp-vouch-signed *scope* subject-aid rel at sig))
      k)))
;; a vouch, a withdrawal and a witness's signature each change what a contact
;; row reads, so the book is read again once the gateway has answered
(define (handle-fp-vouch subject-aid rel at cb)
  (vouch! subject-aid rel at (lambda (s) (fetch-contacts!) (reply! cb s))))
(define (handle-fp-withdraw-vouch subject-aid cb)
  (if (or (not *session*) (not *scope*)) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'fp-withdraw-vouch *scope* subject-aid)
        (lambda (_) (fetch-contacts!) (reply! cb "ok")))))

(define (handle-fp-enroll cb)
  (if (or (not *session*) (not *scope*)) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'fp-request-enroll *scope*)
        (lambda (_) (reply! cb "ok")))))

;; the standing asks, each with its progress and who already vouches for
;; the candidate — the same rows the witness rail shows
(define (handle-fp-pending cb)
  (if (or (not *session*) (not *scope*)) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'fp-pending *scope*)
        (lambda (v)
          (reply! cb (scm->json-canonical
                      (list->vector
                       (map (lambda (r)
                              `(("said"      . ,(str-field r 'said))
                                ("candidate" . ,(str-field r 'candidate))
                                ("sponsor"   . ,(str-field r 'sponsor))
                                ("count"     . ,(alist-ref r 'count 0))
                                ("quorum"    . ,(alist-ref r 'quorum 1))
                                ("vouchers"  . ,(list->vector (filter string? (->list (alist-ref r 'vouchers '())))))))
                            (filter pair? (->list v))))))))))

(define (handle-fp-grant candidate-aid cb)
  (if (or (not *session*) (not *scope*)) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'fp-grant *scope* candidate-aid)
        (lambda (_) (reply! cb "ok")))))

;; the witnessed alternative to fpGrant: open a k-of-n enrollment ceremony —
;; the ask lands in every PHC-holder's witness inbox, each vouch is their own
;; browser signature over the statement, and at quorum the PHC issues carrying
;; one edge per witness.
(define (handle-fp-open-ceremony candidate-aid k cb)
  (if (or (not *session*) (not *scope*)) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'fp-open-ceremony *scope* candidate-aid
                           (if (and (number? k) (>= k 1))
                               (inexact->exact (round k)) 1))
        (lambda (_) (reply! cb "ok")))))

;; the caller's own PHC, as a portable card — the dial stores it so it can
;; present it to other communes' gateways (PHC presentation, slice-1).
(define (handle-fp-my-phc cb)
  ;; the holder's PHC as a portable wire (governance-cred->wire SAD + sig),
  ;; JSON the dial stores + presents to other gateways. "none" if no PHC.
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'my-phc)
        (lambda (v) (reply! cb (if (pair? v) (scm->json-canonical v) "none"))))))

;; present a PHC carried from another gateway/commune (slice-2). WIRE-JSON is
;; the stored my-phc string; the gateway verifies + imports if the issuer is a
;; trusted federated commune and the holder is us.
(define (handle-fp-present wire-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'present-phc wire-json)
        (lambda (_) (reply! cb "ok")))))

;; what you carry between gateways beyond the PHC: the vouches for you and
;; by you, each voucher's personhood, and the key logs a foreign gateway
;; needs to check them — one JSON string, "" when there is nothing yet
(define (handle-fp-my-vouches cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'my-vouches)
        (lambda (v) (reply! cb (if (string? v) v ""))))))

;; present a carried bundle here; the gateway verifies every card in
;; dependency order and imports what stands. "ok:<n>" newly imported.
(define (handle-fp-present-bundle wire-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'present-bundle wire-json)
        (lambda (n) (reply! cb (string-append "ok:" (if (number? n) (number->string n) "0")))))))

;;; ── compute: the commons' machine book (doors/machine.scm) ────────────────
;; Member acts forward the session's AID as identity-key; reads name only
;; the commune. Rows cross as JSON (the door's own wire shape); ids and
;; verdicts cross as "ok:<v>" / JSON the way the sibling handlers answer.

;; optional-args over the seam: {"key":val,…} → (key val …); "" or absent → ()
(define (opts-flat opts-json)
  (if (or (not (string? opts-json)) (string-null? opts-json)) '()
      (apply append
             (map (lambda (p) (list (string->symbol (car p)) (cdr p)))
                  (json-read-ordered opts-json)))))

(define (handle-machine-offer commune lane classes headroom repro opts-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (apply <- *session* 'machine-offer
                              commune lane classes headroom repro
                              (opts-flat opts-json))
        (lambda (v) (reply! cb (string-append "ok:" (if (string? v) v "")))))))

(define (handle-machine-retract commune offer-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-retract commune offer-id)
        (lambda (_v) (reply! cb "ok")))))

(define (handle-machine-offers commune cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-offers commune)
        (lambda (v) (reply! cb (scm->json-canonical (list->vector v)))))))

(define (handle-machine-submit commune task-class lane repro input-hash opts-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (apply <- *session* 'machine-submit
                              commune task-class lane repro input-hash
                              (opts-flat opts-json))
        (lambda (v) (reply! cb (string-append "ok:" (if (string? v) v "")))))))

(define (handle-machine-withdraw commune job-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-withdraw commune job-id)
        (lambda (_v) (reply! cb "ok")))))

(define (handle-machine-jobs commune cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-jobs commune)
        (lambda (v) (reply! cb (scm->json-canonical (list->vector v)))))))

(define (handle-machine-match commune job-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-match commune job-id)
        (lambda (v) (reply! cb (scm->json-canonical (list->vector v)))))))

(define (handle-machine-claim commune job-id offer-id opts-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (apply <- *session* 'machine-claim
                              commune job-id offer-id (opts-flat opts-json))
        (lambda (v) (reply! cb (string-append "ok:" (if (string? v) v "")))))))

(define (handle-machine-accept commune claim-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-accept commune claim-id)
        (lambda (_v) (reply! cb "ok")))))

(define (handle-machine-preempt commune claim-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-preempt commune claim-id)
        (lambda (_v) (reply! cb "ok")))))

(define (handle-machine-claims commune cb)
  (if (not *session*) (reply! cb "err:sign in first")
        (planner-call cb (<- *session* 'machine-claims commune)
        (lambda (v) (reply! cb (scm->json-canonical (list->vector v)))))))

;; the claim's lender fetches the envelope it's meant to run — the door
;; gates on the session's identity; a refusal arrives as an err: reply.
(define (wire-shape x)
  (cond ((tagged? x) (string-append "<" (if (symbol? (tagged-label x))
                                            (symbol->string (tagged-label x)) "?") ">"))
        ((pair? x) (string-append "(P " (wire-shape (car x)) " . " (wire-shape (cdr x)) ")"))
        ((vector? x) (string-append "#(" (number->string (vector-length x)) ")"))
        ((string? x) (string-append "\"" x "\""))
        ((symbol? x) (string-append "'" (symbol->string x)))
        ((boolean? x) (if x "#t" "#f"))
        ((null? x) "()")
        ((number? x) (number->string x))
        (else "?")))
(define (handle-machine-fetch-envelope commune claim-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-fetch-envelope commune claim-id)
        (lambda (v)
          (seam-trace! (string-append "fetch-env tail: " (wire-shape (cddddr v))))
          (reply! cb (scm->json-canonical v))))))

;; replay is authoritative per the dispute model: either party of the claim
;; asks the question again and the verdict carries the challenge fields —
;; receipt digest, reproduced, attestation hash, counter-hash.
(define (handle-machine-replay commune claim-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-replay commune claim-id)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

;; the dispute lifecycle — spec §5: a party raises 'non-delivery or
;; 'wrong-result; three sortition-selected citizens review; the record
;; closes on two-of-three or lapses past its window. PoI replay stays
;; authoritative — the hive weighs the prover's answer.
(define (handle-machine-dispute commune claim-id kind cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-dispute commune claim-id kind)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

(define (handle-machine-dispute-verdict commune dispute-id verdict cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-dispute-verdict commune
                        dispute-id verdict)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

(define (handle-machine-disputes commune cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-disputes commune)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

(define (handle-machine-dispute-close commune dispute-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-dispute-close commune dispute-id)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

;; the AccountLink ceremony — a did:key binds an account, dual-signed;
;; keri:<aid> binds the caller's own AID. Either side unlinks.
(define (handle-machine-bind commune wire-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (let ((w (json-read-ordered wire-json)))
        (planner-call cb (<- *session* 'machine-bind commune w)
          (lambda (v) (reply! cb (scm->json-canonical v)))))))

(define (handle-machine-unbind commune key side cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-unbind commune key side)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

(define (handle-machine-bindings commune cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-bindings commune)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

;; ring-3 payout — the commune's act: a statement's sends, all to the bound
;; treasury Safe; no send rail injected means an honest error, not a phantom.
(define (handle-machine-payout commune wire-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (let ((w (json-read-ordered wire-json)))
        (planner-call cb (<- *session* 'machine-payout commune w)
          (lambda (v) (reply! cb (scm->json-canonical v)))))))

;; the wire receipt as JSON — the body the lender's node emitted. v is
;; (digest verdict): the digest it landed under, verified|unverifiable|bad.
(define (handle-machine-receipt commune wire-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-receipt commune
                            (json-read-ordered wire-json))
        (lambda (v)
          (reply! cb (scm->json-canonical
                      `(("digest"  . ,(or (and (pair? v) (car v)) ""))
                        ("verdict" . ,(or (and (pair? v) (cadr v) #f) #f)))))))))

;; dry-run: does the wire receipt's own digest verify? v is (ok? verdict).
(define (handle-machine-verify wire-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-verify
                            (json-read-ordered wire-json))
        (lambda (v)
          (reply! cb (scm->json-canonical
                      `(("digestOk" . ,(if (and (pair? v) (car v)) #t #f))
                        ("verdict"  . ,(or (and (pair? v) (cadr v) #f) #f)))))))))

;; the bridge's statement as JSON; v is (matched missing claimed paid).
(define (handle-machine-settle commune wire-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-settle commune
                            (json-read-ordered wire-json))
        (lambda (v)
          (reply! cb (scm->json-canonical
                      `(("matched" . ,(or (and (pair? v) (car v)) 0))
                        ("missing" . ,(or (and (pair? v) (cadr v) #f) 0))
                        ("claimed" . ,(or (and (pair? v) (caddr v) #f) 0))
                        ("paid"    . ,(or (and (pair? v) (cadddr v) #f) 0)))))))))

(define (handle-machine-statements commune cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-statements commune)
        (lambda (v) (reply! cb (scm->json-canonical (list->vector v)))))))

;; the envelope contract — a job envelope as JSON; v is its bridgeJobId.
(define (handle-machine-envelope wire-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-envelope
                            (json-read-ordered wire-json))
        (lambda (v) (reply! cb (string-append "ok:" (if (string? v) v "")))))))

;; storage challenges — the store kind's replay: a nonce answered by
;; sha256(nonce ∥ held bytes), 'exact by construction. The borrower (or a
;; governor) issues; the claim's lender answers; the issuer verifies. v is
;; the challenge row as an alist (or a list of them).
(define (handle-machine-challenge commune claim-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-challenge commune claim-id)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

(define (handle-machine-challenge-answer commune challenge-id answer cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-challenge-answer commune
                            challenge-id answer)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

(define (handle-machine-challenge-verify commune challenge-id expected
                                         content-hash cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-challenge-verify commune
                            challenge-id expected content-hash)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

(define (handle-machine-challenges commune claim-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-challenges commune claim-id)
        (lambda (v) (reply! cb (scm->json-canonical (list->vector v)))))))

;; the relay rendezvous — body crosses as a JSON string the door's own
;; wire-normalize reduces; 'after rides as a number the session flattens.
(define (handle-machine-signal commune claim-id body-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (let ((body (json-read-ordered body-json)))
        (planner-call cb (<- *session* 'machine-signal commune claim-id body)
          (lambda (v) (reply! cb (scm->json-canonical v)))))))

(define (handle-machine-signals commune claim-id after cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (let ((n (arg-num after)))
        (planner-call cb (apply <- *session* 'machine-signals commune claim-id
                                (if (and (number? n) (> n 0))
                                    (list 'after n) '()))
          (lambda (v) (reply! cb (scm->json-canonical (list->vector v))))))))

;; ── the swarm bus ────────────────────────────────────────────────────────
;; The N-party rendezvous over the same signal shelf: open binds job-ids
;; (a JSON array of strings) under the borrower's name; of/signal(s) are
;; member-only reads and posts — the door runs the membership check.
(define (handle-machine-swarm-open commune swarm-id job-ids-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (let ((job-ids (vector->list (or (json-read-ordered job-ids-json) #()))))
        (planner-call cb (<- *session* 'machine-swarm-open commune swarm-id
                             job-ids)
          (lambda (v) (reply! cb (scm->json-canonical v)))))))

(define (handle-machine-swarm-of commune swarm-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-swarm-of commune swarm-id)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

(define (handle-machine-swarm-signal commune swarm-id body-json cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (let ((body (json-read-ordered body-json)))
        (planner-call cb (<- *session* 'machine-swarm-signal commune swarm-id
                             body)
          (lambda (v) (reply! cb (scm->json-canonical v)))))))

(define (handle-machine-swarm-signals commune swarm-id after cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (let ((n (arg-num after)))
        (planner-call cb (apply <- *session* 'machine-swarm-signals commune
                                swarm-id
                                (if (and (number? n) (> n 0))
                                    (list 'after n) '()))
          (lambda (v) (reply! cb (scm->json-canonical (list->vector v))))))))

;; ── the bridge — ring 3's legs ───────────────────────────────────────────
;; bridge-submit routes an open, ring:3 job to a provider network when the
;; commune's own match is empty; attempts reads the ledger back.
(define (handle-machine-bridge-submit commune job-id provider cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-bridge-submit commune job-id
                           provider)
        (lambda (v) (reply! cb (scm->json-canonical v))))))

(define (handle-machine-bridge-attempts commune job-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'machine-bridge-attempts commune job-id)
        (lambda (v) (reply! cb (scm->json-canonical (list->vector v)))))))

;;; ── governance: the decision inbox (governance-surface.md §Inbox) ─────────
;; list-proposals → [{id, status}]; the dial renders the open decisions.
(define (handle-list-proposals cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'list-proposals)
        (lambda (v)
          (reply! cb (scm->json-canonical
                      (list->vector
                       (map (lambda (p)
                              `(("id"     . ,(if (pair? p) (car p) ""))
                                ("status" . ,(if (and (pair? p) (symbol? (cdr p)))
                                                 (symbol->string (cdr p)) "open"))))
                            (if (list? v) (filter pair? v) '())))))))))

;; get-result id → {state, tally:{option:weight,…}, abstain}. Tally is a
;; goblins hashmap of stance→rational; fold it into a JSON object of floats.
(define (tally->wire tally)
  (if (procedure? tally)  ; a live hashmap object
      (hashmap-fold (lambda (k val acc)
                      (cons (cons (if (symbol? k) (symbol->string k) k)
                                  (exact->inexact val))
                            acc))
                    '() tally)
      '()))

(define (handle-get-result id cb)
  ;; get-result answers with a BARE shape — `(open . alist)` / `(closed . alist)`
  ;; / `(error …)` — NOT an `(ok . v)` envelope, so planner-call would reject the
  ;; open/closed cases as "refused". Read it directly.
  (if (not *session*) (reply! cb "err:sign in first")
      (with-vat *vat*
        (on (<- *session* 'get-result id)
            (lambda (r)
              (let ((v (denormalize-syrup r)))
                (reply! cb (scm->json-canonical
                            (if (and (pair? v) (memq (car v) '(open closed)))
                                (let ((k (alist-ref (cdr v) 'kind))
                                      (d (alist-ref (cdr v) 'domain)))
                                  `(("state"   . ,(symbol->string (car v)))
                                    ("kind"    . ,(if (symbol? k) (symbol->string k) ""))
                                    ("domain"  . ,(if (symbol? d) (symbol->string d) ""))
                                    ("tally"   . ,(tally->wire (alist-ref (cdr v) 'tally)))
                                    ("abstain" . ,(exact->inexact (or (alist-ref (cdr v) 'abstain) 0)))
                                    ;; the question in the proposer's words — the forum's thread title
                                    ("text"    . ,(let ((t (alist-ref (cdr v) 'description)))
                                                    (if (string? t) t "")))
                                    ("franchise" . ,(franchise->wire (alist-ref (cdr v) 'franchise)))
                                    ;; the registry's meta: when it opened (seconds), what it is about
                                    ("openedAt" . ,(let ((t (alist-ref (cdr v) 'opened-at)))
                                                     (if (number? t) (exact->inexact t) 0)))
                                    ("subject"  . ,(let ((x (alist-ref (cdr v) 'subject)))
                                                     (if (string? x) x "")))))
                                `(("state" . "error")))))))
            #:catch (lambda _ (reply! cb "err:get-result unreachable"))))))

;; liquid democracy, the write side: hand FRACTION (0..1, a string off the
;; form) of your voice to DELEGATE-AID, or take it back. Federation-wide —
;; the per-scope override (lobby's `'scope SID` rest) stays a REPL act.
(define (handle-set-delegation delegate-aid fraction cb)
  (let ((f (and (string? fraction) (string->number fraction))))
    (cond
     ((not *session*) (reply! cb "err:sign in first"))
     ((not (and (string? delegate-aid) (not (string=? delegate-aid ""))))
      (reply! cb "err:no delegate"))
     ((not (and f (> f 0) (<= f 1))) (reply! cb "err:fraction must be within (0, 1]"))
     (else
      (planner-call cb (<- *session* 'set-delegation delegate-aid f)
        (lambda (v)
          (reply! cb (if (and (pair? v) (eq? (car v) 'error))
                         (string-append "err:" (if (pair? (cdr v)) (cadr v) "delegation refused"))
                         "ok"))))))))

(define (handle-revoke-delegation delegate-aid cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'revoke-delegation delegate-aid)
        (lambda (v)
          (reply! cb (if (and (pair? v) (eq? (car v) 'error))
                         (string-append "err:" (if (pair? (cdr v)) (cadr v) "revoke refused"))
                         "ok"))))))

;; your liquid-democracy delegations → [{to, fraction, mandated}]. The fraction
;; you keep (act directly) is 1 − Σ fraction.
(define (handle-list-delegations cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'list-delegations)
        (lambda (v)
          (reply! cb (scm->json-canonical
                      (list->vector
                       (map (lambda (d)
                              `(("to"       . ,(if (pair? d) (car d) ""))
                                ("fraction" . ,(exact->inexact (if (pair? d) (cadr d) 0)))
                                ("mandated" . ,(and (pair? d) (caddr d) #t))))
                            (if (list? v) (filter pair? v) '())))))))))

;; your two governance weights → {producer, consumer} (playnet.typ §Governance):
;; producer = labour share (production), consumer = pool share (consumption).
(define (handle-my-voice cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'my-voice)
        (lambda (v)
          (reply! cb (scm->json-canonical
                      `(("producer" . ,(exact->inexact (or (and (pair? v) (alist-ref v 'producer)) 0)))
                        ("consumer" . ,(exact->inexact (or (and (pair? v) (alist-ref v 'consumer)) 0))))))))))

;; your producer voice in one commune → {producer} — the voice map fills its
;; columns with this, one read per commune in the roster.
(define (handle-voice-in scope-id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'voice-in (if (string? scope-id) scope-id ""))
        (lambda (v)
          (reply! cb (scm->json-canonical
                      `(("producer" . ,(exact->inexact (or (and (pair? v) (alist-ref v 'producer)) 0))))))))))

;; cross-gateway UC merge proposals → [{a,b}] (two colliding UC AIDs). These
;; render in the inbox as scope-formation (production) decisions.
(define (handle-list-uc-proposals cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'list-uc-proposals)
        (lambda (v)
          (reply! cb (scm->json-canonical
                      (list->vector
                       (map (lambda (p)
                              `(("a" . ,(if (pair? p) (car p) ""))
                                ("b" . ,(if (pair? p) (cadr p) ""))))
                            (if (list? v) (filter pair? v) '())))))))))

;; governor: close an open ballot (records the tally). Errors for non-governors.
(define (handle-close id cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'close id)
        (lambda (v)
          (reply! cb (if (and (pair? v) (eq? (car v) 'error))
                         (string-append "err:" (if (pair? (cdr v)) (cadr v) "close failed"))
                         "ok"))))))

;; A franchise on the wire: "federation", or "scope:<sid>" — the commune whose
;; producers weigh the ballot (a bare "scope" means the one you stand in).
;; The service's spelling is 'federation | ('scope sid).
(define (wire->franchise f)
  (cond
   ((not (string? f)) 'federation)
   ((string=? f "scope") (if (string? *scope*) (list 'scope *scope*) 'federation))
   ((and (> (string-length f) 6) (string=? (substring f 0 6) "scope:"))
    (list 'scope (substring f 6)))
   (else (string->symbol f))))
(define (franchise->wire f)
  (cond
   ((symbol? f) (symbol->string f))
   ((and (pair? f) (eq? (car f) 'scope) (pair? (cdr f)) (string? (cadr f)))
    (string-append "scope:" (cadr f)))
   (else "")))

;; governor: open a ballot. domain picks its class (governance-surface.md).
;; SUBJECT, "kind:id" or "", names what the ballot is about; it rides in the
;; registry's meta and comes back on get-result.
(define (handle-open kind domain id description franchise subject cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (apply <- *session* 'open
                          (string->symbol (if (string? kind) kind "ballot"))
                          (string->symbol (if (string? domain) domain "policy"))
                          id description
                          (wire->franchise franchise)
                          (if (and (string? subject) (not (string=? subject ""))) (list subject) '()))
        (lambda (v)
          (reply! cb (if (and (pair? v) (eq? (car v) 'error))
                         (string-append "err:" (if (pair? (cdr v)) (cadr v) "open failed"))
                         "ok"))))))

;; cast a stance on an open ballot. The dial sends the position as a string
;; ("yes"/"no"/…); the service wants a symbol, so coerce here.
(define (handle-cast id stance cb)
  (if (not *session*) (reply! cb "err:sign in first")
      (planner-call cb (<- *session* 'cast id
                          (string->symbol (if (string? stance) stance "abstain")))
        (lambda (v)
          (reply! cb (if (and (pair? v) (eq? (car v) 'error))
                         (string-append "err:" (if (pair? (cdr v)) (cadr v) "cast failed"))
                         "ok"))))))

;; Cast a stance CARRYING THE CITIZEN'S OWN SIGNATURE.
;;
;; A vote is the citizen's assertion, so the durable ACDC is only conformant if
;; the citizen's controller signs it — and that key lives here, in the browser,
;; and never reaches the gateway. Two round trips:
;;
;;   1. `stance-preimage` returns every SAID field the SERVER is authoritative
;;      for (schema, issuer = our session AID, issuee = the recording scope,
;;      domain, proposal-id, the ballot-snapshot edge block). We contribute only
;;      our position and a timestamp.
;;   2. We re-derive the SAID ourselves with the shared `compute-said` — this is
;;      the step that makes it a real signature rather than blind-signing a
;;      digest the server chose — sign it, and return the signature via
;;      `cast-signed`. The gateway rebuilds from its own authoritative fields
;;      and rejects anything whose signature doesn't verify against our AID.
;; local, so we depend on no alist helper Hoot might not carry
(define (preimage-ref pre k)
  (let ((p (assq k pre))) (and p (cdr p))))

(define (handle-cast-signed id stance cb)
  (cond
   ((not *session*) (reply! cb "err:sign in first"))
   ;; No signing key in this session → fall back to the legacy unsigned cast
   ;; (the ballot's unified verifier still accepts the sealer path). Signed
   ;; when we can, never a regression when we can't.
   ((not (can-sign?)) (handle-cast id stance cb))
   (else
    (let ((position (string->symbol (if (string? stance) stance "abstain"))))
      ;; The server builds the WHOLE credential (position included) and hands
      ;; back its SAID fields; we re-derive the SAID over the returned claims —
      ;; the generic client-signing flow, identical in shape to delegation.
      ;; `planner-call` unwraps the `(ok . v)` envelope for us, so `resp` here is
      ;; already v. stance-preimage returns `(list 'ok FIELDS)`, so the wire value
      ;; is `(ok FIELDS)` → v = `(FIELDS)`, i.e. the fields alist is `(car resp)`.
      ;; (This is exactly the socialize-preimage shape; keep the two in step.)
      (planner-call cb (<- *session* 'stance-preimage id position)
        (lambda (resp)
          (let* ((pre    (car resp))
                 (claims (or (preimage-ref pre 'claims) '()))
                 ;; timestamp is server-issued (Hoot is clock-free); it is in
                 ;; the claims we sign over, and we echo it back to cast-signed
                 (ts     (let ((p (assq 'timestamp claims))) (and p (cdr p))))
                 ;; likewise the blinding nonce `u` — server-issued, part of
                 ;; the SAID we sign, so the server needs it back to rebuild
                 ;; the identical credential (#f if the server predates it)
                 (u      (let ((p (assq 'u claims))) (and p (cdr p))))
                 (said   (compute-said (preimage-ref pre 'issuer)
                                       (preimage-ref pre 'holder)
                                       (preimage-ref pre 'schema)
                                       claims
                                       (or (preimage-ref pre 'edges) '()))))
            (sign-said-as-self! said (lambda (sig)
            ;; cast-signed replies a BARE `'ok` symbol on success (not an
            ;; `(ok . _)` envelope — see tests/voice/test-client-signing.scm),
            ;; so planner-call's `('ok . v)` pattern can't match it; handle the
            ;; reply shapes directly.
            (with-vat *vat*
              (on (<- *session* 'cast-signed id position ts sig u)
                  (lambda (r)
                    (match (denormalize-syrup r)
                      ('ok                         (reply! cb "ok"))
                      (('ok . _)                   (reply! cb "ok"))
                      ;; service returns `(list 'error MSG …)`, so the message is
                      ;; the element after 'error, not the whole cdr.
                      (('error (? string? m) . _)  (reply! cb (string-append "err:" m)))
                      (('error . (? string? m))    (reply! cb (string-append "err:" m)))
                      (_                           (reply! cb "err:signed cast refused"))))
                  #:catch (lambda _ (reply! cb "err:signed cast unreachable")))))))))))))

;;; ── connect ─────────────────────────────────────────────────────────────
(define *sref* (gateway-sref))

;; ── the dial's live walkie: a per-ROOM audio WebRTC mesh ──────────────
;; A room is a topic string (`meeting/<scope>/<slug>`); the gateway holds its
;; roster (gateway/presence.scm), and the mesh spans THAT roster rather than
;; everyone online — so several meetings run at once on one gateway without
;; hearing each other (docs/planning/faces/meeting-station.md, Layer 0/1).
;;
;; Negotiation rides the lobby's `signal` relay (same one the repl's netlayer
;; uses) with walkie-* signal types so it never collides with CapTP. Each type
;; carries its room after a `|`, so a signal that crosses a room switch is
;; dropped instead of patching a stale peer connection. Glare: the greater AID
;; initiates. The mic is one shared track, added at pc-creation (rides the
;; initial offer — no renegotiation); PTT just toggles `enabled`.
;;
;; v1 holds ONE room at a time: joining a second leaves the first. The roster
;; arrives from the gateway both as the join reply and as later `room-roster`
;; pushes, so a peer who joins after you does get wired up — the push is what
;; closes the "connected before you joined" hole the scope-wide version had.
(define *walkie-on?* #f)              ; mic acquired (joined the live layer)
(define *walkie-pcs* '())            ; (peer-aid . pc) — the mesh IS this list
(define *walkie-room* #f)            ; the room topic we are in, or #f
(define *walkie-cam?* #f)            ; we hold a camera track right now
(define *walkie-screen?* #f)         ; the video sender is showing the screen

;; The mesh ceiling. Every peer sends its video to every other, so what one
;; person uploads grows with the room; the page's video budget (mesh-plan.ts)
;; says how many peers still get a stream worth sending, and the plan it applies
;; to each sender is cut from the same two numbers. Past it the people are on the
;; roster and in the room, and the face says so rather than melt the last
;; joiner's uplink; a bigger room needs a server in the media path.
(define (walkie-max-peers) (mesh-max-peers))   ; peers besides yourself

(define (walkie-pc peer) (assoc-ref *walkie-pcs* peer))
(define (walkie-pc-set! peer pc)
  (set! *walkie-pcs* (cons (cons peer pc)
                           (filter (lambda (p) (not (equal? (car p) peer)))
                                   *walkie-pcs*))))
(define (walkie-drop-peer! peer)     ; tear one leg of the mesh down
  (let ((pc (walkie-pc peer)))
    (when pc (rtc-close-pc pc) (rtc-drop-media peer))
    (set! *walkie-pcs* (filter (lambda (p) (not (equal? (car p) peer)))
                               *walkie-pcs*))))
(define (walkie-full?) (>= (length *walkie-pcs*) (walkie-max-peers)))

;; every signal type carries the room it belongs to: "walkie-offer|meeting/…"
(define (walkie-type base) (string-append base "|" (or *walkie-room* "")))
(define (walkie-split type)          ; → (base . room), room "" when absent
  (let ((bar (string-index type #\|)))
    (if bar
        (cons (substring type 0 bar) (substring type (+ bar 1)))
        (cons type ""))))

(define (walkie-signal! target type data)
  (when (and *lobby* *aid*)
    (with-vat *vat* (<-np *lobby* 'signal target *aid* type data))))

;; mic + the video sender + remote media + ICE forwarding. The video sender goes
;; on whether or not a camera is on: it is what lets the camera come and go, and
;; lets an audio-only joiner see the room's video, without a new offer.
(define (walkie-equip! pc peer offerer?)
  (rtc-add-mic pc)
  ;; the offerer puts the video sender in its offer; the answerer adopts the
  ;; offer's own (webRTC setRemote) rather than add a second beside it
  (when offerer? (rtc-add-cam pc))
  (when *walkie-screen?* (rtc-replace-video pc 1))
  (rtc-on-remote-media pc peer)
  (rtc-on-ice pc (procedure->external
                  (lambda (cand)
                    (walkie-signal! peer (walkie-type "walkie-ice") cand))))
  (walkie-announce-video! peer))

;; What a peer should draw for us: a tile while we send video of any kind — the
;; camera, or the screen standing in for it — and none otherwise. The wire says
;; so outright; a receiver's own mute events are not a dependable witness.
(define (walkie-announce-video! peer)
  (walkie-signal! peer (walkie-type "walkie-cam")
                  (if (or *walkie-cam?* *walkie-screen?*) "on" "off")))

;; Point every video sender at what we show now — the screen while sharing, else
;; the camera (or nothing: an empty sender sends nothing and its m-line stays) —
;; and tell each peer.
(define (walkie-show!)
  (for-each (lambda (p)
              (rtc-replace-video (cdr p) (if *walkie-screen?* 1 0))
              (walkie-announce-video! (car p)))
            *walkie-pcs*))

(define (walkie-connect! peer)       ; we initiate (greater AID): offer
  (unless (or (walkie-pc peer) (not *walkie-on?*) (walkie-full?))
    (let ((pc (rtc-new-pc)))
      (walkie-pc-set! peer pc)
      (walkie-equip! pc peer #t)
      (rtc-offer pc (procedure->external
                     (lambda (sdp)
                       (walkie-signal! peer (walkie-type "walkie-offer") sdp)))))))

(define (walkie-on-offer! peer sdp)  ; we answer (lesser AID)
  (when (and *walkie-on?* (or (walkie-pc peer) (not (walkie-full?))))
    (let ((pc (or (walkie-pc peer)
                  (let ((p (rtc-new-pc))) (walkie-pc-set! peer p)
                       (walkie-equip! p peer #f) p))))
      (rtc-set-remote pc sdp)
      (rtc-answer pc (procedure->external
                      (lambda (ans)
                        (walkie-signal! peer (walkie-type "walkie-answer") ans)))))))

(define (walkie-on-answer! peer sdp)
  (let ((pc (walkie-pc peer))) (when pc (rtc-set-remote pc sdp))))
(define (walkie-on-ice! peer cand)
  (let ((pc (walkie-pc peer))) (when pc (rtc-add-ice pc cand))))

(define (walkie-route-signal from type data)
  (let* ((split (walkie-split type))
         (base  (car split))
         (room  (cdr split)))
    (cond
     ;; not a walkie signal at all
     ((string=? base "invite")  (fetch-snapshot!))   ; invited to an event
     ;; someone connected with us: FROM is their AID, DATA the name they go by
     ;; a card someone gave us, changed or withdrew: read the book again
     ((string=? base "card") (fetch-contacts!))
     ((string=? base "connect")
      (%seam-connect-ask! (if (string? from) from "") (if (string? data) data "")))
     ;; a walkie signal for a room we are not in — a peer racing our room
     ;; switch, or a stale candidate. Dropping it is the whole point of
     ;; stamping the room onto the type.
     ((not (and *walkie-room* (string=? room *walkie-room*))) #f)
     ((string=? base "walkie-cam")    (rtc-peer-video from (if (string=? data "on") 1 0)))
     ((string=? base "walkie-offer")  (walkie-on-offer! from data))
     ((string=? base "walkie-answer") (walkie-on-answer! from data))
     ((string=? base "walkie-ice")    (walkie-on-ice! from data))
     (else #f))))

;; the roster, from the join reply or a later gateway push. Wire up whoever is
;; new (initiating only where our AID is greater), drop whoever left.
(define (walkie-apply-roster! room members)
  (when (and *walkie-room* (string=? room *walkie-room*))
    (let ((peers (filter (lambda (a) (not (equal? a *aid*))) members)))
      (for-each (lambda (p)
                  (unless (member (car p) peers) (walkie-drop-peer! (car p))))
                *walkie-pcs*)
      (when *walkie-on?*
        (for-each (lambda (peer)
                    (when (string>? *aid* peer) (walkie-connect! peer)))
                  peers)
        ;; say it plainly when the room outgrew the mesh: the people past the
        ;; ceiling are in the room and on the roster, and you are not hearing
        ;; them. Silence here would read as "nobody is talking".
        (when (> (length peers) (walkie-max-peers))
          (seam-walkie-state! "full"))))))

;; The servers a call finds its peers through are the gateway's to name (its
;; `ice-servers` door); the page holds none. They are fetched BEFORE the mic is
;; asked for, so no peer connection can come to exist without its list. A
;; gateway that cannot answer leaves the list empty — peers on the same network
;; still find each other — and the join goes on.
(define (ice-servers->json raw)
  (scm->json-canonical
   (list->vector
    (filter-map
     (lambda (server)
       (let ((al (denormalize-syrup server)))
         (and (list? al) (pair? al) (every pair? al)
              (map (lambda (kv)
                     (cons (if (symbol? (car kv)) (symbol->string (car kv)) (car kv))
                           (cdr kv)))
                   al))))
     (->plain-list raw)))))

(define (walkie-with-ice! then)
  ;; the handler's value is #t on both paths: what THEN ends in is a void FFI
  ;; call, and an `on` handler must yield exactly one value (see %seam-call!)
  (define (go json) (rtc-set-ice json) (then) #t)
  (if (not *lobby*)
      (then)
      (with-vat *vat*
        (on (<- *lobby* 'ice-servers)
            (lambda (raw) (go (ice-servers->json raw)))
            #:catch (lambda _ (go "[]"))))))

;; join: register in the room, acquire the mic (and the camera, when joining
;; with video — it has to exist before the first pc), then mesh over the
;; roster. WITH-VIDEO? starts the camera on; it is only where you begin — the
;; camera goes off and on at any time (walkie-cam!) through the video sender
;; every pc already holds.
(define (walkie-join! room with-video?)
  (when (and *walkie-room* (not (string=? *walkie-room* room)))
    (walkie-leave!))                          ; v1: one room at a time
  (set! *walkie-room* room)
  (set! *walkie-cam?* #f)
  (set! *walkie-screen?* #f)
  (walkie-with-ice! (lambda () (walkie-take-mic! room with-video?))))

(define (walkie-take-mic! room with-video?)
  (rtc-mic-get
   (procedure->external
    (lambda (ok)
      (set! *walkie-on?* (= ok 1))
      (cond
       ((not *walkie-on?*)
        (set! *walkie-room* #f)
        (seam-walkie-state! "denied"))
       (with-video?
        ;; the camera is optional in the weak sense: a refusal drops us to
        ;; audio and the room still works.
        (rtc-cam-get
         (procedure->external
          (lambda (cam-ok)
            (set! *walkie-cam?* (= cam-ok 1))
            (seam-walkie-state! (if *walkie-cam?* "joined-video" "joined"))
            (walkie-register! room)))))
       (else
        (seam-walkie-state! "joined")
        (walkie-register! room)))))))

;; tell the gateway we are in, and mesh over the roster it replies with.
;; The AID-bound session names US — the gateway will not take a name from the
;; wire, so a client cannot put anyone else in a roster.
(define (walkie-register! room)
  (when *session*
    (with-vat *vat*
      (on (<- *session* 'join-room room)
          (lambda (roster)
            (walkie-apply-roster! room (filter string? (->plain-list roster))))
          #:catch (lambda _ #f)))))

(define (walkie-talk! on?)
  (when *walkie-on?* (rtc-mic-enabled (if on? 1 0))))

;; The camera goes off by STOPPING: the light goes out, the video sender is
;; emptied (it stays, so nothing renegotiates) and the call carries on as audio.
;; It comes back the same way in reverse — a fresh capture onto the same sender.
;; Acquiring is asynchronous and can be refused, so the state is reported once
;; it is true ("cam-on" / "cam-denied" / "cam-off"), never assumed.
(define (walkie-cam! on?)
  (cond
   ((not *walkie-on?*) #f)
   ((and on? (not *walkie-cam?*))
    (rtc-cam-get
     (procedure->external
      (lambda (ok)
        (set! *walkie-cam?* (= ok 1))
        (when *walkie-cam?* (walkie-show!))
        (seam-walkie-state! (if *walkie-cam?* "cam-on" "cam-denied"))))))
   ((and (not on?) *walkie-cam?*)
    (set! *walkie-cam?* #f)
    (rtc-cam-stop)
    (walkie-show!)
    (seam-walkie-state! "cam-off"))))

;; screen share swaps what the existing video sender reads from. Same kind on
;; both ends, so by spec no new offer is needed — this is the whole reason
;; sharing works in a mesh that never renegotiates.
(define (walkie-screen! on?)
  (cond
   ((not *walkie-on?*) #f)
   (on?
    (rtc-screen-get
     (procedure->external
      (lambda (ok)
        (set! *walkie-screen?* (= ok 1))
        (when *walkie-screen?* (walkie-show!))
        (seam-walkie-state! (if *walkie-screen?* "screen-on" "screen-denied"))))))
   (else
    (set! *walkie-screen?* #f)
    (walkie-show!)
    (rtc-screen-stop)
    (seam-walkie-state! "screen-off"))))

(define (walkie-leave!)
  (rtc-mic-enabled 0)
  (for-each (lambda (p) (rtc-close-pc (cdr p))) *walkie-pcs*)
  ;; one sweep takes the whole media surface: every sink and tile, the stage,
  ;; the level meters, and the local camera/screen tracks
  (rtc-drop-all-media)
  (when (and *session* *walkie-room*)
    (with-vat *vat* (<-np *session* 'leave-room *walkie-room*)))
  (set! *walkie-pcs* '()) (set! *walkie-on?* #f)
  (set! *walkie-room* #f)
  (set! *walkie-cam?* #f) (set! *walkie-screen?* #f)
  (seam-walkie-state! "left"))

;; ── the wake: every live room, legible at once ───────────────────────
;; docs/planning/faces/meeting-station.md Layer 2. The thing NOT to build is every
;; room's media piped into every other; the thing to build is a low-rate index
;; any peer can hold ALL of — who is in each room, and the last thing said in
;; it. Text and counts: a hundred rooms of this costs less than one video
;; thumbnail, which is what makes "accessible at all times" affordable.
;;
;; Two sources, joined here rather than server-side because they live in
;; different vats: the gateway's ROSTERS (presence.scm `live-rooms`) and the
;; planner's CHAT (`chat-last`, one call for every topic at once — a round
;; trip per room is exactly the cost the wake exists to avoid). A room is a
;; chat topic, so the two are keyed by the same string with nothing to map.
(define (handle-wake cb)
  (cond
   ((not *lobby*) (reply! cb "err:offline"))
   (else
    (with-vat *vat*
      (on (<- *lobby* 'live-rooms)
          (lambda (raw)
            ;; `live-rooms` is gateway-wide, but a room's utterances resolve
            ;; only under the scope that owns them — the chat registry keys
            ;; every topic by the CALLER's scope. Another commune's room would
            ;; therefore come back permanently "quiet", which reads as an empty
            ;; meeting rather than as one we cannot see. Show only what we can
            ;; actually report on: the rooms of the scope we are standing in.
            (let* ((mine (string-append "meeting/" (or *scope* "") "/"))
                   (rooms (filter
                           (lambda (r) (has-prefix? (car r) mine))
                           (map (lambda (r)
                                  (let ((p (denormalize-syrup r)))
                                    (cons (car p)
                                          (filter string? (->plain-list (cdr p))))))
                                (->plain-list raw))))
                   (topics (map car rooms)))
              (define (emit lasts)      ; lasts: alist topic → (author body kind t)
                (reply! cb
                  (scm->json-canonical
                   (list->vector
                    (map (lambda (r)
                           (let ((l (assoc-ref lasts (car r))))
                             `(("room"  . ,(car r))
                               ("here"  . ,(length (cdr r)))
                               ("who"   . ,(list->vector (cdr r)))
                               ("said"  . ,(if l (list-ref l 1) ""))
                               ("by"    . ,(if l (list-ref l 0) ""))
                               ("kind"  . ,(if l (list-ref l 2) "")))))
                         rooms)))))
              (if (or (null? rooms) (not *planner*) (not *scope*))
                  (emit '())
                  ;; the last line of every live room, in ONE call
                  (on (<- *planner* 'chat-last *scope* (list->vector topics))
                      (lambda (v)
                        (match (denormalize-syrup v)
                          (('ok . ls) (emit (->plain-list ls)))
                          (_          (emit '()))))
                      #:catch (lambda _ (emit '()))))))
          #:catch (lambda _ (reply! cb "err:wake unreachable")))))))

;; the seam: the dial drives the whole live layer through one handler.
;; "join" carries the room topic; an empty arg keeps the scope-wide channel
;; the chat face has always used, now spelled as a room of its own.
(define (default-walkie-room)
  (string-append "meeting/" (or *scope* "commons") "/network"))

(define (handle-walkie op arg cb)
  (define (room-arg) (if (string-null? arg) (default-walkie-room) arg))
  (cond
   ((not (and *aid* *session*)) (reply! cb "err:sign in first"))
   ((string=? op "join")      (walkie-join! (room-arg) #f) (reply! cb "ok"))
   ((string=? op "joinvideo") (walkie-join! (room-arg) #t) (reply! cb "ok"))
   ((string=? op "leave")     (walkie-leave!) (reply! cb "ok"))
   ((string=? op "talk")      (walkie-talk! (string=? arg "on")) (reply! cb "ok"))
   ((string=? op "cam")       (walkie-cam! (string=? arg "on")) (reply! cb "ok"))
   ((string=? op "screen")    (walkie-screen! (string=? arg "on")) (reply! cb "ok"))
   ((string=? op "room")      (reply! cb (or *walkie-room* "")))
   ((string=? op "peers")     (reply! cb (number->string (length *walkie-pcs*))))
   (else                      (reply! cb "err:unknown"))))

;; live chat receipt: the gateway <-np's this inbox on every post to a
;; watched topic; we strip the scope prefix and hand the bare topic + the
;; message JSON to the dial (app.html dedups by id). One inbox, one watch
;; per topic (registered lazily on first open).
(define *chat-watched* '())   ; topics we've already asked to watch

(define (chat-msg->alist m)
  `(("id"      . ,(or (alist-ref m 'id) ""))
    ("author"  . ,(or (alist-ref m 'author) ""))
    ("body"    . ,(or (alist-ref m 'body) ""))
    ("kind"    . ,(or (alist-ref m 'kind) "text"))
    ("stratum" . ,(or (alist-ref m 'stratum) "public"))
    ("t"       . ,(or (alist-ref m 't) 0))))
(define (chat-msg->json m) (scm->json-canonical (chat-msg->alist m)))

(define *chat-inbox* #f)   ; spawned lazily inside the vat on first watch

;; the pool's push: the planner tells this ref when a scope's needs or
;; socialized means moved (a declaration, a retirement, a grant landing or
;; leaving), and the dial refetches slots-at — the map's pins follow the
;; pool, never a solve, and never a poll. One watch per scope, registered
;; when the dial stands in it.
(define *slots-watched* '())
(define *slots-inbox* #f)
(define (^slots-inbox _bcom)
  (methods
   ((slots-changed sid)
    (seam-slots-changed! (if (string? sid) sid ""))
    ;; the scope moved — a declaration, a grant, or a SOLVE landing
    ;; (service.scm %on-solve-cached pushes here too): THAT scope's day is
    ;; refetched (one snapshot, folded in by note-snap!), so what the grid
    ;; shows is the plan as it stands, reactively, never a reload's worth
    ;; of lag behind it — and a federation of seven landing in turn costs
    ;; seven single fetches, never seven walks of the whole roster
    (when (and (string? sid) *planner* (member sid *scope-ids*))
      (with-vat *vat* (fetch-scopes! *planner* (list sid)))))))
(define (watch-slots!)
  (when (and *planner* *scope* (not (member *scope* *slots-watched*)))
    (set! *slots-watched* (cons *scope* *slots-watched*))
    (with-vat *vat*
      (unless *slots-inbox* (set! *slots-inbox* (spawn ^slots-inbox)))
      (on (<- *planner* 'slots-watch *scope* *slots-inbox*)
          (lambda _ #f) #:catch (lambda errs #f)))))
(define (^chat-inbox _bcom)
  (methods
   ((chat-message topic msg)
    (let* ((m (denormalize-syrup msg))
           ;; topic arrives as "scope/bare" — hand the dial the bare half
           (slash (string-index topic #\/))
           (bare (if slash (substring topic (+ slash 1)) topic)))
      (seam-chat-message! bare (chat-msg->json m))))))

;; the dial's topic chat — generic: TOPIC is any string (an Intent id, a
;; journey commitment, a label-slug). Strata are resolved and stamped
;; server-side from the plan; the dial filters read-side. Replies:
;;   "post"    → "ok:<stratum>" | "err:…"
;;   "history" → canonical-JSON array of messages | "err:…"
(define (handle-chat op topic body kind cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((not *scope*)   (reply! cb "err:no scope yet"))
   ((and (string? op) (string=? op "post"))
    (planner-call
     cb (<- *session* 'chat-post *scope* topic body
            (if (and (string? kind) (not (string=? kind ""))) kind "text"))
     (lambda (v)
       (reply! cb (string-append "ok:" (or (alist-ref v 'stratum) ""))))))
   (else
    ;; opening a channel → register a live watch (once per topic)
    (unless (member topic *chat-watched*)
      (set! *chat-watched* (cons topic *chat-watched*))
      (with-vat *vat*
        (unless *chat-inbox* (set! *chat-inbox* (spawn ^chat-inbox)))
        (on (<- *planner* 'chat-watch *scope* topic *chat-inbox*)
            (lambda _ #f) #:catch (lambda errs #f))))
    (planner-call
     cb (<- *planner* 'chat-history *scope* topic)
     (lambda (v)
       (reply! cb (scm->json-canonical
                   (list->vector (map chat-msg->alist (->list v))))))))))

;; Claim: draw earned credit for an individually-claimable good (the shop's
;; "get" button). labor-cost rides as #f — the SERVER prices the claim
;; (qty × crystallized SNLT); the browser never prices its own draw. On
;; success we refetch the snapshot (inventory + credit both moved) and
;; reply {claimed, balance} so the shop can animate immediately.
(define (handle-claim resource-id qty where when cb)
  (cond
   ((not *planner*) (reply! cb "err:sign in first"))
   ((not *scope*)   (reply! cb "err:no scope yet"))
   ((not (and (string? resource-id) (not (string=? resource-id ""))))
    (reply! cb "err:no resource"))
   (else
    (let ((q  (if (and (number? qty) (> qty 0)) qty 1))
          (at (and (string? where) (not (string=? where "")) where))
          (t  (and (string? when)  (not (string=? when ""))  when)))
      (planner-call cb (<- *session* 'claim *scope* resource-id q #f at t)
        (lambda (v)
          (fetch-snapshot!)
          (reply! cb (scm->json-canonical
                      `(("claimed" . ,(wire-value 'num (alist-ref v 'claimed) #f))
                        ("balance" . ,(wire-value 'num (alist-ref v 'balance) #f)))))))))))

;; one registry — every dial handler in one place (all defined above)
(for-each (lambda (entry)
            (seam-set-handler! (car entry) (procedure->external (cdr entry))))
          `(
            ("unlock"        . ,handle-unlock)
            ("signup"        . ,handle-signup)
            ("join"          . ,handle-join)
            ("passcodeCheck"   . ,handle-passcode-check)
            ("guardianSplit"   . ,handle-guardian-split)
            ("guardianRecover" . ,handle-guardian-recover)
            ("kelExport"     . ,handle-kel-export)
            ("kelImport"     . ,handle-kel-import)
            ("reconnect"     . ,handle-reconnect)
            ("setGateway"    . ,handle-set-gateway)
            ("enrollDevice"  . ,handle-enroll-device)
            ("enrollExternalDevice" . ,handle-enroll-external-device)
            ("unlockDevice"  . ,handle-unlock-device)
            ("tier"          . ,handle-tier)
            ("devices"       . ,handle-devices)
            ("revokeDevice"  . ,handle-revoke-device)
            ("walkie"        . ,handle-walkie)
            ("log"           . ,handle-log)
            ("fpWithdrawVouch" . ,handle-fp-withdraw-vouch)
            ("contactCheck"    . ,handle-contact-check)
            ("reachPresent"    . ,handle-reach-present)
            ("reachConfirm"    . ,handle-reach-confirm)
            ("reachWithdraw"   . ,handle-reach-withdraw)
            ("reachRead"       . ,handle-reach-read)
            ("cardGive"        . ,handle-card-give)
            ("cardWithdraw"    . ,handle-card-withdraw)
            ("profileGet"    . ,handle-profile-get)
            ("profileSet"    . ,handle-profile-set)
            ("fpStatus"      . ,handle-fp-status)
            ("fpMyCeremony"  . ,handle-fp-my-ceremony)
            ("fpVouch"       . ,handle-fp-vouch)
            ("fpEnroll"      . ,handle-fp-enroll)
            ("fpPending"     . ,handle-fp-pending)
            ("fpGrant"       . ,handle-fp-grant)
            ("fpOpenCeremony" . ,handle-fp-open-ceremony)
            ("fpMyPhc"       . ,handle-fp-my-phc)
            ("setScope"      . ,handle-set-scope)
            ("fpPresent"     . ,handle-fp-present)
            ("fpPresentBundle" . ,handle-fp-present-bundle)))
;; see the note below — one literal must stay under ~150 entries or the
;; Hoot bundle traps at boot; the compute* registrations start a second.
(for-each (lambda (entry)
            (seam-set-handler! (car entry) (procedure->external (cdr entry))))
          `(("machineOffer"      . ,handle-machine-offer)
            ("machineRetract"    . ,handle-machine-retract)
            ("machineOffers"     . ,handle-machine-offers)
            ("machineSubmit"     . ,handle-machine-submit)
            ("machineWithdraw"   . ,handle-machine-withdraw)
            ("machineJobs"       . ,handle-machine-jobs)
            ("machineMatch"      . ,handle-machine-match)
            ("machineClaim"      . ,handle-machine-claim)
            ("machineAccept"     . ,handle-machine-accept)
            ("machinePreempt"    . ,handle-machine-preempt)
            ("machineClaims"     . ,handle-machine-claims)
            ("machineFetchEnvelope" . ,handle-machine-fetch-envelope)
            ("machineReplay"        . ,handle-machine-replay)
            ("machineDispute"       . ,handle-machine-dispute)
            ("machineDisputeVerdict" . ,handle-machine-dispute-verdict)
            ("machineDisputes"      . ,handle-machine-disputes)
            ("machineDisputeClose"  . ,handle-machine-dispute-close)
            ("machineChallenge"        . ,handle-machine-challenge)
            ("machineChallengeAnswer"  . ,handle-machine-challenge-answer)
            ("machineChallengeVerify"  . ,handle-machine-challenge-verify)
            ("machineChallenges"       . ,handle-machine-challenges)
            ("machineSignal"           . ,handle-machine-signal)
            ("machineSignals"          . ,handle-machine-signals)
            ("machineSwarmOpen"        . ,handle-machine-swarm-open)
            ("machineSwarmOf"          . ,handle-machine-swarm-of)
            ("machineSwarmSignal"      . ,handle-machine-swarm-signal)
            ("machineSwarmSignals"     . ,handle-machine-swarm-signals)
            ("machineBridgeSubmit"     . ,handle-machine-bridge-submit)
            ("machineBridgeAttempts"   . ,handle-machine-bridge-attempts)
            ("machineBind"          . ,handle-machine-bind)
            ("machineUnbind"        . ,handle-machine-unbind)
            ("machineBindings"      . ,handle-machine-bindings)
            ("machinePayout"        . ,handle-machine-payout)
            ("machineReceipt"    . ,handle-machine-receipt)
            ("machineVerify"     . ,handle-machine-verify)
            ("machineSettle"     . ,handle-machine-settle)
            ("machineStatements" . ,handle-machine-statements)
            ("machineEnvelope"   . ,handle-machine-envelope)
            ("getResult"      . ,handle-get-result)
            ("listDelegations". ,handle-list-delegations)
            ("setDelegation"  . ,handle-set-delegation)
            ("revokeDelegation" . ,handle-revoke-delegation)
            ("close"          . ,handle-close)
            ("openProposal"   . ,handle-open)
            ;; Casts now go through the client-SIGNED path: the citizen's own
            ;; KERI key signs the stance ACDC (falls back to the legacy unsigned
            ;; cast when a session has no signing key).
              ))
;; The registry above is ONE quoted list, and Hoot's bundle traps at boot
;; ("table index is out of bounds") once that one literal passes ~150
;; entries — bisected 2026-10-10 with the body handlers: the same entries
;; registered from a second list boot, so the registry grows as lists of
;; this size, not as one. tools/protocol-lint reads every registration
;; wherever it is written.
(for-each (lambda (entry)
            (seam-set-handler! (car entry) (procedure->external (cdr entry))))
          `(
              ))

;; Hand-rolled sref parser. goblins' string->ocapn-id goes through
;; (web uri), whose Hoot compilation (JS-RegExp-backed shim) misparses
;; this sref shape — uri-host comes back #f and the vat dies in
;; string-length. The grammar is tiny and fixed:
;;   ocapn://DESIGNATOR.TRANSPORT/s/SWISS[?k=v&…]
;; so parse it with plain string ops and build the id directly.
(define (%uri-decode s)
  (let ((n (string-length s)))
    (let loop ((i 0) (acc '()))
      (cond
       ((>= i n) (list->string (reverse acc)))
       ((and (char=? (string-ref s i) #\%) (< (+ i 2) n))
        ;; tolerate a malformed %XX (string->number → #f): emit the literal
        ;; '%' and advance one char, never crash the spine in integer->char.
        (let ((code (string->number (substring s (+ i 1) (+ i 3)) 16)))
          (if code
              (loop (+ i 3) (cons (integer->char code) acc))
              (loop (+ i 1) (cons #\% acc)))))
       ((char=? (string-ref s i) #\+) (loop (+ i 1) (cons #\space acc)))
       (else (loop (+ i 1) (cons (string-ref s i) acc)))))))

;; Anything that is not a well-formed sref yields #f — a truncated
;; copy-paste, a stale bookmark, a hand-edited ?gateway=. Every field is
;; checked before it is sliced, because `(substring s 0 #f)` throws
;; "value out of range" out of string-copy, and this used to run INSIDE a vat
;; turn: one mangled URL took the entire spine down with a Hoot backtrace
;; instead of leaving a status the dial could show. Same tolerance the
;; %uri-decode above already applies to a malformed %XX.
(define (has-prefix? s p)
  (and (string? s) (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))

;; the swiss number is base64url — reject a stray char (an ellipsis from a
;; truncated paste) before base64-decode gets a chance to throw
(define (base64url-string? s)
  (and (> (string-length s) 0)
       (let loop ((i 0))
         (or (>= i (string-length s))
             (let ((c (string-ref s i)))
               (and (or (char-alphabetic? c) (char-numeric? c)
                        (memv c '(#\- #\_)))
                    (loop (+ i 1))))))))

(define (sref->sturdyref s)
  (and (has-prefix? s "ocapn://")
       (let* ((rest  (substring s (string-length "ocapn://")))
              (slash (string-index rest #\/)))
         (and slash
              (let* ((host  (substring rest 0 slash))
                     (dot   (string-rindex host #\.))
                     (after (substring rest slash))
                     (q     (string-index after #\?))
                     (path  (if q (substring after 0 q) after)))
                (and dot (> dot 0)
                     (has-prefix? path "/s/")
                     (let ((swiss (substring path (string-length "/s/"))))
                       (and (base64url-string? swiss)
                            (let* ((transport  (string->symbol (substring host (+ dot 1))))
                                   (designator (substring host 0 dot))
                                   (query (and q (substring after (+ q 1))))
                                   (hints (and query
                                               (fold (lambda (kv hm)
                                                       (match (string-split kv #\=)
                                                         ((k v) (hashmap-set hm k (%uri-decode v)))
                                                         (_ hm)))
                                                     (make-hashmap)
                                                     (string-split query #\&)))))
                              (make-ocapn-sturdyref
                               (make-ocapn-peer transport designator hints)
                               (base64-decode swiss #:alphabet base64-url-alphabet
                                              #:padding? #f)))))))))))

;; Parse BEFORE entering the vat, so a bad address is a status rather than a
;; dead spine. `#:catch` below only sees a rejected promise — it never saw a
;; synchronous throw from the parser.
(define *sturdy* (and (string? *sref*) (not (string=? *sref* ""))
                      (sref->sturdyref *sref*)))

;; The connection is gone (the socket closed, or CapTP aborted): every ref
;; that lived on it is dead — a `<-` on one throws inside the vat turn and
;; would take the spine down. Drop them, say so, and let the page schedule
;; the reconnect (handle-reconnect); the enliven below re-seats whoever can
;; sign (a passcode session, or the device key) — the seat, the taxonomy,
;; the snapshots all return on their own.
(define (sever! reason)
  (set! *lobby* #f)
  (set! *session* #f)
  (set! *planner* #f)
  (set! *slots-watched* '()) (set! *slots-inbox* #f)
  (set! *scope-ids* '())
  (seam-status! "error:gateway disconnected"))

(define (connect!)
  (seam-status! "connecting")
  ;; A fresh netlayer and mycapn for every attempt. A connect! runs only
  ;; with no live lobby, so nothing live is disturbed — and the previous
  ;; mycapn may hold a DEAD connection record for the gateway's peer
  ;; designator (the same one across every boot): a socket that failed to
  ;; OPEN is never cleaned up by the websocket netlayer (only an opened
  ;; socket's close is), so every later enliven through that mycapn — the
  ;; one on a freshly re-read address included — reused the dead record
  ;; and failed (restart-heal probe, 2026-09-23). The old one is garbage.
  (let ((ws-netlayer (with-vat *vat* (spawn ^websocket-netlayer))))
    (set! *mycapn* (with-vat *vat* (spawn-mycapn ws-netlayer))))
  (with-vat *vat*
    (on (<- *mycapn* 'enliven *sturdy*)
        (lambda (lobby-ref)
          (set! *lobby* lobby-ref)
          ;; on-sever hands its handler NO arguments (the sealed reason is
          ;; the promise's, not the handler's) — a one-argument lambda is an
          ;; arity error inside the vat turn that reports the severing
          (on-sever lobby-ref (lambda _ (sever! 'severed)))
          (seam-status! "connected")
          ;; unlocked before the commune was reachable: take the seat now
          (when (and (can-sign?) *aid* (not *session*))
            (take-seat! seam-status!)))
        #:catch
        (lambda (err)
          (seam-status! "error:gateway unreachable")))))

(define (handle-reconnect cb)
  (cond
   ((not *sturdy*) (reply! cb "err:no gateway"))
   (*lobby* (reply! cb "ok:connected"))
   (else (connect!) (reply! cb "ok"))))

;; The page re-read entry-points.json before this reconnect and found an
;; address. A sturdyref is a gateway PROCESS's — its swiss-num is minted
;; when that process registers and dies with it — so a gateway restarted
;; since this page loaded answers the address in hand with "no such
;; object", forever; and a page loaded while the gateway was still booting
;; had no address at all. The one the page just read is the one to enliven
;; with. An unchanged address is a plain reconnect.
(define (handle-set-gateway sref cb)
  (cond
   ((or (not (string? sref)) (string=? sref ""))
    (reply! cb "err:no gateway"))
   ((and (string? *sref*) (string=? sref *sref*))
    (handle-reconnect cb))
   (else
    (let ((sturdy (sref->sturdyref sref)))
      (cond
       ((not sturdy) (reply! cb "err:unusable gateway address"))
       (*lobby* (reply! cb "ok:connected"))
       (else
        (set! *sref* sref)
        (set! *sturdy* sturdy)
        (connect!)
        (reply! cb "ok:new address")))))))

(cond
 ((or (not (string? *sref*)) (string=? *sref* ""))
  (seam-status! "no-gateway"))
 ((not *sturdy*)
  ;; the common cause is a truncated ?gateway= — an abbreviated sref copied
  ;; out of a chat log or a wrapped terminal line
  (seam-status! "error:unusable gateway address (truncated ?gateway=)"))
 (else (connect!)))
