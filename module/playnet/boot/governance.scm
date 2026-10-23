;;; module/playnet/boot/governance.scm — the governance service composed from its fragments.
;;;
;;; The composition root's word on what the governance service is: the actor
;;; (playnet doors governance) and the six fragments of
;;; docs/planning/codebase-layout.md §5, set once per process so every spawn
;;; composes the same service. Import this module wherever the service is
;;; spawned — the gateway, the test suites — and (playnet doors governance)
;;; where only the store readers or the context are read. The gateway's own
;;; spawn, with the readers it hands the service, is here too.

(define-module (playnet boot governance)
  #:use-module ((playnet boot site) #:select (data-path founders log!))
  #:use-module ((playnet federation scope-graph) #:select (current-scope-graph in-graph-vat))
  #:use-module ((playnet identity oobi-host) #:select (oobi-write-entry-to-dir! read-oobi-entry-from-dir))
  #:use-module ((playnet identity seat) #:select (verify-carried-kel))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:use-module (playnet doors governance)
  #:use-module ((playnet doors personhood) #:select (governance-personhood-doors))
  #:use-module ((playnet doors delegation) #:select (governance-delegation-doors))
  #:use-module ((playnet doors machine) #:select (governance-machine-doors *machine-authz*))
  #:use-module ((playnet delegates) #:select (make-opa-delegate %env-transport))
  #:use-module ((playnet doors economy) #:select (governance-economy-doors))
  #:use-module ((playnet doors federation) #:select (governance-federation-doors))
  #:re-export (fp-wire->cred ^governance-service spawn-governance-service
               governance-service-env plan-part-hands-of contrary-observations-of
               contrary-readings-of)
  #:export (spawn-gateway-governance!))

(set-governance-fragments!
 (list governance-personhood-doors governance-delegation-doors
       governance-economy-doors governance-federation-doors
       governance-machine-doors))

;; ── The gateway's spawn ────────────────────────────────────────
;; Lives in the planner vat (same vat as scope-root and ballot-store).
;; Credentials are checked against the live KERIA via the
;; (playnet keri inception) predicates. If KERIA isn't connected,
;; the predicates return #f and the service rejects writes — open
;; reads (get-tally, list-proposals) still work.
(define* (spawn-gateway-governance! #:key gateway-vat store)
  "The governance service spawned for this gateway: no scope universe or
ballot store in the machine build (no scopes stand), the founders as
governors, the scope graph as its scope-of, the oobi-host directory as
where a carried key log lands, STORE as its credential store."
  ;; the policy engine for the commune acts: PLAYNET_OPA_URL names a
  ;; deployed OPA, the machine doors consult playnet/doors/machine on every
  ;; settle/payout — an answered deny refuses even a governor. Unset, the
  ;; local gov-cap gate alone decides.
  (let ((opa-t (%env-transport "PLAYNET_OPA_URL")))
    (when opa-t
      (*machine-authz* (make-opa-delegate opa-t))))
  (let ((governance-svc
         (with-vat gateway-vat
           (spawn-governance-service
            ;; no standing scopes: the federation universe is empty until
            ;; admit-commune hydrates the scope graph, and no ballot store
            ;; exists — sortition and disputes draw on the service's own
            ;; citizen registry instead.
            '() #f
            ;; founders are the bootstrap governors (can verify newcomers,
            ;; fan-out-capped). PLAYNET_TEST_OPEN_GOVERNANCE is a TEST-ONLY
            ;; affordance (never set in production): it makes any
            ;; authenticated AID a governor so an e2e can open a ballot to
            ;; then exercise the real signed cast + verify path (see
            ;; tests/ux/cast-ux.mjs). It gates only ballot open/close,
            ;; never the cast signature check.
            #:governor?  (let ((open-gov? (and (getenv "PLAYNET_TEST_OPEN_GOVERNANCE")
                                               (not (string=? (getenv "PLAYNET_TEST_OPEN_GOVERNANCE") "0")))))
                           (lambda (aid) (or open-gov?
                                             (member aid (founders)))))
            ;; scope-of: the commune named by an act → its ^scope, through
            ;; the scope graph. Read lazily and cached per AID; a commune
            ;; the graph does not hold answers #f and the act degrades as
            ;; with no key.
            #:scope-of
            (let ((cache (make-hash-table)))
              (lambda (aid)
                (or (hash-ref cache aid #f)
                    (let* ((g (current-scope-graph))
                           (ref (and g (catch #t
                                         (lambda () (in-graph-vat (lambda () ($ g 'find-ref aid))))
                                         (lambda _ #f))))
                           ;; called from inside a vat turn, the graph hop
                           ;; answers a PROMISE, not a ref — only a ref that
                           ;; answers a near call is one the doors can use
                           (live (and ref
                                      (false-if-exception
                                       (equal? aid ($ ref 'scope-aid)))
                                      ref)))
                      (when live (hash-set! cache aid live))
                      live))))
            ;; a carried KEY LOG lands here: verified as signup witnesses a
            ;; log (signup-agent verify-carried-kel), written straight into
            ;; the oobi-host dir both key resolvers read — so the voucher's
            ;; signature on a presented bundle verifies at once, with no
            ;; actor in the way. kel-of is the read twin: the log this
            ;; gateway holds for an AID, wire-shaped, for the bundle a
            ;; person carries away.
            #:kel-landing
            (let ((oobi-dir (data-path "oobi-host")))
              (lambda (aid icp sigs rots)
                (call-with-values
                    (lambda () (verify-carried-kel aid icp sigs rots
                                                   (read-oobi-entry-from-dir oobi-dir aid)))
                  (lambda (v entry)
                    (if (eq? v #t)
                        (begin (oobi-write-entry-to-dir! oobi-dir entry) #t)
                        v)))))
            #:kel-of
            (let ((oobi-dir (data-path "oobi-host")))
              (lambda (aid)
                (let ((e (read-oobi-entry-from-dir oobi-dir aid)))
                  (and e
                       `(("icp" . ,(assq-ref e 'icp))
                         ("sigs" . ,(assq-ref e 'sigs))
                         ("rotations"
                          . ,(list->vector
                              (map (lambda (r) `(("rot" . ,(car r)) ("sigs" . ,(cdr r))))
                                   (or (assq-ref e 'rotations) '())))))))))
            #:acdc-store store))))
    (log! "  [gateway] governance service ready~%")
    governance-svc))
