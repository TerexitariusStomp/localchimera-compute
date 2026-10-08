;;; federation-peers.scm — the peers and parent this gateway federates with
;;;
;;; Operator-supplied, env-driven: PLAYNET_PEERS (OOBI URLs of peer gateways)
;;; and PLAYNET_UC_AID (the Universal Commune this gateway pushes
;;; federation-membership credentials to). Playnet wiring over the KERI
;;; library's bridge — (playnet keri inception) holds the AID inception itself.

(define-module (playnet governance keri federation-peers)
  #:use-module ((playnet keri bridge) #:select (keri-wait-operation keri-resolve-oobi))
  #:use-module ((playnet utils common) #:select (parse-csv-env for-each-catching))
  #:use-module ((srfi srfi-1) #:select (filter-map))
  #:use-module ((srfi srfi-13) #:select (string-contains))
  #:use-module (ice-9 format)
  #:export (resolve-peer-oobis! known-uc-aid set-known-uc-aid! peer-base-urls))

;;; ── Cross-gateway federation state ──────────────────────────────────────────
;;;
;;; For Phase-6 IPEX delivery we need two pieces of operator-supplied
;;; context: (a) the OOBIs of peer gateways we'll be sending to (their
;;; AIDs must land in our local kevers, otherwise KERIA refuses the
;;; grant); (b) the AID of the Universal Commune (the parent we push
;;; federation-membership credentials to). Both are env-driven so a
;;; fresh deploy works with zero code changes — just set PLAYNET_PEERS
;;; and PLAYNET_UC_AID in the environment.

(define *known-uc-aid* #f)

(define (known-uc-aid)
  "AID of the Universal Commune this gateway federates with, or #f when
   unconfigured. Federations push their federation-membership ACDC to
   this AID via IPEX so the UC's gateway sees the parent edge without
   polling. Read via env var PLAYNET_UC_AID at boot."
  (or *known-uc-aid* (getenv "PLAYNET_UC_AID")))

(define (set-known-uc-aid! aid)
  "Override the env var (mostly for tests)."
  (set! *known-uc-aid* aid))

(define (peer-base-urls)
  "Extract just the host part of each PLAYNET_PEERS OOBI URL.
   Inputs like `https://gw1.example/oobi/E_aid` become
   `https://gw1.example`. Used as the fallback witness-URL list for
   scope recovery so we can fetch ANY scope's KEL from any peer
   gateway's /oobi/{aid} endpoint when the scope's declared
   witnesses are unreachable. Pillar #45: multi-gateway witness
   pool coordination without a separate config — PLAYNET_PEERS
   already names the right hosts."
  (filter-map
   (lambda (url)
     ;; Strip everything from /oobi/ onward; keep scheme://host:port
     (let ((idx (string-contains url "/oobi/")))
       (cond
        ((not idx) url)        ; no /oobi/ → use as-is
        ((zero? idx) #f)       ; degenerate
        (else (substring url 0 idx)))))
   (parse-csv-env "PLAYNET_PEERS")))

(define (resolve-peer-oobis!)
  "Read PLAYNET_PEERS — comma-separated OOBI URLs of remote gateways
   we'll be sending IPEX grants to — and register each with KERIA so
   their AIDs land in the local kevers. Idempotent; safe to re-run.

   Format: PLAYNET_PEERS=https://gw1/oobi/E_abc...,https://gw2/oobi/E_xyz...

   Returns the count of OOBIs we attempted. Per-URL errors are logged
   by for-each-catching but don't block the others."
  (let ((urls (parse-csv-env "PLAYNET_PEERS")))
    (for-each-catching
     "peer OOBI"
     (lambda (url)
       (keri-wait-operation (keri-resolve-oobi url) #:timeout 30)
       (format (current-error-port)
               "[federation] resolved peer OOBI: ~a~%" url))
     urls)
    (length urls)))
