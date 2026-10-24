;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/guix/localchimera-valhalla-service.scm — Shepherd service for the
;;; self-hosted Valhalla routing engine (Tier-1, offline, no IP leak).
;;;
;;; Valhalla is not (yet) a Guix package — its tree is built from source under
;;; a working directory (see tools/dev/valhalla-local.sh; locally that's
;;; .valhalla/). This service supervises the built `valhalla_service` binary.
;;;
;;; Runtime model: exec the binary DIRECTLY — no `guix shell` wrapper. The
;;; binary is fully self-contained: its ELF interpreter + all `/gnu/store`
;;; dependency libs are pinned by RPATH, and its own libs live in
;;; <lib-dir> (put on LD_LIBRARY_PATH below). Those exact store paths are
;;; landed on the box out-of-band (a `guix archive` stream of the manifest
;;; profile's closure) and kept alive by a GC root on that profile — so the
;;; service never resolves, downloads, or COMPILES anything at start. That
;;; matters: the production box has no swap, and a runtime `guix shell -m`
;;; that missed a substitute would try to build boost/protobuf and OOM the
;;; live services. Direct exec removes that failure mode entirely.
;;;
;;; It binds localhost only; the browser reaches it through serve-static's
;;; same-origin /route proxy, never directly.
;;;
;;; Thin-nginx model is unchanged — nginx never proxies to :8002. Only
;;; localchimera-static (:8080) talks to Valhalla, server-to-server on loopback.
;;;
;;; Usage in machines.scm:
;;;   (service localchimera-valhalla-service-type
;;;            (localchimera-valhalla-configuration
;;;             (work-dir "/home/localchimera/localchimera-repo")
;;;             (threads 2)))

(define-module (localchimera-valhalla-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (localchimera-valhalla-configuration
            localchimera-valhalla-configuration?
            localchimera-valhalla-configuration-work-dir
            localchimera-valhalla-configuration-config-file
            localchimera-valhalla-configuration-manifest
            localchimera-valhalla-configuration-bin-dir
            localchimera-valhalla-configuration-lib-dir
            localchimera-valhalla-configuration-profile-dir
            localchimera-valhalla-configuration-threads
            localchimera-valhalla-configuration-user
            localchimera-valhalla-service-type))

;;; ── Configuration record ───────────────────────────────────────────────────

(define-record-type* <localchimera-valhalla-configuration>
  localchimera-valhalla-configuration make-localchimera-valhalla-configuration
  localchimera-valhalla-configuration?
  ;; Repo checkout that contains the built engine under .valhalla/.
  (work-dir     localchimera-valhalla-configuration-work-dir
                (default "/home/localchimera/localchimera-repo"))
  ;; Absolute paths default to the conventional .valhalla/ layout under
  ;; work-dir; override only if the engine lives elsewhere.
  (config-file  localchimera-valhalla-configuration-config-file (default #f))
  (manifest     localchimera-valhalla-configuration-manifest    (default #f))
  (bin-dir      localchimera-valhalla-configuration-bin-dir      (default #f))
  (lib-dir      localchimera-valhalla-configuration-lib-dir      (default #f))
  ;; The manifest profile symlink (<vdir>/profile → the GC-rooted store
  ;; profile). Its /lib supplies the dependency libs the binaries' RPATH
  ;; resolves via a build-time profile (e.g. libprotobuf-lite.so.32) and that
  ;; prefix/lib alone does NOT carry — so it must be on LD_LIBRARY_PATH too.
  (profile-dir  localchimera-valhalla-configuration-profile-dir  (default #f))
  (threads      localchimera-valhalla-configuration-threads      (default 2))
  (user         localchimera-valhalla-configuration-user         (default "localchimera")))

;;; ── Shepherd service definition ────────────────────────────────────────────

(define (localchimera-valhalla-shepherd-service config)
  (let* ((work-dir (localchimera-valhalla-configuration-work-dir config))
         (vdir     (string-append work-dir "/.valhalla"))
         (config-f (or (localchimera-valhalla-configuration-config-file config)
                       (string-append vdir "/valhalla.json")))
         (manifest (or (localchimera-valhalla-configuration-manifest config)
                       (string-append vdir "/manifest.scm")))
         (bin-dir  (or (localchimera-valhalla-configuration-bin-dir config)
                       (string-append vdir "/prefix/bin")))
         (lib-dir  (or (localchimera-valhalla-configuration-lib-dir config)
                       (string-append vdir "/prefix/lib")))
         (prof-lib (string-append
                    (or (localchimera-valhalla-configuration-profile-dir config)
                        (string-append vdir "/profile"))
                    "/lib"))
         (threads  (localchimera-valhalla-configuration-threads config))
         (user     (localchimera-valhalla-configuration-user config)))
    (list
     (shepherd-service
      (provision '(localchimera-valhalla))
      (documentation "Self-hosted Valhalla routing engine on tcp://127.0.0.1:8002")
      (requirement '(networking user-processes))
      (start
       #~(make-forkexec-constructor
          ;; Direct exec — RPATH + LD_LIBRARY_PATH resolve every lib; no guix
          ;; shell, no runtime package resolution. See header for why.
          (list (string-append #$bin-dir "/valhalla_service")
                #$config-f #$(number->string threads))
          #:user #$user
          #:directory #$work-dir
          #:environment-variables
          (list (string-append "HOME=/home/" #$user)
                (string-append "LD_LIBRARY_PATH=" #$lib-dir ":" #$prof-lib)
                (string-append "PATH=" #$bin-dir ":/run/current-system/profile/bin"))
          #:log-file "/var/log/localchimera/valhalla.log"))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

;;; ── Service type ───────────────────────────────────────────────────────────

(define localchimera-valhalla-service-type
  (service-type
   (name 'localchimera-valhalla)
   (extensions
    (list (service-extension shepherd-root-service-type
                             localchimera-valhalla-shepherd-service)))
   (default-value (localchimera-valhalla-configuration))
   (description "Supervise the self-hosted Valhalla routing engine.")))
