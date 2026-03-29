;;; module/playnet/gateway/lobby.scm — OCapN gateway entry point
;;;
;;; The lobby is the single actor whose sturdyref is published.
;;; Clients enliven it and call methods to access services.
;;; The lobby delegates to internal actors — callers never see
;;; the underlying ^signup-agent, ^key-pool, etc.

(define-module (playnet gateway lobby)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:export (^lobby))

(define (^lobby _bcom signup-agent transcription-svc express-svc
                presence terminal-svc mailbox-mgr)
  (methods

   ;; ── Account registration ─────────────────────────────────────────────
   ;; Returns 'ok or (list 'error "reason")
   ((signup username email ssh-pubkey)
    (<- signup-agent 'register! username email ssh-pubkey))

   ;; ── Audio transcription ──────────────────────────────────────────────
   ;; Returns transcript string or raises error
   ((transcribe audio-b64)
    (<- transcription-svc 'transcribe audio-b64))

   ;; ── Natural language -> Scheme ───────────────────────────────────────
   ;; Returns S-expression string or raises error
   ((express nl-text)
    (<- express-svc 'express nl-text))

   ;; ── Presence ─────────────────────────────────────────────────────────
   ;; Register as online with a display name and inbox ref.
   ;; Returns current online user list.
   ((announce name user-inbox)
    (<- presence 'announce name user-inbox))

   ;; Leave (disconnect)
   ((leave name)
    (<- presence 'leave name))

   ;; List online users
   ((who)
    (<- presence 'online-users))

   ;; Get another user's inbox ref for direct P2P messaging.
   ;; Returns inbox ref or #f.
   ((introduce target-name)
    (<- presence 'introduce target-name))

   ;; Relay a WebRTC signaling message to a target peer.
   ;; The caller must pass their own name (OCapN has no caller identity).
   ((signal target-name from-name signal-type signal-data)
    (<- presence 'signal target-name from-name signal-type signal-data))

   ;; Return ICE server configuration for WebRTC peers.
   ((ice-servers)
    '(("urls" . "stun:stun.l.google.com:19302")))

   ;; ── Terminal ─────────────────────────────────────────────────────────
   ;; Open a PTY session as the user associated with identity-key.
   ;; client-inbox receives (term-data ...) and (term-closed).
   ;; Returns a ^terminal-session ref or (list 'error "reason").
   ((open-terminal identity-key client-inbox)
    (<- terminal-svc 'open identity-key client-inbox))

   ;; ── Mailbox ──────────────────────────────────────────────────────────
   ;; Get (or create) an offline message queue for identity-key.
   ;; Returns a ^mailbox ref.
   ((get-mailbox identity-key)
    (<- mailbox-mgr 'get-or-create identity-key))))
