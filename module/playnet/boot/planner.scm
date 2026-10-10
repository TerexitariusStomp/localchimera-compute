;;; module/playnet/boot/planner.scm — the planner service over earth, governance handed to it as readers, its gates, and the plan tick.
;;;
;;; ^planner-service lives inside the planner vat alongside the stores so its
;;; methods have synchronous near-call access. The lobby (in the gateway vat)
;;; holds a reference; the OCapN wire is the only cross-vat boundary.

(define-module (playnet boot planner)
  #:use-module ((playnet doors governance) #:select (contrary-observations-of contrary-readings-of plan-part-hands-of))
  #:use-module ((playnet boot site) #:select (log! seed-demo?))
  #:use-module ((playnet doors lobby) #:select (contacts-file-for))
  #:use-module ((playnet doors service) #:select (^planner-service plain-plan-fn scope-of-place spec-of-resource
                                                  standing-credit-uc standing-demand-node-of))
  #:use-module ((playnet economy debts) #:select (debts-owed-in-xmr open-debts-alist settle-debts!))
  #:use-module ((playnet economy recipe-standing) #:select (live-regime-of scope-standing))
  #:use-module ((playnet economy socialization) #:select (make-knows make-may-steward socialized-readers title-rights-of))
  #:use-module ((playnet keri first-person predicates) #:select (holds-any-live-phc? personhood-bootstrapped?))
  #:use-module ((playnet keys peers) #:select (known-uc-aid))
  #:use-module ((playnet knowledge recipes federation-demo) #:select (seed-fed-commune!))
  #:use-module ((playnet observation credentials) #:select (scope-acdc-store))
  #:use-module ((playnet personhood witness-relay) #:select (make-federated-witness-door))
  #:use-module ((playnet utils common) #:select (env-int))
  #:use-module (fibers)
  #:use-module ((goblins utils hashmap) #:select (hashmap))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (spawn-planner! install-planner-gates! start-plan-tick!))

(define* (spawn-planner! #:key planner-vat earth meeting-scope store)
  "The planner service in PLANNER-VAT, reading EARTH as its roster and STORE
through the governance readers. Production starts CLEAN: the founding
commune is registered by its real scope-aid (boot/communes), so the dial's
scope-list shows a real commune, never the \"org:meeting\" demo string."
  (let ((planner-service
         (with-vat planner-vat
           ;; PLAYNET_SEED_FED=granary|table seeds the founding commune as one
           ;; member of the flour federation (federation-demo.scm), opt-in:
           ;; what a gateway on the wire plans over in a two-gateway run.
           ;; Seeded once per state dir (the once-guard reads the durable
           ;; observer); defensive, because a demo seed must never be able
           ;; to abort the gateway boot.
           (let ((fed (getenv "PLAYNET_SEED_FED")))
             (when (and fed (not (string=? fed "")))
               (catch #t
                 (lambda ()
                   (when (null? ($ ($ meeting-scope 'observer) 'all-resources))
                     (seed-fed-commune! meeting-scope "fed" (string-append "commune-" fed)
                                        (string-append (string-upcase (substring fed 0 1)) (substring fed 1))
                                        (string-append "venue-" fed) 42.70 23.32
                                        (if (string=? fed "granary") 300.0 0.0))
                     (log! "  [gateway] founding commune seeded as the federation's ~a~%" fed)))
                 (lambda (k . a) (log! "  [gateway] federation seed skipped: ~a ~a~%" k a)))))
           (spawn ^planner-service
                  (hashmap)               ; local scopes-hm unused in prod — earth is the roster
                  plain-plan-fn           ; the plain solve; governance enters as readers below
                  earth                   ; ONE source of truth: the planner reads earth
                  ;; GOVERNANCE AS READERS (planner/doors/service.scm header): each
                  ;; a fact derived off the stores, handed as a reader, never
                  ;; imported. socialized-readers: the custody view, the
                  ;; demand fold (#:scope-of hands back the service's
                  ;; standing ^demand-node), the span gate's mappings (read
                  ;; at each solve: whose place a place is, what a resource
                  ;; is, who holds its rights, the UC's aid), the stamp and
                  ;; the live pool. Then the debts, the barbell's standing,
                  ;; the steward gate and the plan-part rail.
                  (append
                   (socialized-readers
                    store
                    #:scope-of (lambda (aid) (and (string? aid) (standing-demand-node-of aid)))
                    #:voice-source standing-credit-uc
                    #:consent-of (lambda ()
                                   (list #:place-scope-of scope-of-place
                                         #:spec-of spec-of-resource
                                         #:rights-of (lambda (rid) (title-rights-of store rid (known-uc-aid)))
                                         #:uc-aid (known-uc-aid))))
                   (let ((knows-reading
                          ;; how an owner knows a person: their synced contact
                          ;; book (the lobby's per-AID file) and signed vouches
                          (make-knows store
                            #:contacts-of (lambda (aid)
                                            (let ((f (contacts-file-for aid)))
                                              (if (file-exists? f)
                                                  (call-with-input-file f read)
                                                  '()))))))
                   (list
                    (cons 'debts open-debts-alist)
                    (cons 'owed debts-owed-in-xmr)
                    (cons 'settle settle-debts!)
                    (cons 'standing
                          (lambda (root aid)
                            (catch #t
                              (lambda ()
                                ;; ONE record per recipe: the solve reads its curves,
                                ;; the face (recipes.ts) its rows, yield and runs
                                (scope-standing root
                                  #:observed (contrary-observations-of store aid)
                                  ;; a scope's regime claim on a recipe's domain licenses its statistics
                                  #:regime-of (lambda (rid) (live-regime-of store rid))))
                              (lambda (k . a)
                                (log! "  [gateway] standing read skipped for ~a: ~a ~a~%" aid k a)
                                #f))))
                    ;; the steward gate: an owner's `eligible` rule on a custody
                    ;; grant — who may be assigned to work drawing on the means
                    ;; they lent — read off the grant and the owner's synced
                    ;; contact book (the lobby's per-AID file), asked by the
                    ;; planner at the doors where a person is chosen
                    (cons 'steward (make-may-steward store #:knows knows-reading))
                    ;; the same reading for a slot's own rule: how its owner
                    ;; knows the other side, asked by match-slots
                    (cons 'knows knows-reading)
                    (cons 'hands (lambda (sid) (plan-part-hands-of store sid)))
                    (cons 'observed (lambda (sid) (contrary-readings-of store sid))))))))))
    (log! "  [gateway] planner-service ready (demo-seed: ~a)~%" (seed-demo?))
    planner-service))

(define* (install-planner-gates! #:key planner-vat planner-service store governance-svc)
  "The portable personhood gate and the work-witness door on PLANNER-SERVICE,
which stays oblivious to governance: both are injected, reading STORE and
GOVERNANCE-SVC."
  ;; First-Person: install the portable personhood gate on the planner.
  ;; Provisional AIDs (no live PHC in any ecosystem) may browse but not
  ;; consume — claim / willing / journey return 'needs-personhood.
  (with-vat planner-vat
    (<- planner-service 'set-personhood-checker!
        ;; fail OPEN until the commune has any person — a fresh commune
        ;; with no PHCs can vouch no one in, so gating would deadlock.
        ;; Once bootstrapped, only verified persons pass.
        (lambda (aid)
          (or (not (personhood-bootstrapped? store))
              (holds-any-live-phc? store aid)))))
  (log! "  [gateway] First-Person personhood gate installed~%")

  ;; The WITNESS DOOR: the k-of-n work-witness ceremony, driven from the
  ;; browser through the planner service — which stays oblivious to
  ;; governance, the same injection the personhood gate uses. A scope
  ;; credentialed by install-credentialing! resolves its own store; the
  ;; gateway's shared store stands in for the rest. At quorum the
  ;; single-signer provenance credential STRENGTHENS in place to its
  ;; witnessed, multisig form.
  (with-vat planner-vat
    (<- planner-service 'set-witness-door!
        (make-federated-witness-door
         #:store-of (lambda (scope-aid)
                      (or (scope-acdc-store scope-aid) store))
         ;; a co-signature that leaves for another gateway carries the
         ;; witness's bundle — their personhood and key log — so the
         ;; origin can check a signature from someone it never saw
         #:bundle-of (lambda (aid)
                       (let ((r ($ governance-svc 'fp-my-vouches aid)))
                         (and (pair? r) (eq? 'ok (car r))
                              (string? (cdr r)) (not (string-null? (cdr r)))
                              (cdr r)))))))
  (log! "  [gateway] work-witness door installed (federated via witness relay)~%"))

;; ── the plan tick: schedules keep up with the clock ────────────────
;; The solve path itself runs on no timer, so this fiber asks the
;; planner service, every %plan-tick-sec, to re-solve what has fallen
;; behind (resolve-stale!): caches older than the tick, and scopes
;; with standing needs that have never solved — which also warms a
;; fresh gateway's snapshots before anyone opens the orb. The first
;; tick waits a full interval so boot settles. 0 turns it off.
(define (start-plan-tick! planner-vat planner-service)
  (define %plan-tick-sec (env-int "PLAYNET_PLAN_TICK_SEC" 900))
  (when (> %plan-tick-sec 0)
    (spawn-fiber
     (lambda ()
       (let loop ()
         (sleep %plan-tick-sec)
         (catch #t
           (lambda ()
             ;; ONE scope per vat turn, a breath between turns: a whole
             ;; sweep held in one turn starves every queued
             ;; scope-snapshot read behind the solves (a signed-in dial
             ;; then shows no plan at all). SEEN is the sweep's own
             ;; memory — each pass visits a scope at most once.
             (let sweep ((seen '()))
               (let* ((t0  (current-time))
                      (sid (with-vat planner-vat
                             ($ planner-service 'resolve-one-stale!
                                %plan-tick-sec seen))))
                 ;; each scope's own solve time, on the clock: the
                 ;; number the vat was held for (every read queues
                 ;; behind it), which is what a cadence question needs
                 (when sid
                   (log! "  [gateway] plan tick: ~a re-solved in ~as (~a)~%"
                         sid (- (current-time) t0)
                         (strftime "%H:%M:%S" (localtime (current-time)))))
                 (if sid (begin (sleep 1) (sweep (cons sid seen)))
                     (when (pair? seen)
                       (log! "  [gateway] plan tick: re-solved ~a scope(s)~%"
                             (length seen)))))))
           (lambda (k . a)
             (log! "  [gateway] plan tick error: ~a ~a~%" k a)))
         (loop))))
    (log! "  [gateway] plan tick running (every ~as, one scope per turn)~%" %plan-tick-sec)))
