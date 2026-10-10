;;; social/relationship-kinds.scm — the kinds a relationship is named by.
;;;
;;; A relationship is named in three places: the `rel` a person gives a
;;; contact in their book, the `relationship-type` a relationship credential
;;; carries ("I know SUBJECT as REL"), and the group or lens a rule names
;;; ("friends", `["in-group", "family"]`). All three read one vocabulary, from
;;; here: the kinds the app offers, each with its plural and its colour, and
;;; NORMALIZE-REL, which gives any spelling of a kind its one name.
;;;
;;; The set is open. A rel outside the table is a kind of its own and
;;; normalizes to itself, so a person's own word for a relationship is a lens
;;; and a group the day they use it.
;;;
;;; ui/app/rel-catalogue.ts is the browser's copy (tools/emit/rel-emit.scm).

(define-module (playnet social relationship-kinds)
  #:use-module (srfi srfi-1)
  #:export (%relationship-kinds %default-rel
            kind-id kind-plural kind-colour
            normalize-rel rel=?))

;; (id plural colour) — the order the app offers them in. The first is the
;; kind a contact has before anyone says more.
(define %relationship-kinds
  '(("contact"   "contacts"   "#888888")
    ("friend"    "friends"    "#2c6e8a")
    ("family"    "family"     "#c2756a")
    ("colleague" "colleagues" "#7a6a8a")
    ("commons"   "commons"    "#3f8f6a")))

(define kind-id first)
(define kind-plural second)
(define kind-colour third)

(define %default-rel (kind-id (car %relationship-kinds)))

;; spellings that mean the default kind: the empty word, and the word
;; relationship credentials carried before the kinds had one table
(define %default-spellings '("" "knows"))

(define (normalize-rel rel)
  "REL (a string, a symbol or #f) as its kind's one name: lower case, a
   listed kind's plural read as the kind, the empty word as the default. A
   word outside the table is its own kind."
  (let ((r (string-downcase
            (string-trim-both
             (cond ((string? rel) rel)
                   ((symbol? rel) (symbol->string rel))
                   (else ""))))))
    (cond ((member r %default-spellings) %default-rel)
          ((find (lambda (k) (or (string=? r (kind-id k)) (string=? r (kind-plural k))))
                 %relationship-kinds)
           => kind-id)
          (else r))))

(define (rel=? a b)
  "Do A and B name the same kind? Listed kinds meet through NORMALIZE-REL; a
   person's own word meets its own plural (neighbour / neighbours)."
  (let ((x (normalize-rel a)) (y (normalize-rel b)))
    (or (string=? x y)
        (string=? (string-append x "s") y)
        (string=? x (string-append y "s")))))
