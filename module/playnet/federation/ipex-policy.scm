;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/federation/ipex-policy.scm — schema-keyed policy for inbound IPEX grants
;;;
;;; The grant handler (`handle-ipex-grant` in notifications.scm) consults
;;; this table on every inbound /exn/ipex/grant notification. Three things
;;; per schema:
;;;
;;;   expected-issuer?   (issuer-aid issuee-aid claims) → bool
;;;       Permission check. If #f, the grant is dropped (logged, not retried).
;;;       For security-critical schemas (federation-membership,
;;;       recomposition-ratification) this verifies the issuer is a scope
;;;       we already know about — i.e. the grant didn't come out of nowhere.
;;;
;;;   admit-into         (issuee-aid) → scope-ref-or-#f
;;;       Resolves the local scope whose acdc-store should receive a copy
;;;       of the credential. #f means "we admit but don't mirror locally"
;;;       (KERIA already holds it).
;;;
;;;   post-admit-hook    (cred scope-graph) → any
;;;       Side-effect after successful admit. e.g. federation-membership
;;;       fires `note-parent-link` so the scope-graph and UC curator see
;;;       the new edge without another HTTP poll. #f for schemas with no
;;;       reactive consequence.
;;;
;;; New schemas are added either by extending `%default-grant-policy` below
;;; (for built-ins) or via `(register-grant-policy! schema record)` at
;;; runtime (for app-level extensions).

(define-module (playnet federation ipex-policy)
  #:use-module (goblins)
  #:use-module (playnet credentials membership)
  #:use-module (playnet credentials registry)
  #:use-module (playnet credentials voting)
  #:use-module (playnet keri acdc)
  #:use-module (playnet federation scope-graph)
  #:use-module (playnet federation sturdyref-credential)
  #:use-module ((playnet keri first-person credentials)
                #:select (*schema-playnet-body* *schema-playnet-body-role*))
  #:use-module ((playnet federation pending-recompositions)
                #:select (current-pending-recompositions))
  #:use-module ((playnet keri bridge) #:select (keri-get-keystate))
  #:use-module (playnet utils boot-cell)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:re-export (current-graph-vat in-graph-vat)
  #:export (make-grant-policy
            grant-policy?
            grant-policy-expected-issuer?
            grant-policy-admit-into
            grant-policy-post-admit-hook
            lookup-grant-policy
            register-grant-policy!
            %grant-policy-table
            install-default-grant-policies!
            issuer-has-resolvable-kel?
            body-issuer-ok?
            body-role-issuer-ok?
            current-credential-finder
            current-credential-finder-by-said
            current-root-chain-check))

;; ─────────────────────────────────────────────────────────────────────────
;; Policy record
;; ─────────────────────────────────────────────────────────────────────────

(define-record-type <grant-policy>
  (make-grant-policy expected-issuer? admit-into post-admit-hook)
  grant-policy?
  (expected-issuer? grant-policy-expected-issuer?)
  (admit-into       grant-policy-admit-into)
  (post-admit-hook  grant-policy-post-admit-hook))

;; ─────────────────────────────────────────────────────────────────────────
;; Table (mutable so app code can extend at runtime)
;; ─────────────────────────────────────────────────────────────────────────

(define %grant-policy-table '())   ; alist: schema-string → <grant-policy>

(define (lookup-grant-policy schema)
  "Return the <grant-policy> for SCHEMA, or #f if none registered."
  (let ((cell (assoc schema %grant-policy-table)))
    (and cell (cdr cell))))

(define (register-grant-policy! schema policy)
  "Register POLICY (a <grant-policy>) for SCHEMA. Idempotent — replaces
   any existing entry for the same schema."
  (set! %grant-policy-table
        (cons (cons schema policy)
              (filter (lambda (p) (not (equal? schema (car p))))
                      %grant-policy-table))))

;; ─────────────────────────────────────────────────────────────────────────
;; Default predicates
;; ─────────────────────────────────────────────────────────────────────────
;;
;; The vat plumbing — current-graph-vat / in-graph-vat — lives next to
;; current-scope-graph in (playnet federation scope-graph) and is
;; re-exported here for handlers that consume both.

(define (always-accept _i _e _c) #t)

;; ─────────────────────────────────────────────────────────────────────────
;; Pull-flow: credential lookup hook
;; ─────────────────────────────────────────────────────────────────────────
;;
;; The `apply` handler in notifications.scm consults this parameter to
;; search local stores for a credential matching the requester's
;; schema. The gateway binds it at boot to a closure that searches
;; gov-acdc-store + each known scope's store. Unbound → apply spurns
;; everything (sensible default; tests/non-gateway processes don't
;; serve pull requests).
;;
;; Signature: (lambda (schema-said requester-aid) → cred-alist-or-#f)
;;
;; A BOOT CELL (utils/boot-cell.scm), the same shape (and for the same
;; reason) as current-scope-graph: the reader is the IPEX handler on
;; the notification-poller FIBER, which never sees a parameter set on
;; the gateway's boot thread — the finder was silently #f there and
;; every pull request spurned.

(define current-credential-finder (make-boot-cell))

;; The agree-side twin: (lambda (cred-said) → cred-alist-or-#f). The
;; `agree` handler grants the credential the peer agreed to, and for a
;; LOCALLY-issued governance credential — exactly what the finder above
;; offers out of the local stores — KERIA's /credentials export has
;; nothing (its registry never held it), so the grant needs the same
;; local lookup keyed by SAID. Unbound → the agree handler is
;; KERIA-export-only, the pre-existing behaviour.
(define current-credential-finder-by-said (make-boot-cell))

;; The root check for inbound body credentials: (lambda (issuer-aid) → bool),
;; bound by the gateway to `ecosystem-chains-to-any-root?` over its
;; governance store and FP root. A boot cell for the reason the finders
;; above are. Unbound → an issuer must be a scope this gateway hosts.
(define current-root-chain-check (make-boot-cell))

(define (body-issuer-ok? issuer _issuee _claims)
  "A body credential's issuer is the scope that admitted the body: any AID
   that chains to a root (the bound check), else a scope hosted here."
  (let ((chains? (current-root-chain-check)))
    (if chains?
        (and (catch #t (lambda () (chains? issuer)) (lambda _ #f)) #t)
        (issuer-is-known-scope? issuer #f #f))))

(define (body-role-issuer-ok? issuer _issuee _claims)
  "A body-role credential's issuer is the body: the holder of a body
   credential held in a local store (the bound credential finder, which
   answers by schema and holder). Unbound → refused."
  (let ((finder (current-credential-finder)))
    (and finder
         (let ((body (catch #t (lambda () (finder *schema-playnet-body* issuer))
                       (lambda _ #f))))
           (and body (equal? issuer (cred-holder body)) #t)))))

(define (issuer-is-known-scope? issuer _issuee _claims)
  "The issuer must be a scope this gateway already knows about (any kind).
   Runs inside the graph's vat — callable from the poll fiber."
  (let ((g (current-scope-graph)))
    (and g (in-graph-vat (lambda () ($ g 'get-kind issuer))) #t)))

(define (issuer-has-resolvable-kel? issuer _issuee _claims)
  "Accept any issuer whose KEL the local KERIA can resolve. Pairs with
   KERIA's signature-verification on admit: KERIA only admits credentials
   whose Issuer-signature verifies against the issuer's current key state,
   and that key state is fetched from the same KEL we probe here. So the
   security boundary is the cryptographic verification KERIA already
   performs; this predicate is the trust policy on top — \"we'll accept
   credentials from any AID with a published KEL\" — which is the right
   stance for cross-gateway federation-membership where the issuer is
   typically a federation scope on a peer gateway, not locally known.

   Falls back to scope-graph membership when the keystate lookup fails
   (e.g. KERIA momentarily unreachable but we know this scope locally)."
  (or (catch #t
        (lambda () (keri-get-keystate issuer) #t)
        (lambda _ #f))
      (issuer-is-known-scope? issuer #f #f)))

(define (resolve-scope-store issuee)
  "Resolve the local scope ref owning ISSUEE, returning its acdc-store.
   Returns #f if no local scope holds the AID (then KERIA-only)."
  (let ((g (current-scope-graph)))
    (and g
         (in-graph-vat
          (lambda ()
            (let ((scope-ref ($ g 'find-ref issuee)))
              (and scope-ref ($ scope-ref 'acdc-store))))))))

(define (note-parent-link-hook cred g)
  "Federation-membership received: the holder gained a parent edge to the
   issuer. Update scope-graph so UC curator's next tick sees it. Wrapped
   in the graph's vat (the hook may be called from the poll fiber)."
  (when g
    (in-graph-vat
     (lambda ()
       (<- g 'note-parent-link-with-source
           (cred-holder cred) (cred-issuer cred) 'remote)))))

(define (ratification-arrived-hook cred _g)
  "Recomposition-ratification ACDC admitted from a remote ratifier
   (typically UC). Logs the arrival for operator visibility, then
   consults the current-pending-recompositions registry to fire any
   matching orchestration action that was pre-registered (task #43).

   When unbound (tests, browser, gateway pre-#43-wiring), behaves
   like the original log-only hook — backwards compatible."
  (format (current-error-port)
          "[ipex-policy] ratification arrived: said=~a issuer=~a holder=~a~%"
          (cred-said cred) (cred-issuer cred) (cred-holder cred))
  (let ((pr (current-pending-recompositions)))
    (when pr
      (in-graph-vat
       (lambda () (<- pr 'fire-matching cred))))))

;; ─────────────────────────────────────────────────────────────────────────
;; Default table
;; ─────────────────────────────────────────────────────────────────────────

(define %security-critical
  ;; Schemas where the issuer's identity governs whether the credential
  ;; is acceptable — locked to "must be a known scope on this gateway."
  ;; Federation-membership additionally fires a scope-graph hook so the
  ;; UC curator sees the new parent edge on its next tick.
  ;; federation-membership uses the broader `issuer-has-resolvable-kel?`
  ;; predicate so cross-gateway grants from peer federations get through
  ;; (the issuer is a federation we *don't* host locally but whose KEL
  ;; KERIA can fetch). recomposition-ratification and sturdyref stay
  ;; strict — those originate from scopes we should already know about.
  (list (cons *schema-playnet-federation-membership*
              (make-grant-policy issuer-has-resolvable-kel?
                                 resolve-scope-store
                                 note-parent-link-hook))
        (cons *schema-playnet-recomposition-ratification*
              (make-grant-policy issuer-is-known-scope?
                                 resolve-scope-store
                                 ratification-arrived-hook))
        (cons *schema-playnet-federation-sturdyref*
              (make-grant-policy issuer-is-known-scope?
                                 resolve-scope-store
                                 #f))
        ;; bodies: the admitting scope chains to a root; a role is the
        ;; word of a body whose credential is held here
        (cons *schema-playnet-body*
              (make-grant-policy body-issuer-ok?
                                 resolve-scope-store
                                 #f))
        (cons *schema-playnet-body-role*
              (make-grant-policy body-role-issuer-ok?
                                 resolve-scope-store
                                 #f))))

(define (install-default-grant-policies!)
  "Populate %grant-policy-table with one entry per known playnet schema.
   Safe to call multiple times; later calls overwrite earlier entries.

   Security-critical schemas (see %security-critical) get strict policies;
   every other schema in *playnet-schemas* gets a permissive default
   (always-accept, mirror-if-local, no hook). Adding a new schema to
   credentials.scm's *playnet-schemas* automatically lands here as an
   informational entry — promote to %security-critical when the issuer
   identity matters."
  (for-each (lambda (pair)
              (register-grant-policy! (car pair) (cdr pair)))
            %security-critical)
  (for-each (lambda (schema)
              (unless (assoc schema %security-critical)
                (register-grant-policy!
                 schema
                 (make-grant-policy always-accept
                                    resolve-scope-store
                                    #f))))
            *playnet-schemas*))
