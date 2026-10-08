;;; law/context-pack.scm — a CONTEXT is one file: where a place is, and what the law
;;; asks there.
;;;
;;; Teaching the fold a new jurisdiction costs one drop-in file:
;;;
;;;   docs/legal/contexts/de.sexp   →  ((places (row …) …) (rules (rule-sexp …) …))
;;;
;;; Both halves are already data. A place is a row of the fields `place!` takes
;;; (places.scm `place->row`); a rule is a guard FORM plus demand data plus its
;;; provenance (legal/registry.scm `rule->sexp`). Keeping them in ONE file keeps
;;; them honest with each other: a rule guarded on `(in-jurisdiction "berlin")`
;;; ships beside the row that puts Berlin in the tree, so a pack can never name a
;;; jurisdiction it forgot to place.
;;;
;;; Loading a pack REGISTERS its places (a side effect on the shared tree) and
;;; RETURNS its rules, for the caller to append to whatever library it folds.
;;;
;;; A pack may carry three more sections of FACTS, registered on load the way a
;;; place is and for the same reason — each is read by whoever asks, and no fold
;;; appends it:
;;;
;;;   protections  the statutes that shield an activity in a place
;;;                (law/protections.scm)
;;;   readings  what a structural demand's incumbent function is in a place
;;;             (law/incumbent-readings.scm)
;;;   aspects   the pack's own words for federation aspects, `(clause . aspect)`
;;;             (law/aspects.scm `clause-aspect`) — what lets a demand written
;;;             in this law's words enter the reform diff
;;;
;;; Every reader here goes through `read-pack` (legal/registry.scm), so the
;;; loaders and the lint agree on what a pack is.
;;;
;;; Loads after places.scm and legal/registry.scm.

(define-module (playnet planner knowledge law context-pack)
  #:use-module (srfi srfi-1)
  #:use-module (playnet planner legal registry)   ; rule->sexp / sexp->rule provenance
  #:use-module (playnet planner knowledge law pack-dir)
  #:use-module ((playnet planner legal registry-actor) #:select (^legal-registry))   ; load-legal-registry spawns it
  #:use-module (playnet planner facts places) ; place->row / place-row->place!
  #:use-module (playnet planner knowledge law incumbent-readings) ; a place's reading of a structural demand
  #:use-module (playnet planner knowledge law aspects)      ; a pack's own words for an aspect
  #:use-module (playnet planner knowledge law protections)        ; the statutes that shield an activity
  #:use-module (playnet planner vf schemas)          ; make-spatial-thing (into a scope's store)
  #:use-module (goblins)                          ; $ — the store is an actor
  #:export (context->sexp save-context-pack load-context-pack
            load-context-packs load-law load-legal-registry
            pack-place-rows pack-readings pack-aspects pack-protections register-pack-facts!
            seed-pack-places!
            *pack-rules* current-legal-rules
            bill-at stance-at)
  ;; the registry's own (it scans a pack folder for rules too); handed on, since
  ;; a caller that loads packs asks this module where they are
  #:re-export (pack-paths place-endpoints %contexts-dir))

(cond-expand (guile) (else
  ;; a page has no file system: no file is there to read, and none is written
  (define (file-exists? path) #f)
  (define (call-with-input-file path proc) (error "no file system here" path))
  (define (call-with-output-file path proc) (error "no file system here" path))
  (define (set-port-encoding! port encoding) #t)
  (define (in-vicinity dir file) (string-append dir "/" file))
  (define (%search-load-path file) #f)))


;;; ─── the pack, both directions ────────────────────────────────────────────
(define* (context->sexp place-ids rules
                        #:key (readings '()) (aspects '()) (protections '()))
  `((places . ,(map place->row place-ids))
    (rules  . ,(rules->sexp rules))
    ,@(if (pair? aspects)     `((aspects     . ,aspects))     '())
    ,@(if (pair? protections) `((protections . ,protections)) '())
    ,@(if (pair? readings)    `((readings    . ,readings))    '())))

(define* (save-context-pack path place-ids rules
                            #:key (readings '()) (aspects '()) (protections '()))
  "Write the places named by PLACE-IDS, the RULES, and any READINGS, ASPECTS and
   PROTECTIONS to PATH as one pack."
  (call-with-output-file path
    (lambda (port)
      (set-port-encoding! port "UTF-8")     ; statutes carry § and umlauts
      (write (context->sexp place-ids rules #:readings readings #:aspects aspects
                            #:protections protections)
             port)
      (newline port))))

(define (pack-place-rows path)
  "The place rows in PATH, without registering anything."
  (pack-section (read-pack path) 'places))
(define (pack-readings path)
  "The incumbent readings in PATH, without registering anything."
  (pack-section (read-pack path) 'readings))
(define (pack-aspects path)
  "PATH's own words for federation aspects, as (clause . aspect) pairs."
  (pack-section (read-pack path) 'aspects))
(define (pack-protections path)
  "The protections in PATH, without registering anything."
  (pack-section (read-pack path) 'protections))

;;; a pack's FACTS — its readings, its protections and its words for aspects.
;;; Both the offline loader below and a live scope (scope-root.scm) register
;;; them through here.
(define (register-pack-facts! path)
  (for-each register-incumbent-reading! (pack-readings path))
  (for-each register-protection! (pack-protections path))
  (for-each (lambda (kv) (register-clause-aspect! (car kv) (cdr kv))) (pack-aspects path)))

(define (load-context-pack path)
  "Register PATH's places and facts; return its rules."
  (for-each place-row->place! (pack-place-rows path))
  (register-pack-facts! path)
  (load-rule-pack path))

;;; ─── a directory of packs ─────────────────────────────────────────────────
;;; SOURCE is a directory (its *.sexp, in name order — so load order is a
;;; property of the filenames, not of anyone's memory) or an explicit path list.
;;; A missing directory loads nothing, so a checkout with no packs still folds.
(define (load-context-packs source)
  (append-map load-context-pack (pack-paths source)))

;;; The one loading of law, for the packs in the tree and for a scope's own
;;; folder alike → the rules. Each pack's places stand in the shared tree (where
;;; their kind and their `within` regimes are read), its readings, aspects and
;;; protections are registered, and — given a scope's STORE — its places are
;;; seeded there too, so the scope's own climb passes through them. An absent
;;; SOURCE is no law: '().
(define* (load-law source #:key (store #f))
  (append-map (lambda (path)
                (let ((rules (load-context-pack path)))
                  (when store (seed-pack-places! store (pack-place-rows path)))
                  rules))
              (if (and source (or (pair? source) (file-exists? source)))
                  (pack-paths source)
                  '())))
;; load-legal-registry : spawn the catalogue straight from packs on disk (a
;; directory of *.sexp, or an explicit path list) — "the laws are a folder of
;; signed files." Must run inside a vat. The loading is `load-law`
;; (above): the packs' places, facts and rules, and — given
;; a scope's spatial STORE — the places seeded into it.
;; An absent or missing SOURCE spawns an empty registry: a scope under no
;; pack stands under no law, and its solve is byte-identical.
(define* (load-legal-registry source #:key (store #f))
  (spawn ^legal-registry (load-law source #:store store)))


;;; ─── the pack's places, into a SCOPE's own store ──────────────────────────
;;; `load-context-pack` registers places in the knowledge layer's shared tree.
;;; A scope's legal gate walks its OWN `^spatial-thing-store` (that is the tree
;;; a solve's cells resolve against), so a pack that teaches the fold a
;;; jurisdiction must reach that store too — otherwise a rule guarded on
;;; `(in-jurisdiction "fr-33330-A")` can never fire, because no cell's chain
;;; names it. Parents are added before children, so the store's own cycle check
;;; sees a complete chain.
;;; ─── the law in force : every pack on disk ───────────────────────────────
;;; The federation's law is the packs in `docs/legal/contexts/`, one file per jurisdiction
;;; or regime. Loading them registers their places in the one containment tree
;;; and their readings, aspects and protections, and yields their rules — so a
;;; rule is never in force without the places its guard names. A jurisdiction
;;; reaches every bill by one road: author, generate or scrape a pack, drop it
;;; in. Steward and confidence ride each rule. A place no steward has encoded
;;; carries no rules, and its bill is empty.
(define *pack-rules* (load-context-packs %contexts-dir))

;;; The rules a fold reads when its caller names none. A parameter, so a caller
;;; with law of its own — a live planner, whose scopes carry their own
;;; registries — folds the same code over its own rules.
(define current-legal-rules (make-parameter *pack-rules*))

;;; ─── the bill at a place : the one fold over the shared tree ─────────────
;;; The legal exterior of CROSSINGS at PLACE-ID → (values bill hits). Every
;;; reader that asks "what does the law ask of this, here" outside a solve — a
;;; mode on the law face, a point of an arc, a product feature — asks through
;;; this, so they agree on what a guard sees: the place's chain and regimes,
;;; the crossings, the act and the channel. The caller states the ACT: a symbol
;;; meets the `act-is` guards that name it and stands outside the rest, so a
;;; "forbidden unless the act is X" binds it. #f is the act unstated: a guard
;;; that reads it answers `unknown`, and its rule is a hit in doubt (an uncertain
;;; rule: it prices and warns, and neither prunes nor cancels). CHANNEL #f is the
;;; channel unstated, read the same way.
;;; REGIMES? #f reads the containment chain alone. PATH-OF is the climb: place
;;; → every path it stands in, its own chain first. It defaults to the shared
;;; tree (`place-endpoints`); a live caller passes its scope's reader
;;; (`spatial-path-reader`, legal/gate.scm), which walks the scope's own places
;;; and then the shared tree, so a place only that scope knows is seen.
(define* (bill-at place-id crossings
                  #:key (act (error "bill-at: #:act states the act (or #f, to leave it open)"))
                        (channel #f) (regimes? #t) (path-of place-endpoints)
                        (rules (current-legal-rules)) (as-of #f))
  (let ((endpoints (let ((paths (path-of place-id)))
                     (if regimes? paths (list (car paths))))))
    (legal-demands
     (legal-context #:crossings crossings
                    #:place-path (car endpoints) #:endpoints endpoints
                    #:act act #:channel channel)
     #:rules rules #:as-of as-of)))

;;; The stance of CROSSINGS at PLACE-ID → open | notice | unread | soft | off:
;;; `bill-at` read by `bill-stance`, with the crossings stated so that silence
;;; nobody has read shows as `unread`.
(define* (stance-at place-id crossings #:key (act (error "stance-at: #:act states the act"))
                    (channel #f) (regimes? #t) (path-of place-endpoints)
                    (rules (current-legal-rules)) (as-of #f)
                    (held? (lambda (name) #t)))
  (call-with-values
      (lambda () (bill-at place-id crossings #:act act #:channel channel #:regimes? regimes?
                          #:path-of path-of #:rules rules #:as-of as-of))
    (lambda (bill hits) (bill-stance bill hits held? #:crossings crossings))))

(define (seed-pack-places! store rows)
  "Add ROWS (a pack's places) to a ^spatial-thing-store, parents first."
  (let* ((by-id (map (lambda (r) (cons (car r) r)) rows))
         (done  (make-hash-table)))
    (let add ((rs rows))
      (for-each
       (lambda (r)
         (let loop ((r r))
           (let ((id (car r)) (parent (caddr r)))
             (unless (hash-ref done id)
               (let ((prow (assoc-ref by-id parent)))
                 (when (and prow (not (hash-ref done parent))) (loop prow)))
               (hash-set! done id #t)
               ($ store 'add-location
                  (make-spatial-thing #:id id #:name (cadr r)
                                      #:lat (if (> (length r) 5) (list-ref r 5) #f)
                                      #:long (if (> (length r) 6) (list-ref r 6) #f) #:contained-in parent))))))
       rs))
    (hash-count (const #t) done)))
