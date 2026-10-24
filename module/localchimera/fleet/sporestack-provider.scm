;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/fleet/sporestack-provider.scm — SporeStack provider adapter
;;;
;;; Wraps the existing sporestack.scm API client into the provider
;;; protocol (see provider.scm). The raw sporestack.scm module is
;;; unchanged — this adapter translates between the generic 6-operation
;;; interface and SporeStack's specific API surface.

(define-module (localchimera fleet sporestack-provider)
  #:use-module (srfi srfi-1)
  #:use-module (localchimera fleet sporestack)
  #:use-module (localchimera fleet records)
  #:use-module (localchimera monero wallet)
  #:export (make-sporestack-provider))

(define (make-sporestack-provider creds)
  "Build a provider alist from SporeStack credentials. The returned
alist implements the 6-operation provider protocol."

  `((create-invoice
     . ,(lambda (host)
          (let* ((dollars (desired-host-estimated-monthly-usd host))
                 (invoice (sporestack-add-funds creds
                            #:currency "xmr" #:dollars dollars))
                 (inv-id  (invoice-id invoice))
                 (uri-str (invoice-payment-uri invoice))
                 (parsed  (parse-monero-uri uri-str))
                 (amount  (xmr->atomic (or (and parsed (monero-uri-amount-xmr parsed))
                                           0))))
            (values inv-id uri-str 'xmr amount))))

    (poll-payment
     . ,(lambda (host entry)
          (let* ((info (sporestack-info creds))
                 (balance (assoc-ref info "balance_cents")))
            (if (and (number? balance) (> balance 0))
                'funded
                'pending))))

    (launch
     . ,(lambda (host entry)
          (let* ((params  (desired-host-provider-params host))
                 (backend (or (assoc-ref params "backend") "digitalocean"))
                 (resp (sporestack-launch-server
                        creds
                        #:flavor           (desired-host-flavor host)
                        #:ssh-key          (assoc-ref entry "ssh-key-pub")
                        #:operating-system (desired-host-operating-system host)
                        #:provider         backend
                        #:region           (desired-host-region host)
                        #:hostname         (let ((h (desired-host-hostname host)))
                                             (if (string-null? h)
                                                 (desired-host-name host)
                                                 h))
                        #:days             (desired-host-days host)
                        #:autorenew        (desired-host-autorenew? host)
                        #:billing-cycle    (desired-host-billing-cycle host)
                        #:user-data        (desired-host-user-data host))))
            (assoc-ref resp "machine_id"))))

    (poll-server
     . ,(lambda (machine-id)
          (let ((srv (sporestack-get-server creds machine-id)))
            (values (server-running? srv)
                    (server-ipv4 srv)))))

    (delete-server
     . ,(lambda (machine-id)
          (sporestack-delete-server creds machine-id)))

    (list-servers
     . ,(lambda ()
          (let* ((resp (sporestack-list-servers creds
                         #:include-deleted #f
                         #:include-forgotten #f))
                 (servers (let ((s (assoc-ref resp "servers")))
                            (if (vector? s) (vector->list s) (or s '())))))
            servers)))))
