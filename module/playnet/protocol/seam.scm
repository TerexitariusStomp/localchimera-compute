;;; module/playnet/protocol/seam.scm — the seam, declared once, both halves
;;;
;;; The seam is the object the TypeScript app and the Scheme spine exchange
;;; (ui/app/seam.ts, hoot/day-boot.scm, browser/day-boot.js). It has two
;;; halves, and this table declares both:
;;;
;;;   HANDLERS  app → spine. One entry per handler the spine registers: its
;;;             name, its TypeScript parameter list and return type, the doors
;;;             it sends (a handler composes several — cast signs a stance in
;;;             two doors, signup runs a ceremony), and a doc line. `local`
;;;             handlers touch no door: they work on browser state (keys,
;;;             scope, WebRTC).
;;;   PUSHES    spine → app. One entry per method the spine calls on the seam:
;;;             its name, its TypeScript parameter list, its SINK — the wasm's
;;;             "seam" import that raises it, with how each wire argument is
;;;             read (`json` is parsed, `raw` crosses as the string it is) —
;;;             the seam.data key that KEEPS the value for late readers, and a
;;;             doc line. A push with no sink is raised by day-boot.js itself
;;;             off a page event. seam.ts builds every sink and every push
;;;             from this table: the sink parses, keeps and forwards; the push
;;;             is a forwarder onto the app's bus (ui/app/bus.ts). No app
;;;             module assigns either.
;;;
;;; Emits: ui/app/seam-wire.ts — SeamHandlers + SeamPushes, and SEAM_PUSHES,
;;; SEAM_WIRE + SEAM_SINKS as values, so seam.ts builds its forwarders and
;;; sinks, and the spine worker forwards its sinks, from this one table.
;;; The app and any fork of it typecheck against it. tools/protocol-lint
;;; refuses a handler day-boot registers that is not here, a handler here
;;; that day-boot does not register, a door named here that the declaration
;;; lacks, a JS-raised push here that day-boot.js does not call, a call
;;; day-boot.js makes that is not here, and a "seam" import the wasm declares
;;; that names no sink. Seeded 2026-09-13 from seam.ts and day-boot.scm.

(define-module (playnet protocol seam)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (%handlers handler-ref handler? handler-name handler-params
            handler-returns handler-doors handler-doc handler-local?
            %pushes push-ref push? push-name push-params push-sink push-wire
            push-keep push-doc
            %sink-plumbing %sinks-forwarded))

(define-record-type <handler>
  (make-handler name params returns doors doc)
  handler?
  (name    handler-name)      ; the seam.handlers key
  (params  handler-params)    ; TypeScript parameter list, as text
  (returns handler-returns)   ; TypeScript return type, as text
  (doors   handler-doors)     ; ((object . name) …), in send order
  (doc     handler-doc))

;; (handler NAME PARAMS RETURNS DOORS DOC) — all data.
(define-syntax handler
  (syntax-rules ()
    ((_ name params returns doors doc)
     (make-handler name params returns 'doors doc))))

(define (handler-local? h) (null? (handler-doors h)))
(define (handler-ref name) (find (lambda (h) (string=? (handler-name h) name)) %handlers))

(define-record-type <push>
  (make-push name params sink wire keep doc)
  push?
  (name   push-name)      ; the seam method the spine calls
  (params push-params)    ; TypeScript parameter list, as text
  (sink   push-sink)      ; the wasm's "seam" import that raises it, or #f (JS-side event)
  (wire   push-wire)      ; how the sink reads each wire argument: (json | raw) …
  (keep   push-keep)      ; the seam.data key that keeps the first argument, or #f
  (doc    push-doc))

;; (push NAME PARAMS (SINK KIND …) KEEP DOC), or (push NAME PARAMS #f #f DOC)
;; for a push day-boot.js raises itself — all data.
(define-syntax push
  (syntax-rules ()
    ((_ name params #f keep doc) (make-push name params #f '() keep doc))
    ((_ name params (sink kind ...) keep doc) (make-push name params sink '(kind ...) keep doc))))

(define (push-ref name) (find (lambda (p) (string=? (push-name p) name)) %pushes))

;; the wasm's "seam" imports that are plumbing, never a push: the boot trace,
;; handler registration, callback delivery, and the scope accessor's setter.
(define %sink-plumbing '("trace" "setHandler" "callCallback" "setScope"))

;; every sink the spine worker forwards to the page by name: the pushes' sinks
;; plus the two plumbing sinks that live on the page (setHandler and
;; callCallback are answered in the worker itself).
(define (%sinks-forwarded)
  (append (filter-map push-sink %pushes) '("trace" "setScope")))

(define %pushes
  (list
    (push "status" "state: GatewayStatus" ("status" raw) #f
          "Gateway door state — every string on it is a door state the identity face reads (see GatewayStatus); a diagnostic goes to the trace, never here.")
    (push "deviceUnlock" "reply: string" #f #f
          "The device key signed in on its own at connect — the unlock reply, or \"err:…\". Raised by day-boot.js off the unlockDevice handler.")
    (push "ingest" "snapshot: unknown" ("data" json) "snapshot"
          "A scope snapshot (the planner's day: commitments, intents, recipes, plan, inventory, credit, matter, fragility) — seam.data.snapshot holds it.")
    (push "contacts" "contacts: unknown" ("contacts" json) "contacts"
          "The contact book changed, or what stands between you and someone in it — seam.data.contacts holds each person with their kind, presence, recognition, both vouches and open ask.")
    (push "taxonomy" "taxonomy: unknown" ("taxonomy" json) "taxonomy"
          "The classification spine changed — seam.data.taxonomy holds it.")
    (push "grants" "grants: Grant[] | null" ("grants" json) "grants"
          "Your live socialization grants changed — seam.data.grants holds them.")
    (push "chatMessage" "topic: string, message: unknown" ("chatMessage" raw json) #f
          "A live chat message on a topic.")
    (push "connectAsk" "aid: string, name: string" ("connectAsk" raw raw) #f
          "Someone connected with you — their AID and the name they go by, so the page can offer to connect back.")
    (push "slotsChanged" "scope: string" ("slotsChanged" raw) #f
          "A scope's slot pool moved.")
    (push "scopes" "scopes: unknown" ("scopes" json) "scopes"
          "The roster of scopes you belong to changed — seam.data.scopes holds it.")
    (push "aid" "aid: string" ("aid" raw) "aid"
          "The spine's signed identity — THE \"who am I\" fact; seam.data.aid holds it.")
    (push "walkie" "state: string" ("walkieState" raw) #f
          "The live layer's whole state as one string — joined, joined-video, screen-on/off/denied, full, denied, left.")
    (push "screenEnded" "" #f #f
          "The browser's own \"stop sharing\" chrome ended the screen share. Raised by day-boot.js off the track's ended event.")
    ))

(define %handlers
  (list
    (handler "acceptInvite"
             "scope: string, vfId: string"
             "Promise<string>"
             ((session . accept-invite))
             "Accept a SOCIAL invite — accept-proposal, whitelist-checked. A different door from `commit` because a social invite is a proposal between people, not an assignment out of a solve.")
    (handler "acceptReimbursement"
             "commune: string, claimSaid: string"
             "Promise<unknown>"
             ((session . accept-reimbursement))
             "")
    (handler "acceptSocialization"
             "commune: string, grantSaid: string"
             "Promise<unknown>"
             ((session . accept-socialization))
             "The commune's own word accepting a grant or a reimbursement claim — no new signature, the caller's own session identity is the proof. Mints the reciprocal (a return commitment, or a debt) and wraps it with the primary in an Agreement (governance/scope.scm). Note the real, stated gap: no governor-role credential exists live anywhere in this system yet, so this is open to any authenticated member — only accepting one's OWN reimbursement claim is actually refused.")
    (handler "acceptWorkOffer"
             "scope: string, vfId: string"
             "Promise<string>"
             ((session . accept-work-offer))
             "Accept a DIRECTED WORK OFFER — accept-work-offer, the bounded rung's gated door, where the accepting worker is the PROVIDER. Its own door because an offer promotes a held column to a pin, not an assignment.")
    (handler "adoptCut"
             "...args: unknown[]"
             "Promise<unknown>"
             ((session . adopt-lens))
             "")
    (handler "ai"
             "system: string, user: string, model: string"
             "Promise<string>"
             ((session . ai-complete))
             "The AI seam, at the seat: the session answers `(ai-complete system-prompt user-prompt model)` within its per-minute budget, and \"\" past it or signed out. The third argument is the MODEL the orb passes from the pool's menu; the service runs an enclave (TEE/…) slug as named and anything else as its default.")
    (handler "allotment"
             ""
             "Promise<unknown>"
             ((session . allotment))
             "→ JSON {remaining, perWeek, opens, sees} | \"err:…\" — the week's unplanned photo reads: how many remain of how many, the epoch second the next week opens (Monday 00:00 UTC), and whether a picture can be read here at all (docs/observation/capture.md §5).")
    (handler "auditKinds"
             ""
             "Promise<unknown>"
             ((session . audit-kinds))
             "Stage 3 (truth-telling.md): audit the scope's ratified kinds against what the observer saw each citizen take; a padded row loses its grant. → JSON {examined, padded, findings[]}; `audits` reads the record.")
    (handler "audits"
             ""
             "Promise<unknown>"
             ((session . audits))
             "")
    (handler "cast"
             "proposalId: string, stance: string"
             "Promise<unknown>"
             ((session . stance-preimage) (session . cast-signed) (session . cast))
             "Cast a ballot: yes | no | abstain.")
    (handler "changePasscode"
             "current: string, next: string"
             "Promise<unknown>"
             ((lobby . fetch-icp) (lobby . witness-kel) (lobby . register-oobi-replies) (lobby . keri-challenge) (lobby . keri-authenticate))
             "Change the passcode: two rotations as one act hand the identity's keys from the current passcode's chain to the next one's, and the seat is taken again under the new key. Replies like unlock.")
    (handler "chat"
             "op: string, topic: string, text: string, kind?: string"
             "Promise<unknown>"
             ((session . chat-post) (planner . chat-watch) (planner . chat-history))
             "The room's chat: (\"post\", topic, text, kind) → an id, or \"err:…\". Used by the walkie's own transcriber to post what it heard.")
    (handler "claim"
             "resourceId: string, qty: number, where: string, when: string, reply: (r: unknown) => void"
             "void"
             ((session . claim))
             "Claim a claimable resource. The server prices it and answers through the callback rather than the promise — the reply carries the minted ACDC.")
    (handler "claimRegime"
             "scope: string, recipe: string, tails: string, process: string, until?: string"
             "Promise<unknown>"
             ((session . claim-regime))
             "As one of SCOPE's governors, claim the regime of RECIPE's domain: `tails` thin|fat|unknown, `process` stable|shifting|unknown; thin and stable together license statistics in that domain's standing (recipe-standing.md), anything else reads probability-free. `until` is an ISO date or absent for open-ended. Replies \"ok\" or \"err:…\" (a speaker who is no governor of the scope is refused).")
    (handler "close"
             "proposalId: string"
             "Promise<unknown>"
             ((session . close))
             "Close a proposal (governor only).")
    (handler "commit"
             "scope: string, vfId: string"
             "Promise<string>"
             ((session . accept-assignment))
             "Accept a work proposal — the planner's accept-assignment, acting as your AID. The refreshed snapshot brings it back as a commitment; the local flip at the call site is the optimistic echo of this.")
    (handler "contestWork"
             "scope: string, eventId: string, reason: string"
             "Promise<unknown>"
             ((session . contest-work))
             "Contest a recorded work event as one who says it did not happen: opens the ballot contest:<eventId> the scope settles at its close (cast void or stands through cast). → the ballot id, or \"err:…\".")
    (handler "corpusDomains"
             ""
             "Promise<unknown>"
             ((lobby . corpus-domains))
             "The domain slugs this gateway can search — {domains:[…]} JSON.")
    (handler "corpusSearch"
             "domain: string, query: string, limit: number"
             "Promise<unknown>"
             ((lobby . corpus-search))
             "Hybrid search (docs/planning/faces/corpus-guile-native.md phase 4) over a built corpus domain — DOMAIN a slug (\"permaculture\") for one domain, or \"\" to search every built domain and merge by fusion score (the federation corpus tab). → {hits:[{domain,text,heading,source,title, author,score}], error?} JSON.")
    (handler "declareMeans"
             "spec: string, qty: number, unit: string, where: string, arcs: string, note: string, emoji: string, name: string, cats: string, criteria?: string"
             "Promise<unknown>"
             ((session . declare-means))
             "")
    (handler "declareHosting"
             "scope: string, spec: string, ceiling: number | string, until?: string"
             "Promise<unknown>"
             ((session . declare-hosting))
             "As one of SCOPE's governors, declare the scope's willingness to host pools of SPEC up to CEILING unit-hours a day (the consent a foreign span into this scope's places needs, and the ceiling the means consensus binds); `until` is an ISO date or absent for open-ended. Replies \"ok\" or \"err:…\".")
    (handler "declareNeed"
             "spec: string, qty: number, unit: string, where: string, arcs: string, note: string, emoji: string, from: string, until: string, name?: string, cats?: string, criteria?: string, tension?: string, voice?: number"
             "Promise<unknown>"
             ((session . declare-need))
             "Declare (or re-declare) a need or a capacity. Both are deterministic-id UPSERTS keyed on the spec, which is what lets editing a card BE the write — there is no draft state on this side. `arcs` and `cats` ride as JSON. `name` and `cats` are the spine's variadic tail — lobby.scm declares (declare-need scope-id spec qty unit location arcs note emoji from until . opts) — so the log's digest can declare a need without classifying it.")
    (handler "declarePlace"
             "name: string, lat: number | string, lon: number | string, address?: string, parent?: string"
             "Promise<unknown>"
             ((session . declare-place))
             "A new place by name (+ optional lat/lon, optional address) → its id (a <spatial-thing> in the scope). `parent` is the id of the place it is inside — a room in a site, a shelf in a room — and the new place then stands at its parent's position when it states none.")
    (handler "countSchedule"
             "regime?: string"
             "Promise<unknown>"
             ((session . count-schedule))
             "→ JSON {rows: CountRow[]} | \"err:…\" — the schedule of counts: a row for each thing the inventory shows that sits in no other, soonest due first: {id, name, place, onhand, unit, lines, hours, interval (seconds), class (A|B|C), regime, lastCount, due, overdue} (docs/observation/capture.md §4).")
    (handler "passcodeCheck"
             "passcode: string"
             "Promise<unknown>"
             ()
             "\"ok\" when the passcode opens the identity in hand, read off the log this device holds; else the refusal.")
    (handler "planCounts"
             "regime?: string, counter?: string, atMost?: number"
             "Promise<unknown>"
             ((session . plan-counts))
             "→ JSON {laid: {proposal, target, counter, regime, hours}[], due: number, refused?: string} | \"err:…\" — lays the counts whose window is open as directed work offers through the offer loop (`refused` names why it stopped), each to the member whose turn it is or to `counter`; an offered count reaches its counter among their proposals and is accepted like any offered shift.")
    (handler "see"
             "images: string[], system: string, user: string, fulfills?: string"
             "Promise<string>"
             ((session . see) (session . see-part))
             "A picture, read at the seat: `images` are one to four base64 JPEGs of one thing, sent on in parts and joined at the gateway; `system` says what to look for and in what shape to answer, `user` what the sheet knows of the scene. A read that fulfils a planned count (`fulfills`) draws on the plan, any other spends one of the week's reads. Replies the model's text, \"\" when pictures cannot be read here, \"err:…\" in words the sheet can show. The pictures stay on the device; the gateway holds them only for the read.")
    (handler "scopeReplica"
             ""
             "Promise<string>"
             ((session . scope-replica))
             "→ the scope as this device holds a copy of it, one text (planner/scope/replica.scm), or \"\" where it could not be read — what the device's scope (scope-local.ts) seeds its copy from on taking a seat and after a flush, so the same doors answer with no gateway in reach.")
    (handler "countHistory"
             "resource: string, limit?: number"
             "Promise<unknown>"
             ((session . count-history))
             "→ JSON {rows: {id, at, delta, unit, counter, technique, evidence, mine}[]} | \"err:…\" — the counts of a stock, newest first, as a member reads them to contest one: `delta` is signed as the adjustment landed, `evidence` the hash of the picture the count names (\"\" when none), `mine` whether the caller counted it.")
    (handler "contests"
             ""
             "Promise<unknown>"
             ((session . contests))
             "→ JSON {rows: {id, eventId, kind, resource, worker, by, reason, role}[]} | \"err:…\" — the contests open in the scope as they stand to the caller: `kind` work or count, `resource` the stock a count is of (empty for work), `role` attach when the act is the caller's own (a count's counter attaches the picture), vote when the caller is in the franchise, none otherwise.")
    (handler "attachEvidence"
             "ballot: string, hash: string, picture: string"
             "Promise<unknown>"
             ((session . evidence-part))
             "Attach the counter's picture (its base64) to the contest of their count, sent on in parts and joined at the gateway, which holds it until the ballot settles. → \"ok\" | \"err:…\".")
    (handler "contestEvidence"
             "ballot: string"
             "Promise<string>"
             ((session . evidence-chunk))
             "The picture held for a contest, as base64 joined from its parts, for the counter and the franchise; \"\" when none is held.")
    (handler "labelStock"
             "resource: string"
             "Promise<unknown>"
             ((session . label-stock))
             "→ JSON {code, id, name, minted} | \"err:…\" — the code a stock is known by, for its label: six characters, unique in the scope, silent about owner and contents; the same on every asking (`minted` is true when this asking gave it) (docs/observation/capture.md §6).")
    (handler "readLabel"
             "code: string"
             "Promise<unknown>"
             ((session . read-label))
             "→ JSON {resource: InventoryResource, contents: InventoryResource[]} | \"err:…\" — what a scanned or typed label names: the thing, where it is, and what is in it.")
    (handler "declareSpan"
             "scope: string, resourceId: string, place: string, until?: string"
             "Promise<unknown>"
             ((session . declare-span))
             "As one of SCOPE's governors, declare that RESOURCE-ID's service pool stands at PLACE (a span declaration; a solve reads it through the consent gate, so a foreign place needs the host's hosting willingness); `until` is an ISO date or absent for open-ended. Replies \"ok\" or \"err:…\".")
    (handler "declareSkill"
             "spec: string"
             "Promise<unknown>"
             ((session . declare-skill))
             "The citizen's own skills: declare/revoke ride the session AID (self-only), VF raise/lower over a skill EconomicResource on the server. The scope's labour fold refolds on the write — the roster the UC matches over moves with the dial. mySkills answers the held spec-ids, one per line; mySkillStanding what the record shows for each.")
    (handler "decline"
             "scope: string, vfId: string"
             "Promise<string>"
             ((session . decline-assignment))
             "Decline, or release an accepted one: decline-assignment either way. The planner clears the binding and re-matches, which is what makes a commitment reversible rather than a one-way door.")
    (handler "deviceKeyHere"
             ""
             "boolean"
             ()
             "Whether this browser holds a device key (JS shell; synchronous).")
    (handler "deviceForget"
             ""
             "Promise<void>"
             ()
             "wipe the key from this browser (the gateway's revocation is revokeDevice's)")
    (handler "devices"
             ""
             "Promise<unknown>"
             ((session . my-devices))
             "JSON array of the devices the root authorized, with revocation marks")
    (handler "deviceTiers"
             "): Promise<{ hardware: boolean; software: boolean }>; /** whether a device key is recorded in this browser */ deviceKeyHere?("
             "boolean"
             ()
             "what this browser can hold")
    (handler "dropEvent"
             "action: string, point: string, spec?: string, qty?: number, unit?: string, resource?: string, mine?: string"
             "Promise<unknown>"
             ((planner . drop-event))
             "Record a drop or a take at a drop point.")
    (handler "enrollExternalDevice"
             "deviceAid: string, label: string, doors: string"
             "Promise<unknown>"
             ((session . enroll-device))
             "Authorize an OUTSIDE interface as a device of this person: its own B-prefixed AID, a label, and the door names it may call, comma-separated (\"\" = every device door). Root tier only.")
    (handler "enrollDevice"
             "label: string, tier: string"
             "Promise<unknown>"
             ((session . enroll-device))
             "make this device's key at tier (\"hardware\" | \"software\") and have the root (a passcode session) authorize it; replies \"ok\"")
    (handler "externalityHistory"
             "...args: unknown[]"
             "Promise<unknown>"
             ((session . externality-history))
             "")
    (handler "familyBills"
             "needsJson: string, purse: number, labourH: number, weighted: boolean, eurPerHour: number, membersJson: string, perCitizenHours: number, reply: (r: unknown) => void"
             "void"
             ((session . family-bills))
             "The same week asked backwards: euros and hours beyond the purse for rights, then needs, then wants held as walls; a euro priced at 1/eurPerHour hours. Same MEMBERS-JSON as familySplit.")
    (handler "familySplit"
             "needsJson: string, purse: number, labourH: number, weighted: boolean, membersJson: string, perCitizenHours: number, reply: (r: unknown) => void"
             "void"
             ((session . family-split))
             "The family face: split PURSE across NEEDS (JSON rows) by harmony; MEMBERS-JSON is the household's own consumer voice (playnet.typ §The credit identity) — {person,capacity,hours} rows, \"[]\" reads every owner as an equal citizen; reply is the solve's rows or \"err:…\".")
    (handler "forgetMe"
             "passcode: string, retire: string"
             "Promise<unknown>"
             ((lobby . fetch-icp) (lobby . witness-kel) (session . forget-me))
             "Forget me: the commune erases every record of its own keyed by this identity, the link between identity and person last (identity/forget.scm); with RETIRE \"retire\", a terminal rotation goes first — no next key — closing the log for good: no rotation, no recovery, no new key can take the identity over (the key it reveals stays the passcode's). Replies the receipt as JSON ({dropped:{member,bindings,…},kept:[…]}), or \"err:…\". The page then forgets what this device held.")
    (handler "fpEnroll"
             ""
             "Promise<unknown>"
             ((session . fp-request-enroll))
             "Ask to be recognised: opens (or finds) your enrollment ceremony — the durable ask every verified member sees on their witness rail.")
    (handler "fpGrant"
             "aid: string"
             "Promise<unknown>"
             ((session . fp-grant))
             "The GENESIS act: a founder recognises the first person of an ecosystem that has none yet. Refused once anyone is recognised.")
    (handler "fpMyCeremony"
             ""
             "Promise<unknown>"
             ((session . fp-my-ceremony))
             "JSON: your own ask, read from the ceremony — {state: \"none\" | \"collecting\" | \"finalized\", count, quorum, witnesses, vouchers}.")
    (handler "fpMyPhc"
             ""
             "Promise<unknown>"
             ((session . my-phc))
             "Our own personhood credential, to carry to the next gateway.")
    (handler "fpMyVouches"
             ""
             "Promise<unknown>"
             ((session . my-vouches))
             "The bundle you carry between gateways: your personhood, the vouches for and by you, each voucher's personhood, and the key logs a foreign gateway needs to check them. One JSON string; \"\" when nothing yet.")
    (handler "fpOpenCeremony"
             "aid: string"
             "Promise<unknown>"
             ((session . fp-open-ceremony))
             "Introduce a newcomer: open their enrollment ceremony with you as sponsor. The quorum is the ecosystem's (personhood-policy), never an argument; the ask lands on every witness rail and each vouch is a witness's own signature; at quorum the credential issues carrying one edge per witness.")
    (handler "fpPending"
             ""
             "Promise<unknown>"
             ((session . fp-pending))
             "JSON: the standing asks — [{said, candidate, sponsor, count, quorum, vouchers}].")
    (handler "fpPresent"
             "card: string"
             "Promise<unknown>"
             ((session . present-phc))
             "Present a PHC earned elsewhere; the gateway verifies issuer and federation.")
    (handler "fpPresentBundle"
             "json: string"
             "Promise<unknown>"
             ((session . present-bundle))
             "Present a carried bundle here — verified in dependency order, imported only when every card stands. \"ok:<newly imported>\" | \"err:…\".")
    (handler "fpStatus"
             ""
             "Promise<unknown>"
             ((session . fp-status))
             "JSON: whether this commune recognises you as a person, and what the sheet may offer — {person, scope, governor, bootstrapped, verified}.")
    (handler "fpVouch"
             "aid: string, rel: string"
             "Promise<unknown>"
             ((session . fp-vouch-preimage) (session . fp-vouch-signed) (session . fp-vouch))
             "Vouch for someone as a kind (friend, family, …) in your own signature; a new vouch ends your earlier one for them. \"ok\" | \"err:…\".")
    (handler "fpWithdrawVouch"
             "aid: string"
             "Promise<unknown>"
             ((session . fp-withdraw-vouch))
             "End your standing vouch for someone. \"ok\" | \"err:…\".")
    (handler "getResult"
             "proposalId: string"
             "Promise<unknown>"
             ((session . get-result))
             "One proposal's tally and outcome, as JSON.")
    (handler "guardianRecover"
             "linesJson: string"
             "Promise<unknown>"
             ()
             "k lines back in → \"ok:<aid>|<passcode>\"")
    (handler "guardianSplit"
             "k: string, n: string"
             "Promise<unknown>"
             ()
             "split the passcode k-of-n; replies a JSON array of carryable lines")
    (handler "invite"
             "aid: string, label: string, from: string, until: string"
             "Promise<unknown>"
             ((session . invite-contact) (lobby . signal))
             "")
    (handler "join"
             "name: string, email: string"
             "Promise<unknown>"
             ((lobby . join) (lobby . register-oobi-replies))
             "the log in hand takes a seat at a commune that has never seen it")
    (handler "journey"
             "phase: string, from: string, to: string, mode: string, cid: string"
             "Promise<string>"
             ((session . journey-end) (session . journey-begin))
             "A real trip, both ends: phase \"begin\" mints the journey commitment and its pickup event (reply \"ok:<cid>\"); phase \"end\" records the dropoff fulfilling CID. The routing table learns from this very walk.")
    (handler "kelExport"
             ""
             "Promise<unknown>"
             ()
             "this identity's KEL as ordered JSON (\"\" when none) — the recovery file carries it")
    (handler "kelImport"
             "json: string"
             "Promise<unknown>"
             ()
             "a KEL from a recovery file becomes this device's log; replies ok:<aid>|<k0>")
    (handler "listDelegations"
             ""
             "Promise<unknown>"
             ((session . list-delegations))
             "Your outgoing delegations, as JSON.")
    (handler "lintRecords"
             "scope: string, records: string"
             "Promise<string>"
             ((planner . lint-records))
             "The ValueFlows lint over RECORDS (a JSON array) against SCOPE's specs and units — the findings as a JSON array, or \"err:…\". The log and share-bar passes read it inside their conform check, so a model hears what the planner would refuse.")
    (handler "listProposals"
             ""
             "Promise<unknown>"
             ((session . list-proposals))
             "The scope's open proposals, as JSON.")
    (handler "listUcProposals"
             ""
             "Promise<unknown>"
             ((session . list-uc-proposals))
             "The universal commune's proposals, as JSON.")
    (handler "log"
             "op: string, payload: string"
             "Promise<string>"
             ((session . sync-log) (session . list-log))
             "The captain's log's own backup: (\"sync\"|\"list\", payload) → JSON.")
    (handler "logObserve"
             "...args: unknown[]"
             "Promise<unknown>"
             ((session . log-observe))
             "Promote a lived day to a ledger fact.")
    (handler "countStock"
             "resource: string, counted: number, unit?: string, technique?: string, place?: string, whenIso?: string, fulfills?: string, evidence?: string, note?: string"
             "Promise<unknown>"
             ((session . count-stock))
             "→ JSON {event, record, delta, onhand} | \"err:…\" — a count of a stock the books hold: a count that finds the ledger off lands a raise or lower of the difference on that stock, one that agrees lands none (`event` is then \"\"). `technique` is stated, label or photo; `place` a place id, by default the stock's own; `fulfills` the counter's commitment of a planned count, whose `record` lands as a produce; `evidence` the hash of the picture, which stays on the device (docs/observation/capture.md).")
    (handler "matchSlots"
             ""
             "Promise<unknown>"
             ((session . match-slots) (lobby . who))
             "The scope's needs and offers, scored against each other, as JSON.")
    (handler "myPayouts"
             ""
             "Promise<unknown>"
             ((session . my-payouts))
             "→ JSON {available: number, payouts: Payout[], owed: Debt[]} — `owed` is every open debt the commons carries to you for a purchase you fronted and it has accepted (governance/debts.scm).")
    (handler "scopeReadings"
             "spec: string"
             "Promise<unknown>"
             ((session . scope-readings))
             "→ JSON {rows: ReadingRow[], drift: {n, meanAbs, net}, latest} — what every source says of SPEC at this scope: one row per technique, act and source with its count, sum, extrema and freshest reading; the drift between counts and the ledger. The inventory face's counts line (docs/observation/readings-are-counts.md).")
    (handler "readingsBetween"
             "spec: string, from: string, until: string"
             "Promise<unknown>"
             ((session . readings-between))
             "→ JSON {rows: ReadingRow[], fold: ReadingRow[]} — what every source reported of SPEC at this scope between FROM and UNTIL (ISO-8601; an empty string leaves an end open): one row per reading in time order, n = 1 each, and those rows folded. The inventory face's history line (docs/observation/ngsi-ld.md).")
    (handler "myClaims"
             ""
             "Promise<unknown>"
             ((session . my-claims))
             "→ JSON {rows: ClaimRow[]} — your order book: each want asked (no row yet), held (the plan's claim commitment, with what remains) or taken.")
    (handler "mySkills"
             ""
             "Promise<string>"
             ((session . my-skills))
             "")
    (handler "mySkillStanding"
             ""
             "Promise<string>"
             ((session . my-skill-standing))
             "→ JSON [{skill, held, hours, competence, events, witnessed, attesters, witnessedHours, pending: [{count, quorum}]}] — each skill you hold or have practiced, and what the record shows for it, in hours: `hours` is recipient-validated work (the credit ledger's own gate), `competence` where the skill stands today under its own law (idle time wears it, satisfied practice renews it), `attesters` the distinct people who co-signed the work.")
    (handler "mySlots"
             ""
             "Promise<unknown>"
             ((session . my-slots))
             "Your own slots, both rails, as JSON.")
    (handler "myVoice"
             ""
             "Promise<unknown>"
             ((session . my-voice))
             "Your own voice weights, as JSON.")
    (handler "openProposal"
             "kind: string, domain: string, id: string, text: string, franchise: string, subject?: string"
             "Promise<unknown>"
             ((session . open))
             "Open a proposal: (kind, domain, id, text, franchise, subject) — franchise \"federation\" | \"scope:<sid>\"; subject \"kind:id\" or \"\" names what it is about.")
    (handler "ourSlots"
             ""
             "Promise<unknown>"
             ((session . our-slots))
             "The fold's reading at the scope you stand in — Our Needs / Our Offers as summed cells (spec · place · window → qty), each carrying `mine`, your own share of the sum. No one else's name travels.")
    (handler "pins"
             "op: string, payload: string"
             "Promise<string>"
             ((session . sync-pins) (session . our-pin-lists) (session . our-pins) (session . list-pins))
             "The pin book (map lists): \"sync\" json → \"ok\"; \"list\" → json; \"ourLists\" → json; \"ourPins\" id → json.")
    (handler "needDisplacement"
             "spec: string, qty: number"
             "Promise<unknown>"
             ((session . need-displacement))
             "The declaration-time read: what one unit of SPEC currently displaces elsewhere in the plan, off the scope's last solve — shown in the ⚖️ editor before a kind and level are stated. Answers JSON {read, perUnit, moved}; {read:false} when no solve has run yet.")
    (handler "profileGet"
             ""
             "Promise<unknown>"
             ((session . profile))
             "")
    (handler "profileSet"
             "name: string, email: string"
             "Promise<unknown>"
             ((session . update-profile))
             "")
    (handler "publishSpine"
             "wire: string"
             "Promise<unknown>"
             ((session . sync-taxonomy))
             "Publish the dial's own spine back to the commons — the TWEAK arm of the folksonomy loop. Takes the tree as tab-separated T (term) and E (edge) lines, which is the format the aggregator reads.")
    (handler "purchaseClaim"
             "commune: string, spec: string, qty: number | string, unit?: string, due?: string, resource?: string, ref?: string, trig?: string"
             "Promise<unknown>"
             ((session . purchase-claim-preimage) (session . purchase-claim-signed))
             "\"I gave the commons this\" — the reimbursement trigger, client-signed exactly like `socialize` above (the browser signs, the key never leaves the client). Replies the claim's own SAID (a string, not \"ok\") — whoever calls `acceptReimbursement` needs it. `resource` optionally names WHICH balance/purse actually paid (VF resourceInventoriedAs): a named resource under a live consume-grant to the commune is refused at acceptance (socialized money owes nothing back); an ungranted one clears the coarse flag. `ref` (a receipt reference, or any nonce) uniquifies the claim, so two same-shaped purchases are two claims rather than one deduped SAID. `trig` is the purchase EVENT's id — `recordPurchase` replies it — and rides the claim as VF Claim.triggeredBy, tying the signed word to the recorded raise it speaks about.")
    (handler "ratifiedKinds"
             ""
             "Promise<unknown>"
             ((session . ratified-kinds))
             "")
    (handler "ratifyKind"
             "spec: string, kind: string"
             "Promise<unknown>"
             ((session . ratify-kind))
             "The constitution's gate (truth-telling.md stage 1): a kind beyond a want — \"held\", \"floor\" — is the scope's statement. `ratifyKind` records the scope ratifying SPEC as KIND under this citizen's AID (\"des\" withdraws); `ratifiedKinds` answers the grants as JSON [{spec, kind, by, at}].")
    (handler "recall"
             "said: string"
             "Promise<unknown>"
             ((session . desocialize))
             "End a grant early, by its custody attestation's SAID.")
    (handler "reconnect"
             "...args: unknown[]"
             "Promise<unknown>"
             ()
             "")
    (handler "recordEffort"
             "scope: string, cid: string, qty: string, unit: string"
             "Promise<string>"
             ((session . record-effort))
             "The confirmation mile, work half: record QTY of a committed block's effort as a work event FULFILLING it — partials accumulate in its FulfillmentState. Replies \"ok:<event-id>\".")
    (handler "recordFlow"
             "scope: string, action: string, spec: string, qty: string, total: string, place: string, when: string, proc: string, note: string, rowId?: string"
             "Promise<string>"
             ((planner . record-flow))
             "The confirmation mile, material half: record QTY of one schedule row's produce/consume/pickup/dropoff/use, the row named by its ROWID (the id the schedule carries; the spec is the spec's id, never its label). Each plan row is a commitment under its own id, so partials accumulate and a finished row answers `already` instead of double-moving stock.")
    (handler "recordPurchase"
             "spec: string, qty: number, unit: string, moneySpec: string, cost: number, where?: string, note?: string, receipt?: string, donation?: boolean"
             "Promise<unknown>"
             ((session . record-purchase))
             "\"I bought this for the commons\": the good is raised into the commons with the receipt on the event, and the raise binds to the plan's own records (fulfills a live produce commitment, satisfies an open declared need) when they exist. What you advanced becomes a debt the commons owes you once the commune accepts it (governance accept-reimbursement) — read back via myPayouts' `owed`, paid as a payout. `donation` records the raise and owes nothing. Replies the purchase EVENT's id (\"err:…\" on failure) — pass it to `purchaseClaim` as `trig`.")
    (handler "requestPayout"
             "address: string, xmr: number, due?: string, note?: string"
             "Promise<unknown>"
             ((session . request-payout))
             "Payouts — \"send N XMR of my claim to ⟨address⟩\". A member's monero is a claim on the commons' wallet (the shop's claim of spec-xmr); a payout is their standing intent to have some of it sent on-chain. The gateway's runner moves it under the wallet policy and settles it as a VF transfer out of the claim; no member key exists. `due` \"\" = as soon as possible.")
    (handler "retireMeans"
             "spec: string"
             "Promise<unknown>"
             ((session . retire-means))
             "Withdraw a declared means: a `lower` to zero — the record and its event history stand, only the offer leaves the qty>0 readers.")
    (handler "retireNeed"
             "spec: string"
             "Promise<unknown>"
             ((session . retire-need))
             "Withdraw a need. Capacities are withdrawn by recall, not by this.")
    (handler "retirePayout"
             "id: string"
             "Promise<unknown>"
             ((session . retire-payout))
             "")
    (handler "revokeDelegation"
             "delegateAid: string"
             "Promise<unknown>"
             ((session . revoke-delegation))
             "Take a delegation back: \"ok\" or \"err:…\".")
    (handler "revokeDevice"
             "said: string"
             "Promise<unknown>"
             ((session . revoke-device))
             "retire one device by its authorization's SAID")
    (handler "revokeSkill"
             "spec: string"
             "Promise<unknown>"
             ((session . revoke-skill))
             "")
    (handler "setAvailability"
             "windowsJson: string"
             "Promise<unknown> | void"
             ((session . set-availability-ranges))
             "Push NET availability: the windows you are free, minus the time committed events take, as JSON. Sent whole rather than as a diff — the planner's picture of your week is replaced, not patched.")
    (handler "setContactRel"
             "aid: string, rel: string"
             "void"
             ((session . list-contacts) (session . sync-contacts))
             "Tag the kind you know someone as — your own label in the book. Fire-and-forget: the list repaints locally. A vouch is its own act (fpVouch).")
    (handler "contactCheck"
             "aid: string"
             "Promise<unknown>"
             ((lobby . fetch-icp))
             "Whether this commune holds a verified key log for someone: \"ok:checked\" | \"ok:unchecked\" | \"err:…\".")
    (handler "contactConnect"
             "aid: string, alias: string, oobi: string, myName: string"
             "Promise<unknown>"
             ((lobby . fetch-icp) (session . list-contacts) (session . sync-contacts) (lobby . signal))
             "Add someone to your contact book under ALIAS, noting where their link came from (OOBI) and whether this commune holds their key log; they are told, under MYNAME, so they can connect back. \"ok:checked\" | \"ok:unchecked\" | \"err:…\".")
    (handler "reachPresent"
             "kind: string, value: string"
             "Promise<unknown>"
             ((session . present-contact-point))
             "Tell this commune one way to reach you: a contact-point credential built and signed here. The commune sends a code to the address itself. \"ok:pending\" | \"err:…\".")
    (handler "reachConfirm"
             "kind: string, value: string, code: string"
             "Promise<unknown>"
             ((session . confirm-contact-point))
             "Say back the code the commune sent to the address; it then delivers there. \"ok\" | \"err:…\".")
    (handler "reachWithdraw"
             "kind: string, value: string"
             "Promise<unknown>"
             ((session . withdraw-contact-point))
             "Take a contact point back from this commune; it is erased there. \"ok\" | \"err:…\".")
    (handler "reachRead"
             ""
             "Promise<unknown>"
             ((session . my-contact-points))
             "JSON {delivers: string[], points: {kind, value, state}[]}: the kinds this commune delivers on, and which of your contact points it holds (state bound or pending).")
    (handler "bodyDeclare"
             "scopeId: string, body: string"
             "Promise<unknown>"
             ((session . declare-body))
             "Declare a legal body in a scope: BODY is JSON {name, kind, role, jurisdiction, assetLock, register}; you are its first steward. \"ok:\" + JSON {id, name, tags} | \"err:…\".")
    (handler "bodyAddSteward"
             "body: string, aid: string"
             "Promise<unknown>"
             ((session . body-add-steward))
             "Name a person a steward of a body you steward. \"ok\" | \"err:…\".")
    (handler "bodyOpenCeremony"
             "body: string, k: number"
             "Promise<unknown>"
             ((session . body-open-ceremony))
             "Open the body's inception: K of its stewards must sign. \"ok:\" + JSON {have, need, published, what} | \"err:…\".")
    (handler "bodySign"
             "body: string, what: string"
             "Promise<unknown>"
             ((session . body-sign-preimage) (session . body-sign-signed))
             "Sign the body's open statement (WHAT: inception, rotation or role) here, with your own key, and hand the signature to the ceremony; at k it publishes. \"ok:\" + JSON {have, need, published} | \"err:…\".")
    (handler "bodyRead"
             "body: string"
             "Promise<unknown>"
             ((session . body))
             "One body whole, as JSON {id, name, tags, stewards, members, crossings, holdings, findings, exposure, ceremony} | \"err:…\".")
    (handler "bodiesRead"
             "scopeId: string"
             "Promise<unknown>"
             ((session . my-bodies))
             "The bodies you steward or belong to, as JSON [{id, name, tags, steward, ceremony}] | \"err:…\".")
    (handler "bodyHold"
             "body: string, holding: string"
             "Promise<unknown>"
             ((session . body-present-holding))
             "Present what a body you steward holds: HOLDING is JSON {kind, name, issuer, validUntil, ref}. \"ok:\" + resource id | \"err:…\".")
    (handler "bodyAdmit"
             "scopeId: string, body: string"
             "Promise<unknown>"
             ((session . body-admit))
             "Admit a body to a scope (a governor's act); the admission tests come back as JSON findings | \"err:…\".")
    (handler "pushKey"
             ""
             "Promise<unknown>"
             ((lobby . vapid-public-key))
             "The commune's Web Push key (VAPID public key, base64url), which a browser subscribes with; \"\" when the commune sends no push.")
    (handler "pushRegister"
             "deviceId: string, subscription: string"
             "Promise<unknown>"
             ((session . register-push))
             "Tell this commune the browser's push subscription (its JSON) for this device; it then notifies this device. \"ok\" | \"err:…\".")
    (handler "pushUnregister"
             "deviceId: string"
             "Promise<unknown>"
             ((session . unregister-push))
             "Take this device's push subscription back from this commune. \"ok\" | \"err:…\".")
    (handler "cardGive"
             "aid: string, content: string"
             "Promise<unknown>"
             ((lobby . fetch-icp) (session . give-card) (lobby . signal))
             "Give a contact your card: CONTENT (JSON text) is sealed to their own key and signed by you, in place of any earlier card to them. \"ok\" | \"err:…\".")
    (handler "cardWithdraw"
             "aid: string"
             "Promise<unknown>"
             ((session . withdraw-card) (lobby . signal))
             "Take your card back from a contact; it is erased at the commune. \"ok\" | \"err:…\".")
    (handler "contactForget"
             "aid: string"
             "Promise<unknown>"
             ((session . list-contacts) (session . sync-contacts))
             "Take someone out of your contact book. \"ok\" | \"err:…\". A standing vouch stays until withdrawn (fpWithdrawVouch).")
    (handler "contactsRefresh"
             ""
             "Promise<unknown>"
             ((session . list-contacts) (session . relationships) (session . cards) (lobby . online-users))
             "Read the book again with what stands between you and each person; the answer arrives as the contacts push.")
    (handler "setDelegation"
             "delegateAid: string, fraction: number"
             "Promise<unknown>"
             ((session . set-delegation))
             "Hand a fraction (0..1) of your voice to a delegate: \"ok\" or \"err:…\".")
    (handler "setPosition"
             "period: number, place: string"
             "Promise<unknown>"
             ((session . set-position))
             "Set (or clear) the position for a period, by place id.")
    (handler "setPositionHere"
             "period: number, lat: number, lng: number"
             "Promise<unknown>"
             ((session . set-position-latlon))
             "Tell the spine where you are; it replies with the place it snapped to.")
    (handler "setLocationSharing"
             "mode: string"
             "Promise<unknown>"
             ((session . set-location-sharing))
             "Declare whether you share where you are: \"live\", \"here\" or \"off\", kept once at your home so every device reads the same; off ends the fix that stands; replies the mode or \"err:…\".")
    (handler "locationSharing"
             ""
             "Promise<unknown>"
             ((session . location-sharing))
             "Read the mode you declared for sharing where you are: \"live\", \"here\", \"off\" or \"undeclared\".")
    (handler "setHome"
             "place: string, lat: number, lng: number"
             "Promise<unknown>"
             ((session . set-home))
             "Register your home, the place the plan falls back to: a known place id, or \"\" with coordinates for your own place; replies its id or \"err:…\".")
    (handler "declareDwelling"
             "place: string, areaM2: number, rooms: number, warmthWinterDegC: number, warmthSummerDegC: number, beds: number, attestsJson: string, certified: boolean, rentEurNight: number, tenure: string"
             "Promise<unknown>"
             ((session . declare-dwelling))
             "Declare the dwelling you live in — at PLACE, or \"\" for your registered home — as the housing closure reads it: type, the beds it houses, the gates it attests, whether certified, its own rent per night, tenure; replies its resource id or \"err:…\".")
    (handler "setProfile"
             "tagsJson: string, reply: (r: unknown) => void"
             "void"
             ((session . set-profile))
             "Who you are, for the floors and the diet: a JSON array of typed tags written onto your own agent record; reply \"ok\" or \"err:…\".")
    (handler "setGateway"
             "sref: string"
             "Promise<unknown>"
             ()
             "Point this page at a gateway by its sturdyref and connect; the same sref re-connects the door already open. Local to the browser: no server door.")
    (handler "setScope"
             "scope: string | null"
             "void"
             ()
             "Switch the commune the whole UI reads. Null is earth: the whole commons.")
    (handler "signup"
             "name: string, email: string, passcode: string"
             "Promise<unknown>"
             ((lobby . signup-with-icp) (lobby . register-oobi-replies))
             "Create an AID from a passcode. The two empty strings are name and email.")
    (handler "slotsAt"
             ""
             "Promise<unknown>"
             ((session . slots-at) (lobby . who))
             "The scope's pooled slots at a place, as a JSON string.")
    (handler "socialize"
             "commune: string, spec?: string, qty?: number | string, until?: string, movable?: boolean, returnTo?: string, condition?: string, resource?: string, kind?: GrantKind, ref?: string, eligible?: string"
             "Promise<unknown>"
             ((session . socialize-preimage) (session . socialize-signed))
             "Commons a private resource into a commune's use-pool: custody moves, rights stay. Argument order is the spine's own — lobby.scm's socialize-preimage takes (commune-aid spec qty UNTIL movable rt cf res kind). The fourth is the end of the grant's span, not a unit; both callers pass a date or \"\" there. `kind` is the grant's verb: \"use\" lends the thing's service and it comes back whole (absent = use); \"consume\" lends a QUANTITY to spend — a purse of EUR, a tank of fuel — and what is unspent at the window's close is yours. `ref` (any nonce; the bridge fills a timestamp when absent) uniquifies the grant's SAID — recall-then-relend with identical terms used to collide with the revoked credential and die silently. There is deliberately no loan/repay option here: a private bilateral repayment primitive was built and removed (project_consume_grant_money memory has the reasoning) — anyone who wants value from the commons works for it, there is no lending path between that and a gift. qty is `number | string` because the lend editor holds what was TYPED until the grant is signed (GrantTerms.qty), and hands that straight on. `eligible` is the owner's STEWARD RULE: the same criteria JSON a slot's 🔒 section writes (\"\" = anyone) — its filter-rule bounds who may be assigned to work drawing on the grant; the solve itself stays anonymous.")
    (handler "solve"
             ""
             "Promise<string>"
             ((planner . solve-brief))
             "The EXACT current plan, as a wire-safe summary. The orb feeds it as ground truth so a planning claim is computed rather than guessed over the snapshot; the string starts \"err:\" when the planner could not answer.")
    (handler "taxonomyLens"
             "lens: \"social\" | \"individual\""
             "void"
             ((session . folksonomy-template))
             "Swing the folksonomy LENS: \"social\" reads the commons' own aggregated cut of the classification spine, \"individual\" reads yours. The σ toggle drives it, because which spine you are looking at and whose day you are looking at are the same question asked twice.")
    (handler "tier"
             ""
             "Promise<unknown>"
             ()
             "\"root\" | \"device\" | \"\" — how this session proved the AID")
    (handler "transcribe"
             "wavBase64: string"
             "Promise<string>"
             ((session . transcribe))
             "The gateway's whisper, at the seat: base64 WAV → transcript, \"\" signed out or past the session's budget. The browser transcribes on-device first and asks this for what the device could not.")
    (handler "unlock"
             "passcode: string, aid: string, k0: string"
             "Promise<unknown>"
             ((lobby . fetch-icp) (lobby . find-icp))
             "Unlock an existing AID on this device. k0 is the remembered first key. An empty aid opens the identity the passcode itself names: the log held here, or the one the commune holds under the passcode's first key.")
    (handler "unlockDevice"
             ""
             "Promise<unknown>"
             ((lobby . keri-challenge) (lobby . keri-authenticate-device) (lobby . has-seat))
             "sign in with the device key held here; replies like unlock")
    (handler "voiceIn"
             "scopeId: string"
             "Promise<unknown>"
             ((session . voice-in))
             "Your producer voice in one commune, as JSON {producer}.")
    (handler "wake"
             ""
             "Promise<unknown>"
             ((lobby . live-rooms) (planner . chat-last))
             "The federation's live rooms, as a JSON array string.")
    (handler "walkie"
             "op: string, arg?: string"
             "void"
             ()
             "The live audio/video layer: join, joinvideo, leave, and the toggles (talk/cam/screen) whose second argument is \"on\" or \"off\".")
    (handler "willing"
             "scope: string, spec: string, cell: string, on: boolean"
             "Promise<string>"
             ((session . express-willingness) (planner . materialize-willing))
             "Raise or lower your hand for work: (scope, skill, catchment cell, on). Willingness is over the (skill, cell) PAIR rather than over a particular work-intent — the solver matches across everyone who offered, which is what makes it over-subscribable and not a claim on the slot.")
    (handler "witnessAttest"
             "said: string"
             "Promise<string>"
             ((session . witness-attest))
             "")
    (handler "witnessInbox"
             ""
             "Promise<string>"
             ((session . witness-inbox))
             "")
    (handler "witnessOpen"
             "scope: string, eventId: string"
             "Promise<string>"
             ((session . witness-open))
             "The k-of-n witness ceremony over a peer's work. \"Witness\" here means VOUCHER — a human co-signing that work happened, with the key that never leaves this browser's vault; KERI's own witnesses (the KEL receipt pool, docs/keri/) are unrelated backend infrastructure and everything else about this ceremony — quorum, verification, credential strengthening — runs server-side. OPEN asks peers to witness a lived work event (\"ok:<said>\"); INBOX is a JSON array of {said, worker, skill, hours, count, quorum} rows you may co-sign; ATTEST signs the statement with your own key and lands it (\"ok:attested\" | \"ok:finalized\" — at quorum the credential strengthens in place to its multisig form).")
    ))
