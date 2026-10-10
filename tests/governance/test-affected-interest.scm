;;; test-affected-interest.scm — advisory voice from non-members

(use-modules (playnet test harness))
(use-modules (playnet pools credit-fold) (srfi srfi-1))
(use-modules (playnet org endorsement))
(use-modules (playnet voice affected-interest) (playnet voice ballot) (playnet voice delegation-map) (playnet voice voice-signer))
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
;;; Affected non-member casts advisory; binding tally unchanged
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── Advisory voice doesn't shift binding tally ──\n")

(define vat (spawn-vat))

(with-vat vat
  ;; Members of the scope: alice and bob
  (define alice (make-citizen "alice" 10))
  (define bob   (make-citizen "bob"   20))
  (define members (list alice bob))

  ;; A downstream group (a non-member of this scope, but affected).
  ;; They have their own ^voice-signer for sealing, but no voice-share.
  (define downstream-rep
    (call-with-values
      (lambda () (spawn-voice-signer "downstream-1" (synthetic-aid "downstream-1")))
      (lambda (v s) (cons v s))))
  (define downstream-voice (car downstream-rep))
  (define downstream-sealed? (cdr downstream-rep))

  (define b (open-ballot 'policy "p-affected" 'federation
                         "Should the dam be raised?"
                         (registry members) (vdata members)))

  ;; Register downstream as advisory voice (typically governance does this).
  ($ b 'register-advisor "downstream-1" downstream-sealed?)

  (define advisory (spawn-affected-interest-voice b "downstream-watershed"))

  ;; Alice and bob both vote 'yes (binding).
  ($ b 'cast "alice" ($ (voice alice) 'stance "p-affected" 'yes))
  ($ b 'cast "bob"   ($ (voice bob)   'stance "p-affected" 'yes))

  ;; Downstream casts advisory 'no (non-binding).
  ($ advisory 'cast "downstream-1"
     ($ downstream-voice 'stance "p-affected" 'no))

  ;; Binding tally: yes = 30, no = 0. Downstream's no does NOT shift it.
  (let* ((tally-result ($ b 'tally))
         (tally (assoc-ref tally-result 'tally)))
    (check-pred "binding yes = 30 (alice + bob, ignoring advisory no)"
                (= 30 (hashmap-ref tally 'yes 0)))
    (check-pred "binding no = 0 (advisory not counted)"
                (= 0 (hashmap-ref tally 'no 0))))

  ;; Advisory tally: 1 vote on 'no, 0 on 'yes
  (let* ((adv ($ b 'advisory-tally))
         (counts (assoc-ref adv 'advisory-counts)))
    (check-pred "advisory no count = 1"
                (= 1 (hashmap-ref counts 'no 0)))
    (check-pred "total advisors = 1"
                (= 1 (assoc-ref adv 'total-advisory)))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
