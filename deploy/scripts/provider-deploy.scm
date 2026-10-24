#!/usr/bin/env -S guile -L module
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; deploy/scripts/provider-deploy.scm
;;;
;;; One-shot CLI driver for a VPSBG deploy. Walks the four protocol ops
;;; (create-invoice → poll-payment → launch → poll-server) with
;;; human-readable progress and an explicit BTC payment step.
;;;
;;; Balance-first flow: looks up the plan cost, compares with current
;;; balance, and ONLY asks for BTC when there's a real deficit. If the
;;; account is already funded, the payment step is skipped entirely.
;;;
;;; Endpoints used, each cross-checked against its apidog schema page:
;;;   GET  /servers/plans       (api-3579655)
;;;   GET  /balance             (api-3487355)
;;;   POST /balance             (api-3661125)
;;;   GET  /ssh-keys            (api-3487362)
;;;   POST /ssh-keys            (api-3487363)
;;;   GET  /server-images       (api-4083717)
;;;   POST /isos                (api-3665880)
;;;   GET  /isos/{id}           (api-3665876)
;;;   POST /servers             (api-3487365)
;;;   GET  /servers/{id}        (api-3487367)
;;;
;;; Usage:
;;;   VPSBG_API_KEY="ID|KEY" guile -L module \
;;;     deploy/scripts/provider-deploy.scm \
;;;     --plan cloud-vps-2gb --name localchimera-1 \
;;;     --iso-url https://example.com/localchimera.iso
;;;
;;; See --help for the full option list.

(use-modules (localchimera fleet vpsbg)
             (localchimera fleet records)
             (ice-9 format)
             (ice-9 getopt-long)
             (ice-9 rdelim)              ; read-line
             (ice-9 textual-ports)
             (srfi srfi-1))

;;; ── CLI ──────────────────────────────────────────────────────────────────

(define option-spec
  '((plan          (single-char #\p) (value #t))
    (name          (single-char #\n) (value #t))
    (hostname                        (value #t))
    (billing-cycle (single-char #\b) (value #t))
    (iso-url                         (value #t))
    (image-id                        (value #t))
    (image-name                      (value #t))   ; e.g. "Debian 12"
    (custom-image-id                 (value #t))
    (ssh-key-id                      (value #t))   ; integer; repeatable via ","
    (ssh-key-pub                     (value #t))   ; path to public key file
    (amd-sev-level                   (value #t))   ; 0..3
    (poll-interval                   (value #t))   ; seconds, default 15
    (endpoint                        (value #t))
    (token                           (value #t))
    (yes                             (value #f))   ; skip the confirm prompt
    (help          (single-char #\h) (value #f))))

(define (usage)
  (format #t "Usage: provider-deploy.scm [OPTIONS]

Deploy one VPSBG server end-to-end: balance check, optional BTC deposit,
ISO upload + wait, POST /servers, poll until active. Prints the IP and
next-step commands on success.

Required:
  -p, --plan KEY            Plan key (e.g. cloud-vps-2gb). See
                            `guile -L module -c '(use-modules
                            (localchimera fleet vpsbg))
                            (for-each (lambda (p)
                              (format #t \"~~a~~%\" (assoc-ref p \"key\")))
                              (vpsbg-paginated-data
                                (vpsbg-list-plans
                                  (make-vpsbg-creds vpsbg-default-endpoint
                                                    (getenv \"VPSBG_API_KEY\")))))'
  -n, --name NAME           Logical hostname for the VM.

One of:
      --iso-url URL         HTTPS URL to a bootable ISO (must end in .iso,
                            ≤100 chars). The script uploads it, waits for
                            VPSBG to finish downloading, then attaches it
                            at server-creation time via primary_iso_id.
      --image-id N          Stock image id from /server-images.
      --image-name NAME     Resolves to image-id via /server-images.
                            E.g. \"Debian 12\".
      --custom-image-id N   Pre-uploaded custom image id.

Optional:
  -b, --billing-cycle N     Months (1–24). Default 1.
      --hostname HOST       Override the network hostname (defaults to
                            --name).
      --ssh-key-id N        Pre-existing key id to attach. Repeatable as
                            comma-separated list: --ssh-key-id 12,34.
      --ssh-key-pub FILE    Public-key file to upload (and use).
      --amd-sev-level N     0=off 1=SEV 2=SEV-ES 3=SEV-SNP. Default 0.
      --poll-interval N     Seconds between balance/server polls. Default 15.
      --endpoint URL        API base. Default ~a.
      --token TOKEN         API token \"ID|KEY\". Falls back to
                            VPSBG_API_KEY environment variable.
  -y, --yes                 Skip the pre-flight confirmation prompt.
  -h, --help                Show this help.

After the script returns successfully:
  1. ssh root@<IP> localchimera-install /dev/vda    # interactive disk install
  2. Capture the new host key with ssh-keyscan and paste it into
     deploy/providers/<host>.scm, alongside the IP.
  3. make deploy PROVIDER=deploy/providers/<host>.scm

Examples:
  # First-time setup, brand-new account with empty balance:
  VPSBG_API_KEY=\"123|abc...\" guile -L module \\
    deploy/scripts/provider-deploy.scm \\
    --plan cloud-vps-2gb --name localchimera-1 \\
    --ssh-key-pub ~~/.ssh/localchimera.pub \\
    --image-name \"Debian 12\" \\
    --amd-sev-level 3

  # Boot from a custom ISO (Path 2 in the private ops vault guide):
  VPSBG_API_KEY=\"123|abc...\" guile -L module \\
    deploy/scripts/provider-deploy.scm \\
    --plan cloud-vps-2gb --name localchimera-2 \\
    --iso-url https://localchimera.example/downloads/localchimera.iso \\
    --ssh-key-id 42
" vpsbg-default-endpoint)
  (exit 0))

;;; ── Helpers ──────────────────────────────────────────────────────────────

(define (die fmt . args)
  (apply format (current-error-port) (string-append "error: " fmt "~%") args)
  (exit 1))

(define (read-token-or-die opts)
  (or (option-ref opts 'token #f)
      (getenv "VPSBG_API_KEY")
      (die "no token: pass --token or set VPSBG_API_KEY")))

(define (parse-int-or-die name s)
  (or (and s (string->number s) (integer? (string->number s))
           (string->number s))
      (die "--~a expects an integer, got ~s" name s)))

(define (parse-int-in-range name s lo hi)
  (let ((n (parse-int-or-die name s)))
    (unless (and (>= n lo) (<= n hi))
      (die "--~a must be in [~a, ~a], got ~a" name lo hi n))
    n))

(define (parse-int-list s)
  "\"12,34,56\" → (12 34 56). Whitespace-tolerant."
  (filter-map
   (lambda (tok)
     (let ((trimmed (string-trim-both tok)))
       (and (not (string-null? trimmed))
            (string->number trimmed))))
   (string-split (or s "") #\,)))

(define (read-pubkey-file path)
  (call-with-input-file path
    (lambda (port) (string-trim-both (get-string-all port)))))

(define (resolve-image-id-by-name creds name)
  "Find a stock image id whose `name` contains the given string
case-insensitively. Returns integer id or #f.

Schema-checked: /server-images returns paginated `{data: [{id, name,
minimum_ram, eol, ssh_keys_support, amd_sev_supported, group, order}]}`
(api-4083717)."
  (let* ((resp (vpsbg-http-call creds #:method 'GET
                                #:path "/server-images"
                                #:query '((per_page . 50))))
         (images (vpsbg-paginated-data resp))
         (target (string-downcase name))
         (match? (lambda (img)
                   (let ((n (assoc-ref img "name")))
                     (and n (string-contains (string-downcase n) target))))))
    (let ((m (find match? images)))
      (and m (assoc-ref m "id")))))

(define (find-existing-ssh-key-id creds key-text)
  "Look up an already-registered SSH key by exact `key` match. Returns
the integer id or #f. Lets us avoid duplicate-registration 422s.

Schema-checked: /ssh-keys returns paginated `{data: [{id, name,
fingerprint, key, servers}]}` (api-3487362)."
  (let* ((resp (vpsbg-http-call creds #:method 'GET
                                #:path "/ssh-keys"
                                #:query '((per_page . 50))))
         (keys (vpsbg-paginated-data resp)))
    (let ((m (find (lambda (k) (equal? (assoc-ref k "key") key-text)) keys)))
      (and m (assoc-ref m "id")))))

(define (register-or-find-ssh-key creds pubkey-text key-name)
  "Idempotent SSH-key registration. Reuses an existing id if the key is
already on the account, else POSTs /ssh-keys."
  (or (find-existing-ssh-key-id creds pubkey-text)
      (let ((resp (vpsbg-add-ssh-key creds #:name key-name #:key pubkey-text)))
        (assoc-ref resp "id"))))

(define (fmt-eur n) (format #f "€~a" n))

;;; ── Main ─────────────────────────────────────────────────────────────────

(define (main args)
  (let* ((opts (getopt-long args option-spec)))
    (when (option-ref opts 'help #f) (usage))

    (let* ((plan      (or (option-ref opts 'plan #f)
                          (die "--plan is required")))
           (name      (or (option-ref opts 'name #f)
                          (die "--name is required")))
           (hostname  (option-ref opts 'hostname #f))
           (cycle-arg (option-ref opts 'billing-cycle #f))
           ;; API: billing_cycle ∈ [1, 24] integer.
           (cycle     (if cycle-arg
                          (parse-int-in-range "billing-cycle" cycle-arg 1 24)
                          1))
           (iso-url   (option-ref opts 'iso-url #f))
           (image-id-arg   (option-ref opts 'image-id #f))
           (image-name     (option-ref opts 'image-name #f))
           (custom-image-id-arg (option-ref opts 'custom-image-id #f))
           (ssh-key-id-arg (option-ref opts 'ssh-key-id #f))
           (ssh-key-pub    (option-ref opts 'ssh-key-pub #f))
           (sev-arg   (option-ref opts 'amd-sev-level #f))
           ;; API: amd_sev_level ∈ {0, 1, 2, 3}.
           (sev       (if sev-arg
                          (parse-int-in-range "amd-sev-level" sev-arg 0 3)
                          0))
           (poll-int  (if (option-ref opts 'poll-interval #f)
                          (parse-int-or-die "poll-interval"
                                            (option-ref opts 'poll-interval #f))
                          15))
           (endpoint  (or (option-ref opts 'endpoint #f) vpsbg-default-endpoint))
           (token     (read-token-or-die opts))
           (auto-yes? (option-ref opts 'yes #f)))

      ;; Validate boot source: exactly one source must be specified. The
      ;; API accepts at most one of primary_iso_id / image_id /
      ;; custom_server_image_id at create time; sending multiple makes
      ;; the boot path ambiguous.
      (let ((sources (filter (lambda (x) x)
                             (list (and iso-url 'iso-url)
                                   (and image-id-arg 'image-id)
                                   (and image-name 'image-name)
                                   (and custom-image-id-arg 'custom-image-id)))))
        (cond
         ((null? sources)
          (die "specify one of --iso-url, --image-id, --image-name, --custom-image-id"))
         ((> (length sources) 1)
          (die "exactly one boot source allowed; you passed: ~a" sources))))

      (let* ((creds (make-vpsbg-creds endpoint token))
             ;; ── Resolve image-id from --image-name if needed ──────────────
             (image-id
              (cond
               (image-id-arg (parse-int-or-die "image-id" image-id-arg))
               (image-name
                (or (resolve-image-id-by-name creds image-name)
                    (die "no /server-images entry matched ~s" image-name)))
               (else #f)))
             (custom-image-id
              (and custom-image-id-arg
                   (parse-int-or-die "custom-image-id" custom-image-id-arg)))
             ;; ── Collect SSH key IDs ────────────────────────────────────────
             (preset-key-ids (parse-int-list ssh-key-id-arg))
             (uploaded-key-id
              (and ssh-key-pub
                   (let ((pub (read-pubkey-file ssh-key-pub)))
                     (format #t "Registering SSH key from ~a…~%" ssh-key-pub)
                     (register-or-find-ssh-key creds pub
                                               (string-append name "-key")))))
             (ssh-key-ids (append preset-key-ids
                                  (if uploaded-key-id (list uploaded-key-id) '())))
             ;; ── Build provider-params + host record ───────────────────────
             (provider-params
              (append
               (if iso-url         `(("iso-url" . ,iso-url))          '())
               (if image-id        `(("image-id" . ,image-id))        '())
               (if custom-image-id `(("custom-image-id" . ,custom-image-id)) '())
               (if (pair? ssh-key-ids)
                   `(("ssh-key-ids" . ,ssh-key-ids)) '())
               `(("amd-sev-level" . ,sev))))
             (host (desired-host
                    #:name name
                    #:flavor plan
                    #:provider "vpsbg"
                    #:hostname (or hostname name)
                    #:billing-cycle cycle
                    #:provider-params provider-params))
             (provider (make-vpsbg-provider creds))
             (op (lambda (k) (cdr (assoc k provider)))))

        ;; ── Pre-flight summary ───────────────────────────────────────────
        (format #t "~%=== VPSBG deploy plan ===~%")
        (format #t "  endpoint:        ~a~%" endpoint)
        (format #t "  plan:            ~a (× ~a mo)~%" plan cycle)
        (format #t "  name / hostname: ~a / ~a~%" name (or hostname name))
        (cond (iso-url
               (format #t "  boot source:     ISO ~a~%" iso-url))
              (custom-image-id
               (format #t "  boot source:     custom image ~a~%" custom-image-id))
              (image-id
               (format #t "  boot source:     stock image ~a~a~%"
                       image-id
                       (if image-name (format #f " (\"~a\")" image-name) ""))))
        (format #t "  ssh key ids:     ~a~%"
                (if (pair? ssh-key-ids) ssh-key-ids "(none)"))
        (format #t "  AMD SEV level:   ~a~a~%" sev
                (case sev ((0) " (off)") ((1) " (SEV)")
                      ((2) " (SEV-ES)") ((3) " (SEV-SNP)") (else "")))
        (format #t "~%")

        (unless auto-yes?
          (display "Proceed? [y/N] ")
          (force-output)
          (let* ((reply (read-line))
                 (yes? (and (string? reply)
                            (member (string-downcase (string-trim-both reply))
                                    '("y" "yes")))))
            (unless yes?
              ;; EOF (non-interactive stdin) and any non-y answer both
              ;; abort. Pass --yes to skip this prompt entirely.
              (format #t "Aborted.~%")
              (exit 0))))

        ;; ── Phase 1: balance check, optional deposit ─────────────────────
        (format #t "~%Phase 1/3: balance check…~%")
        (call-with-values
            (lambda () ((op 'create-invoice) host))
          (lambda (inv-id uri currency amount)
            (cond
             ;; Already funded — skip straight to launch.
             ((or (not uri) (string-null? uri))
              (format #t "  → balance covers the plan; no deposit needed.~%"))
             (else
              (format #t "~%──────────────────────────────────────────~%")
              (format #t "  Pay this BTC URI (~a):~%~%    ~a~%~%"
                      (case currency ((btc) "BTC") (else currency)) uri)
              (format #t "  Amount: ~a sats~%" amount)
              (format #t "──────────────────────────────────────────~%~%")
              (format #t "Polling balance every ~as until the deposit confirms…~%"
                      poll-int)
              (let loop ((tick 0))
                (case ((op 'poll-payment) host
                       `(("invoice-id" . ,inv-id)))
                  ((funded)
                   (format #t "  → balance funded after ~a polls (~as).~%"
                           tick (* tick poll-int)))
                  (else
                   (when (zero? (modulo tick 4))
                     (format #t "  … still waiting (~a min)~%"
                             (inexact->exact (round (/ (* tick poll-int) 60)))))
                   (sleep poll-int)
                   (loop (+ tick 1)))))))))

        ;; ── Phase 2: launch (ISO upload + POST /servers) ─────────────────
        (format #t "~%Phase 2/3: launching server…~%")
        (let ((server-id
               ((op 'launch) host
                ;; No need to thread anything through entry; launch reads
                ;; from the host record + provider-params directly.
                '())))
          (format #t "  → server id ~a~%" server-id)

          ;; ── Phase 3: poll until status=active and an IP is published ──
          (format #t "~%Phase 3/3: polling /servers/~a until active…~%" server-id)
          (let loop ((tick 0) (last-ip ""))
            (call-with-values
                (lambda () ((op 'poll-server) server-id))
              (lambda (running? ip)
                (cond
                 ((and running? (string? ip) (not (string-null? ip)))
                  (format #t "  → active at ~a~%" ip)
                  (success-message server-id ip name))
                 (else
                  (when (and (not (equal? ip last-ip))
                             (string? ip) (not (string-null? ip)))
                    (format #t "  IP assigned: ~a (waiting for active)~%" ip))
                  (when (zero? (modulo tick 4))
                    (format #t "  … still provisioning (~a s)~%"
                            (* tick poll-int)))
                  (sleep poll-int)
                  (loop (+ tick 1) ip)))))))))))

(define (success-message server-id ip name)
  (format #t "~%=== Deploy succeeded ===~%~%")
  (format #t "Server id:  ~a~%" server-id)
  (format #t "IP:         ~a~%~%" ip)
  (format #t "Next steps:~%")
  (format #t "  1. ssh root@~a lsblk~%" ip)
  (format #t "     # Confirm the disk path (usually /dev/vda)~%~%")
  (format #t "  2. ssh root@~a localchimera-install /dev/vda~%" ip)
  ;; Use ~~ to emit a literal tilde; bare "~1" / "~10" would be parsed
  ;; as a column-width directive expecting an argument.
  (format #t "     # Wipes the disk and installs Guix System; ~~10 min~%~%")
  (format #t "  3. After the VM reboots off disk, capture the new host key:~%~%")
  (format #t "       ssh-keyscan -t ed25519 ~a~%~%" ip)
  (format #t "  4. cp deploy/providers/example.scm deploy/providers/~a.scm~%" name)
  (format #t "     $EDITOR deploy/providers/~a.scm  # fill in IP + host key~%~%" name)
  (format #t "  5. make deploy PROVIDER=deploy/providers/~a.scm \\~%" name)
  (format #t "                 DEPLOY_SSH_IDENTITY=~~/.ssh/localchimera~%~%"))

(main (command-line))
