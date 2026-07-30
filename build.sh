#!/usr/bin/env bash
# Host side: prechecks, podman build + run. All build logic is in
# build-inner.sh; pins in pins.env; customization in layers (see README).
#
#   ./build.sh                                  # default layers
#   LAYERS="" ./build.sh                        # bare base image
#   LAYERS="layers/nas /path/to/mine" ./build.sh
#
# Any pins.env knob can be overridden per run: KERNEL_TAG=v7.2 ./build.sh

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-localhost/rk3588-builder}"
LAYERS="${LAYERS-layers/nas}"

# qemu-aarch64 binfmt must be registered, enabled, and have the F flag
# (interpreter held open at registration, so it works inside the container).
BINFMT=/proc/sys/fs/binfmt_misc/qemu-aarch64
if ! grep -qs '^flags:.*F' "$BINFMT" 2>/dev/null || \
   ! grep -qs '^enabled' "$BINFMT" 2>/dev/null; then
  echo "FATAL: qemu-aarch64 binfmt handler missing, disabled, or lacks the F flag." >&2
  echo "Fedora: sudo dnf install qemu-user-static  (then re-run)" >&2
  echo "Check:  cat $BINFMT" >&2
  exit 1
fi

if [ -z "${SSH_PUBKEY:-}" ]; then
  if [ -n "${SSH_PUBKEY_FILE:-}" ]; then
    SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"
  else
    for f in "$HOME"/.ssh/id_ed25519.pub "$HOME"/.ssh/id_ecdsa.pub "$HOME"/.ssh/id_rsa.pub; do
      [ -r "$f" ] || continue
      SSH_PUBKEY="$(cat "$f")"; echo "using ssh pubkey $f" >&2; break
    done
  fi
fi
if [ -z "${SSH_PUBKEY:-}" ] && [ -z "${ALLOW_NO_SSH_KEY:-}" ]; then
  echo "FATAL: no ssh pubkey found; the image would be reachable only over serial." >&2
  echo "       Set SSH_PUBKEY_FILE=/path/to/key.pub, or ALLOW_NO_SSH_KEY=1." >&2
  exit 1
fi
export SSH_PUBKEY="${SSH_PUBKEY:-}"

# Layers: relative paths live in the repo; absolute paths get their own bind
# mount so a personal layer can live in its own repo.
LAYER_MOUNTS=()
CTR_LAYERS=""
i=0
for l in $LAYERS; do
  case "$l" in
    /*)
      [ -d "$l" ] || { echo "FATAL: layer directory $l not found" >&2; exit 1; }
      LAYER_MOUNTS+=(-v "$l:/build/layers.d/$i:Z")
      CTR_LAYERS="$CTR_LAYERS layers.d/$i"
      i=$((i + 1)) ;;
    *)
      [ -d "$SELF_DIR/$l" ] || { echo "FATAL: layer directory $l not found in $SELF_DIR" >&2; exit 1; }
      CTR_LAYERS="$CTR_LAYERS $l" ;;
  esac
done
export LAYERS="${CTR_LAYERS# }"

podman build -t "$IMAGE" -f "$SELF_DIR/Dockerfile" "$SELF_DIR"

# --privileged: mmdebstrap needs mknod + chroot. --network=host: throughput
# only. An unset host variable stays unset in the container, so pins.env's
# ${VAR:=default} still wins for anything not exported here.
exec podman run --rm \
  -e SSH_PUBKEY -e REBUILD_KERNEL -e LAYERS \
  -e KERNEL_TAG -e UBOOT_TAG -e ATF_TAG \
  -e DDR_BLOB -e DDR_BLOB_SHA256 -e BL31_BLOB -e MAINLINE_ATF \
  -e BOARD -e UBOOT_DEFCONFIG -e UBOOT_DTSI -e DTB_PATH \
  -e SUITE -e MIRROR -e HOSTNAME_TGT \
  -e SLOT_SIZE_MB -e ROOTFS_SIZE_MB -e PERSIST_SIZE_MB \
  -e ROOT_PASSWORD -e ROOT_PASSWORD_HASH \
  "${LAYER_MOUNTS[@]}" \
  --privileged --network=host \
  -v "$SELF_DIR:/build:Z" \
  "$IMAGE"
