#!/usr/bin/env -S guile -L module
!#
;;; tools/emit/protocol-emit.scm — emits read from (playnet doors protocol)
;;;
;;;   protocol-emit.scm openapi [out]    OpenAPI 3.1 document for the HTTP door
;;;   protocol-emit.scm mcp [out]        MCP tool manifest: one tool per HTTP door
;;;   protocol-emit.scm seam [out]       ui/app/seam-wire.ts: the SeamHandlers
;;;                                      and SeamPushes interfaces, from (playnet protocol seam)
;;;
;;; One operation per door that has an HTTP form: `POST /api/<object>/<name>`
;;; with a JSON body whose properties are the door's positional arguments
;;; in order (optional and rest arguments marked), and a JSON reply. Doors
;;; with auth `root` or `operator` have no path: they appear under
;;; `x-playnet-doors` with `x-playnet-transport: captp` (root) or
;;; `none` (operator) so the document lists the whole surface.
;;;
;;; Argument schemas come from (playnet protocol shapes): one shape per
;;; argument name, the same fragment in the OpenAPI document and the MCP
;;; manifest, so the two cannot disagree. A door with a capability or
;;; in-process argument has no HTTP form (door-http?).
;;;
;;; The committed copy is browser/api/openapi.json; `make check-protocol-fresh`
;;; regenerates and diffs it.

(use-modules (playnet doors protocol) (playnet protocol shapes) (playnet protocol seam)
             ((playnet wire rows) #:select (reply-table-ref wire-type-name wire-table-name))
             (playnet wire replies)
             (playnet protocol mcp)
             (json) (ice-9 match) (ice-9 format) (srfi srfi-1))

(define schema-for door-input-schema)

(define (operation door)
  `((operationId . ,(format #f "~a.~a" (door-object door) (door-name door)))
    (summary . ,(if (string-null? (door-doc door)) (symbol->string (door-name door)) (door-doc door)))
    (description . ,(format #f "~a\n\nObject: `~a`. Callable by ~a. Reply shape: `~a`."
                            (door-doc door) (door-object door) (door-audience door) (door-reply door)))
    (tags . ,(vector (symbol->string (door-topic door))))
    (x-playnet-auth . ,(symbol->string (door-auth door)))
    (x-playnet-kind . ,(symbol->string (door-kind door)))
    (x-playnet-to . ,(symbol->string (door-to door)))
    (x-playnet-object . ,(symbol->string (door-object door)))
    ,@(if (door-seam door) `((x-playnet-seam . ,(door-seam door))) '())
    (security . ,(if (eq? (door-auth door) 'anonymous) (vector) (vector '((deviceSignature . #())))))
    (requestBody . ((required . #t)
                    (content . ((application/json . ((schema . ,(schema-for door))))))))
    (responses . ((200 . ((description . ,(format #f "the door's reply (~a), as JSON" (door-reply door)))
                          (content . ((application/json . ((schema . ,(append (reply-schema (door-reply door))
                                                                                 `((x-playnet-reply . ,(symbol->string (door-reply door))))))))))))
                  (401 . ((description . "no valid device signature (B4)")))
                  (403 . ((description . "the door is outside this device's allowlist")))))))

(define (document)
  (let* ((http (filter door-http? %doors))
         (other (filter (lambda (d) (not (door-http? d))) %doors)))
    `((openapi . "3.1.0")
      (info . ((title . "playnet gateway doors")
               (version . ,(number->string %protocol-version))
               (description . "Every door the browser may call, declared once in module/playnet/doors/protocol.scm and emitted here, grouped by topic. The HTTP door (POST /api/{object}/{name}) carries the same doors CapTP does; a call is signed with an enrolled device key (RFC 9421) unless the door is anonymous. The same doors are MCP tools: POST /api/mcp speaks JSON-RPC (initialize, tools/list, tools/call), and browser/api/mcp-tools.json is the committed tool list. Doors a client cannot reach (root tier, operator) are listed under x-playnet-doors.")))
      (servers . ,(vector '((url . "/"))))
      (tags . ,(list->vector (map (lambda (t) `((name . ,(symbol->string (car t))) (description . ,(cdr t)))) %topics)))
      (components . ((securitySchemes . ((deviceSignature . ((type . "http") (scheme . "signature")
                                                             (description . "RFC 9421 Signature-Input/Signature over the request, key id = the device AID (B4)")))))))
      (paths . ,(map (lambda (d)
                       (cons (format #f "/api/~a/~a" (door-object d) (door-name d))
                             `((post . ,(operation d)))))
                     http))
      (x-playnet-doors . ,(list->vector
                           (map (lambda (d)
                                  `((object . ,(symbol->string (door-object d)))
                                    (name . ,(symbol->string (door-name d)))
                                    (auth . ,(symbol->string (door-auth d)))
                                    (topic . ,(symbol->string (door-topic d)))
                                    (x-playnet-transport . ,(if (memq (door-auth d) '(anonymous device root)) "captp" "none"))
                                    (summary . ,(door-doc d))))
                                other))))))

(define (mcp-manifest)
  ;; The committed tool list: what POST /api/mcp answers tools/list with,
  ;; built by (playnet protocol mcp) so the file and the live answer agree.
  `((protocolVersion . ,%mcp-protocol-version)
    (serverInfo . ,(mcp-server-info))
    (tools . ,(mcp-tools))))

(define (handler-returns* h)
  "The handler's return type: as declared, or the registry's for its reply door."
  (or (handler-returns h)
      (let ((t (reply-table-ref (handler-reply h))))
        (unless t (error "protocol-emit: no reply table for door" (handler-reply h)))
        (string-append "Promise<Json<W." (wire-type-name (wire-table-name t)) ">>"))))

(define (seam-ts)
  (define (ts-list names) (string-join (map (lambda (n) (string-append "\"" n "\"")) names) ", "))
  (string-append
   "// ui/app/seam-wire.ts — GENERATED by tools/emit/protocol-emit.scm seam from\n"
   "// module/playnet/protocol/seam.scm. Do not edit; `make protocol-emit`.\n"
   "//\n"
   "// Both halves of the seam. SeamHandlers is app → spine: every handler the\n"
   "// spine registers (hoot/day-boot.scm), with the doors it sends noted so a\n"
   "// reader can follow a call to the gateway; every member is optional, since\n"
   "// the spine fills the object after the app has booted, and standalone there\n"
   "// is no spine at all. SeamPushes is spine → app: every method the spine\n"
   "// calls, with the wasm sink that raises it; seam.ts installs each name in\n"
   "// SEAM_PUSHES as a forwarder onto the app's bus, so every member is always\n"
   "// present, and builds each sink in SEAM_WIRE — parse the wire arguments as\n"
   "// the table says, keep the value under seam.data, raise the push. SEAM_SINKS\n"
   "// is what the spine worker forwards to the page by name.\n"
   "\n"
   "import type { GatewayStatus, Grant } from \"./seam.js\";\n"
   "import type * as W from \"./wire-rows.js\";\n"
   "\n"
   "/** The JSON string of a door's reply table, or \"err:…\" — read with seam.ts readJson. */\n"
   "export type Json<T> = string & { readonly __shape?: T };\n"
   "\n"
   "export interface SeamPushes {\n"
   (string-concatenate
    (map (lambda (p)
           (string-append
            "  /** " (push-doc p) " */\n"
            "  // sink: " (or (push-sink p) "day-boot.js (page event)") "\n"
            "  " (push-name p) "(" (push-params p) "): void;\n"))
         %pushes))
   "}\n"
   "\n"
   "/** Every push, in table order. */\n"
   "export const SEAM_PUSHES = [" (ts-list (map push-name %pushes)) "] as const;\n"
   "\n"
   "/** How each wire argument crosses: parsed, or the string it is. */\n"
   "export type WireKind = \"json\" | \"raw\";\n"
   "\n"
   "/** Each wasm-raised sink: the push it raises, how it reads its arguments, and the seam.data key that keeps the first. */\n"
   "export const SEAM_WIRE = {\n"
   (string-concatenate
    (filter-map (lambda (p)
                  (and (push-sink p)
                       (string-append
                        "  " (push-sink p) ": { push: \"" (push-name p) "\", args: ["
                        (ts-list (map symbol->string (push-wire p))) "], keep: "
                        (if (push-keep p) (string-append "\"" (push-keep p) "\"") "null")
                        " },\n")))
                %pushes))
   "} as const satisfies Record<string, { push: keyof SeamPushes; args: readonly WireKind[]; keep: string | null }>;\n"
   "export type SeamSink = keyof typeof SEAM_WIRE;\n"
   "\n"
   "/** Every sink the spine worker forwards to the page by name: the wired ones and the page's plumbing. */\n"
   "export const SEAM_SINKS = [" (ts-list (%sinks-forwarded)) "] as const;\n"
   "\n"
   "export interface SeamHandlers {\n"
   (string-concatenate
    (map (lambda (h)
           (string-append
            (if (string-null? (handler-doc h)) "" (string-append "  /** " (handler-doc h) " */\n"))
            (if (null? (handler-doors h))
                "  // local: no door\n"
                (string-append "  // doors: "
                               (string-join (map (lambda (d) (format #f "~a/~a" (car d) (cdr d))) (handler-doors h)) ", ")
                               "\n"))
            "  " (handler-name h) "?(" (handler-params h) "): " (handler-returns* h) ";\n"))
         %handlers))
   "  [handler: string]: unknown;\n"
   "}\n"))

(match (cdr (command-line))
  (("seam" out) (call-with-output-file out (lambda (p) (display (seam-ts) p))))
  (("seam") (display (seam-ts)))
  (("mcp" out) (call-with-output-file out (lambda (p) (scm->json (mcp-manifest) p #:pretty #t) (newline p))))
  (("mcp") (scm->json (mcp-manifest) (current-output-port) #:pretty #t) (newline))
  (("openapi" out) (call-with-output-file out (lambda (p) (scm->json (document) p #:pretty #t) (newline p))))
  (("openapi") (scm->json (document) (current-output-port) #:pretty #t) (newline))
  (_ (display "usage: protocol-emit.scm openapi|mcp|seam [out]\n") (exit 2)))
