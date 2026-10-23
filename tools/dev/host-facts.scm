;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tools/dev/host-facts.scm — read THIS host and print its placement ledger.
;;;
;;; The visibility half of distributed orchestration: what shepherd runs,
;;; what each service's process tree occupies, what the kernel says is
;;; free — printed as the same ledger sync-host-facts! registers as
;;; ^live-resource facts in a scope's live-registry.
;;;
;;; Usage:
;;;   guile --no-auto-compile -L module tools/dev/host-facts.scm            # ledger
;;;   guile --no-auto-compile -L module tools/dev/host-facts.scm --raw      # raw facts
;;;   guile --no-auto-compile -L module tools/dev/host-facts.scm --publish  # → MQTT
;;;
;;; --publish sends the raw facts sexp as a RETAINED message to
;;; playnet/facts/host/<hostname> (mosquitto user "host-facts", whose ACL
;;; grants exactly that subtree — see deploy/os.scm), so any subscriber —
;;; a scope syncing its live-registry via sync-host-facts!, a dashboard —
;;; reads the freshest snapshot the moment it connects. deploy/os.scm's
;;; mcron job runs this mode every five minutes on the box.
;;;
;;; Works anywhere: a host without shepherd reports its capacity with an
;;; empty service list (laptops), the box reports every running service.

(use-modules (playnet observation host-facts)
             (playnet mqtt publish)
             (ice-9 pretty-print))

(define raw? (member "--raw" (command-line)))
(define publish? (member "--publish" (command-line)))

(define facts (read-host-facts))

(cond
 (publish?
  (let* ((topic (string-append "playnet/facts/host/" (assq-ref facts 'host)))
         (rc (mqtt-publish!
              #:topic topic
              #:message (object->string facts)
              #:retain? #t
              #:username "host-facts"
              #:password-file (mqtt-password-file "host-facts"))))
    (format #t "[host-facts] published retained snapshot to ~a (exit ~a)~%"
            topic rc)
    (exit rc)))
 (raw? (pretty-print facts))
 (else
  (format #t ";; host ~a — ~a cores, ~,2f GB (load ~a; ~a services running)~%"
          (assq-ref facts 'host)
          (assq-ref facts 'cores)
          (or (assq-ref facts 'mem-total-gb) 0)
          (assq-ref facts 'load-1m)
          (length (assq-ref facts 'services)))
  (pretty-print (placement-ledger facts))))
