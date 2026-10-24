;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/peer/peer.scm — Shepherd config for the in-container peer.
;;;
;;; Loaded as PID 1's config (see init.sh: `exec shepherd --config`).
;;; Defines four services with crash-loop-aware policies:
;;;
;;;   tor             optional anonymising transport for radicle
;;;   radicle-node    `rad node` — gossip + storage layer
;;;   localchimera-gateway the actual application; runs from current/
;;;   self-update     watches refs, applies new generations
;;;
;;; The gateway has a rollback hook: if it dies more than 3× within
;;; 60 seconds, the symlink `current` is flipped back to `previous`
;;; and the service restarts on the prior generation. This is the
;;; fourth fence against a bad push (the first three live in
;;; updater.sh — delegate signature, preflight, atomic swap).

(use-modules ((localchimera utils clock) #:select (instant->unix (now . clock-now))))
(use-modules (shepherd service)
             (ice-9 popen)
             (ice-9 textual-ports))

(define peer-home
  (or (getenv "PEER_HOME") "/srv/localchimera"))

(define (peer-path . parts)
  (string-join (cons peer-home parts) "/"))

(define (read-symlink path)
  (false-if-exception (readlink path)))

(define (rollback-symlink!)
  "Flip current → previous if previous exists. Returns #t on success."
  (let ((cur (peer-path "current"))
        (prev (peer-path "previous")))
    (and (file-exists? prev)
         (let ((target (read-symlink prev)))
           (when target
             (system* "ln" "-sfn" target (string-append cur ".new"))
             (system* "mv" "-T" (string-append cur ".new") cur))
           #t))))

;; Crash-loop tracker: list of restart timestamps (seconds since epoch),
;; trimmed to the last 60s on each push.
(define gateway-restarts '())

(define (note-restart!)
  (let ((now (instant->unix (clock-now))))
    (set! gateway-restarts
          (cons now
                (filter (lambda (t) (< (- now t) 60))
                        gateway-restarts)))
    (length gateway-restarts)))

(define gateway-service
  (make <service>
    #:provides '(localchimera-gateway)
    #:requires '()
    #:respawn? #t
    ;; Start: run the wrapper from the live generation. The wrapper
    ;; carries its own GUILE_LOAD_PATH; we just chdir into current/
    ;; so any relative paths inside resolve correctly.
    #:start (make-forkexec-constructor
             (list (peer-path "current" "bin" "localchimera-gateway"))
             #:directory (peer-path "current")
             #:log-file (peer-path "gateway.log"))
    #:stop (make-kill-destructor)
    ;; Crash-loop policy: if the service has restarted ≥3× in 60s,
    ;; the most recent restart was probably triggered by a bad
    ;; update. Roll back the symlink and let the next respawn pick
    ;; up the previous generation.
    #:actions
    (list (shepherd-action
           (name 'after-restart)
           (documentation "Track restart frequency and roll back on crash-loop.")
           (procedure
            (lambda (running)
              (let ((n (note-restart!)))
                (when (>= n 3)
                  (format #t "[peer-shepherd] crash-loop detected (~a restarts/60s); rolling back~%" n)
                  (rollback-symlink!)
                  (set! gateway-restarts '())))))))))

(define self-update-service
  (make <service>
    #:provides '(self-update)
    #:requires '(radicle-node)
    #:respawn? #t
    #:start (make-forkexec-constructor
             (list "/share/localchimera/deploy/peer/updater.sh")
             #:log-file (peer-path "updater.log"))
    #:stop (make-kill-destructor)))

(define radicle-node-service
  (make <service>
    #:provides '(radicle-node)
    #:requires '()
    #:respawn? #t
    #:start (make-forkexec-constructor
             (list "rad" "node" "start" "--foreground")
             #:environment-variables
             (list (string-append "RAD_HOME=" peer-home "/.radicle")
                   (string-append "HOME=" peer-home))
             #:log-file (peer-path "radicle.log"))
    #:stop (make-forkexec-constructor (list "rad" "node" "stop"))))

(define tor-service
  ;; Optional. The container can be run with TOR_DISABLED=1 to skip
  ;; tor entirely (e.g. when only LAN gossip is needed).
  (make <service>
    #:provides '(tor)
    #:requires '()
    #:respawn? #t
    #:start (if (getenv "TOR_DISABLED")
                (lambda _ #f)  ; one-shot no-op
                (make-forkexec-constructor
                 (list "tor" "--RunAsDaemon" "0"
                       "--SocksPort" "9050"
                       "--DataDirectory" (peer-path "tor"))
                 #:log-file (peer-path "tor.log")))
    #:stop (make-kill-destructor)
    #:one-shot? (and (getenv "TOR_DISABLED") #t)))

(register-services tor-service
                   radicle-node-service
                   gateway-service
                   self-update-service)

(action 'shepherd 'daemonize)

(start tor-service)
(start radicle-node-service)
(start gateway-service)
(start self-update-service)
