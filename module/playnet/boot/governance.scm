;;; module/playnet/boot/governance.scm — the governance service composed from its fragments.
;;;
;;; The composition root's word on what the governance service is: the actor
;;; (playnet doors governance) and the six fragments of
;;; docs/planning/codebase-layout.md §5, set once per process so every spawn
;;; composes the same service. Import this module wherever the service is
;;; spawned — the gateway, the test suites — and (playnet doors governance)
;;; where only the store readers or the context are read.

(define-module (playnet boot governance)
  #:use-module (playnet doors governance)
  #:use-module ((playnet doors personhood) #:select (governance-personhood-doors))
  #:use-module ((playnet doors delegation) #:select (governance-delegation-doors))
  #:use-module ((playnet doors voice) #:select (governance-voice-doors))
  #:use-module ((playnet doors contests) #:select (governance-contests-doors))
  #:use-module ((playnet doors economy) #:select (governance-economy-doors))
  #:use-module ((playnet doors federation) #:select (governance-federation-doors))
  #:re-export (fp-wire->cred ^governance-service spawn-governance-service
               governance-service-env plan-part-hands-of contrary-observations-of
               contrary-readings-of))

(set-governance-fragments!
 (list governance-personhood-doors governance-delegation-doors governance-voice-doors
       governance-contests-doors governance-economy-doors governance-federation-doors))
