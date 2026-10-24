;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/boot/signup.scm — the signup vat: the agent that witnesses a key log, and the terminal.

(define-module (localchimera boot signup)
  #:use-module ((localchimera boot site) #:select (data-path))
  #:use-module ((localchimera gateway terminal) #:select (^terminal-service))
  #:use-module ((localchimera identity seat) #:select (^signup-agent signup-agent-env))
  #:use-module ((goblins persistence-store syrup) #:select (make-syrup-store))
  #:use-module ((goblins utils hashmap) #:select (hashmap))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (spawn-signup! spawn-terminal!))

(define (spawn-signup! registry)
  "The signup agent in its persistent vat, under REGISTRY. (values signup-vat
signup-agent). Before fibers: a persistent vat needs no scheduler."
  (let ((signup-store (make-syrup-store (data-path "signup.syrup"))))
    (spawn-persistent-vat
     signup-agent-env
     (lambda () (spawn ^signup-agent (hashmap) (hashmap)))
     signup-store
     #:name "signup"
     #:persistence-registry registry)))

(define (spawn-terminal! gateway-vat signup-vat signup-agent)
  "The terminal service, in GATEWAY-VAT, over the signup agent."
  (with-vat gateway-vat
    (spawn ^terminal-service signup-vat signup-agent gateway-vat)))
