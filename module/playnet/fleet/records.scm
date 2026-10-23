;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/fleet/records.scm — fleet record types (runtime + deploy)
;;;
;;; SRFI-9 record types with define* keyword constructors so that both
;;; runtime code (the reconciler, loading desired-fleet.scm via
;;; primitive-load) and deploy-time code (machines.scm, loading the
;;; same file) can share one module. `(guix records)` is intentionally
;;; not used — it's unavailable outside the Guix environment, and the
;;; keyword-argument syntax gives us comparable ergonomics.
;;;
;;; desired-fleet.scm and hosts.scm both import this module at their
;;; top via `(use-modules (playnet fleet records))` and build records
;;; with the keyword-style constructors `desired-host` (or the
;;; backward-compatible `sporestack-host`) and `materialized-host`.

(define-module (playnet fleet records)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (playnet utils files)
  #:export (;; Primary API
            desired-host
            desired-host?
            desired-host-name
            desired-host-flavor
            desired-host-operating-system
            desired-host-provider
            desired-host-region
            desired-host-days
            desired-host-autorenew?
            desired-host-billing-cycle
            desired-host-hostname
            desired-host-user-data
            desired-host-bootstrap-mode
            desired-host-role
            desired-host-estimated-monthly-usd
            desired-host-provider-params

            ;; Backward-compatible aliases (existing code, tests, fleet files)
            sporestack-host
            sporestack-host?
            sporestack-host-name
            sporestack-host-flavor
            sporestack-host-operating-system
            sporestack-host-provider
            sporestack-host-region
            sporestack-host-days
            sporestack-host-autorenew?
            sporestack-host-billing-cycle
            sporestack-host-hostname
            sporestack-host-user-data
            sporestack-host-bootstrap-mode
            sporestack-host-role
            sporestack-host-estimated-monthly-usd

            materialized-host
            materialized-host?
            materialized-host-name
            materialized-host-machine-id
            materialized-host-ipv4
            materialized-host-ipv6
            materialized-host-provider
            materialized-host-flavor
            materialized-host-created-at
            materialized-host-estimated-monthly-atomic
            materialized-host-ssh-host-key
            materialized-host-bootstrap-state
            materialized-host->sexp
            materialized-host-with-bootstrap-state
            load-fleet-file
            write-hosts-file!
            promote-host!

            desired-host-names
            find-materialized
            missing-hosts
            fleet->machines))

;;; ── <desired-host> ──────────────────────────────────────────────────────
;;;
;;; Formerly <sporestack-host>. The `provider` field now names the
;;; entry in the provider registry ("sporestack", "vpsbg", etc.)
;;; rather than the cloud backend. Provider-specific parameters go
;;; into `provider-params` (an alist).

(define-record-type <desired-host>
  (%make-desired-host name flavor operating-system provider region
                      days autorenew? billing-cycle hostname user-data
                      bootstrap-mode role estimated-monthly-usd
                      provider-params)
  desired-host?
  (name              desired-host-name)
  (flavor            desired-host-flavor)
  (operating-system  desired-host-operating-system)
  (provider          desired-host-provider)        ; "sporestack" | "vpsbg"
  (region            desired-host-region)
  (days              desired-host-days)
  (autorenew?        desired-host-autorenew?)
  (billing-cycle     desired-host-billing-cycle)
  (hostname          desired-host-hostname)
  (user-data         desired-host-user-data)
  (bootstrap-mode    desired-host-bootstrap-mode)
  (role              desired-host-role)
  (estimated-monthly-usd desired-host-estimated-monthly-usd)
  (provider-params   desired-host-provider-params)) ; alist

(define* (desired-host
          #:key
          name
          flavor
          (operating-system "debian-12")
          (provider "sporestack")
          (region #f)
          (days 30)
          (autorenew? #f)
          (billing-cycle "monthly")
          (hostname "")
          (user-data #f)
          (bootstrap-mode 'manual)
          (role 'generic)
          (estimated-monthly-usd 5)
          (provider-params '()))
  (unless name (error "desired-host: missing #:name"))
  (unless flavor (error "desired-host: missing #:flavor"))
  (%make-desired-host name flavor operating-system provider region
                      days autorenew? billing-cycle hostname user-data
                      bootstrap-mode role estimated-monthly-usd
                      provider-params))

;;; ── Backward-compatible constructor ─────────────────────────────────────
;;;
;;; `sporestack-host` preserves the old API where `#:provider` meant
;;; the cloud backend (e.g. "digitalocean"). It wraps `desired-host`
;;; with `#:provider "sporestack"` and stashes the backend in
;;; `provider-params`.

(define* (sporestack-host
          #:key
          name
          flavor
          (operating-system "debian-12")
          (provider "digitalocean")
          (region #f)
          (days 30)
          (autorenew? #f)
          (billing-cycle "monthly")
          (hostname "")
          (user-data #f)
          (bootstrap-mode 'manual)
          (role 'generic)
          (estimated-monthly-usd 5))
  (desired-host
   #:name name
   #:flavor flavor
   #:operating-system operating-system
   #:provider "sporestack"
   #:region region
   #:days days
   #:autorenew? autorenew?
   #:billing-cycle billing-cycle
   #:hostname hostname
   #:user-data user-data
   #:bootstrap-mode bootstrap-mode
   #:role role
   #:estimated-monthly-usd estimated-monthly-usd
   #:provider-params `(("backend" . ,provider))))

;; Predicate alias
(define sporestack-host? desired-host?)

;; Accessor aliases — all point to the same procedure
(define sporestack-host-name              desired-host-name)
(define sporestack-host-flavor            desired-host-flavor)
(define sporestack-host-operating-system  desired-host-operating-system)
(define sporestack-host-region            desired-host-region)
(define sporestack-host-days              desired-host-days)
(define sporestack-host-autorenew?        desired-host-autorenew?)
(define sporestack-host-billing-cycle     desired-host-billing-cycle)
(define sporestack-host-hostname          desired-host-hostname)
(define sporestack-host-user-data         desired-host-user-data)
(define sporestack-host-bootstrap-mode    desired-host-bootstrap-mode)
(define sporestack-host-role              desired-host-role)
(define sporestack-host-estimated-monthly-usd desired-host-estimated-monthly-usd)

;; sporestack-host-provider returns the BACKEND for backward compat
;; (the old code expected "digitalocean", not "sporestack").
;; For the actual provider name, use desired-host-provider.
(define (sporestack-host-provider host)
  (or (assoc-ref (desired-host-provider-params host) "backend")
      (desired-host-provider host)))

;;; ── <materialized-host> ──────────────────────────────────────────────────

(define-record-type <materialized-host>
  (%make-materialized-host name machine-id ipv4 ipv6 provider flavor
                           created-at estimated-monthly-atomic
                           ssh-host-key bootstrap-state)
  materialized-host?
  (name                     materialized-host-name)
  (machine-id               materialized-host-machine-id)
  (ipv4                     materialized-host-ipv4)
  (ipv6                     materialized-host-ipv6)
  (provider                 materialized-host-provider)
  (flavor                   materialized-host-flavor)
  (created-at               materialized-host-created-at)
  (estimated-monthly-atomic materialized-host-estimated-monthly-atomic)
  (ssh-host-key             materialized-host-ssh-host-key)
  (bootstrap-state          materialized-host-bootstrap-state))

(define* (materialized-host
          #:key
          name
          machine-id
          (ipv4 #f)
          (ipv6 #f)
          provider
          flavor
          created-at
          (estimated-monthly-atomic 0)
          (ssh-host-key #f)
          (bootstrap-state 'pending))
  (unless name (error "materialized-host: missing #:name"))
  (unless machine-id (error "materialized-host: missing #:machine-id"))
  (unless provider (error "materialized-host: missing #:provider"))
  (unless flavor (error "materialized-host: missing #:flavor"))
  (unless created-at (error "materialized-host: missing #:created-at"))
  (%make-materialized-host name machine-id ipv4 ipv6 provider flavor
                           created-at estimated-monthly-atomic
                           ssh-host-key bootstrap-state))

(define (materialized-host->sexp m)
  "Serialize M to the keyword-constructor form expected by hosts.scm."
  `(materialized-host
    #:name       ,(materialized-host-name m)
    #:machine-id ,(materialized-host-machine-id m)
    #:ipv4       ,(materialized-host-ipv4 m)
    #:ipv6       ,(materialized-host-ipv6 m)
    #:provider   ,(materialized-host-provider m)
    #:flavor     ,(materialized-host-flavor m)
    #:created-at ,(materialized-host-created-at m)
    #:estimated-monthly-atomic ,(materialized-host-estimated-monthly-atomic m)
    #:ssh-host-key ,(materialized-host-ssh-host-key m)
    #:bootstrap-state ',(materialized-host-bootstrap-state m)))

;;; ── The fleet files ───────────────────────────────────────────────────────
;;;
;;; desired-fleet.scm and hosts.scm are Scheme files that evaluate to a list
;;; of records. Everything that reads or writes them does it here.

(define (load-fleet-file path)
  "The list PATH evaluates to; '() when there is no such file."
  (if (file-exists? path)
      (let ((v (primitive-load path)))
        (if (list? v) v '()))
      '()))

(define (write-hosts-file! path materialized-list)
  (write-atomically!
   path
   (lambda (port)
     (display ";;; deploy/hosts.scm — written by the fleet. DO NOT EDIT BY HAND.\n" port)
     (display ";;; See deploy/hosts.scm.example for the format.\n\n" port)
     (display "(use-modules (playnet fleet records))\n\n(list\n" port)
     (for-each (lambda (m)
                 (display "  " port)
                 (write (materialized-host->sexp m) port)
                 (newline port))
               materialized-list)
     (display ")\n" port))))

(define (materialized-host-with-bootstrap-state m state)
  (materialized-host
   #:name (materialized-host-name m)
   #:machine-id (materialized-host-machine-id m)
   #:ipv4 (materialized-host-ipv4 m)
   #:ipv6 (materialized-host-ipv6 m)
   #:provider (materialized-host-provider m)
   #:flavor (materialized-host-flavor m)
   #:created-at (materialized-host-created-at m)
   #:estimated-monthly-atomic (materialized-host-estimated-monthly-atomic m)
   #:ssh-host-key (materialized-host-ssh-host-key m)
   #:bootstrap-state state))

(define (promote-host! path match?)
  "Mark the host MATCH? picks in PATH 'bootstrapped — the state `guix
deploy` reads. Answers the host as it now stands, or #f when none matches."
  (let* ((hosts (load-fleet-file path))
         (found (find match? hosts)))
    (cond
     ((not found) #f)
     ((eq? 'bootstrapped (materialized-host-bootstrap-state found)) found)
     (else
      (let ((promoted (materialized-host-with-bootstrap-state found 'bootstrapped)))
        (write-hosts-file! path (map (lambda (h) (if (eq? h found) promoted h))
                                     hosts))
        promoted)))))

;;; ── Helpers ─────────────────────────────────────────────────────────────

(define (desired-host-names desired)
  (map desired-host-name desired))

(define (find-materialized materialized name)
  (find (lambda (m) (equal? (materialized-host-name m) name))
        materialized))

(define (missing-hosts desired materialized)
  (filter (lambda (h)
            (not (find-materialized materialized (desired-host-name h))))
          desired))

(define (fleet->machines desired materialized)
  "Zip desired with materialized. Returns a list of
(logical-name . materialized-host) pairs for every host that has
been materialized. Callers in machines.scm build `(machine ...)`
entries from these pairs."
  (filter-map
   (lambda (h)
     (let* ((name (desired-host-name h))
            (mat (find-materialized materialized name)))
       (and mat (cons name mat))))
   desired))
