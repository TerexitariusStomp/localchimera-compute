;;; module/playnet/doors/protocol.scm — the doors the browser may call, declared once
;;;
;;; One entry per method on the three objects a client reaches: the anonymous
;;; `lobby` (the sturdyref), the per-person `session` `keri-authenticate*`
;;; returns, and the `planner` facet the lobby hands out. Every field says
;;; what the code does today (docs/planning/audits/protocol-inventory-2026-09-12.md);
;;; `tools/lint/protocol-lint.scm` refuses a declaration whose heads differ from
;;; the code's (`tools/lint/protocol-extract.scm`), in either direction.
;;;
;;; A door:
;;;   (door OBJECT NAME ARGS #:auth A #:topic T #:reply R #:doc "…")
;;;   object  lobby | session | planner
;;;   name    the method symbol, as sent over CapTP
;;;   args    the argument list as written in the method head
;;;   auth    anonymous — no seat needed (every lobby door; the planner facet's
;;;                       doors are anonymous today because the facet is)
;;;           device    — a session at tier device or root
;;;           root      — a session at tier root (the passcode was in hand)
;;;           operator  — not reachable from a client at all (planner doors
;;;                       outside the facet: boot, admin, payout runner)
;;;   topic   one of %topics — what the door is about, the heading it is
;;;           listed under in the OpenAPI document and the MCP tool list
;;;   (seam)  derived, not declared: `door-seam` answers the first handler in
;;;           (playnet protocol seam) whose doors include this one, or #f
;;;   reply   the reply shape, a symbol from %reply-shapes in
;;;           (playnet protocol shapes); `unknown` until classified
;;;   doc     one sentence: what the door does and what it replies
;;;
;;; Emits read this table: seam-wire.ts, the OpenAPI document, the MCP tool
;;; list (also served live at POST /api/mcp by (playnet doors mcp)).
;;; The lobby derives its planner facet allowlist from it. Plan:
;;; docs/planning/identity/repo-split-and-protocol-doors.md §B1.

(define-module (playnet doors protocol)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module ((playnet protocol seam) #:select (%handlers handler-name handler-doors))
  #:export (%doors door-ref doors-of
            door? door-object door-name door-args door-auth door-topic door-seam door-reply door-kind door-to door-doc door-feature door-keyed doors-of-feature doors-keyed %kinds %targets
            %topics topic-doc door-audience
            %protocol-version))

;; Bumped on any non-additive change (a door removed, renamed, or its args
;; reshaped). Additive changes need no bump.
(define %protocol-version 1)

(define-record-type <door>
  (make-door object name args auth topic reply kind to doc feature keyed)
  door?
  (object door-object)
  (name   door-name)
  (args   door-args)
  (auth   door-auth)
  (topic  door-topic)
  (reply  door-reply)
  (kind   door-kind)
  (to     door-to)
  (doc    door-doc)
  (feature door-feature)
  (keyed   door-keyed))      ; the name of the argument that keys one act (a tap), or #f

;; the headings a door is listed under: (topic . one line on what it covers)
(define %topics
  '((identity    . "Seats, KERI authentication, keys, devices and recovery.")
    (scopes      . "Communes: membership, the roster, invites and which scope you act in.")
    (planning    . "Solves and plans: snapshots, schedules, declared needs and a scope's recipes.")
    (slots       . "The needs-and-offers pool: pins, matching and the share face.")
    (commitments . "Accepting and observing work: events, journeys and the calendar.")
    (stock       . "Inventory, claims, purchases, the shop, credit, payouts and reimbursement.")
    (custody     . "Grants, socialization, ownership titles and means pools.")
    (governance  . "Proposals, ballots, delegation, mandates, the forum and audits.")
    (chat        . "Chat, presence, walkie signalling and contacts.")
    (law         . "The legal registry, compliance and law snapshots.")
    (knowledge   . "Taxonomy and folksonomy, corpus search, AI completion and transcription.")
    (places      . "Places, containers, the map and ecology.")
    (operations  . "Boot, admin and maintenance: the operator's doors.")))
(define (topic-doc t) (assq-ref %topics t))

(define (door-audience d)
  "Who can call D, as the docs say it: anyone, a citizen's device, a citizen
at root tier, or the operator alone."
  (case (door-auth d)
    ((anonymous) "anyone")
    ((device) "an enrolled device")
    ((root) "a root-tier session")
    (else "the operator")))

(define (door-seam d)
  "The seam.handlers name that reaches door D, from the seam table,
or #f when no handler sends it."
  (let ((key (cons (door-object d) (door-name d))))
    (and=> (find (lambda (h) (member key (handler-doors h))) %handlers)
           handler-name)))

;; (door OBJECT NAME ARGS #:auth A #:topic T #:reply R #:kind K [#:to W]
;;       [#:feature F] [#:keyed ARG] #:doc D) — every part is data, in any order
;; but #:doc last; nothing is evaluated. `door-collect` gathers the keywords
;; into an alist and `door*` reads it, so a new part of a declaration is one
;; keyword here and one field in the record, and no call site changes.
(define-syntax door
  (syntax-rules ()
    ((_ object name args . options)
     (door-collect (object name args) () . options))))

(define-syntax door-collect
  (syntax-rules ()
    ((_ (o n a) (opt ...) #:auth v . r)    (door-collect (o n a) (opt ... (auth . v)) . r))
    ((_ (o n a) (opt ...) #:topic v . r)   (door-collect (o n a) (opt ... (topic . v)) . r))
    ((_ (o n a) (opt ...) #:reply v . r)   (door-collect (o n a) (opt ... (reply . v)) . r))
    ((_ (o n a) (opt ...) #:kind v . r)    (door-collect (o n a) (opt ... (kind . v)) . r))
    ((_ (o n a) (opt ...) #:to v . r)      (door-collect (o n a) (opt ... (to . v)) . r))
    ((_ (o n a) (opt ...) #:feature v . r) (door-collect (o n a) (opt ... (feature . v)) . r))
    ((_ (o n a) (opt ...) #:keyed v . r)   (door-collect (o n a) (opt ... (keyed . v)) . r))
    ((_ (o n a) (opt ...) #:doc d)         (door* 'o 'n 'a '(opt ...) 'd))))

;; THE PRODUCT FEATURE A DOOR IS PART OF, declared on the door when it has one:
;; a feature is an act of the product the law may speak to — holding funds,
;; keeping what a member says of their health, sending their words to a model.
;; planner/knowledge/law/product.scm states each feature and the crossings it
;; trips; the doors that ARE the feature are read off this declaration
;; (`doors-of-feature`), so a new door joins its feature where it is written.

;; WHERE A DOOR'S ACT IS DONE, declared on the door: a session door either
;; acts in the session itself (`self`) or forwards, with this session's AID
;; as the agent, to the planner service or the governance service. The
;; lobby's forwarding shape is one helper (doors/lobby.scm planner!); the lint
;; (tools/lint/protocol-lint.scm) refuses a door whose code sends elsewhere than
;; its declaration says.
(define %targets '(self planner governance))

;; THE KIND OF STATEMENT A DOOR CARRIES, declared on the door (docs/planning/
;; federation-flow-map.md §1): a CONSTATIVE states a figure about the world
;; and lands as a coefficient or a record; a PREFERENCE sets a weight (a
;; stance, a hand, a want, a willingness); a PERFORMATIVE decides (fixes a
;; column, raises a wall, projects a view, opens or closes a thing); a READ
;; states nothing and answers. A door without a kind is refused here, so the
;; inventory (tools/emit/door-inventory.scm) is read off the declaration.
(define %kinds '(constative preference performative read))

(define (door* object name args options doc)
  (define (opt key default)
    (let ((p (assq key options))) (if p (cdr p) default)))
  (define (required key)
    (let ((p (assq key options)))
      (unless p (error "door: a door declares its auth, topic, reply and kind" object name key))
      (cdr p)))
  (let ((auth (required 'auth)) (topic (required 'topic)) (reply (required 'reply)) (kind (required 'kind))
        (to (opt 'to 'self)) (feature (opt 'feature #f)) (keyed (opt 'keyed #f)))
    (for-each (lambda (o)
                (unless (memq (car o) '(auth topic reply kind to feature keyed))
                  (error "door: no such part of a declaration" object name (car o))))
              options)
    (unless (memq auth '(anonymous device root operator))
      (error "door: auth must be anonymous | device | root | operator" object name auth))
    (unless (assq topic %topics)
      (error "door: topic must be one of %topics" object name topic))
    (unless (memq kind %kinds)
      (error "door: kind must be constative | preference | performative | read" object name kind))
    (unless (memq to %targets)
      (error "door: to must be self | planner | governance" object name to))
    (unless (or (not feature) (symbol? feature))
      (error "door: feature must be a symbol" object name feature))
    ;; a keyed door's last argument IS the key: optional, so a caller with no key
    ;; (a test, a script) lands the act as it always did (tools/lint/protocol-lint.scm
    ;; holds the rest of what keying means)
    (unless (or (not keyed)
                (and (symbol? keyed) (pair? args)
                     (let ((final (last args)))                   ; `tap`, or `(tap #f)` after #:optional
                       (eq? keyed (if (pair? final) (car final) final)))))
      (error "door: keyed names the door's last argument" object name keyed))
    (make-door object name args auth topic reply kind to doc feature keyed)))

(define (doors-of object) (filter (lambda (d) (eq? (door-object d) object)) %doors))
(define (doors-of-feature feature) (filter (lambda (d) (eq? (door-feature d) feature)) %doors))
(define (doors-keyed) (filter door-keyed %doors))
;; door-ref fires on every HTTP and MCP dispatch (doors/http.scm,
;; protocol/mcp.scm); %door-index (below %doors) turns its `find` over every
;; declared door — a few hundred, static, never mutated after load — into an
;; O(1) lookup, same result.
(define (door-ref object name)
  (hash-ref %door-index (cons object name) #f))

(define %doors
  (list

    ;; ── lobby ──
    (door lobby signup (username email aid-prefix oobi-url)
          #:auth anonymous #:topic identity #:reply ok-or-error #:kind performative #:feature account-creation
          #:doc "Registers a seat for an AID whose OOBI is hosted elsewhere: resolves it through KERIA, persists the member, and replies ok or (error reason). Use signup-with-icp when the browser holds its own KEL.")
    (door lobby signup-with-icp (username email aid-prefix icp-alist sigs)
          #:auth anonymous #:topic identity #:reply promise:ok-or-error #:kind performative #:feature account-creation
          #:doc "Takes a seat for a browser-made AID from its inception event and signatures, verified offline (AID = k[0], SAID, sig) and witnessed into ^oobi-host; replies ok or (error reason).")
    (door lobby signup-with-kel (username email aid-prefix icp-alist sigs rotations)
          #:auth anonymous #:topic identity #:reply ok-or-error #:kind performative #:feature account-creation
          #:doc "Takes a seat under an AID's whole KEL (inception, sigs, rotations in sn order), verified end to end and witnessed into ^oobi-host; replies ok or (error reason). No rotations: use signup-with-icp.")
    (door lobby extend-kel (aid-prefix rotations)
          #:auth anonymous #:topic identity #:reply ok-or-error #:kind constative
          #:doc "Appends rotations continuing from this gateway's last held event for a witnessed AID, each verified against stored state; replies ok or (error reason). Public: a rotation proves its own authorship.")
    (door lobby witness-kel (aid-prefix icp-alist sigs rotations)
          #:auth anonymous #:topic identity #:reply ok-or-error #:kind constative
          #:doc "Records a verifiable KEL into ^oobi-host without a seat, levelling a known AID up and refusing a different history under one AID; replies ok or (error reason). Call join afterwards for a seat.")
    (door lobby join (username email aid-prefix)
          #:auth anonymous #:topic identity #:reply ok-or-error #:kind performative #:feature account-creation
          #:doc "Grants a seat in this gateway's universal commune to an AID already witnessed in ^oobi-host (empty username mints a handle); replies ok or (error reason). The seat is what keri-authenticate checks.")
    (door lobby has-seat (aid-prefix)
          #:auth anonymous #:topic identity #:reply boolean #:kind read
          #:doc "Replies #t when the AID holds a seat on this gateway and #f otherwise, so a client can tell whether to join before authenticating.")
    (door lobby register-oobi-replies (aid-prefix replies)
          #:auth anonymous #:topic identity #:reply ok-or-error #:kind performative
          #:doc "Attaches the AID's self-endorsed OKEA endpoint replies (/end/role/add, /loc/scheme) to its served OOBI after each frame verifies under its current key; replies ok or (error reason).")
    (door lobby fetch-icp (aid-prefix)
          #:auth anonymous #:topic identity #:reply alist #:kind read
          #:doc "Replies the stored ^oobi-host entry (ICP plus rotations) for an AID, or #f when unknown, so a new browser can import the AID and unlock it with its bran, which is the only proof asked.")
    (door lobby find-icp (event-key)
          #:auth anonymous #:topic identity #:reply alist #:kind read
          #:doc "Replies the stored ^oobi-host entry (ICP plus rotations) one of whose events carries the given qb64 key as its signing key, the earliest registered when several, or #f when none, so a browser holding only a passcode finds the log by the passcode's first key, verifies it and checks the passcode opens it.")
    (door lobby keri-challenge (aid-prefix)
          #:auth anonymous #:topic identity #:reply string #:kind read
          #:doc "Auth step 1: mints a 32-byte random nonce bound to the AID prefix and replies it as hex; the nonce expires after 120 seconds and is spent on first use.")
    (door lobby keri-authenticate (aid-prefix signature-qb64 nonce)
          #:auth anonymous #:topic identity #:reply promise:ok-or-error #:kind read
          #:doc "Auth step 2: verifies the signed nonce under the AID's current key, checks the AID holds a seat, and replies (ok session) with a root-tier ^lobby-session bound to that AID, or (error reason).")
    (door lobby keri-authenticate-device (aid-prefix wire-json signature-qb64 nonce)
          #:auth anonymous #:topic identity #:reply promise:ok-or-error #:kind read
          #:doc "Auth step 2 for an enrolled device: verifies the root-signed device credential, its live enrollment and the nonce signature; replies (ok session) at tier device within its doors, or an error.")
    (door lobby corpus-search (domain query limit)
          #:auth anonymous #:topic knowledge #:reply alist #:kind read
          #:doc "Searches one corpus domain, or every built domain when domain is #f, by embedding similarity; replies ((hits . rows)) ranked by score up to limit, or ((error . reason)) when corpus search is off here.")
    (door lobby corpus-domains ()
          #:auth anonymous #:topic knowledge #:reply alist #:kind read
          #:doc "Replies ((domains . names)) listing the corpus domains built on this gateway, or ((error . reason)) when corpus search is off, so the corpus tab lists them without hardcoding.")
    (door lobby announce (name user-inbox)
          #:auth anonymous #:topic chat #:reply list #:kind constative
          #:doc "Announces a display name as online with its inbox capability, binds the notification sink to that inbox, broadcasts presence, and replies the list of online names.")
    (door lobby leave (name)
          #:auth anonymous #:topic chat #:reply list #:kind constative
          #:doc "Marks a display name offline, drops it from every meeting room it was in, broadcasts the change, and replies the list of names still online.")
    (door lobby who ()
          #:auth anonymous #:topic chat #:reply list #:kind read
          #:doc "Replies the display names currently announced as online on this gateway; the same read as online-users.")
    (door lobby introduce (target-name)
          #:auth anonymous #:topic chat #:reply capability #:kind read
          #:doc "Replies the inbox capability of the named online user, or #f when nobody by that name is announced, so a peer can open a WebRTC exchange directly.")
    (door lobby signal (target-name from-name signal-type signal-data)
          #:auth anonymous #:topic chat #:reply symbol #:kind constative
          #:doc "Relays a WebRTC signalling message (offer, answer, ICE candidate) from one display name to another's inbox and replies sent, or peer-not-found when the target is offline.")
    (door lobby room-roster (room)
          #:auth anonymous #:topic chat #:reply list #:kind read
          #:doc "Replies the display names currently in a meeting room (a topic string); joining a room is an act done through the authenticated session, this door only reads.")
    (door lobby live-rooms ()
          #:auth anonymous #:topic chat #:reply alist #:kind read
          #:doc "Replies every meeting room with anyone in it as ((room . names) ...), the always-on index the meeting wake reads.")
    (door lobby ice-servers ()
          #:auth anonymous #:topic chat #:reply alist #:kind read
          #:doc "Replies the ICE servers WebRTC peers find each other through, as a list of alists: \"urls\" always, \"username\" and \"credential\" when a relay wants them. The gateway's configuration decides the list; a client carries none of its own.")
    (door lobby vapid-public-key ()
          #:auth anonymous #:topic chat #:reply string #:kind read
          #:doc "Replies the web-push VAPID public key in base64, or \"\" when push is off on this gateway, so the browser knows whether to subscribe.")
    (door lobby register-push (device-id subscription-json)
          #:auth anonymous #:topic chat #:reply ok-or-error #:kind performative
          #:doc "Stores a device's web-push subscription JSON under its device id in the push store when one is configured and replies ok either way.")
    (door lobby unregister-push (device-id)
          #:auth anonymous #:topic chat #:reply ok-or-error #:kind performative
          #:doc "Removes a device's web-push subscription from the push store when one is configured and replies ok either way.")
    (door lobby open-terminal (identity-key client-inbox)
          #:auth anonymous #:topic operations #:reply error-stub #:kind performative
          #:doc "Answers the removed-role-gate error so an old client hears why terminal access has no wiring; per-scope membership credentials are the path a future terminal door takes.")
    (door lobby get-mailbox (identity-key)
          #:auth anonymous #:topic operations #:reply error-stub #:kind read
          #:doc "Answers the removed-role-gate error so an old client hears why mailbox access has no wiring; the authenticated session's mesh mailbox doors serve deliveries.")
    (door lobby planner ()
          #:auth anonymous #:topic planning #:reply capability #:kind read
          #:doc "Replies the planner facet: a capability forwarding only the planner doors declared anonymous and answering every other method with (error ...), keeping boot, admin and payout runners out of reach.")
    (door lobby online-users ()
          #:auth anonymous #:topic chat #:reply list #:kind read
          #:doc "Replies the display names connected to this gateway right now, which the contact book joins onto its online dot; presence is gateway-local.")
    (door lobby donation-address ()
          #:auth anonymous #:topic operations #:reply string #:kind read
          #:doc "Replies the Monero address of the wallet this gateway is wired to, so anyone can donate toward hosting, or #f when no wallet is configured or the read fails.")
    (door lobby has-role? (aid-prefix role)
          #:auth anonymous #:topic governance #:reply boolean #:kind read
          #:doc "Replies #f for every AID and role: the role-credential ceremony it read is gone, and the reply shape stays so an old client keeps working.")
    (door lobby get-result (id)
          #:auth anonymous #:topic governance #:reply mixed #:kind read
          #:doc "Replies a proposal's public tally: (closed . tally-record) for a recorded ballot, (open . live-result) for one still open, or (error ...) for an unknown id.")
    (door lobby list-proposals ()
          #:auth anonymous #:topic governance #:reply alist #:kind read
          #:doc "Replies ((proposal-id . status) ...) for every governance proposal, status open or closed, readable without a seat.")

    ;; ── session ──
    (door session whoami ()
          #:auth device #:topic identity #:reply string #:kind read #:to self
          #:doc "Replies the AID prefix this session cap is bound to, so the browser can check the cap it holds is the identity it expects.")
    (door session announce (name user-inbox)
          #:auth device #:topic chat #:reply list #:kind read #:to self
          #:doc "Binds a `browser` channel for this AID in the recipient registry and announces NAME with USER-INBOX to presence; replies presence's answer.")
    (door session leave (name)
          #:auth device #:topic chat #:reply list #:kind read #:to self
          #:doc "Unbinds this AID's `browser` channel from the recipient registry and tells presence NAME has left; replies presence's answer.")
    (door session join-room (room)
          #:auth device #:topic chat #:reply list #:kind read #:to self
          #:doc "Puts this AID itself on the roster of meeting ROOM (a non-empty string) via presence, so the walkie offers it mic connections; replies presence's answer or () when nothing was joined.")
    (door session leave-room (room)
          #:auth device #:topic chat #:reply list #:kind read #:to self
          #:doc "Takes this AID itself off the roster of meeting ROOM via presence; replies presence's answer or () when no presence or room was named.")
    (door session register-push (device-id subscription-json)
          #:auth device #:topic chat #:reply ok-or-error #:kind performative #:to self
          #:doc "Binds a `push` channel for DEVICE-ID under this AID and stores SUBSCRIPTION-JSON in the push store, so the notification router can reach this device; replies ok.")
    (door session unregister-push (device-id)
          #:auth device #:topic chat #:reply ok-or-error #:kind performative #:to self
          #:doc "Unbinds DEVICE-ID's `push` channel from this AID and drops its subscription from the push store; replies ok.")
    (door session present-contact-point (wire)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to self
          #:feature contact-points
          #:doc "Presents this AID's own contact-point credential WIRE (self-issued, blinded, signed): the commune checks it is the presenter's, of a kind it delivers on, and sends a code to the address itself. Replies (ok . pending), or an error. The channel binds on confirm-contact-point.")
    (door session confirm-contact-point (kind ctx code)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to self
          #:feature contact-points
          #:doc "Binds the presented (KIND CTX) channel under this AID when CODE is the code the commune sent to that address; replies (ok . #t), or an error for a wrong or lapsed code.")
    (door session withdraw-contact-point (kind ctx)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to self
          #:feature contact-points
          #:doc "Erases the (KIND CTX) channel bound under this AID and puts down one still waiting for its code — the deletion path for a contact point; replies (ok . #t).")
    (door session my-contact-points ()
          #:auth device #:topic identity #:reply alist #:kind read #:to self
          #:feature contact-points
          #:doc "Replies ((delivers . kinds) (points . rows)): the kinds this commune delivers on, and this AID's durable channels as (kind ctx state) with state bound or pending. Live browser and push bindings, which reconnects rebuild, stay out.")
    (door session sync-contacts (data)
          #:auth device #:topic chat #:reply ok-or-error #:kind constative #:to self
          #:doc "Stores DATA as the server-side backup of this AID's browser-held contact book (512 KiB cap); replies ok or an error with the failure.")
    (door session list-contacts ()
          #:auth device #:topic chat #:reply alist-list #:kind read #:to self
          #:doc "Replies the server-side backup of this AID's contact book as stored by sync-contacts, or () when none is held.")
    (door session sync-log (data)
          #:auth device #:topic commitments #:reply ok-or-error #:kind constative #:to self
          #:doc "Stores DATA, the browser's opaque JSON captain's log, as this AID's server-side backup; replies ok or an error with the failure.")
    (door session list-log ()
          #:auth device #:topic commitments #:reply json #:kind read #:to self
          #:doc "Replies this AID's captain's log backup as the opaque JSON string sync-log stored, or \"\" when none is held.")
    (door session sync-pins (data)
          #:auth device #:topic slots #:reply ok-or-error #:kind preference #:to self
          #:doc "Stores DATA as this AID's pin book backup and folds the lists marked shared into the scope's `^pins` aggregator; replies ok or an error with the failure.")
    (door session list-pins ()
          #:auth device #:topic slots #:reply json #:kind read #:to self
          #:doc "Replies this AID's pin book as the JSON string sync-pins stored, or \"\" when none is held.")
    (door session our-pin-lists ()
          #:auth device #:topic slots #:reply alist-list #:kind read #:to self
          #:doc "Lists the commune's shared pin lists read off the `^pins` fold, or () when no pin fold is wired.")
    (door session our-pins (list-id)
          #:auth device #:topic slots #:reply alist-list #:kind read #:to self
          #:doc "Replies the members of one shared pin list LIST-ID read off the `^pins` fold, or () when no pin fold is wired.")
    (door session sync-taxonomy (data)
          #:auth device #:topic knowledge #:reply ok-or-error #:kind preference #:to self
          #:doc "Stores DATA as this AID's taxonomy cut and contributes it to the scope's folksonomy aggregator, since publishing a cut is voting; replies ok or an error.")
    (door session list-taxonomy ()
          #:auth device #:topic knowledge #:reply alist #:kind read #:to self
          #:doc "Replies this AID's published taxonomy cut as stored by sync-taxonomy, or () when none is held.")
    (door session folksonomy-template (#:optional (lens #f))
          #:auth device #:topic knowledge #:reply alist #:kind read #:to self
          #:doc "Replies the commune's aggregated taxonomy cut as a {id,label,children,count} template, weighted toward LENS (a name resolved against this AID's own contact book) when given, or the global cut.")
    (door session adopt-lens (#:optional (lens #f))
          #:auth device #:topic knowledge #:reply void #:kind preference #:to self
          #:doc "Resolves LENS's (or, absent, the global) aggregated cut server-side, flattens it to structure edges and publishes it as this AID's own taxonomy cut; replies ok, or () when no folksonomy is wired.")
    (door session profile ()
          #:auth device #:topic identity #:reply alist #:kind read #:to self
          #:doc "Replies this AID's member record as an alist of username, display-name and email, or #f when the AID holds no seat.")
    (door session update-profile (display-name email)
          #:auth device #:topic identity #:reply ok-or-error #:kind constative #:to self
          #:doc "Sets this AID's own DISPLAY-NAME and EMAIL on its member record, validating a non-empty email; replies ok or an error.")
    (door session fp-status (scope-id)
          #:auth device #:topic identity #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok . alist) with this AID's personhood standing in SCOPE-ID: person, governor, whether personhood is bootstrapped, and the verified count.")
    (door session fp-vouch (scope-id subject-aid rel)
          #:auth device #:topic identity #:reply ok-or-error #:kind constative #:to governance
          #:doc "Issues an unsigned relationship credential from this AID for SUBJECT-AID with relation REL, ending prior vouches; replies (ok . #t) or an error. Prefer fp-vouch-signed when the browser can sign.")
    (door session fp-vouch-preimage (scope-id subject-aid rel at)
          #:auth device #:topic identity #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok fields), the SAID-relevant fields of the relationship credential this AID would issue for SUBJECT-AID at AT, so the browser re-derives the SAID and signs it for fp-vouch-signed.")
    (door session fp-vouch-signed (scope-id subject-aid rel at signature)
          #:auth device #:topic identity #:reply ok-or-error #:kind constative #:to governance
          #:doc "Rebuilds the vouch from the same wire args, verifies SIGNATURE is this AID's own, ends prior vouches for SUBJECT-AID and issues it; replies (ok said) or an error.")
    (door session fp-withdraw-vouch (scope-id subject-aid)
          #:auth device #:topic identity #:reply ok-or-error #:kind constative #:to governance
          #:doc "Ends every standing vouch from this AID for SUBJECT-AID; the vouch is the voucher's own to end. Replies (ok . #t), also when none stood.")
    (door session relationships (scope-id)
          #:auth device #:topic identity #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok . rows), one row per person in this AID's contact book: whether they are recognised, the kind this AID's standing vouch for them states (mine), the kind theirs for this AID states (theirs), and their open ask to be recognised in SCOPE-ID. A row names only what stands between the two.")
    (door session give-card (subject-aid wire)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to self
          #:doc "Keeps this AID's card for SUBJECT-AID, someone in its contacts: WIRE is {from,to,at,sealed,said,sig}, its content sealed to the receiver and its identifier signed by the giver. The commune checks the signature and keeps the ciphertext, in place of any earlier card to that person. Replies (ok . #t) or an error.")
    (door session withdraw-card (subject-aid)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to self
          #:doc "Erases this AID's card for SUBJECT-AID; replies (ok . #t), also when none stood.")
    (door session cards ()
          #:auth device #:topic identity #:reply ok-or-error #:kind read #:to self
          #:doc "Replies (ok . rows), one row per person in this AID's contact book with a card either way: the card they gave (its wire, sealed to this AID) and when this AID's own card to them was made.")
    (door session fp-request-enroll (scope-id)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to governance
          #:doc "Opens this AID's own enrollment ceremony in SCOPE-ID's ecosystem at the policy's quorum, durable on every witness rail; replies (ok . #t) or an error when already recognised.")
    (door session fp-pending (scope-id)
          #:auth device #:topic identity #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok . rows), the standing enrollment asks in SCOPE-ID's ecosystem with each candidate's progress and vouchers, after expiring stale ones.")
    (door session fp-my-ceremony (scope-id)
          #:auth device #:topic identity #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok . alist) with this AID's own ask: state none, collecting (count, quorum, witnesses, vouchers) or finalized.")
    (door session fp-grant (scope-id candidate-aid)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to governance
          #:doc "The genesis act: a governor issues personhood to CANDIDATE-AID in an ecosystem where nobody is recognised yet; replies (ok . #t) or an error once personhood is bootstrapped.")
    (door session fp-open-ceremony (scope-id candidate-aid k)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to governance
          #:doc "A recognised person introduces CANDIDATE-AID by opening their enrollment ceremony at the ecosystem's quorum with this AID as sponsor (K is ignored); replies (ok . #t) or an error.")
    (door session my-phc ()
          #:auth device #:topic identity #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok . wire), this AID's live personhood credential as a portable card with the issuer's signature, or (ok . #f) when the AID holds none.")
    (door session present-phc (wire)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to governance
          #:doc "Verifies a personhood credential WIRE from another gateway (holder is this AID, issuer signature, trusted issuer) and imports it; replies (ok . #t) or an error. present-bundle takes a whole bundle.")
    (door session my-vouches ()
          #:auth device #:topic identity #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok . json), the portable bundle this AID carries to another gateway: personhoods, vouches, issuer blessings and key logs, or \"\" when there is nothing to carry.")
    (door session present-bundle (wire)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to governance
          #:doc "Verifies a bundle WIRE from elsewhere in dependency order and imports it only when every card stands; replies (ok . newly-imported) or an error.")
    (door session sync-credentials (data)
          #:auth device #:topic identity #:reply ok-or-error #:kind constative #:to self
          #:doc "Stores DATA, the browser's bran-sealed credential blob the gateway cannot read, as this AID's zero-knowledge backup; replies ok or an error.")
    (door session list-credential-backups ()
          #:auth device #:topic identity #:reply string #:kind read #:to self
          #:doc "Replies the sealed credential backup blob sync-credentials stored for this AID, which the browser decrypts client-side on a fresh device, or () when none is held.")
    (door session watch-credentials (watcher-ref)
          #:auth device #:topic identity #:reply ok-or-error #:kind read #:to self
          #:doc "Registers WATCHER-REF to receive on-credential pushes whenever the poller admits a new credential for this AID, replacing polling after the first list-credentials; replies ok.")
    (door session unwatch-credentials (watcher-ref)
          #:auth device #:topic identity #:reply ok-or-error #:kind read #:to self
          #:doc "Deregisters WATCHER-REF from this AID's credential pushes; replies ok.")
    (door session store-shamir-shares (source-aid threshold shares)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to self
          #:doc "Parks the guardian recovery SHARES with SOURCE-AID and THRESHOLD in this AID's user file for later reconstruction; replies ok or an error.")
    (door session get-shamir-shares ()
          #:auth device #:topic identity #:reply alist #:kind read #:to self
          #:doc "Replies the guardian recovery shares parked for this AID as an alist of source, threshold and shares, or () when none are held.")
    (door session tier ()
          #:auth device #:topic identity #:reply symbol #:kind read #:to self
          #:doc "Replies root or device: whether the passcode key or an enrolled device key proved this session.")
    (door session enroll-device (wire-json)
          #:auth root #:topic identity #:reply ok-or-error #:kind performative #:to self
          #:doc "Records a device authorization WIRE-JSON signed by this AID's root key after verifying it against the current KEL key; replies ok or an error, and refuses a device-tier session.")
    (door session my-devices ()
          #:auth device #:topic identity #:reply alist-list #:kind read #:to self
          #:doc "Lists the devices this AID's root has authorized, each as a wire alist.")
    (door session revoke-device (said)
          #:auth device #:topic identity #:reply ok-or-error #:kind performative #:to self
          #:doc "Retires the device credential SAID from this AID's registry from either tier, so a lost phone is revoked from the laptop; replies ok or an error when no such device exists.")
    (door session forget-me ()
          #:auth root #:topic identity #:reply alist #:kind performative #:to self
          #:feature erasure
          #:doc "Erases every record of this gateway's own keyed by this AID — bindings, push subscriptions, contact points, devices, cards, user files, mailboxes, spooled mail — and last the member record and AID-to-handle index, leaving the key log as data about a pseudonym; replies the receipt (what went, by kind and count, and what stays), refuses a device-tier session, and this session cap refuses everything from then on.")
    (door session rotate-aid (rot-alist-raw sigs)
          #:auth root #:topic identity #:reply ok-or-error #:kind performative #:to self
          #:doc "Verifies rotation event ROT-ALIST-RAW with SIGS against this AID's key state and appends it to the oobi-host KEL; replies ok or an error, and refuses a device-tier session.")
    (door session relay-announce! (packet-hex)
          #:auth device #:topic chat #:reply ok-or-error #:kind constative #:to self
          #:doc "Verifies a browser-signed Reticulum announce PACKET-HEX against this AID's KEL-anchored mesh pubkey, registers its destination and forwards it under a 30-per-60 s budget; replies ok or an error.")
    (door session send-mesh-packet! (packet-hex)
          #:auth device #:topic chat #:reply ok-or-error #:kind constative #:to self
          #:doc "Transmits a browser-composed mesh DATA packet PACKET-HEX through the bridge under the same 30-per-60 s budget, refusing any other packet type; replies ok or an error.")
    (door session drain-mesh-mailbox ()
          #:auth device #:topic chat #:reply alist #:kind constative #:to self
          #:doc "Drains the ciphertext held for every destination derived from this AID's KEL-anchored mesh pubkey; replies ((dest-hex . #(payload-hex ...)) ...) with only non-empty mailboxes.")
    (door session list-credentials ()
          #:auth device #:topic identity #:reply alist-list #:kind read #:to self
          #:doc "Lists the credentials in this gateway's own store whose holder is this AID, or () when no store is wired.")
    (door session issue-credential (cred-alist-raw)
          #:auth device #:topic identity #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Issues an ACDC this AID authored (issuer must match the caller) into this gateway's store; refuses unless the caller holds governor standing. Replies the credential's SAID, or an error.")
    (door session revoke-credential (said)
          #:auth device #:topic identity #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Revokes the credential named by SAID; refuses unless the caller holds governor standing. Governance may revoke any credential by policy, not only ones it issued itself.")
    (door session open (kind domain id description franchise #:optional (target-ids #f) (subject #f))
          #:auth device #:topic governance #:reply ok-or-error #:kind performative #:to governance
          #:doc "Opens a ballot or expression proposal ID in DOMAIN under FRANCHISE as this governor AID, snapshotting voice weights; TARGET-IDS is required when KIND is expression (the distribution's own targets), ignored for a ballot; SUBJECT is an optional \"kind:id\" the forum resolves against. Replies (ok id) or an error when the id is already open or closed.")
    (door session cast (id arg)
          #:auth device #:topic governance #:reply ok-or-error #:kind preference #:to governance
          #:doc "Casts this AID's unsigned stance ARG on proposal ID and issues a stance credential; replies ok or an error. Use cast-signed when the client can sign.")
    (door session stance-preimage (id position)
          #:auth device #:topic governance #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok fields), the SAID fields of the stance credential this AID would cast on ID with POSITION, so the client re-derives the SAID and signs it for cast-signed.")
    (door session cast-signed (id position timestamp signature u)
          #:auth device #:topic governance #:reply ok-or-error #:kind preference #:to governance
          #:doc "Casts POSITION on ID under the client's own signature over the stance-preimage fields, U echoed back from stance-preimage's own claims, verified against this AID's current KEL key (resolved server-side, never a caller argument); replies ok or an error, including when U is missing.")
    (door session part-stance-preimage (scope-id hand-json)
          #:auth device #:topic governance #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok fields), the SAID fields of the plan-part stance credential this AID would cast on SCOPE-ID with HAND-JSON, a JSON object of part-string (parts.scm grammar, e.g. \"process=bake;place=town\") to a signed portion in [-1, 1]; the client re-derives the SAID and signs it for cast-part-signed.")
    (door session cast-part-signed (scope-id hand-json timestamp signature u)
          #:auth device #:topic governance #:reply ok-or-error #:kind preference #:to governance
          #:doc "Casts this AID's HAND of stances on parts of SCOPE-ID's plan under the client's own signature over the part-stance-preimage fields (U echoed back), revokes the AID's previous hand there, and hands the scope's standing hands to the planner's voice fold; replies ok or an error. docs/planning/voice/voice-follows-work.md.")
    (door session declare-span (scope-aid resource-id place #:optional (until #f))
          #:auth device #:topic custody #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Declares, for SCOPE-AID and as one of its governors, that RESOURCE-ID's service pool stands at PLACE (a span declaration, issuer = holder = the scope, live until UNTIL when given); a solve reads the standing declarations through the consent gate (a foreign place needs the host's hosting willingness). Replies (ok said) or an error.")
    (door session admit-commune (federation-aid commune-aid sturdyref-uri #:optional (ratification #f))
          #:auth device #:topic governance #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Admits the commune COMMUNE-AID into the federation FEDERATION-AID this gateway holds, at the sturdyref its peer answers at, as one of the federation's governors (the federation's own ladder decides whether it recognises the caller, and its governance policy may require the commune's consent as RATIFICATION, a SAID). The goods that cross are not named: the commune tells the federation what it deals in. Replies ok or an error.")
    (door session declare-hosting (scope-aid resource-spec ceiling #:optional (until #f))
          #:auth device #:topic custody #:reply promise:ok-or-error #:kind preference #:to governance
          #:doc "Declares, for SCOPE-AID and as one of its governors, its willingness to host pools of RESOURCE-SPEC up to CEILING unit-hours a day (hosting willingness, live until UNTIL when given): the consent a foreign span into this scope's places needs, and the ceiling the means consensus binds. Replies (ok said) or an error.")
    (door session claim-regime (scope-aid domain-spec tails process #:optional (until #f))
          #:auth device #:topic planning #:reply promise:ok-or-error #:kind constative #:to governance
          #:doc "Claims, for SCOPE-AID and as one of its governors, the regime of DOMAIN-SPEC (a recipe id): TAILS thin|fat|unknown and PROCESS stable|shifting|unknown. Thin and stable together license statistics in that domain's standing (recipe-standing live-regime-of); anything else reads probability-free. Replies (ok said) or an error.")
    (door session declare-means (scope-id spec qty unit location #:optional (arcs-json #f) (note #f) (emoji #f) (name #f) (cats-json #f) (criteria-json #f))
          #:auth device #:topic slots #:reply ok-or-error #:kind constative #:to planner
          #:doc "Seeds or edits this AID's owned resource `means:AID:SPEC` in SCOPE-ID with qty, unit, location and the optionals; replies (ok . resource-id).")
    (door session declare-need (scope-id spec qty unit location arcs-json note emoji from until #:optional (name #f) (cats-json #f) (criteria-json #f) (need-kind #f) (voice 0))
          #:auth device #:topic slots #:reply ok-or-error #:kind preference #:to planner
          #:doc "Declares or edits this AID's standing need intent `need:AID:SPEC` in SCOPE-ID with window, note, emoji, bounds and the optionals; replies (ok (id . intent-id)) or an error.")
    (door session need-displacement (scope-id spec qty)
          #:auth device #:topic planning #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies what QTY of SPEC currently displaces elsewhere in SCOPE-ID's plan, read off the last solve's duals with the honesty radius; nothing re-solves and an unsolved scope reads nothing.")
    (door session externality-history (scope-id)
          #:auth device #:topic planning #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies SCOPE-ID's burn meter: the externality display accumulated one snapshot per solve, summarized as its moved-distribution.")
    (door session ratify-kind (scope-id spec kind)
          #:auth device #:topic planning #:reply ok-or-error #:kind performative #:to planner
          #:doc "Records that SCOPE-ID ratifies SPEC as KIND (floor or held) under this AID's name, or withdraws the grant with des; replies (ok (spec kind)).")
    (door session ratified-kinds (scope-id)
          #:auth device #:topic planning #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies SCOPE-ID's ratification grants as rows of spec, kind, by and at.")
    (door session audit-kinds (scope-id #:optional (options #f))
          #:auth device #:topic planning #:reply ok-or-error #:kind performative #:to planner
          #:doc "Audits SCOPE-ID's held and floor need rows against what their citizens actually took, withdrawing padded grants and recording every verdict under this AID; OPTIONS may carry consequence-factor and tolerance overrides. Replies examined, padded and findings.")
    (door session audits (scope-id)
          #:auth device #:topic planning #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies SCOPE-ID's recorded audit findings from the plan-store's audits meta.")
    (door session my-slots (scope-id)
          #:auth device #:topic slots #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies this AID's own standing needs and non-retired means in SCOPE-ID as (needs means) rows with qty, unit, place, note, emoji and window arcs.")
    (door session our-slots (scope-id home-scope-id)
          #:auth device #:topic slots #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies the fold's reading at SCOPE-ID, needs and means summed per cell with nobody named, each carrying `mine`, this AID's own share joined from HOME-SCOPE-ID.")
    (door session retire-need (scope-id spec)
          #:auth device #:topic slots #:reply ok-or-error #:kind performative #:to planner
          #:doc "Withdraws this AID's standing need for SPEC in SCOPE-ID by removing the intent entirely; replies (ok . intent-id).")
    (door session retire-means (scope-id spec)
          #:auth device #:topic slots #:reply ok-or-error #:kind performative #:to planner
          #:doc "Withdraws this AID's offer of SPEC in SCOPE-ID by lowering the means to zero, keeping the record and its history; replies (ok . resource-id).")
    (door session request-payout (scope-id address xmr due note)
          #:auth device #:topic stock #:reply ok-or-error #:kind performative #:to planner
          #:feature payouts
          #:doc "Records this AID's standing intent to have the commons send XMR of its claim to ADDRESS by DUE, checked against what is available; replies (ok (id available)) or an error.")
    (door session my-payouts (scope-id)
          #:auth device #:topic stock #:reply ok-or-error #:kind read #:to planner
          #:feature payouts
          #:doc "Replies this AID's payout standing in SCOPE-ID: available claim, what the commons owes it, and its payout intents with state.")
    (door session scope-readings (scope-id spec)
          #:auth device #:topic stock #:reply ok-or-error #:kind read #:to planner
          #:doc "What every source says of SPEC in SCOPE-ID: the reading fold's rows, drift and freshest reading (planner scope-readings), for the inventory face.")
    (door session readings-between (scope-id spec from until)
          #:auth device #:topic stock #:reply ok-or-error #:kind read #:to planner
          #:doc "What every source reported of SPEC in SCOPE-ID between FROM and UNTIL (ISO-8601, an empty string leaves an end open): one row per reading in time order, and their fold (planner readings-between), for the inventory face's history line.")
    (door session my-claims (scope-id)
          #:auth device #:topic stock #:reply ok-or-error #:kind read #:to planner
          #:feature credit
          #:doc "Replies this AID's order book in SCOPE-ID: each want as asked (no row yet), held (the plan's claim commitment, with what remains) or taken, priced at the good's crystallized SNLT.")
    (door session my-credit-history (scope-id)
          #:auth device #:topic stock #:reply ok-or-error #:kind read #:to planner
          #:feature credit
          #:doc "Replies this AID's credit as a dated account in SCOPE-ID, newest first: work earned, work waiting out its validation window, hours drawn by claims, and acts the log backed out — each with its hours, so earned less drawn is the certificate's balance.")
    (door session retire-payout (scope-id id)
          #:auth device #:topic stock #:reply ok-or-error #:kind performative #:to planner
          #:feature payouts
          #:doc "Cancels this AID's own pending payout intent ID in SCOPE-ID; replies (ok (id)) or an error when it is settled or belongs to someone else.")
    (door session record-purchase (scope-id spec qty unit money-spec cost where note receipt donation?)
          #:auth device #:topic stock #:reply ok-or-error #:kind constative #:to planner
          #:doc "Raises QTY of SPEC bought or donated by this AID for the commons, linked to any planned commitment it fulfils; replies resource and event ids plus cost, money-spec and planned? unless it was a gift.")
    (door session declare-skill (scope-id skill-spec-id)
          #:auth device #:topic slots #:reply ok-or-error #:kind constative #:to planner
          #:doc "Self-declares this AID's labour-power SKILL-SPEC-ID in SCOPE-ID as a held skill resource, re-raising a revoked one, and refolds the labour pool; replies (ok . resource-id).")
    (door session revoke-skill (scope-id skill-spec-id)
          #:auth device #:topic slots #:reply ok-or-error #:kind constative #:to planner
          #:doc "Withdraws this AID's self-declared SKILL-SPEC-ID in SCOPE-ID by lowering it to zero, keeping the record; replies (ok . resource-id).")
    (door session my-skills (scope-id)
          #:auth device #:topic slots #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies (ok (skills . ids)), the skills this AID currently holds in SCOPE-ID.")
    (door session my-skill-standing (scope-id)
          #:auth device #:topic slots #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies (ok (standing . rows)), one row per skill this AID holds or has practiced in SCOPE-ID, in hours: validated hours, where the skill's competence stands today under its own law, work events, how many reached a witness quorum, distinct co-signers, witnessed hours, and ceremonies still collecting.")
    (door session observe-contrary-preimage (scope-id process action spec nominal reading witness at)
          #:auth device #:topic slots #:reply ok-or-error #:kind read #:to governance
          #:doc "The SAID-relevant fields of this AID's contrary observation on SCOPE-ID's map — PROCESS's ACTION on SPEC read READING where the map states NOMINAL, on the WITNESS of a work event of this AID's on that process, AT — for the client to re-derive and sign with its own key; refused unless the witness is this AID's own run of that process. docs/planning/voice/feasibility-follows-the-map.md.")
    (door session observe-contrary-signed (scope-id process action spec nominal reading witness at signature)
          #:auth device #:topic slots #:reply ok-or-error #:kind constative #:to governance
          #:doc "Lands the observation whose preimage observe-contrary-preimage gave, SIGNATURE this AID's own over its SAID, superseding this AID's earlier observation on the same process and action; the scope's next solve reads it in every future, in the cautious direction only; replies (ok said).")
    (door session observe-contrary (scope-id process action spec nominal reading witness)
          #:auth device #:topic slots #:reply ok-or-error #:kind constative #:to governance
          #:doc "The unsigned fallback of observe-contrary-signed for a session with no resident key; replies (ok said).")
    (door session contrary-observations (scope-id)
          #:auth device #:topic slots #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok . rows), every standing contrary observation on SCOPE-ID's map: (observer process action spec nominal reading witness observed-at).")
    (door session slots-at (scope-id)
          #:auth device #:topic slots #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies SCOPE-ID's whole live slot pool: every citizen's standing needs and the means held by grant, each with `drawn` from the last solve; a merely declared private means stays out.")
    (door session family-split (needs-json purse labour-h weighted? #:optional (members-json "[]") (per-citizen-hours 40.0))
          #:auth device #:topic planning #:reply ok-or-error #:kind read #:to planner
          #:doc "Splits a household purse across NEEDS-JSON by harmony, with optional member voice and per-citizen hours, writing nothing; replies the per-member rows.")
    (door session family-bills (needs-json purse labour-h weighted? eur-per-hour #:optional (members-json "[]") (per-citizen-hours 40.0))
          #:auth device #:topic planning #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies the week's three bills for NEEDS-JSON: the euros and hours beyond the purse for rights, then needs, then wants held as walls, at EUR-PER-HOUR; nothing is written.")
    (door session family-externalities (needs-json purse labour-h weighted?)
          #:auth device #:topic planning #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies, beside each held or wanted row of NEEDS-JSON, the euros the other members would have received had it stayed unasked; nothing is written.")
    (door session match-slots (scope-id #:optional (lens #f))
          #:auth device #:topic slots #:reply mixed #:kind read #:to planner
          #:doc "Replies the ring for SCOPE-ID: every standing need scored against every declared means by classification affinity and time, through LENS when given; replies needs, means and matches.")
    (door session set-position (scope-id period place)
          #:auth device #:topic places #:reply ok-or-error #:kind constative #:to planner
          #:feature location
          #:doc "Records where this AID is at PERIOD (0 = now, later = expected) as known place id PLACE, the planner's commute origin; #f clears; replies (ok . place) or (ok . cleared).")
    (door session set-position-latlon (scope-id period lat lon)
          #:auth device #:topic places #:reply ok-or-error #:kind constative #:to planner
          #:feature location
          #:doc "Snaps LAT/LON to SCOPE-ID's nearest known place server-side and records that place as this AID's position at PERIOD, so a shared position is a place rather than a trace; replies (ok . place).")
    (door session set-location-sharing (scope-id mode)
          #:auth device #:topic places #:reply ok-or-error #:kind constative #:to planner
          #:doc "Declares whether this AID shares where they are: MODE live (a watched fix), here (one fix) or off, stated once at their home so every device reads the same; off ends the fix that stands and refuses the next; replies (ok . mode).")
    (door session location-sharing (scope-id)
          #:auth device #:topic places #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies the mode this AID declared for sharing where they are (live, here or off), or undeclared; nothing is written.")
    (door session set-home (scope-id place lat lon)
          #:auth device #:topic places #:reply ok-or-error #:kind constative #:to planner
          #:feature location
          #:doc "Registers this AID's home in SCOPE-ID, the place every position rule falls back to: a known place id, or \"\" with LAT/LON to declare the AID's own `place:AID:home`; replies (ok (place . id)).")
    (door session declare-dwelling (scope-id place area rooms warmth-winter warmth-summer beds attests-json certified rent tenure)
          #:auth device #:topic places #:reply ok-or-error #:kind constative #:to planner
          #:doc "Declares the dwelling this AID lives in, at PLACE (\"\" = the registered home): its floor area in m² and its rooms, shared by the beds it houses a night, the warmth it is kept at in winter and in summer in °C, the gates an inspection would attest, whether that certificate stands, its own rent per night where a landlord is paid, and the tenure; replies (ok (resource . id) (place . id) (tags …)).")
    (door session declare-place (scope-id name lat lon #:optional (address #f) (parent #f))
          #:auth device #:topic places #:reply ok-or-error #:kind constative #:to planner
          #:doc "Names a new spatial thing in SCOPE-ID with id `place:AID:slug`, optional coordinates and ADDRESS, re-placing it when named again. PARENT names the place it is inside (a room in a site, a shelf in a room): its id is then `PARENT/slug`, and it stands at its parent's position when it states none. Replies (ok (id)) or an error.")
    (door session count-schedule (scope-id #:optional (regime #f))
          #:auth device #:topic stock #:reply ok-or-error #:kind read #:to planner
          #:doc "The schedule of counts in SCOPE-ID: a row for each thing the inventory shows that sits in no other, soonest due first, with the lines one visit counts, the counter's hours, the interval between counts (from what the plan stakes on the figure and how far counts have found the ledger off), its class (A, B or C), when it was last counted and when it is due. REGIME (announced, undisclosed, random) sets how the next window falls; absent, announced. Replies (ok (rows)).")
    (door session plan-counts (scope-id #:optional (regime #f) (counter #f) (at-most #f))
          #:auth device #:topic commitments #:reply ok-or-error #:kind performative #:to planner
          #:doc "Lays the counts due in SCOPE-ID, those whose window is open and asked of nobody yet, as directed work offers through the offer loop (so held to its bound on open offers), AT-MOST of them a call (3 when absent), each to COUNTER where one is named and else to the member whose turn it is, the stock's owner passed over while another can count it. A count due later is announced by count-schedule and offered when its window opens. Under REGIME undisclosed or random the commitment is read by its counter alone until its window opens, and the count is blind. Replies (ok (laid due)), with (refused kind) when the offer loop stopped the walk.")
    (door session scope-replica (scope-id)
          #:auth device #:topic stock #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies SCOPE-ID as this AID's device holds a copy of it: one text carrying the scope's goods, places, people, the needs standing in it and the observer's books (its stock and the events behind it), each serialized as its own store keeps it. A device seeds its copy from it on taking a seat and after it flushes what it queued, so the same doors answer there with no gateway in reach.")
    (door session count-history (scope-id resource-id #:optional (limit #f))
          #:auth device #:topic stock #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies the counts of RESOURCE-ID in SCOPE-ID, newest first, LIMIT of them (5 when absent): each count that found the ledger off, as (id at delta unit counter technique evidence mine), DELTA signed as the adjustment landed and EVIDENCE the hash of the picture the count names, \"\" when none. A count voided by a contest is gone from it. What a member reads to contest a count.")
    (door session contests (scope-id)
          #:auth device #:topic governance #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies the contests open in SCOPE-ID as they stand to this AID: each as (id event-id kind resource worker by reason role), KIND work or count, RESOURCE the stock a count is of (empty for work), ROLE attach when the act is this AID's own (a count's counter attaches the picture), vote when this AID is in the franchise, none otherwise.")
    (door session evidence-part (ballot-id hash part-no parts part)
          #:auth device #:topic governance #:reply ok-or-error #:kind performative #:to self
          #:doc "Attaches the counter's picture to the contest BALLOT-ID, one part of PARTS (26 at the most), PART a run of its base64 sixteen kilobytes at the most, PART-NO from 0 and in order, HASH the sha256 the count names. Only the counter whose act is contested may attach, and only the picture the count names. The last part joins them, checks the bytes hash to HASH and holds the picture until the ballot settles. Replies (ok . characters-held) or (ok . held), or an error.")
    (door session evidence-chunk (ballot-id part-no)
          #:auth device #:topic governance #:reply ok-or-error #:kind read #:to self
          #:doc "Replies part PART-NO of the picture held for the contest BALLOT-ID, to the counter and the franchise: (ok (part total hash)), PART a run of its base64. An error when no picture is held, or the caller is neither.")
    (door session label-stock (scope-id resource-id)
          #:auth device #:topic stock #:reply ok-or-error #:kind constative #:to planner
          #:doc "Replies the code RESOURCE-ID is known by in SCOPE-ID, for its label: six characters, unique in the scope, silent about owner and contents; given on the first asking and the same on every asking after. Replies (ok (code id name minted)) with MINTED true when this asking gave the code, or a failure.")
    (door session read-label (scope-id code)
          #:auth device #:topic stock #:reply ok-or-error #:kind read #:to planner
          #:doc "What the label CODE names in SCOPE-ID: the resource, where it is, and the resources it contains. A typed I, L or O reads as the digit it resembles. Replies (ok (resource contents)) or a failure.")
    (door session socialize-preimage (commune-aid spec qty until movable rt cf res kind ref #:optional (eligible #f))
          #:auth device #:topic custody #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok fields), the SAID fields of the custody grant this AID would issue to COMMUNE-AID over SPEC, with ELIGIBLE carrying the owner's steward rule as JSON, for the client to sign for socialize-signed.")
    (door session socialize-signed (commune-aid spec qty until movable rt cf res kind ref signature #:optional (eligible #f))
          #:auth device #:topic custody #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Issues the custody grant under this AID's own SIGNATURE after checking no standing title names another owner, then tells the planner the commune's pool moved; replies (ok said) or an error.")
    (door session my-grants ()
          #:auth device #:topic custody #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok rows), the live custody grants this AID holds out: said, spec, commune, until, qty, consume or use, and steward rule.")
    (door session desocialize (said)
          #:auth device #:topic custody #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Recalls this AID's custody grant SAID, revoking it and telling the planner the commune's pool moved; replies (ok . result) or an error.")
    (door session purchase-claim-preimage (commune-aid spec qty unit due res ref trig)
          #:auth device #:topic stock #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok fields), the SAID fields of the reimbursement claim this AID would raise on COMMUNE-AID for a purchase (triggered by event TRIG), for the client to sign for purchase-claim-signed.")
    (door session purchase-claim-signed (commune-aid spec qty unit due res ref trig signature)
          #:auth device #:topic stock #:reply ok-or-error #:kind performative #:to governance
          #:doc "Issues the reimbursement claim under this AID's own SIGNATURE over the purchase-claim-preimage fields; replies (ok said) or an error.")
    (door session accept-socialization (commune-aid grant-said)
          #:auth device #:topic custody #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Accepts custody grant GRANT-SAID into COMMUNE-AID's scope as this AID and tells the planner the pool moved; any authenticated member may accept today; replies (ok result) or an error.")
    (door session accept-reimbursement (commune-aid claim-said)
          #:auth device #:topic stock #:reply ok-or-error #:kind performative #:to governance
          #:doc "Accepts reimbursement claim CLAIM-SAID for COMMUNE-AID as this AID, minting the commons' debt, refusing the claimant's own claim; replies (ok debt-said amount) or an error.")
    (door session own-means-preimage (resource-id spec qty qty-unit ref)
          #:auth device #:topic custody #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok fields), the SAID fields of the ownership title this AID would issue itself over RESOURCE-ID, for the client to sign for own-means-signed.")
    (door session own-means-signed (resource-id spec qty qty-unit ref signature)
          #:auth device #:topic custody #:reply ok-or-error #:kind performative #:to governance
          #:doc "Issues the ownership title over RESOURCE-ID under this AID's own SIGNATURE over the own-means-preimage fields; replies (ok said) or an error.")
    (door session my-titles ()
          #:auth device #:topic custody #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok rows), the live ownership titles this AID holds: said, resource id, spec and kind.")
    (door session disown-means (said)
          #:auth device #:topic custody #:reply ok-or-error #:kind performative #:to governance
          #:doc "Withdraws this AID's ownership title SAID by revoking it; replies (ok . result) or an error.")
    (door session delegation-preimage (delegate-aid fraction #:optional (scope-id #f))
          #:auth device #:topic governance #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok fields), the SAID fields of the liquid delegation of FRACTION to DELEGATE-AID — federation-wide, or scoped to SCOPE-ID when given — for the client to sign for set-delegation-signed. Pass the SAME SCOPE-ID there: it is baked into this SAID.")
    (door session set-delegation-signed (delegate-aid fraction signature #:optional (scope-id #f))
          #:auth device #:topic governance #:reply ok-or-error #:kind preference #:to governance
          #:doc "Records the delegation of FRACTION to DELEGATE-AID under this AID's own SIGNATURE over the delegation-preimage fields; SCOPE-ID must match the one that preimage was asked for. Replies ok or an error.")
    (door session close (id)
          #:auth device #:topic governance #:reply ok-or-error #:kind performative #:to governance
          #:doc "Closes proposal ID as this governor AID, recording the tally and issuing a signed tally-result credential for a ballot; replies (ok id) or an error.")
    (door session contest-work (scope-id event-id reason)
          #:auth device #:topic governance #:reply ok-or-error #:kind performative #:to governance
          #:doc "Contests work EVENT-ID in SCOPE-ID as this AID, a member of the scope other than the worker: opens the ballot contest:EVENT-ID under the scope's producer voice with the worker's voice left out, positions void and stands, REASON as its question; at the close, void at half the voice or more corrects the work to nothing. A count's adjustment, its record or its hours may be named: the contest is the count's, one per count, and at the close every part of the count is corrected to nothing. Replies (ok id), or an error when the event is no standing work or count, the caller is the worker or no member, or the work is already contested.")
    (door session list-proposals ()
          #:auth device #:topic governance #:reply alist #:kind read #:to governance
          #:doc "Lists every proposal known to the ballot store as (id . status) pairs, status open or closed.")
    (door session get-result (id)
          #:auth device #:topic governance #:reply mixed #:kind read #:to governance
          #:doc "Replies proposal ID's result with its meta: (closed . tally) once closed, (open . live-tally) while open, or an error for an unknown id.")
    (door session list-delegations ()
          #:auth device #:topic governance #:reply list #:kind read #:to governance
          #:doc "Lists this AID's federation-default delegations as (delegate-aid fraction mandated?) rows.")
    (door session my-voice ()
          #:auth device #:topic governance #:reply alist #:kind read #:to governance
          #:doc "Replies this AID's producer voice (labour share) and consumer voice (share of the claimable pool, -1 when the pool is empty) across the scope roots.")
    (door session voice-in (scope-id)
          #:auth device #:topic governance #:reply alist #:kind read #:to governance
          #:doc "Replies this AID's producer voice in the one commune SCOPE-ID, the ballot weight its franchise gives; a commune the gateway cannot name answers 0.")
    (door session list-uc-proposals ()
          #:auth device #:topic governance #:reply list #:kind read #:to governance
          #:doc "Lists the universal commune's pending cross-gateway merge proposals as (id proposal) pairs, or () when no registry is set.")
    (door session set-delegation (delegate-aid fraction #:optional (scope-id #f))
          #:auth device #:topic governance #:reply ok-or-error #:kind preference #:to governance
          #:doc "Records an unsigned delegation of FRACTION to DELEGATE-AID, federation-wide or scoped to SCOPE-ID when given; replies ok. Use set-delegation-signed when the client can sign.")
    (door session delegation-mandated-preimage (delegate-aid fraction mandate-spec #:optional (scope-id #f))
          #:auth device #:topic governance #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok fields), the SAID fields of a delegation to DELEGATE-AID carrying the data MANDATE-SPEC — federation-wide, or scoped to SCOPE-ID when given — for the client to sign for set-delegation-mandated-signed.")
    (door session set-delegation-mandated-signed (delegate-aid fraction mandate-spec signature #:optional (scope-id #f))
          #:auth device #:topic governance #:reply ok-or-error #:kind preference #:to governance
          #:doc "Compiles MANDATE-SPEC into its predicate and records the mandated delegation under this AID's own SIGNATURE; SCOPE-ID must match the preimage's. Replies ok or an error for an unrecognized spec or bad signature.")
    (door session revoke-delegation (delegate-aid #:optional (scope-id #f))
          #:auth device #:topic governance #:reply ok-or-error #:kind preference #:to governance
          #:doc "Revokes this AID's delegation to DELEGATE-AID, federation-wide or for SCOPE-ID when given; replies ok.")

    ;; acting-as-this-AID forwards to the planner (the agent argument is the session's)
    (door session witness-open (scope-id event-id)
          #:auth device #:topic commitments #:reply ok-or-error #:kind performative #:to planner
          #:doc "Opens the witness ceremony over recorded event EVENT-ID in SCOPE-ID as this AID with the scope's agents as roster; replies (ok (said)) or a failure such as needs-personhood.")
    (door session witness-inbox (scope-id)
          #:auth device #:topic commitments #:reply ok-or-error #:kind read #:to planner
          #:doc "Replies (ok (requests)), the ceremony statements in SCOPE-ID this AID may co-sign, or a failure when witnessing is unwired.")
    (door session witness-attest (scope-id said sig)
          #:auth device #:topic commitments #:reply ok-or-error #:kind constative #:to planner
          #:doc "Lands this AID's co-signature SIG on ceremony statement SAID; replies (ok (status)) as attested or finalized, or a failure.")
    (door session journey-begin (scope-id from-place to-place mode)
          #:auth device #:topic commitments #:reply ok-or-error #:kind constative #:to planner
          #:doc "Records this AID's ride commitment by MODE from FROM-PLACE to TO-PLACE and its pickup event at departure; replies (ok (commitment . id)) or needs-personhood.")
    (door session journey-end (scope-id commitment-id from-place to-place mode)
          #:auth device #:topic commitments #:reply ok-or-error #:kind constative #:to planner
          #:doc "Records the dropoff event that fulfils this AID's ride COMMITMENT-ID at arrival; replies (ok (commitment . id)).")
    (door session chat-post (scope-id topic body #:optional (message-kind #f))
          #:auth device #:topic chat #:reply ok-or-error #:kind constative #:to planner
          #:feature chat
          #:doc "Posts BODY of MESSAGE-KIND (default \"text\") to SCOPE-ID/TOPIC as this AID, stamping its plan-resolved stratum; replies (ok . stored-row).")
    (door session accept-assignment (scope-id intent-id)
          #:auth device #:topic commitments #:reply ok-or-error #:kind performative #:to planner
          #:doc "Accepts suggested INTENT-ID in SCOPE-ID as this AID, promoting it to a commitment under the steward gate, then re-plans the scope; replies (ok . cid) or a failure.")
    (door session decline-assignment (scope-id intent-id)
          #:auth device #:topic commitments #:reply ok-or-error #:kind preference #:to planner
          #:doc "Declines suggested INTENT-ID as this AID in SCOPE-ID, rematching it when possible; replies (ok . new-provider) or (ok . cleared).")
    ;; The AI the commons pays for, at the seat: each session has a budget of
    ;; calls per minute, and \"\" is the answer past it — the browser falls
    ;; back to its own, on-device, as it does with no keys.
    (door session transcribe (audio-b64)
          #:auth device #:topic knowledge #:reply string #:kind read #:to self
          #:feature ai
          #:doc "Sends base64 WAV audio to the AI service's transcription endpoint and replies the transcript string, or \"\" when keys are absent, the session's AI budget for the minute is spent, or the call fails, so the browser falls back to on-device transcription.")
    (door session express (nl-text)
          #:auth device #:topic knowledge #:reply string #:kind read #:to self
          #:doc "Turns a natural-language sentence into Scheme through the AI service's express prompt and replies the completion string, or \"\" when no API keys are configured or the session's AI budget for the minute is spent.")
    (door session ai-complete (system-prompt user-prompt model)
          #:auth device #:topic knowledge #:reply string #:kind read #:to self
          #:feature ai
          #:doc "Runs a chat completion with the given system and user prompts on MODEL when it is an enclave (TEE/…) slug, else on the service default, and replies the completion string, or \"\" when no API keys are configured or the session's AI budget for the minute is spent.")
    (door session see-part (upload index part)
          #:auth device #:topic knowledge #:reply ok-or-error #:kind constative #:to self
          #:feature ai
          #:doc "Sends one part of one picture to be read: UPLOAD names the sending, INDEX which of its pictures (0 to 3; several pictures of one thing are one read), PART a run of the picture's base64, sixteen kilobytes at the most. The session joins the parts and holds them until `see` reads them. Replies (ok . characters-held) or an error when a part or the whole is over its bound.")
    (door session see (upload system-prompt user-prompt #:optional (scope-id #f) (fulfills #f))
          #:auth device #:topic knowledge #:reply string #:kind read #:to self
          #:feature ai
          #:doc "Reads the pictures sent under UPLOAD with the enclave vision model, SYSTEM-PROMPT saying what to look for and in what shape to answer and USER-PROMPT what the asker knows of the scene, and replies the model's text. A read that fulfils a count the plan asked of this AID (SCOPE-ID, FULFILLS) draws on the plan; any other spends one of the week's unplanned photo reads, given back when the model gives no answer. Replies \"\" when no picture can be read here or the session's AI budget for the minute is spent, and \"err:…\" when no picture arrived or the week's reads are spent. The pictures are held nowhere once read.")
    (door session allotment ()
          #:auth device #:topic knowledge #:reply ok-or-error #:kind read #:to self
          #:doc "Replies this AID's unplanned photo reads for the week: (ok (remaining per-week opens sees?)), OPENS the epoch second the next week opens (Monday 00:00 UTC), SEES? whether a picture can be read here at all.")
    (door session express-willingness (scope-id skill cell willing? #:optional (hours #f))
          #:auth device #:topic commitments #:reply ok-or-error #:kind preference #:to planner
          #:doc "Marks this AID willing, or withdraws it, for SKILL at CELL in SCOPE-ID with an optional HOURS budget, binding nothing; replies (ok . willing) or (ok . declined).")
    (door session claim (scope-id resource-id qty labor-cost #:optional (where #f) (deliver-at #f))
          #:auth device #:topic stock #:reply ok-or-error #:kind performative #:to planner
          #:feature credit
          #:doc "Draws this AID's credit to claim QTY of RESOURCE-ID at LABOR-COST (derived from crystallized SNLT when #f), checked against on-hand and any live wallet reading; WHERE/DELIVER-AT record the claim's own place and time. Replies claimed, balance and credit.")
    (door session record-effort (scope-id commitment-id qty unit #:optional (tap #f))
          #:auth device #:topic commitments #:reply ok-or-error #:kind constative #:to planner #:keyed tap
          #:doc "Records QTY UNIT of this AID's effort against COMMITMENT-ID in SCOPE-ID; replies (ok . event-id) or a failure when the commitment is unknown. TAP is one press's own token: the same token on the same commitment is the same act, answered with the event it recorded and recording nothing more.")
    (door session log-observe (scope-id action spec qty unit note when-iso)
          #:auth device #:topic commitments #:reply ok-or-error #:kind constative #:to planner
          #:doc "Records this AID's spoken log entry as a self-scoped event of ACTION on SPEC with NOTE and narrated WHEN-ISO; replies (ok (event resource)) or a failure.")
    (door session count-stock (scope-id resource-id counted unit #:optional (technique #f) (place #f) (when-iso #f) (fulfills #f) (evidence #f) (note #f))
          #:auth device #:topic stock #:reply ok-or-error #:kind constative #:to planner
          #:doc "Records this AID's count of RESOURCE-ID in SCOPE-ID as COUNTED UNIT: a count that finds the ledger off lands a raise or lower of the difference on that stock, one that agrees lands none. TECHNIQUE (stated, label, photo), PLACE, WHEN-ISO and the EVIDENCE hash ride the event; FULFILLS names the counter's commitment of a planned count, whose record lands as a produce. Replies (ok (event record delta onhand)) or a failure.")
    (door session read-condition (scope-id resource-id reading unit #:optional (when-iso #f) (ambient #f) (note #f))
          #:auth device #:topic stock #:reply ok-or-error #:kind constative #:to planner
          #:doc "Records this AID's reading of RESOURCE-ID's condition as READING UNIT, an intensive unit (°C), against AMBIENT (°C, the catalogue's when absent): the reading names the form the stock is in among the forms its base has declared, so the stock the books held under another form is counted as nothing and the same quantity lands on the stock of the form named. Replies (ok (form was reading ambient moved unit from-stock to-stock gone event word)) or a failure, among them a form the scope has not declared.")
    (door session set-profile (scope-id json)
          #:auth device #:topic identity #:reply ok-or-error #:kind constative #:to planner
          #:feature health-profile
          #:doc "Upserts this AID's profile tags in SCOPE-ID from a JSON array, replacing prior profile tags and keeping other classifications; replies (ok . tags).")
    ;; ── bodies: a legal body declared, stewarded, incepted k-of-n, read by the law
    ;;    (doors/body.scm; every structure is a JSON string, every reply (ok . x) | (error . msg))
    (door session declare-body (scope-id json)
          #:auth device #:topic law #:reply ok-or-error #:kind performative #:to self
          #:feature bodies
          #:doc "Declares a legal body in SCOPE-ID from JSON {name, kind, role, jurisdiction, assetLock, register}: the caller, a recognised person (live PHC), is its first steward; the id is provisional until the stewards sign its inception. Replies (ok . {id, name, tags}).")
    (door session body-add-steward (id aid)
          #:auth device #:topic law #:reply ok-or-error #:kind performative #:to self
          #:feature bodies
          #:doc "A steward of body ID names AID a steward too; replies (ok . #t), or refuses a caller who is no steward.")
    (door session body-open-ceremony (id k)
          #:auth device #:topic law #:reply ok-or-error #:kind performative #:to self
          #:feature bodies
          #:doc "A steward opens body ID's inception ceremony: K of its stewards must sign the group inception from their own browsers. Replies (ok . {have, need, published, what}).")
    (door session body-sign-preimage (id kind)
          #:auth device #:topic law #:reply ok-or-error #:kind read #:to self
          #:feature bodies
          #:doc "The statement a steward signs for body ID — KIND is inception, rotation or role — as (ok . {what, said}); refused while no ceremony is open or it is at another step.")
    (door session body-sign-signed (id kind said signature)
          #:auth device #:topic law #:reply ok-or-error #:kind performative #:to self
          #:feature bodies
          #:doc "The steward's SIGNATURE over SAID (the statement body-sign-preimage gave), verified under this session's own AID and counted by the ceremony; at k the inception publishes. Replies (ok . {have, need, published}).")
    (door session my-bodies (scope-id)
          #:auth device #:topic law #:reply ok-or-error #:kind read #:to self
          #:feature bodies
          #:doc "The bodies this AID stewards or belongs to, each {id, name, tags, steward, ceremony}; replies (ok . rows).")
    (door session body (id)
          #:auth device #:topic law #:reply ok-or-error #:kind read #:to self
          #:feature bodies
          #:doc "Body ID, read by a steward or member: {id, name, tags, stewards, members, crossings, holdings (each with the law's status), findings (the scope's admission tests), exposure, ceremony}; replies (ok . body).")
    (door session body-present-holding (id json)
          #:auth device #:topic law #:reply ok-or-error #:kind constative #:to self
          #:feature bodies
          #:doc "A steward presents what body ID holds from JSON {kind, name, issuer, validUntil, ref} — a permit, a policy, a registration — as a resource the law reads against the bill; replies (ok . resource-id).")
    (door session body-admit (scope-id id)
          #:auth device #:topic law #:reply promise:ok-or-error #:kind performative #:to governance
          #:feature bodies
          #:doc "A governor admits body ID to SCOPE-ID; replies (ok . findings), the eight admission tests as findings, or refuses a caller without governor standing.")
    (door session set-availability-ranges (scope-id json)
          #:auth device #:topic commitments #:reply ok-or-error #:kind preference #:to planner
          #:doc "Upserts this AID's availability window in SCOPE-ID from the dial's arcs JSON, creating the agent record with generic labour on first offer; replies the agent-store's answer.")
    (door session invite-contact (scope-id invitee label t0-iso t1-iso)
          #:auth device #:topic commitments #:reply ok-or-error #:kind performative #:to planner
          #:doc "Creates a social use-intent labelled LABEL over T0..T1 and a proposal directed from this AID to INVITEE; replies (ok (proposal invitee)) or needs-personhood.")
    (door session accept-invite (scope-id proposal-id)
          #:auth device #:topic commitments #:reply ok-or-error #:kind performative #:to planner
          #:doc "Accepts directed social invite PROPOSAL-ID as this AID, filling the receiver slot so the intent becomes a commitment for both; replies (ok (accepted . id)).")
    (door session accept-work-offer (scope-id proposal-id)
          #:auth device #:topic commitments #:reply ok-or-error #:kind performative #:to planner
          #:doc "Accepts work offer PROPOSAL-ID with this AID as provider and SCOPE-ID as receiver, then re-plans the scope; replies ((accepted . id)).")

    ;; ── planner ──
    (door planner set-personhood-checker! (p)
          #:auth operator #:topic operations #:reply void #:kind performative
          #:doc "Installs the gateway's portable personhood predicate that every citizen-facing planner door consults before acting; replies 'ok.")
    (door planner set-witness-door! (d)
          #:auth operator #:topic operations #:reply ok-or-error #:kind performative
          #:doc "Installs the governance witness door (open/inbox/attest) that the three witness-* doors forward through; replies 'ok.")
    (door planner witness-open (scope-id aid event-id)
          #:auth operator #:topic governance #:reply ok-or-error #:kind performative
          #:doc "Opens the co-signing ceremony over an already-recorded event with the scope's agents as roster (personhood-gated); replies the statement said, or a failure when nothing is attestable.")
    (door planner witness-inbox (scope-id aid)
          #:auth operator #:topic governance #:reply ok-or-error #:kind read
          #:doc "Asks the witness door which context rows AID may co-sign right now; replies those requests as a list.")
    (door planner witness-attest (scope-id aid said sig)
          #:auth operator #:topic governance #:reply ok-or-error #:kind read
          #:doc "Lands one co-signature on a ceremony's statement (personhood-gated); replies status attested or finalized, or a failure when no ceremony collects under that said.")
    (door planner add-scope! (id root)
          #:auth operator #:topic scopes #:reply ok-or-error #:kind performative
          #:doc "Registers a commune's economic root under its scope id in the planner roster, mutating the roster in place; replies 'ok.")
    (door planner forget-scope! (id)
          #:auth operator #:topic scopes #:reply ok-or-error #:kind performative
          #:doc "Drops a scope from the planner roster by id — the symmetric op to add-scope!, for a throwaway/demo scope that never had real participants; replies 'ok.")
    (door planner set-solve-vat! (vat)
          #:auth operator #:topic operations #:reply boolean #:kind performative
          #:doc "Records the vat the solve queue runs on so every solve door answers a promise while a program runs; replies #t.")
    (door planner resolve-stale! (#:optional (max-age 3600))
          #:auth operator #:topic operations #:reply number #:kind performative
          #:doc "Runs the re-stand hooks, then re-solves every registered scope whose cached plan is older than MAX-AGE-SECONDS; replies how many scopes it solved.")
    (door planner resolve-one-stale! (max-age seen)
          #:auth operator #:topic operations #:reply string #:kind performative
          #:doc "Solves ONE due scope per turn given the sweep's seen list (an empty list opens the sweep and runs the re-stand hooks); replies that scope id, or #f when the pass is complete.")
    (door planner re-stand! (thunk)
          #:auth operator #:topic operations #:reply ok-or-error #:kind performative
          #:doc "Registers an idempotent thunk that re-lays a declaration owner's standing terms before each stale sweep; replies 'ok.")
    (door planner move-scope! (id new-parent)
          #:auth operator #:topic scopes #:reply ok-or-error #:kind performative
          #:doc "Reparents a scope's fold and descent nodes under a new parent scope (or the UC when #f or unregistered) with no rebuild; replies the moved id and its parent.")
    (door planner deployment-of (scope-id)
          #:auth operator #:topic commitments #:reply list #:kind read
          #:doc "Reads the descent node's slice of the last UC matching round for a scope; replies its commitments, or '() when the node is absent.")
    (door planner deployed-hours-of (scope-id)
          #:auth operator #:topic commitments #:reply number #:kind read
          #:doc "Reads the hours the last UC matching round landed on a scope's descent node; replies that number, or 0 when the node is absent.")
    (door planner labour-pool (scope-id)
          #:auth operator #:topic planning #:reply capability #:kind read
          #:doc "Hands back one scope's standing labour-pool node so callers can run finer query/free/by-agent reads on the node itself.")
    (door planner labour-total ()
          #:auth operator #:topic planning #:reply capability #:kind read
          #:doc "Replies the whole federation's availability × skills as one keyed pool, the UC labour pool's raw pool read.")
    (door planner labour-total-hours (#:key (skill #f) (cell #f) (radius #f) (time-window #f))
          #:auth operator #:topic planning #:reply number #:kind read
          #:doc "Replies the federation's total available hours, filtered to SKILL and/or a place (CELL, with RADIUS for its neighbourhood) and/or TIME-WINDOW when given; every filter is optional and they compose.")
    (door planner home-of (aid)
          #:auth operator #:topic planning #:reply mixed #:kind read
          #:doc "The scope AID's facts (needs, means, availability, profile, position, skills) are written at, however they connect: the scope whose agent store holds their record, or false for a person nowhere yet. A door that names a person writes at their home; the scope it was dialed through is a lens.")
    (door planner move-home (aid to-scope-id)
          #:auth operator #:topic planning #:reply ok-or-error #:kind performative
          #:doc "Moves AID's home to TO-SCOPE-ID: their needs, means, held skills, places, dwelling, positions and agent record (with its place in the labour pool) are carried there from wherever they were written and withdrawn from it, and the old home's row is closed. A means a commune is lent under a grant stays where the grant names it, and is listed. Asking again carries nothing more, so an interrupted move is finished by asking; it also gathers a person declared in several scopes before there was a home. Replies the home, how many facts were carried and the lent means kept (kept).")
    (door planner demand-total (periods)
          #:auth operator #:topic planning #:reply alist #:kind read
          #:doc "Reads the UC demand fold's demand-for over the given periods and replies the federation's folded demand total.")
    (door planner means-total (spec)
          #:auth operator #:topic custody #:reply number #:kind read
          #:doc "Reads the standing means fold and replies the federation-wide total capacity for SPEC.")
    (door planner means-rebuild! ()
          #:auth operator #:topic custody #:reply ok-or-error #:kind read
          #:doc "Rebuilds the standing means fold from every scope's records; replies 'ok.")
    (door planner slots-watch (scope-id ref)
          #:auth anonymous #:topic slots #:reply ok-or-error #:kind read
          #:doc "Subscribes REF to a scope's slot-change pushes so it re-reads when needs or means change; replies 'ok.")
    (door planner slots-unwatch (scope-id ref)
          #:auth anonymous #:topic slots #:reply ok-or-error #:kind read
          #:doc "Drops REF from a scope's slot-change subscribers; replies 'ok.")
    (door planner slots-changed! (scope-id)
          #:auth operator #:topic slots #:reply ok-or-error #:kind read
          #:doc "Fires a scope's slot-change rail so every watcher re-reads its pool; replies 'ok.")
    (door planner folksonomy-uc ()
          #:auth operator #:topic knowledge #:reply capability #:kind read
          #:doc "Hands back the UC folksonomy fold object, the commons' aggregate contribution and template surface.")
    (door planner folksonomy (scope-id)
          #:auth operator #:topic knowledge #:reply capability #:kind read
          #:doc "Hands back one scope's folksonomy fold node, or #f when the scope has none.")
    (door planner credit-uc ()
          #:auth operator #:topic stock #:reply capability #:kind read
          #:doc "Hands back the UC credit pool root object, on which every global-* credit read is a method.")
    (door planner credit (scope-id)
          #:auth operator #:topic stock #:reply capability #:kind read
          #:doc "Hands back one scope's credit fold node, or #f when the scope has none.")
    (door planner credit-read (method . args)
          #:auth operator #:topic stock #:reply mixed #:kind read
          #:doc "Forwards METHOD and its own ARGS to the UC credit pool (module/playnet/pools/credit-fold.scm) and replies its answer. METHOD is one of: cells, context, pool, sum-met, sum-unmet, citizen-count, citizens (no further args); citizen-claimed/citizen-unmet/contribution-claim/solidarity-supplement (aid); citizen-gross/voice-share (aid, [level]); citizenship-share/total-claim-capacity/effective-balance (aid, [citizenship-fraction]); total-social-svc ([level]). Genuinely polymorphic per method, so ARGS stays a positional tail rather than one fixed shape.")
    (door planner voice-uc ()
          #:auth operator #:topic stock #:reply capability #:kind read
          #:doc "Hands back the UC voice pool root object (module/playnet/pools/voice-fold.scm): producer stances over parts, folded anonymously; reads pushes, hours-of, hours, cells.")
    (door planner voice (scope-id)
          #:auth operator #:topic stock #:reply capability #:kind read
          #:doc "Hands back one scope's voice fold node, or #f when the scope has none.")
    (door planner hands! (scope-id)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Rereads SCOPE-ID's standing plan-part hands from the credential rail (the injected reader over governance's plan-part-hands, parsed by parts.scm validate-hand) into its voice fold and refolds; replies (ok . count) or an error. The rail is the only store of a hand. docs/planning/voice/voice-follows-work.md.")
    (door planner scope-readings (scope-id spec)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Replies what every source says of SPEC at SCOPE-ID's reading fold: rows, one per technique, act and source, each with its count, sum, extrema and freshest reading; the drift between counts and the ledger (n, mean-abs, net); and the freshest flow reading. docs/observation/readings-are-counts.md §1.1.")
    (door planner readings-between (scope-id spec from until)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Replies what every source reported of SPEC at SCOPE-ID between FROM and UNTIL (ISO-8601 instants; an empty string leaves that end open): rows, one per reading in time order, keyed as the fold's cells are (technique, act, unit, source) with n = 1, the rail's standing contrary observations among them; and fold, those rows folded, what the reading fold would say from that window alone. The temporal query over the event log the fold reads (docs/observation/ngsi-ld.md).")
    (door planner substitutes-for (scope-id spec)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Replies the foods of SCOPE-ID that stand in for SPEC, ((spec . id) (cover . k)) by cover descending: k is the least, over the leaves SPEC carries that a body's floors name, of the other's amount over SPEC's per unit (catalogues/substances.scm leaf-substitutes). Substitution as a reading of the leaf registry, declared by nobody. docs/observation/physics.md §6.")
    (door planner readings-uc ()
          #:auth operator #:topic stock #:reply capability #:kind read
          #:doc "Hands back the UC reading pool root object (module/playnet/pools/reading-fold.scm): every scope's readings of a spec, keyed by technique, act and scope, one cell per source; reads readings, latest, drift, sources, contrary, cells.")
    (door planner readings (scope-id)
          #:auth operator #:topic stock #:reply capability #:kind read
          #:doc "Hands back one scope's reading fold node, or #f when the scope has none.")
    (door planner observed! (scope-id)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Rereads SCOPE-ID's standing contrary observations from the credential rail (the injected reader over governance's contrary-readings-of) into its reading fold and refolds; replies ok. The rail is the only store of an observation. docs/observation/observe-wiring.md §4.")
    (door planner hands (scope-id)
          #:auth operator #:topic stock #:reply mixed #:kind read
          #:doc "The standing plan-part hands the voice fold holds for SCOPE-ID, as rows ((owner part-string portion) …).")
    (door planner slack-uc ()
          #:auth operator #:topic planning #:reply capability #:kind read
          #:doc "Hands back the UC slack fold object, the commons' desire overlay as one readable aggregate.")
    (door planner slack (scope-id)
          #:auth operator #:topic planning #:reply capability #:kind read
          #:doc "Hands back one scope's slack fold node, or #f when the scope has none.")
    (door planner slack-read (method . args)
          #:auth operator #:topic planning #:reply mixed #:kind read
          #:doc "Forwards METHOD and its own ARGS to the UC slack fold (module/playnet/pools/slack-fold.scm) and replies its answer. METHOD is one of: cells, slacks (no further args); slack (place); geomean ([places], default every place with a want). Genuinely polymorphic per method, so ARGS stays a positional tail rather than one fixed shape.")
    (door planner match-labour! ()
          #:auth operator #:topic commitments #:reply ok-or-error #:kind performative
          #:doc "Matches every scope's request proposals against the UC labour pool in ONE steward-gated solve seeded by standing accepts, landing the deployment via the descent; replies commitment count and hours.")
    (door planner scope-root-ref (scope-id)
          #:auth operator #:topic scopes #:reply capability #:kind read
          #:doc "Replies a commune's planner root from the roster, for the governance service's per-scope reads.")
    (door planner scope-list ()
          #:auth anonymous #:topic scopes #:reply alist-list #:kind read
          #:doc "Lists every registered scope as an alist of id, name and geographic path.")
    (door planner scope-snapshot (scope-id plan-id #:optional (acting-aid #f))
          #:auth anonymous #:topic planning #:reply alist #:kind read
          #:doc "Builds a scope's full snapshot for PLAN-ID, unioned with federation siblings' locations and, when ACTING-AID is given, the social invites directed at it; replies the snapshot wire.")
    (door planner lint-records (scope-id records-json)
          #:auth anonymous #:topic knowledge #:reply json #:kind read
          #:doc "Judges RECORDS-JSON (an array of ValueFlows records: kind, action, spec, qty, unit, arcs) against what SCOPE-ID knows — its specs and their units — and replies a JSON array of findings (severity, kind, subject, detail); an empty array means well formed.")
    (door planner presets ()
          #:auth anonymous #:topic knowledge #:reply alist-list #:kind read
          #:doc "Lists the worlds a scope can start from — the economies the tree ships as data (module/playnet/knowledge/worlds/presets.scm): id, name and doc per preset.")
    (door planner adopt-preset! (scope-id preset-id)
          #:auth operator #:topic knowledge #:reply ok-or-error #:kind performative
          #:doc "Seeds preset PRESET-ID (see `presets`) into SCOPE-ID's stores — its specs, recipes, places, agents and stock, replacing by id; replies the counts seeded.")
    (door planner legal-snapshot (#:optional (budget #f))
          #:auth operator #:topic law #:reply json #:kind read
          #:doc "Derives the law face live over the activity catalogue, sized to BUDGET when given (a derived federation budget) or the stewarded fallback; replies the snapshot as a JSON string.")
    (door planner journey-begin (scope-id agent-id from-place to-place mode)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind constative
          #:doc "Files a trip for the agent (personhood-gated) as one performed Process based on the scope's mode for MODE (a routing costing), with its pickup and dropoff commitments and the pickup event at departure, ids disambiguated by a running count. Replies the pickup commitment id and the arrival commitment id.")
    (door planner journey-end (scope-id agent-id commitment-id from-place to-place mode)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind constative
          #:doc "Records the dropoff event that fulfills a trip's arrival commitment. Replies the pickup commitment id and the arrival commitment id.")
    (door planner chat-post (scope-id topic aid body #:optional (message-kind #f))
          #:auth operator #:topic chat #:reply ok-or-error #:kind read
          #:doc "Posts a line to scope/topic with the author's plan-resolved stratum stamped and MESSAGE-KIND (default \"text\"); replies the stored row.")
    (door planner chat-history (scope-id topic #:optional (since 0))
          #:auth anonymous #:topic chat #:reply ok-or-error #:kind read
          #:doc "Replies a topic's lines since SINCE (an epoch second; 0 = every line) as a vector.")
    (door planner chat-last (scope-id topics)
          #:auth anonymous #:topic chat #:reply ok-or-error #:kind read
          #:doc "Replies the last line of many topics in one call as topic → (author body kind t); silent topics are absent, so the wake needs one round trip.")
    (door planner chat-watch (scope-id topic cb)
          #:auth anonymous #:topic chat #:reply ok-or-error #:kind read
          #:doc "Registers CB to be called with each new line on scope/topic; replies #t.")
    (door planner plan (scope-id demand #:optional (opts '()))
          #:auth operator #:topic planning #:reply promise:ok-or-error #:kind read
          #:doc "Runs the convex planner over the scope's live state for DEMAND with standing eco-caps, OPTS (movable/storable/whole/tau/willing-only/horizon/reproduce, an alist) and reproduction on by default; replies the plan alist and caches it as the current solve.")
    (door planner federated-plan (boundary-good communes #:optional (opts '()))
          #:auth operator #:topic planning #:reply ok-or-error #:kind read
          #:doc "Composes several communes' provisioning of the goods that cross between them through one pull each and lands the per-scope result. BOUNDARY-GOOD is a good, a list of goods, or #f for every good at least two of the communes deal in (`census`); the communes must partition the economy's people and records, or the call is refused; OPTS may carry `displacement-of`. Replies met, rounds, the good's pull, dilemma, relaxed scopes, per scope each good's signed flow and pull, and `loose` naming any crossing whose give-bound stands far above what crossed.")
    (door planner census (scope-id #:optional (demand #f))
          #:auth operator #:topic planning #:reply ok-or-error #:kind read
          #:doc "The goods the scope deals in, read off its records: what it holds, what its recipes make and consume, what DEMAND (a (good . qty) or #f) asks. A good at least two scopes deal in crosses between them; labour and the capacity a use flow draws on are left out.")
    (door planner scope-record (scope-id goods #:optional (demand #f) (opts '()))
          #:auth operator #:topic planning #:reply ok-or-error #:kind read
          #:doc "The scope's record for a solve across scopes — its projected view, standing caps and spans, processes, flows and standing labour — with one crossing column per good of GOODS, measured from the most the scope can give: what a peer of the federated solve (federation/federate.scm) is built over. DEMAND a (good . qty) or #f; OPTS as federated-plan's.")
    (door planner means-plan (spec total communes ceilings)
          #:auth operator #:topic custody #:reply ok-or-error #:kind performative
          #:doc "Allocates SPEC across communes by consensus under the given ceilings (total 'auto reads the means fold) and lands standing eco-caps; replies allocations, duals and rounds.")
    (door planner solve (scope-id overrides)
          #:auth operator #:topic planning #:reply promise:ok-or-error #:kind read
          #:doc "Runs a non-binding what-if over live state with OVERRIDES merged in (empty = the current plan) and caches it; replies the full plan result with met, work, prices and certificate.")
    (door planner explain (scope-id claim)
          #:auth operator #:topic planning #:reply promise:ok-or-error #:kind read
          #:doc "Traces a prose claim to this scope's pure-Scheme solve; replies its grounds, the numbers it moves and the recipes a legal aspect gates.")
    (door planner solve-brief (scope-id overrides)
          #:auth anonymous #:topic planning #:reply promise:ok-or-error #:kind read
          #:doc "Runs the solve with JSON or alist overrides and replies a compact stringified summary — satisfaction, social ledger, duals, certificate; caches only the current-plan case.")
    (door planner materialize (scope-id demand #:optional (opts '()))
          #:auth operator #:topic commitments #:reply promise:ok-or-error #:kind performative
          #:doc "Runs the willing-only plan and persists its work rows as suggested intents awaiting acceptance; OPTS as `plan`'s (plus `plan-id`); replies the plan alist plus the materialized count.")
    (door planner enact (scope-id plan)
          #:auth operator #:topic stock #:reply ok-or-error #:kind performative
          #:doc "Records the material rows of PLAN that the scope's last plan states, as produce/consume/pickup/dropoff/use events, each once the books hold the stock it draws; replies the event ids and the rows still waiting, each with its reason.")
    (door planner record-flow (scope-id action spec qty total place when-iso proc note #:optional (row-id #f) (tap #f))
          #:auth anonymous #:topic stock #:reply ok-or-error #:kind constative #:keyed tap
          #:doc "Confirms one material produce/consume/pickup/dropoff/use row the scope's last plan states, named by ROW-ID (the id the schedule carries) or, for a caller with none, by its coordinates; QTY is spread over the matching plan rows' remainders (each row is a commitment under the plan's own id) and TOTAL decides nothing. The flow is dated at the row's planned slot, or at its confirmation when the slot is still ahead. The two rows of a relocation chain through their run: a dropoff is refused until its pickup has taken the cargo. Replies the first numbered event id, or `already` once the rows are finished. TAP is one press's own token: the same token on the same rows is the same act, answered with what it recorded (`again`) and recording nothing more.")
    (door planner record-claim (scope-id claimant spec qty total place when-iso)
          #:auth operator #:topic stock #:reply ok-or-error #:kind constative
          #:doc "Confirms one planned claim as the account store's transfer at the good's crystallized SNLT, keyed by claimant, spec, place and time; replies event id, cost and balance, or `already`.")
    (door planner inventory-snapshot (scope-id plan-id)
          #:auth anonymous #:topic stock #:reply alist #:kind read
          #:doc "Builds and replies the scope's inventory snapshot for PLAN-ID.")
    (door planner resource-detail (scope-id resource-id)
          #:auth anonymous #:topic stock #:reply alist #:kind read
          #:doc "Builds and replies the detail view for one resource in the scope.")
    (door planner process-context (scope-id process-id)
          #:auth anonymous #:topic planning #:reply alist #:kind read
          #:doc "Builds and replies the context view for one process in the scope.")
    (door planner accept-assignment (scope-id intent-id acting-as)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind performative
          #:doc "Promotes a suggested intent to a commitment for the acting agent (personhood- and steward-gated), arms fulfillment tracking and re-plans the scope; replies (ok . cid).")
    (door planner decline-assignment (scope-id intent-id acting-as)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind preference
          #:doc "Clears a suggested intent's provider for the acting agent and re-matches it to another in-scope agent; replies (ok . new-provider) or (ok . cleared).")
    (door planner express-willingness (scope-id worker skill cell willing? #:optional (hours #f))
          #:auth operator #:topic commitments #:reply ok-or-error #:kind preference
          #:doc "Marks a worker willing or declined for skill@cell with optional HOURS willing hours (personhood-gated), binding nothing; replies willing or declined.")
    (door planner materialize-willing (scope-id)
          #:auth anonymous #:topic commitments #:reply ok-or-error #:kind performative
          #:doc "Assigns willing workers to the scope's open needs so they surface as awaiting acceptance; replies (materialized . N).")
    (door planner set-position (scope-id agent-id period place)
          #:auth operator #:topic places #:reply ok-or-error #:kind constative
          #:doc "Sets where an agent is at PERIOD (0 = now) as the commute origin the planner reads; place #f clears it; replies the place or cleared.")
    (door planner set-position-latlon (scope-id agent-id period lat lon)
          #:auth operator #:topic places #:reply ok-or-error #:kind constative
          #:doc "Snaps lat/lon to the nearest known place and stores that as the agent's position for PERIOD; replies the snapped place.")
    (door planner set-location-sharing (scope-id aid mode)
          #:auth operator #:topic places #:reply ok-or-error #:kind constative
          #:doc "Declares whether AID shares where they are — MODE live, here or off — in a row at their home; off ends the fix that stands and refuses the next (a fix for now is a lease, and counts while fresh); replies the mode.")
    (door planner location-sharing (scope-id aid)
          #:auth operator #:topic places #:reply ok-or-error #:kind read
          #:doc "Replies the mode AID declared for sharing where they are (live, here or off), or undeclared.")
    (door planner set-home (scope-id aid place lat lon)
          #:auth operator #:topic places #:reply ok-or-error #:kind constative
          #:doc "Sets the agent's primary location — the home the planner falls back to — to a known place id, or with \"\" and LAT/LON to the agent's own place:AID:home, declared here; replies (ok (place . id)).")
    (door planner declare-dwelling (scope-id aid place area rooms warmth-winter warmth-summer beds attests-json certified rent tenure)
          #:auth operator #:topic places #:reply ok-or-error #:kind constative
          #:doc "Seeds the agent's dwelling `dwelling:AID` of spec-dwelling at PLACE (\"\" = their primary location), tagged as the housing closure reads a unit: area-m2, rooms, warmth-winter-degc, warmth-summer-degc, beds, attests, certified, rent-eur-night, tenure — a rented one under split custody (landlord accountable, tenant custodian); replies the resource id, place and tags.")
    (door planner thermal-form! (scope-id base specific-heat delta-t enclosure #:optional (ua #f) (mass #f))
          #:auth operator #:topic stock #:reply ok-or-error #:kind constative
          #:doc "A state is a form: declares BASE warmed (or cooled) by DELTA-T kelvin with SPECIFIC-HEAT kJ/(kg·K) as a spec of its own with its heat and entropy stated, states the base's zero, and adds the relaxation recipe that holds it in ENCLOSURE (a keep-in-place spec) and lets it relax toward ambient at the rate UA kW/K over MASS kg sets (knowledge/thermal.scm declare-thermal-form!); replies the form's id. docs/observation/physics.md §3.")
    (door planner declare-place (scope-id agent-id name lat lon #:optional (address #f) (parent #f))
          #:auth operator #:topic places #:reply ok-or-error #:kind constative
          #:doc "Creates a named spatial-thing with the deterministic id place:AID:slug (re-naming re-places it) and optional coordinates and ADDRESS; with PARENT, inside that place, with id PARENT/slug and its parent's position when it states none. Replies that id.")
    (door planner count-commitment-of (scope-id agent-id commitment-id)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind read
          #:doc "Replies (ok . #t) when the commitment is a planned count, the agent's own, and unfinished: what a photo read draws on in place of the week's allotment; (ok . #f) otherwise.")
    (door planner count-schedule (scope-id #:optional (regime #f))
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Every count target of the scope with its cadence: lines, hours, interval, class, last count and due instant, soonest due first (counting.scm count-schedule over the inventory, the recipes' prices and the reading fold's drift).")
    (door planner plan-counts (scope-id agent-id #:optional (regime #f) (counter #f) (at-most #f))
          #:auth operator #:topic commitments #:reply ok-or-error #:kind performative
          #:doc "Lays the due counts, those whose window is open, as directed work offers through offer-work (personhood-gated), by turn among the members or to a named counter, bounded per call and by the offer loop; replies the offers laid, how many targets were due, and why the walk stopped when the offer loop refused.")
    (door planner scope-replica (scope-id agent-id)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "The scope as a member's device holds it (planner/scope/replica.scm): goods, places, people, standing needs and the observer's portable snapshot, as one text that write and read carry.")
    (door planner count-history (scope-id agent-id resource-id #:optional (limit #f))
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "The counts of a stock, newest first: each adjustment a count landed, as (id at delta unit counter technique evidence mine); reads the standing events, so a count voided by a contest is gone.")
    (door planner label-stock (scope-id agent-id resource-id)
          #:auth operator #:topic stock #:reply ok-or-error #:kind constative
          #:doc "The code a stock is known by (personhood-gated; the agent's own stock, the scope's, or stock in the scope's custody): gives the resource a tracking identifier when it has none and replies it with the resource's id and name, and whether this asking minted it.")
    (door planner read-label (scope-id agent-id code)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "The resource known by a label code (personhood-gated), in the inventory wire's shape, with the resources it contains.")
    (door planner drop-event (scope-id action container-id agent spec qty unit #:optional (resource-id #f) (note #f) (accountable #f))
          #:auth anonymous #:topic stock #:reply ok-or-error #:kind performative
          #:doc "Records a dropoff or pickup in a shared container for the agent (personhood-gated), moving RESOURCE-ID (naming nothing introduces one) with rights and rail intact; replies the ledger's answer.")
    (door planner claim (scope-id resource-id qty claimant labor-cost #:optional (where #f) (deliver-at #f))
          #:auth operator #:topic stock #:reply ok-or-error #:kind preference
          #:doc "Draws credit to claim QTY of a resource at labor-cost or its crystallized SNLT, refused beyond on-hand or a live wallet reading; WHERE/DELIVER-AT record the claim's own place and time. Replies cost, new balance and credit wire.")
    (door planner credit-balance (scope-id agent-id)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Replies a person's credit standing in this scope — validated work minus individually-claimable draws.")
    (door planner record-effort (scope-id commitment-id acting-as qty unit #:optional (tap #f))
          #:auth operator #:topic commitments #:reply ok-or-error #:kind constative #:keyed tap
          #:doc "Records QTY UNIT of work effort against a commitment for the acting agent, advancing its fulfillment; replies the new event id.")
    (door planner log-observe (scope-id agent-id action spec qty unit note when-iso)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind constative
          #:doc "Records a spoken log entry's suggested event self-scoped on the observer (personhood-gated) with note and narrated time; replies the event id and any minted resource id.")
    (door planner count-stock (scope-id agent-id resource-id counted unit #:optional (technique #f) (place #f) (when-iso #f) (fulfills #f) (evidence #f) (note #f))
          #:auth operator #:topic stock #:reply ok-or-error #:kind constative
          #:doc "Records an agent's count of a stock (personhood-gated): the difference from on-hand lands as a raise or lower on that resource with technique, place, instant and evidence hash; a planned count's record lands as a produce fulfilling the record's commitment. Replies the adjustment's event id, the record's event id, the difference and what is on hand after.")
    (door planner read-condition (scope-id agent-id resource-id reading unit #:optional (when-iso #f) (ambient #f) (note #f))
          #:auth operator #:topic stock #:reply ok-or-error #:kind constative
          #:doc "Records an agent's reading of a stock's condition (personhood-gated): the intensive reading names the declared form the stock is in, and the stock moves from the form the books held to it. See session read-condition.")
    (door planner set-availability (scope-id aid availability-window)
          #:auth operator #:topic scopes #:reply ok-or-error #:kind preference
          #:doc "Replaces a member's availability window on their agent record; replies (ok . AID).")
    (door planner set-profile (scope-id aid json)
          #:auth operator #:topic identity #:reply ok-or-error #:kind constative
          #:doc "Upserts the member's profile tags from a JSON array, replacing prior profile tags and keeping other classifications; replies (ok . tags).")
    (door planner set-availability-ranges (scope-id aid json)
          #:auth operator #:topic scopes #:reply ok-or-error #:kind preference
          #:doc "Upserts the agent's availability window from the arcs JSON, creating the agent and seeding spec-labor for a browser-born AID; replies (ok . AID).")
    (door planner invite-contact (scope-id inviter invitee label t0-iso t1-iso)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind performative
          #:doc "Creates a social use-intent by the inviter (personhood-gated) wrapped in a proposal directed at the invitee; replies the proposal id and invitee.")
    (door planner accept-invite (scope-id agent-id proposal-id)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind performative
          #:doc "Accepts a directed social invite as the invitee, filling the intent's receiver and promoting it to a commitment; replies (accepted . proposal-id).")
    (door planner offer-work (scope-id agent-id proc hours when-iso place skill #:optional (until #f))
          #:auth operator #:topic commitments #:reply ok-or-error #:kind read
          #:doc "Makes a directed work offer (process, hours, when, place, skill, optional UNTIL) to an agent as a proposal with an acceptance window; replies the proposal.")
    (door planner present-offers (scope-id)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind read
          #:doc "Turns the last solve's work rows into directed offers, nearest-forcing first; replies the proposals, and fails when no solve stands.")
    (door planner commitment-drift (scope-id #:optional (window-days 7.0) (at #f))
          #:auth operator #:topic commitments #:reply ok-or-error #:kind read
          #:doc "Reads κ against the lapse and release rates of the scope's commitments over WINDOW-DAYS, ended AT (an epoch number) or now; replies the drift read.")
    (door planner accept-regret (scope-id)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind read
          #:doc "Prices the standing accepts against the pins-freed counterfactual of the last solve's demand (two solves); replies the regret, and fails when no solve stands.")
    (door planner voice-displacement (scope-id)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind read
          #:doc "Reads what the standing voice field displaces, as a total: the last solve's demand with the field at the governed τ against the same program at τ = 0 (two solves); replies hours and met need at each and their difference beside the per-part marginals, and fails when no solve stands.")
    (door planner accept-work-offer (scope-id agent-id proposal-id)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind performative
          #:doc "Accepts a work offer with the worker as provider and the scope as receiver, then re-plans the scope; replies (accepted . proposal-id).")
    (door planner release-commitment (scope-id agent-id cid)
          #:auth operator #:topic commitments #:reply ok-or-error #:kind performative
          #:doc "Releases a provider's own accepted commitment and re-plans at once so the freed slot re-enters the plan; replies (released . cid).")
    (door planner declare-skill (scope-id agent-id skill-spec-id)
          #:auth operator #:topic identity #:reply ok-or-error #:kind constative
          #:doc "Self-declares a skill as an owned resource skill:AID:SPEC, raising it back after a revoke and refolding the labour pool; replies (ok . RID).")
    (door planner my-skills (scope-id agent-id)
          #:auth operator #:topic identity #:reply ok-or-error #:kind read
          #:doc "Replies the skill specs the agent holds — every skill resource with on-hand above zero.")
    (door planner revoke-skill (scope-id agent-id skill-spec-id)
          #:auth operator #:topic identity #:reply ok-or-error #:kind constative
          #:doc "Lowers a declared skill's on-hand to zero, keeping the record and its history, and refolds the labour pool; replies (ok . RID).")
    (door planner skill-standing (scope-id agent-id)
          #:auth operator #:topic identity #:reply ok-or-error #:kind read
          #:doc "One row per held or practiced skill, in hours: held, validated hours, competence under the skill's law, and the witnessed-work counts the witness door reads off the work-event credentials; replies (ok (standing . rows)).")
    (door planner declare-means (scope-id agent-id spec qty unit location #:optional (arcs-json #f) (note #f) (emoji #f) (name #f) (cats-json #f) (criteria-json #f))
          #:auth operator #:topic slots #:reply ok-or-error #:kind constative
          #:doc "Declares or edits an owned means slot means:AID:SPEC as raise/lower events; replies (ok . RID).")
    (door planner request-payout (scope-id agent-id store address xmr due note)
          #:auth operator #:topic stock #:reply ok-or-error #:kind preference
          #:doc "Files a member's standing intent to send XMR of their claim to a plausible Monero address, refused beyond what is available; replies the intent id and what stays available.")
    (door planner my-payouts (scope-id agent-id store)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Replies the member's claimable XMR amount, what the commons owes them, and their payout records.")
    (door planner my-claims (scope-id agent-id)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Replies the member's order book: wants asked, claim rows the plan holds for them, rows taken.")
    (door planner my-credit-history (scope-id agent-id)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Replies the member's credit as a dated account: earned, waiting, drawn and voided rows, newest first.")
    (door planner retire-payout (scope-id agent-id id)
          #:auth operator #:topic stock #:reply ok-or-error #:kind performative
          #:doc "Removes the requester's own still-pending payout intent; replies its id.")
    (door planner due-payouts (scope-id now-iso)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Replies the pending payouts whose due date is unset or already past NOW-ISO — the runner's read.")
    (door planner settle-payout (scope-id id txid store)
          #:auth operator #:topic stock #:reply ok-or-error #:kind performative
          #:doc "Records the on-chain transfer out of the member's claim, debts paid first, and restates the intent as sent with the txid; replies id and txid.")
    (door planner begin-payout (scope-id id)
          #:auth operator #:topic stock #:reply ok-or-error #:kind performative
          #:doc "Restates a pending payout as sending so a second tick never sends it twice; replies its id.")
    (door planner sending-payouts (scope-id)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Replies the payouts that began moving and were never settled — the reconciler's read after a mid-transfer crash.")
    (door planner settled-payout-txids (scope-id)
          #:auth operator #:topic stock #:reply ok-or-error #:kind read
          #:doc "Replies the transaction ids that have already settled a payout, so the reconciler never reads one wallet transfer as the evidence for two.")
    (door planner unsettle-payout (scope-id id reason)
          #:auth operator #:topic stock #:reply ok-or-error #:kind performative
          #:doc "Parks a sending payout as unsettled with a reason, the claim still reserved for an operator to settle or fail; replies its id.")
    (door planner fail-payout (scope-id id reason)
          #:auth operator #:topic stock #:reply ok-or-error #:kind performative
          #:doc "Marks an open payout failed with a reason, leaving the member's claim whole; replies its id.")
    (door planner record-purchase (scope-id agent-id spec qty unit money-spec cost where note receipt #:optional (donation? #f))
          #:auth operator #:topic stock #:reply ok-or-error #:kind constative
          #:doc "Raises a bought (or, when DONATION? is true, donated) good into the commons bound to the produce commitment and need it corroborates; replies resource and event ids, cost, planned?, fulfills and satisfies.")
    (door planner retire-means (scope-id agent-id spec)
          #:auth operator #:topic slots #:reply ok-or-error #:kind performative
          #:doc "Lowers a declared means to zero as the offer withdrawn, the record standing, and notifies the means fold; replies (ok . RID).")
    (door planner need-displacement (scope-id spec qty)
          #:auth operator #:topic planning #:reply ok-or-error #:kind read
          #:doc "Reads what SPEC displaces off the last solve's duals without re-solving; replies read?, per-unit, what QTY moved, the lately read and the honesty radius.")
    (door planner externality-history (scope-id)
          #:auth operator #:topic planning #:reply ok-or-error #:kind read
          #:doc "Replies the scope's accumulated moved-distribution summary — the burn meter read from standing metadata, nothing re-solved.")
    (door planner ratify-kind (scope-id agent-id spec kind)
          #:auth operator #:topic governance #:reply ok-or-error #:kind performative
          #:doc "Records the scope's grant of SPEC as floor or held with the ratifier's AID and time, and des withdraws it; replies spec and kind.")
    (door planner audit-kinds (scope-id agent-id #:optional (options #f))
          #:auth operator #:topic governance #:reply ok-or-error #:kind performative
          #:doc "Audits ratified need rows against observed takings at Becker's rate, withdrawing padded grants and recording conduits; OPTIONS may carry consequence-factor and tolerance overrides. Replies examined, padded and findings.")
    (door planner audits (scope-id)
          #:auth operator #:topic governance #:reply ok-or-error #:kind read
          #:doc "Replies every audit finding recorded in the scope's plan-store meta.")
    (door planner ratified-kinds (scope-id)
          #:auth operator #:topic governance #:reply ok-or-error #:kind read
          #:doc "Replies the scope's standing grants as spec, kind, who ratified each and when.")
    (door planner declare-need (scope-id agent-id spec qty unit location arcs-json note emoji from until #:optional (name #f) (cats-json #f) (criteria-json #f) (need-kind #f) (voice 0))
          #:auth operator #:topic slots #:reply ok-or-error #:kind preference
          #:doc "Declares or edits a need slot need:AID:SPEC as a standing intent with window, NEED-KIND and VOICE, refused when the kind lacks ratification; replies its id.")
    (door planner my-slots (scope-id agent-id)
          #:auth operator #:topic slots #:reply ok-or-error #:kind read
          #:doc "Replies the citizen's own needs and non-zero means with quantity, unit, place, cats, criteria and arcs.")
    (door planner our-slots (scope-id home-scope-id agent-id)
          #:auth operator #:topic slots #:reply ok-or-error #:kind read
          #:doc "Replies the scope's folded need cells and capacity cells, each carrying the asker's own share as `mine` read from their home scope.")
    (door planner retire-need (scope-id agent-id spec)
          #:auth operator #:topic slots #:reply ok-or-error #:kind performative
          #:doc "Removes the citizen's own need intent entirely and fires the slot rail; replies (ok . IID).")
    (door planner slots-at (scope-id)
          #:auth operator #:topic slots #:reply ok-or-error #:kind read
          #:doc "Replies the scope's live standing needs and commons-held means, each joined to the last solve's drawn (0 when unseen); use my-slots for the owner's private view.")
    (door planner family-split (needs-json purse labour-h weighted? #:optional (members-json "[]") (per-citizen-hours 40.0))
          #:auth operator #:topic planning #:reply ok-or-error #:kind read
          #:doc "Splits a household purse across its members' needs by harmony with optional member voice; replies the per-member rows.")
    (door planner family-bills (needs-json purse labour-h weighted? eur-per-hour #:optional (members-json "[]") (per-citizen-hours 40.0))
          #:auth operator #:topic planning #:reply ok-or-error #:kind read
          #:doc "Replies what the week takes in euros and hours beyond the purse for rights, then needs, then wants held as walls.")
    (door planner family-externalities (needs-json purse labour-h weighted? #:optional (members-json "[]") (per-citizen-hours 40.0))
          #:auth operator #:topic planning #:reply ok-or-error #:kind read
          #:doc "Replies, per held/des row, the euros the other members would have received had it not been asked.")
    (door planner match-slots (scope-id tree)
          #:auth operator #:topic slots #:reply ok-or-error #:kind read
          #:doc "Scores every standing need against every declared means over TREE by affinity, window overlap and bilateral eligibility; replies needs, means and matches.")
    ))

(define %door-index
  (let ((h (make-hash-table)))
    (for-each (lambda (d) (hash-set! h (cons (door-object d) (door-name d)) d)) %doors)
    h))
