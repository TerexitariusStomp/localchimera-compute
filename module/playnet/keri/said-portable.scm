;;; module/playnet/keri/said-portable.scm — Hoot-portable SAID derivation
;;;
;;; The credential SAID computation, extracted from governance/credentials.scm
;;; so BOTH the server and the browser derive identical SAIDs from identical
;;; content. Same split as `signify-portable.scm`: pure Scheme over an
;;; injectable crypto backend, so it compiles unchanged under Hoot/WASM.
;;;
;;; Why the browser needs it: a citizen's KERI key lives client-side, so for a
;;; citizen-issued ACDC (a stance, a delegation) to be a *conformant* ACDC the
;;; citizen's own controller must sign it. Signing a SAID handed down by the
;;; server would be blind-signing — the client must be able to RE-DERIVE the
;;; SAID from the claims it is agreeing to before it signs. That requires this
;;; module on both sides.
;;;
;;; SAID = Blake3-256 over the canonical rendering of
;;;   (issuer holder schema sorted-claims sorted-edges)
;;; encoded CESR qb64 under code "E" (44 chars), per KERI/ACDC.
;;;
;;; Blake3 backend: this module is pure — it holds no FFI reference of its own,
;;; because it compiles under Hoot/WASM, which has neither `module-ref`/
;;; `resolve-interface` nor a native libblake3. The implementation is INJECTED
;;; via `install-said-blake3!`:
;;;   - Server: (playnet keri said) installs the lazy-FFI blake3 (which preserves the
;;;     deliberate no-dlopen-at-load-time behaviour — the ref resolves on first
;;;     actual use, not here).
;;;   - Hoot: day-boot.scm installs the noble.js-backed implementation at boot.
;;; Using compute-said before either has installed a backend is an error, not a
;;; silent wrong answer.

(define-module (playnet keri said-portable)
  #:use-module (rnrs bytevectors)
  #:use-module ((playnet keri cesr) #:select (cesr-bytes->qb64))
  #:export (canonical-string
            said-sort-pairs
            compute-said
            install-said-blake3!))

;;; ── Blake3 backend (injected — no FFI here, so this stays Hoot-clean) ────────

(define %said-blake3-impl #f)

(define (install-said-blake3! fn)
  "Install a blake3-256 implementation (bytevector → 32-byte bytevector).
   Both the server and the Hoot build call this at load/boot; see module header."
  (set! %said-blake3-impl fn))

(define (%said-blake3 bv)
  (unless %said-blake3-impl
    (error "said-portable: no blake3-256 backend installed (call install-said-blake3!)"))
  (%said-blake3-impl bv))

;;; ── Canonicalization ────────────────────────────────────────────────────────

(define (canonical-string x)
  (cond
    ((null? x) "()")
    ((pair? x)
     (string-append "("
                    (canonical-string (car x))
                    " . "
                    (canonical-string (cdr x))
                    ")"))
    ((string? x) (string-append "\"" x "\""))
    ((symbol? x) (symbol->string x))
    ((number? x) (number->string x))
    ((boolean? x) (if x "#t" "#f"))
    ;; `write` rendering — identical to the `(format #f "~s" x)` this replaced,
    ;; but without depending on (ice-9 format), which Hoot does not provide.
    ;; GUARDED: an object whose written form contains "#<" (a Goblins
    ;; hashmap, a record, a procedure) has no readable, printer-independent
    ;; rendering — its text depends on the host's printer (the goblins
    ;; hashmap printer even TRUNCATES after 10 pairs), so hashing it makes
    ;; the SAID non-portable and lets two distinct values collide. That is
    ;; never SAID material; refusing loudly here is what turned the
    ;; expression-stance distribution bug from a silent vote-collision into
    ;; an error at mint time. Vectors ("#(…)") and other readable forms
    ;; pass through untouched.
    (else
     (let ((s (call-with-output-string (lambda (port) (write x port)))))
       (let loop ((i 0))
         (cond
           ((> (+ i 1) (- (string-length s) 1)) s)
           ((and (char=? (string-ref s i) #\#)
                 (char=? (string-ref s (+ i 1)) #\<))
            (error "canonical-string: unrenderable object in SAID material (fold it to an alist first)" s))
           (else (loop (+ i 1)))))))))

(define (said-sort-pairs pairs)
  "Sort an alist by key for order-INDEPENDENT hashing. Field maps are
   mappings, not ordered lists (ACDC §: reproducible serialization
   requires a canonical ordering); a SAID must therefore be invariant
   under key reordering, or it cannot survive a serialization round trip
   (e.g. JSON object-key reordering) — the precondition for any verifier
   to re-derive it. Keys are symbols or strings; compare by their
   canonical-string rendering so mixed-type keys still order totally."
  (sort pairs (lambda (a b) (string<? (canonical-string (car a))
                                      (canonical-string (car b))))))

;;; ── SAID ────────────────────────────────────────────────────────────────────

(define* (compute-said issuer holder schema claims #:optional (edges '()))
  "Deterministic SAID: Blake3-256 of the canonical content, encoded as
   CESR qb64 under code \"E\" (44 chars). Matches KERI / ACDC SAID
   format so credentials are portable to foreign verifiers.

   EDGES is the ACDC `e` block; folded into the hash so any edge
   change produces a different SAID (ACDC §8 invariant).

   Claims and edges are canonicalized to sorted-key order before
   hashing, so the SAID commits to the field *set* and is reproducible
   after any serialization that reorders object keys. Edge sub-blocks
   (the n/o/s specs) are sorted too, since they are field maps as well."
  (let* ((claims* (said-sort-pairs claims))
         (edges*  (map (lambda (e) (cons (car e) (said-sort-pairs (cdr e))))
                       (said-sort-pairs edges)))
         (canonical (list issuer holder schema claims* edges*))
         (text (canonical-string canonical))
         (digest (%said-blake3 (string->utf8 text))))
    (cesr-bytes->qb64 "E" digest)))
