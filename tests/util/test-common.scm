;;; tests/util/test-common.scm — unit tests for the shared util helpers

(use-modules (playnet test harness)
             (playnet utils common))

;; ── safe-call ───────────────────────────────────────────────────────

(check "safe-call: success returns thunk's value"
       (safe-call (lambda () 42)) 42)

(check "safe-call: error returns default #f"
       (safe-call (lambda () (error "boom"))) #f)

(check "safe-call: error returns explicit default"
       (safe-call (lambda () (error "boom")) 'fallback) 'fallback)

(check "safe-call: error doesn't propagate"
       (let ((reached? #f))
         (safe-call (lambda () (error "x")))
         (set! reached? #t)
         reached?))

;; ── for-each-catching ───────────────────────────────────────────────

(define %ran '())

(for-each-catching "test"
                   (lambda (x)
                     (set! %ran (cons x %ran))
                     (when (eq? x 'fail) (error "intentional")))
                   '(a b fail c))

(check "for-each-catching: all items attempted"
       (equal? (reverse %ran) '(a b fail c)))

;; ── env-int ─────────────────────────────────────────────────────────

;; Set a temp env var via setenv (Guile core).
(setenv "TEST_ENV_INT_OK"  "42")
(setenv "TEST_ENV_INT_BAD" "not-a-number")
(setenv "TEST_ENV_INT_EMPTY" "")

(check "env-int: valid integer parsed"
       (env-int "TEST_ENV_INT_OK" 99) 42)

(check "env-int: unparseable falls back to default"
       (env-int "TEST_ENV_INT_BAD" 99) 99)

(check "env-int: empty falls back to default"
       (env-int "TEST_ENV_INT_EMPTY" 99) 99)

(check "env-int: missing falls back to default"
       (env-int "TEST_ENV_INT_DOES_NOT_EXIST" 99) 99)

;; ── parse-csv-env ───────────────────────────────────────────────────

(setenv "TEST_CSV_OK"     "a,b ,c,, d  ")
(setenv "TEST_CSV_EMPTY"  "")
(setenv "TEST_CSV_SINGLE" "only")

(check "parse-csv-env: parses + trims + drops empties"
       (parse-csv-env "TEST_CSV_OK") '("a" "b" "c" "d"))

(check "parse-csv-env: empty env → '()"
       (parse-csv-env "TEST_CSV_EMPTY") '())

(check "parse-csv-env: missing env → '()"
       (parse-csv-env "TEST_CSV_DOES_NOT_EXIST") '())

(check "parse-csv-env: single entry"
       (parse-csv-env "TEST_CSV_SINGLE") '("only"))

;; ── read-sexp-file ──────────────────────────────────────────────────

(define %tmp-sexp (string-append "/tmp/test-common-sexp-"
                                 (number->string (getpid))))

(call-with-output-file %tmp-sexp
  (lambda (p) (write '((alpha . 1) (beta . 2)) p) (newline p)))

(check "read-sexp-file: roundtrip"
       (read-sexp-file %tmp-sexp) '((alpha . 1) (beta . 2)))

(check "read-sexp-file: missing → #f"
       (read-sexp-file "/tmp/definitely-does-not-exist.scm") #f)

(delete-file %tmp-sexp)

;; ── read-all-sexps-file ─────────────────────────────────────────────

(define %tmp-all (string-append "/tmp/test-common-all-"
                                (number->string (getpid))))

(call-with-output-file %tmp-all
  (lambda (p)
    (write '(first 1) p) (newline p)
    (write '(second 2) p) (newline p)
    (write '(third 3) p) (newline p)))

(check "read-all-sexps-file: roundtrip three entries"
       (read-all-sexps-file %tmp-all)
       '((first 1) (second 2) (third 3)))

(check "read-all-sexps-file: missing → '()"
       (read-all-sexps-file "/tmp/definitely-does-not-exist.scm") '())

(delete-file %tmp-all)

;; ── peer-base-urls (lives in keri/governance) — quick coverage ──────

(use-modules ((playnet governance keri federation-peers) #:select (peer-base-urls)))

(setenv "PLAYNET_PEERS"
        "https://gw1.example/oobi/E_aid1,https://gw2.example:8080/oobi/E_aid2,,https://gw3.example")

(check "peer-base-urls: strips /oobi/ suffix"
       (peer-base-urls)
       '("https://gw1.example"
         "https://gw2.example:8080"
         "https://gw3.example"))

(setenv "PLAYNET_PEERS" "")

(check "peer-base-urls: empty env → '()"
       (peer-base-urls) '())

(test-summary!)
