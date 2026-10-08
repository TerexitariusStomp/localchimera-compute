;;; tests/playnet/test-email-transport.scm — where the email adapter's mail goes
;;;
;;; The adapter hands a mail to the box's relay through msmtp, with the
;;; relay's host, account and password file taken from the environment. This
;;; runs the adapter against a stand-in msmtp that records what it was run
;;; with and what it was fed.
;;;
;;; What this pins:
;;;   • the arguments name the relay, turn TLS on, read the password from its
;;;     file as msmtp runs, and take recipients from the mail's own headers;
;;;   • port 465 is TLS from the first byte, any other port STARTTLS;
;;;   • a relay with no account is spoken to without a login;
;;;   • a relay that does not answer is given up on after a minute;
;;;   • a line break in a subject or a recipient stays inside its header;
;;;   • the mail msmtp is fed carries the sender, the recipient, the subject
;;;     and the body, and what a mail carries reaches no shell.
;;;
;;; Run: guile -L module -L tests tests/playnet/test-email-transport.scm

(use-modules (playnet test harness)
             (ice-9 textual-ports)
             ((srfi srfi-1) #:select (find)))

(define tmp (string-append (or (getenv "TMPDIR") "/tmp") "/playnet-mail-test-" (number->string (getpid))))
(mkdir tmp)
(define out (string-append tmp "/out"))
;; a stand-in msmtp: its arguments one per line, then its input, using the
;; shell's builtins alone
(call-with-output-file (string-append tmp "/msmtp")
  (lambda (p)
    (format p "#!/bin/sh\nprintf '%s\\n' \"$@\" > ~a.args\nwhile IFS= read -r line; do printf '%s\\n' \"$line\"; done > ~a.mail\n" out out)))
(chmod (string-append tmp "/msmtp") #o755)
(setenv "PATH" (string-append tmp ":" (or (getenv "PATH") "")))
(unsetenv "PLAYNET_MAIL_DIR")
(setenv "PLAYNET_SMTP_HOST" "relay.example.org")
(setenv "PLAYNET_SMTP_USER" "noreply@playnet.example")
(define password-file (string-append tmp "/smtp-password"))
(call-with-output-file password-file (lambda (p) (display "hunter2" p)))
(setenv "PLAYNET_SMTP_PASSWORD_FILE" password-file)
(setenv "SMTP_FROM" "noreply@playnet.example")

;; the adapter reads its transport as it loads, so it loads after the settings
(use-modules (playnet interface adapters email)
             (playnet notify rendered)
             (goblins) (goblins vat))

(define (has? args a) (and (member a args) #t))
(define (lines file) (string-split (string-trim-right (call-with-input-file file get-string-all)) #\newline))

(display "\n── the arguments ──\n")
(let ((args (msmtp-arguments #:host "relay.example.org" #:user "u" #:password-file "/f" #:from "a@b" #:ca "/ca")))
  (check "they name the relay and its submission port"
         (and (has? args "--host=relay.example.org") (has? args "--port=587")))
  (check "TLS is on, upgraded with STARTTLS, against the box's certificates"
         (and (has? args "--tls=on") (has? args "--tls-starttls=on") (has? args "--tls-trust-file=/ca")))
  (check "the account logs in, its password read from its file as msmtp runs"
         (and (has? args "--auth=on") (has? args "--user=u") (has? args "--passwordeval=cat /f")))
  (check "the sender is stated and the recipients come from the mail"
         (and (has? args "--from=a@b") (has? args "--read-recipients"))))
(check "a relay that does not answer is given up on after a minute"
       (has? (msmtp-arguments #:host "h") "--timeout=60"))
(check "port 465 is TLS from the first byte"
       (has? (msmtp-arguments #:host "h" #:port "465") "--tls-starttls=off"))
(check "a relay with no account is spoken to without a login"
       (let ((args (msmtp-arguments #:host "h")))
         (and (has? args "--auth=off") (not (find (lambda (a) (string-prefix? "--user" a)) args)))))

(display "\n── a mail, handed over ──\n")
(check "the transport is msmtp, as found on the path, for the relay the box names"
       (let ((t (email-transport)))
         (and (eq? 'argv (car t)) (string=? (cadr t) (string-append tmp "/msmtp"))
              (has? (cddr t) "--host=relay.example.org") (has? (cddr t) "--user=noreply@playnet.example"))))
(check "the commune has a mail transport" (email-transport?))
(define vat (spawn-vat))
(define adapter (with-vat vat (spawn ^email-adapter)))
(with-vat vat
  ($ adapter 'deliver "tia@example.org; touch /tmp/playnet-mail-test-shell"
     (rendered-notification 'info "confirm $(id)\r\nBcc: x@example.org" "your code:\n\n    123456\n" "t")))
(let ((args (lines (string-append out ".args"))) (mail (lines (string-append out ".mail"))))
  (check "msmtp was run with the relay's arguments, one each"
         (and (has? args "--host=relay.example.org") (has? args "--read-recipients")
              (has? args (string-append "--passwordeval=cat " password-file))))
  (check "the mail states its sender, recipient and subject, then the body"
         (and (has? mail "From: noreply@playnet.example\r")
              (has? mail "Subject: confirm $(id)  Bcc: x@example.org\r")
              (not (find (lambda (l) (string-prefix? "Bcc:" l)) mail))
              (has? mail "    123456")))
  (check "what a mail carries reaches no shell"
         (and (has? mail "To: tia@example.org; touch /tmp/playnet-mail-test-shell\r")
              (not (file-exists? "/tmp/playnet-mail-test-shell")))))

(system* "rm" "-rf" tmp)
(test-summary!)
