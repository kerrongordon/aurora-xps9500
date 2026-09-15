#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

### Goodix fingerprint reader (27c6:533c) — Dell XPS 9500
#
# libfprint does not drive this reader in-tree. libfprint-tod-goodix is a
# libfprint-tod fork bundled with Dell's closed Touch OEM Driver blob,
# covering 538c, 533c, 530c and 5840. This has to happen at build time: as a
# runtime `rpm-ostree override` it can block `bootc upgrade` the moment
# Fedora bumps libfprint.
#
# The COPR lags Fedora releases sometimes. If `dnf5 copr enable` fails
# because there's no build for the base image's Fedora release yet, pin the
# repo file to an older fedora-NN release instead (the blob itself is
# release-agnostic) rather than waiting for the COPR to catch up.
#
# libfprint-tod only Provides "libfprint = 1.94.5", not Obsoletes, and that
# version trails Fedora's stock libfprint — so a plain `install` sees it as
# a downgrade and fails on file conflicts instead of replacing it. `swap`
# forces the remove+install instead of trying to resolve it as an upgrade.
dnf5 -y copr enable manciukic/libfprint-tod-goodix
dnf5 -y swap --allowerasing libfprint libfprint-tod-goodix
dnf5 -y copr disable manciukic/libfprint-tod-goodix

### zsh — must exist in /usr as a login shell
#
# Cannot come from Homebrew: a broken brew prefix would lock out every
# terminal. Everything else zsh-related (config, plugins, starship, mise)
# stays in $HOME via setup-zsh-aurora.sh, not in this image.
dnf5 -y install zsh
