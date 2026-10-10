;;; module/playnet/doors/federation.scm — the federation doors of the governance service: a commune admitted, a scope's self-declarations, credentials issued and revoked
;;;
;;; A fragment of the governance service (playnet doors governance): a procedure
;;; from the actor's context to the doors it serves, composed into the service by
;;; (playnet boot governance). `with-governance-ctx` binds the actor's arguments,
;;; cells and shared helpers under their own names, so each clause reads as it did
;;; inside the actor (docs/planning/codebase-layout.md §5).

(define-module (playnet doors federation)
  #:use-module (srfi srfi-1)
  #:use-module (playnet credentials declarations)
  #:use-module (playnet keri acdc)
  #:use-module ((playnet personhood enrollment)
                #:select (spawn-enrollment-ceremony enroll-ceremony-for-candidate
                          enroll-asks expire-stale-enrollments! *self-request-evidence*
                          rehydrate-enrollment-ceremonies!))
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:use-module (playnet doors governance)
  #:use-module ((playnet protocol dispatch) #:select (declared-doors))
  #:export (governance-federation-doors))

(define (governance-federation-doors ctx)
  (with-governance-ctx ctx
    ;; aid → the KEL this gateway holds for it, wire-shaped, or #f
    ;; a scope's self-declaration, minted for it by a governor (MAKE : → cred)
    (define (%scope-declare! identity-key make)
      (cond
        ((not acdc-store) (list 'error "acdc-store not configured on this gateway"))
        ((not (governor? identity-key)) (list 'error "a scope's declaration is spoken by a governor"))
        (else (catch #t
                (lambda ()
                  (let ((cred (make)))
                    ($ acdc-store 'issue-idempotent cred)
                    (list 'ok (cred-said cred))))
                (lambda (k . args) (list 'error (format #f "~a ~s" k args)))))))

    (declared-doors governance

      ;; Cross-gateway UC merge proposals (scope-formation decisions). The
      ;; gateway sets the registry ref; we surface its pending list.
      ((set-uc-proposals! ref) (set! uc-proposals-ref ref) 'ok)

      ((list-uc-proposals)
       (if uc-proposals-ref
           (map (lambda (e) (list (car e) (cadr e))) ($ uc-proposals-ref 'pending))
           '()))

      ;; --- Voice events: ballot ('binary yes/no) and expression
      ;; ('fractional distribution). Unified surface — kind dispatches.
      ;;
      ;;   open  : governor opens an event of given kind in given domain
      ;;   cast  : anyone authenticated casts; voice-weight from snapshot
      ;;   close : governor closes; ballots get tally-result ACDC
      ;;   get-result : live or closed result
      ;;
      ;; KIND: 'ballot  → arg/cast is a position symbol ('yes | 'no | …);
      ;;                  rest = ()
      ;;       'expression → arg/cast is a distribution hashmap;
      ;;                     rest = (target-ids) — list of target strings

      ;; Issue an ACDC as this gateway's store: a governor act, gated on
      ;; the same founders.txt `governor?` every other admin door here
      ;; gates on. CRED has already been through doors/lobby.scm's own
      ;; issuer==caller check — this door is the only path that reaches
      ;; the store, so a caller without governor standing gets refused
      ;; before ACDC-STORE ever sees the credential. The reply CHAINS
      ;; acdc-store's own — its `issue` resolves to the SAID on success,
      ;; and a rejection (a SAID collision) propagates as one, the same
      ;; shape every other governance-svc→acdc-store door here already
      ;; returns unwrapped (present-bundle, socialize-signed, …) — no
      ;; local catch, so the reply is never claimed before the write
      ;; that backs it has actually landed.
      ((issue-credential identity-key cred)
       (cond
         ((not acdc-store) (list 'error "acdc-store not configured on this gateway"))
         ((not (governor? identity-key)) (list 'error "issuer must hold governor standing"))
         (else (<- acdc-store 'issue cred))))

      ;; Revoke an ACDC by SAID — same governor gate, no issuer check:
      ;; governance revokes by policy, not by authorship. acdc-store's
      ;; `revoke` resolves to no useful value on success (a rebind, not a
      ;; reply) and raises on an unknown SAID, so this turns the settled
      ;; promise into 'ok — never claiming success before the rebind has
      ;; actually happened, the same bug this replaces.
      ((revoke-credential identity-key said)
       (cond
         ((not acdc-store) (list 'error "acdc-store not configured on this gateway"))
         ((not (governor? identity-key)) (list 'error "revoker must hold governor standing"))
         (else (on (<- acdc-store 'revoke said)
                   (lambda (_) 'ok)
                   #:catch (lambda (e) (list 'error (format #f "revoke error: ~a" e)))
                   #:promise? #t))))

      ;; ── A scope's own word: three self-declarations on the rail ─────────
      ;; A span (where a resource's pool stands), hosting willingness (what a
      ;; scope will host, with a ceiling) and a regime claim (whether a
      ;; domain's statistics are licensed) are performatives issuer = holder
      ;; = the scope, spoken for it by a governor — the gate issue-credential
      ;; holds. Each is read where it lies (socialization consented-span-of,
      ;; live-willingness-of; recipe-standing live-regime-of): a lapsed or
      ;; revoked one stops contributing, with no further event. Replies
      ;; (ok said) or an error.
      ((declare-span identity-key scope-aid resource-id place . opt)
       (%scope-declare! identity-key
                        (lambda () (make-span-declaration-credential
                                    scope-aid resource-id place
                                    #:valid-until (and (pair? opt) (car opt))))))

      ((declare-hosting identity-key scope-aid resource-spec ceiling . opt)
       (%scope-declare! identity-key
                        (lambda () (make-hosting-willingness-credential
                                    scope-aid resource-spec (exact->inexact ceiling)
                                    #:valid-until (and (pair? opt) (car opt))))))

      ((claim-regime identity-key scope-aid domain-spec tails process . opt)
       (%scope-declare! identity-key
                        (lambda () (make-regime-claim-credential
                                    scope-aid domain-spec (%as-symbol tails) (%as-symbol process)
                                    #:valid-until (and (pair? opt) (car opt))))))

      ;; ── A federation admits a commune ────────────────────────────────────────
      ;; The federation's act, spoken by a governor of this gateway (the gate
      ;; every admin door here holds) and then by the scope's own ladder: the
      ;; federation mints the governor its gov-cap only if it recognises them
      ;; (scope.scm may-govern?), and its governance-policy may require the
      ;; commune's consent as a ratification (RATIFICATION, a SAID, optional).
      ;; The commune enters under its AID with the sturdyref its peer answers
      ;; at; what crosses it is the commune's to tell (a census), not the
      ;; admission's. Replies ok or an error.
      ((admit-commune identity-key federation-aid commune-aid sturdyref-uri . opt)
       (cond
         ((not (governor? identity-key)) (list 'error "a federation admits a commune through a governor"))
         (else
          (let ((fed (scope-for federation-aid)))
            (if (not fed)
                (list 'error "this gateway holds no federation by that AID")
                (on (<- fed 'mint-gov-cap identity-key)
                    (lambda (cap)
                      (on (apply <- fed 'admit-commune-remote cap commune-aid commune-aid sturdyref-uri
                                 (if (and (pair? opt) (car opt)) (list 'ratification (car opt)) '()))
                          (lambda (_) 'ok)
                          #:catch (lambda (e) (list 'error (format #f "admit-commune: ~a" e)))
                          #:promise? #t))
                    #:catch (lambda (e) (list 'error (format #f "admit-commune: ~a" e)))
                    #:promise? #t))))))

      ;; ── Admitting a legal body — the commune issues its body credential ────
      ;; The same forward as accept-socialization: the commune's own gov-cap,
      ;; minted for IDENTITY-KEY (may-govern? decides), then the scope's
      ;; admit-body (personhood/issuance.scm). OPTS, positional after the
      ;; body AID: kind jurisdiction legal-ids quorum.
      ((admit-body identity-key commune-aid body-aid . opts)
       (let ((sc (scope-for commune-aid)))
         (if (not sc)
             (list 'error "admit-body: no scope reachable here for that commune")
             (catch #t
               (lambda ()
                 (list 'ok (apply $ sc 'admit-body ($ sc 'mint-gov-cap identity-key) body-aid opts)))
               (lambda (key . args) (list 'error (format #f "admit-body failed: ~a" args))))))))))
