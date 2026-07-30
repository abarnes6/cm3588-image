#!/usr/bin/env bash
# build-inner.sh — image engine, baked into the builder image. Stages:
# blobs -> U-Boot -> kernel .deb -> rootfs -> A/B image. Configuration comes
# from /build/pins.env and the layer list in $LAYERS (see README).

set -euo pipefail

JOBS="$(nproc)"
WORK=/build/work; OUT=/build/out
mkdir -p "$WORK" "$OUT"
export DEBIAN_FRONTEND=noninteractive

[ -f /build/pins.env ] || { echo "FATAL: /build/pins.env is missing" >&2; exit 1; }
source /build/pins.env

# The board axis: everything RK3588-generic lives in rk3588/ and base/;
# boards/$BOARD/ holds only what names the hardware.
BOARD_ENV="/build/boards/$BOARD/board.env"
[ -f "$BOARD_ENV" ] || { echo "FATAL: unknown BOARD '$BOARD' — no $BOARD_ENV" >&2; exit 1; }
source "$BOARD_ENV"
for v in UBOOT_DEFCONFIG UBOOT_DTSI DTB_PATH; do
  [ -n "${!v:-}" ] || { echo "FATAL: $v not set by $BOARD_ENV" >&2; exit 1; }
done

### ── layers ───────────────────────────────────────────────────────────────
# Each layer dir may contain files/ (synced into the image root, ownership
# normalised to root:root) and layer.sh (sourced here; may append to
# EXTRA_PACKAGES, EXTRA_APT_KEYS, EXTRA_MIRRORS, KERNEL_FRAGMENT_EXTRA and
# LAYER_HOOKS). Layers apply in list order, after the base hooks.
LAYERS="${LAYERS-}"
EXTRA_PACKAGES="" EXTRA_APT_KEYS="" EXTRA_MIRRORS="" KERNEL_FRAGMENT_EXTRA=""
LAYER_HOOKS=()
LAYER_MANIFEST=""
for layer in $LAYERS; do
  LAYER_DIR="/build/$layer"
  [ -d "$LAYER_DIR" ] || { echo "FATAL: layer '$layer' not found at $LAYER_DIR" >&2; exit 1; }
  if [ -d "$LAYER_DIR/files" ]; then
    LAYER_HOOKS+=("sync-in $LAYER_DIR/files /")
    # Scoped chown, NOT a blanket chown -R /etc (which would take /etc/shadow
    # off group "shadow").
    LAYER_HOOKS+=('cd '"$LAYER_DIR"'/files && find . -mindepth 1 -printf "%P\0" | (cd "$1" && xargs -0r chown root:root)')
  fi
  if [ -f "$LAYER_DIR/layer.sh" ]; then
    source "$LAYER_DIR/layer.sh"
    LAYER_MANIFEST="${LAYER_MANIFEST}layer        $layer $(sha256sum "$LAYER_DIR/layer.sh" | cut -d' ' -f1)"$'\n'
  else
    LAYER_MANIFEST="${LAYER_MANIFEST}layer        $layer files-only"$'\n'
  fi
done

# git_pin <dir> <url> <ref> — clone at <ref>, or move an existing clone to it.
# Movement is reported via a global: an && list would suppress set -e inside
# the function body.
GIT_PIN_MOVED=
git_pin() {
  local dir="$1" url="$2" ref="$3"
  GIT_PIN_MOVED=1
  if [ ! -d "$dir/.git" ]; then
    git clone --depth=1 -b "$ref" "$url" "$dir"
    return 0
  fi
  if [ "$(git -C "$dir" describe --tags --exact-match 2>/dev/null)" = "$ref" ]; then
    GIT_PIN_MOVED=
    return 0
  fi
  echo "pin moved: $(basename "$dir") -> $ref"
  git -C "$dir" fetch --depth=1 --force "$url" "refs/tags/$ref:refs/tags/$ref"
  git -C "$dir" checkout -f "$ref"
  git -C "$dir" clean -qfdx
}

# assert_config <fragment> <dotconfig> — merge_config -m silently drops
# unknown symbols and demotes values; check the EFFECTIVE result of every
# fragment line. A silently-dropped symbol here means an unbootable board.
assert_config() {
  local frag="$1" dot="$2" line sym
  while IFS= read -r line; do
    case "$line" in
      CONFIG_*=*)
        sym="${line%%=*}"
        grep -qxF "$line" "$dot" || {
          echo "FATAL: fragment line '$line' did not survive the merge." >&2
          echo "       effective: $(grep -E "^(${sym}=|# ${sym} is not set)" "$dot" \
                                    || echo "${sym} absent entirely")" >&2
          exit 1; } ;;
      "# CONFIG_"*" is not set")
        sym="${line#\# }"; sym="${sym%% *}"
        grep -q "^${sym}=" "$dot" && {
          echo "FATAL: '$line' requested, but merged config has" >&2
          echo "       $(grep "^${sym}=" "$dot")" >&2
          exit 1; } || true ;;
    esac
  done < "$frag"
}

### ── 1. blobs: rkbin TPL + mainline TF-A BL31 ─────────────────────────────
# rkbin is pinned by CONTENT (DDR_BLOB_SHA256), not revision: it has no tags
# and rewrites history.
if [ ! -d "$WORK/rkbin/.git" ]; then
  git clone --depth=1 --filter=blob:none --no-checkout \
    https://github.com/rockchip-linux/rkbin "$WORK/rkbin"
  git -C "$WORK/rkbin" sparse-checkout set --no-cone bin/rk35
  git -C "$WORK/rkbin" checkout
fi

if [ -n "${MAINLINE_ATF:-}" ]; then
  git_pin "$WORK/atf" https://github.com/ARM-software/arm-trusted-firmware "$ATF_TAG"
  if [ -n "$GIT_PIN_MOVED" ] || [ ! -s "$WORK/atf/build/rk3588/release/bl31/bl31.elf" ]; then
    make -C "$WORK/atf" CROSS_COMPILE=aarch64-linux-gnu- PLAT=rk3588 -j"$JOBS" bl31
  fi
  cp "$WORK/atf/build/rk3588/release/bl31/bl31.elf" "$WORK/rkbin/bin/rk35/bl31_mainline.elf"
  : "${BL31_BLOB:=bl31_mainline.elf}"
fi
: "${BL31_BLOB:=$(ls "$WORK"/rkbin/bin/rk35/rk3588_bl31_v*.elf | sort -V | tail -1)}"
DDR_BLOB="$WORK/rkbin/bin/rk35/$(basename "$DDR_BLOB")"
BL31_BLOB="$WORK/rkbin/bin/rk35/$(basename "$BL31_BLOB")"
[ -s "$DDR_BLOB" ]  || { echo "FATAL: DDR blob missing or empty: $DDR_BLOB" >&2; exit 1; }
[ -s "$BL31_BLOB" ] || { echo "FATAL: BL31 blob missing or empty: $BL31_BLOB" >&2; exit 1; }
if [ -n "${DDR_BLOB_SHA256:-}" ]; then
  echo "$DDR_BLOB_SHA256  $DDR_BLOB" | sha256sum -c - >/dev/null || {
    echo "FATAL: $DDR_BLOB does not match the pin in pins.env." >&2
    echo "  expected $DDR_BLOB_SHA256" >&2
    echo "  actual   $(sha256sum "$DDR_BLOB" | cut -d' ' -f1)" >&2
    echo "  rkbin rewrote the DRAM training blob. Boot-validate the new one," >&2
    echo "  then record its hash in pins.env — do not just delete this check." >&2
    exit 1; }
fi

### ── 2. mainline U-Boot: A/B slot selection ───────────────────────────────
git_pin "$WORK/u-boot" https://github.com/u-boot/u-boot "$UBOOT_TAG"
pushd "$WORK/u-boot"
# checkout-then-append so re-running does not stack duplicate nodes.
UB_DTSI="arch/arm/dts/$UBOOT_DTSI"
git checkout -- "$UB_DTSI"
cat /build/rk3588/bootstd-rauc.dtsi >> "$UB_DTSI"

make "$UBOOT_DEFCONFIG"
scripts/kconfig/merge_config.sh -m .config /build/rk3588/uboot.config
make CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
assert_config /build/rk3588/uboot.config .config
make CROSS_COMPILE=aarch64-linux-gnu- \
  ROCKCHIP_TPL="$DDR_BLOB" BL31="$BL31_BLOB" -j"$JOBS"

# boot.scr, built with the in-tree mkimage so it always matches U-Boot.
tools/mkimage -A arm64 -T script -C none -n "$BOARD A/B boot" \
  -d /build/rk3588/boot.cmd "$WORK/boot.scr"
popd
UBOOT_BIN="$WORK/u-boot/u-boot-rockchip.bin"

### ── 3. mainline kernel as a .deb ─────────────────────────────────────────
git_pin "$WORK/linux" \
  https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$KERNEL_TAG"
# Fragment order: common -> board quirks -> generated LOCALVERSION (names the
# .deb after the board) -> layer extras.
{ cat /build/rk3588/kernel.config
  [ ! -f "/build/boards/$BOARD/kernel.config" ] || cat "/build/boards/$BOARD/kernel.config"
  printf 'CONFIG_LOCALVERSION="-%s"\n' "$BOARD"
} > "$WORK/linux/board.config"
[ -n "${KERNEL_FRAGMENT_EXTRA:-}" ] && \
  printf '%s\n' "$KERNEL_FRAGMENT_EXTRA" >> "$WORK/linux/board.config"
# Rebuild gated on the INPUTS, not on "a .deb exists": the assertions below
# live inside this branch, so a stale .deb would also skip validation.
KSTAMP="$WORK/.kernel.stamp"
KWANT="$({ git -C "$WORK/linux" rev-parse HEAD; cat "$WORK/linux/board.config"; } \
         | sha256sum | cut -c1-16)"
if [ -n "${REBUILD_KERNEL:-}" ] || [ "$(cat "$KSTAMP" 2>/dev/null)" != "$KWANT" ] \
   || ! ls "$WORK"/linux-image-*"$BOARD"*.deb >/dev/null 2>&1; then
pushd "$WORK/linux"
rm -f "$WORK"/linux-image-*.deb "$WORK"/linux-libc-dev_*.deb \
      "$WORK"/linux-upstream_*.buildinfo "$WORK"/linux-upstream_*.changes
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
scripts/kconfig/merge_config.sh -m .config board.config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
assert_config board.config .config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  DEB_BUILD_PROFILES=pkg.linux-upstream.nokernelheaders \
  KDEB_CHANGELOG_DIST="$SUITE" bindeb-pkg -j"$JOBS"
popd
printf '%s\n' "$KWANT" > "$KSTAMP"
fi
KERNEL_DEB="$(ls -t "$WORK"/linux-image-*"$BOARD"*.deb | head -1)"
# plain grep, not -q: -q SIGPIPEs dpkg-deb and pipefail fails the pipeline
# precisely when the DTB IS present
dpkg -c "$KERNEL_DEB" | grep "$DTB_PATH" >/dev/null || {
  echo "FATAL: $DTB_PATH missing from $KERNEL_DEB" >&2; exit 1; }

### ── 4. rootfs: base packages + base hooks + layers ───────────────────────
PACKAGES="firmware-realtek,initramfs-tools,openssh-server,ca-certificates,cloud-guest-utils,systemd-resolved,systemd-timesyncd,pciutils,ethtool,nvme-cli,libubootenv-tool${EXTRA_PACKAGES:+,$EXTRA_PACKAGES}"

if [ -n "${ROOT_PASSWORD_HASH:-}" ]; then
  export ROOT_PW_ENTRY="root:$ROOT_PASSWORD_HASH" ROOT_PW_FLAG=-e
else
  export ROOT_PW_ENTRY="root:$ROOT_PASSWORD" ROOT_PW_FLAG=
fi

# The RTL8125 has no burned-in MAC; pin a stable locally-administered address
# derived from the hostname so the DHCP identity survives A/B updates. A layer
# can overwrite 10-persistent-mac.link with a real deployment's pin.
MAC_HASH="$(printf '%s' "$HOSTNAME_TGT" | sha256sum)"
BASE_MAC="$(printf '%02x:%s:%s:%s:%s:%s' \
  $(( (16#${MAC_HASH:0:2} & 16#fe) | 16#02 )) \
  "${MAC_HASH:2:2}" "${MAC_HASH:4:2}" "${MAC_HASH:6:2}" "${MAC_HASH:8:2}" "${MAC_HASH:10:2}")"

HOOKS=(
  'echo '"$HOSTNAME_TGT"' > "$1/etc/hostname"'
  # Without this the box cannot resolve its own name (nsswitch has no
  # myhostname).
  'printf "127.0.1.1\t%s\n" '"$HOSTNAME_TGT"' >> "$1/etc/hosts"'
  # NO "/" entry: the same image goes to both slots, so any root identifier
  # would name the wrong slot half the time. persist IS shared, so PARTLABEL
  # is safe.
  'printf "%s\n" "PARTLABEL=persist /persist ext4 defaults,nofail,x-systemd.device-timeout=30 0 2" > "$1/etc/fstab"'
  # EMPTY machine-id = "not a first boot" (machine-id(5) rule 4); also
  # permanently disables ConditionFirstBoot — hence the sshd-keygen drop-in.
  ': > "$1/etc/machine-id"'
  # A matching .link REPLACES 99-default.link outright, so NamePolicy must be
  # restated.
  'mkdir -p "$1/etc/systemd/network" && printf "%s\n" "# Generated by build-inner.sh: stable MAC so the DHCP identity survives A/B updates." "[Match]" "Driver=r8169" "" "[Link]" "NamePolicy=keep kernel database onboard slot path" "AlternativeNamesPolicy=database onboard slot path" "MACAddress='"$BASE_MAC"'" > "$1/etc/systemd/network/10-persistent-mac.link"'
  'sync-in /build/base /'
  # Scoped chown — see the layer loop above.
  'cd /build/base && find . -mindepth 1 -printf "%P\0" | (cd "$1" && xargs -0r chown root:root)'
  # networkd is not enabled by any postinst, and the empty machine-id
  # suppresses first-boot preset-all: without this line the image has no
  # network at all.
  'chroot "$1" systemctl enable systemd-networkd.service grow-persist.service persist-setup.service slot-mark-good.service'
  # Symlink, not a mount unit (which deadlocks against local-fs.target); it
  # dangles until persist-setup creates the target and re-flushes.
  'rm -rf "$1/var/log/journal" && ln -sfn /persist/journal "$1/var/log/journal"'
  # Credentials are BASE, not layer: a layer-less image must still be
  # reachable. Serial-console password only; ssh stays key-only. Passed via
  # the environment so it never appears in a process argument list.
  'printf "%s\n" "$ROOT_PW_ENTRY" | chroot "$1" chpasswd $ROOT_PW_FLAG'
  '[ -z "${SSH_PUBKEY:-}" ] || { mkdir -p "$1/root/.ssh" && printf "%s\n" "$SSH_PUBKEY" > "$1/root/.ssh/authorized_keys" && chmod 700 "$1/root/.ssh" && chmod 600 "$1/root/.ssh/authorized_keys"; }'
  "${LAYER_HOOKS[@]}"
  # ── LATE hooks, after every layer ──
  # Host keys are regenerated per board by sshd-keygen; the drop-in resets
  # ConditionFirstBoot (permanently false here) and re-gates on key absence.
  'rm -f "$1"/etc/ssh/ssh_host_*'
  'mkdir -p "$1/etc/systemd/system/sshd-keygen.service.d" && printf "%s\n" "[Unit]" "ConditionFirstBoot=" "ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key" > "$1/etc/systemd/system/sshd-keygen.service.d/always.conf"'
  # Last: resolv.conf becomes a dangling-in-chroot symlink, so any hook
  # needing DNS must already have run.
  'ln -sf /run/systemd/resolve/stub-resolv.conf "$1/etc/resolv.conf"'
)
HOOK_ARGS=(); for h in "${HOOKS[@]}"; do HOOK_ARGS+=("--customize-hook=$h"); done

# Third-party apt repos. Keyrings must be in place before apt runs (setup
# hooks), so EXTRA_PACKAGES can name third-party packages and apt resolves
# them normally.
#   EXTRA_APT_KEYS  "<name> <url>" per line -> /etc/apt/keyrings/<name>.gpg
#   EXTRA_MIRRORS   one apt one-line source per line
KEY_HOOKS=()
if [ -n "${EXTRA_APT_KEYS:-}" ]; then
  mkdir -p "$WORK/keys"
  while read -r name url; do
    [ -n "$name" ] || continue
    f="$WORK/keys/$name.gpg"
    if [ ! -s "$f" ]; then
      echo "fetching apt key: $name"
      # temp + rename: a mid-stream curl failure must not leave a partial key
      # that the -s check above would accept on the next run.
      curl -fsSL --retry 3 "$url" | gpg --batch --yes --dearmor -o "$f.tmp"
      mv "$f.tmp" "$f"
    fi
    [ -s "$f" ] || { echo "FATAL: apt key $name empty; fetch from $url failed" >&2; exit 1; }
  done <<< "$EXTRA_APT_KEYS"
  # Two copies, both needed: mmdebstrap resolves signed-by against the BUILDER
  # for the initial apt-get update; the chroot copy serves later upgrades.
  mkdir -p /etc/apt/keyrings
  cp "$WORK"/keys/*.gpg /etc/apt/keyrings/
  KEY_HOOKS+=(--setup-hook='mkdir -p "$1"/etc/apt/keyrings')
  KEY_HOOKS+=(--setup-hook="sync-in $WORK/keys /etc/apt/keyrings")
fi

# Mirrors are spelled out: a bare positional mirror would suppress
# mmdebstrap's automatic -updates/-security entries.
MIRRORS=(
  "deb $MIRROR $SUITE main non-free-firmware"
  "deb $MIRROR $SUITE-updates main non-free-firmware"
  "deb http://security.debian.org/debian-security $SUITE-security main non-free-firmware"
)
if [ -n "${EXTRA_MIRRORS:-}" ]; then
  while IFS= read -r m; do [ -n "$m" ] && MIRRORS+=("$m"); done <<< "$EXTRA_MIRRORS"
fi

ROOTDIR="$WORK/rootfs"
APTCACHE="$WORK/aptcache"
rm -rf "$ROOTDIR"
mkdir -p "$APTCACHE"
mmdebstrap --arch=arm64 --components=main,non-free-firmware \
  --include="$PACKAGES" \
  --setup-hook='mkdir -p "$1"/var/cache/apt/archives/' \
  --setup-hook="sync-in $APTCACHE /var/cache/apt/archives/" \
  "${KEY_HOOKS[@]}" \
  "${HOOK_ARGS[@]}" \
  --customize-hook="copy-in $KERNEL_DEB /tmp" \
  --customize-hook='chroot "$1" sh -c "dpkg -i /tmp/linux-image-*.deb && rm -f /tmp/linux-image-*.deb"' \
  --customize-hook="copy-in $WORK/boot.scr /boot" \
  --customize-hook='cd "$1/boot" && ln -sfn "$(ls -1 vmlinuz-* | head -1)" vmlinuz' \
  --customize-hook='cd "$1/boot" && ln -sfn "$(ls -1 initrd.img-* | head -1)" initrd.img' \
  --customize-hook='ln -sfn "../usr/lib/$(basename "$(ls -1d "$1"/usr/lib/linux-image-* | head -1)")/'"$DTB_PATH"'" "$1/boot/dtb"' \
  --customize-hook="find \"\$1\"/usr/lib/linux-image-*/ -name '*.dtb' ! -path '*/$DTB_PATH' -delete" \
  --customize-hook='find "$1"/usr/lib/linux-image-*/ -depth -type d -empty -delete' \
  --customize-hook="sync-out /var/cache/apt/archives $APTCACHE" \
  "$SUITE" "$ROOTDIR" "${MIRRORS[@]}"

### ── boot-sanity assertions: a wrong answer here is an unbootable image ────
[ -s "$ROOTDIR/boot/boot.scr" ] || {
  echo "FATAL: /boot/boot.scr missing — U-Boot's RAUC bootmeth has nothing to run" >&2
  exit 1; }
for f in vmlinuz initrd.img dtb; do
  [ -s "$ROOTDIR/boot/$f" ] || {
    echo "FATAL: /boot/$f missing or dangling (-> $(readlink "$ROOTDIR/boot/$f" 2>/dev/null))" >&2
    exit 1; }
done
grep -q "$SUITE-security" "$ROOTDIR/etc/apt/sources.list" || {
  echo "FATAL: no $SUITE-security in sources.list — image has no security feed" >&2; exit 1; }
[ -e "$ROOTDIR/etc/ssh/ssh_host_ed25519_key" ] && {
  echo "FATAL: ssh host keys present in the golden image" >&2; exit 1; } || true
# Field 2 is the mount point; any device spelling with "/" there must be
# caught.
awk '$1 !~ /^#/ && $2 == "/"' "$ROOTDIR/etc/fstab" | grep -q . && {
  echo "FATAL: /etc/fstab names a root device; the image must be slot-agnostic" >&2
  exit 1; } || true
echo "rootfs OK: boot.scr + vmlinuz/initrd.img/dtb resolve, security-suite=yes," \
     "host-keys=absent, fstab slot-agnostic"

### ── 5. assemble image without mounting anything ──────────────────────────
STAMP="$(date -u +%Y%m%d-%H%M%S)"
IMG="$OUT/$BOARD-$SUITE-$STAMP.img"
rm -f "$IMG" "$IMG.gz"

# A/B geometry is FIXED: an update writes a whole filesystem image into a
# slot, so slots must be identical and must not move between builds.
ROOTFS_MB="$(du -sm "$ROOTDIR" | cut -f1)"
FS_MIN_MB=$(( ROOTFS_MB + ROOTFS_MB / 8 + 64 ))
[ "$ROOTFS_SIZE_MB" -ge "$FS_MIN_MB" ] || {
  echo "FATAL: ROOTFS_SIZE_MB=$ROOTFS_SIZE_MB is too small for a ${ROOTFS_MB}M rootfs" >&2
  echo "       (needs at least ${FS_MIN_MB}M including ext4 overhead)" >&2
  exit 1; }
[ "$SLOT_SIZE_MB" -ge "$ROOTFS_SIZE_MB" ] || {
  echo "FATAL: SLOT_SIZE_MB=$SLOT_SIZE_MB is smaller than ROOTFS_SIZE_MB=$ROOTFS_SIZE_MB" >&2
  exit 1; }
IMG_SIZE_MB=$(( 16 + 2 * SLOT_SIZE_MB + PERSIST_SIZE_MB ))
echo "A/B image: rootfs ${ROOTFS_MB}M in a ${ROOTFS_SIZE_MB}M fs, slots ${SLOT_SIZE_MB}M x2," \
     "persist ${PERSIST_SIZE_MB}M+grow -> ${IMG_SIZE_MB}M"

# The loader must fit below the U-Boot environment at 13 MiB (ENV_OFFSET in
# rk3588/uboot.config), or it would silently overwrite the A/B slot state.
UBOOT_MAX=$(( 13 * 1024 * 1024 - 64 * 512 ))
UBOOT_SZ="$(stat -c%s "$UBOOT_BIN")"
[ "$UBOOT_SZ" -le "$UBOOT_MAX" ] || {
  echo "FATAL: $UBOOT_BIN is $UBOOT_SZ bytes; only $UBOOT_MAX fit before the" >&2
  echo "       partition at LBA 32768. Move the partition start." >&2; exit 1; }

SLOT_SECTORS=$(( SLOT_SIZE_MB * 2048 ))
truncate -s "${IMG_SIZE_MB}M" "$IMG"
# first-lba keeps the loader and both env copies out of the GPT's "free
# space" so partitioning tools cannot allocate over them.
sfdisk -q "$IMG" <<EOF
label: gpt
first-lba: 32768
start=32768,        size=$SLOT_SECTORS, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=rootA
                    size=$SLOT_SECTORS, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=rootB
                                        type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=persist
EOF
SLOT_BLOCKS=$(( $(partx -g -b -o SIZE -s --nr 1 "$IMG") / 512 / 8 ))
PERSIST_START=$(partx -g -b -o START -s --nr 3 "$IMG")
PERSIST_BLOCKS=$(( $(partx -g -b -o SIZE -s --nr 3 "$IMG") / 512 / 8 ))
[ "${SLOT_BLOCKS:-0}" -gt 0 ] && [ "${PERSIST_BLOCKS:-0}" -gt 0 ] \
  || { echo "FATAL: could not read partition geometry back" >&2; exit 1; }

# The slot filesystem is a deliverable: the same bytes are dd'd into slot A
# and shipped as the slotctl update payload. -b 4096 is mandatory (block size
# cannot be changed later); no -L (slots are found by PARTLABEL); sized to
# ROOTFS_SIZE_MB, not the slot, so updates write/verify only what exists.
ROOTFS_BLOCKS=$(( ROOTFS_SIZE_MB * 256 ))
[ "$ROOTFS_BLOCKS" -le "$SLOT_BLOCKS" ] || {
  echo "FATAL: rootfs filesystem does not fit the slot partition" >&2; exit 1; }
SLOT_IMG="$WORK/rootfs.ext4"
rm -f "$SLOT_IMG"
truncate -s $(( ROOTFS_BLOCKS * 4096 )) "$SLOT_IMG"
mke2fs -q -F -t ext4 -b 4096 -m 1 -d "$ROOTDIR" "$SLOT_IMG" "$ROOTFS_BLOCKS"

# Slot B stays a hole: it compresses to nothing and is written by the first
# slotctl update.
dd if="$SLOT_IMG" of="$IMG" bs=1M seek=16 conv=notrunc,sparse status=none
mke2fs -q -F -t ext4 -b 4096 -m 0 -L persist \
  -E "offset=$(( PERSIST_START * 512 ))" "$IMG" "$PERSIST_BLOCKS"

dd if="$UBOOT_BIN" of="$IMG" bs=512 seek=64 conv=notrunc status=none

# Compress to a temp name: gzip unlinks its input on success, and an
# interrupted run must not leave a truncated .img.gz under the canonical name.
COMPRESS=gzip; command -v pigz >/dev/null && COMPRESS=pigz
"$COMPRESS" -9 -n -c "$IMG" > "$IMG.gz.tmp"
mv "$IMG.gz.tmp" "$IMG.gz"
rm -f "$IMG"
sha256sum "$IMG.gz" | sed "s|$OUT/||" > "$IMG.gz.sha256"
ln -sfn "$(basename "$IMG.gz")" "$OUT/$BOARD-$SUITE-latest.img.gz"

# The slot payload, shipped separately for slotctl update.
ROOTFS_GZ="$OUT/$BOARD-$SUITE-$STAMP.rootfs.img.gz"
"$COMPRESS" -9 -n -c "$SLOT_IMG" > "$ROOTFS_GZ.tmp"
mv "$ROOTFS_GZ.tmp" "$ROOTFS_GZ"
sha256sum "$ROOTFS_GZ" | sed "s|$OUT/||" > "$ROOTFS_GZ.sha256"
ln -sfn "$(basename "$ROOTFS_GZ")" "$OUT/$BOARD-$SUITE-latest.rootfs.img.gz"

# The loader by itself, for slotctl update-loader's in-place write at sector 64.
# The full image already contains these bytes; this is the OTA-able copy.
UBOOT_GZ="$OUT/$BOARD-$SUITE-$STAMP.uboot.bin.gz"
"$COMPRESS" -9 -n -c "$UBOOT_BIN" > "$UBOOT_GZ.tmp"
mv "$UBOOT_GZ.tmp" "$UBOOT_GZ"
sha256sum "$UBOOT_GZ" | sed "s|$OUT/||" > "$UBOOT_GZ.sha256"
ln -sfn "$(basename "$UBOOT_GZ")" "$OUT/$BOARD-$SUITE-latest.uboot.bin.gz"

cat > "$IMG.manifest" <<MANIFEST
image        $(basename "$IMG.gz")
sha256       $(cut -d' ' -f1 < "$IMG.gz.sha256")
built_utc    $(date -u +%FT%TZ)
board        $BOARD (dtb $DTB_PATH, defconfig $UBOOT_DEFCONFIG)
suite        $SUITE ($MIRROR)
geometry     img=${IMG_SIZE_MB}M slots=2x${SLOT_SIZE_MB}M fs=${ROOTFS_SIZE_MB}M persist=${PERSIST_SIZE_MB}M+grow
rootfs_img   $(basename "$ROOTFS_GZ")
rootfs_sha   $(cut -d' ' -f1 < "$ROOTFS_GZ.sha256")
uboot_env    0xD00000 + 0xD80000 (redundant), BOOT_ORDER="A B", tries=3
kernel       $KERNEL_TAG $(git -C "$WORK/linux" rev-parse HEAD) $(basename "$KERNEL_DEB")
kernel_cfg   $(sha256sum "$WORK/linux/.config" | cut -d' ' -f1)
u-boot       $UBOOT_TAG $(git -C "$WORK/u-boot" rev-parse HEAD)
u-boot_bin   $UBOOT_SZ bytes $(sha256sum "$UBOOT_BIN" | cut -d' ' -f1)
uboot_img    $(basename "$UBOOT_GZ") $(cut -d' ' -f1 < "$UBOOT_GZ.sha256")
atf          ${MAINLINE_ATF:+$ATF_TAG }$(git -C "$WORK/atf" rev-parse HEAD 2>/dev/null || echo n/a)
bl31         $(basename "$BL31_BLOB") $(sha256sum "$BL31_BLOB" | cut -d' ' -f1)
ddr          $(basename "$DDR_BLOB") $(sha256sum "$DDR_BLOB" | cut -d' ' -f1)
rkbin        $(git -C "$WORK/rkbin" rev-parse HEAD)
layers       ${LAYERS:-none}
MANIFEST
printf '%s' "$LAYER_MANIFEST" >> "$IMG.manifest"
dpkg-query --admindir="$ROOTDIR/var/lib/dpkg" -W -f='${Package} ${Version}\n' \
  2>/dev/null | sort >> "$IMG.manifest" || true

echo "DONE: ${IMG}.gz"
echo "      $(cut -d' ' -f1 < "$IMG.gz.sha256")"
echo "      manifest: $IMG.manifest"
