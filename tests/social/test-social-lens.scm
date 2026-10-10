;;; test-social-lens.scm — resolve-lens over a contact book.
;;;
;;; Proves the named CF lens (folksonomy.md Phase 4): a lens name + the caller's
;;; contacts → the AID neighbourhood whose assertions count, data-driven off the
;;; `rel` graph so any relationship kind is a lens for free.
;;;
;;; Run:  guile --no-auto-compile -q -L module \
;;;         -l tests/social/test-social-lens.scm

(use-modules (playnet test harness)
             (playnet social lens)
             (playnet social relationship-kinds)
             (srfi srfi-1))

(define book
  '(((alias . "Ana")   (aid . "AID-ana")   (rel . "friend"))
    ((alias . "Sam")   (aid . "AID-sam")   (rel . "friend"))
    ((alias . "mama")  (aid . "AID-mama")  (rel . "family"))
    ((alias . "assembly") (prefix . "AID-asm") (rel . "commons"))  ; 'prefix not 'aid
    ((alias . "Priya") (aid . "AID-priya") (rel . "colleague"))))

(define (set= a b) (and (= (length a) (length b)) (lset= equal? a b)))

(display "\n── special lenses ──\n")
(check "everyone → #f (global, no weighting)"
       (resolve-lens "everyone" book "AID-me") #f)
(check "empty string → #f" (resolve-lens "" book "AID-me") #f)
(check "#f name → #f" (resolve-lens #f book "AID-me") #f)
(check "me → just the caller" (resolve-lens "me" book "AID-me") '("AID-me"))
(check "social → #f (the commons/UC aggregate — the dial's default)"
       (resolve-lens "social" book "AID-me") #f)
(check "individual → just the caller (the dial toggle's other pole)"
       (resolve-lens "individual" book "AID-me") '("AID-me"))
(check "contacts → every AID in the book"
       (set= (resolve-lens "contacts" book "AID-me")
             '("AID-ana" "AID-sam" "AID-mama" "AID-asm" "AID-priya")) #t)

(display "\n── rel-driven lenses (data-driven) ──\n")
(check "friends → the two friend AIDs (plural name, singular rel)"
       (set= (resolve-lens "friends" book "AID-me") '("AID-ana" "AID-sam")) #t)
(check "friend (singular) → same"
       (set= (resolve-lens "friend" book "AID-me") '("AID-ana" "AID-sam")) #t)
(check "family → mama" (resolve-lens "family" book "AID-me") '("AID-mama"))
(check "commons → the assembly (via 'prefix key)"
       (resolve-lens "commons" book "AID-me") '("AID-asm"))
(check "colleague → Priya (a custom-ish rel, no special-casing)"
       (resolve-lens "colleague" book "AID-me") '("AID-priya"))
(check "an unknown rel → empty neighbourhood"
       (resolve-lens "nemesis" book "AID-me") '())

(display "\n── one vocabulary (relationship-kinds) ──\n")
(check "a listed kind's plural reads as the kind"
       (map normalize-rel '("Friends" "family" "colleagues" "commons" friend))
       '("friend" "family" "colleague" "commons" "friend"))
(check "the empty word, #f and the credential's old default read as the default kind"
       (map normalize-rel '("" #f "knows" knows)) '("contact" "contact" "contact" "contact"))
(check "normalize-rel is idempotent over every listed spelling"
       (every (lambda (k) (and (equal? (normalize-rel (normalize-rel (kind-plural k)))
                                       (normalize-rel (kind-plural k)))
                               (equal? (normalize-rel (kind-id k)) (kind-id k))))
              %relationship-kinds) #t)
(check "a person's own word is its own kind, and meets its plural"
       (list (normalize-rel "Neighbour") (rel=? "neighbour" "neighbours") (rel=? "neighbour" "friend"))
       '("neighbour" #t #f))
(check "a contact with no rel is in the default kind's lens"
       (resolve-lens "contact" '(((aid . "AID-x"))) "AID-me") '("AID-x"))

(display "\n── the predicate (built locally, not across the wire) ──\n")
(define friends (resolve-lens "friends" book "AID-me"))
(define p (lens-predicate friends))
(check "friend AID passes the predicate" (p "AID-ana") #t)
(check "non-friend AID fails" (p "AID-mama") #f)
(check "everyone-lens predicate is #f (means: no weighting)"
       (lens-predicate (resolve-lens "everyone" book "AID-me")) #f)

(test-summary!)
