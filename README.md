# RK3588 A/B Debian image builder

Builds a bootable Debian image for Rockchip RK3588 boards from scratch
(default board: the FriendlyELEC CM3588 Plus NAS). The image has two
root slots with **automatic rollback**: updates are written to the inactive
slot and U-Boot's RAUC bootmeth falls back by itself if the new slot doesn't
prove itself healthy.

## Requirements

- Linux host with `podman` and `qemu-user-static` registered with the binfmt
  **F** flag (`build.sh` checks and tells you how to fix it). Everything else
  runs inside the builder container.
- ~10 GB free under `work/` (source clones, apt cache) plus the images in
  `out/` (~17 GB uncompressed each, ~0.3 GB compressed).
- First build compiles TF-A, U-Boot, and the kernel: expect 30–60 minutes.
  Rebuilds with unchanged pins take a few minutes.
- An SD card of 32 GB or more for the default geometry (the image is
  ~16.3 GiB; shrink `SLOT_SIZE_MB` / `PERSIST_SIZE_MB` in `pins.env` if you
  want it smaller — persist grows to fill the card on first boot anyway).

## Quick start

```bash
LAYERS="" ./build.sh        # bare base image: boots, DHCPs, runs sshd
./build.sh                  # default: the example NAS layer (see below)
```

`build.sh` picks up your ssh public key (`~/.ssh/id_*.pub`, or set
`SSH_PUBKEY_FILE=`) and bakes it in for root. The serial-console root password
defaults to `changeme-on-first-login` — set `ROOT_PASSWORD_HASH` (from
`openssl passwd -6`) for anything you keep. Root over ssh is key-only.

Write the image to an SD card and boot from it:

```bash
zcat out/cm3588-trixie-latest.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

On first boot, confirm on serial that the A/B machinery is live:

```
cat /proc/cmdline          # -> ... rauc.slot=A
slotctl status             # slot, boot order, tries, trial
systemctl status slot-mark-good   # health check that arms rollback
```

To move to the on-board eMMC, run `flash-emmc <image.img.gz>` from the
SD-booted system — it auto-detects the eMMC, verifies the whole write by
sha256 read back from the media, and randomises the copy's GPT identifiers so
the two media can never be confused. Then power off and remove the SD.

## Layout

| Path | What it is |
|---|---|
| `build.sh` | Host side: binfmt precheck, ssh-key discovery, layer mounts, `podman build` + `run`. No build logic. |
| `Dockerfile` | The builder image. `build-inner.sh` is baked in; everything else is bind-mounted. |
| `build-inner.sh` | Five numbered stages: blobs → U-Boot → kernel `.deb` → rootfs → image. |
| `pins.env` | Every moving input: source tags, blob names and hashes, suite, mirror, geometry, `BOARD`. |
| `rk3588/` | SoC/design-common boot material: `boot.cmd`, U-Boot A/B fragment, bootstd dtsi, kernel fragment. |
| `boards/<name>/` | Per-board facts: `board.env` (U-Boot defconfig + dtsi, DTB) and a kernel-quirk fragment. |
| `base/` | Static files present in **every** image, installed by one `sync-in`. |
| `layers/nas/` | Working example layer I use for my NAS setup. |
| `work/`, `out/` | Gitignored. Source clones, apt cache, and build products. |

Build products land in `out/`: the flashable disk image, the `.rootfs.img.gz`
slot payload for updates, the `.uboot.bin.gz` loader payload for
`slotctl update-loader`, a `.sha256` for each, and a `.manifest` recording
every input revision and hash.

## Layers

All customization lives in layers. A layer is a directory with two optional
pieces:

- `files/` — a tree synced into the image root (ownership normalized to
  `root:root`, modes from git).
- `layer.sh` — sourced by the engine before the rootfs stage. It may append
  to `EXTRA_PACKAGES` (comma list), `EXTRA_APT_KEYS` / `EXTRA_MIRRORS`
  (one per line), `KERNEL_FRAGMENT_EXTRA`, and add mmdebstrap customize
  hooks to `LAYER_HOOKS` (run in the chroot as `"$1"`).

Select layers with the `LAYERS` variable — a space-separated list applied in
order, after the base:

```bash
LAYERS="layers/nas" ./build.sh              # the default
LAYERS="" ./build.sh                        # bare base image
LAYERS="layers/nas /home/me/my-layer" ./build.sh
```

Relative paths resolve inside this repo; absolute paths are bind-mounted into
the builder, so your personal layer can live in its own repository and never
conflict with pulling this one. To start your own, copy `layers/nas/` and
replace its measured values (array UUIDs, MAC address, LAN subnets) — they are
one deployment's facts, not defaults. Each build's manifest records the layer
list and a hash of every `layer.sh`. Note that layers feed the kernel config,
so switching layer sets triggers a kernel rebuild.

The bare base image still boots, DHCPs, and accepts the ssh key found at build
time.

## Boards

`BOARD` (default `cm3588`) selects `boards/<name>/`, which holds the only
facts that name the hardware: `board.env` (U-Boot defconfig, the U-Boot dtsi
the bootstd node is appended to, the kernel DTB) and an optional
`kernel.config` of board quirks. The boot flow, A/B geometry, recovery
machinery, and all on-device tooling are board-independent. To target another
RK3588 board with mainline U-Boot + kernel support:

```bash
cp -r boards/cm3588 boards/rock5b   # then edit the three values in board.env
BOARD=rock5b ./build.sh
```

Treat a new board like a new DDR blob: nothing here is trusted until it has
boot-validated on the real hardware (per-board quirks like the CM3588's
combo-PHY line are exactly the things only hardware reveals).

## How it boots — A/B slots

```
LBA 64        u-boot-rockchip.bin   (idbloader + u-boot.itb; RK3588 BootROM contract)
LBA 1-33      GPT, FirstUsableLBA = 32768 so loader + env are not "free space"
13.0 MiB      U-Boot environment, primary     \ BOOT_ORDER, BOOT_A_LEFT,
13.5 MiB      U-Boot environment, redundant   / BOOT_B_LEFT
16 MiB        p1 rootA    PARTLABEL=rootA   } fixed size, never grown
              p2 rootB    PARTLABEL=rootB   }
              p3 persist  ssh host keys, journal — grown to fill the disk
```

U-Boot's **RAUC bootmeth** (`CONFIG_BOOTMETH_RAUC`) reads
`BOOT_ORDER`, decrements `BOOT_<slot>_LEFT`, and runs that slot's
`/boot/boot.scr`. If a slot's counter reaches zero it falls through to the
other one.

The environment is **redundant** so a power cut during a slot switch cannot
corrupt it, and it sits *after* the loader on purpose: the Rockchip default of
`0x3f8000` lands inside `u-boot-rockchip.bin`'s padding, so every bootloader
update would wipe the slot state.

`boot.scr` is **slot-agnostic** — the same rootfs image is written to either
slot, so it may not name a slot. It reads `distro_rootpart` and `raucargs` from
the bootmeth and resolves `root=PARTUUID=` out of the live partition table.
For the same reason `/etc/fstab` has **no `/` entry** at all, and `/` is mounted
`rw` directly rather than remounted.

## Updating

```bash
slotctl update out/cm3588-trixie-<stamp>.rootfs.img.gz <sha256>
reboot
```

That writes the image to the slot you are *not* running, verifies it by reading
it back, and gives it 3 boot attempts. On the next boot `slotctl mark-good`
polls the recoverability set (default route present, sshd up, `/persist`
mounted) for up to 2 minutes and only then resets the counter. **Recovery from
a bad update is unattended in both failure modes:** a slot that fails in
U-Boot resets the board (`bootcmd` ends in `reset`), and a slot that boots but
stays unhealthy reboots itself while the update's `BOOT_TRIAL` flag names it —
either way one attempt burns per pass until U-Boot returns to the old slot.
Outside a trial, an unhealthy boot stays up (an external outage must not
reboot-loop a known-good slot) and rolls back only on the next reboot. Hangs
are covered separately: the dw_wdt watchdog is armed from U-Boot on and handed
via the kernel to systemd (`RuntimeWatchdogSec`), and a kernel panic reboots
after 10 s (`CONFIG_PANIC_TIMEOUT`).

`slotctl update` also accepts an `https://` URL. Ship the `.rootfs.img.gz`
plus the `.sha256` the build emits alongside it.

The loader (everything below 16 MiB: DDR init, TF-A, U-Boot and its bootcmd/
watchdog policy) is the one non-A/B piece — the BootROM reads it from a fixed
sector with no fallback logic. `slotctl update-loader <stamp>.uboot.bin.gz
<sha256>` rewrites it in place on the running boot disk, leaving slots and the
env untouched, and verifies by read-back. A power cut during those few seconds is
the one failure that needs the rescue SD — keep one flashed. The truly
permanent decisions are the partition geometry (`SLOT_SIZE_MB` and friends)
and the env offsets: no tool changes those without a reflash.

Two consequences of image-based updates worth internalising:

- **Runtime changes to the OS do not survive.** `apt install` or hand-edited
  `/etc` is replaced wholesale by the next update. Changes belong in a layer
  and get rebuilt. Data on attached storage is untouched.
- **`machine-id` is regenerated per slot.** The two things that
  would otherwise destabilise are pinned separately: the NIC MAC by
  `10-persistent-mac.link`, and the DHCP lease by `ClientIdentifier=mac`.
  SSH host keys and the journal live on `/persist` so they *do* survive.

## Recovery

- Keep the previous `.img.gz` **and** its `.manifest` and `.sha256`.
- The rescue path is an SD card carrying any known-good `.img.gz`.
- The two media can coexist: `flash-emmc` randomises the eMMC's GPT
  identifiers so `root=PARTUUID=` can never resolve to the wrong medium, and
  whichever medium boots, `persist-setup` remounts `/persist` from its own
  disk (`PARTLABEL=persist` exists on both), so neither system adopts the
  other's identity or journal.

## Example layer "NAS"

`layers/nas/` is my actual deployment, kept in-tree as a
complete example of what a layer can do: Plex from its own apt repo (with
build-chroot workarounds its postinst needs), qBittorrent confined to a
WireGuard network namespace with a kill switch and Proton NAT-PMP port
forwarding, NFS exports of a 4× NVMe md raid0, smartd as the array's only
early warning, and pinned service uids so appdata on the array survives
reimaging.
