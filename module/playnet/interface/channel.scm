;;; module/playnet/interface/channel.scm — Generic interface channel
;;;
;;; A ^channel binds a backend + transport adapter + output sink
;;; into a single coordinated actor. The channel knows nothing about
;;; what the backend IS — it could be a VF planning scope, a chat room,
;;; a kanban board, or anything that implements the backend protocol.
;;;
;;; Because the backend is just an actor ref, it works transparently
;;; over OCapN — the scope could be on this machine or any other.
;;; The channel uses <- (async) to talk to the backend so that remote
;;; backends work identically to local ones.
;;;
;;; Backend protocol (3 methods):
;;;   (handle user-id command-name args-string) → ('response text) | ('error reason)
;;;   (available-commands) → list of command name strings
;;;   (wire-output sink-ref) → void

(define-module (playnet interface channel)
  #:use-module (goblins)
  #:use-module (goblins actor-lib methods)
  #:use-module (goblins utils hashmap)
  #:use-module (ice-9 receive)
  #:use-module (ice-9 match)
  #:export (^channel))


;; =========================================================================
;; ^channel — backend-agnostic interface channel
;; =========================================================================

(define (^channel bcom
                  channel-id        ;; string: unique identifier ("tg-12345", "mx-!abc:server")
                  backend           ;; actor ref implementing backend protocol (local or remote)
                  sink-ref          ;; ^output-sink actor ref
                  transport         ;; ^transport-adapter actor ref, or #f
                  channel-context   ;; opaque transport destination, or #f
                  members)          ;; hashmap: user-id string -> member info alist

  (methods

    ;; --- Identity ---
    ((id) channel-id)
    ((backend) backend)

    ;; --- Member management ---
    ((add-member user-id display-name capabilities)
     ;; capabilities: list of symbols, e.g. '(observe query command admin)
     (bcom (^channel bcom channel-id backend sink-ref
                      transport channel-context
                      (hashmap-set members user-id
                                   `((display-name . ,display-name)
                                     (capabilities . ,capabilities))))))

    ((remove-member user-id)
     (bcom (^channel bcom channel-id backend sink-ref
                      transport channel-context
                      (hashmap-remove members user-id))))

    ((members)
     (hashmap-fold (lambda (k v acc) (cons (cons k v) acc)) '() members))

    ((member? user-id)
     (hashmap-ref members user-id #f))

    ;; --- Command entry point (from transport) ---
    ((handle-input user-id raw-text)
     ;; Parse command via transport adapter, route through backend.
     ;; Uses <- so the backend can be on any machine.
     ;; Returns a vow that resolves to ('response text) or ('error reason).
     (if (not transport)
         (list 'error "No transport bound")
         (receive (cmd args)
           ($ transport 'parse-command raw-text)
           (if cmd
               (let ((result-vow (<- backend 'handle user-id cmd args)))
                 (on result-vow
                     (lambda (result)
                       (match result
                         (('response text)
                          (<-np transport 'send-message channel-context text))
                         (('error reason)
                          (<-np transport 'send-message channel-context
                                (format #f "Error: ~a" reason))))
                       result))
                 result-vow)
               (list 'error "No command found in input")))))

    ;; --- Transport binding ---
    ((bind-transport new-transport new-context)
     ;; Attach transport and wire output-sink.
     ($ sink-ref 'bind-transport new-transport new-context)
     (<-np backend 'wire-output sink-ref)
     (bcom (^channel bcom channel-id backend sink-ref
                      new-transport new-context members)))

    ((unbind-transport)
     ;; Detach transport; notifications queue to sink.
     ($ sink-ref 'unbind-transport)
     (bcom (^channel bcom channel-id backend sink-ref
                      #f #f members)))

    ;; --- Backend delegation ---
    ((available-commands)
     (<- backend 'available-commands))))
