;;; test-berlin-food-chain.scm — one chain, two jurisdictions, no law in the recipe.
;;;
;;; Berlin's reclaim → store → distribute chain is DATA over the generic
;;; seed-food-chain! (recipes/food-chain-seed.scm). This test holds that data
;;; fixed and varies only WHERE it runs, to show the two properties the split is
;;; for:
;;;
;;;   THE PLANNER SIDE — the chain is ordinary VF records, so the convex solve
;;;     reads it with no special case, and its `store` stage carries goods across
;;;     a period through a keep-in-place Kühlraum. Helper hours exist on Monday
;;;     only; the Fairteiler is wanted on Tuesday; the cold room is the only way
;;;     across, so `fill` is the honest discriminator.
;;;
;;;   THE LEGAL SIDE — the SAME seeded processes meet a different bill in Berlin
;;;     than in Laramie County, Wyoming. Berlin's demands arrive from a dropped
;;;     file (docs/legal/contexts/de.sexp); Wyoming's from the food-freedom belt.
;;;     Neither jurisdiction is named anywhere in the recipe: the chain declares
;;;     crossings, the fold prices them.
;;;
;;;   AND THE SITE DECIDES ONE CROSSING — the same chain with its Fairteiler on
;;;     public street land trips `feed-in-public`, and Berlin answers with a
;;;     Sondernutzungserlaubnis. One flag in the data, a heavier legal exterior,
;;;     zero engine change.
;;;
;;; Run: guile -L module tests/scope/test-berlin-food-chain.scm

(use-modules (playnet test harness) (playnet knowledge recipes store) (playnet knowledge recipes berlin-food-seed) (playnet scope root) (playnet vf schemas) (srfi srfi-1) (playnet scope live)
             (goblins) (goblins vat) (goblins utils hashmap)
             (srfi srfi-1) (ice-9 format))

;; tests run from the repository root (the Run: line); the root is resolved by
;; its marker rather than by current-filename, which is #f or -L-relative
;; depending on how the file was loaded — both wrong for building paths.
(define root (or (and (file-exists? "module/playnet/solve/engine.scm") (getcwd))
                 (error "run this test from the repository root")))
(use-modules (playnet legal crossings))
(use-modules (playnet legal registry))
(use-modules (playnet vf facts places))
(use-modules (playnet knowledge law context-pack))
(use-modules (playnet knowledge catalogues us-states-fips))
(use-modules (playnet knowledge worlds free-food-distribution))   ; the US belts + the packs
(use-modules (playnet legal gate))
(use-modules ((playnet solve engine) #:select (set-period-length!)))
;; A period here is a WEEK: the seeded chain names its weekdays (Tuesday's sort), and this plan is one period over all of them.
(set-period-length! 1.0 "week")

;; the engine's container table, read the way test-berlin-live-scope reads live
;; internals — it lives in the engine, which is loaded into (playnet scope live).
(define (live-stationary) (@@ (playnet scope live) *stationary*))

(define (empty-recipe-store)
  (spawn ^recipe-store (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)
                       (hashmap) (hashmap) (hashmap) (hashmap) (hashmap)))

;;; ─── the bill for one seeded process at one place ─────────────────────────
;;; Crossings off the REAL records, path off the REAL tree, demands off the REAL
;;; rule library — the legal/gate.scm path, with nothing hand-listed.
(define (process-bill rs place-path proc-id)
  (let* ((flows (legal-proc-flows rs proc-id))
         (crossings (process-crossings rs proc-id))
         (ctx (legal-context #:crossings crossings #:place-path place-path #:act 'food)))
    (call-with-values (lambda () (legal-demands ctx #:rules *pack-rules*))
      (lambda (bill hits) (list bill hits crossings)))))

(define (demand-names bill) (map demand-name (append-map cdr bill)))
(define (path-of id) (jurisdiction-path id place-parent-of))

;;; ─── seed the chain, then read it back as records for the convex solve ────
(define (chain-records rs recipe-id)
  (let* ((chain ($ rs 'get-process-chain recipe-id))
         (pids  (map recipe-process-id chain))
         (flows (append-map (lambda (p)
                              (let ((io ($ rs 'flows-for-process p)))
                                (append (car io) (cdr io))))
                            pids)))
    (values chain flows)))

(define vat (spawn-vat))

(define seeded
  (with-vat vat
    (let ((indoor (empty-recipe-store))
          (public (empty-recipe-store)))
      (seed-berlin-food-recipe! indoor)
      (seed-berlin-food-recipe! public #:public-handout? #t #:id "recipe-berlin-food-public")
      (call-with-values (lambda () (chain-records indoor "recipe-berlin-food-chain"))
        (lambda (procs flows)
          (list indoor public procs flows
                ;; the goods' specs, for the solve's keep-in-place table
                (map (lambda (id) ($ indoor 'get-resource-spec id))
                     '("spec-bfs-ueberschuss" "spec-bfs-gesichtet" "spec-bfs-fairteiler"
                       "spec-bfs-kuehlraum" "spec-bt-cargo-bike" "spec-bfs-helfer"))))))))

(define rs-indoor (list-ref seeded 0))
(define rs-public (list-ref seeded 1))
(define chain-procs (list-ref seeded 2))
(define chain-flows (list-ref seeded 3))
(define chain-specs (list-ref seeded 4))

(display "\n── the chain, as records the convex planner reads ──\n")
(format #t "  stages: ~a\n" (map recipe-process-id chain-procs))
(check-pred "four stages seeded" (= 4 (length chain-procs)))
;; pickup + dropoff, NOT move: only that pair builds a relocation arc
;; (compile-process routes `move` to `moved` and pickup/dropoff to `relocated`,
;; and the transport branch reads `relocated`). A store stage written with `move`
;; runs a free column and carries nothing.
(check-pred "the store stage PICKS UP its good (the pair that builds the arc)"
            (any (lambda (f) (and (eq? 'pickup (recipe-flow-action f))
                                  (equal? "recipe-berlin-food-chain/kuehlung"
                                          (recipe-flow-recipe-input-of f))))
                 chain-flows))
(check-pred "… and DROPS IT OFF, which is where the time edge lands"
            (any (lambda (f) (and (eq? 'dropoff (recipe-flow-action f))
                                  (equal? "recipe-berlin-food-chain/kuehlung"
                                          (recipe-flow-recipe-output-of f))))
                 chain-flows))
(check-pred "the cold room is keep-in-place (what makes the column temporal)"
            (resource-specification-keep-in-place
             (find (lambda (s) (equal? "spec-bfs-kuehlraum" (resource-specification-id s)))
                   chain-specs)))

;;; ─── the convex solve, on a LIVE scope ───────────────────────────────────
;;; The gateway's own path (spawn-scope-root → seed → plan-scope), the same one
;;; test-berlin-live-scope.scm runs for the growing half: the seeded chain is
;;; ordinary VF records, so the live convex solve reads it with no special case.
;;;
;;; THE CARRY. Helper hours exist on Monday only; the Fairteiler is wanted on
;;; Tuesday. The cold room is the only way across, so period-1 delivery is the
;;; honest discriminator — and it now works, which took three fixes:
;;;   · the scope's keep-in-place specs reach the engine (live.scm → #:specs),
;;;     including through the robust branch, where they were dropped;
;;;   · a period nobody is available in is capped at zero rather than left
;;;     unbounded, so a good actually HAS to cross time to arrive;
;;;   · the store stage uses pickup/dropoff, the pair that builds the arc.
(define PLACE "berlin")

(define solved
  (let ((root (with-vat vat (spawn-scope-root "Berlin-Fairteiler"))))
    (with-vat vat
      (seed-berlin-food-scope! root #:place PLACE)
      (let ((r (plan-scope->alist root
                 #:demand (list (cons (format #f "spec-bfs-fairteiler#~a@0" PLACE) 60.0))
                 #:periods '(0 1)
                 #:backend 'native-c #:allow-infeasible? #t)))
        (list (or (assq-ref r 'met) 0)
              ;; the containers the engine was told about, for this solve
              (live-stationary))))))

(define met (car solved))
(define stationary (cadr solved))

(display "\n── the live convex solve over the seeded chain ──\n")
(format #t "  demand met            : ~,3f\n" met)
(format #t "  containers declared   : ~a\n" stationary)
(check-pred "the live convex solve reads the seeded chain and meets the want"
            (> met 0.99))
(check-pred "the cold room reaches the engine AS a container (through the robust branch)"
            (member "spec-bfs-kuehlraum" stationary))

;;; ─── the legal exterior : same chain, two jurisdictions ──────────────────
(define bills
  (with-vat vat
    (list (process-bill rs-indoor (path-of "berlin")        "recipe-berlin-food-chain/fairteiler")
          (process-bill rs-indoor (path-of "us-56-laramie") "recipe-berlin-food-chain/fairteiler")
          (process-bill rs-public (path-of "berlin")        "recipe-berlin-food-public/fairteiler"))))
(define berlin-bill  (list-ref bills 0))
(define laramie-bill (list-ref bills 1))
(define public-bill  (list-ref bills 2))

(define berlin-names  (demand-names (car berlin-bill)))
(define laramie-names (demand-names (car laramie-bill)))
(define public-names  (demand-names (car public-bill)))

(display "\n── the SAME handout stage, folded at two places ──\n")
(format #t "  crossings, off the records : ~a\n" (caddr berlin-bill))
(format #t "  berlin          : ~a\n" berlin-names)
(format #t "    rules         : ~a\n" (map legal-rule-label (cadr berlin-bill)))
(format #t "  us-56-laramie   : ~a\n" laramie-names)
(format #t "    rules         : ~a\n" (map legal-rule-label (cadr laramie-bill)))

(check-pred "the handout's crossings come off the records (share-food)"
            (memq 'share-food (caddr berlin-bill)))
(check-pred "Berlin demands the §43 IfSG Belehrung — from the dropped context pack"
            (member "Belehrung nach §43 IfSG" berlin-names))
(check-pred "Berlin demands the Lebensmittelunternehmer registration"
            (member "Registrierung als Lebensmittelunternehmer" berlin-names))
(check-pred "Wyoming answers the same chain with the food-freedom notice"
            (member "Homemade-food notice" laramie-names))
(check-pred "… and asks for no German credential"
            (not (member "Belehrung nach §43 IfSG" laramie-names)))
(check-pred "the two bills differ — the recipe is identical"
            (not (equal? (sort berlin-names string<?) (sort laramie-names string<?))))

(display "\n── the same chain, its Fairteiler out on the pavement ──\n")
(format #t "  berlin (public) : ~a\n" public-names)
(check-pred "a public handout also trips feed-in-public"
            (memq 'feed-in-public (caddr public-bill)))
(check-pred "… which Berlin answers with a Sondernutzungserlaubnis"
            (member "Sondernutzungserlaubnis (öffentliches Straßenland)" public-names))
(check-pred "the indoor Fairteiler owes no street-land permit"
            (not (member "Sondernutzungserlaubnis (öffentliches Straßenland)" berlin-names)))

;;; ─── the books: STRANDED is not STARVED ──────────────────────────────────
;;; With Tuesday in the horizon, the raw-lint has something to say about this
;;; chain, and which WORD it uses is the whole finding.
;;;
;;; With the surplus set out, the books are whole. The cold room keeps what
;;; stands on it: Monday's surplus is starting inventory, the keep column
;;; carries it to Tuesday, and Tuesday's pickup, sort and handout all run
;;; on it. Nothing is drawn where nothing makes it, so the lint says nothing.
;;;
;;; Take the surplus away and the same chain says two different things, each
;;; for the right good. The surplus itself is STARVED: consumed, produced at
;;; no cell, stocked nowhere — a hole in the books. Everything downstream of
;;; it — the collected food, the sorted food — is STRANDED: a real column
;;; makes each of them, and that column stands on the hole. The prune removes
;;; the dead columns before the solve, and reads them out in the lint's two
;;; words on the way; a CI gate on "starved" stays a gate on goods that would
;;; conjure themselves, and never trips on the casualties beneath one.
(define (lint-of ueberschuss-kg)
  ;; the report goes to the error port, and the solve runs in the VAT's thread —
  ;; so the rebinding has to happen inside with-vat, where that thread can see it.
  (let ((err (open-output-string))
        (root (with-vat vat (spawn-scope-root "Berlin-lint"))))
    (with-vat vat
      (seed-berlin-food-scope! root #:place PLACE #:ueberschuss-kg ueberschuss-kg)
      (with-error-to-port err
        (lambda ()
          (plan-scope->alist root
            #:demand (list (cons (format #f "spec-bfs-fairteiler#~a@0" PLACE) 60.0))
            #:periods '(0 1) #:backend 'native-c #:allow-infeasible? #t))))
    (get-output-string err)))

(define lint-normal  (begin (setenv "PLANNER_RAW_LINT" "1") (lint-of 400.0)))
(define lint-nosurpl (lint-of 0.0))
(unsetenv "PLANNER_RAW_LINT")

;; the goods each RAW-LINT line names, by the word it uses
(define (lint-names report word)
  (let loop ((lines (string-split report #\newline)) (acc '()))
    (cond ((null? lines) (delete-duplicates acc))
          ((and (string-contains (car lines) "[RAW-LINT]") (string-contains (car lines) word))
           (loop (cdr lines)
                 (append (let ((at (string-contains (car lines) ": (")))   ; the list the line ends on
                           (if at
                               (call-with-input-string (substring (car lines) (+ at 2)) read)
                               '()))
                         acc)))
          (else (loop (cdr lines) acc)))))

(define stranded-nosurpl (lint-names lint-nosurpl "stranded"))
(define starved-nosurpl  (lint-names lint-nosurpl "starved"))

(display "\n── what the raw-lint says about the chain's books ──\n")
(format #t "  400 kg surplus : ~a\n"
        (if (or (string-contains lint-normal "stranded") (string-contains lint-normal "starved"))
            "a finding" "— (whole)"))
(format #t "  no surplus     : starved ~a · stranded ~a\n" starved-nosurpl stranded-nosurpl)

(check-pred "with the surplus set out, the cold room carries it and the books are whole — no word"
            (not (or (string-contains lint-normal "stranded") (string-contains lint-normal "starved"))))
(check-pred "take the surplus away and the surplus IS starved — a hole in the books"
            (member "spec-bfs-ueberschuss" starved-nosurpl))
(check-pred "… and the collected food downstream is STRANDED — a real column makes it, on the hole"
            (member "recipe-berlin-food-chain/good-abholung" stranded-nosurpl))
(check-pred "… and neither word names the other's good"
            (and (not (member "spec-bfs-ueberschuss" stranded-nosurpl))
                 (not (member "recipe-berlin-food-chain/good-abholung" starved-nosurpl))))

(display "\n")
(test-summary!)
