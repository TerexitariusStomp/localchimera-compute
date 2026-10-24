#!/usr/bin/env -S guile --no-auto-compile -s
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; deploy/guix/provision-user.scm — enrol a new account on the Guix machine.
;;;
;;; Usage:
;;;   guile -s deploy/guix/provision-user.scm \
;;;     --user USERNAME \
;;;     --key  "ssh-ed25519 AAAA… comment" \
;;;     --email user@example.com \
;;;     [--dry-run]
;;;
;;; The script:
;;;   1. Validates the inputs.
;;;   2. Appends the new user+key to users.scm.
;;;   3. Sends a welcome/recovery email via sendmail (or $MAILER).
;;;   4. Reminds you to re-run: guix deploy deploy/guix/machines.scm
;;;
;;; Email setup:
;;;   Install and configure msmtp (or any sendmail-compatible MTA) on the
;;;   machine running this script, or set the MAILER env var to the path of
;;;   your preferred mailer binary.

(use-modules (ice-9 getopt-long)
             (ice-9 format)
             (ice-9 regex)
             (ice-9 popen)
             (srfi srfi-1))        ; any

;;; ── Paths ───────────────────────────────────────────────────────────────────

(define %script-dir
  (dirname (or (current-filename) ".")))

(define %users-file
  (string-append %script-dir "/users.scm"))

(define %host
  (or (getenv "LOCALCHIMERA_HOST")
      (error "Set LOCALCHIMERA_HOST to the server IP or .onion address")))

;;; ── Argument spec ───────────────────────────────────────────────────────────

(define %option-spec
  '((user    (single-char #\u) (value #t))
    (key     (single-char #\k) (value #t))
    (email   (single-char #\e) (value #t))
    (dry-run (single-char #\n) (value #f))
    (help    (single-char #\h) (value #f))))

(define (usage)
  (display "\
provision-user.scm — add a new user to the Guix machine

Usage:
  guile -s deploy/guix/provision-user.scm \\
    --user USERNAME \\
    --key  \"ssh-ed25519 AAAA… comment\" \\
    --email user@example.com \\
    [--dry-run]

Options:
  -u, --user     Login username (lowercase letters, digits, hyphens; max 31 chars)
  -k, --key      SSH public key string (e.g. ssh-ed25519 AAAA…)
  -e, --email    Email address for the welcome / recovery email
  -n, --dry-run  Print what would happen without writing or sending
  -h, --help     Show this message

After running, redeploy:
  guix deploy deploy/guix/machines.scm
"))

;;; ── Validation ──────────────────────────────────────────────────────────────

(define (valid-username? s)
  (and (string? s)
       (not (string-null? s))
       (string-match "^[a-z][a-z0-9-]{0,30}$" s)
       #t))

(define (valid-ssh-key? s)
  (and (string? s)
       (string-match "^ssh-(ed25519|rsa|ecdsa-sha2-nistp(256|384|521)) " s)
       #t))

(define (valid-email? s)
  (and (string? s)
       (string-match "^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+" s)
       #t))

;;; ── users.scm I/O ───────────────────────────────────────────────────────────

(define (load-users)
  "Return the current list of (username . pubkey) pairs from users.scm."
  (if (file-exists? %users-file)
      (primitive-load %users-file)
      '()))

(define (username-exists? name users)
  (any (lambda (entry) (string=? (car entry) name)) users))

(define (write-users! users)
  "Overwrite users.scm with USERS, an alist of (username . pubkey)."
  (with-output-to-file %users-file
    (lambda ()
      (display ";;; deploy/guix/users.scm — dynamically provisioned user accounts\n")
      (display ";;; Managed by provision-user.scm — do not hand-edit.\n")
      (display ";;; Each entry: (cons \"username\" \"ssh-pubkey\")\n")
      (display ";;;\n")
      (display ";;; After editing, redeploy:\n")
      (display ";;;   guix deploy deploy/guix/machines.scm\n")
      (display "\n(list\n")
      (for-each
       (lambda (entry)
         (format #t "  (cons ~s\n        ~s)\n" (car entry) (cdr entry)))
       users)
      (display ")\n"))))

;;; ── Email ───────────────────────────────────────────────────────────────────

(define (crlf s)
  "S with every line break as CRLF (RFC 5322 §2.2)."
  (string-join (string-split s #\newline) "\r\n"))

(define (send-welcome-email! to username pubkey)
  "Send a welcome/recovery email to TO for the newly provisioned USERNAME."
  (let* ((subject (string-append "[sapient-os] Account ready: " username))
         (body    (string-join
                   (list
                    (string-append "Hi " username ",")
                    ""
                    "Your account has been provisioned on the Sapient-OS Guix machine."
                    ""
                    "  Username : " username
                    (string-append "  Host     : " %host)
                    (string-append "  SSH      : ssh " username "@" %host)
                    ""
                    "Registered public key:"
                    (string-append "  " pubkey)
                    ""
                    "Account recovery:"
                    "  If you ever lose your private key, contact an administrator"
                    "  and supply a new SSH public key to replace the registered one."
                    "  No password resets — the key IS your credential."
                    ""
                    "Happy hacking!"
                    "-- sapient-os / localchimera")
                   "\n"))
         ;; RFC 5322 wants CRLF line endings; LF-only is not a valid message
         (message (crlf (string-append
                         "To: " to "\n"
                         "Subject: " subject "\n"
                         "Content-Type: text/plain; charset=utf-8\n"
                         "\n"
                         body "\n")))
         ;; Use $MAILER env var, defaulting to "sendmail -t"
         (mailer  (or (getenv "MAILER") "sendmail"))
         (port    (open-output-pipe (string-append mailer " -t"))))
    (display message port)
    (let ((status (close-pipe port)))
      (unless (zero? status)
        (format (current-error-port)
                "⚠  Mailer exited with status ~a — email may not have been delivered.\n"
                status)
        (format (current-error-port)
                "   Set the MAILER env var to your MTA binary (e.g. msmtp, ssmtp).\n")))))

;;; ── Main ────────────────────────────────────────────────────────────────────

(define (die msg . args)
  (apply format (current-error-port) (string-append "Error: " msg "\n") args)
  (exit 1))

(define (main args)
  (let* ((opts    (getopt-long args %option-spec))
         (help?   (option-ref opts 'help    #f))
         (dry?    (option-ref opts 'dry-run #f))
         (user    (option-ref opts 'user    #f))
         (key     (option-ref opts 'key     #f))
         (email   (option-ref opts 'email   #f)))

    (when help? (usage) (exit 0))

    ;; ── Validate inputs ──────────────────────────────────────────────────────
    (unless user  (die "missing --user"))
    (unless key   (die "missing --key"))
    (unless email (die "missing --email"))

    (unless (valid-username? user)
      (die "invalid username ~s  (must match [a-z][a-z0-9-]{0,30})" user))
    (unless (valid-ssh-key? key)
      (die "invalid SSH public key — must start with ssh-ed25519 / ssh-rsa / ssh-ecdsa…"))
    (unless (valid-email? email)
      (die "invalid email address ~s" email))

    ;; ── Load existing users ──────────────────────────────────────────────────
    (let ((users (load-users)))
      (when (username-exists? user users)
        (die "user ~s already exists in ~a" user %users-file))

      (let ((new-users (append users (list (cons user key)))))

        (if dry?
            ;; ── Dry-run ──────────────────────────────────────────────────────
            (begin
              (format #t "[dry-run] Would append to ~a:\n" %users-file)
              (format #t "  (cons ~s\n        ~s)\n" user key)
              (format #t "[dry-run] Would send welcome email to ~s\n" email)
              (format #t "[dry-run] No files written, no email sent.\n"))

            ;; ── Live run ─────────────────────────────────────────────────────
            (begin
              ;; 1. Persist
              (write-users! new-users)
              (format #t "✓ Added ~s to ~a\n" user %users-file)

              ;; 2. Email
              (send-welcome-email! email user key)
              (format #t "✓ Welcome email dispatched to ~s\n" email)

              ;; 3. Reminder
              (format #t "\nNext step — apply to the live machine:\n")
              (format #t "  guix deploy deploy/guix/machines.scm\n")))))))

(main (command-line))
