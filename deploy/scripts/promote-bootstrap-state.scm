#!/usr/bin/env -S guile -L module
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; deploy/scripts/promote-bootstrap-state.scm
;;;
;;; Atomically flip a host in deploy/hosts.scm from bootstrap-state
;;; 'pending to 'bootstrapped. Identified by IPv4. Idempotent: re-running
;;; on an already-bootstrapped host is a no-op.
;;;
;;; On success, prints two lines to stdout that the bootstrap script
;;; greps for to populate /etc/localchimera/host-id and /etc/localchimera/provider-tag
;;; on the new VM:
;;;
;;;   host=<name>
;;;   provider=<provider>
;;;
;;; Usage:
;;;   guile -L module deploy/scripts/promote-bootstrap-state.scm <IPV4>
;;;
;;; Exit codes:
;;;   0  promotion succeeded (or host was already bootstrapped)
;;;   1  hosts.scm missing, no matching host, or write failed

(use-modules (localchimera fleet records)
             (ice-9 format)
             (srfi srfi-1))

(define (find-hosts-file)
  (let* ((script-dir (dirname (car (command-line))))
         (candidates (list (string-append script-dir "/../hosts.scm")
                           "deploy/hosts.scm"
                           "/home/localchimera/localchimera-repo/deploy/hosts.scm")))
    (find file-exists? candidates)))

(define (emit-tags! m)
  ;; Stdout — captured by bootstrap-debian.sh.
  (format #t "host=~a~%" (materialized-host-name m))
  (format #t "provider=~a~%" (materialized-host-provider m)))

(define (main args)
  (when (< (length args) 2)
    (format (current-error-port) "Usage: ~a <ipv4>~%" (car args))
    (exit 1))
  (let* ((target-ip (cadr args))
         (hosts-file (find-hosts-file)))
    (unless hosts-file
      (format (current-error-port) "hosts.scm not found~%")
      (exit 1))
    (let ((promoted (promote-host! hosts-file
                                   (lambda (h)
                                     (equal? (materialized-host-ipv4 h)
                                             target-ip)))))
      (cond
       ((not promoted)
        (format (current-error-port)
                "no host with ipv4=~a in ~a~%" target-ip hosts-file)
        (exit 1))
       (else
        (format (current-error-port) "~a is 'bootstrapped~%"
                (materialized-host-name promoted))
        (emit-tags! promoted)
        (exit 0))))))

(main (command-line))
