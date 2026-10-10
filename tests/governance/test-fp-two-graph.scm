;;; test-fp-two-graph.scm — cross-gateway recognition between two graphs
;;;
;;; Two independently-booted graphs, each sovereign with its own Universal
;;; Commune root. A person enrolled under graph A's root presents to graph B.
;;; Exercises the three cross-gateway outcomes end-to-end (real crypto, real
;;; JSON wire, separate stores + services):
;;;   1. B recognises only its own root  → A's person is REJECTED.
;;;   2. B cross-recognises {B, A}        → A's person is ACCEPTED (multi-root).
;;;   3. A and B merge into C; B roots at C → A's person ACCEPTED via lineage.

(use-modules (playnet test harness))
(use-modules (playnet voice ballot-store) (playnet credentials recomposition) (playnet keri acdc) (playnet keri first-person credentials) (playnet boot scope) (playnet boot governance) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri first-person credentials) (playnet keri first-person predicates))
(use-modules (playnet voice ballot-store))
(use-modules ((playnet keys exchange) #:select (governance-cred->wire)))
(use-modules ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-aid keri-identity-keypair)))
(use-modules (goblins) (goblins vat) (goblins actor-lib methods) (goblins utils hashmap)
             (json) (rnrs bytevectors))

(define (^acct _b g t) (methods ((total-social-svc . _l) t) ((citizen-gross c . _l) (hashmap-ref g c 0))))
(define (^sr _b a bs)  (methods ((account-store) a) ((ballot-store) bs)))

(define (phc-wire cred)
  (scm->json-string (append (governance-cred->wire cred)
                            (list (cons "sig" (or (cred-signature cred) ""))))))

(define (spawn-verifier store)
  "A foreign gateway B: a governance-service over its own store."
  (let ((bs (spawn-ballot-store)))
    (spawn-governance-service (list (spawn ^sr (spawn ^acct (hashmap) 1) bs)) bs
                              #:acdc-store store)))

(define vat (spawn-vat))

(display "\n── Two sovereign graphs: cross-recognition, rejection, merge ──\n")

(with-vat vat
  ;; ── Graph A: UC-A blesses commune-A, which enrols Alice ──
  (define uc-a      (make-keri-identity (make-bytevector 32 101)))
  (define commune-a (make-keri-identity (make-bytevector 32 102)))
  (define uca-aid   (keri-identity-aid uc-a))
  (define ca-aid    (keri-identity-aid commune-a))
  (define store-a   (spawn-acdc-store))
  (define scope-a   (spawn-scope "Commune-A" #:kind 'federation
                                 #:scope-aid ca-aid
                                 #:keypair (keri-identity-keypair commune-a)
                                 #:acdc-store store-a))
  (define aic-a (make-authorized-issuer-credential
                  uca-aid ca-aid 10 #:signing-keypair (keri-identity-keypair uc-a)))
  ($ store-a 'issue aic-a)
  ($ scope-a 'issue-phc ($ scope-a 'mint-gov-cap "a") "E_alice")
  (define alice-wire (phc-wire (phc-for store-a ca-aid "E_alice")))

  ;; ── Graph B: separate store; replicates A's published AIC (registry) ──
  (define uc-b    (make-keri-identity (make-bytevector 32 103)))
  (define ucb-aid (keri-identity-aid uc-b))
  (define store-b (spawn-acdc-store))
  ($ store-b 'import (list (cons aic-a #f)))     ;; published trust-registry entry
  (define bsvc (spawn-verifier store-b))

  ;; 1. B recognises only its OWN root → Alice (rooted at UC-A) is foreign.
  ($ bsvc 'set-fp-root! ucb-aid)
  ($ bsvc 'set-fp-strict-root! #t)
  (check "B (own root only) rejects A's person"
         (cdr ($ bsvc 'present-phc "E_alice" alice-wire))
         "issuer is not a federated commune")

  ;; 2. B cross-recognises {UC-B, UC-A} → Alice accepted (multi-root).
  ($ bsvc 'set-fp-root! (list ucb-aid uca-aid))
  (check-pred "B (cross-recognising A) accepts A's person"
              (eq? 'ok (car ($ bsvc 'present-phc "E_alice" alice-wire))))
  (check-pred "…and Alice is now recognised in B"
              (assoc-ref (cdr ($ bsvc 'fp-status "E_alice" "s")) 'person))

  ;; 3. The two UCs merge into UC-C; B roots at C. Alice chains via lineage.
  (define store-c (spawn-acdc-store))
  ($ store-c 'import (list (cons aic-a #f)))
  ($ store-c 'issue (make-scope-merger-credential
                      uca-aid ucb-aid "E_uc_c" 'universal-commune 200))
  (define csvc (spawn-verifier store-c))
  ($ csvc 'set-fp-root! "E_uc_c")
  ($ csvc 'set-fp-strict-root! #t)
  (check-pred "after A+B→C merge, C's root still recognises A's person (lineage)"
              (eq? 'ok (car ($ csvc 'present-phc "E_alice" alice-wire)))))


(newline)
(test-summary!)
