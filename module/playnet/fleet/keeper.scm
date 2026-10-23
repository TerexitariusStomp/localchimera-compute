;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/fleet/keeper.scm — carrying a recorded host to a running one
;;;
;;; The reconciler's work ends when a host is paid for, launched and written
;;; to hosts.scm with bootstrap-state 'pending: a stock image with this
;;; box's provisioning key on it. The keeper takes it from there, one tick
;;; at a time, for every host whose desired entry says `#:bootstrap-mode
;;; 'auto`:
;;;
;;;   (no record)  → make the host's secrets, install the encrypted system
;;;                  (when an installer is present: the host waits until one is)
;;;   installing   → an install was under way when this process last stopped
;;;   installed    → offer the passphrase until the initrd takes it, then
;;;                  wait for the booted system to answer; promote the host
;;;                  in hosts.scm, which is what `guix deploy` reads
;;;   bootstrapped → each tick, offer the passphrase; a host that rebooted
;;;                  is waiting in its initrd and takes it
;;;   install-failed → left for a person: the install erases a disk, and
;;;                  the keeper runs it once per host
;;;
;;; The state is this box's own record ((playnet fleet child)), apart from
;;; hosts.scm, which the reconciler writes; the keeper touches hosts.scm
;;; once per host, to promote it.
;;;
;;; Everything that reaches outside — the install, the unlock, the
;;; promotion — is a procedure handed in, so the sequence is tested whole.

(define-module (playnet fleet keeper)
  #:use-module (playnet fleet child)
  #:use-module (playnet fleet records)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (keeper-tick!
            wants-auto-bootstrap?))

(define (wants-auto-bootstrap? desired name)
  (let ((host (find (lambda (h) (equal? (desired-host-name h) name)) desired)))
    (and host (eq? 'auto (desired-host-bootstrap-mode host)))))

(define* (keeper-tick! data-dir desired materialized
                       #:key
                       install!         ; (materialized-host child-dir) → #t | raises
                       unlock!          ; (name address) → verdict symbol
                       promote!         ; (materialized-host) → unspecified
                       (installer-ready? (lambda () #t)) ; can an install run at all?
                       (log! (lambda (fmt . args) #t)))
  "One pass over MATERIALIZED. Returns an alist (name . what-happened) for
the hosts it acted on."
  (define (step m)
    (let* ((name (materialized-host-name m))
           (address (materialized-host-ipv4 m))
           (state (child-state data-dir name)))
      (cond
       ((not (and address (wants-auto-bootstrap? desired name)))
        #f)

       ;; A host promoted by hand, or before the keeper existed, with no
       ;; secrets here: this box is not its key-holder.
       ((and (not state)
             (eq? 'bootstrapped (materialized-host-bootstrap-state m)))
        #f)

       ;; No installer on this box: the host waits, untouched, for one.
       ((and (not state) (not (installer-ready?)))
        #f)

       ((not state)
        (let ((dir (ensure-child-secrets! data-dir name)))
          (set-child-state! data-dir name 'installing)
          (log! "  [keeper] ~a: installing the encrypted system at ~a~%" name address)
          (catch #t
            (lambda ()
              (install! m dir)
              (set-child-state! data-dir name 'installed)
              (log! "  [keeper] ~a: installed; it reboots into its initrd~%" name)
              (cons name 'installed))
            (lambda (key . args)
              (set-child-state! data-dir name 'install-failed)
              (log! "  [keeper] ~a: install failed (~a ~s) — left for a person~%"
                    name key args)
              (cons name 'install-failed)))))

       ((eq? state 'installing)
        ;; The install outlives no restart of this process, and what it got
        ;; through is unknown: the disk may be half written.
        (set-child-state! data-dir name 'install-failed)
        (log! "  [keeper] ~a: an install was cut short — left for a person~%" name)
        (cons name 'install-failed))

       ((memq state '(installed unlocked bootstrapped))
        (let ((verdict (unlock! name address)))
          (case verdict
            ((unlocked)
             (log! "  [keeper] ~a: passphrase taken, the host goes on booting~%" name)
             (when (eq? state 'installed)
               (set-child-state! data-dir name 'unlocked))
             (cons name 'unlocked))
            ((not-waiting)
             ;; The booted system holds the address. For a host unlocked for
             ;; the first time, that is the end of its bootstrap.
             (cond
              ((eq? state 'unlocked)
               (promote! m)
               (set-child-state! data-dir name 'bootstrapped)
               (log! "  [keeper] ~a: its system is up — promoted in hosts.scm~%" name)
               (cons name 'bootstrapped))
              (else #f)))
            ((refused)
             (log! "  [keeper] ~a: the initrd turned the passphrase down~%" name)
             (cons name 'refused))
            (else #f))))

       (else #f))))
  (filter-map step materialized))
