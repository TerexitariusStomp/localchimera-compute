;;; load-bridge.scm — Load MQTT bridge modules
;;;
;;; Separate from load-all.scm because the bridge depends on external
;;; packages (mosquitto, json) that aren't part of the core planner.
;;;
;;; Usage: from the planner directory, after load-all.scm:
;;;   (load "lib/bridge/load-bridge.scm")

(let ((dir "lib/bridge/"))
  (load (string-append dir "codec.scm"))
  (load (string-append dir "topic-observer.scm"))
  (load (string-append dir "signal-publisher.scm"))
  (load (string-append dir "mqtt-bridge.scm")))
