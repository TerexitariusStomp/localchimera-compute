;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/playnet/keri/witnesses.scm — Witness selection, toad calculation,
;;;                                     and OOBI sharing for group creation
;;;
;;; Witnesses are the durability layer of KERI. They receive KEL events and
;;; return receipts — without enough witness receipts (toad), key events are
;;; not accepted. This module handles:
;;;
;;;   1. Fetching available witnesses from KERIA config
;;;   2. Calculating toad (threshold of acceptable duplicity) from witness count
;;;   3. Sharing witness OOBIs to group members (/introduce reply route)
;;;   4. Sharing member OOBIs within a group before inception
;;;
;;; Toad thresholds (from Veridian, protocol-correct values):
;;;   ≥12 witnesses → toad 8  (use first 12)
;;;   ≥10 witnesses → toad 7  (use first 10)
;;;    ≥9 witnesses → toad 6
;;;    ≥7 witnesses → toad 5
;;;    ≥6 witnesses → toad 4  (minimum viable)
;;;    <6 witnesses → error (insufficient)

(define-module (playnet keri witnesses)
  #:use-module (playnet keri bridge)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (web uri)
  #:use-module (ice-9 format)
  #:use-module (ice-9 regex)
  #:use-module (json)
  #:export (keri-get-available-witnesses
            keri-toad-for-count
            keri-share-witness-oobis!
            keri-share-member-oobi!
            keri-get-member-oobi))

;;; ── Toad threshold table ─────────────────────────────────────────────────────

(define %toad-table
  ;; (min-witnesses toad max-select), descending by min-witnesses.
  '((12 8 12)
    (10 7 10)
    ( 9 6  9)
    ( 7 5  7)
    ( 6 4  6)))

(define (keri-toad-for-count n)
  "Calculate toad and witness selection count for N available witnesses.
   Returns (values toad select-count) or raises if n < 6."
  (when (< n 6)
    (error "Insufficient witnesses — need at least 6, have" n))
  ;; Table is sorted descending by min-witnesses, so the first row whose
  ;; threshold n meets is the right one. The n>=6 guard above makes
  ;; `find` always succeed.
  (let ((entry (find (lambda (row) (>= n (car row))) %toad-table)))
    (values (cadr entry) (caddr entry))))

;;; ── Witness discovery ────────────────────────────────────────────────────────

(define (parse-witness-eid oobi-url)
  "Extract witness EID from an OOBI URL.
   Format: http://host:port/oobi/{EID}/controller?role=witness
   Returns EID string or #f."
  (let ((m (string-match "/oobi/([A-Za-z0-9_-]+)/" oobi-url)))
    (and m (match:substring m 1))))

(define (witness-role oobi-url)
  "Extract role from OOBI URL query params. Returns \"witness\" or #f."
  (let ((m (string-match "role=([^&]+)" oobi-url)))
    (and m (match:substring m 1))))

(define (keri-get-available-witnesses)
  "Fetch available witnesses from KERIA config.
   Parses iurls, filters by role=witness, deduplicates by EID.
   Returns (values witnesses toad) where witnesses = list of ((eid . oobi) ...).
   Raises if fewer than 6 witnesses are available."
  (let* ((config  (keri-get-config))
         (iurls   (keri-as-list (assoc-ref config "iurls")))
         ;; Parse and filter witness OOBIs
         (parsed  (filter-map
                   (lambda (oobi)
                     (let ((eid  (parse-witness-eid oobi))
                           (role (witness-role oobi)))
                       (and eid
                            (equal? role "witness")
                            (cons eid oobi))))
                   iurls))
         ;; Deduplicate by EID. srfi-1's delete-duplicates preserves the
         ;; first occurrence of each EID — same semantics as the prior
         ;; mutable-hash-table dedup but without the side-effecting filter.
         (unique  (delete-duplicates parsed
                                     (lambda (a b)
                                       (equal? (car a) (car b))))))
    (let-values (((toad sel-count) (keri-toad-for-count (length unique))))
      (let ((selected (if (> (length unique) sel-count)
                          (list-head unique sel-count)
                          unique)))
        (format (current-error-port)
                "[witnesses] ~a available, using ~a, toad=~a\n"
                (length unique) (length selected) toad)
        (values selected toad)))))

;;; ── Witness OOBI sharing (initiator → joiners) ───────────────────────────────
;;;
;;; In real KERIA, witnesses are resolved locally on each member's agent
;;; via POST /oobis (the signify-ts path). Each agent's config carries the
;;; same witness `iurls` list, and /oobis is idempotent, so having the
;;; initiator resolve them on behalf of joiners is both unnecessary and
;;; wire-incompatible (KERIA has no /replies endpoint).
;;;
;;; These functions now resolve the OOBIs on OUR agent (idempotent). Joiners
;;; handle their own resolution when they confirm the group inception.

(define (keri-share-witness-oobis! member-prefix contact-aids)
  "Resolve all available witness OOBIs on our agent.
   member-prefix and contact-aids are kept for API compatibility with the
   governance flow but are unused: each agent resolves its own witnesses."
  (let-values (((witnesses _toad) (keri-get-available-witnesses)))
    (for-each
     (lambda (witness)
       (catch #t
         (lambda () (keri-resolve-oobi (cdr witness)))
         (lambda (key . args)
           (format (current-error-port)
                   "[witnesses] resolve ~a failed: ~a ~a\n"
                   (car witness) key args))))
     witnesses)
    (format (current-error-port)
            "[witnesses] resolved ~a witness OOBIs locally (contacts=~a)\n"
            (length witnesses) (length contact-aids))))

;;; ── Member OOBI fetching ────────────────────────────────────────────────────

(define (keri-get-member-oobi aid-prefix)
  "Fetch the OOBI URL for a local AID. Returns OOBI string or #f."
  (catch #t
    (lambda ()
      (let* ((result (GET (string-append "/identifiers/"
                                         (uri-encode aid-prefix)
                                         "/oobi")))
             (oobis  (keri-as-list (assoc-ref result "oobis"))))
        (and (pair? oobis) (car oobis))))
    (lambda _ #f)))

(define (keri-share-member-oobi! my-aid-prefix recipient-aids)
  "Fetch our AID's OOBI and log it. In real KERIA, other members resolve
   us via their own /oobis POST when they process /multisig/icp
   notifications — the initiator doesn't need to push OOBIs to them."
  (let ((our-oobi (keri-get-member-oobi my-aid-prefix)))
    (unless our-oobi
      (error "Could not fetch OOBI for AID" my-aid-prefix))
    (format (current-error-port)
            "[witnesses] member OOBI for ~a: ~a (recipients will resolve: ~a)\n"
            my-aid-prefix our-oobi (length recipient-aids))))
