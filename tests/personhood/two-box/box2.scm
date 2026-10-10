;;; tests/personhood/two-box/box2.scm — the WITNESS's box.
;;;
;;; Own process, own PLAYNET_STATE_DIR, own static server; the only line to
;;; box1 is HTTP. It publishes its citizen AID for the choreography, polls
;;; box1's served /witness/requests until the ask arrives in its OWN
;;; registries, co-signs the statement with the key that never leaves this
;;; process, and publishes the attest for box1's poll to land.

(use-modules (playnet personhood witness-relay)
             ((playnet observation credentials) #:select (witness-work-inbox))
             ((playnet keri citizen-sig)
              #:select (make-keri-identity keri-identity-aid
                        keri-identity-keypair sign-said))
             (rnrs bytevectors)
             (ice-9 format)
             (srfi srfi-1))

(define peer   (getenv "WITNESS_PEER"))     ; box1's static base URL
(define shared (getenv "WITNESS_SHARED"))   ; the choreography dir

(define witness-id (make-keri-identity (make-bytevector 32 77)))
(define w-aid (keri-identity-aid witness-id))

;; hand box1 the roster entry it needs (memberships are out-of-band in prod)
(call-with-output-file (string-append shared "/witness-aid.tmp")
  (lambda (p) (display w-aid p)))
(rename-file (string-append shared "/witness-aid.tmp")
             (string-append shared "/witness-aid"))
(format #t "[box2] witness aid published: ~a~%" w-aid)

;; poll box1 until its ask reaches THIS box's inbox
(define row
  (let loop ((tries 0))
    (poll-peer-witness! peer)
    (let ((rows (witness-work-inbox w-aid)))
      (cond
       ((pair? rows) (car rows))
       ((> tries 120) (format #t "[box2] FAIL: no request arrived~%") (exit 1))
       (else (usleep 500000) (loop (+ tries 1)))))))

(let ((said   (assq-ref row 'said))
      (worker (assq-ref row 'worker))
      (skill  (assq-ref row 'skill)))
  (format #t "[box2] request arrived: ~a's ~a (~a)~%" worker skill said)
  (unless (and (equal? worker "EAdaFar") (equal? skill "skill-bake"))
    (format #t "[box2] FAIL: context did not cross intact: ~s~%" row)
    (exit 1))
  ;; the co-signature, made HERE — then the door publishes it home
  (let* ((door (make-federated-witness-door #:store-of (lambda (_) #f)))
         (attest (assq-ref door 'attest))
         (res (attest said w-aid (sign-said said (keri-identity-keypair witness-id)))))
    (unless (eq? res 'sent)
      (format #t "[box2] FAIL: attest did not publish: ~s~%" res)
      (exit 1))
    (format #t "[box2] attest published for ~a~%" said)))

;; ── the ENROLLMENT leg: vouch for box1's candidate ──────────────────────────
;; The generic ctx wire must carry the OTHER ceremony kind intact: the row
;; arrives as kind=enroll with the candidate in the subject slot and the
;; sponsor beside it. The vouch is the same own-key signature over the
;; statement — one signing act, two ceremonies.
(define erow
  (let loop ((tries 0))
    (poll-peer-witness! peer)
    (let ((rows (filter (lambda (r) (equal? "enroll" (assq-ref r 'kind)))
                        (witness-work-inbox w-aid))))
      (cond
       ((pair? rows) (car rows))
       ((> tries 120) (format #t "[box2] FAIL: no enrollment ask arrived~%") (exit 1))
       (else (usleep 500000) (loop (+ tries 1)))))))

(let ((said      (assq-ref erow 'said))
      (candidate (assq-ref erow 'worker))
      (sponsor   (assq-ref erow 'sponsor)))
  (format #t "[box2] enrollment ask arrived: ~a via ~a (~a)~%" candidate sponsor said)
  (unless (and (equal? candidate "ECandidate2Box0000000000000000000000000000")
               (equal? sponsor "EAdaFar"))
    (format #t "[box2] FAIL: enroll context did not cross intact: ~s~%" erow)
    (exit 1))
  (let* ((door (make-federated-witness-door #:store-of (lambda (_) #f)))
         (attest (assq-ref door 'attest))
         (res (attest said w-aid (sign-said said (keri-identity-keypair witness-id)))))
    (unless (eq? res 'sent)
      (format #t "[box2] FAIL: enrollment vouch did not publish: ~s~%" res)
      (exit 1))
    (format #t "[box2] enrollment vouch published for ~a~%" said)))

(exit 0)
