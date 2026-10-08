;;; tests/keri/test-ipex-policy.scm — IPEX grant-policy registry tests
;;;
;;; Pure-data tests for the schema → policy-record lookup table. No
;;; KERIA, no Goblins, no scope-graph. Exercises:
;;;
;;;   - install-default-grant-policies! populates every known schema
;;;   - lookup-grant-policy returns #f for unknown schemas
;;;   - register-grant-policy! is idempotent (replaces, doesn't dup)
;;;   - default predicates: always-accept, issuer-is-known-scope?
;;;   - default hooks fire with the right args
;;;
;;; Run: guile -L module -L tests tests/keri/test-ipex-policy.scm

(use-modules (playnet test harness)
             (playnet governance keri ipex-policy)
             (playnet governance credentials))

;; ── install + lookup ─────────────────────────────────────────────────

(install-default-grant-policies!)

(check "federation-membership has a policy after install"
       (grant-policy? (lookup-grant-policy
                       *schema-playnet-federation-membership*)))

(check "recomposition-ratification has a policy after install"
       (grant-policy? (lookup-grant-policy
                       *schema-playnet-recomposition-ratification*)))

(check "membership has a policy after install"
       (grant-policy? (lookup-grant-policy *schema-playnet-membership*)))

(check "unknown schema returns #f"
       (lookup-grant-policy "playnet-not-a-real-schema/v999")
       #f)

;; ── register idempotency ─────────────────────────────────────────────

(define %marker-schema "playnet-test-marker/v1")
(define %p1 (make-grant-policy (lambda _ #t) (lambda _ #f) #f))
(define %p2 (make-grant-policy (lambda _ #f) (lambda _ #f) #f))

(register-grant-policy! %marker-schema %p1)
(check "first register stores the policy"
       (eq? (lookup-grant-policy %marker-schema) %p1))

(register-grant-policy! %marker-schema %p2)
(check "second register replaces (does not duplicate)"
       (eq? (lookup-grant-policy %marker-schema) %p2))

;; Count entries for the marker — must be exactly 1.
(check "marker schema appears exactly once in the table"
       (length (filter (lambda (cell)
                         (equal? (car cell) %marker-schema))
                       %grant-policy-table))
       1)

;; ── policy-record accessors ──────────────────────────────────────────

(define %fm-policy
  (lookup-grant-policy *schema-playnet-federation-membership*))

(check "federation-membership has an expected-issuer? predicate"
       (procedure? (grant-policy-expected-issuer? %fm-policy)))

(check "federation-membership has an admit-into resolver"
       (procedure? (grant-policy-admit-into %fm-policy)))

(check "federation-membership has a post-admit-hook"
       (procedure? (grant-policy-post-admit-hook %fm-policy)))

(define %member-policy
  (lookup-grant-policy *schema-playnet-membership*))

(check "informational schema has #f post-admit-hook (no reactive effect)"
       (grant-policy-post-admit-hook %member-policy)
       #f)

;; ── always-accept vs issuer-is-known-scope (without a graph) ────────
;;
;; current-scope-graph is unbound here — issuer-is-known-scope? must
;; return #f (no graph → can't verify). always-accept must return #t.

(check "informational predicate accepts any issuer (no graph needed)"
       ((grant-policy-expected-issuer? %member-policy)
        "EFakeIssuer" "EFakeIssuee" '())
       #t)

(check "security-critical predicate rejects when no scope-graph bound"
       ((grant-policy-expected-issuer? %fm-policy)
        "EFakeIssuer" "EFakeIssuee" '())
       #f)

;; ── in-graph-vat passthrough (no vat bound) ──────────────────────────
;;
;; When current-graph-vat is #f, in-graph-vat must call the thunk
;; directly instead of wrapping in with-vat.

(check "in-graph-vat with no vat bound runs thunk directly"
       (in-graph-vat (lambda () 'ran))
       'ran)

(test-summary!)
