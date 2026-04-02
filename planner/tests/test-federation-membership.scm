;;; test-federation-membership.scm — Agent hierarchy and membership indexing
;;;
;;; Ported from: old/planner/src/lib/tests/membership-lifecycle.test.ts
;;;
;;; Run: cd planner && guile --no-auto-compile -q -L ../module \
;;;        -l load-all.scm -l tests/test-federation-membership.scm

(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (srfi srfi-1))

;;; -- Harness ----------------------------------------------------------------

(define pass-count 0)
(define fail-count 0)

(define (check label got expected)
  (if (equal? got expected)
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n"))
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write got)      (newline))))

(define (check-pred label pred)
  (if pred
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n")))))


;;; ============================================================================
;;; Setup — 3 scopes, 5 persons
;;;
;;; Hierarchy:
;;;   federation (org)
;;;     commune-1 (org)  ← alice, bob
;;;     commune-2 (org)  ← charlie, dave
;;;   eve is a person in federation directly
;;;
;;; Additional relationships make commune-1/commune-2 members also federation
;;; members so that commune-share can be tested.
;;; ============================================================================

(display "\n── Federation Membership Tests ──\n\n")

(define mem-store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat
    scope-env
    (lambda () (spawn-scope "Federation Membership Test"))
    mem-store))

(with-vat vat
  (let ((as ($ scope 'agent-store)))

    ;; -- Organizations --------------------------------------------------------
    ($ as 'add-agent (make-agent "federation" 'organization "Federation" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "commune-1" 'organization "Commune 1" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "commune-2" 'organization "Commune 2" #f #f #f #f #f))

    ;; -- Persons --------------------------------------------------------------
    ($ as 'add-agent (make-agent "alice"   'person "Alice"   #f #f #f #f #f))
    ($ as 'add-agent (make-agent "bob"     'person "Bob"     #f #f #f #f #f))
    ($ as 'add-agent (make-agent "charlie" 'person "Charlie" #f #f #f #f #f))
    ($ as 'add-agent (make-agent "dave"    'person "Dave"    #f #f #f #f #f))
    ($ as 'add-agent (make-agent "eve"     'person "Eve"     #f #f #f #f #f))

    ;; -- Membership relationships (person → commune) --------------------------
    ($ as 'add-relationship
       (make-agent-relationship "rel-alice-c1"   "alice"   "commune-1" "member" #f #f))
    ($ as 'add-relationship
       (make-agent-relationship "rel-bob-c1"     "bob"     "commune-1" "member" #f #f))
    ($ as 'add-relationship
       (make-agent-relationship "rel-charlie-c2" "charlie" "commune-2" "member" #f #f))
    ($ as 'add-relationship
       (make-agent-relationship "rel-dave-c2"    "dave"    "commune-2" "member" #f #f))
    ($ as 'add-relationship
       (make-agent-relationship "rel-eve-fed"    "eve"     "federation" "member" #f #f))

    ;; -- Federation-level membership (commune members → federation) -----------
    ;; These let commune-share compute correct ratios.
    ($ as 'add-relationship
       (make-agent-relationship "rel-alice-fed"   "alice"   "federation" "member" #f #f))
    ($ as 'add-relationship
       (make-agent-relationship "rel-bob-fed"     "bob"     "federation" "member" #f #f))
    ($ as 'add-relationship
       (make-agent-relationship "rel-charlie-fed" "charlie" "federation" "member" #f #f))
    ($ as 'add-relationship
       (make-agent-relationship "rel-dave-fed"    "dave"    "federation" "member" #f #f))

    (check "agents seeded" (length ($ as 'all-agents)) 8)
    (check "relationships seeded" (length ($ as 'all-relationships)) 9)


    ;; =========================================================================
    ;; 1. Agent removal cascades
    ;;
    ;; Remove charlie. His two relationships (rel-charlie-c2, rel-charlie-fed)
    ;; should be cascaded. Other agents and relationships are preserved.
    ;; =========================================================================

    (display "── 1. Agent removal cascades ──\n")

    (let ((removed-ids ($ as 'remove-agent "charlie")))
      (check-pred "charlie removal returned relationship ids"
                  (and (list? removed-ids) (= (length removed-ids) 2)))
      (check-pred "rel-charlie-c2 removed"
                  (member "rel-charlie-c2" removed-ids))
      (check-pred "rel-charlie-fed removed"
                  (member "rel-charlie-fed" removed-ids)))

    (check "charlie agent gone" ($ as 'get-agent "charlie") #f)
    (check "agents after removal" (length ($ as 'all-agents)) 7)
    (check "relationships after removal" (length ($ as 'all-relationships)) 7)

    ;; Others preserved
    (check-pred "alice still exists" (not (not ($ as 'get-agent "alice"))))
    (check-pred "bob still exists"   (not (not ($ as 'get-agent "bob"))))
    (check-pred "dave still exists"  (not (not ($ as 'get-agent "dave"))))
    (check-pred "eve still exists"   (not (not ($ as 'get-agent "eve"))))


    ;; =========================================================================
    ;; 2. Membership index
    ;;
    ;; Build the index from remaining agents (after charlie removal).
    ;; 4 persons remain: alice, bob, dave, eve.
    ;; =========================================================================

    (display "── 2. Membership index ──\n")

    (let* ((agents ($ as 'all-agents))
           (rels   ($ as 'all-relationships))
           (idx    (build-membership-index agents rels)))

      ;; Citizens = all persons = 4
      (check "citizens count" (length (assq-ref idx 'citizens)) 4)

      ;; person-to-scope: last-processed relationship wins, but we verify
      ;; the hashmap contains mappings for each person
      (let ((p2s (assq-ref idx 'person-to-scope)))
        (check-pred "alice mapped"
                    (not (not (hashmap-ref p2s "alice" #f))))
        (check-pred "bob mapped"
                    (not (not (hashmap-ref p2s "bob" #f))))
        (check-pred "dave mapped"
                    (not (not (hashmap-ref p2s "dave" #f))))
        (check-pred "eve mapped"
                    (not (not (hashmap-ref p2s "eve" #f))))
        ;; charlie should not be present
        (check "charlie not in person-to-scope"
               (hashmap-ref p2s "charlie" #f) #f))

      ;; scope-to-citizens: commune-1 has alice+bob, commune-2 has dave,
      ;; federation has alice+bob+dave (eve maps to federation too)
      (let ((s2c (assq-ref idx 'scope-to-citizens)))
        (check "commune-1 citizen count"
               (length (hashmap-ref s2c "commune-1" '())) 2)
        (check-pred "alice in commune-1"
                    (member "alice" (hashmap-ref s2c "commune-1" '())))
        (check-pred "bob in commune-1"
                    (member "bob" (hashmap-ref s2c "commune-1" '())))
        (check "commune-2 citizen count"
               (length (hashmap-ref s2c "commune-2" '())) 1)
        (check-pred "dave in commune-2"
                    (member "dave" (hashmap-ref s2c "commune-2" '())))
        ;; federation scope has eve + alice + bob + dave = 4
        (check "federation citizen count"
               (length (hashmap-ref s2c "federation" '())) 4)))


    ;; =========================================================================
    ;; 3. Citizen share
    ;;
    ;; After removing charlie, 4 persons remain.
    ;; commune-1 has 2 citizens (alice, bob) → share = 2/4 = 1/2.
    ;; commune-2 has 1 citizen (dave) → share = 1/4.
    ;; =========================================================================

    (display "── 3. Citizen share ──\n")

    (let* ((agents ($ as 'all-agents))
           (rels   ($ as 'all-relationships))
           (idx    (build-membership-index agents rels)))
      (check "commune-1 citizen share" (citizen-share "commune-1" idx) 1/2)
      (check "commune-2 citizen share" (citizen-share "commune-2" idx) 1/4))


    ;; =========================================================================
    ;; 4. Commune share
    ;;
    ;; Federation citizens (scope-to-citizens[federation]) = 4
    ;;   (alice, bob, dave, eve).
    ;; Commune-1 citizens in federation = alice, bob = 2.
    ;; commune-share(federation, commune-1) = 2/4 = 1/2.
    ;; Commune-2 citizens in federation = dave = 1.
    ;; commune-share(federation, commune-2) = 1/4.
    ;; =========================================================================

    (display "── 4. Commune share ──\n")

    (let* ((agents ($ as 'all-agents))
           (rels   ($ as 'all-relationships))
           (idx    (build-membership-index agents rels)))
      (check "commune-1 share of federation"
             (commune-share "federation" "commune-1" idx) 1/2)
      (check "commune-2 share of federation"
             (commune-share "federation" "commune-2" idx) 1/4))


    ;; =========================================================================
    ;; 5. Relationship removal (selective)
    ;;
    ;; Remove a single relationship without touching agents.
    ;; =========================================================================

    (display "── 5. Selective relationship removal ──\n")

    (let ((result ($ as 'remove-relationship "rel-eve-fed")))
      (check "remove-relationship returns #t" result #t))
    (let ((result2 ($ as 'remove-relationship "rel-eve-fed")))
      (check "second remove returns #f (already gone)" result2 #f))

    ;; Eve still exists as an agent
    (check-pred "eve agent preserved" (not (not ($ as 'get-agent "eve"))))

    ;; But eve no longer appears in the membership index
    (let* ((agents ($ as 'all-agents))
           (rels   ($ as 'all-relationships))
           (idx    (build-membership-index agents rels)))
      (check "eve not in person-to-scope after rel removal"
             (hashmap-ref (assq-ref idx 'person-to-scope) "eve" #f) #f)
      ;; Federation now has 3 citizens (alice, bob, dave)
      (check "federation citizens after eve rel removal"
             (length (hashmap-ref (assq-ref idx 'scope-to-citizens) "federation" '()))
             3)
      ;; Citizens still count eve (she is still a person agent)
      (check "total citizens still includes eve"
             (length (assq-ref idx 'citizens)) 4))))


;;; ============================================================================

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(when (> fail-count 0) (exit 1))
