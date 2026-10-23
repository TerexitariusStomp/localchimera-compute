;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keri/keria-reconnect.scm — Server recovery: reconnect KERIA
;;;
;;; After a server restart or KERIA reconnect, this module verifies
;;; witnesses, reloads the governance AID, and syncs credentials/contacts.
;;; The only secret needed is the 21-char CESR bran passcode.
;;;
;;; The witness pool holds all KEL history — no server-local state needed
;;; for identity recovery. Just the bran.

(define-module (playnet keri keria-reconnect)
  #:use-module (playnet keri bridge)
  #:use-module (playnet keri credentials)
  #:use-module (playnet keri inception)
  #:use-module ((playnet utils common) #:select (for-each-catching))
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (ice-9 format)
  #:export (recovery-reconnect!
            recovery-sync!
            recovery-check-witnesses
            recovery-check-governance
            recovery-full!
            recovery-status
            register-reconnect-hook!
            run-reconnect-hooks!))

;;; ── Reconnect hooks ─────────────────────────────────────────────────────────
;;;
;;; Observer list fired after a successful (re)connect. The gateway
;;; registers a drain-pending-grants hook here so a transient KERIA
;;; outage is followed by an immediate retry pass — without it, the
;;; periodic 60s drain fiber would still get to it eventually, but
;;; recipients see the latency.

(define *reconnect-hooks* '())

(define (register-reconnect-hook! thunk)
  "Add THUNK to the post-reconnect hook list. Idempotent on identity."
  (unless (memq thunk *reconnect-hooks*)
    (set! *reconnect-hooks* (cons thunk *reconnect-hooks*))))

(define (run-reconnect-hooks!)
  "Fire every registered hook. Each hook runs under a per-hook catch
   so one bad hook doesn't stop the others."
  (for-each-catching "recovery reconnect-hook"
                     (lambda (h) (h))
                     *reconnect-hooks*))

;;; ── Reconnect ───────────────────────────────────────────────────────────────

(define* (recovery-reconnect! bran #:key
                              (agent-url "http://127.0.0.1:3901")
                              (boot-url  "http://127.0.0.1:3903"))
  "Reconnect to KERIA after a restart. Sets bran + URLs, connects,
   then fires post-reconnect hooks (drain pending grants, etc.)."
  (keri-set-urls! agent-url boot-url)
  (keri-connect! bran)
  (format (current-error-port) "[recovery] reconnected to KERIA\n")
  (run-reconnect-hooks!))

;;; ── Sync from KERIA ─────────────────────────────────────────────────────────

(define-syntax-rule (or-empty body ...)
  ;; Run BODY, returning '() if it raises. Used below to give each
  ;; KERIA call a uniform "no data" fallback so the count summary still
  ;; renders when one endpoint is offline.
  (catch #t (lambda () body ...) (lambda _ '())))

(define (recovery-sync!)
  "Sync identifiers and credentials from KERIA after reconnect.
   Returns alist with counts."
  (format (current-error-port) "[recovery] syncing from KERIA...\n")
  (let* ((aids     (or-empty (keri-as-list (keri-list-aids))))
         (creds    (or-empty (acdc-sync-credentials)))
         (contacts (or-empty (keri-as-list (keri-list-contacts)))))
    (format (current-error-port)
            "[recovery] synced: ~a AIDs, ~a credentials, ~a contacts\n"
            (length aids) (length creds) (length contacts))
    `((aids        . ,(length aids))
      (credentials . ,(length creds))
      (contacts    . ,(length contacts)))))

;;; ── Witness health check ─────────────────────────────────────────────────────

(define (recovery-check-witnesses)
  "Check connectivity to all configured witnesses.
   Returns alist with 'total, 'reachable, 'unreachable counts."
  (let* ((witnesses (keri-default-witnesses))
         (results
          (map (lambda (oobi)
                 (catch #t
                   (lambda ()
                     (keri-resolve-oobi oobi)
                     (cons oobi 'reachable))
                   (lambda _ (cons oobi 'unreachable))))
               witnesses)))
    (let-values (((up down)
                  (partition (lambda (r) (eq? (cdr r) 'reachable)) results)))
      `((total       . ,(length witnesses))
        (reachable   . ,(length up))
        (unreachable . ,(length down))
        (details     . ,results)))))

;;; ── Governance check ─────────────────────────────────────────────────────────

(define (recovery-check-governance)
  "Check that this gateway's own controller AID is accessible and its
   credential registry works. Returns alist with status info."
  (catch #t
    (lambda ()
      (let* ((aid-name (gateway-controller-aid-name))
             (state    (keri-get-aid aid-name))
             (prefix   (assoc-ref state "prefix")))
        `((ok         . #t)
          (aid-name   . ,aid-name)
          (prefix     . ,prefix)
          (registry   . ,(acdc-registry-id)))))
    (lambda (key . args)
      `((ok . #f) (error . ,(format #f "~a: ~a" key args))))))

;;; ── Status report ────────────────────────────────────────────────────────────

(define (recovery-status)
  "Full status report: KERIA connection, witnesses, governance."
  `((witnesses  . ,(recovery-check-witnesses))
    (governance . ,(recovery-check-governance))))

;;; ── Full recovery ────────────────────────────────────────────────────────────

(define* (recovery-full! bran #:key
                         (agent-url "http://127.0.0.1:3901")
                         (boot-url  "http://127.0.0.1:3903"))
  "Complete recovery sequence: reconnect + init controller AID + sync.
   Returns recovery status alist."
  (recovery-reconnect! bran #:agent-url agent-url #:boot-url boot-url)
  (gateway-controller-init!)
  (recovery-sync!)
  (recovery-status))
