;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/scripts/render-child-os.scm — a fleet host's operating-system, filled in
;;;
;;;   guile -L module deploy/scripts/render-child-os.scm NAME \
;;;     --prefix 24 --gateway 203.0.113.1 \
;;;     --luks-uuid … --store-uuid … --esp-uuid 1234-ABCD \
;;;     (--uefi | --bios /dev/vda) > child-os.scm
;;;
;;; Fills deploy/fleet-child-os.scm.example for host NAME from this box's
;;; records: the host's address from hosts.scm, its passphrase-door host key
;;; from <data-dir>/fleet-children/NAME/ (made on first use), the parent's
;;; provisioning public key. The disk's three UUIDs are what the person or
;;; program that partitioned the disk read back from it.
;;;
;;; Options:
;;;   --address A.B.C.D    the host's address (default: hosts.scm's record)
;;;   --prefix N           network prefix length
;;;   --gateway A.B.C.D    default gateway
;;;   --luks-uuid U        `cryptsetup luksUUID` of the LUKS partition
;;;   --store-uuid U       ext4 UUID of the /gnu/store partition
;;;   --esp-uuid U         vfat volume id of the ESP, "1234-ABCD"
;;;   --uefi | --bios DISK firmware; DISK is where a BIOS host's GRUB goes
;;;   --interface IF       the initrd's interface name
;;;   --name-server A.B.C.D  repeatable
;;;   --kernel-arg ARG     repeatable, e.g. console=ttyS0,115200
;;;   --root-key FILE      public key root's sshd accepts     (the parent's)
;;;   --identity-pub FILE  the parent's provisioning public key
;;;   --initrd-host-key-file FILE
;;;                        the initrd door's private key as `guix system init`
;;;                        sees it (default: this box's record of the host)
;;;   --data-dir DIR       where the per-host secrets live (PLAYNET_DATA_DIR)
;;;   --deploy-dir DIR     where hosts.scm and the template live
;;;   --template FILE      another template
;;;
;;; Prefix, gateway, interface and name servers come from the first of: the
;;; options above, the host's provider-params in desired-fleet.scm
;;; ("network-prefix" "network-gateway" "network-interface"
;;; "network-name-servers"), PLAYNET_PREFIX / _GATEWAY / _INTERFACE /
;;; _NAMESERVERS, deploy/fleet-network.scm. Prefix and gateway have no
;;; default and must come from one of them; the interface defaults to eth0
;;; and the name servers to public resolvers.

(use-modules (playnet fleet child)
             (playnet fleet child-os)
             (playnet fleet records)
             (ice-9 format)
             (ice-9 match)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (srfi srfi-1))

(define (die fmt . args)
  (apply format (current-error-port) (string-append "render-child-os: " fmt "~%") args)
  (exit 2))

(define (parse args)
  "ARGS → an alist of options; repeatable ones collect a list."
  (let loop ((args args) (opts '()))
    (match args
      (() opts)
      (("--uefi" . rest) (loop rest (cons '(firmware . uefi) opts)))
      (("--bios" disk . rest)
       (loop rest `((firmware . bios) (disk . ,disk) ,@opts)))
      (((and flag (or "--address" "--prefix" "--gateway" "--luks-uuid" "--store-uuid"
                      "--esp-uuid" "--interface" "--root-key" "--identity-pub"
                      "--data-dir" "--deploy-dir" "--template"
                      "--initrd-host-key-file"))
        value . rest)
       (loop rest (cons (cons (string->symbol (string-drop flag 2)) value) opts)))
      (((and flag (or "--name-server" "--kernel-arg")) value . rest)
       (loop rest (cons (cons (string->symbol (string-drop flag 2)) value) opts)))
      ((("--" . _) . _) (die "unknown option ~a" (car args)))
      ((word . rest) (loop rest (cons (cons 'name word) opts))))))

(define (opt opts key) (assq-ref opts key))
(define (opts* opts key)
  (filter-map (lambda (p) (and (eq? (car p) key) (cdr p))) (reverse opts)))

(define (main args)
  (let* ((opts (parse args))
         (name (or (opt opts 'name) (die "a host name is needed")))
         (data-dir (or (opt opts 'data-dir) (getenv "PLAYNET_DATA_DIR") "/var/lib/playnet"))
         (deploy-dir (or (opt opts 'deploy-dir) (getenv "PLAYNET_DEPLOY_DIR") "deploy"))
         (identity-pub (or (opt opts 'identity-pub)
                           (string-append (passwd:dir (getpwuid (getuid)))
                                          "/.ssh/id_ed25519.pub")))
         (hosts-file (string-append deploy-dir "/hosts.scm"))
         (recorded (and (file-exists? hosts-file)
                        (find (lambda (m) (equal? (materialized-host-name m) name))
                              (load-fleet-file hosts-file))))
         (desired (find (lambda (h) (equal? (desired-host-name h) name))
                        (load-fleet-file (string-append deploy-dir "/desired-fleet.scm"))))
         (fleet-net (let ((f (string-append deploy-dir "/fleet-network.scm")))
                      (if (file-exists? f) (primitive-load f) '())))
         (net (resolve-network
               #:explicit (filter-map
                           (lambda (k)
                             (let ((v (if (eq? k 'name-servers)
                                          (let ((l (opts* opts 'name-server)))
                                            (and (pair? l) l))
                                          (opt opts k))))
                               (and v (cons k v))))
                           '(prefix gateway interface name-servers))
               #:host-params (if desired (desired-host-provider-params desired) '())
               #:fleet-net fleet-net))
         (address (or (opt opts 'address)
                      (and recorded (materialized-host-ipv4 recorded))
                      (die "no address: ~a is not in ~a; pass --address" name hosts-file)))
         (template (or (opt opts 'template)
                       (string-append deploy-dir "/fleet-child-os.scm.example"))))
    (ensure-child-secrets! data-dir name)
    (let ((bindings
           (child-os-bindings
            data-dir name
            #:address address
            #:prefix (assq-ref net 'prefix)
            #:gateway (assq-ref net 'gateway)
            #:identity-pub identity-pub
            #:luks-uuid (opt opts 'luks-uuid)
            #:store-uuid (opt opts 'store-uuid)
            #:esp-uuid (opt opts 'esp-uuid)
            #:firmware (opt opts 'firmware)
            #:disk (opt opts 'disk)
            #:interface (assq-ref net 'interface)
            #:name-servers (assq-ref net 'name-servers)
            #:extra-kernel-arguments (opts* opts 'kernel-arg)
            #:initrd-host-key-file (opt opts 'initrd-host-key-file)
            #:root-authorized-key
            (and=> (opt opts 'root-key)
                   (lambda (f) (string-trim-both (call-with-input-file f read-line)))))))
      (display (render-child-os (call-with-input-file template get-string-all)
                                bindings)))))

(catch #t
  (lambda () (main (cdr (command-line))))
  (lambda (key . args)
    (match args
      ((_ fmt fmt-args . _)
       (die "~a" (if (string? fmt) (apply format #f fmt (if (list? fmt-args) fmt-args '())) fmt)))
      (_ (die "~a ~s" key args)))))
