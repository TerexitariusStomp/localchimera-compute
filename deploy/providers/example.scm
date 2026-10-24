;;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; deploy/providers/example.scm — provider config template
;;;
;;; Copy this file to create a provider config for your server:
;;;   cp deploy/providers/example.scm deploy/providers/my-server.scm
;;;
;;; Provider configs are gitignored — they contain server IPs and
;;; SSH host keys that must NEVER be committed.
;;;
;;; Deploy with:
;;;   LOCALCHIMERA_PROVIDER=deploy/providers/my-server.scm \
;;;     bash deploy/scripts/reconfigure.sh

(use-modules (gnu bootloader grub)
             (gnu system file-systems))

;; Provider config — an alist consumed by machines.scm.
;; Fill in values from your VPS provider's control panel.
`((host-ip        . "YOUR_SERVER_IP")
  (host-name      . "localchimera")
  (system         . "x86_64-linux")
  (ssh-host-key   . "ssh-ed25519 YOUR_HOST_KEY_HERE")

  ;; KVM-based VPS typically needs virtio_blk or virtio_scsi.
  ;; Check with: lsmod | grep virtio (in rescue mode)
  (initrd-modules . ("virtio_blk"))

  ;; EFI boot — standard for modern VPS providers.
  ;; If your provider uses BIOS boot, change to grub-bootloader.
  (bootloader     . ,(bootloader-configuration
                       (bootloader grub-efi-removable-bootloader)
                       (targets (list "/boot/efi"))
                       (terminal-outputs '(console))
                       (theme #f)))

  ;; Optional clearnet domain — set to #f for onion-only operation.
  ;; When set, machines.scm enables nginx HTTPS with a self-signed cert
  ;; (the CDN terminates TLS at the edge with its own cert, and pulls
  ;; from origin with SSL verification disabled). No Let's Encrypt, no
  ;; Certificate Transparency log exposure. Per docs/deploy/CLEARNET-FACES.md.
  (clearnet-domain    . #f)       ; e.g. "localchimera.earth" when ready

  ;; CDN edge IP allowlist — only these IPs reach the origin on 443; direct
  ;; IP access returns 444 (silent drop). Required with clearnet-domain:
  ;; the ranges your CDN publishes for its edges.
  ;; (cdn-edge-ips . ("1.2.3.0/24" "2001:db8::/48"))

  ;; The CDN account that fronts clearnet-domain. `adapter` names a module
  ;; under module/localchimera/fleet/cdn/; `credential` is the key's name in
  ;; secrets.scm. Drives the purge after each deploy, the no-cache rules
  ;; (deploy/scripts/cdn.scm), and fronting for fleet hosts that ask for it.
  ;; (cdn . ((adapter    . "NAME")
  ;;         (credential . "CDN_API_KEY")
  ;;         (zone       . "ZONE-ID")
  ;;         (origin     . "https://example.org")))

  ;; Tor obfs4 bridges. Set ONLY if the provider blocks direct connections
  ;; to Tor relay ORPorts — the symptom is: the box's .onion stops
  ;; resolving (and can't reach any other onion) while clearnet is fine, and
  ;; tor logs "No more HSDir available to query" / "tried for N seconds to
  ;; get a connection". Present ⇒ os.scm emits `UseBridges 1` + these lines;
  ;; absent ⇒ torrc is unchanged. These are SECRET (a committed bridge gets
  ;; scraped and blocked), which is why they live here, not in os.scm.
  ;; Fresh lines: https://bridges.torproject.org (Advanced → obfs4), or email
  ;; bridges@torproject.org with body "get transport obfs4".
  ;; (tor-bridges
  ;;  (list
  ;;   "obfs4 1.2.3.4:443 FINGERPRINT cert=BASE64CERT iat-mode=0"
  ;;   "obfs4 5.6.7.8:9001 FINGERPRINT cert=BASE64CERT iat-mode=0"))

  ;; Who runs this gateway — the controller the notices name, and where a
  ;; report, a data request or a vulnerability goes. Every field is optional
  ;; text and left out renders as a visibly unfilled placeholder in the
  ;; notices. abuse, privacy and security fall back to contact. An address
  ;; becomes mailto:, a URL (an https: page, an .onion) stands as written.
  ;; docs/legal/operator.md §2 says what each is for.
  ;; (operator . ((name . "Kreuzberg Commune e.V.")
  ;;              (contact . "contact@example.org")
  ;;              (abuse . "safety@example.org")
  ;;              (privacy . "privacy@example.org")
  ;;              (security . "security@example.org")
  ;;              (jurisdiction . "Berlin, Germany")
  ;;              (address . "…postal address, if you have one…")
  ;;              (supervisory . "Berliner Beauftragte für Datenschutz und Informationsfreiheit")
  ;;              (representative . "…Art 27 representative or DPO, if designated…")
  ;;              ;; where THIS deployment offers its source (AGPL §13) and its
  ;;              ;; live API docs; the upstream's when left out
  ;;              (source . "https://example.org/source")
  ;;              (docs . "https://example.org/api/docs")))
  ;; The relay this box hands its mail to. msmtp logs in on the submission
  ;; port and the relay delivers; the box reaches it through Tor, like all its
  ;; outbound traffic. `from` is the sender (the domain's DNS says the relay
  ;; may send for it: SPF, DKIM, DMARC); the account's password is
  ;; SMTP_PASSWORD in secrets.scm. With this set the commune offers email as
  ;; a channel a person may be notified on; without it, it offers none.
  ;; Port 587 is STARTTLS; 465 is TLS from the first byte. deploy/README.md §Mail.
  ;; (mail . ((host . "smtp.example.org")
  ;;          (port . 587)
  ;;          (user . "noreply@example.org")
  ;;          (from . "noreply@example.org")))

  ;; Radicle project ID. The radicle-ci hook watches this RID for ref
  ;; updates. Get it after `rad init`, or set LOCALCHIMERA_RID env var to
  ;; override per-deploy.
  (radicle-rid        . "rad:REPLACE_ME_AFTER_RAD_INIT")

  ;; Provider tag — published by localchimera-liveness in MQTT heartbeats so
  ;; the fleet rotor can mark a whole provider unhealthy when all its
  ;; hosts go silent. One of: "sporestack", "vpsbg", "flokinet", or
  ;; whatever you call this provider. Written declaratively to
  ;; /etc/localchimera/provider-tag at every reconfigure.
  (provider-tag       . "sporestack")

  ;; Hosting credentials the fleet on this box holds: the names they carry
  ;; in secrets.scm. Each is decrypted to /run/secrets at activation and
  ;; read into the gateway's environment at start, where the fleet registers
  ;; the provider whose key it finds. Omit for a box that provisions nothing.
  ;; (fleet-credentials  . ("SPORESTACK_TOKEN"))

  ;; KERI witnesses run on THIS host: alist of (name . port).
  ;; Omit for the canonical 6-witness default (wan/wil/wes/wit/wub/wyz
  ;; on 5642-5647). Sister fleet hosts in a geo-distributed pool set
  ;; this to a disjoint subset. See GOVERNANCE-CEREMONIES.md §2.4-§2.5.
  ;; (witnesses          . (("wit" . 5645) ("wub" . 5646) ("wyz" . 5647)))

  ;; Disk layout — check with: lsblk (in rescue mode)
  ;; Common layouts:
  ;;   /dev/vda1 root + /dev/vda15 EFI  (KVM/FlokiNET)
  ;;   /dev/sda1 root + /dev/sda15 EFI  (SCSI-based providers)
  (file-systems   . (,(file-system
                         (mount-point "/")
                         (device "/dev/vda1")
                         (type "ext4"))
                     ,(file-system
                         (mount-point "/boot/efi")
                         (device "/dev/vda15")
                         (type "vfat")))))
