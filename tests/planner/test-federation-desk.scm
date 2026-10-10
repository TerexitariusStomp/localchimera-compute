;;; test-federation-desk.scm — a federation answers for itself, and a commune
;;; takes its word only as far as it checks.
;;;
;;; A federation scope admits communes; each tells its DESK
;;; (federation/federate.scm) what it deals in, a census it signs. The desk hands
;;; whoever asks the credentials that stand — the sturdyrefs and the censuses —
;;; signed under the federation's AID with the asker's nonce, and the fold
;;; its members tell. The commune reads the answer with `desk-word->spec`:
;;; the roster it will run on is derived from the signed credentials, so a
;;; word from anybody else, an answer to another question, or a spec in which
;;; not every member has told its census gives it nothing to boot on.
;;; `federation-ask!` is that reading, asked again until it holds — a commune
;;; admitted before its counterpart waits for the counterpart.
;;;
;;; No network: the desk is reached through a stand-in for the mycapn, which
;;; enlivens every sturdyref to it. The wire itself is
;;; test-federation-peer-procs.scm.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-federation-desk.scm

(use-modules (playnet test harness)
             ((playnet test planner federation-wire-fixture) #:select (fx-identity))
             (playnet boot scope) (playnet keri acdc-store) (playnet keri citizen-sig)
             (playnet federation federate)
             ((playnet federation sturdyref-credential) #:select (verified-spec spec-ready?))
             ((playnet federation peer) #:select (^attestation-fold wait-vow call-from-thread))
             ((playnet federation wire) #:select (signed-reply))
             ((playnet keri citizen-sig) #:select (make-keri-identity keri-identity-aid keri-identity-keypair))
             (goblins) (goblins vat) (goblins actor-lib methods) (goblins actor-lib timers) (goblins actor-lib on)
             (fibers)
             (ice-9 threads)
             (rnrs bytevectors) (srfi srfi-1))

(define id-f (fx-identity 3)) (define id-a (fx-identity 1)) (define id-b (fx-identity 2)) (define id-x (fx-identity 4))
(define aid-f (keri-identity-aid id-f)) (define aid-a (keri-identity-aid id-a))
(define aid-b (keri-identity-aid id-b)) (define aid-x (keri-identity-aid id-x))
(define a-desk "ocapn://3jcbsuavdisglt5ot7e24aznupj7gxnwogzo55s7vozjxthxqrta.websocket/s/8kWcGpITHBXwfen0ZUQGfYGoV_StzcqQmQyhMCuByiQ?url=ws%3A%2F%2F127.0.0.1%3A9")

;; the vat on a fibers thread (the ask waits on Goblins' timeout), the reading on this one
(define mtx (make-mutex)) (define cv (make-condition-variable)) (define vat #f)
(call-with-new-thread
 (lambda ()
   (run-fibers
    (lambda ()
      (with-mutex mtx (set! vat (spawn-vat #:name "federation")) (signal-condition-variable cv))
      (let loop () (sleep 3600) (loop)))
    #:drain? #f)))
(with-mutex mtx (let lp () (unless vat (wait-condition-variable cv mtx) (lp))))

(define (^stand-in bcom far) (methods ((enliven id) far)))   ; a mycapn whose every sturdyref is FAR
(define-values (fed gov fold desk mycapn forger)
  (with-vat vat
    (let* ((fed (spawn-scope "Valley" #:kind 'federation #:scope-aid aid-f
                             #:keypair (keri-identity-keypair id-f) #:acdc-store (spawn-acdc-store)))
           (fold (spawn ^attestation-fold '()))
           (desk (spawn ^federation-desk fed (scope-signer aid-f fed) fold "ocapn://the-fold")))
      (values fed ($ fed 'mint-gov-cap "bootstrap") fold desk
              (spawn ^stand-in desk)
              ;; somebody else's desk over the same scope: the same credentials, another signature
              (spawn ^federation-desk fed id-x fold "ocapn://elsewhere")))))
(define (asked who nonce) (call-from-thread vat who 'spec nonce))
(define (told! who id goods) (call-from-thread vat who 'census (census-credential id aid-f goods "t0")))

(display "\n── one member admitted: the federation's word, and what it is not yet ──\n")
(with-vat vat ($ fed 'admit-commune-remote gov "granary" aid-a "ocapn://a/s/1"))
(told! desk id-a '("flour"))
(define word-1 (asked desk "n1"))
(check "the desk answers a text and a signature" (and (= 2 (length word-1)) (every string? word-1)))
(check-error "a federation of one has nothing to cross: not a spec to boot on"
             (lambda () (desk-word->spec word-1 aid-f "n1" aid-a)))

(display "\n── both admitted, one has told ──\n")
(with-vat vat ($ fed 'admit-commune-remote gov "table" aid-b "ocapn://b/s/2"))
(check-error "the table has not told its census: the roster is not whole"
             (lambda () (desk-word->spec (asked desk "n1b") aid-f "n1b" aid-a)))
(check-error "a stranger cannot tell one" (lambda () (told! desk id-x '("flour"))))
(told! desk id-b '("flour"))
(define word-2 (asked desk "n2"))
(define spec (desk-word->spec word-2 aid-f "n2" aid-a))
(define own (with-vat vat ($ fed 'federation-spec)))
(check "the commune derives the roster the federation's store gives" (assq-ref spec 'roster) (assq-ref own 'roster))
(check "and its goods and issuer" (list (assq-ref spec 'goods) (assq-ref spec 'issuer)) (list (assq-ref own 'goods) aid-f))
(check "the word names the fold to tell" (assq-ref spec 'tell) "ocapn://the-fold")
(check "flour crosses between them" (assq-ref spec 'goods) '("flour"))
(check "the spec holds either member's crossing" (and (spec-ready? spec aid-a) (spec-ready? spec aid-b)))
(check "and nobody else's" (not (spec-ready? spec aid-x)))

(display "\n── what a commune refuses ──\n")
(check-error "an answer to another question" (lambda () (desk-word->spec word-2 aid-f "n3" aid-a)))
(check-error "a word signed by somebody else, over the federation's own credentials"
             (lambda () (desk-word->spec (asked forger "n4") aid-f "n4" aid-a)))
(check-error "the federation's word read under another AID than the one the commune trusts"
             (lambda () (desk-word->spec word-2 aid-x "n2" aid-a)))
(check-error "a word whose text was edited after it was signed"
             (lambda () (desk-word->spec (list (string-append (car word-2) " ") (cadr word-2)) aid-f "n2" aid-a)))
(check-error "a census whose goods were edited after it was signed"
             (lambda ()
               (verified-spec
                aid-f
                (append (map cdr (assq-ref own 'credentials))
                        (map (lambda (held)
                               (map (lambda (p)
                                      (if (eq? (car p) 'claims)
                                          (cons 'claims (map (lambda (c) (if (eq? (car c) 'goods) (cons 'goods '("gold")) c))
                                                             (cdr p)))
                                          p))
                                    (cdr held)))
                             (assq-ref own 'census))))))

(display "\n── the fold hears who the federation admitted ──\n")
(define (word-of id) (signed-reply id `((aid . ,(keri-identity-aid id)) (attestation . ((met . 100.0))))))
(check "a member's word is heard" (apply call-from-thread vat fold 'hear (word-of id-b)) 'heard)
(check "anybody else's is refused" (apply call-from-thread vat fold 'hear (word-of id-x)) 'refused)

(display "\n── asked until it holds ──\n")
;; a second federation, its first member asking before its counterpart is admitted
(define-values (fed-2 gov-2 mycapn-2)
  (with-vat vat
    (let* ((fed (spawn-scope "Ridge" #:kind 'federation #:scope-aid aid-f
                             #:keypair (keri-identity-keypair id-f) #:acdc-store (spawn-acdc-store)))
           (desk (spawn ^federation-desk fed (scope-signer aid-f fed) (spawn ^attestation-fold '()) "ocapn://the-fold")))
      ($ fed 'admit-commune-remote ($ fed 'mint-gov-cap "bootstrap") "granary" aid-a "ocapn://a/s/1")
      (values fed ($ fed 'mint-gov-cap "bootstrap") (spawn ^stand-in desk)))))
(define attempts '())
(define asking
  (with-vat vat (federation-ask! mycapn-2 a-desk aid-f aid-a #:retry 0.2
                                 #:census (census-credential id-a aid-f '("flour") "t0")
                                 #:log (lambda (m) (set! attempts (cons (cadr m) attempts))))))
(sleep 1)
(check "the commune is still asking while its counterpart is outside" (and (pair? attempts) (every (lambda (a) (eq? a 'away)) attempts)))
(with-vat vat ($ fed-2 'admit-commune-remote gov-2 "table" aid-b "ocapn://b/s/2")
               ($ fed-2 'accept-census (census-credential id-b aid-f '("flour") "t0")))
(define asked-spec (wait-vow vat asking))
(check "once the counterpart is admitted the ask answers, with both on the roster"
       (cdr (assoc "flour" (assq-ref asked-spec 'roster))) (sort (list aid-a aid-b) string<?))
(check "the last attempt is the one that held" (car attempts) 'ok)
(test-summary!)
