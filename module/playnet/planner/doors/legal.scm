;;; legal.scm — the legal layer, through one door.
;;;
;;; Import this to read the law; each module below stays importable on its own.
;;;
;;;   vocabulary   legal/crossings.scm                 what an activity can trip
;;;                legal/registry.scm            demand, guard, rule, context;
;;;                                              `legal-demands` (the fold),
;;;                                              `bill-stance` (the one reading)
;;;                knowledge/places.scm          the one containment tree
;;;   the law      knowledge/context-pack.scm    a jurisdiction is a pack on disk;
;;;                docs/legal/contexts/*.sexp     `current-legal-rules` (the law in
;;;                                              force), `bill-at` (the bill of
;;;                                              crossings at a place)
;;;   readings     knowledge/incumbent-readings.scm   what is already won, by place
;;;                knowledge/protections.scm          the statutes that shield
;;;                knowledge/legal-aspects.scm        clause → aspect; practice
;;;                reform.scm                         (L, I, D) → regions → move
;;;   in the solve legal/gate.scm                the bill as planner inputs
;;;                legal/policy.scm              a scope's tolerance, governed
;;;   in the world knowledge/activities.scm      activities and their modes
;;;                knowledge/product-law.scm     the product's own acts
;;;
;;; The governance actor (`^legal-registry`, legal-registry-actor.scm), custody
;;; (compliance.scm) and the law face's builder (knowledge/law-snapshot-build.scm)
;;; stand on this and are imported where a vat, an observer or JSON is at hand.

(define-module (playnet planner doors legal)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner legal crossings)
  #:use-module (playnet planner legal registry)
  #:use-module (playnet planner legal policy)
  #:use-module (playnet planner legal reform)
  #:use-module (playnet planner facts places)
  #:use-module (playnet planner knowledge law context-pack)
  #:use-module (playnet planner knowledge law incumbent-readings)
  #:use-module (playnet planner knowledge law protections)
  #:use-module (playnet planner knowledge law aspects)
  #:use-module (playnet planner knowledge law activities)
  #:use-module (playnet planner knowledge law product)
  #:use-module (playnet planner legal compliance)
  #:use-module (playnet planner legal filings)
  #:use-module (playnet planner legal adapters)
  #:use-module (playnet planner legal bodies)
  ;; the registry shadows core's `rule` and `negate` on purpose; the door hands
  ;; that on, so an importer meets the legal ones without a warning
  #:re-export-and-replace (rule negate))

;; Re-export each interface whole, by name: the door adds no names and hides
;; none, and its own interface lists them, so a tool that asks what it publishes
;; (tools/sexp.scm `publishes`) reads the layer. `rule` and `negate` are
;; re-exported above, as replacements.
(for-each
 (lambda (name)
   (let ((names '()))
     (module-for-each (lambda (sym var) (set! names (cons sym names)))
                      (resolve-interface name))
     (module-re-export! (resolve-module '(playnet planner doors legal))
                        (lset-difference eq? names '(rule negate)))))
 '((playnet planner legal crossings)
   (playnet planner legal registry)
   (playnet planner legal policy)
   (playnet planner legal reform)
   (playnet planner facts places)
   (playnet planner knowledge law context-pack)
   (playnet planner knowledge law incumbent-readings)
   (playnet planner knowledge law protections)
   (playnet planner knowledge law aspects)
   (playnet planner knowledge law activities)
   (playnet planner knowledge law product)
   (playnet planner legal compliance)
   (playnet planner legal filings)
   (playnet planner legal adapters)
   (playnet planner legal bodies)))
