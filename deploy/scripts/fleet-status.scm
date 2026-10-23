#!/usr/bin/env -S guile -L module
;;; SPDX-License-Identifier: AGPL-3.0-or-later
!#
;;; deploy/scripts/fleet-status.scm — fleet status dashboard
;;;
;;; Reads desired-fleet.scm and hosts.scm (if they exist) and prints
;;; a summary of the fleet state: desired hosts, materialized hosts,
;;; missing hosts, bootstrap status.
;;;
;;; Does NOT need a running gateway — reads files directly.
;;;
;;; Usage:
;;;   guile -L module deploy/scripts/fleet-status.scm

(use-modules (playnet fleet records)
             (ice-9 format)
             (srfi srfi-1))

(define DEPLOY_DIR
  (or (getenv "PLAYNET_DEPLOY_DIR")
      (let ((script-dir (dirname (current-filename))))
        (string-append (dirname script-dir)))))

(define (load-if-exists path)
  (if (file-exists? path)
      (primitive-load path)
      '()))

(define (main)
  (let* ((desired-path (string-append DEPLOY_DIR "/desired-fleet.scm"))
         (hosts-path   (string-append DEPLOY_DIR "/hosts.scm"))
         (desired (load-if-exists desired-path))
         (hosts   (load-if-exists hosts-path)))

    (format #t "~%=== Fleet Status ===~%")
    (format #t "  desired-fleet.scm: ~a (~a hosts)~%"
            (if (file-exists? desired-path) "found" "MISSING")
            (length desired))
    (format #t "  hosts.scm:         ~a (~a hosts)~%"
            (if (file-exists? hosts-path) "found" "not yet created")
            (length hosts))

    ;; Desired hosts
    (when (pair? desired)
      (format #t "~%=== Desired Hosts ===~%~%")
      (format #t "~25a ~20a ~15a ~10a ~8a~%"
              "name" "flavor" "provider" "region" "$/mo")
      (format #t "~78,,,'-a~%" "")
      (for-each
       (lambda (h)
         (format #t "~25a ~20a ~15a ~10a $~7,2f~%"
                 (sporestack-host-name h)
                 (sporestack-host-flavor h)
                 (sporestack-host-provider h)
                 (or (sporestack-host-region h) "auto")
                 (sporestack-host-estimated-monthly-usd h)))
       desired))

    ;; Materialized hosts
    (when (pair? hosts)
      (format #t "~%=== Materialized Hosts ===~%~%")
      (format #t "~25a ~16a ~20a ~15a~%"
              "name" "ipv4" "machine-id" "bootstrap")
      (format #t "~76,,,'-a~%" "")
      (for-each
       (lambda (m)
         (format #t "~25a ~16a ~20a ~15a~%"
                 (materialized-host-name m)
                 (or (materialized-host-ipv4 m) "—")
                 (let ((mid (materialized-host-machine-id m)))
                   (if (> (string-length mid) 18)
                       (string-append (substring mid 0 18) "…")
                       mid))
                 (materialized-host-bootstrap-state m)))
       hosts))

    ;; Missing hosts
    (let ((missing (missing-hosts desired hosts)))
      (when (pair? missing)
        (format #t "~%=== Missing (not yet provisioned) ===~%~%")
        (for-each
         (lambda (h)
           (format #t "  ~a (~a on ~a)~%"
                   (sporestack-host-name h)
                   (sporestack-host-flavor h)
                   (sporestack-host-provider h)))
         missing)))

    ;; Pending bootstrap
    (let ((pending (filter (lambda (m)
                             (eq? (materialized-host-bootstrap-state m) 'pending))
                           hosts)))
      (when (pair? pending)
        (format #t "~%=== Pending Bootstrap (run bootstrap-debian.sh) ===~%~%")
        (for-each
         (lambda (m)
           (format #t "  ~a → ~a~%"
                   (materialized-host-name m)
                   (materialized-host-ipv4 m)))
         pending)))

    (format #t "~%")))

(main)
