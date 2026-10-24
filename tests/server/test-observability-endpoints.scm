;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; tests/server/test-observability-endpoints.scm
;;;
;;; Unit tests for the three observability endpoints added to
;;; server/serve-static.scm (A2):
;;;
;;;   /federation-status.json — reads <data>/federation-status.scm
;;;   /pending-grants.json    — reads <data>/pending-grants.scm
;;;   /audit/{aid}.json       — scans <state>/scopes/{aid}/acdc/
;;;
;;; All three are file-driven; we set up a temp state dir, populate
;;; the files the gateway would write, drive the handlers, assert
;;; the JSON shape. No HTTP / no subprocess.
;;;
;;; The handlers are not exported from serve-static; we re-resolve
;;; them via module-ref (same pattern test-ipex-grant-handler uses).
;;;
;;; Run: guile -L module -L tests tests/server/test-observability-endpoints.scm

(use-modules (localchimera test harness)
             (localchimera utils paths)
             (web request)
             (web response)
             (rnrs bytevectors)
             (ice-9 ftw)
             (json))

(define srv-mod (resolve-module '(server serve-static)))
(define handle-federation-status (module-ref srv-mod 'handle-federation-status))
(define handle-pending-grants    (module-ref srv-mod 'handle-pending-grants))
(define handle-audit             (module-ref srv-mod 'handle-audit))

;; Sandbox the state dir.
(define %tmp-root
  (let ((p (string-append "/tmp/localchimera-obs-test-"
                          (number->string (getpid)))))
    (ensure-directory! p)
    p))
(current-localchimera-state-dir-override %tmp-root)   ; /audit's scopes/ scan
;; the status + queue probes follow LOCALCHIMERA_DATA_DIR (where the gateway
;; writes them) — point both conventions at the same sandbox root
(setenv "LOCALCHIMERA_DATA_DIR" %tmp-root)

(define (rm-rf path)
  (when (file-exists? path)
    (cond
     ((eq? (stat:type (lstat path)) 'directory)
      (for-each (lambda (entry)
                  (unless (member entry '("." ".."))
                    (rm-rf (string-append path "/" entry))))
                (or (scandir path) '()))
      (rmdir path))
     (else (delete-file path)))))

;; ── /federation-status.json ──────────────────────────────────────────

(define (call-handler thunk)
  ;; Handlers return (values response body); call them inside
  ;; call-with-values to package the pair as a list.
  (call-with-values thunk list))

(define (status-of pair) (response-code (car pair)))
(define (body-of pair)   (cadr pair))
(define (json-of pair)   (json-string->scm (body-of pair)))

;; Missing file → 503 with hint
(let ((r (call-handler handle-federation-status)))
  (check "federation-status (no file): 503"
         (status-of r) 503)
  (check "federation-status (no file): JSON has hint"
         (string? (assoc-ref (json-of r) "hint"))))

;; Write the status file the gateway would write
(call-with-output-file (string-append %tmp-root "/federation-status.scm")
  (lambda (port)
    (write `((boot-time . 1700000000)
             (peers . 3)
             (federation-parent-uc . "E_test_parent_uc")
             (keri-connected? . #t)
             (auditors . 2)
             (custody-watchers . 5))
           port)
    (newline port)))

(let* ((r (call-handler handle-federation-status))
       (j (json-of r)))
  (check "federation-status: 200" (status-of r) 200)
  (check "federation-status: peers" (assoc-ref j "peers") 3)
  (check "federation-status: federation-parent-uc"
         (assoc-ref j "federation-parent-uc") "E_test_parent_uc")
  (check "federation-status: local-uc empty until the aid file exists"
         (assoc-ref j "local-uc") "")
  (check "federation-status: keri-connected"
         (assoc-ref j "keri-connected") #t)
  (check "federation-status: auditors" (assoc-ref j "auditors") 2)
  (check "federation-status: custody-watchers"
         (assoc-ref j "custody-watchers") 5))

;; The LOCAL UC joins in from the same aid file /universal-commune.json
;; serves; a status file written by a pre-rename gateway (old `uc-aid`
;; key) still renders its parent during rollout.
(call-with-output-file (string-append %tmp-root "/universal-commune-aid.txt")
  (lambda (port) (display "E_test_local_uc\n" port)))
(call-with-output-file (string-append %tmp-root "/federation-status.scm")
  (lambda (port)
    (write `((boot-time . 1700000000) (peers . 0) (uc-aid . "E_old_key_parent")
             (keri-connected? . #f) (auditors . 0) (custody-watchers . 0))
           port)
    (newline port)))

(let ((j (json-of (call-handler handle-federation-status))))
  (check "federation-status: local-uc from the aid file"
         (assoc-ref j "local-uc") "E_test_local_uc")
  (check "federation-status: pre-rename uc-aid key still read as the parent"
         (assoc-ref j "federation-parent-uc") "E_old_key_parent"))

;; ── /pending-grants.json ─────────────────────────────────────────────

;; No file → empty queue
(let* ((r (call-handler handle-pending-grants))
       (j (json-of r)))
  (check "pending-grants (no file): 200" (status-of r) 200)
  (check "pending-grants (no file): count = 0"
         (assoc-ref j "count") 0)
  (check "pending-grants (no file): entries is empty array"
         (vector? (assoc-ref j "entries"))))

;; Write two pending entries (in the format pending-grants.scm uses:
;; one S-expression per line, each is (kind . payload-alist))
(call-with-output-file (string-append %tmp-root "/pending-grants.scm")
  (lambda (port)
    (write '(scope-grant
             (scope-aid . "E_scope_A")
             (seed-hex  . "deadbeef")
             (cred-said . "E_cred_1")
             (holder    . "E_holder_1"))
           port)
    (newline port)
    (write '(umbrella-grant
             (issuer-aid-name . "localchimera-governance")
             (said            . "E_cred_2")
             (holder          . "E_holder_2"))
           port)
    (newline port)))

(let* ((r (call-handler handle-pending-grants))
       (j (json-of r))
       (entries (vector->list (assoc-ref j "entries"))))
  (check "pending-grants: 200" (status-of r) 200)
  (check "pending-grants: count = 2" (assoc-ref j "count") 2)
  (check "pending-grants: first entry is scope-grant"
         (assoc-ref (car entries) "kind") "scope-grant")
  (check "pending-grants: second entry is umbrella-grant"
         (assoc-ref (cadr entries) "kind") "umbrella-grant")
  (check "pending-grants: scope-grant has cred-said in payload"
         (assoc-ref (assoc-ref (car entries) "payload") "cred-said")
         "E_cred_1"))

;; ── /audit/{aid}.json ────────────────────────────────────────────────

(define %fed-aid "E_test_federation_AID")
(define %acdc-bucket
  (string-append %tmp-root "/scopes/" %fed-aid "/acdc/00"))
(ensure-directory! %acdc-bucket)

;; No credentials → 404
(let ((r (call-handler (lambda () (handle-audit %fed-aid)))))
  (check "audit (no creds): 404" (status-of r) 404))

;; Write a single audit-pass credential alist (matching cred-* format)
(call-with-output-file (string-append %acdc-bucket "/cred-pass-001.scm")
  (lambda (port)
    (write '((said      . "E_audit_pass_001")
             (schema    . "localchimera-audit-pass/v1")
             (issuer    . "E_auditor_aid")
             (holder    . "E_test_federation_AID")
             (claims    . ((cycle . 1)))
             (edges     . ())
             (signature . #f)
             (revoked?  . #f))
           port)
    (newline port)))

(let* ((r (call-handler (lambda () (handle-audit %fed-aid))))
       (j (json-of r)))
  (check "audit (have pass): 200" (status-of r) 200)
  (check "audit: schema = audit-pass"
         (assoc-ref j "schema") "localchimera-audit-pass/v1")
  (check "audit: said populated"
         (assoc-ref j "said") "E_audit_pass_001")
  (check "audit: not revoked"
         (assoc-ref j "revoked") #f))

;; Write a NEWER incoherence-alert; should win on mtime
(sleep 1)  ; ensure mtime differs
(call-with-output-file (string-append %acdc-bucket "/cred-alert-002.scm")
  (lambda (port)
    (write '((said      . "E_audit_alert_002")
             (schema    . "localchimera-incoherence-alert/v1")
             (issuer    . "E_auditor_aid")
             (holder    . "E_test_federation_AID")
             (claims    . ((violations . ((double-counted-members . ((aid1)))))))
             (edges     . ())
             (signature . #f)
             (revoked?  . #f))
           port)
    (newline port)))

(let* ((r (call-handler (lambda () (handle-audit %fed-aid))))
       (j (json-of r)))
  (check "audit (mixed): newest wins"
         (assoc-ref j "said") "E_audit_alert_002")
  (check "audit (mixed): schema reflects alert"
         (assoc-ref j "schema") "localchimera-incoherence-alert/v1"))

;; Cleanup
(rm-rf %tmp-root)

(test-summary!)
