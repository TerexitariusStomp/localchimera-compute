;;; deploy/guix/playnet-valhalla-service.scm — Shepherd service for the
;;; self-hosted Valhalla routing engine (Tier-1, offline, no IP leak).
;;;
;;; Valhalla is not (yet) a Guix package — its tree is built from source under
;;; a working directory (see tools/valhalla-local.sh; locally that's
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
;;; playnet-static (:8080) talks to Valhalla, server-to-server on loopback.
;;;
;;; Usage in machines.scm:
;;;   (service playnet-valhalla-service-type
;;;            (playnet-valhalla-configuration
;;;             (work-dir "/home/playnet/playnet-repo")
;;;             (threads 2)))

(define-module (playnet-valhalla-service)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (playnet-valhalla-configuration
            playnet-valhalla-configuration?
            playnet-valhalla-configuration-work-dir
            playnet-valhalla-configuration-config-file
            playnet-valhalla-configuration-manifest
            playnet-valhalla-configuration-bin-dir
            playnet-valhalla-configuration-lib-dir
            playnet-valhalla-configuration-profile-dir
            playnet-valhalla-configuration-threads
            playnet-valhalla-configuration-user
            playnet-valhalla-service-type))

;;; ── Configuration record ───────────────────────────────────────────────────

(define-record-type* <playnet-valhalla-configuration>
  playnet-valhalla-configuration make-playnet-valhalla-configuration
  playnet-valhalla-configuration?
  ;; Repo checkout that contains the built engine under .valhalla/.
  (work-dir     playnet-valhalla-configuration-work-dir
                (default "/home/playnet/playnet-repo"))
  ;; Absolute paths default to the conventional .valhalla/ layout under
  ;; work-dir; override only if the engine lives elsewhere.
  (config-file  playnet-valhalla-configuration-config-file (default #f))
  (manifest     playnet-valhalla-configuration-manifest    (default #f))
  (bin-dir      playnet-valhalla-configuration-bin-dir      (default #f))
  (lib-dir      playnet-valhalla-configuration-lib-dir      (default #f))
  ;; The manifest profile symlink (<vdir>/profile → the GC-rooted store
  ;; profile). Its /lib supplies the dependency libs the binaries' RPATH
  ;; resolves via a build-time profile (e.g. libprotobuf-lite.so.32) and that
  ;; prefix/lib alone does NOT carry — so it must be on LD_LIBRARY_PATH too.
  (profile-dir  playnet-valhalla-configuration-profile-dir  (default #f))
  (threads      playnet-valhalla-configuration-threads      (default 2))
  (user         playnet-valhalla-configuration-user         (default "playnet")))

;;; ── Shepherd service definition ────────────────────────────────────────────

(define (playnet-valhalla-shepherd-service config)
  (let* ((work-dir (playnet-valhalla-configuration-work-dir config))
         (vdir     (string-append work-dir "/.valhalla"))
         (config-f (or (playnet-valhalla-configuration-config-file config)
                       (string-append vdir "/valhalla.json")))
         (manifest (or (playnet-valhalla-configuration-manifest config)
                       (string-append vdir "/manifest.scm")))
         (bin-dir  (or (playnet-valhalla-configuration-bin-dir config)
                       (string-append vdir "/prefix/bin")))
         (lib-dir  (or (playnet-valhalla-configuration-lib-dir config)
                       (string-append vdir "/prefix/lib")))
         (prof-lib (string-append
                    (or (playnet-valhalla-configuration-profile-dir config)
                        (string-append vdir "/profile"))
                    "/lib"))
         (threads  (playnet-valhalla-configuration-threads config))
         (user     (playnet-valhalla-configuration-user config)))
    (list
     (shepherd-service
      (provision '(playnet-valhalla))
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
          #:log-file "/var/log/playnet-valhalla.log"))
      (stop #~(make-kill-destructor))
      (respawn? #t)))))

;;; ── Service type ───────────────────────────────────────────────────────────

(define playnet-valhalla-service-type
  (service-type
   (name 'playnet-valhalla)
   (extensions
    (list (service-extension shepherd-root-service-type
                             playnet-valhalla-shepherd-service)))
   (default-value (playnet-valhalla-configuration))
   (description "Supervise the self-hosted Valhalla routing engine.")))
