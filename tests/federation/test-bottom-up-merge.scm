;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; test-bottom-up-merge.scm — Phase-2 bottom-up recomposition
;;;
;;; Validates docs/governance/democracy-on-keri.md §4.3:
;;;   1. The Universal Commune issues a recomposition-ratification ACDC
;;;      *before* the new scope C exists.
;;;   2. C is incepted with the ratification SAID sealed as an anchor
;;;      in C's inception event (icp.a).
;;;   3. Predecessors A and B emit dissolution rotations after C exists.
;;;   4. verify-parent-ratification! catches every misuse: wrong issuer,
;;;      wrong predecessors, wrong spec, threshold not met.
;;;
;;; Both shapes are exercised:
;;;   - Synthetic-keri-backend mode (no real keypair, no real KEL),
;;;     where anchors live only in the merger ACDC.
;;;   - Stub-keri-backend mode, where create-scope-aid records the
;;;     anchors arg so we can assert they were threaded through.

(use-modules (localchimera test harness))
(use-modules (localchimera scope root) (srfi srfi-1))
(use-modules (localchimera credentials membership) (localchimera credentials recomposition) (localchimera keri acdc) (localchimera boot scope) (localchimera keri acdc) (localchimera keri acdc-store))
(use-modules (localchimera federation universal-commune))
(use-modules (localchimera keys keri-backend))
(use-modules (goblins) (goblins vat) (goblins utils hashmap))


(define vat (spawn-vat))

(define (fresh-store _name) (spawn-acdc-store))

(format #t "~%=== Bottom-up merge: synthetic keri-backend ===~%")

(with-vat vat
  (let* ((store-A (fresh-store "A"))
         (store-B (fresh-store "B"))
         (store-UC (fresh-store "UC"))
         (root-A  (spawn-scope-root "A"))
         (root-B  (spawn-scope-root "B"))
         (A (spawn-scope "A" #:kind 'commune #:scope-root-ref root-A
                         #:scope-aid "E_A" #:acdc-store store-A))
         (B (spawn-scope "B" #:kind 'commune #:scope-root-ref root-B
                         #:scope-aid "E_B" #:acdc-store store-B))
         (UC (spawn-universal-commune #:acdc-store store-UC))
         (predecessors (sort (list "E_A" "E_B") string<?))
         (successor-spec
          '((kind . commune) (name . "AB-merged")))
         (proposal-spec '(merge-with "E_B"))
         (rat-said (ratify-recomposition!
                    UC 'merge-with proposal-spec
                    "E_ballot_AB" '((yes . 1.0) (no . 0.0) (abstain . 0.0))
                    #:predecessors predecessors
                    #:successor-spec successor-spec)))

    ;; ── 1. Ratification exists in UC's TEL before C ────────────────
    (check "ratification SAID is a string"
           (string? rat-said))
    (let ((found
           (find (lambda (c) (equal? rat-said (cred-said c)))
                 ($ store-UC 'all))))
      (check "ratification stored in UC TEL"
             (and found #t))
      (check "ratification issuer = UC AID"
             (equal? ($ UC 'scope-aid) (cred-issuer found)))
      (check "ratification names predecessors"
             (equal? predecessors (cred-claim found 'predecessors)))
      (check "ratification names successor-spec"
             (equal? successor-spec (cred-claim found 'successor-spec))))

    ;; ── 2. merge-with-parent succeeds with valid ratification ──────
    (let ((C-aid ($ A 'merge-with-parent B
                    ($ A 'mint-gov-cap "E_A")
                    ($ UC 'scope-aid)
                    store-UC
                    rat-said
                    successor-spec)))
      (check "merge-with-parent returns AID"
             (string? C-aid))
      (check "C AID begins with E_merged_bottom_up_ in synthetic mode"
             (string-prefix? "E_merged_bottom_up_" C-aid)))

    ;; ── 3. verify-parent-ratification! rejects misuse ──────────────
    (check "wrong issuer rejected"
           (not (false-if-exception
                  (verify-parent-ratification!
                    store-UC "E_NOT_UC"
                    predecessors successor-spec
                    rat-said 'merge-with proposal-spec))))
    (check "wrong predecessors rejected"
           (not (false-if-exception
                  (verify-parent-ratification!
                    store-UC ($ UC 'scope-aid)
                    '("E_A" "E_X")
                    successor-spec
                    rat-said 'merge-with proposal-spec))))
    (check "wrong successor-spec rejected"
           (not (false-if-exception
                  (verify-parent-ratification!
                    store-UC ($ UC 'scope-aid)
                    predecessors
                    '((kind . commune) (name . "WRONG"))
                    rat-said 'merge-with proposal-spec))))
    (check "wrong proposal type rejected"
           (not (false-if-exception
                  (verify-parent-ratification!
                    store-UC ($ UC 'scope-aid)
                    predecessors successor-spec
                    rat-said 'split proposal-spec))))))

(format #t "~%=== Bottom-up merge: stub keri-backend threads anchors ===~%")

(reset-universal-commune!)

(with-vat vat
  (let* ((events-box (cons #f (list)))
         (be (stub-keri-backend events-box))
         (store-A  (fresh-store "A2"))
         (store-B  (fresh-store "B2"))
         (store-UC (fresh-store "UC2"))
         (root-A   (spawn-scope-root "A2"))
         (root-B   (spawn-scope-root "B2"))
         (A (spawn-scope "A2" #:kind 'commune #:scope-root-ref root-A
                          #:scope-aid "E_A2" #:acdc-store store-A
                          #:keri-backend be))
         (B (spawn-scope "B2" #:kind 'commune #:scope-root-ref root-B
                          #:scope-aid "E_B2" #:acdc-store store-B
                          #:keri-backend be))
         (UC (spawn-universal-commune #:acdc-store store-UC
                                       #:keri-backend be))
         (predecessors (sort (list "E_A2" "E_B2") string<?))
         (successor-spec '((kind . commune) (name . "AB2")))
         (rat-said (ratify-recomposition!
                    UC 'merge-with '(merge-with "E_B2")
                    "E_ballot_AB2" '((yes . 1.0) (no . 0.0) (abstain . 0.0))
                    #:predecessors predecessors
                    #:successor-spec successor-spec))
         (C-aid ($ A 'merge-with-parent B
                   ($ A 'mint-gov-cap "E_A2")
                   ($ UC 'scope-aid)
                   store-UC
                   rat-said
                   successor-spec)))
    (check "C-aid emitted by stub create-scope-aid"
           (string-prefix? "Dscope_stub_" C-aid))
    ;; The stub records every (create-scope-aid #:anchors ANCHORS) call.
    ;; The most recent anchors should equal our ratification seal.
    (let ((create-scope-events
           (filter (lambda (ev) (eq? (car ev) 'create-scope-aid))
                   (cdr events-box))))
      (check "stub recorded at least one create-scope-aid"
             (not (null? create-scope-events)))
      ;; Find the merge call's anchors (the one with our rat-said)
      (let* ((mst (find (lambda (ev)
                          (let* ((tail (cdr ev))
                                 (anc (let loop ((xs tail))
                                        (cond ((null? xs) '())
                                              ((eq? (car xs) #:anchors)
                                               (cadr xs))
                                              (else (loop (cdr xs)))))))
                            (and (pair? anc)
                                 (equal? rat-said
                                         (assoc-ref (car anc) "d")))))
                        create-scope-events)))
        (check "merge-call anchors include the ratification SAID"
               (and mst #t))))))

;; ============================================================================
;; Multi-parent flows: shared / disjoint / mixed (democracy-on-keri.md §4.3
;; follow-up — previous parents have observation rights and bookkeeping
;; duties, not ratification authority).
;; ============================================================================

(define (issue-fed-membership! store federation-aid commune-aid commune-id)
  "Helper: write a fresh localchimera-federation-membership/v1 ACDC into STORE,
   issued by FEDERATION-AID, holder = COMMUNE-AID."
  (let ((cred (make-federation-membership-credential
               #:issuer-group-aid federation-aid
               #:commune-aid commune-aid
               #:federation federation-aid
               #:commune-id commune-id
               #:admitted-at (current-time))))
    ($ store 'issue cred)
    (cred-said cred)))

;; ── Scenario 1: A and B share exactly one parent F → F ratifies ───────────
(format #t "~%=== Multi-parent: shared parent F ===~%")
(reset-universal-commune!)

(with-vat vat
  (let* ((shared-store (fresh-store "shared")) ;; one store all actors share
         (F (spawn-scope "F" #:kind 'federation #:scope-aid "E_F"
                         #:acdc-store shared-store))
         (root-A (spawn-scope-root "A3"))
         (root-B (spawn-scope-root "B3"))
         (A (spawn-scope "A3" #:kind 'commune #:scope-root-ref root-A
                         #:scope-aid "E_A3" #:acdc-store shared-store))
         (B (spawn-scope "B3" #:kind 'commune #:scope-root-ref root-B
                         #:scope-aid "E_B3" #:acdc-store shared-store))
         (UC (spawn-universal-commune #:acdc-store shared-store)))
    ;; Make A and B both members of F.
    (issue-fed-membership! shared-store "E_F" "E_A3" "A3")
    (issue-fed-membership! shared-store "E_F" "E_B3" "B3")

    (call-with-values
        (lambda ()
          (merge-bottom-up! A B
                            ($ A 'mint-gov-cap "E_A3")
                            '((kind . commune) (name . "AB-shared"))
                            #:parent-resolver
                            (lambda (aid) (and (equal? aid "E_F") F))))
      (lambda (c-aid ratifier-ref source rat-said)
        (check "shared parent: source = shared-parent"
               (eq? source 'shared-parent))
        (check "shared parent: ratifier ref = F"
               (eq? ratifier-ref F))
        (check "shared parent: ratification issued by F"
               (let ((rat (find (lambda (c) (equal? rat-said (cred-said c)))
                                ($ shared-store 'all))))
                 (and rat (equal? "E_F" (cred-issuer rat)))))
        ;; Merger ACDC should have NO stale-membership edges.
        (let* ((merger (find (lambda (c)
                               (and (equal? *schema-localchimera-scope-merger*
                                            (cred-schema c))
                                    (equal? c-aid (cred-claim c 'new-scope-aid))))
                             ($ shared-store 'all))))
          (check "shared parent: merger ACDC exists"
                 (and merger #t))
          (check "shared parent: merger has ratification edge"
                 (assq 'ratification (cred-edges merger)))
          (check "shared parent: merger has NO stale-membership edges"
                 (null? (filter (lambda (e)
                                  (let ((s (symbol->string (car e))))
                                    (string-prefix? "stale-membership-" s)))
                                (cred-edges merger)))))))))

;; ── Scenario 2: A in F_A only, B in F_B only → UC ratifies, both stale ─────
(format #t "~%=== Multi-parent: disjoint parents → UC fallback ===~%")
(reset-universal-commune!)

(with-vat vat
  (let* ((shared-store (fresh-store "disjoint"))
         (F_A (spawn-scope "F_A" #:kind 'federation #:scope-aid "E_F_A"
                            #:acdc-store shared-store))
         (F_B (spawn-scope "F_B" #:kind 'federation #:scope-aid "E_F_B"
                            #:acdc-store shared-store))
         (root-A (spawn-scope-root "A4"))
         (root-B (spawn-scope-root "B4"))
         (A (spawn-scope "A4" #:kind 'commune #:scope-root-ref root-A
                         #:scope-aid "E_A4" #:acdc-store shared-store))
         (B (spawn-scope "B4" #:kind 'commune #:scope-root-ref root-B
                         #:scope-aid "E_B4" #:acdc-store shared-store))
         (UC (spawn-universal-commune #:acdc-store shared-store)))
    (define stale-A (issue-fed-membership! shared-store "E_F_A" "E_A4" "A4"))
    (define stale-B (issue-fed-membership! shared-store "E_F_B" "E_B4" "B4"))

    (call-with-values
        (lambda ()
          (merge-bottom-up! A B
                            ($ A 'mint-gov-cap "E_A4")
                            '((kind . commune) (name . "AB-disjoint"))
                            #:parent-resolver
                            (lambda (aid)
                              (cond ((equal? aid "E_F_A") F_A)
                                    ((equal? aid "E_F_B") F_B)
                                    (else #f)))))
      (lambda (c-aid ratifier-ref source rat-said)
        (check "disjoint: source = universal-commune"
               (eq? source 'universal-commune))
        (check "disjoint: ratifier ref = UC"
               (eq? ratifier-ref UC))
        (let* ((merger (find (lambda (c)
                               (and (equal? *schema-localchimera-scope-merger*
                                            (cred-schema c))
                                    (equal? c-aid (cred-claim c 'new-scope-aid))))
                             ($ shared-store 'all)))
               (stale-edges (filter (lambda (e)
                                      (let ((s (symbol->string (car e))))
                                        (string-prefix? "stale-membership-" s)))
                                    (cred-edges merger)))
               (stale-saids (map (lambda (e) (assoc-ref (cdr e) 'n))
                                 stale-edges)))
          (check "disjoint: 2 stale-membership edges"
                 (= 2 (length stale-edges)))
          (check "disjoint: stale edges include A's F_A membership"
                 (member stale-A stale-saids))
          (check "disjoint: stale edges include B's F_B membership"
                 (member stale-B stale-saids)))))))

;; ── Scenario 3: A in {F, G}, B in {F, K} → F shared, G & K stale ───────────
(format #t "~%=== Multi-parent: A∈{F,G}, B∈{F,K} → F ratifies, G+K stale ===~%")
(reset-universal-commune!)

(with-vat vat
  (let* ((shared-store (fresh-store "mixed"))
         (F (spawn-scope "F5" #:kind 'federation #:scope-aid "E_F5"
                         #:acdc-store shared-store))
         (G (spawn-scope "G5" #:kind 'federation #:scope-aid "E_G5"
                         #:acdc-store shared-store))
         (K (spawn-scope "K5" #:kind 'federation #:scope-aid "E_K5"
                         #:acdc-store shared-store))
         (root-A (spawn-scope-root "A5"))
         (root-B (spawn-scope-root "B5"))
         (A (spawn-scope "A5" #:kind 'commune #:scope-root-ref root-A
                         #:scope-aid "E_A5" #:acdc-store shared-store))
         (B (spawn-scope "B5" #:kind 'commune #:scope-root-ref root-B
                         #:scope-aid "E_B5" #:acdc-store shared-store))
         (UC (spawn-universal-commune #:acdc-store shared-store)))
    (issue-fed-membership! shared-store "E_F5" "E_A5" "A5")
    (define stale-A-G (issue-fed-membership! shared-store "E_G5" "E_A5" "A5"))
    (issue-fed-membership! shared-store "E_F5" "E_B5" "B5")
    (define stale-B-K (issue-fed-membership! shared-store "E_K5" "E_B5" "B5"))

    (call-with-values
        (lambda ()
          (merge-bottom-up! A B
                            ($ A 'mint-gov-cap "E_A5")
                            '((kind . commune) (name . "AB-mixed"))
                            #:parent-resolver
                            (lambda (aid)
                              (cond ((equal? aid "E_F5") F)
                                    ((equal? aid "E_G5") G)
                                    ((equal? aid "E_K5") K)
                                    (else #f)))))
      (lambda (c-aid ratifier-ref source rat-said)
        (check "mixed: source = shared-parent"
               (eq? source 'shared-parent))
        (check "mixed: ratifier ref = F"
               (eq? ratifier-ref F))
        (let* ((merger (find (lambda (c)
                               (and (equal? *schema-localchimera-scope-merger*
                                            (cred-schema c))
                                    (equal? c-aid (cred-claim c 'new-scope-aid))))
                             ($ shared-store 'all)))
               (stale-edges (filter (lambda (e)
                                      (let ((s (symbol->string (car e))))
                                        (string-prefix? "stale-membership-" s)))
                                    (cred-edges merger)))
               (stale-saids (map (lambda (e) (assoc-ref (cdr e) 'n))
                                 stale-edges)))
          (check "mixed: 2 stale-membership edges"
                 (= 2 (length stale-edges)))
          (check "mixed: stale edges include A's G membership"
                 (member stale-A-G stale-saids))
          (check "mixed: stale edges include B's K membership"
                 (member stale-B-K stale-saids))
          (check "mixed: F's memberships NOT in stale edges"
                 (not (any (lambda (s)
                             (let ((c (find (lambda (c) (equal? s (cred-said c)))
                                            ($ shared-store 'all))))
                               (and c (equal? "E_F5" (cred-issuer c)))))
                           stale-saids))))))))

;; ── Scenario 4: 3-way merge A + B + C → D, all sharing parent F ─────────────
(format #t "~%=== N-way: 3-way merge with shared parent F ===~%")
(reset-universal-commune!)

(with-vat vat
  (let* ((shared-store (fresh-store "n-way"))
         (F (spawn-scope "F6" #:kind 'federation #:scope-aid "E_F6"
                         #:acdc-store shared-store))
         (root-A (spawn-scope-root "A6"))
         (root-B (spawn-scope-root "B6"))
         (root-C (spawn-scope-root "C6"))
         (A (spawn-scope "A6" #:kind 'commune #:scope-root-ref root-A
                         #:scope-aid "E_A6" #:acdc-store shared-store))
         (B (spawn-scope "B6" #:kind 'commune #:scope-root-ref root-B
                         #:scope-aid "E_B6" #:acdc-store shared-store))
         (C (spawn-scope "C6" #:kind 'commune #:scope-root-ref root-C
                         #:scope-aid "E_C6" #:acdc-store shared-store))
         (UC (spawn-universal-commune #:acdc-store shared-store)))
    (issue-fed-membership! shared-store "E_F6" "E_A6" "A6")
    (issue-fed-membership! shared-store "E_F6" "E_B6" "B6")
    (issue-fed-membership! shared-store "E_F6" "E_C6" "C6")

    (call-with-values
        (lambda ()
          (merge-bottom-up! (list A B C)
                            ($ A 'mint-gov-cap "E_A6")
                            '((kind . commune) (name . "ABC-merged"))
                            #:parent-resolver
                            (lambda (aid) (and (equal? aid "E_F6") F))))
      (lambda (d-aid ratifier-ref source rat-said)
        (check "3-way: source = shared-parent"
               (eq? source 'shared-parent))
        (check "3-way: ratifier ref = F"
               (eq? ratifier-ref F))
        (let ((rat (find (lambda (c) (equal? rat-said (cred-said c)))
                         ($ shared-store 'all))))
          (check "3-way: ratification names all 3 predecessors"
                 (equal? '("E_A6" "E_B6" "E_C6")
                         (cred-claim rat 'predecessors))))
        (let* ((merger (find (lambda (c)
                               (and (equal? *schema-localchimera-scope-merger*
                                            (cred-schema c))
                                    (equal? d-aid (cred-claim c 'new-scope-aid))))
                             ($ shared-store 'all))))
          (check "3-way: merger ACDC has #:predecessors claim"
                 (equal? '("E_A6" "E_B6" "E_C6")
                         (cred-claim merger 'predecessors)))
          (check "3-way: merger has ratification edge"
                 (assq 'ratification (cred-edges merger)))
          (check "3-way: no stale edges (all 3 share F)"
                 (null? (filter (lambda (e)
                                  (let ((s (symbol->string (car e))))
                                    (string-prefix? "stale-membership-" s)))
                                (cred-edges merger)))))))))

;; ── Scenario 5: split A → A1, A2 via split-bottom-up! ──────────────────────
(format #t "~%=== N-way: 1→2 split (federation-mediated) ===~%")
(reset-universal-commune!)

(with-vat vat
  (let* ((shared (fresh-store "split"))
         (F (spawn-scope "F7" #:kind 'federation #:scope-aid "E_F7"
                         #:acdc-store shared))
         (root-A (spawn-scope-root "A7"))
         (A (spawn-scope "A7" #:kind 'commune #:scope-root-ref root-A
                         #:scope-aid "E_A7" #:acdc-store shared))
         (UC (spawn-universal-commune #:acdc-store shared)))
    (issue-fed-membership! shared "E_F7" "E_A7" "A7")

    (call-with-values
        (lambda ()
          (split-bottom-up! A
                            (list (list (cons 'kind 'commune) (cons 'name "A1"))
                                  (list (cons 'kind 'commune) (cons 'name "A2")))
                            ($ A 'mint-gov-cap "E_A7")
                            #:parent-resolver
                            (lambda (aid) (and (equal? aid "E_F7") F))))
      (lambda (succ-aids ratifier source rat-said)
        (check "split: 2 successors"
               (= 2 (length succ-aids)))
        (check "split: ratifier = F"
               (eq? ratifier F))
        (check "split: source = shared-parent"
               (eq? source 'shared-parent))
        (let ((rat (find (lambda (c) (equal? rat-said (cred-said c)))
                         ($ shared 'all))))
          (check "split: ratification has proposal-type=split"
                 (eq? 'split (cred-claim rat 'proposal-type))))
        (let ((split-acdc (find (lambda (c)
                                  (and (equal? *schema-localchimera-scope-split*
                                               (cred-schema c))
                                       (equal? "E_A7"
                                               (cred-claim c 'parent-scope-aid))))
                                ($ shared 'all))))
          (check "split: scope-split ACDC issued"
                 (and split-acdc #t))
          (check "split: ACDC has ratification edge"
                 (assq 'ratification (cred-edges split-acdc))))))))

(test-summary!)
