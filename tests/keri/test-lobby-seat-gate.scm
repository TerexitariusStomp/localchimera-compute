;;; tests/keri/test-lobby-seat-gate.scm — a key proven is not a seat held.
;;;
;;; ^oobi-host witnesses any verifiable KEL, so an AID can have a current
;;; key at a gateway without ever having joined its universal commune.
;;; keri-authenticate verifies the challenge under that key AND asks
;;; signup-agent for the seat; witnessed-only is refused, seated is
;;; admitted. The lobby's witness-kel / join / has-seat doors are driven
;;; the way the browser's take-seat! drives them. signup-agent sits in
;;; its own vat, as in the gateway, so the gated answer is a promise.

(use-modules (playnet test harness)
             (playnet keri signify-portable)
             ((playnet keri cesr) #:select (cesr-bytes->qb64))
             (playnet gateway signup-agent)
             (playnet gateway oobi-host)
             (playnet gateway lobby)
             (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (rnrs bytevectors)
             (ice-9 format))

(define gateway-vat (spawn-vat #:name "gateway"))
(define signup-vat  (spawn-vat #:name "signup"))

(define bran "seat-gate-passcode-21ch")
(define kp0 (bran->signing-keypair bran))
(define kp1 (bran->rotation-keypair bran 1))
(define (q kp) (public-key->aid-prefix (ed25519-keypair-public kp)))
(define-values (icp-json icp-said icp-alist)
  (build-icp #:keys (list (q kp0)) #:nkeys (list (next-key-digest (ed25519-keypair-public kp1)))))
(define aid (assoc-ref icp-alist "i"))
(define icp-sigs (vector (sign-event icp-json kp0)))

(define signup-agent
  (with-vat signup-vat (spawn ^signup-agent (hashmap) (hashmap))))
(define oobi-host
  (with-vat gateway-vat (spawn ^oobi-host)))
(define stub
  (with-vat gateway-vat (spawn (lambda (_bcom) (methods)))))
(define lobby
  (with-vat gateway-vat
    (spawn ^lobby signup-agent stub stub stub stub stub stub stub oobi-host)))

;; settle a cross-vat promise from a lobby method
(define (settle p)
  (let ((box #f) (done #f))
    (with-vat gateway-vat
      (on p (lambda (v) (set! box v) (set! done #t))
          #:catch (lambda (e) (set! box (list 'error e)) (set! done #t))))
    (let loop ((i 0))
      (unless (or done (> i 200))
        (usleep 10000) (loop (+ i 1))))
    box))

(define (challenge-and-answer kp)
  (let* ((nonce (with-vat gateway-vat ($ lobby 'keri-challenge aid)))
         (sig   (cesr-bytes->qb64 "0B" (sign-bytes (string->utf8 nonce) kp))))
    (settle (with-vat gateway-vat ($ lobby 'keri-authenticate aid sig nonce)))))

(format #t "~%=== witnessed, not seated ===~%")

(check "witness-kel → 'ok"
       (eq? 'ok (settle (with-vat gateway-vat
                          ($ lobby 'witness-kel aid icp-alist icp-sigs (vector))))))
(check "has-seat → #f"
       (not (settle (with-vat gateway-vat ($ lobby 'has-seat aid)))))
(let ((r (challenge-and-answer kp0)))
  (check "keri-authenticate under the right key, no seat → error"
         (and (pair? r) (eq? 'error (car r))))
  (check "…and the reason names the seat"
         (and (pair? r) (string? (cadr r)) (string-contains (cadr r) "seat"))))

(format #t "~%=== seated ===~%")

(check "join → 'ok"
       (eq? 'ok (settle (with-vat gateway-vat ($ lobby 'join "" "" aid)))))
(check "has-seat → #t"
       (eq? #t (settle (with-vat gateway-vat ($ lobby 'has-seat aid)))))
(let ((r (challenge-and-answer kp0)))
  (check "keri-authenticate, seated → ok + session"
         (and (pair? r) (eq? 'ok (car r))))
  (when (and (pair? r) (eq? 'ok (car r)))
    (check "the session reports the AID"
           (equal? aid (with-vat gateway-vat ($ (cadr r) 'whoami))))))
(let ((r (challenge-and-answer (bran->signing-keypair "someone-else-entirely-21"))))
  (check "seated, wrong key → error"
         (and (pair? r) (eq? 'error (car r)))))

(test-summary!)
