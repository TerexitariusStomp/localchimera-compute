;;; module/playnet/gateway/http-door.scm — the doors over HTTP, signed by a device key
;;;
;;; POST /api/<object>/<name> with a JSON object body keyed by the door's
;;; argument names (browser/api/openapi.json says which) reaches the same
;;; door CapTP does. A door whose auth is `device` needs the request signed
;;; by an enrolled device key; an `anonymous` door needs nothing; `root` and
;;; `operator` doors, and doors with a capability or in-process argument or
;;; reply, have no HTTP form (403). Plan: repo-split-and-protocol-doors.md §B4.
;;;
;;; The signature is RFC 9421 in the shape `sign-request` in
;;; (playnet keri signify) already emits toward KERIA, with the body covered:
;;;
;;;   Signify-Resource:  <device AID, the B-prefixed key>
;;;   Signify-Timestamp: <civil ISO instant>
;;;   Content-Digest:    blake3-256=:<base64 of blake3-256(body)>:
;;;   Signature-Input:   door=("signify-resource" "@method" "@path"
;;;                             "signify-timestamp" "content-digest")
;;;                      ;created=<unix seconds>;keyid=<device AID>;alg=ed25519
;;;   Signature:         door=:<CESR 0B qb64 Ed25519 signature>:
;;;
;;; Verification, each a refusal on its own: the keyid is the resource; the
;;; created instant is within %created-window of now; the digest is the
;;; body's; the signature verifies under the device AID's own key; the
;;; device is enrolled and live in the registry, which names its person; the
;;; (device, created, digest) triple has not been seen inside the window.
;;; The session the door then acts through is the person's, at tier device,
;;; spawned the way keri-authenticate-device spawns it.
;;;
;;; `handle-door-request` is pure over its inputs: the caller supplies `call`,
;;; (call object-ref name args) → the reply, so tests run it synchronously
;;; and the gateway runs it through its vat and settles the promise.

(define-module (playnet gateway http-door)
  #:use-module ((playnet utils records) #:select (vf-record?))
  #:use-module (playnet protocol)
  #:use-module (playnet protocol shapes)
  #:use-module ((playnet identity devices) #:select (device-owner-of device-entry-doors))
  #:use-module ((playnet keri citizen-sig) #:select (aid-prefix->pubkey))
  #:use-module ((playnet keri cesr) #:select (cesr-bytes->qb64 cesr-qb64->bytes))
  #:use-module ((playnet keri crypto-primitives)
                #:select (keri-crypto-ed25519-verify keri-crypto-blake3-256))
  #:use-module ((playnet keri signify-portable) #:select (sign-bytes))
  #:use-module ((playnet keri signify) #:select (signify-timestamp))
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web uri)
  #:use-module (rnrs bytevectors)
  #:use-module (json)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (%created-window
            door-signature-base sign-door-request verify-door-request
            door-path-parse door-args-from-body value->json parse-json-object
            admit-and-call handle-door-request))

;; seconds a `created` may sit from now, either way
(define %created-window 120)

(define %components
  '("signify-resource" "@method" "@path" "signify-timestamp" "content-digest"))

(define (params-string created keyid)
  (format #f "(~a);created=~a;keyid=~a;alg=ed25519"
          (string-join (map (lambda (c) (string-append "\"" c "\"")) %components) " ")
          created keyid))

(define (content-digest body-bv)
  (string-append "blake3-256=:"
                 (base64-encode-bv (keri-crypto-blake3-256 body-bv))
                 ":"))

(define (base64-encode-bv bv)
  ;; standard base64 with padding, the form Content-Digest carries
  (let* ((alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
         (n (bytevector-length bv))
         (out (open-output-string)))
    (let loop ((i 0))
      (when (< i n)
        (let* ((b0 (bytevector-u8-ref bv i))
               (b1 (if (< (+ i 1) n) (bytevector-u8-ref bv (+ i 1)) 0))
               (b2 (if (< (+ i 2) n) (bytevector-u8-ref bv (+ i 2)) 0))
               (triple (+ (* b0 65536) (* b1 256) b2)))
          (display (string-ref alphabet (logand (ash triple -18) 63)) out)
          (display (string-ref alphabet (logand (ash triple -12) 63)) out)
          (display (if (< (+ i 1) n) (string-ref alphabet (logand (ash triple -6) 63)) #\=) out)
          (display (if (< (+ i 2) n) (string-ref alphabet (logand triple 63)) #\=) out)
          (loop (+ i 3)))))
    (get-output-string out)))

(define (door-signature-base method path resource timestamp digest created keyid)
  "The bytes a door request signs: one line per covered component, then the
signature params, joined by newlines — the shape sign-request uses."
  (string->utf8
   (string-join
    (list (format #f "\"signify-resource\": ~a" resource)
          (format #f "\"@method\": ~a" (string-upcase (if (symbol? method) (symbol->string method) method)))
          (format #f "\"@path\": ~a" path)
          (format #f "\"signify-timestamp\": ~a" timestamp)
          (format #f "\"content-digest\": ~a" digest)
          (format #f "\"@signature-params\": ~a" (params-string created keyid)))
    "\n")))

(define* (sign-door-request keypair device-aid method path body-bv #:key (now #f))
  "The five headers a device signs a door request with, as (symbol . string)."
  (let* ((created (or now (inexact->exact (floor (instant->unix (clock-now))))))
         (ts (signify-timestamp))
         (digest (content-digest body-bv))
         (base (door-signature-base method path device-aid ts digest created device-aid))
         (sig (cesr-bytes->qb64 "0B" (sign-bytes base keypair))))
    (list (cons 'signify-resource device-aid)
          (cons 'signify-timestamp ts)
          (cons 'content-digest digest)
          (cons 'signature-input (string-append "door=" (params-string created device-aid)))
          (cons 'signature (string-append "door=:" sig ":")))))

;; ── verification ──────────────────────────────────────────────────────────

(define (header headers name)
  (let ((p (assq name headers)))
    (and p (let ((v (cdr p))) (if (string? v) v (format #f "~a" v))))))

(define (parse-signature-input s)
  "created and keyid from door=(…);created=N;keyid=K;alg=ed25519, or #f."
  (let ((mc (string-match ";created=([0-9]+)" s))
        (mk (string-match ";keyid=([A-Za-z0-9_-]+)" s)))
    (and mc mk (string-prefix? "door=(" s)
         (cons (string->number (match:substring mc 1)) (match:substring mk 1)))))

(define (parse-signature s)
  (let ((m (string-match "^door=:([A-Za-z0-9_-]+):$" s)))
    (and m (match:substring m 1))))

;; replay guard: (keyid created digest) seen inside the window
(define %seen '())
(define (seen! key now)
  (set! %seen (filter (lambda (e) (< (- now (cadr e)) (* 2 %created-window))) %seen))
  (if (member key %seen)
      #f
      (begin (set! %seen (cons key %seen)) #t)))

(define* (verify-door-request headers method path body-bv #:key (now #f))
  "(ok device-aid person-aid entry) or (error reason)."
  (let* ((now (or now (inexact->exact (floor (instant->unix (clock-now))))))
         (resource (header headers 'signify-resource))
         (ts (header headers 'signify-timestamp))
         (digest (header headers 'content-digest))
         (input (header headers 'signature-input))
         (sig (header headers 'signature)))
    (cond
     ((not (and resource ts digest input sig))
      '(error "missing signature headers (Signify-Resource, Signify-Timestamp, Content-Digest, Signature-Input, Signature)"))
     (else
      (let* ((parsed (parse-signature-input input))
             (created (and parsed (car parsed)))
             (keyid (and parsed (cdr parsed)))
             (sig-qb64 (parse-signature sig)))
        (cond
         ((not parsed) '(error "Signature-Input is not the door profile"))
         ((not sig-qb64) '(error "Signature is not door=:qb64:"))
         ((not (string=? keyid resource)) '(error "keyid is not the Signify-Resource"))
         ((> (abs (- now created)) %created-window) '(error "created is outside the window"))
         ((not (string=? digest (content-digest body-bv))) '(error "Content-Digest is not the body's"))
         ((not (catch #t
                 (lambda ()
                   (let ((pub (aid-prefix->pubkey resource))
                         (sig-bv (cesr-qb64->bytes sig-qb64))
                         (base (door-signature-base method path resource ts digest created keyid)))
                     (and (bytevector? sig-bv) (= 64 (bytevector-length sig-bv))
                          (keri-crypto-ed25519-verify pub base sig-bv))))
                 (lambda _ #f)))
          '(error "signature does not verify under the device key"))
         (else
          (let ((owner (device-owner-of resource now)))
            (cond
             ((not owner) '(error "device is not enrolled here, or not live"))
             ((not (seen! (list keyid created digest) now)) '(error "replay: this request was already seen"))
             (else (list 'ok resource (car owner) (cdr owner))))))))))))

;; ── request → door call ───────────────────────────────────────────────────

(define (door-path-parse path)
  "(object . name) from /api/<object>/<name>, or #f."
  (let ((m (string-match "^/api/(lobby|session|planner)/([a-z][a-z0-9!?-]*)$" path)))
    (and m (cons (string->symbol (match:substring m 1))
                 (string->symbol (match:substring m 2))))))

(define (door-args-from-body door body-alist)
  "The positional argument list for DOOR from the JSON object BODY-ALIST
(string keys), in head order; (error reason) when a required one is absent.

A skipped OPTIONAL argument is filled with its declared default (DOOR-ARG-
SHAPES' 4th field), never omitted — the door's own Scheme #:optional list
carries the identical default, so this is what the caller would have gotten
by leaving it out of a direct call too. Omitting it here instead would shift
every argument after it one position left, so a caller who supplies a LATER
optional while skipping an EARLIER one would silently hand the door its
values under the wrong names — the placeholder is what keeps position and
name in lockstep for every optional, not only the trailing one."
  (let loop ((entries (door-arg-shapes door)) (acc '()))
    (if (null? entries)
        (reverse acc)
        (let* ((e (car entries)) (name (symbol->string (car e))) (shape (cadr e))
               (required? (caddr e)) (default (cadddr e))
               (given (assoc name body-alist)))
          (cond
           ((eq? shape 'rest)
            ;; a trailing list is spliced; absent = none
            (let ((v (if given (cdr given) '())))
              (reverse (append (reverse (if (vector? v) (vector->list v) (if (list? v) v (list v)))) acc))))
           ((and (not given) required?)
            (list 'error (string-append "missing argument: " name)))
           ((not given) (loop (cdr entries) (cons default acc)))
           (else (loop (cdr entries) (cons (json-value->arg shape (cdr given)) acc))))))))

(define (json-value->arg shape v)
  "A JSON value as the Scheme the door expects for SHAPE."
  (cond
   ((eq? v 'null) #f)
   ((memq shape '(symbol)) (if (string? v) (string->symbol v) v))
   ((memq shape '(alist)) (if (list? v) (map (lambda (kv) (cons (string->symbol (car kv)) (cdr kv))) v) v))
   ((memq shape '(list)) (if (vector? v) (vector->list v) v))
   (else v)))

(define (value->json v)
  "A door's reply as something scm->json takes: symbols become strings,
alists objects, lists arrays, unspecified null. A door's rows leave the planner
written by their table (wire/rows.scm finished), so a record reaching here is
one the wire has no table for, and is refused by name."
  (cond
   ((or (eq? v #t) (eq? v #f) (number? v) (string? v)) v)
   ((vf-record? v) (error "http-door: a door answered a record the wire has no table for" v))
   ((symbol? v) (symbol->string v))
   ((unspecified? v) 'null)
   ((null? v) (vector))
   ((vector? v) (vector-map value->json v))
   ((and (pair? v) (every (lambda (x) (and (pair? x) (or (symbol? (car x)) (string? (car x))))) v))
    (map (lambda (kv) (cons (if (symbol? (car kv)) (symbol->string (car kv)) (car kv))
                            (value->json (cdr kv))))
         v))
   ((and (pair? v) (list? v)) (list->vector (map value->json v)))
   ((pair? v) (vector (value->json (car v)) (value->json (cdr v))))   ; a dotted pair
   (else (format #f "~s" v))))

(define (vector-map f v) (list->vector (map f (vector->list v))))

(define (respond code alist)
  (values (build-response #:code code
                          #:headers '((content-type . (application/json))))
          (string-append (scm->json-string (value->json alist)) "\n")))

(define* (admit-and-call door body-alist headers method path body-bv #:key target call (now #f))
  "Admit one call to DOOR and make it: the signature (unless the door is
anonymous), the device's allowlist, the arguments from BODY-ALIST (string
keys), the target object, the call. (code . alist) — 200 carries `reply`.
The HTTP door and the MCP door both stand on this."
  (let ((auth (door-auth door)) (object (door-object door)) (name (door-name door)))
    (let ((verdict (if (eq? auth 'anonymous)
                       '(ok #f #f #f)
                       (verify-door-request headers method path body-bv #:now now))))
      (cond
       ((eq? (car verdict) 'error)
        (cons 401 `((error . ,(cadr verdict)))))
       ((let ((allowed (and (cadddr verdict) (device-entry-doors (cadddr verdict)))))
          (and allowed (not (memq name allowed))))
        (cons 403 `((error . ,(format #f "~a/~a is outside this device's doors" object name)))))
       (else
        (let ((args (door-args-from-body door body-alist)))
          (if (and (pair? args) (eq? (car args) 'error))
              (cons 400 `((error . ,(cadr args))))
              (let* ((person (caddr verdict))
                     (ref (target object person)))
                (if (not ref)
                    (cons 503 '((error . "the door's object is not available")))
                    (let ((reply (catch #t
                                   (lambda () (call ref name args))
                                   (lambda (k . a) (list 'error (format #f "~a ~s" k a))))))
                      (cons 200 `((door . ,(format #f "~a/~a" object name))
                                  (reply . ,reply)))))))))))))

(define (parse-json-object body-bv)
  "The JSON object in BODY-BV as an alist (empty body = empty object), or 'bad."
  (catch #t
    (lambda ()
      (let ((v (if (zero? (bytevector-length body-bv)) '()
                   (json-string->scm (utf8->string body-bv)))))
        (if (list? v) v 'bad)))
    (lambda _ 'bad)))

(define* (handle-door-request request body-bv #:key target call (now #f))
  "Answer one door request. TARGET: (object person-aid-or-#f) → the Goblins
ref to send to (the lobby, the planner facet, or the person's device-tier
session); CALL: (ref name args) → the settled reply."
  (let* ((path (uri-path (request-uri request)))
         (method (request-method request))
         (headers (request-headers request))
         (body-bv (or body-bv (make-bytevector 0)))
         (parsed (door-path-parse path)))
    (cond
     ((not (eq? method 'POST)) (respond 405 '((error . "doors answer POST"))))
     ((not parsed) (respond 404 '((error . "no such door: the path is /api/<object>/<name>"))))
     (else
      (let ((door (door-ref (car parsed) (cdr parsed))))
        (cond
         ((not door) (respond 404 `((error . ,(format #f "no such door: ~a/~a" (car parsed) (cdr parsed))))))
         ((not (door-http? door))
          (respond 403 `((error . ,(format #f "~a/~a has no HTTP form (auth ~a)"
                                           (car parsed) (cdr parsed) (door-auth door))))))
         (else
          (let ((body-alist (parse-json-object body-bv)))
            (if (eq? body-alist 'bad)
                (respond 400 '((error . "body is not a JSON object")))
                (let ((r (admit-and-call door body-alist headers method path body-bv
                                         #:target target #:call call #:now now)))
                  (respond (car r) (cdr r))))))))))))
