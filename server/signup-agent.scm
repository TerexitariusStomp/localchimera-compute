;;; server/signup-agent.scm — ^signup-agent Goblins actor
;;;
;;; Handles account registration requests arriving over the relay.
;;; Each request carries: username, email, and the applicant's xorg
;;; public key (which becomes their SSH credential on the Guix machine).
;;;
;;; Usage (from relay.scm via primitive-load):
;;;
;;;   (define *signup-vat*   (spawn-vat #:name "signup"))
;;;   (define *signup-agent* (with-vat *signup-vat* (spawn ^signup-agent (hashmap))))
;;;
;;; Messages (processed synchronously inside the relay's signup handler):
;;;
;;;   ($ *signup-agent* 'register! username email ssh-pubkey)
;;;     → 'ok  |  (list 'error "reason string")
;;;
;;;   ($ *signup-agent* 'members)
;;;     → list of (username email registered-at) triples
;;;
;;;   ($ *signup-agent* 'member? username)
;;;     → #t | #f

(use-modules (goblins)
             (goblins actor-lib methods)
             (goblins utils hashmap)
             (ice-9 format)
             (ice-9 popen)
             (ice-9 regex))

;;; ── Path helpers ────────────────────────────────────────────────────────────

(define %provision-script
  ;; Resolved relative to the project root (run server from there).
  "deploy/guix/provision-user.scm")

;;; ── Validation ──────────────────────────────────────────────────────────────

(define (valid-username? s)
  (and (string? s)
       (not (string-null? s))
       (string-match "^[a-z][a-z0-9-]{0,30}$" s)
       #t))

(define (valid-ssh-key? s)
  (and (string? s)
       (string-match "^ssh-(ed25519|rsa|ecdsa-sha2-nistp(256|384|521)) " s)
       #t))

(define (valid-email? s)
  (and (string? s)
       (string-match "^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+" s)
       #t))

;;; ── Provision call ──────────────────────────────────────────────────────────

(define (provision! username email ssh-pubkey)
  "Call provision-user.scm. Returns #t on success, error string on failure."
  (let* ((status (system*
                  "guile" "--no-auto-compile" "-s" %provision-script
                  "--user"  username
                  "--key"   ssh-pubkey
                  "--email" email))
         (ok?   (= status 0)))
    (if ok? #t
        (string-append "provision-user.scm exited with status "
                       (number->string status)))))

;;; ── Record helpers ──────────────────────────────────────────────────────────

(define (make-member username email key registered-at)
  (list username email key registered-at))

(define (member-username m) (list-ref m 0))
(define (member-email    m) (list-ref m 1))
(define (member-key      m) (list-ref m 2))
(define (member-registered-at m) (list-ref m 3))

;;; ── ^signup-agent ───────────────────────────────────────────────────────────

(define-actor (^signup-agent bcom members)
  ;; members: hashmap of username → (username email ssh-key registered-at)

  #:portrait
  (lambda ()
    ;; Serialize to a plain list of lists for Goblins persistence
    (list (hashmap-fold (lambda (k v acc) (cons v acc)) '() members)))

  #:version 1

  #:restore
  (lambda (version serialized-members)
    (case version
      ((1)
       (let ((hm (fold (lambda (m hm)
                         (hashmap-set hm (member-username m) m))
                       (hashmap)
                       serialized-members)))
         (spawn ^signup-agent hm)))
      (else (error "Unknown ^signup-agent version" version))))

  (methods

    ;; ── register! ────────────────────────────────────────────────────────────
    ;; Validate inputs, provision the Linux account, persist the member.
    ;; Returns 'ok or (list 'error "reason").
    ((register! username email ssh-pubkey)
     (cond
       ((not (valid-username? username))
        (list 'error (string-append "invalid username: " username
                                    " (must match [a-z][a-z0-9-]{0,31})")))
       ((not (valid-ssh-key? ssh-pubkey))
        (list 'error "invalid SSH public key (must start with ssh-ed25519/rsa/ecdsa)"))
       ((not (valid-email? email))
        (list 'error (string-append "invalid email: " email)))
       ((hashmap-ref members username #f)
        (list 'error (string-append "username already registered: " username)))
       (else
        ;; Try to provision
        (let ((result (provision! username email ssh-pubkey)))
          (if (eq? result #t)
              ;; Success — persist the new member
              (let* ((now  (number->string (current-time)))
                     (mem  (make-member username email ssh-pubkey now))
                     (new  (hashmap-set members username mem)))
                (bcom (^signup-agent bcom new))
                (format (current-error-port)
                        "[signup-agent] registered ~a (~a)\n" username email)
                'ok)
              ;; Provision failed
              (list 'error result))))))

    ;; ── members ──────────────────────────────────────────────────────────────
    ;; Returns list of (username email registered-at) — omits keys for privacy.
    ((members)
     (hashmap-fold
      (lambda (k v acc)
        (cons (list (member-username v)
                    (member-email v)
                    (member-registered-at v))
              acc))
      '() members))

    ;; ── member? 
    ((member? username)
     (and (hashmap-ref members username #f) #t))

    ;; ── get-member ───────────────────────────────────────────────────────────
    ((get-member username)
     (hashmap-ref members username #f))

    ;; ── member-count ─────────────────────────────────────────────────────────
    ((member-count)
     (hashmap-size members))))

;;; ── Persistence environment ───────────────────────────────────────────────────────────────────────────────────────────────────────────────

(define signup-agent-env
  (make-persistence-env
    `((((sapient-os signup) ^signup-agent) ,^signup-agent))))
