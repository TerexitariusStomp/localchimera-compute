;;; credentials/membership.scm — membership and its ends: membership, federation membership, exclusion, the CCF assessment, and the federation sturdyref and census.
;;;
;;; One family of the playnet credential catalogue (docs/planning/codebase-layout.md
;;; §6); the bundle a constructor returns is described once, in credentials/registry.scm.

(define-module (playnet credentials membership)
  #:use-module (playnet keri acdc)
  #:use-module (srfi srfi-1)
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

(define-credential (make-ccf-credential issuer-group-aid holder-aid commune ccf assessed-at reason)
  "Capacity assessment by a commune's governance group, for a citizen.
   The latest non-revoked CCF credential per (commune, holder) wins at
   recovery time."
  *schema-playnet-ccf-assessment*
  #:signed (keypair multisig)
  #:claims (commune ccf assessed-at reason)
  #:index ()
  #:time assessed-at)

(define-credential (make-exclusion-credential issuer-group-aid holder-aid commune excluded-at)
  "Exclusion of a citizen from a commune. Revocation = reinstatement."
  *schema-playnet-exclusion*
  #:signed (keypair multisig)
  #:claims (commune excluded-at)
  #:index ()
  #:time excluded-at)

(define-credential (make-federation-membership-credential issuer-group-aid commune-aid federation commune-id admitted-at)
  "Federation admits a commune as a member.
   EDGES: optional extra ACDC edges (used by Phase-6 recomposition
   ratification to attach a 'ratification edge to this credential)."
  *schema-playnet-federation-membership*
  #:key ((edges '()))
  #:signed (keypair multisig)
  #:claims (federation commune-id admitted-at)
  #:edges ((@ edges))
  #:index ()
  #:time admitted-at)

(define-credential (make-membership-credential issuer-group-aid holder-aid commune admitted-at)
  "Citizen is recognized as a member of commune. Issued on first account
   creation (work credit or CCF assessment)."
  *schema-playnet-membership*
  #:signed (keypair multisig)
  #:claims (commune admitted-at)
  #:index ()
  #:time admitted-at)

(define-credential (make-federation-sturdyref-credential issuer-group-aid commune-aid commune-id sturdyref-uri netlayer registered-at)
  "Sturdyref for a remote commune in a federation: how it is reached. Enables
   recovery by re-resolving the sturdyref via mycapn enliven. The goods that
   cross are not said here: the commune tells what it deals in with its own
   census (`make-federation-census-credential`) and the roster is what at
   least two members deal in. The `crosses` claim is still emitted, empty — a
   constructor's emission is frozen, a SAID commits to it."
  *schema-playnet-federation-sturdyref*
  #:signed (keypair multisig)
  #:claims (commune-id sturdyref-uri netlayer registered-at (crosses '()))
  #:index ()
  #:time registered-at)

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

;; What the store knows of this family's schemas: the claims it indexes for
;; O(1) lookup, and the claim the observation time stands under. Registered
;; here at load, so a module that imports one family finds its credentials.
(register-schema-claims!
 `((,*schema-playnet-federation-census* () told-at)))
