;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/tools/test-playnet-scope.scm
;;;
;;; Pure-Scheme parts of tools/dev/playnet-scope.scm: scope-summary,
;;; custody-mode, list-known-scope-aids, and the vault-key migration
;;; sequence (decrypt under K1, re-encrypt under K2). The shell-out
;;; export/import via tar+age is exercised end-to-end in the
;;; multi-gateway integration test (Pillar C); here we keep the deps
;;; minimal so this test runs in any environment with libsodium.
;;;
;;; Run: guile -L module -L tests tests/tools/test-playnet-scope.scm

;; the host crypto backend: loading (playnet keri signify) installs it
(use-modules ((playnet keri signify) #:select ()))
(use-modules (playnet test harness)
             (playnet utils paths)
             ;; vault helpers are exported via (playnet boot prelude);
             ;; bran-custody is `include-from-path`'d, not its own module.
             ((playnet keys bran-custody) #:select (read-vault-bran write-vault-bran!))
             ((playnet utils hex) #:select (hex->bv bv->hex))
             (rnrs bytevectors)
             (ice-9 ftw))

;; Load the tool's pure-Scheme helpers by evaluating the script file
;; into our module. The script ends with `(main (command-line))` which
;; would try to dispatch — we don't want that, so we redefine main
;; first to no-op before loading.

(define (no-op . _) #t)

;; Pre-bind main so the load-time call at end of script is harmless.
(define main no-op)
(define here (dirname (car (command-line))))
(primitive-load (string-append here "/../../tools/dev/playnet-scope.scm"))
;; main is now the tool's main, but we never call it from here.

;; Sandbox.
(define %tmp-root
  (let ((p (string-append "/tmp/playnet-scope-test-"
                          (number->string (getpid)))))
    (ensure-directory! p)
    p))
(current-playnet-state-dir-override %tmp-root)

(define (rm-rf path)
  (when (file-exists? path)
    (cond
     ((eq? (stat:type (lstat path)) 'directory)
      (for-each (lambda (e) (unless (member e '("." ".."))
                              (rm-rf (string-append path "/" e))))
                (or (scandir path) '()))
      (rmdir path))
     (else (delete-file path)))))

;; ── Synthetic scope on disk ──────────────────────────────────────────

(define %fed-aid "E_test_fed_AID_xxxxxxxxxxxxxxxxxxxxxxxxxxx")
(define %commune-aid "E_test_commune_AID_yyyyyyyyyyyyyyyyyyyyyyyy")
(define %key-1 (make-string 64 #\a))   ; 32 bytes of 0xAA in hex
(define %key-2 (make-string 64 #\b))   ; 32 bytes of 0xBB

(define (mk-scope! aid kind)
  (ensure-directory! (scope-acdc-dir aid))
  (ensure-directory! (scope-kel-dir aid))
  (write-scope-kind! aid kind)
  (write-scope-aid-name! aid (default-scope-aid-name aid))
  ;; Write a fake credential file under acdc/00/
  (ensure-directory! (string-append (scope-acdc-dir aid) "/00"))
  (call-with-output-file (string-append (scope-acdc-dir aid) "/00/cred-1.scm")
    (lambda (p) (write '((said . "Ecred1") (schema . "test/v1")) p)))
  ;; And one fake KEL event under kel/00/
  (ensure-directory! (string-append (scope-kel-dir aid) "/00"))
  (call-with-output-file (string-append (scope-kel-dir aid) "/00/icp.scm")
    (lambda (p) (write '((t . "icp") (i . "E...")) p)))
  ;; And encrypt a tiny "bran" under %key-1
  (let ((bran (string->utf8 "this-is-a-fake-bran-of-21-chars")))
    (write-vault-bran! bran (scope-vault-path aid)
                       #:key-bv (hex->bv %key-1))))

(mk-scope! %fed-aid 'federation)
(mk-scope! %commune-aid 'commune)

;; ── list-known-scope-aids ────────────────────────────────────────────

(check "list-known-scope-aids: finds both"
       (= 2 (length (list-known-scope-aids))))

(check "list-known-scope-aids: includes the federation"
       (member %fed-aid (list-known-scope-aids)))

;; ── custody-mode ────────────────────────────────────────────────────

(check "custody-mode: federation is vault (bran.vault present)"
       (eq? 'vault (custody-mode %fed-aid)))

;; ── scope-summary ───────────────────────────────────────────────────

(let ((s (scope-summary %fed-aid)))
  (check "summary: aid"      (assq-ref s 'aid)      %fed-aid)
  (check "summary: kind"     (assq-ref s 'kind)     'federation)
  (check "summary: aid-name" (assq-ref s 'aid-name)
         (default-scope-aid-name %fed-aid))
  (check "summary: custody"  (assq-ref s 'custody)  'vault)
  (check "summary: acdc-count" (assq-ref s 'acdc-count) 1)
  (check "summary: kel-count"  (assq-ref s 'kel-count)  1))

;; ── Vault-key migration (the load-bearing portability check) ────────
;;
;; Source host encrypted under %key-1. Destination host has %key-2.
;; Migration: decrypt under K1, re-encrypt under K2 in place. The
;; restored bran must round-trip byte-for-byte.

(define %original-bran
  (read-vault-bran (scope-vault-path %fed-aid) #:key-bv (hex->bv %key-1)))

(check "decrypt under K1 returns 31-byte bran"
       (= 31 (bytevector-length %original-bran)))

;; Now re-encrypt under K2 (simulating the `import -k` workflow)
(write-vault-bran! %original-bran (scope-vault-path %fed-aid)
                   #:key-bv (hex->bv %key-2))

(check "re-encrypted vault decrypts under K2"
       (let ((b (read-vault-bran (scope-vault-path %fed-aid)
                                  #:key-bv (hex->bv %key-2))))
         (bytevector=? %original-bran b)))

(check "re-encrypted vault does NOT decrypt under K1 (different ciphertext)"
       (catch #t
         (lambda ()
           (read-vault-bran (scope-vault-path %fed-aid)
                            #:key-bv (hex->bv %key-1))
           #f)
         (lambda _ #t)))

;; ── truncate-aid ────────────────────────────────────────────────────

(check "truncate-aid: short aid passes through"
       (truncate-aid "short") "short")

(check "truncate-aid: long aid truncated with ellipsis"
       (string-suffix? "…" (truncate-aid %fed-aid)))

;; ── Shamir round-trip (export-shamir → import-shamir) ─────────────
;;
;; The cleanest single-process Shamir test: split bran into 3-of-5,
;; gather any 3 share files, reconstitute, assert byte-equal bran.
;; Uses the same shamir-split / shamir-combine that
;; keys/bran-custody.scm uses internally, plus our CLI's wrapping.

(use-modules ((playnet crypto shamir) #:select (shamir-split shamir-combine))
             ((playnet credentials keys) #:select (make-bran-share-credential)) ((playnet keri acdc) #:select (cred-claim)))

(define %shamir-aid "E_shamir_test_AID_zzzzzzzzzzzzzzzzzzzzzzzzz")
(mk-scope! %shamir-aid 'federation)

(define %original-shamir-bran
  (read-vault-bran (scope-vault-path %shamir-aid) #:key-bv (hex->bv %key-1)))

;; Use a fresh bran for the Shamir test (the make-string fake from
;; mk-scope! is only 31 bytes; shamir-split wants 32)
(define %shamir-bran-32
  (let ((bv (make-bytevector 32 0)))
    (do ((i 0 (1+ i))) ((>= i 32))
      (bytevector-u8-set! bv i (modulo (* i 31) 256)))
    bv))

(define %holder-aids
  '("E_holder_A_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    "E_holder_B_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    "E_holder_C_cccccccccccccccccccccccccccccc"
    "E_holder_D_dddddddddddddddddddddddddddddd"
    "E_holder_E_eeeeeeeeeeeeeeeeeeeeeeeeeeeeee"))
(define %threshold 3)

;; Split + write share files (mirrors what export-shamir does after
;; reading the bran from vault).
(define %share-dir (string-append %tmp-root "/shares-test"))
(ensure-directory! %share-dir)
(let* ((shares (shamir-split %shamir-bran-32 %threshold 5))
       (n      5))
  (for-each
   (lambda (holder share)
     (let* ((idx       (car share))
            (k         (cadr share))
            (share-bv  (caddr share))
            (share-hex (bv->hex share-bv))
            (cred (make-bran-share-credential
                   #:issuer-group-aid %shamir-aid
                   #:holder-aid holder
                   #:share-index idx
                   #:threshold k
                   #:total-shares n
                   #:share-data-hex share-hex
                   #:subject-aid %shamir-aid))
            (filename (string-append %share-dir
                                     (format #f "/share-~a.scm" idx))))
       (call-with-output-file filename
         (lambda (port) (write cred port) (newline port)))))
   %holder-aids shares))

(check "Shamir: 5 share files written"
       (= 5 (length (filter (lambda (f) (string-suffix? ".scm" f))
                            (or (scandir %share-dir) '())))))

;; Now gather any 3 + reconstitute (mirrors import-shamir's body)
(let* ((share-files
        (filter (lambda (f) (string-suffix? ".scm" f))
                (or (scandir %share-dir) '())))
       (creds
        (filter-map
         (lambda (f)
           (let ((cred (read-sexp-file (string-append %share-dir "/" f))))
             (and cred
                  (equal? %shamir-aid (cred-claim cred 'subject-aid))
                  cred)))
         share-files))
       (shares-for-combine
        (map (lambda (c)
               (list (cred-claim c 'share-index)
                     (cred-claim c 'threshold)
                     (hex->bv (cred-claim c 'share-data))))
             (list-head creds %threshold)))
       (reconstituted (shamir-combine shares-for-combine)))
  (check "Shamir: reconstituted bran matches original (byte-for-byte)"
         (bytevector=? %shamir-bran-32 reconstituted)))

;; Cleanup
(rm-rf %tmp-root)

(test-summary!)
