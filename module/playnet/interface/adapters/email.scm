;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/interface/adapters/email.scm — Email transport adapter
;;;
;;; Sends notifications via SMTP. Same transport interface as browser,
;;; Telegram, Matrix. Uses its own template registry with richer
;;; multi-line email bodies.
;;;
;;; channel-context = recipient email address.
;;;
;;; Where a mail goes is the box's own setting, read from the environment
;;; once at load:
;;;
;;;   PLAYNET_MAIL_DIR     each mail is written to a file in this directory —
;;;                        the transport a development box and the tests use;
;;;   PLAYNET_SMTP_HOST    msmtp logs in to this relay and the relay delivers:
;;;     PLAYNET_SMTP_PORT           587 (STARTTLS) by default; 465 is TLS from
;;;                                 the first byte
;;;     PLAYNET_SMTP_USER           the account, when the relay asks for one
;;;     PLAYNET_SMTP_PASSWORD_FILE  the file its password is read from
;;;     SMTP_FROM                   the sender; the operator's contact address
;;;                                 (PLAYNET_OPERATOR_CONTACT) when it is one, else
;;;                                 noreply@invalid, which is plainly unset
;;;   neither              a sendmail on the path, as it is configured.
;;;
;;; With none of these the commune has no mail transport, and
;;; `email-transport?` says so: the gateway then offers no email channel
;;; (server/gateway.scm). The relay's host, account and sender come from the
;;; deployment's provider config and its password from the secrets blob
;;; (deploy/os.scm, deploy/README.md §Mail).

(define-module (playnet interface adapters email)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (playnet notify rendered)
  #:use-module ((playnet utils operator) #:select (operator-email))
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module ((ice-9 rdelim) #:select (read-line))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (^email-adapter email-transport? email-transport msmtp-arguments
            mail-spool-forget!
            smtp-from rfc5322-message send-raw-email!))

(define %smtp-from
  (or (getenv "SMTP_FROM") (operator-email) "noreply@invalid"))

;; the configured sender, for a caller that builds its own message and must
;; agree with the relay's From (an invitation's ORGANIZER included)
(define (smtp-from) %smtp-from)

(define (program-on-path name)
  "The first NAME in a directory of PATH, or #f."
  (any (lambda (dir)
         (let ((file (string-append dir "/" name)))
           (and (not (string-null? dir)) (access? file X_OK) file)))
       (string-split (or (getenv "PATH") "") #\:)))

(define (setting name)
  (let ((v (getenv name))) (and v (not (string-null? v)) v)))

(define %ca-bundle
  (find file-exists?
        (filter string? (list (getenv "SSL_CERT_FILE") "/etc/ssl/certs/ca-certificates.crt"))))

(define* (msmtp-arguments #:key host (port "587") user password-file (from %smtp-from) (ca %ca-bundle))
  "The arguments msmtp is run with to hand one mail (read from its input,
   recipients from the headers) to the relay at HOST. Port 465 is TLS from
   the first byte; any other port upgrades with STARTTLS. With USER the
   relay is logged in to, the password read from PASSWORD-FILE as msmtp runs.
   A relay that does not answer is given up on after a minute: the adapter
   waits for msmtp inside the gateway's vat."
  `(,(string-append "--host=" host)
    ,(string-append "--port=" port)
    "--timeout=60"
    "--tls=on"
    ,(string-append "--tls-starttls=" (if (equal? port "465") "off" "on"))
    ,@(if ca (list (string-append "--tls-trust-file=" ca)) '())
    ,@(if user
          `("--auth=on" ,(string-append "--user=" user)
            ,@(if password-file (list (string-append "--passwordeval=cat " password-file)) '()))
          '("--auth=off"))
    ,(string-append "--from=" from)
    "--read-recipients"))

(define (password-to-hand? file)
  "Whether FILE is there to be read and holds something."
  (and file (access? file R_OK)
       (catch #t (lambda () (positive? (stat:size (stat file)))) (lambda _ #f))))

;; the transport, decided once: (dir . DIR), (argv PROGRAM ARG …), or #f
(define %transport
  (let ((mail-dir (setting "PLAYNET_MAIL_DIR"))
        (host (setting "PLAYNET_SMTP_HOST"))
        (user (setting "PLAYNET_SMTP_USER"))
        (password-file (setting "PLAYNET_SMTP_PASSWORD_FILE"))
        (msmtp (program-on-path "msmtp"))
        (sendmail (program-on-path "sendmail")))
    (cond
     (mail-dir (cons 'dir mail-dir))
     ;; an account whose password is not to hand cannot log in: the commune
     ;; then has no mail transport, and says so, where it would otherwise
     ;; offer email and deliver none
     ((and host msmtp user (not (password-to-hand? password-file)))
      (format (current-error-port)
              "[email] the relay account's password is not in ~a; no mail transport~%" password-file)
      #f)
     ((and host msmtp)
      (cons* 'argv msmtp
             (msmtp-arguments #:host host
                              #:port (or (setting "PLAYNET_SMTP_PORT") "587")
                              #:user user
                              #:password-file password-file)))
     (sendmail (list 'argv sendmail "-t"))
     (else #f))))

(define (email-transport) "The transport as decided at load: (dir . DIR), (argv PROGRAM ARG …) or #f." %transport)
(define (email-transport?)
  "Whether a mail handed to the adapter goes anywhere."
  (and %transport #t))

;; A short, non-identifying form of an address for logs: the first character
;; of the local part and the domain, e.g. j***@example.com — the domain alone
;; is still useful for diagnosing a relay's per-provider failures, and the
;; full address never reaches stderr.
(define (email-tag addr)
  (let ((at (and (string? addr) (string-index addr #\@))))
    (if (and at (> at 0))
        (string-append (substring addr 0 1) "***" (substring addr at))
        "?")))

(define %mail-count 0)
(define (drop-email! dir to subject body)
  (set! %mail-count (+ 1 %mail-count))
  (unless (file-exists? dir) (mkdir dir))
  (call-with-output-file (format #f "~a/~a-~a.eml" dir (current-time) %mail-count)
    (lambda (port)
      (format port "To: ~a\nSubject: ~a\n\n~a\n" to subject body))))

(define (mail-spool-forget! dir addresses)
  "Erase every spooled mail in DIR addressed to one of ADDRESSES — the spool
   is the one place an address is written out in full — and reply how many
   went. A missing directory or an empty address list replies 0."
  (if (and (string? dir) (file-exists? dir) (pair? addresses))
      (let* ((to-line (lambda (f)
                        (catch #t
                          (lambda ()
                            (call-with-input-file (string-append dir "/" f)
                              (lambda (p) (let ((l (read-line p)))
                                            (and (string? l) (string-prefix? "To: " l)
                                                 (substring l 4))))))
                          (lambda _ #f))))
             (theirs (filter (lambda (f) (and (string-suffix? ".eml" f)
                                              (member (to-line f) addresses)))
                             (or (scandir dir) '()))))
        (for-each (lambda (f) (delete-file (string-append dir "/" f))) theirs)
        (length theirs))
      0))

;; a header is one line: a line break in a recipient or a subject would
;; begin a header of its own
(define (one-line s)
  (string-map (lambda (c) (if (memv c '(#\return #\newline)) #\space c)) s))

;; the program is run directly, its arguments as a list: nothing a mail
;; carries reaches a shell
(define (pipe-email! argv to subject body)
  (let ((port (apply open-pipe* OPEN_WRITE argv)))
    (format port "From: ~a\r\n" %smtp-from)
    (format port "To: ~a\r\n" (one-line to))
    (format port "Subject: ~a\r\n" (one-line subject))
    (format port "Content-Type: text/plain; charset=utf-8\r\n")
    (format port "\r\n")
    (display body port)
    (newline port)
    (let ((status (close-pipe port)))
      (unless (zero? (status:exit-val status))
        (format (current-error-port) "[email] ~a answered ~a sending to ~a~%"
                (car argv) (status:exit-val status) (email-tag to))))))

(define (send-email! to subject body)
  (catch #t
    (lambda ()
      (cond
       ((not %transport)
        (format (current-error-port) "[email] no mail transport; dropping email to ~a~%" (email-tag to)))
       ((eq? 'dir (car %transport)) (drop-email! (cdr %transport) to subject body))
       (else (pipe-email! (cdr %transport) to subject body))))
    (lambda (key . args)
      (format (current-error-port) "[email] error sending to ~a: ~a ~a~%" (email-tag to) key args))))

;; A caller that has already assembled a full RFC-5322 message (its own
;; headers, its own MIME parts — a multipart/alternative with a
;; text/calendar part, say) hands it here whole, so it goes out through
;; the SAME transport selection and the SAME safety (argv exec, no shell,
;; addresses never past the tag in a log) as the plain-text path above,
;; without this module's own header-building getting in the way.
(define (drop-raw-email! dir to raw-message)
  (set! %mail-count (+ 1 %mail-count))
  (unless (file-exists? dir) (mkdir dir))
  (call-with-output-file (format #f "~a/~a-~a.eml" dir (current-time) %mail-count)
    (lambda (port) (display raw-message port))))

(define (pipe-raw-email! argv raw-message)
  (let ((port (apply open-pipe* OPEN_WRITE argv)))
    (display raw-message port)
    (let ((status (close-pipe port)))
      (unless (zero? (status:exit-val status))
        (format (current-error-port) "[email] ~a answered ~a sending a raw message~%"
                (car argv) (status:exit-val status))))))

(define (send-raw-email! to raw-message)
  "RAW-MESSAGE is a complete RFC-5322 message (headers included) the caller
   built itself; TO is used only for the dev-mode filename / error log, the
   same way the plain-text path's TO is — the message's own To: header is
   what any real transport actually reads."
  (catch #t
    (lambda ()
      (cond
       ((not %transport)
        (format (current-error-port) "[email] no mail transport; dropping email to ~a~%" (email-tag to)))
       ((eq? 'dir (car %transport)) (drop-raw-email! (cdr %transport) to raw-message))
       (else (pipe-raw-email! (cdr %transport) raw-message))))
    (lambda (key . args)
      (format (current-error-port) "[email] error sending to ~a: ~a ~a~%" (email-tag to) key args))))


;; RFC 5322 requires CRLF line endings; a message built with bare LFs is
;; not a valid message to every relay. Bare CRs are dropped, every line
;; break becomes CRLF, so input with CRLF or LF both come out right.
(define (crlf s)
  (call-with-output-string
   (lambda (port)
     (string-for-each
      (lambda (c)
        (cond ((char=? c #\newline) (display "\r\n" port))
              ((char=? c #\return) #f)
              (else (write-char c port))))
      s))))

;; A complete RFC-5322 message, CRLF throughout. FROM defaults to the
;; configured sender. HEADERS are extra "Name: value" lines (MIME-Version,
;; Content-Type …) placed after Subject. One-line fields are kept one line.
(define* (rfc5322-message #:key from to subject (headers '()) (body ""))
  (string-append
   "From: " (one-line (or from %smtp-from)) "\r\n"
   "To: " (one-line to) "\r\n"
   "Subject: " (one-line subject) "\r\n"
   (apply string-append (map (lambda (h) (string-append (one-line h) "\r\n")) headers))
   "\r\n"
   (crlf body)))

;;; ── Adapter actor ──────────────────────────────────────────────────
;;;
;;; A DUMB transport: it puts a pre-rendered notification's title/body
;;; into an email. The `rich' rendering happens upstream in the sink
;;; formatter (`(notification-formatter 'rich)'), not here.

(define (^email-adapter _bcom)
  (methods
   ((deliver recipient-email rendered)
    (send-email! recipient-email
                 (or (rendered-title rendered) "playnet notification")
                 (or (rendered-body rendered) "")))
   ((send-message recipient-email x)
    (if (string? x)
        (send-email! recipient-email "playnet notification" x)
        (send-email! recipient-email
                     (or (rendered-title x) "playnet notification")
                     (or (rendered-body x) (format #f "~a" x)))))
   ((send-formatted recipient-email blocks)
    (send-email! recipient-email "playnet notification"
                 (string-join
                  (map (lambda (b) (if (string? b) b (format #f "~a" b)))
                       blocks)
                  "\n")))
   ((parse-command raw-text)
    (values #f #f))))
