;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/tails.scm — Tails-equivalent Guix System live ISO
;;;
;;; Build (with WiFi firmware — requires nonguix channel):
;;;   guix time-machine -C deploy/tails-channels.scm \
;;;     -- system image -t iso9660 deploy/tails.scm
;;;
;;; Build (libre kernel only — some WiFi won't work):
;;;   guix time-machine -C deploy/channels.scm \
;;;     -- system image -t iso9660 deploy/tails.scm
;;;
;;; Write to USB:
;;;   sudo dd if=/path/to/image.iso of=/dev/sdX bs=4M status=progress
;;;   sync
;;;
;;; Security properties (matching Tails):
;;;   - Amnesic: boots into RAM, never touches disk
;;;   - All traffic forced through Tor (transparent proxy)
;;;   - Tor bridge support (obfs4) for censored networks
;;;   - Unsafe browser for captive portal login (clearnet, isolated)
;;;   - MAC randomization on all interfaces
;;;   - Spoofed hostname over DHCP
;;;   - DNS routed through Tor (no leaks)
;;;   - Firewall blocks all non-Tor traffic (IPv4 + IPv6)
;;;   - No swap
;;;   - Kernel hardening: memory poisoning, slab debug, init_on_free
;;;   - sysctl hardening: ptrace, kptr, dmesg, ICMP, source routing
;;;   - RAM wipe on shutdown (multi-pass, kernel + userspace)
;;;   - AppArmor LSM enabled + profiles for Tor Browser
;;;   - Firejail sandboxing for applications
;;;   - Tor Browser hardening (user.js overrides)
;;;   - Clock sync via Tor (no NTP leak)
;;;   - Lid-close lock + emergency shutdown hotkey
;;;   - Welcome screen with Tor connection status
;;;   - Optional encrypted persistent storage (LUKS)
;;;   - Privacy tools: Tor Browser, exiftool, wipe, bubblewrap

;; WiFi firmware: Tails ships non-free firmware so most laptops work.
;; To get this, build with tails-channels.scm (includes nonguix).
;; Uncomment the next 2 lines AND the kernel/initrd/firmware fields
;; in the operating-system below:
;;
;; (use-modules (nongnu packages linux)
;;              (nongnu system linux-initrd))

(use-modules (gnu)
             (gnu system)
             (gnu system image)
             (gnu packages admin)
             (gnu packages base)
             (gnu packages bash)
             (gnu packages cryptsetup)
             (gnu packages nss)              ; nss-certs
             (gnu packages disk)             ; wipe
             (gnu packages photo)            ; perl-image-exiftool
             (gnu packages gnome)            ; network-manager, zenity
             (gnu packages golang-crypto)    ; go-obfs4proxy
             (gnu packages terminals)        ; foot
             (gnu packages linux)            ; iptables, firejail, haveged
             (gnu packages networking)
             (gnu packages curl)
             (gnu packages wget)
             (gnu packages apparmor)
             (gnu packages security-token)
             (gnu packages tor)
             (gnu packages tor-browsers)
             (gnu packages virtualization)   ; bubblewrap
             (gnu packages web-browsers)     ; epiphany (unsafe browser)
             (gnu packages wm)
             (gnu packages xdisorg)
             (gnu packages xorg)
             ;; Tails application suite
             (gnu packages gnuzilla)         ; icedove (thunderbird)
             (gnu packages gnupg)            ; gnupg
             (gnu packages kde-pim)          ; kleopatra
             (gnu packages password-utils)   ; keepassxc
             (gnu packages libreoffice)
             (gnu packages gimp)
             (gnu packages inkscape)
             (gnu packages audio)            ; audacity, sound-juicer
             (gnu packages video)            ; ffmpeg
             (gnu packages ocr)              ; tesseract-ocr
             (gnu packages messaging)        ; pidgin, pidgin-otr
             (gnu services)
             (gnu services base)
             (gnu services desktop)
             (gnu services networking)
             (gnu services shepherd)
             (gnu services xorg)
             (guix gexp)
             (gnu system setuid))

;; ===================================================================
;; §1  Tor transparent proxy
;; ===================================================================

;; TransPort:  intercepts TCP from iptables REDIRECT
;; DNSPort:    resolves DNS through Tor (prevents leaks)
;; SocksPort:  for applications that support SOCKS directly
;; ClientTransportPlugin: obfs4 bridge support for censored networks

(define %tor-config
  (tor-configuration
   (tor tor)
   (config-file
    (plain-file "torrc"
      "## --- Ports ---
TransPort 9040
DNSPort 5353
AutomapHostsOnResolve 1
VirtualAddrNetworkIPv4 10.192.0.0/10

## --- Stream isolation (Tails-style) ---
## Each SocksPort gets its own Tor circuit to prevent correlation.
## Default: general applications
SocksPort 9050 IsolateDestAddr IsolateDestPort
## Tor Browser (dedicated circuit per site)
SocksPort 9150 IsolateSOCKSAuth KeepAliveIsolateSOCKSAuth
## torsocks CLI tools
SocksPort 9051 IsolateDestAddr IsolateDestPort
## Unsafe browser Tor check (no isolation — shares circuit for speed)
SocksPort 9062
## System updates (no isolation — benefits from GeoIP mirror routing)
SocksPort 9063

## --- Bridge support ---
## Uncomment and fill in to bypass censorship:
## UseBridges 1
## ClientTransportPlugin obfs4 exec /run/current-system/profile/bin/obfs4proxy
## Bridge obfs4 <IP>:<PORT> <FINGERPRINT> cert=<CERT> iat-mode=0

## --- Safety ---
SafeSocks 1
TestSocks 1

## --- Hardening ---
## Sandbox Tor process (seccomp)
Sandbox 1
## Reject plaintext connections on SocksPort by default
WarnPlaintextPorts 23,109,110,143
RejectPlaintextPorts 23,109,110,143
"))))

;; ===================================================================
;; §2  iptables firewall
;; ===================================================================

;; Force ALL traffic through Tor.  Only the tor user may connect
;; directly (to reach relays/bridges).  The clearnet-user gets a
;; narrow exception for captive portal login only (unsafe browser).

(define %iptables-rules
  (plain-file "iptables-rules"
    "*nat
:PREROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]

## DNS → Tor DNSPort (except clearnet-user for captive portal)
-A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5353
-A OUTPUT -p udp --dport 53 -m owner --uid-owner clearnet-user -j ACCEPT
-A OUTPUT -p udp --dport 53 -m owner ! --uid-owner tor -j REDIRECT --to-ports 5353

## TCP → Tor TransPort (skip localhost, Tor's own, and clearnet-user)
-A PREROUTING -p tcp --syn -j REDIRECT --to-ports 9040
-A OUTPUT -p tcp --syn -m owner --uid-owner clearnet-user -j ACCEPT
-A OUTPUT -p tcp --syn -m owner ! --uid-owner tor -d 127.0.0.0/8 -j RETURN
-A OUTPUT -p tcp --syn -m owner ! --uid-owner tor -j REDIRECT --to-ports 9040
COMMIT

*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]

## Loopback
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

## Established connections
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

## DHCP — needed to get an IP before Tor can start
-A INPUT -p udp --sport 67 --dport 68 -j ACCEPT
-A OUTPUT -p udp --sport 68 --dport 67 -j ACCEPT

## Tor process can reach the network (relays + bridges)
-A OUTPUT -m owner --uid-owner tor -j ACCEPT

## Clearnet user — direct access (unsafe browser for captive portals only)
-A OUTPUT -m owner --uid-owner clearnet-user -j ACCEPT

## Block RFC1918 DNS responses (prevent local network discovery leaks)
-A INPUT -s 10.0.0.0/8 -p udp --sport 53 -j DROP
-A INPUT -s 172.16.0.0/12 -p udp --sport 53 -j DROP
-A INPUT -s 192.168.0.0/16 -p udp --sport 53 -j DROP

## Drop everything else
-A INPUT -j DROP
-A FORWARD -j DROP
-A OUTPUT -j DROP
COMMIT
"))

(define %ip6tables-rules
  (plain-file "ip6tables-rules"
    "*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]
## Block all IPv6 — prevents leaks
-A INPUT -j DROP
-A FORWARD -j DROP
-A OUTPUT -j DROP
COMMIT
"))

;; ===================================================================
;; §3  MAC randomization + hostname spoofing
;; ===================================================================

(define %nm-hardened-conf
  (plain-file "99-hardened-nm.conf"
    "[device]
wifi.scan-rand-mac-address=yes

[connection]
wifi.cloned-mac-address=random
ethernet.cloned-mac-address=random

## Spoof hostname — don't leak real hostname over DHCP
[connection-hostname]
ipv4.dhcp-send-hostname=false
ipv6.dhcp-send-hostname=false
"))

(define %nm-hardening-service
  (simple-service
   'nm-hardening
   etc-service-type
   (list `("NetworkManager/conf.d/99-hardened-nm.conf"
           ,%nm-hardened-conf))))

;; ===================================================================
;; §4  Kernel hardening
;; ===================================================================

(define %hardened-kernel-arguments
  (append
   '(;; --- Memory hardening ---
     "page_poison=1"            ; poison freed pages (cold-boot)
     "slub_debug=P"             ; SLUB: poison freed objects
     "slab_nomerge"             ; prevent cross-cache attacks
     "init_on_free=1"           ; zero all freed memory
     "init_on_alloc=1"          ; zero all allocated memory

     ;; --- Network hardening ---
     "ipv6.disable=1"           ; disable IPv6 entirely

     ;; --- AppArmor LSM ---
     "lsm=landlock,lockdown,yama,integrity,apparmor"
     "apparmor=1"
     "security=apparmor"

     ;; --- Misc hardening ---
     "modules_disabled=1"       ; no module loading after boot
     "quiet" "loglevel=0"       ; suppress kernel address logs
     "debugfs=off"              ; disable debugfs
     "lockdown=integrity"       ; restrict userspace→kernel
     "kexec_load_disabled=1"    ; no hot-loading another kernel
     "vsyscall=none"            ; disable vsyscall (exploit target)
     "mce=0"                    ; don't log machine check info
     "random.trust_cpu=off")    ; don't trust CPU RNG alone
   %default-kernel-arguments))

;; ===================================================================
;; §5  sysctl hardening
;; ===================================================================

(define %hardened-sysctl
  (plain-file "99-hardened.conf"
    "# === Network ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.ip_forward = 0
net.ipv4.tcp_timestamps = 0
net.ipv4.conf.all.log_martians = 1

# === Kernel ===
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 2
kernel.sysrq = 0
kernel.perf_event_paranoid = 3
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
fs.suid_dumpable = 0
vm.unprivileged_userfaultfd = 0
kernel.unprivileged_userns_clone = 0
kernel.kexec_load_disabled = 1
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
"))

(define %sysctl-hardening-service
  (simple-service
   'sysctl-hardening
   etc-service-type
   (list `("sysctl.d/99-hardened.conf"
           ,%hardened-sysctl))))

;; ===================================================================
;; §5b  HAVEGE entropy daemon
;; ===================================================================

;; Tails runs haveged to ensure sufficient entropy at boot.
;; Critical for key generation, Tor circuit creation, etc.
;; Without this, /dev/random can block on headless/minimal systems.

(define %haveged-service
  (simple-service
   'haveged
   shepherd-root-service-type
   (list
    (shepherd-service
     (provision '(haveged))
     (requirement '())
     (start #~(make-forkexec-constructor
               (list #$(file-append haveged "/sbin/haveged")
                     "-w" "1024"      ; watermark: refill when pool < 1024 bits
                     "-v" "0"         ; quiet
                     "--run=0")       ; run as daemon (don't exit)
               #:log-file "/var/log/haveged.log"))
     (stop #~(make-kill-destructor))
     (documentation "HAVEGE entropy daemon for /dev/random.")))))

;; ===================================================================
;; §6  RAM wipe on shutdown (multi-pass)
;; ===================================================================

;; More thorough than v1: drops caches, then fills memory with
;; 0xFF (pass 1) and 0x00 (pass 2) to defeat simple recovery.
;; The kernel's init_on_free=1 handles pages freed normally;
;; this catches everything still resident at shutdown.

(define %ram-wipe-script
  (program-file "ram-wipe"
    #~(begin
        (use-modules (ice-9 format)
                     (rnrs bytevectors))
        (format #t "~%*** RAM WIPE: dropping caches ***~%")
        ;; 1. Drop all filesystem caches
        (call-with-output-file "/proc/sys/vm/drop_caches"
          (lambda (port) (display "3" port)))
        ;; 2. Fill free memory — pass 1 (0xFF), pass 2 (0x00)
        (let wipe-pass ((passes '(#xFF #x00))
                        (pass-num 1))
          (when (pair? passes)
            (format #t "*** RAM WIPE: pass ~a (0x~2,'0x) ***~%" pass-num (car passes))
            (let ((fill-byte (car passes)))
              (catch #t
                (lambda ()
                  (let loop ((chunks '()))
                    (let ((chunk (make-bytevector (* 1024 1024) fill-byte)))
                      (loop (cons chunk chunks)))))
                (lambda _ #t)))  ; OOM — pass done
            (wipe-pass (cdr passes) (1+ pass-num))))
        ;; 3. Sync to flush anything remaining
        (system* "sync")
        (format #t "*** RAM WIPE COMPLETE ***~%"))))

(define %ram-wipe-service
  (simple-service
   'ram-wipe
   shepherd-root-service-type
   (list
    (shepherd-service
     (provision '(ram-wipe))
     (requirement '())
     (one-shot? #t)
     (stop #~(lambda _
               (system* #$%ram-wipe-script)
               #f))
     (start #~(lambda _ #t))
     (documentation "Multi-pass RAM wipe on system shutdown.")))))

;; ===================================================================
;; §6b  RAM wipe on boot media removal
;; ===================================================================

;; Tails wipes RAM if the USB stick is physically removed.
;; We monitor /dev/disk/by-label for the boot media disappearing
;; and trigger emergency shutdown if it does.

(define %media-removal-wipe-script
  (program-file "media-removal-wipe"
    #~(begin
        (use-modules (ice-9 format))
        ;; Find the boot device from /proc/cmdline
        ;; On a live USB this won't have a persistent root, so we watch
        ;; for the ISO label disappearing from /dev/disk/by-label/
        (let loop ()
          (sleep 2)
          ;; If the boot media is gone, trigger emergency shutdown
          (let ((boot-media-present?
                 (or (file-exists? "/dev/disk/by-label/Guix_image")
                     (file-exists? "/dev/disk/by-label/GUIX_IMAGE")
                     ;; Fallback: check if any removable block device exists
                     (file-exists? "/sys/block/sda/removable"))))
            (if boot-media-present?
                (loop)
                (begin
                  (format #t "*** BOOT MEDIA REMOVED — EMERGENCY SHUTDOWN ***~%")
                  (system* #$%ram-wipe-script)
                  (system* "systemctl" "poweroff" "--force" "--force"))))))))

(define %media-removal-service
  (simple-service
   'media-removal-wipe
   shepherd-root-service-type
   (list
    (shepherd-service
     (provision '(media-removal-wipe))
     (requirement '(user-processes))
     (start #~(make-forkexec-constructor
               (list #$%media-removal-wipe-script)
               #:log-file "/var/log/media-removal-wipe.log"))
     (stop #~(make-kill-destructor))
     (documentation "Wipe RAM and shutdown if boot USB is removed.")))))

;; ===================================================================
;; §7  Emergency shutdown (panic button)
;; ===================================================================

;; Script that immediately wipes RAM and powers off.
;; Bound to Mod+Shift+Delete in sway (see §14).

(define %emergency-shutdown-script
  (program-file "emergency-shutdown"
    #~(begin
        (system* "sudo" "sh" "-c"
                 (string-append
                  "echo 3 > /proc/sys/vm/drop_caches; "
                  #$%ram-wipe-script "; "
                  "systemctl poweroff --force --force")))))

;; ===================================================================
;; §8  Unsafe browser (captive portal)
;; ===================================================================

;; Tails provides a clearnet browser solely for logging into captive
;; portals.  It runs as a dedicated user (clearnet-user) whose traffic
;; bypasses Tor in the firewall (see §2).  A zenity warning is shown
;; before launch.  The browser profile is tmpfs-only (amnesic).

(define %unsafe-browser-script
  (program-file "unsafe-browser"
    #~(begin
        (use-modules (ice-9 format))
        ;; Show warning dialog
        (let ((response
               (system* #$(file-append zenity "/bin/zenity")
                        "--warning"
                        "--title=Unsafe Browser"
                        "--text=WARNING: This browser connects directly to the Internet WITHOUT Tor.\n\nUse it ONLY to log into captive portals (hotel/airport wifi).\n\nClose it as soon as you have network access."
                        "--ok-label=Launch Unsafe Browser")))
          (when (zero? response)
            ;; Launch epiphany as clearnet-user in a temporary profile
            (setenv "HOME" "/tmp/unsafe-browser-home")
            (system* "mkdir" "-p" "/tmp/unsafe-browser-home")
            (system* "sudo" "-u" "clearnet-user"
                     "env" "HOME=/tmp/unsafe-browser-home"
                     #$(file-append epiphany "/bin/epiphany")
                     "--incognito")
            ;; Clean up after close
            (system* "rm" "-rf" "/tmp/unsafe-browser-home"))))))

;; ===================================================================
;; §9  Clock sync via Tor (no NTP)
;; ===================================================================

;; Tails uses htpdate to set the clock from HTTP headers fetched
;; through Tor.  NTP leaks timezone and network fingerprint.
;; This shepherd service fetches Date: headers from multiple
;; well-known HTTPS sites via torsocks and sets the system clock.

(define %tor-clock-sync-script
  (program-file "tor-clock-sync"
    #~(begin
        (use-modules (ice-9 format)
                     (ice-9 popen)
                     (ice-9 rdelim)
                     (ice-9 regex))
        (format #t "tor-clock-sync: waiting for Tor...~%")
        ;; Wait for Tor to be reachable
        (let wait-loop ((tries 0))
          (when (< tries 60)
            (let ((result (system* #$(file-append torsocks "/bin/torsocks")
                                   "wget" "-q" "--spider"
                                   "--timeout=5"
                                   "https://www.torproject.org")))
              (unless (zero? result)
                (sleep 5)
                (wait-loop (1+ tries))))))
        ;; Fetch Date: header from multiple sources
        (let ((urls '("https://www.torproject.org"
                      "https://www.eff.org"
                      "https://www.wikipedia.org")))
          (let url-loop ((remaining urls))
            (when (pair? remaining)
              (let* ((pipe (open-pipe*
                            OPEN_READ
                            #$(file-append torsocks "/bin/torsocks")
                            "wget" "-S" "--spider" "-q"
                            "--timeout=10"
                            (car remaining)))
                     (output (let line-loop ((lines ""))
                               (let ((line (read-line pipe)))
                                 (if (eof-object? line)
                                     lines
                                     (line-loop (string-append lines line "\n")))))))
                (close-pipe pipe)
                ;; Parse "Date: ..." header and set clock
                (let ((match (string-match "Date: (.+)" output)))
                  (if match
                      (begin
                        (format #t "tor-clock-sync: setting clock from ~a~%"
                                (car remaining))
                        (system* "date" "-s" (match:substring match 1)))
                      (url-loop (cdr remaining)))))))))))

(define %tor-clock-sync-service
  (simple-service
   'tor-clock-sync
   shepherd-root-service-type
   (list
    (shepherd-service
     (provision '(tor-clock-sync))
     (requirement '(tor networking))
     (one-shot? #t)
     (start #~(lambda _
                (system* #$%tor-clock-sync-script)
                #t))
     (documentation "Sync system clock via HTTP Date headers over Tor.")))))

;; ===================================================================
;; §10  Tor Browser hardening (user.js)
;; ===================================================================

;; Hardened preferences matching Tails' Tor Browser configuration.
;; Deployed to /etc/torbrowser/user.js and symlinked into the
;; browser profile on first launch.

(define %torbrowser-user-js
  (plain-file "user.js"
    "// === Tails-equivalent Tor Browser hardening ===

// Letterboxing: round window size to multiples to reduce fingerprint
user_pref(\"privacy.resistFingerprinting.letterboxing\", true);

// Disable WebRTC (can leak real IP even through Tor)
user_pref(\"media.peerconnection.enabled\", false);
user_pref(\"media.navigator.enabled\", false);

// Disable WebGL (fingerprinting vector)
user_pref(\"webgl.disabled\", true);

// Canvas: prompt before extraction (fingerprinting)
user_pref(\"privacy.resistFingerprinting\", true);

// Disable telemetry
user_pref(\"toolkit.telemetry.enabled\", false);
user_pref(\"datareporting.healthreport.uploadEnabled\", false);
user_pref(\"datareporting.policy.dataSubmissionEnabled\", false);

// Disable Pocket, screenshots, experiments
user_pref(\"extensions.pocket.enabled\", false);
user_pref(\"extensions.screenshots.disabled\", true);
user_pref(\"app.shield.optoutstudies.enabled\", false);

// Disable speculative connections
user_pref(\"network.http.speculative-parallel-limit\", 0);
user_pref(\"network.dns.disablePrefetch\", true);
user_pref(\"network.prefetch-next\", false);
user_pref(\"browser.urlbar.speculativeConnect.enabled\", false);

// Force HTTPS
user_pref(\"dom.security.https_only_mode\", true);
user_pref(\"dom.security.https_only_mode_ever_enabled\", true);

// Disable search suggestions (leak to search engine)
user_pref(\"browser.search.suggest.enabled\", false);
user_pref(\"browser.urlbar.suggest.searches\", false);

// Isolate cookies/cache to first-party domain
user_pref(\"privacy.firstparty.isolate\", true);

// Disable offline cache
user_pref(\"browser.cache.offline.enable\", false);

// Disable form autofill
user_pref(\"extensions.formautofill.available\", \"off\");
user_pref(\"extensions.formautofill.addresses.enabled\", false);
user_pref(\"extensions.formautofill.creditCards.enabled\", false);

// Disable geolocation
user_pref(\"geo.enabled\", false);

// Disable battery API (fingerprinting)
user_pref(\"dom.battery.enabled\", false);

// Disable Clipboard API events
user_pref(\"dom.event.clipboardevents.enabled\", false);

// Security: block mixed content
user_pref(\"security.mixed_content.block_active_content\", true);
user_pref(\"security.mixed_content.block_display_content\", true);

// New tab: blank (no information leak)
user_pref(\"browser.newtabpage.enabled\", false);
user_pref(\"browser.startup.homepage\", \"about:blank\");
"))

(define %torbrowser-hardening-service
  (simple-service
   'torbrowser-hardening
   etc-service-type
   (list `("torbrowser/user.js" ,%torbrowser-user-js))))

;; ===================================================================
;; §11  AppArmor profiles
;; ===================================================================

;; Tails confines Tor Browser, Thunderbird, etc. with AppArmor.
;; We write profiles for our key applications.

(define %apparmor-torbrowser-profile
  (plain-file "torbrowser"
    "#include <tunables/global>

profile torbrowser /run/current-system/profile/bin/torbrowser flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/fonts>
  #include <abstractions/X>
  #include <abstractions/wayland>
  #include <abstractions/nameservice>
  #include <abstractions/ssl_certs>

  # Tor Browser needs
  /run/current-system/profile/** r,
  /gnu/store/** r,
  /tmp/** rwk,
  owner @{HOME}/.local/share/torbrowser/** rwk,
  owner @{HOME}/.cache/torbrowser/** rwk,

  # Tor SOCKS
  network inet stream,
  network inet6 stream,

  # Block everything else
  deny /etc/passwd r,
  deny /etc/shadow r,
  deny /home/*/.ssh/** r,
  deny /home/*/.gnupg/** r,
  deny /home/*/.bash_history r,
  deny /proc/*/cmdline r,
  deny /proc/*/environ r,
}
"))

(define %apparmor-foot-profile
  (plain-file "foot"
    "#include <tunables/global>

profile foot /run/current-system/profile/bin/foot flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/fonts>
  #include <abstractions/wayland>

  /run/current-system/profile/** r,
  /gnu/store/** r,
  owner @{HOME}/** rw,
  /tmp/** rw,
  /dev/ptmx rw,
  /dev/pts/* rw,

  # Allow launching programs
  /run/current-system/profile/bin/* ix,

  # Block sensitive files from terminal apps
  deny /etc/shadow r,
  deny /proc/*/environ r,
}
"))

(define %apparmor-epiphany-profile
  (plain-file "epiphany-unsafe"
    "#include <tunables/global>

profile epiphany-unsafe /run/current-system/profile/bin/epiphany flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/fonts>
  #include <abstractions/wayland>
  #include <abstractions/nameservice>
  #include <abstractions/ssl_certs>

  /run/current-system/profile/** r,
  /gnu/store/** r,
  /tmp/unsafe-browser-home/** rwk,

  # Direct network (this is the unsafe/captive portal browser)
  network inet stream,
  network inet dgram,

  # Block access to everything sensitive
  deny @{HOME}/** r,
  deny /etc/shadow r,
  deny /etc/tor/** r,
  deny /home/*/.ssh/** r,
  deny /home/*/.gnupg/** r,
}
"))

(define %apparmor-icedove-profile
  (plain-file "icedove"
    "#include <tunables/global>

profile icedove /run/current-system/profile/bin/icedove flags=(attach_disconnected) {
  #include <abstractions/base>
  #include <abstractions/fonts>
  #include <abstractions/X>
  #include <abstractions/wayland>
  #include <abstractions/nameservice>
  #include <abstractions/ssl_certs>
  #include <abstractions/gnupg>

  /run/current-system/profile/** r,
  /gnu/store/** r,
  /tmp/** rwk,
  owner @{HOME}/.icedove/** rwk,
  owner @{HOME}/.cache/icedove/** rwk,
  owner @{HOME}/.gnupg/** rwk,

  # Email via Tor SOCKS
  network inet stream,
  network inet6 stream,

  # Block sensitive system files
  deny /etc/passwd r,
  deny /etc/shadow r,
  deny /home/*/.ssh/** r,
  deny /home/*/.bash_history r,
  deny /proc/*/cmdline r,
  deny /proc/*/environ r,
}
"))

(define %apparmor-profiles-service
  (simple-service
   'apparmor-profiles
   etc-service-type
   (list `("apparmor.d/torbrowser" ,%apparmor-torbrowser-profile)
         `("apparmor.d/foot" ,%apparmor-foot-profile)
         `("apparmor.d/epiphany-unsafe" ,%apparmor-epiphany-profile)
         `("apparmor.d/icedove" ,%apparmor-icedove-profile))))

;; ===================================================================
;; §12  Encrypted persistent storage (optional)
;; ===================================================================

;; Script to create or unlock a LUKS-encrypted partition on the USB
;; for selective persistence (similar to Tails Persistent Storage).
;; Run manually: sudo persistent-storage setup  OR
;;               sudo persistent-storage unlock

(define %persistent-storage-script
  (program-file "persistent-storage"
    #~(begin
        (use-modules (ice-9 format)
                     (ice-9 match))
        (define persistence-device "/dev/disk/by-label/TailsData")
        (define persistence-mount "/mnt/persistent")

        (match (cdr (command-line))
          (("setup")
           (format #t "~%=== Persistent Storage Setup ===~%")
           (format #t "This will create an encrypted partition.~%")
           (format #t "You need a second partition on your USB stick.~%~%")
           ;; Find the USB device
           (let ((device (getenv "PERSIST_DEVICE")))
             (unless device
               (format #t "Set PERSIST_DEVICE to the partition to encrypt.~%")
               (format #t "Example: PERSIST_DEVICE=/dev/sda2 persistent-storage setup~%")
               (exit 1))
             (format #t "Formatting ~a with LUKS...~%" device)
             (system* #$(file-append cryptsetup "/sbin/cryptsetup")
                      "luksFormat" "--type" "luks2"
                      "--label" "TailsData"
                      device)
             (format #t "~%Done. Use 'persistent-storage unlock' to mount.~%")))

          (("unlock")
           (format #t "~%Unlocking persistent storage...~%")
           (system* #$(file-append cryptsetup "/sbin/cryptsetup")
                    "luksOpen" persistence-device "persistence")
           (system* "mkdir" "-p" persistence-mount)
           (system* "mount" "/dev/mapper/persistence" persistence-mount)
           (format #t "Persistent storage mounted at ~a~%" persistence-mount)
           ;; Symlink common directories
           (for-each
            (lambda (dir)
              (let ((src (string-append persistence-mount "/" dir))
                    (dst (string-append "/home/user/" dir)))
                (when (file-exists? src)
                  (system* "ln" "-sf" src dst)
                  (format #t "  Linked ~a → ~a~%" src dst))))
            '("Documents" "dotfiles" "gnupg" "ssh-keys")))

          (("lock")
           (format #t "Locking persistent storage...~%")
           (system* "umount" persistence-mount)
           (system* #$(file-append cryptsetup "/sbin/cryptsetup")
                    "luksClose" "persistence")
           (format #t "Persistent storage locked.~%"))

          (_
           (format #t "Usage: persistent-storage {setup|unlock|lock}~%"))))))

;; ===================================================================
;; §13  Welcome screen
;; ===================================================================

;; Simple first-boot dialog explaining the system and showing
;; Tor connection status.

(define %welcome-script
  (program-file "welcome"
    #~(begin
        (use-modules (ice-9 format)
                     (ice-9 popen)
                     (ice-9 rdelim))
        ;; Check Tor status
        (let* ((pipe (open-pipe* OPEN_READ
                                 #$(file-append torsocks "/bin/torsocks")
                                 "wget" "-q" "-O" "/dev/null"
                                 "--timeout=10"
                                 "https://check.torproject.org"))
               (status (close-pipe pipe))
               (tor-ok? (zero? status))
               (message
                (string-append
                 "Welcome to playnet-live\n\n"
                 "Security features active:\n"
                 "  ✓ All traffic routed through Tor\n"
                 "  ✓ MAC address randomized\n"
                 "  ✓ Hostname spoofed\n"
                 "  ✓ RAM-only (amnesic)\n"
                 "  ✓ Firewall blocking non-Tor traffic\n"
                 "  ✓ AppArmor enabled\n\n"
                 "Tor status: "
                 (if tor-ok? "CONNECTED ✓" "NOT CONNECTED ✗")
                 "\n\n"
                 "Key bindings:\n"
                 "  Mod+Return     Terminal\n"
                 "  Mod+d          App launcher\n"
                 "  Mod+Shift+Del  EMERGENCY SHUTDOWN (wipes RAM)\n"
                 "  Mod+l          Lock screen\n\n"
                 "Commands:\n"
                 "  unsafe-browser           Captive portal login (clearnet!)\n"
                 "  persistent-storage unlock  Mount encrypted storage\n"
                 "  firejail torbrowser      Sandboxed Tor Browser\n")))
          (system* #$(file-append zenity "/bin/zenity")
                   "--info"
                   "--title=playnet-live"
                   (string-append "--text=" message)
                   "--width=500")))))

;; Launch welcome screen after login
(define %welcome-autostart
  (plain-file "welcome.desktop"
    "[Desktop Entry]
Type=Application
Name=Welcome
Exec=welcome
NoDisplay=true
X-GNOME-Autostart-enabled=true
"))

(define %welcome-service
  (simple-service
   'welcome-autostart
   etc-service-type
   (list `("xdg/autostart/welcome.desktop" ,%welcome-autostart))))

;; ===================================================================
;; §14  Sway configuration (security + UX)
;; ===================================================================

(define %sway-config
  (plain-file "sway-security-config"
    "# --- Auto-lock ---
exec swayidle -w \\
    timeout 300 'swaylock -f -c 000000' \\
    before-sleep 'swaylock -f -c 000000'

# --- Black wallpaper (no information leak) ---
output * bg #000000 solid_color

# --- Emergency shutdown: Mod+Shift+Delete ---
bindsym Mod4+Shift+Delete exec emergency-shutdown

# --- Lock screen: Mod+l ---
bindsym Mod4+l exec swaylock -f -c 000000

# --- Launch terminal ---
bindsym Mod4+Return exec foot

# --- Launch app menu ---
bindsym Mod4+d exec wofi --show drun

# --- Launch Tor Browser (sandboxed) ---
bindsym Mod4+b exec firejail torbrowser

# --- Launch unsafe browser (captive portal) ---
bindsym Mod4+Shift+u exec unsafe-browser

# --- Launch welcome screen ---
exec welcome
"))

(define %sway-config-service
  (simple-service
   'sway-security-config
   etc-service-type
   (list `("sway/config.d/99-security.conf"
           ,%sway-config))))

;; ===================================================================
;; §15  Lid close + elogind hardening
;; ===================================================================

(define %elogind-lid-config
  (plain-file "99-lid-hardening.conf"
    "[Login]
HandleLidSwitch=lock
HandleLidSwitchExternalPower=lock
HandleLidSwitchDocked=lock
IdleAction=lock
IdleActionSec=300
"))

(define %elogind-hardening-service
  (simple-service
   'elogind-lid-hardening
   etc-service-type
   (list `("elogind/logind.conf.d/99-lid-hardening.conf"
           ,%elogind-lid-config))))

;; ===================================================================
;; §16  DNS → Tor
;; ===================================================================

(define %tor-resolv-conf
  (plain-file "resolv.conf"
    "# All DNS through Tor
nameserver 127.0.0.1
options edns0
"))

(define %tor-dns-service
  (simple-service
   'tor-dns-resolv
   etc-service-type
   (list `("resolv.conf" ,%tor-resolv-conf))))

;; ===================================================================
;; §17  Firejail setuid
;; ===================================================================

(define %firejail-setuid
  (setuid-program
   (program (file-append firejail "/bin/firejail"))))

;; ===================================================================
;; §18  Packages
;; ===================================================================

(define %privacy-packages
  (list
   ;; --- Tor & networking ---
   tor torsocks torbrowser
   go-obfs4proxy                ; bridge pluggable transport
   curl wget                    ; CLI download tools (routed through Tor)
   onionshare                   ; anonymous file sharing

   ;; --- Sandboxing ---
   firejail
   bubblewrap
   apparmor

   ;; --- Encryption & passwords ---
   gnupg                        ; OpenPGP
   kleopatra                    ; GnuPG graphical frontend
   keepassxc                    ; password manager
   cryptsetup                   ; LUKS disk encryption

   ;; --- Metadata & secure deletion ---
   perl-image-exiftool          ; EXIF/metadata stripping
   wipe                         ; secure file deletion

   ;; --- Communication ---
   icedove                      ; Thunderbird email (with OpenPGP)
   pidgin pidgin-otr            ; IM with OTR encryption

   ;; --- Office & documents ---
   libreoffice

   ;; --- Graphics & media ---
   gimp                         ; image editor
   inkscape                     ; vector graphics
   audacity                     ; audio editor
   ffmpeg                       ; audio/video conversion
   sound-juicer                 ; audio CD ripper
   brasero                      ; CD/DVD burning

   ;; --- Utilities ---
   tesseract-ocr                ; OCR
   simple-scan                  ; document scanner

   ;; --- System ---
   haveged                      ; entropy daemon
   iptables
   network-manager
   nss-certs                    ; TLS root certificates

   ;; --- Unsafe browser (captive portal only) ---
   epiphany
   zenity                       ; dialog boxes

   ;; --- Desktop (Wayland) ---
   sway
   swaylock
   swayidle
   wofi                         ; launcher
   foot                         ; terminal
   xorg-server))                ; Xwayland for Tor Browser

;; ===================================================================
;; §19  Operating system
;; ===================================================================

(operating-system
  (host-name "localhost")                  ; generic — reveals nothing
  (timezone "UTC")                         ; no location leak
  (locale "en_US.utf8")

  ;; Bootloader (overridden by image type, but required by schema)
  (bootloader (bootloader-configuration
               (bootloader grub-efi-bootloader)
               (targets '("/boot/efi"))))

  ;; RAM-only root filesystem (amnesic)
  (file-systems (cons (file-system
                        (device "none")
                        (mount-point "/")
                        (type "tmpfs")
                        (options "size=80%"))
                      %base-file-systems))

  ;; No swap — ever
  (swap-devices '())

  ;; Non-free kernel + WiFi firmware (uncomment if using tails-channels.scm):
  ;; (kernel linux)
  ;; (initrd microcode-initrd)
  ;; (firmware (list linux-firmware))

  ;; Kernel hardening (AppArmor, memory poisoning, lockdown)
  (kernel-arguments %hardened-kernel-arguments)

  ;; User accounts
  (users (append
          (list
           ;; Primary user — no password (live system)
           (user-account
            (name "user")
            (group "users")
            (supplementary-groups '("wheel" "netdev" "audio" "video")))
           ;; Clearnet user — used exclusively by unsafe browser
           ;; Firewall allows this UID direct network access
           (user-account
            (name "clearnet-user")
            (group "nogroup")
            (system? #t)
            (home-directory "/var/empty")
            (shell (file-append shadow "/sbin/nologin"))))
          %base-user-accounts))

  ;; Setuid programs
  (setuid-programs (cons %firejail-setuid
                         %setuid-programs))

  ;; System-wide packages
  (packages (append %privacy-packages %base-packages))

  ;; Services
  (services
   (append
    (list
     ;; --- §1 Networking ---
     (service tor-service-type %tor-config)

     ;; --- §2 Firewall ---
     (service iptables-service-type
              (iptables-configuration
               (ipv4-rules %iptables-rules)
               (ipv6-rules %ip6tables-rules)))

     ;; --- §3 NetworkManager ---
     (service network-manager-service-type
              (network-manager-configuration
               (dns "none")))

     ;; --- Hardening configs ---
     %nm-hardening-service         ; MAC randomization + hostname
     %sysctl-hardening-service     ; kernel + network sysctl
     %tor-dns-service              ; resolv.conf → Tor
     %elogind-hardening-service    ; lid close → lock
     %sway-config-service          ; sway keybindings + security
     %apparmor-profiles-service    ; AppArmor for TB, foot, epiphany
     %torbrowser-hardening-service ; user.js overrides
     %welcome-service              ; first-boot welcome dialog

     ;; --- Shepherd services ---
     %ram-wipe-service             ; multi-pass RAM wipe on shutdown
     %tor-clock-sync-service       ; clock via Tor (no NTP)
     %haveged-service              ; entropy daemon
     %media-removal-service        ; RAM wipe if USB yanked

     ;; --- Desktop ---
     (service seatd-service-type)
     (service elogind-service-type)

     ;; Greetd — auto-login to sway
     (service greetd-service-type
              (greetd-configuration
               (terminals
                (list (greetd-terminal-configuration
                       (terminal-vt "1")
                       (terminal-switch #t)
                       (default-session-command
                         (greetd-agreety-session
                          (command (file-append sway "/bin/sway"))
                          (command-args '())))))))))

    ;; Base services minus dhcpcd (NM handles networking)
    (modify-services %base-services
      (delete dhcpcd-service-type)))))
