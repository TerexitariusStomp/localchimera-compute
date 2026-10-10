;;; credentials/membership.scm — membership and its ends: membership, federation membership, exclusion, the CCF assessment, and the federation sturdyref and census.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6). A constructor returns the ACDC bundle as an alist — said, schema, issuer,
;;; holder, claims, edges, revoked? — with its SAID computed over the whole; the
;;; edge block follows ACDC §8 (`make-edge` in (playnet keri acdc)).

(define-module (playnet credentials membership)
  #:use-module (playnet keri acdc)
  #:use-module (playnet keri first-person credentials)
  #:use-module (playnet keri cesr)
  #:use-module (playnet keri said-portable)
  #:use-module (goblins utils hashmap)
  #:use-module (playnet utils clock)
  #:use-module (playnet planner vf schemas)
  #:use-module (srfi srfi-1)
  #:use-module (playnet keri crypto-primitives)
  #:use-module (playnet keri citizen-sig)
  #:use-module (ice-9 format)
  #:use-module (goblins)
  #:export (*schema-playnet-ccf-assessment*
            *schema-playnet-exclusion*
            *schema-playnet-federation-census*
            *schema-playnet-federation-membership*
            *schema-playnet-federation-sturdyref*
            *schema-playnet-membership*
            make-ccf-credential
            make-exclusion-credential
            make-federation-census-credential
            make-federation-membership-credential
            make-federation-sturdyref-credential
            make-membership-credential))
(define *schema-playnet-federation-sturdyref* "playnet-federation-sturdyref/v1")
(define *schema-playnet-federation-census* "playnet-federation-census/v1")

(define *schema-playnet-ccf-assessment*         "playnet-ccf-assessment/v1")
(define *schema-playnet-exclusion*              "playnet-exclusion/v1")
(define *schema-playnet-federation-membership*  "playnet-federation-membership/v1")
(define *schema-playnet-membership*             "playnet-membership/v1")

(define* (make-ccf-credential issuer-group-aid holder-aid commune
                              ccf assessed-at reason
                              #:key (signing-keypair #f) (multisig-signers #f))
  "Capacity assessment by a commune's governance group, for a citizen.
   The latest non-revoked CCF credential per (commune, holder) wins at
   recovery time."
  (make-credential *schema-playnet-ccf-assessment*
                   issuer-group-aid
                   holder-aid
                   (list (cons 'commune     commune)
                         (cons 'ccf         ccf)
                         (cons 'assessed-at assessed-at)
                         (cons 'reason      reason))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-exclusion-credential issuer-group-aid holder-aid commune
                                    excluded-at
                                    #:key (signing-keypair #f) (multisig-signers #f))
  "Exclusion of a citizen from a commune. Revocation = reinstatement."
  (make-credential *schema-playnet-exclusion*
                   issuer-group-aid
                   holder-aid
                   (list (cons 'commune     commune)
                         (cons 'excluded-at excluded-at))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-federation-membership-credential issuer-group-aid
                                                 commune-aid
                                                 federation
                                                 commune-id
                                                 admitted-at
                                                 #:key (edges '())
                                                 (signing-keypair #f) (multisig-signers #f))
  "Federation admits a commune as a member.
   EDGES: optional extra ACDC edges (used by Phase-6 recomposition
   ratification to attach a 'ratification edge to this credential)."
  (make-credential *schema-playnet-federation-membership*
                   issuer-group-aid
                   commune-aid
                   (list (cons 'federation  federation)
                         (cons 'commune-id  commune-id)
                         (cons 'admitted-at admitted-at))
                   edges
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-membership-credential issuer-group-aid holder-aid commune
                                     admitted-at
                                     #:key (signing-keypair #f) (multisig-signers #f))
  "Citizen is recognized as a member of commune. Issued on first account
   creation (work credit or CCF assessment)."
  (make-credential *schema-playnet-membership*
                   issuer-group-aid
                   holder-aid
                   (list (cons 'commune     commune)
                         (cons 'admitted-at admitted-at))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-federation-sturdyref-credential issuer-group-aid commune-aid
                                               commune-id sturdyref-uri
                                               netlayer registered-at
                                               #:key (signing-keypair #f) (multisig-signers #f))
  "Sturdyref for a remote commune in a federation: how it is reached. Enables
   recovery by re-resolving the sturdyref via mycapn enliven. The goods that
   cross are not said here: the commune tells what it deals in with its own
   census (`make-federation-census-credential`) and the roster is what at
   least two members deal in. The `crosses` claim is still emitted, empty — a
   constructor's emission is frozen, a SAID commits to it."
  (make-credential *schema-playnet-federation-sturdyref*
                   issuer-group-aid
                   commune-aid
                   (list (cons 'commune-id     commune-id)
                         (cons 'sturdyref-uri  sturdyref-uri)
                         (cons 'netlayer       netlayer)
                         (cons 'registered-at  registered-at)
                         (cons 'crosses        '()))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))

(define* (make-federation-census-credential commune-aid federation-aid goods told-at
                                            #:key (kel #f) (units '()) (signing-keypair #f) (multisig-signers #f))
  "What a commune deals in, told to its federation: GOODS, the spec ids its
   records hold, make, consume and ask for (planner/federation/crossing-set.scm
   `commune-goods`). Issued by the COMMUNE — its records are its own to read —
   and held by the federation; the commune signs it. A good at least two
   members tell crosses between them. KEL, when the commune's key has rotated,
   is its key event log: the AID alone no longer says which key signed, and the
   log, inside what the SAID commits to, does. UNITS, ((good . unit) …), are the
   units the commune counts those goods in (their specifications' own): the
   federation's record of a crossing counts in the same."
  (make-credential *schema-playnet-federation-census*
                   commune-aid
                   federation-aid
                   (append (list (cons 'goods   (sort goods string<?))
                                 (cons 'told-at told-at))
                           (if (pair? units) (list (cons 'units (map (lambda (u) (list (car u) (cdr u))) units))) '())
                           (if kel (list (cons 'kel kel)) '()))
                   '()
                   #:signing-keypair signing-keypair
                   #:multisig-signers multisig-signers))
;; The claim each schema keeps its observation time under (the default is
;; `timestamp`), for the store's time-range queries.
(register-timestamp-claims!
 `((,*schema-playnet-ccf-assessment* . assessed-at)
   (,*schema-playnet-exclusion* . excluded-at)
   (,*schema-playnet-federation-membership* . admitted-at)
   (,*schema-playnet-membership* . admitted-at)
   (,*schema-playnet-federation-sturdyref* . registered-at)
   (,*schema-playnet-federation-census* . told-at)))
