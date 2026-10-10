;;; handover.scm — a recipe states what it hands over, and what comes back.
;;;
;;; A recipe's process makes a good; who the good then goes to, and for what, is
;;; an EXCHANGE (ValueFlows RecipeExchange). A flow that is a clause of an
;;; exchange is handed over or received under it:
;;;
;;;   an output, with nothing coming back     a gift given    (food: share-food)
;;;   an output, with money coming back       a sale          (food: food-vending)
;;;   an input, with nothing going back       a gift received (food: recover-surplus)
;;;
;;; The legal crossings are read off exactly this (legal/crossings.scm
;;; `*crossing-patterns*`), so a recipe that states its exchange needs no tag to
;;; say which it is. The exchange touches no solve: the planner reads a
;;; process's inputs and outputs, and the money that comes back belongs to no
;;; process.
;;;
;;;   (state-exchange! rs "rx-meal" "A meal, given")                  ; a gift
;;;   (state-exchange! rs "rx-meal" "A meal, sold" #:money "spec-eur") ; a sale
;;;
;;; then name the exchange on the flow handed over (`recipe-clause-of`) and in
;;; the recipe's own list of exchanges.

(define-module (playnet knowledge recipes handover)
  #:use-module (playnet vf schemas)
  #:use-module (goblins)
  #:export (state-exchange!))

(define* (state-exchange! recipe-store id name #:key (money #f))
  "Register the RecipeExchange ID. MONEY — a money spec id — adds what comes
   back: a transfer of that money, a clause of the exchange and of no process.
   Returns ID."
  ($ recipe-store 'add-recipe-exchange (make-recipe-exchange #:id id #:name name))
  (when money
    ($ recipe-store 'add-recipe-flow
       (make-recipe-flow #:id (string-append id "/money") #:action 'transfer
                         #:resource-conforms-to money #:resource-classified-as '("currency")
                         #:recipe-clause-of id)))
  id)
