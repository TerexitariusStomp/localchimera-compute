;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/boot/mailbox.scm — the mailbox vat: the manager of every person's mailbox, persistent.

(define-module (playnet boot mailbox)
  #:use-module ((playnet boot site) #:select (data-path))
  #:use-module ((playnet gateway mailbox) #:select (^mailbox-manager mailbox-env))
  #:use-module ((goblins persistence-store syrup) #:select (make-syrup-store))
  #:use-module ((goblins utils hashmap) #:select (hashmap))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (spawn-mailbox!))

(define (spawn-mailbox! registry)
  "The mailbox manager in its persistent vat, under REGISTRY."
  (call-with-values
      (lambda ()
        (spawn-persistent-vat
         mailbox-env
         (lambda () (spawn ^mailbox-manager (hashmap)))
         (make-syrup-store (data-path "mailbox.syrup"))
         #:name "mailbox"
         #:persistence-registry registry))
    (lambda (vat manager) manager)))
