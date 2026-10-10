;;; test-guardianship.scm — documentary guardianship; voice math unchanged

(use-modules (playnet test harness))
(use-modules (playnet pools credit-fold) (srfi srfi-1))
(use-modules (playnet org endorsement))
(use-modules (playnet voice ballot) (playnet voice delegation-map) (playnet economy guardianship) (playnet voice voice-signer))
(use-modules (goblins) (goblins utils hashmap) (srfi srfi-1))


(define (synthetic-aid id) (string-append "E_" id))

(define (make-citizen id voice-share)
  (call-with-values
    (lambda () (spawn-voice-signer id (synthetic-aid id)))
    (lambda (voice sealed?)
      (list id voice sealed? (spawn-delegation-map id) voice-share))))

(define (id c) (list-ref c 0))
(define (voice c) (list-ref c 1))
(define (sealed c) (list-ref c 2))
(define (deleg c) (list-ref c 3))
(define (share c) (list-ref c 4))

(define (registry citizens)
  (fold (lambda (c acc) (hashmap-set acc (id c) (sealed c))) (hashmap) citizens))

(define (vdata citizens)
  (fold (lambda (c acc) (hashmap-set acc (id c) (cons (share c) (deleg c))))
        (hashmap) citizens))


;;; ════════════════════════════════════════════════════════════════════════════
;;; Guardian's stance carries on-behalf-of; tally is just the guardian's weight
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Guardianship is documentary; weight unchanged ──\n")

(define vat (spawn-vat))

(with-vat vat
  ;; Guardian works (voice 10). Ward has voice 0 (CCF=0, no labor).
  (define alice (make-citizen "alice" 10))
  ;; Make a ward with their own voice-actor for completeness, but no labor.
  (define grandma-rec
    (call-with-values
      (lambda () (spawn-voice-signer "grandma" (synthetic-aid "grandma")))
      (lambda (v s)
        (list "grandma" v s (spawn-delegation-map "grandma") 0))))

  (define citizens (list alice grandma-rec))

  ;; Establish guardianship
  (define guardianship
    (spawn-guardianship "alice" "grandma" (voice alice)
                         "watershed-commune" 1700000000))

  (check-pred "guardianship records guardian"
              (equal? "alice" ($ guardianship 'guardian-aid)))
  (check-pred "guardianship records ward"
              (equal? "grandma" ($ guardianship 'ward-aid)))

  ;; Open a ballot. Both alice and grandma have voice records (grandma's = 0).
  (define b (open-ballot 'policy "p-g" 'federation "test"
                         (registry citizens) (vdata citizens)))

  ;; Alice casts on behalf of grandma — produces a normal stance bundle
  ;; (sealed by her own voice) plus the on-behalf-of annotation.
  (let* ((on-behalf ($ guardianship 'stance-on-behalf "p-g" 'yes))
         (stance-bundle (car on-behalf))
         (annotation    (cadr on-behalf)))
    ($ b 'cast "alice" stance-bundle)
    (check-pred "annotation references the ward"
                (equal? '(on-behalf-of "grandma") annotation)))

  ;; Tally: alice's 10 on yes; grandma's 0 unchanged. No bonus voice.
  (let* ((result ($ b 'tally))
         (tally  (assoc-ref result 'tally)))
    (check-pred "yes = 10 (alice's own voice; no ward bump)"
                (= 10 (hashmap-ref tally 'yes 0)))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
