;;; test-ai-expressor.scm — tests for AI as its own expressor
;;; Run with: guile -L module tests/test-ai-expressor.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib sealers)
             ((goblins utils crypto) #:select (generate-key-pair key-pair->public-key))
             (xorg org)
             (xorg gplay)
             (xorg endorsement)
             (xorg ai-expressor)
             (ice-9 receive)
             (ice-9 match)
             (srfi srfi-1))

;;; ── Harness ─────────────────────────────────────────────────────────────────

(define pass-count 0)
(define fail-count 0)

(define (check label got expected)
  (if (equal? got expected)
      (begin (set! pass-count (+ pass-count 1))
             (display (string-append "  PASS  " label "\n")))
      (begin (set! fail-count (+ fail-count 1))
             (display (string-append "  FAIL  " label "\n"))
             (display "    expected: ") (write expected) (newline)
             (display "    got:      ") (write got)      (newline))))

(define-syntax check-error
  (syntax-rules ()
    ((_ label body ...)
     (check label
            (catch #t
              (lambda () body ... #f)
              (lambda (key . args) #t))
            #t))))

;;; ── Mock AI handler ─────────────────────────────────────────────────────────
;;; Returns a known expression so we can test attribution and authority
;;; without a real AI backend.

(define *mock-ai-result* '(modify! 'ai-output "from-ai"))

(define (mock-ai-eval-handler prompt ref expressor-id)
  "Mock handler that returns a fixed expression."
  *mock-ai-result*)

;; Install the mock handler
(set-ai-eval-handler! mock-ai-eval-handler)

(display "\n══ AI Expressor Tests ════════════════════════════════════════\n")

;;; ── Test 1: make-ai-expressor! creates an expressor ──────────────────────────

(display "\n── 1. make-ai-expressor! creates an expressor with its own sealer ──\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-ai-1")
  (receive (ai-seal ai-pk)
    (make-ai-expressor! org #:name 'test-ai)
    (with-vat (org-vat org)
      (let* ((ref (org-ref org))
             ;; Verify the AI expressor exists
             (ai-id ($ ref 'authenticate-sealer ai-seal)))
        (check "1a: AI expressor registered"
               (not (not ai-id)) #t)
        (check "1b: AI expressor has a name"
               ($ ref 'expressor-name ai-id) 'test-ai)
        (check "1c: AI public key is not #f"
               (not (not ai-pk)) #t)
        ;; Verify it's distinct from genesis
        (check "1d: AI expressor is different from genesis"
               (not (equal? ai-id ($ ref 'current-expressor))) #t)))))

;;; ── Test 2: AI history entries attributed to AI expressor ────────────────────

(display "\n── 2. AI history entries attributed to AI expressor ──\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-ai-2")
  (receive (ai-seal ai-pk)
    (make-ai-expressor! org #:name 'ai-bot)
    (with-vat (org-vat org)
      (let* ((ref (org-ref org))
             (gen ($ ref 'current-expressor))
             (ai-id ($ ref 'authenticate-sealer ai-seal)))
        ;; AI modifies a binding directly (as ai-seal)
        (evaluate '(as seal (modify! 'ai-note "hello from ai"))
                  ref
                  `((seal . ,ai-seal))
                  gen)
        ;; Check latest history entry is attributed to AI, not genesis
        (let* ((latest (car ($ ref 'history)))
               (entry-expressor (cadr latest)))
          (check "2a: history entry attributed to AI expressor"
                 entry-expressor ai-id)
          (check "2b: entry NOT attributed to genesis"
                 (not (equal? entry-expressor gen)) #t)
          ;; Verify signature with AI's public key
          (check "2c: entry signed by AI's keypair"
                 (verify-history-entry latest ai-pk) #t))))))

;;; ── Test 3: AI cannot modify governed names without endorsement ──────────────

(display "\n── 3. AI cannot modify governed names without endorsement ──\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-ai-3")
  (receive (ai-seal ai-pk)
    (make-ai-expressor! org #:name 'ai-limited)
    (with-vat (org-vat org)
      (let* ((ref (org-ref org))
             (gen ($ ref 'current-expressor)))
        ;; AI can set ungoverned names
        (evaluate '(as seal (modify! 'notes "ai was here"))
                  ref
                  `((seal . ,ai-seal))
                  gen)
        (check "3a: AI can set ungoverned names"
               (evaluate 'notes ref '() gen) "ai was here")
        ;; AI cannot set governed (infra-*) names without infra-seal
        (check-error "3b: AI blocked on infra-* names"
          (evaluate '(as seal (modify! 'infra-deploy "bad"))
                    ref
                    `((seal . ,ai-seal))
                    gen))
        ;; AI cannot set governed (member-*) names without member-seal
        (check-error "3c: AI blocked on member-* names"
          (evaluate '(as seal (modify! 'member-new "bad"))
                    ref
                    `((seal . ,ai-seal))
                    gen))))))

;;; ── Test 4: ai-eval-as runs expression under AI's authority ──────────────────

(display "\n── 4. ai-eval-as runs under AI's authority ──\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-ai-4")
  (receive (ai-seal ai-pk)
    (make-ai-expressor! org #:name 'ai-eval-test)
    (with-vat (org-vat org)
      (let* ((ref (org-ref org))
             (gen ($ ref 'current-expressor))
             (ai-id ($ ref 'authenticate-sealer ai-seal)))
        ;; Use ai-eval-as: the mock handler returns (modify! 'ai-output "from-ai")
        ;; This should run under the AI's authority
        (evaluate '(ai-eval-as seal "generate something")
                  ref
                  `((seal . ,ai-seal))
                  gen)
        ;; Verify the binding was set
        (check "4a: ai-eval-as created binding"
               (evaluate 'ai-output ref '() gen) "from-ai")
        ;; Verify the history entry is attributed to the AI
        (let* ((latest (car ($ ref 'history)))
               (entry-expressor (cadr latest)))
          (check "4b: ai-eval-as entry attributed to AI"
                 entry-expressor ai-id)
          ;; Verify signature
          (check "4c: ai-eval-as entry signed by AI's key"
                 (verify-history-entry latest ai-pk) #t))))))

;;; ── Test 5: AI expressor with extra-bindings ─────────────────────────────────

(display "\n── 5. AI expressor with extra-bindings ──\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-ai-5")
  ;; Create the endorsed value inside the vat first
  (let ((endorsed-deploy (with-vat (org-vat org)
                           (endorse "nginx-deployer" infra-seal))))
    ;; make-ai-expressor! does its own with-vat, so call from outside
    (receive (ai-seal ai-pk)
      (make-ai-expressor! org
                          #:name 'ai-with-extras
                          #:extra-bindings `((ai-deploy . ,endorsed-deploy)))
      ;; Now verify inside the vat
      (with-vat (org-vat org)
        (let* ((ref (org-ref org))
               (gen ($ ref 'current-expressor)))
          ;; The AI's extra-binding should be in the org
          (check "5a: extra-binding stored in org"
                 (pair? (assq 'ai-deploy ($ ref 'bindings))) #t)
          ;; The extra-binding was set by the AI (attributed to AI)
          (let* ((ai-id ($ ref 'authenticate-sealer ai-seal))
                 ;; Find the history entry for the ai-deploy modification
                 (deploy-entry (find (lambda (e)
                                       (match (caddr e)
                                         (('modify! ('quote 'ai-deploy) _) #t)
                                         (_ #f)))
                                     ($ ref 'history))))
            (check "5b: extra-binding entry attributed to AI"
                   (and deploy-entry (equal? (cadr deploy-entry) ai-id)) #t)))))))

;;; ── Test 6: Two AI expressors have different scopes ──────────────────────────

(display "\n── 6. Two AI expressors have different capability scopes ──\n")

(receive (org gov-seal infra-seal member-seal)
  (make-governed-org "test-ai-6")
  ;; Create endorsed values inside vat first
  (let ((endorsed-infra (with-vat (org-vat org) (endorse "infra-cap" infra-seal)))
        (endorsed-member (with-vat (org-vat org) (endorse "member-cap" member-seal))))
    ;; AI-1 gets infra capability (make-ai-expressor! does own with-vat)
    (receive (ai1-seal ai1-pk)
      (make-ai-expressor! org
                          #:name 'ai-infra
                          #:extra-bindings `((ai1-cap . ,endorsed-infra)))
      ;; AI-2 gets member capability
      (receive (ai2-seal ai2-pk)
        (make-ai-expressor! org
                            #:name 'ai-member
                            #:extra-bindings `((ai2-cap . ,endorsed-member)))
        ;; Now verify everything inside vat
        (with-vat (org-vat org)
          (let* ((ref (org-ref org))
                 (gen ($ ref 'current-expressor))
                 (ai1-id ($ ref 'authenticate-sealer ai1-seal))
                 (ai2-id ($ ref 'authenticate-sealer ai2-seal)))
            ;; Verify they're different expressors
            (check "6a: two AIs are different expressors"
                   (not (equal? ai1-id ai2-id)) #t)
            ;; Verify they have different public keys
            (check "6b: different public keys"
                   (not (equal? ai1-pk ai2-pk)) #t)
            ;; Verify each has their own extra-binding
            (check "6c: AI-1 extra-binding exists"
                   (pair? (assq 'ai1-cap ($ ref 'bindings))) #t)
            (check "6d: AI-2 extra-binding exists"
                   (pair? (assq 'ai2-cap ($ ref 'bindings))) #t)
            ;; Both can set ungoverned names independently
            (evaluate '(as seal (modify! 'ai1-note "from ai-1"))
                      ref `((seal . ,ai1-seal)) gen)
            (evaluate '(as seal (modify! 'ai2-note "from ai-2"))
                      ref `((seal . ,ai2-seal)) gen)
            (check "6e: AI-1 set its own note"
                   (evaluate 'ai1-note ref '() gen) "from ai-1")
            (check "6f: AI-2 set its own note"
                   (evaluate 'ai2-note ref '() gen) "from ai-2")
            ;; Verify signatures are from different keys
            (let* ((history ($ ref 'history))
                   (ai2-entry (car history))
                   (ai1-entry (cadr history)))
              (check "6g: AI-1 entry verifies with AI-1 key"
                     (verify-history-entry ai1-entry ai1-pk) #t)
              (check "6h: AI-2 entry verifies with AI-2 key"
                     (verify-history-entry ai2-entry ai2-pk) #t)
              (check "6i: cross-key verification fails"
                     (verify-history-entry ai1-entry ai2-pk) #f))))))))

;;; ── Test 7: ai-eval-as with invalid sealer errors ───────────────────────────

(display "\n── 7. ai-eval-as rejects invalid sealers ──\n")

(let ((org (make-open-org "test-ai-7")))
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (gen ($ ref 'current-expressor)))
      ;; Try ai-eval-as with a non-sealer value
      (check-error "7a: ai-eval-as rejects non-sealer"
        (evaluate '(ai-eval-as 42 "prompt")
                  ref '() gen)))))

;;; ── Test 8: Existing ai-eval still works unchanged ──────────────────────────

(display "\n── 8. Existing ai-eval backward-compatible ──\n")

(let ((org (make-open-org "test-ai-8")))
  (with-vat (org-vat org)
    (let* ((ref (org-ref org))
           (gen ($ ref 'current-expressor)))
      ;; ai-eval uses the mock handler and runs as genesis
      (evaluate '(ai-eval "do something") ref '() gen)
      (check "8a: ai-eval still works"
             (evaluate 'ai-output ref '() gen) "from-ai")
      ;; The entry should be attributed to genesis (not an AI expressor)
      (let ((latest (car ($ ref 'history))))
        (check "8b: ai-eval attributed to calling expressor"
               (cadr latest) gen)))))

;;; ── Summary ─────────────────────────────────────────────────────────────────

(display "\n══════════════════════════════════════════════════════════════\n")
(format #t "Results: ~a passed, ~a failed\n" pass-count fail-count)
(when (> fail-count 0)
  (exit 1))
