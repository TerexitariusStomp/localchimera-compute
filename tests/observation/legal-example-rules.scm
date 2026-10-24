;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; legal-example-rules.scm — five worked rules and the contexts that meet them.
;;;
;;; One rule per shape the vocabulary has: authorisation with a levy (food retail
;;; in one county), a competence licence, a levy with a disclosure, a
;;; prohibition, and a personal / extraterritorial disclosure that follows the
;;; data subject. They are examples of the form, with an example place tree; the
;;; law a scope or a face folds comes from the packs
;;; (docs/legal/contexts/).
;;;
;;;   (load (string-append (dirname (current-filename)) "/legal-example-rules.scm"))
;;;   guile -L module tests/observation/legal-example-rules.scm      ; prints the demo

(use-modules (localchimera legal registry) (srfi srfi-1) (srfi srfi-13) (ice-9 format))

;;; ─── the rules ───────────────────────────────────────────────────────────
(define *example-rules*
  (list
   ;; authorisation + levy together: public food sale in one county
   (rule (all-of (in-jurisdiction 'us-ca-alameda) (on-crossing 'public-sale)
                 (act-is 'food))
         (list (obtain #:rides 'entity #:name "Retail Food Permit"
                       #:issuer "ACDEH" #:spec '(fire-safety hygiene labeling))
               (obtain #:rides 'person #:name "Food Handler Card"
                       #:per 'each-handler #:spec '(hygiene-training))
               (pay #:name "Sales Tax" #:base 'gross-receipts #:rate 0.1025))
         #:label "ca-alameda/food-retail" #:source "Cal. Retail Food Code"
         #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:food.alameda")
   ;; authorisation (competence): the practitioner licence
   (rule (all-of (in-jurisdiction 'us-ca) (on-crossing 'act-on-person))
         (list (obtain #:rides 'person #:name "CA Medical License"
                       #:issuer "Medical Board of CA" #:per 'each-practitioner
                       #:spec '(competence ethics scope-of-practice)))
         #:label "ca/medical" #:source "Cal. B&P §2052"
         #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:health.ca")
   ;; levy + disclosure together: owning real property
   (rule (all-of (in-jurisdiction 'us) (on-crossing 'own-property))
         (list (pay  #:name "Property Tax" #:base 'assessed-value #:rate 0.011)
               (tell #:name "Beneficial-Ownership Report" #:to "FinCEN"
                     #:discloses '(controller-name controller-id)))
         #:label "us/real-property" #:source "FinCEN CTA + local assessor"
         #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:treasury")
   ;; PROHIBITION — alcohol sale in a dry jurisdiction
   (rule (all-of (in-jurisdiction 'dryland) (on-crossing 'public-sale)
                 (act-is 'alcohol))
         (list (forbid #:reason "dry-county ordinance"))
         #:label "dryland/alcohol-ban" #:source "(example ordinance)"
         #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:uc")
   ;; disclosure — PERSONAL / EXTRATERRITORIAL: GDPR follows the data subject
   (rule (all-of (on-crossing 'data-processing) (agent-has 'data-subject-region 'eu))
         (list (tell #:name "GDPR breach-notification" #:to "EU DPA"
                     #:discloses '(processing-records))
               (obtain #:rides 'entity #:name "GDPR Art.30 records + DPO"
                       #:spec '(lawful-basis records dpo)))
         #:label "eu/gdpr" #:source "Regulation (EU) 2016/679"
         #:as-of "2026-01-01" #:confidence 'verified #:steward "scope:data")))

(define *example-parents*
  '((us-ca-alameda . us-ca) (us-ca . us) (dryland . us) (us . world) (world . #f)))
(define (example-parent-of id)
  (let ((e (assq id *example-parents*))) (and e (cdr e))))

;;; ─── context builder + the derivation (the fold; never stored) ───────────
(define* (activity-context crossings place-id
                           #:key (parent-of example-parent-of)
                                 (agents '()) (assets '()) (act #f))
  (legal-context #:crossings crossings
                 #:place-path (jurisdiction-path place-id parent-of)
                 #:agents agents #:assets assets #:act act))

;;; ─── demo (only when run as a script) ────────────────────────────────────
(define (names ds) (map demand-name ds))
(define (show ctx title)
  (call-with-values (lambda () (legal-demands ctx #:rules *example-rules*))
    (lambda (bill hits)
      (format #t "~%~a~%" title)
      (format #t "  path     : ~a~%" (ctx-place-path ctx))
      (if (pair? (assq-ref bill 'forbid))
          (format #t "  ✗ FORBIDDEN : ~a~%" (names (assq-ref bill 'forbid)))
          (begin
            (format #t "  obtain   : entity ~a · person ~a~%"
                    (names (assq-ref bill 'obtain-entity))
                    (names (assq-ref bill 'obtain-person)))
            (format #t "  pay      : ~a~%" (names (assq-ref bill 'pay)))
            (format #t "  tell     : ~a~%" (names (assq-ref bill 'tell)))))
      (format #t "  rules    : ~a~%" (map legal-rule-label hits)))))

(define (legal-demo)
  (show (activity-context '(public-sale act-on-person own-property) 'us-ca-alameda
                          #:act 'food)
        "food retail + clinic, premises owned @ us-ca-alameda  (obtain + pay + tell)")
  (show (activity-context '(public-sale) 'dryland #:act 'alcohol)
        "alcohol sale @ dryland                                (forbid)")
  (show (activity-context '(data-processing) 'us-ca-alameda
                          #:agents '(((id . "p1") (data-subject-region . eu))))
        "processing an EU subject's data                       (tell + obtain, personal)")
  (format #t "~%outside the fold: standing (be a suable party — a fixture) ·")
  (format #t " subjection (the state acts on you, unchosen — structural defence)~%"))

(when (and (pair? (command-line))
           (string-suffix? "legal-example-rules.scm" (car (command-line))))
  (legal-demo))

