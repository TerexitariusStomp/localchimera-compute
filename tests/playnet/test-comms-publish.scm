;;; test-comms-publish.scm — the publishing "hands": dry-run, the human gate, and
;;; a REAL Mastodon POST against a local mock instance.
;;;
;;; Proves the send layer is safe by construction: the gate is fail-closed
;;; (nothing goes live without explicit approval), the default publisher only
;;; logs, and the Mastodon adapter actually performs the HTTP POST and parses the
;;; created status — the piece the planner side did not have.
;;;
;;; Run: guile -L module tests/playnet/test-comms-publish.scm

(use-modules (playnet test harness)
             (playnet interface adapters platforms)
             (playnet interface adapters comms-publish)
             (goblins) (goblins vat)
             (web server) (web response) (json) (rnrs bytevectors) (ice-9 format))

;; ── a mock Mastodon instance: any POST returns a created Status ─────────────
(define %last-status #f)
(define (handle-request request body)
  (catch #t
    (lambda ()
      (let ((s (if (bytevector? body) (utf8->string body) (or body ""))))
        (set! %last-status (and (not (string-null? s)) (json-string->scm s)))
        (values (build-response #:code 200)
                (scm->json-string
                 `(("id" . "12345") ("url" . "http://mock/@scope/12345"))))))
    (lambda (k . a)
      (format (current-error-port) "mock handler error: ~a ~a~%" k a)
      (values (build-response #:code 500) "err"))))

(define-values (%port %thread) (spawn-mock-server handle-request))
(define %base (format #f "http://127.0.0.1:~a" %port))
(define vat (spawn-vat))

;;; ─── 1. the dry-run publisher + the fail-closed human gate ─────────────────
(display "\n── dry-run default + fail-closed gate: nothing leaks ──\n")
(with-vat vat
  (let ((pub (spawn ^dry-run-publisher "reticulum")))
    (check "the gate HOLDS by default (fail-closed) — nothing is sent"
           (assq-ref (publish-with-gate pub "hello") 'held) #t)
    (check "with explicit approval the publisher accepts"
           (assq-ref (publish-with-gate pub "hello" #:approve? (lambda (_) #t)) 'ok) #t)
    (check "the dry-run result is flagged (it never touched a network)"
           (assq-ref (publish-with-gate pub "hi" #:approve? (lambda (_) #t)) 'dry-run) #t)))

;;; ─── 2. the Mastodon adapter performs a REAL HTTP POST (to the mock) ───────
(display "\n── the Mastodon adapter actually POSTs and parses the status ──\n")
(with-vat vat
  (let* ((post "Short 12 kg for Saturday's share — can you bring some? [cite:intent-food]")
         (tok  (spawn-mastodon %base "sealed-secret-token"))
         (res  (publish-with-gate tok post #:approve? (lambda (_) #t))))
    (check "the adapter reports ok" (assq-ref res 'ok) #t)
    (check "it POSTed and parsed the created status id" (assq-ref res 'id) "12345")
    (check "the instance received exactly the composed post as `status`"
           (assoc-ref %last-status "status") post)))

;;; ─── 3. an UNAPPROVED real-channel post never reaches the instance ─────────
(display "\n── the gate protects the real channel too (fail-closed) ──\n")
(set! %last-status 'untouched)
(with-vat vat
  (let* ((tok (spawn-mastodon %base "sealed-secret-token"))
         (res (publish-with-gate tok "unapproved!" )))   ; no #:approve? ⇒ refuse
    (check "an unapproved post is HELD" (assq-ref res 'held) #t)
    (check "the Mastodon instance was never contacted" %last-status 'untouched)))

(display "\n")
(test-summary!)
