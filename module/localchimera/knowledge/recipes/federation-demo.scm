;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; federation-demo.scm — seed a demo commune for the cross-vat federation and
;;; the earth-map desire overlay in one shot: a bake recipe (flour+work→bread),
;;; a baker, a NESTED spatial tree (federation ⊃ commune ⊃ venue at real coords —
;;; the exact tree containers.js draws), and inventory. Seed TWO of these (one
;;; flour-rich, one flour-poor with a bread demand) and compose them via
;;; service.scm `federated-plan`: the flour-poor commune's deficit is filled by
;;; the flour-rich one's surplus, priced across the boundary, and its venue on
;;; the map drains from red to green.
;;;
;;; fed-world is the commune as data; seed-fed-commune! writes it into a
;;; scope's stores. Every `$` here is a near-call — call within the scope's vat.

(define-module (localchimera knowledge recipes federation-demo)
  #:use-module ((localchimera utils units) #:select (%count-unit %effort-unit))
  #:use-module (localchimera vf schemas)
  #:use-module (localchimera knowledge dsl shorthand)
  #:use-module (localchimera knowledge dsl world)
  #:use-module (goblins)
  #:export (fed-er fed-world seed-fed-commune!))

;; a worker's day, as the availability the solve's banding reads: hours a
;; PERSON keeps, so no band of the plan lands in the middle of the night
(define (fed-er id spec onhand loc acct)
  (er id spec acct #:place loc #:qty onhand #:unit "kg"))

(define* (fed-world fed-id commune-id commune-name venue lat lon flour-qty
                    #:key (commune-aid #f))
  "One commune of the federation, as data. flour-qty > 0 ⇒ a granary (it will
   EXPORT flour); 0 ⇒ a consumer (it IMPORTS flour and bakes). COMMUNE-AID, when
   given, is the accountable the flour seeds under — the commune's REAL
   scope-aid, which is what the socialized tenure view (commune-resource-view)
   checks primary-accountable against. Absent (the plain unit tests), the stock
   seeds unattributed: the pre-tenure world, which every view admits."
  (let ((baker (string-append "w-" venue)))
    (world
     ;; the work flow names its skill — the planner key willingness is offered
     ;; over, and the shape every candidate/eligible read keys on
     #:specs (list (spec* "bread" "Bread" "kg") (spec* "flour" "Flour" "kg") (spec* "baking" "Baking" %effort-unit))
     #:procs (list (rp* "bake" "Bake bread" 0.1))
     #:flows (list (make-recipe-flow #:id "bf-o" #:action 'produce #:resource-conforms-to "bread"
                                     #:resource-quantity (make-measure 1.0 "kg")
                                     #:recipe-output-of "bake")
                   (consume* "bf-i" "flour" 1.0 "bake")
                   (wk* "bf-w" "baking" 0.1 "bake"))
     #:recipes (list (make-recipe #:id "r-bake" #:name "Bake bread" #:primary-output "bread"
                                  #:recipe-processes (list "bake")))
     ;; the nested containment tree (id name note lat long alt mappable contained-in)
     #:spatials (list (make-spatial-thing #:id fed-id #:name "Federation")
                      (make-spatial-thing #:id commune-id #:name commune-name #:lat lat #:long lon
                                          #:contained-in fed-id)
                      (make-spatial-thing #:id venue #:name (string-append commune-name " venue")
                                          #:lat lat #:long lon #:contained-in commune-id))
     ;; the Baker keeps a baker's hours — the banding follows real windows
     #:agents (list (make-agent #:id baker #:type 'person #:name "Baker" #:primary-location venue
                                #:classified-as '()
                                #:availability-window (all-week-window "05:00" "13:00")))
     ;; the Baker HOLDS the skill — the same resource shape declare-skill
     ;; writes, which is what skill-holders and the candidate field read;
     ;; an agent without it is skill-absent to every solve, and the seeded
     ;; commune bakes nothing no matter the flour
     #:resources (cons (make-economic-resource #:id (string-append "skill:" baker ":baking")
                                               #:name (string-append baker " baking") #:conforms-to "baking"
                                               #:accounting-quantity (make-measure 1 %count-unit) #:onhand-quantity (make-measure 1 %count-unit) #:primary-accountable baker)
                       (if (> flour-qty 0)
                           (list (fed-er (string-append "flour-" venue) "flour" flour-qty venue commune-aid))
                           '())))))

;; Seed one commune's real stores. Returns the venue id (build the bread demand
;; as (cons (string-append "bread#" venue "@0") qty)).
(define* (seed-fed-commune! scope fed-id commune-id commune-name venue lat lon flour-qty
                            #:key (commune-aid #f))
  (seed-world! scope (fed-world fed-id commune-id commune-name venue lat lon flour-qty
                                #:commune-aid commune-aid))
  venue)
