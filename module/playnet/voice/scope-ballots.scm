;;; module/playnet/voice/scope-ballots.scm — the ballot methods of a scope: the federation voice math, the direct and scoped ballots, the close ceremony.
;;;
;;; A fragment of the scope actor (playnet scope actor): a procedure from the
;;; actor's context to the doors it serves, composed into every scope by
;;; (playnet boot scope). `with-scope-ctx` binds the actor's fields and helpers
;;; under their own names, so each clause reads as it did inside the actor
;;; (docs/planning/codebase-layout.md §5).

(define-module (playnet voice scope-ballots)
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri first-person predicates)
  #:use-module (playnet keri said-portable)
  #:use-module (playnet pools credit-fold)
  #:use-module (playnet vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet governance ballot)
  #:use-module ((playnet personhood attestation-ceremony) #:select (^attestation-ceremony register-attestation-ceremony!))
  #:use-module (goblins)
  #:use-module (playnet scope actor)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (scope-ballots-doors
            open-recomposition-ballot))

(define (scope-ballots-doors ctx)
  (with-scope-ctx ctx
    (declared-doors scope

    ;; --- Federation voice math ---
    ((commune-weight commune-id scope-roots)
     (let ((commune (hashmap-ref members commune-id #f)))
       (cond
         ((not commune) 0)
         (else
          (let* ((scope ($ commune 'scope-root))
                 (local ($ ($ scope 'account-store) 'total-social-svc))
                 (total (global-total-social-svc scope-roots)))
            (if (= 0 total) 0 (/ local total)))))))

    ;; --- Mandated commune-stance: a commune's delegate casts on its behalf ---
    ((receive-commune-stance delegate-cap commune-id proposal-id stance-bundle)
     (unless (memq kind '(federation universal-commune))
       (error "receive-commune-stance: scope is not a federation/UC" name kind))
     (unless ($ delegate-sealed? delegate-cap)
       (error "receive-commune-stance requires delegate-authority"
              name commune-id))
     (unless (hashmap-ref members commune-id #f)
       (error "Unknown commune" commune-id))
     (let* ((per-proposal (hashmap-ref (or commune-stances (hashmap))
                                       proposal-id (hashmap)))
            (updated (hashmap-set per-proposal commune-id stance-bundle))
            (new-cs  (hashmap-set (or commune-stances (hashmap))
                                  proposal-id updated)))
       (bcom (rebuild members excluded ballots new-cs
                member-sturdyrefs mycapn-ref acdc-store lineage))))

    ((commune-stances-for proposal-id)
     (hashmap-ref (or commune-stances (hashmap)) proposal-id (hashmap)))

    ;; --- Mandated tally with commune weights ---
    ((tally-mandated proposal-id scope-roots)
     (let ((per-proposal (hashmap-ref (or commune-stances (hashmap))
                                      proposal-id (hashmap)))
           (tally (hashmap))
           (total-weight 0))
       (define (add-tally pos w)
         (set! tally (hashmap-set tally pos
                                  (+ w (hashmap-ref tally pos 0)))))
       (let ((fed-total (global-total-social-svc scope-roots)))
         (hashmap-fold
           (lambda (commune-id stance-bundle _)
             (let* ((commune (hashmap-ref members commune-id #f))
                    (scope   (and commune ($ commune 'scope-root)))
                    (local   (and scope
                                  ($ ($ scope 'account-store) 'total-social-svc)))
                    (weight  (if (and local (not (= 0 fed-total)))
                                 (* local (/ 1 fed-total))
                                 0))
                    (cleartext (if (pair? stance-bundle) (car stance-bundle)
                                   stance-bundle))
                    (position (and (pair? cleartext) (caddr cleartext))))
               (when position
                 (set! total-weight (+ total-weight weight))
                 (add-tally position weight))))
           #f per-proposal))
       (list (cons 'tally tally)
             (cons 'total-mandated-weight total-weight)
             (cons 'mode 'mandated))))

    ;; --- Direct federation ballot lifecycle ---
    ((open-direct-ballot gov-cap proposal-id description
                          citizen-registry citizen-voice-data)
     (unless ($ gov-sealed? gov-cap)
       (error "open-direct-ballot requires gov-authority" name proposal-id))
     (let ((b (open-ballot 'policy proposal-id 'federation description
                           citizen-registry citizen-voice-data
                           #:close-authority gov-sealed?)))
       (bcom (rebuild members excluded
                (hashmap-set ballots proposal-id b)
                commune-stances
                member-sturdyrefs mycapn-ref acdc-store lineage)
             b)))

    ((open-ballot-for-scope gov-cap proposal-id description
                             citizen-registry citizen-voice-data)
     (unless (eq? kind 'commune)
       (error "open-ballot-for-scope: scope is not a commune" name kind))
     (unless ($ gov-sealed? gov-cap)
       (error "open-ballot-for-scope requires gov-authority" name proposal-id))
     (let ((b (open-ballot 'policy proposal-id (list 'scope name) description
                           citizen-registry citizen-voice-data
                           #:close-authority gov-sealed?)))
       (bcom (rebuild members excluded
                (hashmap-set ballots proposal-id b)
                commune-stances
                member-sturdyrefs mycapn-ref acdc-store lineage)
             b)))

    ;; Close a ballot held by this scope (gov-gated). A single gov-cap
    ;; holder closing a live ballot unilaterally — early, before other
    ;; members cast — decides its outcome alone; open-close-ceremony below
    ;; is the k-of-n alternative that removes that single point.
    ((close-ballot gov-cap proposal-id)
     (unless ($ gov-sealed? gov-cap)
       (error "close-ballot requires gov-authority" name proposal-id))
     (let ((b (hashmap-ref ballots proposal-id #f)))
       (unless b (error "Unknown ballot in this scope" proposal-id))
       ($ b 'close gov-cap)))

    ;; k-of-n co-signed close: the SAME ^attestation-ceremony enrollment and
    ;; witnessed work-events already use (personhood/attestation-ceremony.scm), with
    ;; this commune's own may-govern? as ELIGIBLE? and the actual close as
    ;; ISSUE!. Opening the ceremony is gov-cap-gated and procedural — low-
    ;; stakes, the same as proposing a ballot at all — but nobody may CLOSE
    ;; it until THRESHOLD-K distinct eligible members have each signed the
    ;; ceremony's own statement-said and someone calls its 'finalize. That
    ;; is the fix: closing now takes k independent signatures, never one.
    ((open-close-ceremony gov-cap proposal-id threshold-k)
     (require-gov-cap! gov-sealed? gov-cap "open-close-ceremony" name)
     (let ((b (hashmap-ref ballots proposal-id #f)))
       (unless b (error "Unknown ballot in this scope" proposal-id))
       (let* ((statement-said (string-append "close-ballot:" scope-aid ":" proposal-id))
              (ceremony (spawn ^attestation-ceremony 'collecting statement-said threshold-k
                              (lambda (aid) (may-govern? kind scope-aid acdc-store aid members))
                              (lambda (attestations) ($ b 'close gov-cap))
                              '() #f)))
         (register-attestation-ceremony! statement-said ceremony)
         ceremony)))

    ;; Filter voice-data to remove excluded members (commune-only)
    ((filter-excluded voice-data)
     (unless (eq? kind 'commune)
       (error "filter-excluded: scope is not a commune" name kind))
     (hashmap-fold
       (lambda (cid data acc)
         (if (and excluded (hashmap-ref excluded cid #f))
             acc
             (hashmap-set acc cid data)))
       (hashmap) voice-data)))))


(define* (open-recomposition-ballot scope-ref proposal-type proposal-spec
                                    description
                                    citizen-registry citizen-voice-data
                                    #:key
                                    (credential-check (lambda (_aid) #t))
                                    (close-authority #f))
  "Open a labor-proportional ballot on a structural question.

   PROPOSAL-TYPE: 'admit-commune | 'merge-with | 'split |
                  'rejoin-federation
   PROPOSAL-SPEC: canonical equal?-comparable form (see scope.scm method bodies)
   DESCRIPTION:   human-readable summary
   CITIZEN-REGISTRY: hashmap citizen-id → sealed?-actor
   CITIZEN-VOICE-DATA: hashmap citizen-id → (voice-share . delegation-map-ref)
   CLOSE-AUTHORITY: optional sealed?-actor required to close

   Returns the spawned ^ballot. Caller orchestrates votes, close,
   ballot-snapshot ACDC, ratification ACDC, and recomposition method
   invocation with `'ratification SAID`."
  (let ((proposal-id
         (string-append "recomp:"
                        (symbol->string proposal-type)
                        ":"
                        (canonical-string proposal-spec))))
    (open-ballot 'recomposition proposal-id
                 (list 'scope ($ scope-ref 'name))
                 description
                 citizen-registry
                 citizen-voice-data
                 #:credential-check credential-check
                 #:close-authority close-authority)))
