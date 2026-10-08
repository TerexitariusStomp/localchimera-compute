;;; test-slots-service.scm — slots: capacity + need as one expression
;;;
;;; The free-association port: a slot is qty + unit + place + a recurring
;;; time pattern (arcs JSON → <availability-window>). Capacity slots ride
;;; <economic-resource> (declare-means, deterministic id ⇒ re-declare =
;;; edit); need slots ride <intent> (declare-need, receiver = citizen,
;;; window ⇒ standing order). my-slots reads both back with the arcs;
;;; retire-need withdraws. NO new schema fields anywhere.
;;; Run: guile -L module tests/planner/test-slots-service.scm

(use-modules (playnet test harness))
(use-modules (playnet planner scope root) (playnet planner vf schemas) (srfi srfi-1))
(use-modules (playnet planner doors service))
(use-modules ((playnet wire rows) #:select (plain-reply)))
(use-modules ((playnet planner solve engine) #:select (set-cap-scale!)))
(use-modules (goblins) (goblins vat) (goblins actor-lib methods) (goblins utils hashmap) (srfi srfi-1))

(define ARCS "[{\"start\":\"09:00\",\"end\":\"12:00\",\"days\":[\"monday\",\"wednesday\"]},{\"start\":\"18:00\",\"end\":\"20:00\",\"days\":[\"friday\"]}]")

(define vat (spawn-vat))
(define root-ref #f)
(define svc-ref
  (with-vat vat
    ;; add-scope! is the one door that wires a scope's folds (demand, means,
    ;; labour) — the reading our-slots gives back is the demand node's
    (let* ((sr  (spawn-scope-root "Slot Scope"))
           (svc (spawn ^planner-service (hashmap))))
      ($ svc 'add-scope! "s1" sr)
      (set! root-ref sr)
      svc)))

(with-vat vat
  (let ((svc svc-ref))
    (display "\n── a CAPACITY slot: declare-means with pattern + note + emoji ──\n")
    (let ((r ($ svc 'declare-means "s1" "alice" "spec-bike-repair" 4 "hours"
                "loc-courtyard" ARCS "I fix flats and brakes" "🚲" "bike repair")))
      (check "declared" (car r) 'ok))

    (display "\n── a NEED slot: declare-need (a standing order) ──\n")
    (let ((r ($ svc 'declare-need "s1" "alice" "spec-bread" 3 "loaf"
                "loc-pantry" ARCS "sourdough please" "🍞" #f #f "fresh bread")))
      (check "declared" (car r) 'ok))

    (display "\n── VF measures by kind: hours ride effort-quantity + 'use ──\n")
    ($ svc 'declare-need "s1" "alice" "spec-childcare" 6 "hours"
       "" "" "" "🧸" #f #f "childcare")
    (let* ((sl (cdr (plain-reply ($ svc 'my-slots "s1" "alice"))))
           (cc (find (lambda (n) (equal? (assq-ref n 'spec) "spec-childcare"))
                     (assq-ref sl 'needs))))
      (check "hours qty read from effort" (assq-ref cc 'qty) 6)
      (check "unit hours" (assq-ref cc 'unit) "hours"))
    ($ svc 'retire-need "s1" "alice" "spec-childcare")

    (display "\n── my-slots reads both back, arcs intact ──\n")
    (let* ((r  (plain-reply ($ svc 'my-slots "s1" "alice")))
           (sl (cdr r))
           (needs (assq-ref sl 'needs))
           (means (assq-ref sl 'means))
           (n0 (and (pair? needs) (car needs)))
           (m0 (and (pair? means) (car means))))
      (check "ok"                (car r) 'ok)
      (check "one need"          (length needs) 1)
      (check "one capacity"      (length means) 1)
      (check "need qty"          (assq-ref n0 'qty) 3)
      (check "need keeps the HUMAN name" (assq-ref n0 'name) "fresh bread")
      (check "need emoji rides image" (assq-ref n0 'emoji) "🍞")
      (check "need where"        (assq-ref n0 'where) "loc-pantry")
      (check "capacity note"     (assq-ref m0 'note) "I fix flats and brakes")
      (check "capacity keeps the HUMAN name" (assq-ref m0 'name) "bike repair")
      (check "arcs round-trip: two arcs" (length (assq-ref n0 'arcs)) 2)
      (check "arc 1 days"        (assq-ref (car (assq-ref n0 'arcs)) 'days)
             '("monday" "wednesday"))
      (check "arc 2 start"       (assq-ref (cadr (assq-ref n0 'arcs)) 'start) "18:00"))

    (display "\n── re-declaring IS editing (deterministic ids) ──\n")
    ($ svc 'declare-need "s1" "alice" "spec-bread" 5 "loaf" "loc-pantry" "" "" "🍞" #f #f "fresh bread")
    (let* ((sl (cdr (plain-reply ($ svc 'my-slots "s1" "alice"))))
           (n0 (car (assq-ref sl 'needs))))
      (check "still one need"    (length (assq-ref sl 'needs)) 1)
      (check "qty updated to 5"  (assq-ref n0 'qty) 5)
      (check "empty arcs ⇒ unconstrained" (assq-ref n0 'arcs) '()))

    (display "\n── our-slots: the fold's reading — cells, with my share joined ──\n")
    ($ svc 'declare-need "s1" "bob" "spec-bread" 2 "loaf" "loc-pantry" "" "" "🍞" #f #f "bread")
    (let* ((r  (plain-reply ($ svc 'our-slots "s1" "s1" "alice")))
           (sl (cdr r))
           (needs (assq-ref sl 'needs))
           (c (find (lambda (n) (equal? (assq-ref n 'spec) "spec-bread")) needs)))
      (check "ok"                     (car r) 'ok)
      (check "one cell for the spec"  (length (filter (lambda (n) (equal? (assq-ref n 'spec) "spec-bread")) needs)) 1)
      (check "the cell is the SUM"    (assq-ref c 'qty) 7)
      (check "of which mine"          (assq-ref c 'mine) 5)
      (check "the spec's unit"        (assq-ref c 'unit) "loaf")
      (check "the cell's place"       (assq-ref c 'where) "loc-pantry")
      (check "no one's name travels"  (assq-ref c 'who) #f))
    ($ svc 'retire-need "s1" "bob" "spec-bread")

    (display "\n── retire-need withdraws the standing order ──\n")
    ($ svc 'retire-need "s1" "alice" "spec-bread")
    (check "no needs left"
           (length (assq-ref (cdr (plain-reply ($ svc 'my-slots "s1" "alice"))) 'needs)) 0)

    (display "\n── another citizen's slots are separate ──\n")
    (check "bob has none"
           (length (assq-ref (cdr (plain-reply ($ svc 'my-slots "s1" "bob"))) 'means)) 0)

    ;; ── the ring: match-slots scores needs against declared means by
    ;; classification affinity over a folksonomy template. cats ride the
    ;; declare wire as JSON (the classify pass's terms), read back on the
    ;; slot rows, and two slots meet at their shared term; the time
    ;; dimension reads the real windows (a disjoint window vetoes).
    (display "\n── match-slots: affinity over the folksonomy cut ──\n")
    (define TREE
      '((id . "all") (label . "all") (count . 0)
        (children
         ((id . "nourishment") (label . "nourishment") (count . 2)
          (children
           ((id . "meals") (label . "meals") (count . 1) (children))
           ((id . "baking") (label . "baking") (count . 1) (children))))
         ((id . "movement") (label . "movement") (count . 1)
          (children
           ((id . "cycling") (label . "cycling") (count . 1) (children)))))))
    ($ svc 'declare-need "s1" "bob" "spec-bread" 2 "loaf" "" ARCS "" "🍞" #f #f
       "bread" "[\"baking\",\"nourishment\"]")
    ($ svc 'declare-means "s1" "carla" "spec-oven-bread" 6 "loaf" "" ARCS
       "wood-oven loaves" "🔥" "oven bread" "[\"baking\",\"nourishment\"]")
    ($ svc 'declare-means "s1" "dev" "spec-soup" 10 "portion" "" ""
       "" "🍲" "soup" "[\"meals\",\"nourishment\"]")
    (let* ((n (find (lambda (x) (equal? (assq-ref x 'spec) "spec-bread"))
                    (assq-ref (cdr (plain-reply ($ svc 'my-slots "s1" "bob"))) 'needs))))
      (check "cats ride the declare and read back on the row"
             (assq-ref n 'cats) '("baking" "nourishment")))
    (let* ((r  (plain-reply ($ svc 'match-slots "s1" TREE)))
           (v  (cdr r))
           (row (find (lambda (m) (equal? (assq-ref m 'need) "need:bob:spec-bread"))
                      (assq-ref v 'matches)))
           (hits (assq-ref row 'hits))
           (best (and (pair? hits) (car hits))))
      (check "ok" (car r) 'ok)
      (check "the means come with their owner"
             (assq-ref (find (lambda (m) (equal? (assq-ref m 'spec) "spec-soup"))
                             (assq-ref v 'means)) 'owner)
             "dev")
      (check "the shared-leaf oven bread is the best hit"
             (assq-ref best 'id) "means:carla:spec-oven-bread")
      (check "…meeting at its leaf term" (assq-ref best 'term) "baking")
      (check "…at distance 0" (assq-ref best 'distance) 0)
      (check "the soup meets one step up, via nourishment"
             (assq-ref (cadr hits) 'term) "nourishment")
      (check "…and scores below the leaf match"
             (< (assq-ref (cadr hits) 'score) (assq-ref best 'score)))
      (check "the bike repair (movement) is no match at all"
             (find (lambda (h) (equal? (assq-ref h 'id) "means:alice:spec-bike-repair"))
                   hits)
             #f))
    ;; a same-spec pair with a DISJOINT window: the floor matches, time vetoes
    ($ svc 'declare-means "s1" "erin" "spec-bread" 4 "loaf" ""
       "[{\"start\":\"06:00\",\"end\":\"07:00\",\"days\":[\"sunday\"]}]"
       "" "🍞" "sunday dawn bread" "")
    (let* ((v (cdr (plain-reply ($ svc 'match-slots "s1" TREE))))
           (row (find (lambda (m) (equal? (assq-ref m 'need) "need:bob:spec-bread"))
                      (assq-ref v 'matches))))
      (check "a same-spec offer whose window never overlaps is vetoed by time"
             (find (lambda (h) (equal? (assq-ref h 'id) "means:erin:spec-bread"))
                   (assq-ref row 'hits))
             #f))
    ;; an empty template still matches by spec identity (the floor)
    ($ svc 'declare-means "s1" "finn" "spec-bread" 4 "loaf" "" ARCS "" "🍞" "bread too" "")
    (let* ((v (cdr (plain-reply ($ svc 'match-slots "s1" '()))))
           (row (find (lambda (m) (equal? (assq-ref m 'need) "need:bob:spec-bread"))
                      (assq-ref v 'matches)))
           (h (find (lambda (h) (equal? (assq-ref h 'id) "means:finn:spec-bread"))
                    (assq-ref row 'hits))))
      (check "no folksonomy yet: the same-spec floor still matches"
             (and h (assq-ref h 'term)) "spec-bread"))

    ;; ── the criteria sidecar: <intent-matching-criteria> as one JSON object
    ;; on the declare wire, read back on the row, enforced by match-slots —
    ;; the eligibility rule bilaterally, divisibility as a size floor.
    (display "\n── criteria: the sidecar rides, reads back, and locks ──\n")
    ($ svc 'declare-need "s1" "bob" "spec-bread" 2 "loaf" "" ARCS "" "🍞" #f #f
       "bread" "[\"baking\",\"nourishment\"]"
       "{\"filter-rule\":[\"aid\",\"finn\"],\"min-atomic-size\":3,\"online-link\":\"\"}")
    (let* ((n (find (lambda (x) (equal? (assq-ref x 'spec) "spec-bread"))
                    (assq-ref (cdr (plain-reply ($ svc 'my-slots "s1" "bob"))) 'needs)))
           (c (assq-ref n 'criteria)))
      (check "the sidecar reads back on the need row" (and c #t) #t)
      (check "…its rule as an array" (assq-ref c 'filter-rule) (quote ("aid" "finn")))
      (check "…its size floor" (assq-ref c 'min-atomic-size) 3)
      (check "…blank fields dropped" (assq-ref c 'online-link) #f))
    (let* ((v (cdr (plain-reply ($ svc 'match-slots "s1" '()))))
           (row (find (lambda (m) (equal? (assq-ref m 'need) "need:bob:spec-bread"))
                      (assq-ref v 'matches)))
           (ids (map (lambda (h) (assq-ref h 'id)) (assq-ref row 'hits))))
      (check "the need's rule admits only finn's bread"
             (and (member "means:finn:spec-bread" ids)
                  (not (member "means:carla:spec-oven-bread" ids))
                  (not (member "means:erin:spec-bread" ids)))
             #t))
    ;; the offer's rule locks the other way
    ($ svc 'declare-need "s1" "bob" "spec-bread" 2 "loaf" "" ARCS "" "🍞" #f #f
       "bread" "[\"baking\",\"nourishment\"]" "")
    ($ svc 'declare-means "s1" "finn" "spec-bread" 4 "loaf" "" ARCS "" "🍞" "bread too" ""
       "{\"filter-rule\":[\"not-aid\",\"bob\"]}")
    (let* ((v (cdr (plain-reply ($ svc 'match-slots "s1" TREE))))
           (row (find (lambda (m) (equal? (assq-ref m 'need) "need:bob:spec-bread"))
                      (assq-ref v 'matches)))
           (ids (map (lambda (h) (assq-ref h 'id)) (assq-ref row 'hits))))
      (check "an offer's rule locks bob out, bilaterally"
             (member "means:finn:spec-bread" ids) #f)
      (check "…the others still meet him"
             (and (member "means:carla:spec-oven-bread" ids) #t) #t))
    ;; divisibility: a size floor above an offer's quantity is no match
    ($ svc 'declare-means "s1" "finn" "spec-bread" 4 "loaf" "" ARCS "" "🍞" "bread too" "" "")
    ($ svc 'declare-need "s1" "bob" "spec-bread" 2 "loaf" "" ARCS "" "🍞" #f #f
       "bread" "[\"baking\",\"nourishment\"]" "{\"min-atomic-size\":5}")
    (let* ((v (cdr (plain-reply ($ svc 'match-slots "s1" TREE))))
           (row (find (lambda (m) (equal? (assq-ref m 'need) "need:bob:spec-bread"))
                      (assq-ref v 'matches)))
           (ids (map (lambda (h) (assq-ref h 'id)) (assq-ref row 'hits))))
      (check "a smallest-useful-piece of 5 drops the 4-loaf offers"
             (member "means:finn:spec-bread" ids) #f)
      (check "…and keeps the 6-loaf one"
             (and (member "means:carla:spec-oven-bread" ids) #t) #t))
    ;; re-declaring without a sidecar clears it
    ($ svc 'declare-need "s1" "bob" "spec-bread" 2 "loaf" "" ARCS "" "🍞" #f #f "bread" "[\"baking\",\"nourishment\"]" "")
    (check "a re-declare without criteria clears the sidecar"
           (assq-ref (find (lambda (x) (equal? (assq-ref x 'spec) "spec-bread"))
                           (assq-ref (cdr (plain-reply ($ svc 'my-slots "s1" "bob"))) 'needs))
                     'criteria)
           #f)))

(with-vat vat
  (let ((svc svc-ref))
    ;; ── the arcs wire's week and month tiers: an arc may name weeks (1–5)
    ;; and months (1–12); the window is placed in the finest tier named, the
    ;; day tier always carries the union, and the wire reads the tiers back.
    (display "\n── arcs: week and month tiers ride the wire and read back ──\n")
    ($ svc 'declare-need "s1" "gia" "spec-firewood" 1 "m3" "" 
       "[{\"start\":\"09:00\",\"end\":\"12:00\",\"days\":[\"saturday\"],\"weeks\":[1,3],\"months\":[10,11,12]},{\"start\":\"18:00\",\"end\":\"20:00\",\"days\":[\"friday\"]}]"
       "" "🪵" #f #f "firewood" "" "")
    (let* ((n (find (lambda (x) (equal? (assq-ref x 'spec) "spec-firewood"))
                    (assq-ref (cdr (plain-reply ($ svc 'my-slots "s1" "gia"))) 'needs)))
           (arcs (assq-ref n 'arcs))
           (a1 (find (lambda (a) (equal? (assq-ref a 'start) "09:00")) arcs))
           (a2 (find (lambda (a) (equal? (assq-ref a 'start) "18:00")) arcs)))
      (check "two arcs read back" (length arcs) 2)
      (check "the tiered arc keeps its weeks" (assq-ref a1 'weeks) '(1 3))
      (check "…and its months" (assq-ref a1 'months) '(10 11 12))
      (check "…and its days" (assq-ref a1 'days) '("saturday"))
      (check "the plain arc reads back without tiers"
             (and (not (assq-ref a2 'weeks)) (not (assq-ref a2 'months))) #t))
    ;; weeks alone: the week tier
    ($ svc 'declare-need "s1" "gia" "spec-firewood" 1 "m3" ""
       "[{\"start\":\"09:00\",\"end\":\"12:00\",\"days\":[\"saturday\"],\"weeks\":[2,4]}]"
       "" "🪵" #f #f "firewood" "" "")
    (let* ((n (find (lambda (x) (equal? (assq-ref x 'spec) "spec-firewood"))
                    (assq-ref (cdr (plain-reply ($ svc 'my-slots "s1" "gia"))) 'needs)))
           (a (car (assq-ref n 'arcs))))
      (check "weeks alone read back" (assq-ref a 'weeks) '(2 4))
      (check "…with no months" (assq-ref a 'months) #f))
    ($ svc 'retire-need "s1" "gia" "spec-firewood")

    ;; ── a new place by name: a <spatial-thing> in the scope, its id back ──
    (display "\n── declare-place: a citizen names a place ──\n")
    (let ((r ($ svc 'declare-place "s1" "gia" "The old mill" 52.5 13.4)))
      (check "ok" (car r) 'ok)
      (check "deterministic id, namer + slug" (assq-ref (cdr r) 'id) "place:gia:the-old-mill"))
    (check "a nameless place is refused"
           (car ($ svc 'declare-place "s1" "gia" "  " 0 0)) 'error)

    ;; the address — theirs is five mailing-address fields (street/city/state/
    ;; postal/country); ours is the one string <spatial-thing> already carries
    ;; (mappable-address), an optional trailing arg on declare-place
    (display "\n── declare-place: the address rides mappable-address ──\n")
    ($ svc 'declare-place "s1" "gia" "The bakery" 0 0 "12 Bread St, Sofia")
    (let ((st ($ ($ root-ref 'spatial-thing-store) 'get-location "place:gia:the-bakery")))
      (check "the address is kept" (spatial-thing-mappable-address st) "12 Bread St, Sofia")
      (check "no coordinates given, none stored" (spatial-thing-lat st) #f))

    ;; ── ⭐ a capacity's priority-distribution: per-person weights that
    ;; re-rank its matches — the recipient it names first ranks first
    (display "\n── ⭐ priority-distribution re-ranks an offer's matches ──\n")
    (define TREE2 '((id . "all") (label . "all") (count . 0)
                    (children ((id . "wood") (label . "wood") (count . 1) (children)))))
    ($ svc 'declare-need "s1" "hal" "spec-logs" 1 "m3" "" "" "" "🪵" #f #f "logs" "[\"wood\"]" "")
    ($ svc 'declare-need "s1" "ida" "spec-logs" 1 "m3" "" "" "" "🪵" #f #f "logs" "[\"wood\"]" "")
    ($ svc 'declare-means "s1" "jon" "spec-logs" 5 "m3" "" "" "" "🪵" "logs" "[\"wood\"]"
       "{\"priority-distribution\":{\"ida\":1.0,\"hal\":0.4}}")
    (let* ((v (cdr (plain-reply ($ svc 'match-slots "s1" TREE2))))
           (score-of (lambda (need)
                       (let* ((row (find (lambda (m) (equal? (assq-ref m 'need) need)) (assq-ref v 'matches)))
                              (h (find (lambda (h) (equal? (assq-ref h 'id) "means:jon:spec-logs")) (assq-ref row 'hits))))
                         (and h (assq-ref h 'score))))))
      (check "the favoured recipient scores higher"
             (> (score-of "need:ida:spec-logs") (score-of "need:hal:spec-logs")) #t)
      (check "the sidecar reads back on the means row"
             (and (assq-ref (find (lambda (m) (equal? (assq-ref m 'id) "means:jon:spec-logs"))
                                  (assq-ref (cdr (plain-reply ($ svc 'my-slots "s1" "jon"))) 'means))
                            'criteria) #t)
             #t))))

(with-vat vat
  (let ((svc svc-ref))
    ;; ── the rule's context reads recognition (my contact book) and distance
    ;; (the two places' coordinates) — a min-recognition lock admits contacts
    ;; only; a within-km lock admits the near and denies the far
    (display "\n── 🔒 recognition and distance in the ring's context ──\n")
    (define T3 '((id . "all") (label . "all") (count . 0)
                 (children ((id . "eggs") (label . "eggs") (count . 1) (children)))))
    ($ svc 'declare-place "s1" "kim" "Kim's yard" 52.50 13.40)
    ($ svc 'declare-place "s1" "lou" "Lou's farm" 52.51 13.41)      ; ~1.3 km off
    ($ svc 'declare-place "s1" "max" "Max's field" 53.50 13.40)     ; ~111 km off
    ($ svc 'declare-need "s1" "kim" "spec-eggs" 6 "each" "place:kim:kim-s-yard" "" "" "🥚" #f #f
       "eggs" "[\"eggs\"]" "{\"filter-rule\":[\"min-recognition\",0.5]}")
    ($ svc 'declare-means "s1" "lou" "spec-eggs" 12 "each" "place:lou:lou-s-farm" "" "" "🥚" "eggs" "[\"eggs\"]")
    ($ svc 'declare-means "s1" "max" "spec-eggs" 12 "each" "place:max:max-s-field" "" "" "🥚" "eggs" "[\"eggs\"]")
    (define (hits-for need)
      (let* ((v (cdr (plain-reply ($ svc 'match-slots "s1" T3))))
             (row (find (lambda (m) (equal? (assq-ref m 'need) need)) (assq-ref v 'matches))))
        (map (lambda (h) (assq-ref h 'id)) (assq-ref row 'hits))))
    (check "min-recognition with no contacts admits nobody" (hits-for "need:kim:spec-eggs") '())
    ($ ($ root-ref 'agent-store) 'add-relationship
       (make-agent-relationship #:id "rel-kim-lou" #:subject "kim" #:object "lou"
                                #:relationship "contact"))
    (check "…and admits a contact once the book names them"
           (hits-for "need:kim:spec-eggs") '("means:lou:spec-eggs"))
    ($ svc 'declare-need "s1" "kim" "spec-eggs" 6 "each" "place:kim:kim-s-yard" "" "" "🥚" #f #f
       "eggs" "[\"eggs\"]" "{\"filter-rule\":[\"within-km\",10]}")
    (check "within-km admits the near offer and denies the far one"
           (hits-for "need:kim:spec-eggs") '("means:lou:spec-eggs"))
    ($ svc 'retire-need "s1" "kim" "spec-eggs")))

;; ── the constitution's gate: a kind beyond a want is the scope's statement ──
;; A bare declare states a want; `held` and `floor` pass declare-need only
;; against the scope's ratified-kinds grants (truth-telling.md, stage 1). The
;; ratifier is named on the grant; a floor grant also covers held; "des"
;; withdraws.
(with-vat vat
  (let* ((svc svc-ref)
         (held-r (lambda (who) ($ svc 'declare-need "s1" who "spec-insulin" 1 "each" "" "" "" "💉" #f #f
                                  "insulin" "" "" "held" 100))))
    (display "\n── ratified kinds: the gate in declare-need ──\n")
    (check "a want needs no ratification"
           (car ($ svc 'declare-need "s1" "ada" "spec-insulin" 1 "each" "" "" "" "💉" #f #f "insulin")) 'ok)
    (check "an unratified held need is refused" (car (held-r "ada")) 'error)
    (check "…naming the rite"
           (and (string-contains (cdr (held-r "ada")) "ratify-kind") #t) #t)
    (check "the scope ratifies the spec as held" (car ($ svc 'ratify-kind "s1" "ben" "spec-insulin" "held")) 'ok)
    (check "…and the held need now declares" (car (held-r "ada")) 'ok)
    (let ((g (car (assq-ref (cdr ($ svc 'ratified-kinds "s1")) 'grants))))
      (check "the grant names the spec, the kind and the ratifier"
             (list (assq-ref g 'spec) (assq-ref g 'kind) (assq-ref g 'by))
             '("spec-insulin" "held" "ben")))
    (check "a held grant does not cover a floor"
           (car ($ svc 'declare-need "s1" "ada" "spec-insulin" 1 "each" "" "" "" "💉" #f #f
                   "insulin" "" "" "floor")) 'error)
    ($ svc 'ratify-kind "s1" "ben" "spec-insulin" "floor")
    (check "a floor grant covers the floor"
           (car ($ svc 'declare-need "s1" "ada" "spec-insulin" 1 "each" "" "" "" "💉" #f #f
                   "insulin" "" "" "floor")) 'ok)
    (check "…and the held need beneath it" (car (held-r "ada")) 'ok)
    ($ svc 'ratify-kind "s1" "ben" "spec-insulin" "des")
    (check "ratifying as a want withdraws the grant"
           (assq-ref (cdr ($ svc 'ratified-kinds "s1")) 'grants) '())
    (check "…and the held need is refused again" (car (held-r "ada")) 'error)
    ($ svc 'retire-need "s1" "ada" "spec-insulin")))

;; ── stage 3: needs are facts — a held row is audited against the log ──
;; Ada's held insulin (declared 1) is ratified; the observer has seen her
;; take none since the grant ⇒ padded, and the grant is withdrawn through
;; the ratification door. Ratified again, with a consume event on the log
;; ⇒ confirmed. The unmeasured gain (no burn history) audits every row.
(with-vat vat
  (let* ((svc svc-ref) (root root-ref) (obs ($ root 'observer))
         (held! (lambda () ($ svc 'declare-need "s1" "ada" "spec-insulin" 1 "each" "" "" "" "💉" #f #f
                              "insulin" "" "" "held" 100)))
         (grants (lambda () (assq-ref (cdr ($ svc 'ratified-kinds "s1")) 'grants))))
    (display "\n── stage 3: the audit of a ratified kind ──\n")
    ($ svc 'ratify-kind "s1" "ben" "spec-insulin" "held")
    (check "the held row declares" (car (held!)) 'ok)
    (let ((r (cdr ($ svc 'audit-kinds "s1" "cy"))))
      (check "one row examined (unmeasured gain ⇒ π = 1)" (assq-ref r 'examined) 1)
      (check "nothing taken since the grant ⇒ padded" (assq-ref r 'padded) 1)
      (check "the finding names the row, the verdict and the auditor"
             (let ((f (car (assq-ref r 'findings))))
               (list (assq-ref f 'spec) (assq-ref f 'who) (assq-ref f 'verdict) (assq-ref f 'by)))
             '("spec-insulin" "ada" "padded" "cy")))
    (check "…and the grant is withdrawn" (grants) '())
    (check "the record keeps the finding" (length (assq-ref (cdr ($ svc 'audits "s1")) 'findings)) 1)
    ;; ratified again; this time the log shows her taking it
    ($ svc 'ratify-kind "s1" "ben" "spec-insulin" "held")
    ($ obs 'record-event
       (make-economic-event #:id "ev-ins-1" #:action 'consume #:resource-conforms-to "spec-insulin" #:provider "ada"
                            #:resource-quantity (make-measure 1 "each") #:has-point-in-time "2099-01-01T08:00:00Z"))
    (let ((r (cdr ($ svc 'audit-kinds "s1" "cy"))))
      (check "taken as declared ⇒ confirmed" (assq-ref r 'padded) 0)
      (check "the confirmed row's observed quantity is on the finding"
             (assq-ref (car (assq-ref r 'findings)) 'observed) 1.0))
    (check "…and the grant stands" (length (grants)) 1)
    (check "the record now holds both audits" (length (assq-ref (cdr ($ svc 'audits "s1")) 'findings)) 2)
    (check "a consequence factor of 4 examines a quarter of rows on average — here the draw decides"
           (let ((r (cdr ($ svc 'audit-kinds "s1" "cy" '((consequence-factor . 4))))))
             (and (memv (assq-ref r 'examined) '(0 1)) #t)) #t)
    ($ svc 'retire-need "s1" "ada" "spec-insulin")))

;; ── the burn-meter reads the demand a solve RAN ON, at its own duals ──
;; Both come off the landed alist: `demand` (the fold's wants, keyed
;; "spec#place@t") and the duals. A stub plan-fn hands the service exactly
;; that; the history and the ⚖️ chip's `lately` read the same record.
(with-vat vat
  (let* ((sr   (spawn-scope-root "Meter"))
         (stub (lambda (root sid . kw)
                 `((met . 1.0) (work . ()) (social . ())
                   (material . (((action . produce) (conforms-to . "bread~ada") (quantity . 4.0))))
                   (certificate . ((sigma . 0.5) (residual . 0.1)))
                   (demand . (("bread#hearth@0" . 3.0) ("bread#hearth@1" . 1.0)
                              ("lamp#hearth@0" . 2.0)))          ; lamp: no dual → nothing to displace
                   (good-pulls . (("bread#hearth@0" . 2.5))))))
         (svc  (spawn ^planner-service (hashmap) stub)))
    ($ svc 'add-scope! "m" sr)
    (display "\n── the burn-meter: the ran-on demand at the solve's duals ──\n")
    (check "before any solve the history is empty"
           (assq-ref (cdr ($ svc 'externality-history "m")) 'solves) 0)
    (check "a solve lands" (car ($ svc 'solve "m" '())) 'ok)
    (let* ((h (cdr ($ svc 'externality-history "m")))
           (b (find (lambda (r) (equal? (assq-ref r 'spec) "bread")) (assq-ref h 'specs))))
      (check "one solve noted" (assq-ref h 'solves) 1)
      (check "bread summed across its cells: 4 units × μ 2.5 moved"
             (assq-ref b 'mean-moved) 10.0)
      (check "a spec the plan holds no pull for is not a row"
             (find (lambda (r) (equal? (assq-ref r 'spec) "lamp")) (assq-ref h 'specs)) #f))
    (let ((p (cdr ($ svc 'need-displacement "m" "bread" 2))))
      (check "need-displacement carries the same lately"
             (list (assq-ref p 'per-unit) (assq-ref (assq-ref p 'lately) 'solves)
                   (assq-ref (assq-ref p 'lately) 'mean-moved))
             '(2.5 1 10.0))
      ;; the certificate states its own manipulation bound: 2W/σ at one hand
      (check "…and the honesty radius off the certificate's modulus"
             (assq-ref (assq-ref p 'honesty) 'radius-whole-hand) (/ (* 2.0 1000) 0.5))
      ;; ‖r‖/σ: how far a solved-to-tolerance point can sit from the exact
      ;; optimum, in the same σ that sizes the radius above
      (check "…and the solve's own tolerance, ‖r‖/σ"
             (assq-ref (assq-ref p 'honesty) 'solve-tolerance) (/ 0.1 0.5))
      ;; L_Φ at the catalogue's default scale (1.0, unstated) is exactly 1 —
      ;; the shown radius needed no correction all along at the default
      (check "…and L_Φ is exactly 1 at the default reference scale"
             (assq-ref (assq-ref p 'honesty) 'l-phi) 1.0))
    ;; a governed reference scale away from 1.0 rescales the radius by
    ;; its exact reciprocal — the correction the audit found missing
    (set-cap-scale! "bread" 4.0)
    (let ((p (cdr ($ svc 'need-displacement "m" "bread" 2))))
      (check "…and a non-default cap scale corrects L_Φ exactly"
             (assq-ref (assq-ref p 'honesty) 'l-phi) 0.25)
      (check "…and the radius scales by that same exact factor"
             (assq-ref (assq-ref p 'honesty) 'radius-whole-hand)
             (/ (* 2.0 0.25 1000) 0.5)))
    (set-cap-scale! "bread" #f)
    ($ svc 'solve "m" '())
    (check "each landing is one record"
           (assq-ref (cdr ($ svc 'externality-history "m")) 'solves) 2)
    ;; the conduit pass rides audit-kinds: the stub's landed solve delivered
    ;; 4 bread to ada's own good and the log shows her taking none — the
    ;; pad-and-gift signature, recorded, with no grant to withdraw
    (let ((r (cdr ($ svc 'audit-kinds "m" "cy"))))
      (check "a delivery far above consumption is a conduit finding"
             (let ((f (find (lambda (f) (equal? (assq-ref f 'verdict) "conduit"))
                            (assq-ref r 'findings))))
               (and f (list (assq-ref f 'spec) (assq-ref f 'who))))
             '("bread" "ada")))))

;; ── the pool is LIVE: pool-of answers slots-at, and its watchers hear moves ──
;; The means side of slots-at is what the injected pool-of derives right now
;; (governance's custody projection in prod, a stub here); a solve only lends
;; each row its `drawn`. Every writer of the pool wakes the scope's watchers.
(define heard '())
(with-vat vat
  (let* ((sr   (spawn-scope-root "Live Pool"))
         (rows (list '((id . "res:oven") (spec . "spec-oven") (qty . 1) (unit . "each")
                       (kind . "use") (where . "kitchen") (owner . "ann"))))
         (svc  (spawn ^planner-service (hashmap) plain-plan-fn #f (list (cons 'pool (lambda (root sid) rows)))))
         (ear  (spawn (lambda (_bcom)
                        (methods ((slots-changed sid) (set! heard (cons sid heard)) #t))))))
    ($ svc 'add-scope! "live" sr)
    (display "\n── the live pool: pool-of feeds slots-at, watchers hear every move ──\n")
    (let ((pool (cdr (plain-reply ($ svc 'slots-at "live")))))
      (check "the means are pool-of's rows, without any solve"
             (assq-ref (car (assq-ref pool 'means)) 'id) "res:oven")
      (check "…each stamped drawn 0 until a solve says otherwise"
             (assq-ref (car (assq-ref pool 'means)) 'drawn) 0.0))
    ($ svc 'slots-watch "live" ear)
    ($ svc 'declare-need "live" "kim" "spec-bread" 2 "each" "" "" "" "🍞" #f #f "bread")
    ($ svc 'declare-means "live" "lou" "spec-flour" 1 "kg" "")
    ($ svc 'retire-need "live" "kim" "spec-bread")
    ($ svc 'slots-changed! "live")))
(usleep 200000)
(check "a need declared, a means declared, a need retired, a grant door poked: four wakes"
       (length heard) 4)
(check "…each naming the scope that moved" (delete-duplicates heard) '("live"))

(display "\n")
(test-summary!)
