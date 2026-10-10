;;; test-labels-containers.scm — places inside places, the code a thing is known
;;; by, a container that moves with what is in it, and the lot's date, over the
;;; real ^planner-service (docs/observation/capture.md §6).
;;;
;;; What this pins:
;;;
;;;   • a place is declared inside a place, as deep as the store needs; its id
;;;     is its parent's with its own name after a slash, it stands at its
;;;     parent's position when it states none, and its parent exists;
;;;   • a stock's label code is six characters of an alphabet with no
;;;     look-alikes, unique in the scope, the same on every asking, and it
;;;     outlasts a re-declaration of the thing;
;;;   • a code finds its thing however it was typed, with what is in it;
;;;   • a container that moves takes along what was where it was, and a content
;;;     that keeps a place of its own keeps it;
;;;   • a content that states no place reads at its container's on the wire;
;;;   • a lot's date says which date it is, the wire carries it, and a lot
;;;     stored before the field reads as stating none.
;;;
;;; Run from project root:
;;;   tools/own-ccache.sh guile --no-auto-compile -q -L module tests/playnet/test-labels-containers.scm

(define %project-root (string-append (dirname (current-filename)) "/../.."))
(chdir %project-root)

(add-to-load-path "module")
(use-modules ((playnet utils units) #:select (%count-unit %effort-unit)))
(use-modules ((playnet wire rows) #:select (plain-reply)))   ; a door's rows, read back as alists
(use-modules (playnet test harness))
(use-modules (goblins)
             (goblins persistence-store memory)
             (goblins utils hashmap)
             (playnet planner scope root) (playnet planner vf schemas) (playnet planner beyond lot) (playnet planner vf serdes) (srfi srfi-1)
             (playnet planner doors service)
             (playnet planner facts labels)
             (playnet planner vf serdes)
             (srfi srfi-1))

(display "\n── Setup: a scope, a site, a bin on a shelf ──\n")

(define store (make-memory-store))
(define-values (vat scope)
  (spawn-persistent-vat scope-root-env
                        (lambda () (spawn-scope-root "Commune"))
                        store))

(define svc
  (with-vat vat
    ($ ($ scope 'recipe-store) 'add-resource-spec
       (make-resource-specification #:id "spec-bin" #:name "Storage bin"
                                    #:resource-classified-as '("container") #:default-unit-of-resource %count-unit #:default-unit-of-effort %effort-unit
                                    #:keep-in-place #t))
    (spawn ^planner-service (hashmap-set (hashmap) "org:commune" scope))))

(define (call method . args) (plain-reply (with-vat vat (apply $ svc method args))))
(define (obs method . args)
  (with-vat vat (apply $ ($ scope 'observer) method args)))
(define (place id)
  (with-vat vat ($ ($ scope 'spatial-thing-store) 'get-location id)))
(define (resource id) (obs 'get-resource id))
(define (ok? r)  (and (pair? r) (eq? (car r) 'ok)))
(define (err r)  (and (pair? r) (eq? (car r) 'error) (cdr r)))
(define (field r k) (and (ok? r) (assq-ref (cdr r) k)))

(check-pred "setup: service spawned" svc)

;;; ── 1. places inside places ─────────────────────────────────────────────

(display "\n── 1. a place inside a place ──\n")

(define site (call 'declare-place "org:commune" "ada" "Mill House" 52.5 13.4 "Mill Lane 1"))
(check-pred "a site is declared" (ok? site))
(define site-id (field site 'id))

(define pantry (call 'declare-place "org:commune" "ada" "Pantry" 0 0 "" site-id))
(define cellar (call 'declare-place "org:commune" "ada" "Cellar" 0 0 "" site-id))
(check-pred "a room is declared inside the site" (ok? pantry))
(define pantry-id (field pantry 'id))
(define cellar-id (field cellar 'id))

(check "the room's parent is the site"
       (spatial-thing-contained-in (place pantry-id)) site-id)
(check-pred "the room's id is the site's with its own name after a slash"
            (string=? pantry-id (string-append site-id "/pantry")))
(check "a room that states no position stands at its site's latitude"
       (spatial-thing-lat (place pantry-id)) 52.5)
(check "…and its longitude"
       (spatial-thing-long (place pantry-id)) 13.4)
(check "…and answers to its address"
       (spatial-thing-mappable-address (place pantry-id)) "Mill Lane 1")

(define shelf-p (call 'declare-place "org:commune" "ada" "Shelf 1" 0 0 "" pantry-id))
(define shelf-c (call 'declare-place "org:commune" "ada" "Shelf 1" 0 0 "" cellar-id))
(check-pred "a shelf is declared inside the room" (ok? shelf-p))
(define shelf-id (field shelf-p 'id))
(define cellar-shelf-id (field shelf-c 'id))
(check "the shelf's parent is the room"
       (spatial-thing-contained-in (place shelf-id)) pantry-id)
(check-pred "two rooms each have a shelf 1, and they are two places"
            (not (string=? shelf-id cellar-shelf-id)))
(check "three levels down, the position is still the site's"
       (spatial-thing-lat (place shelf-id)) 52.5)

(define own (call 'declare-place "org:commune" "ada" "Garden Shed" 52.6 13.5 "" site-id))
(check "a place that states its position keeps it"
       (spatial-thing-lat (place (field own 'id))) 52.6)
(check-pred "a place is inside a place that exists"
            (err (call 'declare-place "org:commune" "ada" "Nowhere" 0 0 "" "place:none")))
(check "a place declared with no parent has none"
       (spatial-thing-contained-in (place site-id)) #f)

;;; ── 2. the code a thing is known by ─────────────────────────────────────

(display "\n── 2. a label's code ──\n")

(obs 'seed-resource
     (make-economic-resource #:id "bin/1" #:name "the jar bin" #:conforms-to "spec-bin" #:classified-as '()
                             #:accounting-quantity (make-measure 1.0 %count-unit) #:onhand-quantity (make-measure 1.0 %count-unit)
                             #:current-location shelf-id #:primary-accountable "org:commune"))
(obs 'seed-resource
     (make-economic-resource #:id "bin/2" #:name "the tin bin" #:conforms-to "spec-bin" #:classified-as '()
                             #:accounting-quantity (make-measure 1.0 %count-unit) #:onhand-quantity (make-measure 1.0 %count-unit)
                             #:current-location shelf-id #:primary-accountable "org:commune"))
(obs 'seed-resource
     (make-economic-resource #:id "bob/drill" #:name "bob's drill" #:conforms-to "drill" #:classified-as '()
                             #:accounting-quantity (make-measure 1.0 %count-unit) #:onhand-quantity (make-measure 1.0 %count-unit) #:primary-accountable "bob"))

(define l1 (call 'label-stock "org:commune" "ada" "bin/1"))
(check-pred "a stock is given a code" (ok? l1))
(define code1 (field l1 'code))
(check "the code is six characters" (string-length code1) %label-length)
(check-pred "…of the alphabet with no look-alikes"
            (every (lambda (c) (string-index %label-alphabet c)) (string->list code1)))
(check-pred "the code says nothing of the thing"
            (not (or (string-contains-ci code1 "bin") (string-contains-ci code1 "jar"))))
(check "the resource holds its code"
       (economic-resource-tracking-identifier (resource "bin/1")) code1)
(check "the code is the same on every asking"
       (field (call 'label-stock "org:commune" "ada" "bin/1") 'code) code1)
(check "the first asking says it gave the code" (field l1 'minted) #t)
(check "…and a later asking says it did not"
       (field (call 'label-stock "org:commune" "ada" "bin/1") 'minted) #f)
(check "a label leaves what is on hand as it was"
       (measure-qty (economic-resource-onhand-quantity (resource "bin/1"))) 1.0)

(define code2 (field (call 'label-stock "org:commune" "ada" "bin/2") 'code))
(check-pred "two stocks are known by two codes" (not (string=? code1 code2)))

(check-pred "a label is for a stock that exists"
            (err (call 'label-stock "org:commune" "ada" "no/such")))
(check-pred "another person's stock is theirs to label"
            (err (call 'label-stock "org:commune" "ada" "bob/drill")))
(check "…and stays without a code"
       (economic-resource-tracking-identifier (resource "bob/drill")) #f)

(define oven (call 'declare-means "org:commune" "ada" "oven" 1 %count-unit pantry-id))
(check-pred "a thing declared is accepted" (ok? oven))
(define oven-code (economic-resource-tracking-identifier (resource (cdr oven))))
(check-pred "a thing declared has its code from the start"
            (and (string? oven-code) (= 6 (string-length oven-code))))
;; custody, stage and state are the thing's own: a re-declaration outlasts them
(obs 'seed-resource
     (copy-economic-resource (resource (cdr oven))
                             #:custodian-scope "org:commune" #:stage "stored" #:state "fresh"
                             #:previous-event "evt-before"))
(call 'declare-means "org:commune" "ada" "oven" 2 %count-unit pantry-id #f "the big one")
(check "a re-declaration keeps the code"
       (economic-resource-tracking-identifier (resource (cdr oven))) oven-code)
(check "…and lands the new quantity"
       (measure-qty (economic-resource-onhand-quantity (resource (cdr oven)))) 2)
(check "…and says what it now states" (economic-resource-note (resource (cdr oven))) "the big one")
(check "…and keeps the custody" (economic-resource-custodian-scope (resource (cdr oven))) "org:commune")
(check "…the stage and the state"
       (list (economic-resource-stage (resource (cdr oven))) (economic-resource-state (resource (cdr oven))))
       '("stored" "fresh"))
(check-pred "…and the trail of its last event"
            (economic-resource-previous-event (resource (cdr oven))))

;;; ── 3. a code finds its thing ───────────────────────────────────────────

(display "\n── 3. reading a label ──\n")

(define jars (call 'drop-event "org:commune" "dropoff" "bin/1" "ada"
                   "jam" 12.0 %count-unit "bin/1/jam" "plum jam, this year's"))
(check-pred "jars are left in the bin" (ok? jars))
(check-pred "a thing left in a container has its code from the start"
            (string? (economic-resource-tracking-identifier (resource "bin/1/jam"))))

(define read1 (call 'read-label "org:commune" "ada" code1))
(check-pred "a code finds its thing" (ok? read1))
(check "…the thing it names"
       (assq-ref (field read1 'resource) 'id) "bin/1")
(check "…where it is"
       (assq-ref (field read1 'resource) 'location) shelf-id)
(check "…and what is in it"
       (map (lambda (c) (assq-ref c 'id)) (field read1 'contents)) '("bin/1/jam"))
(check "the tin bin holds nothing"
       (field (call 'read-label "org:commune" "ada" code2) 'contents) '())

(check "a code typed in lower case finds the same thing"
       (assq-ref (field (call 'read-label "org:commune" "ada" (string-downcase code1))
                        'resource) 'id)
       "bin/1")
(check "a code typed with spaces and a dash finds the same thing"
       (assq-ref (field (call 'read-label "org:commune" "ada"
                              (string-append (substring code1 0 3) " - " (substring code1 3)))
                        'resource) 'id)
       "bin/1")
;; a code holding a 1 or a 0, typed with the letters they resemble
(obs 'seed-resource
     (make-economic-resource #:id "tin/10" #:name "a tin" #:tracking-identifier "A1B0C1" #:conforms-to "tin" #:classified-as '()
                             #:accounting-quantity (make-measure 1.0 %count-unit) #:onhand-quantity (make-measure 1.0 %count-unit)
                             #:current-location shelf-id #:primary-accountable "org:commune"))
(check "a typed I, L or O reads as the digit it resembles"
       (assq-ref (field (call 'read-label "org:commune" "ada" "AiBoCl") 'resource) 'id)
       "tin/10")
(check-pred "a code no stock is known by finds nothing"
            (err (call 'read-label "org:commune" "ada" "ZZZZZZ")))
(check-pred "an empty code finds nothing"
            (err (call 'read-label "org:commune" "ada" "")))

;;; ── 4. a container moves with what is in it ─────────────────────────────

(display "\n── 4. a bin carried to another shelf ──\n")

;; the oven sits in the bin's containment and keeps a place of its own
(obs 'seed-resource
     (make-economic-resource #:id "bin/1/scale" #:name "the kitchen scale" #:conforms-to "scale" #:classified-as '()
                             #:accounting-quantity (make-measure 1.0 %count-unit) #:onhand-quantity (make-measure 1.0 %count-unit)
                             #:current-location pantry-id #:primary-accountable "org:commune" #:contained-in "bin/1"))
;; a nested container, and a thing in it that states no place
(obs 'seed-resource
     (make-economic-resource #:id "bin/1/box" #:name "a box in the bin" #:conforms-to "spec-bin" #:classified-as '()
                             #:accounting-quantity (make-measure 1.0 %count-unit) #:onhand-quantity (make-measure 1.0 %count-unit)
                             #:current-location shelf-id #:primary-accountable "org:commune" #:contained-in "bin/1"))
(obs 'seed-resource
     (make-economic-resource #:id "bin/1/box/lids" #:name "spare lids" #:conforms-to "lid" #:classified-as '()
                             #:accounting-quantity (make-measure 30.0 %count-unit) #:onhand-quantity (make-measure 30.0 %count-unit) #:primary-accountable "org:commune" #:contained-in "bin/1/box"))

(check "before the move, the jars are where the bin is"
       (economic-resource-current-location (resource "bin/1/jam")) shelf-id)
(check "a content that states no place reads at its container's on the wire"
       (assq-ref (find (lambda (c) (equal? "bin/1/box/lids" (assq-ref c 'id)))
                       (field (call 'read-label "org:commune" "ada"
                                    (field (call 'label-stock "org:commune" "ada" "bin/1/box") 'code))
                              'contents))
                 'location)
       shelf-id)

;; the listeners an event reaches hear of what its container carried
(define heard '())
(obs 'add-event-listener (lambda (event affected) (set! heard affected)))

(obs 'record-event
     (make-economic-event
      #:id "evt-move-bin" #:action 'move
      #:resource-inventoried-as "bin/1" #:to-resource-inventoried-as "bin/1"
      #:resource-conforms-to "spec-bin"
      #:provider "ada" #:receiver "ada"
      #:resource-quantity (make-measure 1.0 %count-unit) #:has-point-in-time "2026-09-28T10:00:00Z" #:created "2026-09-28T10:00:00Z"
      #:at-location shelf-id #:to-location cellar-shelf-id
      #:note "carried to the cellar" #:in-scope-of '("org:commune")))

(check-pred "the listeners hear of every content the move carried"
            (every (lambda (id) (member id (map economic-resource-id heard)))
                   '("bin/1" "bin/1/jam" "bin/1/box" "bin/1/box/lids")))
(check-pred "…and not of the one that kept its place"
            (not (member "bin/1/scale" (map economic-resource-id heard))))
(check "the bin is on the other shelf"
       (economic-resource-current-location (resource "bin/1")) cellar-shelf-id)
(check "the jars went with it"
       (economic-resource-current-location (resource "bin/1/jam")) cellar-shelf-id)
(check "the box in the bin went with it"
       (economic-resource-current-location (resource "bin/1/box")) cellar-shelf-id)
(check "…and what is in the box, which stated no place, is there too"
       (economic-resource-current-location (resource "bin/1/box/lids")) cellar-shelf-id)
(check "a content that keeps a place of its own keeps it"
       (economic-resource-current-location (resource "bin/1/scale")) pantry-id)
(check "the move leaves the jars in the bin"
       (economic-resource-contained-in (resource "bin/1/jam")) "bin/1")
(check "…and as many as there were"
       (measure-qty (economic-resource-onhand-quantity (resource "bin/1/jam"))) 12.0)
(check "the bin beside it stayed where it was"
       (economic-resource-current-location (resource "bin/2")) shelf-id)

;;; ── 5. the lot's date says which date it is ─────────────────────────────

(display "\n── 5. a lot's date ──\n")

(define use-by (make-batch-lot-record "lot-1" "L-2026-09" "2026-10-05T00:00:00Z"
                                      #:expiration-kind 'use-by))
(define plain  (make-batch-lot-record "lot-2" "L-2026-10" "2026-11-01T00:00:00Z"))
(check "a lot states which date it carries" (batch-lot-record-expiration-kind use-by) 'use-by)
(check "a lot that states none carries none" (batch-lot-record-expiration-kind plain) #f)
(check "a kind the label does not know is no kind"
       (batch-lot-record-expiration-kind
        (make-batch-lot-record "lot-3" #f "2026-11-01T00:00:00Z" #:expiration-kind 'sell-by))
       #f)
(check "the date stands as stated"
       (batch-lot-record-expiration-date use-by) "2026-10-05T00:00:00Z")
(check "the kind survives storing and restoring"
       (batch-lot-record-expiration-kind (vf-deserialize (vf-serialize use-by))) 'use-by)
(check "a lot stored before the field reads as stating none"
       (batch-lot-record-expiration-kind
        (vf-deserialize '(@vf BatchLotRecord (id . "lot-old") (batch-lot-code . "OLD")
                              (expiration-date . "2026-01-01T00:00:00Z"))))
       #f)

(obs 'seed-resource
     (make-economic-resource #:id "bin/2/milk" #:name "milk" #:tracking-identifier "M11K00" #:conforms-to "milk" #:classified-as '()
                             #:accounting-quantity (make-measure 6.0 "l") #:onhand-quantity (make-measure 6.0 "l")
                             #:current-location shelf-id #:primary-accountable "org:commune" #:contained-in "bin/2" #:lot use-by))
(define milk (field (call 'read-label "org:commune" "ada" "M11K00") 'resource))
(check "the wire carries the lot's code" (assq-ref milk 'lot-code) "L-2026-09")
(check "…its date" (assq-ref milk 'expires) "2026-10-05T00:00:00Z")
(check "…and which date that is" (assq-ref milk 'expires-kind) "use-by")

(test-summary!)
