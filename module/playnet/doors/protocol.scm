;;; SPDX-License-Identifier: AGPL-3.0-or-later
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
  #:use-module ((playnet protocol seam) #:select (%handlers handler-name handler-doors handler-arity handler-ref))
  #:export (%doors door-ref doors-of
            door? door-object door-name door-args door-auth door-topic door-seam door-reply door-kind door-to door-doc door-feature door-keyed door-offline doors-of-feature doors-keyed doors-offline offline-handlers %kinds %targets
            %topics topic-doc door-audience
            %protocol-version))

;; Bumped on any non-additive change (a door removed, renamed, or its args
;; reshaped). Additive changes need no bump.
(define %protocol-version 1)

(define-record-type <door>
  (make-door object name args auth topic reply kind to doc feature keyed offline)
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
  (keyed   door-keyed)       ; the name of the argument that keys one act (a tap), or #f
  (offline door-offline))    ; `act`, `(act ARG)` or `read` where a device with no gateway answers it, else #f

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
;;       [#:feature F] [#:keyed ARG] [#:offline O] #:doc D) — every part is data, in any order
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
    ((_ (o n a) (opt ...) #:offline v . r) (door-collect (o n a) (opt ... (offline . v)) . r))
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
        (to (opt 'to 'self)) (feature (opt 'feature #f)) (keyed (opt 'keyed #f)) (offline (opt 'offline #f)))
    (for-each (lambda (o)
                (unless (memq (car o) '(auth topic reply kind to feature keyed offline))
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
    ;; a door the device answers with no gateway in reach says how: a READ answers from the
    ;; device's copy, an ACT lands on it and waits for the gateway (ui/app/outbox.ts), stamped
    ;; with the instant its argument ARG carries when it states none (tools/emit/offline-emit.scm
    ;; derives the page's table; tools/lint/protocol-lint.scm holds the rest)
    (unless (or (not offline) (memq offline '(act read))
                (and (pair? offline) (eq? 'act (car offline)) (pair? (cdr offline)) (symbol? (cadr offline))
                     (null? (cddr offline))))
      (error "door: offline is read | act | (act ARG)" object name offline))
    (make-door object name args auth topic reply kind to doc feature keyed offline)))

(define (doors-of object) (filter (lambda (d) (eq? (door-object d) object)) %doors))
(define (doors-of-feature feature) (filter (lambda (d) (eq? (door-feature d) feature)) %doors))
(define (doors-keyed) (filter door-keyed %doors))
;; the door's argument names in order, `#:optional` and defaults dropped
(define (door-arg-names d)
  (let loop ((a (door-args d)))
    (cond ((null? a) '())
          ((symbol? a) (list a))
          ((keyword? (car a)) (loop (cdr a)))
          (else (cons (if (pair? (car a)) (caar a) (car a)) (loop (cdr a)))))))

(define (doors-offline) (filter door-offline %doors))

(define (offline-handlers)
  "((handler-name kind at) …), sorted: every seam handler whose door declares `#:offline`.
   KIND is act or read; AT is the index of the argument that stamps the act's instant
   among the handler's own, or #f where the act names itself. The handler drops the
   door's leading arguments the session fills in, so an index counts from the end."
  (sort (delete-duplicates
         (filter-map
          (lambda (d)
            (let* ((o (door-offline d)) (name (door-seam d)))
              (and name
                   (let* ((kind (if (pair? o) (car o) o))
                          (names (door-arg-names d))
                          (dropped (- (length names) (handler-arity (handler-ref name))))
                          (at (and (pair? o)
                                   (let ((i (list-index (lambda (n) (eq? n (cadr o))) names)))
                                     (and i (- i dropped))))))
                     (list name kind at)))))
          (doors-offline)))
        (lambda (a b) (string<? (car a) (car b)))))
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
    (door lobby ice-servers ()
          #:auth anonymous #:topic chat #:reply alist #:kind read
          #:doc "Replies the ICE servers WebRTC peers find each other through, as a list of alists: \"urls\" always, \"username\" and \"credential\" when a relay wants them. The gateway's configuration decides the list; a client carries none of its own.")
    (door lobby get-mailbox (identity-key)
          #:auth anonymous #:topic operations #:reply error-stub #:kind read
          #:doc "Answers the removed-role-gate error so an old client hears why mailbox access has no wiring; the authenticated session's mesh mailbox doors serve deliveries.")
    (door lobby online-users ()
          #:auth anonymous #:topic chat #:reply list #:kind read
          #:doc "Replies the display names connected to this gateway right now, which the contact book joins onto its online dot; presence is gateway-local.")
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
    (door session sync-log (data)
          #:auth device #:topic commitments #:reply ok-or-error #:kind constative #:to self
          #:doc "Stores DATA, the browser's opaque JSON captain's log, as this AID's server-side backup; replies ok or an error with the failure.")
    (door session list-log ()
          #:auth device #:topic commitments #:reply json #:kind read #:to self
          #:doc "Replies this AID's captain's log backup as the opaque JSON string sync-log stored, or \"\" when none is held.")
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
    (door session admit-commune (federation-aid commune-aid sturdyref-uri #:optional (ratification #f))
          #:auth device #:topic governance #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Admits the commune COMMUNE-AID into the federation FEDERATION-AID this gateway holds, at the sturdyref its peer answers at, as one of the federation's governors (the federation's own ladder decides whether it recognises the caller, and its governance policy may require the commune's consent as RATIFICATION, a SAID). The goods that cross are not named: the commune tells the federation what it deals in. Replies ok or an error.")
    (door session my-grants ()
          #:auth device #:topic custody #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok rows), the live custody grants this AID holds out: said, spec, commune, until, qty, consume or use, and steward rule.")
    (door session my-titles ()
          #:auth device #:topic custody #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok rows), the live ownership titles this AID holds: said, resource id, spec and kind.")
    (door session delegation-preimage (delegate-aid fraction #:optional (scope-id #f))
          #:auth device #:topic governance #:reply ok-or-error #:kind read #:to governance
          #:doc "Replies (ok fields), the SAID fields of the liquid delegation of FRACTION to DELEGATE-AID — federation-wide, or scoped to SCOPE-ID when given — for the client to sign for set-delegation-signed. Pass the SAME SCOPE-ID there: it is baked into this SAID.")
    (door session set-delegation-signed (delegate-aid fraction signature #:optional (scope-id #f))
          #:auth device #:topic governance #:reply ok-or-error #:kind preference #:to governance
          #:doc "Records the delegation of FRACTION to DELEGATE-AID under this AID's own SIGNATURE over the delegation-preimage fields; SCOPE-ID must match the one that preimage was asked for. Replies ok or an error.")
    (door session close (id)
          #:auth device #:topic governance #:reply ok-or-error #:kind performative #:to governance
          #:doc "Closes proposal ID as this governor AID, recording the tally and issuing a signed tally-result credential for a ballot; replies (ok id) or an error.")
    (door session get-result (id)
          #:auth device #:topic governance #:reply mixed #:kind read #:to governance
          #:doc "Replies proposal ID's result with its meta: (closed . tally) once closed, (open . live-tally) while open, or an error for an unknown id.")
    (door session list-delegations ()
          #:auth device #:topic governance #:reply list #:kind read #:to governance
          #:doc "Lists this AID's federation-default delegations as (delegate-aid fraction mandated?) rows.")
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

    ;; ── machine — the node tab's machine book ──────────────────────────
    ;; identity-bound doors pass this AID as the member the act belongs to:
    ;; the lender on offer, claim and preempt; the borrower on submit,
    ;; withdraw and accept. Reads are open.
    (door session machine-offer (commune-aid lane classes headroom repro . opts)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Advertises this AID's machine as a compute lane in COMMUNE-AID: LANE the lane id, CLASSES the task classes it runs, HEADROOM the offered capacity, REPRO its replay promise; OPTS carry the wire extras. Replies ok or an error.")
    (door session machine-retract (commune-aid offer-id)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Withdraws offer OFFER-ID in COMMUNE-AID, this AID its lender; replies ok or an error.")
    (door session machine-offers (commune-aid)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replies the open compute offers in COMMUNE-AID, whoever's.")
    (door session machine-submit (commune-aid task-class lane repro input-hash . opts)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Submits an enveloped job in COMMUNE-AID under TASK-CLASS, wanting LANE, REPRO the replay requirement, INPUT-HASH the envelope's digest; OPTS carry the wire extras. The envelope carries no amount. Replies ok or an error.")
    (door session machine-withdraw (commune-aid job-id)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Withdraws unclaimed job JOB-ID in COMMUNE-AID, this AID its borrower; replies ok or an error.")
    (door session machine-jobs (commune-aid)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replies the open compute jobs in COMMUNE-AID, whoever's.")
    (door session machine-match (commune-aid job-id)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replies the offers JOB-ID in COMMUNE-AID matches on class and lane, for the borrower to claim one.")
    (door session machine-claim (commune-aid job-id offer-id . opts)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Binds JOB-ID to OFFER-ID in COMMUNE-AID, this AID the lender on the claim; OPTS carry the wire extras. Replies ok or an error.")
    (door session machine-accept (commune-aid claim-id)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Accepts CLAIM-ID in COMMUNE-AID, this AID the borrower confirming the work may run; replies ok or an error.")
    (door session machine-preempt (commune-aid claim-id)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Lifts CLAIM-ID in COMMUNE-AID before it runs, this AID the lender reclaiming the lane; replies ok or an error.")
    (door session machine-claims (commune-aid)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replies the claims standing in COMMUNE-AID.")
    (door session machine-receipt (commune-aid w)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Delivers the executed envelope's receipt W in COMMUNE-AID — digest, metering (tokens or seconds), the lender's countersignature; replies ok or an error.")
    (door session machine-verify (w)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replays receipt W's envelope and replies whether the output reproduces — the proof a wrong-result dispute rides on.")
    (door session machine-settle (commune-aid w)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Reconciles settlement W in COMMUNE-AID against receipts and the on-chain transfer, governance-cap gated; disputed entries stay held. Replies ok or an error.")
    (door session machine-statements (commune-aid)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replies COMMUNE-AID's periodic signed settlement statements — bridgeJobId, receipt digest, amount, asset, total, transaction hash.")
    (door session machine-envelope (w)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replies job envelope W as kept — the executor fetches it by digest to run; carries no price field.")
    (door session machine-fetch-envelope (commune-aid claim-id)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replies the envelope claim CLAIM-ID in COMMUNE-AID binds, this AID the lender whose node is meant to run it; refuses anyone else.")
    (door session machine-replay (commune-aid claim-id)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replays claim CLAIM-ID's envelope in COMMUNE-AID — the authoritative answer a wrong-result challenge rides on: receipt digest, reproduced, attestation hash, counter-hash.")
    (door session machine-dispute (commune-aid claim-id kind)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Raises a dispute on CLAIM-ID in COMMUNE-AID, KIND 'non-delivery or 'wrong-result; this AID a party to the claim. Three sortition-selected citizens review; the receipt stays held in full until closure.")
    (door session machine-dispute-verdict (commune-aid dispute-id verdict)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Records reviewer VERDICT on DISPUTE-ID in COMMUNE-AID, this AID one of the three sortition-selected reviewers; the record closes on two-of-three.")
    (door session machine-disputes (commune-aid)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replies the disputes open in COMMUNE-AID — raised, reviewing, closed.")
    (door session machine-dispute-close (commune-aid dispute-id)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Closes DISPUTE-ID in COMMUNE-AID past its window or on verdicts in hand; the held receipt's settlement resumes or dies with the record.")
    ;; ── storage challenges — the store kind's replay: a nonce answered by
    ;; sha256(nonce ∥ held bytes), 'exact by construction. The borrower (or
    ;; a governor) issues, the claim's lender answers, the issuer verifies.
    (door session machine-challenge (commune-aid claim-id)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Issues a retention challenge on CLAIM-ID in COMMUNE-AID — a fresh nonce the lender's node must answer with sha256(nonce ∥ held content); this AID the claim's borrower or a governor, CLAIM-ID a live storage claim.")
    (door session machine-challenge-answer (commune-aid challenge-id answer)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Answers CHALLENGE-ID in COMMUNE-AID with ANSWER — sha256(nonce ∥ held bytes) as hex; this AID the claim's lender, before the deadline.")
    (door session machine-challenge-verify (commune-aid challenge-id expected content-hash)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Closes CHALLENGE-ID in COMMUNE-AID — EXPECTED is the issuer's sha256(nonce ∥ content), CONTENT-HASH sha256(content) which must equal the job's committed inputHash; the record lands 'reproduced, 'mismatch or 'failed.")
    (door session machine-challenges (commune-aid claim-id)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replies the storage challenges on CLAIM-ID in COMMUNE-AID — the node's poll surface for what it must answer; this AID a party to the claim or a governor.")
    ;; ── relay signaling — the relay kind's rendezvous: browsers cannot
    ;; listen, so the claim is the mailbox for the SDP/ICE handshake.
    (door session machine-signal (commune-aid claim-id body)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Posts signal BODY on CLAIM-ID in COMMUNE-AID — an opaque blob (an SDP offer/answer, an ICE candidate) seq'd by the shelf; this AID a party to the claim, and the claim must be live.")
    (door session machine-signals (commune-aid claim-id . opts)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replies the signals on CLAIM-ID in COMMUNE-AID strictly after 'after (0 reads all) — the counterparty's poll; this AID a party to the claim or a governor.")
    (door session machine-bind (commune-aid w)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Lands an AccountLink W in COMMUNE-AID — an Ethereum CAIP-10 account bound to a did:key by EIP-712/EIP-191, dual-signed, or the caller's own AID under keri:<aid>; the linked EOAs stand behind the one bridge identity the grant names.")
    (door session machine-unbind (commune-aid key side)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Ends the AccountLink under KEY in COMMUNE-AID — either side may unlink, SIDE naming which ('signer the did:key, 'account the EOA); the record stays, marked by who ended it.")
    (door session machine-bindings (commune-aid)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind read #:to governance
          #:doc "Replies COMMUNE-AID's AccountLinks — didKey, account, purpose, status per row.")
    (door session machine-payout (commune-aid w)
          #:auth device #:topic stock #:reply promise:ok-or-error #:kind performative #:to governance
          #:doc "Pays statement W's sends in COMMUNE-AID — every send to the hive treasury Safe the bridge grant binds; no send rail injected answers an honest error, never a phantom payout.")

    ;; ── planner ──
    ))

(define %door-index
  (let ((h (make-hash-table)))
    (for-each (lambda (d) (hash-set! h (cons (door-object d) (door-name d)) d)) %doors)
    h))
