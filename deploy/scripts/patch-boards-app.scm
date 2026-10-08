#!/usr/bin/env -S guile -L module
!#
;;; deploy/scripts/patch-boards-app.scm — self-healing patch for the vendored
;;; radicle-planning-boards static app (browser/boards/).
;;;
;;; This app is a prebuilt, self-hosted third-party release, not something
;;; this repo builds from source (see the "radicle-planning-boards:
;;; self-host full stack behind playnet.earth front" commits). It gets three
;;; things wrong for a self-hosted, non-127.0.0.1 origin, and every time
;;; someone drops in a freshly-fetched copy, all three come back:
;;;
;;;  1. Its JS hardcodes an API-base fallback for a developer's own local
;;;     `rad web` session (pc="http://127.0.0.1:8080") — wrong for a visitor
;;;     browsing the real deployment. This exact fix has already been
;;;     hand-applied and lost to a rebuild six times before this script
;;;     existed (83b739df, ad3bee71, e91b58a0, dae486a9, 36c57741, 021ac983,
;;;     b9934741 — see `git log --oneline -- browser/boards`).
;;;  2. Its own runtime-config script (window.__NUXT__.config, which carries
;;;     the *correct* relative API base, "/api/v1") sits near the end of
;;;     <body>, but the app's top-level code reads it at module-load time —
;;;     before that script has run for a fresh visit — so the read sees
;;;     `undefined` ("Uncaught TypeError: can't access property 'baseURL',
;;;     Qs is undefined"). Moving it earlier fixes it; putting it back at
;;;     the end (a fresh rebuild's default) reintroduces it.
;;;  3. The page's CSP script-src is a hash allowlist, and the JS file has a
;;;     matching SRI `integrity="sha384-…"` — both are literal content
;;;     hashes. Any patch to the JS, or any HTML restructuring, invalidates
;;;     both unless they're recomputed from the actual patched files.
;;;
;;; This script fixes all three from the files as they actually are, not
;;; from any hardcoded hash or filename — Nuxt content-hashes every build
;;; output, so filenames change on every real rebuild. It is idempotent:
;;; safe to run on an untouched, freshly-fetched copy (which is the point:
;;; it's designed to survive the next upstream rebuild unattended) and a
;;; no-op on an already-patched one.
;;;
;;; Usage: deploy/scripts/patch-boards-app.scm [boards-dir]
;;;   boards-dir defaults to browser/boards relative to the repo root
;;;   (found the same way satellite-pins.scm finds it: three dirnames up
;;;   from this script's own path).
;;;
;;; Wired into deploy/scripts/radicle-ci-hook.sh's deploy path (runs before
;;; the CDN purge, so a fix never ships without the purge that makes it
;;; visible) and exposed as `make patch-boards` for a local/manual run.

(use-modules (ice-9 popen)
             (ice-9 rdelim)
             (ice-9 textual-ports)
             (ice-9 ftw)
             (rnrs bytevectors)
             (srfi srfi-1)
             (srfi srfi-13))

;; the origin the boards fall back to; PLAYNET_ORIGIN names this deployment's own
(define %playnet-origin (or (getenv "PLAYNET_ORIGIN") "https://playnet.earth"))
(define %local-fallback-pattern "pc=\"http://127.0.0.1:8080\"")
(define %local-fallback-replacement (string-append "pc=\"" %playnet-origin "\""))

;;; ── tiny IO helpers ──────────────────────────────────────────────────────

(define (read-file path)
  (call-with-input-file path get-string-all))

(define (write-file path content)
  (call-with-output-file path
    (lambda (port) (put-string port content))))

(define (run->string . args)
  (let* ((port (apply open-pipe* OPEN_READ args))
         (out (get-string-all port)))
    (close-pipe port)
    (string-trim-right out)))

;;; ── hashing: shell out for the digest, base64-encode it ourselves ──────
;;; (sha256sum/sha384sum are on PATH; there's no `xxd` on this box to go
;;; hex -> bytes -> base64 through the `base64` binary, so the encode step
;;; is hand-rolled here instead of adding a dependency.)

(define %b64-alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(define (hex->bytevector hex)
  (let* ((n (quotient (string-length hex) 2))
         (bv (make-bytevector n)))
    (let loop ((i 0))
      (if (< i n)
          (begin
            (bytevector-u8-set! bv i
              (string->number (substring hex (* i 2) (+ (* i 2) 2)) 16))
            (loop (+ i 1)))
          bv))))

(define (bytevector->base64 bv)
  (let* ((n (bytevector-length bv))
         (out (open-output-string)))
    (let loop ((i 0))
      (when (< i n)
        (let* ((b0 (bytevector-u8-ref bv i))
               (b1 (if (< (+ i 1) n) (bytevector-u8-ref bv (+ i 1)) 0))
               (b2 (if (< (+ i 2) n) (bytevector-u8-ref bv (+ i 2)) 0))
               (triple (logior (ash b0 16) (ash b1 8) b2))
               (c0 (string-ref %b64-alphabet (logand (ash triple -18) #x3f)))
               (c1 (string-ref %b64-alphabet (logand (ash triple -12) #x3f)))
               (c2 (if (< (+ i 1) n)
                       (string-ref %b64-alphabet (logand (ash triple -6) #x3f))
                       #\=))
               (c3 (if (< (+ i 2) n)
                       (string-ref %b64-alphabet (logand triple #x3f))
                       #\=)))
          (write-char c0 out) (write-char c1 out)
          (write-char c2 out) (write-char c3 out))
        (loop (+ i 3))))
    (get-output-string out)))

(define (file-hash-base64 algo path)
  ;; algo is "sha256sum" or "sha384sum"; both print "<hex>  <path>\n".
  (let* ((line (run->string algo path))
         (hex (car (string-split line #\space))))
    (bytevector->base64 (hex->bytevector hex))))

(define (string-hash-base64 algo content)
  (let ((tmp (string-append (or (getenv "TMPDIR") "/tmp")
                             "/patch-boards-app-" (number->string (random 1000000)))))
    (write-file tmp content)
    (let ((h (file-hash-base64 algo tmp)))
      (delete-file tmp)
      h)))

;;; ── literal string search/replace (no regex — this content is full of
;;;    regex metacharacters: +, /, ., (, ) …) ─────────────────────────────

(define (replace-once haystack needle replacement)
  (let ((i (string-contains haystack needle)))
    (if i
        (string-append (substring haystack 0 i)
                        replacement
                        (substring haystack (+ i (string-length needle))))
        haystack)))

(define (replace-all haystack needle replacement)
  (let loop ((s haystack))
    (if (string-contains s needle)
        (loop (replace-once s needle replacement))
        s)))

;;; ── step 1: JS fallback string ───────────────────────────────────────────

(define (patch-js-file! path)
  (let ((content (read-file path)))
    (when (string-contains content %local-fallback-pattern)
      (write-file path (replace-all content %local-fallback-pattern
                                     %local-fallback-replacement))
      (format #t "patch-boards-app: fixed local-node fallback in ~a~%" path))))

;;; ── step 2/3: HTML — move the config script first, recompute hashes ─────

(define (tag-attr-value tag-text attr)
  "Value of ATTR=\"…\" inside TAG-TEXT (a full opening-tag string), or #f."
  (let ((i (string-contains tag-text (string-append attr "=\""))))
    (and i
         (let* ((start (+ i (string-length attr) 2))
                (end (string-index tag-text #\" start)))
           (and end (substring tag-text start end))))))

(define (opening-tag-at html start-of-lt)
  "The full '<…>' opening-tag text starting at HTML's index START-OF-LT."
  (substring html start-of-lt (+ 1 (string-index html #\> start-of-lt))))

(define (extract-inline-scripts html)
  "List of (start . end) index pairs, each spanning a full bare
'<script>…</script>' block. A BARE tag (no attributes) never matches a
typed one (type=\"module\", type=\"application/json\", …), so this only
ever finds the scripts we care about."
  (let loop ((search-from 0) (acc '()))
    (let ((start (string-contains html "<script>" search-from)))
      (if (not start)
          (reverse acc)
          (let* ((close (string-contains html "</script>" start))
                 (end (+ close (string-length "</script>"))))
            (loop end (cons (cons start end) acc)))))))

(define (rewrite-sri-hashes html)
  "Recompute every 'integrity=\"sha384-…\"' in HTML from the file its tag's
href/src actually points at. Returns (values new-html sha384-hash-list)."
  (define (local-path-of href)
    (let ((i (string-contains href "/boards/")))
      (string-append %boards-dir "/"
                      (if i (substring href (+ i (string-length "/boards/")))
                          href))))
  (let loop ((h html) (search-from 0) (hashes '()))
    (let ((i (string-contains h "integrity=\"sha384-" search-from)))
      (if (not i)
          (values h (delete-duplicates (reverse hashes)))
          (let* ((tag-start (string-rindex h #\< 0 i))
                 (tag (opening-tag-at h tag-start))
                 (href (or (tag-attr-value tag "href") (tag-attr-value tag "src")))
                 (target (local-path-of href))
                 (old-value (tag-attr-value tag "integrity")))
            (if (file-exists? target)
                (let* ((new-hash (file-hash-base64 "sha384sum" target))
                       (new-h (replace-once h
                                (string-append "integrity=\"" old-value "\"")
                                (string-append "integrity=\"sha384-" new-hash "\""))))
                  (loop new-h (+ i 1) (cons new-hash hashes)))
                (begin
                  (format #t "patch-boards-app: WARNING ~a not found, leaving its integrity hash as-is~%" target)
                  (loop h (+ i (string-length "integrity=\"sha384-")) hashes))))))))

(define (move-config-script-first html)
  "Move the bare inline <script> containing window.__NUXT__ to be the very
first thing inside <head>. No-op if it already is."
  (let* ((spans (extract-inline-scripts html))
         (config-span
          (find (lambda (se)
                  (string-contains (substring html (car se) (cdr se))
                                    "window.__NUXT__"))
                spans))
         (head-i (string-contains html "<head>"))
         (insert-at (and head-i (+ head-i (string-length "<head>")))))
    (if (or (not config-span) (not insert-at)
            (= (car config-span) insert-at))
        html
        (let* ((start (car config-span)) (end (cdr config-span))
               (block (substring html start end))
               (without (string-append (substring html 0 start)
                                        (substring html end))))
          (string-append (substring without 0 insert-at)
                          block
                          (substring without insert-at))))))

(define (rebuild-csp html sha256-hashes sha384-hashes)
  (let* ((i (string-contains html "script-src "))
         (seg-end (string-index html #\; i))
         (rebuilt
          (string-append
           "script-src 'self' https: 'unsafe-inline' 'strict-dynamic'"
           (string-concatenate
            (map (lambda (h) (string-append " 'sha256-" h "'")) sha256-hashes))
           (string-concatenate
            (map (lambda (h) (string-append " 'sha384-" h "'")) sha384-hashes)))))
    (string-append (substring html 0 i) rebuilt (substring html seg-end))))

(define %boards-dir #f) ;; set by main; read by rewrite-sri-hashes's closure

(define (patch-html-file! path)
  (let* ((html (read-file path))
         (html (move-config-script-first html)))
    (call-with-values (lambda () (rewrite-sri-hashes html))
      (lambda (html sha384-hashes)
        (let* ((sha256-hashes
                (map (lambda (se)
                       (string-hash-base64 "sha256sum"
                         (substring html (+ (car se) (string-length "<script>"))
                                    (- (cdr se) (string-length "</script>")))))
                     (extract-inline-scripts html)))
               (html (rebuild-csp html sha256-hashes sha384-hashes)))
          (write-file path html)
          (format #t "patch-boards-app: rewrote ~a (~a inline hash(es), ~a external hash(es))~%"
                  path (length sha256-hashes) (length sha384-hashes)))))))

;;; ── driver ────────────────────────────────────────────────────────────

(define (all-files-with-extension dir ext)
  (filter (lambda (f) (string-suffix? ext f))
          (map (lambda (f) (string-append dir "/" f))
               (or (scandir dir) '()))))

(define (all-js-files-recursive dir)
  (let ((out '()))
    (ftw dir (lambda (filename statinfo flag)
               (when (and (eq? flag 'regular) (string-suffix? ".js" filename))
                 (set! out (cons filename out)))
               #t))
    out))

(define (main args)
  (let* ((here (dirname (dirname (dirname (canonicalize-path (car (command-line)))))))
         (boards-dir (if (> (length args) 1)
                         (cadr args)
                         (string-append here "/browser/boards"))))
    (set! %boards-dir boards-dir)
    (unless (file-exists? boards-dir)
      (format #t "patch-boards-app: ~a does not exist, nothing to do~%" boards-dir)
      (exit 0))
    (for-each patch-js-file! (all-js-files-recursive boards-dir))
    (for-each patch-html-file! (all-files-with-extension boards-dir ".html"))
    (format #t "patch-boards-app: done~%")))

(main (command-line))
