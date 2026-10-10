;;; test-law-insurance.scm — the two insurances the statute makes a condition of
;;; an act, as the packs carry them (docs/legal/insurance/README.md).
;;;
;;; Only two covers are mandatory for any body in France, Germany, the UK and
;;; the US, and both attach to crossings the catalogue has carried all along:
;;; third-party motor cover on `public-vehicle`, and cover for an injured
;;; employee on `wage-labour`. The second is the one real difference between
;;; the four: in France and Germany it is a statutory scheme the employer pays
;;; into (a `pay`), in the UK and the US a policy bought from an insurer (an
;;; `obtain`). The US workers' compensation rule is `uncertain` because several
;;; states exempt small employers by a head-count no guard can read, so it
;;; prices and warns and prunes nothing. Properties, not snapshots: what each
;;; bill carries, by demand kind and aspect, never by count of rules.
;;;
;;; Run: guile -L module tests/planner/test-law-insurance.scm

(use-modules (playnet test harness)
             (playnet doors legal)
             (playnet legal registry)
             (playnet knowledge law context-pack)
             (playnet knowledge law aspects)
             (playnet knowledge law lint)
             (srfi srfi-1) (ice-9 format))

(define (bill-of thunk) (call-with-values thunk list))          ; → (bill hits)
(define (at place crossing)
  (bill-of (lambda () (bill-at place (list crossing) #:act 'activity))))
(define (kinds bh)                                               ; the non-empty kinds
  (filter (lambda (k) (pair? (bill-ref (car bh) k))) '(obtain-entity obtain-person pay tell forbid)))
(define (aspects-of bh)                                          ; the federation aspects the bill's specs name
  (delete-duplicates
   (append-map (lambda (d) (filter-map clause-aspect (or (demand-spec d) '())))
               (append (bill-ref (car bh) 'obtain-entity) (bill-ref (car bh) 'obtain-person)))))
(define (labels bh) (map legal-rule-label (cadr bh)))
(define (stance bh) (bill-stance (car bh) (cadr bh)))
(define nothing-held (lambda (name) #f))
(define (stance/unheld bh) (bill-stance (car bh) (cadr bh) nothing-held))

(define nations '("france" "germany" "uk" "us-06"))

(display "\n── a titled vehicle on public ways ──\n")
(for-each
 (lambda (place)
   (let ((bh (at place 'public-vehicle)))
     (check (format #f "~a: motor cover is one entity-borne obtain and nothing else" place)
            (kinds bh) '(obtain-entity))
     (check (format #f "~a: the policy's clause names the third-party-liability aspect" place)
            (aspects-of bh) '(third-party-liability))
     (check (format #f "~a: a sure demand reads as notice" place) (stance bh) 'notice)))
 nations)
(check "New Hampshire asks no motor policy" (kinds (at "us-33" 'public-vehicle)) '())

(display "\n── wage labour ──\n")
(for-each
 (lambda (place)
   (check (format #f "~a: cover for an injured employee is a levy into the statutory scheme" place)
          (kinds (at place 'wage-labour)) '(pay)))
 '("france" "germany"))
(for-each
 (lambda (place)
   (let ((bh (at place 'wage-labour)))
     (check (format #f "~a: cover for an injured employee is a policy to obtain" place)
            (kinds bh) '(obtain-entity))
     (check (format #f "~a: the policy's clause names the injury-cover aspect" place)
            (aspects-of bh) '(injury-cover))))
 '("uk" "us-06"))
(check "Texas asks no workers' compensation policy" (kinds (at "us-48" 'wage-labour)) '())
(check "the UK rule is sure: a policy nobody holds closes the door"
       (stance/unheld (at "uk" 'wage-labour)) 'off)
(check "the US rule stands in doubt: a policy nobody holds is a notice, and prunes nothing"
       (stance/unheld (at "us-06" 'wage-labour)) 'notice)

(display "\n── the packs lint clean ──\n")
(check-pred "no error among the pack findings (the uk pack, the new aspects, the new crossing)"
            (null? (filter (lambda (f) (eq? 'error (finding-severity f)))
                           (lint-law-packs %contexts-dir #:known '("world")))))
(check-pred "every insurance rule names a source the steward can open"
            (every (lambda (r) (and (string? (legal-rule-source r)) (> (string-length (legal-rule-source r)) 10)))
                   (filter (lambda (r) (member (legal-rule-label r)
                                               '("fr/rc-auto" "fr/at-mp" "de/kfz-haftpflicht" "de/bg-beitrag"
                                                 "uk/employers-liability" "uk/motor-third-party"
                                                 "us/auto-liability" "us/workers-comp")))
                           *pack-rules*)))

(test-summary!)
