;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/fleet/child-os.scm — one host's operating-system, from the one template
;;;
;;; deploy/fleet-child-os.scm.example is the operating-system of every fleet
;;; host that reboots unattended. Its host-specific values are @NAME@
;;; placeholders. This module fills them:
;;;
;;;   (child-os-bindings DATA-DIR NAME #:address … #:prefix … #:gateway …
;;;                      #:identity-pub … #:luks-uuid … #:store-uuid …
;;;                      #:esp-uuid … #:bootloader …)   → an alist
;;;   (render-child-os TEMPLATE-TEXT BINDINGS)          → the filled text
;;;
;;; What comes from this box's per-host record ((playnet fleet child)): the
;;; initrd host key's file name. What comes from the parent's provisioning
;;; key: the one public key the initrd door accepts, and the key root's sshd
;;; accepts in the booted system. What the caller gives: where the host is
;;; (address, prefix, gateway) and what its disk looks like once partitioned
;;; (the three UUIDs, the firmware's bootloader).
;;;
;;; The result is a Scheme file that `guix system init` reads, so a value
;;; enters it as data: a value that sits inside a string literal carries no
;;; quote, backslash or newline, and every placeholder the template names is
;;; bound before anything is written.

(define-module (playnet fleet child-os)
  #:use-module (playnet fleet child)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (render-child-os
            child-os-bindings
            bootloader-bindings
            resolve-network
            %raw-placeholders))

;;; ── Network values ────────────────────────────────────────────────────────

(define %ipv4 (make-regexp "^([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})$"))

(define (ipv4? s)
  (and (string? s)
       (let ((m (regexp-exec %ipv4 s)))
         (and m (every (lambda (i) (<= (string->number (match:substring m i)) 255))
                       '(1 2 3 4))))))

(define (check-ipv4! what s)
  (unless (ipv4? s)
    (error "child-os: not an IPv4 address" what s)))

(define (check-prefix! p)
  (let ((n (if (string? p) (string->number p) p)))
    (unless (and (integer? n) (<= 0 n 32))
      (error "child-os: a network prefix is a number from 0 to 32" p))
    n))

(define (check-interface! s)
  (unless (and (string? s) (regexp-exec (make-regexp "^[A-Za-z0-9._:-]{1,15}$") s))
    (error "child-os: not an interface name" s)))

(define %default-name-servers '("9.9.9.9" "149.112.112.112"))

(define* (resolve-network #:key (explicit '()) (host-params '())
                          (env getenv) (fleet-net '()))
  "The host's network: an alist with prefix, gateway, interface, name-servers.
Each value comes from the first of these that names it:

  1. EXPLICIT       an alist keyed prefix/gateway/interface/name-servers
  2. HOST-PARAMS    the host's provider-params: \"network-prefix\",
                    \"network-gateway\", \"network-interface\",
                    \"network-name-servers\"
  3. ENV            a procedure name → string or #f: PLAYNET_PREFIX,
                    PLAYNET_GATEWAY, PLAYNET_INTERFACE, PLAYNET_NAMESERVERS
                    (comma-separated)
  4. FLEET-NET      deploy/fleet-network.scm's alist, the fleet-wide defaults

Prefix and gateway have no default: a static address on a guessed network
is a host nobody can reach. Interface defaults to eth0, the name servers to
public resolvers. Every value is checked before it is returned."
  (define (from-env var parse)
    (let ((v (env var)))
      (and v (not (string-null? v)) (parse v))))
  (define (layer key param var parse)
    (or (assq-ref explicit key)
        (assoc-ref host-params param)
        (from-env var parse)
        (assq-ref fleet-net key)))
  (define (number-or-error v)
    (or (string->number v) (error "child-os: PLAYNET_PREFIX is not a number" v)))
  (let ((prefix (layer 'prefix "network-prefix" "PLAYNET_PREFIX" number-or-error))
        (gateway (layer 'gateway "network-gateway" "PLAYNET_GATEWAY" identity))
        (interface (or (layer 'interface "network-interface" "PLAYNET_INTERFACE" identity)
                       "eth0"))
        (name-servers (or (layer 'name-servers "network-name-servers"
                                 "PLAYNET_NAMESERVERS"
                                 (lambda (v) (string-split v #\,)))
                          %default-name-servers)))
    (unless prefix
      (error "child-os: no network prefix: give one as an option, in the host's provider-params, in PLAYNET_PREFIX, or in fleet-network.scm"))
    (unless gateway
      (error "child-os: no network gateway: give one as an option, in the host's provider-params, in PLAYNET_GATEWAY, or in fleet-network.scm"))
    (check-ipv4! "gateway" gateway)
    (for-each (lambda (ns) (check-ipv4! "name server" ns)) name-servers)
    (check-interface! interface)
    `((prefix . ,(check-prefix! prefix))
      (gateway . ,gateway)
      (interface . ,interface)
      (name-servers . ,name-servers))))

;; Placeholders whose value is a piece of Scheme: a list of quoted strings,
;; or an identifier. Every other placeholder sits inside a string literal.
(define %raw-placeholders '("NAME_SERVERS" "EXTRA_KERNEL_ARGUMENTS" "BOOTLOADER"))

(define %placeholder (make-regexp "@([A-Z][A-Z_]*)@"))

(define (comment-line? line)
  (string-prefix? ";" (string-trim line)))

(define (check-value! name value)
  (unless (string? value)
    (error "child-os: the value of a placeholder is a string" name value))
  (when (string-any #\newline value)
    (error "child-os: a value is one line" name))
  (unless (member name %raw-placeholders)
    (when (or (string-any #\" value) (string-any #\\ value))
      (error "child-os: a value inside a string literal carries no quote or backslash"
             name))))

(define (fill-line line bindings missing)
  "LINE with each @NAME@ replaced; the names it could not fill go to MISSING."
  (regexp-substitute/global
   #f %placeholder line
   'pre
   (lambda (m)
     (let* ((name (match:substring m 1))
            (entry (assoc name bindings)))
       (cond (entry (check-value! name (cdr entry))
                    (cdr entry))
             (else (set-car! missing (cons name (car missing)))
                   (match:substring m 0)))))
   'post))

(define (render-child-os template bindings)
  "TEMPLATE (a string) with every @NAME@ of a code line replaced by its
binding. Comment lines are copied as they are: they document the
placeholders. Raises when a code line names a placeholder BINDINGS lacks."
  (let* ((missing (list '()))
         (lines (string-split template #\newline))
         (out (map (lambda (line)
                     (if (comment-line? line)
                         line
                         (fill-line line bindings missing)))
                   lines)))
    (unless (null? (car missing))
      (error "child-os: placeholders with no value"
             (sort (delete-duplicates (car missing)) string<?)))
    (string-join out "\n")))

(define (public-key-line file)
  "The first line of FILE, an OpenSSH public key."
  (let ((line (and (file-exists? file)
                   (call-with-input-file file read-line))))
    (unless (and (string? line) (string-prefix? "ssh-" line))
      (error "child-os: no OpenSSH public key in" file))
    (string-trim-both line)))

(define (bootloader-bindings firmware disk)
  "The two placeholders that follow the host's firmware: FIRMWARE is 'uefi
or 'bios; DISK (\"/dev/vda\") is where a BIOS host's GRUB goes."
  (case firmware
    ((uefi) '(("BOOTLOADER" . "grub-efi-removable-bootloader")
              ("BOOTLOADER_TARGET" . "/boot")))
    ((bios)
     (unless disk (error "child-os: a BIOS host names the disk its GRUB goes on"))
     `(("BOOTLOADER" . "grub-bootloader")
       ("BOOTLOADER_TARGET" . ,disk)))
    (else (error "child-os: firmware is 'uefi or 'bios" firmware))))

(define* (child-os-bindings data-dir name
                            #:key
                            address prefix gateway
                            identity-pub
                            luks-uuid store-uuid esp-uuid
                            firmware disk
                            (interface "eth0")
                            (name-servers '("9.9.9.9" "149.112.112.112"))
                            (extra-kernel-arguments '())
                            (root-authorized-key #f)
                            (initrd-host-key-file #f))
  "The alist that fills the template for NAME. IDENTITY-PUB is the parent's
provisioning public key file; ROOT-AUTHORIZED-KEY is the line the booted
system's sshd accepts for root, by default that same key.
INITRD-HOST-KEY-FILE is where `guix system init` finds the initrd door's
private key: the file's name on the machine that runs it. By default that is
this box's record of the host; an install that runs on the target puts the
key there and names its path here."
  (define (quoted strings)
    (string-join (map (lambda (s) (string-append "\"" s "\"")) strings) " "))
  (unless (and address prefix gateway)
    (error "child-os: the host's address, prefix and gateway are needed"))
  (check-ipv4! "address" address)
  (check-ipv4! "gateway" gateway)
  (for-each (lambda (ns) (check-ipv4! "name server" ns)) name-servers)
  (check-interface! interface)
  (let ((parent-key (public-key-line identity-pub)))
    (append
     `(("HOST_NAME" . ,name)
       ("ADDRESS_CIDR" . ,(format #f "~a/~a" address (check-prefix! prefix)))
       ("GATEWAY" . ,gateway)
       ("INTERFACE" . ,interface)
       ("NAME_SERVERS" . ,(quoted name-servers))
       ("EXTRA_KERNEL_ARGUMENTS" . ,(quoted extra-kernel-arguments))
       ("LUKS_UUID" . ,luks-uuid)
       ("STORE_UUID" . ,store-uuid)
       ("ESP_UUID" . ,esp-uuid)
       ("PARENT_PUBLIC_KEY" . ,parent-key)
       ("ROOT_AUTHORIZED_KEY" . ,(or root-authorized-key parent-key))
       ("INITRD_HOST_KEY_FILE"
        . ,(or initrd-host-key-file
               (child-file data-dir name "initrd-host-key"))))
     (bootloader-bindings firmware disk))))
