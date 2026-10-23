;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; worlds/demo-neighbourhood.scm — the demo neighbourhood: one world, and what happened in it.
;;;
;;; The neighbourhood a person sees before they have a commune of their own: its
;;; places, its people, the goods its commons holds and where, and the counts and
;;; contests of those stocks. It is a `<world>` (world.scm) plus a short list of
;;; acts, each a call of a real door, so every figure a face shows of it is one
;;; the planner answered:
;;;
;;;   • a gateway adopts it as the preset `neighbourhood` (worlds/presets.scm);
;;;   • the page's offline demo is a recording of it (tools/emit/demo-emit.scm →
;;;     ui/app/demo/recording.ts);
;;;   • its suite reads it over a real scope (tests/doors/test-demo-neighbourhood.scm).
;;;
;;; Places are laid as offsets in degrees from the person, who stands at the
;;; origin: a face moves them to where the person is. Days are counted from the
;;; day the acts are played on, so "four days ago" holds whatever day that is.

(define-module (playnet knowledge worlds demo-neighbourhood)
  #:use-module (playnet vf schemas)
  #:use-module (playnet vf beyond lot)
  #:use-module (playnet knowledge dsl world)
  #:use-module (playnet knowledge dsl shorthand)
  #:use-module ((playnet utils clock) #:select (epoch->civil civil->epoch))
  #:use-module (srfi srfi-1)
  #:export (%demo-scope %demo-you
            demo-world demo-world-on demo-acts demo-face play-demo!))

(define %demo-scope "org:neighbourhood")
;; the person the demo is seen through
(define %demo-you "you")
;; what the scope is called where its stocks name who holds them
(define %commons-name "the commons")

;;; ── people: (id name) ────────────────────────────────────────────────────

(define %people
  '(("you" "you")
    ("ana" "Ana") ("sam" "Sam") ("priya" "Priya") ("mara" "Mara") ("dev" "Dev")
    ("ines" "Ines") ("mira" "Mira") ("luca" "Luca") ("noor" "Noor") ("kai" "Kai")
    ("omar" "Omar") ("bob" "Bob") ("meiers" "the Meiers") ("jonas" "Jonas") ("lena" "Lena")
    ;; your family
    ("mama" "mama") ("dad" "dad")))

;; where a person lives, for those the world gives a home; the rest are of the commons
(define %homes
  '(("you" . "place:home") ("mama" . "place:home") ("dad" . "place:home")
    ("ana" . "place:ana-home") ("sam" . "place:sam-home") ("bob" . "place:bob-home")
    ("priya" . "place:priya-home") ("omar" . "place:omar-home") ("mira" . "place:mira-home")
    ("meiers" . "place:meiers-workshop")))

(define (home-of person) (or (assoc-ref %homes person) "place:commons"))

;;; ── places: (id name emoji contained-in north east), degrees from the person ──

(define %places
  '(
    ("place:commons" "neighbourhood commons" "🏘️" #f -0.006 0.005)
    ("place:home" "home" "🛏️" #f 0.001 0.002)
    ("place:aleko-mountain-hut" "Aleko mountain hut" "⛰️" #f 0.060 -0.090)
    ("place:city-garden" "city garden" "🌳" #f 0.004 -0.006)
    ("place:mineral-baths" "mineral baths" "♨️" #f -0.003 0.004)
    ("place:cafe" "reading café" "☕" #f 0.007 0.009)
    ("place:borisova-gradina" "Borisova gradina" "🌲" #f -0.011 0.013)
    ("place:monastery-garden" "monastery garden" "🕊️" #f 0.045 0.060)
    ("place:bakery" "Bakery Vitosha" "🍞" #f 0.004 -0.008)
    ("place:canteen" "commons canteen" "🍲" "place:commons" -0.006 0.005)
    ("place:sourdough-co-op" "Sourdough Co-op" "🥖" #f 0.012 -0.003)
    ("place:teahouse" "tea house" "🍵" #f -0.002 0.007)
    ("place:corner-cafe" "corner café" "🫖" #f 0.006 0.001)
    ("place:communal-kitchen" "communal kitchen" "🍳" #f -0.005 -0.004)
    ("place:central-market-hall" "central market hall" "🧺" #f 0.003 0.010)
    ("place:vitosha-trailhead" "Vitosha trailhead" "🥾" #f 0.030 -0.045)
    ("place:south-park-loop" "South Park loop" "🚶" #f -0.009 0.008)
    ("place:gym-commons" "gym commons" "🏋️" #f 0.005 -0.011)
    ("place:climbing-wall" "climbing wall" "🧗" #f -0.012 0.006)
    ("place:yoga-hall" "yoga hall" "🧘" #f 0.002 0.005)
    ("place:park-pavilion" "park pavilion" "⛩️" #f -0.007 -0.009)
    ("place:city-library" "city library" "📚" #f 0.003 -0.002)
    ("place:book-swap-shelf" "book swap shelf" "📖" #f -0.008 0.011)
    ("place:rehearsal-rooms" "rehearsal rooms" "🎻" #f 0.009 0.007)
    ("place:makerspace-south" "makerspace south" "🛠️" #f -0.004 0.013)
    ("place:community-hall" "community hall" "🏛️" #f -0.006 -0.007)
    ("place:open-seminar" "open seminar" "👩‍🏫" #f 0.011 0.004)
    ("place:grandmas" "grandma's" "🏡" #f 0.014 -0.010)
    ("place:cousins-place" "cousins' place" "🏠" #f -0.016 0.012)
    ("place:hovel-cafe" "hovel café" "🍻" #f 0.005 0.006)
    ("place:board-game-club" "board-game club" "🎲" #f -0.003 -0.011)
    ("place:neighbourhood-assembly" "neighbourhood assembly" "🗣️" #f 0.001 -0.005)
    ("place:repair-cafe" "repair café" "🔧" #f 0.010 -0.007)
    ("place:free-kitchen" "free kitchen" "🥘" #f -0.009 0.003)
    ("place:ana-home" "Ana's place" "🏠" #f 0.0038 0.0052)
    ("place:sam-home" "Sam's place" "🏠" #f 0.0040 0.0055)
    ("place:meiers-workshop" "the Meiers' workshop" "🔧" #f -0.0046 0.0031)
    ("place:bob-home" "Bob's place" "🏠" #f 0.0012 -0.0058)
    ("place:priya-home" "Priya's place" "🏠" #f -0.0022 -0.0035)
    ("place:omar-home" "Omar's place" "🏠" #f 0.0051 -0.0018)
    ("place:mira-home" "Mira's place" "🏠" #f -0.0031 0.0062)
    ("place:community-farm" "community farm" "🌾" #f -0.020 0.025)
    ("place:north-field" "north field" "🌾" #f -0.028 0.031)
    ("place:community-garden" "community garden" "🌱" #f 0.006 0.012)
    ("place:school" "the school" "🏫" #f -0.012 0.004)
    ("place:tool-library" "tool library" "🧰" #f -0.003 0.006)
    ("place:pantry" "pantry" "🥫" "place:commons" -0.0062 0.0053)
    ("place:hub" "mobility hub" "🚲" "place:commons" -0.0057 0.0046)
    ("place:storeroom" "store room" "📦" "place:commons" -0.0064 0.0047)
    ))

(define %venues
  '(
    ("place:home" "rest/sleep" own "always" #f #f)
    ("place:aleko-mountain-hut" "rest/sleep" common "weekends" #f #f)
    ("place:city-garden" "rest/unwinding" common "now" #f #f)
    ("place:mineral-baths" "rest/unwinding" claim "till 22h" #f #f)
    ("place:cafe" "rest/unwinding" claim "till 23h" #f #f)
    ("place:borisova-gradina" "rest/stillness" common "always" #f #f)
    ("place:monastery-garden" "rest/stillness" common "dawn–dusk" #f #f)
    ("place:bakery" "nourishment/meals" claim "now" #f #f)
    ("place:canteen" "nourishment/meals" common "12–15h" #f #f)
    ("place:sourdough-co-op" "nourishment/meals" claim "+2h" #f #f)
    ("place:canteen" "nourishment/meals" work "5–9h · 3 needed" "bakery shift" "🧑‍🍳")
    ("place:teahouse" "nourishment/tea-snacks" claim "now" #f #f)
    ("place:corner-cafe" "nourishment/tea-snacks" claim "now" #f #f)
    ("place:communal-kitchen" "nourishment/cooking" common "16–21h" #f #f)
    ("place:central-market-hall" "nourishment/cooking" claim "till 19h" #f #f)
    ("place:communal-kitchen" "nourishment/cooking" work "11–14h · 2 needed" "canteen cook shift" #f)
    ("place:vitosha-trailhead" "movement/walking" common "always" #f #f)
    ("place:south-park-loop" "movement/walking" common "always" #f #f)
    ("place:gym-commons" "movement/training" common "6–22h" #f #f)
    ("place:climbing-wall" "movement/training" claim "10–22h" #f #f)
    ("place:gym-commons" "movement/training" work "18h · 1 needed" "coach a session" "🧑‍🏫")
    ("place:yoga-hall" "movement/stretching" common "7h & 18h" #f #f)
    ("place:park-pavilion" "movement/stretching" common "always" #f #f)
    ("place:city-library" "learning/reading" common "9–20h" #f #f)
    ("place:book-swap-shelf" "learning/reading" common "always" #f #f)
    ("place:rehearsal-rooms" "learning/practice" common "book a slot" #f #f)
    ("place:makerspace-south" "learning/practice" common "10–22h" #f #f)
    ("place:rehearsal-rooms" "learning/practice" work "flexible · 1 needed" "mentor an hour" "🧑‍🏫")
    ("place:community-hall" "learning/study-circle" common "Tue & Thu 18h" #f #f)
    ("place:open-seminar" "learning/study-circle" common "Wed 17h" #f #f)
    ("place:community-hall" "learning/study-circle" work "Thu 18h · 1 needed" "lead a circle" "🗣️")
    ("place:grandmas" "connection/family" own "she's home" #f #f)
    ("place:cousins-place" "connection/family" own "evenings" #f #f)
    ("place:hovel-cafe" "connection/friends" claim "till late" #f #f)
    ("place:board-game-club" "connection/friends" common "19–24h" #f #f)
    ("place:neighbourhood-assembly" "connection/community" common "Mon 19h" #f #f)
    ("place:repair-cafe" "connection/community" common "Sat 11h" #f #f)
    ("place:free-kitchen" "connection/community" common "Sun 13h" #f #f)
    ("place:repair-cafe" "connection/community" work "Sat 11h · 2 needed" "repair café (staff)" #f)
    ("place:free-kitchen" "connection/community" work "Sun 13h · 3 needed" "free kitchen shift" #f)
    ))
;; a venue is what a place offers toward one need: (place leaf mode when name
;; emoji), the name and emoji its own where they differ from the place's (a shift)

;;; ── goods: (id name unit emoji categories hours-in-one external?) ────────

(define %goods
  '(("spec-bread"  "bread"       "loaf"    "🍞" ("nourishment/meals")      0.6 #f)
    ("spec-veg"    "vegetables"  "kg"      "🥬" ("nourishment/meals")      0.4 #f)
    ("spec-tea"    "tea"         "box"     "🍵" ("nourishment/tea-snacks") 0.8 #f)
    ("spec-fabric" "fabric"      "m"       "🧵" ("clothing/fabric")        1.2 #f)
    ("spec-coat"   "winter coat" "item"    "🧥" ("clothing")               9   #f)
    ("spec-chair"  "chair"       "pc"      "🪑" ("furnishing")             6   #f)
    ("spec-eur"    "euros"       "€100"    "💶" ("external/fiat")          2.5 #t)
    ("spec-xmr"    "monero"      "0.1 XMR" "🔒" ("external/crypto")        3.2 #t)
    ;; what else the commons holds
    ("spec-meal"   "cooked meal" "each"    "🍲" ("nourishment/meals")      0.3 #f)
    ("spec-beans"  "dry beans"   "kg"      "🫘" ("nourishment/cooking")    0.5 #f)
    ("spec-jar"    "pantry jar"  "each"    "🫙" ("nourishment/cooking")    0.2 #f)
    ("spec-bike"   "bicycle"     "each"    "🚲" ("movement/commute")       20  #f)
    ("spec-tools"  "repair tools" "set"    "🧰" ("movement/commute")       12  #f)
    ("spec-book"   "book"        "each"    "📚" ("learning/skills")        1   #f)
    ("spec-shelf"  "shelf"       "each"    "🗄️" ("container/shelf")        4   #f)
    ("spec-crate"  "crate"       "each"    "🧺" ("container/crate")        1   #f)
    ;; what people ask for and offer of one another
    ("spec-shelter"     "shelter"      "person-nights" "🏠" ("housing/shelter")        1   #f)
    ("spec-bed"         "bed"          "each"          "🛏️" ("rest/sleep")             8   #f)
    ("spec-childcare"   "childcare"    "hours"         "🧸" ("connection/family")      1   #f)
    ("spec-bike-repair" "bike repair"  "hours"         "🚲" ("movement/commute")       1   #f)
    ("spec-training"    "training"     "hours"         "🏃" ("movement/training")      1   #f)
    ("spec-ride"        "ride"         "seat-hours"    "🚲" ("movement/commute")       1   #f)
    ("spec-workshop"    "workshop"     "each"          "🔧" ("learning/practice")      40  #f)
    ("spec-cargo-bike"  "cargo bike"   "each"          "🚲" ("movement/commute")       30  #f)
    ("spec-zucchini"    "zucchini"     "kg"            "🥒" ("nourishment/meals")      0.3 #f)
    ("spec-sourdough"   "sourdough"    "loaf"          "🍞" ("nourishment/cooking")    0.7 #f)
    ("spec-walks"       "walks"        "hours"         "🚶" ("movement/walking")       1   #f)
    ("spec-study"       "study circle" "hours"         "📚" ("learning/study-circle")  1   #f)))

;;; ── stocks: (id name emoji good held place container mode holder) ────────
;;; HELD is what the books read before the first count below. MODE is how the
;;; stock is shared out: communal, claimable against credit, or a person's own.

(define %stocks
  '(("demo:greens"  "garden greens"    "🥬" "spec-veg"    74.0  "place:canteen"   #f           communal  #f)
    ("demo:loaves"  "sourdough loaves" "🍞" "spec-bread"  102.0 "place:bakery"    #f           communal  #f)
    ("demo:meals"   "cooked meals"     "🍲" "spec-meal"   26.0  "place:canteen"   #f           communal  #f)
    ;; the pantry shelf holds the beans and the roots
    ("demo:shelf"   "pantry shelf"     "🗄️" "spec-shelf"  1.0   "place:pantry"    #f           communal  #f)
    ("demo:beans"   "dry beans"        "🫘" "spec-beans"  63.0  "place:pantry"    "demo:shelf" communal  #f)
    ("demo:roots"   "onions & roots"   "🧅" "spec-veg"    72.0  "place:pantry"    "demo:shelf" communal  #f)
    ("demo:tea"     "loose tea"        "🍵" "spec-tea"    9.0   "place:teahouse"  #f           claimable #f)
    ("demo:fabric"  "bolts of fabric"  "🧵" "spec-fabric" 40.0  "place:storeroom" #f           claimable #f)
    ("demo:coats"   "winter coats"     "🧥" "spec-coat"   3.0   "place:storeroom" #f           claimable #f)
    ("demo:chairs"  "chairs"           "🪑" "spec-chair"  5.0   "place:storeroom" #f           claimable #f)
    ("demo:bikes"   "shared bicycles"  "🚲" "spec-bike"   6.0   "place:hub"       #f           communal  #f)
    ("demo:tools"   "repair tools"     "🧰" "spec-tools"  1.0   "place:hub"       #f           communal  #f)
    ("demo:library" "lending library"  "📚" "spec-book"   340.0 "place:cafe"      #f           communal  #f)
    ;; what the commons holds of the outside's money, claimable like any good
    ("demo:eur"     "euros"            "💶" "spec-eur"    12.0  "place:storeroom" #f           claimable #f)
    ("demo:xmr"     "monero"           "🔒" "spec-xmr"    20.0  "place:storeroom" #f           claimable #f)
    ;; yours: a crate at home, with the jars in it
    ("demo:crate"   "pantry crate"     "🧺" "spec-crate"  1.0   "place:home"      #f           own       "you")
    ("demo:jars"    "your pantry jars" "🫙" "spec-jar"    5.0   "place:home"      "demo:crate" own       "you")))

;; a stock that is a dated lot: (stock code kind), its date the day the world is laid on
(define %lots '(("demo:meals" "L-0612" use-by)))

;;; ── the world ────────────────────────────────────────────────────────────

(define (good-unit spec) (third (assoc spec %goods)))

(define* (demo-world-on today #:optional (scope %demo-scope))
  "The neighbourhood as a world, its commons' stocks accounted to the scope id
   SCOPE. TODAY is the unix second its dated lots hang off (the cooked meals
   are to be used by that day); #f leaves them undated."
  (world
   #:specs (map (lambda (g)
                  (make-resource-specification #:id (first g) #:name (second g) #:resource-classified-as (fifth g)
                                               #:default-unit-of-resource (third g) #:medium-of-exchange (seventh g)))
                %goods)
   #:spatials (map (lambda (p)
                     (place* (first p) #:name (second p) #:parent (fourth p)
                             #:lat (fifth p) #:lon (sixth p)))
                   %places)
   ;; the commons itself, under the name its stocks are shown held by, and its people
   #:agents (cons (org* scope #:name %commons-name #:place "place:commons")
                  (map (lambda (p) (person* (first p) #:name (second p) #:place (home-of (first p))))
                       %people))
   #:resources (map (lambda (s)
                      (let ((lot (and today (assoc-ref %lots (first s)))))
                        (make-economic-resource
                         #:id (first s) #:name (second s) #:conforms-to (fourth s)
                         #:classified-as (case (eighth s)
                           ((communal)  '("communal"))
                           ((claimable) '("individually-claimable"))
                           (else '()))
                         #:accounting-quantity (make-measure (fifth s) (good-unit (fourth s)))
                         #:onhand-quantity (make-measure (fifth s) (good-unit (fourth s)))
                         #:current-location (sixth s) #:primary-accountable (or (ninth s) scope)
                         #:contained-in (seventh s)
                         #:lot (and lot (make-batch-lot-record
                                   (string-append "lot:" (car lot)) (car lot)
                                   (substring (epoch->civil today) 0 10)
                                   #:expiration-kind (cadr lot))))))
                    %stocks)))

;; the world with no day to hang a lot's date off: what a gateway adopts
(define demo-world (demo-world-on #f))

;;; ── what happened: the acts, oldest first ────────────────────────────────
;;; (count who stock figure technique days-ago hour evidence) is a count through
;;; the count door; (contest who stock reason) contests the latest count of the
;;; stock through governance; (label who stock) asks the code the stock is known
;;; by, which mints it. The stocks then show each standing a store has: a
;;; ledger two counts found off, a count that agreed, a stock never counted, a
;;; contest to answer with a picture and one to vote in.

;; What people ask for and offer: (need|offer who spec qty unit place arcs name
;; emoji note categories until-days). ARCS are the hours it recurs in, (start
;; end day …); PLACE is where it stands, when it stands at one; UNTIL-DAYS how
;; many days from the day played it stands until. Each is declared through the
;; slot doors (declare-need, declare-means).
(define %slots
  '(
    (need  "you" "spec-shelter" 2 "person-nights" "place:home" () "housing" "🏠" "matched → Ana's guest room · your ✓ on its proposal commits it" () 2)
    (need  "you" "spec-bread" 3 "loaf" #f (("17:00" "19:00" monday wednesday friday)) "bread" "🍞" "" ("nourishment/meals" "nourishment") #f)
    (need  "you" "spec-childcare" 6 "hours" #f (("09:00" "12:00" tuesday thursday)) "childcare" "🧸" "" () #f)
    (offer "you" "spec-bike-repair" 4 "hours" #f (("16:00" "20:00" saturday)) "bike repair" "🚲" "flats & brakes" () #f)
    (offer "you" "spec-bed" 1 "each" #f () "a spare bed" "🏠" "the sofa bed — lend it into the commons below" () #f)
    (need  "mira" "spec-shelter" 2 "person-nights" "place:mira-home" () "a night's shelter" "🏠" "two nights while the roof dries" ("rest/sleep" "rest") #f)
    (need  "sam" "spec-training" 2 "hours" #f (("07:00" "09:00" tuesday thursday)) "a running partner" "🏃" "mornings, easy pace" ("movement/training" "movement") #f)
    (need  "priya" "spec-shelter" 30 "person-nights" "place:priya-home" () "a room for the month" "🏠" "" ("rest/sleep" "rest") 30)
    (need  "omar" "spec-ride" 3 "seat-hours" "place:omar-home" (("09:00" "12:00" saturday)) "market haul, Saturdays" "🚲" "" ("movement" "movement/commute") #f)
    (offer "ana" "spec-bed" 1 "each" "place:ana-home" () "Ana's guest room" "🏠" "socialized into the commons" ("rest/sleep" "rest") 60)
    (offer "sam" "spec-bed" 1 "each" "place:sam-home" () "Sam's attic bed" "🏠" "socialized into the commons" ("rest/sleep" "rest") 21)
    (offer "meiers" "spec-workshop" 1 "each" "place:meiers-workshop" () "the wood workshop" "🔧" "" ("learning/practice" "learning") #f)
    (offer "bob" "spec-cargo-bike" 1 "each" "place:bob-home" (("08:00" "18:00" monday tuesday wednesday thursday friday)) "Bob's Lastenrad" "🚲" "" ("movement" "movement/commute") #f)
    (offer "ana" "spec-zucchini" 6 "kg" #f () "zucchini glut" "🥒" "the garden overdid it — please take some" ("nourishment/meals" "nourishment") #f)
    (offer "luca" "spec-sourdough" 2 "loaf" #f (("16:00" "20:00" friday)) "sourdough starter + bake day" "🍞" "loaves every Friday, extras to share" ("nourishment/cooking" "nourishment") #f)
    (offer "noor" "spec-walks" 5 "hours" #f (("07:00" "08:30" monday tuesday wednesday thursday friday)) "morning walks" "🚶" "up the hill and back, company welcome" ("movement/walking" "movement") #f)
    (offer "kai" "spec-study" 2 "hours" #f () "reading circle" "📚" "Tuesdays, the long table" ("learning/study-circle" "learning") #f)
    (offer "noor" "spec-bread" 8 "loaf" #f (("17:00" "18:30" monday friday)) "wood-oven loaves" "🔥" "bakes Monday and Friday" ("nourishment/meals" "nourishment") #f)
    ))

(define %picture (string-append "sha256:" (apply string-append (make-list 32 "d3"))))

(define demo-acts
  `((count "dev"  "demo:beans"  61.5  "stated" 24 10 "")
    (count "mara" "demo:greens" 75.0  "stated" 11 9  "")
    (count "you"  "demo:beans"  60.0  "photo"  9  17 ,%picture)
    (count "dev"  "demo:loaves" 104.0 "stated" 6  8  "")
    (count "mara" "demo:bikes"  6.0   "stated" 5  12 "")
    (count "you"  "demo:greens" 72.0  "stated" 4  12 "")
    (count "ines" "demo:meals"  24.0  "stated" 1  14 "")
    (label "you" "demo:shelf")
    (label "you" "demo:crate")
    (contest "mara" "demo:greens" "the crate was empty at noon")
    (contest "ines" "demo:loaves" "the bakery was shut that day")
    ,@%slots))

;; a list of strings, and a slot's arcs, as the JSON the slot doors take
(define (strings-json l)
  (string-append "[" (string-join (map (lambda (s) (string-append "\"" s "\"")) l) ",") "]"))
(define (arcs-json arcs)
  (string-append
   "["
   (string-join
    (map (lambda (a)
           (string-append "{\"start\":\"" (first a) "\",\"end\":\"" (second a) "\",\"days\":"
                          (strings-json (map symbol->string (cddr a))) "}"))
         arcs)
    ",")
   "]"))

(define (ok-field reply key)
  (and (pair? reply) (eq? 'ok (car reply)) (pair? (cdr reply))
       (let ((p (assoc key (cdr reply)))) (and p (cdr p)))))

(define (play-demo! call contest today)
  "Play the acts on a scope the world is seeded in. CALL is the planner
   service's door, (call method arg …); CONTEST opens a contest, (contest who
   event-id reason); TODAY is the unix second the acts are counted back from.
   Returns each act's reply, in order."
  (define (instant days-ago hour)
    (epoch->civil (+ (- (* 86400 (quotient today 86400)) (* 86400 days-ago)) (* 3600 hour))))
  (let loop ((acts demo-acts) (latest '()) (out '()))
    (if (null? acts)
        (reverse out)
        (let ((a (car acts)))
          (case (car a)
            ((count)
             (let* ((who (second a)) (stock (third a))
                    (reply (call 'count-stock %demo-scope who stock (fourth a)
                                 (good-unit (fourth (assoc stock %stocks)))
                                 (fifth a) (sixth (assoc stock %stocks))
                                 (instant (sixth a) (seventh a)) "" (eighth a) "")))
               (loop (cdr acts)
                     (acons stock (or (ok-field reply "record") "") latest)
                     (cons reply out))))
            ((need offer)
             (let* ((until (and (list-ref a 11) (substring (instant (- (list-ref a 11)) 0) 0 10)))
                    (arcs  (arcs-json (list-ref a 6)))
                    (cats  (strings-json (list-ref a 10)))
                    ;; a slot that names no place stands where its person lives
                    (place (or (list-ref a 5) (home-of (second a)))))
               (loop (cdr acts) latest
                     (cons (if (eq? 'need (car a))
                               (call 'declare-need %demo-scope (second a) (third a) (fourth a) (fifth a)
                                     place arcs (list-ref a 9) (list-ref a 8) "" (or until "")
                                     (list-ref a 7) cats)
                               (call 'declare-means %demo-scope (second a) (third a) (fourth a) (fifth a)
                                     place arcs (list-ref a 9) (list-ref a 8) (list-ref a 7) cats))
                           out))))
            ((label)
             (loop (cdr acts) latest
                   (cons (call 'label-stock %demo-scope (second a) (third a)) out)))
            ((contest)
             (let ((reply (contest (second a) (or (assoc-ref latest (third a)) "") (fourth a))))
               (loop (cdr acts) latest (cons reply out))))
            (else (error "demo-acts: no such act" a)))))))

;;; ── what no record carries: how a face shows the world ───────────────────

(define (demo-face)
  "The emoji of each place, good and stock, and the venues of the places: the
   presentation a face adds to the records, as string-keyed rows."
  `(("you" . ,%demo-you)
    ("scope" . ,%demo-scope)
    ("commons" . ,%commons-name)
    ("people" . ,(list->vector (map (lambda (p) `(("id" . ,(first p)) ("name" . ,(second p)))) %people)))
    ("places" . ,(map (lambda (p) (cons (first p) (third p))) %places))
    ("goods" . ,(list->vector
                 (map (lambda (g)
                        `(("id" . ,(first g)) ("name" . ,(second g)) ("unit" . ,(third g))
                          ("emoji" . ,(fourth g)) ("cats" . ,(list->vector (fifth g)))
                          ("snlt" . ,(exact->inexact (sixth g)))
                          ("external" . ,(seventh g))))
                      %goods)))
    ("stocks" . ,(map (lambda (s) (cons (first s) (third s))) %stocks))
    ("venues" . ,(list->vector
                  (map (lambda (v)
                         `(("place" . ,(first v)) ("leaf" . ,(second v))
                           ("mode" . ,(symbol->string (third v))) ("when" . ,(fourth v))
                           ,@(if (fifth v) `(("name" . ,(fifth v))) '())
                           ,@(if (sixth v) `(("emoji" . ,(sixth v))) '())))
                       %venues)))))
