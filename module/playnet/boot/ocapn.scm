;;; module/playnet/boot/ocapn.scm — the OCapN vat: the designator key, the websocket netlayer, mycapn, and what a registration keeps.

(define-module (playnet boot ocapn)
  #:use-module ((playnet boot site) #:select (data-path keep-line! log!))
  #:use-module ((goblins ocapn captp) #:select (spawn-mycapn))
  #:use-module ((goblins ocapn ids) #:select (ocapn-id->string))
  #:use-module ((goblins ocapn netlayer websocket) #:select (^websocket-netlayer))
  #:use-module ((goblins utils crypto) #:select (data->private-key generate-key-pair private-key->data))
  #:use-module (goblins vat)
  #:use-module (goblins)
  #:export (spawn-ocapn! register!))

;;; ── Designator key persistence ─────────────────────────────────────────────
;;;
;;; The designator key determines the server's OCapN identity.
;;; It must survive restarts so sturdyrefs remain stable.

(define (load-or-generate-designator-key!)
  "Load the designator key from disk, or generate and save a new one."
  (let ((path (data-path "designator-key.scm")))
    (if (file-exists? path)
        (let ((data (call-with-input-file path read)))
          (log!
                  "  [gateway] loaded designator key from ~a~%" path)
          (data->private-key data))
        ;; Generate new key
        (let ((key (generate-key-pair)))
          (call-with-output-file path
            (lambda (port)
              (write (private-key->data key) port)
              (newline port)))
          (log!
                  "  [gateway] generated new designator key at ~a~%" path)
          key))))

(define (spawn-ocapn! host port)
  "The OCapN vat with the websocket netlayer listening on HOST:PORT and
mycapn over it. (values ocapn-vat ws-netlayer mycapn)."
  (let* ((designator-key (load-or-generate-designator-key!))
         (ocapn-vat (spawn-vat #:name "ocapn"))
         (ws-netlayer
          (with-vat ocapn-vat
            (spawn ^websocket-netlayer
                   #:host host
                   #:port port
                   #:encrypted? #f
                   #:designator-key designator-key
                   #:max-peers 64)))
         (mycapn (with-vat ocapn-vat (spawn-mycapn ws-netlayer))))
    (values ocapn-vat ws-netlayer mycapn)))

(define* (register! ocapn-vat mycapn object transport file #:key (say (lambda (uri) #f)))
  "OBJECT registered with MYCAPN on TRANSPORT (websocket or reticulum); its
sturdyref URI kept at FILE under the data directory, for the browser and
every other client, and told to SAY."
  (with-vat ocapn-vat
    (on (<- mycapn 'register object transport)
        (lambda (sref)
          (let ((uri (ocapn-id->string sref)))
            (say uri)
            (catch #t
              (lambda () (keep-line! (data-path file) uri))
              (lambda args
                (log! "  warning: could not write ~a: ~a~%" file args))))))))
