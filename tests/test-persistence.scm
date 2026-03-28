;;; test-persistence.scm — Bloblin persist/restore round-trip tests
;;; Run with: guile -L module tests/test-persistence.scm

(define %project-root (string-append (dirname (current-filename)) "/.."))
(add-to-load-path (string-append %project-root "/module"))

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins actor-lib sealers)
             (goblins actor-lib ward)
             (goblins persistence-store bloblin)
             ((goblins utils crypto) #:select (generate-key-pair key-pair->public-key))
             (xorg org)
             (xorg gplay)
             (xorg endorsement)
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

;;; ── Temp directory helpers ──────────────────────────────────────────────────

(define test-counter 0)

(define (make-test-dir name)
  (set! test-counter (+ test-counter 1))
  (let ((dir (string-append "/tmp/xorg-test-persist-"
                            name "-"
                            (number->string (getpid)) "-"
                            (number->string test-counter))))
    (when (file-exists? dir)
      (system* "rm" "-rf" dir))
    (mkdir dir)
    dir))

(define (cleanup-test-dir dir)
  (system* "rm" "-rf" dir))

;;; ── Base bindings (shared) ──────────────────────────────────────────────────

(define test-base default-base-bindings)

(display "\n══ Persistence Round-Trip Tests ═══════════════════════════════\n")

;;; ── Test 1: Open org survives round-trip ─────────────────────────────────────

(display "\n── 1. Open org survives round-trip ──\n")

(let ((dir (make-test-dir "open-org")))
  (let ((store (make-bloblin-store dir)))
    ;; First run: create org via make-persistent-org, set bindings
    (receive (vat org inbox incanter refs)
      (make-persistent-org "test-open" test-base store)
      (with-vat vat
        (let ((gen ($ org 'current-expressor)))
          (evaluate '(modify! 'x 42) org '() gen)
          (evaluate '(modify! 'greeting "hello") org '() gen)
          (check "1a: binding set before persist"
                 (evaluate 'x org '() gen) 42)))
      (vat-halt! vat))

    ;; Second run: restore from store
    (receive (vat2 org2 inbox2 incanter2 refs2)
      (make-persistent-org "test-open" test-base store)
      (with-vat vat2
        (let ((gen ($ org2 'current-expressor)))
          (check "1b: numeric binding survives round-trip"
                 (evaluate 'x org2 '() gen) 42)
          (check "1c: string binding survives round-trip"
                 (evaluate 'greeting org2 '() gen) "hello")
          (check "1d: base bindings restored (+ works)"
                 (evaluate '(+ 1 2) org2 '() gen) 3)
          (check "1e: history preserved"
                 (>= (length ($ org2 'history)) 3) #t)))
      (vat-halt! vat2)))
  (cleanup-test-dir dir))

;;; ── Test 2: Governed org validator survives ──────────────────────────────────

(display "\n── 2. Governed org validator survives round-trip ──\n")

(let ((dir (make-test-dir "governed-org")))
  (let ((store (make-bloblin-store dir)))
    ;; First run: create governed org with faceted validator
    (receive (vat org-ref seal-infra sealed-infra?)
      (parameterize ((*restore-base-bindings* test-base))
        (spawn-persistent-vat
         gplay-env
         (lambda ()
           (receive (seal-infra _unseal-infra sealed-infra?)
             (make-endorsement-authority)
             (let* ((infra-pred  (name-prefix-predicate "infra-"))
                    (infra-facet (make-facet infra-pred sealed-infra?))
                    (validator   (spawn ^faceted-validator (list infra-facet)))
                    (org-ref     (make-initial-org test-base
                                                   #:validator validator)))
               (values org-ref seal-infra sealed-infra?))))
         store
         #:name "test-governed"
         #:version 1))

      ;; Verify governance works before persist
      (with-vat vat
        (let ((gen ($ org-ref 'current-expressor)))
          ;; Ungoverned name works
          (evaluate '(modify! 'budget 50000) org-ref '() gen)
          (check "2a: ungoverned name works"
                 (evaluate 'budget org-ref '() gen) 50000)
          ;; Governed name without endorsement fails
          (check-error "2b: infra-* blocked without seal"
            (evaluate '(modify! 'infra-deploy "deployer") org-ref '() gen))
          ;; Governed name with endorsement works
          (evaluate '(modify! 'infra-deploy (endorse "deployer" seal))
                    org-ref
                    `((seal . ,seal-infra))
                    gen)
          (check "2c: infra-deploy set with endorsement"
                 (pair? (assq 'infra-deploy ($ org-ref 'bindings))) #t)))
      (vat-halt! vat))

    ;; Second run: restore and verify governance still enforced
    (receive (vat2 org-ref2 seal-infra2 sealed-infra2?)
      (parameterize ((*restore-base-bindings* test-base))
        (spawn-persistent-vat
         gplay-env
         (lambda () (error "should not be called on restore"))
         store
         #:name "test-governed"
         #:version 1))

      (with-vat vat2
        (let ((gen ($ org-ref2 'current-expressor)))
          ;; Ungoverned name still works after restore
          (evaluate '(modify! 'notes "restored") org-ref2 '() gen)
          (check "2d: ungoverned name works after restore"
                 (evaluate 'notes org-ref2 '() gen) "restored")
          ;; Previous ungoverned binding survived
          (check "2e: budget binding survived"
                 (evaluate 'budget org-ref2 '() gen) 50000)
          ;; Governed name still blocked without endorsement
          (check-error "2f: infra-* still blocked after restore"
            (evaluate '(modify! 'infra-db "db-cap") org-ref2 '() gen))))
      (vat-halt! vat2)))
  (cleanup-test-dir dir))

;;; ── Test 3: Seals survive — infra-seal can still endorse after restore ──────

(display "\n── 3. Seals survive round-trip ──\n")

(let ((dir (make-test-dir "seals")))
  (let ((store (make-bloblin-store dir)))
    ;; First run: create governed org, persist immediately
    (receive (vat org-ref seal-infra sealed-infra?)
      (parameterize ((*restore-base-bindings* test-base))
        (spawn-persistent-vat
         gplay-env
         (lambda ()
           (receive (seal-infra _unseal sealed-infra?)
             (make-endorsement-authority)
             (let* ((pred    (name-prefix-predicate "infra-"))
                    (facet   (make-facet pred sealed-infra?))
                    (validator (spawn ^faceted-validator (list facet)))
                    (org-ref (make-initial-org test-base
                                               #:validator validator)))
               (values org-ref seal-infra sealed-infra?))))
         store
         #:name "test-seals"
         #:version 1))
      (vat-halt! vat))

    ;; Second run: restore, use restored seal to endorse
    (receive (vat2 org-ref2 seal-infra2 sealed-infra2?)
      (parameterize ((*restore-base-bindings* test-base))
        (spawn-persistent-vat
         gplay-env
         (lambda () (error "should not be called"))
         store
         #:name "test-seals"
         #:version 1))
      (with-vat vat2
        (let ((gen ($ org-ref2 'current-expressor)))
          ;; The restored seal-infra can still produce endorsements
          (evaluate '(modify! 'infra-nginx (endorse "nginx-cap" seal))
                    org-ref2
                    `((seal . ,seal-infra2))
                    gen)
          (check "3a: restored seal endorses, restored validator accepts"
                 (pair? (assq 'infra-nginx ($ org-ref2 'bindings))) #t)
          ;; Verify the endorsed value satisfies the restored sealed? predicate
          (let ((endorsed-val (assq-ref ($ org-ref2 'bindings) 'infra-nginx)))
            (check "3b: restored sealed? recognizes endorsement"
                   ($ sealed-infra2? endorsed-val) #t))))
      (vat-halt! vat2)))
  (cleanup-test-dir dir))

;;; ── Test 4: Capability actor binding survives ───────────────────────────────

(display "\n── 4. Capability actor binding survives round-trip ──\n")

(let ((dir (make-test-dir "cap-binding")))
  (let ((store (make-bloblin-store dir)))
    ;; First run: create org with a ^ref-store as a capability stand-in
    (receive (vat org-ref cap-actor)
      (parameterize ((*restore-base-bindings* test-base))
        (spawn-persistent-vat
         gplay-env
         (lambda ()
           (let* ((cap (spawn ^ref-store '((status . "ready"))))
                  (org-ref (make-initial-org test-base)))
             (values org-ref cap)))
         store
         #:name "test-cap"
         #:version 1))
      ;; Bind the cap actor in the org
      (with-vat vat
        (let ((gen ($ org-ref 'current-expressor)))
          (evaluate '(modify! 'deploy-cap cap)
                    org-ref
                    `((cap . ,cap-actor))
                    gen)
          ;; Verify it's callable
          (check "4a: cap actor callable before persist"
                 (assq-ref ($ cap-actor 'get) 'status) "ready")))
      (vat-halt! vat))

    ;; Second run: restore and verify cap actor still callable
    (receive (vat2 org-ref2 cap-actor2)
      (parameterize ((*restore-base-bindings* test-base))
        (spawn-persistent-vat
         gplay-env
         (lambda () (error "should not be called"))
         store
         #:name "test-cap"
         #:version 1))
      (with-vat vat2
        (let* ((gen ($ org-ref2 'current-expressor))
               (restored-cap (evaluate 'deploy-cap org-ref2 '() gen)))
          (check "4b: cap binding present after restore"
                 (not (not restored-cap)) #t)
          (check "4c: restored cap actor is callable"
                 (assq-ref ($ restored-cap 'get) 'status) "ready")
          ;; Also verify the root cap ref matches
          (check "4d: root cap ref also works"
                 (assq-ref ($ cap-actor2 'get) 'status) "ready")))
      (vat-halt! vat2)))
  (cleanup-test-dir dir))

;;; ── Test 5: History with signatures survives ─────────────────────────────────

(display "\n── 5. History with signatures survives round-trip ──\n")

(let ((dir (make-test-dir "signatures")))
  (let* ((store (make-bloblin-store dir))
         (kp (generate-key-pair))
         (pk (key-pair->public-key kp)))
    ;; First run: create expressor with keypair, make signed modifications
    (receive (vat org inbox incanter refs)
      (make-persistent-org "test-sigs" test-base store)
      (with-vat vat
        (let* ((gen ($ org 'current-expressor))
               (sealer (evaluate '(defexpressor 'alice kp)
                                 org
                                 `((kp . ,kp))
                                 gen)))
          ;; Modify as alice (signed)
          (evaluate '(as seal (modify! 'x 42))
                    org
                    `((seal . ,sealer))
                    gen)
          ;; Verify signature before persist
          (let ((latest (car ($ org 'history))))
            (check "5a: entry signed before persist"
                   (not (not (list-ref latest 5))) #t)
            (check "5b: verify passes before persist"
                   (verify-history-entry latest pk) #t))))
      (vat-halt! vat))

    ;; Second run: restore, verify signatures still valid
    (receive (vat2 org2 inbox2 incanter2 refs2)
      (make-persistent-org "test-sigs" test-base store)
      (with-vat vat2
        (let* ((history ($ org2 'history))
               ;; Find signed entries (have 6 elements with non-#f signature)
               (signed (filter (lambda (e)
                                 (and (>= (length e) 6)
                                      (list-ref e 5)))
                               history)))
          (check "5c: signed entries present after restore"
                 (> (length signed) 0) #t)
          (check "5d: signature still verifies after restore"
                 (every (lambda (e) (verify-history-entry e pk)) signed) #t)
          ;; Verify binding also survived
          (check "5e: binding survives with signed history"
                 (evaluate 'x org2 '() ($ org2 'current-expressor)) 42)))
      (vat-halt! vat2)))
  (cleanup-test-dir dir))

;;; ── Test 6: Output-cap survives ──────────────────────────────────────────────

(display "\n── 6. Output-cap survives round-trip ──\n")

(let ((dir (make-test-dir "output-cap")))
  (let ((store (make-bloblin-store dir)))
    ;; First run: create org with output-cap
    (receive (vat org-ref)
      (parameterize ((*restore-base-bindings* test-base))
        (spawn-persistent-vat
         gplay-env
         (lambda ()
           (let ((out (spawn ^output-port (current-output-port))))
             (values (make-initial-org test-base #:output-cap out))))
         store
         #:name "test-output"
         #:version 1))
      (with-vat vat
        (let ((gen ($ org-ref 'current-expressor)))
          ;; Verify display works before persist
          (check "6a: display works before persist"
                 (begin
                   (evaluate '(display "  [output before persist]\n") org-ref '() gen)
                   #t)
                 #t)))
      (vat-halt! vat))

    ;; Second run: restore, verify display still works
    (receive (vat2 org-ref2)
      (parameterize ((*restore-base-bindings* test-base))
        (spawn-persistent-vat
         gplay-env
         (lambda () (error "should not be called"))
         store
         #:name "test-output"
         #:version 1))
      (with-vat vat2
        (let ((gen ($ org-ref2 'current-expressor)))
          ;; display should delegate to restored output-cap
          (check "6b: display works after restore"
                 (begin
                   (evaluate '(display "  [output after restore]\n") org-ref2 '() gen)
                   #t)
                 #t)
          ;; write should also work
          (check "6c: write works after restore"
                 (begin
                   (evaluate '(write 42) org-ref2 '() gen)
                   (evaluate '(newline) org-ref2 '() gen)
                   #t)
                 #t)))
      (vat-halt! vat2)))
  (cleanup-test-dir dir))

;;; ── Summary ─────────────────────────────────────────────────────────────────

(display "\n══════════════════════════════════════════════════════════════\n")
(format #t "Results: ~a passed, ~a failed\n" pass-count fail-count)
(when (> fail-count 0)
  (exit 1))
