;;; tests/governance/test-scope-portability.scm
;;;
;;; The portability claim: a scope's state directory
;;; (<state>/scopes/<aid>/) is the complete portable artifact. Tar it
;;; up, drop on another gateway, run restore-all-scopes! → the scope is
;;; back with the same AID, same kind, same KERIA alias, ready to
;;; sign/issue/admit on the new host.
;;;
;;; This test exercises the on-disk persistence layer in isolation —
;;; the bran-vault round-trip is already covered by test-recovery.scm.
;;; Here we just verify that kind + aid-name persist and recover
;;; correctly, since those are what Phase 3 adds.

(use-modules (playnet test harness)
             (playnet utils paths)
             (srfi srfi-13)
             (ice-9 ftw))

;;; Sandbox: redirect playnet-state-dir to a temp dir per run.

(define %tmp-root
  (let ((p (string-append "/tmp/playnet-portability-test-"
                          (number->string (getpid)))))
    (ensure-directory! p)
    p))

(current-playnet-state-dir-override %tmp-root)

(define %aid-1 "E_TEST_COMMUNE_AID_111111111111111111111111")
(define %aid-2 "E_TEST_FED_AID_2222222222222222222222222222")

;; ── kind round-trip ─────────────────────────────────────────────────

(write-scope-kind! %aid-1 'commune)
(check "kind round-trip: commune"
       (eq? 'commune (read-scope-kind %aid-1)))

(write-scope-kind! %aid-2 'federation)
(check "kind round-trip: federation"
       (eq? 'federation (read-scope-kind %aid-2)))

(check "read-scope-kind returns #f for unknown AID"
       (not (read-scope-kind "E_NEVER_WRITTEN")))

;; ── aid-name round-trip ─────────────────────────────────────────────

(define %default-name (default-scope-aid-name %aid-1))
(check "default-scope-aid-name follows scope-<aid> convention"
       (equal? %default-name "scope-E_TEST_COMMUNE_AID_111111111111111111111111"))

(write-scope-aid-name! %aid-1 %default-name)
(check "aid-name round-trip: conventional"
       (equal? %default-name (read-scope-aid-name %aid-1)))

;; Non-conventional alias also round-trips — supports operator-imported
;; scopes that came from a host using a different naming convention.
(write-scope-aid-name! %aid-2 "imported-alias-2")
(check "aid-name round-trip: non-conventional"
       (equal? "imported-alias-2" (read-scope-aid-name %aid-2)))

(check "read-scope-aid-name returns #f for unknown AID"
       (not (read-scope-aid-name "E_NEVER_WRITTEN")))

;; ── overwrite is idempotent ─────────────────────────────────────────

(write-scope-aid-name! %aid-1 %default-name)
(write-scope-aid-name! %aid-1 %default-name)
(check "aid-name double-write yields same value"
       (equal? %default-name (read-scope-aid-name %aid-1)))

;; ── directory layout matches expected paths ─────────────────────────

(check "kind file lives at scope-kind-file path"
       (file-exists? (scope-kind-file %aid-1)))

(check "aid-name file lives at scope-aid-name-file path"
       (file-exists? (scope-aid-name-file %aid-1)))

(check "both files sit inside the scope-state-dir"
       (and (string-prefix? (scope-state-dir %aid-1)
                            (scope-kind-file %aid-1))
            (string-prefix? (scope-state-dir %aid-1)
                            (scope-aid-name-file %aid-1))))

;; Cleanup
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

(rm-rf %tmp-root)

(test-summary!)
