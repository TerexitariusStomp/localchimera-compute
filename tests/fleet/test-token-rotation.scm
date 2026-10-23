;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/fleet/test-token-rotation.scm — token-rotation state machine
;;;
;;; Exercises advance-token-rotation-step's three terminal-or-pending
;;; transitions:
;;;
;;;   pending      — balance still 0, ticks bumped, rotation kept
;;;   confirmed    — balance > 0, token file written, providers swapped,
;;;                  rotation cleared
;;;   timed-out    — ticks ≥ %token-fund-max-ticks, rotation cleared,
;;;                  no token file
;;;
;;; Driven by a mock SporeStack /balance endpoint with a single mutable
;;; cents value the test toggles between calls.
;;;
;;; Run:
;;;   guile -L module -L tests tests/fleet/test-token-rotation.scm

;; Redirect the token file, so 'confirmed writes here and not to the
;; deployment's /var/lib/playnet. `sporestack-token-file` reads the
;; environment when it is CALLED, so this no longer has to precede the
;; module's load — but setting it first still reads best.
(define %token-file
  (string-append "/tmp/test-sporestack-token-"
                 (number->string (getpid)) ".txt"))
(setenv "PLAYNET_SPORESTACK_TOKEN_FILE" %token-file)

(use-modules (goblins)
             (goblins vat)
             (goblins utils hashmap)
             (web request)
             (web response)
             (web uri)
             (rnrs bytevectors)
             (ice-9 format)
             (json)
             (ice-9 textual-ports)
             (srfi srfi-13)
             (playnet test harness)
             (playnet fleet sporestack)
             (playnet fleet records)
             (playnet fleet reconciler))

;;; ── Mutable mock state ───────────────────────────────────────────────────

(define %balance-cents 0)

(define (json-response code body)
  (values (build-response #:code code
                          #:reason-phrase "ok"
                          #:headers '((content-type . "application/json")))
          (string->utf8 (scm->json-string body))))

(define (handle-request request body)
  (let* ((method (request-method request))
         (path   (uri-path (request-uri request))))
    (cond
     ;; GET /token/<TOKEN>/balance
     ((and (eq? method 'GET)
           (string-suffix? "/balance" path))
      (json-response 200
        `(("cents" . ,%balance-cents)
          ("usd"   . ,(/ %balance-cents 100.0)))))
     (else
      (values (build-response #:code 404) "not found")))))

(define (string-suffix? suf s)
  (let ((sl (string-length s))
        (tl (string-length suf)))
    (and (>= sl tl)
         (string=? suf (substring s (- sl tl) sl)))))

(define-values (port _thread)
  (spawn-mock-server handle-request))
(define endpoint (format #f "http://127.0.0.1:~a" port))

(format #t "=== Starting mock SporeStack at ~a ===~%~%" endpoint)

;;; ── Spawn reconciler with a hand-crafted in-flight rotation ──────────────

(define vat (spawn-vat #:name "token-rotation-test"))

(define synthetic-token "ss_t_rotation_test_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
(define synthetic-creds (make-sporestack-creds endpoint synthetic-token))

(define (make-rec-with-rotation rotation)
  (with-vat vat
    (spawn ^fleet-reconciler
           #f                  ; policy
           '()                 ; providers (empty so 'confirmed inserts a fresh sporestack entry)
           #f                  ; swapper
           ""                  ; ssh-key-pub
           "/tmp/desired-fleet-stub.scm"
           "/tmp/hosts-stub.scm"
           (hashmap)
           0
           0
           rotation)))

;;; ── Phase 1: pending ─────────────────────────────────────────────────────

(format #t "── Phase 1: balance=0 → 'pending ──~%")
(set! %balance-cents 0)

(define rec1
  (make-rec-with-rotation
   `((token . ,synthetic-token)
     (creds . ,synthetic-creds)
     (ticks . 0)
     (started-at . 1700000000))))

(define s1 (with-vat vat ($ rec1 'advance-token-rotation!)))
(check "balance=0 → 'pending" (eq? s1 'pending))

(define after1 (with-vat vat ($ rec1 'token-rotation-status)))
(check "rotation still active after pending" (and after1 #t))
(check "ticks bumped to 1" (= 1 (assq-ref after1 'ticks)))

;;; ── Phase 2: confirmed ───────────────────────────────────────────────────

(format #t "~%── Phase 2: balance=500 → 'confirmed ──~%")
(set! %balance-cents 500)

;; A fresh actor per phase, so no phase inherits another's rotation state.
(define rec2
  (make-rec-with-rotation
   `((token . ,synthetic-token)
     (creds . ,synthetic-creds)
     (ticks . 3)
     (started-at . 1700000000))))

(define s2 (with-vat vat ($ rec2 'advance-token-rotation!)))
(check "balance>0 → 'confirmed" (eq? s2 'confirmed))

(define after2 (with-vat vat ($ rec2 'token-rotation-status)))
(check "rotation cleared after confirmed" (not after2))

;; The status method's `providers` field shows what's in the registry;
;; on 'confirmed the actor adds the SporeStack provider via
;; make-sporestack-provider.  Inspect via (status).
(define stat2 (with-vat vat ($ rec2 'status)))
(check "providers list contains sporestack after confirmed"
       (member "sporestack" (assq-ref stat2 'providers)))

;; The write lands where the override says, and nowhere else. This is the
;; assertion whose absence let the two definitions of this path disagree:
;; the gateway's boot copy ignored the override entirely, so 'confirmed
;; could write to /var/lib/playnet during a test run and only ever failed
;; as a bare "No such file or directory" from open-file.
(check "token written to the overridden path" (file-exists? %token-file))
(check "token file holds the rotated token"
       (equal? synthetic-token
               (string-trim-both
                (call-with-input-file %token-file get-string-all))))
(check "token file is 0600"
       (= #o600 (logand #o777 (stat:mode (stat %token-file)))))

;;; ── Phase 3: timed-out ───────────────────────────────────────────────────

(format #t "~%── Phase 3: ticks at cap → 'timed-out ──~%")
(set! %balance-cents 0)

;; Bump ticks past the cap.  %token-fund-max-ticks is private so we
;; just push it well past any plausible cap (1000).
(define rec3
  (make-rec-with-rotation
   `((token . ,synthetic-token)
     (creds . ,synthetic-creds)
     (ticks . 1000)
     (started-at . 1700000000))))

(define s3 (with-vat vat ($ rec3 'advance-token-rotation!)))
(check "ticks past cap → 'timed-out" (eq? s3 'timed-out))

(define after3 (with-vat vat ($ rec3 'token-rotation-status)))
(check "rotation cleared after timeout" (not after3))

;;; ── Phase 4: idle is no-op ───────────────────────────────────────────────

(format #t "~%── Phase 4: idle → 'idle (no-op) ──~%")
(define rec4 (make-rec-with-rotation #f))
(define s4 (with-vat vat ($ rec4 'advance-token-rotation!)))
(check "idle → 'idle" (eq? s4 'idle))
(check "still no rotation after idle advance"
       (not (with-vat vat ($ rec4 'token-rotation-status))))

(test-summary!)
