;;; test-keri-stance.scm — KERI-signed stances with local Ed25519 keypairs
;;;
;;; Proves the verifier abstraction works: ballot accepts Ed25519-signed
;;; stances verified locally, not via Goblins sealers. No KERIA needed.
;;; Uses (goblins utils crypto) for Ed25519 ops (same lib as OCapN CapTP).

(use-modules (playnet test harness))
(use-modules (playnet governance ballot) (playnet governance voice-signer) (playnet keri said-portable))
(use-modules (goblins) (goblins vat) (goblins utils hashmap)
             (goblins utils crypto)
             (rnrs bytevectors) (srfi srfi-1)
             (ice-9 match))


;;; ── Ed25519 sign/verify using goblins crypto ────────────────────────────

(define (sig-sexp->bytes sig)
  "Extract raw 64-byte signature from goblins crypto sig-sexp."
  (match sig
    (('sig-val ('eddsa ('r r-bv) ('s s-bv)))
     (let ((out (make-bytevector 64 0)))
       (bytevector-copy! r-bv 0 out 0 32)
       (bytevector-copy! s-bv 0 out 32 32)
       out))))

(define (make-ed25519-sign-fn keypair)
  "Returns a sign-fn suitable for spawn-keri-voice-signer.
   Produces raw 64-byte signature (not the sig-sexp wrapper)."
  (lambda (cleartext)
    (let ((msg (string->utf8 (canonical-string cleartext))))
      (sig-sexp->bytes (sign msg keypair)))))

(define (make-ed25519-verify-fn public-key-sexp)
  "Returns a verify function for a single citizen.
   public-key-sexp: the sexp from key-pair->public-key.
   auth-proof: raw 64-byte signature bytevector."
  (let* ((pub-bv (captp-public-key->bytevector public-key-sexp))
         (gnutls-key (bytevector->crypto-public-key pub-bv)))
    (lambda (_cleartext auth-proof)
      (let ((msg (string->utf8 (canonical-string _cleartext))))
        (verify auth-proof msg gnutls-key)))))

(define (make-local-ed25519-verifier citizen-verify-map)
  "Verifier using local Ed25519. citizen-verify-map: hashmap cid → verify-fn."
  (lambda (citizen-id cleartext auth-proof)
    (let ((vfn (hashmap-ref citizen-verify-map citizen-id #f)))
      (unless vfn
        (error "Unknown citizen for this ballot" citizen-id))
      (unless (vfn cleartext auth-proof)
        (error "Ed25519 signature verification failed" citizen-id))
      #t)))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 1. KERI-signed ballot round-trip
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 1. KERI-signed ballot round-trip ──\n")

(define vat (spawn-vat))

(with-vat vat
  (let* ((alice-kp  (generate-key-pair))
         (bob-kp    (generate-key-pair))
         (alice-pub (key-pair->public-key alice-kp))
         (bob-pub   (key-pair->public-key bob-kp)))

    ;; Create KERI-signed citizen-voices
    (define alice-voice
      (spawn-keri-voice-signer "alice" "E_alice"
                                (make-ed25519-sign-fn alice-kp)))
    (define bob-voice
      (spawn-keri-voice-signer "bob" "E_bob"
                                (make-ed25519-sign-fn bob-kp)))

    ;; Build verifier from public keys
    (define verify-map
      (hashmap-set
        (hashmap-set (hashmap) "alice" (make-ed25519-verify-fn alice-pub))
        "bob" (make-ed25519-verify-fn bob-pub)))
    (define keri-verifier (make-local-ed25519-verifier verify-map))

    ;; Voice snapshot (alice=30, bob=70)
    (define voice-snapshot
      (hashmap-set
        (hashmap-set (hashmap) "alice" (voice-snap 30 (hashmap)))
        "bob" (voice-snap 70 (hashmap))))

    ;; Spawn ballot with KERI verifier
    (define ballot
      (spawn ^ballot 'policy "keri-p1" 'federation "KERI test"
             voice-snapshot (hashmap) keri-verifier
             (lambda (_aid) #t) #f
             (hashmap) (hashmap) 'open))

    ;; Cast
    ($ ballot 'cast "alice" ($ alice-voice 'stance "keri-p1" 'yes))
    ($ ballot 'cast "bob"   ($ bob-voice   'stance "keri-p1" 'no))

    (let* ((tally (assoc-ref ($ ballot 'tally) 'tally))
           (yes (hashmap-ref tally 'yes 0))
           (no  (hashmap-ref tally 'no 0)))
      (check-pred "yes = 30" (= yes 30))
      (check-pred "no = 70"  (= no 70)))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 2. Wrong signature rejected
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 2. Rejects wrong signature ──\n")

(with-vat vat
  (let* ((alice-kp (generate-key-pair))
         (eve-kp   (generate-key-pair))
         (alice-pub (key-pair->public-key alice-kp)))

    (define verify-map
      (hashmap-set (hashmap) "alice" (make-ed25519-verify-fn alice-pub)))
    (define keri-verifier (make-local-ed25519-verifier verify-map))

    (define voice-snapshot
      (hashmap-set (hashmap) "alice" (voice-snap 100 (hashmap))))

    (define ballot
      (spawn ^ballot 'policy "keri-p2" 'federation "Reject test"
             voice-snapshot (hashmap) keri-verifier
             (lambda (_aid) #t) #f
             (hashmap) (hashmap) 'open))

    ;; Eve forges a stance for alice using eve's key
    (let* ((ct (list 'stance "keri-p2" 'yes "alice" "E_alice"))
           (forged-sig (sig-sexp->bytes
                         (sign (string->utf8 (canonical-string ct)) eve-kp))))
      (check-pred "forged stance rejected"
                  (catch #t
                    (lambda ()
                      ($ ballot 'cast "alice" (cons ct forged-sig))
                      #f)
                    (lambda _ #t))))))


;;; ════════════════════════════════════════════════════════════════════════════
;;; 3. Mixed sealer + KERI in same ballot
;;; ════════════════════════════════════════════════════════════════════════════

(display "\n── 3. Mixed sealer + KERI ──\n")

(with-vat vat
  (define-values (alice-voice alice-sealed?) (spawn-voice-signer "alice" "E_alice"))
  (let* ((bob-kp  (generate-key-pair))
         (bob-pub (key-pair->public-key bob-kp))
         (bob-voice (spawn-keri-voice-signer "bob" "E_bob"
                                              (make-ed25519-sign-fn bob-kp))))

    ;; Composite verifier: sealer for alice, Ed25519 for bob
    (define bob-verify (make-ed25519-verify-fn bob-pub))
    (define (mixed-verifier citizen-id cleartext proof)
      (cond
        ((equal? citizen-id "alice")
         (unless ($ alice-sealed? proof)
           (error "Sealer check failed" citizen-id))
         #t)
        ((equal? citizen-id "bob")
         (unless (bob-verify cleartext proof)
           (error "Ed25519 check failed" citizen-id))
         #t)
        (else (error "Unknown citizen" citizen-id))))

    (define voice-snapshot
      (hashmap-set
        (hashmap-set (hashmap) "alice" (voice-snap 40 (hashmap)))
        "bob" (voice-snap 60 (hashmap))))

    (define ballot
      (spawn ^ballot 'policy "mixed-1" 'federation "Mixed test"
             voice-snapshot (hashmap) mixed-verifier
             (lambda (_aid) #t) #f
             (hashmap) (hashmap) 'open))

    ($ ballot 'cast "alice" ($ alice-voice 'stance "mixed-1" 'yes))
    ($ ballot 'cast "bob"   ($ bob-voice   'stance "mixed-1" 'yes))

    (check-pred "mixed yes = 100"
                (= 100 (hashmap-ref (assoc-ref ($ ballot 'tally) 'tally) 'yes 0)))))


;;; ════════════════════════════════════════════════════════════════════════════

(newline)
(display (string-append "── Results: "
                        (number->string pass-count) " passed, "
                        (number->string fail-count) " failed ──\n"))
(test-summary!)
