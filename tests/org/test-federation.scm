;;; test-federation.scm — recursive scope-of-scopes

(use-modules (playnet test harness))
(use-modules (playnet scope root))
(use-modules (playnet org endorsement))
(use-modules (playnet boot scope) (playnet boot scope) (playnet voice voice-signer) (playnet keri acdc) (playnet keri acdc-store) (playnet keri first-person credentials) (playnet keri first-person predicates))
(use-modules (goblins) (goblins utils hashmap) (srfi srfi-1))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Federation admits communes; commune-weight reflects labor share
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Federation membership and weights ──\n")

(define vat (spawn-vat))

(with-vat vat
  ;; Two scopes with different labor totals.
  (define scope-a (spawn-scope-root "Watershed"))
  (define scope-b (spawn-scope-root "Bakery"))
  ;; Seed labor in each scope (events recorded directly so account-store
  ;; reports total-social-svc).
  ($ ($ scope-a 'account-store) 'add-contribution "alice" 30)
  ($ ($ scope-b 'account-store) 'add-contribution "bob" 70)

  ;; Wrap in communes.
  (define commune-a (spawn-commune "Watershed" scope-a))
  (define commune-b (spawn-commune "Bakery" scope-b))

  (define fed (spawn-federation "River-Federation"))
  (define fed-gov-cap ($ fed 'mint-gov-cap "fed-gov"))

  ($ fed 'admit-commune fed-gov-cap "watershed" commune-a)
  ($ fed 'admit-commune fed-gov-cap "bakery"    commune-b)

  (check-pred "federation has 2 communes"
              (= 2 (length ($ fed 'member-commune-ids))))

  ;; Commune weights: watershed has 30/100 = 0.3; bakery has 70/100 = 0.7.
  (let ((scope-roots (list scope-a scope-b)))
    (check-pred "watershed weight = 0.3"
                (= 30/100 ($ fed 'commune-weight "watershed" scope-roots)))
    (check-pred "bakery weight = 0.7"
                (= 70/100 ($ fed 'commune-weight "bakery" scope-roots)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Mandated federation ballot: communes' delegates cast aggregate stances
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Mandated federation ballot ──\n")

(define vat2 (spawn-vat))

(with-vat vat2
  (define scope-a (spawn-scope-root "Watershed"))
  (define scope-b (spawn-scope-root "Bakery"))
  ($ ($ scope-a 'account-store) 'add-contribution "alice" 30)
  ($ ($ scope-b 'account-store) 'add-contribution "bob" 70)

  (define commune-a (spawn-commune "Watershed" scope-a))
  (define commune-b (spawn-commune "Bakery" scope-b))

  (define fed (spawn-federation "River-Federation"))
  (define fed-gov-cap ($ fed 'mint-gov-cap "fed-gov"))

  ($ fed 'admit-commune fed-gov-cap "watershed" commune-a)
  ($ fed 'admit-commune fed-gov-cap "bakery"    commune-b)

  ;; Each commune elects a delegate with a fed-delegate-cap.
  (define a-delegate-cap ($ fed 'mint-delegate-cap "delegate-from-watershed"))
  (define b-delegate-cap ($ fed 'mint-delegate-cap "delegate-from-bakery"))

  ;; Delegates produce sealed stances on behalf of their communes.
  ;; (The delegate's stance is a regular voice-stance; the federation
  ;;  weights it by commune weight at tally time.)
  (call-with-values
    (lambda () (spawn-voice-signer "watershed-delegate" "E_wd"))
    (lambda (a-voice _s)
      (call-with-values
        (lambda () (spawn-voice-signer "bakery-delegate" "E_bd"))
        (lambda (b-voice _s2)

          ;; Watershed votes 'no, Bakery votes 'yes
          ($ fed 'receive-commune-stance a-delegate-cap "watershed" "dam-1"
             ($ a-voice 'stance "dam-1" 'no))
          ($ fed 'receive-commune-stance b-delegate-cap "bakery" "dam-1"
             ($ b-voice 'stance "dam-1" 'yes))

          ;; Tally: yes = 0.7, no = 0.3 (commune weights)
          (let* ((scope-roots (list scope-a scope-b))
                 (result ($ fed 'tally-mandated "dam-1" scope-roots))
                 (tally (assoc-ref result 'tally)))
            (check-pred "yes weight = 0.7 (bakery)"
                        (= 70/100 (hashmap-ref tally 'yes 0)))
            (check-pred "no weight = 0.3 (watershed)"
                        (= 30/100 (hashmap-ref tally 'no 0)))))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; First-Person re-anchoring: admission optionally blesses the commune as an
;;; authorized PHC issuer, so its personhood chains to the federation root.
;;; This is the growth-time hook — a new commune joining AND a recomposed
;;; commune re-joining both flow through here.
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Admission → authorized-issuer (root re-anchoring) ──\n")

(with-vat vat
  (define store (spawn-acdc-store))
  (define fed   (spawn-federation "River-Federation" #:acdc-store store))
  (define fed-aid    ($ fed 'scope-aid))
  (define fed-gov    ($ fed 'mint-gov-cap "fed-gov"))

  (define commune-a (spawn-commune "Watershed" (spawn-scope-root "Watershed")))
  (define commune-b (spawn-commune "Bakery"    (spawn-scope-root "Bakery")))
  (define a-aid ($ commune-a 'commune-aid))
  (define b-aid ($ commune-b 'commune-aid))

  ;; Admit A WITHOUT blessing: economic member, but NOT a personhood issuer.
  ($ fed 'admit-commune fed-gov "watershed" commune-a)
  (check-pred "plain admission does NOT authorize the commune as an issuer"
              (not (issuer-chains-to-root? store fed-aid a-aid
                                           #:require-signature? #f)))

  ;; Admit B WITH the blessing: now its PHCs chain to the federation root.
  ($ fed 'admit-commune fed-gov "bakery" commune-b 'authorize-issuer #t)
  (check-pred "authorize-issuer admission blesses the commune"
              (issuer-chains-to-root? store fed-aid b-aid
                                      #:require-signature? #f))
  (check-pred "the blessing is a live authorized-issuer credential"
              (let ((aic (authorized-issuer-cred store fed-aid b-aid)))
                (and aic (equal? (cred-issuer aic) fed-aid)
                         (equal? (cred-holder aic) b-aid))))

  ;; A PHC B later issues to a person chains to the federation root.
  (let ((phc (make-personhood-credential b-aid "E_person_in_bakery" 100)))
    (check-pred "a person enrolled by the blessed commune chains to root"
                (issuer-chains-to-root? store fed-aid (cred-issuer phc)
                                        #:require-signature? #f))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
