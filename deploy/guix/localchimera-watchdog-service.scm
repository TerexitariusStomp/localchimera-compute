;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/localchimera-watchdog-service.scm — health check + auto-restart
;;;
;;; Polls the gateway's /federation-status.json endpoint every
;;; LOCALCHIMERA_WATCHDOG_INTERVAL_SEC (default 60s). On 3 consecutive
;;; failures (timeout / non-200 / malformed JSON), restarts
;;; localchimera-gateway via `herd restart`.
;;;
;;; This is the deferred-task-#52 deliverable: shepherd doesn't have a
;;; native WatchdogSec equivalent (that's systemd's). We get the same
;;; semantics with a tiny shepherd service that exec's a polling script.
;;;
;;; Usage in machines.scm:
;;;   (service localchimera-watchdog-service-type
;;;            (localchimera-watchdog-configuration
;;;             (gateway-url "http://127.0.0.1:8080")
;;;             (interval-sec 60)
;;;             (failure-threshold 3)))

(define-module (localchimera-watchdog-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages base)        ; coreutils, grep
  #:use-module (gnu packages curl)        ; curl
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (localchimera-watchdog-configuration
            localchimera-watchdog-configuration?
            localchimera-watchdog-service-type))

(define-record-type* <localchimera-watchdog-configuration>
  localchimera-watchdog-configuration make-localchimera-watchdog-configuration
  localchimera-watchdog-configuration?
  ;; URL the watchdog probes (must serve /federation-status.json)
  (gateway-url   localchimera-watchdog-configuration-gateway-url
                 (default "http://127.0.0.1:8080"))
  ;; Seconds between probes
  (interval-sec  localchimera-watchdog-configuration-interval-sec
                 (default 60))
  ;; Consecutive failures before triggering a restart
  (failure-threshold localchimera-watchdog-configuration-failure-threshold
                     (default 3))
  ;; HTTP timeout per probe (seconds)
  (timeout-sec   localchimera-watchdog-configuration-timeout-sec
                 (default 10))
  ;; Shepherd service name to restart on failure
  (target        localchimera-watchdog-configuration-target
                 (default 'localchimera-gateway))
  ;; User to run as
  (user          localchimera-watchdog-configuration-user
                 (default "localchimera")))

(define (watchdog-script config)
  "Bash script body — polls in a loop, restarts on threshold."
  (let* ((url        (localchimera-watchdog-configuration-gateway-url config))
         (interval   (localchimera-watchdog-configuration-interval-sec config))
         (threshold  (localchimera-watchdog-configuration-failure-threshold config))
         (timeout    (localchimera-watchdog-configuration-timeout-sec config))
         (target     (symbol->string
                      (localchimera-watchdog-configuration-target config))))
    #~(string-append
       "#!" #$(file-append (canonical-package bash) "/bin/sh") "\n"
       "set -u\n"
       "URL='" #$url "/federation-status.json'\n"
       "INTERVAL=" #$(number->string interval) "\n"
       "THRESHOLD=" #$(number->string threshold) "\n"
       "TIMEOUT=" #$(number->string timeout) "\n"
       "TARGET='" #$target "'\n"
       "FAILS=0\n"
       "while true; do\n"
       "  if " #$(file-append curl "/bin/curl")
              " -fsS --max-time \"$TIMEOUT\" \"$URL\""
              " | " #$(file-append grep "/bin/grep") " -q '\"boot-time\"'; then\n"
       "    FAILS=0\n"
       "  else\n"
       "    FAILS=$((FAILS + 1))\n"
       "    echo \"[watchdog] probe failed ($FAILS/$THRESHOLD): $URL\" 1>&2\n"
       "    if [ \"$FAILS\" -ge \"$THRESHOLD\" ]; then\n"
       "      echo \"[watchdog] restarting $TARGET after $FAILS consecutive failures\" 1>&2\n"
       "      "
       ;; Restart by invoking herd; the watchdog user needs passwordless
       ;; sudo on `herd restart <target>` (set this in deploy/os.scm's
       ;; sudoers, same pattern as radicle-ci uses).
       #$(file-append shadow "/bin/sudo")
       " /run/current-system/profile/bin/herd restart \"$TARGET\" || true\n"
       "      FAILS=0\n"
       "    fi\n"
       "  fi\n"
       "  sleep \"$INTERVAL\"\n"
       "done\n")))

(define (localchimera-watchdog-shepherd-service config)
  "Build the shepherd service definition."
  (let ((script (program-file "localchimera-watchdog.sh"
                              #~(call-with-output-file %output
                                  (lambda (port)
                                    (display #$(watchdog-script config)
                                             port)
                                    (chmod port #o755)))))
        (user   (localchimera-watchdog-configuration-user config)))
    (list (shepherd-service
           (provision '(localchimera-watchdog))
           (requirement '(networking localchimera-gateway))
           (start #~(make-forkexec-constructor
                    (list #$script)
                    #:user #$user
                    #:log-file "/var/log/localchimera/watchdog.log"))
           (stop #~(make-kill-destructor))
           (respawn? #t)))))

(define localchimera-watchdog-service-type
  (service-type
   (name 'localchimera-watchdog)
   (extensions
    (list (service-extension shepherd-root-service-type
                             localchimera-watchdog-shepherd-service)))
   (default-value (localchimera-watchdog-configuration))
   (description
    "Polls localchimera-gateway's /federation-status.json every
INTERVAL-SEC seconds; if FAILURE-THRESHOLD consecutive probes fail
(timeout, non-200, malformed JSON), restarts the gateway via
`herd restart`.")))
