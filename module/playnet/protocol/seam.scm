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
;;;             scope, WebRTC). A handler whose reply is a door's table says so
;;;             in place of its return type, `(reply door)`: the type is then
;;;             the registry's (wire/rows.scm reply-table, ui/app/wire-rows.ts),
;;;             `Promise<Json<W.Wire…Reply>>` — the JSON string of that table's
;;;             row, which the page reads with `readJson` — and protocol-lint
;;;             holds the door to the handler's doors and to the registry.
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
  #:export (%handlers handler-ref handler? handler-name handler-params handler-arity handler-param-list handler-param-name
            handler-returns handler-reply handler-doors handler-doc handler-local?
            %pushes push-ref push? push-name push-params push-sink push-wire
            push-keep push-doc
            %sink-plumbing %sinks-forwarded))

(define-record-type <handler>
  (make-handler name params returns reply doors doc)
  handler?
  (name    handler-name)      ; the seam.handlers key
  (params  handler-params)    ; TypeScript parameter list, as text
  (returns handler-returns)   ; TypeScript return type, as text, or #f where REPLY says it
  (reply   handler-reply)     ; the door whose reply table types the handler's answer, or #f
  (doors   handler-doors)     ; ((object . name) …), in send order
  (doc     handler-doc))

;; (handler NAME PARAMS RETURNS DOORS DOC) — all data; RETURNS is the
;; TypeScript return type as text, or (reply DOOR) for a door's table.
(define-syntax handler
  (syntax-rules (reply)
    ((_ name params (reply door) doors doc)
     (make-handler name params #f 'door 'doors doc))
    ((_ name params returns doors doc)
     (make-handler name params returns #f 'doors doc))))

;; A handler's parameters, one string each: the parameter list cut at its top-level commas.
;; The page's bridge pads and cuts to how many there are (tools/lint/check-bridge-arity.scm),
;; a keyed door's key is the last of them (tools/emit/keyed-emit.scm), and an offline act's
;; instant is the one its door names (tools/emit/offline-emit.scm).
(define (handler-param-list h)
  (let ((params (handler-params h)))
    (if (string=? params "") '()
        (let loop ((i 0) (depth 0) (start 0) (acc '()))
          (if (= i (string-length params))
              (reverse (cons (string-trim (substring params start)) acc))
              (let ((c (string-ref params i)))
                (cond ((memv c '(#\( #\[ #\{ #\<)) (loop (+ i 1) (+ depth 1) start acc))
                      ((memv c '(#\) #\] #\} #\>)) (loop (+ i 1) (- depth 1) start acc))
                      ((and (char=? c #\,) (= depth 0))
                       (loop (+ i 1) depth (+ i 1) (cons (string-trim (substring params start i)) acc)))
                      (else (loop (+ i 1) depth start acc)))))))))
(define (handler-arity h) (length (handler-param-list h)))
(define (handler-param-name h i)
  "The name of the I-th parameter of H, without its `?` or its type."
  (let ((p (list-ref (handler-param-list h) i)))
    (car (string-split (car (string-split p #\:)) #\?))))

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
    (push "ingest" "snapshot: W.WireScopeSnapshotReply" ("data" json) "snapshot"
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
    (handler "close"
             "proposalId: string"
             "Promise<unknown>"
             ((session . close))
             "Close a proposal (governor only).")
    (handler "passcodeCheck"
             "passcode: string"
             "Promise<unknown>"
             ()
             "\"ok\" when the passcode opens the identity in hand, read off the log this device holds; else the refusal.")
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
    (handler "join"
             "name: string, email: string"
             "Promise<unknown>"
             ((lobby . join) (lobby . register-oobi-replies))
             "the log in hand takes a seat at a commune that has never seen it")
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
    (handler "log"
             "op: string, payload: string"
             "Promise<string>"
             ((session . sync-log) (session . list-log))
             "The captain's log's own backup: (\"sync\"|\"list\", payload) → JSON.")
    (handler "openProposal"
             "kind: string, domain: string, id: string, text: string, franchise: string, subject?: string"
             "Promise<unknown>"
             ((session . open))
             "Open a proposal: (kind, domain, id, text, franchise, subject) — franchise \"federation\" | \"scope:<sid>\"; subject \"kind:id\" or \"\" names what it is about.")
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
    (handler "reconnect"
             ""
             "Promise<unknown>"
             ()
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
    (handler "contactCheck"
             "aid: string"
             "Promise<unknown>"
             ((lobby . fetch-icp))
             "Whether this commune holds a verified key log for someone: \"ok:checked\" | \"ok:unchecked\" | \"err:…\".")
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
    (handler "setDelegation"
             "delegateAid: string, fraction: number"
             "Promise<unknown>"
             ((session . set-delegation))
             "Hand a fraction (0..1) of your voice to a delegate: \"ok\" or \"err:…\".")
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
    (handler "tier"
             ""
             "Promise<unknown>"
             ()
             "\"root\" | \"device\" | \"\" — how this session proved the AID")
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
    (handler "walkie"
             "op: string, arg?: string"
             "void"
             ()
             "The live audio/video layer: join, joinvideo, leave, and the toggles (talk/cam/screen) whose second argument is \"on\" or \"off\".")
    ;; the machine book — the node tab lends and borrows machine resources
    (handler "machineOffer"
             "commune: string, lane: string, classes: string[], headroom: number, repro: string, optsJson: string"
             "Promise<unknown>"
             ((session . machine-offer))
             "Advertise this tab's machine as a lane in COMMUNE. \"ok:\" | \"err:…\".")
    (handler "machineRetract"
             "commune: string, offerId: string"
             "Promise<unknown>"
             ((session . machine-retract))
             "Withdraw OFFER-ID in COMMUNE, this AID its lender. \"ok\" | \"err:…\".")
    (handler "machineOffers"
             "commune: string"
             "Promise<unknown>"
             ((session . machine-offers))
             "The lane offers standing in COMMUNE, as a JSON array.")
    (handler "machineSubmit"
             "commune: string, taskClass: string, lane: string, repro: string, inputHash: string, optsJson: string"
             "Promise<unknown>"
             ((session . machine-submit))
             "Submit a job of TASK-CLASS to COMMUNE on LANE. \"ok:<job-id>\" | \"err:…\".")
    (handler "machineWithdraw"
             "commune: string, jobId: string"
             "Promise<unknown>"
             ((session . machine-withdraw))
             "Withdraw job JOB-ID in COMMUNE. \"ok\" | \"err:…\".")
    (handler "machineJobs"
             "commune: string"
             "Promise<unknown>"
             ((session . machine-jobs))
             "This AID's jobs in COMMUNE, as a JSON array.")
    (handler "machineMatch"
             "commune: string, jobId: string"
             "Promise<unknown>"
             ((session . machine-match))
             "The offers matching job JOB-ID in COMMUNE, as a JSON array.")
    (handler "machineClaim"
             "commune: string, jobId: string, offerId: string, optsJson: string"
             "Promise<unknown>"
             ((session . machine-claim))
             "Claim job JOB-ID against offer OFFER-ID in COMMUNE. \"ok:<claim-id>\" | \"err:…\".")
    (handler "machineAccept"
             "commune: string, claimId: string"
             "Promise<unknown>"
             ((session . machine-accept))
             "The borrower accepts the work on CLAIM-ID. \"ok\" | \"err:…\".")
    (handler "machinePreempt"
             "commune: string, claimId: string"
             "Promise<unknown>"
             ((session . machine-preempt))
             "The lender preempts CLAIM-ID. \"ok\" | \"err:…\".")
    (handler "machineClaims"
             "commune: string"
             "Promise<unknown>"
             ((session . machine-claims))
             "The claims standing in COMMUNE, as a JSON array.")
    (handler "machineFetchEnvelope"
             "commune: string, claimId: string"
             "Promise<unknown>"
             ((session . machine-fetch-envelope))
             "Fetch the job envelope CLAIM-ID carries, as JSON.")
    (handler "machineReplay"
             "commune: string, claimId: string"
             "Promise<unknown>"
             ((session . machine-replay))
             "Replay CLAIM-ID's metered evidence, as JSON.")
    (handler "machineDispute"
             "commune: string, claimId: string, kind: string"
             "Promise<unknown>"
             ((session . machine-dispute))
             "Raise a dispute of KIND on CLAIM-ID in COMMUNE. \"ok:<dispute-id>\" | \"err:…\".")
    (handler "machineDisputeVerdict"
             "commune: string, disputeId: string, verdict: string"
             "Promise<unknown>"
             ((session . machine-dispute-verdict))
             "Cast VERDICT on DISPUTE-ID in COMMUNE (a reviewer's hand). \"ok\" | \"err:…\".")
    (handler "machineDisputes"
             "commune: string"
             "Promise<unknown>"
             ((session . machine-disputes))
             "The disputes standing in COMMUNE, as a JSON array.")
    (handler "machineDisputeClose"
             "commune: string, disputeId: string"
             "Promise<unknown>"
             ((session . machine-dispute-close))
             "Close DISPUTE-ID in COMMUNE, recording its outcome. \"ok\" | \"err:…\".")
    (handler "machineBind"
             "commune: string, wireJson: string"
             "Promise<unknown>"
             ((session . machine-bind))
             "Bind a did:key to this AID in COMMUNE (the AccountLink wire). \"ok\" | \"err:…\".")
    (handler "machineUnbind"
             "commune: string, key: string, side: string"
             "Promise<unknown>"
             ((session . machine-unbind))
             "Unbind KEY on SIDE in COMMUNE. \"ok\" | \"err:…\".")
    (handler "machineBindings"
             "commune: string"
             "Promise<unknown>"
             ((session . machine-bindings))
             "The did:key bindings standing in COMMUNE, as a JSON array.")
    (handler "machinePayout"
             "commune: string, wireJson: string"
             "Promise<unknown>"
             ((session . machine-payout))
             "Post the payout wire for settled work in COMMUNE. \"ok\" | \"err:…\".")
    (handler "machineReceipt"
             "commune: string, wireJson: string"
             "Promise<unknown>"
             ((session . machine-receipt))
             "Post a metered receipt wire in COMMUNE. \"ok\" | \"err:…\".")
    (handler "machineVerify"
             "wireJson: string"
             "Promise<unknown>"
             ((session . machine-verify))
             "Verify a receipt wire's signature and digest, as JSON.")
    (handler "machineSettle"
             "commune: string, wireJson: string"
             "Promise<unknown>"
             ((session . machine-settle))
             "Settle a receipt wire in COMMUNE (mutual credit). \"ok\" | \"err:…\".")
    (handler "machineStatements"
             "commune: string"
             "Promise<unknown>"
             ((session . machine-statements))
             "This AID's settlement statements in COMMUNE, as a JSON array.")
    (handler "machineEnvelope"
             "wireJson: string"
             "Promise<unknown>"
             ((session . machine-envelope))
             "Read a job envelope wire, as JSON.")
    ))
