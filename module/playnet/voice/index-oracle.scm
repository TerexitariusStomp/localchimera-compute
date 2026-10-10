;;; voice/index-oracle.scm — ^index-oracle actor
;;;
;;; Writes external-index observation credentials into the ACDC store on
;;; demand (pull) or on a tick (push). This is the bridge that lets
;;; rollover-premium pricing consume external market-data series:
;;; the movement produces S_t (support tally-result credentials) via
;;; ^expression; the oracle produces I_t (observation credentials)
;;; via ^index-oracle; a covariance-view joins the two by timestamp.
;;;
;;; The oracle does not fetch external data itself — callers hand it a
;;; value when they have one. This keeps it pure and testable; real
;;; integrations live in a separate shepherd service that polls a feed
;;; and calls ($ oracle 'observe ...).
;;;

(define-module (playnet voice index-oracle)
  #:use-module (srfi srfi-1)
  #:use-module (playnet credentials work)
  #:use-module (playnet keri acdc)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^index-oracle spawn-index-oracle observation-value
            credential-stream->pairs-fn))

(define* (^index-oracle bcom acdc-store oracle-aid index-uri
                        #:optional (signing-keypair #f))
  ;; oracle-aid: AID string of the oracle; used as issuer on all creds.
  ;; index-uri:  string pinning this oracle to a single external source
  ;;             (one oracle per source; multi-source dashboards spawn
  ;;             multiple oracles).
  ;; signing-keypair: the oracle's own KERI keypair. When present, each
  ;;             observation is signed by oracle-aid — an observation is an
  ;;             (untargeted §7.5) assertion by the oracle, so a conformant
  ;;             ACDC carries the issuer's signature. Absent → unsigned
  ;;             (tests / fixtures that don't exercise verification).

  (methods

    ;; --- Writes ---

    ((observe value timestamp . rest)
     ;; Issue an observation credential. Optional trailing NOTE becomes
     ;; the credential's source-note claim. Returns the issued SAID.
     (let ((note (and (pair? rest) (car rest))))
       ($ acdc-store 'issue
          (make-external-index-observation-credential
            #:oracle-aid oracle-aid
            #:index-uri index-uri
            #:observed-value value
            #:observed-at timestamp
            #:source-note note
            #:signing-keypair signing-keypair))))

    ;; --- Reads (convenience wrappers over the acdc-store range queries) ---

    ((series)
     ;; All observations for this oracle's index-uri, ordered by time.
     ($ acdc-store 'by-claim-in-range
        *schema-playnet-external-index-observation*
        'index-uri index-uri #f #f))

    ((series-in-range from-ts to-ts)
     ($ acdc-store 'by-claim-in-range
        *schema-playnet-external-index-observation*
        'index-uri index-uri from-ts to-ts))

    ((oracle-aid) oracle-aid)
    ((index-uri)  index-uri)))


(define* (spawn-index-oracle acdc-store oracle-aid index-uri
                             #:optional (signing-keypair #f))
  "Spawn an ^index-oracle bound to ACDC-STORE, writing observations for
   INDEX-URI as ORACLE-AID. When SIGNING-KEYPAIR is supplied, observations
   are signed by ORACLE-AID (conformant); otherwise unsigned."
  (spawn ^index-oracle acdc-store oracle-aid index-uri signing-keypair))


(define (observation-value cred)
  "Extract the observed-value from an external-index-observation credential."
  (cred-claim cred 'observed-value))


;; =========================================================================
;; credential-stream->pairs-fn
;; =========================================================================
;;
;; Bridge between governance credential streams and planner correlation.
;; The returned procedure is a drop-in for <covariance-view>'s stream-a /
;; stream-b fields.

(define (credential-stream->pairs-fn source extract-value)
  "Given SOURCE (an actor answering 'series / 'series-in-range) and
   EXTRACT-VALUE (cred → number-or-#f), return a procedure
   (from-ts to-ts) → list of (ts . value) pairs. Credentials whose
   timestamp or value extracts to #f are filtered out.

   Use to adapt an ^index-oracle, an ACDC-store cursor, or any similar
   actor into a correlation stream.

   Example — correlate a plan's tally-result weight against an oracle:

     (define tally-stream
       (credential-stream->pairs-fn
         tally-source                            ; actor around acdc-store
         (lambda (c) (assoc-ref (cred-claim c 'tally-data) \"plan-X\"))))

     (define index-stream
       (credential-stream->pairs-fn oracle observation-value))

     (define view
       (make-covariance-view 'plan-X-vs-abx
                             tally-stream index-stream
                             86400 'pearson))"
  (lambda (from-ts to-ts)
    (let ((creds (if (and from-ts to-ts)
                     ($ source 'series-in-range from-ts to-ts)
                     ($ source 'series))))
      (filter-map
        (lambda (c)
          (let ((ts (cred-timestamp c))
                (v  (extract-value c)))
            (and ts v (cons ts v))))
        creds))))
