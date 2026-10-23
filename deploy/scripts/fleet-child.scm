;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/scripts/fleet-child.scm — what this box keeps for one fleet host
;;;
;;;   guile -L module deploy/scripts/fleet-child.scm init NAME
;;;   guile -L module deploy/scripts/fleet-child.scm state NAME [STATE]
;;;
;;; `init`  makes NAME's disk passphrase and initrd host key (once; a host
;;;         that has them keeps them) and prints the directory that holds
;;;         them: <data-dir>/fleet-children/NAME/.
;;; `state` prints where NAME's bootstrap stands, or sets it. A host whose
;;;         system a person installed by hand becomes the keeper's with
;;;         `state NAME installed`: from then on the keeper offers the
;;;         passphrase to its initrd and promotes it once its system answers.
;;;
;;; The data directory is PLAYNET_DATA_DIR (default /var/lib/playnet).

(use-modules (playnet fleet child)
             (ice-9 format)
             (ice-9 match))

(define %data-dir (or (getenv "PLAYNET_DATA_DIR") "/var/lib/playnet"))

(define %states '(installing installed unlocked bootstrapped install-failed))

(match (cdr (command-line))
  (("init" name)
   (display (ensure-child-secrets! %data-dir name))
   (newline))
  (("state" name)
   (format #t "~a~%" (or (child-state %data-dir name) "none")))
  (("state" name state)
   (let ((s (string->symbol state)))
     (unless (memq s %states)
       (format (current-error-port) "fleet-child: state is one of ~a~%" %states)
       (exit 2))
     (set-child-state! %data-dir name s)
     (format #t "~a: ~a~%" name s)))
  (_
   (format (current-error-port) "usage: fleet-child.scm init NAME | state NAME [STATE]~%")
   (exit 2)))
