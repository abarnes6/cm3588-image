#!/usr/bin/env bash
# Host side: one-command A/B update of a running board.
#
#   ./deploy.sh                              # newest rootfs build in out/
#   ./deploy.sh out/<stamp>.rootfs.img.gz    # a specific build
#
# DEPLOY_HOST (env, or the gitignored deploy.env) names the target, e.g.
# root@10.13. The payload streams to /persist, `slotctl update` installs it
# into the inactive slot (sha-verified before writing, read back from the
# media after), the board reboots, and this script watches the trial: exit 0
# once the new slot is marked good, 1 if the board rolled back to the old
# slot. Nothing here modifies the running slot, so a failure leaves the
# board exactly as it was.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SELF_DIR"
. pins.env
[ ! -f deploy.env ] || . deploy.env
: "${DEPLOY_HOST:?set DEPLOY_HOST (env or deploy.env), e.g. DEPLOY_HOST=root@10.13}"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5)

# -latest resolves to the stamped file so the matching .sha256 is found.
IMG="${1:-out/$BOARD-$SUITE-latest.rootfs.img.gz}"
[ -e "$IMG" ] || { echo "FATAL: $IMG not found — run ./build.sh first" >&2; exit 1; }
IMG="$(realpath "$IMG")"
[ -s "$IMG.sha256" ] || { echo "FATAL: $IMG.sha256 missing; refusing an unverified deploy" >&2; exit 1; }
SHA="$(cut -d' ' -f1 "$IMG.sha256")"

# One sample of the slot state: "<slot> <trial>", trial "-" when unset.
# Fails while the board is unreachable (mid-reboot), so callers guard it.
slot_state() {
  "${SSH[@]}" "$DEPLOY_HOST" \
    'printf "%s %s\n" \
       "$(sed -n "s/.*rauc\.slot=\([A-Za-z0-9]*\).*/\1/p" /proc/cmdline)" \
       "$(fw_printenv -n BOOT_TRIAL 2>/dev/null | grep . || echo -)"' 2>/dev/null
}

STATE="$(slot_state)" || { echo "FATAL: cannot reach $DEPLOY_HOST" >&2; exit 1; }
read -r CUR TRIAL <<<"$STATE"
case "$CUR" in
  A) TARGET=B ;;
  B) TARGET=A ;;
  *) echo "FATAL: $DEPLOY_HOST reports slot '$CUR' — not an A/B system?" >&2; exit 1 ;;
esac
[ "$TRIAL" = "-" ] || {
  echo "FATAL: slot $TRIAL is mid-trial on $DEPLOY_HOST; conclude it (reboot," >&2
  echo "       or wait for mark-good) before deploying again." >&2
  exit 1; }

REMOTE_IMG="/persist/$(basename "$IMG")"
echo "deploying $(basename "$IMG") to $DEPLOY_HOST: slot $CUR -> $TARGET"
"${SSH[@]}" "$DEPLOY_HOST" "cat > '$REMOTE_IMG'" < "$IMG"
# The payload is spent once slotctl has verified and written it; remove it
# either way — a failed update is retried from the build host, not the board.
"${SSH[@]}" "$DEPLOY_HOST" "slotctl update '$REMOTE_IMG' '$SHA'; rc=\$?; rm -f '$REMOTE_IMG'; exit \$rc"

echo "rebooting $DEPLOY_HOST ..."
"${SSH[@]}" "$DEPLOY_HOST" 'systemctl reboot' || true

# Watch the trial. The samples are unambiguous:
#   slot=$TARGET trial=-        mark-good ran on the new slot: success
#   slot=$TARGET trial=$TARGET  new slot is up, mark-good still polling
#   slot=$CUR    trial=$TARGET  shutting down, or U-Boot retrying the new slot
#   slot=$CUR    trial=-        tries drained, mark-good reran on the old
#                               slot and cleared the flag: rolled back
# The deadline outlasts the worst case, tries x (boot + mark-good's 120 s).
DEADLINE=$(( $(date +%s) + 900 ))
while :; do
  if STATE="$(slot_state)"; then
    read -r SLOT TRIAL <<<"$STATE"
    case "$SLOT $TRIAL" in
      "$TARGET -")
        echo "slot $TARGET is up and marked good:"
        "${SSH[@]}" "$DEPLOY_HOST" 'slotctl status'
        exit 0 ;;
      "$CUR -")
        echo "FATAL: board rolled back — slot $TARGET failed its trial; slot $CUR is running." >&2
        echo "       journalctl -u slot-mark-good on the board has the health verdict;" >&2
        echo "       boot failures before that are only on the serial console." >&2
        exit 1 ;;
    esac
  fi
  [ "$(date +%s)" -lt "$DEADLINE" ] || {
    echo "FATAL: no verdict after 15 min; check the serial console." >&2; exit 1; }
  sleep 5
done
