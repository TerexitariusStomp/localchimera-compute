;;; module/playnet/test/keri-identity.scm — a test identity and a lobby to seat it
;;;
;;; The ~30 lines three lobby tests each spelled out word for word
;;; (test-device-auth, test-lobby-seat-gate, test-signup-disabled-gate):
;;; a bran-derived identity with its inception event signed, a ^lobby wired
;;; to a real ^signup-agent and ^oobi-host with stubs in every other slot, and
;;; the poll that settles a cross-vat promise. Moved here the same way
;;; harness.scm absorbed check/^mock; a test keeps its own copy of a piece
;;; only where its copy genuinely differs (test-signup-with-kel's extra
;;; rotation keys, the gateway tests' eight-#f lobbies).
;;;
;;;   (define-values (kp0 kp1 icp-json icp-said icp-alist aid icp-sigs)
;;;     (test-identity "some-passcode-21-chars"))
;;;   (define-values (gateway-vat signup-vat signup-agent oobi-host lobby settle)
;;;     (lobby-fixture))
;;;
;;; settle closes over the fixture's own gateway vat, so a test calls
;;; (settle p) exactly as its local copy was called.

(define-module (playnet test keri-identity)
  #:use-module (playnet keri signify-portable)
  #:use-module (playnet gateway signup-agent)
  #:use-module (playnet gateway oobi-host)
  #:use-module (playnet gateway lobby)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:export (keypair->aid-prefix test-identity lobby-fixture))

(define (keypair->aid-prefix kp)
  "The AID prefix a keypair's public key incepts — the `q` every lobby
   test spelled for itself."
  (public-key->aid-prefix (ed25519-keypair-public kp)))

(define (test-identity bran)
  "BRAN → (values kp0 kp1 icp-json icp-said icp-alist aid icp-sigs): the
   signing and first rotation keypairs, the inception event in both forms,
   the AID it incepts, and the event's signature vector."
  (let* ((kp0 (bran->signing-keypair bran))
         (kp1 (bran->rotation-keypair bran 1)))
    (call-with-values
        (lambda () (build-icp #:keys (list (keypair->aid-prefix kp0))
                              #:nkeys (list (next-key-digest (ed25519-keypair-public kp1)))))
      (lambda (icp-json icp-said icp-alist)
        (values kp0 kp1 icp-json icp-said icp-alist
                (assoc-ref icp-alist "i")
                (vector (sign-event icp-json kp0)))))))

(define (lobby-fixture)
  "→ (values gateway-vat signup-vat signup-agent oobi-host lobby settle):
   a lobby over a real signup-agent (in its own vat, as in the gateway) and
   oobi-host, every other service a method-less stub; settle resolves a
   promise from a lobby call in the gateway vat, (list 'error e) on a
   broken one, #f if nothing arrives in ~2 s."
  (let* ((gateway-vat (spawn-vat #:name "gateway"))
         (signup-vat  (spawn-vat #:name "signup"))
         (signup-agent (with-vat signup-vat (spawn ^signup-agent (hashmap) (hashmap))))
         (oobi-host (with-vat gateway-vat (spawn ^oobi-host)))
         (stub (with-vat gateway-vat (spawn (lambda (_bcom) (methods)))))
         (lobby (with-vat gateway-vat
                  (spawn ^lobby signup-agent stub stub stub stub stub stub stub oobi-host)))
         (settle (lambda (p)
                   (let ((box #f) (done #f))
                     (with-vat gateway-vat
                       (on p (lambda (v) (set! box v) (set! done #t))
                           #:catch (lambda (e) (set! box (list 'error e)) (set! done #t))))
                     (let loop ((i 0))
                       (unless (or done (> i 200)) (usleep 10000) (loop (+ i 1))))
                     box))))
    (values gateway-vat signup-vat signup-agent oobi-host lobby settle)))
