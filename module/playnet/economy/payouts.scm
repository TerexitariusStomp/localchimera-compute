;;; module/playnet/economy/payouts.scm — a payout, as the records ValueFlows gives it: the member's intent, the commons' commitment, its ending.
;;;
;;; A library the planner service's doors call (docs/planning/codebase-layout.md §12): a
;;; verb takes the plan-store and the arguments; the door is the gate and one call.
;;;
;;; A payout is three records and nothing else:
;;;   · the member's INTENT, "payout:…" (doors/planner/money.scm request-payout): a
;;;     `transfer` of their claimed XMR to an address outside the commons, open
;;;     (not finished) until the coins went or the ask was closed;
;;;   · the commons' COMMITMENT to send it, "sending:<intent>", written when the runner
;;;     BEGINS (its hasBeginning the instant the coins started moving, satisfies the
;;;     intent): while it stands unfinished the claim stays reserved. A commitment the
;;;     reconciler could not match on-chain is PARKED: its hasEnd is the instant it gave
;;;     up, the reason beside it in the store's meta, for an operator to settle or fail;
;;;   · the commitment's ENDING, the plan-store's own dated fact (end-commitment):
;;;     `fulfilled` with the txid of the transfer event the ledger recorded
;;;     (money.scm ledger-settled!, which names the commitment as what it fulfils), or
;;;     `failed` with the reason. Either finishes the intent.
;;; Retiring, the requester's own act while nothing has begun, removes the intent.
;;; The word a row shows ("pending" "sending" "unsettled:…" "sent:…" "failed:…") is
;;; `payout-word`, read off those records; no record carries it.
;;;
;;; A store written before this stated the word in the intent's `state` (VF's slot for
;;; the resource's state, not a lifecycle): `payouts-upgrade!` reads such intents into
;;; the three records once, at the scope's wiring (doors/service.scm), and clears the slot.

(define-module (playnet economy payouts)
  #:use-module ((goblins) #:select ($))
  #:use-module ((playnet vf schemas) #:select (copy-intent economic-resource-onhand-quantity intent-finished intent-has-beginning intent-id intent-provider intent-resource-conforms-to intent-resource-quantity intent-state make-commitment commitment-id commitment-finished commitment-has-beginning commitment-has-end copy-commitment measure-has-numerical-value))
  #:use-module ((srfi srfi-1) #:select (fold filter-map))
  #:use-module ((ice-9 match) #:select (match))
  #:export (sending-id intent-private? commitment-private? payout-source-id monero-address-plausible? payouts-of payout-available
            payout-open? payout-pending? payout-sending? payout-txid payout-word payout-row-context
            payouts-where payout-move! payouts-upgrade!))

(define (intent-private? i)
  "An intent that names something of one member's that no other reader is
   owed — today the payout intents, which carry a destination address. Kept
   out of the snapshot and the query door; the member reads their own via
   my-payouts."
  (let ((id (intent-id i)))
    (and (string? id) (string-prefix? "payout:" id))))
(define (commitment-private? c)
  "The commons' commitment to send a private intent's payout: it names that intent,
   so it stays with the member as the intent does."
  (let ((id (commitment-id c)))
    (and (string? id) (string-prefix? "sending:payout:" id))))
(define (payout-source-id aid)
  "The member's claimed-XMR record: what the shop's claim of `res-xmr-main`
   lands in (account.scm: to-resource = resource-id ^ \"-\" ^ aid)."
  (string-append "res-xmr-main-" aid))
(define (monero-address-plausible? a)
  "Shape check only — a standard/sub address (95) or an integrated one (106)
   in the base58 alphabet. The wallet is the authority on validity; this
   keeps a typo from becoming a parked intent."
  (and (string? a)
       (memv (string-length a) '(95 106))
       (string-every (lambda (c)
                       (string-index "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz" c))
                     a)
       #t))
(define (payouts-of ps aid)
  "The payout intents, AID's own or (AID #f) everyone's, oldest first."
  (sort (filter (lambda (i)
                  (and (intent-private? i)
                       (or (not aid) (equal? aid (intent-provider i)))))
                ($ ps 'all-intents))
        (lambda (a b) (string<? (intent-id a) (intent-id b)))))
(define* (payout-available obs ps aid #:key (owed 0.0))
  "What AID may still ask to send: their claimed XMR on hand, plus OWED (what
   the commons owes them, already priced in XMR — economy/debts.scm
   debts-owed-in-xmr, injected as owed-of; see the ^planner-service header),
   less every payout of theirs still OPEN — pending, sending, or parked
   (a transfer the gateway lost sight of reserves the claim until an
   operator settles or fails it, so a re-ask can never pay twice)."
  (let* ((r  ($ obs 'get-resource (payout-source-id aid)))
         (oh (and r (economic-resource-onhand-quantity r)))
         (have (+ (if oh (measure-has-numerical-value oh) 0) owed))
         (pending (fold + 0 (map (lambda (i) (measure-has-numerical-value (intent-resource-quantity i)))
                                 (filter (lambda (i) (payout-open? ps i))
                                         (payouts-of ps aid))))))
    (max 0 (- have pending))))
(define (payouts-where ps keep?)
  "Everyone's payout intents that (KEEP? ps intent) accepts, oldest first."
  (filter (lambda (i) (keep? ps i)) (payouts-of ps #f)))

;; ── the three records, read ──────────────────────────────────────────────────
(define (sending-id iid) (string-append "sending:" iid))
(define (payout-commitment ps i) ($ ps 'get-commitment (sending-id (intent-id i))))
(define (payout-meta ps i) (or ($ ps 'get-meta (sending-id (intent-id i))) '()))
(define (payout-ending ps i)
  "The commitment's ending as the store dated it: ((ended . fulfilled|failed) (at . t) …), or #f."
  (let ((m (payout-meta ps i))) (and (assq 'ended m) m)))
(define (payout-open? ps i) (not (intent-finished i)))
(define (payout-pending? ps i) (and (not (intent-finished i)) (not (payout-commitment ps i))))
(define (payout-sending? ps i)
  "Begun and neither ended nor parked: what the reconciler looks for on-chain."
  (let ((c (payout-commitment ps i)))
    (and c (not (commitment-finished c)) (not (commitment-has-end c)) #t)))
(define (payout-parked? ps i)
  (let ((c (payout-commitment ps i)))
    (and c (not (commitment-finished c)) (commitment-has-end c) #t)))
(define (payout-txid ps i)
  "The txid a fulfilled ending carries, else #f."
  (let ((m (payout-ending ps i)))
    (and m (eq? 'fulfilled (assq-ref m 'ended)) (assq-ref m 'txid))))
(define (payout-row-context ps i)
  "What a payout's row shows beyond the intent's own fields: the WORD, and BEGAN,
   the instant the coins started moving (the commitment's hasBeginning)."
  (let ((c (payout-commitment ps i)))
    `((word . ,(payout-word ps i))
      (began . ,(or (and c (commitment-has-beginning c)) (intent-has-beginning i))))))
(define (payout-word ps i)
  "The one word a row shows for where the payout stands, read off the records."
  (let ((m (payout-ending ps i)))
    (cond ((and m (eq? 'fulfilled (assq-ref m 'ended))) (string-append "sent:" (or (assq-ref m 'txid) "?")))
          (m (string-append "failed:" (or (assq-ref m 'reason) "?")))
          ((payout-parked? ps i) (string-append "unsettled:" (or (assq-ref (payout-meta ps i) 'reason) "?")))
          ((payout-commitment ps i) "sending")
          (else "pending"))))

;; ── the lifecycle, as one table ──────────────────────────────────────────────
;; A payout moves by these verbs and no other, each a row: a predicate over the
;; records it may leave from, the move itself over the store, and the refusal.
;; `payout-move!` is the one step every verb takes: find the intent, refuse what
;; the row does not allow, run the verb's own effect while the records stand as
;; they were, then move. AT is the instant as the store dates its facts (unix
;; seconds); BEGAN the ISO instant the coins started moving.
(define (begin! ps i at began arg)
  ($ ps 'add-commitment-silent
     (make-commitment #:id (sending-id (intent-id i)) #:action 'transfer
                      #:resource-inventoried-as (payout-source-id (intent-provider i))
                      #:resource-conforms-to (intent-resource-conforms-to i)
                      #:resource-quantity (intent-resource-quantity i)
                      #:provider (intent-provider i) #:receiver "monero-chain"
                      #:has-beginning (or began (intent-has-beginning i))
                      #:satisfies (intent-id i) #:in-scope-of '())))
(define (park! ps i at began reason)
  (let ((c (payout-commitment ps i)))
    ($ ps 'add-commitment-silent (copy-commitment c #:has-end (number->string at)))
    ($ ps 'set-meta (sending-id (intent-id i)) `((parked . #t) (reason . ,(if (string? reason) reason "?")) (at . ,at)))))
(define (end! ps i at began kind detail)
  "The commitment ended KIND (fulfilled | failed) with DETAIL beside the dated fact; the intent finished."
  (unless (payout-commitment ps i) (begin! ps i at began #f))   ; failed or settled before the runner began it
  (let ((cid (sending-id (intent-id i))))
    ($ ps 'end-commitment cid kind at)
    ($ ps 'set-meta cid (append ($ ps 'get-meta cid) (list detail)))
    (finish-intent! ps i)))
(define (finish-intent! ps i)
  ($ ps 'remove-intent (intent-id i))
  ($ ps 'add-intent-silent (copy-intent i #:finished #t)))
(define %payout-moves
  `((begin    ,payout-pending? ,begin! "not pending")
    (unsettle ,payout-sending? ,park! "not sending")
    (fail     ,payout-open?    ,(lambda (ps i at began r) (end! ps i at began 'failed (cons 'reason (if (string? r) r "?")))) "already settled")
    (settle   ,payout-open?    ,(lambda (ps i at began txid) (end! ps i at began 'fulfilled (cons 'txid txid))) "already settled")
    (retire   ,payout-pending? ,(lambda (ps i at began _) ($ ps 'remove-intent (intent-id i))) "already settled")))
(define* (payout-move! ps id verb #:optional (arg #f) #:key (by #f) (at 0) (began #f) (effect (lambda (i) #t)))
  "The payout ID moved by VERB with ARG; BY names the caller where only the
   requester may; AT the instant (unix seconds) the store dates the move; BEGAN
   the ISO instant the coins started moving; EFFECT runs on the intent as it
   stood, before the move. Answers the intent as it stood."
  (match (or (assq verb %payout-moves) (error "no such payout move" verb))
    ((_ may? move! refusal)
     (let ((i ($ ps 'get-intent id)))
       (unless (and i (string-prefix? "payout:" id)) (error "no such payout" id))
       (when (and by (not (equal? by (intent-provider i)))) (error "not your payout" id))
       (unless (may? ps i) (error refusal id))
       (effect i)
       (move! ps i at began arg)
       i))))

;; ── a store written before the records: the word read into them once ────────
(define* (payouts-upgrade! ps #:key (at 0))
  "Every payout intent still carrying the lifecycle word in its `state` slot is
   read into the three records, and the slot cleared. Idempotent: an intent
   with no word is left alone. Answers how many it read."
  (let ((n 0))
    (for-each
     (lambda (i)
       (let ((w (intent-state i)))
         (when (string? w)
           (set! n (1+ n))
           ($ ps 'remove-intent (intent-id i))
           ($ ps 'add-intent-silent (copy-intent i #:state #f))
           (let ((i ($ ps 'get-intent (intent-id i))) (began (intent-has-beginning i)))
             (cond ((equal? w "pending") #t)
                   ((equal? w "sending") (begin! ps i at began #f))
                   ((string-prefix? "unsettled:" w) (begin! ps i at began #f) (park! ps i at began (substring w 10)))
                   ((string-prefix? "sent:" w) (end! ps i at began 'fulfilled (cons 'txid (substring w 5))))
                   ((string-prefix? "failed:" w) (end! ps i at began 'failed (cons 'reason (substring w 7))))
                   (else #t))))))
     (payouts-of ps #f))
    n))
