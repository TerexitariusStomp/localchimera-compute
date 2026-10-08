#!/usr/bin/env -S guile -L module
!#
;;; deploy/scripts/fleet-discover.scm — discover SporeStack catalog
;;;
;;; Queries SporeStack for available flavors, regions, and operating
;;; systems. Prints them in a table the operator can reference when
;;; editing desired-fleet.scm.
;;;
;;; Usage:
;;;   guile -L module deploy/scripts/fleet-discover.scm [--provider digitalocean]

(use-modules (playnet fleet sporestack)
             (ice-9 format)
             (ice-9 getopt-long))

(define option-spec
  '((provider (single-char #\p) (value #t))
    (token    (single-char #\t) (value #t))
    (help     (single-char #\h) (value #f))))

(define (main args)
  (let* ((options  (getopt-long args option-spec))
         (help?    (option-ref options 'help #f))
         (provider (option-ref options 'provider #f))
         (token    (or (option-ref options 'token #f)
                       (getenv "SPORESTACK_TOKEN")
                       "")))
    (when help?
      (format #t "Usage: fleet-discover.scm [--provider PROVIDER] [--token TOKEN]

Queries SporeStack for available flavors and operating systems.
TOKEN can also be set via SPORESTACK_TOKEN env var.
If no token is set, queries the public /slugs endpoints.
")
      (exit 0))

    (let ((creds (make-sporestack-creds sporestack-default-endpoint token)))

      ;; Flavors
      (format #t "~%=== Flavors~a ===~%~%"
              (if provider (format #f " (provider: ~a)" provider) ""))
      (format #t "~30a ~6a ~8a ~8a ~12a ~10a~%"
              "slug" "cores" "memory" "disk" "price/mo" "provider")
      (format #t "~80,,,'-a~%" "")

      (let ((flavors (sporestack-list-flavors creds #:provider provider)))
        (for-each
         (lambda (f)
           (format #t "~30a ~6a ~8a ~8a $~11,2f ~10a~%"
                   (assoc-ref f "slug")
                   (assoc-ref f "cores")
                   (assoc-ref f "memory")
                   (assoc-ref f "disk")
                   (/ (or (assoc-ref f "monthly_price") 0) 100.0)
                   (assoc-ref f "provider")))
         (if (vector? flavors) (vector->list flavors) flavors)))

      ;; Operating systems
      (format #t "~%=== Operating Systems~a ===~%~%"
              (if provider (format #f " (provider: ~a)" provider) ""))
      (format #t "~25a ~25a ~10a~%"
              "slug" "name" "provider")
      (format #t "~60,,,'-a~%" "")

      (let ((oses (sporestack-list-operating-systems creds #:provider provider)))
        (for-each
         (lambda (o)
           (format #t "~25a ~25a ~10a~%"
                   (assoc-ref o "slug")
                   (assoc-ref o "name")
                   (assoc-ref o "provider")))
         (if (vector? oses) (vector->list oses) oses)))

      (format #t "~%"))))

(main (command-line))
