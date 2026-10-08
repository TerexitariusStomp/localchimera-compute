;;; module/playnet/fleet/reconciler.scm — staged fleet reconciler actor
;;;
;;; `^fleet-reconciler` is the actor that actually closes the
;;; endogenous-provisioning loop. Each tick:
;;;
;;;   1. Reads desired-fleet.scm (committed, declarative).
;;;   2. Diffs against the reconciler's own `in-flight` hashmap + the
;;;      materialized hosts already recorded in hosts.scm.
;;;   3. For each new host: starts a staged provisioning sequence
;;;      that progresses one step per tick so we never block the
;;;      vat on long-running external calls.
;;;
;;; The per-host state machine:
;;;
;;;     new
;;;      │  provider.create-invoice → invoice-pending
;;;      ▼
;;;     invoice-pending  (invoice id stored, payment info parsed)
;;;      │  dispatch on currency: XMR → policy.transfer, BTC → manual
;;;      ▼
;;;     paying           (payment initiated, waiting for confirmation)
;;;      │  provider.poll-payment → funded when confirmed
;;;      ▼
;;;     funded
;;;      │  provider.launch → machine-id
;;;      ▼
;;;     launching
;;;      │  provider.poll-server → running? → provisioned
;;;      ▼
;;;     provisioned      (terminal — in-flight entry removed,
;;;                       host appears in hosts.scm)
;;;
;;; Providers are pluggable via the provider protocol (see provider.scm).
;;; The reconciler receives a provider registry (name → closure-alist)
;;; and dispatches based on each host's `provider` field.

(define-module (playnet fleet reconciler)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (rnrs io ports)
  #:use-module ((srfi srfi-13) #:select (string-trim-both))
  #:use-module (playnet monero wallet)
  #:use-module ((playnet monero payout) #:select (outgoing-rows outgoing-match))
  #:use-module (playnet fleet records)
  #:use-module (playnet fleet provider)
  #:use-module (playnet fleet paths)
  #:use-module (playnet fleet sporestack)
  #:use-module (playnet fleet sporestack-provider)
  #:use-module (playnet fleet vpsbg)
  #:use-module (playnet utils time)
  #:use-module (playnet utils hashmap)
  #:export (set-payment-grace-seconds!
            set-host-fronting!
            ^fleet-reconciler
            fleet-reconciler-env
            next-healthy-provider-name!
            make-in-flight-entry
            in-flight-entry?
            in-flight-entry-name
            in-flight-entry-state
            in-flight-entry-invoice-id
            in-flight-entry-payment-uri
            in-flight-entry-payment-currency
            in-flight-entry-swap-id
            in-flight-entry-swap-provider
            in-flight-entry-swap-deposit-name
            in-flight-entry-machine-id
            in-flight-entry-last-error))

;;; ── in-flight entry record ──────────────────────────────────────────────
;;;
;;; One per host that's mid-provisioning. When the host reaches the
;;; 'provisioned state, the entry is deleted from in-flight and the
;;; resulting <materialized-host> is appended to hosts.scm.

(define-record-type <in-flight-entry>
  (make-in-flight-entry name state invoice-id payment-uri payment-currency
                        swap-id swap-provider swap-deposit-name
                        machine-id ipv4 ssh-key-pub
                        budget-atomic last-error)
  in-flight-entry?
  (name              in-flight-entry-name)              ; string
  (state             in-flight-entry-state)             ; symbol
  (invoice-id        in-flight-entry-invoice-id)        ; string or #f
  (payment-uri       in-flight-entry-payment-uri)       ; string or #f
  (payment-currency  in-flight-entry-payment-currency)  ; symbol: 'xmr 'btc or #f
  (swap-id           in-flight-entry-swap-id)           ; string or #f
  (swap-provider     in-flight-entry-swap-provider)     ; symbol or #f
  (swap-deposit-name in-flight-entry-swap-deposit-name) ; string or #f
  (machine-id        in-flight-entry-machine-id)        ; string or #f
  (ipv4              in-flight-entry-ipv4)              ; string or #f
  (ssh-key-pub       in-flight-entry-ssh-key-pub)       ; string
  (budget-atomic     in-flight-entry-budget-atomic)     ; integer
  (last-error        in-flight-entry-last-error))       ; string or #f

(define (entry->list e)
  (list 'in-flight-v3
        (in-flight-entry-name e)
        (in-flight-entry-state e)
        (in-flight-entry-invoice-id e)
        (in-flight-entry-payment-uri e)
        (in-flight-entry-payment-currency e)
        (in-flight-entry-swap-id e)
        (in-flight-entry-swap-provider e)
        (in-flight-entry-swap-deposit-name e)
        (in-flight-entry-machine-id e)
        (in-flight-entry-ipv4 e)
        (in-flight-entry-ssh-key-pub e)
        (in-flight-entry-budget-atomic e)
        (in-flight-entry-last-error e)))

(define (list->entry lst)
  (match lst
    ;; v3: with swap fields
    (('in-flight-v3 name state invoice-id payment-uri currency
                    swap-id swap-prov swap-dep-name
                    machine-id ipv4 ssh-key budget-atomic last-error)
     (make-in-flight-entry name state invoice-id payment-uri currency
                           swap-id swap-prov swap-dep-name
                           machine-id ipv4 ssh-key budget-atomic last-error))
    ;; v2: with currency, no swap fields
    (('in-flight name state invoice-id payment-uri currency
                 machine-id ipv4 ssh-key budget-atomic last-error)
     (make-in-flight-entry name state invoice-id payment-uri currency
                           #f #f #f
                           machine-id ipv4 ssh-key budget-atomic last-error))
    ;; v1: no currency, no swap fields
    (('in-flight name state invoice-id payment-uri
                 machine-id ipv4 ssh-key budget-atomic last-error)
     (make-in-flight-entry name state invoice-id payment-uri 'xmr
                           #f #f #f
                           machine-id ipv4 ssh-key budget-atomic last-error))
    (_ (error "list->entry: bad shape" lst))))

(define* (entry-with e
                     #:key
                     (state             #f)
                     (invoice-id        'unchanged)
                     (payment-uri       'unchanged)
                     (payment-currency  'unchanged)
                     (swap-id           'unchanged)
                     (swap-provider     'unchanged)
                     (swap-deposit-name 'unchanged)
                     (machine-id        'unchanged)
                     (ipv4              'unchanged)
                     (ssh-key-pub       'unchanged)
                     (budget-atomic     #f)
                     (last-error        'unchanged))
  (define (keep new current)
    (if (eq? new 'unchanged) current new))
  (make-in-flight-entry
   (in-flight-entry-name e)
   (or state (in-flight-entry-state e))
   (keep invoice-id        (in-flight-entry-invoice-id e))
   (keep payment-uri       (in-flight-entry-payment-uri e))
   (keep payment-currency  (in-flight-entry-payment-currency e))
   (keep swap-id           (in-flight-entry-swap-id e))
   (keep swap-provider     (in-flight-entry-swap-provider e))
   (keep swap-deposit-name (in-flight-entry-swap-deposit-name e))
   (keep machine-id        (in-flight-entry-machine-id e))
   (keep ipv4              (in-flight-entry-ipv4 e))
   (keep ssh-key-pub       (in-flight-entry-ssh-key-pub e))
   (or budget-atomic       (in-flight-entry-budget-atomic e))
   (keep last-error        (in-flight-entry-last-error e))))

;;; ── Helpers ─────────────────────────────────────────────────────────────

(define (log-line logger fmt . args)
  (apply logger (string-append "fleet-reconciler: " fmt "\n") args))

(define (serialize-hashmap hm)
  (hashmap-fold
   (lambda (k v acc) (cons (cons k (entry->list v)) acc))
   '()
   hm))

(define (deserialize-hashmap pairs)
  (fold (lambda (p acc)
          (hashmap-set acc (car p) (list->entry (cdr p))))
        (hashmap)
        pairs))

;; hosts.scm is read and written through (playnet fleet records).

;;; ── Round-robin rotor + unhealthy-provider cache ───────────────────────
;;;
;;; These are deliberately module-level (not actor parameters): they're
;;; transient routing decisions that don't need to survive a vat snapshot.
;;; The fleet-bridge re-marks providers unhealthy on its next tick after
;;; restart based on missing liveness heartbeats.
;;;
;;; If a future deployment ever spawns *two* ^fleet-reconciler actors in
;;; the same Guile process — say, one per region — they would share this
;;; cursor and step on each other's round-robin. There's currently no
;;; such use case (one reconciler per gateway vat), but the fix is to
;;; promote these to actor parameters with #:portrait/#:restore handling.
;;; Until then: one process, one rotor, by design.

(define *rotor-cursor* 0)
(define *unhealthy-providers* '())  ; list of provider name strings

;;; ── Outcomes of what was asked of the wallet and the swapper ─────────────
;;;
;;; The wallet policy lives in the wallet's own process and the swapper in
;;; the gateway's vat, so the reconciler asks with a send and the answer
;;; arrives in a later turn. A persistent actor holds no reference to itself
;;; to be told with, and everything here happens on ticks anyway: an answer
;;; is noted in this list, and the next `reconcile` applies it to the entry
;;; it concerns before stepping. Each outcome is (KIND HOST-NAME . DATA):
;;;
;;;   (payment-failed NAME REASON)
;;;   (payment-check  NAME VERDICT)        ; left | failed | unseen
;;;   (swap-created   NAME SWAP-ID PROVIDER DEPOSIT-NAME)
;;;   (swap-failed    NAME REASON)
;;;   (swap-recall    NAME (SWAP-ID PROVIDER DEPOSIT-NAME) | #f)
;;;   (swap-status    NAME SWAP-ID STATUS)
;;;
;;; The list is this process's; after a restart an entry stands in the state
;;; it was asked into and its own asking takes it from there: 'paying polls
;;; the provider, 'swap-requested asks the swapper what it has on record.
(define *outcomes* '())

(define (note-outcome! outcome)
  (set! *outcomes* (append *outcomes* (list outcome))))

(define (take-outcomes!)
  (let ((taken *outcomes*))
    (set! *outcomes* '())
    taken))

(define (reason-string e)
  (format #f "~a" e))

;;; A transfer that comes back broken was refused — or its answer was lost on
;;; the way and the money left all the same. "Not seen" is not "did not
;;; happen" (monero/payout.scm stands on the same rule): before an invoice is
;;; paid again the wallet's outgoing transfers are asked about it, and an
;;; unseen one is waited on for this long from when the payment was asked for.
;;; A provider issues a fresh address per invoice, so address and amount name
;;; the payment.
(define %payment-grace-seconds 1800)

(define (set-payment-grace-seconds! seconds)
  "For a test, or an operator at the REPL, to shorten or lengthen the wait."
  (set! %payment-grace-seconds seconds))

;;; ── Fronting a recorded host ────────────────────────────────────────────
;;;
;;; A desired host whose provider-params carry ("cdn-front" . #t) is put
;;; behind the deployment's CDN once it is recorded. The reconciler hands
;;; the hosts that want it to this procedure each tick — a list of
;;; (name ipv4 provider-params) — and goes on; the procedure does its work
;;; off the vat ((playnet fleet cdn-front)) and keeps its own record of
;;; which hosts are fronted, so a host is recorded whether or not a CDN
;;; ever answers. It is a capability of the process, so like the outcomes
;;; list it lives beside the actor, outside its portrait.
(define *host-fronting* #f)

(define (set-host-fronting! proc)
  "PROC: (list of (name ipv4 provider-params)) → unspecified, or #f for none."
  (set! *host-fronting* proc))

(define (front-recorded-hosts! desired materialized)
  (when *host-fronting*
    (let ((wanting
           (filter-map
            (lambda (m)
              (let ((host (find (lambda (h)
                                  (equal? (desired-host-name h)
                                          (materialized-host-name m)))
                                desired)))
                (and host
                     (materialized-host-ipv4 m)
                     (assoc-ref (desired-host-provider-params host) "cdn-front")
                     (list (materialized-host-name m)
                           (materialized-host-ipv4 m)
                           (desired-host-provider-params host)))))
            materialized)))
      (when (pair? wanting)
        (catch #t
          (lambda () (*host-fronting* wanting))
          (lambda (key . args)
            (format (current-error-port)
                    "[fleet] host fronting raised ~a ~s~%" key args)))))))

;; When each entry's payment was asked for, by host name. This process's; a
;; restart starts the wait over, which errs toward waiting.
(define *payment-asked-at* '())

(define (payment-asked-at name)
  (or (assoc-ref *payment-asked-at* name)
      (let ((now (current-epoch-seconds)))
        (set! *payment-asked-at* (acons name now *payment-asked-at*))
        now)))

(define (note-payment-asked! name)
  (set! *payment-asked-at*
        (acons name (current-epoch-seconds)
               (filter (lambda (kv) (not (equal? (car kv) name)))
                       *payment-asked-at*))))

;; SporeStack token-rotation constants. Used by the token-rotating
;; in-flight state and by ensure-sporestack-token!.
;; The token file's path comes from (playnet fleet paths), one definition
;; shared with the gateway's boot path, which writes the same file. Call
;; it, don't cache it: it reads the environment, so overriding the path
;; works whatever order things load in.
(define %token-poll-interval-sec 15)
(define %token-fund-max-ticks 120)  ; 120 × 15 s = 30 min cap

;; In-progress token rotation: now an actor parameter (see #:portrait
;; below), persisted via syrup along with the rest of the actor's state.
;; By the time we enter rotation the wallet has already been charged, so
;; a gateway restart between "transfer XMR" and "balance confirmed" must
;; NOT lose track — the actor's portrait/restore handles that now.
;;
;; Shape (alist) when active; #f when idle:
;;   token       — the freshly minted ss_t_… string
;;   creds       — sporestack-creds for that token
;;                 (NOT serialized; reconstructed from `token` on restore)
;;   ticks       — how many polls so far
;;   started-at  — epoch-seconds

(define (make-rotation token creds ticks started-at)
  `((token . ,token)
    (creds . ,creds)
    (ticks . ,ticks)
    (started-at . ,started-at)))

(define (rotation-active? r) (and r #t))

(define (rotation-with-bumped-ticks r)
  "Return a new rotation alist with ticks incremented."
  (cons (cons 'ticks (+ 1 (assq-ref r 'ticks)))
        (filter (lambda (p) (not (eq? (car p) 'ticks))) r)))

(define (rotation->portrait r)
  "Strip the un-serializable creds field for the on-disk portrait."
  (and r
       `((token      . ,(assq-ref r 'token))
         (ticks      . ,(assq-ref r 'ticks))
         (started-at . ,(assq-ref r 'started-at)))))

(define (rotation-from-portrait p)
  "Inverse of rotation->portrait: rehydrate creds from token."
  (and p
       (let ((token (assq-ref p 'token)))
         (make-rotation
          token
          (make-sporestack-creds sporestack-default-endpoint token)
          (or (assq-ref p 'ticks) 0)
          (or (assq-ref p 'started-at) 0)))))

(define (next-healthy-provider-name! registry unhealthy)
  "Pick the next provider name from REGISTRY, skipping names in
UNHEALTHY. Advances the module-level rotor cursor. If every registered
provider is unhealthy, returns the first registered name (best-effort
fallback) — caller is expected to log a warning."
  (let* ((all-names (map car registry))
         (healthy (filter (lambda (n) (not (member n unhealthy))) all-names))
         (pool (if (null? healthy) all-names healthy)))
    (if (null? pool)
        (error "next-healthy-provider-name!: empty provider registry")
        (let ((picked (list-ref pool (modulo *rotor-cursor* (length pool)))))
          (set! *rotor-cursor* (+ *rotor-cursor* 1))
          picked))))

;;; ── ^fleet-reconciler actor ─────────────────────────────────────────────

(define-actor (^fleet-reconciler bcom
                                 policy
                                 providers         ; provider registry alist
                                 swapper           ; ^xmr-btc-swapper or #f
                                 ssh-key-pub        ; string
                                 desired-path
                                 hosts-path
                                 in-flight          ; hashmap name -> entry
                                 last-reconcile
                                 min-reconcile-interval
                                 token-rotation)    ; #f or rotation alist

  #:portrait
  (lambda ()
    ;; policy/providers/swapper carry credentials — NOT serialized.
    ;; Re-injected via the rewire method after restore.
    ;; token-rotation: creds are reconstructable from token, so the
    ;; portrait stores only the small token+ticks+started-at form.
    (list desired-path hosts-path ssh-key-pub
          (serialize-hashmap in-flight)
          last-reconcile
          min-reconcile-interval
          (rotation->portrait token-rotation)))

  #:version 4

  #:restore
  (lambda (version . args)
    (case version
      ((4)
       (match args
         ((dpath hpath ssh-key hm-pairs last interval rot)
          (spawn ^fleet-reconciler
                 #f '() #f ssh-key dpath hpath
                 (deserialize-hashmap hm-pairs) last interval
                 (rotation-from-portrait rot)))))
      ;; v3 → v4: token-rotation didn't exist; default to #f (no rotation
      ;; in flight). Token-rotation.scm side-file from v3 era is ignored;
      ;; if any operator boots a v3 syrup with rotation in flight, the
      ;; XMR transfer was already made and confirmation will eventually
      ;; arrive — but the actor won't poll for it. Operator action: run
      ;; sporestack-token-create.scm manually to recover.
      ((3)
       (match args
         ((dpath hpath ssh-key hm-pairs last interval)
          (spawn ^fleet-reconciler
                 #f '() #f ssh-key dpath hpath
                 (deserialize-hashmap hm-pairs) last interval #f))))
      ((2)
       (match args
         ((tpath endpoint dpath hpath ssh-key hm-pairs last interval)
          (spawn ^fleet-reconciler
                 #f '() #f ssh-key dpath hpath
                 (deserialize-hashmap hm-pairs) last interval #f))))
      (else (error "Unknown ^fleet-reconciler version" version))))

  ;; Private: the logger is injected via rewire; default is stderr.
  (define logger
    (lambda (fmt . args)
      (apply format (current-error-port) fmt args)))

  (define (require-policy!)
    (unless policy
      (error "^fleet-reconciler: policy cap not yet rewired after restore")))

  (define (pay-invoice! invoice-name addr amount-xmr atomic on-failure)
    "Ask the policy to pay ATOMIC to ADDR under a one-payment allowlist
entry. Three sends, which reach the policy in this order whatever the
transfer's fate: authorize the address for exactly this payment, transfer,
revoke. Providers issue a fresh XMR address per invoice, so the entries
cannot be declared at deploy time. ON-FAILURE gets the transfer's error."
    (<-np policy 'authorize-invoice invoice-name addr amount-xmr)
    (let ((paid (<- policy 'transfer
                    (list (list (cons "address" addr)
                                (cons "amount" atomic))))))
      (<-np policy 'revoke-invoice invoice-name)
      (on paid
          (lambda (_) #t)
          #:catch on-failure)))

  (define (apply-outcome entry outcome)
    "ENTRY as OUTCOME leaves it. An outcome that finds its entry in another
state than the one it answers — the entry moved on, or was re-asked — leaves
it as it stands."
    (let ((state (in-flight-entry-state entry))
          (name  (in-flight-entry-name entry)))
      (match outcome
        (('payment-failed _ reason)
         (cond
          ((eq? state 'paying)
           (log-line logger "[~a] the transfer came back broken: ~a — asking the wallet what left"
                     name reason)
           (entry-with entry
                       #:state 'payment-unconfirmed
                       #:last-error (format #f "payment unconfirmed: ~a" reason)))
          (else entry)))
        (('payment-check _ verdict)
         (cond
          ((not (eq? state 'payment-unconfirmed)) entry)
          ((eq? verdict 'left)
           (log-line logger "[~a] the wallet shows the payment on its way — 'paying"
                     name)
           (entry-with entry #:state 'paying #:last-error #f))
          ((eq? verdict 'failed)
           (log-line logger "[~a] the wallet reports the transfer failed — back to invoice-pending"
                     name)
           (entry-with entry
                       #:state 'invoice-pending
                       #:last-error "payment failed: the wallet reports the transfer failed"))
          ((> (- (current-epoch-seconds) (payment-asked-at name))
              %payment-grace-seconds)
           (log-line logger "[~a] no outgoing transfer for this invoice in ~as — back to invoice-pending"
                     name %payment-grace-seconds)
           (entry-with entry
                       #:state 'invoice-pending
                       #:last-error "payment failed: the wallet shows no transfer for this invoice"))
          (else entry)))
        (('swap-created _ swap-id swap-prov deposit-name)
         (cond
          ((eq? state 'swap-requested)
           (log-line logger "[~a] swap ~a created via ~a" name swap-id swap-prov)
           (entry-with entry
                       #:state 'swapping
                       #:swap-id swap-id
                       #:swap-provider swap-prov
                       #:swap-deposit-name deposit-name
                       #:last-error #f))
          (else entry)))
        (('swap-failed _ reason)
         ;; A create-swap that comes back broken was refused — or its answer
         ;; was lost with the swap made. The entry keeps waiting; the
         ;; swapper's record of the swap (swap-recall, below) decides.
         (cond
          ((eq? state 'swap-requested)
           (log-line logger "[~a] the swapper's answer came back broken: ~a — asking what it has on record"
                     name reason)
           (entry-with entry
                       #:last-error (format #f "swap unconfirmed: ~a" reason)))
          (else entry)))
        (('swap-recall _ recalled)
         (cond
          ((not (eq? state 'swap-requested)) entry)
          ((pair? recalled)
           (match recalled
             ((swap-id swap-prov deposit-name)
              (log-line logger "[~a] the swapper has swap ~a on record — 'swapping"
                        name swap-id)
              (entry-with entry
                          #:state 'swapping
                          #:swap-id swap-id
                          #:swap-provider swap-prov
                          #:swap-deposit-name deposit-name
                          #:last-error #f))
             (_ entry)))
          ((> (- (current-epoch-seconds) (payment-asked-at name))
              %payment-grace-seconds)
           (log-line logger "[~a] no swap on record in ~as — back to invoice-pending"
                     name %payment-grace-seconds)
           (entry-with entry
                       #:state 'invoice-pending
                       #:last-error "swap not created: the swapper has none on record"))
          (else entry)))
        (('swap-status _ swap-id status)
         (cond
          ((and (eq? state 'swapping)
                (equal? swap-id (in-flight-entry-swap-id entry)))
           (swap-status->entry entry status))
          (else entry)))
        (_ entry))))

  (define (apply-outcomes table outcomes)
    "The in-flight TABLE with each of OUTCOMES applied to the entry it names."
    (fold (lambda (outcome acc)
            (let* ((name (and (pair? outcome) (pair? (cdr outcome))
                              (cadr outcome)))
                   (entry (and name (hashmap-ref acc name #f))))
              (if entry
                  (hashmap-set acc name (apply-outcome entry outcome))
                  acc)))
          table
          outcomes))

  ;; Single source of truth for "make a fresh behaviour with these fields
  ;; updated, everything else carried over." Replaces ten-line bcom calls
  ;; that repeat the constant fields verbatim. All keyword args default
  ;; to the current closed-over value.
  (define* (rebuild #:key
                    (new-policy policy)
                    (new-providers providers)
                    (new-swapper swapper)
                    (new-in-flight in-flight)
                    (new-last-reconcile last-reconcile)
                    (new-token-rotation token-rotation)
                    (new-ssh-key-pub ssh-key-pub))
    (^fleet-reconciler bcom
                       new-policy new-providers new-swapper
                       new-ssh-key-pub desired-path hosts-path
                       new-in-flight new-last-reconcile
                       min-reconcile-interval
                       new-token-rotation))

  (define (advance-token-rotation-step)
    "Run one balance-poll against the current in-flight rotation, if any.
Returns (values STATUS NEW-ROTATION NEW-PROVIDERS):
  STATUS ∈ {idle pending confirmed timed-out}
  NEW-ROTATION is the rotation to install (#f on terminal, bumped on
                pending, current value when idle)
  NEW-PROVIDERS is non-#f only on 'confirmed.
Pure with respect to the actor — does NOT bcom; the caller stitches
both NEW-ROTATION and NEW-PROVIDERS into its own rebuild."
    (cond
     ((not (rotation-active? token-rotation))
      (values 'idle token-rotation #f))
     (else
      (let* ((token (assq-ref token-rotation 'token))
             (creds (assq-ref token-rotation 'creds))
             (ticks (assq-ref token-rotation 'ticks))
             (info  (catch #t
                      (lambda () (sporestack-balance creds))
                      (lambda _ '())))
             (cents (or (assoc-ref info "cents") 0)))
        (cond
         ((> cents 0)
          (let* ((dest (provider-token-file "sporestack"))
                 (tmp  (string-append dest ".tmp")))
            (call-with-output-file tmp
              (lambda (port) (display token port)))
            (chmod tmp #o600)
            (rename-file tmp dest))
          (log-line logger
                    "[sporestack-token] funded after ~a ticks (cents=~a)"
                    ticks cents)
          (let* ((new-prov (cons "sporestack" (make-sporestack-provider creds)))
                 (filtered (filter (lambda (p)
                                     (not (equal? (car p) "sporestack")))
                                   providers))
                 (new-providers (cons new-prov filtered)))
            (values 'confirmed #f new-providers)))
         ((>= ticks %token-fund-max-ticks)
          (log-line logger
                    "[sporestack-token] timeout after ~a ticks — abandoning rotation"
                    ticks)
          (values 'timed-out #f #f))
         (else
          (when (zero? (modulo ticks 4))
            (log-line logger
                      "[sporestack-token] still waiting (~a min)"
                      (inexact->exact
                       (round (/ (* ticks %token-poll-interval-sec) 60)))))
          (values 'pending (rotation-with-bumped-ticks token-rotation) #f)))))))

  (define (provider-for host)
    "Look up the provider for HOST from the registry. If the host's
provider is the sentinel \"auto\", round-robin through healthy providers."
    (let ((named (desired-host-provider host)))
      (cond
       ((equal? named "auto")
        (let ((picked (next-healthy-provider-name! providers
                                                  *unhealthy-providers*)))
          (when (and (pair? *unhealthy-providers*)
                     (member picked *unhealthy-providers*))
            (log-line logger
                      "[provider-for] all providers unhealthy — using ~a anyway"
                      picked))
          (log-line logger "[provider-for] auto → ~a (host ~a)"
                    picked (desired-host-name host))
          (registry-ref providers picked)))
       (else
        (registry-ref providers named)))))

  (define (provider-for-name provider-name)
    "Look up a provider by name string."
    (registry-ref providers provider-name))

  ;; ── Per-step handlers ────────────────────────────────────────────

  (define (handle-new-host host)
    "First step: create an invoice via the host's provider."
    (let ((prov (provider-for host))
          (name (desired-host-name host)))
      (call-with-values
        (lambda () (provider-call prov 'create-invoice host))
        (lambda (inv-id uri currency amount)
          (log-line logger "[~a] invoice ~a created (~a), uri=~a"
                    name inv-id currency uri)
          (make-in-flight-entry
           name 'invoice-pending inv-id uri currency
           #f #f #f    ; swap-id, swap-provider, swap-deposit-name
           #f #f ssh-key-pub 0 #f)))))

  (define (handle-invoice-pending entry)
    "Parse the invoice, dispatch payment by currency."
    (require-policy!)
    (let ((currency (or (in-flight-entry-payment-currency entry) 'xmr)))
      (case currency
        ((xmr)
         ;; Parse Monero URI and pay via wallet-policy
         (let* ((uri-str (in-flight-entry-payment-uri entry))
                (uri (parse-monero-uri uri-str)))
           (unless uri
             (error (format #f "[~a] invoice URI did not parse: ~a"
                            (in-flight-entry-name entry) uri-str)))
           (let* ((addr (monero-uri-address uri))
                  (amount-xmr (monero-uri-amount-xmr uri))
                  (atomic (xmr->atomic (or amount-xmr 0)))
                  (invoice-name (format #f "invoice-~a"
                                        (in-flight-entry-name entry))))
             (log-line logger "[~a] paying ~a XMR (~a atomic) to ~a via policy"
                       (in-flight-entry-name entry) amount-xmr atomic addr)
             ;; The entry moves to 'paying as the payment is asked for, so
             ;; no later tick asks again; a refused transfer comes back as
             ;; a payment-failed outcome and returns it to invoice-pending.
             (let ((name (in-flight-entry-name entry)))
               (note-payment-asked! name)
               (pay-invoice! invoice-name addr amount-xmr atomic
                             (lambda (e)
                               (note-outcome!
                                (list 'payment-failed name (reason-string e))))))
             (entry-with entry
                         #:state 'paying
                         #:budget-atomic atomic
                         #:last-error #f))))
        ((btc lightning)
         ;; Initiate XMR→BTC swap via Trocador/Majestic Bank
         (unless swapper
           (error (format #f "[~a] BTC payment required but no swapper configured"
                          (in-flight-entry-name entry))))
         (let* ((uri-str (in-flight-entry-payment-uri entry))
                (uri (parse-bitcoin-uri uri-str)))
           (unless uri
             (error (format #f "[~a] BTC URI did not parse: ~a"
                            (in-flight-entry-name entry) uri-str)))
           (let* ((btc-addr (bitcoin-uri-address uri))
                  (btc-amount (or (bitcoin-uri-amount-btc uri) 0)))
             (log-line logger "[~a] initiating XMR→BTC swap for ~a BTC to ~a"
                       (in-flight-entry-name entry) btc-amount btc-addr)
             ;; The swapper answers with (swap-id provider deposit-name);
             ;; the entry waits in 'swap-requested for that outcome, so no
             ;; later tick starts a second swap for the same invoice.
             (let ((name (in-flight-entry-name entry)))
               (note-payment-asked! name)
               (on (<- swapper 'create-swap name btc-addr btc-amount)
                   (lambda (created)
                     (match created
                       ((swap-id swap-prov deposit-name)
                        (note-outcome!
                         (list 'swap-created name
                               swap-id swap-prov deposit-name)))
                       (other
                        (note-outcome!
                         (list 'swap-failed name
                               (format #f "unexpected answer ~s" other))))))
                   #:catch
                   (lambda (e)
                     (note-outcome!
                      (list 'swap-failed name (reason-string e))))))
             (entry-with entry
                         #:state 'swap-requested
                         #:last-error #f))))
        (else
         (error "unsupported payment currency" currency)))))

  (define (handle-paying entry host)
    "Poll the provider for payment confirmation."
    (let* ((prov (provider-for host))
           (result (provider-call prov 'poll-payment host entry)))
      (if (eq? result 'funded)
          (begin
            (log-line logger "[~a] payment confirmed, advancing to funded"
                      (in-flight-entry-name entry))
            (entry-with entry #:state 'funded))
          (begin
            (log-line logger "[~a] payment still pending"
                      (in-flight-entry-name entry))
            entry))))

  (define (handle-funded entry host)
    "Launch the server via the provider."
    (let* ((prov (provider-for host))
           ;; The provider's launch expects an alist with ssh-key-pub
           (entry-info `(("ssh-key-pub" . ,(in-flight-entry-ssh-key-pub entry))))
           (mid (provider-call prov 'launch host entry-info)))
      (unless mid
        (error (format #f "[~a] launch returned no machine-id"
                       (in-flight-entry-name entry))))
      (log-line logger "[~a] launched as ~a" (in-flight-entry-name entry) mid)
      (entry-with entry #:state 'launching #:machine-id mid)))

  (define (ssh-keyscan ip)
    (catch #t
      (lambda ()
        (let* ((pipe (open-pipe*
                      OPEN_READ
                      "ssh-keyscan" "-t" "ed25519" "-T" "5" ip))
               (lines (let loop ((acc '()))
                        (let ((line (read-line pipe)))
                          (if (eof-object? line)
                              (reverse acc)
                              (loop (cons line acc)))))))
          (close-pipe pipe)
          (let ((key-line (find (lambda (l)
                                 (and (not (string-prefix? "#" l))
                                      (string-contains l "ssh-ed25519")))
                               lines)))
            key-line)))
      (lambda _ #f)))

  (define (handle-launching entry host)
    "Poll the provider for server readiness."
    (let ((prov (provider-for host)))
      (call-with-values
        (lambda () (provider-call prov 'poll-server
                                  (in-flight-entry-machine-id entry)))
        (lambda (running? ip)
          (cond
           (running?
            (let ((host-key (and (string? ip)
                                 (not (string-null? ip))
                                 (ssh-keyscan ip))))
              (log-line logger "[~a] running, ipv4=~a, host-key=~a"
                        (in-flight-entry-name entry) ip
                        (if host-key "scanned" "unavailable"))
              (entry-with entry
                          #:state 'provisioned
                          #:ipv4 ip
                          #:ssh-key-pub (or host-key
                                            (in-flight-entry-ssh-key-pub entry)))))
           (else
            (log-line logger "[~a] not yet running" (in-flight-entry-name entry))
            entry))))))

  (define (promote-to-materialized entry host)
    (let ((raw-key (in-flight-entry-ssh-key-pub entry)))
      (materialized-host
       #:name       (in-flight-entry-name entry)
       #:machine-id (in-flight-entry-machine-id entry)
       #:ipv4       (in-flight-entry-ipv4 entry)
       #:ipv6       #f
       #:provider   (desired-host-provider host)
       #:flavor     (desired-host-flavor host)
       #:created-at (current-epoch-seconds)
       #:estimated-monthly-atomic (in-flight-entry-budget-atomic entry)
       #:ssh-host-key (if (and (string? raw-key)
                               (string-contains raw-key "ssh-ed25519"))
                          raw-key
                          #f)
       #:bootstrap-state 'pending)))

  (define (handle-payment-unconfirmed entry)
    "The transfer's answer came back broken. Ask the wallet what it shows
for this invoice; the verdict arrives as a payment-check outcome."
    (require-policy!)
    (let* ((name   (in-flight-entry-name entry))
           (uri    (parse-monero-uri (in-flight-entry-payment-uri entry)))
           (addr   (and uri (monero-uri-address uri)))
           (atomic (in-flight-entry-budget-atomic entry)))
      (on (<- policy 'get-outgoing 0)
          (lambda (reply)
            (let ((row (outgoing-match addr atomic #f (outgoing-rows reply))))
              (note-outcome!
               (list 'payment-check name
                     (cond ((not row) 'unseen)
                           ((assoc-ref row "failed") 'failed)
                           (else 'left))))))
          #:catch
          (lambda (e)
            (log-line logger "[~a] the wallet's outgoing transfers are unavailable: ~a"
                      name (reason-string e))))
      entry))

  (define (handle-swap-requested entry)
    "A swap has been asked of the swapper. Its answer arrives as an outcome —
and since an answer can be lost (a restart, a broken promise), each tick
also asks the swapper what it has on record for this host."
    (unless swapper
      (error "handle-swap-requested: no swapper configured"))
    (let ((name (in-flight-entry-name entry)))
      (on (<- swapper 'recall-swap name)
          (lambda (recalled)
            (note-outcome! (list 'swap-recall name recalled)))
          #:catch
          (lambda (e)
            (log-line logger "[~a] the swapper's record is unavailable: ~a"
                      name (reason-string e))))
      entry))

  (define (handle-swapping entry host)
    "Ask the XMR→BTC swap service how the swap stands; the answer arrives
as a swap-status outcome and the next tick acts on it."
    (unless swapper
      (error "handle-swapping: no swapper configured"))
    (let ((name    (in-flight-entry-name entry))
          (swap-id (in-flight-entry-swap-id entry)))
      (on (<- swapper 'poll-swap swap-id (in-flight-entry-swap-provider entry))
          (lambda (status)
            (note-outcome! (list 'swap-status name swap-id status)))
          #:catch
          (lambda (e)
            (log-line logger "[~a] swap ~a: status unavailable: ~a"
                      name swap-id (reason-string e))))
      entry))

  (define (swap-status->entry entry status)
    "ENTRY, in 'swapping, as the swap service's STATUS leaves it."
    (let ((swap-id  (in-flight-entry-swap-id entry))
          (dep-name (in-flight-entry-swap-deposit-name entry)))
      (define (reverted last-error)
        (<-np swapper 'finalize-swap dep-name)
        (<-np swapper 'forget-swap (in-flight-entry-name entry))
        (entry-with entry
                    #:state 'invoice-pending
                    #:swap-id #f
                    #:swap-provider #f
                    #:swap-deposit-name #f
                    #:last-error last-error))
      (case status
        ((finished)
         (log-line logger "[~a] swap ~a finished, BTC sent"
                   (in-flight-entry-name entry) swap-id)
         (<-np swapper 'finalize-swap dep-name)
         (<-np swapper 'forget-swap (in-flight-entry-name entry))
         (entry-with entry
                     #:state 'paying
                     #:last-error #f))
        ((failed expired halted)
         (log-line logger "[~a] swap ~a: ~a — reverting to invoice-pending"
                   (in-flight-entry-name entry) swap-id status)
         (reverted (format #f "swap ~a: ~a" swap-id status)))
        ((refunded)
         (log-line logger "[~a] swap ~a refunded — XMR returning"
                   (in-flight-entry-name entry) swap-id)
         (reverted "swap refunded, XMR returning"))
        (else
         ;; Still in progress (waiting, confirming, sending)
         (log-line logger "[~a] swap ~a: ~a"
                   (in-flight-entry-name entry) swap-id status)
         entry))))

  (define (one-step host entry)
    (let ((state (if entry (in-flight-entry-state entry) 'new)))
      (case state
        ((new)             (handle-new-host host))
        ((invoice-pending) (handle-invoice-pending entry))
        ((payment-unconfirmed) (handle-payment-unconfirmed entry))
        ((swap-requested)  (handle-swap-requested entry))
        ((swapping)        (handle-swapping entry host))
        ((paying)          (handle-paying entry host))
        ((funded)          (handle-funded entry host))
        ((launching)       (handle-launching entry host))
        ((provisioned)     entry)
        (else (error "unknown state" state)))))

  (define (step-one host entry)
    (catch #t
      (lambda ()
        (let loop ((e entry))
          (let* ((state (if e (in-flight-entry-state e) 'new))
                 (new-e (one-step host e)))
            (cond
             ((or (eq? state 'provisioned)
                  (eq? (in-flight-entry-state new-e) state))
              new-e)
             ;; Blocking states: wait for external confirmation
             ((memq (in-flight-entry-state new-e)
                    '(paying payment-unconfirmed swap-requested swapping launching))
              new-e)
             (else (loop new-e))))))
      (lambda (key . args)
        (log-line logger "[~a] step failed: ~a ~a"
                  (desired-host-name host) key args)
        (if entry
            (entry-with entry #:last-error (format #f "~a: ~a" key args))
            (make-in-flight-entry (desired-host-name host)
                                  'new #f #f #f
                                  #f #f #f  ; swap fields
                                  #f #f ssh-key-pub 0
                                  (format #f "~a: ~a" key args))))))

  (define (emit-fleet-changed! names)
    (catch #t
      (lambda ()
        (let ((trigger "/var/run/playnet/deploy-trigger"))
          (call-with-output-file trigger
            (lambda (port)
              (format port "~a ~a~%" (length names) (current-epoch-seconds))))
          (log-line logger "wrote deploy trigger (~a hosts)" (length names))))
      (lambda _ #f)))

  (define (load-desired)
    (if (file-exists? desired-path)
        (primitive-load desired-path)
        '()))

  (define (load-current-materialized)
    (load-fleet-file hosts-path))

  (methods

    [(rewire new-policy new-providers new-swapper new-logger)
     (when new-logger (set! logger new-logger))
     (bcom (rebuild #:new-policy (or new-policy policy)
                    #:new-providers (if (pair? new-providers)
                                        new-providers providers)
                    #:new-swapper (or new-swapper swapper)))]

    ;; The provisioning key rests in the portrait, so a restored actor holds
    ;; the one it was first spawned with. Boot hands it the key on disk now.
    [(set-ssh-key new-ssh-key-pub)
     (bcom (rebuild #:new-ssh-key-pub new-ssh-key-pub))]

    [(reconcile)
     (let ((elapsed (- (current-epoch-seconds) last-reconcile)))
       (when (and (> min-reconcile-interval 0)
                  (> last-reconcile 0)
                  (< elapsed min-reconcile-interval))
         (error (format #f
                        "fleet-reconciler: cooldown — last reconcile was ~a seconds ago (min ~a)"
                        elapsed min-reconcile-interval))))
     (let* ((desired (load-desired))
            ;; What the wallet and the swapper answered since the last tick.
            (in-flight (apply-outcomes in-flight (take-outcomes!)))
            (pairs (map (lambda (h)
                          (cons h
                                (hashmap-ref in-flight
                                             (desired-host-name h)
                                             #f)))
                        desired))
            (current-names
             (map materialized-host-name (load-current-materialized))))

       (let* ((active-pairs (filter (lambda (p)
                                      (not (member (desired-host-name (car p))
                                                   current-names)))
                                    pairs))
              (updated-entries
               (map (lambda (p)
                      (let ((next (step-one (car p) (cdr p))))
                        (cons (desired-host-name (car p)) next)))
                    active-pairs))
              (terminals (filter (lambda (kv)
                                   (eq? (in-flight-entry-state (cdr kv))
                                        'provisioned))
                                 updated-entries))
              (pending   (filter (lambda (kv)
                                   (not (eq? (in-flight-entry-state (cdr kv))
                                             'provisioned)))
                                 updated-entries))
              (new-in-flight
               (fold (lambda (kv acc) (hashmap-set acc (car kv) (cdr kv)))
                     (hashmap)
                     pending)))

         (when (pair? terminals)
           (let* ((existing (load-current-materialized))
                  (new-records
                   (map (lambda (kv)
                          (let ((host (find (lambda (h)
                                              (equal? (desired-host-name h)
                                                      (car kv)))
                                            desired)))
                            (promote-to-materialized (cdr kv) host)))
                        terminals)))
             (write-hosts-file! hosts-path (append existing new-records))
             (emit-fleet-changed! (map car terminals))))

         ;; Recorded hosts that ask for the CDN in front of them.
         (front-recorded-hosts! desired (load-current-materialized))

         ;; Advance any in-flight token rotation by one balance-poll.
         ;; Fold the new rotation state (and, on 'confirmed, the new
         ;; SporeStack provider) into the same bcom rebuild.
         (call-with-values advance-token-rotation-step
           (lambda (token-status new-rotation rotation-providers)
             (bcom (apply rebuild
                          `(#:new-in-flight ,new-in-flight
                            #:new-last-reconcile ,(current-epoch-seconds)
                            #:new-token-rotation ,new-rotation
                            ,@(if (eq? token-status 'confirmed)
                                  `(#:new-providers ,rotation-providers)
                                  '())))
                   `((desired . ,(length desired))
                     (in-flight . ,(length (hashmap-keys new-in-flight)))
                     (newly-provisioned . ,(length terminals))
                     (token-rotation . ,token-status)
                     (tick-epoch . ,(current-epoch-seconds))))))))]

    [(status)
     `((last-reconcile . ,last-reconcile)
       (in-flight-count . ,(length (hashmap-keys in-flight)))
       (in-flight-names . ,(hashmap-keys in-flight))
       (in-flight-states
        . ,(map (lambda (k)
                  (cons k (in-flight-entry-state (hashmap-ref in-flight k))))
                (hashmap-keys in-flight)))
       (policy-wired . ,(if policy #t #f))
       (providers . ,(map car providers)))]

    [(in-flight-entries) in-flight]

    [(mark-providers-unhealthy names)
     "Replace the module-level set of unhealthy providers. NAMES is a
list of provider name strings. The next 'auto' selection will skip
these. Set to '() to mark everyone healthy again."
     (set! *unhealthy-providers* names)
     (log-line logger "[health] unhealthy providers: ~a" names)
     'ok]

    [(unhealthy-providers) *unhealthy-providers*]

    [(ensure-sporestack-token! requested-dollars)
     "Kick off (non-blocking) a SporeStack token rotation if needed.

Returns 'already-funded if the existing token's balance covers
REQUESTED-DOLLARS, 'rotating if a rotation is already in flight,
or 'started if a fresh token was minted + paid. The vat is held only
for the wallet-policy transfer call (~seconds in production); the
balance-confirmation poll runs across subsequent reconcile ticks via
advance-token-rotation!, never blocking the vat."
     (cond
      ((rotation-active? token-rotation)
       (log-line logger
                 "[sporestack-token] rotation already in flight (ticks=~a)"
                 (assq-ref token-rotation 'ticks))
       'rotating)
      (else
       (let* ((token-path (provider-token-file "sporestack"))
              (existing (and (file-exists? token-path)
                             (let ((s (string-trim-both
                                       (call-with-input-file token-path
                                         get-string-all))))
                               (and (not (string-null? s)) s))))
              (existing-creds (and existing
                                   (make-sporestack-creds
                                    sporestack-default-endpoint existing)))
              (existing-cents (and existing-creds
                                   (catch #t
                                     (lambda ()
                                       (or (assoc-ref
                                            (sporestack-balance existing-creds)
                                            "cents")
                                           0))
                                     (lambda _ 0)))))
         (cond
          ((and existing-cents
                (>= existing-cents (* requested-dollars 100)))
           (log-line logger
                     "[sporestack-token] balance ~a cents covers $~a — keeping"
                     existing-cents requested-dollars)
           'already-funded)
          (else
           (require-policy!)
           (let* ((token (generate-sporestack-token))
                  (creds (make-sporestack-creds
                          sporestack-default-endpoint token))
                  (invoice (sporestack-add-funds creds
                                                 #:currency "xmr"
                                                 #:dollars requested-dollars))
                  (uri-str (invoice-payment-uri invoice))
                  (uri (parse-monero-uri uri-str))
                  (addr (and uri (monero-uri-address uri)))
                  (amount-xmr (and uri (monero-uri-amount-xmr uri)))
                  (atomic (xmr->atomic (or amount-xmr 0)))
                  (invoice-name (format #f "sporestack-token-~a"
                                        (current-epoch-seconds))))
             (unless (and addr amount-xmr)
               (error "ensure-sporestack-token!: invoice URI did not parse"
                      uri-str))
             (log-line logger
                       "[sporestack-token] new token, paying ~a XMR to ~a"
                       amount-xmr addr)
             ;; A refused transfer leaves the new token unfunded; the
             ;; rotation's own balance poll runs to its cap and gives up.
             (pay-invoice! invoice-name addr amount-xmr atomic
                           (lambda (e)
                             (log-line logger
                                       "[sporestack-token] payment failed: ~a"
                                       (reason-string e))))
             (log-line logger
                       "[sporestack-token] rotation started — confirmation will arrive across subsequent ticks (cap ~a min)"
                       (inexact->exact
                        (round (/ (* %token-fund-max-ticks
                                     %token-poll-interval-sec)
                                  60))))
             (bcom (rebuild
                    #:new-token-rotation
                    (make-rotation token creds 0 (current-epoch-seconds)))
                   'started)))))))]

    [(advance-token-rotation!)
     "Advance an in-flight token rotation by one balance-poll. Idempotent
no-op if no rotation is active. Returns one of 'idle, 'pending,
'confirmed, 'timed-out. On 'confirmed the new token is persisted and
the SporeStack provider is re-spawned in the registry."
     (call-with-values advance-token-rotation-step
       (lambda (status new-rotation new-providers)
         (case status
           ((idle)
            'idle)
           ((confirmed)
            (bcom (rebuild #:new-token-rotation #f
                           #:new-providers new-providers)
                  'confirmed))
           (else
            ;; pending or timed-out: install new-rotation (#f on
            ;; timed-out, bumped on pending); providers unchanged.
            (bcom (rebuild #:new-token-rotation new-rotation) status)))))]

    [(token-rotation-status)
     "Inspector: return #f when idle, or an alist with current rotation
state (token-prefix, ticks, started-at)."
     (and token-rotation
          `((token-prefix . ,(substring (assq-ref token-rotation 'token) 0 12))
            (ticks        . ,(assq-ref token-rotation 'ticks))
            (started-at   . ,(assq-ref token-rotation 'started-at))))]

    [(decommission)
     "Delete servers for hosts in hosts.scm but NOT in desired-fleet.scm."
     (let* ((desired (load-desired))
            (materialized (load-current-materialized))
            (desired-names (map desired-host-name desired))
            (stale (filter (lambda (m)
                             (not (member (materialized-host-name m)
                                         desired-names)))
                           materialized)))
       (if (null? stale)
           '()
           (let ((decommissioned
                  (filter-map
                   (lambda (m)
                     (catch #t
                       (lambda ()
                         (let* ((prov-name (materialized-host-provider m))
                                (prov (provider-for-name prov-name))
                                (mid (materialized-host-machine-id m)))
                           (log-line logger
                                    "[~a] decommissioning via ~a (machine ~a)"
                                    (materialized-host-name m) prov-name mid)
                           (provider-call prov 'delete-server mid)
                           (materialized-host-name m)))
                       (lambda (key . args)
                         (log-line logger
                                  "[~a] decommission failed: ~a ~a"
                                  (materialized-host-name m) key args)
                         #f)))
                   stale)))
             (let ((remaining (filter (lambda (m)
                                        (not (member (materialized-host-name m)
                                                     decommissioned)))
                                      materialized)))
               (write-hosts-file! hosts-path remaining))
             decommissioned)))]

    [(check-renewals)
     "Query all providers for servers expiring within 7 days."
     (catch #t
       (lambda ()
         (let ((now (current-epoch-seconds)))
           (append-map
            (lambda (prov-pair)
              (let* ((prov-name (car prov-pair))
                     (prov (cdr prov-pair))
                     (servers (provider-call prov 'list-servers)))
                (filter-map
                 (lambda (srv)
                   (let* ((exp (or (assoc-ref srv "expiration") 0))
                          (days-left (/ (max 0 (- exp now)) 86400))
                          (hostname (or (assoc-ref srv "hostname") "?")))
                     (when (< days-left 7)
                       (log-line logger "[~a/~a] EXPIRING in ~a days"
                                 prov-name hostname
                                 (inexact->exact (floor days-left))))
                     (and (< days-left 7)
                          (cons hostname days-left))))
                 servers)))
            providers)))
       (lambda (key . args)
         (log-line logger "check-renewals failed: ~a ~a" key args)
         '()))]))

;;; ── Persistence environment ─────────────────────────────────────────────

(define fleet-reconciler-env
  (make-persistence-env
    `((((playnet fleet) ^fleet-reconciler) ,^fleet-reconciler))))
