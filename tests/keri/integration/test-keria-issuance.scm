;;; tests/keri/integration/test-keria-issuance.scm — LIVE economic-credential
;;; issuance against real KERIA.
;;;
;;; Runs against REAL KERIA started by run-integration.sh, which also starts
;;; schema-server.py and exports:
;;;
;;;   KERIA_ADMIN_URL / KERIA_BOOT_URL / KERIA_PASSCODE — bridge wiring
;;;   PLAYNET_SCHEMA_SERVER — http://127.0.0.1:<port>, serving /oobi/<said>
;;;                           → the saidified economic schema JSON
;;;
;;; ── What this suite proves ──────────────────────────────────────────────────
;;;
;;; The in-memory `^acdc-store` path is exercised by the planner suites. This
;;; one closes the remaining gap: that our FIVE economic schemas
;;; (work-event / skill / intent / commitment / claim) and their CESR "E"
;;; SAIDs are accepted by a live KERIA verifier — schema OOBI resolves, the
;;; a-block field shapes validate, and ACDC edge-chaining works with a real
;;; target SAID. It is intentionally progressive so the FIRST failing step
;;; localizes the problem (schema resolve vs. field-shape vs. edge target)
;;; rather than collapsing into one opaque "issue failed".

(use-modules (playnet test harness)
             (playnet test keri-integration)
             (playnet keri bridge)
             ((playnet keri signify) #:select (signify-context-agent-aid))
             (playnet keri credentials)
             (ice-9 format)
             (ice-9 match)
             (srfi srfi-1))

;;; ── env plumbing ──────────────────────────────────────────────────────────

(define-values (%admin-url %boot-url %passcode) (keri-integration-bring-up!))
(define %schema-server (getenv "PLAYNET_SCHEMA_SERVER"))

(format #t "=== Live KERIA economic-credential issuance ===~%")
(format #t "  admin : ~a~%" %admin-url)
(format #t "  boot  : ~a~%" %boot-url)
(format #t "  schema-server : ~a~%" (or %schema-server "(unset!)"))
(format #t "  skill schema  : ~a~%" %schema-skill)
(format #t "  work  schema  : ~a~%" %schema-work-event)

;;; ── helpers ─────────────────────────────────────────────────────────────────

(define (aid-prefix result)
  "Pull the AID prefix out of a keri-create-aid result, tolerating either an
   alist with \"prefix\"/\"i\" or a bare op alist."
  (and result
       (or (assoc-ref result "prefix")
           (assoc-ref result "i")
           (and=> (assoc-ref result "response")
                  (lambda (r) (assoc-ref r "i"))))))

;;; ── bring the bridge up ─────────────────────────────────────────────────────

(define booted #f)
(check-call "keri-boot! issuance-agent"
  (lambda ()
    (let ((r (keri-boot! "issuance-agent" %passcode)))
      (set! booted (and r #t))
      r)))

;; If boot failed (agent may already exist from a prior run), try connect.
(unless booted
  (check-call "keri-connect! (fallback)"
    (lambda () (keri-connect! %passcode))))

;;; ── 1. resolve the economic schemas over OOBI ───────────────────────────────
;;; acdc-ensure-schemas-resolved! reads PLAYNET_SCHEMA_SERVER and POSTs each
;;; /oobi/<said> to KERIA's /oobis. A 404/405 here means the schema host or the
;;; bridge endpoint is wrong — fail loud before we ever try to issue.

(check-call "resolve economic schemas over OOBI"
  (lambda ()
    (unless %schema-server
      (error "PLAYNET_SCHEMA_SERVER unset — run via run-integration.sh"))
    (acdc-ensure-schemas-resolved!)
    #t))

;;; ── 2. issuer AID + registry ─────────────────────────────────────────────────

(define issuer-name "econ-scope")
(check-call "create issuer AID (econ-scope)"
  (lambda () (keri-create-aid issuer-name)))

(check-call "create registry (econ-reg)"
  (lambda () (acdc-create-registry issuer-name "econ-reg")))

;;; ── 3. holder AID (the worker) ───────────────────────────────────────────────

(define worker-prefix #f)
(check-call "create holder AID (worker) + extract prefix"
  (lambda ()
    (let ((p (aid-prefix (keri-create-aid "worker"))))
      (set! worker-prefix p)
      (format #t "  → worker prefix: ~a~%" p)
      (and p (string-prefix? "E" p)))))

;;; ── 4. issue a SKILL credential (no edges) — schema field-shape acceptance ───

(define skill-said #f)
(check-call "issue skill cred (no edges) → live KERIA validator"
  (lambda ()
    (let ((said (acdc-issue issuer-name worker-prefix %schema-skill
                            `(("skill"            . "electrician")
                              ("founding-event-id" . "evt-bootstrap-0")
                              ("issued-by"         . ,issuer-name)))))
      (set! skill-said said)
      (format #t "  → skill SAID: ~a~%" said)
      (and said (string-prefix? "E" said)))))

;;; ── 5. issue a WORK-EVENT credential (no edges) — second schema ──────────────

(define work-said #f)
(check-call "issue work-event cred (no edges) → live KERIA validator"
  (lambda ()
    (let ((said (acdc-issue issuer-name worker-prefix %schema-work-event
                            `(("event-id"             . "evt-electric-1")
                              ("hours"                . 4)
                              ("unit"                 . "hour")
                              ("resource-conforms-to" . "electrician")))))
      (set! work-said said)
      (format #t "  → work-event SAID: ~a~%" said)
      (and said (string-prefix? "E" said)))))

;;; ── 6. issue a SKILL credential WITH a founding-event edge to a REAL SAID ────
;;; This is the edge-chaining proof: the `founding-event` edge `n`-points at the
;;; work-event credential we just issued (a SAID KERIA actually holds), with the
;;; NI2I operator + the work-event schema.

(define edged-said #f)
(check-call "issue skill cred WITH founding-event edge → real work-event SAID"
  (lambda ()
    (unless work-said (error "no work-event SAID to edge to"))
    (let ((said (acdc-issue issuer-name worker-prefix %schema-skill
                            `(("skill"             . "electrosurgeon")
                              ("founding-event-id" . ,work-said)
                              ("issued-by"         . ,issuer-name))
                            #:edges
                            `((founding-event
                               . ((n . ,work-said)
                                  (s . ,%schema-work-event)
                                  (o . "NI2I")))))))
      (set! edged-said said)
      (format #t "  → edged skill SAID: ~a~%" said)
      (and said (string-prefix? "E" said)))))

;;; ── 7. verify each credential landed + conforms ─────────────────────────────
;;; Fetch each issued SAID back from KERIA (GET /credentials/<said>) and confirm
;;; KERIA returns the ACDC with the SAID, issuer, holder and schema we sent —
;;; i.e. it validated against the resolved schema and stored it.

(define (verify-cred label said want-schema want-holder)
  (check-call label
    (lambda ()
      (unless said (error "no SAID issued"))
      (let* ((c    (keri-get-credential said))
             (sad  (or (assoc-ref c "sad") c))
             (d    (and sad (assoc-ref sad "d")))
             (s    (and sad (assoc-ref sad "s")))
             (a    (and sad (assoc-ref sad "a")))
             (i    (and a   (assoc-ref a "i"))))
        (format #t "  → got d=~a s=~a holder=~a~%" d s i)
        (and (equal? d said)
             (equal? s want-schema)
             (equal? i want-holder))))))

(verify-cred "verify skill cred lands + conforms"
             skill-said %schema-skill worker-prefix)
(verify-cred "verify work-event cred lands + conforms"
             work-said %schema-work-event worker-prefix)
(verify-cred "verify edged skill cred lands + conforms"
             edged-said %schema-skill worker-prefix)

;;; ── 8. the list route (POST /credentials/query) returns our creds ───────────
;;; Exercises keri-list-credentials — KERIA serves listing via POST
;;; /credentials/query, not a bare GET /credentials (which 401s). This is the
;;; path ^keria-acdc-store's sync! uses to repopulate its cache from KERIA.

(check-call "list credentials (POST /credentials/query) shows our creds"
  (lambda ()
    (let* ((creds (keri-list-credentials #:limit 50))
           (lst   (cond ((vector? creds) (vector->list creds))
                        ((list? creds)   creds)
                        (else '())))
           (saids (filter-map
                    (lambda (c)
                      (let ((sad (or (assoc-ref c "sad") c)))
                        (and sad (assoc-ref sad "d"))))
                    lst)))
      (format #t "  → ~a credentials listed~%" (length lst))
      (let ((want (filter values (list skill-said work-said edged-said))))
        (every (lambda (s) (member s saids)) want)))))

;;; ── 9. IPEX grant → admit round-trip for an economic cred ───────────────────
;;; The skill cred is issued to `worker`. Now the issuer (econ-scope) GRANTs it
;;; over IPEX; the holder discovers the grant via a notification (the same
;;; `{a:{r,d}}` shape the production poll-loop in notifications.scm consumes)
;;; and ADMITs it. This is the disclosure handshake `^keria-acdc-store`'s
;;; %try-grant drives outbound and the notification poll-loop drives inbound —
;;; proven here end-to-end live for our economic schemas for the first time.
;;; (Single KERIA agent: issuer + holder are two AIDs under one controller, so
;;; KERIA both sends the grant and raises the holder's notification.)

(define %grant-exn-said #f)

;; KERIA's POST /ipex/grant returns a long-running operation whose
;; metadata.said IS the grant exn's SAID (ipexing.py: agent.grants.append +
;; monitor.submit(metadata={said,…})). Pull it from there, or fall back to the
;; SAID encoded in the operation name (keri-op-name-said).
(define (grant-exn-said resp)
  (or (and=> (assoc-ref resp "metadata")
             (lambda (m) (and (pair? m) (assoc-ref m "said"))))
      (assoc-ref resp "said")
      (keri-op-name-said resp)))

(check-call "IPEX grant: econ-scope grants skill cred to worker"
  (lambda ()
    (let ((resp (acdc-grant issuer-name skill-said worker-prefix)))
      (set! %grant-exn-said (grant-exn-said resp))
      (format #t "  → grant exn SAID: ~a~%" %grant-exn-said)
      (and %grant-exn-said (string-prefix? "E" %grant-exn-said)))))

;; The grant exn KERIA stored must embed exactly the cred we granted —
;; confirms the disclosure carries the right ACDC.
(check-call "IPEX grant exn references the granted cred"
  (lambda ()
    (unless %grant-exn-said (error "no grant exn SAID"))
    (let* ((msg (keri-get-exchange %grant-exn-said))
           ;; Spec-complete acdc-grant embeds the full SAD in exn.e.acdc;
           ;; tolerate both wrapped ({exn:{e:{acdc}}}) and bare shapes, the
           ;; legacy a.acdc location, and both a string-SAID and a SAD.
           (ref (or (assoc-path msg "exn" "e" "acdc")
                    (assoc-path msg "e" "acdc")
                    (assoc-path msg "exn" "a" "acdc")
                    (assoc-path msg "a" "acdc")))
           (said (cond ((string? ref) ref)
                       ((pair? ref)   (acdc-said ref))
                       (else          #f))))
      (format #t "  → grant exn references cred ~a~%" said)
      (equal? skill-said said))))

;; Holder admits the disclosure. KERIA accepts the admit exn referencing the
;; grant — the receiving half of the IPEX handshake, live for an economic cred.
(check-call "IPEX admit: worker admits the granted cred"
  (lambda ()
    (unless %grant-exn-said (error "no grant to admit"))
    (let ((op (acdc-admit "worker" %grant-exn-said)))
      (when (and (pair? op) (assoc-ref op "name"))
        (false-if-exception (keri-wait-operation op #:timeout 20)))
      (and op #t))))

;; NB: the production INBOUND path (notifications.scm poll-loop →
;; handle-ipex-grant → acdc-admit) discovers grants via a notification KERIA
;; raises only once the grant is DELIVERED to the holder's mailbox. That
;; async delivery rides the same witness/mailbox transport as witnessed
;; receipts (a documented Phase-3 gap — docs/keri/IMPLEMENTATION.md §"Witness
;; receipts"). Here issuer+holder share one KERIA agent, so we drive admit
;; directly from the grant exn SAID rather than waiting on mailbox delivery;
;; the grant/admit exns themselves are proven accepted by KERIA above.

;;; ── 10. IPEX INBOUND: grant to a WITNESSED recipient → notification ─────────
;;; The production inbound path (notifications poll-loop → handle-ipex-grant)
;;; needs KERIA to DELIVER the grant to the recipient's mailbox; for a
;;; witnessless recipient that delivery has nowhere to land (diagnosed when
;;; section 9 was built). A recipient witnessed by the pool witness has a
;;; mailbox — this section proves the delivery → notification leg live.

(define %wit-aid (getenv "KERI_POOLWIT_AID"))
(define wholder-prefix #f)
(define wgrant-cred-said #f)
(define %wgrant-exn-said #f)

(if (not %wit-aid)
    (format #t "~%-- 10. SKIP: no pool witness exported --~%")
    (begin
      (format #t "~%-- 10. IPEX inbound via witnessed recipient --~%")

      (check-call "incept witnessed holder (toad=1, pool witness)"
        (lambda ()
          ;; resolve the witness so KERIA can collect receipts
          (let ((op (keri-resolve-oobi (getenv "KERI_POOLWIT_OOBI")
                                       #:alias "poolwit")))
            (when (and (pair? op) (assoc-ref op "name"))
              (keri-wait-operation op #:timeout 30)))
          (let* ((op   (keri-create-aid "wholder"
                                        #:toad 1
                                        #:witnesses (list %wit-aid)))
                 (done (keri-wait-operation op #:timeout 90)))
            (set! wholder-prefix
                  (or (and=> (assoc-ref done "response")
                             (lambda (r) (and (pair? r) (assoc-ref r "i"))))
                      (and=> (keri-get-aid "wholder")
                             (lambda (d) (assoc-ref d "prefix")))))
            (format #t "  → wholder: ~a~%" wholder-prefix)
            (and wholder-prefix (string? wholder-prefix)))))

      ;; The canonical signify step our suites had skipped: the AID
      ;; authorizes the KERIA agent as its `agent` end-role, which is what
      ;; lets the postman route IPEX to the agent endpoint (= deliver the
      ;; grant and raise the notification).
      (check-call "authorize agent end-role for wholder"
        (lambda ()
          (let* ((ctx       (@@ (playnet keri bridge) *signify-ctx*))
                 (agent-aid (signify-context-agent-aid ctx))
                 (op        (keri-add-end-role "wholder" "agent" agent-aid)))
            (format #t "  → agent eid: ~a~%" agent-aid)
            (when (and (pair? op) (assoc-ref op "name"))
              (keri-wait-operation op #:timeout 30))
            #t)))

      (check-call "issue cred to the witnessed holder"
        (lambda ()
          (let ((said (acdc-issue issuer-name wholder-prefix %schema-skill
                                  `(("skill"     . "witnessed-holder")
                                    ("issued-by" . ,issuer-name)))))
            (set! wgrant-cred-said said)
            (and said (string-prefix? "E" said)))))

      (check-call "IPEX grant to witnessed holder"
        (lambda ()
          (let ((resp (acdc-grant issuer-name wgrant-cred-said
                                  wholder-prefix)))
            (set! %wgrant-exn-said (grant-exn-said resp))
            (format #t "  → wgrant exn SAID: ~a~%" %wgrant-exn-said)
            (and %wgrant-exn-said #t))))

      ;; The delivery leg: with the holder witnessed (mailbox) + agent
      ;; end-role (route) + a spec-complete grant (acdc/iss/anc embedded
      ;; in `e` with -L pathed attachments), KERIA's postman gathers the
      ;; credential artifacts and forwards them to the agent endpoint,
      ;; and the receiving handler raises the /exn/ipex/grant
      ;; notification the production poll-loop consumes. Async — poll.
      (check-call "grant DELIVERED: /exn/ipex/grant notification raised"
        (lambda ()
          ;; Match THIS grant's exn SAID, not just any grant notification
          ;; (section 9's same-agent grant also raises one now that
          ;; grants are spec-complete).
          (let loop ((tries 0))
            (let* ((batch (keri-list-notifications #:start 0 #:end 49))
                   (notes (keri-as-list batch))
                   (hit   (find (lambda (n)
                                  (and (equal? "/exn/ipex/grant"
                                               (assoc-path n "a" "r"))
                                       (equal? %wgrant-exn-said
                                               (assoc-path n "a" "d"))))
                                notes)))
              (cond
               (hit
                (format #t "  → grant notification, exn ~a~%"
                        (assoc-path hit "a" "d"))
                #t)
               ((>= tries 30) #f)
               (else (sleep 2) (loop (+ tries 1))))))))
      ))

;;; ── summary ─────────────────────────────────────────────────────────────────

(test-summary!)
