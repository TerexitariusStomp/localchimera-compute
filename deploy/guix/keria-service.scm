;;; deploy/guix/keria-service.scm — Guix/Shepherd services for KERIA + witnesses
;;;
;;; Runs KERIA (cloud agent) and kli witness nodes as native Shepherd services.
;;; No Docker — packages are defined in python-keria.scm and installed via Guix.
;;;
;;; Two services:
;;;   keria    — KERIA cloud agent (ports 3901/3902/3903, localhost only)
;;;   keri-witnesses — kli witness demo (ports 5642-5647, public)
;;;
;;; The witness nodes provide KEL (Key Event Log) durability. If the playnet
;;; server is replaced, users reconnect with their AID — witnesses hold the
;;; KEL history so identity is recovered automatically.
;;;
;;; Usage: add (service keria-service-type) to the services list in system.scm.
;;; Both services are enabled by default with one (service keria-service-type).

(define-module (keria-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (python-keria)         ; python-keria, python-keri packages
  #:export (keria-configuration
            keria-configuration?
            keria-service-type))

;;; ── Configuration ────────────────────────────────────────────────────────────

(define-record-type* <keria-configuration>
  keria-configuration make-keria-configuration
  keria-configuration?
  ;; Directory for KERIA's persistent data (LEI, KELs, credentials)
  (data-dir  keria-configuration-data-dir
             (default "/var/lib/playnet/keria"))
  ;; Path to keria.json config (witness OOBIs, connect URLs)
  (config    keria-configuration-config
             (default "/var/lib/playnet/keria/config/keria.json"))
  ;; Port for KERIA admin API (signature-authenticated)
  (admin-port keria-configuration-admin-port
              (default 3901))
  ;; Port for KERIA agent HTTP API
  (agent-port keria-configuration-agent-port
              (default 3902))
  ;; Port for KERIA boot/connect API
  (boot-port  keria-configuration-boot-port
              (default 3903))
  ;; User to run as
  (user       keria-configuration-user
              (default "playnet"))
  ;; Witness pool: alist of (name . port). Each entry becomes one
  ;; Shepherd service + one keystore under <data-dir>/{witnesses,ks}/<name>/.
  ;; Default is the canonical full pool (6 witnesses on the standard
  ;; KERI ports). Shrink for sister hosts to run a disjoint subset; see
  ;; docs/governance/GOVERNANCE-CEREMONIES.md §2.4-§2.5. Toad table
  ;; (witnesses.scm:%toad-table) requires ≥4 active witnesses across
  ;; the federation for a meaningful quorum; fewer is allowed for
  ;; testing but flagged by preflight.
  (witnesses  keria-configuration-witnesses
              (default '(("wan" . 5642)
                         ("wil" . 5643)
                         ("wes" . 5644)
                         ("wit" . 5645)
                         ("wub" . 5646)
                         ("wyz" . 5647)))))

;;; ── KERIA agent service ──────────────────────────────────────────────────────

(define (keria-shepherd-service config)
  (let* ((data-dir    (keria-configuration-data-dir config))
         (config-file (keria-configuration-config config))
         (admin-port  (keria-configuration-admin-port config))
         (agent-port  (keria-configuration-agent-port config))
         ;; Capture passcode at deploy time from secrets.scm env
         (passcode    (or (getenv "KERIA_PASSCODE") ""))
         (boot-port   (keria-configuration-boot-port config))
         (user        (keria-configuration-user config))
         ;; Use the keria binary from the python-keria package
         (keria-bin   (file-append python-keria "/bin/keria")))
    (append
     (list
     ;; ── keria ────────────────────────────────────────────────────────────
     (shepherd-service
      (documentation "KERIA KERI cloud agent for playnet identity")
      (provision '(keria))
      (requirement '(networking loopback))
      (start #~(make-forkexec-constructor
                (append
                 (list #$keria-bin "start"
                       "--config-dir" (dirname #$config-file)
                       "--config-file" (basename #$config-file)
                       "--admin-http-port" (number->string #$admin-port)
                       "--http" (number->string #$agent-port)
                       "--boot" (number->string #$boot-port))
                 ;; Add --passcode if set in secrets.scm
                 #$(if (string-null? passcode)
                       #~'()
                       #~(list "--passcode" #$passcode)))
                #:user #$user
                #:directory #$data-dir
                #:log-file "/var/log/playnet/keria.log"
                #:environment-variables
                (list (string-append "HOME=" #$data-dir)
                      (string-append "KERI_HOME=" #$data-dir)
                      (string-append "KERIA_PASSCODE=" #$passcode)
                      "PYTHONUNBUFFERED=1"
                      "PYTHONDONTWRITEBYTECODE=1")))
      (stop #~(make-kill-destructor))
      (respawn? #t))

     ;; ── keri-witnesses ───────────────────────────────────────────────────
     ;;
     ;; Six witness nodes on ports 5642-5647 with REAL, persistently-stored
     ;; keys. The activation step (below) runs `kli init` once per witness
     ;; on first deploy, generating fresh salts that are written to the
     ;; data directory at 0600 and never re-rolled. Each witness runs as
     ;; its own Shepherd service so they can be restarted independently.
     ;;
     ;; Names follow the KERI convention (wan/wil/wes/wit/wub/wyz) and
     ;; map to ports 5642-5647 in order.
     )
     (map
        (lambda (entry)
          (let* ((name      (car entry))
                 ;; Configured port is the HTTP port; TCP listens 10 below
                 ;; (matches keripy's `kli witness demo` convention:
                 ;; HTTP 5642–5647 paired with TCP 5632–5637). kli witness
                 ;; start binds two sockets; passing the same number for
                 ;; -T and -H makes the second bind fail with EADDRINUSE
                 ;; and the process dies before the listener ever shows
                 ;; in ss/netstat. Surfaced only with --loglevel DEBUG.
                 (http-port (cdr entry))
                 (tcp-port  (- http-port 10)))
            (shepherd-service
             (documentation
              (string-append "KERI witness " name
                             " (tcp " (number->string tcp-port)
                             " / http " (number->string http-port) ")"))
             (provision (list (string->symbol
                               (string-append "keri-witness-" name))))
             (requirement '(networking))
             (start #~(make-forkexec-constructor
                       (list #$(file-append python-keri "/bin/kli")
                             "witness" "start"
                             "--name" #$name
                             "--alias" #$name
                             "-T" (number->string #$tcp-port)
                             "-H" (number->string #$http-port))
                       #:user #$user
                       #:directory #$data-dir
                       #:log-file (string-append "/var/log/playnet/keri-witness-"
                                                 #$name ".log")
                       #:environment-variables
                       (list (string-append "HOME=" #$data-dir)
                             "PYTHONUNBUFFERED=1"
                             (string-append "KERI_WITNESS_DIR="
                                            #$data-dir "/witnesses"))))
             (stop #~(make-kill-destructor))
             (respawn? #t))))
        (keria-configuration-witnesses config)))))

;;; ── Activation ──────────────────────────────────────────────────────────────
;; Creates the data directory and deploys the KERIA config from the repo.
;; Fully declarative — no manual SSH steps needed.

(define %keria-config-file
  (local-file "../keria-config.json"))

(define (keria-activation config)
  (let ((data-dir      (keria-configuration-data-dir config))
        (user          (keria-configuration-user config))
        (witness-names (map car (keria-configuration-witnesses config)))
        (kli-bin       (file-append python-keri "/bin/kli")))
    #~(begin
        (use-modules (guix build utils)
                     (ice-9 popen)
                     (ice-9 rdelim)
                     ((srfi srfi-1) #:select (filter-map)))
        (let* ((pw (getpwnam #$user))
               (uid (passwd:uid pw))
               (gid (passwd:gid pw))
               (config-dir (string-append #$data-dir "/config"))
               ;; keripy's Configer resolves --config-dir D --config-file F
               ;; to D/keri/cf/F.json — a file at D/F.json is silently
               ;; ignored and KERIA boots with no iurls.
               (config-cf   (string-append config-dir "/keri/cf"))
               (config-dest (string-append config-cf "/keria.json"))
               (witness-dir (string-append #$data-dir "/witnesses"))
               (witness-names '#$witness-names))
          ;; ONE privilege-dropping kli runner for everything in this
          ;; activation. Forks, setuids to the keystore owner (root's
          ;; kli refuses: "Keystore must already exist"), and keeps kli
          ;; off the activation's stdio (the inferior-stream trap —
          ;; chatty output corrupts the deploy protocol). With
          ;; CAPTURE-TO, stdout lands in that file (0600) and comes
          ;; back as a string; otherwise it joins stderr in /dev/null.
          (define* (run-kli! args #:optional capture-to)
            (let ((pid (primitive-fork)))
              (cond
               ((zero? pid)
                (setgid gid) (setuid uid)
                (setenv "HOME" #$data-dir)
                (let ((out (if capture-to
                               (open-fdes capture-to
                                          (logior O_WRONLY O_CREAT O_TRUNC)
                                          #o600)
                               (open-fdes "/dev/null" O_WRONLY)))
                      (devnull (open-fdes "/dev/null" O_WRONLY)))
                  (dup2 out 1)
                  (dup2 devnull 2)
                  (close-fdes out)
                  (close-fdes devnull))
                (apply execl #$kli-bin "kli" args))
               (else
                (waitpid pid)
                (and capture-to
                     (file-exists? capture-to)
                     (let ((txt (call-with-input-file capture-to
                                  (@ (ice-9 textual-ports) get-string-all))))
                       (delete-file capture-to)
                       txt))))))

          (mkdir-p #$data-dir)
          (mkdir-p config-cf)
          (mkdir-p witness-dir)
          (copy-file #$%keria-config-file config-dest)
          (for-each (lambda (d) (chown d uid gid))
                    (list #$data-dir config-dir config-cf config-dest
                          witness-dir))

          ;; Per-witness keystore — generated once, never re-rolled.
          ;; Salts persist at <data-dir>/witnesses/<name>/salt.txt (0600).
          ;; If a salt is missing, generate one via `kli salt` and run
          ;; `kli init`. On subsequent activations, both files exist and
          ;; we no-op. This keeps witness AIDs stable across deploys.
          (for-each
           (lambda (name)
             (let* ((wdir (string-append witness-dir "/" name))
                    (salt-file (string-append wdir "/salt.txt"))
                    (ks-marker (string-append #$data-dir "/ks/" name)))
               (mkdir-p wdir)
               (chown wdir uid gid)
               (unless (file-exists? salt-file)
                 (let* ((p (open-pipe* OPEN_READ #$kli-bin "salt"))
                        (salt (read-line p)))
                   (close-pipe p)
                   (call-with-output-file salt-file
                     (lambda (port) (display salt port)))
                   (chmod salt-file #o600)
                   (chown salt-file uid gid)))
               (unless (file-exists? ks-marker)
                 (let ((salt (call-with-input-file salt-file read-line)))
                   ;; kli init creates <data-dir>/ks/<name>/*.
                   (run-kli! (list "init"
                                   "--name" name
                                   "--nopasscode"
                                   "--salt" salt
                                   "--config-dir" #$data-dir))
                   ;; kli incept creates the witness's own AID inside
                   ;; the keystore with (alias = name). `kli witness
                   ;; start` REQUIRES --alias, so without this step the
                   ;; shepherd-service would never start.
                   ;; Non-transferable, single-sig, no witnesses-of-witness.
                   (run-kli! (list "incept"
                                   "--name" name
                                   "--alias" name
                                   "--icount" "1" "--isith" "1"
                                   "--ncount" "1" "--nsith" "1"
                                   "--toad" "0"))))))
           witness-names)

          ;; ── witness-aids manifest ──────────────────────────────────
          ;; "<name> <http-port> <aid>" per line at
          ;; <data-dir>/witness-aids. The gateway service reads it at
          ;; START to build PLAYNET_WITNESS_{AIDS,OOBIS} — witness AIDs
          ;; are box-specific (fresh salts at first deploy), so they
          ;; must never be baked into the repo.
          ;;
          ;; kli MUST run AS THE KEYSTORE OWNER (root's kli refuses:
          ;; "Keystore must already exist"), with stdout captured to a
          ;; file (never the activation's stdout — the inferior-stream
          ;; trap) and stderr dropped. And the manifest is only
          ;; REPLACED when the probe yields entries — a transient kli
          ;; failure must not clobber a good manifest into the
          ;; witnessless soft-degrade.
          (let ()
            (define (probe-witness name)
              (let ((txt (run-kli! (list "status" "--name" name "--alias" name)
                                   (string-append #$data-dir "/.kli-probe"))))
                (and txt
                     (let ((m ((@ (ice-9 regex) string-match)
                               "Identifier:[ \t]*([A-Za-z0-9_-]+)" txt)))
                       (and m ((@ (ice-9 regex) match:substring) m 1))))))
            (let* ((manifest (string-append #$data-dir "/witness-aids"))
                   (entries
                    (filter-map
                     (lambda (entry)
                       (let ((aid (probe-witness (car entry))))
                         (and aid (list (car entry) (cdr entry) aid))))
                     '#$(keria-configuration-witnesses config))))
              (when (pair? entries)
                (call-with-output-file manifest
                  (lambda (out)
                    (for-each
                     (lambda (e)
                       (format out "~a ~a ~a~%" (car e) (cadr e) (caddr e)))
                     entries)))
                (chown manifest uid gid))))))))

;;; ── Service type ─────────────────────────────────────────────────────────────

(define keria-service-type
  (service-type
   (name 'keria)
   (description
    "KERIA cloud agent + KERI witness pool. Provides KERI-based self-sovereign
identity for playnet users. Witnesses store KEL receipts so user identity
survives server replacement.")
   (extensions
    (list (service-extension shepherd-root-service-type
                             keria-shepherd-service)
          (service-extension activation-service-type
                             keria-activation)))
   (default-value (keria-configuration))))
