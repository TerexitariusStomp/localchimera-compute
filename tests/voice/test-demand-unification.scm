;;; test-demand-unification.scm — structural unification of partial demands.
;;;
;;; Exercises the stage-1 pipeline: merging compatible partial demands
;;; into a single unified entry before aggregation. Two partial
;;; knowledge fragments become a stronger one via unification.

(use-modules (playnet test harness)
             (playnet scope demand-registry)
             (playnet deprecated governance demand-unify)
             (srfi srfi-1))


(define (mk-entry citizen description fields)
  (make-demand-entry citizen description fields))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. Unify two compatible partial demands (complementary gaps)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. Complementary partial demands unify ──\n")

;; Alice: knows spec, leaves location unspecified.
;; Bob: knows location, leaves spec unspecified.
;; These should unify into a single entry carrying both ground facts.
(define alice
  (mk-entry "alice" "jacuzzi"
            '((resource-conforms-to . "spec-hot-tub-v2")
              (quantity-value       . 1)
              (quantity-unit        . "unit"))))

(define bob
  (mk-entry "bob" "hot-tub"
            '((at-location    . "room-302")
              (quantity-value . 1)
              (quantity-unit  . "unit"))))

(define unified (try-unify-entries alice bob))

(check-pred "unification succeeds"
            (and unified #t))
(check-pred "unified spec carried from Alice"
            (equal? "spec-hot-tub-v2"
                    (demand-entry-resource-conforms-to unified)))
(check-pred "unified location carried from Bob"
            (equal? "room-302" (demand-entry-at-location unified)))
(check-pred "unified quantity summed (both contributed 1)"
            (= 2 (demand-entry-quantity-value unified)))
(check-pred "unified quantity unit preserved"
            (equal? "unit" (demand-entry-quantity-unit unified)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Conflict on a ground slot blocks unification
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Ground conflict ⇒ no unification ──\n")

(define alice2
  (mk-entry "alice" "jacuzzi"
            '((resource-conforms-to . "spec-hot-tub-v2")
              (at-location          . "room-302"))))

(define bob2
  (mk-entry "bob" "jacuzzi"
            '((resource-conforms-to . "spec-hot-tub-v2")
              (at-location          . "room-405"))))  ;; conflict!

(check-pred "different locations reject unification"
            (not (try-unify-entries alice2 bob2)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Classification tags set-union rather than strict equality
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Classification tags set-union ──\n")

(define ann
  (mk-entry "ann" "wellness thing"
            '((resource-classified-as . ("hydrotherapy"))
              (at-location            . "floor-3"))))

(define ben
  (mk-entry "ben" "wellness thing"
            '((resource-classified-as . ("comfort" "hydrotherapy"))
              (at-location            . "floor-3"))))

(let ((u (try-unify-entries ann ben)))
  (check-pred "unification succeeds"
              (and u #t))
  (check-pred "tag set-union ⊇ hydrotherapy"
              (member "hydrotherapy"
                      (demand-entry-resource-classified-as u)))
  (check-pred "tag set-union ⊇ comfort"
              (member "comfort"
                      (demand-entry-resource-classified-as u))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 4. Clustering sweep: three partial demands collapse to one
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 4. Three partial demands → one cluster ──\n")

;; Three citizens each know one field about the same underlying wish.
(define a (cons "d1" (mk-entry "alice"   "jacuzzi"
                                '((resource-conforms-to . "spec-hot-tub-v2")
                                  (quantity-value       . 1)
                                  (quantity-unit        . "unit")))))
(define b (cons "d2" (mk-entry "bob"     "hot tub"
                                '((at-location    . "room-302")
                                  (quantity-value . 1)
                                  (quantity-unit  . "unit")))))
(define c (cons "d3" (mk-entry "charlie" "hot tub window"
                                '((has-beginning . "2026-07-01T00:00:00Z")
                                  (has-end       . "2026-09-30T23:59:59Z")
                                  (quantity-value . 1)
                                  (quantity-unit  . "unit")))))

(call-with-values
  (lambda () (unify-demand-cluster (list a b c)))
  (lambda (clusters solos)
    (check-pred "one cluster formed"
                (= 1 (length clusters)))
    (check-pred "no solos"
                (null? solos))
    (let* ((cluster (car clusters))
           (unified (car cluster))
           (members (cdr cluster)))
      (check-pred "cluster has three members"
                  (= 3 (length members)))
      (check-pred "unified carries spec from Alice"
                  (equal? "spec-hot-tub-v2"
                          (demand-entry-resource-conforms-to unified)))
      (check-pred "unified carries location from Bob"
                  (equal? "room-302"
                          (demand-entry-at-location unified)))
      (check-pred "unified carries window from Charlie"
                  (and (equal? "2026-07-01T00:00:00Z"
                                (demand-entry-has-beginning unified))
                       (equal? "2026-09-30T23:59:59Z"
                                (demand-entry-has-end unified))))
      (check-pred "unified quantity summed across all three"
                  (= 3 (demand-entry-quantity-value unified))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 5. Opt-out prevents participation in a cluster
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 5. no-auto-unify keeps a demand solo ──\n")

(define a5 (cons "e1" (mk-entry "alice" "jacuzzi"
                                 '((resource-conforms-to . "spec-hot-tub-v2")))))
(define b5 (cons "e2" (mk-entry "bob"   "hot-tub"
                                 '((at-location    . "room-302")
                                   (no-auto-unify  . #t)))))  ;; opt out

(call-with-values
  (lambda () (unify-demand-cluster (list a5 b5)))
  (lambda (clusters solos)
    (check-pred "no cluster when bob opts out"
                (null? clusters))
    (check-pred "two solos (alice singleton + bob)"
                (= 2 (length solos)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 6. Incompatible cluster members split: two clusters
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 6. Conflicting ground pins split the population ──\n")

(define p1 (cons "f1" (mk-entry "alice"   "jacuzzi"
                                 '((resource-conforms-to . "spec-hot-tub-v2")
                                   (at-location          . "room-302")))))
(define p2 (cons "f2" (mk-entry "bob"     "jacuzzi"
                                 '((resource-conforms-to . "spec-hot-tub-v2")
                                   (at-location          . "room-302")))))
(define p3 (cons "f3" (mk-entry "charlie" "jacuzzi"
                                 '((resource-conforms-to . "spec-hot-tub-v2")
                                   (at-location          . "room-405")))))

(call-with-values
  (lambda () (unify-demand-cluster (list p1 p2 p3)))
  (lambda (clusters solos)
    (check-pred "one cluster (rooms 302)"
                (= 1 (length clusters)))
    (check-pred "one solo (room 405)"
                (= 1 (length solos)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 7. Named hole shared across two demands
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 7. Named (hole ?loc) shared across demands ──\n")

;; Alice gives the spec; Bob gives the location; both tag the
;; same unknown with (hole 'loc) in the OTHER slot. Unification
;; must bind the hole transitively.
(define a7 (cons "d1" (mk-entry "alice" "jacuzzi"
                                 '((resource-conforms-to . "spec-hot-tub-v2")
                                   (at-location . (hole loc))
                                   (quantity-value . 1)
                                   (quantity-unit . "unit")))))
(define b7 (cons "d2" (mk-entry "bob" "hot tub"
                                 '((resource-conforms-to . "spec-hot-tub-v2")
                                   (at-location . "room-302")
                                   (quantity-value . 1)
                                   (quantity-unit . "unit")))))

(call-with-values
  (lambda () (unify-demand-cluster (list a7 b7)))
  (lambda (clusters solos)
    (check-pred "one cluster formed"
                (= 1 (length clusters)))
    (let ((unified (car (car clusters))))
      (check-pred "alice's (hole ?loc) bound to room-302"
                  (equal? "room-302" (demand-entry-at-location unified))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 8. (link) references a ground slot in another demand
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 8. (link) to a ground slot ──\n")

(define a8 (cons "alice-beer"
                 (mk-entry "alice" "beer"
                           '((resource-conforms-to . "spec-beer")
                             (at-location          . "pub-lounge")))))
;; Charlie wants a jacuzzi wherever Alice's beer is.
(define c8 (cons "charlie-jacuzzi"
                 (mk-entry "charlie" "jacuzzi"
                           `((resource-conforms-to . "spec-hot-tub-v2")
                             (at-location          . ,(make-link "alice-beer" 'at-location))))))

(call-with-values
  (lambda () (unify-demand-cluster (list a8 c8)))
  (lambda (clusters solos)
    (check-pred "no clusters (different specs)"
                (null? clusters))
    (check-pred "two solos"
                (= 2 (length solos)))
    ;; Charlie's link should have resolved to pub-lounge.
    (let ((charlie-solo (assoc "charlie-jacuzzi" solos)))
      (check-pred "charlie's link resolved to pub-lounge"
                  (equal? "pub-lounge"
                          (demand-entry-at-location (cdr charlie-solo)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 9. (link) to a #f anonymous hole — both end up sharing a fresh var
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 9. (link) to an anonymous #f slot ──\n")

;; Alice has an unspecified location (#f). Bob links to it.
;; Then Diana shows up with a ground location for the same spec —
;; ground propagates across the link via the shared session subst.
(define a9 (cons "alice-9"
                 (mk-entry "alice" "jacuzzi"
                           '((resource-conforms-to . "spec-hot-tub-v2")
                             (at-location          . #f)))))
(define b9 (cons "bob-9"
                 (mk-entry "bob" "hot tub"
                           `((resource-conforms-to . "spec-hot-tub-v2")
                             (at-location          . ,(make-link "alice-9" 'at-location))))))
(define d9 (cons "diana-9"
                 (mk-entry "diana" "jacuzzi"
                           '((resource-conforms-to . "spec-hot-tub-v2")
                             (at-location          . "floor-3")))))

(call-with-values
  (lambda () (unify-demand-cluster (list a9 b9 d9)))
  (lambda (clusters solos)
    (check-pred "one cluster (all share spec, compatible locations)"
                (= 1 (length clusters)))
    (let ((unified (car (car clusters))))
      (check-pred "unified at-location = floor-3 (propagated through link + anon hole)"
                  (equal? "floor-3" (demand-entry-at-location unified))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 10. Link cycle is broken safely (no infinite recursion)
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 10. Cycle-safe link resolution ──\n")

(define a10 (cons "aa"
                  (mk-entry "alice" "jacuzzi"
                            `((resource-conforms-to . "spec-hot-tub-v2")
                              (at-location          . ,(make-link "bb" 'at-location))))))
(define b10 (cons "bb"
                  (mk-entry "bob" "hot tub"
                            `((resource-conforms-to . "spec-hot-tub-v2")
                              (at-location          . ,(make-link "aa" 'at-location))))))
;; No ground location anywhere — cycle resolves to anon holes that
;; share a var, so unification succeeds with at-location unbound.
(call-with-values
  (lambda () (unify-demand-cluster (list a10 b10)))
  (lambda (clusters solos)
    (check-pred "cycle doesn't crash; one cluster formed"
                (= 1 (length clusters)))
    (let ((unified (car (car clusters))))
      (check-pred "unified at-location is unresolved (#f or reference)"
                  (not (string? (demand-entry-at-location unified)))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 11. Named hole in a solo: ground binding from another cluster propagates
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 11. Named hole in a solo picks up ground from another cluster ──\n")

;; Two demands share (hole 'when) — one in a cluster-forming pair that
;; grounds 'when, and one solo that doesn't merge (different spec).
;; The solo's reified entry should show the ground value at has-end.
(define x1 (cons "x1" (mk-entry "alice" "jacuzzi"
                                 '((resource-conforms-to . "spec-hot-tub-v2")
                                   (at-location          . "room-302")
                                   (has-end . (hole when))))))
(define x2 (cons "x2" (mk-entry "bob" "hot tub"
                                 '((resource-conforms-to . "spec-hot-tub-v2")
                                   (at-location          . "room-302")
                                   (has-end . "2026-09-30T23:59:59Z")))))
;; Carla's spec differs — will end up solo — but shares (hole 'when).
(define x3 (cons "x3" (mk-entry "carla" "plants"
                                 '((resource-conforms-to . "spec-plants")
                                   (has-end . (hole when))))))

(call-with-values
  (lambda () (unify-demand-cluster (list x1 x2 x3)))
  (lambda (clusters solos)
    (check-pred "one 2-member cluster"
                (and (= 1 (length clusters))
                     (= 2 (length (cdr (car clusters))))))
    (check-pred "one solo (carla)"
                (= 1 (length solos)))
    (let ((carla (cdr (assoc "x3" solos))))
      (check-pred "carla's (hole ?when) inherited the cluster's ground has-end"
                  (equal? "2026-09-30T23:59:59Z"
                          (demand-entry-has-end carla))))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
