;;; module/playnet/monero/poller.scm — donation poller for ^monero-wallet
;;;
;;; Background thread that bridges a live Monero wallet to the planner's
;;; economic model:
;;;
;;;   • Every TICK seconds: read balance, resize the live-resource.
;;;   • For every new incoming transfer: record an EconomicEvent in the
;;;     scope's observer (action 'raise) so the audit trail reflects the
;;;     donation.
;;;
;;; Persistence of the last-seen block height is a plain file in the
;;; wallet data directory. The poller is idempotent: if it crashes after
;;; recording events but before bumping the height, the next tick will
;;; re-record — we de-duplicate by transfer txid before touching the
;;; observer.
;;;
;;; Usage:
;;;
;;;   (use-modules (playnet monero poller))
;;;
;;;   (define stop
;;;     (start-monero-poller
;;;       #:wallet-vat wallet-vat
;;;       #:wallet wallet-actor
;;;       #:scope-vat scope-vat
;;;       #:scope scope-root
;;;       #:live-resource live-resource
;;;       #:state-file "/var/lib/playnet/monero/poller.state"
;;;       #:interval-seconds 60))
;;;
;;;   ;; later:
;;;   (stop)

(define-module (playnet monero poller)
  #:use-module ((playnet observation adjustment) #:select (adjustment-event))
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet monero wallet)
  #:use-module (playnet monero specs)
  #:use-module (playnet utils time)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (;; Actor-based API (preferred):
            ^donation-poller
            donation-poller-env
            start-donation-poller
            ;; The gateway's watch — the wallet in its own process:
            start-donation-watch!
            donation-watch-tick!
            ;; Pure-function API (for tests):
            new-incoming-transfers
            transfer->donation-event
            tick-monero-poller
            load-poller-state
            save-poller-state
            %default-poller-interval))

(define %default-poller-interval 60)   ; seconds

;;; ── State file ────────────────────────────────────────────────────────────
;;;
;;; The state file holds two fields: last-seen-height and a list of
;;; already-processed txids (capped). Format: one read/write form.
;;;
;;;   ((last-seen-height . 3100123)
;;;    (seen-txids . ("tx1" "tx2" ...)))

(define %max-seen-txids 1024)

(define (load-poller-state path)
  "Load the poller state alist from PATH. Returns an alist with
default values if the file does not exist."
  (if (and path (file-exists? path))
      (catch #t
        (lambda ()
          (call-with-input-file path read))
        (lambda _ '((last-seen-height . 0) (seen-txids . ()))))
      '((last-seen-height . 0) (seen-txids . ()))))

(define (save-poller-state path state)
  "Write STATE to PATH (atomic via rename) when PATH is set."
  (when path
    (catch #t
      (lambda ()
        (let ((tmp (string-append path ".tmp")))
          (call-with-output-file tmp
            (lambda (port) (write state port) (newline port)))
          (rename-file tmp path)))
      (lambda (key . args)
        (format (current-error-port)
                "monero-poller: failed to save state to ~a: ~a ~a\n"
                path key args)))))

(define (update-state state key value)
  (let ((others (filter (lambda (p) (not (eq? (car p) key))) state)))
    (cons (cons key value) others)))

(define (state-ref state key default)
  (let ((p (assq key state))) (if p (cdr p) default)))

(define (cap-seen seen)
  (let loop ((xs seen) (n 0) (acc '()))
    (cond
     ((or (null? xs) (>= n %max-seen-txids)) (reverse acc))
     (else (loop (cdr xs) (+ n 1) (cons (car xs) acc))))))

;;; ── Parsing transfers ─────────────────────────────────────────────────────
;;;
;;; get_transfers returns:
;;;
;;;   {"result":{"in":[{"amount":N, "txid":"...", "height":H, ...}, ...]}}
;;;
;;; We only act on 'in' transfers here — outgoing is the wallet sending
;;; funds itself, which the operator already knows about.

(define (response-incoming-transfers rpc-result)
  "Extract the list of incoming transfers from a get_transfers result
alist. Returns a list of per-transfer alists."
  (let ((inv (assoc-ref rpc-result "in")))
    (cond
     ((not inv) '())
     ((vector? inv) (vector->list inv))
     ((list? inv) inv)
     (else '()))))

(define (transfer-txid t)    (assoc-ref t "txid"))
(define (transfer-amount t)  (or (assoc-ref t "amount") 0))  ; atomic units
(define (transfer-height t)  (or (assoc-ref t "height") 0))
(define (transfer-subaddr t) (or (assoc-ref t "subaddr_index") #f))

;;; ── Tick ──────────────────────────────────────────────────────────────────
;;;
;;; A single tick resynchronizes balance and records new donation events.
;;; Pure w.r.t. errors: if any step throws we log and return the old state,
;;; so the background loop can retry on the next tick.

;; current-epoch-seconds imported from (playnet utils time)

(define (donation-event-id txid)
  (string-append "evt-xmr-donation-" txid))

(define (donation-note amount-atomic subaddr)
  (format #f "Incoming XMR donation: ~a atomic units (subaddr ~a)"
          amount-atomic subaddr))

;;; ── What is new, and the event a transfer becomes ─────────────────────────

(define (new-incoming-transfers rpc-result state)
  "The incoming transfers of RPC-RESULT (a get_transfers answer) this STATE
has yet to see, and the state that has seen them: (values NEW-IN NEW-STATE).
A txid is recorded once however often the wallet reports it."
  (let* ((last-height (state-ref state 'last-seen-height 0))
         (seen (state-ref state 'seen-txids '()))
         (new-in (filter (lambda (t)
                           (let ((txid (transfer-txid t)))
                             (and txid (not (member txid seen)))))
                         (response-incoming-transfers rpc-result)))
         (max-height (fold (lambda (t h) (max h (transfer-height t)))
                           last-height
                           new-in)))
    (values new-in
            (update-state
             (update-state state 'last-seen-height max-height)
             'seen-txids
             (cap-seen (append (map transfer-txid new-in) seen))))))

(define (transfer->donation-event t)
  "The EconomicEvent an incoming transfer T is recorded as."
  ;; a donation enters the books by no process: a `raise` (the one constructor
  ;; of an adjustment, observation/adjustment.scm)
  (let ((amount (transfer-amount t)))
    (adjustment-event (donation-event-id (transfer-txid t)) %xmr-resource-id "spec-xmr"
                      (exact->inexact (atomic->xmr amount)) "XMR"
                      #:classified-as '("donation") #:receiver "agent-playnet"
                      #:note (donation-note amount (transfer-subaddr t)))))

(define* (tick-monero-poller #:key
                             wallet-vat wallet
                             scope-vat scope live-resource
                             state
                             (logger (lambda (fmt . args)
                                       (apply format
                                              (current-error-port) fmt args))))
  "Run one tick. Returns a new STATE alist reflecting processed events
(callers should persist it). Catches per-step errors so a transient
daemon blip doesn't crash the poller thread."
  (define (log fmt . args)
    (apply logger (string-append "monero-poller: " fmt "\n") args))

  (catch #t
    (lambda ()
      ;; Phase 1 — balance → live-resource resize.
      (let* ((balance-info (with-vat wallet-vat ($ wallet 'get-balance)))
             (atomic (balance-info-atomic balance-info))
             (xmr (exact->inexact (atomic->xmr atomic))))
        (with-vat scope-vat ($ live-resource 'resize xmr))
        (log "balance = ~a XMR (~a atomic)" xmr atomic))

      ;; Phase 2 — new incoming transfers → observer events.
      (let* ((last-height (state-ref state 'last-seen-height 0))
             (result (with-vat wallet-vat
                       ($ wallet 'get-transfers
                          ;; monero-wallet-rpc get_transfers: only incoming,
                          ;; from min_height
                          `(("in" . #t)
                            ("filter_by_height" . #t)
                            ("min_height" . ,last-height))))))
        (call-with-values (lambda () (new-incoming-transfers result state))
          (lambda (new-in new-state)
            (for-each
             (lambda (t)
               (with-vat scope-vat
                 ($ ($ scope 'observer) 'record-event
                    (transfer->donation-event t)))
               (log "recorded donation event txid=~a amount=~a XMR"
                    (transfer-txid t)
                    (exact->inexact (atomic->xmr (transfer-amount t)))))
             new-in)
            (when (pair? new-in)
              (log "processed ~a new transfer(s), advancing height ~a -> ~a"
                   (length new-in) last-height
                   (state-ref new-state 'last-seen-height 0)))
            new-state))))
    (lambda (key . args)
      (log "tick failed: ~a ~a" key args)
      state)))

;;; ── ^donation-poller actor ────────────────────────────────────────────────
;;;
;;; Wraps the pure tick-monero-poller function in a Goblins define-actor
;;; so state (last-seen-height, seen-txids) lives in bcom and persists
;;; via portrait. No more hand-rolled state file or set! mutation.

(define-actor (^donation-poller bcom
                                wallet-vat wallet
                                scope-vat scope live-resource
                                last-seen-height seen-txids)

  #:portrait
  (lambda ()
    ;; wallet-vat/scope-vat are raw Goblins `vat` objects — live,
    ;; per-process scheduler handles from `spawn-vat`, not capabilities.
    ;; They don't mean anything in a different process and Goblins has no
    ;; sane way to reconstitute one from a portrait, so they're excluded
    ;; here and re-supplied via `rewire-vats!` after restore (same shape
    ;; as `wallet`/`rewire-*` elsewhere in this codebase). wallet/scope
    ;; refs ARE real cross-vat actor caps and serialize as graph refs if
    ;; the actors are in the same persistence env.
    (list wallet scope live-resource last-seen-height seen-txids))

  #:version 1

  #:restore
  (lambda (version w s lr height txids)
    (case version
      ((1) (spawn ^donation-poller #f w #f s lr height txids))
      (else (error "Unknown ^donation-poller version" version))))

  (methods

    ;; `tick` is intentionally NOT where the cross-vat wallet/scope work
    ;; happens. `with-vat` blocks-and-returns only when called *outside*
    ;; any vat turn; called from inside this actor's own method (i.e.
    ;; already inside poller-vat's turn), `with-vat wallet-vat`/
    ;; `with-vat scope-vat` return unresolved promises instead — which
    ;; `tick-monero-poller` would then treat as real values and crash on,
    ;; silently no-op'ing forever (caught by its own top-level `catch`).
    ;; So the actual poll runs from the plain background thread in
    ;; `start-donation-poller` (no ambient vat there), and this actor
    ;; only ever hands out refs/state and commits the result.

    ((rewire-vats! new-wallet-vat new-scope-vat)
     "Re-supply the live vat handles lost on restore (see #:portrait).
Must be called before `refs`/`commit!` on a freshly-restored poller."
     (bcom (^donation-poller bcom new-wallet-vat wallet new-scope-vat scope
                             live-resource last-seen-height seen-txids)))

    ((refs)
     "Snapshot of everything the background thread needs to run one poll
cycle outside any vat turn: the cross-vat refs and current state."
     (unless (and wallet-vat scope-vat)
       (error "^donation-poller: vats not yet rewired after restore — call 'rewire-vats! first"))
     `((wallet-vat . ,wallet-vat) (wallet . ,wallet)
       (scope-vat . ,scope-vat) (scope . ,scope)
       (live-resource . ,live-resource)
       (state . ((last-seen-height . ,last-seen-height)
                 (seen-txids . ,seen-txids)))))

    ((commit! new-state)
     "Persist the state alist a background-thread tick produced."
     (let ((new-height (assq-ref new-state 'last-seen-height))
           (new-txids  (assq-ref new-state 'seen-txids)))
       (bcom (^donation-poller bcom wallet-vat wallet scope-vat scope
                               live-resource
                               (or new-height last-seen-height)
                               (or new-txids seen-txids))
             new-state)))

    ((state)
     `((last-seen-height . ,last-seen-height)
       (seen-txids . ,seen-txids)))

    ((height) last-seen-height)))

;;; ── Persistence environment ──────────────────────────────────────────────

(define donation-poller-env
  (make-persistence-env
    `((((playnet monero) ^donation-poller) ,^donation-poller))))

;;; ── Background loop ─────────────────────────────────────────────────────
;;;
;;; start-donation-poller is the Goblins-idiomatic replacement for
;;; start-monero-poller. It spawns a ^donation-poller actor in
;;; POLLER-VAT and ticks it in a background thread. No set!, no state
;;; file — the actor's bcom state is the source of truth.

(define* (start-donation-poller #:key
                                poller-vat poller
                                (interval-seconds %default-poller-interval)
                                (logger (lambda (fmt . args)
                                          (apply format
                                                 (current-error-port)
                                                 fmt args))))
  "Start a background thread that runs one poll cycle every
INTERVAL-SECONDS. Returns a thunk to stop the loop.

The actual wallet/scope cross-vat work (`tick-monero-poller`) runs here,
in the plain background thread — not inside a `($ poller 'tick)` method
body. `with-vat` only blocks-and-returns when called outside any vat
turn; called from inside another vat's own turn it returns a promise
instead, which `tick-monero-poller` would misread as a real value and
silently no-op forever. So this thread pulls refs+state out of the
poller actor, runs the tick with no ambient vat, then commits the
result back."
  (let ((running? #t))
    (call-with-new-thread
     (lambda ()
       (let loop ()
         (when running?
           (catch #t
             (lambda ()
               (let* ((refs (with-vat poller-vat ($ poller 'refs)))
                      (new-state
                       (tick-monero-poller
                        #:wallet-vat (assq-ref refs 'wallet-vat)
                        #:wallet (assq-ref refs 'wallet)
                        #:scope-vat (assq-ref refs 'scope-vat)
                        #:scope (assq-ref refs 'scope)
                        #:live-resource (assq-ref refs 'live-resource)
                        #:state (assq-ref refs 'state)
                        #:logger logger)))
                 (with-vat poller-vat ($ poller 'commit! new-state))))
             (lambda (key . args)
               (apply logger
                      (string-append "donation-poller: tick failed: ~a ~a\n")
                      key args)))
           (sleep interval-seconds)
           (loop)))))
    (lambda () (set! running? #f))))


;;; ── The gateway's donation watch ─────────────────────────────────────────
;;;
;;; The wallet runs in its own process (server/wallet-service.scm) and the
;;; gateway holds its policy through a ^wallet-policy-client, so what the
;;; gateway can do is ask and be answered in a later turn. One tick, inside
;;; the gateway's vat:
;;;
;;;   - the wallet's UNLOCKED balance becomes the XMR pool's total — what a
;;;     citizen can claim is what the wallet can pay right now;
;;;   - each confirmed incoming transfer the state has yet to see is recorded
;;;     once as a donation event, and the state is saved to STATE-FILE so a
;;;     restart records nothing twice.
;;;
;;; A tick that finds the wallet down is a broken promise, logged, and the
;;; next tick asks again — so the order the two services boot in is no one's
;;; concern.

(define* (donation-watch-tick! policy scope live-resource state-file
                               #:key (log! (lambda _ #f)) (done (lambda () #t)))
  "Ask the wallet for its balance and its new incoming transfers. Runs in a
vat turn; the work happens as the answers arrive. DONE is called once the
incoming-transfers ask is answered, either way."
  (on (<- policy 'get-balance)
      (lambda (bi)
        (<-np live-resource 'resize
              (exact->inexact
               (atomic->xmr (balance-info-unlocked-atomic bi)))))
      #:catch
      (lambda (e)
        (log! "  [donations] balance unavailable: ~a~%" e)))
  (let ((state (load-poller-state state-file)))
    (on (<- policy 'get-incoming (state-ref state 'last-seen-height 0))
        (lambda (result)
          (call-with-values (lambda () (new-incoming-transfers result state))
            (lambda (new-in new-state)
              (when (pair? new-in)
                (let ((observer (<- scope 'observer)))
                  (for-each
                   (lambda (t)
                     (<-np observer 'record-event (transfer->donation-event t))
                     (log! "  [donations] recorded ~a XMR (txid ~a)~%"
                           (exact->inexact (atomic->xmr (transfer-amount t)))
                           (transfer-txid t)))
                   new-in))
                (save-poller-state state-file new-state))))
          (done))
        #:catch
        (lambda (e)
          (log! "  [donations] incoming transfers unavailable: ~a~%" e)
          (done)))))

(define* (start-donation-watch! vat policy scope live-resource state-file
                                #:key
                                (interval-seconds %default-poller-interval)
                                (log! (lambda _ #f)))
  "A background thread that runs one donation-watch-tick! every
INTERVAL-SECONDS inside VAT. Returns a thunk that stops it.

A tick reads the state file and its answer writes it, so a tick waits for
the one before it: two asks in flight over one state would each find the
same transfer new. An ask unanswered for ten minutes is taken for lost."
  (let ((running? #t)
        (asked-at #f))
    (call-with-new-thread
     (lambda ()
       (let loop ()
         (when running?
           (catch #t
             (lambda ()
               (when (or (not asked-at)
                         (> (- (current-time) asked-at) 600))
                 (set! asked-at (current-time))
                 (with-vat vat
                   (donation-watch-tick! policy scope live-resource state-file
                                         #:log! log!
                                         #:done (lambda () (set! asked-at #f))))))
             (lambda (key . args)
               (log! "  [donations] watch: ~a ~a~%" key args)))
           (sleep interval-seconds)
           (loop)))))
    (lambda () (set! running? #f))))
