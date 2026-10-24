#!/usr/bin/env -S guile --no-auto-compile
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; tools/dev/localchimera-scope.scm — operator CLI for scope inspection + handoff
;;;
;;; The IPEX pipeline made scopes cryptographically portable: a scope's
;;; state directory + the bran (vault or Shamir) is the complete
;;; artifact. `restore-all-scopes!` rebuilds the actor on the
;;; destination. This CLI surfaces the operator workflow around that:
;;; inspect what's on disk, validate before handing off, pack/unpack
;;; the tarball, optionally re-encrypt the bran when the destination
;;; uses a different LOCALCHIMERA_VAULT_KEY.
;;;
;;; Subcommands:
;;;
;;;   list                 every scope on this host with kind + status
;;;   inspect <aid>        full detail for one scope
;;;   validate <aid>       dry-run: bran decrypts, KEL/ACDC counts sane
;;;   export <aid> [-o]    tar + age-encrypt <state>/scopes/<aid>/
;;;   import <file>        unpack + optionally re-encrypt bran
;;;   export-shamir <aid>  split bran k-of-n, write share-ACDC files
;;;   import-shamir <aid>  reconstitute bran from gathered share files
;;;
;;; Reuses the on-disk schema from (localchimera utils paths) so any
;;; future schema change lands here automatically. The Shamir subcommands
;;; wrap (localchimera crypto shamir)'s split/combine + make-bran-share-credential
;;; so the wire format matches what keys/bran-custody.scm uses internally.
;;;
;;; Usage:
;;;   guile -L module tools/dev/localchimera-scope.scm <subcommand> [args]
;;;
;;; Or via the executable shebang if PATH has guile + libsodium loaded.

(use-modules (ice-9 ftw)
             (ice-9 format)
             (ice-9 getopt-long)
             (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1)
             ((srfi srfi-13)
              #:select (string-prefix? string-suffix?
                        string-trim-both string-null?))
             ((rnrs io ports) #:select (get-bytevector-n put-bytevector))
             (localchimera utils paths)
             ((localchimera keri signify) #:select ())   ; loading it installs the crypto backend the vault helpers use
             ((localchimera keys bran-custody) #:select (read-vault-bran write-vault-bran! host-vault-key)) ((localchimera credentials keys) #:select (make-bran-share-credential)) ((localchimera keri acdc) #:select (cred-said cred-claim cred-revoked?))
             ((localchimera crypto shamir) #:select (shamir-split shamir-combine))
             ((localchimera utils hex) #:select (hex->bv bv->hex))
             ((localchimera utils common) #:select (read-sexp-file)))

;; ─────────────────────────────────────────────────────────────────────
;; Helpers
;; ─────────────────────────────────────────────────────────────────────

(define (die fmt . args)
  (apply format (current-error-port) (string-append fmt "~%") args)
  (exit 1))

(define (info fmt . args)
  (apply format #t (string-append fmt "~%") args))

(define (scopes-root)
  (string-append (localchimera-state-dir) "/scopes"))

(define (list-known-scope-aids)
  "Return list of AID prefixes that look like real scope state on disk."
  (let ((dir (scopes-root)))
    (if (not (file-exists? dir))
        '()
        (or (scandir dir
                     (lambda (entry)
                       (and (not (member entry '("." "..")))
                            (file-exists?
                             (string-append dir "/" entry "/acdc")))))
            '()))))

(define (count-files-recursive path)
  "Count files (not directories) under PATH. Used for ACDC + KEL counts."
  (cond
   ((not (file-exists? path)) 0)
   ((not (eq? 'directory (stat:type (lstat path)))) 1)
   (else
    (apply + (map (lambda (entry)
                    (if (member entry '("." ".."))
                        0
                        (count-files-recursive
                         (string-append path "/" entry))))
                  (or (scandir path) '()))))))

(define (custody-mode aid)
  "Detect whether the scope uses vault (bran.vault on disk) or Shamir
   (no vault file; bran reconstituted from share-store at restore)."
  (cond
   ((file-exists? (scope-vault-path aid)) 'vault)
   (else 'shamir-or-external)))

(define (scope-summary aid)
  "Plain alist with the fields `list` and `inspect` both want."
  `((aid           . ,aid)
    (kind          . ,(read-scope-kind aid))
    (aid-name      . ,(or (read-scope-aid-name aid)
                          (default-scope-aid-name aid)))
    (custody       . ,(custody-mode aid))
    (acdc-count    . ,(count-files-recursive (scope-acdc-dir aid)))
    (kel-count     . ,(count-files-recursive (scope-kel-dir aid)))
    (state-dir     . ,(scope-state-dir aid))))

;; ─────────────────────────────────────────────────────────────────────
;; list
;; ─────────────────────────────────────────────────────────────────────

(define (cmd-list . _args)
  (let ((aids (list-known-scope-aids)))
    (cond
     ((null? aids)
      (info "No scopes found under ~a" (scopes-root)))
     (else
      (info "~a  ~12a  ~22a  ~6a  ~6a  ~a"
            "AID" "KIND" "CUSTODY" "ACDC" "KEL" "ALIAS")
      (for-each
       (lambda (aid)
         (let ((s (scope-summary aid)))
           (info "~a  ~12a  ~22a  ~6a  ~6a  ~a"
                 (truncate-aid (assq-ref s 'aid))
                 (or (assq-ref s 'kind) "?")
                 (assq-ref s 'custody)
                 (assq-ref s 'acdc-count)
                 (assq-ref s 'kel-count)
                 (assq-ref s 'aid-name))))
       aids)
      (info "~%~a scope(s)" (length aids))))))

(define (truncate-aid aid)
  (if (> (string-length aid) 14)
      (string-append (substring aid 0 14) "…")
      aid))

;; ─────────────────────────────────────────────────────────────────────
;; inspect
;; ─────────────────────────────────────────────────────────────────────

(define (cmd-inspect . args)
  (unless (= 1 (length args))
    (die "usage: localchimera-scope inspect <aid>"))
  (let ((aid (car args)))
    (unless (file-exists? (scope-state-dir aid))
      (die "no scope state at ~a" (scope-state-dir aid)))
    (let ((s (scope-summary aid)))
      (info "Scope: ~a" (assq-ref s 'aid))
      (info "  kind        : ~a" (assq-ref s 'kind))
      (info "  aid-name    : ~a" (assq-ref s 'aid-name))
      (info "  custody     : ~a" (assq-ref s 'custody))
      (info "  state-dir   : ~a" (assq-ref s 'state-dir))
      (info "  acdc count  : ~a" (assq-ref s 'acdc-count))
      (info "  kel count   : ~a" (assq-ref s 'kel-count))
      (info "  bran.vault  : ~a" (if (file-exists? (scope-vault-path aid))
                                     "present" "absent"))
      (info "  kind file   : ~a" (if (file-exists? (scope-kind-file aid))
                                     "present" "absent"))
      (info "  aid-name file: ~a" (if (file-exists? (scope-aid-name-file aid))
                                     "present" "absent")))))

;; ─────────────────────────────────────────────────────────────────────
;; validate — dry-run readiness check
;; ─────────────────────────────────────────────────────────────────────

(define (cmd-validate . args)
  (unless (= 1 (length args))
    (die "usage: localchimera-scope validate <aid>"))
  (let* ((aid (car args))
         (checks '())
         (fails  '())
         (add!   (lambda (label pass? . details)
                   (set! checks (cons label checks))
                   (cond
                    (pass? (info "  ✓ ~a" label))
                    (else
                     (set! fails (cons label fails))
                     (info "  ✗ ~a~@[: ~a~]" label (and (pair? details)
                                                        (car details))))))))
    (info "Validating scope ~a..." aid)
    (add! "state directory exists" (file-exists? (scope-state-dir aid)))
    (add! "acdc/ directory exists" (file-exists? (scope-acdc-dir aid)))
    (add! "kel/ directory exists"  (file-exists? (scope-kel-dir aid)))
    (add! "kind file present"      (file-exists? (scope-kind-file aid)))
    (add! "aid-name file present"  (file-exists? (scope-aid-name-file aid)))

    ;; If vault mode, try to decrypt
    (when (eq? 'vault (custody-mode aid))
      (catch #t
        (lambda ()
          (read-vault-bran (scope-vault-path aid))
          (add! "bran.vault decrypts under LOCALCHIMERA_VAULT_KEY" #t))
        (lambda (key . a)
          (add! "bran.vault decrypts under LOCALCHIMERA_VAULT_KEY"
                #f (format #f "~a ~a" key a)))))

    ;; aid-name file should match directory name (convention check)
    (let ((on-disk-name (read-scope-aid-name aid))
          (expected     (default-scope-aid-name aid)))
      (cond
       ((not on-disk-name)
        (add! "aid-name file matches convention" #f "no aid-name file"))
       ((equal? on-disk-name expected)
        (add! "aid-name file matches convention" #t))
       (else
        (info "  ~~ aid-name = ~a (non-conventional but valid)" on-disk-name))))

    (info "~%~a / ~a checks passed"
          (- (length checks) (length fails))
          (length checks))
    (when (pair? fails)
      (exit 1))))

;; ─────────────────────────────────────────────────────────────────────
;; export — tar + age-encrypt
;; ─────────────────────────────────────────────────────────────────────

(define (cmd-export . args)
  (let* ((opts (getopt-long (cons "export" args)
                            `((output (single-char #\o) (value #t))
                              (recipient (single-char #\r) (value #t)))))
         (aid       (let ((leftovers (option-ref opts '() '())))
                      (cond
                       ((null? leftovers)
                        (die "usage: localchimera-scope export <aid> [-o file] [-r recipient]"))
                       (else (car leftovers)))))
         (output    (or (option-ref opts 'output #f)
                        (format #f "~a.tar.age" aid)))
         (recipient (option-ref opts 'recipient #f))
         (state-dir (scope-state-dir aid)))
    (unless (file-exists? state-dir)
      (die "no scope state at ~a" state-dir))
    (info "Packing ~a → ~a..." state-dir output)
    (let* ((tar-args
            ;; -C to the parent dir, then the bare AID — keeps the
            ;; tar paths relative so import unpacks cleanly into any
            ;; <state>/scopes/.
            (list "-C" (scopes-root) "-cf" "-" aid))
           (tar-port (apply open-pipe* OPEN_READ "tar" tar-args))
           (age-args
            (cond
             (recipient (list "-e" "-r" recipient "-o" output))
             (else
              (info "  no recipient given; using passphrase mode")
              (list "-e" "-p" "-o" output))))
           (age-port (apply open-pipe* OPEN_WRITE "age" age-args)))
      ;; Stream tar → age
      (let loop ()
        (let ((chunk (get-bytevector-n tar-port 65536)))
          (cond
           ((eof-object? chunk) #t)
           (else (put-bytevector age-port chunk) (loop)))))
      (close-pipe tar-port)
      (let ((age-status (close-pipe age-port)))
        (unless (zero? (status:exit-val age-status))
          (die "age encryption failed: status ~a" age-status))))
    (info "Wrote ~a" output)
    (info "")
    (info "Transfer this file + your recipient's identity (or passphrase)")
    (info "to the destination host, then: localchimera-scope import ~a" output)))

;; ─────────────────────────────────────────────────────────────────────
;; import — unpack + optionally re-encrypt bran
;; ─────────────────────────────────────────────────────────────────────

(define (cmd-import . args)
  (let* ((opts (getopt-long (cons "import" args)
                            `((vault-key (single-char #\k) (value #t))
                              (identity  (single-char #\i) (value #t)))))
         (file      (let ((leftovers (option-ref opts '() '())))
                      (cond
                       ((null? leftovers)
                        (die "usage: localchimera-scope import <file.tar.age> [-k new-vault-key-hex] [-i age-identity]"))
                       (else (car leftovers)))))
         (new-key   (option-ref opts 'vault-key #f))
         (identity  (option-ref opts 'identity #f))
         (root      (scopes-root)))
    (unless (file-exists? file) (die "no such file: ~a" file))
    (unless (file-exists? root) (ensure-directory! root))
    (info "Unpacking ~a → ~a..." file root)
    (let* ((age-args
            (cond
             (identity (list "-d" "-i" identity file))
             (else
              (info "  no identity given; age will prompt for passphrase")
              (list "-d" file))))
           (age-port (apply open-pipe* OPEN_READ "age" age-args))
           (tar-args (list "-C" root "-xf" "-"))
           (tar-port (apply open-pipe* OPEN_WRITE "tar" tar-args)))
      (let loop ()
        (let ((chunk (get-bytevector-n age-port 65536)))
          (cond
           ((eof-object? chunk) #t)
           (else (put-bytevector tar-port chunk) (loop)))))
      (close-pipe age-port)
      (let ((tar-status (close-pipe tar-port)))
        (unless (zero? (status:exit-val tar-status))
          (die "tar extraction failed: status ~a" tar-status))))
    (info "Unpacked successfully")

    ;; Discover the imported scope AID(s) — any new dirs under scopes/
    (let* ((all-aids (list-known-scope-aids)))
      (info "")
      (info "Scope(s) now on disk: ~a" (length all-aids))
      (for-each
       (lambda (aid)
         (when (eq? 'vault (custody-mode aid))
           (cond
            (new-key
             (info "Re-encrypting bran for ~a under new vault key..."
                   (truncate-aid aid))
             (catch #t
               (lambda ()
                 ;; Decrypt under SOURCE key (currently in LOCALCHIMERA_VAULT_KEY)
                 (let ((bran (read-vault-bran (scope-vault-path aid))))
                   ;; Re-encrypt under DEST key
                   (write-vault-bran! bran (scope-vault-path aid)
                                      #:key-bv (hex->bv new-key)))
                 (info "  ✓ ~a re-encrypted" (truncate-aid aid)))
               (lambda (key . a)
                 (info "  ✗ ~a re-encrypt failed: ~a ~a"
                       (truncate-aid aid) key a))))
            (else
             (info "  ~a still encrypted under source vault key"
                   (truncate-aid aid))
             (info "    (pass -k <hex> to re-encrypt for this host's key)")))))
       all-aids))
    (info "")
    (info "Run `herd restart localchimera-gateway` to load the imported scope.")))

;; ─────────────────────────────────────────────────────────────────────
;; export-shamir — split bran k-of-n; write share-ACDC files
;; ─────────────────────────────────────────────────────────────────────
;;
;; Reuses the existing primitives of keys/ and credentials/:
;;
;;   shamir-split bran k n          → list of (idx k share-bv)
;;   make-bran-share-credential …   → the same ACDC shape keys/bran-custody.scm
;;                                    issues via split-and-issue-bran-shares!
;;
;; We don't go through an acdc-store because operators ship the share
;; ACDCs as files (gathered by custodians out-of-band); the store-based
;; path is for in-process / federation-internal Shamir distribution.

(define (cmd-export-shamir . args)
  (let* ((opts (getopt-long
                (cons "export-shamir" args)
                `((holders   (single-char #\h) (value #t))
                  (threshold (single-char #\k) (value #t))
                  (output    (single-char #\o) (value #t))
                  (issuer    (single-char #\i) (value #t))
                  (remove-vault            (value #f)))))
         (aid       (let ((rest (option-ref opts '() '())))
                      (cond ((null? rest)
                             (die "usage: localchimera-scope export-shamir <aid> -h holders.txt -k <threshold> [-o dir] [-i issuer-aid] [--remove-vault]"))
                            (else (car rest)))))
         (holders-file (or (option-ref opts 'holders #f)
                           (die "missing -h holders.txt (one AID per line)")))
         (holders      (filter (lambda (s) (not (string-null? s)))
                               (map string-trim-both
                                    (string-split
                                     (call-with-input-file holders-file
                                       (lambda (p) (get-string-all p)))
                                     #\newline))))
         (n            (length holders))
         (threshold    (cond
                        ((option-ref opts 'threshold #f)
                         => string->number)
                        (else (+ 1 (quotient n 2)))))   ; majority default
         (output-dir   (or (option-ref opts 'output #f)
                           (format #f "~a-shares" aid)))
         (issuer       (or (option-ref opts 'issuer #f) aid)))
    (when (< n threshold)
      (die "fewer holders (~a) than threshold (~a) — can't reconstitute"
           n threshold))
    (unless (file-exists? (scope-vault-path aid))
      (die "no bran.vault at ~a — scope must be vault-mode to convert to Shamir"
           (scope-vault-path aid)))
    (info "Splitting bran for ~a into ~a shares (threshold ~a)..."
          aid n threshold)
    (let* ((bran    (read-vault-bran (scope-vault-path aid)))
           (shares  (shamir-split bran threshold n)))
      (ensure-directory! output-dir)
      ;; Each share is a (idx k share-bv) triple. Wrap as a
      ;; localchimera-bran-share/v1 credential matching what keys/bran-custody.scm
      ;; writes — receivers read via reconstitute-bran-from-store OR our
      ;; import-shamir subcommand.
      (for-each
       (lambda (holder share)
         (let* ((idx       (car share))
                (k         (cadr share))
                (share-bv  (caddr share))
                (share-hex (bv->hex share-bv))
                (cred      (make-bran-share-credential
                            #:issuer-group-aid issuer
                            #:holder-aid holder
                            #:share-index idx
                            #:threshold k
                            #:total-shares n
                            #:share-data-hex share-hex
                            #:subject-aid aid))
                (filename  (format #f "~a/share-~a-~a.scm"
                                   output-dir idx (truncate-aid holder))))
           (call-with-output-file filename
             (lambda (port) (write cred port) (newline port)))
           (info "  → ~a  (holder ~a)" filename (truncate-aid holder))))
       holders shares)
      (info "")
      (info "Distribute each share file to its corresponding custodian.")
      (info "Threshold ~a of ~a needed to reconstitute." threshold n)
      (when (option-ref opts 'remove-vault #f)
        (delete-file (scope-vault-path aid))
        (info "")
        (info "Removed local bran.vault — scope now Shamir-only on this host.")
        (info "If you need to roll back, gather ≥~a shares + run import-shamir."
              threshold)))))

;; ─────────────────────────────────────────────────────────────────────
;; import-shamir — gather share files, reconstitute, write vault
;; ─────────────────────────────────────────────────────────────────────

(define (cmd-import-shamir . args)
  (let* ((opts (getopt-long
                (cons "import-shamir" args)
                `((shares    (single-char #\d) (value #t))
                  (vault-key (single-char #\K) (value #t)))))
         (aid       (let ((rest (option-ref opts '() '())))
                      (cond ((null? rest)
                             (die "usage: localchimera-scope import-shamir <aid> -d share-dir [-K new-vault-key-hex]"))
                            (else (car rest)))))
         (share-dir (or (option-ref opts 'shares #f)
                        (die "missing -d <share-dir>")))
         (new-key   (option-ref opts 'vault-key #f)))
    (unless (file-exists? share-dir)
      (die "no such share directory: ~a" share-dir))
    (let* ((share-files
            (filter (lambda (f) (string-suffix? ".scm" f))
                    (or (scandir share-dir) '())))
           (creds
            ;; Each share file is a credential alist; extract the
            ;; relevant claims using the same cred-claim path
            ;; keys/bran-custody.scm's reconstitute-bran-from-store uses.
            (filter-map
             (lambda (f)
               (let ((cred (read-sexp-file (string-append share-dir "/" f))))
                 (and cred
                      (equal? aid (cred-claim cred 'subject-aid))
                      (not (cred-revoked? cred))
                      cred)))
             share-files))
           ;; Dedupe by share-index in case operator gathered duplicates
           (by-idx (let ((h (make-hash-table)))
                     (for-each (lambda (c)
                                 (hash-set! h (cred-claim c 'share-index) c))
                               creds)
                     (hash-map->list (lambda (_k v) v) h)))
           (have (length by-idx))
           (threshold (and (pair? by-idx)
                           (cred-claim (car by-idx) 'threshold))))
      (info "Found ~a share(s) for ~a in ~a" have aid share-dir)
      (when (zero? have)
        (die "no shares for ~a found in ~a (subject-aid mismatch or empty dir)"
             aid share-dir))
      (when (< have threshold)
        (die "have ~a shares, need ~a to reconstitute" have threshold))
      (info "Reconstituting bran from ~a share(s) (threshold ~a)..." have threshold)
      (let* ((shares-for-combine
              (map (lambda (c)
                     (list (cred-claim c 'share-index)
                           (cred-claim c 'threshold)
                           (hex->bv (cred-claim c 'share-data))))
                   (list-head by-idx threshold)))
             (bran (shamir-combine shares-for-combine)))
        (cond
         (new-key
          (info "Writing bran.vault under provided key...")
          (write-vault-bran! bran (scope-vault-path aid)
                             #:key-bv (hex->bv new-key))
          (info "  ✓ bran.vault written at ~a" (scope-vault-path aid)))
         (else
          (info "Writing bran.vault under current LOCALCHIMERA_VAULT_KEY...")
          (write-vault-bran! bran (scope-vault-path aid))
          (info "  ✓ bran.vault written at ~a" (scope-vault-path aid)))))
      (info "")
      (info "Run `herd restart localchimera-gateway` to load the restored scope."))))

;; ─────────────────────────────────────────────────────────────────────
;; Dispatch
;; ─────────────────────────────────────────────────────────────────────

(define %commands
  `(("list"          . ,cmd-list)
    ("inspect"       . ,cmd-inspect)
    ("validate"      . ,cmd-validate)
    ("export"        . ,cmd-export)
    ("import"        . ,cmd-import)
    ("export-shamir" . ,cmd-export-shamir)
    ("import-shamir" . ,cmd-import-shamir)))

(define (print-usage)
  (info "Usage: localchimera-scope <command> [args]")
  (info "")
  (info "Commands:")
  (info "  list              every scope on this host + kind/custody/counts")
  (info "  inspect <aid>     full detail for one scope")
  (info "  validate <aid>    dry-run readiness check (decrypt, file presence)")
  (info "  export <aid>      tar + age-encrypt for handoff")
  (info "                    -o FILE       output path (default <aid>.tar.age)")
  (info "                    -r RECIPIENT  age recipient (default: passphrase)")
  (info "  import <file>     unpack + optionally re-encrypt bran")
  (info "                    -k KEY-HEX    re-encrypt bran under this vault key")
  (info "                    -i IDENTITY   age identity file (default: passphrase)")
  (info "  export-shamir <aid>  split bran k-of-n into per-holder share files")
  (info "                    -h FILE       holders.txt (one AID per line)")
  (info "                    -k N          threshold (default majority)")
  (info "                    -o DIR        output dir (default <aid>-shares)")
  (info "                    -i ISSUER     issuer-aid for share ACDCs (default <aid>)")
  (info "                    --remove-vault  delete local bran.vault after split")
  (info "  import-shamir <aid>  gather share files, reconstitute bran.vault")
  (info "                    -d DIR        directory of share-*.scm files")
  (info "                    -K KEY-HEX    write vault under this key (default: env)")
  (info "")
  (info "State dir: ~a" (scopes-root)))

(define (main argv)
  (cond
   ((or (null? (cdr argv))
        (member (cadr argv) '("-h" "--help" "help")))
    (print-usage))
   (else
    (let* ((cmd-name (cadr argv))
           (cmd      (assoc-ref %commands cmd-name)))
      (cond
       ((not cmd)
        (info "Unknown command: ~a" cmd-name)
        (print-usage)
        (exit 1))
       (else (apply cmd (cddr argv))))))))

(main (command-line))
