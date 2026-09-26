#!/usr/bin/bash
#
# Layers Titanoboa's Container-native ISO contract v0.1.0 onto the real
# aurora-xps9500 image. Adapted from ublue-os/titanoboa's own
# examples/bazzite/src/build.sh, with the Bazzite-specific branding,
# secure-boot enrollment dropped — but NOT its
# titanoboa_hook_postrootfs.sh anaconda-live install, which is the actual
# installer mechanism. Earlier revisions of this script skipped that too,
# on the mistaken assumption livesys-scripts provides an installer by
# itself; it doesn't, so there was no way to install from the live session
# at all. See the anaconda-live block below for what's added back.
#
# Preinstall Aurora's default Flatpaks for the live session.
# Copy the seeded Flatpaks into the installed deployment in Anaconda's post step.

set -exo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create the directory that /root is symlinked to
mkdir -p "$(realpath /root)"

# bwrap tries to write /proc/sys/user/max_user_namespaces which is mounted
# read-only during a container build; remount rw.
mount -o remount,rw /proc/sys

# Use the app manifest from this base image, keeping its Aurora defaults in sync.
# This is base Aurora; the separate DX app manifest does not apply.
flatpak_manifest=/usr/share/ublue-os/homebrew/system-flatpaks.Brewfile
test -s "$flatpak_manifest"
mapfile -t default_flatpaks < <(sed -nE 's/^[[:space:]]*flatpak[[:space:]]+"([^"]+)"[[:space:]]*(#.*)?$/\1/p' "$flatpak_manifest")
if (( ${#default_flatpaks[@]} == 0 )); then
    echo "No default Flatpaks found in $flatpak_manifest" >&2
    exit 1
fi

# Seed all default apps and their runtimes into the live filesystem.
flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --system --noninteractive -y flathub "${default_flatpaks[@]}"
for app in "${default_flatpaks[@]}"; do
    flatpak info --system "$app"
done
test -s /var/lib/flatpak/exports/share/applications/io.github.kolunmi.Bazaar.desktop

# Live-bootable initramfs: the ostree-boot initramfs already in the image
# doesn't know how to mount root from a squashfs. dmsquash-live(-autooverlay)
# does — this is what makes `root=live:CDLABEL=...` in iso.yaml work.
dnf5 install -y dracut-live
kernel=$(kernel-install list --json pretty | jq -r '.[] | select(.has_kernel == true) | .version')
DRACUT_NO_XATTR=1 dracut -v --force --zstd --reproducible --no-hostonly \
    --add "dmsquash-live dmsquash-live-autooverlay" \
    "/usr/lib/modules/${kernel}/initramfs.img" "${kernel}"

# Live session UX: auto-login live user via livesys-scripts.
dnf5 install -y livesys-scripts
sed -i "s/^livesys_session=.*/livesys_session=kde/" /etc/sysconfig/livesys
systemctl enable livesys.service livesys-late.service

# The actual installer. anaconda-live ships /usr/bin/liveinst plus a
# liveinst.desktop entry ("Install to Hard Drive") that shows up in KDE's
# app launcher on its own — livesys-scripts only manages the live session,
# it has no installer of its own. libblockdev-{btrfs,lvm,dm} are Anaconda's
# storage backends; without them the Storage spoke can't format a target
# disk. /var/lib/rpm-state is expected to exist by the Anaconda Web UI.
dnf5 install -y firefox anaconda-live rsync libblockdev-{btrfs,lvm,dm}
mkdir -p /var/lib/rpm-state

# Fail the build rather than publish another live desktop without an installer.
test -x /usr/bin/liveinst
test -s /usr/share/applications/liveinst.desktop

# Deploy the daily-driver image from the registry, not this live overlay.
# Installation requires an internet connection. --no-signature-verification matches
# disk_config/iso.toml's unattended install path, which also switches
# without cosign enforcement at install time.
cat >/usr/share/anaconda/interactive-defaults.ks <<'EOF'
ostreecontainer --url=ghcr.io/kerrongordon/aurora-xps9500:latest --transport=registry --no-signature-verification

# The registry payload does not contain the live ISO's /var/lib/flatpak.
# Follow Titanoboa's deployment-aware copy so all default apps and runtimes survive.
%post --nochroot --erroronfail --log=/tmp/install-flatpaks.log
set -euo pipefail
deployment="$(ostree rev-parse --repo=/mnt/sysimage/ostree/repo ostree/0/1/0)"
target="/mnt/sysimage/ostree/deploy/default/deploy/${deployment}.0/var/lib/flatpak"
test -d "/mnt/sysimage/ostree/deploy/default/deploy/${deployment}.0"
mkdir -p "$target"
rsync -aAXH --filter='-x security.selinux' /var/lib/flatpak/ "$target/"
test -s "$target/exports/share/applications/io.github.kolunmi.Bazaar.desktop"
%end
EOF

# grub2-efi-x64-cdboot provides gcdx64.efi, which the ISO contract needs.
dnf5 install -y grub2-efi-x64-cdboot xorriso isomd5sum

# Container-native ISO contract: shim/grub2 EFI binaries must be at
# /boot/efi/EFI/$VENDOR. The rpms actually install to /usr/lib/efi/<ver>/ —
# there's no real ESP mounted during a container build to receive them.
mkdir -p /boot/efi
cp -av /usr/lib/efi/*/*/EFI /boot/efi/
cp -v /boot/efi/EFI/fedora/grubx64.efi /boot/efi/EFI/BOOT/fbx64.efi

# / in a booted live ISO is an overlayfs backed by a small tmpfs /run, so
# /var/tmp is small too. bootc/ostree need real room there for an in-session
# `bootc install`. Only matters for this live image, never the daily driver.
rm -rf /var/tmp || :
mkdir -p /var/tmp
cat >/etc/systemd/system/var-tmp.mount <<'EOF'
[Unit]
Description=Larger tmpfs for /var/tmp on live system

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=50%,nr_inodes=1m

[Install]
WantedBy=local-fs.target
EOF
systemctl enable var-tmp.mount

mkdir -p /usr/lib/bootc-image-builder
cp "$SCRIPT_DIR/iso.yaml" /usr/lib/bootc-image-builder/iso.yaml
