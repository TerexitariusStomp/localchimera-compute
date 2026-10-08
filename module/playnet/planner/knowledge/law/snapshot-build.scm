;;; law/snapshot-build.scm — the law-face snapshot builder, SHARED by the
;;; offline emitter (tools/emit-law-snapshot.scm) and the live legal-snapshot
;;; service method (planner service.scm). `(law-snapshot-string)` returns the
;;; snapshot JSON from the already-loaded legal fold + activity catalogue +
;;; reform mirrors — one builder, offline + live.
;;;
;;; Assumes loaded first: legal/registry.scm, catalogues/us-states-fips.scm, reform.scm,
;;; worlds/free-food-distribution.scm, law/activities.scm, law/reform-mirrors.scm.

(define-module (playnet planner knowledge law snapshot-build)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:use-module (playnet utils json-emit)
  #:use-module (playnet planner vf schemas)
  #:use-module (playnet planner legal crossings)
  #:use-module (playnet planner legal registry)
  #:use-module (playnet planner legal reform)
  #:use-module (playnet planner facts places)
  #:use-module ((playnet planner knowledge law context-pack) #:select (*pack-rules* current-legal-rules place-endpoints bill-at))
  #:use-module (playnet planner knowledge catalogues us-states-fips)
  #:use-module (playnet planner knowledge law aspects)
  #:use-module (playnet planner knowledge law reform-mirrors)
  #:use-module (playnet planner knowledge law structural-demands)
  #:use-module (playnet planner knowledge law incumbent-readings)
  #:use-module (playnet planner knowledge law protections)
  #:use-module (playnet planner knowledge worlds free-food-distribution)
  #:use-module (playnet planner knowledge law activities)
  #:re-export (jesc J:s J:n J:b J:a J:o J:sa J:syms)
  #:export (%bill-json-keys demand->json bill->json hits->json protections->json members-at mode->json activity-block place->json extra->json %snapshot-place-kinds snapshot-place-ids extra->json-pairs registered-place->json catalogue-crossings recipe->json member->json place-name place-nation bill-mirrored demand-imposer place-program place-program->json program-links reading-pairs reading->json tiers->json reform-program-entries program-entry->json structural-demand->json structural-program->json bill->jb arc->json rules-with law-snapshot-string))

;;; ─── a demand → json ──────────────────────────────────────────────────────
(define (demand->json d)
  (let ((det (demand-detail d)))
    (J:o `(("kind"   . ,(J:s (demand-kind d)))
           ("name"   . ,(J:s (demand-name d)))
           ("rides"  . ,(if (demand-rides d) (J:s (demand-rides d)) "null"))
           ("spec"   . ,(if (demand-spec d) (J:syms (demand-spec d)) "[]"))
           ("issuer" . ,(let ((v (assq-ref det 'issuer))) (if v (J:s v) "null")))
           ("per"    . ,(let ((v (assq-ref det 'per)))    (if v (J:s v) "null")))
           ("to"     . ,(let ((v (assq-ref det 'to)))     (if v (J:s v) "null")))
           ("discloses" . ,(let ((v (assq-ref det 'discloses))) (if (pair? v) (J:syms v) "[]")))
           ("direction" . ,(let ((v (assq-ref det 'direction))) (if v (J:s v) "null")))
           ("reason" . ,(let ((v (assq-ref det 'reason))) (if v (J:s v) "null")))
           ("reform" . ,(let ((rf (demand-reform d)))   ; the (L,I,D) cells, if any
                          (if rf (J:o `(("redundant" . ,(J:syms (or (assq-ref rf 'redundant) '())))
                                        ("absorbFirst" . ,(J:syms (or (assq-ref rf 'absorb-first) '())))
                                        ("reproduceUnwanted" . ,(J:syms (or (assq-ref rf 'reproduce-unwanted) '())))
                                        ("transform" . ,(J:syms (or (assq-ref rf 'transform-law) '())))
                                        ("unmapped"  . ,(J:syms (or (assq-ref rf 'unmapped) '())))))
                              "null")))))))

;;; ─── bill (the fold output) → json + a numeric burden ─────────────────────
;;; burden is the engine's UNIVERSAL `bill-weight` (legal/registry.scm) — a
;;; property of any legal exterior, not of free food: a one-time registration
;;; is lighter than a per-event permit, a competence card heavier, a forbid
;;; dominant. forbid → 99 for JSON (the engine's +inf.0 isn't valid JSON).
;;; → (values json burden stance). HITS are the rules behind the bill and
;;; CROSSINGS what the activity trips: the stance (`bill-stance`) is read from
;;; all three, and it is the one statement of whether the thing can be done —
;;; `stance-forbids?` is what "forbidden" means. The crossings nobody has read
;;; here ride out beside it.
(define %bill-json-keys
  '((obtain-entity . "obtainEntity") (obtain-person . "obtainPerson")
    (pay . "pay") (tell . "tell") (forbid . "forbid")))
(define* (bill->json bill hits #:optional (crossings '()))
  (let ((w (bill-weight bill))
        (stance (bill-stance bill hits #:crossings crossings)))
    (values
     (J:o `(("stance" . ,(J:s (symbol->string stance)))
            ("unread" . ,(J:a (map (lambda (c) (J:s (symbol->string c)))
                                   (bill-unread hits crossings))))
            ,@(map (lambda (k) (cons (assq-ref %bill-json-keys k)
                                     (J:a (map demand->json (bill-ref bill k)))))
                   %bill-keys)))
     (if (inf? w) 99 w)
     stance)))

;;; ─── rule hits at a place (provenance: which laws fired, with citations) ──
(define (hits->json hits)
  (J:a (map (lambda (r)
              (J:o `(("label"  . ,(J:s (legal-rule-label r)))
                     ("source" . ,(J:s (legal-rule-source r)))
                     ("asOf"   . ,(J:s (legal-rule-as-of r)))
                     ("confidence" . ,(J:s (legal-rule-confidence r)))
                     ("steward". ,(J:s (legal-rule-steward r))))))
            hits)))

(define (protections->json place-id)
  (J:a (map (lambda (p)
              (J:o `(("name"   . ,(J:s (protection-name p)))
                     ("activity" . ,(J:s (protection-activity p)))
                     ("shields". ,(J:s (or (protection-shields p) "")))
                     ("source" . ,(J:s (protection-source p))))))
            (protections-at place-id))))

;;; member recipe-ids operating at a place (exact place match)
(define (members-at place-id)
  (filter (lambda (m) (equal? place-id (assq-ref m 'place))) (ffd-member-list)))

;;; per-pathway bill at a place: each recipe trips its own crossings → its own
;;; legal exterior. Returns (id burden forbidden billjson).
;;; one MODE's bill at a place → json (the generic per-mode legal exterior).
(define (mode->json place-id m)
  (call-with-values (lambda () (mode-bill place-id m))
    (lambda (bill hits)
      (call-with-values (lambda () (bill->json bill hits (assq-ref m 'crossings)))
        (lambda (billjson burden stance)
          (J:o `(("id"    . ,(J:s (assq-ref m 'id)))
                 ("name"  . ,(J:s (assq-ref m 'name)))
                 ("kind"  . ,(J:s (assq-ref m 'kind)))
                 ("burden". ,(J:n burden))
                 ("forbidden" . ,(J:b (stance-forbids? stance)))
                 ("bill"  . ,billjson))))))))

;;; one ACTION at a place → json: every mode's bill, the lightest legal one
;;; (the headline), and the law that fires for the action here.
(define (activity-block place-id activity)
  (let* ((modes (activity-modes activity))
         (hl (activity-headline place-id activity))     ; (modeId burden forb) | #f
         (allcross (delete-duplicates (append-map (lambda (m) (assq-ref m 'crossings)) modes))))
    (call-with-values
        (lambda () (bill-at place-id allcross #:act (activity-act activity)))
      (lambda (fullbill hits)
        (J:o `(("headline"    . ,(J:n (if hl (cadr hl) 99)))
               ("recommended" . ,(if hl (J:s (car hl)) "null"))
               ("forbidden"   . ,(J:b (not hl)))
               ("modes"       . ,(J:a (map (lambda (m) (mode->json place-id m)) modes)))
               ("hits"        . ,(hits->json hits))))))))

(define (place->json id name parent extra-pairs)
  (J:o (append
        `(("name"   . ,(J:s name))
          ("parent" . ,(if parent (J:s parent) "null"))
          ("byActivity" . ,(J:o (map (lambda (a)
                                       (cons (assq-ref a 'id) (activity-block id a)))
                                     *activities*)))
          ("protections" . ,(protections->json id))
          ("program" . ,(place-program->json (place-program id)))
          ("structural" . ,(J:a (filter-map reading->json (readings-at-place id))))
          ("members" . ,(J:a (map (lambda (m)
                                    (J:o `(("scope" . ,(J:s (assq-ref m 'scope)))
                                           ("aid"   . ,(J:s (assq-ref m 'aid)))
                                           ("recipe". ,(J:s (assq-ref m 'recipe))))))
                                  (members-at id)))))
        extra-pairs)))

;;; ─── places, straight off the shared tree ─────────────────────────────────
;;; Every registered place emits the same way: its level (`kind`), its parent,
;;; whatever `extra` its registrar attached (a FIPS key, an ISO code, an AGS
;;; key), and its coordinates when it has them. A jurisdiction whose
;;; administrative levels this file has never heard of emits with no edit here.
;;; Roots (world, biosphere) carry no law of their own, so the snapshot starts
;;; at the nations.
(define %snapshot-place-kinds '(nation region locality))
(define (snapshot-place-ids)
  (filter (lambda (id) (memq (place-kind id) %snapshot-place-kinds)) (all-place-ids)))

;;; A place's extras are arbitrary data — a string INSEE code, a numeric
;;; population, a boolean `rnu`, a LIST of the regimes it stands `within`. Sent
;;; through J:s alone they all came out as strings, so a list arrived at the law
;;; face as the printed s-expression "(sage-… aoc-…)" and a boolean as the string
;;; "#f". Each shape gets the JSON it means.
(define (extra->json x)
  (cond ((boolean? x) (J:b x))
        ((number? x)  (J:n x))
        ((and (list? x) (pair? x)) (J:a (map extra->json x)))
        ((null? x) (J:a '()))
        (else (J:s x))))

(define (extra->json-pairs id)
  (map (lambda (kv) (cons (symbol->string (car kv)) (extra->json (cdr kv))))
       (place-extra id)))

(define (registered-place->json id)
  (let* ((kind (place-kind id))
         (lat (place-lat-of id)) (lng (place-long-of id)))
    (cons id
          (place->json id (place-name-of id) (place-parent-of id)
                       (append `(("kind" . ,(J:s kind)))
                               (extra->json-pairs id)
                               (if lat `(("lat"  . ,(J:n lat)))  '())
                               (if lng `(("long" . ,(J:n lng))) '())
                               (case kind
                                 ((nation)   '(("nation"   . "true")))
                                 ((locality) '(("locality" . "true")))
                                 (else '())))))))

;;; the crossings the catalogue actually uses, glossed from the OPEN catalogue
;;; (legal/crossings.scm) — the vocabulary is derived from the modes, never re-listed.
(define (catalogue-crossings)
  (sort (delete-duplicates
         (append-map (lambda (a)
                       (append-map (lambda (m) (assq-ref m 'crossings)) (activity-modes a)))
                     *activities*))
        (lambda (a b) (string<? (symbol->string a) (symbol->string b)))))

;;; ─── assemble the whole snapshot ──────────────────────────────────────────
(define (recipe->json r)
  (J:o `(("id"    . ,(J:s (assq-ref r 'id)))
         ("name"  . ,(J:s (assq-ref r 'name)))
         ("model" . ,(J:s (assq-ref r 'model)))
         ("crossings" . ,(J:syms (assq-ref r 'crossings)))
         ("steps" . ,(J:sa (assq-ref r 'steps)))
         ("note"  . ,(J:s (assq-ref r 'note))))))

(define (member->json m)
  (let ((place (assq-ref m 'place)))
    (J:o `(("scope" . ,(J:s (assq-ref m 'scope)))
           ("aid"   . ,(J:s (assq-ref m 'aid)))
           ("place" . ,(J:s place))
           ("placeName" . ,(J:s (place-name-of place)))
           ("recipe". ,(J:s (assq-ref m 'recipe)))))))

;;; name and nation both come off the shared tree (places.scm) — one lookup for
;;; every level, so a place at a level this file has never heard of still names.
(define (place-name id) (place-name-of id))
(define (place-nation id) (place-nation-of id))

;;; ─── the POLITICAL PROGRAM : the reform agenda, the move we can make first ──
;;; Every spec-bearing law the federation meets, with its (L,I,D) diff — the
;;; clauses it already verifies (ripe to demand the state's check WITHER), the
;;; ones to build first (ABSORB), and the duress-gap to TRANSFORM. Derived from
;;; the rule library + reform mirrors, the move we can make first leading. Not authored: the
;;; agenda falls out of the same fold as the bill (legal-crossings.md §8).
;;; ─── the program of ONE PLACE ─────────────────────────────────────────────
;;; The program is a reading of a place: the spec-bearing demands in force there
;;; and up its chain, each with the WAYS that trip it (activity and mode) and the
;;; level that imposes it. It falls out of the same fold as the bill — every mode
;;; of every activity is folded at the place, and a demand is in the program
;;; because a bill carries it.
;;;
;;; A demand may be in force for a way nobody has modelled as a mode: Berlin's
;;; rules for a public fridge turn on a channel, and no mode states one. Each such
;;; rule is folded once more under the crossings and channel its own guard names;
;;; a demand that survives is in force here with no way listed.
(define (bill-mirrored bill)           ; the demands of a bill that carry a spec
  (filter demand->mirror (append (bill-ref bill 'obtain-entity)
                                 (bill-ref bill 'obtain-person))))

(define (demand-imposer name hits path)   ; the nearest place on PATH whose rule states NAME;
                                          ; PATH is the place's own chain, then its regimes'
  (let ((places (append-map
                 (lambda (r)
                   (if (member name (map demand-name (legal-rule-demands r)))
                       (guard-places (legal-rule-guard-form r))
                       '()))
                 hits)))
    (find (lambda (id) (member id places)) path)))

(define %place-programs (make-hash-table))   ; place-id → rows, for one snapshot

(define (place-program place-id)
  "→ ((name ((activity-id . mode-id) …) imposer-place-id|#f) …), in fold order."
  (or (hash-ref %place-programs place-id #f)
      (let* ((endpoints (place-endpoints place-id))
             (path (apply append endpoints))
             (rows '()))
        (define (note! name via hits)
          (let ((cur (assoc name rows)))
            (cond (cur (when via
                         (set-car! (cdr cur) (lset-adjoin equal? (cadr cur) via))))
                  (else (set! rows
                              (append rows
                                      (list (list name (if via (list via) '())
                                                  (demand-imposer name hits path)))))))))
        (for-each
         (lambda (a)
           (for-each
            (lambda (m)
              (call-with-values (lambda () (mode-bill place-id m))
                (lambda (bill hits)
                  (for-each (lambda (d)
                              (note! (demand-name d)
                                     (cons (assq-ref a 'id) (assq-ref m 'id)) hits))
                            (bill-mirrored bill)))))
            (activity-modes a)))
         *activities*)
        (for-each
         (lambda (r)
           (let ((names (filter (lambda (n) (not (assoc n rows)))
                                (map demand-name (filter demand->mirror (legal-rule-demands r)))))
                 (form (legal-rule-guard-form r)))
             (when (and (pair? names) (not (border-rule? r)))
               (call-with-values
                   (lambda ()
                     ;; the act is unstated: this lists what the rule could
                     ;; ask of any act at the place
                     (bill-at place-id (guard-atoms 'on-crossing form)
                              #:act #f
                              #:channel (let ((c (guard-atoms 'via-channel form)))
                                          (and (pair? c) (car c)))))
                 (lambda (bill hits)
                   (when (memq r hits)
                     (for-each (lambda (d)
                                 (when (member (demand-name d) names)
                                   (note! (demand-name d) #f hits)))
                               (bill-mirrored bill))))))))
         (current-legal-rules))
        (hash-set! %place-programs place-id rows)
        rows)))

(define (place-program->json rows)
  (J:a (map (lambda (row)
              (J:o `(("name" . ,(J:s (car row)))
                     ("via"  . ,(J:a (map (lambda (v)
                                            (J:o `(("activity" . ,(J:s (car v)))
                                                   ("mode"     . ,(J:s (cdr v))))))
                                          (cadr row))))
                     ("by"   . ,(if (caddr row) (J:s (caddr row)) "null")))))
            rows)))

;;; every way that trips a demand, over all the places the snapshot carries
(define (program-links name)
  (delete-duplicates
   (append-map (lambda (id)
                 (let ((row (assoc name (place-program id))))
                   (if row (cadr row) '())))
               (snapshot-place-ids))))

;;; ─── a place's reading of a structural demand → json ──────────────────────
;;; Emitted on the place that carries the reading; a place below it inherits by
;;; walking up, the way it inherits its nation's rules.
(define (reading-pairs reading)
  (let ((demand (find (lambda (d) (equal? (reading-demand reading) (assq-ref d 'name)))
                      *structural-demands*)))
    (and demand
         (let* ((st (reading-standing reading (assq-ref demand 'mirror)))
                (e  (assq-ref st 'entry)))
           `(("name"     . ,(J:s (reading-demand reading)))
             ("status"   . ,(J:s (assq-ref st 'status)))
             ("inForce"  . ,(J:syms (assq-ref st 'in-force)))
             ("won"      . ,(J:syms (assq-ref st 'won)))
             ("standing" . ,(J:syms (assq-ref st 'standing)))
             ("redundant"   . ,(J:syms (or (assq-ref e 'redundant) '())))
             ("absorbFirst" . ,(J:syms (or (assq-ref e 'absorb-first) '())))
             ("reproduceUnwanted" . ,(J:syms (or (assq-ref e 'reproduce-unwanted) '())))
             ("transform"   . ,(J:syms (or (assq-ref e 'transform-law) '())))
             ;; what the cells say to do: wither · absorb · transform · keep
             ("move"        . ,(J:s (reform-move e)))
             ("source"     . ,(J:s (or (reading-source reading) "")))
             ("asOf"       . ,(J:s (or (reading-as-of reading) "")))
             ("confidence" . ,(J:s (reading-confidence reading)))
             ("steward"    . ,(J:s (or (reading-steward reading) "")))
             ("note"       . ,(J:s (or (reading-note reading) ""))))))))
(define (reading->json reading)
  (and=> (reading-pairs reading) J:o))

;;; the burden scale's tiers, as the fold names them (legal/registry.scm)
(define (tiers->json)
  (J:a (map (lambda (t)
              (J:o `(("upTo" . ,(if (car t) (J:n (car t)) "null"))
                     ("name" . ,(J:s (cadr t))))))
            *burden-tiers*)))

;;; → ((name entry places sources crossings border? unmapped) …), the move we
;;; can make now first, then by name.
(define (reform-program-entries)
  (let ((acc (make-hash-table)))       ; demand-name → (mirror places sources crossings border? unmapped)
    (for-each
     (lambda (r)
       (let* ((form   (legal-rule-guard-form r))
              (places (delete-duplicates (guard-places form)))
              (xs     (delete-duplicates (guard-atoms 'on-crossing form)))
              (border (border-rule? r)))
         (for-each
          (lambda (d)
            (let ((m (demand->mirror d)))
              (when m
                (let* ((name (demand-name d)) (cur (hash-ref acc name #f)))
                  (hash-set! acc name
                    (if cur (list (list-ref cur 0)
                                  (lset-union equal? (list-ref cur 1) places)
                                  (lset-adjoin equal? (list-ref cur 2) (legal-rule-source r))
                                  (lset-union eq? (list-ref cur 3) xs)
                                  (and (list-ref cur 4) border)
                                  (list-ref cur 5))
                        (list m places (list (legal-rule-source r)) xs border
                              (demand-unmapped d))))))))
          (legal-rule-demands r))))
     (current-legal-rules))
    (sort (hash-map->list
           (lambda (name v) (let ((m (car v)))
                              (list name (reform-entry m)
                                    (list-ref v 1) (list-ref v 2) (list-ref v 3) (list-ref v 4)
                                    (list-ref v 5))))
           acc)
          (lambda (a b)
            (let ((ra (move-rank (cadr a))) (rb (move-rank (cadr b))))
              (or (< ra rb) (and (= ra rb) (string<? (car a) (car b)))))))))

(define (program-entry->json row)
  (let* ((name (list-ref row 0)) (e (list-ref row 1))
         (places (list-ref row 2)) (sources (list-ref row 3))
         (links (program-links name)))
    (J:o `(("name" . ,(J:s name))
           ("move" . ,(J:s (reform-move e)))
           ("redundant"   . ,(J:syms (or (assq-ref e 'redundant) '())))
           ("absorbFirst" . ,(J:syms (or (assq-ref e 'absorb-first) '())))
           ("reproduceUnwanted" . ,(J:syms (or (assq-ref e 'reproduce-unwanted) '())))
           ("transform"   . ,(J:syms (or (assq-ref e 'transform-law) '())))
           ("unmapped"    . ,(J:syms (list-ref row 6)))
           ("jurisdictions" . ,(J:a (map (lambda (id)
                                           (J:o `(("id" . ,(J:s id)) ("name" . ,(J:s (place-name id))))))
                                         places)))
           ;; the ways that trip it, anywhere the snapshot reaches; a demand of
           ;; the border belongs to an arc, and is marked so
           ("activities" . ,(J:sa (delete-duplicates (map car links))))
           ("modes"      . ,(J:sa (delete-duplicates (map cdr links))))
           ("crossings"  . ,(J:syms (list-ref row 4)))
           ("border"     . ,(J:b (list-ref row 5)))
           ("sources" . ,(J:sa sources))))))

;;; the STRUCTURAL program (the abolitions) → json. ONE premium is the BUDGET;
;;; the four do×want regions and the move are DERIVED from each demand's (L,I,D)
;;; mirror by reform.scm. (The cost/budget/bundle pricing is OFF for now — it
;;; ranked & priced demands as if commensurable, which clashes with the categorical
;;; reading; the ranking/extraction engine that tried it was removed from
;;; option-composition.scm 2026-10-08, not just disabled.)
(define (structural-demand->json d)
  (let ((m (assq-ref d 'mirror)))
    (J:o (append
          (reading-pairs (incumbent-at "world" (assq-ref d 'name)))   ; the general case
          `(("withers"   . ,(J:s (assq-ref d 'withers)))
            ("becomes"   . ,(J:s (assq-ref d 'becomes)))
            ("class"     . ,(J:s (assq-ref d 'class))))))))
;; just the demands with their do×want regions — no bundle, no budget.
(define* (structural-program->json #:optional (budget *program-budget*))
  (J:o `(("demands" . ,(J:a (map structural-demand->json *structural-demands*))))))

;;; bill → (list billjson burden) — flattens the 3-value bill->json.
(define (bill->jb bill hits)
  (call-with-values (lambda () (bill->json bill hits)) (lambda (j b s) (list j b))))

;;; supply arcs → json : each split into EXPORT (origin) · CROSSING · IMPORT
;;; (destination), the truest §2.6 import/export.
(define (arc->json a)
  (let* ((from (list-ref a 0)) (to (list-ref a 1))
         (good (list-ref a 2)) (by (list-ref a 3))
         (pf (place-chain from))
         (pt (place-chain to))
         (crosses (paths-cross? pf pt))
         (level (and crosses (common-ancestor pf pt)))
         (international (equal? level "world")))
    (call-with-values (lambda () (ffd-arc-components from to))
      (lambda (ex cr im hits)
        (let ((e (bill->jb ex hits)) (c (bill->jb cr hits)) (i (bill->jb im hits)))
          (J:o `(("from" . ,(J:s from)) ("to" . ,(J:s to))
                 ("fromName" . ,(J:s (place-name from))) ("toName" . ,(J:s (place-name to)))
                 ("fromNation" . ,(J:s (or (place-nation from) "")))
                 ("toNation"   . ,(J:s (or (place-nation to)   "")))
                 ("good" . ,(J:s good)) ("by" . ,(J:s by))
                 ("crossesBorder" . ,(J:b crosses))
                 ("international" . ,(J:b international))
                 ("borderLevel" . ,(if level (J:s level) "null"))
                 ("export"   . ,(J:o `(("bill" . ,(car e)) ("burden" . ,(J:n (cadr e))))))
                 ("crossing" . ,(J:o `(("bill" . ,(car c)) ("burden" . ,(J:n (cadr c))))))
                 ("import"   . ,(J:o `(("bill" . ,(car i)) ("burden" . ,(J:n (cadr i))))))
                 ("burden" . ,(J:n (+ (cadr e) (cadr c) (cadr i))))
                 ("hits" . ,(hits->json hits)))))))))


;;; ─── the snapshot as a JSON string (the shared builder) ──────────────────
;;; #:budget — the program's credibility budget. Offline ⇒ the stewarded
;;; *program-budget* default; live ⇒ federation-budget over real composed plans.
;;; #:rules — the law to fold. Offline ⇒ the static library; live ⇒ that
;;; library with the rules the planner's scopes carry (`rules-with`).
(define (rules-with own)
  "The static library with OWN added — a scope's registry rules. A rule the
   library already holds under the same label is the same rule and is kept once."
  (let ((labels (filter-map legal-rule-label *pack-rules*)))
    (append *pack-rules*
            (delete-duplicates
             (remove (lambda (r) (member (legal-rule-label r) labels)) own)
             (lambda (a b) (and (legal-rule-label a)
                                (equal? (legal-rule-label a) (legal-rule-label b))))))))

(define* (law-snapshot-string #:key (budget *program-budget*) (rules *pack-rules*))
  (parameterize ((current-legal-rules rules))
    (hash-clear! %place-programs)
    (law-snapshot-json budget)))

(define (law-snapshot-json budget)
  (let* ((all-places (map registered-place->json (snapshot-place-ids)))
         (snapshot
          (J:o `(("defaultActivity" . ,(J:s %ffd-activity))
                 ("tiers" . ,(tiers->json))
                 ("activities" . ,(J:a (map (lambda (a)
                   (J:o `(("id" . ,(J:s (assq-ref a 'id))) ("name" . ,(J:s (assq-ref a 'name)))
                          ("verb" . ,(J:s (assq-ref a 'verb)))
                          ("modes" . ,(J:a (map (lambda (m)
                            (J:o `(("id" . ,(J:s (assq-ref m 'id))) ("name" . ,(J:s (assq-ref m 'name)))
                                   ("kind" . ,(J:s (assq-ref m 'kind)))
                                   ("crossings" . ,(J:syms (assq-ref m 'crossings)))
                                   ("steps" . ,(J:sa (assq-ref m 'steps))) ("note" . ,(J:s (assq-ref m 'note)))
                                   ("performs" . ,(J:syms (or (assq-ref m 'performs) '()))))))
                            (activity-modes a)))))))
                   *activities*)))
                 ("generatedBy" . ,(J:s "tools/emit-law-snapshot.scm — real legal fold (legal/registry.scm) over the activity catalogue"))
                 ("crossings" . ,(J:a (map (lambda (c)
                                             (J:o `(("id" . ,(J:s c))
                                                    ("kind" . ,(J:s (crossing-kind c)))
                                                    ("gloss" . ,(J:s (or (crossing-gloss c) ""))))))
                                           (catalogue-crossings))))
                 ("federation" . ,(J:o `(("name" . ,(J:s (ffd-federation-name)))
                                         ("activity" . ,(J:s %ffd-activity))
                                         ("aid"  . ,(J:s (ffd-federation-aid)))
                                         ("members" . ,(J:a (map member->json (ffd-member-list))))
                                         ("arcs" . ,(J:a (map arc->json *ffd-arcs*))))))
                 ("nations" . ,(J:a (map (lambda (id)
                                           (J:o `(("id" . ,(J:s id)) ("name" . ,(J:s (place-name-of id)))
                                                  ("iso" . ,(J:s (or (place-extra-ref id 'iso) ""))))))
                                         (all-nations))))
                 ("recipes" . ,(J:a (map recipe->json *ffd-recipes*)))
                 ("program" . ,(J:a (map program-entry->json (reform-program-entries))))
                 ("structuralProgram" . ,(structural-program->json budget))
                 ("places"  . ,(J:o (map (lambda (kv) (cons (car kv) (cdr kv))) all-places)))))))
    snapshot))
