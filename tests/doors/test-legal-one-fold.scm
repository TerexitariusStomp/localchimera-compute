;;; test-legal-one-fold.scm — one law, one fold, one reading.
;;;
;;; The legal layer answers "what does the law ask of this, here" in several
;;; places: a mode on the law face, a point of a supply arc, the solve's prune,
;;; the registry's `forbids?`. These properties hold them to one answer:
;;;
;;;   · the law in force is the packs on disk, and every fold reads it;
;;;   · every place fold is `bill-at`;
;;;   · every decision is `bill-stance`, read after derogations, by confidence;
;;;   · the product's own features are crossings folded the same way.
;;;
;;; Run: guile -L module tests/doors/test-legal-one-fold.scm

(use-modules (ice-9 regex) (playnet test harness)
             (playnet knowledge law activities) (playnet knowledge law aspects) (playnet knowledge law context-pack) (playnet knowledge law incumbent-readings) (playnet knowledge law pack-dir) (playnet knowledge law product) (playnet legal adapters) (playnet legal compliance) (playnet legal crossings) (playnet legal policy) (playnet legal reform) (playnet legal registry) (playnet observation observer) (playnet plan store) (playnet scope spatial-things) (playnet vf facts places) (playnet vf schemas) (srfi srfi-1)
             (playnet legal gate)
             (playnet legal registry-actor)
             (playnet knowledge worlds free-food-distribution)
             ((playnet doors protocol) #:select (%doors door-feature))
             (playnet scope spatial-things) (playnet observation observer) (playnet plan store) (playnet vf schemas) (srfi srfi-1) (playnet legal compliance) (playnet legal adapters)
             (playnet knowledge law structural-demands)
             (playnet knowledge law lint)
             (playnet legal policy) (playnet utils governed-row)
             ((playnet utils geo) #:select (in-geometry?))
             ((playnet knowledge law jurisdiction-at) #:select (jurisdiction-at register-jurisdiction-outline!))
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (srfi srfi-13) (ice-9 format) (ice-9 rdelim))

(define (bill-of thunk) (call-with-values thunk list))          ; → (bill hits)
(define (bill-names bh)
  (map (lambda (kv) (cons (car kv) (map demand-name (cdr kv)))) (car bh)))
(define (same-bill? a b)
  (and (equal? (bill-names a) (bill-names b))
       (equal? (map legal-rule-label (cadr a)) (map legal-rule-label (cadr b)))))

(display "\n── the law in force ──\n")
(check-pred "the law in force is the packs on disk"
            (and (pair? *pack-rules*) (eq? (current-legal-rules) *pack-rules*)))
(check-error "the fold names no law of its own: a caller states the rules"
             (lambda () (legal-demands (legal-context #:crossings '(share-food)))))
(check-error "the fold of a place assumes no act: a caller states it"
             (lambda () (bill-at "berlin" '(share-food))))
(check-pred "a caller with law of its own folds the same code over it"
            (parameterize ((current-legal-rules '()))
              (equal? 'open (apply bill-stance
                                   (bill-of (lambda () (bill-at "berlin" '(share-food) #:act 'activity)))))))

(display "\n── one fold ──\n")
(define places (filter place-known? '("us" "us-06" "berlin" "germany" "france" "mexico" "canada")))
(define modes (append-map activity-modes *activities*))
(check-pred "there are places and modes to fold"
            (and (pair? places) (pair? modes)))
(check-pred "a way's bill is bill-at over the way's crossings, act and channel"
            (every (lambda (p)
                     (every (lambda (m)
                              (same-bill? (bill-of (lambda () (mode-bill p m)))
                                          (bill-of (lambda ()
                                                     (bill-at p (assq-ref m 'crossings)
                                                              #:act (assq-ref m 'act)
                                                              #:channel (assq-ref m 'channel))))))
                            modes))
                   places))
(check-pred "an arc point's bill is bill-at over the arc crossings, chain alone"
            (every (lambda (p)
                     (same-bill? (bill-of (lambda () (ffd-point-bill p)))
                                 (bill-of (lambda ()
                                            (bill-at p *ffd-arc-crossings*
                                                     #:act 'free-food-distribution
                                                     #:regimes? #f)))))
                   places))

(display "\n── one reading ──\n")
;; a small law of its own, at a place of its own
(define here "stance-test-place")
(place! here "Stance test place" #f #:kind 'locality)
(define (ban confidence)
  (rule (all-of (in-jurisdiction here) (on-crossing 'stance-test))
        (list (forbid #:reason "test ban"))
        #:label (format #f "test/ban/~a" confidence) #:confidence confidence))
(define lift
  (rule (all-of (in-jurisdiction here) (on-crossing 'stance-test))
        '() #:label "test/lift" #:confidence 'verified #:cancels '("test ban")))
(define (doubtful-lift)
  (rule (all-of (in-jurisdiction here) (on-crossing 'stance-test))
        '() #:label "test/doubtful-lift" #:confidence 'uncertain #:cancels '("test ban")))
(define ask
  (rule (all-of (in-jurisdiction here) (on-crossing 'stance-test))
        (list (obtain #:rides 'entity #:name "Test permit"))
        #:label "test/ask" #:confidence 'reported))
(define doubtful-ask
  (rule (all-of (in-jurisdiction here) (on-crossing 'stance-test))
        (list (obtain #:rides 'entity #:name "Test permit"))
        #:label "test/doubtful-ask" #:confidence 'uncertain))
(define (at rules) (bill-of (lambda () (bill-at here '(stance-test) #:act 'activity #:rules rules))))
(define (stance rules . held) (apply bill-stance (append (at rules) held)))
(define (prunes? rules . held)
  (call-with-values (lambda () (apply legal-bill->decoration (append (at rules) held)))
    (lambda (prune? cost skills frag bill) prune?)))
(define (tension rules)
  (call-with-values (lambda () (apply legal-bill->decoration (at rules)))
    (lambda (prune? cost skills frag bill) frag)))
(define nothing-held (lambda (name) #f))

(check "the law asks nothing → open" (stance '()) 'open)
(check "something is asked → notice" (stance (list ask)) 'notice)
(check "a sure prohibition → off" (stance (list (ban 'verified))) 'off)
(check "a reported prohibition is sure → off" (stance (list (ban 'reported))) 'off)
(check "an uncertain prohibition → soft" (stance (list (ban 'uncertain))) 'soft)
(check "one sure prohibition among uncertain ones → off"
       (stance (list (ban 'uncertain) (ban 'verified))) 'off)
(check "a verified derogation lifts the prohibition → open"
       (stance (list (ban 'verified) lift)) 'open)
(check "an uncertain derogation lifts nothing → off"
       (stance (list (ban 'verified) (doubtful-lift))) 'off)
(check "a sure permit, not held → off" (stance (list ask) nothing-held) 'off)
(check "an uncertain permit, not held → notice" (stance (list doubtful-ask) nothing-held) 'notice)

(check-pred "the solve prunes exactly where the stance is off"
            (every (lambda (rules)
                     (and (eq? (prunes? rules) (eq? 'off (stance rules)))
                          (eq? (prunes? rules nothing-held)
                               (eq? 'off (stance rules nothing-held)))))
                   (list '() (list ask) (list doubtful-ask)
                         (list (ban 'verified)) (list (ban 'uncertain))
                         (list (ban 'verified) lift) (list (ban 'verified) (doubtful-lift)))))
(check-pred "a lifted prohibition leaves the column in the solve"
            (not (prunes? (list (ban 'verified) lift))))
(check-pred "an uncertain prohibition rides as a tension, a sure one does not"
            (and (tension (list (ban 'uncertain)))
                 (not (tension (list (ban 'verified))))
                 (not (tension (list (ban 'uncertain) lift)))))

(define vat (spawn-vat))
(define (registry-forbids? rules)
  (with-vat vat
    (let ((reg (spawn ^legal-registry rules)))
      ($ reg 'forbids? (legal-context #:crossings '(stance-test) #:place-path (list here))))))
(check-pred "the registry's forbids? is the stance being off"
            (every (lambda (rules) (eq? (registry-forbids? rules) (eq? 'off (stance rules))))
                   (list '() (list ask) (list (ban 'verified)) (list (ban 'uncertain))
                         (list (ban 'verified) lift))))

(display "\n── confidence ──\n")
(check-pred "every rule in force carries a confidence the layer knows"
            (every (lambda (r) (memq (legal-rule-confidence r) %confidences)) *pack-rules*))

(display "\n── the product's own acts ──\n")
(check-pred "every feature names crossings the catalogue knows"
            (every (lambda (id)
                     (let ((xs (feature-crossings (product-feature id))))
                       (and (pair? xs) (every known-crossing? xs))))
                   (product-feature-ids)))
(check-pred "every feature has doors, declared on the doors"
            (every (lambda (id) (pair? (feature-doors (product-feature id)))) (product-feature-ids)))
(check-pred "every feature a door declares is a feature of the product"
            (every (lambda (d) (or (not (door-feature d)) (product-feature (door-feature d)))) %doors))
(check-pred "the attribution is the line the additional terms ask for"
            (let ((terms (call-with-input-file "LICENSE-ADDITIONAL-TERMS.md"
                           (lambda (p)
                             (set-port-encoding! p "UTF-8")
                             (let loop ((acc '()) (l (read-line p)))
                               (if (eof-object? l)
                                   (string-join (reverse acc) " ")
                                   (loop (cons l acc) (read-line p))))))))
              (string-contains terms (product-notice 'attribution))))
(define (file-text path)
  (call-with-input-file path
    (lambda (p)
      (set-port-encoding! p "UTF-8")
      (let loop ((acc '()) (l (read-line p)))
        (if (eof-object? l) (string-join (reverse acc) " ") (loop (cons l acc) (read-line p)))))))
(check-pred "the terms and the privacy notice state the licence line and the version a member accepts"
            (every (lambda (page)
                     (let ((text (file-text (string-append "browser/" (product-notice page)))))
                       (and (string-contains text (product-notice 'licence))
                            (string-contains text (product-notice 'legal-version))
                            (string-contains text (product-notice 'document-version)))))
                   '(terms privacy)))
(check-pred "the about scroll shows the attribution, the licence and both notices from the manifest"
            (let ((js (file-text "browser/app/scroll.js")))
              (every (lambda (name) (string-contains js name))
                     '("legal-product.js" "ATTRIBUTION" "LICENCE_LINE" "TERMS_HREF" "PRIVACY_HREF"))))
(check-pred "each notice's own footer states its generated version and date, not just somewhere on the page"
            (every (lambda (page title)
                     ;; the figures ride in marked spans (tools/emit/emit-notice-facts.scm); read the sentence
                     (let ((text (regexp-substitute/global
                                  #f "</?span[^>]*>" (file-text (string-append "browser/" (product-notice page)))
                                  'pre 'post)))
                       (string-contains text
                         (string-append title " v" (product-notice 'document-version)
                                        ", effective " (product-notice 'legal-version)))))
                   '(terms privacy) '("Terms of Use" "Privacy Notice")))
(check-pred "the three notice pages cross-link each other by the generated hrefs"
            (let* ((pages '((terms . "browser/terms.html") (privacy . "browser/privacy.html")
                             (accessibility . "browser/accessibility.html")))
                   (hrefs (map (lambda (p) (cons (car p) (product-notice (car p)))) pages)))
              (every (lambda (page)
                       (let ((text (file-text (cdr page))))
                         (every (lambda (other)
                                  (or (eq? (car other) (car page))
                                      (string-contains text (string-append "href=\"" (cdr other) "\""))))
                                hrefs)))
                     pages)))
(check-pred "accessibility.html states a consistent version in its sub-line and its footer"
            (let ((text (file-text "browser/accessibility.html")))
              (and (string-contains text "Accessibility Statement v1.0.0, effective 2026-10-05.")
                   (string-contains text "Version <b>1.0.0</b>")
                   (string-contains text "effective <b>2026-10-05</b>"))))
(check-pred "a feature's stance is the stance of its crossings at the place, its act stated"
            (every (lambda (id)
                     (eq? (product-stance "berlin" id)
                          (stance-at "berlin" (feature-crossings (product-feature id))
                                     #:act %product-act)))
                   (product-feature-ids)))
;; a pack's rule on a product crossing reaches the feature, by place and by confidence
(define (funds-ban confidence)
  (rule (all-of (in-jurisdiction here) (on-crossing 'hold-funds))
        (list (forbid #:reason "custody needs a licence here"))
        #:label "test/funds-ban" #:confidence confidence))
(check "payouts where a sure rule forbids holding funds → off"
       (product-stance here 'payouts #:rules (list (funds-ban 'reported))) 'off)
(check "payouts where the pack doubts the ban → soft"
       (product-stance here 'payouts #:rules (list (funds-ban 'uncertain))) 'soft)
(check "the same ban says nothing of a feature that holds no funds"
       (product-stance here 'chat #:rules (list (funds-ban 'reported))) 'unread)
;; "forbidden here unless the act is farming" binds a feature, which is no farm
(define unless-farming
  (rule (all-of (in-jurisdiction here) (on-crossing 'hold-funds)
                (negate (act-is 'agriculture)))
        (list (forbid #:reason "only farms hold funds here"))
        #:label "test/unless-farming" #:confidence 'reported))
(check "a prohibition with an excepted act binds a feature, which states its own"
       (product-stance here 'payouts #:rules (list unless-farming)) 'off)
(check "the ban binds where its jurisdiction reaches, and only there"
       (product-stance "berlin" 'payouts #:rules (list (funds-ban 'reported))) 'unread)
;; reading a crossing and finding the law asks nothing is a rule with no demands
(define (read-as-silent crossing)
  (rule (all-of (in-jurisdiction here) (on-crossing crossing)) '()
        #:label (format #f "test/read/~a" crossing) #:confidence 'verified))
(check "a crossing a steward read and found silent → open"
       (product-stance here 'payouts #:rules (list (read-as-silent 'hold-funds))) 'open)
(check "a feature with one crossing read and one not → unread"
       (product-stance here 'chat #:rules (list (read-as-silent 'communications))) 'unread)
(check "every crossing read → open"
       (product-stance here 'chat
                             #:rules (list (read-as-silent 'communications)
                                           (read-as-silent 'data-processing))) 'open)
(check "a prohibition outranks what is unread beside it"
       (stance-at here '(hold-funds communications) #:act %product-act
                       #:rules (list (funds-ban 'reported))) 'off)
(check "the crossings nobody read are named"
       (call-with-values
           (lambda () (bill-at here '(hold-funds communications) #:act %product-act
                               #:rules (list (funds-ban 'reported))))
         (lambda (bill hits) (bill-unread hits '(hold-funds communications))))
       '(communications))
(check-pred "the solve reads the bill alone: silence prunes nothing"
            (not (prunes? '())))
;; Today's packs carry no rule on the product's own crossings.
(check-pred "where no pack speaks of a feature's crossings, its stance is unread"
            (every (lambda (id) (eq? 'unread (product-stance here id))) (product-feature-ids)))

;;; ─── what the context does not state ─────────────────────────────────────
(display "\n── an unstated fact is unknown, and unknown is doubt ──\n")
;; one guard, three answers: a known yes, a known no, and a fact nobody stated
(define (guard-says form . kw)
  ((compile-guard form) (apply legal-context #:crossings '(stance-test) #:place-path (list here) kw)))
(define yes  '(on-crossing stance-test))
(define no   '(on-crossing some-other-crossing))
(define ask? '(act-is farming))                      ; the act is unstated below
(check "a fact the context states is answered"
       (list (guard-says ask? #:act 'farming) (guard-says ask? #:act 'housing))
       '(#t #f))
(check "a fact it leaves unstated is unknown" (guard-says ask?) 'unknown)
(check "all-of: a no decides; else an unknown leaves it unknown"
       (list (guard-says `(all-of ,yes ,ask?)) (guard-says `(all-of ,no ,ask?))
             (guard-says `(all-of ,yes ,yes)))
       '(unknown #f #t))
(check "any-of: a yes decides; else an unknown leaves it unknown"
       (list (guard-says `(any-of ,no ,ask?)) (guard-says `(any-of ,yes ,ask?))
             (guard-says `(any-of ,no ,no)))
       '(unknown #t #f))
(check "the negation of unknown is unknown"
       (list (guard-says `(negate ,ask?)) (guard-says `(negate ,yes)) (guard-says `(negate ,no)))
       '(unknown #f #t))
(check "the channel is such a fact too"
       (list (guard-says '(via-channel box)) (guard-says '(via-channel box) #:channel 'box)
             (guard-says '(via-channel box) #:channel 'hand))
       '(unknown #t #f))

;; "forbidden here unless the act is farming"
(define unless-farm
  (rule (all-of (in-jurisdiction here) (on-crossing 'stance-test) (negate (act-is 'farming)))
        (list (forbid #:reason "only farms may"))
        #:label "test/unless-farm" #:confidence 'verified))
(define (act-stance act) (stance-at here '(stance-test) #:act act #:rules (list unless-farm)))
(check "the act stated as the excepted one → nothing forbids it" (stance-forbids? (act-stance 'farming)) #f)
(check "the act stated as another → off" (act-stance 'housing) 'off)
(check "the act unstated → soft: the rule may apply, so it stands in doubt" (act-stance #f) 'soft)
(define (hits-at act)
  (call-with-values (lambda () (bill-at here '(stance-test) #:act act #:rules (list unless-farm)))
    (lambda (bill hits) hits)))
(check-pred "a rule in doubt is the same rule, at confidence uncertain"
            (let ((h (car (hits-at #f))))
              (and (equal? "test/unless-farm" (legal-rule-label h))
                   (eq? 'uncertain (legal-rule-confidence h))
                   (eq? 'verified (legal-rule-confidence (car (hits-at 'housing)))))))
(check "…and says which fact was missing"
       (hit-unknowns (hits-at #f) (legal-context #:crossings '(stance-test) #:place-path (list here)))
       '(("test/unless-farm" act)))

;; an exemption whose guard cannot be answered lifts nothing
(define farm-lift
  (rule (all-of (in-jurisdiction here) (on-crossing 'stance-test) (act-is 'farming))
        '() #:label "test/farm-lift" #:confidence 'verified #:cancels '("test ban")))
(define (lift-stance act)
  (stance-at here '(stance-test) #:act act #:rules (list (ban 'verified) farm-lift)))
(check "an exemption for farming lifts the ban for a farm" (lift-stance 'farming) 'open)
(check "…and lifts nothing while the act is unstated" (lift-stance #f) 'off)

;; the solve: an unstated act keeps the column and carries the tension
(define (decorated act)
  (call-with-values
      (lambda () (bill-at here '(stance-test) #:act act #:rules (list unless-farm)))
    (lambda (bill hits)
      (call-with-values (lambda () (legal-bill->decoration bill hits))
        (lambda (prune? cost skills frag names) (list prune? (and frag #t)))))))
(check "stated otherwise: pruned, no tension" (decorated 'housing) '(#t #f))
(check "unstated: kept, with the tension" (decorated #f) '(#f #t))
(check "stated as excepted: kept, no tension" (decorated 'farming) '(#f #f))

;; every way states its act, so no way's bill stands in doubt for want of one
(check-pred "every way states its act"
            (every (lambda (m) (symbol? (assq-ref m 'act)))
                   (append-map activity-modes *activities*)))

;;; ─── the tables the layer derives ────────────────────────────────────────
(display "\n── what is derived is whole ──\n")
(define (mirror-of name)
  (assq-ref (find (lambda (d) (equal? name (assq-ref d 'name))) *structural-demands*) 'mirror))
(define property "Hold the means of life in common")
(check-pred "every clause an abolition names is an aspect the diff can see"
            (every (lambda (d)
                     (let ((m (assq-ref d 'mirror)))
                       (every legal-aspect? (append (or (spec-mirror-legal m) '())
                                                    (or (spec-mirror-internal m) '())
                                                    (or (spec-mirror-desired m) '())))))
                   *structural-demands*))
(check-pred "what the commons already does of the property demand is in its mirror"
            (and (memq 'allocate-use (spec-mirror-internal (mirror-of property)))
                 (memq 'allocate-use (spec-mirror-legal (mirror-of property)))
                 #t))
(check-pred "an arc trips what the recovery pathway trips; the activity, what its pathways trip"
            (and (equal? *ffd-arc-crossings*
                         (assq-ref (ffd-recipe-ref "recipe-ffd-recovery") 'crossings))
                 (lset= eq? *ffd-activity-crossings*
                        (append-map (lambda (r) (assq-ref r 'crossings)) *ffd-recipes*))))
(check-pred "a stance and a reading's status are words the layer lists"
            (and (every (lambda (rules) (memq (stance rules) %stances))
                        (list '() (list ask) (list (ban 'verified)) (list (ban 'uncertain))))
                 (memq (product-stance here 'chat) %stances)
                 (every (lambda (d)
                          (memq (assq-ref (reading-standing (incumbent-at "france" (assq-ref d 'name))
                                                            (assq-ref d 'mirror))
                                          'status)
                                %reading-statuses))
                        *structural-demands*)))

;;; ─── the other readers of a bill ─────────────────────────────────────────
(display "\n── every reader draws the same line ──\n")
(define (statuses rules)                 ; reconcile's status of each forbid, over a bare observer
  (with-vat vat
    (let ((obs (spawn ^observer (empty-observer-state) '())))
      (call-with-values (lambda () (bill-at here '(stance-test) #:act 'activity #:rules rules))
        (lambda (bill hits)
          (map (lambda (e) (list-ref e 3))
               (filter (lambda (e) (eq? 'forbid (list-ref e 1)))
                       (reconcile bill hits obs "2026-07-14"))))))))
(check "custody reads a sure prohibition as forbidden" (statuses (list (ban 'verified))) '(forbidden))
(check "…and an uncertain one as doubted, which stops nothing"
       (statuses (list (ban 'uncertain))) '(doubted))
(check-pred "a doubted prohibition is no gap; a sure one is"
            (and (null? (reconcile-gaps (list (list 'k 'forbid "test ban" 'doubted))))
                 (pair? (reconcile-gaps (list (list 'k 'forbid "test ban" 'forbidden))))))
(define (exposure rules)
  (with-vat vat
    (let ((obs (spawn ^observer (empty-observer-state) '())))
      (adapter-exposure obs "mask:test" #:crossings '(stance-test) #:place-path (list here)
                        #:rules rules))))
(check-pred "a mask's exposure says the stance, and tells forbidden from doubted"
            (let ((sure (exposure (list (ban 'verified)))) (doubt (exposure (list (ban 'uncertain)))))
              (and (eq? 'off (assq-ref sure 'stance)) (pair? (assq-ref sure 'forbidden))
                   (null? (assq-ref sure 'doubted))
                   (eq? 'soft (assq-ref doubt 'stance)) (null? (assq-ref doubt 'forbidden))
                   (pair? (assq-ref doubt 'doubted)))))

;;; ─── one climb, one loader ───────────────────────────────────────────────
(display "\n── one climb, one loader ──\n")
;; a place only a scope knows, standing under the test place
(define local-stance
  (with-vat vat
    (let ((sts (spawn ^spatial-thing-store (hashmap))))
      ($ sts 'add-location (make-spatial-thing #:id here #:name "Stance test place"))
      ($ sts 'add-location (make-spatial-thing #:id "a-scope-own-plot" #:name "A plot"
                                               #:contained-in here))
      (list (stance-at "a-scope-own-plot" '(stance-test) #:act 'activity
                       #:rules (list (ban 'verified)))
            (stance-at "a-scope-own-plot" '(stance-test) #:act 'activity
                       #:rules (list (ban 'verified))
                       #:path-of (spatial-path-reader sts))))))
(check "the shared tree knows nothing of a scope's own place" (car local-stance) 'unread)
(check "the scope's climb reaches it, and the law above it" (cadr local-stance) 'off)

;; a pack in a scope's folder: its places stand in the shared tree and in the
;; scope's store, and a regime it stands `within` reaches a rule guarded there
(define pack-dir (string-append "/tmp/playnet-one-fold-" (number->string (getpid))))
(mkdir pack-dir)
(call-with-output-file (string-append pack-dir "/basin.sexp")
  (lambda (port)
    (write `((places . (("one-fold-basin" "A basin" #f regime ())
                        ("one-fold-town" "A town" #f locality ((within . ("one-fold-basin"))))))
             (rules . ,(rules->sexp
                        (list (rule (all-of (in-jurisdiction "one-fold-basin")
                                            (on-crossing 'stance-test))
                                    (list (forbid #:reason "the basin is closed"))
                                    #:label "test/basin" #:confidence 'verified)))))
           port)))
(define loaded
  (with-vat vat
    (let* ((sts (spawn ^spatial-thing-store (hashmap)))
           (rules (load-law pack-dir #:store sts)))
      (list rules
            (and ($ sts 'get-location "one-fold-town") #t)
            (stance-at "one-fold-town" '(stance-test) #:act 'activity #:rules rules
                       #:path-of (spatial-path-reader sts))))))
(delete-file (string-append pack-dir "/basin.sexp")) (rmdir pack-dir)
(check "the loader yields the pack's rules" (length (car loaded)) 1)
(check-pred "…seeds its places into the scope's store, and keeps their kind in the tree"
            (and (cadr loaded) (eq? 'regime (place-kind "one-fold-basin"))))
(check "…and a regime a place stands within reaches the scope's gate" (caddr loaded) 'off)
(check "an absent folder is no law" (load-law #f) '())

;;; ─── nobody looked ───────────────────────────────────────────────────────
(display "\n── what nobody looked at is unknown ──\n")
(define has-kitchen '(asset-has classified-as "kitchen"))
(define held-by-club '(agent-has classified-as "club"))
(check "things at the cell: looked and found, looked and none, nobody looked"
       (list (guard-says has-kitchen #:assets '(((classified-as . ("kitchen")))))
             (guard-says has-kitchen #:assets '())
             (guard-says has-kitchen))
       '(#t #f unknown))
(check "their holders the same way"
       (list (guard-says held-by-club #:agents '(((classified-as . ("club")))))
             (guard-says held-by-club #:agents '())
             (guard-says held-by-club))
       '(#t #f unknown))
(check-pred "a gate with no observer has looked at nothing"
            (and (not (legal-assets-at #f (lambda (p) (list (list p))) '() here))
                 (not (legal-agents-of #f '()))))
(define thing-ban
  (rule (all-of (in-jurisdiction here) (on-crossing 'stance-test) (negate has-kitchen))
        (list (forbid #:reason "test ban"))
        #:label "test/ban-without-kitchen" #:confidence 'verified))
(define (thing-read . kw)
  (let ((ctx (apply legal-context #:crossings '(stance-test) #:place-path (list here) kw)))
    (call-with-values (lambda () (legal-demands ctx #:rules (list thing-ban)))
      (lambda (bill hits) (list (bill-stance bill hits) (hit-unknowns hits ctx))))))
(check "a ban that turns on a thing: seen absent it stands, seen present it is silent"
       (list (car (thing-read #:assets '())) (car (thing-read #:assets '(((classified-as . ("kitchen")))))))
       '(off open))
(check "…and with nobody looking it is a doubt that names what was not looked at"
       (thing-read) '(soft (("test/ban-without-kitchen" assets))))
(check "a permit whose custody nobody looked at is named, and prunes nothing"
       (call-with-values (lambda () (apply legal-bill->decoration (at (list ask))))
         (lambda (prune? cost skills frag bill)
           (list prune? (assq-ref bill 'custody-unknown))))
       '(#f ("Test permit")))
(check "the same permit, looked for and not held, prunes" (prunes? (list ask) nothing-held) #t)

;;; ─── a member's place ────────────────────────────────────────────────────
(display "\n── a member's place stands in the law ──\n")
(define square '(("type" . "Polygon")
                 ("coordinates" . #(#(#(10.0 10.0) #(11.0 10.0) #(11.0 11.0) #(10.0 11.0) #(10.0 10.0))))))
(check "a point is inside the ring that holds it, and outside the one that does not"
       (list (in-geometry? 10.5 10.5 square) (in-geometry? 12.0 10.5 square)) '(#t #f))
(check-pred "the shipped outlines place a point in the deepest jurisdiction that holds it"
            (let ((oakland (jurisdiction-at 37.80 -122.27)) (berlin (jurisdiction-at 52.52 13.40)))
              (and (place-known? oakland) (member "us" (place-chain oakland))
                   (not (equal? oakland "us"))
                   (place-known? berlin) (member "germany" (place-chain berlin)))))
(check "open sea stands in no jurisdiction" (jurisdiction-at 30.0 -40.0) #f)
(register-jurisdiction-outline! here square)
(check "an outline a scope registers is read the same way" (jurisdiction-at 10.5 10.5) here)
(define standing-in (@@ (playnet doors service) standing-in))
(define (spot id lat lon up) (make-spatial-thing #:id id #:name id #:lat lat #:long lon
                                                 #:contained-in up))
(check "a fix stands in the nearby place of its scope when that place is under the outline"
       (standing-in 10.5 10.5 (list (spot "one-fold-plot" 10.5 10.51 here))) here)
(place! "one-fold-quarter" "A quarter" here #:kind 'locality)
(check "…the nearer the better: a known place under the outline is where it stands"
       (standing-in 10.5 10.5 (list (spot "one-fold-quarter" 10.5 10.51 here))) "one-fold-quarter")
(check "a nearby place across the line gives way to the outline"
       (standing-in 10.99 10.5 (list (spot "germany" 11.01 10.5 #f))) here)
(define member-stance
  (with-vat vat
    (let ((sts (spawn ^spatial-thing-store (hashmap))))
      ;; the scope's store holds the member's place and nothing above it
      ($ sts 'add-location (spot "place:member:here" 10.5 10.5 (standing-in 10.5 10.5 '())))
      (list (car ((spatial-path-reader sts) "place:member:here"))
            (stance-at "place:member:here" '(stance-test) #:act 'activity
                       #:rules (list (ban 'verified))
                       #:path-of (spatial-path-reader sts))))))
(check "the climb from a member's place steps into the shared tree"
       (car member-stance) (list "place:member:here" here))
(check "…so the law of where they stand reaches them" (cadr member-stance) 'off)

;;; ─── coverage ────────────────────────────────────────────────────────────
(display "\n── coverage ──\n")
(check-pred "what the packs speak of is what a fired rule speaks of"
            (lset= eq? (pack-crossings %contexts-dir)
                   (delete-duplicates (append-map rule-speaks-of *pack-rules*))))
(check-pred "a crossing the federation trips and no pack speaks of is unread wherever it is tripped"
            (let ((uncovered (map finding-subject
                                  (filter (lambda (f) (eq? 'uncovered-crossing (finding-kind f)))
                                          (law-coverage (federation-crossings)
                                                        (pack-crossings %contexts-dir))))))
              (and (memq 'hold-funds uncovered)
                   (every (lambda (c)
                            (call-with-values
                                (lambda () (bill-at "berlin" (list c) #:act %product-act))
                              (lambda (bill hits) (equal? (list c) (bill-unread hits (list c))))))
                          uncovered))))

;;; ─── a scope's own word ──────────────────────────────────────────────────
(display "\n── a governed row ──\n")
(check-pred "a policy read without a scope is its default, and an explicit value stands over both"
            (and (equal? (legal-policy #f 'uncertain-forbid)
                         (assq-ref *legal-policy-defaults* 'uncertain-forbid))
                 (equal? '(1 2 3 4) (legal-policy #f 'uncertain-forbid '(1 2 3 4)))
                 (equal? 7 (governed-row #f "any-row" '((k . 7)) 'k))))
(define row-written
  (with-vat vat
    (let ((ps (spawn ^plan-store (empty-plan-store-state) '())))
      (merge-governed-row! ps "legal-policy" '((uncertain-forbid . (0.0 1.0 1.0 5.0))))
      (list (legal-policy ps 'uncertain-forbid)
            (false-if-exception
             (merge-governed-row! ps "legal-policy" '(("not a key" . 1))))))))
(check "a scope's written word is what its policy reads" (car row-written) '(0.0 1.0 1.0 5.0))
(check-pred "a malformed entry is refused" (not (cadr row-written)))

(test-summary!)
