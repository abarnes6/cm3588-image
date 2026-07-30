# boot.cmd — compiled to /boot/boot.scr and executed by U-Boot's RAUC
# bootmeth once it has picked a slot.
#
# MUST BE SLOT-AGNOSTIC: the same rootfs image is written to either slot, so
# nothing here may name a slot or a partition. The bootmeth provides devtype,
# devnum, distro_bootpart, distro_rootpart, and raucargs (rauc.slot=<name>).

part uuid ${devtype} ${devnum}:${distro_rootpart} partuuid

# root= is a PARTUUID read from the live table (LABEL= would need initramfs).
# "rw" because / is deliberately absent from fstab (see README).
# console= ORDER is load-bearing: the kernel binds /dev/console to the LAST
# console listed, and emergency.service writes there — serial must be last on
# a headless box.
setenv bootargs "root=PARTUUID=${partuuid} rootwait rw ${raucargs} console=tty0 console=ttyS2,1500000"

# Stable symlinks created at build time; no kernel version knowledge here.
load ${devtype} ${devnum}:${distro_bootpart} ${kernel_addr_r} /boot/vmlinuz
load ${devtype} ${devnum}:${distro_bootpart} ${ramdisk_addr_r} /boot/initrd.img
# capture the initrd size before the next load overwrites ${filesize}
setenv ramdisk_bytes ${filesize}
load ${devtype} ${devnum}:${distro_bootpart} ${fdt_addr_r} /boot/dtb

booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_bytes} ${fdt_addr_r}
