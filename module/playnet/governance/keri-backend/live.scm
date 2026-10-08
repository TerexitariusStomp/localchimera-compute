;;; module/playnet/governance/keri-backend/live.scm — live KERIA backend
;;;
;;; Wraps the real KERIA bridge: every call hits the agent (libsodium +
;;; HTTP). Imported separately so unit tests using stub-keri-backend
;;; never load libsodium.

(define-module (playnet governance keri-backend live)
  #:use-module (playnet keri bridge)
  #:use-module (playnet keri inception)
  #:use-module ((playnet keri receiptor) #:select (parse-witness-env))
  #:use-module (srfi srfi-11)
  #:use-module (ice-9 format)
  #:export (live-keri-backend))

;; Resolve the pool's witness OOBIs in KERIA once per process — KERIA
;; needs each witness's loc-scheme in its db before it can collect
;; receipts for the KERIA-managed AIDs it incepts with that pool.
(define %pool-resolved? #f)
(define (resolve-pool-in-keria! oobis)
  (unless (or %pool-resolved? (null? oobis))
    (for-each
     (lambda (oobi)
       (catch #t
         (lambda ()
           (let ((op (keri-resolve-oobi oobi)))
             (when (and (pair? op) (assoc-ref op "name"))
               (keri-wait-operation op #:timeout 30))))
         (lambda (key . args)
           (format (current-error-port)
                   "[keri-backend] witness OOBI resolve failed ~a: ~a ~a\n"
                   oobi key args))))
     oobis)
    (set! %pool-resolved? #t)))

(define* (live-keri-backend #:key
                            (witnesses #f)
                            (group-name "playnet-scope-group"))
  "Build a keri-backend alist that delegates to live KERIA.

   WITNESSES — explicit witness AID list, or #f to use the deployment
   witness pool from the environment (PLAYNET_WITNESS_AIDS /
   PLAYNET_WITNESS_OOBIS / PLAYNET_WITNESS_TOAD — see
   `parse-witness-env`). Unset env = witnessless, the dev default.
   GROUP-NAME — local name to use when creating new multi-sig groups.

   Witnessing policy (docs/keri/IMPLEMENTATION.md §2): witness the
   AIDs that ISSUE TRUST or NEED A MAILBOX — scope/governance AIDs and
   KERIA-managed recipient identities. Browser personas stay toad=0
   (locally-built; their inbound delivery rides the gateway session,
   and a bt>0 KEL without receipts is escrowed by resolvers).

   Each call to `create-group` reuses GROUP-NAME; the operator can
   override per-call by binding a fresh backend with a different name
   (one ceremony at a time)."
  (let*-values (((env-aids env-oobis env-toad) (parse-witness-env)))
    (let ((pool-aids  (or witnesses env-aids))
          (pool-oobis env-oobis)
          (pool-toad  env-toad))
      `((create-scope-aid
         . ,(lambda* (#:key (anchors '()) (bran #f)
                      (witnesses* pool-aids) (toad pool-toad)
                      (kel-store #f))
              ;; Autonomous-signer scope: single-controller AID, keypair +
              ;; bran returned to caller. Bran is the durable secret —
              ;; persist via Shamir share-holders or vault-on-disk; the actor
              ;; itself never holds it. See democracy-on-keri.md §4.1 +
              ;; bran-custody.scm. When KEL-STORE is supplied, the signed icp
              ;; body lands in the durable KEL store too.
              ;;
              ;; PLAYNET_PUBLIC_URL (the gateway's public base URL, where
              ;; serve-static answers /oobi/{aid}) turns on OKEA endpoint
              ;; replies in the icp body so the scope's OOBI advertises its
              ;; service endpoint — prerequisite for witness receipting.
              ;;
              ;; Scope AIDs are LOCALLY-BUILT, so witnessing rides the
              ;; Scheme receiptor: receipts are collected from the pool's
              ;; HTTP /receipts endpoints at mint time and served after
              ;; the KEL (governance-create-scope-aid! raises below toad
              ;; rather than minting an escrow-doomed inception).
              (governance-create-scope-aid! #:anchors anchors
                                            #:bran bran
                                            #:witnesses (or witnesses* '())
                                            #:toad toad
                                            #:witness-oobis pool-oobis
                                            #:kel-store kel-store
                                            #:endpoint-url
                                            (getenv "PLAYNET_PUBLIC_URL"))))
        (create-group . ,(lambda (member-aid-names threshold)
                           (resolve-pool-in-keria! pool-oobis)
                           (governance-create-group! member-aid-names
                                                     #:group-name group-name
                                                     #:signing-threshold threshold
                                                     #:witnesses pool-aids)))
        (rotate-keys  . ,(lambda (aid-name . kwargs)
                           (apply keri-rotate-keys aid-name kwargs)))
        ;; KERIA-managed AIDs (umbrella governance identity, recipient
        ;; identities needing mailboxes): KERIA's own Receiptor collects
        ;; receipts, so witnessing is just toad+wits at inception —
        ;; default them to the pool unless the caller overrides.
        (create-aid   . ,(lambda (name . kwargs)
                           (when (pair? pool-aids)
                             (resolve-pool-in-keria! pool-oobis))
                           (apply keri-create-aid name
                                  (if (or (null? pool-aids)
                                          (memq #:witnesses kwargs))
                                      kwargs
                                      (append (list #:toad pool-toad
                                                    #:witnesses pool-aids)
                                              kwargs)))))))))
