;;; sturdyref-credential.scm — the federation's word on the wire, read.
;;;
;;; A federation admits a commune with a `playnet-federation-sturdyref/v1`
;;; ACDC: the commune's AID (the holder) and the sturdyref its peer answers at.
;;; The commune tells the federation what it deals in with a
;;; `playnet-federation-census/v1` ACDC of its own: issued by the commune, held
;;; by the federation, the goods its records hold, make, consume and ask for
;;; (planner/federation/crossing-set.scm reads them off the records; nobody types them).
;;; The credentials that stand ARE the federation on the wire: who is reached
;;; where, who speaks under which AID, which goods cross between whom — the
;;; goods at least two members deal in. Which commune supplies a good and which
;;; draws it is the plan's to say, so no credential says it.
;;; This module reads them, on both sides, with one reader:
;;;
;;;   `sturdyref-credential-end` is one credential checked — its schema, its
;;;   SAID committing to its content, its issuer the AID the reader trusts,
;;;   the issuer's signature over the SAID — and answers the far end it names.
;;;
;;;   `census-credential-goods` is one census checked the same way (its issuer
;;;   the member's own AID, which signs it) and answers the goods it names.
;;;
;;;   `sturdyref-credentials->spec` is the SPEC a set of credentials makes:
;;;   the issuer, the goods, the roster ((good aid …) …) with each good's
;;;   participants ordered by AID (one order on every side, and the first of
;;;   them the good's master), and the credentials by holder. The federation's
;;;   scope answers it off its own store (`federation-spec`); a commune derives
;;;   the same spec from the credentials the federation hands it
;;;   (`verified-spec`, every credential checked first), so the roster a
;;;   commune builds its peer on is a function of signed words alone.
;;;
;;;   `spec-ready?` says whether a spec holds a commune's crossings: every
;;;   member has told its census, so the roster is whole.
;;;
;;; Pure data over (playnet keri acdc): no actor, no network, no planner.

(define-module (playnet governance sturdyref-credential)
  #:use-module (srfi srfi-1)
  #:use-module ((playnet keri acdc)
                #:select (cred-schema cred-issuer cred-holder cred-claim cred-said
                          cred-signature cred-revoked? cred-said-consistent?))
  #:use-module ((playnet keri citizen-sig) #:select (verify-said-signature verify-said-signature-under-key))
  #:use-module ((playnet keri key-state) #:select (key-for-credential events->key-state state-key))
  #:use-module ((playnet planner facts partition) #:select (held-twice))
  #:export (*schema-playnet-federation-sturdyref* *schema-playnet-federation-census*
            sturdyref-credential-end census-credential-goods census-key-state
            sturdyref-credentials->spec verified-spec spec-ready? spec-goods))

(define *schema-playnet-federation-sturdyref* "playnet-federation-sturdyref/v1")
(define *schema-playnet-federation-census* "playnet-federation-census/v1")

(define (signed-by? cred who kel)
  "Whether CRED's signature checks as WHO's. With WHO's key log KEL (a rotated
   identifier's), under the key the log had in force when it sealed the SAID —
   a credential is signed by the key of its day and stays that key's after a
   rotation; without, under the AID (its inception key, and whatever the
   verifier's resolver adds)."
  (and (string? (cred-signature cred))
       (if kel
           (verify-said-signature-under-key (cred-said cred) (cred-signature cred)
                                            (key-for-credential who kel (cred-said cred)))
           (verify-said-signature (cred-said cred) (cred-signature cred) who))))

(define* (sturdyref-credential-end cred #:key issuer (kel #f))
  "The far end CRED names, once it checks: the schema, the SAID committing to
   the content, the issuer being ISSUER — the AID the federation issues under,
   which the caller trusts — and the issuer's signature over the SAID. KEL, the
   issuer's key log when it has rotated, says which key that signature is
   checked under (`signed-by?`). → (values aid sturdyref-uri), the commune's AID
   to pin and where to enliven it. Raises otherwise."
  (unless (equal? (cred-schema cred) *schema-playnet-federation-sturdyref*)
    (error "sturdyref-credential: a credential of another kind" (cred-schema cred)))
  (unless (cred-said-consistent? cred)
    (error "sturdyref-credential: the SAID does not commit to the content"))
  (unless (equal? (cred-issuer cred) issuer)
    (error "sturdyref-credential: issued under another AID" (cred-issuer cred)))
  (unless (signed-by? cred issuer kel)
    (error "sturdyref-credential: the issuer's signature does not check" (cred-said cred)))
  (let ((uri (cred-claim cred 'sturdyref-uri)))
    (unless (string? uri) (error "sturdyref-credential: the credential names no sturdyref"))
    (values (cred-holder cred) uri)))

(define (census-credential-goods cred)
  "The goods CRED, a census, names, once it checks: the schema, the SAID
   committing to the content, and the signature of its issuer — the member
   whose records it reads — over the SAID. A member whose key has rotated tells
   its key log in the census (`kel`, inside what the SAID commits to), and the
   signature is checked under the key that log leaves in force. Raises otherwise."
  (unless (equal? (cred-schema cred) *schema-playnet-federation-census*)
    (error "census-credential: a credential of another kind" (cred-schema cred)))
  (unless (cred-said-consistent? cred)
    (error "census-credential: the SAID does not commit to the content"))
  (let ((kel (cred-claim cred 'kel)))
    (unless (false-if-exception (signed-by? cred (cred-issuer cred) (and (pair? kel) kel)))
      (error "census-credential: the member's signature does not check" (cred-said cred))))
  (let ((goods (cred-claim cred 'goods)))
    (unless (and (list? goods) (every string? goods))
      (error "census-credential: the credential names no goods"))
    goods))

(define (census-key-state cred)
  "The key state CRED, a census that checks, shows of its member: the state its
   `kel` claim leaves in force, or #f when it carries none (the member's
   inception key speaks, sequence 0). A federation reads the rotation of a
   member off the censuses it holds, revoked ones too."
  (let ((kel (cred-claim cred 'kel)))
    (and (pair? kel)
         (let ((state (events->key-state (cred-issuer cred) kel)))
           (and (not (string? state)) state)))))

(define (stands? schema c)
  (and (equal? (cred-schema c) schema) (not (cred-revoked? c))))

(define (sturdyref-credentials->spec issuer creds)
  "The spec CREDS make under ISSUER: the sturdyref credentials that stand
   (revoked ones are out) and the census each member has told (a member's later
   census revokes its earlier, so one stands) — whose roster is what at least
   two members deal in.
   → ((issuer . aid) (goods good …) (roster (good aid …) …) (units (good . unit) …)
      (credentials (aid . cred) …) (census (aid . cred) …))."
  (let* ((members (filter (lambda (c) (stands? *schema-playnet-federation-sturdyref* c)) creds))
         (holders (map cred-holder members))
         ;; a census counts when a member issued it
         (censuses (filter (lambda (c) (and (stands? *schema-playnet-federation-census* c)
                                            (member (cred-issuer c) holders)))
                           creds))
         (told (fold (lambda (c acc) (cons (cons (cred-issuer c) c) (alist-delete (cred-issuer c) acc)))
                     '() censuses))
         (shared (held-twice (map (lambda (t) (cons (car t) (or (cred-claim (cdr t) 'goods) '())))
                                  told)))
         ;; the unit a good is counted in: what the first member to state one (by AID) says
         (units (fold (lambda (t acc)
                        (fold (lambda (u acc)
                                (if (and (pair? u) (pair? (cdr u)) (not (assoc (car u) acc)))
                                    (acons (car u) (cadr u) acc) acc))
                              acc (or (cred-claim (cdr t) 'units) '())))
                      '() (sort told (lambda (a b) (string<? (car a) (car b)))))))
    `((issuer . ,issuer)
      (goods . ,(sort (map car shared) string<?))
      (roster . ,(map (lambda (h) (cons (car h) (sort (cdr h) string<?)))
                      (sort shared (lambda (a b) (string<? (car a) (car b))))))
      (units . ,(sort units (lambda (a b) (string<? (car a) (car b)))))
      (credentials . ,(map (lambda (c) (cons (cred-holder c) c)) members))
      (census . ,told))))

(define* (verified-spec issuer creds #:key (kel #f))
  "The spec of CREDS, every one checked first: a sturdyref credential under
   ISSUER (`sturdyref-credential-end`; KEL, the issuer's key log when it has
   rotated, says which key), a census under its own issuer
   (`census-credential-goods`). Raises on the first that fails."
  (for-each (lambda (c)
              (if (equal? (cred-schema c) *schema-playnet-federation-census*)
                  (census-credential-goods c)
                  (sturdyref-credential-end c #:issuer issuer #:kel kel)))
            creds)
  (sturdyref-credentials->spec issuer creds))

(define (spec-goods spec me)
  "The goods of SPEC that cross for the commune ME and for another: what its
   record carries a crossing for."
  (filter-map (lambda (g) (and (member me (cdr g)) (pair? (cddr g)) (car g)))
              (or (assq-ref spec 'roster) '())))

(define (spec-ready? spec me)
  "Whether SPEC holds the crossings of the commune ME: ME is a member beside at
   least one other (a federation of one has nothing to cross) and every member
   has told its census, so no good that crosses for ME can still be missing
   from the roster."
  (let ((members (map car (or (assq-ref spec 'credentials) '())))
        (told    (map car (or (assq-ref spec 'census) '()))))
    (and (member me members)
         (pair? (cdr members))
         (every (lambda (m) (member m told)) members)
         #t)))
