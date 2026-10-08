;;; deploy/guix/remote-unlock.scm — LUKS root unlocked over SSH from the initrd
;;;
;;; A fleet host reboots unattended: its parent holds the LUKS passphrase
;;; and sends it at every boot.  This module provides the mapped-device
;;; kind that makes the initrd wait for that passphrase on an SSH door.
;;;
;;; Disk layout the kind is made for (deploy/fleet-child-os.scm.example):
;;;   - EFI system partition (vfat) mounted at /boot — GRUB's modules and
;;;     grub.cfg live here, in the clear (plus a 1 MiB BIOS boot partition
;;;     in front of it for BIOS firmware);
;;;   - plain ext4 mounted at /gnu/store (needed-for-boot? #t) — public
;;;     software only; GRUB reads the kernel and the initrd from it;
;;;   - LUKS partition holding "/" — /etc, /var, /home, /root.
;;;
;;; What the initrd does when it opens the mapped device:
;;;   - waits for the network interface, gives it the static IPv4 address,
;;;     adds the default route (rtnetlink from core Guile; IPv4 only);
;;;   - starts dropbear on the SSH port with the dedicated initrd host key,
;;;     public-key authentication only, one authorized key, user root;
;;;   - every session runs the unlock helper whatever command the client
;;;     names: the helper reads ONE LINE from stdin, hands it to
;;;     `cryptsetup open` as the passphrase, exits 0 when the device opens
;;;     and 1 when cryptsetup refuses it;
;;;   - the console keeps a passphrase prompt in parallel (console-fallback?);
;;;   - once /dev/mapper/<target> exists: dropbear stops, the address and
;;;     the route are removed, the interface goes down, boot continues.
;;;
;;; The parent side:
;;;   printf '%s\n' "$PASSPHRASE" | \
;;;     ssh -i KEY -o UserKnownHostsFile=INITRD_KNOWN_HOSTS root@HOST unlock
;;;
;;; The initrd host key sits in /gnu/store, on the plain partition: it
;;; identifies the initrd door only.  The booted system's sshd holds its
;;; own host key under the encrypted /etc/ssh.
;;;
;;; Usage:
;;;   (use-modules (remote-unlock))
;;;   (mapped-device
;;;     (source (uuid "…luks uuid…"))
;;;     (target "cryptroot")
;;;     (type (remote-unlock-luks-mapping
;;;            #:address "203.0.113.7/24"
;;;            #:gateway "203.0.113.1"
;;;            #:authorized-key "ssh-ed25519 AAAA… parent"
;;;            #:host-key-file (local-file "initrd_host_ed25519_key"))))
;;;
;;; Keywords of `remote-unlock-luks-mapping':
;;;   #:address            "A.B.C.D/PREFIX", static IPv4 (required)
;;;   #:gateway            "A.B.C.D" default route, or #f for on-link only
;;;   #:interface          interface name as the initrd sees it ("eth0":
;;;                        udev's renaming happens later, in the booted
;;;                        system)
;;;   #:authorized-key     one OpenSSH public key line (required)
;;;   #:host-key-file      file-like, an OpenSSH-format private key
;;;                        (ed25519/ecdsa/rsa, no passphrase); converted to
;;;                        dropbear's format at build time (required)
;;;   #:port               TCP port of the initrd SSH door (22)
;;;   #:interface-timeout  seconds to wait for the interface (60); when it
;;;                        never appears the console prompt is the one door
;;;   #:console-fallback?  keep a passphrase prompt on the console (#t)
;;;   #:allow-discards?    pass --allow-discards to cryptsetup (#f)
;;;   #:extra-options      more `cryptsetup open' options ('())
;;;
;;; The initrd needs the NIC driver: virtio_net is part of
;;; %base-initrd-modules; other hardware adds its module to the
;;; operating-system's `initrd-modules'.

(define-module (remote-unlock)
  #:use-module (gnu system mapped-devices)
  #:use-module (gnu system uuid)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages cryptsetup)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (remote-unlock-luks-mapping
            dropbear-host-key))

(define (parse-cidr str)
  "Return two values for STR (\"A.B.C.D/PREFIX\"): the address string and the
prefix length."
  (match (string-split str #\/)
    ((address prefix)
     (let ((bits (string->number prefix)))
       (unless (and bits (exact-integer? bits) (<= 0 bits 32)
                    (false-if-exception (inet-pton AF_INET address)))
         (error "remote-unlock: invalid #:address" str))
       (values address bits)))
    (_ (error "remote-unlock: #:address is \"A.B.C.D/PREFIX\"" str))))

(define (dropbear-host-key openssh-key)
  "Return a file-like object: OPENSSH-KEY, a file-like OpenSSH private key,
converted to the format dropbear reads with -r."
  (computed-file "initrd-dropbear-host-key"
                 #~(begin
                     (unless (zero? (system* #$(file-append dropbear
                                                            "/bin/dropbearconvert")
                                             "openssh" "dropbear"
                                             #$openssh-key #$output))
                       (error "dropbearconvert failed")))))

(define* (open-remote-unlock-luks-device source targets
                                         #:key address prefix gateway
                                         interface authorized-key host-key
                                         port interface-timeout
                                         console-fallback?
                                         allow-discards? extra-options)
  "Return the gexp the initrd runs to map SOURCE to the one target in
TARGETS: it serves the SSH unlock door described at the top of this file
and returns #t once the LUKS device is open."
  (with-imported-modules (source-module-closure
                          '((gnu build file-systems)
                            (guix build utils)))
    (match targets
      ((target)
       #~(let* ((source #$(if (uuid? source)
                              (uuid-bytevector source)
                              source))
                (target #$target)
                (mapping (string-append "/dev/mapper/" target))
                (state "/run/remote-unlock")
                (helper (string-append state "/unlock"))
                (guile (readlink "/proc/self/exe"))
                (cryptsetup #$(file-append cryptsetup-static
                                           "/sbin/cryptsetup"))
                (dropbear #$(file-append dropbear "/sbin/dropbear"))
                (open-flags (append '("open" "--type" "luks")
                                    (if #$allow-discards?
                                        '("--allow-discards")
                                        '())
                                    '#$extra-options))
                ;; The LUKS partition, looked up by UUID the way the stock
                ;; mapping does it: udev is absent in the initrd.
                (partition
                 (if (bytevector? source)
                     (or (let loop ((tries-left 20))
                           (and (positive? tries-left)
                                (or (find-partition-by-luks-uuid source)
                                    (begin (sleep 1)
                                           (loop (- tries-left 1))))))
                         (error "LUKS partition not found" source))
                     source)))

           (define (say fmt . args)
             (apply format (current-error-port)
                    (string-append "remote-unlock: " fmt "~%") args)
             (force-output (current-error-port)))

           ;; The initrd's Guile is statically linked: the FFI-backed
           ;; procedures of (guix build syscalls) are absent there.  rtnetlink
           ;; over a plain socket covers link, address and route with core
           ;; Guile alone.
           (define (interface-index)
             (call-with-input-file
                 (string-append "/sys/class/net/" #$interface "/ifindex")
               read))

           (define (ipv4-bytes str)
             (let ((bv (make-bytevector 4)))
               (bytevector-u32-set! bv 0 (inet-pton AF_INET str)
                                    (endianness big))
               bv))

           (define (u32-bytes n)
             (let ((bv (make-bytevector 4)))
               (bytevector-u32-native-set! bv 0 n)
               bv))

           (define (attribute type payload)
             ;; struct rtattr + PAYLOAD; every payload here is 4 bytes, so
             ;; the 4-byte alignment holds.
             (let* ((len (+ 4 (bytevector-length payload)))
                    (bv (make-bytevector len 0)))
               (bytevector-u16-native-set! bv 0 len)
               (bytevector-u16-native-set! bv 2 type)
               (bytevector-copy! payload 0 bv 4 (bytevector-length payload))
               bv))

           (define (concatenate-bytevectors lst)
             (let* ((total (apply + (map bytevector-length lst)))
                    (bv (make-bytevector total 0)))
               (let loop ((lst lst) (offset 0))
                 (match lst
                   (() bv)
                   ((head . tail)
                    (bytevector-copy! head 0 bv offset
                                      (bytevector-length head))
                    (loop tail (+ offset (bytevector-length head))))))))

           (define (rtnetlink! type flags . parts)
             ;; Send one NETLINK_ROUTE request and read the kernel's ACK;
             ;; an error code in the ACK raises.
             (let* ((body (concatenate-bytevectors parts))
                    (len (+ 16 (bytevector-length body)))
                    (msg (make-bytevector len 0))
                    (reply (make-bytevector 4096 0))
                    (sock (socket 16 SOCK_RAW 0))) ;AF_NETLINK, NETLINK_ROUTE
               (bytevector-u32-native-set! msg 0 len)
               (bytevector-u16-native-set! msg 4 type)
               ;; NLM_F_REQUEST | NLM_F_ACK | FLAGS
               (bytevector-u16-native-set! msg 6 (logior 1 4 flags))
               (bytevector-u32-native-set! msg 8 1)
               (bytevector-copy! body 0 msg 16 (bytevector-length body))
               (send sock msg)
               (recv! sock reply)
               (close-port sock)
               (let ((code (if (= 2 (bytevector-u16-native-ref reply 4))
                               (bytevector-s32-native-ref reply 16)
                               0)))
                 (unless (zero? code)
                   (error "rtnetlink request refused" type
                          (strerror (- code)))))))

           (define (link-message up?)
             ;; struct ifinfomsg: IFF_UP set or cleared.
             (let ((bv (make-bytevector 16 0)))
               (bytevector-s32-native-set! bv 4 (interface-index))
               (bytevector-u32-native-set! bv 8 (if up? 1 0))
               (bytevector-u32-native-set! bv 12 1)
               bv))

           (define (address-message)
             ;; struct ifaddrmsg: AF_INET, prefix length, interface.
             (let ((bv (make-bytevector 8 0)))
               (bytevector-u8-set! bv 0 AF_INET)
               (bytevector-u8-set! bv 1 #$prefix)
               (bytevector-u32-native-set! bv 4 (interface-index))
               bv))

           (define (route-message)
             ;; struct rtmsg: default route, main table, RTPROT_BOOT,
             ;; universe scope, unicast, RTNH_F_ONLINK — the gateway of a /32
             ;; address is reachable on the link by declaration.
             (let ((bv (make-bytevector 12 0)))
               (bytevector-u8-set! bv 0 AF_INET)
               (bytevector-u8-set! bv 4 254)
               (bytevector-u8-set! bv 5 3)
               (bytevector-u8-set! bv 7 1)
               (bytevector-u32-native-set! bv 8 4)
               bv))

           (define (wait-for-interface seconds)
             ;; #t once INTERFACE exists; #f after SECONDS.
             (let loop ((left seconds))
               (cond ((file-exists? (string-append "/sys/class/net/"
                                                   #$interface))
                      #t)
                     ((<= left 0) #f)
                     (else (sleep 1) (loop (- left 1))))))

           (define (network-up!)
             (rtnetlink! 16 0 (link-message #t))            ;RTM_NEWLINK
             (rtnetlink! 20 #x600                           ;RTM_NEWADDR
                         (address-message)
                         (attribute 2 (ipv4-bytes #$address))  ;IFA_LOCAL
                         (attribute 1 (ipv4-bytes #$address))) ;IFA_ADDRESS
             (when #$gateway
               (rtnetlink! 24 #x600                         ;RTM_NEWROUTE
                           (route-message)
                           (attribute 5 (ipv4-bytes #$gateway))    ;RTA_GATEWAY
                           (attribute 4 (u32-bytes (interface-index)))))) ;RTA_OIF

           (define (network-down!)
             ;; The booted system's own network service starts from a bare
             ;; interface: route gone, address gone, link down (udev renames
             ;; the interface while it is down).
             (when #$gateway
               (false-if-exception
                (rtnetlink! 25 0                            ;RTM_DELROUTE
                            (route-message)
                            (attribute 5 (ipv4-bytes #$gateway))
                            (attribute 4 (u32-bytes (interface-index))))))
             (false-if-exception
              (rtnetlink! 21 0                              ;RTM_DELADDR
                          (address-message)
                          (attribute 2 (ipv4-bytes #$address))
                          (attribute 1 (ipv4-bytes #$address))))
             (false-if-exception
              (rtnetlink! 16 0 (link-message #f))))

           (define (write-door-files!)
             ;; root's account, its one authorized key, and the helper that
             ;; stands as root's login shell: dropbear runs every session as
             ;; `<shell> -c <command>', so the helper is what runs.
             (let ((home (string-append state "/root")))
               (mkdir-p (string-append home "/.ssh"))
               (chmod state #o700)
               (chmod home #o700)
               (chmod (string-append home "/.ssh") #o700)
               (call-with-output-file (string-append home
                                                     "/.ssh/authorized_keys")
                 (lambda (port)
                   (format port "~a~%" #$authorized-key)))
               (chmod (string-append home "/.ssh/authorized_keys") #o600)
               (mkdir-p "/etc")
               (call-with-output-file "/etc/passwd"
                 (lambda (port)
                   (format port "root:x:0:0:root:~a:~a~%" home helper)))
               (call-with-output-file "/etc/group"
                 (lambda (port)
                   (format port "root:x:0:~%")))
               (call-with-output-file "/etc/shells"
                 (lambda (port)
                   (format port "~a~%" helper)))
               (call-with-output-file helper
                 (lambda (port)
                   (format port "#!~a --no-auto-compile~%!#~%" guile)
                   (write
                    `(begin
                       (use-modules (ice-9 rdelim))
                       (define (finish code message)
                         (display message)
                         (newline)
                         (force-output)
                         (primitive-exit code))
                       (let ((passphrase (read-line (current-input-port))))
                         (when (eof-object? passphrase)
                           (finish 2 "remote-unlock: no passphrase on stdin"))
                         ;; cryptsetup reads the key from its stdin through
                         ;; a pipe: the passphrase stays out of argv and
                         ;; off every file system.
                         (let* ((ends (pipe))
                                (null (open-file "/dev/null" "w"))
                                (pid (spawn ,cryptsetup
                                            (append '("cryptsetup")
                                                    ',open-flags
                                                    '("--key-file" "-"
                                                      ,partition ,target))
                                            #:input (car ends)
                                            #:output null
                                            #:error null)))
                           (close-port (car ends))
                           (display passphrase (cdr ends))
                           (close-port (cdr ends))
                           (let ((status (cdr (waitpid pid))))
                             (if (and (eqv? 0 (status:exit-val status))
                                      (file-exists? ,mapping))
                                 (finish 0 "remote-unlock: unlocked")
                                 (finish 1 "remote-unlock: refused"))))))
                    port)
                   (newline port)))
               (chmod helper #o755)))

           (define (start-dropbear)
             ;; -F foreground, -E log to stderr (the console), -s no
             ;; password logins, -j -k no forwarding, -c the forced command.
             (spawn dropbear
                    (list "dropbear" "-F" "-E" "-s" "-j" "-k"
                          "-p" #$(number->string port)
                          "-r" #$host-key
                          "-c" "unlock"
                          "-I" "120"
                          "-P" (string-append state "/dropbear.pid"))))

           (define (start-console-prompt)
             ;; `cryptsetup open' asking on the console; #f when the console
             ;; cannot be opened.
             (false-if-exception
              (let* ((console (open-file "/dev/console" "r+0"))
                     (pid (spawn cryptsetup
                                 (append '("cryptsetup") open-flags
                                         (list partition target))
                                 #:input console
                                 #:output console
                                 #:error console)))
                (close-port console)
                pid)))

           (define (dropbear-pids)
             ;; Every live dropbear: the listener and its per-session
             ;; children.
             (filter-map
              (lambda (entry)
                (let ((pid (string->number entry)))
                  (and pid
                       (false-if-exception
                        (string=? (readlink (string-append "/proc/" entry
                                                           "/exe"))
                                  dropbear))
                       pid)))
              (scandir "/proc")))

           (define (reap pid)
             ;; #t when child PID has exited.
             (and pid
                  (match (false-if-exception (waitpid pid WNOHANG))
                    ((0 . _) #f)
                    (_ #t))))

           (define (stop! pid)
             (when pid
               (false-if-exception (kill pid SIGTERM))
               (false-if-exception (waitpid pid))))

           ;; LUKS2 takes a lock under /run/cryptsetup.
           (mkdir-p "/run/cryptsetup")
           (mkdir-p state)

           (let ((network?
                  (if (wait-for-interface #$interface-timeout)
                      ;; A refused address or route leaves the console
                      ;; prompt as the one door; the boot goes on.
                      (catch #t
                        (lambda ()
                          (network-up!)
                          (write-door-files!)
                          (say "~a is ~a/~a, SSH unlock door on port ~a"
                               #$interface #$address #$prefix #$port)
                          #t)
                        (lambda args
                          (say "network setup failed: ~s; console prompt only"
                               args)
                          #f))
                      (begin
                        (say "interface ~a absent after ~a s; console prompt only"
                             #$interface #$interface-timeout)
                        #f))))

             (let loop ((ssh (and network? (start-dropbear)))
                        (prompt (and (or #$console-fallback? (not network?))
                                     (start-console-prompt))))
               (cond ((file-exists? mapping)
                      ;; The helper's exit status travels back to the client
                      ;; before the door closes.
                      (sleep 1)
                      (stop! ssh)
                      (for-each (lambda (pid)
                                  (false-if-exception (kill pid SIGTERM)))
                                (dropbear-pids))
                      (stop! prompt)
                      (when network? (network-down!))
                      (say "~a is open; boot continues" mapping)
                      #t)
                     ((and network? (reap ssh))
                      (say "dropbear exited; restarting")
                      (sleep 2)
                      (loop (start-dropbear) prompt))
                     ((and prompt (reap prompt))
                      (sleep 1)
                      (loop ssh (and (not (file-exists? mapping))
                                     (start-console-prompt))))
                     (else
                      (usleep 250000)
                      (loop ssh prompt))))))))))

(define* (remote-unlock-luks-mapping #:key
                                     address
                                     (gateway #f)
                                     (interface "eth0")
                                     authorized-key
                                     host-key-file
                                     (port 22)
                                     (interface-timeout 60)
                                     (console-fallback? #t)
                                     (allow-discards? #f)
                                     (extra-options '()))
  "Return a <mapped-device-kind> for a LUKS device the initrd opens with a
passphrase received over SSH.  See the top of this file for the keywords."
  (unless (and (string? authorized-key)
               (string-prefix? "ssh-" authorized-key)
               (not (string-index authorized-key #\newline)))
    (error "remote-unlock: #:authorized-key is one OpenSSH public key line"
           authorized-key))
  (unless host-key-file
    (error "remote-unlock: #:host-key-file is required"))
  (when gateway
    (unless (false-if-exception (inet-pton AF_INET gateway))
      (error "remote-unlock: invalid #:gateway" gateway)))
  (call-with-values (lambda () (parse-cidr address))
    (lambda (ip prefix)
      (mapped-device-kind
       (inherit luks-device-mapping)
       (open (lambda (source targets . _)
               (open-remote-unlock-luks-device
                source targets
                #:address ip #:prefix prefix #:gateway gateway
                #:interface interface
                #:authorized-key authorized-key
                #:host-key (dropbear-host-key host-key-file)
                #:port port
                #:interface-timeout interface-timeout
                #:console-fallback? console-fallback?
                #:allow-discards? allow-discards?
                #:extra-options extra-options)))
       (modules '((rnrs bytevectors)
                  (ice-9 match)
                  (ice-9 ftw)
                  (srfi srfi-1)
                  ((gnu build file-systems)
                   #:select (find-partition-by-luks-uuid))
                  ((guix build utils) #:select (mkdir-p))))))))
