;;; test/vf-ttl.scm — reads the VF vocabulary's action individuals.
;;;
;;; Shared by the four ValueFlows conformance tests (tests/*/vf-conformance-*-test.scm), which `load` it. It parses the Turtle file
;;; docs/valueflows/assets/all_vf.TTL AT RUN TIME, so the tests hold the repo to
;;; the vocabulary as published rather than to a hand copy of it.
;;;
;;; The file layout the parser reads (all_vf.TTL, "# Actions"):
;;;
;;;     vf:produce a                owl:NamedIndividual ,
;;;                                 vf:Action ;
;;;             vf:inputOutput      vf:output ;
;;;             ...
;;;             rdfs:label          "produce"@en ;
;;;             .
;;;
;;; A block opens at a column-0 line and ends at a line holding only ".". It is
;;; an ACTION when `owl:NamedIndividual` and `vf:Action` both appear among the
;;; tokens of its first three lines after the subject (a property declaration
;;; whose `rdfs:domain` is vf:Action is not).
;;;
;;; ── Mapping table: VF vocabulary → playnet symbols ───────────────────────────
;;;
;;;   property (TTL)         accessor suffix (schemas.scm)    notes
;;;   vf:eventQuantity       event-quantity                   resource → resource-quantity,
;;;                                                           effort → effort-quantity, both → both
;;;   vf:inputOutput         input-output                     input | output | outputInput →
;;;                                                           output-input | notApplicable →
;;;                                                           not-applicable
;;;   vf:pairsWith           pairs-with                       an action → its kebab symbol;
;;;                                                           notApplicable → #f
;;;   vf:createResource      create-resource                  optional | optionalTo → optional-to |
;;;                                                           notApplicable → no-effect
;;;   vf:accountingEffect    accounting-effect                increment | decrement |
;;;   vf:onhandEffect        onhand-effect                    decrementIncrement →
;;;                                                           decrement-increment | incrementTo →
;;;                                                           increment-to | notApplicable → no-effect
;;;   vf:locationEffect      location-effect                  update | updateTo → update-to |
;;;   vf:containedEffect     contained-effect                 remove | new |
;;;   vf:accountableEffect   accountable-effect               notApplicable → no-effect
;;;   vf:stageEffect         stage-effect
;;;   vf:stateEffect         state-effect
;;;
;;;   action name: camelCase → kebab-case (transferAllRights → transfer-all-rights,
;;;   deliverService → deliver-service).
;;;
;;; A TTL value that the mapping does not know is returned as its kebab symbol, so
;;; a vocabulary term the repo has not met shows up as a failed comparison, never
;;; as a silent pass.

(define-module (playnet test vf-ttl)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module ((playnet vf schemas) #:select (<action-definition>))
  #:use-module ((playnet utils records) #:select (vf-record-type-fields))
  #:export (vf-repo-root %ttl-path camel->kebab kebab->camel-class kebab->camel-field strip-vf clean-tokens
            %beyond-ttl-action-fields
            read-lines ttl-blocks label-of action-block? parse-action-block
            load-ttl-actions %prop-map %behaviour-props ttl-value->symbol
            ttl-action-table ttl-label
            property-block? parse-property-block ttl-properties))

(define %ttl-path "docs/valueflows/assets/all_vf.TTL")

(define (vf-repo-root)
  "The repository root: the first directory, up from this file, that holds the TTL."
  (let ((file (or (current-filename) (%search-load-path "playnet/test/vf-ttl.scm"))))
    (or (and file
             (let up ((d (dirname (if (absolute-file-name? file) file (string-append (getcwd) "/" file)))))
               (cond ((file-exists? (string-append d "/" %ttl-path)) d)
                     ((string=? d (dirname d)) #f)
                     (else (up (dirname d))))))
        (getcwd))))

(define (camel->kebab s)
  (list->string
   (append-map (lambda (c) (if (char-upper-case? c)
                               (list #\- (char-downcase c))
                               (list c)))
               (string->list s))))

(define (strip-vf s)
  (if (string-prefix? "vf:" s) (substring s 3) s))

(define (clean-tokens line)
  "LINE's whitespace tokens with trailing ; , . punctuation dropped."
  (filter (lambda (t) (not (member t '(";" "," "."))))
          (string-tokenize line)))

(define (read-lines path)
  (string-split (call-with-input-file path get-string-all) #\newline))

(define (ttl-blocks lines)
  "The top-level blocks of LINES: lists of lines from a column-0 subject line up
   to the line holding only a period."
  (let loop ((ls lines) (cur #f) (acc '()))
    (cond
     ((null? ls) (reverse acc))
     (else
      (let* ((l (car ls)) (t (string-trim-both l)))
        (cond
         ((and cur (string=? t "."))
          (loop (cdr ls) #f (cons (reverse cur) acc)))
         (cur (loop (cdr ls) (cons l cur) acc))
         ((and (> (string-length l) 3) (string-prefix? "vf:" l))
          (loop (cdr ls) (list l) acc))
         (else (loop (cdr ls) #f acc))))))))

(define (label-of line)
  (let* ((i (string-index line #\")))
    (and i (let ((j (string-index line #\" (+ i 1))))
             (and j (substring line (+ i 1) j))))))

(define (action-block? block)
  (let ((head (append-map clean-tokens (list-head block (min 3 (length block))))))
    (and (pair? head)
         (member "owl:NamedIndividual" (cdr head))
         (member "vf:Action" (cdr head))
         #t)))

(define (parse-action-block block)
  "(name-string label-or-#f (prop-string . value-string) ...) for one action block."
  (let* ((name (strip-vf (car (clean-tokens (car block)))))
         (props '()) (label #f))
    (for-each
     (lambda (l)
       (let ((t (string-trim-both l)))
         (cond
          ((string-prefix? "rdfs:label" t) (set! label (label-of t)))
          (else
           (let ((toks (clean-tokens t)))
             (when (and (= (length toks) 2)
                        (string-prefix? "vf:" (car toks))
                        (string-prefix? "vf:" (cadr toks)))
               (set! props (cons (cons (strip-vf (car toks)) (strip-vf (cadr toks)))
                                 props))))))))
     (cdr block))
    (cons name (cons label (reverse props)))))

(define (load-ttl-actions root)
  "All vf:Action individuals of the TTL under ROOT, in file order, as
   ((name label (prop . value) ...) ...), every string verbatim from the file."
  (let* ((lines (read-lines (string-append root "/" %ttl-path))))
    (map parse-action-block (filter action-block? (ttl-blocks lines)))))

;;; ── TTL values → playnet symbols ────────────────────────────────────────────

;; the record's own field list is the map: kebab field ↔ camelCase TTL property.
;; Two fields of <action-definition> are playnet's, beyond the TTL's vf:Action
;; properties, and are declared so here (the fields test holds the list).
(define (kebab->camel-class sym)
  (string-concatenate (map string-titlecase (string-split (symbol->string sym) #\-))))
(define (kebab->camel-field sym)
  (let ((parts (string-split (symbol->string sym) #\-)))
    (string-concatenate (cons (car parts) (map string-titlecase (cdr parts))))))

(define %beyond-ttl-action-fields '(implies-transfer eligible-for-exchange))

(define %behaviour-props
  (filter (lambda (f) (not (memq f %beyond-ttl-action-fields)))
          (vf-record-type-fields <action-definition>)))

(define %prop-map
  (map (lambda (f) (cons (kebab->camel-field f) f)) %behaviour-props))

(define (ttl-value->symbol prop raw)
  "RAW (a TTL local name) read as the playnet symbol for property PROP (a
   behaviour symbol of %behaviour-props)."
  (cond
   ((string=? raw "notApplicable")
    (case prop
      ((input-output) 'not-applicable)
      ((pairs-with)   #f)
      (else           'no-effect)))
   ((eq? prop 'event-quantity)
    (cond ((string=? raw "resource") 'resource-quantity)
          ((string=? raw "effort")   'effort-quantity)
          (else (string->symbol (camel->kebab raw)))))
   (else (string->symbol (camel->kebab raw)))))

(define (ttl-action-table root)
  "The vocabulary as playnet symbols: ((action-symbol (prop . value) ...) ...),
   one entry per vf:Action in file order, props in %prop-map order. A property
   the TTL omits for an action is absent from its entry."
  (map (lambda (a)
         (let ((name (car a)) (props (cddr a)))
           (cons (string->symbol (camel->kebab name))
                 (filter-map
                  (lambda (m)
                    (let ((c (assoc (car m) props)))
                      (and c (cons (cdr m) (ttl-value->symbol (cdr m) (cdr c))))))
                  %prop-map))))
       (load-ttl-actions root)))

(define (ttl-label action-sym root)
  "The rdfs:label the TTL gives ACTION-SYM, or #f."
  (let ((a (find (lambda (a) (eq? (string->symbol (camel->kebab (car a))) action-sym))
                 (load-ttl-actions root))))
    (and a (cadr a))))


;;; ── the properties: what a class's fields are ──────────────────────────────
;; A property block states its label, its domain (one class, or a union of
;; classes, which may span lines), its range and its cardinality. The fields a
;; record of a class may carry are the properties whose domain names the class;
;; a property stating no domain belongs to every class.

(define (property-block? block)
  (let ((head (append-map clean-tokens (list-head block (min 3 (length block))))))
    ;; the file spells the kinds owl:ObjectProperty, owl:DatatypeProperty and
    ;; owl:DataTypeProperty; a property is a property whichever it says
    (and (pair? head)
         (any (lambda (t) (and (string-prefix? "owl:" t) (string-suffix? "Property" t))) (cdr head))
         #t)))

(define (clause-tokens block key)
  "The tokens of BLOCK's KEY clause (from KEY to the next ';' or the block's end)."
  (let loop ((toks (append-map (lambda (l) (string-tokenize (string-trim-both l))) block)) (in? #f) (acc '()))
    (cond ((null? toks) (reverse acc))
          ((and in? (or (string=? (car toks) ";") (string-suffix? ";" (car toks))))
           (reverse (if (string-suffix? ";" (car toks))
                        (let ((t (string-drop-right (car toks) 1))) (if (string-null? t) acc (cons t acc)))
                        acc)))
          (in? (loop (cdr toks) #t (cons (car toks) acc)))
          ((string=? (car toks) key) (loop (cdr toks) #t '()))
          (else (loop (cdr toks) #f acc)))))

(define (parse-property-block block)
  "(name label domain range max-cardinality) for one property block: NAME the
   property's name without its prefix, DOMAIN the classes it belongs to (() for
   every class), RANGE a class or datatype name or #f, MAX-CARDINALITY a number or #f."
  (let* ((name (strip-vf (car (clean-tokens (car block)))))
         (label (any (lambda (l) (and (string-prefix? "rdfs:label" (string-trim-both l)) (label-of l))) block))
         ;; a union's parentheses and brackets cling to its first and last class
         (bare (lambda (t) (string-trim-both t (lambda (c) (memv c '(#\( #\) #\[ #\]))))))
         (domain (filter-map (lambda (t) (let ((t (bare t))) (and (string-prefix? "vf:" t) (strip-vf t))))
                             (clause-tokens block "rdfs:domain")))
         (range (let ((r (clause-tokens block "rdfs:range"))) (and (pair? r) (car r))))
         (card (let ((c (clause-tokens block "owl:maxCardinality"))) (and (pair? c) (string->number (car c))))))
    (list name label domain range card)))

(define (ttl-properties root)
  "Every property of the TTL, parsed."
  (map parse-property-block
       (filter property-block? (ttl-blocks (read-lines (string-append root "/" %ttl-path))))))
