;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/fleet/child.scm — what this box keeps for each fleet host
;;;
;;; A fleet host's root is LUKS-encrypted, and it reboots with nobody at its
;;; console. The box that provisioned it is its key-holder: it makes the
;;; host's disk passphrase, keeps it, and sends it over SSH each time the
;;; host comes up and waits in its initrd.
;;;
;;; Per host, under <data-dir>/fleet-children/<name>/ (0700):
;;;
;;;   luks-passphrase        the disk passphrase, one line (0600)
;;;   initrd-host-key        the SSH host key the host's INITRD presents (0600)
;;;   initrd-host-key.pub
;;;   state                  where its bootstrap stands: a symbol, one datum
;;;
;;; The initrd's host key is made here, before the host exists, and baked
;;; into its system. So an unlock goes only to a server that proves it holds
;;; that key: the passphrase is never offered to the booted system's sshd (a
;;; different key), nor to anything else answering at that address.
;;;
;;; Unlocking is one SSH command whose stdin is the passphrase:
;;;
;;;   printf '%s\n' PASSPHRASE | ssh -i KEY root@HOST unlock
;;;
;;; exit 0 = the disk opened and the host goes on booting.

(define-module (localchimera fleet child)
  #:use-module (localchimera utils files)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (children-dir
            child-dir
            child-file
            ensure-child-secrets!
            child-passphrase
            child-initrd-host-key-pub
            child-state
            set-child-state!
            random-passphrase
            try-unlock!
            ssh-runner))

(define (children-dir data-dir)
  (string-append data-dir "/fleet-children"))

(define (child-dir data-dir name)
  (string-append (children-dir data-dir) "/" (path-component name)))

(define (child-file data-dir name file)
  (string-append (child-dir data-dir name) "/" file))

(define (write-private! file text)
  (write-atomically! file (lambda (p) (display text p)) #:mode #o600))

(define %passphrase-alphabet
  "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

(define (random-passphrase)
  "40 characters from the kernel's random source, ~230 bits. Letters and
digits only, so it survives any shell, keyboard layout or console."
  (let* ((n 40)
         (len (string-length %passphrase-alphabet))
         (bytes (call-with-input-file "/dev/urandom"
                  (lambda (p) (get-bytevector-n p (* 2 n))))))
    (list->string
     (map (lambda (i)
            (string-ref %passphrase-alphabet
                        (modulo (+ (* 256 (bytevector-u8-ref bytes (* 2 i)))
                                   (bytevector-u8-ref bytes (+ 1 (* 2 i))))
                                len)))
          (iota n)))))

(define* (ensure-child-secrets! data-dir name
                                #:key (ssh-keygen "ssh-keygen"))
  "NAME's passphrase and initrd host key exist; made once, kept from then
on. Returns the host's directory."
  (let* ((dir (child-dir data-dir name))
         (pass (string-append dir "/luks-passphrase"))
         (key (string-append dir "/initrd-host-key")))
    (mkdir-private! dir)
    (unless (file-exists? pass)
      (write-private! pass (string-append (random-passphrase) "\n")))
    (unless (file-exists? key)
      (unless (zero? (system* ssh-keygen "-q" "-t" "ed25519" "-N" ""
                              "-C" (string-append "initrd-" (path-component name))
                              "-f" key))
        (error "fleet child: ssh-keygen failed for" name)))
    dir))

(define (first-line file)
  (and (file-exists? file)
       (let ((line (call-with-input-file file read-line)))
         (and (string? line) (not (string-null? line)) line))))

(define (child-passphrase data-dir name)
  (first-line (child-file data-dir name "luks-passphrase")))

(define (child-initrd-host-key-pub data-dir name)
  "\"ssh-ed25519 AAAA…\" — type and key, without the comment."
  (let ((line (first-line (child-file data-dir name "initrd-host-key.pub"))))
    (and line
         (let ((parts (string-tokenize line)))
           (and (>= (length parts) 2)
                (string-append (car parts) " " (cadr parts)))))))

(define (child-state data-dir name)
  "The host's bootstrap state on this box's record, or #f."
  (let ((file (child-file data-dir name "state")))
    (and (file-exists? file)
         (let ((v (call-with-input-file file read)))
           (and (symbol? v) v)))))

(define (set-child-state! data-dir name state)
  (mkdir-private! (child-dir data-dir name))
  (write-private! (child-file data-dir name "state")
                  (format #f "~s~%" state)))

;;; ── Sending the passphrase ────────────────────────────────────────────────

(define* (ssh-runner #:key (ssh "ssh") (prefix '()))
  "A procedure (ARGS STDIN-FILE) → (values exit-code output) that runs
PREFIX... SSH ARGS... reading STDIN-FILE. PREFIX is how a Tor-only box
reaches the network: '(\"torsocks\"). The passphrase goes from the file it
rests in straight to ssh's stdin; it is never an argument and never copied."
  (lambda (args stdin-file)
    (let* ((port (with-input-from-file stdin-file
                   (lambda ()
                     ;; ssh speaks of host keys and refusals on stderr; the
                     ;; verdict reads both streams.
                     (apply open-pipe* OPEN_READ
                            "sh" "-c" "exec \"$@\" 2>&1" "sh"
                            (append prefix (list ssh) args)))))
           (out (get-string-all port))
           (status (close-pipe port)))
      (values (or (status:exit-val status) 255) out))))

(define* (try-unlock! data-dir name address identity-file
                      #:key
                      (run (ssh-runner))
                      (port 22)
                      (connect-timeout 25))
  "Offer NAME's passphrase to the initrd at ADDRESS. Answers one of:

  unlocked     the initrd took the passphrase and the disk is open
  refused      the initrd answered and turned the passphrase down
  not-waiting  something else holds that address's SSH port — the booted
               system, whose host key is another one
  unreachable  nothing answered
  no-secrets   this box holds no passphrase or initrd key for NAME"
  (let ((passphrase (child-passphrase data-dir name))
        (host-key (child-initrd-host-key-pub data-dir name)))
    (if (not (and passphrase host-key))
        'no-secrets
        (let ((known (child-file data-dir name "initrd-known-hosts")))
          ;; The only key this connection trusts is the one made for the
          ;; host's initrd.
          (write-private! known
                          (format #f "~a ~a~%"
                                  (if (= port 22)
                                      address
                                      (format #f "[~a]:~a" address port))
                                  host-key))
          (call-with-values
            (lambda ()
              (run (list "-i" identity-file
                         "-p" (number->string port)
                         "-o" "BatchMode=yes"
                         "-o" "IdentitiesOnly=yes"
                         "-o" "StrictHostKeyChecking=yes"
                         "-o" (string-append "UserKnownHostsFile=" known)
                         "-o" "GlobalKnownHostsFile=/dev/null"
                         "-o" (format #f "ConnectTimeout=~a" connect-timeout)
                         "-o" "LogLevel=ERROR"
                         (string-append "root@" address)
                         "unlock")
                   (child-file data-dir name "luks-passphrase")))
            (lambda (code out)
              (cond
               ((zero? code) 'unlocked)
               ((or (string-contains out "HOST IDENTIFICATION HAS CHANGED")
                    (string-contains out "Host key verification failed"))
                'not-waiting)
               ((= code 255) 'unreachable)
               (else 'refused))))))))
