;;; module/playnet/gateway/lobby.scm — OCapN gateway entry point
;;;
;;; The lobby is the single actor whose sturdyref is published.
;;; Clients enliven it and call methods to access services.
;;; The lobby delegates to internal actors — callers never see
;;; the underlying ^signup-agent, ^key-pool, etc.
;;;
;;; Authentication is KERI-based (challenge-response):
;;;   1. (keri-challenge)           → nonce string
;;;   2. client signs nonce with their AID private key (via SignifyPy)
;;;   3. (keri-authenticate aid sig nonce) → 'ok or (list 'error ...)
;;;   Successful auth returns the AID as the session identity-key,
;;;   which can then be used for open-terminal / get-mailbox.

(define-module (playnet gateway lobby)
  #:use-module ((playnet utils common) #:select (string-or-false env-flag?))
  #:use-module (playnet gateway evidence)
  #:use-module ((playnet gateway limits) #:select (%max-user-data-bytes %picture-max-chars))
  #:use-module ((playnet planner formulas counting) #:select (%contest-prefix))
  #:use-module ((playnet planner observation evidence) #:select (evidence-hash?))
  #:use-module (goblins)
  #:use-module ((playnet protocol) #:select (%doors door-name door-object door-auth))
  #:use-module ((playnet protocol dispatch) #:select (declared-methods))
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module ((playnet utils boot-cell) #:select (make-boot-cell))
  #:use-module (rnrs bytevectors)
  #:use-module (playnet keri bridge)
  #:use-module ((playnet keri citizen-sig)
                #:select (verify-said-signature verify-said-signature-under-key))
  #:use-module ((playnet openvtc first-person)
                #:select (holds-any-live-phc?))
  #:use-module ((playnet gateway device-registry)
                #:select (device-wire->cred device-credential-verdict
                          device-enroll! device-revoke! devices-of device-entry
                          device-entry-doors
                          device-entry-live? device-entry->wire-alist))
  #:use-module ((playnet keri crypto-primitives)
                #:select (keri-crypto-random-bytes))
  #:use-module ((playnet utils hex) #:select (bv->hex))
  #:use-module (playnet utils constant-time)
  #:use-module ((playnet gateway signup-agent)
                #:select (verify-rotation-event normalize-vecs aid-tag))
  #:use-module ((playnet keri reticulum-binding)
                #:select (kel-reticulum-pub verify-announce-packet
                          anchored-destinations announce-dest-hex
                          data-packet?))
  #:use-module ((playnet utils hex) #:select (hex->bv))
  ;; a grant's holder is the commune whose pool a recall moves
  #:use-module ((playnet governance credentials) #:select (cred-holder))
  #:use-module ((playnet governance keri notifications)
                #:select (register-credential-watcher!
                          unregister-credential-watcher!))
  ;; recipient.scm owns the channel taxonomy; validate against it rather
  ;; than restating the kind list here.
  #:use-module ((playnet notify recipient)
                #:select (durable-kind? binding-kind binding-ctx))
  #:use-module ((playnet gateway contact-points)
                #:select (contact-point-wire->cred contact-point-verdict))
  #:use-module ((playnet openvtc credentials) #:select (contact-point-binding-fields))
  #:use-module ((playnet gateway cards)
                #:select (card-wire->card card-verdict card-at card-put! card-get card-drop! person-aid?))
  #:use-module ((srfi srfi-1) #:select (filter-map))
  #:use-module (playnet gateway allotment)   ; the week's unplanned photo reads
  #:use-module ((playnet wire replies) #:select (finished))   ; registers the allotment table
  #:use-module ((playnet social lens) #:select (resolve-lens contact-aid))
  #:use-module ((playnet planner folksonomy graph) #:select (template->doc))
  ;; the pin book: a citizen's shared lists fold like their taxonomy cut
  #:use-module ((playnet planner folksonomy pins) #:select (pins-doc-public))
  #:use-module ((json parser) #:select (json-string->scm))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module (ice-9 format)
  #:export (^lobby ^lobby-session ^planner-facet %planner-public-doors release-contest-evidence!
            %default-ice-urls ice-servers-from-urls
            seed-pins! seed-taxonomy-docs!
            current-mesh-announcer
            current-mesh-mailbox
            contacts-file-for
            credentials-file-for
            taxonomy-file-for))

;; The mesh announcer — the reticulum netlayer ref (its announce-raw!
;; method forwards pre-signed packets to the bridge). Set by the
;; gateway at boot when --reticulum is on; #f means relay-announce is
;; declined. Boot cells, not parameters — vat spawn order must not
;; decide visibility (see boot-cell.scm).
(define current-mesh-announcer (make-boot-cell))

;; The mesh mailbox — ^mesh-mailbox holding ciphertext deliveries for
;; offline personas. Set alongside the announcer.
(define current-mesh-mailbox (make-boot-cell))

;;; ── Challenge nonce helpers ──────────────────────────────────────────────────
;;;
;;; Nonces are 32-byte random values encoded as hex.
;;; They expire after %nonce-ttl seconds to prevent replay.

(define %nonce-ttl 120)  ; 2 minutes

(define (generate-nonce)
  "Generate a 32-byte random nonce as a hex string. Routes through the
   keri-crypto backend (server: /dev/urandom; browser: getRandomValues)
   instead of Guile's `(random …)`, whose default *random-state* is a
   fixed Mersenne-Twister seed — that would make every gateway boot
   emit the same nonce sequence and break replay protection."
  (bv->hex (keri-crypto-random-bytes 32)))

(define (nonce-expired? timestamp)
  (> (- (instant->unix (clock-now)) timestamp) %nonce-ttl))

;;; ── ^lobby-session ──────────────────────────────────────────────────────────
;;;
;;; A per-AID facet returned to the caller by ^lobby on successful
;;; keri-authenticate. AID-PREFIX is closed over, NOT passed as a
;;; parameter — callers holding this cap cannot impersonate other AIDs
;;; through it. This is the pure-ocap way to enforce authentication:
;;; the proof IS the cap, not a parameter the server has to validate.
;;;
;;; The public ^lobby keeps only the unauthenticated surface
;;; (signup, keri-challenge, keri-authenticate, fetch-icp, has-role?,
;;; donation-address, public reads). Everything that operates on
;;; behalf of an identified caller lives here.

(define (%data-dir)
  (or (getenv "PLAYNET_DATA_DIR")
      (string-append (or (getenv "HOME") "/tmp")
                     "/.local/state/playnet")))

(define (release-contest-evidence! ballot-id)
  "Let go of the picture held for a contest ballot that has settled."
  (release-evidence! (%data-dir) ballot-id))

(define (%user-file kind aid-prefix)
  (string-append (%data-dir) "/" kind "-"
                 (substring aid-prefix 0 (min 16 (string-length aid-prefix)))
                 ".scm"))

(define (contacts-file-for aid-prefix) (%user-file "contacts" aid-prefix))
(define (cards-dir) (string-append (%data-dir) "/cards"))
(define (credentials-file-for aid-prefix) (%user-file "credentials" aid-prefix))
(define (taxonomy-file-for aid-prefix) (%user-file "taxonomy" aid-prefix))
(define (log-file-for aid-prefix) (%user-file "log" aid-prefix))
(define (pins-file-for aid-prefix) (%user-file "pins" aid-prefix))
(define (allotment-file-for aid-prefix) (%user-file "allotment" aid-prefix))

;; A picture crosses in parts and the session joins them; the whole is bounded
;; by %picture-max-chars (gateway/limits.scm).

;; the dial's pin book arrives as JSON ({lists:[{id,name,emoji,shared}],
;; pins:[{list,subject,note}]}); the fold reads the alist doc pins.scm names.
;; The read is tolerant — a malformed book folds as an empty one.
;; the fold's seed after a restart: every stored book, re-folded under the
;; AID its file carries. A book from before the aid wrap has no key to fold
;; under and is skipped — it re-folds on its citizen's next sync. Called by
;; the gateway right after ^pins is spawned; failures skip a file, never boot.
;; the same seed for the taxonomy fold: every stored cut, re-folded under
;; the AID its file carries. A cut from before the aid wrap has no key and
;; is skipped — it re-folds on its citizen's next publish.
(define (seed-taxonomy-docs! folksonomy-ref)
  (%seed-user-docs! "taxonomy-"
                    (lambda (aid doc) (<-np folksonomy-ref 'contribute aid doc))))

(define (seed-pins! pins-ref)
  (%seed-user-docs! "pins-"
                    (lambda (aid doc)
                      (<-np pins-ref 'contribute aid
                            (pins-doc-public (pins-json->doc doc))))))

;; the one scanner both seeds share: every aid-wrapped PREFIX file in the
;; data dir, handed to CONTRIBUTE! as (aid doc); a bad file is skipped
(define (%seed-user-docs! prefix contribute!)
  (let ((dir (%data-dir)))
    (for-each
     (lambda (f)
       (catch #t
         (lambda ()
           (let ((v (%read-user-data (string-append dir "/" f))))
             (when (and (list? v) (assq 'aid v) (assq 'doc v))
               (contribute! (cdr (assq 'aid v)) (cdr (assq 'doc v))))))
         (lambda _ #f)))
     (filter (lambda (f) (string-prefix? prefix f))
             (or (scandir dir) '())))))

(define (pins-json->doc json)
  (catch #t
    (lambda ()
      (let* ((v (json-string->scm json))
             (ref (lambda (o k) (and (list? o) (assoc-ref o k))))
             (vec (lambda (x) (if (vector? x) (vector->list x) '())))
             (str (lambda (x) (if (string? x) x ""))))
        (list
         (cons 'lists (map (lambda (l) `((id . ,(str (ref l "id")))
                                         (label . ,(str (ref l "name")))
                                         (emoji . ,(str (ref l "emoji")))
                                         (shared . ,(eq? #t (ref l "shared")))))
                           (vec (ref v "lists"))))
         (cons 'pins (map (lambda (p) `((list . ,(str (ref p "list")))
                                        (subject . ,(str (ref p "subject")))))
                          (vec (ref v "pins")))))))
    (lambda _ '((lists . ()) (pins . ())))))

;; Per-AID sync payloads funnel through %write-user-data!, which holds each to
;; %max-user-data-bytes (gateway/limits.scm).

(define (%user-data-size data)
  "Byte size of a sync payload: the bytevector length for an encrypted blob,
   else the serialised length."
  (if (bytevector? data)
      (bytevector-length data)
      (bytevector-length
       (string->utf8 (call-with-output-string (lambda (p) (write data p)))))))

(define (%write-user-data! file data)
  (let ((sz (%user-data-size data)))
    (when (> sz %max-user-data-bytes)
      (error "sync payload exceeds cap" sz %max-user-data-bytes)))
  (let ((dir (dirname file)))
    (unless (file-exists? dir)
      (catch 'system-error (lambda () (mkdir dir)) (lambda _ #f)))
    (call-with-output-file file
      (lambda (p) (write data p) (newline p)))))

(define (%read-user-data file)
  (if (file-exists? file) (call-with-input-file file read) '()))

;; Four endpoints (issue-credential, revoke-credential, open-terminal,
;; get-mailbox) used to gate on a role credential from the maintainer
;; role-credential ceremony (governance-member?/-governor? etc, (playnet
;; keri governance)) — removed 2026-08-19, never bootstrapped, so every one
;; of these was already permanently refused for everyone. All four are now
;; rewired to real credential checks: issue-credential and revoke-credential
;; to the founders.txt governor? gate (governance-svc's own capability, see
;; ^lobby-session below); open-terminal and get-mailbox below to a live PHC
;; (personhood credential) check.

;; A session answering only DOORS (a list of method symbols), or OBJECT
;; itself when DOORS is #f. The allowlist comes from the device's
;; authorization credential (device-registry `device-entry-doors`); the HTTP
;; door applies the same list before it reaches a session.
(define (door-gated doors object)
  (if (not doors)
      object
      (lambda (method . args)
        (if (memq method doors)
            (apply object method args)
            (list 'error (format #f "~a is outside this device's doors" method))))))

(define (hand-json->alist hand-json)
  "A plan-part hand off the wire: a JSON object {part-string: portion} (or an
   alist already) → ((part-string . portion) …)."
  (cond ((string? hand-json)
         (map (lambda (kv) (cons (if (symbol? (car kv)) (symbol->string (car kv)) (car kv)) (cdr kv)))
              (json-string->scm hand-json)))
        ((list? hand-json) hand-json)
        (else (error "hand: a JSON object of part-string → portion" hand-json))))

(define* (^lobby-session _bcom aid-prefix
                         terminal-svc mailbox-mgr governance-svc signup-agent
                         #:optional (oobi-host #f) (acdc-store #f)
                                    (folksonomy #f) (presence #f)
                                    (push-store #f) (recipient-registry #f)
                                    (planner-service #f) (tier 'root)
                                    (pins #f) (doors #f) (ai-svc #f)
                                    (contact-desk #f))
  ;; CONTACT-DESK: the commune's desk for presented contact points
  ;; (gateway/contact-points.scm make-contact-point-desk), or #f for a commune
  ;; that delivers to none.
  ;; DOORS: #f, or the door names (symbols) this device's authorization
  ;; allows — an outside interface enrolled with an allowlist answers those
  ;; and refuses the rest (door-gated, below the methods).
  ;; AI-SVC is the gateway's ^ai-service (the key-pool behind it), which
  ;; the commons pays for per call — so it is asked from a seat, within the
  ;; budget below, and never from the anonymous lobby.
  ;; PINS is the scope's pin book aggregator (folksonomy/pins.scm ^pins):
  ;; the shared half of this citizen's map lists folds there.
  ;; TIER is how this session proved the AID: 'root — the KEL key itself
  ;; (the passcode was in hand); 'device — a device key the root authorized
  ;; (keri-authenticate-device). Everyday acts are open to both; the acts
  ;; that reshape the identity (rotate-aid, enroll-device) need the root.
  ;; THE FORWARD, STATED ONCE: a session door whose act is the planner's
  ;; sends it there with this session's AID as the agent; absent a planner
  ;; (a gateway without one) the door answers the absence. The door's
  ;; declaration names the target (protocol.scm #:to), and the lint holds
  ;; the two together.
  (define (planner! . msg)
    (if planner-service (apply <- planner-service msg) (list 'error "no planner service")))
  (define (root-only what thunk)
    (if (eq? tier 'root)
        (thunk)
        (list 'error (string-append what " needs the passcode: sign in with it first"))))
  ;; The session AID's KEL-anchored reticulum pubkey (latest anchor
  ;; across icp+rotations), or #f. Both mesh methods gate on it: the
  ;; anchor is what makes a destination THIS persona's.
  ;; PROMISE is a governance write that moved SCOPE-ID's socialized pool.
  ;; Once it settles, the planner's watchers of that scope (the map) hear;
  ;; the reply passes through untouched, a rejection too.
  (define (pool-moved scope-id promise)
    (on promise
        (lambda (r)
          (when (and planner-service scope-id)
            (<- planner-service 'slots-changed! scope-id))
          r)
        #:promise? #t))
  ;; a grant names its commune as holder — the scope a recall moves
  (define (grant-scope-of said)
    (and acdc-store (and=> ($ acdc-store 'get said) cred-holder)))
  (define (anchored-mesh-pub)
    (let* ((entry (and oobi-host ($ oobi-host 'get aid-prefix)))
           (kel   (and entry
                       (cons (assq-ref entry 'icp)
                             (map car (or (assq-ref entry 'rotations) '()))))))
      (and kel (kel-reticulum-pub kel))))

  ;; Mesh send budget: a fixed-window rate limit per session (vats are
  ;; single-threaded, so plain mutation is safe). The mesh is a shared
  ;; scarce medium — LoRa links carry tens of packets a minute total —
  ;; and the gateway is the only chokepoint between a browser loop and
  ;; the airwaves.
  (define %mesh-window 60)   ; seconds
  (define %mesh-budget 30)   ; packets per window (announces + mail)
  (define mesh-window-start 0)
  (define mesh-window-count 0)
  (define (mesh-send-allowed?)
    (let ((now (instant->unix (clock-now))))
      (when (>= (- now mesh-window-start) %mesh-window)
        (set! mesh-window-start now)
        (set! mesh-window-count 0))
      (and (< mesh-window-count %mesh-budget)
           (begin (set! mesh-window-count (+ 1 mesh-window-count)) #t))))

  ;; AI budget: the same fixed window per session for the calls the
  ;; commons' account pays for. A seat that has spent its minute is answered
  ;; "" — the browser's cue to work on-device — and the log says so.
  (define %ai-window 60)     ; seconds
  (define %ai-budget 20)     ; completions + transcriptions per window
  (define ai-window-start 0)
  (define ai-window-count 0)
  (define (ai-call-allowed? what)
    (let ((now (instant->unix (clock-now))))
      (when (>= (- now ai-window-start) %ai-window)
        (set! ai-window-start now)
        (set! ai-window-count 0))
      (cond
       ((< ai-window-count %ai-budget)
        (set! ai-window-count (+ 1 ai-window-count))
        #t)
       (else
        (format (current-error-port)
                "[lobby ~a] ~a: AI budget for the minute spent (~a/~as)\n"
                (aid-tag aid-prefix) what %ai-budget %ai-window)
        #f))))
  (define (ai-door what ask)
    (cond
     ((not ai-svc) "")
     ((ai-call-allowed? what) (ask))
     (else "")))

  ;; The pictures this seat is sending, joined as their parts arrive:
  ;; upload id → the pictures of that upload, each a list of parts newest
  ;; first. Held in the session's memory for as long as the sending takes and
  ;; taken out by the read; a session's end takes what was never read.
  (define pictures '())                  ; ((id . ((part …) …)) …)
  (define (pictures-chars)
    (apply + (map (lambda (u) (apply + (map (lambda (pic) (apply + (map string-length pic)))
                                            (cdr u))))
                  pictures)))
  (define (picture-part! id index part)
    "Add PART to picture INDEX of upload ID. Returns the characters held."
    (let* ((u    (or (assoc-ref pictures id) '()))
           (pics (if (< index (length u)) u
                     (append u (make-list (- (+ index 1) (length u)) '()))))
           (pics (let loop ((ps pics) (i 0))
                   (cond ((null? ps) '())
                         ((= i index) (cons (cons part (car ps)) (cdr ps)))
                         (else (cons (car ps) (loop (cdr ps) (+ i 1))))))))
      (set! pictures (cons (cons id pics)
                           (filter (lambda (x) (not (equal? (car x) id))) pictures)))
      (pictures-chars)))
  ;; A counter's picture on its way to a contest ballot: ballot id → the parts
  ;; received so far, oldest first, with the hash and total they were sent
  ;; under. Held in the session's memory for as long as the sending takes.
  (define evidence-pending '())          ; ((ballot hash total part …) …)
  (define (evidence-take! ballot hash index total part)
    "Take PART of the picture for BALLOT (evidence.scm take-part). The last part
     joins them, checks they hash to HASH and holds the picture."
    (call-with-values
        (lambda () (take-part evidence-pending ballot hash index total part))
      (lambda (pending status)
        (set! evidence-pending pending)
        (case (car status)
          ((more)  (cons 'ok (cdr status)))
          ((done)  (if (hold-evidence! (%data-dir) ballot hash (cdr status))
                       (cons 'ok 'held)
                       (cons 'error "the picture does not match its hash, or is too large")))
          (else    status)))))
  (define (with-contest-terms ballot-id not-a-contest takes-none k)
    "Ask governance what BALLOT-ID's contest lets this seat do with a picture,
     and hand K the terms (role, scope-id, hash). Replies NOT-A-CONTEST for an id
     no contest carries, and governance's own words, or TAKES-NONE, when it
     names no terms."
    (if (not (and (string? ballot-id) (string-prefix? %contest-prefix ballot-id)))
        (cons 'error not-a-contest)
        (on (<- governance-svc 'contest-terms aid-prefix ballot-id)
            (lambda (r)
              (let ((t (and (pair? r) (eq? (car r) 'ok) (pair? (cdr r)) (cadr r))))
                (if t
                    (k t)
                    (cons 'error (if (and (pair? r) (pair? (cdr r)) (string? (cadr r)))
                                     (cadr r)
                                     takes-none)))))
            #:catch (lambda _ (cons 'error "the contest could not be read"))
            #:promise? #t)))
  (define (take-pictures! id)
    "The pictures of upload ID, each joined, and the upload forgotten."
    (let ((u (assoc-ref pictures id)))
      (set! pictures (filter (lambda (x) (not (equal? (car x) id))) pictures))
      (and u
           (let ((whole (filter (lambda (s) (not (string-null? s)))
                                (map (lambda (pic) (apply string-append (reverse pic))) u))))
             (and (pair? whole) whole)))))

  ;; The week's unplanned photo reads (allotment.scm), in this person's file.
  (define (allotment-week-now) (allotment-week (instant->unix (clock-now))))
  (define (allotment-doc-now)
    (catch #t
      (lambda () (%read-user-data (allotment-file-for aid-prefix)))
      (lambda _ '())))
  (define (allotment-keep! doc)
    (catch #t
      (lambda () (%write-user-data! (allotment-file-for aid-prefix) doc) #t)
      (lambda (k . a)
        (format (current-error-port) "[lobby ~a] allotment: ~a ~a\n" (aid-tag aid-prefix) k a)
        #f)))
  (define (allotment-spend!)
    "Spend one read of this week. #f when the week has none left."
    (let ((doc (allotment-spend (allotment-doc-now) (allotment-week-now))))
      (and doc (allotment-keep! doc))))
  (define (allotment-refund!)
    (allotment-keep! (allotment-refund (allotment-doc-now) (allotment-week-now))))
  ;; what the allotment door answers, as the page reads it (wire/replies.scm):
  ;; the door answers once a promise settles, so it finishes here
  (define (allotment-answer sees?)
    (finished 'allotment (cons 'ok (allotment-reply (allotment-doc-now) (allotment-week-now) sees?))))

  ;; The ONE write path for this AID's taxonomy cut — whether it arrives as a
  ;; synced doc (sync-taxonomy) or is adopted from a derived template
  ;; (adopt-lens): persist locally (backup) + feed the scope's aggregator
  ;; (publishing your cut IS voting). Single-sourced so the two entry points
  ;; can't drift.
  (define (publish-taxonomy! doc)
    ;; the full AID rides in the file, so a gateway restart re-folds every
    ;; stored cut (seed-taxonomy-docs! below) — the pin book's move
    (%write-user-data! (taxonomy-file-for aid-prefix)
                       `((aid . ,aid-prefix) (doc . ,doc)))
    (when folksonomy (<-np folksonomy 'contribute aid-prefix doc))
    'ok)

  ;; Resolve the optional lens NAME (car of OPT) against THIS caller's own
  ;; contact book into an AID set (or #f = the global cut). Shared by the
  ;; three lens-taking methods (folksonomy-template, adopt-lens, match-slots)
  ;; so they can't drift. LENS is the caller's own optional argument, #f
  ;; meaning "everyone" — the same value on all three, taken bare.
  ;; THIS caller's own contact book as the gateway keeps it: the copy the
  ;; lens, the relationships reading and list-contacts all read.
  (define (own-book)
    (catch #t
      (lambda () (%read-user-data (contacts-file-for aid-prefix)))
      (lambda _ '())))
  (define (lens-aids lens)
    (resolve-lens lens (own-book) aid-prefix))
  ;; A delegation's franchise, from the door's one optional SCOPE-ID: the
  ;; internal REST tag governance-svc's own arms read — () for
  ;; federation-wide, ('scope SID) for one commune. All six delegation
  ;; doors below build it here, spliced with `apply`, rather than each
  ;; writing the same `(if scope-id …)` out by hand.
  (define (franchise-rest scope-id) (if scope-id (list 'scope scope-id) '()))
  ;; a landed contrary observation refolds the scope's reading fold: the rail
  ;; changed, the fold rereads it (no row travels), as a cast hand does for voice
  (define (refolding-readings scope-id p)
    (on p (lambda (r)
            (when (and (pair? r) (eq? (car r) 'ok) planner-service)
              (<- planner-service 'observed! scope-id))
            r)
        #:promise? #t))

  (door-gated doors
  (declared-methods session

   ;; Diagnostic: which AID is this session bound to? Browser uses
   ;; this to verify the cap it's holding matches what it expects.
   ((whoami) aid-prefix)

   ;; ── Presence / push, AID-aware ─────────────────────────────────────
   ;; These mirror ^lobby's anonymous announce/register-push, but seed the
   ;; recipient registry with THIS session's AID (the closure) so the
   ;; notification router can reach the user per-identity. The browser
   ;; calls these on its session cap instead of the bare lobby once it
   ;; holds a session (see repl.scm announce-presence!). Presence itself
   ;; still keys by display name for the who/introduce/WebRTC surface.
   ((announce name user-inbox)
    (when recipient-registry
      (<-np recipient-registry 'bind aid-prefix 'browser user-inbox 'terse))
    (when presence (<- presence 'announce name user-inbox)))

   ((leave name)
    (when recipient-registry
      (<-np recipient-registry 'unbind-kind aid-prefix 'browser))
    (when presence (<- presence 'leave name)))

   ;; ── Meeting rooms, WRITE side ───────────────────────────────────────
   ;; The AID is closed over, so a caller can only ever put ITSELF in a room
   ;; or take itself out — the same property the contact-point doors below rely on.
   ;; Without it any client could add another AID to a roster, and the walkie
   ;; would then offer that peer a mic connection it never asked for.
   ;; Reads (`room-roster`, `live-rooms`) stay on the anonymous lobby.
   ((join-room room)
    (if (and presence (string? room) (not (string-null? room)))
        (<- presence 'join-room room aid-prefix)
        '()))

   ((leave-room room)
    (if (and presence (string? room) (not (string-null? room)))
        (<- presence 'leave-room room aid-prefix)
        '()))

   ;; The store parses the browser's subscription and refuses what is none;
   ;; the `push` channel is bound only for a subscription that was kept.
   ((register-push device-id subscription-json)
    (if (and push-store
             (eq? ($ push-store 'register device-id subscription-json) 'malformed))
        "err:that is not a push subscription"
        (begin
          (when recipient-registry
            (<-np recipient-registry 'bind aid-prefix 'push device-id 'terse))
          'ok)))

   ((unregister-push device-id)
    (when recipient-registry
      (<-np recipient-registry 'unbind aid-prefix 'push device-id))
    (when push-store ($ push-store 'unregister device-id))
    'ok)

   ;; ── Contact points ──────────────────────────────────────────────────
   ;;
   ;; How to reach this AID on a durable channel: an email address, an lxmf
   ;; address, a matrix room. `announce` binds 'browser and `register-push`
   ;; binds 'push as a client connects; the four methods below are the path
   ;; from a person's own word to the router for the channels that last.
   ;;
   ;; The AID is closed over, so a caller can only ever bind, list or drop
   ;; its OWN channel. That is the security property: without it anyone
   ;; could bind a channel under someone else's AID and redirect their
   ;; notifications.
   ;;
   ;; The registry is the live source of truth — the member record's email
   ;; field predates this and is display-only. `withdraw-contact-point` is
   ;; therefore a real erasure path for a notification address.
   ;;
   ;; What binds is the person's own contact-point credential, presented
   ;; (gateway/contact-points.scm): self-issued, blinded, signed. The commune
   ;; rebuilds it, checks it is the presenter's own, and holds it at the desk
   ;; while a code travels to the address itself; the code said back
   ;; (confirm-contact-point) is what binds the channel. So a commune delivers
   ;; only to an address that answered, for a person who signed for it.
   ((present-contact-point wire)
    (let ((cred (contact-point-wire->cred wire)))
      (cond
       ((string? cred) (cons 'error cred))
       ((not (and recipient-registry contact-desk))
        (cons 'error "this commune delivers to no contact points"))
       (else
        (let ((verdict (contact-point-verdict cred aid-prefix)))
          (if (not (eq? verdict #t))
              (cons 'error verdict)
              (let* ((fields (contact-point-binding-fields cred))
                     (held (apply contact-desk 'present aid-prefix fields)))
                (if (eq? held 'pending) (cons 'ok 'pending) held))))))))

   ((confirm-contact-point kind ctx code)
    (if (not (and recipient-registry contact-desk))
        (cons 'error "this commune delivers to no contact points")
        (let ((style (contact-desk 'confirm aid-prefix kind ctx code)))
          (if (symbol? style)
              (begin (<-np recipient-registry 'bind aid-prefix kind ctx style)
                     (cons 'ok #t))
              style))))

   ;; withdrawing is erasure: the binding leaves the registry (and its
   ;; keeper's file), and a point still waiting at the desk is put down
   ((withdraw-contact-point kind ctx)
    (cond
     ((not recipient-registry) (cons 'error "this commune delivers to no contact points"))
     (else
      (when contact-desk (contact-desk 'drop aid-prefix kind ctx))
      (<-np recipient-registry 'unbind aid-prefix kind ctx)
      (cons 'ok #t))))

   ;; The kinds this commune delivers on, and this AID's points on them: each
   ;; (kind ctx state), state `bound` or `pending` (its code is on its way).
   ;; Live kinds (browser, push) are connect-time state rebuilt on reconnect —
   ;; they are not contact points the person manages, so they stay out.
   ((my-contact-points)
    `((delivers . ,(if contact-desk (contact-desk 'delivers) '()))
      (points . ,(append
                  (if (not recipient-registry) '()
                      (filter-map
                       (lambda (b)
                         (and (durable-kind? (binding-kind b))
                              (list (binding-kind b) (binding-ctx b) 'bound)))
                       ($ recipient-registry 'bindings-for aid-prefix)))
                  (if (not contact-desk) '()
                      (map (lambda (p) (list (car p) (cadr p) 'pending))
                           (contact-desk 'pending aid-prefix)))))))

   ;; Per-AID data sync — server persists contacts and credentials so
   ;; they survive browser clears and transfer to new devices. The
   ;; browser is the primary holder (local-first); server is backup.
   ((sync-contacts data)
    (catch #t
      (lambda () (%write-user-data! (contacts-file-for aid-prefix) data) 'ok)
      (lambda (k . a) (list 'error (format #f "contacts: ~a ~a" k a)))))
   ((list-contacts) (own-book))

   ;; ── Per-AID captain's log — the dial's log face, synced whole ──
   ;; The document is an opaque JSON string the browser owns (local-first);
   ;; the server is backup, the same shape as contacts. The 512 KiB
   ;; %write-user-data! cap bounds it like every other sync payload.
   ((sync-log data)
    (catch #t
      (lambda () (%write-user-data! (log-file-for aid-prefix) data) 'ok)
      (lambda (k . a) (list 'error (format #f "log: ~a ~a" k a)))))
   ((list-log)
    (catch #t
      (lambda ()
        (let ((v (%read-user-data (log-file-for aid-prefix))))
          (if (string? v) v "")))
      (lambda _ "")))

   ;; ── the pin book: map lists, the same local-first + server-backup shape
   ;; as the log, and — like the taxonomy — a contribution: the lists marked
   ;; shared fold into the scope's pin book (folksonomy/pins.scm), notes and
   ;; private lists never leave this AID's file.
   ((sync-pins data)
    (catch #t
      (lambda ()
        ;; the full AID rides in the file, so a gateway restart can re-fold
        ;; every stored book under the key live syncs use (seed-pins! below)
        (%write-user-data! (pins-file-for aid-prefix)
                           `((aid . ,aid-prefix) (doc . ,data)))
        (when pins
          (<-np pins 'contribute aid-prefix (pins-doc-public (pins-json->doc data))))
        'ok)
      (lambda (k . a) (list 'error (format #f "pins: ~a ~a" k a)))))
   ((list-pins)
    (catch #t
      (lambda ()
        (let ((v (%read-user-data (pins-file-for aid-prefix))))
          (cond ((string? v) v)                       ; a book from before the wrap
                ((and (list? v) (assq 'doc v)) (cdr (assq 'doc v)))
                (else ""))))
      (lambda _ "")))
   ;; the commune's shared lists, and one list's members — read off the fold
   ((our-pin-lists) (if pins (<- pins 'lists) '()))
   ((our-pins list-id) (if pins (<- pins 'pins list-id) '()))

   ;; ── Per-AID taxonomy doc — the folksonomy's structure edges ──
   ;; Identical local-first + server-backup shape to contacts, but it also
   ;; feeds the scope's ^folksonomy aggregator: publishing your cut IS voting
   ;; (folksonomy.md "using is voting"). The aggregator lives in planner-vat,
   ;; so the contribute is an eventual <-np across the OCapN boundary.
   ((sync-taxonomy data)
    (catch #t
      (lambda () (publish-taxonomy! data))
      (lambda (k . a) (list 'error (format #f "taxonomy: ~a ~a" k a)))))
   ((list-taxonomy)
    (catch #t
      (lambda ()
        (let ((v (%read-user-data (taxonomy-file-for aid-prefix))))
          (if (and (list? v) (assq 'aid v) (assq 'doc v))
              (cdr (assq 'doc v))
              v)))                         ; a cut from before the aid wrap
      (lambda _ '())))
   ;; The commune's aggregated cut — a {id,label,children,count} template the
   ;; dial feeds straight to rebuildSpine. Optional LENS-NAME (folksonomy.md
   ;; Phase 4): "friends"/"family"/"commons"/"me"/… weights the cut toward that
   ;; neighbourhood. We resolve the name against THIS caller's own contact book
   ;; (the rel graph) into an AID set here in gateway-vat, then hand the SET to
   ;; the planner-vat aggregator, which builds the predicate locally — no closure
   ;; crosses the wire. #f / "everyone" → the global cut.
   ((folksonomy-template #:optional (lens #f))
    (if folksonomy (<- folksonomy 'template (lens-aids lens)) '()))
   ;; Adopt {this lens's cut} as MY published cut — the "using is voting" loop
   ;; and cold-start (a newcomer takes the commons'/friends' cut as their
   ;; starting taxonomy). Resolve the cut server-side, flatten it to my
   ;; structure edges (template->doc), publish via the shared path. No tree
   ;; crosses the wire; reuses the aggregator + template->doc + publish-taxonomy!.
   ((adopt-lens #:optional (lens #f))
    (if folksonomy
        (on (<- folksonomy 'template (lens-aids lens))
            (lambda (tree) (publish-taxonomy! (template->doc tree))))
        '()))

   ;; ── profile (settings) ── the AID edits its OWN display-name + email.
   ((profile) (<- signup-agent 'profile aid-prefix))
   ((update-profile display-name email)
    (<- signup-agent 'update-profile! aid-prefix display-name email))

   ;; ── First-Person ── personhood/vouch/enrollment, bound to THIS AID.
   ((fp-status scope-id) (<- governance-svc 'fp-status aid-prefix scope-id))
   ((fp-vouch scope-id subject-aid rel)
    (<- governance-svc 'fp-vouch aid-prefix scope-id subject-aid rel))
   ;; the client-signed pair: the vouch in the voucher's own signature
   ((fp-vouch-preimage scope-id subject-aid rel at)
    (<- governance-svc 'fp-vouch-preimage aid-prefix scope-id subject-aid rel at))
   ((fp-vouch-signed scope-id subject-aid rel at signature)
    (<- governance-svc 'fp-vouch-signed aid-prefix scope-id subject-aid rel at signature))
   ((fp-withdraw-vouch scope-id subject-aid)
    (<- governance-svc 'fp-withdraw-vouch aid-prefix scope-id subject-aid))
   ;; what stands between this AID and each person in its own book — the
   ;; book is read here, so the reading is of the caller's contacts alone
   ((relationships scope-id)
    (<- governance-svc 'relationships aid-prefix scope-id
        (filter-map contact-aid (own-book))))
   ;; ── Cards ── how to reach this person, handed to one contact. The
   ;; content is sealed to the receiver in the giver's browser; the commune
   ;; keeps ciphertext it can tell is the giver's, one card per pair, and a
   ;; withdrawal erases it (gateway/cards.scm). A card goes to, and is read
   ;; from, the people in the caller's own book.
   ((give-card subject-aid wire)
    (let ((card (card-wire->card wire)))
      (cond
       ((string? card) (cons 'error card))
       ((not (equal? subject-aid (assq-ref card 'to))) (cons 'error "the card is for someone else"))
       ((not (member subject-aid (filter-map contact-aid (own-book))))
        (cons 'error "a card goes to someone in your contacts"))
       (else
        (let ((verdict (card-verdict card aid-prefix)))
          (if (eq? verdict #t)
              (catch #t
                (lambda () (card-put! (cards-dir) card wire) (cons 'ok #t))
                (lambda _ (cons 'error "the card could not be kept")))
              (cons 'error verdict)))))))
   ((withdraw-card subject-aid)
    (if (person-aid? subject-aid)
        (begin (card-drop! (cards-dir) subject-aid aid-prefix) (cons 'ok #t))
        (cons 'error "a card is given to a person")))
   ;; what stands in cards between this AID and each person in its own book:
   ;; the card they gave (its wire, sealed to this AID) and when this AID's
   ;; own card to them was made
   ((cards)
    (cons 'ok
          (filter-map
           (lambda (aid)
             (and (person-aid? aid)
                  (let* ((theirs (card-get (cards-dir) aid-prefix aid))
                         (mine (card-get (cards-dir) aid aid-prefix))
                         (given (and mine (let ((c (card-wire->card mine))) (and (pair? c) (card-at c))))))
                    (and (or theirs given)
                         `((aid . ,aid) (card . ,theirs) (given . ,given))))))
           (filter-map contact-aid (own-book)))))
   ((fp-request-enroll scope-id)
    (<- governance-svc 'fp-request-enroll aid-prefix scope-id))
   ((fp-pending scope-id) (<- governance-svc 'fp-pending aid-prefix scope-id))
   ;; the caller's own ask, read from the ceremony
   ((fp-my-ceremony scope-id) (<- governance-svc 'fp-my-ceremony aid-prefix scope-id))
   ((fp-grant scope-id candidate-aid)
    (<- governance-svc 'fp-grant aid-prefix scope-id candidate-aid))
   ((fp-open-ceremony scope-id candidate-aid k)
    (<- governance-svc 'fp-open-ceremony aid-prefix scope-id candidate-aid k))
   ((my-phc) (<- governance-svc 'fp-my-phc aid-prefix))
   ((present-phc wire) (<- governance-svc 'present-phc aid-prefix wire))
   ;; the bundle: what you carry between gateways — personhood, vouches,
   ;; the blessings and key logs that make them checkable elsewhere
   ((my-vouches) (<- governance-svc 'fp-my-vouches aid-prefix))
   ((present-bundle wire) (<- governance-svc 'present-bundle aid-prefix wire))

   ;; Two credential surfaces, DON'T confuse them (they have different threat
   ;; models — conflating them is what made the encrypted sync a no-op before):
   ;;
   ;;   sync-credentials / list-credential-backups  — the CLIENT's zero-knowledge
   ;;     backup. The browser seals its full credential view under a bran-derived
   ;;     key before it ever reaches the wire (hoot/repl.scm encrypt-blob), so
   ;;     `data` here is opaque ciphertext this gateway cannot read. This is the
   ;;     restore-of-record on a fresh device — do-keri-fetch-credentials! reads
   ;;     it back and decrypt-blobs it client-side.
   ;;
   ;;   list-credentials (below) — this gateway's OWN operational holdings
   ;;     (acdc-store 'by-holder): the credentials it issued or witnesses and
   ;;     must read in the clear to run governance (personhood gate, delegation
   ;;     tally). Those sit plaintext in acdc-store's #:durable-dir. Encrypting
   ;;     that operational store at rest is a real, separate hardening — but the
   ;;     gateway has to decrypt it on every governance read, and this box has no
   ;;     FDE and boots unattended (nowhere to hold the key that a cold-disk
   ;;     thief couldn't also reach), so it is deliberately deferred, not faked
   ;;     with redundant crypto. The off-box snapshots ARE age-encrypted, so a
   ;;     stolen backup stays sealed; a stolen live disk does not. That residual
   ;;     is the gateway's own issued creds, not the client's aggregate view —
   ;;     the latter is protected by the zero-knowledge blob above.
   ((sync-credentials data)
    (catch #t
      (lambda () (%write-user-data! (credentials-file-for aid-prefix) data) 'ok)
      (lambda (k . a) (list 'error (format #f "credentials: ~a ~a" k a)))))
   ((list-credential-backups)
    (catch #t
      (lambda () (%read-user-data (credentials-file-for aid-prefix)))
      (lambda _ '())))

   ;; Live credential push — browser registers a watcher ref that
   ;; receives on-credential messages when the notification poller
   ;; admits a new credential for this AID. Replaces polling with
   ;; delta-only push after the initial list-credentials pull.
   ((watch-credentials watcher-ref)
    (register-credential-watcher! aid-prefix watcher-ref)
    'ok)

   ((unwatch-credentials watcher-ref)
    (unregister-credential-watcher! aid-prefix watcher-ref)
    'ok)

   ;; Shamir share storage — browser splits the bran and sends shares
   ;; here for safekeeping. Each share is addressed to a contact's AID.
   ;; Recovery: browser collects k shares from contacts and reconstructs.
   ((store-shamir-shares source-aid threshold shares)
    (catch #t
      (lambda ()
        (%write-user-data!
         (%user-file "shamir" aid-prefix)
         `((source . ,source-aid)
           (threshold . ,threshold)
           (shares . ,shares)))
        'ok)
      (lambda (k . a) (list 'error (format #f "shamir: ~a ~a" k a)))))

   ((get-shamir-shares)
    (catch #t
      (lambda () (%read-user-data (%user-file "shamir" aid-prefix)))
      (lambda _ '())))

   ;; ── the AI the commons pays for, from this seat ────────────────────
   ((transcribe audio-b64)
    (ai-door 'transcribe (lambda () (<- ai-svc 'transcribe audio-b64))))
   ((express nl-text)
    (ai-door 'express (lambda () (<- ai-svc 'express nl-text))))
   ;; MODEL is a string or #f; the service runs an enclave slug as named and
   ;; anything else as its default.
   ((ai-complete system-prompt user-prompt model)
    (ai-door 'ai-complete
             (lambda () (<- ai-svc 'complete system-prompt user-prompt model))))

   ;; ── a picture, read (docs/observation/capture.md §9) ───────────────
   ;; One part of one picture of an upload. UPLOAD is the browser's own name
   ;; for the sending, INDEX which picture of it (several pictures of one
   ;; thing are one read), PART a run of its base64. Replies the characters
   ;; held, or an error when a part or the whole is over its bound.
   ((see-part upload index part)
    (cond
     ((not (and (string? upload) (not (string-null? upload)))) (cons 'error "a picture is sent under a name"))
     ((not (and (integer? index) (< -1 index %pictures-per-read)))
      (cons 'error (format #f "a read takes ~a pictures at the most" %pictures-per-read)))
     ((not (and (string? part) (not (string-null? part)))) (cons 'error "an empty part"))
     ((> (string-length part) %part-chars) (cons 'error "a part is sixteen kilobytes at the most"))
     ((> (+ (pictures-chars) (string-length part)) %picture-max-chars)
      (set! pictures '())
      (cons 'error "the pictures are too large to read; take them smaller"))
     (else (cons 'ok (picture-part! upload index part)))))

   ;; Read the pictures sent under UPLOAD. A read that fulfils a count the
   ;; plan asked of this person (SCOPE-ID, FULFILLS) draws on the plan; any
   ;; other spends one of the week's reads, given back when the model gives
   ;; no answer. Replies the model's text; "" when pictures cannot be read
   ;; here; "err:…" in words the sheet can show.
   ((see upload system-prompt user-prompt #:optional (scope-id #f) (fulfills #f))
    (let* ((images (take-pictures! upload))
           (read (lambda () (<- ai-svc 'see system-prompt user-prompt images)))
           (unplanned
            (lambda ()
              (if (not (allotment-spend!))
                  "err:the week's photo reads are spent; say or type the figure"
                  (on (read)
                      (lambda (text)
                        (when (or (not (string? text)) (string-null? text)) (allotment-refund!))
                        (if (string? text) text ""))
                      #:catch (lambda _ (allotment-refund!) "")
                      #:promise? #t)))))
      (cond
       ((not ai-svc) "")
       ((not images) "err:no picture arrived")
       ((not (ai-call-allowed? 'see)) "")
       ((and planner-service (string-or-false scope-id) (string-or-false fulfills))
        (on (<- planner-service 'count-commitment-of (string-or-false scope-id) aid-prefix (string-or-false fulfills))
            (lambda (r)
              (if (and (pair? r) (eq? (car r) 'ok) (cdr r))
                  (read)
                  (unplanned)))
            #:catch (lambda _ (unplanned))
            #:promise? #t))
       (else (unplanned)))))

   ;; ── a counter's picture, attached to the contest of their count ─────
   ;; (docs/observation/capture.md §8). The count names the picture by hash;
   ;; the contest's franchise reads it when it votes. Governance says who may
   ;; attach (the counter whose act it is) and who may read (the franchise),
   ;; and which hash the count names; the gateway holds the picture until the
   ;; ballot settles.
   ((evidence-part ballot-id hash part-no parts part)
    (cond
     ((not (evidence-hash? hash)) (cons 'error "name the picture by its sha256 hash"))
     ((not (and (integer? parts) (<= 1 parts %evidence-max-parts)))
      (cons 'error (format #f "a picture is ~a parts at the most" %evidence-max-parts)))
     ((not (and (integer? part-no) (<= 0 part-no (- parts 1)))) (cons 'error "no such part"))
     ((not (and (string? part) (not (string-null? part)))) (cons 'error "an empty part"))
     ((> (string-length part) %part-chars) (cons 'error "a part is sixteen kilobytes at the most"))
     (else
      (with-contest-terms ballot-id "a picture is attached to a contest" "this contest takes no picture"
        (lambda (t)
          (cond
           ((not (eq? 'attach (assq-ref t 'role))) (cons 'error "only the counter attaches the picture"))
           ((not (equal? hash (assq-ref t 'hash))) (cons 'error "that is not the picture the count names"))
           (else (evidence-take! ballot-id hash part-no parts part))))))))

   ;; One part of the picture held for a contest, to the counter and the
   ;; franchise: the part, how many there are, and the hash it is held under.
   ((evidence-chunk ballot-id part-no)
    (with-contest-terms ballot-id "a picture is held for a contest" "this contest shows no picture"
      (lambda (t)
        (let ((held (held-evidence (%data-dir) ballot-id)))
          (cond
           ((or (not held) (not (equal? (car held) (assq-ref t 'hash))))
            (cons 'error "no picture is held for this contest"))
           (else
            (let ((part (evidence-part-of (cdr held) part-no)))
              (if part
                  (cons 'ok `((part . ,part) (total . ,(evidence-parts-total (cdr held))) (hash . ,(car held))))
                  (cons 'error "no such part")))))))))

   ;; The contests open in a scope, as they stand to this seat: what each names,
   ;; whose act it is, and whether this seat attaches a picture, votes, or neither.
   ((contests scope-id)
    (<- governance-svc 'contests aid-prefix scope-id))

   ;; The week's unplanned photo reads: how many remain, of how many, and
   ;; when the week opens again; and whether a picture can be read here.
   ((allotment)
    (on (if ai-svc (<- ai-svc 'sees?) #f)
        allotment-answer
        #:catch (lambda _ (allotment-answer #f))
        #:promise? #t))

   ;; ── devices: the keys the root lets sign as this AID ───────────────
   ((tier) tier)
   ;; WIRE-JSON is the device-authorization credential the browser built
   ;; (compute-said over the claims) and signed with the KEL key — this
   ;; session's own, so only a root session may present one. Verified
   ;; against the current key, then recorded; from here the device
   ;; authenticates and signs on its own.
   ((enroll-device wire-json)
    (root-only "authorizing a device"
      (lambda ()
        (let* ((cred (and (string? wire-json) (device-wire->cred wire-json)))
               (root-key (or (and oobi-host ($ oobi-host 'current-key aid-prefix))
                             aid-prefix)))
          (cond
           ((not cred) (list 'error "malformed device authorization"))
           (else
            (let ((v (device-credential-verdict cred aid-prefix root-key)))
              (if (eq? v #t)
                  (begin (device-enroll! aid-prefix cred (instant->unix (clock-now)))
                         (format (current-error-port)
                                 "[lobby-session] device enrolled for ~a\n" (aid-tag aid-prefix))
                         'ok)
                  (list 'error v)))))))))
   ((my-devices)
    (map device-entry->wire-alist (devices-of aid-prefix)))
   ;; Any session of the person retires a device — a lost phone is revoked
   ;; from the laptop, and a device signs itself out. The registry is the
   ;; authority the signer-keys resolver reads on every verification.
   ((revoke-device said)
    (if (and (string? said) (device-revoke! aid-prefix said (instant->unix (clock-now))))
        'ok
        (list 'error "no such device")))

   ;; Rotation — bound to this session's AID. Caller can't rotate
   ;; someone else through this cap. Root-only: a device key cannot
   ;; author a rotation (it is not in the bran's chain).
   ((rotate-aid rot-alist-raw sigs)
    (root-only "rotating the identity" (lambda ()
    (catch #t
      (lambda ()
        (let ((rot-alist (normalize-vecs rot-alist-raw))
              (entry (and oobi-host ($ oobi-host 'get aid-prefix))))
          (cond
           ((not oobi-host)
            (list 'error "no oobi-host configured"))
           ((not entry)
            (list 'error (string-append "AID not registered: " aid-prefix)))
           (else
            (let ((verdict (verify-rotation-event
                            aid-prefix entry rot-alist sigs)))
              (cond
               ((eq? verdict #t)
                ($ oobi-host 'append-rotation! aid-prefix rot-alist sigs)
                (format (current-error-port)
                        "[lobby-session] rotation accepted for ~a (sn=~a)\n"
                        (aid-tag aid-prefix) (assoc-ref rot-alist "s"))
                'ok)
               (else (list 'error verdict))))))))
      (lambda (key . args)
        (list 'error (format #f "rotation error: ~a ~a" key args)))))))

   ;; Relay-announce — bound to this session's AID. The browser builds
   ;; and SIGNS the announce packet (rns-wasm packAnnounce; the persona
   ;; identity key never leaves the browser); we verify it against the
   ;; AID's KEL-anchored reticulum pubkey (anchor = verification root)
   ;; and only then forward the bytes to the bridge via the netlayer's
   ;; announce-raw!. Without the verification gate, any session could
   ;; announce arbitrary destinations under this gateway's transport.
   ((relay-announce! packet-hex)
    (catch #t
      (lambda ()
        (let ((announcer (current-mesh-announcer))
              (pub       (anchored-mesh-pub)))
          (cond
           ((not announcer)
            (list 'error "mesh announcer not configured (no reticulum netlayer)"))
           ((not (string? packet-hex))
            (list 'error "packet must be a hex string"))
           ((not pub)
            (list 'error "no KEL-anchored reticulum pubkey for this AID"))
           ((not (mesh-send-allowed?))
            (list 'error "mesh send budget exhausted — try again shortly"))
           (else
            (let ((v (verify-announce-packet (hex->bv packet-hex) pub)))
              (if (eq? v #t)
                  (let ((dest-hex (announce-dest-hex packet-hex)))
                    ;; Register the (ownership-verified) destination so
                    ;; the transport delivers inbound packets for it —
                    ;; they land in ^mesh-mailbox via the gateway's
                    ;; SUBSCRIBE connection.
                    (<- announcer 'register-dest! dest-hex)
                    (<- announcer 'announce-raw! packet-hex)
                    (format (current-error-port)
                            "[lobby-session] relay-announce ~a for ~a\n"
                            dest-hex aid-prefix)
                    'ok)
                  (list 'error (if (string? v) v "invalid announce packet"))))))))
      (lambda (key . args)
        (list 'error (format #f "relay-announce error: ~a ~a" key args)))))

   ;; Transmit a browser-composed mesh DATA packet (LXMF mail: signed
   ;; and encrypted in the browser — the gateway never sees plaintext).
   ;; The gate is the packet TYPE: only DATA passes, so this method
   ;; cannot be used to smuggle an unverified announce past
   ;; relay-announce!'s ownership check. Authenticated-session-bound;
   ;; rate limiting is future work.
   ((send-mesh-packet! packet-hex)
    (catch #t
      (lambda ()
        (let ((announcer (current-mesh-announcer)))
          (cond
           ((not announcer)
            (list 'error "mesh not configured (no reticulum netlayer)"))
           ((not (string? packet-hex))
            (list 'error "packet must be a hex string"))
           ((not (data-packet? (hex->bv packet-hex)))
            (list 'error "only DATA packets may be sent through this method"))
           ((not (mesh-send-allowed?))
            (list 'error "mesh send budget exhausted — try again shortly"))
           (else
            (<- announcer 'send-raw! packet-hex)
            'ok))))
      (lambda (key . args)
        (list 'error (format #f "send-mesh-packet error: ~a ~a" key args)))))

   ;; Drain this persona's mesh mailbox. The destinations are DERIVED
   ;; from the session AID's KEL-anchored pubkey (anchored-destinations
   ;; — every scheme the binding model covers), so a session can only
   ;; ever name destinations it owns; no dest parameter rides the wire.
   ;; Returns ((dest-hex . #(payload-hex …)) …); payloads are ciphertext
   ;; only the browser-held identity can decrypt.
   ((drain-mesh-mailbox)
    (catch #t
      (lambda ()
        (let ((mailbox (current-mesh-mailbox))
              (pub     (anchored-mesh-pub)))
          (if (not (and mailbox pub))
              '()
              (filter (lambda (p) (positive? (vector-length (cdr p))))
                      (map (lambda (sd)
                             (let ((dest (cdr sd)))
                               (cons dest
                                     (list->vector ($ mailbox 'drain! dest)))))
                           (anchored-destinations pub))))))
      (lambda (key . args)
        (format (current-error-port)
                "[lobby-session] drain-mesh-mailbox error: ~a ~a\n" key args)
        '())))

   ;; Credentials issued to THIS AID. The filter is intrinsic — the
   ;; caller can't ask for a different AID's credentials through this
   ;; cap.
   ((list-credentials)
    (if acdc-store
        (<- acdc-store 'by-holder aid-prefix)
        '()))

   ;; Issue an ACDC. The full credential alist is constructed + signed by
   ;; the browser (browser has the signing keypair). What lobby.scm can
   ;; check WITHOUT a round trip it checks here — the credential's own
   ;; `issuer` field must match this session's AID, so a caller can never
   ;; attribute issuance to someone else. Governor standing and the actual
   ;; store write are governance-svc's own capabilities (`governor?`,
   ;; `acdc-store`, both already closed over there), so the rest of the
   ;; act crosses to it in one call — the same division present-phc and
   ;; every socialize-* door already use. Replies the credential's SAID.
   ((issue-credential cred-alist-raw)
    (let* ((cred (normalize-vecs cred-alist-raw))
           (issuer (assq-ref cred 'issuer)))
      (if (not (equal? issuer aid-prefix))
          (list 'error
                (string-append "credential.issuer must match the caller's own AID: got "
                                (if (string? issuer) issuer "<not-a-string>")))
          (<- governance-svc 'issue-credential aid-prefix cred))))

   ;; Revoke an ACDC by SAID. No issuer check here — governance may revoke
   ;; ANY credential by policy, so the only gate is the caller's own
   ;; governor standing, checked (with the actual write) in governance-svc.
   ((revoke-credential said)
    (<- governance-svc 'revoke-credential aid-prefix said))

   ;; NOTE: open-terminal and get-mailbox stay on the public ^lobby
   ;; for now — they're consumed by the legacy inner-mode flow that
   ;; uses an org pubkey, not the KERI AID. When the terminal/mailbox
   ;; UX migrates onto the KERI identity, expose them here too.

   ;; Governance methods — the AID is closed over; callers passing
   ;; different identity-key values to these methods through the
   ;; public lobby would be lying. Here, the AID is the cap.
   ;; TARGET-IDS/SUBJECT translate to governance-svc's own internal REST
   ;; here: a ballot's rest is (subject), an expression's is
   ;; (target-ids [subject]) — the SAME positional slot means a different
   ;; thing per KIND on the far side, so the tag is built at this boundary.
   ((open kind domain id description franchise #:optional (target-ids #f) (subject #f))
    (apply <- governance-svc 'open aid-prefix kind domain id description franchise
           (case kind
             ((expression) (if subject (list target-ids subject) (list target-ids)))
             (else (if subject (list subject) '())))))

   ((cast id arg)
    (<- governance-svc 'cast aid-prefix id arg))

   ;; Client-side citizen signing. `stance-preimage` hands the client every
   ;; SAID field the SERVER is authoritative for; the client adds only its
   ;; position + timestamp, re-derives the SAID itself (so it is not
   ;; blind-signing), signs with its own KERI key, and returns the signature
   ;; via `cast-signed`. As with the other governance methods the AID is
   ;; closed over here, so a client cannot sign as anyone else.
   ((stance-preimage id position)
    (<- governance-svc 'stance-preimage aid-prefix id position))

   ;; U — the blinding nonce from the preimage's claims, echoed back so the
   ;; server rebuilds the exact credential the client signed. Variadic so an
   ;; old five-arg client gets a clean signature rejection instead of an
   ;; arity error; see the deploy-order note on `cast-signed` in service.scm.
   ((cast-signed id position timestamp signature u)
    ;; Resolve the caller's CURRENT signing key from the KEL and thread it to the
    ;; service as the verification key. ^oobi-host shares this vat, so the read is
    ;; synchronous (same resolution keri-authenticate does). A transferable
    ;; E-prefix AID does not encode its key in the prefix; without this the
    ;; service would verify the stance signature against the AID and always fail.
    ;; For a D/B-prefix AID (unrotated / not in oobi-host) current-key is #f and
    ;; the service falls back to the AID itself. VKEY is never a caller
    ;; argument — it is derived here, server-side, on every call.
    (let ((vkey (and oobi-host (string? aid-prefix)
                     ($ oobi-host 'current-key aid-prefix))))
      (<- governance-svc 'cast-signed
          aid-prefix id position timestamp signature u (or vkey aid-prefix))))

   ;; Producer voice over the plan: this AID's HAND of signed stances on parts
   ;; of SCOPE-ID's plan (docs/planning/voice/). HAND-JSON is a JSON object
   ;; {"part-string": portion, …}, portions in [−1, 1]. Same two legs as a
   ;; ballot stance: the preimage hands back the SAID fields, the signed leg
   ;; verifies against the KEL key resolved here, then the planner's voice
   ;; fold takes the scope's standing hands (data across the vat seam).
   ((part-stance-preimage scope-id hand-json)
    (<- governance-svc 'part-stance-preimage aid-prefix scope-id (hand-json->alist hand-json)))
   ((cast-part-signed scope-id hand-json timestamp signature u)
    (let ((vkey (and oobi-host (string? aid-prefix) ($ oobi-host 'current-key aid-prefix))))
      (on (<- governance-svc 'cast-part-signed
              aid-prefix scope-id (hand-json->alist hand-json) timestamp signature u (or vkey aid-prefix))
          (lambda (r)
            ;; the rail changed: the fold rereads it (no row travels)
            (when (and (eq? r 'ok) planner-service)
              (<- planner-service 'hands! scope-id))
            r)
          #:promise? #t)))
   ;; a scope's own word, spoken for it by a governor (this AID): where a
   ;; resource's pool stands, what the scope will host, what its domain's
   ;; statistics license — each a credential the solve reads where it lies
   ((declare-span scope-aid resource-id place #:optional (until #f))
    (<- governance-svc 'declare-span aid-prefix scope-aid resource-id place until))
   ;; a federation admits a commune, as one of its governors: the commune's AID
   ;; and the sturdyref its peer answers at; RATIFICATION (a SAID) is the
   ;; commune's consent when the federation requires one
   ((admit-commune federation-aid commune-aid sturdyref-uri #:optional (ratification #f))
    (<- governance-svc 'admit-commune aid-prefix federation-aid commune-aid sturdyref-uri ratification))
   ((declare-hosting scope-aid resource-spec ceiling #:optional (until #f))
    (<- governance-svc 'declare-hosting aid-prefix scope-aid resource-spec ceiling until))
   ((claim-regime scope-aid domain-spec tails process #:optional (until #f))
    (<- governance-svc 'claim-regime aid-prefix scope-aid domain-spec tails process until))

   ;; ── Temporary socialization — the AID is the closed-over session identity,
   ;; so owner is non-spoofable. `declare-means` seeds an owned resource into the
   ;; scope's observer (planner-vat); socialize-preimage/-signed issue the owner-
   ;; signed custody attestation (client-signing, like stance above); my-grants /
   ;; desocialize read + recall. commune-aid + scope-id come from the dial's
   ;; scope-list (a real scope, e.g. the whole commons).
   ;; OPTS: (arcs-json note emoji) — the slot's recurring time pattern +
   ;; prose + face, riding the resource's own fields (availability-window,
   ;; note, image). Same closed-over AID, so declarations are non-spoofable.
   ((declare-means scope-id spec qty unit location
                    #:optional (arcs-json #f) (note #f) (emoji #f) (name #f) (cats-json #f) (criteria-json #f))
    (planner! 'declare-means scope-id aid-prefix spec qty unit location arcs-json note emoji name cats-json criteria-json))
   ;; the need side of the same expression: a standing intent (see
   ;; planner-service declare-need). One surface, two rails.
   ((declare-need scope-id spec qty unit location arcs-json note emoji from until
                  #:optional (name #f) (cats-json #f) (criteria-json #f) (need-kind #f) (voice 0))
    (planner! 'declare-need scope-id aid-prefix spec qty unit location arcs-json note emoji from until name cats-json criteria-json need-kind voice))
   ;; what that need displaces at declaration time — a read off the scope's last
   ;; solve, shown in the ⚖️ editor before a kind and level are stated.
   ((need-displacement scope-id spec qty)
    (planner! 'need-displacement scope-id spec qty))
   ;; the burn-meter: the scope's accumulated externality display, one
   ;; snapshot per solve, summarized as its moved-distribution
   ((externality-history scope-id)
    (planner! 'externality-history scope-id))
   ;; the constitution's gate: the scope ratifies a spec's kind (floor | held),
   ;; recorded under this citizen's AID; the grants are what declare-need reads
   ((ratify-kind scope-id spec kind)
    (planner! 'ratify-kind scope-id aid-prefix spec kind))
   ((ratified-kinds scope-id)
    (planner! 'ratified-kinds scope-id))
   ;; stage 3: the audit of the scope's ratified kinds, and its record
   ((audit-kinds scope-id #:optional (options #f))
    (planner! 'audit-kinds scope-id aid-prefix options))
   ((audits scope-id)
    (planner! 'audits scope-id))
   ((my-slots scope-id)
    (planner! 'my-slots scope-id aid-prefix))
   ;; the fold's reading at SCOPE-ID — Our Needs / Our Offers — with this
   ;; citizen's own share joined from HOME-SCOPE-ID, where their leaf lives
   ((our-slots scope-id home-scope-id)
    (planner! 'our-slots scope-id home-scope-id aid-prefix))
   ((retire-need scope-id spec)
    (planner! 'retire-need scope-id aid-prefix spec))
   ;; the offer side's withdrawal: a `lower` to zero on the declared means —
   ;; the record and its event history stand, only the offer leaves
   ((retire-means scope-id spec)
    (planner! 'retire-means scope-id aid-prefix spec))
   ;; payouts — "send N XMR of my claim to ⟨address⟩". The member is the
   ;; session AID (non-spoofable); the runner in the gateway moves the coins
   ;; under the wallet policy. See planner/doors/service.scm request-payout.
   ((request-payout scope-id address xmr due note)
    (planner! 'request-payout scope-id aid-prefix acdc-store address xmr due note))
   ((my-payouts scope-id)
    (planner! 'my-payouts scope-id aid-prefix acdc-store))
   ((retire-payout scope-id id)
    (planner! 'retire-payout scope-id aid-prefix id))
   ((scope-readings scope-id spec)
    (planner! 'scope-readings scope-id spec))
   ((readings-between scope-id spec from until)
    (planner! 'readings-between scope-id spec from until))
   ((my-claims scope-id)
    (planner! 'my-claims scope-id aid-prefix))
   ;; purchases for the commons — the member is the session AID; the raise
   ;; lands immediately, and whether it fulfils a plan the commons already
   ;; committed to comes back as PLANNED? (informational). What the commons
   ;; then owes is minted as a debt through governance's own
   ;; accept-reimbursement (governance/scope.scm, a ^scope method — the
   ;; commune's own word, not this session's) and read back via my-payouts'
   ;; `owed` field (governance/debts.scm), paid as a payout.
   ((record-purchase scope-id spec qty unit money-spec cost where note receipt donation?)
    (planner! 'record-purchase scope-id aid-prefix spec qty unit money-spec cost where note receipt donation?))
   ;; ── skills: the citizen's own labour-power, self-declared ──
   ;; The closed-over AID is the agent, so a citizen declares and revokes
   ;; only their own skills — the same non-spoofability declare-means
   ;; states. The service side is the VF raise/lower pair over a skill
   ;; EconomicResource, and the scope's labour fold refolds on the write.
   ((declare-skill scope-id skill-spec-id)
    (planner! 'declare-skill scope-id aid-prefix skill-spec-id))
   ((revoke-skill scope-id skill-spec-id)
    (planner! 'revoke-skill scope-id aid-prefix skill-spec-id))
   ((my-skills scope-id)
    (planner! 'my-skills scope-id aid-prefix))
   ((my-skill-standing scope-id)
    (planner! 'skill-standing scope-id aid-prefix))
   ((observe-contrary-preimage scope-id process action spec nominal reading witness at)
    (<- governance-svc 'observe-contrary-preimage aid-prefix scope-id process action spec nominal reading witness at))
   ((observe-contrary-signed scope-id process action spec nominal reading witness at signature)
    (refolding-readings scope-id
      (<- governance-svc 'observe-contrary-signed aid-prefix scope-id process action spec nominal reading witness at signature)))
   ((observe-contrary scope-id process action spec nominal reading witness)
    (refolding-readings scope-id
      (<- governance-svc 'observe-contrary aid-prefix scope-id process action spec nominal reading witness)))
   ((contrary-observations scope-id)
    (<- governance-svc 'contrary-observations aid-prefix scope-id))
   ;; the scope's whole slot pool (every citizen's standing needs + the means
   ;; socialized into the commons as of the last solve) — the map's 🏠 source.
   ;; Scope-wide by design, so no AID: what stands in the commons is the
   ;; commons' to see; a merely declared private means never appears here.
   ((slots-at scope-id)
    (planner! 'slots-at scope-id))
   ;; the ring: the scope's needs scored against its declared means by
   ;; classification affinity. The folksonomy template is resolved HERE —
   ;; through the caller's optional lens name, exactly as folksonomy-template
   ;; does — and handed to the planner as a plain tree, so the planner-vat
   ;; scorer needs no folksonomy reference and "what matches" is read through
   ;; the same cut the caller's spine shows. No folksonomy yet → the empty
   ;; tree: the same-spec floor still matches.
   ;; the member's own profile: body and diet, as typed tags on their agent record
   ;; the family face: a purse split across stated needs by harmony. Scope-free
   ;; (the household is its own world) and AID-free (nothing is written).
   ;; MEMBERS-JSON, when given, is the household's own consumer voice (§The
   ;; credit identity, family-voice-of): each declared member's capacity to
   ;; labour and hours contributed this week — never required, an undeclared
   ;; ledger reads every owner as an equal citizen exactly as before.
   ((family-split needs-json purse labour-h weighted? #:optional (members-json "[]") (per-citizen-hours 40.0))
    (planner! 'family-split needs-json purse labour-h weighted? members-json per-citizen-hours))
   ;; the week asked backwards: the three bills (euros and hours beyond the purse).
   ((family-bills needs-json purse labour-h weighted? eur-per-hour #:optional (members-json "[]") (per-citizen-hours 40.0))
    (planner! 'family-bills needs-json purse labour-h weighted? eur-per-hour members-json per-citizen-hours))
   ;; its externality display: what each held/des ask moved from the others.
   ((family-externalities needs-json purse labour-h weighted?)
    (planner! 'family-externalities needs-json purse labour-h weighted?))
   ((match-slots scope-id #:optional (lens #f))
    (cond ((not planner-service) (list 'error "no planner service"))
          ((not folksonomy)
           (<- planner-service 'match-slots scope-id '()))
          (else
           (on (<- folksonomy 'template (lens-aids lens))
               (lambda (tree)
                 (<- planner-service 'match-slots scope-id tree))))))
   ;; ── live / expected position ────────────────────────────────────────────
   ;; Where the caller IS at PERIOD (0 = now; t > 0 = a declared future). The
   ;; planner reads it as their commute origin and as the cell their labour and
   ;; their reproduction floors sit in, so a citizen who moves moves what they
   ;; can reach AND what the plan brings to them. The AID is the closed-over
   ;; session identity, so a citizen positions only themselves.
   ;; `set-position-latlon` snaps raw coordinates to the scope's nearest known
   ;; place server-side and stores that place id — the coordinates go no
   ;; further, so sharing a position shares a place rather than a trace.
   ((set-position scope-id period place)
    (planner! 'set-position scope-id aid-prefix period place))
   ((set-position-latlon scope-id period lat lon)
    (planner! 'set-position-latlon scope-id aid-prefix period lat lon))
   ;; whether the caller shares where they are (live, here, off): stated once at
   ;; their home, read by every device; off ends the fix that stands
   ((set-location-sharing scope-id mode)
    (planner! 'set-location-sharing scope-id aid-prefix mode))
   ((location-sharing scope-id)
    (planner! 'location-sharing scope-id aid-prefix))
   ;; the citizen's registered home (planner-service set-home): the agent
   ;; record's primary location, the floor `agent-position` falls back to. A
   ;; known place id, or "" with coordinates for the citizen's own place:AID:home.
   ((set-home scope-id place lat lon)
    (planner! 'set-home scope-id aid-prefix place lat lon))
   ((declare-dwelling scope-id place area rooms warmth-winter warmth-summer beds attests-json certified rent tenure)
    (planner! 'declare-dwelling scope-id aid-prefix place area rooms warmth-winter warmth-summer beds attests-json certified rent tenure))
   ;; a new place, named by the citizen (planner-service declare-place):
   ;; a <spatial-thing> in the scope, id place:AID:slug — the closed-over
   ;; AID names it, so a place is its namer's to re-place. OPTS: (address) —
   ;; free-association's Specific tab (street/city/state/postal/country)
   ;; collapsed to the one string <spatial-thing> already carries.
   ((declare-place scope-id name lat lon #:optional (address #f) (parent #f))
    (planner! 'declare-place scope-id aid-prefix name lat lon address parent))
   ;; The schedule of counts: every target with its cadence, soonest due first.
   ((count-schedule scope-id #:optional (regime #f))
    (planner! 'count-schedule scope-id regime))
   ;; Lays the counts that are due as directed work offers.
   ((plan-counts scope-id #:optional (regime #f) (counter #f) (at-most #f))
    (planner! 'plan-counts scope-id aid-prefix regime counter at-most))
   ;; The scope as this person's device holds it, as one text.
   ((scope-replica scope-id)
    (planner! 'scope-replica scope-id aid-prefix))
   ;; The counts of one stock, newest first, as a member reads them to contest one.
   ((count-history scope-id resource-id #:optional (limit #f))
    (planner! 'count-history scope-id aid-prefix resource-id limit))
   ;; The code a stock is known by, for its label.
   ((label-stock scope-id resource-id)
    (planner! 'label-stock scope-id aid-prefix resource-id))
   ;; What a label's code names: the thing, where it is, what is in it.
   ((read-label scope-id code)
    (planner! 'read-label scope-id aid-prefix code))
   ;; ELIGIBLE: the owner's steward rule, forwarded verbatim
   ((socialize-preimage commune-aid spec qty until movable rt cf res kind ref #:optional (eligible #f))
    (<- governance-svc 'socialize-preimage aid-prefix commune-aid spec qty until movable rt cf res kind ref eligible))
   ;; a grant landing or leaving moves the scope's pool: the planner's
   ;; slots-at reads the store live, and its watchers (the map) hear the
   ;; move through slots-changed! once the governance write settles.
   ((socialize-signed commune-aid spec qty until movable rt cf res kind ref signature #:optional (eligible #f))
    (pool-moved commune-aid
      (<- governance-svc 'socialize-signed aid-prefix commune-aid spec qty until movable rt cf res kind ref signature eligible)))
   ((my-grants) (<- governance-svc 'my-grants aid-prefix))
   ((desocialize said)
    (pool-moved (grant-scope-of said) (<- governance-svc 'desocialize aid-prefix said)))
   ;; ── purchase claims: the member's own signed word, the reimbursement
   ;; primary — the exact twin of socialize-preimage/-signed above.
   ((purchase-claim-preimage commune-aid spec qty unit due res ref trig)
    (<- governance-svc 'purchase-claim-preimage aid-prefix commune-aid spec qty unit due res ref trig))
   ((purchase-claim-signed commune-aid spec qty unit due res ref trig signature)
    (<- governance-svc 'purchase-claim-signed aid-prefix commune-aid spec qty unit due res ref trig signature))
   ;; ── accepting a grant or a reimbursement — the commune's own word.
   ;; See governance/service.scm's own accept-socialization/accept-reimbursement
   ;; for the real, stated security gap: no governor-role gate exists live
   ;; anywhere yet, so this is open to any authenticated member, not just
   ;; governors — self-accepting one's own reimbursement is the one thing
   ;; actually refused.
   ((accept-socialization commune-aid grant-said)
    (pool-moved commune-aid
      (<- governance-svc 'accept-socialization aid-prefix commune-aid grant-said)))
   ((accept-reimbursement commune-aid claim-said)
    (<- governance-svc 'accept-reimbursement aid-prefix commune-aid claim-said))
   ;; ── ownership: title over one declared means, client-signed ──
   ;; The rights-side twin of the socialize legs — issuer = holder = the
   ;; session AID, so a citizen titles only what they declare as their own.
   ((own-means-preimage resource-id spec qty qty-unit ref)
    (<- governance-svc 'own-means-preimage aid-prefix resource-id spec qty qty-unit ref))
   ((own-means-signed resource-id spec qty qty-unit ref signature)
    (<- governance-svc 'own-means-signed aid-prefix resource-id spec qty qty-unit ref signature))
   ((my-titles) (<- governance-svc 'my-titles aid-prefix))
   ((disown-means said) (<- governance-svc 'disown-means aid-prefix said))

   ;; Client-signed delegation — same two-step (preimage → sign → signed
   ;; write) as the stance path; AID closed over so a citizen can only
   ;; delegate their own voice.
   ;; SCOPE-ID names this delegation's franchise — federation-wide when
   ;; absent, or scoped to that commune. governance-svc's own arm still
   ;; reads it as REST — () or ('scope SID) — so the tag is built here, at
   ;; the boundary, and never crosses to a caller.
   ((delegation-preimage delegate-aid fraction #:optional (scope-id #f))
    (apply <- governance-svc 'delegation-preimage aid-prefix
           delegate-aid fraction (franchise-rest scope-id)))

   ((set-delegation-signed delegate-aid fraction signature #:optional (scope-id #f))
    (apply <- governance-svc 'set-delegation-signed aid-prefix
           delegate-aid fraction signature (franchise-rest scope-id)))

   ((close id)
    (<- governance-svc 'close aid-prefix id))

   ;; ── contesting work: the record says it happened, a member says it did not ──
   ;; Opens the ballot the scope settles at its close; the caller's own AID is
   ;; the contester, so a worker can never open one on their own record.
   ((contest-work scope-id event-id reason)
    (<- governance-svc 'contest-work aid-prefix scope-id event-id reason))

   ;; Governance READS — the decision inbox + tallies. The mutating
   ;; open/cast/close above let the dial act; these let it SHOW the open
   ;; decisions and their live/closed results (governance-surface.md §Inbox).
   ((list-proposals)
    (<- governance-svc 'list-proposals))

   ((get-result id)
    (<- governance-svc 'get-result id))

   ((list-delegations)
    (<- governance-svc 'list-delegations aid-prefix))

   ((my-voice)
    (<- governance-svc 'my-voice aid-prefix))

   ;; your producer voice in ONE commune — the voice map's cell
   ((voice-in scope-id)
    (<- governance-svc 'voice-in aid-prefix scope-id))

   ((list-uc-proposals)
    (<- governance-svc 'list-uc-proposals))

   ((set-delegation delegate-aid fraction #:optional (scope-id #f))
    (apply <- governance-svc 'set-delegation aid-prefix delegate-aid fraction
           (franchise-rest scope-id)))

   ;; Mandated delegation, client-signed: the citizen sends a mandate SPEC
   ;; (data, e.g. '(equal-position yes)), gets the credential preimage, signs
   ;; the SAID, then commits via set-delegation-mandated-signed.
   ((delegation-mandated-preimage delegate-aid fraction mandate-spec #:optional (scope-id #f))
    (apply <- governance-svc 'delegation-mandated-preimage aid-prefix
           delegate-aid fraction mandate-spec (franchise-rest scope-id)))

   ((set-delegation-mandated-signed delegate-aid fraction mandate-spec signature #:optional (scope-id #f))
    (apply <- governance-svc 'set-delegation-mandated-signed aid-prefix
           delegate-aid fraction mandate-spec signature (franchise-rest scope-id)))

   ((revoke-delegation delegate-aid #:optional (scope-id #f))
    (apply <- governance-svc 'revoke-delegation aid-prefix delegate-aid
           (franchise-rest scope-id)))

   ;; ── planner doors that act AS this AID ─────────────────────────────
   ;; These planner doors name the acting agent as an argument. Over the
   ;; session the AID is closed over — the caller cannot act as anyone
   ;; else — and the planner facet the anonymous lobby hands out does not
   ;; carry them (declared `operator` on the planner side).
   ;; Opens the witness ceremony over a recorded event as this AID; replies the statement said.
   ((witness-open scope-id event-id)
    (planner! 'witness-open scope-id aid-prefix event-id))
   ;; The context rows this AID may co-sign; replies those requests.
   ((witness-inbox scope-id)
    (planner! 'witness-inbox scope-id aid-prefix))
   ;; Lands this AID's co-signature on a ceremony's statement; replies attested, finalized, or a failure.
   ((witness-attest scope-id said sig)
    (planner! 'witness-attest scope-id aid-prefix said sig))
   ;; Records this AID's ride commitment and its pickup event at departure; replies the new commitment id.
   ((journey-begin scope-id from-place to-place mode)
    (planner! 'journey-begin scope-id aid-prefix from-place to-place mode))
   ;; Records the dropoff event that fulfills this AID's ride commitment; replies that commitment id.
   ((journey-end scope-id commitment-id from-place to-place mode)
    (planner! 'journey-end scope-id aid-prefix commitment-id from-place to-place mode))
   ;; Posts a line to scope/topic as this AID; replies the stored row.
   ((chat-post scope-id topic body #:optional (message-kind #f))
    (planner! 'chat-post scope-id topic aid-prefix body message-kind))
   ;; Accepts a suggested intent as this AID (steward-gated) and re-plans the scope.
   ((accept-assignment scope-id intent-id)
    (planner! 'accept-assignment scope-id intent-id aid-prefix))
   ;; Declines a suggested intent as this AID.
   ((decline-assignment scope-id intent-id)
    (planner! 'decline-assignment scope-id intent-id aid-prefix))
   ;; Marks this AID willing (or withdraws it) for skill@cell with an optional hours budget; binds nothing.
   ((express-willingness scope-id skill cell willing? #:optional (hours #f))
    (planner! 'express-willingness scope-id aid-prefix skill cell willing? hours))
   ;; Draws this AID's credit to claim a resource, checked against on-hand and any live wallet reading; replies the balance.
   ((claim scope-id resource-id qty labor-cost #:optional (where #f) (deliver-at #f))
    (planner! 'claim scope-id resource-id qty aid-prefix labor-cost where deliver-at))
   ;; Records QTY of this AID's effort against a commitment.
   ((record-effort scope-id commitment-id qty unit)
    (planner! 'record-effort scope-id commitment-id aid-prefix qty unit))
   ;; Records this AID's spoken log entry as its suggested event, with note and narrated time.
   ((log-observe scope-id action spec qty unit note when-iso)
    (planner! 'log-observe scope-id aid-prefix action spec qty unit note when-iso))
   ;; Records this AID's count of a stock: the difference from the ledger lands on that stock.
   ((count-stock scope-id resource-id counted unit
                 #:optional (technique #f) (place #f) (when-iso #f)
                            (fulfills #f) (evidence #f) (note #f))
    (planner! 'count-stock scope-id aid-prefix resource-id counted unit
              technique place when-iso fulfills evidence note))
   ;; Upserts this AID's profile tags from a JSON array, keeping other classifications; replies the tags.
   ((set-profile scope-id json)
    (planner! 'set-profile scope-id aid-prefix json))
   ;; Upserts this AID's availability window from the dial's arcs JSON.
   ((set-availability-ranges scope-id json)
    (planner! 'set-availability-ranges scope-id aid-prefix json))
   ;; Creates a social use-intent and a proposal from this AID to the invitee; replies the proposal id.
   ((invite-contact scope-id invitee label t0-iso t1-iso)
    (planner! 'invite-contact scope-id aid-prefix invitee label t0-iso t1-iso))
   ;; Accepts a directed social invite as this AID, promoting the intent to a commitment.
   ((accept-invite scope-id proposal-id)
    (planner! 'accept-invite scope-id aid-prefix proposal-id))
   ;; Accepts a work offer with this AID as provider and the scope as receiver, then re-plans the scope.
   ((accept-work-offer scope-id proposal-id)
    (planner! 'accept-work-offer scope-id aid-prefix proposal-id)))))

;;; ── ^planner-facet ───────────────────────────────────────────────────────────
;;;
;;; What the anonymous lobby hands out when asked for the planner: a facet
;;; that forwards the doors a browser uses and answers every other message
;;; with an error. The planner-service itself has no per-method access
;;; check (docs/planning/audits/protocol-inventory-2026-09-12.md §1c), so the raw
;;; capability lets any connection settle payouts, add scopes or move the
;;; solve vat. The facet is the allowlist; the Phase B1 declaration turns it
;;; into a per-door auth level.
;;;
;;; The list is the declaration's: every planner door (playnet protocol)
;;; marks `anonymous`. Opening a door to the browser is one edit there, and
;;; tools/protocol-lint.scm keeps the declaration and the code's heads in
;;; step.

(define %planner-public-doors
  (map door-name
       (filter (lambda (d) (and (eq? (door-object d) 'planner)
                                (eq? (door-auth d) 'anonymous)))
               %doors)))

(define (^planner-facet _bcom planner)
  (lambda (method . args)
    (if (memq method %planner-public-doors)
        (apply <- planner method args)
        (list 'error (format #f "planner: ~a is not a public door" method)))))

;;; ── the ICE servers a call may use ──────────────────────────────────────────
;;; The gateway is the one place that says which servers peers find each other
;;; through; the browser asks the `ice-servers` door when it joins a room and
;;; carries no address of its own. A server is an alist: "urls" always, and
;;; "username" and "credential" when the server wants them (a TURN relay).

(define %default-ice-urls "stun:stun.l.google.com:19302")

(define (ice-servers-from-urls str)
  "STR, a comma-separated list of ICE urls (PLAYNET_ICE_URLS), as the door's
   list of servers. Blank entries drop out; an empty STR is no servers."
  (filter-map (lambda (u)
                (let ((u (string-trim-both u)))
                  (and (not (string-null? u)) `(("urls" . ,u)))))
              (string-split (or str "") #\,)))

;;; ── ^lobby ───────────────────────────────────────────────────────────────────

(define* (^lobby _bcom signup-agent ai-svc
                 presence terminal-svc mailbox-mgr planner-service
                 wallet-policy governance-svc
                 #:optional (oobi-host #f) (acdc-store #f)
                            (push-store #f) (vapid-pub-b64 #f)
                            (folksonomy #f) (recipient-registry #f)
                            (corpus-svc #f) (pins #f)
                            (ice-list #f) (contact-desk #f))
  ;; pending-challenges: hashmap of nonce → (aid-prefix . timestamp)
  ;; Checked on keri-authenticate, expired entries pruned lazily.
  (let ((pending-challenges (hashmap))
        (planner-facet (and planner-service (spawn ^planner-facet planner-service))))

    ;; The shared gate for open-terminal/get-mailbox below: a live
    ;; personhood credential (PHC) for IDENTITY-KEY, in ANY ecosystem
    ;; this store holds (holds-any-live-phc? — personhood travels with
    ;; the person, portable the same way accept-socialization/may-
    ;; govern? already treat it). A legacy org-pubkey identity-key never
    ;; holds a PHC, so that path is refused here exactly as before the
    ;; gate existed. Calls ON-SUCCESS (a thunk) only once both checks pass.
    (define (member-gated identity-key on-success)
      (cond
       ((not acdc-store) (list 'error "acdc-store not configured on this gateway"))
       ((not (holds-any-live-phc? acdc-store identity-key))
        (list 'error "not a registered member — credential required"))
       (else (on-success))))

    ;; The account-creation feature, on or off: a GDPR-deferral switch, not
    ;; a capability gap. PLAYNET_DISABLE_REAL_SIGNUP turns new real-identity
    ;; signups off; unset (the default) leaves them on, matching every
    ;; deploy before this flag existed. See docs/planning/legal/gdpr-
    ;; analysis.md and deploy/os.scm's gateway-service environment for why
    ;; production sets it and dev does not. The doors it gates are the ones
    ;; declared `#:feature account-creation` in protocol.scm — the same
    ;; declaration the product's law reads them off (`doors-of-feature`);
    ;; tests/keri/test-signup-disabled-gate.scm holds the wrappers below to
    ;; exactly that set, so neither can drift from the other.
    (define (real-signup-enabled?)
      (not (env-flag? "PLAYNET_DISABLE_REAL_SIGNUP")))

    (define (signup-gated thunk)
      (if (real-signup-enabled?)
          (thunk)
          (list 'error "real account creation is temporarily disabled on this gateway")))

    (declared-methods lobby

     ;; ── Account registration (KERI) ───────────────────────────────────────
     ;; Legacy path: user provides AID prefix + OOBI URL hosted elsewhere.
     ;; Server resolves OOBI via KERIA (witness-verified), then persists.
     ((signup username email aid-prefix oobi-url)
      (signup-gated (lambda ()
        (<- signup-agent 'register! username email aid-prefix oobi-url))))

     ;; Browser-resident-Signify path: the user creates the AID locally
     ;; and ships the inception event + signatures. The server verifies
     ;; them offline (no KERIA round-trip) and stores the ICP in
     ;; ^oobi-host. Per (playnet gateway signup-agent) verify-self-signed-icp,
     ;; we check (i) AID matches icp.k[0], (ii) recomputed SAID matches
     ;; icp.d, (iii) sigs[0] verifies under the AID's pubkey.
     ;; Returns 'ok or (list 'error "reason").
     ((signup-with-icp username email aid-prefix icp-alist sigs)
      (signup-gated (lambda ()
        (<- signup-agent 'register-with-icp!
            username email aid-prefix icp-alist sigs oobi-host))))

     ;; The controller brings its whole KEL — icp, sigs, and ROTATIONS
     ;; (a vector of (rot . sigs) in sn order) — and takes a seat here
     ;; under its existing, possibly rotated, key state. This is the
     ;; door an identity walks through when it arrives at a commune
     ;; that has never seen it: the KEL is the controller's own signed
     ;; log, verified end to end by signup-agent. A KEL with no
     ;; rotations is signup-with-icp.
     ((signup-with-kel username email aid-prefix icp-alist sigs rotations)
      (signup-gated (lambda ()
        (<- signup-agent 'register-with-kel!
            username email aid-prefix icp-alist sigs rotations oobi-host))))

     ;; The controller's log has moved on elsewhere and this commune is
     ;; behind: ROTATIONS (a vector of (rot . sigs), sn order, continuing
     ;; from this commune's last event) catch it up. Public, like
     ;; fetch-icp — a rotation proves its own authorship, so possession
     ;; of a verifiable one is the only authority that matters, and the
     ;; session that would otherwise gate it is exactly what a stale
     ;; copy of the log cannot grant.
     ((extend-kel aid-prefix rotations)
      (<- signup-agent 'register-rotations! aid-prefix rotations
          (and oobi-host (string? aid-prefix) ($ oobi-host 'get aid-prefix))
          oobi-host))

     ;; ── witnessing and seating, apart ──
     ;; witness-kel: the log into ^oobi-host on its own terms — any
     ;; verifiable KEL from anyone who forwards it; no username, no seat.
     ;; Levels a known AID up (rotations beyond the held depth), refuses
     ;; a different history under one AID. Public, like fetch-icp.
     ((witness-kel aid-prefix icp-alist sigs rotations)
      (<- signup-agent 'witness-kel! aid-prefix icp-alist sigs rotations
          (and oobi-host (string? aid-prefix) ($ oobi-host 'get aid-prefix))
          oobi-host))
     ;; join: a seat in this gateway's universal commune for an AID
     ;; already witnessed here. The seat is what keri-authenticate checks
     ;; for; scope standing below the UC is a governance act, not this.
     ((join username email aid-prefix)
      (signup-gated (lambda ()
        (<- signup-agent 'join! username email aid-prefix
            (and oobi-host (string? aid-prefix)
                 ($ oobi-host 'get aid-prefix) #t)))))
     ((has-seat aid-prefix)
      (<- signup-agent 'has-seat? aid-prefix))

     ;; Follow-up to signup-with-icp: the browser endorses its OKEA
     ;; endpoint replies (/end/role/add + /loc/scheme, framed CESR
     ;; strings) with the AID's own key and ships them here, so the
     ;; served OOBI advertises WHERE the AID is, not just WHO
     ;; (OOBI §3.4). Validation (sig under the AID's pubkey, route
     ;; whitelist) happens in signup-agent.
     ;; We read the AID's current signing key here (^lobby shares
     ;; gateway-vat with ^oobi-host, so the `$` read is synchronous)
     ;; and pass it along — signup-agent lives in another vat and
     ;; must not read oobi-host itself.
     ((register-oobi-replies aid-prefix replies)
      (<- signup-agent 'register-oobi-replies!
          aid-prefix
          (and oobi-host (string? aid-prefix)
               ($ oobi-host 'current-key aid-prefix))
          replies oobi-host))

     ;; Cross-device recovery: hand back the stored ICP+rotations for AID
     ;; so a new browser can import the AID and unlock with its bran.
     ;; Returns the entry alist, or #f if the AID isn't known.
     ;; Public method — no auth needed; callers prove AID ownership by
     ;; possessing the bran (which they use to re-derive keys locally).
     ((fetch-icp aid-prefix)
      (and oobi-host (<- oobi-host 'get aid-prefix)))

     ;; The same entry, found by a KEY its events carry: a device that
     ;; holds only the passcode derives the passcode's first key — the
     ;; inception's, or the rotation's that a passcode change made — and
     ;; asks for the log it appears in. Public, like fetch-icp — a log is
     ;; public, and the caller verifies the one it is handed and checks its
     ;; own passcode opens it before using it.
     ((find-icp event-key)
      (and oobi-host (<- oobi-host 'by-event-key event-key)))

     ;; NOTE: rotate-aid and list-credentials have moved to
     ;; ^lobby-session (returned by keri-authenticate). Callers
     ;; holding the session cap invoke them there; the AID is
     ;; closed-over and cannot be impersonated.

     ;; ── KERI challenge-response auth ──────────────────────────────────────
     ;;
     ;; Step 1: get a nonce to sign.
     ;; The client should send their AID prefix so we can associate the nonce.
     ;; Returns nonce string (hex).
     ((keri-challenge aid-prefix)
      (let* ((nonce (generate-nonce))
             (now   (instant->unix (clock-now))))
        (set! pending-challenges
              (hashmap-set pending-challenges nonce (cons aid-prefix now)))
        nonce))

     ;; Step 2: verify the signed nonce.
     ;; aid-prefix     — the user's AID
     ;; signature-qb64 — CESR ed25519 sig over nonce ('0B...')
     ;; nonce          — the nonce returned from keri-challenge
     ;; Returns 'ok (with aid-prefix as identity) or (list 'error reason).
     ((keri-authenticate aid-prefix signature-qb64 nonce)
      ;; Prune expired challenges lazily
      (let ((entry (hashmap-ref pending-challenges nonce #f)))
        (cond
         ((not entry)
          (list 'error "unknown or expired nonce"))
         ;; Constant-time comparison: prevents timing side-channel
         ;; that could reconstruct a valid AID prefix byte-by-byte.
         ((not (constant-time-string=? (car entry) aid-prefix))
          (list 'error "AID mismatch for this nonce"))
         ((nonce-expired? (cdr entry))
          (set! pending-challenges
                (hashmap-remove pending-challenges nonce))
          (list 'error "nonce expired"))
         (else
          (set! pending-challenges
                (hashmap-remove pending-challenges nonce))
          ;; ^oobi-host now lives in the same vat as ^lobby, so we
          ;; can call it synchronously to resolve the current signing
          ;; key (post-rotation the AID prefix no longer encodes the
          ;; key — the latest-rotation k[0] does). For unrotated D/B-
          ;; prefix AIDs (or when the AID isn't in oobi-host) we fall
          ;; back to keri-verify-signature, which handles fast-path
          ;; verification against the prefix.
          (catch #t
            (lambda ()
              (let* ((current-key (and oobi-host
                                       ($ oobi-host 'current-key aid-prefix)))
                     (verified?
                      (cond
                       ((string? current-key)
                        (verify-said-signature nonce signature-qb64 current-key))
                       (else
                        (keri-verify-signature aid-prefix nonce signature-qb64)))))
                (cond
                 ((not verified?)
                  (list 'error "signature verification failed"))
                 (else
                  ;; Spawn a session facet bound to this AID and return
                  ;; the cap. Callers use the cap for all privileged
                  ;; operations (rotate-aid, list-credentials, governance
                  ;; methods, terminal, mailbox). The AID is the
                  ;; closure, not a passable parameter.
                  ;;
                  ;; THE SEAT GATE. A key proven is not a seat held:
                  ;; ^oobi-host witnesses any verifiable KEL, so an AID
                  ;; with a current-key here may never have joined. With
                  ;; an oobi-host in play the seat is asked of
                  ;; signup-agent (another vat — so the answer is a
                  ;; promise, which the caller's `on` resolves). Without
                  ;; one, the prefix-verified path stands as it was.
                  (let ((seat!
                         (lambda ()
                           (let ((session (spawn ^lobby-session aid-prefix
                                                 terminal-svc mailbox-mgr
                                                 governance-svc signup-agent
                                                 oobi-host acdc-store folksonomy
                                                 presence push-store
                                                 recipient-registry planner-service
                                                 'root pins #f ai-svc contact-desk)))
                             (format (current-error-port)
                                     "[lobby] authenticated (~a)\n" (aid-tag aid-prefix))
                             (list 'ok session)))))
                    (if (string? current-key)
                        (on (<- signup-agent 'has-seat? aid-prefix)
                            (lambda (seated?)
                              (if seated?
                                  (seat!)
                                  (list 'error "no seat here: join first")))
                            #:catch (lambda _ (list 'error "no seat here: join first"))
                            #:promise? #t)
                        (seat!)))))))
            (lambda (key . args)
              (list 'error (format #f "auth verify error: ~a ~a" key args))))))))

     ;; Step 2, device form: the AID's root authorized this device's key
     ;; (WIRE-JSON, a device-authorization credential the root signed) and
     ;; the device signed the nonce. The session is the person's, at tier
     ;; 'device. The nonce came from keri-challenge under the PERSON's AID.
     ((keri-authenticate-device aid-prefix wire-json signature-qb64 nonce)
      (let ((entry (hashmap-ref pending-challenges nonce #f)))
        (cond
         ((not entry) (list 'error "unknown or expired nonce"))
         ((not (constant-time-string=? (car entry) aid-prefix))
          (list 'error "AID mismatch for this nonce"))
         ((nonce-expired? (cdr entry))
          (set! pending-challenges (hashmap-remove pending-challenges nonce))
          (list 'error "nonce expired"))
         (else
          (set! pending-challenges (hashmap-remove pending-challenges nonce))
          (catch #t
            (lambda ()
              (let* ((cred (and (string? wire-json) (device-wire->cred wire-json)))
                     (root-key (or (and oobi-host ($ oobi-host 'current-key aid-prefix))
                                   aid-prefix))
                     (verdict (and cred (device-credential-verdict cred aid-prefix root-key)))
                     (said (and cred (assq-ref cred 'said)))
                     (reg (and said (device-entry aid-prefix said)))
                     (device-aid (and cred (assq-ref cred 'holder))))
                (cond
                 ((not cred) (list 'error "malformed device authorization"))
                 ;; the registry speaks first: a retired device is told so
                 ;; whatever else is true of its authorization
                 ((and reg (not (device-entry-live? reg (instant->unix (clock-now)))))
                  (list 'error "device authorization revoked or expired"))
                 ;; an authorization verifies under the key in force: one the
                 ;; root signed before a rotation is retired by that rotation,
                 ;; and the passcode seat that follows authorizes afresh
                 ((equal? verdict "signature is not the root's")
                  (list 'error "device authorization revoked: it predates the key now in force"))
                 ((not (eq? verdict #t)) (list 'error verdict))
                 ((not reg) (list 'error "device not enrolled here"))
                 ((not (verify-said-signature-under-key nonce signature-qb64 device-aid))
                  (list 'error "signature verification failed"))
                 (else
                  (let ((seat!
                         (lambda ()
                           (let ((session (spawn ^lobby-session aid-prefix
                                                 terminal-svc mailbox-mgr
                                                 governance-svc signup-agent
                                                 oobi-host acdc-store folksonomy
                                                 presence push-store
                                                 recipient-registry planner-service
                                                 'device pins
                                                 (device-entry-doors reg)
                                                 ai-svc contact-desk)))
                             (format (current-error-port)
                                     "[lobby] authenticated (~a) by device ~a\n"
                                     (aid-tag aid-prefix) (aid-tag device-aid))
                             (list 'ok session)))))
                    (if oobi-host
                        (on (<- signup-agent 'has-seat? aid-prefix)
                            (lambda (seated?)
                              (if seated? (seat!) (list 'error "no seat here: join first")))
                            #:catch (lambda _ (list 'error "no seat here: join first"))
                            #:promise? #t)
                        (seat!)))))))
            (lambda (key . args)
              (list 'error (format #f "auth verify error: ~a ~a" key args))))))))

     ;; The AI doors (transcribe, express, ai-complete) are the session's:
     ;; the commons pays per call, so a call has a seat and a budget.

     ;; ── Corpus search (docs/planning/faces/corpus-guile-native.md phase 4) ───────
     ;; DOMAIN names one corpus (the recipes face's own use — this scope's
     ;; knowledge, "permaculture" etc.) or is #f to search every built domain
     ;; and merge by fusion score (the federation-wide corpus tab). Both
     ;; surfaces are one door: what differs is only whether DOMAIN is given.
     ;;
     ;; The degrade-path reply is an ALIST — `((error . "…"))` — matching
     ;; ^corpus-service's OWN reply shape exactly, not this file's more
     ;; common `(list 'error "…")` convention: day-boot.scm's
     ;; handle-corpus-search/-domains call `(assq-ref r 'error)` on
     ;; whatever comes back, and a flat 2-element list is not an alist —
     ;; `assq-ref` throws on it. Caught by testing the unconfigured-gateway
     ;; path directly, not by review: this is precisely the soft-degrade
     ;; case (a box with no onnxruntime/guile-sqlite3 in its manifest) the
     ;; whole `corpus-svc #f` design exists to answer gracefully, and the
     ;; mismatched shape meant it never actually reached the browser as a
     ;; clean error — the JS promise would hang instead.
     ((corpus-search domain query limit)
      (if corpus-svc
          (<- corpus-svc 'search domain query limit)
          `((error . "corpus search is not configured on this gateway"))))
     ((corpus-domains)
      (if corpus-svc (<- corpus-svc 'domains)
          `((error . "corpus search is not configured on this gateway"))))

     ;; ── Presence ──────────────────────────────────────────────────────────
     ((announce name user-inbox)
      (<- presence 'announce name user-inbox))

     ((leave name)
      (<- presence 'leave name))

     ((who)
      (<- presence 'online-users))

     ((introduce target-name)
      (<- presence 'introduce target-name))

     ((signal target-name from-name signal-type signal-data)
      (<- presence 'signal target-name from-name signal-type signal-data))

     ;; ── Meeting rooms, READ side ──────────────────────────────────────────
     ;; A room is a topic string; its roster is who the walkie meshes over.
     ;; Who is in a room is public within the gateway — that is the point of
     ;; the wake (docs/planning/faces/meeting-station.md, Layer 2).
     ;;
     ;; JOINING is not here. Entering a room is an act performed AS someone,
     ;; so it lives only on the AID-bound `^lobby-session`, which supplies the
     ;; name from its own closure. An anonymous `join-room room name` would let
     ;; any client put any AID in any roster.
     ((room-roster room)
      (<- presence 'room-roster room))

     ((live-rooms)
      (<- presence 'live-rooms))

     ((ice-servers)
      (or ice-list (ice-servers-from-urls %default-ice-urls)))

     ;; ── Push notifications ───────────────────────────────────────────────
     ((vapid-public-key) (or vapid-pub-b64 ""))

     ((register-push device-id subscription-json)
      (when push-store
        ($ push-store 'register device-id subscription-json))
      'ok)

     ((unregister-push device-id)
      (when push-store
        ($ push-store 'unregister device-id))
      'ok)

     ;; ── Terminal ──────────────────────────────────────────────────────────
     ;; identity-key = AID prefix or org pubkey (legacy flow).
     ;; Stays on public lobby for the inner-mode org-pubkey path; KERI
     ;; AID callers should obtain a session cap first and call from
     ;; ^lobby-session (not yet wired through here, but planned).
     ;; Gated by member-gated (above) — see its comment for the PHC check.
     ((open-terminal identity-key client-inbox)
      (member-gated identity-key
                    (lambda () (<- terminal-svc 'open identity-key client-inbox))))

     ;; ── Mailbox ───────────────────────────────────────────────────────────
     ;; Same gate as open-terminal above.
     ((get-mailbox identity-key)
      (member-gated identity-key
                    (lambda () (<- mailbox-mgr 'get-or-create identity-key))))

     ;; ── Planner ──────────────────────────────────────────────────────────
     ;; Hand the caller the planner FACET: the browser's doors forward, the
     ;; service's boot, admin and payout-runner doors do not exist from here
     ;; (^planner-facet above). Anonymous, like every ^lobby method.
     ((planner) planner-facet)

     ;; ── Presence ──────────────────────────────────────────────────────────
     ;; who's connected to THIS gateway right now (by display-name — presence
     ;; keys sessions by name, not AID). The dial joins this onto its contact
     ;; book for the `online` dot. Gateway-local only; cross-mesh presence is
     ;; not tracked here.
     ((online-users) (<- presence 'online-users))

     ;; ── Donations (public, no auth needed) ────────────────────────────────
     ;; Returns the Monero address this node's operator uses — whatever
     ;; wallet the gateway is wired to through wallet-service. Callers
     ;; display it so anons can donate to cover hosting costs. Returns
     ;; `#f` if no wallet is configured on this deployment.
     ((donation-address)
      (if wallet-policy
          (catch #t
            (lambda () (<- wallet-policy 'get-address))
            (lambda _ #f))
          #f))

     ;; ── Role checks (public, no auth needed) ──────────────────────────────
     ;; Always #f: the role-credential ceremony this checked against
     ;; (governance-member?/-supplier?/-planner?/-governor?) was removed
     ;; 2026-08-19 — it never bootstrapped, so every role always read
     ;; false anyway. Kept as an explicit stub (same return shape, same
     ;; result) rather than a dangling call to a deleted function; see
     ;; the TODO on issue-credential in ^lobby-session for the reasoning.
     ((has-role? aid-prefix role)
      #f)

     ;; ── Governance: public reads only ────────────────────────────────────
     ;; The mutating methods (open / cast / close / set-delegation /
     ;; revoke-delegation) have moved to ^lobby-session — they need
     ;; an authenticated AID, and the session cap is the proof.
     ((get-result id)
      (<- governance-svc 'get-result id))

     ((list-proposals)
      (<- governance-svc 'list-proposals)))))
