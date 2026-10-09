;;; module/playnet/governance/uc-curator.scm — Universal Commune curator
;;;
;;; The UC has *derived* membership: its members are exactly the
;;; orphans (scopes with no parent) currently known to the gateway-wide
;;; ^scope-graph. This actor is the daemon that maintains the UC's
;;; member-set against the live graph.
;;;
;;; Tick loop (default interval: 3600s — see PLAYNET_UC_CURATION_INTERVAL_SEC):
;;;
;;;   desired := ($ scope-graph 'orphans)
;;;   current := keys of ($ uc 'member-communes)
;;;   admit (desired - current); remove (current - desired)
;;;   if any change → ($ uc 'rotate-keys)
;;;
;;; Authority: holds a gov-cap minted to itself at gateway boot. Since
;;; the UC has no separate governance body, its gov-cap IS the
;;; curator-cap conceptually. The cap is kept inside this actor's
;;; closure and never escapes — admit/remove calls happen only via
;;; this actor's tick body.
;;;
;;; Scheduling: a plain Scheme thread external to the vat pushes
;;; `(<- self 'tick)` every interval-sec. Goblins vat's turn loop
;;; processes the message in due course. Same pattern as the project's
;;; existing periodic actors (see ^http-witness-publisher in
;;; identity/oobi-host-mirror.scm and adjacent files).
;;;
;;; Per `docs/commons.typ` §3686: "no one is a *member* of any scope,
;;; every leaf is a *universal leaf*". The curator implements the
;;; structural side of this — actively keeping the UC's member-list
;;; in sync with the scope topology so the "universal" label means
;;; what it says at any moment.

(define-module (playnet governance uc-curator)
  #:use-module (goblins)
  #:use-module ((playnet utils clock) #:select (instant->unix (now . clock-now)))   ; the one clock: instants inside, civil at the boundary
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 format)
  #:use-module (ice-9 threads)
  #:use-module (srfi srfi-1)
  ;; SAID over the sorted member-AID list. Same hash function
  ;; (compute-said) the rest of governance uses for plan IDs etc., so
  ;; the digest is interpretable with no new tooling — anyone with
  ;; the member list can independently re-derive it.
  #:use-module ((playnet governance credentials) #:select (compute-plan-said))
  #:export (^uc-curator
            spawn-uc-curator
            uc-curator-default-interval-sec
            member-set-anchor))

(define (uc-curator-default-interval-sec)
  "Default tick interval, overridable via env."
  (let ((env (getenv "PLAYNET_UC_CURATION_INTERVAL_SEC")))
    (cond
     ((not env) 3600)
     ((string->number env))
     (else 3600))))

(define (log* fmt . args)
  (apply format (current-error-port)
         (string-append "[uc-curator] " fmt "~%")
         args)
  (force-output (current-error-port)))

(define (oobi-url-for aid)
  (string-append "/oobi/" aid))

(define (member-set-anchor uc-aid member-aids)
  "KERI seal anchored to UC rotation events: a SAID over UC-AID and
   the sorted member-AID set. Sorted so two observers with the same
   set always derive the same SAID; UC-AID folded in so the digest is
   scoped to this UC. Returned shape is one ACDC seal alist:
     ((d . <said>) (s . playnet-uc-membership/v1))
   Wrap in a list when passing as #:anchors."
  `((d . ,(compute-plan-said uc-aid (sort member-aids string<?)
                             '((schema . "playnet-uc-membership/v1"))))
    (s . "playnet-uc-membership/v1")))

(define* (^uc-curator bcom
                      uc-ref
                      scope-graph
                      gov-cap
                      #:optional
                      (interval-sec (uc-curator-default-interval-sec))
                      (local-refs (hashmap))
                      (last-tick   #f)
                      (last-orphans '()))

  (define (with-state new-refs new-tick new-orphans)
    (^uc-curator bcom uc-ref scope-graph gov-cap interval-sec
                 new-refs new-tick new-orphans))

  (define (hashmap-keys hm)
    (hashmap-fold (lambda (k _v acc) (cons k acc)) '() hm))

  (define (do-tick)
    ;; A tick that cannot READ reconciles NOTHING: either read failing must
    ;; end the tick, typed, before any diff is taken. Failure-as-empty-set
    ;; made an unreachable graph read as "no orphans desired", and the diff
    ;; three lines later issued remove-commune on EVERY member — one
    ;; transient vat hiccup de-federating the whole UC while the log said
    ;; only "orphans failed".
    (let* ((desired (catch #t
                      (lambda () ($ scope-graph 'orphans))
                      (lambda args
                        (log* "scope-graph unreadable — tick skipped: ~a" args)
                        'unreadable)))
           ;; "current" = union of locally-resolved members AND remote
           ;; sturdyref entries. admit-commune-remote writes only to
           ;; member-sturdyrefs (not members), so the bare
           ;; member-commune-ids list would think every remote-admitted
           ;; AID was still missing and re-issue the admit each tick.
           ;; Taking the union avoids the duplicate-admit churn while
           ;; still letting `remove-commune` work (it tears down both).
           (current (catch #t
                      (lambda ()
                        (let* ((members ($ uc-ref 'member-communes))
                               (refs    ($ uc-ref 'member-sturdyrefs)))
                          (delete-duplicates
                           (append (hashmap-keys members)
                                   (hashmap-keys (or refs (hashmap)))))))
                      (lambda args
                        (log* "uc member-communes unreadable — tick skipped: ~a" args)
                        'unreadable)))
           (to-add  (if (or (eq? desired 'unreadable) (eq? current 'unreadable))
                        '() (lset-difference equal? desired current)))
           (to-rm   (if (or (eq? desired 'unreadable) (eq? current 'unreadable))
                        '() (lset-difference equal? current desired))))
      (for-each
       (lambda (aid)
         (let ((ref (hashmap-ref local-refs aid #f)))
           (catch #t
             (lambda ()
               (if ref
                   ($ uc-ref 'admit-commune gov-cap aid ref)
                   ;; Remote / unknown-ref orphan: admit by sturdyref.
                   ;; The sturdyref-uri we record is a relative OOBI
                   ;; URL; consumers resolve against the publishing
                   ;; gateway. Cross-gateway orphans (noted by the
                   ;; remote-scope-poller) take this path.
                   ($ uc-ref 'admit-commune-remote gov-cap aid aid
                      (oobi-url-for aid))))
             (lambda args
               (log* "admit ~a failed: ~a" aid args)))))
       to-add)
      (for-each
       (lambda (aid)
         (catch #t
           (lambda () ($ uc-ref 'remove-commune gov-cap aid))
           (lambda args
             (log* "remove ~a failed: ~a" aid args))))
       to-rm)
      (when (or (pair? to-add) (pair? to-rm))
        (catch #t
          (lambda ()
            ;; Anchor a digest of the post-change member set into the
            ;; rotation event. Observers can re-derive the same SAID
            ;; from the same membership and confirm the UC's KEL
            ;; commitment matches what the gateway is publishing —
            ;; without the KEL having to enumerate every member AID.
            (let* ((uc-aid ($ uc-ref 'scope-aid))
                   (anchor (member-set-anchor uc-aid desired)))
              ($ uc-ref 'rotate-keys #:anchors (list anchor))))
          (lambda args
            (log* "rotate-keys failed: ~a" args)))
        (log* "tick: +~a/-~a; total orphans=~a"
              (length to-add) (length to-rm) (length desired)))
      ;; a skipped tick keeps the last GOOD reading — 'unreadable is a
      ;; refusal to answer, never a membership observation
      (values (if (or (eq? desired 'unreadable) (eq? current 'unreadable))
                  last-orphans desired)
              (instant->unix (clock-now)))))

  (methods

    ;; ── tick ─────────────────────────────────────────────────────────────
    ;; Idempotent. Called by the scheduler thread once per interval-sec;
    ;; also callable directly (for tests / REPL).
    ((tick)
     (call-with-values do-tick
       (lambda (desired now)
         (bcom (with-state local-refs now desired) 'ok))))

    ;; ── force-tick ───────────────────────────────────────────────────────
    ;; Same as 'tick but explicit name for REPL/operator use.
    ((force-tick)
     (call-with-values do-tick
       (lambda (desired now)
         (bcom (with-state local-refs now desired) 'ok))))

    ;; ── register-local-ref ───────────────────────────────────────────────
    ;; Gateway boot calls this for every restored scope (alist returned
    ;; by restore-all-scopes!). The cached ref lets the tick body do a
    ;; cheap `admit-commune` instead of the remote-sturdyref variant.
    ((register-local-ref aid ref)
     (bcom (with-state (hashmap-set local-refs aid ref)
                       last-tick last-orphans)
           'ok))

    ;; ── status ───────────────────────────────────────────────────────────
    ;; Diagnostic snapshot for /uc-curator/status or REPL inspection.
    ((status)
     `((interval-sec  . ,interval-sec)
       (last-tick     . ,last-tick)
       (last-orphans  . ,last-orphans)
       (known-refs    . ,(length (hashmap-keys local-refs)))))))

(define* (spawn-uc-curator uc-ref scope-graph gov-cap
                           #:key
                           (interval-sec (uc-curator-default-interval-sec))
                           (start-ticker? #t)
                           (vat #f))
  "Spawn ^uc-curator + (when START-TICKER?) a Scheme thread that
   pushes (<- curator 'tick) every INTERVAL-SEC. Returns the curator
   ref. The ticker thread holds a weak-ish reference via the curator
   ref alone; stop it by exiting the host process (no clean stop API
   for v1 — curator lifetime = gateway lifetime).

   VAT must be the vat that owns CURATOR. `<-` from a bare thread
   without a vat context fails the syscaller transactormap merge
   check on every send; wrapping in `(with-vat vat ...)` gives the
   send a proper turn boundary. Callers that already are inside
   `(with-vat gw ...)` can omit VAT and we capture it via
   parameterize-style fallback (errors if neither is set).

   In tests where you'd rather drive ticks manually, pass
   `#:start-ticker? #f`."
  (let ((curator (spawn ^uc-curator uc-ref scope-graph gov-cap interval-sec)))
    (when start-ticker?
      (unless vat
        (error "spawn-uc-curator: #:vat is required when start-ticker? is #t"))
      (call-with-new-thread
       (lambda ()
         (let loop ()
           (sleep interval-sec)
           (catch #t
             (lambda ()
               (with-vat vat (<- curator 'tick)))
             (lambda args
               (log* "ticker push failed: ~a" args)))
           (loop)))))
    curator))
