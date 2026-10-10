;;; server/serve-static.scm — dev/IIW HTTP server with /oobi/{aid} route
;;;
;;; Wraps (hoot web-server)'s `serve` so that:
;;;   - /oobi/{aid}        → returns the stored ICP+sigs as JSON
;;;   - /oobi/{schemaSAID} → returns the catalogued ACDC schema document
;;;   - /.well-known/did/keri/{aid} → returns a minimal DID Document
;;;   - everything else    → static files from --work-dir (default browser/)
;;;
;;; The OOBI directory is shared with the gateway's ^oobi-host actor
;;; (which writes durable entries under data/oobi-host/<prefix-2>/<aid>.scm).
;;; Reading the same directory means the dev server picks up new ICPs as
;;; soon as the browser registers — no IPC needed.
;;;
;;; Usage:
;;;   make serve         (uses default --oobi-dir=data/oobi-host)
;;;   make serve OOBI_DIR=/path

(define-module (server serve-static)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-9)
  #:use-module ((playnet utils operator) #:select (operator-config contact-uri))
  #:use-module (playnet utils paths)
  #:use-module ((playnet vf facts limits) #:select (%feedback-max-bytes %report-max-bytes))
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 binary-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (web server)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web client)             ; http-post → local Valhalla
  #:use-module (web uri)
  #:use-module ((srfi srfi-1)  #:select (any filter-map append-map))
  #:use-module ((srfi srfi-13) #:select (string-suffix? string-drop-right
                                          string-index string-filter))
  #:use-module ((playnet keri signify-portable)
                #:select (cesr-stream-event cesr-stream-kel
                          scm->json-canonical))
  #:use-module ((playnet keri did) #:select (aid->did-keri))
  #:use-module ((playnet utils pmtiles)
                #:select (pmtiles-archives pmtiles-tile pmtiles-tile-compression
                          pmtiles-info pmtiles-path archive-bytes))
  #:use-module ((playnet keri schemas) #:select (schema-document-for-said))
  #:use-module ((playnet identity oobi-host)
                #:select ((read-oobi-entry-from-dir . read-oobi-entry)
                          (read-oobi-entries-from-dir . read-oobi-entries)))
  ;; Read-only scope discovery — use the path-level helpers from
  ;; (playnet utils paths) rather than (playnet scope recovery), because
  ;; the latter transitively loads (playnet keri signify),
  ;; which dlopens libsodium. The playnet-static service runs in a
  ;; minimal env without libsodium and would crash-loop on startup.
  #:use-module ((playnet utils paths)
                #:select (playnet-state-dir read-scope-kind
                          scope-acdc-dir))
  #:use-module ((playnet utils common)
                #:select (read-sexp-file read-all-sexps-file))
  #:use-module (ice-9 ftw)   ; scandir, for inline list-known-scopes
  #:use-module ((srfi srfi-13) #:select (string-trim-both string-null?))
  #:export (run-static-server
            ;; Exported for testability — also serves anyone who wants
            ;; to drive the endpoints from another harness.
            handle-federation-status
            handle-pending-grants
            handle-audit
            handle-peer-status
            handle-osm-tile
            handle-osm-regions
            handle-osm-pack
            handle-feedback-post
            handle-feedback-list
            handle-feedback-delete
            handle-report-post
            handle-report-list
            handle-report-delete
            handle-operator
            handle-security-txt))

;;; The on-disk layout used here is owned by (playnet identity oobi-host); we
;;; route reads through `read-oobi-entry-from-dir` so the bucket-prefix
;;; convention can't drift between writer (actor) and reader (HTTP).

;;; ── Routes ──────────────────────────────────────────────────────────────────
;;;
;;; JSON emission delegates to (playnet keri signify-portable)'s
;;; `scm->json-canonical` — same emitter the SAID computation uses,
;;; which guarantees byte-identical output to guile-json. It accepts
;;; both string and symbol alist keys, so OOBI entry alists (symbol
;;; keys) and DID Documents (string keys) both serialise correctly.

;;; ── Headers ────────────────────────────────────────────────────────────────
;;;
;;; Two header bundles — `%security-headers` rides on every response;
;;; `%keri-no-cache-headers` is added on /oobi and /.well-known/* so
;;; KEL freshness is guaranteed end-to-end (a stale cached KEL could
;;; hide a key rotation — see docs/deploy/OOBI-CLEARNET.md).
;;;
;;; The (web response) `build-response` accepts headers as an alist
;;; where keys are symbols. Raw strings ("Cache-Control") would be
;;; emitted but the symbol form ('cache-control) is canonical and what
;;; the existing handlers already use.

(define %security-headers
  '((x-content-type-options . "nosniff")
    ;; SAMEORIGIN, not DENY: the Radicle Explorer (/radicle/) embeds the
    ;; Planning Boards (/boards/) in an iframe, and both are same-origin on
    ;; this host. DENY blocked that frame ("X-Frame-Options: deny"); SAMEORIGIN
    ;; still blocks cross-origin clickjacking.
    (x-frame-options        . "SAMEORIGIN")
    (referrer-policy        . "no-referrer")
    ;; `(self)`, not `()`. An empty allowlist means NO origin may use the
    ;; feature — including this page — so the server that serves the dial was
    ;; forbidding the dial from ever opening a camera or a microphone. The
    ;; walkie's meeting rooms (docs/planning/faces/meeting-station.md) cannot work
    ;; under that, and neither can the dial's own "set position here": in
    ;; Chromium getUserMedia answered NotAllowedError before any permission
    ;; prompt could appear. Firefox's partial Permissions-Policy support hid
    ;; it — the camera came on there and nowhere else.
    ;;
    ;; `(self)` still denies every THIRD PARTY, which is what this header is
    ;; for: an embedded frame or injected script gets nothing, while the
    ;; first-party dial can ask, and the browser's own prompt stays the thing
    ;; that actually decides.
    (permissions-policy     . "camera=(self), microphone=(self), geolocation=(self)")))

;; cache-control value MUST be a list of directives (symbols + pairs)
;; per Guile's (web http) validator — passing a string raises bad-response.
(define %keri-no-cache-headers
  '((cache-control . (no-store))
    (access-control-allow-origin . "*")))

(define %wasm-extra-headers
  ;; COOP/COEP enable cross-origin isolation which the WASM threading +
  ;; SharedArrayBuffer-backed code needs to run. Matches the prior
  ;; nginx `location ~ \.wasm$` block in deploy/machines.scm.
  ;;
  ;; Cross-origin isolation is granted by the TOP-LEVEL DOCUMENT's own
  ;; response headers, not a subresource's — sending this only on the
  ;; .wasm file itself does nothing for the page that loads it.
  ;; `window.crossOriginIsolated` stayed false and `SharedArrayBuffer`
  ;; stayed undefined even with this header on every .wasm response
  ;; (verified live), which is why app.html's dial entry point needs it
  ;; too. Confirmed real, not hypothetical: the ONNX Runtime Web build
  ;; app/voice/audio.ts downloads (ort-wasm-simd-threaded.asyncify) is
  ;; the THREADED variant, which needs SharedArrayBuffer to spin up its
  ;; worker thread pool — without isolation it hangs indefinitely rather
  ;; than erroring or falling back, reproduced end to end with a real
  ;; gateway + real synthesized speech: all model/runtime downloads
  ;; completed, then transcription never resolved even after a
  ;; generous 180s bound (audio.ts's own worker-hang timeout), because
  ;; nothing was ever going to come back.
  '((cross-origin-embedder-policy . "require-corp")
    (cross-origin-opener-policy   . "same-origin")))

;; Dev mode (make serve sets PLAYNET_DEV=1): serve assets no-store so live edits
;; to app.html / dial JS / CSS show on the very next reload, instead of the
;; browser holding a stale copy for max-age. Prod keeps the CDN-friendly cache.
(define %dev-no-cache? (and (getenv "PLAYNET_DEV") #t))

(define (asset-cache-headers ext)
  "Cache headers for static SPA assets. Short max-age in prod (behind a CDN, the
   asset name or a manual purge handles invalidation); no-store in dev so the
   live-edit loop is never fighting the browser cache."
  (case (string->symbol (or ext ""))
    ((js mjs css wasm png svg ico webp)
     (if %dev-no-cache?
         '((cache-control . (no-store)))
         '((cache-control . (public (max-age . 3600) no-transform)))))
    ;; A document is revalidated on every load: it names the scripts and
    ;; styles of ITS build, and a stale one would ask a new tree for an old
    ;; build's files. Fonts change with a rename, so they are kept long.
    ((html htm)
     (if %dev-no-cache?
         '((cache-control . (no-store)))
         '((cache-control . (no-cache)))))
    ((woff2)
     (if %dev-no-cache?
         '((cache-control . (no-store)))
         '((cache-control . (public (max-age . 2592000) immutable)))))
    (else '())))

(define (with-headers extra base-headers)
  "Merge EXTRA header alist into BASE-HEADERS (BASE wins on conflict)."
  (let loop ((es extra) (acc base-headers))
    (cond
     ((null? es) acc)
     ((assq (caar es) base-headers) (loop (cdr es) acc))
     (else (loop (cdr es) (cons (car es) acc))))))

(define (json-response body-str)
  (values (build-response
           #:code 200
           #:headers
           (with-headers %security-headers
            (append `((content-type . (application/json (charset . "utf-8"))))
                    %keri-no-cache-headers)))
          body-str))

(define (cesr-response body-str)
  ;; KERI CESR text-stream MIME type per draft-ssmith-cesr §1.5; KERIA
  ;; resolvers accept application/cesr-text-stream and application/cesr.
  ;; We emit cesr-text-stream which is the JSON+attachment form
  ;; signify-ts produces.
  (values (build-response
           #:code 200
           #:headers
           (with-headers %security-headers
            (append `((content-type . (application/cesr (charset . "utf-8"))))
                    %keri-no-cache-headers)))
          body-str))

(define (oobi-not-found aid)
  (values (build-response
           #:code 404
           #:headers
           (with-headers %security-headers
            (append '((content-type . (application/json)))
                    %keri-no-cache-headers)))
          (scm->json-canonical
           `(("error" . "AID not registered")
             ("aid"   . ,(or aid ""))))))

(define (cesr-kel-of-entry entry)
  "Build the CESR text-stream OOBI body for ENTRY: ICP frame followed by
   each ROT frame in sequence (canonical event JSON + ControllerIdxSigs
   attachment), then any witness receipt streams (rct messages exactly
   as the witnesses returned them — what lets a bt>0 inception exit
   resolver escrow), then any stored OKEA endpoint replies
   (/end/role/add + /loc/scheme, already framed with their endorsement
   attachments). The replies are what let a resolver register the AID's
   service endpoint (OOBI §3.4) — keripy verifies them against the KEL
   that precedes them in this same stream."
  (let* ((icp        (assq-ref entry 'icp))
         (icp-sigs   (assq-ref entry 'sigs))
         (rotations  (or (assq-ref entry 'rotations) '()))
         (receipts   (or (assq-ref entry 'receipts) #()))
         (replies    (or (assq-ref entry 'replies) #()))
         (icp-pair   (cons (scm->json-canonical icp) icp-sigs))
         (rot-pairs  (map (lambda (r)
                            (cons (scm->json-canonical (car r)) (cdr r)))
                          rotations)))
    (apply string-append
           (cesr-stream-kel (cons icp-pair rot-pairs))
           (append (vector->list receipts)
                   (vector->list replies)))))

(define (schema-oobi-response doc)
  "Serve an ACDC schema document to a resolver. KERIA GETs
   /oobi/{schemaSAID} and re-derives the SAID over the body it
   receives, so DOC is the on-disk bytes verbatim (field order is what
   the derivation canonicalizes over — see (playnet keri schemas)).
   Content-addressed, hence immutable and cacheable forever, unlike the
   controller OOBIs below whose KELs must stay fresh."
  (values (build-response
           #:code 200
           #:headers
           (with-headers %security-headers
            ;; Bare media type, no charset param: KERIpy's OOBI processor
            ;; matches the Content-Type exactly to decide this is a schema
            ;; OOBI — "application/schema+json;charset=utf-8" would be
            ;; silently ignored and the schema never loaded. The body goes
            ;; out as a bytevector for the same reason: Guile's
            ;; sanitize-response appends charset=utf-8 to any string body.
            '((content-type . (application/schema+json))
              (cache-control . (public (max-age . 31536000) immutable))
              (access-control-allow-origin . "*"))))
          (string->utf8 doc)))

(define (handle-oobi-cesr oobi-dir aid)
  "Return the canonical CESR text-stream OOBI body for AID (KEL +
   endpoint replies). This is the KERI-OOBI-spec-compliant body that
   any KERIA resolver will accept."
  (let ((entry (read-oobi-entry oobi-dir aid)))
    (if entry
        (cesr-response (cesr-kel-of-entry entry))
        (oobi-not-found aid))))

(define (handle-oobi-json oobi-dir aid)
  "Return a JSON debug view of the OOBI entry. Convenient for browser
   inspection; not intended for KERIA consumption."
  (let ((entry (read-oobi-entry oobi-dir aid)))
    (if entry
        (json-response (scm->json-canonical entry))
        (oobi-not-found aid))))

(define (handle-did-keri oobi-dir aid)
  "Minimal DID Document for did:keri:<aid>. References the OOBI URL
   as a service endpoint per W3C DID core §5.4."
  (let ((entry (read-oobi-entry oobi-dir aid)))
    (cond
     ((not entry) (oobi-not-found aid))
     (else
      (let* ((did    (aid->did-keri aid))
             (key-id (string-append did "#k0")))
        (json-response
         (scm->json-canonical
          `(("@context" . #("https://www.w3.org/ns/did/v1"))
            ("id" . ,did)
            ("verificationMethod"
             . #((("id" . ,key-id)
                  ("type" . "Ed25519VerificationKey2020")
                  ("controller" . ,did)
                  ("publicKeyMultibase" . ,(string-append "z" aid)))))
            ("authentication" . #(,key-id))
            ("service"
             . #((("id" . ,(string-append did "#oobi"))
                  ("type" . "KERIOOBI")
                  ("serviceEndpoint" . ,(string-append "/oobi/" aid)))))))))))))

;;; ── Static file serving (self-contained, no hoot dep) ────────────────────
;;;
;;; The hoot web-server packages on the user's system (0.7 in
;;; ~/.guix-profile, 0.8 in guix shell) disagree on exports and
;;; signatures and the 0.8 default handler is currently broken even
;;; with no router at all. Easier to own the handler — Guile's
;;; (web server) is small and stable.

(define %mime-types
  '(("js"   . application/javascript)
    ("mjs"  . application/javascript)  ;; ES module — not in hoot's default
    ("wasm" . application/wasm)
    ("json" . application/json)
    ("html" . text/html)
    ("css"  . text/css)
    ("svg"  . image/svg+xml)
    ("png"  . image/png)
    ("jpg"  . image/jpeg)
    ("jpeg" . image/jpeg)
    ("ico"  . image/x-icon)
    ("txt"  . text/plain)
    ("webp" . image/webp)
    ("woff2" . font/woff2)
    ("pbf"  . application/x-protobuf)  ;; the basemap's glyph ranges (assets/map/fonts)
    ("ogg"  . audio/ogg)
    ("wav"  . audio/wav)
    ("webmanifest" . application/manifest+json)
    ;; the scroll's "the latest spec" download links (docs/playnet.{pdf,epub},
    ;; built by deploy/scripts/build-docs-epub.sh)
    ("pdf"  . application/pdf)
    ("epub" . application/epub+zip)))

(define (mime-type-for filename)
  (let ((dot (string-rindex filename #\.)))
    (or (and dot
             (assoc-ref %mime-types
                        (substring filename (+ 1 dot))))
        'application/octet-stream)))

;; A response that carries no body still has to say so. HTTP/1.1 keeps the
;; connection alive, so a reply with neither content-length nor a chunked
;; encoding leaves the client reading for a body terminator that never
;; arrives — it holds the socket open until its own timeout fires. That
;; turns every 404 into a ~60s stall, and through the CDN a missing asset
;; surfaces as a 504 rather than a 404. An explicit zero-length says the
;; body is complete, and the reply lands immediately.
(define (empty-response code)
  (values (build-response #:code code
                          #:headers (with-headers %security-headers
                                     '((content-length . 0))))
          #f))

(define (bad-request)
  (empty-response 400))

;;; ── Offline routing (/route) — Tier 1: self-hosted Valhalla ─────────────────
;;; Same-origin endpoint so the browser never touches an external router (no IP
;;; leak; works on Tor / the mesh). A *thin proxy* to a local Valhalla HTTP
;;; service (default http://127.0.0.1:8002, built from an OSM extract — see
;;; docs/valhalla/ and tools/dev/valhalla-local.sh). Valhalla is multimodal:
;;; pedestrian / bicycle / auto / bus / multimodal-transit.
;;;
;;; The server stays dumb on purpose: it builds the Valhalla request, POSTs it,
;;; and relays Valhalla's JSON verbatim. The browser (repl.js `routing.fetch`)
;;; owns JSON.parse, polyline decode, and the straight-line fallback when
;;; Valhalla is down — so the map UI works offline today and lights up real
;;; roads the moment the service is up, with zero server-side JSON parsing
;;; (which also dodges the (json) module-shadowing under the Hoot dev env).
;;; Configure via env:
;;;   PLAYNET_VALHALLA_URL          base URL (default http://127.0.0.1:8002)

(define %valhalla-url
  (or (getenv "PLAYNET_VALHALLA_URL") "http://127.0.0.1:8002"))

;; The wire speaks Valhalla costing names natively — the browser translates its
;; UI words (foot/bike/…) at the source (repl.js), and the ENGINE is the sole
;; authority on which costings exist (an unknown one gets Valhalla's 400, which
;; relays as "{}" and the client straight-lines: the honest degradation, and
;; new engine costings work here without touching this file). All the proxy
;; owns is SYNTAX safety: the profile is spliced into hand-built JSON, so it
;; must never carry anything beyond a costing-shaped token.
(define (valhalla-costing profile)
  (let ((p (string-filter (lambda (c) (or (char-alphabetic? c) (char=? c #\_)))
                          (or profile ""))))
    (if (string-null? p) "pedestrian" p)))

(define (parse-latlng s)
  (let ((i (and s (string-index s #\,))))
    (and i (let ((lat (string->number (substring s 0 i)))
                 (lng (string->number (substring s (+ i 1)))))
             (and lat lng (cons lat lng))))))

;; Optional intermediate waypoints: "lat,lng;lat,lng".
(define (parse-vias s)
  (if (or (not s) (string-null? s)) '()
      (filter-map parse-latlng (string-split s #\;))))

(define (query->alist q)
  (if (or (not q) (string-null? q)) '()
      (filter-map
       (lambda (kv)
         (let ((i (string-index kv #\=)))
           (and i (cons (substring kv 0 i) (uri-decode (substring kv (+ i 1)))))))
       (string-split q #\&))))

;; Build the Valhalla /route request body by hand (numbers + strings only —
;; no JSON library needed, so nothing to shadow). locs = list of (lat . lng).
(define (valhalla-request-json locs costing)
  (string-append
   "{\"locations\":["
   (string-join
    (map (lambda (ll)
           (string-append "{\"lat\":" (number->string (car ll))
                          ",\"lon\":" (number->string (cdr ll)) "}"))
         locs)
    ",")
   "],\"costing\":\"" costing "\""
   ",\"directions_options\":{\"units\":\"kilometers\"}}"))

;; POST a JSON body to a local Valhalla endpoint; return the raw JSON response
;; body string, or #f if unreachable / non-200.
(define (valhalla-relay path body-str)
  (false-if-exception
   (call-with-values
     (lambda ()
       (http-post (string-append %valhalla-url path)
                  #:body body-str
                  #:headers '((content-type . (application/json (charset . "utf-8"))))
                  #:keep-alive? #f))
     (lambda (resp rbody)
       (and (= 200 (response-code resp))
            (if (bytevector? rbody) (utf8->string rbody) rbody))))))

(define (valhalla-post locs costing)
  (valhalla-relay "/route" (valhalla-request-json locs costing)))

;; Map-matching: the browser's collected GPS trace, relayed verbatim to
;; trace_route — how the journey ACTUALLY went, snapped to the network. The
;; body is browser-built Valhalla JSON; the engine is its own validator
;; (same trust story as /route — relayed "{}" on refusal).
(define (handle-trace body)
  ;; cap the relayed trace at 1 MB (~10k GPS points) — locally this is just
  ;; hygiene; in production nginx caps bodies before they reach us anyway
  (define (sized? s) (and s (<= (string-length s) 1048576) s))
  (route-relay
   (or (valhalla-relay "/trace_route"
                       (or (sized? (cond ((bytevector? body) (utf8->string body))
                                         ((string? body) body)
                                         (else "")))
                           "{}"))
       "{}")))

;; Relay a JSON body string to the client (no-store, CORS-open like our other
;; JSON endpoints). On Valhalla failure we relay "{}" so the client can detect
;; the empty trip and draw its own straight-line fallback.
(define (route-relay body-str)
  (values (build-response
           #:code 200
           #:headers (with-headers %security-headers
                      (append '((content-type . (application/json (charset . "utf-8"))))
                              %keri-no-cache-headers)))
          body-str))

(define (handle-route query)
  (let* ((p       (query->alist query))
         (from    (parse-latlng (assoc-ref-str p "from")))
         (to      (parse-latlng (assoc-ref-str p "to")))
         (via     (parse-vias (assoc-ref-str p "via")))
         (profile (or (assoc-ref-str p "profile") "foot")))
    (if (and from to)
        (let ((locs (append (list from) via (list to))))
          (route-relay (or (valhalla-post locs (valhalla-costing profile)) "{}")))
        (bad-request))))

(define (assoc-ref-str alist key)
  (let ((p (assoc key alist))) (and p (cdr p))))

(define (not-found)
  (empty-response 404))

;;; ── Basemap tiles (/tiles/osm/{z}/{x}/{y}) — OpenStreetMap, served from here ──
;;; The map draws vector tiles cut from OpenStreetMap data (a Protomaps build,
;;; `make map-tiles`) and held as PMTiles archives under PLAYNET_MAP_DIR, one
;;; file per region. Nothing upstream is called at request time: a tile is
;;; a byte range of a local file, found by its Hilbert id, and a tile no
;;; archive holds is a 404. The browser never contacts a tile provider — no
;;; per-tile location leak, nothing to proxy, and the map works over the
;;; onion and with no network at all. Attribution ("© OpenStreetMap
;;; contributors") is the ODbL's one ask and rides in the style.
;;;
;;;   PLAYNET_MAP_DIR   where the *.pmtiles archives live (default data/map)
(define %map-dir (or (getenv "PLAYNET_MAP_DIR") "data/map"))

;; z/x/y must be bare non-negative integers — nothing else reaches the reader.
(define (tile-int s)
  (let ((n (and s (string->number s))))
    (and (integer? n) (exact? n) (>= n 0) n)))

(define (handle-osm-tile z x y)
  "Tile Z/X/Y from the first archive (by name) that holds it, as stored —
gzipped archives answer under Content-Encoding: gzip."
  (let* ((zn (tile-int z)) (xn (tile-int x)) (yn (tile-int y))
         ;; (archive . bytes) — found as ONE value, so the search cannot drop
         ;; the body the way a multi-value return inside `any` would
         (hit (and zn xn yn
                   (any (lambda (a)
                          (let ((bv (pmtiles-tile a zn xn yn)))
                            (and bv (cons a bv))))
                        (pmtiles-archives %map-dir)))))
    (if hit
        (values (build-response
                 #:code 200
                 #:headers
                 (with-headers %security-headers
                  `((content-type . (application/vnd.mapbox-vector-tile))
                    ,@(if (eq? (pmtiles-tile-compression (car hit)) 'gzip)
                          '((content-encoding . (gzip)))
                          '())
                    ;; a build is immutable; a new build is new archives
                    (cache-control . (public (max-age . 604800) immutable)))))
                (cdr hit))
        (not-found))))

(define %pack-chunk (* 8 1024 1024))

(define (handle-osm-pack name request)
  "The archive NAME (as regions.json lists it, with its .pmtiles suffix), for
the device's own copy: a Range answers 206 with at most 8 MiB, so a download
over Tor is a series of resumable slices; no Range answers the whole file.
A name no archive carries is a 404 — the request never becomes a path."
  (let ((a (any (lambda (a) (and (string=? (basename (pmtiles-path a)) name) a))
                (pmtiles-archives %map-dir))))
    (if (not a)
        (not-found)
        (let* ((size  (assq-ref (pmtiles-info a) 'bytes))
               (range (request-range request))
               (span  (and (pair? range) (eq? (car range) 'bytes)
                           (pair? (cdr range)) (pair? (cadr range))
                           (cadr range)))
               (start (and span (car span)))
               (end   (and span (min (- size 1)
                                     (or (cdr span) (- size 1))
                                     (+ start %pack-chunk -1)))))
          (cond
           ((and span (or (not (integer? start)) (>= start size) (< end start)))
            (values (build-response #:code 416
                                    #:headers (with-headers %security-headers
                                               `((content-range . (bytes * ,size)))))
                    ""))
           (span
            (let ((bv (archive-bytes a start (+ 1 (- end start)))))
              (if bv
                  (values (build-response
                           #:code 206
                           #:headers (with-headers %security-headers
                                      `((content-type . (application/octet-stream))
                                        (content-range . (bytes (,start . ,end) ,size))
                                        (accept-ranges . (bytes))
                                        (cache-control . (public (max-age . 604800) immutable)))))
                          bv)
                  ;; the file shrank under us (an archive being replaced): say so, never a half body
                  (values (build-response #:code 416
                                          #:headers (with-headers %security-headers
                                                     `((content-range . (bytes * ,size)))))
                          ""))))
           (else
            (values (build-response
                     #:code 200
                     #:headers (with-headers %security-headers
                                `((content-type . (application/octet-stream))
                                  (accept-ranges . (bytes))
                                  (cache-control . (public (max-age . 604800) immutable)))))
                    (archive-bytes a 0 size))))))))

(define (handle-osm-regions)
  "The archives on offer — name, bounds, zooms, size — for the map's region
list and the offline-pack chooser."
  (values (build-response
           #:code 200
           #:headers (with-headers %security-headers
                      '((content-type . (application/json (charset . "utf-8")))
                        (cache-control . (no-cache)))))
          (scm->json-canonical
           (list->vector
            (map (lambda (a)
                   (let ((info (pmtiles-info a)))
                     `(("name" . ,(assq-ref info 'name))
                       ("bounds" . ,(list->vector (assq-ref info 'bounds)))
                       ("minZoom" . ,(assq-ref info 'min-zoom))
                       ("maxZoom" . ,(assq-ref info 'max-zoom))
                       ("bytes" . ,(assq-ref info 'bytes))
                       ;; the OSM data's date — null when the archive says none
                       ("build" . ,(or (assq-ref info 'build) 'null)))))
                 (pmtiles-archives %map-dir))))))

(define (forbidden-component? c)
  ;; Block path traversal AND hidden files / dirs (the old nginx
  ;; `location ~ /\. { deny all; }` rule). Without this, /.git/...
  ;; or /.env would be served from disk. One exception: `.well-known`
  ;; (RFC 8615) is the reserved, deliberately-public namespace tools look
  ;; under (security.txt, RFC 9116) — the single literal component let
  ;; through; every other hidden file or dir, including ONE under it
  ;; (.well-known/.git would still be blocked, by its OWN component),
  ;; stays blocked.
  (or (string=? c "..")
      (string=? c ".")
      (and (> (string-length c) 0)
           (char=? #\. (string-ref c 0))
           (not (string=? c ".well-known")))))

(define (filename-extension filename)
  ;; Only a dot in the BASENAME (after the last slash) is an extension.
  ;; A dot in an intermediate path segment — e.g. the seed host in a board
  ;; route like /boards/playnet.earth:443/<rid> — must NOT count, or the SPA
  ;; fallback misfires and the deep route 404s instead of serving index.html.
  (let ((dot (string-rindex filename #\.))
        (slash (string-rindex filename #\/)))
    (and dot
         (or (not slash) (> dot slash))
         (substring filename (+ 1 dot)))))

(define (resolve-static-path work-dir components)
  "Return the resolved file path or #f. Does NOT fall back to
   index.html for missing paths — that's the SPA fallback, handled
   separately in serve-static-file so we know when to apply it."
  (let* ((joined (string-join components "/" 'prefix))
         (file   (string-append work-dir joined))
         (index  (string-append file "/index.html")))
    (cond
     ((any forbidden-component? components) #f)
     ((file-exists? index) index)
     ((and (file-exists? file)
           (not (eq? (stat:type (stat file)) 'directory)))
      file)
     (else #f))))

(define (read-file file-name)
  (call-with-input-file file-name get-bytevector-all))

;; The Explorer and the Boards live in subroots of the document root and are
;; served as they were built. FILE-NAME is under one of them.
(define %spa-subroots '("radicle" "boards"))

(define (in-spa-subroot? file-name)
  (any (lambda (sub) (string-contains file-name (string-append "/" sub "/")))
       %spa-subroots))

;; The dial's own two entry documents (app.html / the repl's index.html) —
;; NOT the Radicle Explorer/Boards subroots' own index.html files, whose
;; embedded third-party pages may load cross-origin resources of their own
;; that COEP require-corp would otherwise start blocking.
(define (dial-entry-document? file-name)
  (and (or (string-suffix? "/app.html" file-name)
           (string-suffix? "/index.html" file-name))
       (not (in-spa-subroot? file-name))))

;; The dial's own code: wasm and scripts, outside the Explorer and Boards
;; subroots (their bundles are theirs to serve as they were built).
(define (dial-script-or-wasm? file-name ext)
  (and ext
       (member ext '("wasm" "js" "mjs"))
       (not (in-spa-subroot? file-name))))

(define (file-response file-name)
  (let* ((ext  (filename-extension file-name))
         (mime (mime-type-for file-name))
         (size (stat:size (stat file-name)))
         (body (read-file file-name))
         ;; Every script of the dial's own answers with the isolation
         ;; headers, beside the wasm and the two entry documents. A dedicated
         ;; worker under COEP require-corp must itself answer with a COEP no
         ;; weaker, or the browser refuses to start it (a bare error Event,
         ;; no message) — and any script may be a worker's entry (the spine,
         ;; the household solve, the speech worker). Covering the type covers
         ;; the next worker with it. On a script that is only imported the
         ;; headers are inert.
         (extra (if (or (dial-entry-document? file-name)
                        (dial-script-or-wasm? file-name ext))
                    %wasm-extra-headers
                    '()))
         ;; Files that must NEVER be cached at any layer:
         ;;   sw.js — service worker, controls all other caching.
         ;;     If stale, client stays pinned to old fetch logic.
         ;;   entry-points.json — encodes the gateway's current OCapN
         ;;     sref. When the gateway reissues its identity (e.g. on
         ;;     restart), a cached entry-points.json points clients at
         ;;     a dead designator and they hit "WebSocket designator
         ;;     verification failed" forever. Originally the CDN's
         ;;     default max-age=2592000 made the browser cache it
         ;;     locally for 30 days, defeating CDN purges entirely.
         (no-cache-file?
          (or (string-suffix? "/sw.js" file-name)
              (string-suffix? "/entry-points.json" file-name)))
         (cache (if no-cache-file?
                    %keri-no-cache-headers
                    (asset-cache-headers ext))))
    (values
     (build-response
      #:code 200
      #:headers
      (with-headers %security-headers
       (with-headers extra
        (append `((content-type . (,mime))
                  (content-length . ,size))
                cache))))
     body)))

;; The dial is the front door: playnet.earth/ serves app.html. The
;; repl keeps the whole machine reachable on its own subdomain —
;; repl.<domain>/ serves index.html — and stays addressable everywhere
;; (the onion included) as /index.html. One directory, two faces.
(define (host-default-page request)
  "The page \"/\" means on this Host: index.html on a repl.* subdomain,
   app.html (the dial) everywhere else."
  (let* ((h    (request-host request))
         (name (cond ((pair? h) (car h))
                     ((string? h) h)
                     (else ""))))
    (if (and (string? name) (string-prefix? "repl." name))
        "index.html"
        "app.html")))

(define* (spa-fallback work-dir #:optional (page "index.html"))
  "Serve the host's default page for client-side-routed paths. Same
   content as nginx's `try_files $uri $uri/ /<page>` SPA fallback."
  (let ((index (string-append work-dir "/" page))
        (classic (string-append work-dir "/index.html")))
    (cond
     ((file-exists? index) (file-response index))
     ((file-exists? classic) (file-response classic))
     (else (not-found)))))

;; Self-contained SPA sub-roots mounted under work-dir: a path
;; /<root>/… serves files from work-dir/<root>/ and, for client-side
;; routes (no extension), falls back to work-dir/<root>/index.html
;; rather than the host default (app.html). Used for the third-party
;; Radicle front-ends — the Radicle Explorer at /radicle/ and Radicle
;; Planning Boards at /boards/ — each of which is its own SPA with its
;; own router and index.html. Keeping the list here (not nginx) means
;; serve-static stays the single owner of routing + SPA fallback.

(define (spa-subroot-of components)
  "If COMPONENTS addresses a mounted SPA sub-root, return its name."
  (and (pair? components)
       (member (car components) %spa-subroots)
       (car components)))

(define* (serve-static-file work-dir components #:optional (page "index.html"))
  ;; the root: the host decides which face the directory shows
  (if (null? components)
      (spa-fallback work-dir page)
      (match (resolve-static-path work-dir components)
        (#f
         ;; SPA fallback: if the path *could* be a route in the SPA
         ;; (no extension, no hidden segment), return the SPA's index so
         ;; the browser-side router handles it. Anything with an
         ;; extension is a missing asset → real 404. Anything containing
         ;; a forbidden segment → 404 (don't reveal whether it would
         ;; exist). A mounted sub-root falls back to its OWN index.html.
         (let* ((joined (string-join components "/" 'prefix))
                (has-ext? (filename-extension joined))
                (denied? (any forbidden-component? components))
                (subroot (spa-subroot-of components)))
           (cond
            ((or has-ext? denied?) (not-found))
            (subroot
             (spa-fallback (string-append work-dir "/" subroot) "index.html"))
            (else (spa-fallback work-dir page)))))
        (file-name (file-response file-name)))))

;;; ── /playnet-identity.json ────────────────────────────────────────────────
;;;
;;; Canonical "playnet" identity for browser-side contacts seeding.
;;; Lazily reads /var/lib/playnet/playnet-scope-aid.txt (one-line file
;;; containing the durable-scope AID for the playnet org); if absent,
;;; returns 404 — the browser falls back to a no-op seed and the
;;; contacts tab just starts empty. Once the gateway has been used to
;;; create a "playnet" durable scope (via REPL: `(durable-scope-aid
;;; "playnet")` or similar — see docs/governance/persistence-
;;; operations.md), the operator writes the AID to that file and this
;;; endpoint starts serving.
;;;
;;; The published AID is auto-mirrored into ^oobi-host by the gateway
;;; (PLAYNET_OOBI_AUTO_MIRROR=1), so /oobi/{aid} on the same origin
;;; returns its KEL — the browser can use this endpoint's URL as a
;;; one-stop seed contact.

;; Same PLAYNET_DATA_DIR convention as the gateway writes it under.
;; A PROCEDURE, not a constant — state-file reads the env at call time,
;; so a test's sandbox dir (set after module load) is honoured.
(define (playnet-identity-file) (state-file "playnet-scope-aid.txt"))

;;; ── /entry-points.json ────────────────────────────────────────────────────
;;;
;;; The gateway writes its current OCapN sturdyref to
;;; /var/lib/playnet/gateway-sref.txt on every boot. The previous
;;; design served browser/entry-points.json as a static file with a
;;; hand-edited sref — which silently went stale every time the
;;; gateway minted a new swiss number on restart, locking clients
;;; into "WebSocket designator verification failed" until the file
;;; was manually re-synced. This handler reads the live file at
;;; request time so the published sref is always current.
;;;
;;; The on-disk sref has an internal `?url=ws://127.0.0.1:9090`
;;; suffix used by the gateway's own ocapn registrations; we strip
;;; that for the browser, which splices in the correct public URL
;;; (window.location-derived "self" entry or one of the configured
;;; tor/clearnet entries) at connection time.

;; Same PLAYNET_DATA_DIR convention as server/gateway.scm, so a local
;; full-stack (gateway + serve-static) runs without /var/lib or root.
(define %gateway-sref-file (state-file "gateway-sref.txt"))

(define (strip-url-suffix sref)
  "Drop any ?url=... query string. The query is gateway-local
   plumbing; the browser provides its own ws URL."
  (let ((q (string-index sref #\?)))
    (if q (substring sref 0 q) sref)))

(define (sref-ws-url sref)
  "The ws URL the gateway registered itself under, out of the sref's
   own `?url=` suffix (percent-decoded), or #f. This is the gateway
   talking about itself, so it is always current — no config to keep
   in step with it."
  (let ((q (string-index sref #\?)))
    (and q
         (let ((query (substring sref (+ q 1))))
           (and (string-prefix? "url=" query)
                (let ((raw (uri-decode (substring query 4))))
                  (and (string? raw) (positive? (string-length raw)) raw)))))))

(define (loopback-request? request)
  "Was this page served on a loopback Host? Then the browser is on this
   machine, and the gateway's own loopback ws is reachable from it."
  (let* ((h    (request-host request))
         (name (cond ((pair? h) (car h))
                     ((string? h) h)
                     (else ""))))
    (and (string? name)
         (or (string=? name "127.0.0.1")
             (string=? name "localhost")
             (string=? name "::1")))))

;; Gateway faces are runtime config, NOT hardcoded — so this source is portable
;; and carries no specific deployment's address (a new operator just drops in
;; their own values). The clearnet ws defaults to the current public domain but
;; can be overridden; the Tor onion face is added IFF the operator has provided
;; one in gateway-onion.txt (absent → onion face simply omitted).
(define %gateway-onion-file (state-file "gateway-onion.txt"))

(define %clearnet-ws (getenv "PLAYNET_CLEARNET_WS"))

(define (gateway-entries)
  "Build the gateway entry vector: a Tor onion face (when configured) followed
   by the clearnet face (when PLAYNET_CLEARNET_WS names one — deploy/os.scm
   derives it from the provider config's clearnet-domain; there is NO default,
   so a deployment that never set it advertises no one else's gateway). The
   browser's discoverGateway() prepends a window.location-derived 'self' entry,
   so a page loaded over the .onion or the box's own domain works with neither;
   these entries advertise the other faces to a visitor who is on one of them."
  (let ((clearnet (and %clearnet-ws (not (string-null? %clearnet-ws))
                       `(("name"    . "clearnet")
                         ("kind"    . "cdn")
                         ("ws"      . ,%clearnet-ws)
                         ("comment" . "Clearnet face: CDN in front of the origin."))))
        (onion (read-trimmed-line %gateway-onion-file)))
    (list->vector
     (append
      (if (and onion (> (string-length onion) 0))
          (list `(("name"    . "tor")
                  ("kind"    . "onion")
                  ("ws"      . ,(string-append "ws://" onion "/ws"))
                  ("comment" . "Tor hidden-service face (operator-configured).")))
          '())
      (if clearnet (list clearnet) '())))))

(define (handle-entry-points request)
  (let ((raw-sref (read-trimmed-line %gateway-sref-file)))
    (if raw-sref
        (let* ((sref (strip-url-suffix raw-sref))
               ;; LOCAL DEV, with nothing to configure. In production nginx
               ;; proxies /ws on the page's own origin, so the browser's
               ;; window.location-derived "self" entry is right and this is
               ;; absent. Served on loopback there is no proxy — so hand the
               ;; browser the gateway's OWN ws address, read out of the sref
               ;; the gateway just wrote. `make dev` therefore needs no
               ;; ?gateway= splice: http://127.0.0.1:8080/app.html is enough,
               ;; and it re-syncs by itself every time the gateway restarts.
               (direct (and (loopback-request? request)
                            (sref-ws-url raw-sref))))
          (values
           (build-response
            #:code 200
            #:headers
            (with-headers %security-headers
             (append `((content-type . (application/json (charset . "utf-8"))))
                     %keri-no-cache-headers)))
           (scm->json-canonical
            (append
             `(("comment" . "Entry points for the playnet OCapN gateway. Generated at request time: the sref reflects the running gateway's current identity (from gateway-sref.txt) and the gateway faces are operator config — the clearnet ws and the optional Tor onion (gateway-onion.txt) are read here, never hardcoded. discoverGateway() also prepends a 'self' entry derived from window.location so a working ws is always available.")
              ("sref"    . ,sref)
              ("gateway" . ,(gateway-entries)))
              (if direct `(("directWs" . ,direct)) '())))))
        (values
         (build-response
          #:code 503
          #:headers
          (with-headers %security-headers
           (append '((content-type . (application/json)))
                   %keri-no-cache-headers)))
         (scm->json-canonical
          `(("error" . "gateway sref not yet written")
            ("hint"  . "wait for the playnet-gateway service to finish booting")))))))

(define (read-trimmed-line path)
  (and (file-exists? path)
       (let ((s (call-with-input-file path get-string-all)))
         (and (string? s)
              (let ((t (string-trim-both s)))
                (and (not (string-null? t)) t))))))

(define (handle-playnet-identity)
  (let ((aid (read-trimmed-line (playnet-identity-file))))
    (if aid
        (values
         (build-response
          #:code 200
          #:headers
          (with-headers %security-headers
           (append `((content-type . (application/json (charset . "utf-8"))))
                   %keri-no-cache-headers)))
         (scm->json-canonical
          `(("name"  . "playnet")
            ("aid"   . ,aid)
            ("oobi"  . ,(string-append "/oobi/" aid))
            ("did"   . ,(aid->did-keri aid)))))
        (values
         (build-response
          #:code 404
          #:headers
          (with-headers %security-headers
           (append '((content-type . (application/json)))
                   %keri-no-cache-headers)))
         (scm->json-canonical
          `(("error" . "playnet identity not yet provisioned")
            ("hint"  . "operator: create a durable 'playnet' scope and write its AID to /var/lib/playnet/playnet-scope-aid.txt")))))))

;;; ── /universal-commune.json ──────────────────────────────────────────────
;;;
;;; Sibling of /playnet-identity.json, but for the Universal Commune —
;;; the scope at the planning-time root of the federation tree, whose
;;; member-list is reactively derived from orphan scopes (those with no
;;; parent). The gateway writes its AID to
;;; /var/lib/playnet/universal-commune-aid.txt once at boot after
;;; spawning or restoring the UC. Browsers fetching this endpoint can
;;; use the returned `oobi` URL on the same origin to verify the UC's
;;; KEL (auto-mirrored by ^oobi-host-mirror).
;;;
;;; The two endpoints are split rather than conflated because the
;;; "playnet org identity" (operator-curated brand AID) and the
;;; "Universal Commune AID" (algorithmic root) are different things;
;;; conflating them would create migration pain when an operator
;;; deployment wants its org-identity to differ from the UC (and it
;;; usually should — the org is a member, not the root).

;; Same PLAYNET_DATA_DIR convention as the gateway writes it under — a
;; `make dev` stack answers /universal-commune.json for ITS gateway.
;; A procedure for the same reason as playnet-identity-file above.
(define (universal-commune-file) (state-file "universal-commune-aid.txt"))

(define (handle-universal-commune)
  (let ((aid (read-trimmed-line (universal-commune-file))))
    (if aid
        (values
         (build-response
          #:code 200
          #:headers
          (with-headers %security-headers
           (append `((content-type . (application/json (charset . "utf-8"))))
                   %keri-no-cache-headers)))
         (scm->json-canonical
          `(("name"  . "universal-commune")
            ("aid"   . ,aid)
            ("oobi"  . ,(string-append "/oobi/" aid))
            ("did"   . ,(aid->did-keri aid)))))
        (values
         (build-response
          #:code 404
          #:headers
          (with-headers %security-headers
           (append '((content-type . (application/json)))
                   %keri-no-cache-headers)))
         (scm->json-canonical
          `(("error" . "universal commune not yet provisioned")
            ("hint"  . "the gateway writes this file at boot when PLAYNET_SCOPES_DURABLE=1; check the gateway log for spawn errors")))))))

;;; ── /scopes ──────────────────────────────────────────────────────────────
;;;
;;; Public enumeration of every durable scope on this gateway, with its
;;; kind tag. Consumed by other gateways' ^remote-scope-poller to
;;; discover scopes for cross-gateway membership derivation. Each entry
;;; is `{aid, kind}` — neither sensitive nor signed; the trust handoff
;;; happens at the OOBI level (peers verify the KEL at /oobi/{aid}
;;; before trusting any claim about the scope).
;;;
;;; Reads `<state>/scopes/` filesystem on demand. Lightweight (one
;;; directory listing + one stat per entry for the kind file). No
;;; ACDC unpacking, no actor calls — safe to expose without rate
;;; limits beyond the nginx-level zones already on /.
;;;
;;; cache-control: no-store because scope-set changes whenever any
;;; scope is admitted/removed.

(define (list-known-scopes-inline)
  "Mirror of (playnet scope recovery)'s list-known-scopes
   — inlined here to keep serve-static's import surface minimal (no
   libsodium dependency chain)."
  (let ((dir (string-append (playnet-state-dir) "/scopes")))
    (cond
     ((not (file-exists? dir)) '())
     (else
      (or (scandir dir
                   (lambda (entry)
                     (and (not (member entry '("." "..")))
                          (file-exists?
                           (string-append dir "/" entry "/acdc")))))
          '())))))

;;; ── /witness/{requests,attests} ─────────────────────────────────────────
;;; The work-witness relay's served half (personhood/witness-relay.scm
;;; writes the files; peers' poll ticks read them here). Inlined file reads
;;; rather than importing witness-relay, for the same reason as
;;; list-known-scopes-inline: that module's import chain reaches libsodium,
;;; which this minimal service deliberately runs without.
(define (handle-witness-files kind)
  (if (not (member kind '("requests" "attests")))
      (bad-request)
      (let* ((dir (string-append (playnet-state-dir) "/witness/" kind))
             (names (if (file-exists? dir)
                        (or (scandir dir (lambda (e) (string-suffix? ".json" e))) '())
                        '()))
             (body (string-append
                    "[" (string-join
                         (filter-map
                          (lambda (n)
                            (catch #t
                              (lambda ()
                                (call-with-input-file (string-append dir "/" n)
                                  get-string-all))
                              (lambda _ #f)))
                          names)
                         ",")
                    "]")))
        (values (build-response
                 #:code 200
                 #:headers `((content-type . (application/json))
                             (cache-control . (no-store))))
                body))))

(define (handle-scopes-list)
  (let* ((aids (list-known-scopes-inline))
         (entries (map (lambda (aid)
                         `(("aid"  . ,aid)
                           ("kind" . ,(symbol->string
                                       (or (read-scope-kind aid) 'commune)))))
                       aids)))
    (values
     (build-response
      #:code 200
      #:headers
      (with-headers %security-headers
       (append `((content-type . (application/json (charset . "utf-8"))))
               %keri-no-cache-headers)))
     (scm->json-canonical
      `(("count"  . ,(length entries))
        ("scopes" . ,(list->vector entries)))))))

;;; ── /scope/<aid>/parents.json ────────────────────────────────────────────
;;;
;;; For each parent of AID, returns the parent's AID plus the
;;; membership ACDC SAID. v1 ships AID+SAID only; v2 will bundle the
;;; full ACDC inline (per the Q1 recommendation in the plan) so the
;;; remote poller can verify without a second round-trip. For now the
;;; poller can fetch the ACDC via /oobi/{aid} traversal or via direct
;;; ACDC lookup on the issuing scope (those endpoints land in the same
;;; commit as ^remote-scope-poller).
;;;
;;; cache-control: no-store (membership churn).

;; Direct disk read of federation-membership ACDCs without dragging the
;; governance umbrella (and libsodium) into playnet-static.
;;
;; Layout (owned by ^acdc-store):
;;   <state>/scopes/<aid>/acdc/<2-char prefix>/<said>.scm  ← (write cred)
;;   <state>/scopes/<aid>/acdc/_revoked.log               ← (write (said . t))
;;
;; cred is a plain alist; we read it back with `read` and pick fields
;; with assq. No need to share constructor code.
(define %fed-membership-schema "playnet-federation-membership/v1")

(define (assq-ref* alist key)
  (let ((p (assq key alist))) (and p (cdr p))))

(define (read-revoked-saids acdc-dir)
  (let ((log (string-append acdc-dir "/_revoked.log")))
    (if (not (file-exists? log)) '()
        (call-with-input-file log
          (lambda (port)
            (let loop ((acc '()))
              (let ((datum (read port)))
                (cond
                 ((eof-object? datum) acc)
                 ((pair? datum)       (loop (cons (car datum) acc)))
                 (else                (loop acc))))))))))

(define (read-creds-in acdc-dir)
  (if (not (file-exists? acdc-dir)) '()
      (let ((subs (or (scandir acdc-dir
                               (lambda (e)
                                 (and (not (member e '("." ".." "_revoked.log")))
                                      (eq? 'directory
                                           (stat:type
                                            (stat (string-append acdc-dir "/" e)))))))
                      '())))
        (append-map
         (lambda (sub)
           (let* ((subpath (string-append acdc-dir "/" sub))
                  (files (or (scandir subpath
                                      (lambda (f) (string-suffix? ".scm" f)))
                             '())))
             (map (lambda (f)
                    (call-with-input-file (string-append subpath "/" f) read))
                  files)))
         subs))))

(define (handle-scope-parents aid)
  (let* ((acdc-dir (scope-acdc-dir aid))
         (parents
          (catch #t
            (lambda ()
              (let* ((revoked (read-revoked-saids acdc-dir))
                     (creds   (read-creds-in acdc-dir)))
                (filter-map
                 (lambda (c)
                   (and (equal? (assq-ref* c 'schema)
                                %fed-membership-schema)
                        (equal? (assq-ref* c 'holder) aid)
                        (not (assq-ref* c 'revoked?))
                        (not (member (assq-ref* c 'said) revoked))
                        ;; The cred alist serialises to a Scheme
                        ;; s-expression; the remote poller reads it
                        ;; back with `read` and re-derives the SAID
                        ;; under signify-portable to verify integrity
                        ;; before noting the parent link.
                        `(("parent_aid"      . ,(assq-ref* c 'issuer))
                          ("membership_said" . ,(assq-ref* c 'said))
                          ("parent_oobi"     . ,(string-append "/oobi/"
                                                               (assq-ref* c 'issuer)))
                          ("acdc_scm"
                           . ,(call-with-output-string
                                (lambda (p) (write c p)))))))
                 creds)))
            (lambda _ '()))))
    (values
     (build-response
      #:code 200
      #:headers
      (with-headers %security-headers
       (append `((content-type . (application/json (charset . "utf-8"))))
               %keri-no-cache-headers)))
     (scm->json-canonical
      `(("aid"     . ,aid)
        ("parents" . ,(list->vector parents)))))))

;;; ── Observability endpoints (A2) ──────────────────────────────────
;;;
;;; Three read-only JSON probes for operators and dashboards:
;;;
;;;   /federation-status.json — "are we federated?" healthcheck
;;;     reads <data>/federation-status.scm written by gateway boot.
;;;
;;;   /pending-grants.json — "is IPEX delivery flowing?"
;;;     reads <data>/pending-grants.scm; renders each entry's kind,
;;;     holder, and age. Empty queue = healthy.
;;;
;;;   /audit/{aid}.json — "is this federation coherent?"
;;;     scans <state>/scopes/{aid}/acdc/ for the most recent
;;;     audit-pass or incoherence-alert credential.
;;;
;;; All three are file-driven so serve-static stays out of the
;;; libsodium-dependency-chain that the gateway vat needs.

;; Computed lazily — the resolvers read env vars at call time, so a test
;; harness pointing at a tmp dir isn't frozen out by module-load order.
;; All three follow PLAYNET_DATA_DIR, because that is where the gateway
;; WRITES them: federation-status and peer-status always did (this reader
;; alone was on the XDG state dir, so both probes read a file nothing
;; wrote), and pending-grants moved there with the gateway's writer.
(define (federation-status-file)
  (state-file "federation-status.scm"))

(define (peer-status-file)
  (state-file "peer-status.scm"))

(define (pending-grants-file)
  (state-file "pending-grants.scm"))

(define (%json-response code body)
  (values
   (build-response
    #:code code
    #:headers
    (with-headers %security-headers
     (append `((content-type . (application/json (charset . "utf-8"))))
             %keri-no-cache-headers)))
   (scm->json-canonical body)))

;; read-sexp-file and read-all-sexps-file live in (playnet utils common)
;; and are imported at the top — same defensive shape, shared with
;; pending-grants.scm.

(define (handle-federation-status)
  (let ((data (read-sexp-file (federation-status-file))))
    (cond
     ((not data)
      (%json-response
       503
       `(("error" . "gateway not yet booted")
         ("hint"  . "wait for the gateway to finish startup; this file appears after auditor wiring completes"))))
     (else
      (let ((alist (if (list? data) data '())))
        (%json-response
         200
         `(("boot-time"        . ,(or (assoc-ref alist 'boot-time) 0))
           ("peers"            . ,(or (assoc-ref alist 'peers) 0))
           ;; two UC facts, named apart — `uc-aid` used to carry only the
           ;; upward parent, so the UC's OWN gateway read as "no UC":
           ;;   federation-parent-uc — who we push membership up to
           ;;     (PLAYNET_UC_AID; empty on the UC's own gateway, correctly)
           ;;   local-uc — the UC minted/hosted HERE, joined from the same
           ;;     aid file /universal-commune.json serves
           ;; the old `uc-aid` key is still read as a fallback so a status
           ;; file from a pre-rename gateway boot renders during rollout
           ("federation-parent-uc" . ,(or (assoc-ref alist 'federation-parent-uc)
                                          (assoc-ref alist 'uc-aid) ""))
           ("local-uc"         . ,(or (read-trimmed-line (universal-commune-file)) ""))
           ("keri-connected"   . ,(if (assoc-ref alist 'keri-connected?) #t #f))
           ("auditors"         . ,(or (assoc-ref alist 'auditors) 0))
           ("custody-watchers" . ,(or (assoc-ref alist 'custody-watchers) 0)))))))))

;;; /peer-status.json — KERIA's view of each known contact AID
;;;
;;; Reads <data>/peer-status.scm written by the gateway's peer-status
;;; ticker (every PLAYNET_PEER_STATUS_TICK_SEC, default 60s). Each
;;; entry is the gateway's last-known answer to "is this peer
;;; reachable?": resolved? + pending-ops count + oobi-known?. A peer
;;; with resolved?=#f or persistent pending-ops>0 is the silent-grant-
;;; drop signature from capability #8.
;;;
;;; Returns 200 with {"updated": <epoch>, "peers": [...]} when fresh,
;;; or a friendly 200-with-hint when the gateway hasn't written yet.

(define (handle-peer-status)
  (let ((data (read-sexp-file (peer-status-file))))
    (cond
     ((not data)
      (%json-response
       200
       '(("error" . "peer status not yet written")
         ("hint"  . "wait for the gateway's first ticker cycle (~60s after boot)"))))
     (else
      (let* ((alist data)
             (updated (or (assoc-ref alist 'updated) 0))
             (peers   (or (assoc-ref alist 'peers) '())))
        (%json-response
         200
         `(("updated" . ,updated)
           ("peers"   . ,(list->vector
                          (map (lambda (p)
                                 `(("aid"          . ,(or (assoc-ref p 'aid) ""))
                                   ("alias"        . ,(or (assoc-ref p 'alias) ""))
                                   ("resolved"     . ,(and (assoc-ref p 'resolved?) #t))
                                   ("pending_ops"  . ,(or (assoc-ref p 'pending-ops) 0))
                                   ("oobi_known"   . ,(and (assoc-ref p 'oobi-known?) #t))))
                               peers))))))))))

;;; /mesh-endpoints.json — the AID → mesh-destination map, DERIVED from
;;; oobi-host entries (RETICULUM-IDENTITIES.md step 4's relay-announce
;;; map, event-sourced instead of ws-session-tracked): every registered
;;; AID whose verified replies advertise a reticulum /loc/scheme appears
;;; here, with the binding verdict against its icp-anchored pubkey.
;;; Consumers: the future persona announcer, dashboards, mesh routers.
;;;
;;; (playnet keri reticulum-binding) is loaded lazily and the sha256
;;; backend installed from gcrypt on first use — this server runs in a
;;; minimal env (no libsodium, deliberately no (playnet keri signify)),
;;; so when gcrypt/json are absent the endpoint degrades to a hint
;;; instead of crashing the service.

(define %mesh-binding-api
  (delay
    (catch #t
      (lambda ()
        (let ((binding (resolve-interface '(playnet keri reticulum-binding)))
              (prims   (resolve-interface '(playnet keri crypto-primitives)))
              (gch     (resolve-interface '(gcrypt hash))))
          ((module-ref prims 'set-keri-crypto-backend!)
           #:sha256 (module-ref gch 'sha256))
          (list (module-ref binding 'replies-mesh-locs)
                (module-ref binding 'verify-reticulum-binding))))
      (lambda args
        (format (current-error-port)
                "[serve-static] mesh-endpoints unavailable: ~a~%" args)
        #f))))

(define (handle-mesh-endpoints oobi-dir)
  (let ((api (force %mesh-binding-api)))
    (if (not api)
        (%json-response
         200 '(("error" . "mesh binding verifier unavailable in this environment")))
        (let ((replies-mesh-locs (car api))
              (verify-binding    (cadr api)))
          (%json-response
           200
           `(("endpoints"
              . ,(list->vector
                  (filter-map
                   (lambda (entry)
                     (let* ((aid     (assq-ref entry 'aid))
                            ;; Full KEL: latest anchor wins, so personas
                            ;; that retrofitted the binding via a rot
                            ;; verify against the rot's anchor.
                            (kel     (cons (assq-ref entry 'icp)
                                           (map car (or (assq-ref entry
                                                                  'rotations)
                                                        '()))))
                            (replies (assq-ref entry 'replies))
                            (locs    (if (vector? replies)
                                         (replies-mesh-locs replies)
                                         '()))
                            (mesh    (assoc-ref locs "reticulum"))
                            (mail    (assoc-ref locs "lxmf")))
                       (and (or mesh mail)
                            `(("aid"         . ,aid)
                              ;; OCapN destination (legacy field name).
                              ,@(if mesh `(("destination" . ,mesh)) '())
                              ;; lxmf.delivery — where mesh mail for
                              ;; this persona is addressed.
                              ,@(if mail `(("lxmf" . ,mail)) '())
                              ;; #t → ALL advertised destinations derive
                              ;; from the anchored pubkey; symbols/
                              ;; strings name why they don't.
                              ("binding"
                               . ,(let ((v (verify-binding kel replies)))
                                    (cond ((eq? v #t) "verified")
                                          ((symbol? v) (symbol->string v))
                                          (else v))))))))
                   (read-oobi-entries oobi-dir))))))))))

(define (handle-pending-grants)
  (let* ((entries (read-all-sexps-file (pending-grants-file)))
         ;; Each entry is (kind . payload-alist) per pending-grants.scm format
         (rendered
          (map (lambda (entry)
                 (let ((kind (and (pair? entry) (car entry)))
                       (payload (and (pair? entry) (cdr entry))))
                   `(("kind" . ,(if (symbol? kind) (symbol->string kind) ""))
                     ("payload" . ,(map (lambda (p)
                                          (cons (symbol->string (car p))
                                                (let ((v (cdr p)))
                                                  (if (or (string? v)
                                                          (number? v)
                                                          (boolean? v))
                                                      v
                                                      (format #f "~a" v)))))
                                        (or payload '()))))))
               entries)))
    (%json-response
     200
     `(("count"   . ,(length entries))
       ("entries" . ,(list->vector rendered))))))

;;; /audit/{aid}.json — most recent audit-pass / incoherence-alert
;;;
;;; Walks <state>/scopes/{aid}/acdc/ for credential files (.scm),
;;; filters those whose schema matches audit-pass or incoherence-alert,
;;; returns the most recent (by mtime — credentials are content-
;;; addressed so filename is the SAID; mtime reflects issue time on
;;; disk). Operator-visible signal: "did this federation pass its
;;; last cycle?"

(define %audit-pass-schema       "playnet-audit-pass/v1")
(define %incoherence-schema      "playnet-incoherence-alert/v1")

(define (handle-audit aid)
  (let* ((acdc-dir (string-append (playnet-state-dir) "/scopes/" aid "/acdc"))
         (cred-files
          (cond
           ((not (file-exists? acdc-dir)) '())
           (else
            (let ((entries (or (scandir acdc-dir) '())))
              (filter-map
               (lambda (sub)
                 (and (not (member sub '("." "..")))
                      (let ((subdir (string-append acdc-dir "/" sub)))
                        (and (file-exists? subdir)
                             (eq? 'directory (stat:type (stat subdir)))
                             (map (lambda (f)
                                    (string-append subdir "/" f))
                                  (filter (lambda (f)
                                            (string-suffix? ".scm" f))
                                          (or (scandir subdir) '())))))))
               entries)))))
         (flat (apply append cred-files))
         ;; Read each, keep audit-pass + incoherence-alert
         (audit-creds
          (filter-map
           (lambda (path)
             (let ((cred (read-sexp-file path)))
               (and cred
                    (let ((schema (assq-ref cred 'schema)))
                      (and (or (equal? schema %audit-pass-schema)
                               (equal? schema %incoherence-schema))
                           (cons (stat:mtime (stat path)) cred))))))
           flat))
         (newest (and (pair? audit-creds)
                      (cdr (car (sort audit-creds
                                      (lambda (a b) (> (car a) (car b)))))))))
    (cond
     ((not newest)
      (%json-response
       404
       `(("error" . "no audit credentials yet for this scope")
         ("aid"   . ,aid)
         ("hint"  . "the auditor fiber emits one audit-pass per cycle; check PLAYNET_AUDIT_INTERVAL_SEC and gateway logs"))))
     (else
      (%json-response
       200
       `(("aid"        . ,aid)
         ("schema"     . ,(or (assq-ref newest 'schema) ""))
         ("said"       . ,(or (assq-ref newest 'said) ""))
         ("issuer"     . ,(or (assq-ref newest 'issuer) ""))
         ("claims"     . ,(format #f "~a" (or (assq-ref newest 'claims) '())))
         ("revoked"    . ,(if (assq-ref newest 'revoked?) #t #f))))))))

;;; ── The operator (/operator.json, /.well-known/security.txt) ────────────────
;;; Who runs THIS gateway, from PLAYNET_OPERATOR_* in the environment — the
;;; fields, and why they are configuration and not repository content, are in
;;; (playnet utils operator). Every field is optional; one left out is left out
;;; of the answer and the notices render it as a visibly unfilled placeholder.

(define (handle-operator)
  (%json-response 200 (operator-config)))

(define (handle-security-txt fallback)
  "security.txt from the operator's configuration, with Expires always a year out
   — an old, unmaintained one is worse than none. With no security contact
   configured, the unfinished template under browser/.well-known answers
   instead (FALLBACK), which looks unfinished on purpose."
  (let* ((op (operator-config))
         (who (or (assoc-ref op "security") (assoc-ref op "contact"))))
    (if (not who)
        (fallback)
        (values
         (build-response
          #:code 200
          #:headers
          (with-headers %security-headers
           (append '((content-type . (text/plain (charset . "utf-8"))))
                   %keri-no-cache-headers)))
         (string-append
          "# security.txt (RFC 9116) — generated from this gateway's operator\n"
          "# configuration; Expires is a year from this request.\n"
          "Contact: " (contact-uri who) "\n"
          "Expires: " (strftime "%Y-%m-%dT%H:%M:%SZ"
                                (gmtime (+ (current-time) (* 364 86400)))) "\n"
          "Preferred-Languages: en\n")))))

;;; ── Feedback pool (/feedback) — tier 1 of the two-tier issue flow ───────────
;;;
;;; Anonymous free-form feedback from the browser widget. Entries land in an
;;; append-only sexp file under the data dir (the house style for durable
;;; queues — see doors/service/chat.scm) and stay OUT of the Radicle COBs: the pool
;;; is prunable testimony, the issue board is curated permanence. Synthesis
;;; (clustered feedback → one `rad issue` citing entry ids) happens
;;; operator-side.
;;;
;;; The client body is stored verbatim as a string — zero server-side JSON
;;; parsing, the same trust story as /trace (and the same module-shadowing
;;; dodge). The server contributes only the id, the arrival time, and the
;;; transport-observed User-Agent; everything else the client claims about
;;; itself (viewport, face, path) lives inside its own JSON.
;;;
;;; The admin surface (list / delete) is token-gated: the token is the first
;;; line of <data>/feedback-admin-token, presented in the X-Playnet-Admin
;;; HEADER. A header rather than a query parameter for two reasons — a query
;;; string lands in nginx's access log, and it can enter a CDN cache key, so
;;; a URL that returns the whole pool would be edge-cacheable. While the token
;;; file is absent, admin routes answer 404: a fresh deploy exposes nothing,
;;; and a wrong token is indistinguishable from no route.

;; ── a pool, and the two the server keeps ──
;; Feedback and reports are the same machinery with different stakes: an
;; append-only sexp file, a token-gated admin list and delete, a byte-bounded
;; write path. They are kept as SEPARATE pools — their own file, their own
;; admin token, their own body cap — so a report is never read, pruned or
;; swept up with product feedback, and whoever triages one need not hold the
;; other's token. A pool is a record of those four facts; every handler below
;; takes one.
(define-record-type <pool>
  (make-pool label file token-file max-body keep-ua?)
  pool?
  (label pool-label)            ; "feedback" | "report" — the word the errors use
  (file pool-file-name)         ; under the state dir
  (token-file pool-token-file)  ; first line = the X-Playnet-Admin token
  (max-body pool-max-body)      ; bytes (vf/facts/limits.scm)
  (keep-ua? pool-keep-ua?))     ; store the transport-observed User-Agent?

(define %feedback-pool
  (make-pool "feedback" "feedback-pool.scm" "feedback-admin-token" %feedback-max-bytes #t))
;; A report names no device: it keeps no User-Agent, only what the reporter wrote.
(define %report-pool
  (make-pool "report" "report-pool.scm" "report-admin-token" %report-max-bytes #f))

(define (pool-file pool) (state-file (pool-file-name pool)))
(define (pool-admin-token pool) (read-trimmed-line (state-file (pool-token-file pool))))

;; The pool's ceiling is BYTES, not entries. Every read of it parses the whole
;; file into a Guile list, and the box runs with no swap — so the bound that
;; matters is the one on how much memory a read can cost, and an entry count
;; does not bound that (5000 entries at the per-entry cap is over a gigabyte).
;; A soft ceiling: the last accepted entry may cross it by its own size.
(define %pool-max-bytes (* 8 1024 1024))

;; A string body reaches here only from a test harness or a client path that
;; already decoded; measure it as the bytes it would serialise to.
(define (string-utf8-length s)
  (bytevector-length (string->utf8 s)))

(define (pool-bytes pool)
  ;; O(1), and the point: the write path must NOT read the pool to decide
  ;; whether it can be written to. Anonymous callers reach this.
  (let ((path (pool-file pool)))
    (if (file-exists? path) (stat:size (stat path)) 0)))

(define (read-pool pool) (read-all-sexps-file (pool-file pool)))

(define (append-pool! pool entry)
  (call-with-port (open-file (pool-file pool) "a")
    (lambda (p) (write entry p) (newline p))))

(define (pool-admin-authorized? pool request)
  (let ((tok (pool-admin-token pool))
        (given (assq-ref (request-headers request) 'x-playnet-admin)))
    (and tok (string? given) (string=? tok given))))

(define (handle-pool-post pool request body)
  ;; Measure BYTES, the same quantity nginx's client_max_body_size counts —
  ;; string-length counts characters, so a body of multibyte prose would pass
  ;; here at a size the edge already refused, and the two caps would name
  ;; different things. Measure before decoding, so an oversized body is
  ;; refused without being turned into a string at all.
  (let* ((cap  (pool-max-body pool))
         (size (cond ((bytevector? body) (bytevector-length body))
                     ((string? body) (string-utf8-length body))
                     (else 0)))
         (text (if (or (= size 0) (> size cap))
                   ""
                   (or (false-if-exception
                        (cond ((bytevector? body) (utf8->string body))
                              ((string? body) body)
                              (else #f)))
                       "")))
         ;; the one server-side observation: what the transport saw, capped —
         ;; corroborates (or contradicts) the ua the client claims in its JSON
         (ua (if (pool-keep-ua? pool)
                 (let ((h (assq-ref (request-headers request) 'user-agent)))
                   (if (string? h) (substring h 0 (min 256 (string-length h))) ""))
                 "")))
    (cond
     ((or (= size 0) (> size cap) (string-null? text))
      (%json-response 400 `(("error" . ,(format #f "~a body must be 1..~a bytes"
                                                (pool-label pool) cap)))))
     ((>= (pool-bytes pool) %pool-max-bytes)
      (%json-response 503 `(("error" . ,(format #f "~a pool is full" (pool-label pool)))
                            ("hint"  . "a maintainer prunes it; try again later"))))
     (else
      ;; epoch + random tail = the chat.scm id discipline (two entries in one
      ;; second stay distinct)
      (let ((id (string-append (if (pool-keep-ua? pool) "fb-" "rp-")
                               (number->string (current-time))
                               "-" (number->string (random 1000000)))))
        (append-pool! pool `((id . ,id) (t . ,(current-time))
                             (ua . ,ua) (json . ,text)))
        (%json-response 200 `(("ok" . #t) ("id" . ,id))))))))

(define (handle-pool-list pool request)
  (if (not (pool-admin-authorized? pool request))
      (not-found)
      (%json-response
       200
       `(("entries"
          . ,(list->vector
              (map (lambda (e)
                     `(("id"   . ,(or (assq-ref e 'id) ""))
                       ("t"    . ,(or (assq-ref e 't) 0))
                       ("ua"   . ,(or (assq-ref e 'ua) ""))
                       ("json" . ,(or (assq-ref e 'json) ""))))
                   (read-pool pool))))))))

(define (handle-pool-delete pool id request)
  (if (not (pool-admin-authorized? pool request))
      (not-found)
      (let* ((all  (read-pool pool))
             (kept (filter (lambda (e) (not (equal? id (assq-ref e 'id)))) all)))
        (cond
         ((= (length kept) (length all))
          (%json-response 404 `(("error" . "no such entry"))))
         (else
          ;; deletion is the point of tier 1: rewrite the file without the
          ;; entry — no tombstone, no residue
          (call-with-port (open-file (pool-file pool) "w")
            (lambda (p)
              (for-each (lambda (e) (write e p) (newline p)) kept)))
          (%json-response 200 `(("ok" . #t)
                                ("removed" . ,(- (length all) (length kept))))))))))

(define (handle-feedback-post request body) (handle-pool-post %feedback-pool request body))
(define (handle-feedback-list request)      (handle-pool-list %feedback-pool request))
(define (handle-feedback-delete id request) (handle-pool-delete %feedback-pool id request))

;;; ── Reports (/report) — kept apart from feedback ────────────────────────────
;;; The in-app "report a concern" page (ui/app/report.ts; terms §7.2, privacy
;;; §11): unlawful or harmful content, a child at risk. Same door and shape as
;;; the feedback pool, a pool of its own — <data>/report-pool.scm, its own
;;; <data>/report-admin-token — so a report is read by whoever the operator
;;; trusts with reports, and is never in the file feedback synthesis prunes.
(define (handle-report-post request body) (handle-pool-post %report-pool request body))
(define (handle-report-list request)      (handle-pool-list %report-pool request))
(define (handle-report-delete id request) (handle-pool-delete %report-pool id request))

(define (handle-request work-dir oobi-dir request body)
  (define method (request-method request))
  (define components
    (split-and-decode-uri-path (uri-path (request-uri request))))
  ;; Treat HEAD like GET — Guile's web stack drops the body
  ;; automatically per HTTP spec, so the same handler shape works.
  (define m (if (eq? method 'HEAD) 'GET method))
  (match (cons m components)
    ((or ('GET ".well-known" "keri" "oobi" aid)
         ('GET "oobi" aid))
     ;; One /oobi/{said} namespace, two OOBI kinds: a SAID naming a
     ;; catalogued ACDC schema serves that schema document; anything
     ;; else is a controller OOBI (KEL + endpoint replies). The two
     ;; can never collide — schema SAIDs and AID prefixes are both
     ;; content-addressed digests.
     (cond
      ((schema-document-for-said aid) => schema-oobi-response)
      ((string-suffix? ".json" aid)
       (handle-oobi-json oobi-dir (string-drop-right aid 5)))
      (else (handle-oobi-cesr oobi-dir aid))))
    (('GET ".well-known" "did" "keri" aid)
     (handle-did-keri oobi-dir aid))
    (('GET "entry-points.json")
     (handle-entry-points request))
    (('GET "operator.json")
     (handle-operator))
    (('GET ".well-known" "security.txt")
     (handle-security-txt
      (lambda () (serve-static-file work-dir components (host-default-page request)))))
    (('GET "playnet-identity.json")
     (handle-playnet-identity))
    (('GET "universal-commune.json")
     (handle-universal-commune))
    (('GET "scopes")
     (handle-scopes-list))
    (('GET "witness" kind)
     (handle-witness-files kind))
    (('GET "scope" aid "parents.json")
     (handle-scope-parents aid))
    (('GET "federation-status.json")
     (handle-federation-status))
    (('GET "peer-status.json")
     (handle-peer-status))
    (('GET "mesh-endpoints.json")
     (handle-mesh-endpoints oobi-dir))
    (('GET "pending-grants.json")
     (handle-pending-grants))
    (('GET "audit" aid)
     (let ((aid-clean (if (string-suffix? ".json" aid)
                          (string-drop-right aid 5)
                          aid)))
       (handle-audit aid-clean)))
    (('GET "route")
     (handle-route (uri-query (request-uri request))))
    (('GET "tiles" "osm" "regions.json")
     (handle-osm-regions))
    (('GET "tiles" "osm" pack)
     (if (string-suffix? ".pmtiles" pack)
         (handle-osm-pack pack request)
         (not-found)))
    (('GET "tiles" "osm" z x y)
     (handle-osm-tile z x y))
    (('POST "trace")
     (handle-trace body))
    (('POST "feedback")
     (handle-feedback-post request body))
    (('GET "feedback.json")
     (handle-feedback-list request))
    (('POST "feedback" id "delete")
     (handle-feedback-delete id request))
    (('POST "report")
     (handle-report-post request body))
    (('GET "report.json")
     (handle-report-list request))
    (('POST "report" id "delete")
     (handle-report-delete id request))
    (('GET . _)
     (serve-static-file work-dir components (host-default-page request)))
    (_ (bad-request))))

(define* (run-static-server #:key
                            (work-dir "browser")
                            (oobi-dir "data/oobi-host")
                            (port 8080))
  (format #t "Serving ~a on http://127.0.0.1:~a~%" work-dir port)
  (format #t "  /oobi/{aid}                   → CESR KEL stream (KERI spec)~%")
  (format #t "  /oobi/{aid}.json              → JSON debug view~%")
  (format #t "  /.well-known/keri/oobi/{aid}  → CESR KEL stream (well-known)~%")
  (format #t "  /.well-known/did/keri/{aid}   → did:keri DID Document~%")
  (format #t "  /federation-status.json       → gateway healthcheck~%")
  (format #t "  /peer-status.json             → per-contact KERIA reachability~%")
  (format #t "  /pending-grants.json          → IPEX retry-queue contents~%")
  (format #t "  /audit/{aid}.json             → most recent audit cycle for federation~%")
  (format #t "  /route?from=&to=&profile=     → Valhalla route proxy (GeoJSON-ish)~%")
  (format #t "  /tiles/osm/{z}/{x}/{y}        → OpenStreetMap vector tiles from ~a/*.pmtiles~%" %map-dir)
  (format #t "  /tiles/osm/regions.json       → the archives on offer~%")
  (format #t "  /tiles/osm/{name}.pmtiles     → one archive, by Range, for a device's offline copy~%")
  (format #t "  /feedback (POST)              → anonymous feedback pool (tier 1 of the issue flow)~%")
  (format #t "  /report (POST)                → reports of unlawful or harmful content, kept apart from feedback~%")
  (format #t "  (else)                        → static files from ~a~%~%"
          work-dir)
  ;; A LOCAL gateway (PLAYNET_DATA_DIR convention) has no nginx /ws proxy in
  ;; front of it, so browser self-ws discovery can't reach it — the ?gateway=
  ;; param is the local mechanism. Hand the operator the ready-made URLs.
  (let ((sref (read-trimmed-line %gateway-sref-file)))
    (when sref
      (let ((enc (uri-encode sref)))
        (format #t "local gateway found (~a):~%" %gateway-sref-file)
        (format #t "  app:  http://127.0.0.1:~a/?gateway=~a~%" port enc)
        (format #t "  dial: http://127.0.0.1:~a/app.html?gateway=~a~%~%" port enc))))
  (force-output)
  (run-server (lambda (request body)
                (handle-request work-dir oobi-dir request body))
              (server-impl)
              `(#:port ,port #:addr ,INADDR_LOOPBACK)))

;; Prefer the fibers backend so a slow handler — a Valhalla POST, a tile read
;; off a cold disk — runs on its own fiber instead of freezing the single
;; accept loop; every other request (app.html, the live-reload poll, other
;; tiles) keeps being served concurrently. Loading (web server fibers) both registers
;; the 'fibers impl and lets us detect availability; fall back to the stable
;; single-threaded 'http impl if guile-fibers isn't in this environment.
;; The fibers backend is OPT-IN via PLAYNET_FIBERS=1 (set by `make serve`), not
;; the default. `make serve` has exercised it for the whole dev loop, but it is
;; not yet verified on the box, so prod keeps the stock single-threaded `http`
;; backend it has always run — a slow upstream fetch briefly blocks, same as
;; before, and nginx buffers in front. Flip the default (or set PLAYNET_FIBERS in
;; the prod service) once fibers is smoke-tested on the box.
(define (server-impl)
  (if (and (getenv "PLAYNET_FIBERS")
           (false-if-exception (begin (resolve-interface '(web server fibers)) #t)))
      (begin (format #t "  (server: fibers backend — non-blocking, concurrent)~%")
             'fibers)
      (begin (format #t "  (server: http backend — single-threaded)~%")
             'http)))
