;;; test-admit-commune-door.scm — a federation admits a commune through a
;;; governor of the gateway that holds it.
;;;
;;; The session door `admit-commune` is the federation's act, spoken by a
;;; governor: the gateway's `governor?` gate first, then the federation's own
;;; ladder (it mints the governor its gov-cap only if it recognises them), then
;;; `admit-commune-remote`. It names the commune, its AID and the sturdyref its
;;; peer answers at, and nothing that crosses: the commune tells the federation
;;; what it deals in.
;;;
;;; Run: guile --no-auto-compile -q -L module tests/doors/test-admit-commune-door.scm

(use-modules (playnet test harness)
             ((playnet test planner federation-wire-fixture) #:select (fx-identity))
             (playnet doors lobby)
             (playnet boot scope) (playnet boot governance) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig) (playnet keri first-person credentials)
             (playnet scope root)
             ((playnet keri citizen-sig) #:select (make-keri-identity keri-identity-aid keri-identity-keypair))
             (goblins) (goblins vat) (goblins actor-lib on)
             (srfi srfi-1) (rnrs bytevectors))

(define id-f (fx-identity 3))
(define aid-f (keri-identity-aid id-f))
(define aid-c (keri-identity-aid (fx-identity 1)))
(define aid-d (keri-identity-aid (fx-identity 2)))
(define GOV  "EGovernor0000000000000000000000000000000000")
(define BYST "EBystander0000000000000000000000000000000000")
(define (err? r) (and (pair? r) (eq? 'error (car r))))

(define vat (spawn-vat))
(define-values (store fed svc)
  (with-vat vat
    (let* ((root  (spawn-scope-root "Valley"))
           (store (spawn-acdc-store))
           (fed   (spawn-scope "Valley" #:kind 'federation #:scope-aid aid-f
                               #:keypair (keri-identity-keypair id-f) #:acdc-store store))
           (svc   (spawn-governance-service '() ($ root 'ballot-store)
                                            #:acdc-store store
                                            #:governor? (lambda (aid) (equal? aid GOV))
                                            #:scope-of (lambda (aid) (and (equal? aid aid-f) fed)))))
      (values store fed svc))))
(define (session aid) (with-vat vat (spawn ^lobby-session aid #f #f svc #f)))
(define gov-session (session GOV))
(define byst-session (session BYST))

;; a delegated door's reply is a promise — settle it
(define (settle p)
  (let ((box #f) (done #f))
    (with-vat vat
      (on p (lambda (v) (set! box v) (set! done #t))
          #:catch (lambda (e) (set! box (list 'error e)) (set! done #t))))
    (let loop ((i 0))
      (unless (or done (> i 300)) (usleep 10000) (loop (+ i 1))))
    box))
(define (spec) (with-vat vat ($ fed 'federation-spec)))
(define (members) (map car (assq-ref (spec) 'credentials)))
(define (admit! session federation commune sref) (settle (with-vat vat ($ session 'admit-commune federation commune sref))))

(display "\n── the gate: a governor speaks for the federation ──\n")
(check "a bystander's admission is refused" (err? (admit! byst-session aid-f aid-c "ocapn://c/s/1")) #t)
(check "and admits no one" (members) '())
(check "a federation this gateway does not hold is no federation"
       (err? (admit! gov-session "ENowhere" aid-c "ocapn://c/s/1")) #t)

(display "\n── the admission ──\n")
(check "a governor admits a commune at its sturdyref" (admit! gov-session aid-f aid-c "ocapn://c/s/1") 'ok)
(check "it is a member, under its AID" (members) (list aid-c))
(check "its credential names the sturdyref"
       (cred-claim (cdr (assoc aid-c (assq-ref (spec) 'credentials))) 'sturdyref-uri)
       "ocapn://c/s/1")

(display "\n── the federation's own ladder still applies ──\n")
;; once the federation has recognised someone of its own, a governor of the
;; gateway it has not recognised cannot speak for it
(with-vat vat ($ store 'issue (make-personhood-credential #:ecosystem-aid aid-f
                                                          #:holder-aid "EFounder"
                                                          #:enrolled-at "2026-01-01T00:00:00Z")))
(check "a governor the federation does not recognise is refused by it"
       (err? (admit! gov-session aid-f aid-d "ocapn://d/s/2")) #t)
(check "and the federation has still one member" (members) (list aid-c))

(test-summary!)
