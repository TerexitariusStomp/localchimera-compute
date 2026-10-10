;;; test-verteilstation-obligations.scm — the bill IS the calendar.
;;;
;;; Design: docs/planning/food/berlin-verteilstation-requirements.md, from the
;;; Verbraucherzentrale Berlin's Leitfaden (vendored at
;;; docs/reference/berlin-food/leitfaden-verteilstationen.pdf), which implements
;;; the Berliner Mindestanforderungen (SenJustV 2016) and was written with the
;;; Lebensmittelüberwachung Berlin-Pankow.
;;;
;;; A Fairteiler cabinet is a PUBLIC FRIDGE. The Berlin chain declares that on the
;;; container spec (`crossing:public-fridge`, berlin-food-seed.scm) and says
;;; nothing else; Berlin answers from a dropped file with registration, an ANNUAL
;;; LMHV hygiene training, standing supervision, a documentation folder reviewed
;;; MONTHLY, the notices and the recall duty.
;;;
;;; The recurring ones carry their cadence on the demand itself (`#:renew`), so
;;; the compliance calendar falls out of the SAME fold that priced the bill — no
;;; second derivation, no hand-written list of what expires when.
;;;
;;; Run: guile -L module tests/planner/test-verteilstation-obligations.scm

(use-modules (playnet test harness) (playnet knowledge recipes store) (playnet knowledge recipes berlin-food-seed) (playnet legal crossings) (playnet observation observer) (playnet vf schemas) (playnet vf beyond lot) (srfi srfi-1)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

(define here (dirname (current-filename)))
(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet vf facts places))
(use-modules (playnet knowledge law context-pack))
(use-modules (playnet knowledge catalogues us-states-fips))
(use-modules (playnet knowledge worlds free-food-distribution))
(use-modules (playnet legal gate))
(use-modules (playnet legal compliance))

(define (empty-recipe-store)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))

(define %station "scope:kiezkueche")
(define %amt "auth:bezirksamt-lebensmittelaufsicht")
(define %today "2026-08-07")
(define %horizon "2027-08-07")

;;; ─── fold the bill for the STORE stage, where the cabinet lives ───────────
(define vat (spawn-vat))

(define folded
  (with-vat vat
    (let ((rs (empty-recipe-store)))
      (seed-berlin-food-recipe! rs)
      (let* ((proc "recipe-berlin-food-chain/kuehlung")
             (flows (legal-proc-flows rs proc))
             (crossings (process-crossings rs proc))
             (ctx (legal-context #:crossings crossings
                                 #:place-path (jurisdiction-path "berlin" place-parent-of)
                                 #:act 'food)))
        (call-with-values (lambda () (legal-demands ctx #:rules *pack-rules*))
          (lambda (bill hits) (list bill hits crossings)))))))

(define bill (list-ref folded 0))
(define hits (list-ref folded 1))
(define crossings (list-ref folded 2))
(define names (map demand-name (append-map cdr bill)))

(display "\n── the Fairteiler cabinet, folded at berlin ──\n")
(format #t "  crossings off the records : ~a\n" crossings)
(format #t "  rules that fired          : ~a\n" (map legal-rule-label hits))
(for-each (lambda (d)
            (format #t "    ~46a ~a~a\n" (demand-name d) (demand-kind d)
                    (let ((r (demand-renew d))) (if r (format #f "  renew ~a" r) ""))))
          (append-map cdr bill))

(check-pred "the cabinet trips public-fridge — declared on the spec, not hand-listed"
            (memq 'public-fridge crossings))
(check-pred "Berlin demands the Verteilstation be registered with the Bezirk"
            (member "Registrierung der Verteilstation" names))
(check-pred "… an LMHV §4 hygiene training per handler"
            (member "Hygiene-/HACCP-Schulung nach §4 LMHV" names))
(check-pred "… standing supervision of the site"
            (member "Ständige Aufsicht der Verteilstation" names))
(check-pred "… the documentation folder"
            (member "Dokumentation der Verteilstation" names))
(check-pred "… the notices at the station"
            (member "Hinweisschilder an der Verteilstation" names))
(check-pred "… and passing on recalls"
            (member "Lebensmittelwarnungen weitergeben" names))
(check-pred "the IfSG Erstbelehrung fee rides along as a `pay`"
            (member "Gebühr IfSG-Erstbelehrung" names))

;;; ─── the calendar, derived from that same bill ───────────────────────────
;;; The station HOLDS both recurring things, each with a real expiry. Nothing
;;; below names a spec: `bill->specs+cadence` reads the cadence off the demands.
;; a held credential: a resource conforming to the demand-name spec, held by the
;; station, expiring via its lot — the same shape test-compliance.scm uses.
(define (held id spec expires)
  (make-economic-resource
    #:id id #:name spec #:conforms-to spec #:classified-as '("credential")
    #:onhand-quantity (make-measure 1 "cert")
    #:primary-accountable %station #:state "active"
    #:lot (make-batch-lot-record (string-append id ":lot") #f expires)))

(define cal
  (with-vat vat
    (let ((obs (spawn ^observer (empty-observer-state) '())))
      ($ obs 'seed-resource (held "cert-hygiene" "Hygiene-/HACCP-Schulung nach §4 LMHV"
                                  "2026-09-30"))
      ($ obs 'seed-resource (held "ordner" "Dokumentation der Verteilstation"
                                  "2026-08-31"))
      (list (bill->specs+cadence bill)
            (bill-obligations bill obs %station %amt %today %horizon)))))

(define cadences (car cal))
(define due (cadr cal))

(display "\n── the calendar, off the same fold ──\n")
(for-each (lambda (c) (format #t "  cadence ~46a ~a\n" (car c) (cdr c))) cadences)
(for-each (lambda (ob)
            (format #t "  DUE ~a  ~46a ~a → ~a\n"
                    (commitment-due ob) (commitment-resource-conforms-to ob)
                    (commitment-action ob) (commitment-receiver ob)))
          due)

(check-pred "only the RECURRING demands enter the calendar"
            (= 2 (length cadences)))
(check-pred "the hygiene training renews before it expires"
            (assoc "Hygiene-/HACCP-Schulung nach §4 LMHV" cadences))
(check-pred "the documentation folder recurs monthly"
            (equal? '(every . month)
                    (assoc-ref cadences "Dokumentation der Verteilstation")))
(check-pred "two obligations fall due inside the year" (= 2 (length due)))
(check-pred "they are sorted by due date"
            (or (< (length due) 2)
                (string<=? (commitment-due (car due)) (commitment-due (cadr due)))))
(check-pred "the renewal is due 30 days BEFORE the training expires (2026-08-31)"
            (equal? "2026-08-31"
                    (commitment-due
                     (find (lambda (o) (equal? "Hygiene-/HACCP-Schulung nach §4 LMHV"
                                               (commitment-resource-conforms-to o))) due))))
(check-pred "a renewal lowers to `modify`, not a fresh `produce`"
            (eq? 'modify (commitment-action
                          (find (lambda (o) (equal? "Hygiene-/HACCP-Schulung nach §4 LMHV"
                                                    (commitment-resource-conforms-to o))) due))))
(check-pred "every obligation is owed to the authority"
            (every (lambda (o) (equal? %amt (commitment-receiver o))) due))

;;; ─── and the same station elsewhere owes none of it ──────────────────────
(define laramie-names
  (map demand-name
       (append-map cdr
         (call-with-values
           (lambda ()
             (legal-demands
              (legal-context #:crossings crossings
                             #:place-path (jurisdiction-path "us-56-laramie" place-parent-of)
                             #:act 'food)
              #:rules *pack-rules*))
           (lambda (b h) b)))))

(display "\n── the same cabinet in Laramie County, Wyoming ──\n")
(format #t "  ~a\n" laramie-names)
(check-pred "Wyoming answers a public fridge with nothing of Berlin's"
            (not (any (lambda (n) (member n laramie-names))
                      '("Registrierung der Verteilstation"
                        "Hygiene-/HACCP-Schulung nach §4 LMHV"
                        "Dokumentation der Verteilstation"))))

;;; ─── the CHANNEL MATRIX : (crossing × channel), not either alone ─────────
;;; Both rulebooks say the same thing and neither could be expressed before: a
;;; home-cooked pot may pass hand to hand and may NOT be left in a Fairteiler.
;;; The rule turns on the PAIR — forbidding the crossing alone would prune the
;;; chain wherever home-cooked food appears, and forbidding the channel alone
;;; would ban the Fairteiler. Together they prune exactly the forbidden column.
(define* (pot-bill channel #:optional (crossing 'home-kitchen) (nm "Ein Topf Suppe"))
  (with-vat vat
    (let ((rs (empty-recipe-store)))
      ($ rs 'add-resource-spec
         (make-resource-specification #:id "spec-pot" #:name nm
           #:resource-classified-as (list "food" (string-append "crossing:" (symbol->string crossing))
                 "crossing:share-food")
           #:default-unit-of-resource "kg"))
      ($ rs 'add-recipe-process (make-recipe-process #:id "hand-on" #:name "Weitergabe"))
      ($ rs 'add-recipe-flow
         (make-recipe-flow #:id "f<" #:action 'consume #:resource-conforms-to "spec-pot"
           #:resource-classified-as (and channel (list (string-append "channel:" (symbol->string channel))))
           #:resource-quantity (make-measure 1.0 "kg") #:recipe-input-of "hand-on"))
      (let* ((flows (legal-proc-flows rs "hand-on"))
             (resolve (lambda (id) ($ rs 'get-resource-spec id)))
             (ctx (legal-context #:crossings (recipe-crossings flows resolve)
                                 #:channel (recipe-channel flows resolve)
                                 #:place-path (jurisdiction-path "berlin" place-parent-of)
                                 #:act 'food)))
        (call-with-values (lambda () (legal-demands ctx #:rules *pack-rules*))
          (lambda (bill hits)
            (list (recipe-channel flows resolve)
                  (map demand-name (or (assq-ref bill 'forbid) '()))
                  (bill-stance bill hits))))))))

(define by-hand (pot-bill 'personal))
(define by-box  (pot-bill 'non-personal))
(define unsaid  (pot-bill #f))

(display "\n── the same home-cooked pot, handed on two ways ──\n")
(for-each (lambda (r nm)
            (format #t "  ~14a channel ~14a → ~a\n" nm (or (car r) "(unstated)")
                    (case (caddr r) ((off) (car (cadr r))) ((soft) "in doubt") (else "may go"))))
          (list by-hand by-box unsaid) '("hand to hand" "into the box" "unspecified"))

(check-pred "the channel is read off the record, like a crossing"
            (and (eq? 'personal (car by-hand)) (eq? 'non-personal (car by-box))))
(check-pred "hand to hand, a home-cooked pot may go"
            (null? (cadr by-hand)))
(check-pred "into a Fairteiler it may NOT — the pair fires, not the crossing alone"
            (pair? (cadr by-box)))
(check-pred "an unstated channel is doubted: the rule may apply, so it stands as a doubt, never as a sure prohibition"
            (and (eq? 'soft (caddr unsaid)) (eq? 'off (caddr by-box))
                 (not (stance-forbids? (caddr by-hand)))))
;; and the chain's own handout is unaffected: rescued surplus is not home-cooked
;; and appears on no Stage-1 line, so the same non-personal channel — the very
;; channel every rule above turns on — carries it perfectly legally. This is the
;; whole point of guarding on the PAIR: the cabinet stays open for what belongs
;; in it. Folded from the REAL chain's Fairteiler stage, channel and all.
(define fairteiler-forbids
  (with-vat vat
    (let ((rs (empty-recipe-store)))
      (seed-berlin-food-recipe! rs)
      (let* ((proc "recipe-berlin-food-chain/fairteiler")
             (flows (legal-proc-flows rs proc))
             (resolve (lambda (id) ($ rs 'get-resource-spec id)))
             (ctx (legal-context #:crossings (process-crossings rs proc)
                                 #:channel (recipe-channel flows resolve)
                                 #:place-path (jurisdiction-path "berlin" place-parent-of)
                                 #:act 'food)))
        (call-with-values (lambda () (legal-demands ctx #:rules *pack-rules*))
          (lambda (bill hits) (or (assq-ref bill 'forbid) '())))))))

(format #t "  the chain's own Fairteiler stage → ~a\n"
        (if (null? fairteiler-forbids) "may go" (map demand-name fairteiler-forbids)))
(check-pred "the Berlin chain's own Fairteiler handout is NOT forbidden"
            (null? fairteiler-forbids))

;;; ─── the whole Stage-1 list, one good at a time ──────────────────────────
;;; The Leitfaden §7 "nicht geeignet" list is thirteen items, and it is thirteen
;;; ROWS in emit-de-context.scm — one guard shape, one row each. What matters is
;;; that every one behaves like the two written by hand: forbidden into the
;;; cabinet, permitted hand to hand.
;;;
;;; So the list is READ OFF THE PACK rather than retyped here. A test that keeps
;;; its own copy of the thing it checks is testing the copy: the fourteenth row
;;; would be added to the generator, the test would still pass, and nobody would
;;; learn that the row was never exercised. Instead the rules themselves say
;;; which crossings are gated on a channel, and the crossing catalogue — the same
;;; open vocabulary the law face glosses — says what each one is.
(define (channel-gated-crossings rules)
  "Every crossing some rule FORBIDS on a stated channel, from the loaded pack."
  (delete-duplicates
   (filter-map
    (lambda (r)
      (and (any (lambda (d) (eq? 'forbid (demand-kind d))) (legal-rule-demands r))
           (let ((g (legal-rule-guard-form r)))
             (and (find-in-form g 'via-channel)
                  (find-in-form g 'on-crossing)))))
    rules)))

;; the argument of the first (TAG x) anywhere in a guard form
(define (find-in-form form tag)
  (cond ((not (pair? form)) #f)
        ((and (eq? tag (car form)) (pair? (cdr form))) (cadr form))
        (else (any (lambda (sub) (find-in-form sub tag)) form))))

(define stage-1-crossings (channel-gated-crossings *pack-rules*))

(display "\n── Leitfaden §7, the not-suitable list, item by item ──\n")
(define stage-1-results
  (map (lambda (x)
         (let* ((nm   (or (crossing-gloss x) (symbol->string x)))
                (box  (pot-bill 'non-personal x nm))
                (hand (pot-bill 'personal     x nm)))
           (format #t "  ~52a box: ~a   hand: ~a\n" nm
                   (if (pair? (cadr box))  "FORBIDDEN" "may go   ")
                   (if (pair? (cadr hand)) "forbidden"  "may go"))
           (list x (pair? (cadr box)) (pair? (cadr hand)))))
       stage-1-crossings))

(check-pred "the pack states a Stage-1 list, and it is the Leitfaden's thirteen"
            (= 13 (length stage-1-crossings)))
(check-pred "every Stage-1 good is forbidden into an unattended Fairteiler"
            (every cadr stage-1-results))
(check-pred "…and every one of them may still pass hand to hand"
            (not (any caddr stage-1-results)))
;; the negative control: a good on NO Stage-1 line is unaffected by any of them.
(check-pred "a good the list does not name goes into the box freely"
            (null? (cadr (pot-bill 'non-personal 'recover-surplus "Gerettetes Brot"))))

(display "\n")
(test-summary!)
