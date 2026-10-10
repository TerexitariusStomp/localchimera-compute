;;; test-law-snapshot-build.scm — the program is a reading of a place.
;;;
;;; The law face shows what the law asks HERE: the demands in force at a place
;;; and up its chain, the ways that trip each, and how each structural demand
;;; stands there. All of it is derived by law/snapshot-build.scm, and the browser
;;; draws what it is handed — so a wrong answer here is a wrong answer on screen
;;; with nothing downstream to catch it.
;;;
;;; The properties below hold for any rule library and any set of readings; none
;;; pins a count the packs will outgrow.
;;;
;;; Run: guile -L module tests/planner/test-law-snapshot-build.scm

(use-modules (playnet test harness)
             (playnet legal registry)
             (playnet legal reform)
             (playnet vf facts places)
             (playnet knowledge law context-pack)
             (playnet knowledge law reform-mirrors)
             (playnet knowledge law aspects)
             (playnet knowledge law structural-demands)
             (playnet knowledge law incumbent-readings)
             (playnet knowledge law protections)
             (playnet knowledge worlds free-food-distribution)
             (playnet knowledge law activities)
             (playnet knowledge law snapshot-build)
             (srfi srfi-1) (srfi srfi-13) (ice-9 format))

(define zoning "Zoning compliance / use permit")
(define church "Separate church from state")
(define entries (reform-program-entries))
(define (entry name) (find (lambda (e) (equal? name (car e))) entries))
(define (entry-places e) (list-ref e 2))
(define (entry-border? e) (list-ref e 5))
(define (program-names place) (map car (place-program place)))
(define places (snapshot-place-ids))

(display "\n── a guard's places are the ones it reaches ──\n")
(check-pred "a negated jurisdiction is left out of a guard's places"
            (equal? '("us")
                    (guard-places '(all-of (in-jurisdiction "us") (on-crossing land-use)
                                           (negate (any-of (in-jurisdiction "us-06")
                                                           (in-jurisdiction "us-41")))))))
(check-pred "a permit is listed for the places its rule reaches, and for no place that derogates from it"
            (let ((derogating (append-map (lambda (r) (if (member zoning (legal-rule-cancels r))
                                                          (guard-places (legal-rule-guard-form r))
                                                          '()))
                                          *pack-rules*)))
              (and (member "us" (entry-places (entry zoning)))
                   (pair? derogating)
                   (null? (lset-intersection equal? (entry-places (entry zoning)) derogating)))))

(display "\n── the program of a place ──\n")
(check-pred "a state that eased its zoning carries no zoning permit; its neighbour does"
            (and (not (member zoning (program-names "us-06")))
                 (member zoning (program-names "us-32"))
                 #t))
(check-pred "every spec-bearing demand a mode's bill carries at a place is in that place's program"
            (every (lambda (place)
                     (every (lambda (a)
                              (every (lambda (m)
                                       (call-with-values (lambda () (mode-bill place m))
                                         (lambda (bill hits)
                                           (every (lambda (d) (member (demand-name d) (program-names place)))
                                                  (bill-mirrored bill)))))
                                     (activity-modes a)))
                            *activities*))
                   places))
(check-pred "…and every demand in a place's program is an entry of the whole program"
            (every (lambda (place) (every entry (program-names place))) places))
(check-pred "the level that imposes a demand is the place, one of its ancestors, or a regime it stands in"
            (every (lambda (place)
                     (let ((path (apply append (place-endpoints place))))
                       (every (lambda (row) (or (not (caddr row)) (member (caddr row) path)))
                              (place-program place))))
                   places))
(check-pred "a place inherits its nation's demands"
            (every (lambda (name) (member name (program-names "us-56-laramie")))
                   (filter (lambda (name) (equal? "us" (caddr (assoc name (place-program "us")))))
                           (lset-intersection equal? (program-names "us") (program-names "us-56")))))

(display "\n── ways nobody has modelled, and the border ──\n")
(define fridge "Registrierung der Verteilstation")
(check-pred "a demand that turns on a channel no mode states is in force where its rule reaches, with no way listed"
            (let ((row (assoc fridge (place-program "berlin"))))
              (and row (null? (cadr row)) (equal? "berlin" (caddr row)))))
(check-pred "…and stays out of the program of the nation above it"
            (not (member fridge (program-names "germany"))))
(check-pred "a demand of the border is marked so, and sits in no place's program"
            (let ((border (filter entry-border? entries)))
              (and (pair? border)
                   (every (lambda (e)
                            (not (any (lambda (place) (member (car e) (program-names place))) places)))
                          border))))
(check-pred "a demand some mode trips names its activity"
            (every (lambda (e)
                     (or (entry-border? e)
                         (null? (program-links (car e)))
                         (every (lambda (link) (activity-ref (car link))) (program-links (car e)))))
                   entries))

(display "\n── a place's reading of a structural demand ──\n")
(define (status-at place name)
  (let ((demand (find (lambda (d) (equal? name (assq-ref d 'name))) *structural-demands*)))
    (assq-ref (reading-standing (incumbent-at place name) (assq-ref demand 'mirror)) 'status)))
(check-pred "every place resolves a reading of every demand by the one walk"
            (every (lambda (place)
                     (every (lambda (d) (incumbent-at place (assq-ref d 'name))) *structural-demands*))
                   places))
(check-pred "the reading a place reaches at the root is the general case: the whole incumbent"
            (let ((general (incumbent-at "france" "Retire rent")))
              (and (reading-general? general)
                   (lset= eq? (reading-in-force general)
                          (spec-mirror-legal
                           (assq-ref (find (lambda (d) (equal? "Retire rent" (assq-ref d 'name)))
                                           *structural-demands*)
                                     'mirror))))))
(check-pred "two nations with different histories stand differently on the same demand"
            (not (eq? (status-at "france" church) (status-at "germany" church))))
(place! "fr-99999" "A commune, synthetic for this check" "france" #:kind 'locality)
(check-pred "a place inherits the nearest reading up its chain"
            (eq? (incumbent-at "fr-99999" church) (incumbent-at "france" church)))
(check-pred "a demand nobody has read in a place is unread there"
            (eq? 'unread (status-at "france" "Retire rent")))
(check-pred "a place nobody has read is unread"
            (eq? 'unread (status-at "biosphere" church)))

(define mirror (assq-ref (find (lambda (d) (equal? church (assq-ref d 'name))) *structural-demands*)
                         'mirror))
(define shell (lset-difference eq? (spec-mirror-legal mirror) (spec-mirror-desired mirror)))
(define (standing-of in-force)
  (reading-standing `((place . "france") (demand . ,church) (in-force . ,in-force)) mirror))
(check-pred "won and standing tile the coercive shell"
            (every (lambda (in-force)
                     (let ((st (standing-of in-force)))
                       (and (null? (lset-intersection eq? (assq-ref st 'won) (assq-ref st 'standing)))
                            (lset= eq? shell (append (assq-ref st 'won) (assq-ref st 'standing))))))
                   (list '() (spec-mirror-desired mirror) (spec-mirror-legal mirror)
                         (cons (car shell) (spec-mirror-desired mirror)))))
(check-pred "the whole shell shed is won; the whole shell in force is standing; between them, partly"
            (and (eq? 'won (assq-ref (standing-of (spec-mirror-desired mirror)) 'status))
                 (eq? 'standing (assq-ref (standing-of (spec-mirror-legal mirror)) 'status))
                 (eq? 'partly (assq-ref (standing-of (cons (car shell) (spec-mirror-desired mirror)))
                                        'status))))
(check-pred "a region that reads itself differs from its nation, and the nation's reading stands elsewhere"
            (and (not (eq? (incumbent-at "berlin" church) (incumbent-at "germany" church)))
                 (not (eq? (status-at "berlin" church) (status-at "germany" church)))
                 (eq? (incumbent-at "brandenburg" church) (incumbent-at "germany" church))))
(register-incumbent-reading!
 `((place . "brandenburg") (demand . ,church) (in-force . ,(spec-mirror-desired mirror))
   (source . "a reading registered by this test") (confidence . uncertain)))
(check-pred "a reading registered on a region is found there before its nation's"
            (eq? 'won (status-at "brandenburg" church)))

(display "\n── a reading that reads nothing is said so ──\n")
(define (problems reading) (reading-problems reading *structural-demands*))
(check-pred "the shipped readings are clean"
            (every (lambda (r) (null? (problems r)))
                   (filter (lambda (r) (not (equal? "brandenburg" (reading-place r))))
                           (all-incumbent-readings))))
(check-pred "a clause the demand's incumbent never had is a problem"
            (pair? (problems `((place . "france") (demand . ,church) (in-force armed-patrol)
                               (source . "x") (confidence . reported)))))
(check-pred "…and so is a demand nobody states, a place nobody places, and a reading with no source"
            (and (pair? (problems `((place . "france") (demand . "Repeal gravity") (in-force)
                                    (source . "x"))))
                 (pair? (problems `((place . "atlantide") (demand . ,church) (in-force)
                                    (source . "x"))))
                 (pair? (problems `((place . "france") (demand . ,church) (in-force))))))

(display "\n── a clause enters the diff when it is mapped ──\n")
(define (reform-of spec) (demand-reform (obtain #:rides 'entity #:name "x" #:spec spec)))
(define (cells entry)
  (append-map (lambda (k) (or (assq-ref entry k) '()))
              '(redundant absorb-first reproduce-unwanted transform-law)))
(check-pred "a clause nobody has mapped is reported unmapped and sits in none of the four cells"
            (let ((e (reform-of '(fire-safety a-clause-nobody-maps))))
              (and (equal? '(a-clause-nobody-maps) (assq-ref e 'unmapped))
                   (not (memq 'a-clause-nobody-maps (cells e)))
                   (memq 'fire-safety (cells e)))))
(register-clause-aspect! 'brandschutz 'fire-safety)
(check-pred "the words are one vocabulary: a word keeps its first aspect, and an aspect's id names only itself"
            (and (not (register-clause-aspect! 'brandschutz 'habitability))
                 (eq? 'fire-safety (clause-aspect 'brandschutz))
                 (not (register-clause-aspect! 'fire-safety 'habitability))
                 (eq? 'fire-safety (clause-aspect 'fire-safety))
                 (register-clause-aspect! 'brandschutz 'fire-safety)))
(check-pred "a law's own word for an aspect lands in the cell the aspect lands in"
            (let ((own (reform-of '(brandschutz))) (ours (reform-of '(fire-safety))))
              (and (null? (assq-ref own 'unmapped))
                   (every (lambda (k) (= (length (or (assq-ref own k) '())) (length (or (assq-ref ours k) '()))))
                          '(redundant absorb-first reproduce-unwanted transform-law)))))
(check-pred "every clause of every rule is in exactly one of the four cells or unmapped"
            (every (lambda (r)
                     (every (lambda (d)
                              (let ((e (demand-reform d)))
                                (or (not e)
                                    (lset= eq? (demand-spec d)
                                           (append (assq-ref e 'unmapped) (cells e))))))
                            (legal-rule-demands r)))
                   *pack-rules*))
(check-pred "a demand written wholly in unmapped words has nothing to press yet: its move is keep"
            (eq? 'keep (reform-move (demand-reform (obtain #:rides 'entity #:name "x" #:spec '(a-clause-nobody-maps))))))

(display "\n── a demand's move is read off the cells ──\n")
(define (reading-json r) (reading->json r))
(define social "Recognize social property")
(define social-mirror (assq-ref (find (lambda (d) (equal? social (assq-ref d 'name))) *structural-demands*) 'mirror))
(define (entry-of in-force)
  (assq-ref (reading-standing `((place . "france") (demand . ,social) (in-force . ,in-force)) social-mirror) 'entry))
(define (move-of e) (reform-move e))
(check-pred "something we want that no way performs yet is to build first"
            (eq? 'absorb (move-of (entry-of (spec-mirror-legal social-mirror)))))
(check-pred "a reading that leaves that function out leaves nothing to build: all we want is provided"
            (eq? 'wither (move-of (entry-of (delete 'dispute-title (spec-mirror-legal social-mirror))))))
(check-pred "with nothing in force there is nothing to press"
            (eq? 'keep (move-of (entry-of '()))))
(check-pred "only the shell left is to be changed, not built or withered"
            (eq? 'transform (move-of '((redundant) (absorb-first) (reproduce-unwanted) (transform-law shell-clause)))))
(check-pred "a reading's json carries its move, and nothing carries a score"
            (let ((json (law-snapshot-string)))
              (and (string-contains (reading-json (incumbent-at "world" social)) "\"move\":\"absorb\"")
                   (not (string-contains json "dualPower")) (not (string-contains json "trackRecord"))
                   (not (string-contains json "readiness")))))
(check-pred "the program lists the move we can make first, then by name"
            (let ((ranks (map (lambda (e) (move-rank (cadr e))) entries)))
              (equal? ranks (sort ranks <))))

(display "\n── what the federation does is what its members' ways perform ──\n")
(check-pred "the actual practice is the union of what the members' pathways perform"
            (lset= eq? (actual-aspects)
                   (delete-duplicates
                    (append-map (lambda (m) (assq-ref (ffd-recipe-ref (assq-ref m 'recipe)) 'performs))
                                (ffd-member-list)))))
(check-pred "a way performs federation aspects, and nothing else"
            (every (lambda (a) (every (lambda (m) (every legal-aspect? (assq-ref m 'performs)))
                                      (activity-modes a)))
                   *activities*))
(check-pred "a wanted function no running way performs is to build; a practised shell is borne"
            (let ((unpractised (find (lambda (a) (and (not (practised? a)) (not (aspect-shell? a))))
                                     *food-housing-ids*))
                  (borne (find (lambda (a) (and (practised? a) (aspect-shell? a))) *food-housing-ids*)))
              (and unpractised
                   (equal? (list unpractised) (assq-ref (reform-of (list unpractised)) 'absorb-first))
                   (or (not borne)
                       (equal? (list borne) (assq-ref (reform-of (list borne)) 'reproduce-unwanted))))))

(display "\n── a derogation removes what it names, where it reaches ──\n")
(check-pred "a rule that derogates states it as cancels, and the bill at its place drops the demand"
            (every (lambda (r)
                     (every (lambda (name)
                              (every (lambda (place)
                                       (not (member name (program-names place))))
                                     (lset-intersection equal? places
                                                        (guard-places (legal-rule-guard-form r)))))
                            (legal-rule-cancels r)))
                   (filter (lambda (r) (pair? (legal-rule-cancels r))) *pack-rules*)))
(check-pred "the builder folds the rules it is handed"
            (let* ((own (rule '(all-of (in-jurisdiction "mexico") (on-crossing share-food))
                              (list (obtain #:rides 'entity #:name "A permit this test registers"
                                            #:spec '(fire-safety)))
                              #:label "test/own-rule"))
                   (with (law-snapshot-string #:rules (rules-with (list own own)))))
              (and (string-contains with "A permit this test registers")
                   (not (string-contains (law-snapshot-string) "A permit this test registers"))
                   (= (length (rules-with (list own own))) (+ 1 (length *pack-rules*)))
                   (= (length (rules-with *pack-rules*)) (length *pack-rules*)))))

(display "\n── the law is the packs ──\n")
(check-pred "every rule the fold reads came off a pack on disk"
            (and (eq? (current-legal-rules) *pack-rules*)
                 (= (length *pack-rules*)
                    (apply + (map (lambda (p) (length (pack-section (read-pack p) 'rules)))
                                  (pack-paths %contexts-dir))))))
(check-pred "a place stands under its own protections and those of every place that contains it"
            (every (lambda (place)
                     (let ((path (jurisdiction-path place place-parent-of)))
                       (lset= eq? (protections-at place)
                              (filter (lambda (p) (member (protection-place p) path))
                                      (all-protections)))))
                   places))
(check-pred "a protection names its activity and cites its source"
            (and (pair? (all-protections))
                 (every (lambda (p) (null? (protection-problems p))) (all-protections))
                 (pair? (protection-problems '((place . "atlantide") (name . "x"))))))

(display "\n── one reader of a guard, one reader of a pack ──\n")
(define form '(all-of (in-jurisdiction "us") (on-crossing land-use)
                      (negate (any-of (in-jurisdiction "us-06") (on-crossing border)))))
(check-pred "what a guard keys on stays outside a negate; what it names includes it"
            (and (equal? '("us") (guard-atoms 'in-jurisdiction form))
                 (equal? '("us" "us-06") (guard-atoms 'in-jurisdiction form #:negated? #t))
                 (equal? '(land-use border) (guard-atoms 'on-crossing form #:negated? #t))))
(check-pred "a bare rule list reads as a pack with the one section"
            (let* ((dir (string-append (or (getenv "TMPDIR") "/tmp") "/law-pack-" (number->string (getpid))))
                   (rules (list (rule '(on-crossing x) (list (forbid #:reason "r")) #:label "t"))))
              (save-rule-pack dir rules)
              (let ((pack (read-pack dir)))
                (delete-file dir)
                (and (= 1 (length (pack-section pack 'rules)))
                     (null? (pack-section pack 'places))
                     (null? (pack-section pack 'readings))))))
(check-pred "a place that stands within a regime is folded under the regime's rules"
            (every (lambda (place)
                     (let ((eps (place-endpoints place)))
                       (and (equal? (car eps) (jurisdiction-path place place-parent-of))
                            (every (lambda (w) (any (lambda (path) (member w path)) eps))
                                   (or (place-extra-ref place 'within) '())))))
                   places))

(display "\n── the snapshot carries what the face reads ──\n")
(define json (law-snapshot-string))
(check-pred "a bill's reform stance carries the build clauses beside the other three"
            (string-contains (demand->json (obtain #:rides 'entity #:name "x" #:spec '(fire-safety)))
                             "\"absorbFirst\""))
(check-pred "the burden scale's tiers ride the snapshot, as the fold names them"
            (every (lambda (t) (string-contains json (string-append "\"name\":\"" (cadr t) "\"")))
                   *burden-tiers*))
(check-pred "every place carries its program and its own readings"
            (and (string-contains json "\"program\":[{\"name\"")
                 (string-contains json "\"structural\":[{\"name\"")))

(test-summary!)
