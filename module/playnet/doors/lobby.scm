;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/doors/lobby.scm — OCapN gateway entry point
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

(define-module (playnet doors lobby)
  #:use-module ((playnet utils common) #:select (string-or-false env-flag?))
  #:use-module (playnet gateway evidence)
  #:use-module ((playnet vf facts limits) #:select (%picture-max-chars))
  #:use-module ((playnet vf formulas counting) #:select (%contest-prefix))
  #:use-module ((playnet observation evidence) #:select (evidence-hash?))
  #:use-module (goblins)
  #:use-module ((playnet doors protocol) #:select (%doors door-name door-object door-auth))
  #:use-module ((playnet protocol dispatch) #:select (declared-methods declared-methods*))
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module ((playnet utils boot-cell) #:select (make-boot-cell))
  #:use-module ((playnet keri first-person predicates)
                #:select (holds-any-live-phc?))
  #:use-module ((playnet identity seat) #:select (aid-tag))
  #:use-module ((playnet keri reticulum-binding)
                #:select (kel-reticulum-pub verify-announce-packet
                          anchored-destinations announce-dest-hex
                          data-packet?))
  #:use-module ((playnet utils hex) #:select (hex->bv))
  ;; a grant's holder is the commune whose pool a recall moves
  #:use-module ((playnet keri acdc) #:select (cred-holder))
  ;; every session's dispatch passes the forgotten gate
  #:use-module ((playnet identity forget) #:select (forgotten-gated unmark-forgotten!))
  ;; the identity doors of both objects live in (playnet doors identity) as
  ;; fragments; each object composes its own with them (declared-methods*)
  #:use-module ((playnet doors identity)
                #:select (identity-lobby-doors identity-session-doors make-session-identity))
  ;; the body doors — a legal body declared, stewarded, incepted k-of-n and
  ;; read by the law — are a fragment too (playnet doors body)
  ;; the per-AID files a member's sync doors keep (one module lists the kinds)
  #:use-module ((playnet identity user-files)
                #:select (%data-dir %user-file %read-user-data %write-user-data!
                          %seed-user-docs!))
  #:use-module ((srfi srfi-1) #:select (filter-map))
  #:use-module (playnet gateway allotment)   ; the week's unplanned photo reads
  #:use-module ((playnet wire replies) #:select (finished))   ; registers the allotment table
  #:use-module ((playnet social lens) #:select (resolve-lens))
  #:use-module ((playnet folksonomy graph) #:select (template->doc))
  ;; the pin book: a citizen's shared lists fold like their taxonomy cut
  #:use-module ((playnet folksonomy pins) #:select (pins-doc-public))
  #:use-module ((json parser) #:select (json-string->scm))
  #:use-module (ice-9 format)
  #:export (^lobby ^lobby-session ^planner-facet %planner-public-doors release-contest-evidence!
            %default-ice-urls ice-servers-from-urls
            seed-pins! seed-taxonomy-docs!
            current-mesh-announcer
            current-mesh-mailbox
            contacts-file-for
           
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

(define (release-contest-evidence! ballot-id)
  "Let go of the picture held for a contest ballot that has settled."
  (release-evidence! (%data-dir) ballot-id))

;; the per-AID files, named once each (identity/user-files.scm holds the
;; path scheme and the list of kinds a forget erases)
(define (contacts-file-for aid-prefix) (%user-file "contacts" aid-prefix))
(define (taxonomy-file-for aid-prefix) (%user-file "taxonomy" aid-prefix))
(define (log-file-for aid-prefix) (%user-file "log" aid-prefix))
(define (pins-file-for aid-prefix) (%user-file "pins" aid-prefix))
(define (allotment-file-for aid-prefix) (%user-file "allotment" aid-prefix))

;; A picture crosses in parts and the session joins them; the whole is bounded
;; by %picture-max-chars (vf/facts/limits.scm).

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
  ;; (identity/contact-points.scm make-contact-point-desk), or #f for a commune
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
  ;; declaration names the target (doors/protocol.scm #:to), and the lint holds
  ;; the two together.
  ;; A session is spawned only once has-seat? held: a seat proven afresh is
  ;; a person who is a member again, so any forgotten mark on the AID lifts
  ;; (identity/forget.scm).
  (unmark-forgotten! aid-prefix)
  (define (planner! . msg)
    (if planner-service (apply <- planner-service msg) (list 'error "no planner service")))
  ;; the name this session announced itself under: presence keys by it, so
  ;; a forget leaves by it too
  (define announced-name #f)
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

  ;; outermost: once the AID is forgotten, every message is refused —
  ;; this cap's and every other live session's of the same AID
  (forgotten-gated aid-prefix
  (door-gated doors
  (declared-methods* session
   ((identity-session-doors
          (make-session-identity
           #:aid-prefix aid-prefix #:tier tier #:signup-agent signup-agent
           #:oobi-host oobi-host #:acdc-store acdc-store
           #:recipient-registry recipient-registry #:contact-desk contact-desk
           #:presence presence #:push-store push-store #:pins pins
           #:folksonomy folksonomy #:mailbox-mgr mailbox-mgr
           #:governance-svc governance-svc #:planner! planner!
           #:announced-name (lambda () announced-name)
           #:own-book own-book #:anchored-mesh-pub anchored-mesh-pub
           #:mesh-mailbox (current-mesh-mailbox))))

   ;; ── Presence / push, AID-aware ─────────────────────────────────────
   ;; These mirror ^lobby's anonymous announce/register-push, but seed the
   ;; recipient registry with THIS session's AID (the closure) so the
   ;; notification router can reach the user per-identity. The browser
   ;; calls these on its session cap instead of the bare lobby once it
   ;; holds a session (see repl.scm announce-presence!). Presence itself
   ;; still keys by display name for the who/introduce/WebRTC surface.
   ((announce name user-inbox)
    (set! announced-name name)
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


   ;; The store parses the browser's subscription and refuses what is none;
   ;; the `push` channel is bound only for a subscription that was kept.


   ;; Per-AID data sync — server persists contacts and credentials so
   ;; they survive browser clears and transfer to new devices. The
   ;; browser is the primary holder (local-first); server is backup.

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
   ;; the commune's shared lists, and one list's members — read off the fold

   ;; ── Per-AID taxonomy doc — the folksonomy's structure edges ──
   ;; Identical local-first + server-backup shape to contacts, but it also
   ;; feeds the scope's ^folksonomy aggregator: publishing your cut IS voting
   ;; (folksonomy.md "using is voting"). The aggregator lives in planner-vat,
   ;; so the contribute is an eventual <-np across the OCapN boundary.
   ;; The commune's aggregated cut — a {id,label,children,count} template the
   ;; dial feeds straight to rebuildSpine. Optional LENS-NAME (folksonomy.md
   ;; Phase 4): "friends"/"family"/"commons"/"me"/… weights the cut toward that
   ;; neighbourhood. We resolve the name against THIS caller's own contact book
   ;; (the rel graph) into an AID set here in gateway-vat, then hand the SET to
   ;; the planner-vat aggregator, which builds the predicate locally — no closure
   ;; crosses the wire. #f / "everyone" → the global cut.
   ;; Adopt {this lens's cut} as MY published cut — the "using is voting" loop
   ;; and cold-start (a newcomer takes the commons'/friends' cut as their
   ;; starting taxonomy). Resolve the cut server-side, flatten it to my
   ;; structure edges (template->doc), publish via the shared path. No tree
   ;; crosses the wire; reuses the aggregator + template->doc + publish-taxonomy!.

   ;; ── the AI the commons pays for, from this seat ────────────────────
   ;; MODEL is a string or #f; the service runs an enclave slug as named and
   ;; anything else as its default.

   ;; ── a picture, read (docs/observation/capture.md §9) ───────────────
   ;; One part of one picture of an upload. UPLOAD is the browser's own name
   ;; for the sending, INDEX which picture of it (several pictures of one
   ;; thing are one read), PART a run of its base64. Replies the characters
   ;; held, or an error when a part or the whole is over its bound.

   ;; Read the pictures sent under UPLOAD. A read that fulfils a count the
   ;; plan asked of this person (SCOPE-ID, FULFILLS) draws on the plan; any
   ;; other spends one of the week's reads, given back when the model gives
   ;; no answer. Replies the model's text; "" when pictures cannot be read
   ;; here; "err:…" in words the sheet can show.

   ;; ── a counter's picture, attached to the contest of their count ─────
   ;; (docs/observation/capture.md §8). The count names the picture by hash;
   ;; the contest's franchise reads it when it votes. Governance says who may
   ;; attach (the counter whose act it is) and who may read (the franchise),
   ;; and which hash the count names; the gateway holds the picture until the
   ;; ballot settles.

   ;; One part of the picture held for a contest, to the counter and the
   ;; franchise: the part, how many there are, and the hash it is held under.

   ;; The contests open in a scope, as they stand to this seat: what each names,
   ;; whose act it is, and whether this seat attaches a picture, votes, or neither.

   ;; The week's unplanned photo reads: how many remain, of how many, and
   ;; when the week opens again; and whether a picture can be read here.

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
                            dest-hex (aid-tag aid-prefix))
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


   ;; Client-side citizen signing. `stance-preimage` hands the client every
   ;; SAID field the SERVER is authoritative for; the client adds only its
   ;; position + timestamp, re-derives the SAID itself (so it is not
   ;; blind-signing), signs with its own KERI key, and returns the signature
   ;; via `cast-signed`. As with the other governance methods the AID is
   ;; closed over here, so a client cannot sign as anyone else.

   ;; U — the blinding nonce from the preimage's claims, echoed back so the
   ;; server rebuilds the exact credential the client signed. Variadic so an
   ;; old five-arg client gets a clean signature rejection instead of an
   ;; arity error; see the deploy-order note on `cast-signed` in service.scm.

   ;; Producer voice over the plan: this AID's HAND of signed stances on parts
   ;; of SCOPE-ID's plan (docs/planning/voice/). HAND-JSON is a JSON object
   ;; {"part-string": portion, …}, portions in [−1, 1]. Same two legs as a
   ;; ballot stance: the preimage hands back the SAID fields, the signed leg
   ;; verifies against the KEL key resolved here, then the planner's voice
   ;; fold takes the scope's standing hands (data across the vat seam).
   ;; a scope's own word, spoken for it by a governor (this AID): where a
   ;; resource's pool stands, what the scope will host, what its domain's
   ;; statistics license — each a credential the solve reads where it lies
   ;; a federation admits a commune, as one of its governors: the commune's AID
   ;; and the sturdyref its peer answers at; RATIFICATION (a SAID) is the
   ;; commune's consent when the federation requires one
   ((admit-commune federation-aid commune-aid sturdyref-uri #:optional (ratification #f))
    (<- governance-svc 'admit-commune aid-prefix federation-aid commune-aid sturdyref-uri ratification))

   ;; ── Temporary socialization — the AID is the closed-over session identity,
   ;; so owner is non-spoofable. `declare-means` seeds an owned resource into the
   ;; scope's observer (planner-vat); socialize-preimage/-signed issue the owner-
   ;; signed custody attestation (client-signing, like stance above); my-grants /
   ;; desocialize read + recall. commune-aid + scope-id come from the dial's
   ;; scope-list (a real scope, e.g. the whole commons).
   ;; OPTS: (arcs-json note emoji) — the slot's recurring time pattern +
   ;; prose + face, riding the resource's own fields (availability-window,
   ;; note, image). Same closed-over AID, so declarations are non-spoofable.
   ;; the need side of the same expression: a standing intent (see
   ;; planner-service declare-need). One surface, two rails.
   ;; what that need displaces at declaration time — a read off the scope's last
   ;; solve, shown in the ⚖️ editor before a kind and level are stated.
   ;; the burn-meter: the scope's accumulated externality display, one
   ;; snapshot per solve, summarized as its moved-distribution
   ;; the constitution's gate: the scope ratifies a spec's kind (floor | held),
   ;; recorded under this citizen's AID; the grants are what declare-need reads
   ;; stage 3: the audit of the scope's ratified kinds, and its record
   ;; the fold's reading at SCOPE-ID — Our Needs / Our Offers — with this
   ;; citizen's own share joined from HOME-SCOPE-ID, where their leaf lives
   ;; the offer side's withdrawal: a `lower` to zero on the declared means —
   ;; the record and its event history stand, only the offer leaves
   ;; payouts — "send N XMR of my claim to ⟨address⟩". The member is the
   ;; session AID (non-spoofable); the runner in the gateway moves the coins
   ;; under the wallet policy. See doors/service.scm request-payout.
   ;; purchases for the commons — the member is the session AID; the raise
   ;; lands immediately, and whether it fulfils a plan the commons already
   ;; committed to comes back as PLANNED? (informational). What the commons
   ;; then owes is minted as a debt through governance's own
   ;; accept-reimbursement (governance/scope.scm, a ^scope method — the
   ;; commune's own word, not this session's) and read back via my-payouts'
   ;; `owed` field (economy/debts.scm), paid as a payout.
   ;; ── skills: the citizen's own labour-power, self-declared ──
   ;; The closed-over AID is the agent, so a citizen declares and revokes
   ;; only their own skills — the same non-spoofability declare-means
   ;; states. The service side is the VF raise/lower pair over a skill
   ;; EconomicResource, and the scope's labour fold refolds on the write.
   ;; the scope's whole slot pool (every citizen's standing needs + the means
   ;; socialized into the commons as of the last solve) — the map's 🏠 source.
   ;; Scope-wide by design, so no AID: what stands in the commons is the
   ;; commons' to see; a merely declared private means never appears here.
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
   ;; the week asked backwards: the three bills (euros and hours beyond the purse).
   ;; its externality display: what each held/des ask moved from the others.
   ;; ── live / expected position ────────────────────────────────────────────
   ;; Where the caller IS at PERIOD (0 = now; t > 0 = a declared future). The
   ;; planner reads it as their commute origin and as the cell their labour and
   ;; their reproduction floors sit in, so a citizen who moves moves what they
   ;; can reach AND what the plan brings to them. The AID is the closed-over
   ;; session identity, so a citizen positions only themselves.
   ;; `set-position-latlon` snaps raw coordinates to the scope's nearest known
   ;; place server-side and stores that place id — the coordinates go no
   ;; further, so sharing a position shares a place rather than a trace.
   ;; whether the caller shares where they are (live, here, off): stated once at
   ;; their home, read by every device; off ends the fix that stands
   ;; the citizen's registered home (planner-service set-home): the agent
   ;; record's primary location, the floor `agent-position` falls back to. A
   ;; known place id, or "" with coordinates for the citizen's own place:AID:home.
   ;; a new place, named by the citizen (planner-service declare-place):
   ;; a <spatial-thing> in the scope, id place:AID:slug — the closed-over
   ;; AID names it, so a place is its namer's to re-place. OPTS: (address) —
   ;; free-association's Specific tab (street/city/state/postal/country)
   ;; collapsed to the one string <spatial-thing> already carries.
   ;; The schedule of counts: every target with its cadence, soonest due first.
   ;; Lays the counts that are due as directed work offers.
   ;; The scope as this person's device holds it, as one text.
   ;; The counts of one stock, newest first, as a member reads them to contest one.
   ;; The code a stock is known by, for its label.
   ;; What a label's code names: the thing, where it is, what is in it.
   ;; ELIGIBLE: the owner's steward rule, forwarded verbatim
   ;; a grant landing or leaving moves the scope's pool: the planner's
   ;; slots-at reads the store live, and its watchers (the map) hear the
   ;; move through slots-changed! once the governance write settles.
   ((my-grants) (<- governance-svc 'my-grants aid-prefix))
   ;; ── purchase claims: the member's own signed word, the reimbursement
   ;; primary — the exact twin of socialize-preimage/-signed above.
   ;; ── accepting a grant or a reimbursement — the commune's own word.
   ;; See doors/governance.scm's own accept-socialization/accept-reimbursement
   ;; for the real, stated security gap: no governor-role gate exists live
   ;; anywhere yet, so this is open to any authenticated member, not just
   ;; governors — self-accepting one's own reimbursement is the one thing
   ;; actually refused.
   ;; ── ownership: title over one declared means, client-signed ──
   ;; The rights-side twin of the socialize legs — issuer = holder = the
   ;; session AID, so a citizen titles only what they declare as their own.
   ((my-titles) (<- governance-svc 'my-titles aid-prefix))

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

   ;; Governance READS — the decision inbox + tallies. The mutating
   ;; open/cast/close above let the dial act; these let it SHOW the open
   ;; decisions and their live/closed results (governance-surface.md §Inbox).

   ((get-result id)
    (<- governance-svc 'get-result id))

   ((list-delegations)
    (<- governance-svc 'list-delegations aid-prefix))


   ;; your producer voice in ONE commune — the voice map's cell


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
           (franchise-rest scope-id)))))))

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
;;; The list is the declaration's: every planner door (playnet doors protocol)
;;; marks `anonymous`. Opening a door to the browser is one edit there, and
;;; tools/lint/protocol-lint.scm keeps the declaration and the code's heads in
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
  (let ((planner-facet (and planner-service (spawn ^planner-facet planner-service))))

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

    ;; A seat, proven: the session an authenticated AID is handed, at TIER
    ;; ('root — the KEL key; 'device — an authorized device key) and under
    ;; DOORS (#f, or a device's allowlist). The identity doors spawn it
    ;; (doors/identity.scm keri-authenticate, keri-authenticate-device).
    (define (spawn-session aid-prefix tier doors)
      (spawn ^lobby-session aid-prefix
             terminal-svc mailbox-mgr governance-svc signup-agent
             oobi-host acdc-store folksonomy presence push-store
             recipient-registry planner-service tier pins doors ai-svc contact-desk))


    (declared-methods* lobby
     ((identity-lobby-doors signup-agent oobi-host spawn-session))

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


     ((ice-servers)
      (or ice-list (ice-servers-from-urls %default-ice-urls)))

     ;; ── Push notifications ───────────────────────────────────────────────



     ;; ── Terminal ──────────────────────────────────────────────────────────
     ;; identity-key = AID prefix or org pubkey (legacy flow).
     ;; Stays on public lobby for the inner-mode org-pubkey path; KERI
     ;; AID callers should obtain a session cap first and call from
     ;; ^lobby-session (not yet wired through here, but planned).
     ;; Gated by member-gated (above) — see its comment for the PHC check.

     ;; ── Mailbox ───────────────────────────────────────────────────────────
     ;; Same gate as open-terminal above.
     ((get-mailbox identity-key)
      (member-gated identity-key
                    (lambda () (<- mailbox-mgr 'get-or-create identity-key))))

     ;; ── Planner ──────────────────────────────────────────────────────────
     ;; Hand the caller the planner FACET: the browser's doors forward, the
     ;; service's boot, admin and payout-runner doors do not exist from here
     ;; (^planner-facet above). Anonymous, like every ^lobby method.

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
