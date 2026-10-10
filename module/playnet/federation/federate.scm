;;; federation/federate.scm — a gateway's commune as a peer of the federated solve.
;;;
;;; The gateway holds the commune: its planner record (the planner service's
;;; `scope-record`), its governance ^scope that signs under its AID and keeps
;;; its key to itself, one OCapN mycapn and netlayer, and a data directory.
;;; This module puts the commune on the wire with those, and nothing new:
;;;
;;;   `federate!` builds the peer over the record, names it by its AID, gives
;;;   it the goods it masters and the members of those (`roster-ends` — the
;;;   master of a good is its first participant by AID, the same on every side),
;;;   resumes it from what it kept, expects every end by its AID (a
;;;   neighbour's first word is read before this side has reached it),
;;;   registers it under a swiss number kept beside (the same sturdyref after
;;;   every restart), tells the fold that hears attestations, and starts its
;;;   clock. It answers the ends still to reach.
;;;
;;;   `federation-join!` connects those ends from the far communes' sturdyref
;;;   credentials, each verified under the federation's AID, and starts the
;;;   peer once every join has answered. An end with no credential in hand is
;;;   left for the far side to connect; a join that fails holds nothing else.
;;;
;;;   `federation-ask!` asks the federation itself for the spec: the
;;;   federation answers at a DESK (`serve-federation!`, where the federation
;;;   lives), signed under its AID, with the credentials that stand and the
;;;   fold its members tell. A commune first tells the desk what it deals in —
;;;   its CENSUS, a credential it issues and signs over the goods its records
;;;   hold, make, consume and ask for — and the roster is the goods at least
;;;   two members told. The commune checks the answer and every credential
;;;   under the AID it trusts (a census under its member's own), and derives
;;;   the roster from them (`verified-spec`) — asked again until every member
;;;   has told its census. Admission at the federation and the commune naming
;;;   the federation it answers to are the two human acts; everything between
;;;   them travels.
;;;
;;;   `federation-boot!` is a commune's boot on the wire, one door for a
;;;   gateway and a test host alike: the spec asked of the federation's desk
;;;   when the commune names one, read as written otherwise, then `federate!`
;;;   and `federation-join!` over it.
;;;
;;;   A crossing that settles leaves a record (`^custody-recorder`). The goods in
;;;   the federation's pool are common, so a scope that gives hands its custody
;;;   to the federation and a scope that draws receives it from the federation:
;;;   two legs, never a pairing of supplier and drawer. Each leg is written by
;;;   the party that RECEIVES it, as the occurrence it witnessed (an observation
;;;   event of action `transfer-custody`, held by the provider, signed by the
;;;   receiver): the federation records what the scopes gave it, a scope records
;;;   what it drew. A giver's side stands in its own final attestation, signed
;;;   under its AID. They are minted when the commune's peer is FINAL
;;;   (planner/federation/crossing-custody.scm derives the legs from the final
;;;   attestations, and every gateway derives the same ones).
;;;
;;; All run in a turn of the vat the commune (or the federation) lives in.
;;; What a gateway keeps for this is one file, `federation.scm` in its data
;;; directory: its demand, and either the federation's AID and desk, or the
;;; spec written out.

(define-module (playnet federation federate)
  #:use-module (goblins)
  #:use-module (goblins actor-lib on)
  #:use-module (goblins actor-lib joiners)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins actor-lib timers)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (playnet federation host)
  #:use-module ((playnet federation peer) #:select (^commune-peer ^attestation-fold start-ticker! now-seconds))
  #:use-module ((playnet federation async) #:select (make-peer))
  #:use-module ((playnet federation wire)
                #:select (make-signer signer-aid signer-sign signer-of signed-reply verify-signed
                          make-key-ledger signer-rotated-kel))
  #:use-module ((playnet solve engine) #:select (make-boundary-oracle))
  #:use-module ((playnet federation sturdyref-credential) #:select (verified-spec spec-ready?))
  #:use-module ((playnet credentials membership) #:select (make-federation-census-credential))
  #:use-module ((playnet credentials registry) #:select (cred-signed-by-scope))
  #:use-module ((playnet credentials work) #:select (make-observation-event-credential *schema-playnet-observation-event*))
  #:use-module ((playnet keri acdc) #:select (cred-with-signature cred-said cred-claim cred-schema cred-revoked?))
  #:use-module ((playnet federation crossing-custody)
                #:select (crossing-legs leg-id leg-good leg-provider leg-receiver leg-qty))
  #:use-module ((playnet keri crypto-primitives) #:select (keri-crypto-random-bytes))
  #:use-module ((rnrs bytevectors) #:select (bytevector->u8-list))
  #:export (scope-signer census-credential told-at-now federate! federation-join! federation-boot!
            ^federation-desk serve-federation! desk-word->spec federation-ask!
            ^custody-recorder custody-credential today-iso))

(define (scope-signer aid scope)
  "A signer for the governance ^scope of AID: it signs through the scope's
   `sign-said`, in the scope's vat. The scope's key event log goes with it, so
   what it says after a rotation is read under the key the log leaves in force."
  (make-signer aid
               (lambda (text) ($ scope 'sign-said text))
               (lambda () ($ scope 'kel-events))))

(define (told-at-now)
  "The moment a census is told, whole seconds of the host's clock, as the
   census states it: one spelling for every path that tells one."
  (number->string (inexact->exact (floor (now-seconds)))))

(define* (census-credential signer federation-aid goods told-at #:key (units '()))
  "The census of the commune that speaks as SIGNER, told to the federation
   FEDERATION-AID: GOODS, the spec ids its records deal in, as a credential
   the commune issues and signs over its SAID. A commune whose key has rotated
   tells its key log with it, so the signature is read under the key in force.
   UNITS, ((good . unit) …), are what it counts those goods in."
  (let* ((s (signer-of signer))
         (cred (make-federation-census-credential #:commune-aid (signer-aid s)
                                                  #:federation-aid federation-aid
                                                  #:goods goods
                                                  #:told-at told-at
                                                  #:kel (signer-rotated-kel s)
                                                  #:units units)))
    (cred-with-signature cred ((signer-sign s) (cred-said cred)))))

(define (kept-ledger path)
  "A key ledger (`make-key-ledger`) resumed from and kept at PATH: a key seen
   rotated stays retired across a restart."
  (let ((keep (file-keeper path)))
    (make-key-ledger #:resume (or (read-kept path) '())
                     #:keep (lambda (states) (mkdir-p (dirname path)) (keep states)))))

(define* (federate! record signer mycapn netlayer state-dir roster #:key (seconds 0.5) (tell #f))
  "In a turn of the commune's vat: the commune's peer over RECORD, speaking as
   SIGNER (a signer or a keri-identity; its AID names it on the roster), the goods it masters and their
   members read off ROSTER, resumed from and kept at STATE-DIR, registered at
   MYCAPN through NETLAYER under the swiss number kept there, telling TELL its
   attestations when given — a reference, or a sturdyref reached through
   MYCAPN and kept reached (`reach!`) — ticked every SECONDS. → an alist: `ref` the peer,
   `sturdyref` a vow of its sturdyref, `ends` ((good who aid) …) still to
   connect (`federation-join!`)."
  (let* ((me (signer-aid (signer-of signer)))
         (plan (roster-ends roster me))
         (kept-path (string-append state-dir "/kept"))
         (swiss (berth-swiss! state-dir))
         ;; the versions of a good that begins here count up from now, so they
         ;; outrank whatever its participants hold from before: a first boot, a
         ;; snapshot kept in another form, a good whose members have changed
         (peer (make-peer (make-boundary-oracle record)
                          #:name me
                          #:mastering (assq-ref plan 'mastering)
                          #:members (assq-ref plan 'members)
                          #:epoch (inexact->exact (floor (* 1000 (now-seconds))))
                          #:restore (read-kept kept-path)))
         (ref (spawn ^commune-peer peer signer #:name me #:keep (file-keeper kept-path)
                     #:key-ledger (kept-ledger (string-append state-dir "/keys")))))
    ;; every end expected by its AID before any is reachable: a neighbour's
    ;; first word is read on arrival
    (for-each (match-lambda ((link who aid) ($ ref 'connect link who #f aid))) (assq-ref plan 'ends))
    (cond ((string? tell) (reach! mycapn tell (lambda (far) (<- ref 'tell far))))
          (tell (<-np ref 'tell tell)))
    (start-ticker! (list ref) seconds)
    `((ref . ,ref)
      (sturdyref . ,(berth-register! mycapn netlayer ref swiss))
      (ends . ,(assq-ref plan 'ends)))))

(define* (federation-join! mycapn ref ends credentials #:key issuer (log (lambda (m) #f)))
  "In a turn: every one of ENDS ((good who aid) …) whose AID has a sturdyref
   credential in CREDENTIALS ((aid . credential) …) joined (`join!`, under
   ISSUER), and REF started once every join has answered. LOG hears each end
   as (good who joined rtt deadline far-ref), (good who failed error) or
   (good who no-credential), and each later mend as `join!` says it. → a vow
   of the ends joined."
  (let ((answered
         (filter-map
          (lambda (end)
            (match end
              ((link who aid)
               (let ((cred (assoc-ref credentials aid)))
                 (if cred
                     (on (join! mycapn ref link cred #:issuer issuer #:who who #:log log)
                         (lambda (r) (log (list link who 'joined (assq-ref r 'rtt) (assq-ref r 'deadline) (assq-ref r 'ref))) end)
                         #:catch (lambda (e) (log (list link who 'failed e)) #f)
                         #:promise? #t)
                     (begin (log (list link who 'no-credential)) #f))))))
          ends)))
    (on (all-of* answered)
        (lambda (joined) (<-np ref 'start) (filter values joined))
        #:promise? #t)))

;; ── the federation's desk ────────────────────────────────────────────────────
(define (^federation-desk bcom scope signer fold tell)
  "Where a federation answers for itself, in the vat its SCOPE lives in:
   SIGNER signs under the federation's AID, FOLD hears its members and TELL is
   the fold's sturdyref. Methods:
     (ping t)               → T: a round trip, as every far end answers
     (census cred)          → #t: a member's census credential, kept when it
                            checks (`accept-census`); it replaces the member's
                            earlier one
     (spec nonce)           → (text sig), the federation's signed word: its
                            AID, NONCE, the fold to tell and every credential
                            that stands, the sturdyref of each member and the
                            census each has told. The fold expects every
                            holder from then on."
  (define aid (signer-aid (signer-of signer)))
  (methods
   ((ping t) t)
   ((census cred) ($ scope 'accept-census cred) #t)
   ((spec nonce)
    (let* ((spec ($ scope 'federation-spec))
           (held (assq-ref spec 'credentials)))   ; ((holder . credential) …)
      (for-each (lambda (h) ($ fold 'expect (car h))) held)
      (signed-reply signer `((aid . ,aid) (nonce . ,nonce) (tell . ,tell)
                             (credentials . ,(append (map cdr held)
                                                     (map cdr (assq-ref spec 'census))))))))))

(define* (serve-federation! scope signer mycapn netlayer state-dir #:key (unit-of #f) (seconds 2.0))
  "In a turn of the vat SCOPE (a federation's ^scope) lives in: its fold and
   its desk, registered at MYCAPN through NETLAYER under swiss numbers kept
   at STATE-DIR — the same sturdyrefs after every restart. SIGNER signs the
   desk's word (`scope-signer`). → a vow of an alist: `desk`, `fold`,
   `sturdyref` the desk's, `tell` the fold's."
  (let ((fold (spawn ^attestation-fold              ; every member admitted so far is expected
                     (map car (assq-ref ($ scope 'federation-spec) 'credentials))
                     #:key-ledger (kept-ledger (string-append state-dir "/fold-keys")))))
    (let*-on ((tell (berth-register! mycapn netlayer fold (berth-swiss! (string-append state-dir "/fold")))))
      (let ((desk (spawn ^federation-desk scope signer fold tell)))
        (let*-on ((sref (berth-register! mycapn netlayer desk (berth-swiss! (string-append state-dir "/desk")))))
          ;; the federation's own record of what settled: what the scopes gave it
          (let* ((aid (signer-aid (signer-of signer)))
                 (store ($ scope 'acdc-store))
                 (recorder (and store
                                (spawn ^custody-recorder store (and ($ scope 'has-keypair?) scope) aid aid
                                       (lambda () ($ fold 'heard))
                                       ;; a good is counted in the unit its members' censuses state
                                       (or unit-of
                                           (lambda (good)
                                             (or (assoc-ref (or (assq-ref ($ scope 'federation-spec) 'units) '()) good)
                                                 "kg")))))))
            (when recorder (start-ticker! (list recorder) seconds))
            `((desk . ,desk) (fold . ,fold) (recorder . ,recorder) (sturdyref . ,sref) (tell . ,tell))))))))

;; ── a settled crossing leaves a record ───────────────────────────────────────
(define (today-iso)
  "Today's date, UTC, \"YYYY-MM-DD\" — the day a crossing settled on."
  (let ((tm (gmtime (inexact->exact (floor (now-seconds))))))
    (strftime "%Y-%m-%d" tm)))

;; the event id, on the claim, is the leg's id: one record per (good, scope, day)
(define (custody-credential leg unit day)
  "The record of LEG: the occurrence its RECEIVER witnessed, unsigned. Issuer the
   receiver, holder the provider; an observation event of action
   `transfer-custody` for the leg's quantity of its good on DAY. Its SAID is a
   function of the leg alone."
  (make-observation-event-credential
   #:scope-aid (leg-receiver leg)
   #:holder-aid (leg-provider leg)
   #:event-id (leg-id leg)
   #:action 'transfer-custody
   #:qty (leg-qty leg)
   #:unit unit
   #:resource-conforms-to (leg-good leg)
   #:timestamp day))

(define (issue-custody! store scope who legs unit-of day)
  "Issue into STORE the record of every leg WHO receives, signed through SCOPE
   when it has a key. A record of the same leg WHO issued before for another
   quantity is revoked first: the day's settlement is the one that stands."
  (let ((sign (lambda (c) (if scope (cred-signed-by-scope c scope) c)))
        (received (filter (lambda (l) (equal? (leg-receiver l) who)) legs)))
    (for-each
     (lambda (leg)
       (let ((record (custody-credential leg (unit-of (leg-good leg)) day)))
         (for-each (lambda (old)
                     (when (and (equal? (cred-schema old) *schema-playnet-observation-event*)
                                (not (cred-revoked? old))
                                (equal? (cred-claim old 'event-id) (leg-id leg))
                                (not (equal? (cred-said old) (cred-said record))))
                       ($ store 'revoke (cred-said old))))
                   ($ store 'by-issuer who))
         ($ store 'issue-idempotent (sign record))))
     received)
    (length received)))

(define (^custody-recorder bcom store scope who fed-aid read-attested unit-of)
  "Where a gateway keeps the record of its crossings, in the vat its STORE lives
   in: WHO (its AID) signs through SCOPE (or nothing, with no key). READ-ATTESTED
   is a thunk → ((aid . attestation) …), the final standings it can see: the
   commune's own, or every commune's the federation's fold has heard. WHO
   records the legs it receives. Methods:
     (tick)    the legs the standings leave this day are recorded (once per change)
     (legs)    the legs seen at the last tick"
  (define last '())
  (methods
   ((tick)
    (let* ((day (today-iso))
           (legs (crossing-legs (read-attested) fed-aid day)))
      (if (equal? legs last)
          0
          (begin (set! last legs)
                 (issue-custody! store scope who legs unit-of day)))))
   ((legs) last)))

;; ── the commune asks ─────────────────────────────────────────────────────────
(define (fresh-nonce)
  (string-concatenate (map (lambda (b) (string-pad (number->string b 16) 2 #\0))
                           (bytevector->u8-list (keri-crypto-random-bytes 8)))))

(define* (desk-word->spec answer issuer nonce me #:key (ledger #f))
  "The spec the desk's ANSWER (text sig) carries, once it checks: signed
   under ISSUER (read under the key its log leaves in force when it carries
   one; LEDGER remembers what earlier answers showed), answering NONCE, every
   credential standing under ISSUER (`verified-spec`, which derives the roster
   from them, the sturdyrefs read under the key the log had in force when it
   sealed each), and the spec holding the census of every member
   (`spec-ready?`). → the spec, with `tell`. Raises otherwise."
  (let ((word (verify-signed answer issuer #:ledger ledger)))
    (unless (equal? (assq-ref word 'nonce) nonce)
      (error "federation: the desk answers another question"))
    (let ((spec (verified-spec issuer (assq-ref word 'credentials) #:kel (assq-ref word 'kel))))
      (unless (spec-ready? spec me)
        (error "federation: not every member has told its census yet" me))
      (cons (cons 'tell (assq-ref word 'tell)) spec))))

(define* (federation-ask! mycapn desk issuer me #:key (retry 2.0) (census #f) (log (lambda (m) #f))
                           (ledger (make-key-ledger)))
  "In a turn: the spec of the federation ISSUER, asked of its desk at the
   sturdyref DESK (`ask!`) under a fresh nonce and read by `desk-word->spec`.
   CENSUS, when given, is the commune's census credential (`census-credential`),
   told to the desk first on every attempt (telling it twice is telling it
   once). An answer that fails a check, or whose spec does not yet hold
   every member's census, is asked for again RETRY seconds later. LOG hears
   each attempt as `ask!` says it, a failed reading as (uri away (unread
   reason …)). LEDGER, a key ledger, holds what the federation's answers have
   shown of its key. → a vow of the spec, with `tell`."
  (ask! mycapn desk
        (lambda (far)
          (let ((nonce (fresh-nonce)))
            (let*-on ((_ (if census (<- far 'census census) #t))
                      (answer (<- far 'spec nonce)))
              (catch #t
                (lambda () (desk-word->spec answer issuer nonce me #:ledger ledger))
                (lambda reason (cons 'unread reason))))))
        #:refused? (lambda (answer) (and (pair? answer) (eq? (car answer) 'unread)))
        #:retry retry #:log log))

;; ── the boot ─────────────────────────────────────────────────────────────────
(define* (federation-boot! record-of signer mycapn netlayer state-dir spec
                           #:key (seconds 0.5) (census #f) (custody #f) (log (lambda (m) #f)))
  "In a turn: the commune on the wire from SPEC, what it keeps as
   federation.scm. A spec that names the federation's desk (`federation` its
   AID, `desk` its sturdyref) is asked of the federation (`federation-ask!`);
   any other is the spec written out (issuer, goods, roster, credentials,
   tell). CENSUS, the goods the commune's records deal in (planner `census`),
   is told to the desk before the spec is asked for. Then the commune's record for the spec's goods (RECORD-OF, a
   procedure of the spec), `federate!` over the roster telling the spec's
   fold, and `federation-join!` from the credentials under the issuer. What
   a gateway does with its founding commune and what a test host does with
   the commune it holds: one boot. → a vow of the `federate!` alist with
   `joined`, a vow of the ends joined."
  (define (boot spec)
    (let ((fed (federate! (record-of spec) signer mycapn netlayer state-dir (assq-ref spec 'roster)
                          #:seconds seconds #:tell (assq-ref spec 'tell))))
      ;; CUSTODY ((store . S) (scope . SC) (unit-of . proc)): a crossing that settles
      ;; leaves its legs in S, signed through SC
      (when custody
        (let* ((me (signer-aid (signer-of signer)))
               (ref (assq-ref fed 'ref))
               (recorder (spawn ^custody-recorder (assq-ref custody 'store) (assq-ref custody 'scope)
                                me (assq-ref spec 'issuer)
                                ;; the commune's own signed standing, read back and checked
                                (lambda ()
                                  (call-with-values (lambda () (verify-signed ($ ref 'attest) me))
                                    (lambda (payload _) (list (cons me (assq-ref payload 'attestation))))))
                                (or (assq-ref custody 'unit-of)
                                    (lambda (good) (or (assoc-ref (or (assq-ref spec 'units) '()) good) "kg"))))))
          (start-ticker! (list recorder) seconds)))
      (cons (cons 'joined (federation-join! mycapn (assq-ref fed 'ref) (assq-ref fed 'ends)
                                            (assq-ref spec 'credentials)
                                            #:issuer (assq-ref spec 'issuer) #:log log))
            fed)))
  (let ((desk (assq-ref spec 'desk)) (issuer (assq-ref spec 'federation)))
    (if (and desk issuer)
        (let*-on ((asked (federation-ask! mycapn desk issuer (signer-aid (signer-of signer))
                                          #:census (and census
                                                        (census-credential signer issuer census (told-at-now)
                                                                           #:units (let ((u (and custody (assq-ref custody 'unit-of))))
                                                                                     (if u (map (lambda (g) (cons g (u g))) census) '()))))
                                          #:ledger (kept-ledger (string-append state-dir "/desk-keys"))
                                          #:log log)))
          (boot (append asked spec)))
        (let*-on ((_ (timeout 0)))                 ; a vow either way
          (boot spec)))))
