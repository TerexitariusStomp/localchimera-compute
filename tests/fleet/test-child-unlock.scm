;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/fleet/test-child-unlock.scm — this box as a fleet host's key-holder
;;;
;;; What has to hold:
;;;
;;;   - a host's passphrase and initrd host key are made once and stay
;;;   - they rest in files only their owner reads
;;;   - the passphrase is offered ONLY to a server proving the initrd's host
;;;     key — the booted system's sshd, another key, is never offered it
;;;   - each way an unlock can go has its own verdict
;;;
;;; The verdicts are checked against a real sshd when one is at hand
;;; (LOCALCHIMERA_TEST_SSHD, or an openssh in the Guix store), which plays the
;;; initrd: one authorized key, a forced command that reads one line.
;;;
;;; Run:  guile -L module tests/fleet/test-child-unlock.scm

(use-modules (localchimera test harness)
             (localchimera fleet child)
             (ice-9 format)
             (ice-9 ftw)
             (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1)
             (srfi srfi-13))

(define %dir (format #f "/tmp/localchimera-test-child-~a" (getpid)))
(system* "rm" "-rf" %dir)
(mkdir %dir #o700)

;;; ── Secrets ───────────────────────────────────────────────────────────────

(ensure-child-secrets! %dir "web-1")

(define (mode file) (logand #o777 (stat:perms (stat file))))

(check "a passphrase of 40 letters and digits is made"
       (let ((p (child-passphrase %dir "web-1")))
         (and (= 40 (string-length p))
              (string-every (lambda (c) (or (char-alphabetic? c) (char-numeric? c))) p))))
(check "two hosts get two passphrases"
       (begin (ensure-child-secrets! %dir "web-2")
              (not (equal? (child-passphrase %dir "web-1")
                           (child-passphrase %dir "web-2")))))
(check "the initrd host key's public half reads as type and key"
       (string-prefix? "ssh-ed25519 AAAA" (child-initrd-host-key-pub %dir "web-1")))
(check "the host's directory, passphrase and key are their owner's alone"
       (and (= #o700 (mode (child-dir %dir "web-1")))
            (= #o600 (mode (child-file %dir "web-1" "luks-passphrase")))
            (= #o600 (mode (child-file %dir "web-1" "initrd-host-key")))))
(check "asked again, the same secrets stand"
       (let ((p (child-passphrase %dir "web-1"))
             (k (child-initrd-host-key-pub %dir "web-1")))
         (ensure-child-secrets! %dir "web-1")
         (and (equal? p (child-passphrase %dir "web-1"))
              (equal? k (child-initrd-host-key-pub %dir "web-1")))))
(check "a name is one path component, whatever it holds"
       (string=? (child-dir %dir "../../etc") (string-append %dir "/fleet-children/.._.._etc")))

(check "a host with no record has no state" (not (child-state %dir "web-9")))
(set-child-state! %dir "web-1" 'installing)
(check "its state is what was last set" (eq? 'installing (child-state %dir "web-1")))

;;; ── Verdicts, from what ssh reports ───────────────────────────────────────

(define %asked '())
(define (fake-run code out)
  (lambda (args stdin-file)
    (set! %asked (cons (cons args stdin-file) %asked))
    (values code out)))

(define (verdict code out)
  (try-unlock! %dir "web-1" "203.0.113.5" "/key" #:run (fake-run code out)))

(check "exit 0 is unlocked" (eq? 'unlocked (verdict 0 "")))
(check "a changed host key is not-waiting"
       (eq? 'not-waiting (verdict 255 "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @")))
(check "a failed host key check is not-waiting"
       (eq? 'not-waiting (verdict 255 "Host key verification failed.")))
(check "no answer is unreachable"
       (eq? 'unreachable (verdict 255 "ssh: connect to host 203.0.113.5 port 22: Connection timed out")))
(check "the initrd turning it down is refused" (eq? 'refused (verdict 1 "")))
(check "a host this box holds nothing for is no-secrets"
       (eq? 'no-secrets (try-unlock! %dir "stranger" "203.0.113.6" "/key"
                                     #:run (fake-run 0 ""))))

(let* ((call (car %asked)) (args (car call)))
  (check "the passphrase reaches ssh as its stdin file, never as an argument"
         (and (string-suffix? "/luks-passphrase" (cdr call))
              (not (member (child-passphrase %dir "web-1") args))))
  (check "the connection trusts one known-hosts file and checks it strictly"
         (and (member "StrictHostKeyChecking=yes" args)
              (any (lambda (a) (string-prefix? "UserKnownHostsFile=" a)) args)
              (member "GlobalKnownHostsFile=/dev/null" args)))
  (check "that file holds the initrd's key for that address, and nothing else"
         (equal? (string-trim-both
                  (call-with-input-file (child-file %dir "web-1" "initrd-known-hosts")
                    get-string-all))
                 (string-append "203.0.113.5 "
                                (child-initrd-host-key-pub %dir "web-1")))))

;;; ── Against a real sshd playing the initrd ────────────────────────────────

(define %sshd
  (or (getenv "LOCALCHIMERA_TEST_SSHD")
      (let* ((port (open-input-pipe
                    "ls -d /gnu/store/*-openssh*/sbin/sshd 2>/dev/null | head -1"))
             (line (read-line port)))
        (close-pipe port)
        (and (string? line) (not (string-null? line)) line))))

(define (free-port)
  (let ((s (socket PF_INET SOCK_STREAM 0)))
    (bind s AF_INET INADDR_LOOPBACK 0)
    (let ((p (sockaddr:port (getsockname s))))
      (close-port s)
      p)))

(define (start-sshd! name host-key-file receiver port)
  "An sshd that lets the parent key in and runs RECEIVER whatever is asked."
  (let* ((d (string-append %dir "/sshd-" name))
         (conf (string-append d "/sshd_config"))
         (auth (string-append d "/authorized_keys")))
    (mkdir d #o700)
    (call-with-output-file auth
      (lambda (p)
        (format p "command=\"~a\",no-pty,no-port-forwarding ~a~%" receiver
                (string-trim-both
                 (call-with-input-file (string-append %dir "/parent.pub")
                   get-string-all)))))
    (chmod auth #o600)
    (call-with-output-file conf
      (lambda (p)
        (format p "Port ~a~%ListenAddress 127.0.0.1~%HostKey ~a~%PidFile ~a/pid~%AuthorizedKeysFile ~a~%PasswordAuthentication no~%StrictModes no~%UsePAM no~%"
                port host-key-file d auth)))
    (system* %sshd "-f" conf "-E" (string-append d "/log"))
    (usleep 700000)
    d))

(define (stop-sshd! d)
  (false-if-exception
   (kill (string->number
          (string-trim-both
           (call-with-input-file (string-append d "/pid") get-string-all)))
         SIGTERM)))

(if (not %sshd)
    (format #t "  (no sshd at hand — the real-SSH verdicts are skipped)~%")
    (let* ((parent (string-append %dir "/parent"))
           (_ (system* "ssh-keygen" "-q" "-t" "ed25519" "-N" "" "-f" parent))
           (receiver (string-append %dir "/receiver.sh"))
           (got (string-append %dir "/received"))
           (me (passwd:name (getpwuid (getuid))))
           (port-1 (free-port)))
      ;; The initrd's side of the interface: one line on stdin is the
      ;; passphrase; exit 0 when it opens the disk.
      (call-with-output-file receiver
        (lambda (p)
          ;; Shell builtins only: sshd hands a forced command a bare PATH.
          (format p "#!/bin/sh\nread -r line\nprintf '%s' \"$line\" > ~a\nread -r want < ~a\n[ \"$line\" = \"$want\" ]\n"
                  got (child-file %dir "web-1" "luks-passphrase"))))
      (chmod receiver #o755)

      (define (unlock! name port)
        (try-unlock! %dir name "127.0.0.1" parent
                     #:port port #:connect-timeout 5
                     #:run (let ((run (ssh-runner)))
                             (lambda (args stdin)
                               (run (append (list "-l" me) args) stdin)))))

      (let ((d (start-sshd! "initrd" (child-file %dir "web-1" "initrd-host-key")
                            receiver port-1)))
        (check "a server holding the initrd key, given the right passphrase: unlocked"
               (eq? 'unlocked (unlock! "web-1" port-1)))
        (check "and what it read on stdin is the passphrase, whole"
               (equal? (child-passphrase %dir "web-1")
                       (call-with-input-file got get-string-all)))
        ;; web-2's passphrase is another one; played against web-1's disk.
        (system* "cp" (child-file %dir "web-1" "initrd-host-key")
                 (child-file %dir "web-2" "initrd-host-key"))
        (system* "cp" (child-file %dir "web-1" "initrd-host-key.pub")
                 (child-file %dir "web-2" "initrd-host-key.pub"))
        (check "the wrong passphrase: refused"
               (eq? 'refused (unlock! "web-2" port-1)))
        (stop-sshd! d))

      ;; The booted system: same address, its own host key.
      (let* ((sys-key (string-append %dir "/system-host-key"))
             (_ (system* "ssh-keygen" "-q" "-t" "ed25519" "-N" "" "-f" sys-key))
             (port-2 (free-port))
             (d (start-sshd! "system" sys-key receiver port-2)))
        (when (file-exists? got) (delete-file got))
        (check "a server with another host key: not-waiting"
               (eq? 'not-waiting (unlock! "web-1" port-2)))
        (check "and the passphrase never reached it"
               (not (file-exists? got)))
        (stop-sshd! d))

      (check "nothing listening: unreachable"
             (eq? 'unreachable (unlock! "web-1" (free-port))))))

(system* "rm" "-rf" %dir)
(test-summary!)
