;;; test-federation-spec.scm — a federation's store says who is on the wire.
;;;
;;; A federation scope, signing under its own key, admits three communes as
;;; remote members with their sturdyrefs. Each member tells its census — the
;;; goods its records deal in, a credential it issues and signs — and the
;;; federation's `federation-spec`, read off its own store with nothing typed,
;;; names the issuer, the goods at least two members told, the roster and each
;;; member's credential; every credential checks (a sturdyref under the
;;; federation's AID, a census under its member's own), and `roster-ends` reads
;;; each side's ends off the roster. A later census replaces an earlier; a
;;; stranger's, a tampered one and one told to another federation are refused;
;;; a revoked member leaves the spec.
;;;
;;; Run:  guile --no-auto-compile -q -L module tests/planner/test-federation-spec.scm

(use-modules (playnet test harness)
             ((playnet test planner federation-wire-fixture) #:select (fx-identity))
             (playnet governance scope) (playnet keri acdc) (playnet keri acdc-store) (playnet keri citizen-sig)
             ((playnet planner federation host) #:select (roster-ends))
             ((playnet governance sturdyref-credential) #:select (sturdyref-credential-end spec-ready? verified-spec))
             ((playnet gateway federate) #:select (census-credential))
             ((playnet keri acdc) #:select (cred-said cred-schema cred-issuer cred-holder cred-signature
                                            make-credential cred-with-signature))
             ((playnet keri citizen-sig) #:select (make-keri-identity keri-identity-aid keri-identity-keypair))
             (goblins) (goblins vat)
             (rnrs bytevectors) (srfi srfi-1))

(define id-f (fx-identity 3))
(define id-a (fx-identity 1))
(define id-b (fx-identity 2))
(define id-c (fx-identity 5))
(define aid-f (keri-identity-aid id-f)) (define aid-a (keri-identity-aid id-a))
(define aid-b (keri-identity-aid id-b)) (define aid-c (keri-identity-aid id-c))

(define vat (spawn-vat #:name "federation"))
(define-values (fed store)
  (with-vat vat
    (let* ((store (spawn-acdc-store))
           (fed (spawn-scope "Valley" #:kind 'federation #:scope-aid aid-f
                             #:keypair (keri-identity-keypair id-f) #:acdc-store store)))
      (values fed store))))
(define gov (with-vat vat ($ fed 'mint-gov-cap "bootstrap")))

(with-vat vat
  ($ fed 'admit-commune-remote gov "granary" aid-a "ocapn://a/s/1")
  ($ fed 'admit-commune-remote gov "table" aid-b "ocapn://b/s/2")
  ($ fed 'admit-commune-remote gov "mill" aid-c "ocapn://c/s/3"))

;; each telling is a later one: the clock a census is told at is a counter, so a run is the same each time
(define told-at (let ((n 0)) (lambda () (set! n (+ n 1)) (number->string n))))
(define (tell! id goods)
  (with-vat vat ($ fed 'accept-census (census-credential id aid-f goods (told-at)))))

(display "\n── admitted, none has told: nothing crosses yet ──\n")
(let ((spec (with-vat vat ($ fed 'federation-spec))))
  (check "no goods" (assq-ref spec 'goods) '())
  (check "and the spec is not ready for any member"
         (or (spec-ready? spec aid-a) (spec-ready? spec aid-b) (spec-ready? spec aid-c)) #f))

(tell! id-a '("flour"))
(tell! id-b '("flour" "bread"))
(display "\n── two have told, one has not: not ready, but flour already crosses ──\n")
(let ((spec (with-vat vat ($ fed 'federation-spec))))
  (check "flour crosses between the two that told" (assq-ref spec 'goods) '("flour"))
  (check "not ready: the mill has not told" (spec-ready? spec aid-a) #f))
(tell! id-c '("flour"))

(define spec (with-vat vat ($ fed 'federation-spec)))

(display "\n── the spec, off the store ──\n")
(check "the issuer is the federation" (assq-ref spec 'issuer) aid-f)
(check "the goods are what at least two members told" (assq-ref spec 'goods) '("flour"))
(check "flour's roster: the three who told it, in the order of their AIDs"
       (cdr (assoc "flour" (assq-ref spec 'roster))) (sort (list aid-a aid-b aid-c) string<?))
(check "bread, told by the table alone, crosses nowhere" (assoc "bread" (assq-ref spec 'roster)) #f)
(check "the roster names no side: which commune supplies is the plan's to say"
       (every (lambda (g) (every string? (cdr g))) (assq-ref spec 'roster)))
(check "one credential per member, by AID"
       (lset= equal? (map car (assq-ref spec 'credentials)) (list aid-a aid-b aid-c)))
(check "every credential checks under the federation's AID and names the member's sturdyref"
       (every (lambda (p)
                (call-with-values (lambda () (sturdyref-credential-end (cdr p) #:issuer aid-f))
                  (lambda (aid uri) (and (equal? aid (car p)) (string-prefix? "ocapn://" uri)))))
              (assq-ref spec 'credentials)))
(check "a census per member, and the spec every member can read ready"
       (and (lset= equal? (map car (assq-ref spec 'census)) (list aid-a aid-b aid-c))
            (every (lambda (a) (spec-ready? spec a)) (list aid-a aid-b aid-c))))
(check "the spec re-derived from its credentials alone, every one checked, is the same"
       (equal? (assq-ref (verified-spec aid-f (append (map cdr (assq-ref spec 'credentials))
                                                      (map cdr (assq-ref spec 'census))))
                         'roster)
               (assq-ref spec 'roster)))

(display "\n── a later census replaces an earlier ──\n")
(tell! id-c '("flour" "bread"))
(let ((spec (with-vat vat ($ fed 'federation-spec))))
  (check "the mill now deals in bread too: bread crosses for the table and the mill"
         (cdr (assoc "bread" (assq-ref spec 'roster))) (sort (list aid-b aid-c) string<?))
  (check "one census stands per member" (length (assq-ref spec 'census)) 3))
(tell! id-c '("flour"))

(display "\n── the unit a good is counted in is the one its members state ──\n")
(define (tell-units! id goods units)
  (with-vat vat ($ fed 'accept-census (census-credential id aid-f goods (told-at) #:units units))))
(tell-units! id-a '("flour") '(("flour" . "kg")))
(tell-units! id-b '("flour" "bread") '(("flour" . "lb") ("bread" . "each")))
(let* ((spec (with-vat vat ($ fed 'federation-spec)))
       (first-by-aid (if (string<? aid-a aid-b) "kg" "lb")))
  (check "flour is counted in the unit of the first member to state one, by AID"
         (assoc-ref (assq-ref spec 'units) "flour") first-by-aid)
  (check "and bread in the only one stated" (assoc-ref (assq-ref spec 'units) "bread") "each")
  (check "a census that states none leaves the unit to the others"
         (begin (tell! id-a '("flour"))
                (assoc-ref (assq-ref (with-vat vat ($ fed 'federation-spec)) 'units) "flour"))
         "lb"))
(tell! id-b '("flour" "bread"))

(display "\n── words that cannot be attributed are refused ──\n")
(define id-x (fx-identity 9))
(check "a stranger's census"
       (raises? (lambda () (tell! id-x '("flour")))) #t)
(check "a census told to another federation"
       (raises? (lambda () (with-vat vat ($ fed 'accept-census (census-credential id-a aid-a '("flour") "t"))))) #t)
(check "a census whose goods were changed after it was signed"
       (raises?
        (lambda ()
          (let* ((c (census-credential id-a aid-f '("flour") "t"))
                 (forged (make-credential (cred-schema c) (cred-issuer c) (cred-holder c)
                                          '((goods "gold") (told-at . "t")) '())))
            (with-vat vat ($ fed 'accept-census (cred-with-signature forged (cred-signature c)))))))
       #t)
(check "none of them changed the spec"
       (equal? (assq-ref (with-vat vat ($ fed 'federation-spec)) 'roster) (assq-ref spec 'roster)) #t)

(display "\n── each side's ends, off the roster ──\n")
(let* ((roster (assq-ref spec 'roster))
       (sides (map (lambda (aid) (cons aid (roster-ends roster aid))) (list aid-a aid-b aid-c)))
       (master (car (sort (list aid-a aid-b aid-c) string<?)))
       (of (lambda (aid k) (assq-ref (cdr (assoc aid sides)) k))))
  (check "flour's master is its first participant by AID, and exactly one side masters it"
         (map (lambda (s) (car s)) (filter (lambda (s) (member "flour" (assq-ref (cdr s) 'mastering))) sides))
         (list master))
  (check "the master's members are the other two, and its ends reach each by its AID"
         (list (cdr (assoc "flour" (of master 'members)))
               (map caddr (filter (lambda (e) (equal? (car e) "flour")) (of master 'ends))))
         (let ((others (remove (lambda (a) (equal? a master)) (sort (list aid-a aid-b aid-c) string<?))))
           (list others others)))
  (check "every other side has one end on flour: the master"
         (every (lambda (aid)
                  (or (equal? aid master)
                      (equal? (filter (lambda (e) (equal? (car e) "flour")) (of aid 'ends))
                              (list (list "flour" 'master master)))))
                (list aid-a aid-b aid-c)))
  (check "bread is told by the table alone: no side holds it"
         (every (lambda (s) (and (not (member "bread" (assq-ref (cdr s) 'mastering)))
                                 (not (assoc "bread" (assq-ref (cdr s) 'ends)))))
                sides)))

(display "\n── one commune tells two federations on one store: neither census ends the other ──\n")
(define id-f2 (fx-identity 7))
(define aid-f2 (keri-identity-aid id-f2))
(define fed2
  (with-vat vat
    (spawn-scope "Coast" #:kind 'federation #:scope-aid aid-f2
                 #:keypair (keri-identity-keypair id-f2) #:acdc-store store)))
(define gov2 (with-vat vat ($ fed2 'mint-gov-cap "bootstrap")))
(with-vat vat
  ($ fed2 'admit-commune-remote gov2 "granary" aid-a "ocapn://a/s/1")
  ($ fed2 'accept-census (census-credential id-a aid-f2 '("flour" "salt") "t2")))
(let ((census-of-a (lambda (f) (assoc aid-a (assq-ref (with-vat vat ($ f 'federation-spec)) 'census)))))
  (check "the first federation still holds the granary's census" (and (census-of-a fed) #t) #t)
  (check "and the second holds its own" (and (census-of-a fed2) #t) #t)
  (check "the two are the two that were told"
         (not (equal? (cred-said (cdr (census-of-a fed))) (cred-said (cdr (census-of-a fed2))))) #t))

(display "\n── a revoked member leaves the spec ──\n")
(with-vat vat
  (let ((c (cdr (assoc aid-c (assq-ref spec 'credentials)))))
    ($ store 'revoke (cred-said c))))
(define spec-2 (with-vat vat ($ fed 'federation-spec)))
(check "the mill is gone from the roster and the credentials"
       (and (not (assoc aid-c (assq-ref spec-2 'credentials)))
            (not (member aid-c (cdr (assoc "flour" (assq-ref spec-2 'roster)))))))
(test-summary!)
