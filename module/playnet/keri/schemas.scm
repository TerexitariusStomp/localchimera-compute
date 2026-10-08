;;; module/playnet/keri/schemas.scm — the ACDC schema catalog
;;;
;;; ONE table names every checked-in ACDC schema document. Everything
;;; that touches the schema set reads it from here:
;;;
;;;   (playnet keri credentials)  — the %schema-* SAID constants and the
;;;                                 boot-time OOBI resolver
;;;   tools/saidify-schemas.scm   — the saidification work list
;;;   server/serve-static.scm     — the /oobi/{said} schema branch that
;;;                                 serves each document to resolvers
;;;
;;; In ACDC, a schema is identified by its SAID: `$id` holds a
;;; blake3-256 SAID computed over the document with `$id` blanked to 44
;;; `#` chars (see tools/saidify-schemas.scm for the build step and
;;; tests/keri/test-schemas.scm for the idempotency proof). The files
;;; live beside this module in module/playnet/keri/schemas/.
;;;
;;; Each schema also carries an env-var escape hatch so tests and
;;; alternate deployments can point issuance at a different SAID.
;;; `schema-said` honours the override; the served-document index does
;;; not (we can only serve what is on disk).

(define-module (playnet keri schemas)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:export (%schema-catalog
            schema-path
            schema-said
            all-schema-saids
            schema-document-for-said
            read-schema-alist))

;; filename → env-override variable.
(define %schema-catalog
  '(;; role credentials (issued by a scope over its members)
    ("member.json"     . "PLAYNET_SCHEMA_MEMBER")
    ("supplier.json"   . "PLAYNET_SCHEMA_SUPPLIER")
    ("planner.json"    . "PLAYNET_SCHEMA_PLANNER")
    ("governor.json"   . "PLAYNET_SCHEMA_GOVERNOR")
    ;; economic-substrate credentials (skills / work / settlement)
    ("work-event.json" . "PLAYNET_SCHEMA_WORK_EVENT")
    ("skill.json"      . "PLAYNET_SCHEMA_SKILL")
    ("intent.json"     . "PLAYNET_SCHEMA_INTENT")
    ("commitment.json" . "PLAYNET_SCHEMA_COMMITMENT")
    ("claim.json"      . "PLAYNET_SCHEMA_CLAIM")
    ;; the property form: title as a credential (custody's rights-side sibling)
    ("ownership-attestation.json" . "PLAYNET_SCHEMA_OWNERSHIP_ATTESTATION")
    ;; First-Person Project personhood substrate (founder seed / enrollment)
    ("personhood.json"        . "PLAYNET_SCHEMA_PERSONHOOD")
    ("membership.json"        . "PLAYNET_SCHEMA_MEMBERSHIP")
    ("authorized-issuer.json" . "PLAYNET_SCHEMA_AUTHORIZED_ISSUER")))

(define (schema-path filename)
  "Absolute path of playnet/keri/schemas/FILENAME, searched on
   %load-path. Works under both source load and compiled .go load —
   `current-filename` is #f in the latter, so the load path is the
   reliable anchor."
  (or (search-path %load-path
                   (string-append "playnet/keri/schemas/" filename))
      (error "schema not found on %load-path:" filename)))

;; Explicit UTF-8 on every read: schemas contain non-ASCII glyphs, and
;; under a C locale the default port encoding mangles them — changing
;; the served bytes and thus the SAID a resolver re-derives.
(define (%read-schema-file filename)
  (call-with-input-file (schema-path filename) get-string-all
                        #:encoding "UTF-8"))

(define (%order-preserved x)
  "guile-json's `json-string->scm` builds alists by consing, which
   reverses the original field order. SAID derivation canonicalizes
   over that order (KERIpy preserves it), so restore it by
   deep-reversing every alist after parse."
  (cond
   ((and (list? x) (not (null? x)) (every pair? x)
         (every string? (map car x)))
    (reverse (map (lambda (p) (cons (car p) (%order-preserved (cdr p)))) x)))
   ((vector? x)
    (list->vector (map %order-preserved (vector->list x))))
   (else x)))

(define (read-schema-alist filename)
  "Parse playnet/keri/schemas/FILENAME with the file's original field
   order intact — the form SAID derivation canonicalizes over."
  (%order-preserved (json-string->scm (%read-schema-file filename))))

(define (%stored-said filename)
  "The `$id` SAID as saidified into the checked-in file."
  (assoc-ref (json-string->scm (%read-schema-file filename)) "$id"))

(define (schema-said filename)
  "The effective SAID for FILENAME: the catalog's env override when
   set, else the SAID stored in the file itself."
  (or (getenv (assoc-ref %schema-catalog filename))
      (%stored-said filename)))

(define (all-schema-saids)
  "Effective SAIDs of every catalogued schema, in catalog order."
  (map (lambda (entry) (schema-said (car entry))) %schema-catalog))

;; said → filename, built once from the ON-DISK `$id`s (not the env
;; overrides): this index answers "which document do I serve for this
;; SAID", and the answer can only ever be a file we actually have.
(define %said-index
  (delay (map (lambda (entry)
                (cons (%stored-said (car entry)) (car entry)))
              %schema-catalog)))

(define (schema-document-for-said said)
  "The raw on-disk bytes of the schema whose stored `$id` is SAID, or
   #f when SAID names no catalogued schema. Serving the file verbatim
   keeps field order intact, which is what a resolver's SAID
   re-derivation canonicalizes over."
  (let ((filename (assoc-ref (force %said-index) said)))
    (and filename (%read-schema-file filename))))
