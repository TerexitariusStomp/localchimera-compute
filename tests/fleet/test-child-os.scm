;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/fleet/test-child-os.scm — one host's operating-system, from the one template
;;;
;;; What has to hold:
;;;
;;;   - the shipped template fills completely, and the result reads as Scheme
;;;   - every value lands where its placeholder stood; comment lines stay as written
;;;   - a placeholder with no value stops the render (no half-filled config)
;;;   - a value cannot break out of the string literal it sits in
;;;   - the keys come from the right places: the initrd host key from this
;;;     box's record of the host, the door's key from the parent's public key
;;;
;;; Run:  guile -L module tests/fleet/test-child-os.scm

(use-modules (playnet test harness)
             (ice-9 popen)
             (srfi srfi-1)
             (playnet fleet child)
             (playnet fleet child-os)
             (ice-9 rdelim)
             (ice-9 regex)
             (ice-9 textual-ports)
             (srfi srfi-13))

(define %dir (format #f "/tmp/playnet-test-child-os-~a" (getpid)))
(system* "rm" "-rf" %dir)
(mkdir %dir #o700)

(define pub (string-append %dir "/parent.pub"))
(call-with-output-file pub
  (lambda (p) (display "ssh-ed25519 AAAAparentkey parent@box\n" p)))
(define root-pub (string-append %dir "/root.pub"))
(call-with-output-file root-pub
  (lambda (p) (display "ssh-ed25519 AAAArootkey operator\n" p)))

(ensure-child-secrets! %dir "web-1")

(define template
  (call-with-input-file "deploy/fleet-child-os.scm.example" get-string-all))

(define (bindings . overrides)
  (apply child-os-bindings %dir "web-1"
         #:address "203.0.113.7" #:prefix "24" #:gateway "203.0.113.1"
         #:identity-pub pub
         #:luks-uuid "11111111-2222-3333-4444-555555555555"
         #:store-uuid "66666666-7777-8888-9999-000000000000"
         #:esp-uuid "1234-ABCD"
         #:firmware 'uefi
         overrides))

(define out (render-child-os template (bindings)))

(define (contains? s) (string-contains out s))

(define (code-placeholder? line)
  (and (not (string-prefix? ";" (string-trim line)))
       (string-match "@[A-Z][A-Z_]*@" line)))

(begin
  (check "no code line keeps a placeholder" (not (any code-placeholder? (string-split out #\newline))))
  (check "the result reads as Scheme" (call-with-input-string out
      (lambda (p) (let loop ((n 0)) (if (eof-object? (read p)) (> n 0) (loop (+ n 1)))))))
  (check "host name" (contains? "(host-name \"web-1\")"))
  (check "address and gateway" (and (contains? "#:address \"203.0.113.7/24\"")
         (contains? "#:gateway \"203.0.113.1\"")))
  (check "disk identities" (and (contains? "(uuid \"11111111-2222-3333-4444-555555555555\")")
         (contains? "(uuid \"66666666-7777-8888-9999-000000000000\")")
         (contains? "(uuid \"1234-ABCD\" 'fat)")))
  (check "UEFI bootloader" (and (contains? "(bootloader grub-efi-removable-bootloader)")
         (contains? "(targets '(\"/boot\"))")))
  (check "name servers are a list of strings" (contains? "(name-servers '(\"9.9.9.9\" \"149.112.112.112\"))"))
  (check "no extra kernel arguments" (contains? "(kernel-arguments '(\"net.ifnames=0\" ))"))
  (check "comment lines stay as written" (contains? ";;;   @HOST_NAME@             host name")))

(begin
  (check "the initrd door accepts the parent's key" (contains? "(define %parent-public-key \"ssh-ed25519 AAAAparentkey parent@box\")"))
  (check "root's sshd defaults to the parent's key" (contains? "\"ssh-ed25519 AAAAparentkey parent@box\\n\""))
  (check "the initrd host key is the one this box holds for the host" (contains? (string-append "(local-file \"" %dir
                              "/fleet-children/web-1/initrd-host-key\"")))
  (check "another root key replaces the default" (let ((o (render-child-os template (bindings #:root-authorized-key
                                                 "ssh-ed25519 AAAArootkey operator"))))
      (string-contains o "\"ssh-ed25519 AAAArootkey operator\\n\""))))

(begin
  (check "the initrd key can sit at the path the installing machine sees"
         (string-contains
          (render-child-os template
                           (bindings #:initrd-host-key-file "/root/initrd-key"))
          "(local-file \"/root/initrd-key\"")))

(begin
  (let ((o (render-child-os
            template
            (bindings #:firmware 'bios #:disk "/dev/vda"
                      #:extra-kernel-arguments '("console=ttyS0,115200")
                      #:name-servers '("10.0.2.3")))))
    (check "BIOS bootloader on the disk" (and (string-contains o "(bootloader grub-bootloader)")
           (string-contains o "(targets '(\"/dev/vda\"))")))
    (check "kernel argument kept as one string" (string-contains o "'(\"net.ifnames=0\" \"console=ttyS0,115200\")"))
    (check "one name server" (string-contains o "(name-servers '(\"10.0.2.3\"))")))
  (check "a BIOS host names its disk" (catch #t (lambda () (bindings #:firmware 'bios) #f) (lambda _ #t))))

(begin
  (check "a placeholder with no value stops the render" (catch #t
      (lambda () (render-child-os template (list '("HOST_NAME" . "x"))) #f)
      (lambda _ #t)))
  (check "a quote cannot leave its string literal" (catch #t
      (lambda () (render-child-os template (bindings #:gateway "1.2.3.4\") (evil")) #f)
      (lambda _ #t)))
  (check "a newline cannot start a new line" (catch #t
      (lambda () (render-child-os template (bindings #:luks-uuid "a\nb")) #f)
      (lambda _ #t)))
  (check "a host with no address stops" (catch #t (lambda () (child-os-bindings %dir "web-1" #:prefix "24" #:gateway "g"
                                            #:identity-pub pub) #f)
      (lambda _ #t)))
  (check "a missing public key stops" (catch #t (lambda () (bindings #:identity-pub "/nonexistent.pub") #f)
      (lambda _ #t))))

;;; ── The network, from the first place that names it ──────────────────────

(define (env . pairs) (lambda (k) (assoc-ref pairs k)))
(define fleet '((prefix . 24) (gateway . "10.0.0.1") (interface . "ens3")
                (name-servers . ("8.8.8.8"))))

(let ((net (lambda args (apply resolve-network args))))
  (check "the fleet file fills what nothing above it names"
         (net #:fleet-net fleet)
         '((prefix . 24) (gateway . "10.0.0.1") (interface . "ens3")
           (name-servers "8.8.8.8")))
  (check "the environment beats the fleet file"
         (assq-ref (net #:fleet-net fleet
                        #:env (env '("PLAYNET_GATEWAY" . "10.9.9.1")
                                   '("PLAYNET_NAMESERVERS" . "1.1.1.1,9.9.9.9")))
                   'gateway)
         "10.9.9.1")
  (check "a comma-separated environment list is split"
         (assq-ref (net #:fleet-net fleet
                        #:env (env '("PLAYNET_NAMESERVERS" . "1.1.1.1,9.9.9.9")))
                   'name-servers)
         '("1.1.1.1" "9.9.9.9"))
  (check "the host's provider-params beat the environment"
         (assq-ref (net #:fleet-net fleet
                        #:host-params '(("network-gateway" . "10.5.5.1"))
                        #:env (env '("PLAYNET_GATEWAY" . "10.9.9.1")))
                   'gateway)
         "10.5.5.1")
  (check "an explicit option beats everything"
         (assq-ref (net #:fleet-net fleet
                        #:explicit '((gateway . "10.7.7.1"))
                        #:host-params '(("network-gateway" . "10.5.5.1")))
                   'gateway)
         "10.7.7.1")
  (check "interface and name servers have defaults"
         (let ((n (net #:explicit '((prefix . 24) (gateway . "10.0.0.1")))))
           (list (assq-ref n 'interface) (assq-ref n 'name-servers)))
         '("eth0" ("9.9.9.9" "149.112.112.112")))
  (check "no prefix, no default: the resolver stops"
         (raises? (lambda () (net #:explicit '((gateway . "10.0.0.1"))))))
  (check "no gateway, no default: the resolver stops"
         (raises? (lambda () (net #:explicit '((prefix . 24))))))
  (check "a prefix past 32 stops"
         (raises? (lambda () (net #:explicit '((prefix . 33) (gateway . "10.0.0.1"))))))
  (check "a prefix that is no number stops"
         (raises? (lambda () (net #:env (env '("PLAYNET_PREFIX" . "big"))
                                  #:explicit '((gateway . "10.0.0.1"))))))
  (check "a gateway that is no IPv4 address stops"
         (raises? (lambda () (net #:explicit '((prefix . 24) (gateway . "10.0.0.256"))))))
  (check "a name server with a quote stops"
         (raises? (lambda () (net #:explicit '((prefix . 24) (gateway . "10.0.0.1")
                                               (name-servers . ("1.1.1.1\")")))))))
  (check "an interface name with a space stops"
         (raises? (lambda () (net #:explicit '((prefix . 24) (gateway . "10.0.0.1")
                                               (interface . "eth 0")))))))

(check "an address that is no IPv4 address stops the bindings"
       (raises? (lambda () (bindings #:address "203.0.113.7; (evil)"))))

;;; ── The CLI resolves the same way ────────────────────────────────────────

(let* ((deploy (string-append %dir "/deploy"))
       (run (lambda (extra)
              (let* ((port (apply open-pipe* OPEN_READ
                                  "guile" "--no-auto-compile" "-L" "module"
                                  "deploy/scripts/render-child-os.scm" "web-1"
                                  "--data-dir" %dir "--deploy-dir" deploy
                                  "--identity-pub" pub "--address" "203.0.113.7"
                                  "--luks-uuid" "L" "--store-uuid" "S"
                                  "--esp-uuid" "1234-ABCD" "--uefi" extra))
                     (out (get-string-all port)))
                (close-pipe port)
                out))))
  (mkdir deploy)
  (call-with-output-file (string-append deploy "/fleet-network.scm")
    (lambda (p) (write (list (quote quote) fleet) p)))
  (call-with-output-file (string-append deploy "/desired-fleet.scm")
    (lambda (p)
      (write '(list (desired-host #:name "web-1" #:flavor "f" #:provider "p"
                                  #:provider-params '(("network-gateway" . "10.5.5.1"))))
             p)))
  (call-with-output-file (string-append deploy "/fleet-child-os.scm.example")
    (lambda (p) (display (string-append "@ADDRESS_CIDR@ @GATEWAY@ @INTERFACE@ @NAME_SERVERS@\n"
                                        "@HOST_NAME@ @LUKS_UUID@ @STORE_UUID@ @ESP_UUID@\n"
                                        "@BOOTLOADER@ @BOOTLOADER_TARGET@ @EXTRA_KERNEL_ARGUMENTS@\n"
                                        "@PARENT_PUBLIC_KEY@ @ROOT_AUTHORIZED_KEY@ @INITRD_HOST_KEY_FILE@\n")
                         p)))
  (check "the CLI takes the host's provider-params, then the fleet file"
         (string-prefix? "203.0.113.7/24 10.5.5.1 ens3 \"8.8.8.8\"" (run '())))
  (check "a CLI option beats both"
         (string-prefix? "203.0.113.7/24 10.7.7.1 ens3" (run '("--gateway" "10.7.7.1")))))

(system* "rm" "-rf" %dir)
(test-summary!)
