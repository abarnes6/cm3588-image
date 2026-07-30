# layers/nas/layer.sh — the author's NAS deployment, kept as a worked example:
# Plex + qBittorrent-behind-WireGuard + NFS on a 4x NVMe md raid0. Static
# files live in files/ (synced in automatically); this script adds packages,
# repos, kernel config, and hooks that must RUN in the chroot. Replace the
# measured values (array UUIDs, MAC, subnets) with your own.
#
# Operator notes for this deployment:
#  * WireGuard confs are parsed by `wg setconf`, NOT wg-quick: strip Address=,
#    DNS=, MTU=, Post* (see files/usr/local/share/wg0.conf.template).
#  * Align uids on the array BEFORE first boot, services stopped:
#      chown -R 951:951 /srv/nfs/data/plex-appdata
#      chown -R 950:950 /srv/nfs/data/qbt-appdata
#    Leave wireguard/ at root:root 0700 — qbt must not read the private key.
#  * After first boot: append `mdadm --detail --scan` output to
#    /etc/mdadm/mdadm.conf, restore /etc/exports, and set qBittorrent WebUI
#    credentials in /etc/wireguard/qbt-webui.creds (WEBUI_USER=/WEBUI_PASS=)
#    — behind the MASQUERADE the subnet whitelist cannot authenticate anyone.

# Plex from its own repo, resolved by apt like anything else; it must be in
# the image because an A/B update replaces the whole slot.
EXTRA_APT_KEYS="$EXTRA_APT_KEYS
plexmediaserver.v2 https://downloads.plex.tv/plex-keys/PlexSign.v2.key"
EXTRA_MIRRORS="$EXTRA_MIRRORS
deb [signed-by=/etc/apt/keyrings/plexmediaserver.v2.gpg] https://repo.plex.tv/deb/ public main"

# curl is a runtime dep of proton-portfw.sh; msmtp-mta + bsd-mailx make
# smartd's notifications deliverable at all.
EXTRA_PACKAGES="${EXTRA_PACKAGES:+$EXTRA_PACKAGES,}mdadm,nfs-kernel-server,curl,gnupg2,qbittorrent-nox,wireguard-tools,iptables,smartmontools,natpmpc,msmtp-mta,bsd-mailx,plexmediaserver"

# Lines restating an arm64 default are deliberate: assert_config then enforces
# the value this box needs on every kernel bump.
KERNEL_FRAGMENT_EXTRA="$KERNEL_FRAGMENT_EXTRA
# 4x NVMe md raid0 exported over NFS
CONFIG_BLK_DEV_MD=y
CONFIG_MD_RAID0=y
CONFIG_NFSD=m
CONFIG_NFSD_V4=y
# qbt netns kill-switch: wireguard, veth, nftables (trixie's iptables is the
# nft frontend; NFT_COMPAT is what translates qbt-netns's rules)
CONFIG_WIREGUARD=m
CONFIG_VETH=m
CONFIG_NF_TABLES=m
CONFIG_NF_TABLES_INET=y
CONFIG_NFT_COMPAT=m
CONFIG_NFT_NAT=m
CONFIG_NF_NAT=m
CONFIG_NETFILTER_XT_NAT=m
CONFIG_NETFILTER_XT_TARGET_MASQUERADE=m
CONFIG_NF_CONNTRACK=m
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=m"

LAYER_HOOKS+=(
  # Plex's preinst decides "is this systemd?" from /proc/1/comm — in the build
  # chroot that is the container's pid 1, so its postinst silently skips
  # installing the unit and creating the account. Do both here.
  '[ -s "$1/usr/lib/plexmediaserver/lib/plexmediaserver.service" ] || { echo "FATAL: plexmediaserver did not install" >&2; exit 1; }'
  'install -m0644 "$1/usr/lib/plexmediaserver/lib/plexmediaserver.service" "$1/usr/lib/systemd/system/plexmediaserver.service"'
  'chroot "$1" systemctl enable plexmediaserver.service'
  # Pinned uid/gid: appdata lives on the array and outlives the image.
  'chroot "$1" sh -c "getent group plex >/dev/null || addgroup --system --gid 951 plex"'
  'chroot "$1" sh -c "getent passwd plex >/dev/null || adduser --system --uid 951 --gid 951 --home /var/lib/plexmediaserver --no-create-home plex"'
  'grep -q "^plex:[^:]*:951:951:" "$1/etc/passwd" || { echo "FATAL: plex is not uid/gid 951:951 — $(grep "^plex:" "$1/etc/passwd")" >&2; exit 1; }'
  'chroot "$1" sh -c "mkdir -p /var/lib/plexmediaserver && chown -R plex:plex /var/lib/plexmediaserver"'

  # Array + mount, from measured values (blkid / mdadm --detail --scan).
  # nofail: the box boots without the array; services that need it are gated
  # individually with RequiresMountsFor.
  'mkdir -p "$1/etc/mdadm" && echo "ARRAY /dev/md0 metadata=1.2 UUID=43376ce8:1334901f:41d9b115:713892f3" >> "$1/etc/mdadm/mdadm.conf"'
  'echo "UUID=9edd22cd-d995-4029-92f6-15ba332390ea /srv/nfs/data ext4 defaults,nofail,x-systemd.device-timeout=30 0 2" >> "$1/etc/fstab" && mkdir -p "$1/srv/nfs/data"'

  # qbt, pinned uid/gid; the group is created separately or adduser lets the
  # GID float even with the UID pinned.
  'chroot "$1" addgroup --system --gid 950 qbt'
  'chroot "$1" adduser --system --uid 950 --gid 950 --home /nonexistent --no-create-home qbt'
  # Keys stay on the array behind this symlink; the archived image holds no
  # secrets.
  'rm -rf "$1/etc/wireguard" && ln -s /srv/nfs/data/wireguard "$1/etc/wireguard"'
  'chroot "$1" systemctl enable qbt-netns.service qbittorrent-nox.service qbt-portfw.timer qbt-wg-select.timer'
)
