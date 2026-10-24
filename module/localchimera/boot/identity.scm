;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; module/localchimera/boot/identity.scm — the key logs this gateway holds: the oobi-host, who resolves a key, and the mirror every durable scope publishes through.

(define-module (localchimera boot identity)
  #:use-module ((localchimera boot restore) #:select (restored-aid restored-ref restored-vat))
  #:use-module ((localchimera boot site) #:select (data-path log! oobi-auto-mirror? scopes-durable?))
  #:use-module ((localchimera identity devices) #:select (device-keys-at device-registry-dir))
  #:use-module ((localchimera identity oobi-host) #:select (oobi-current-key-from-dir oobi-host-spawn-from-dir))
  #:use-module ((localchimera identity oobi-host-mirror) #:select (spawn-oobi-host-mirror))
  #:use-module ((localchimera keri citizen-sig) #:select (aid-signer-keys-resolver))
  #:use-module ((localchimera personhood attestation-ceremony) #:select (current-aid-key-resolver))
  #:use-module ((localchimera utils paths) #:select (default-scope-witnesses localchimera-data-dir))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (spawn-oobi-host! mirror-key-logs!))

;; ── ^oobi-host (browser-resident-Signify ICP store) ─────────
;; Lives in gateway-vat so ^lobby's keri-authenticate handler
;; can call ($ oobi-host 'current-key …) synchronously when
;; resolving post-rotation signing keys. signup-agent (in
;; signup-vat) writes via async `(<- oobi-host 'put! …)`, so
;; the cross-vat boundary stays on the write path only.
;; Persistence is via a directory under the data dir; on restart
;; oobi-host-spawn-from-dir replays the stored entries.
(define (spawn-oobi-host! gateway-vat)
  "The oobi-host in GATEWAY-VAT over its durable directory, and the two
vat-free key resolvers set over the same directory."
  (let ((oobi-dir (data-path "oobi-host")))
    (unless (file-exists? oobi-dir) (mkdir oobi-dir))
    ;; The witness ceremony verifies a citizen's co-signature in the
    ;; PLANNER vat, where the oobi-host actor is unreachable — a
    ;; browser AID (E-prefix) resolves its current signing key through
    ;; the durable dir instead: a pure file read, callable mid-turn.
    (current-aid-key-resolver
     (lambda (aid) (oobi-current-key-from-dir oobi-dir aid)))
    ;; The keys that sign AS an AID, for every SAID/nonce verification
    ;; anywhere (citizen-sig verify-bytes-under-aid): its current KEL
    ;; key, and the device keys its root had authorized at the
    ;; statement's time (AT; #f = now) — both pure file reads,
    ;; vat-free. docs/planning/identity/device-keys.md.
    (device-registry-dir (localchimera-data-dir))
    (aid-signer-keys-resolver
     (lambda (aid at)
       (let ((cur (oobi-current-key-from-dir oobi-dir aid)))
         (append (if (string? cur) (list cur) '())
                 (device-keys-at aid (or at (current-time)))))))
    (with-vat gateway-vat
      (oobi-host-spawn-from-dir oobi-dir))))

;; §4.6 / §4.1: Wire the oobi-host-mirror into the default
;; witness list so durable scopes auto-publish their KEL events
;; into /oobi/{aid}. Combined with the http-witness-publisher
;; spawned at connect, every durable scope gets local OOBI serving
;; AND cross-internet push for free. Opt-out via
;; LOCALCHIMERA_OOBI_AUTO_MIRROR=0.
(define (mirror-key-logs! signup-vat oobi-host restored)
  "The mirror into OOBI-HOST added to the default witnesses, and every scope
of RESTORED witnessed by it now."
  (when (and (scopes-durable?) (oobi-auto-mirror?))
    (catch #t
      (lambda ()
        (let ((oobi-mirror
               (with-vat signup-vat
                 (spawn-oobi-host-mirror oobi-host))))
          (default-scope-witnesses
            (cons oobi-mirror (default-scope-witnesses)))
          (log! "  [gateway] ^oobi-host-mirror added to default witnesses~%")
          ;; Every durable scope restored (boot/restore) was spawned before
          ;; this mirror existed, so its default #:witnesses was '() — the
          ;; founding commune and the UC among them, restored on every boot
          ;; since before the mirror was ever added. Witness each one now,
          ;; the same door a newly-minted scope gets for free: the mirror
          ;; asks for nothing back, and a scope already holding it as a
          ;; subscriber (a boot after this fix) no-ops.
          (let ((n 0))
            (for-each
             (lambda (r)
               (catch #t
                 (lambda ()
                   ;; Both the fetch AND the witness! call are `$`
                   ;; (same-vat sends) against the scope's own vat —
                   ;; the first version of this fix ran only the
                   ;; fetch inside with-vat and threw "No current
                   ;; syscaller" on witness! the moment it ran on
                   ;; the plain boot thread instead.
                   (with-vat (restored-vat r)
                     (let ((store ($ (restored-ref r) 'kel-store)))
                       (when store
                         ($ store 'witness! oobi-mirror)
                         (set! n (+ n 1))))))
                 (lambda (key . args)
                   (log! "  [gateway] witness-catchup error for ~a: ~a ~a~%"
                         (restored-aid r) key args))))
             restored)
            (when (> n 0)
              (log! "  [gateway] ^oobi-host-mirror caught up on ~a restored scope(s)~%" n)))))
      (lambda (key . args)
        (log! "  [gateway] oobi-host-mirror error: ~a ~a~%" key args)))))
