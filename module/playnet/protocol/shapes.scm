;;; module/playnet/protocol/shapes.scm — what each door argument is
;;;
;;; (playnet doors protocol) declares every door's arguments as written in its
;;; method head. This table says what those names carry, once per NAME:
;;; the same name means the same thing on every door (`scope-id` is always a
;;; scope id, `qty` always a number), so the shape lives with the name and a
;;; door inherits it. A door whose argument is named against the convention
;;; gets an override in %door-arg-overrides, keyed by object, door, name.
;;;
;;; Each shape is one JSON Schema fragment (the OpenAPI document and the MCP
;;; manifest read that) and one TypeScript type (seam.d.ts reads that). Two
;;; shapes are not wire shapes at all:
;;;   internal    an in-process object (a vat, a thunk, a store) — the door is
;;;               reachable by the gateway's own code only
;;;   capability  a CapTP reference (a watcher, an inbox) — the door works
;;;               over CapTP and has no HTTP form
;;; A door with any such argument is emitted without a path.
;;;
;;; tools/lint/protocol-lint.scm refuses an argument name this table does not
;;; know, so a new door either follows a known name or adds one here.

(define-module (playnet protocol shapes)
  #:use-module (playnet doors protocol)
  #:use-module (srfi srfi-1)
  #:export (%shapes %arg-shapes %door-arg-overrides %reply-shapes %arg-docs
            shape-schema shape-ts arg-shape arg-doc door-arg-shapes door-http?
            reply-schema reply-ts))

;; shape → (json-schema-alist . ts-type)
(define %shapes
  '((string      . (((type . "string")) . "string"))
    (integer     . (((type . "integer")) . "number"))
    (number      . (((type . "number")) . "number"))
    (boolean     . (((type . "boolean")) . "boolean"))
    (json        . (((type . "string") (contentMediaType . "application/json")
                     (description . "a JSON document, as a string")) . "string"))
    (aid         . (((type . "string") (pattern . "^[A-Z][A-Za-z0-9_-]{43}$")
                     (description . "a KERI AID prefix")) . "string"))
    (said        . (((type . "string") (pattern . "^[A-Z][A-Za-z0-9_-]{43}$")
                     (description . "a SAID")) . "string"))
    (qb64        . (((type . "string") (description . "a CESR qb64 signature")) . "string"))
    (hex         . (((type . "string") (pattern . "^[0-9a-f]*$")) . "string"))
    (base64      . (((type . "string") (contentEncoding . "base64")) . "string"))
    (instant     . (((type . "string") (format . "date-time")
                     (description . "civil ISO 8601 at the boundary")) . "string"))
    (scope-id    . (((type . "string") (description . "a scope (commune) id")) . "string"))
    (agent-id    . (((type . "string") (description . "an agent id inside a scope")) . "string"))
    (spec        . (((type . "string") (description . "a resource-specification id")) . "string"))
    (unit        . (((type . "string") (description . "a unit symbol, e.g. kg, h, each")) . "string"))
    (place       . (((type . "string") (description . "a place id or name")) . "string"))
    (id          . (((type . "string")) . "string"))
    (symbol      . (((type . "string") (description . "a symbol, sent as its name")) . "string"))
    (alist       . (((type . "object") (additionalProperties . #t)) . "Record<string, unknown>"))
    (list        . (((type . "array")) . "unknown[]"))
    (rest        . (((type . "array") (description . "trailing arguments, as written in the head")) . "unknown[]"))
    (any         . (() . "unknown"))
    (capability  . (((description . "a CapTP reference; no HTTP form")) . "unknown"))
    (internal    . (((description . "in-process only")) . "never"))))

;; argument name → one clause on what the value is, for a name whose shape
;; says only its type. The same name means the same thing on every door, so
;; one line covers every door that takes it. Filled below %arg-shapes.
(define %arg-docs
  '(
    (records-json       . "a JSON array of ValueFlows records: kind (event|need|offer|flow), action, spec, qty, unit, and a need's arcs")
    (preset-id          . "a preset's id as the `presets` door lists it (bread-town, garden, …)")
    (username           . "the seat's login handle, a plain string chosen at signup")
    (email              . "the seat's contact email, display-only on the member record")
    (oobi-url           . "the KERIA-hosted OOBI URL where this AID's key state can be resolved")
    (icp-alist          . "the AID's inception event as a JSON object (KERI icp fields, serialized)")
    (sigs               . "a JSON array of CESR qb64 signatures over the event, one per signing key")
    (rotations          . "a JSON array of the AID's rotation events after inception, each a KERI rot object")
    (replies            . "a JSON array of CESR-framed OKEA endpoint reply events (/end/role/add, /loc/scheme)")
    (nonce              . "the 32-byte challenge from keri-challenge as lowercase hex; expires 120 s after issue")
    (audio-b64          . "a base64-encoded audio recording to transcribe")
    (nl-text            . "a natural-language sentence to express as Scheme")
    (system-prompt      . "the completion's system instruction, a plain string")
    (user-prompt        . "the completion's user turn, a plain string")
    (model              . "an AI model name, or #f for the service's default")
    (domain             . "on corpus-search a corpus domain name or #f for all; on open the ballot domain (policy, recomposition, …)")
    (query              . "free-text search terms")
    (limit              . "the maximum number of results to reply")
    (name               . "on announce/leave the caller's display name; on declare-place the human name of the new place; on declare-need/declare-means the row's own display name, default SPEC (need) or \"AGENT's SPEC\" (means)")
    (target-name        . "the display name of the peer the signal or introduction is addressed to")
    (from-name          . "the display name of the peer sending the signal")
    (signal-type        . "the WebRTC signal kind, one of walkie-offer, walkie-answer, walkie-ice, walkie-cam (on or off: whether the sender is sending video) or invite, room-suffixed")
    (room               . "a meeting-room topic string; its roster is who the walkie meshes over")
    (device-id          . "the push subscription's device identifier chosen by the browser")
    (identity-key       . "a KERI AID prefix or legacy org pubkey naming the caller; the gate is removed, always errors")
    (event-key          . "a qb64 public key an identity's log carries as a signing key, in an event's k[0] — the first key a passcode derives is one")
    (role               . "a role name; the role ceremony is removed, so has-role? always replies #f")
    (id                 . "on open/cast/close/get-result a proposal id; on retire-payout/settle-payout a payout intent id; on add-scope! a scope id")
    (ctx                . "the notification channel's destination address for KIND (an email, a push endpoint, …)")
    (list-id            . "the id of one shared pin list off the ^pins fold")
    (display-name       . "the profile's display name shown to others")
    (k                  . "a requested quorum count; ignored, the ecosystem's own personhood quorum applies")
    (threshold          . "the number of Shamir shares needed to reconstruct the bran")
    (shares             . "a JSON array of the bran's Shamir shares, each addressed to a contact's AID")
    (packet-hex         . "a signed Reticulum announce or DATA packet as lowercase hex bytes")
    (cred-alist-raw     . "a browser-built, browser-signed ACDC as a JSON object; issuance gate is removed, always errors")
    (description        . "the proposal's human-readable description")
    (franchise          . "who votes: the symbol federation, or the list (scope SCOPE-ID)")
    (arg                . "the legacy stance: a position symbol (yes, no, …) for a ballot, a distribution map for an expression")
    (position           . "the ballot position the caller takes, sent as a symbol name such as yes or no")
    (qty                . "the quantity of SPEC in UNIT, a positive number")
    (note               . "a free-text note recorded on the row or event")
    (counted            . "how much of the stock the counter found, zero or more, in the stock's own unit")
    (parent             . "the id of the place a new place is inside, \"\" when it is inside none")
    (upload             . "the browser's own name for one sending of pictures to be read")
    (index              . "which picture of an upload a part belongs to, 0 to 3")
    (ballot-id          . "the id of a contest ballot, contest: and the contested count's adjustment id")
    (hash               . "a picture's hash as a count names it, sha256: and sixty-four hex digits")
    (part-no            . "which part of a picture this is, from 0")
    (parts              . "how many parts the picture is sent in, 26 at the most")
    (part               . "a run of a picture's base64, sixteen kilobytes at the most")
    (regime             . "how a planned count is disclosed: announced, undisclosed or random; absent, announced")
    (counter            . "the AID a count is offered to, \"\" for the member whose turn it is")
    (at-most            . "the most offers one call lays; absent, 3")
    (code               . "a label's code: the six characters a resource is known by in its scope")
    (technique          . "the counting technique: stated, label or photo; absent, stated")
    (fulfills           . "the id of the counter's commitment when a plan asked for the count, \"\" when none")
    (evidence           . "the hash of the picture a count was read from, sha256: and sixty-four hex digits, \"\" when none; the picture stays with the counter, the hash rides the count's events as evidence:<hash> and the observation credential as its evidence claim")
    (emoji              . "an emoji string shown on the need slot")
    (address            . "the external Monero address the payout is sent to")
    (xmr                . "the amount of XMR to send, a number in whole monero")
    (cost               . "what the purchase cost in MONEY-SPEC units, a number; 0 only when donated")
    (receipt            . "a receipt reference string for the purchase, \"\" when none")
    (donation?          . "#t when the purchase was donated to the commons and nothing is owed back")
    (purse              . "the household's weekly money on hand, a number in euros")
    (labour-h           . "the household's labour hours on hand this week")
    (weighted?          . "#t to weight the split by each member's contributed hours rather than equally")
    (per-citizen-hours  . "the weekly hours one citizen's full labour counts as (default 40)")
    (eur-per-hour       . "the euro value of one labour hour, used to price the bills")
    (period             . "a period index into the plan horizon; 0 is now, later integers are future periods")
    (base               . "the resource-specification id a warmed or cooled form is made from; the form is base warmed by delta-t")
    (specific-heat      . "the material's specific heat in kJ/(kg·K), stated once per material")
    (delta-t            . "the form's excess over ambient in kelvin, signed: positive warmed, negative cooled")
    (enclosure          . "the keep-in-place resource-specification id the form is held in; its conductance sets the relaxation")
    (ua                 . "the enclosure's conductance times area, kW/K; absent means the form is held with no loss")
    (mass               . "the held mass in kg, with ua and specific-heat the time constant m·c/(U·A)")
    (lat                . "latitude in decimal degrees; 0 with lon 0 means no coordinates")
    (lon                . "longitude in decimal degrees; 0 with lat 0 means no coordinates")
    (movable            . "#t when the socialized resource may leave the owner's place")
    (rt                 . "the return-to place for a socialized resource, \"\" when unset")
    (cf                 . "the condition floor the resource must be returned in, \"\" when unset")
    (res                . "the exact resource id the grant or claim names, \"\" when unnamed")
    (ref                . "on the signing legs a caller nonce folded into the SAID (\"\" = none); on slots-watch a CapTP watcher reference")
    (trig               . "the record-purchase event id the claim is triggered by, \"\" when none")
    (resource-id        . "an economic-resource id in the scope (own-means: the titled thing; claim/resource-detail: the good)")
    (scope-aid          . "the AID of the scope the declaration is spoken for; the caller must be one of its governors")
    (federation-aid     . "the AID of the federation this gateway holds that admits the commune; the caller must be a governor the federation recognises")
    (sturdyref-uri      . "the sturdyref the commune's peer answers at, an ocapn:// URI")
    (ratification       . "the SAID of the commune's consent, when the federation's governance policy requires one; absent otherwise")
    (to-scope-id        . "the scope the person's home moves to")
    (ceiling            . "the most unit-hours a day this scope will host of RESOURCE-SPEC, a positive number")
    (domain-spec        . "the domain a regime claim is over: a recipe id, as recipe-standing reads it")
    (tails              . "the regime's tails, one of thin, fat, unknown")
    (fraction           . "the share of the caller's voice delegated, a number in (0, 1]")
    (event-id           . "the id of a recorded economic event the witness ceremony opens over")
    (commitment-id      . "the id of a commitment being fulfilled, effort-recorded or ended")
    (topic              . "a chat topic string under the scope: an intent/commitment id, a place, a walkie room, …")
    (intent-id          . "the id of a suggested intent from materialize, accepted or declined by the worker")
    (cell               . "a time-space cell key of the form place@period, paired with SKILL as skill@cell")
    (willing?           . "#t to opt in to being materialized for skill@cell, #f to withdraw")
    (hours              . "on express-willingness an optional hours budget; on offer-work the effort hours offered")
    (labor-cost         . "the credit drawn for the claim in hours, or #f to derive qty × the good's crystallized SNLT")
    (label              . "the human name of the social invite, stored as the intent's name")
    (proposal-id        . "the id of a directed proposal (social invite or work offer) in the invitee's snapshot")
    (plan-id            . "the plan identifier the snapshot is built for")
    (topics             . "a JSON array of topic strings to read the last line of at once")
    (total              . "on record-flow the row's planned total that sizes its commitment; on means-plan the federation bar for SPEC")
    (proc               . "a process id: the row's process on record-flow, the process the work is input-of on offer-work")
    (row-id             . "on record-flow the plan's own id for the schedule row being confirmed, as the schedule carries it; absent, the row is found by its coordinates")
    (process-id         . "the id of a process in the scope's plan")
    (container-id       . "the id of the shared container the drop-off or pickup happens in")
    (lens               . "a named cut of the taxonomy, resolved against this AID's own contact book; absent = the global cut")
    (budget             . "a derived federation budget (billions), sizing the law program's bundle; absent = the stewarded fallback")
    (target-ids         . "on open with kind expression, the distribution's own target ids as a JSON array; required for that kind")
    (subject            . "a \"kind:id\" string the forum resolves an open proposal against, e.g. \"recipe:bread\"")
    (options            . "an audit's overrides as a JSON object: consequence-factor (default 1) and tolerance (default 0.25)")
    (message-kind       . "a chat message's kind, e.g. text or system; default text")
    (u                  . "the stance nonce echoed back from stance-preimage's own claims; a reply refusing this as missing needs a fresh preimage")
    (acting-aid         . "when given, an AID whose social invites are included in the snapshot's proposals")
    (radius             . "combined with cell, also matches cells within RADIUS hops of it")
    (time-window        . "an availability window as JSON; only entries whose own window overlaps it match")
    (cats-json          . "a JSON array of classification terms for the affinity side of matching")
    (criteria-json      . "the eligibility sidecar as JSON (rule, divisibility, link, priority); absent clears it")
    (need-kind          . "under the reserved prefix, the need's own reproduction kind: floor, held or des (default des); called tension in older clients")
    (voice              . "the attached voice mass on a need's own kind claim, a number; default 0")
    (deliver-at         . "when the good should reach the claimant, an ISO instant, recorded on the transfer")
    (accountable        . "on drop-event, who holds the rights to a thing being INTRODUCED; absent, it enters the books as the commons' own")
    (window-days        . "the trailing window a read looks back over, in days; default 7")
    (area               . "the dwelling's whole floor area in m², a positive number — shared by the beds it houses")
    (rooms              . "the dwelling's rooms, kitchen and bathroom aside, a positive number — shared by the beds it houses")
    (warmth-winter      . "the indoor temperature the dwelling is kept at in winter, in °C")
    (warmth-summer      . "the indoor temperature the dwelling reaches in summer, in °C")
    (beds             . "how many people the dwelling houses a night, a positive number")
    (attests-json       . "a JSON array of the gate rows an inspection of the dwelling would certify: hs-safety, hs-sanitation, hs-energy, hs-dry, hs-quiet, hs-dark, hs-accessibility")
    (certified          . "#t when the dwelling's certificate stands today")
    (rent               . "the dwelling's own rent in EUR per person-night, 0 when no landlord is paid")
    (tenure             . "own, rent or lodged — custody, never a row of the housing vector")
    (eligible           . "the owner's steward rule as JSON slot criteria, bounding who may be assigned work drawing on the grant; absent means anyone")
    (opts               . "a solve's options alist (movable/storable/whole/tau/willing-only/horizon/reproduce/plan-id/displacement-of as the door names); absent runs with every default")))
(define (arg-doc name)
  "The documented meaning of argument NAME, or #f when its shape says enough."
  (assq-ref %arg-docs name))

;; argument name → shape
(define %arg-shapes
  '(;; the ValueFlows lint door
    (records-json . json)
    ;; identity
    (aid-prefix . aid) (aid . aid) (delegate-aid . aid) (commune-aid . aid)
    (subject-aid . aid) (candidate-aid . aid) (source-aid . aid) (inviter . aid)
    (invitee . aid) (worker . aid) (claimant . aid) (agent . aid) (acting-as . aid)
    (identity-key . string) (event-key . string) (ctx . string) (username . string) (display-name . string)
    (email . string) (name . string) (label . string) (role . string)
    ;; keri / credentials
    (said . said) (grant-said . said) (claim-said . said) (nonce . hex)
    (signature . qb64) (signature-qb64 . qb64) (sig . qb64) (sigs . list)
    (icp-alist . alist) (rotations . list) (rot-alist-raw . alist)
    (cred-alist-raw . alist) (wire . json) (wire-json . json) (replies . list)
    (oobi-url . string) (shares . list) (threshold . integer) (k . integer)
    (packet-hex . hex) (audio-b64 . base64) (u-opt . rest)
    ;; scopes, agents, resources
    (scope-id . scope-id) (home-scope-id . scope-id) (communes . list)
    (agent-id . agent-id) (spec . spec) (skill-spec-id . spec) (skill . spec)
    (money-spec . spec) (resource-id . id) (res . id) (container-id . id)
    (process-id . id) (intent-id . id) (plan-id . id) (commitment-id . id) (preset-id . id)
    (event-id . id) (proposal-id . id) (list-id . id) (device-id . id)
    (cid . id) (id . id) (ref . string) (trig . string) (rt . string) (cf . string)
    (unit . unit) (qty-unit . unit) (qty . number) (total . number) (hours . number)
    (base . spec) (enclosure . spec) (specific-heat . number) (delta-t . number) (ua . number) (mass . number)
    (labor-cost . number) (cost . number) (xmr . number) (purse . number)
    (labour-h . number) (eur-per-hour . number) (per-citizen-hours . number)
    (fraction . number) (limit . integer) (max-age . integer) (period . integer)
    (lat . number) (lon . number) (position . string) (place . place)
    (area . number) (rooms . number) (warmth-winter . number) (warmth-summer . number) (beds . number) (attests-json . json) (certified . boolean) (rent . number) (tenure . string)
    (location . place) (from-place . place) (to-place . place) (where . place)
    (address . string) (cell . string) (room . string) (topic . string) (topics . list)
    (kind . symbol) (action . symbol) (mode . symbol) (style . symbol) (method . symbol)
    (rel . symbol) (domain . string) (franchise . string) (description . string)
    (note . string) (emoji . string) (reason . string) (query . string)
    (nl-text . string) (system-prompt . string) (user-prompt . string) (model . string)
    (target-name . string) (from-name . string) (signal-type . string)
    (signal-data . json) (subscription-json . json) (needs-json . json)
    (members-json . json) (arcs-json . json) (json . json) (data . json)
    (body . json) (demand . json) (availability-window . json) (periods . json)
    (ceilings . json) (overrides . json) (mandate-spec . json) (claim . json)
    (plan . json) (tree . json) (seen . json) (boundary-good . spec)
    ;; the goods that cross for a scope in a solve across scopes
    (goods . list)
    (weighted? . boolean) (willing? . boolean) (donation? . boolean) (movable . boolean)
    (from . instant) (until . instant) (due . instant) (at . instant) (since . integer)
    (timestamp . instant) (when-iso . instant) (now-iso . instant) (t0-iso . instant)
    (t1-iso . instant) (proc . string) (row-id . id) (receipt . string) (txid . string)
    (counted . number) (technique . string) (fulfills . id) (evidence . string)
    (parent . place) (code . string)
    (regime . string) (counter . aid) (at-most . integer)
    (upload . string) (index . integer) (part . base64)
    (ballot-id . id) (hash . string) (part-no . integer) (parts . integer)
    (new-parent . scope-id) (arg . any) (args . rest) (opt . rest)
    (rest . rest) (more . rest) (d . any) (p . any) (wc . any)
    ;; formerly-bare variadic tails, split into their real named arguments
    (lens . string) (budget . number)
    ;; the voice field's hands: a hand as JSON, and the rows a scope lays down
    (hand-json . json) (rows . json)
    ;; a contrary observation on the map: the process run, the map's figure, the reading, the work event witnessing it
    (process . id) (nominal . number) (reading . number) (witness . id)
    (target-ids . json) (subject . string) (options . alist)
    ;; a scope's own declarations: the scope spoken for, a hosting ceiling, a regime's domain and tails
    (scope-aid . aid) (ceiling . number) (domain-spec . spec) (tails . symbol) (resource-spec . spec)
    ;; a federation admits a commune; a person's home moves
    (federation-aid . aid) (sturdyref-uri . string) (ratification . said) (to-scope-id . scope-id)
    (message-kind . string) (u . qb64) (acting-aid . aid)
    (radius . integer) (time-window . json)
    (cats-json . json) (criteria-json . json) (need-kind . string) (voice . number)
    (deliver-at . instant) (accountable . aid) (window-days . number) (eligible . json)
    (opts . alist)
    ;; capabilities and in-process objects
    (user-inbox . capability) (client-inbox . capability) (watcher-ref . capability)
    (cb . capability) (vat . internal) (thunk . internal) (store . internal)
    (root . internal)))

;; (object door name) → shape, for a name whose meaning differs on one door
(define %door-arg-overrides
  '(((session cast arg) . string)             ; the stance, as text
    ((lobby signal signal-data) . json)
    ((planner claim claim) . json)
    ;; a watcher is a CapTP reference: these two doors work over CapTP only
    ((planner slots-watch ref) . capability)
    ((planner slots-unwatch ref) . capability)
    ;; commitment-drift's AT is an epoch NUMBER (checked (number? …) in the
    ;; code), unlike every other door's `at`, which is the ISO string half
    ;; of an at/until pair
    ((planner commitment-drift at) . number)))

(define (shape-schema shape) (car (or (assq-ref %shapes shape) (error "no such shape" shape))))
(define (shape-ts shape)     (cdr (or (assq-ref %shapes shape) (error "no such shape" shape))))

(define (arg-shape object door name)
  "The shape of argument NAME on DOOR of OBJECT, or #f when the table lacks it."
  (or (assoc-ref %door-arg-overrides (list object door name))
      (assq-ref %arg-shapes name)))

(define (door-arg-shapes d)
  "((name shape required? default) …) for door D, in head order; #f shape =
unknown. DEFAULT is the literal value an omitted optional falls back to — the
declaration's own `(name expr)` when written that way, #f for a bare optional
name or a required entry (never consulted for a required one: its absence is
refused before DEFAULT would matter). This is the value a caller who leaves
the argument out gets in its place — real callers of DOOR-ARGS-FROM-BODY rely
on it lining up with what the door's own Scheme #:optional default already
is, so a middle optional being skipped never shifts the ones after it."
  (let loop ((a (door-args d)) (mode 'req) (acc '()))
    (cond
     ((null? a) (reverse acc))
     ((symbol? a) (reverse (cons (list a (or (arg-shape (door-object d) (door-name d) a) 'rest) #f #f) acc)))
     ((memq (car a) '(#:optional #:key)) (loop (cdr a) 'opt acc))
     ((pair? (car a))
      (loop (cdr a) mode (cons (list (caar a) (arg-shape (door-object d) (door-name d) (caar a)) #f (cadar a)) acc)))
     (else
      (loop (cdr a) mode
            (cons (list (car a) (arg-shape (door-object d) (door-name d) (car a)) (eq? mode 'req) #f) acc))))))

(define (door-http? d)
  "A door has an HTTP form when its auth allows a client and no argument is a
capability or in-process object."
  (and (memq (door-auth d) '(anonymous device))
       (not (eq? (reply-base (door-reply d)) 'capability))
       (not (any (lambda (e) (memq (cadr e) '(capability internal))) (door-arg-shapes d)))))

;; reply shape → (json-schema-alist . ts-type). A door's #:reply names one of
;; these; `promise:X` is X delivered a turn later (the HTTP door awaits it).
(define %reply-shapes
  '((ok-or-error  . (((oneOf . #(((const . "ok"))
                                ((type . "array")
                                 (prefixItems . #(((const . "ok")) ((description . "the value"))))
                                 (description . "(ok . value)"))
                                ((type . "array")
                                 (prefixItems . #(((const . "error")) ((type . "string"))))
                                 (description . "(error \"reason\")"))
                                ((type . "object")
                                 (properties . ((error . ((type . "string")))))
                                 (description . "((error . \"reason\"))")))))
                     . "\"ok\" | [\"ok\", unknown] | [\"error\", string] | { error: string }"))
    (boolean      . (((type . "boolean")) . "boolean"))
    (string       . (((type . "string")) . "string"))
    (json         . (((type . "string") (contentMediaType . "application/json")) . "string"))
    (number       . (((type . "number")) . "number"))
    (symbol       . (((type . "string")) . "string"))
    (alist        . (((type . "object") (additionalProperties . #t)) . "Record<string, unknown>"))
    (alist-list   . (((type . "array") (items . ((type . "object") (additionalProperties . #t)))) . "Record<string, unknown>[]"))
    (list         . (((type . "array")) . "unknown[]"))
    (capability   . (((description . "a CapTP reference; no HTTP form")) . "unknown"))
    (void         . (((description . "nothing meaningful")) . "void"))
    (error-stub   . (((type . "array")
                      (prefixItems . #(((const . "error")) ((type . "string"))))
                      (description . "always the removed-gate error")) . "[\"error\", string]"))
    (mixed        . (((description . "differs by branch; see the door's doc")) . "unknown"))
    (unknown      . (((description . "unclassified")) . "unknown"))))

(define (reply-base r)
  "promise:X → X; anything else itself."
  (let ((s (symbol->string r)))
    (if (string-prefix? "promise:" s) (string->symbol (substring s 8)) r)))
(define (reply-schema r) (car (or (assq-ref %reply-shapes (reply-base r)) (error "no such reply shape" r))))
(define (reply-ts r)     (cdr (or (assq-ref %reply-shapes (reply-base r)) (error "no such reply shape" r))))
