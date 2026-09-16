# aurora-xps9500

A personal [bootc](https://github.com/bootc-dev/bootc) image, derived from
[Aurora](https://github.com/ublue-os/aurora), for a Dell XPS 9500. Everything
is stock Aurora except one addition: the Goodix fingerprint driver, baked in
at build time instead of as a runtime `rpm-ostree override` (which could
otherwise block `bootc upgrade` on any Fedora libfprint bump).

## Base

```
ghcr.io/ublue-os/aurora-nvidia-open:stable
```

KDE, Fedora 44 line. `-nvidia-open` because the GTX 1650 Ti (Turing) in this
laptop is supported by the open driver, which ships as the default in this
image — nothing extra needed for NVIDIA. Base Aurora, not `aurora-dx` — this
setup is podman-only and doesn't want DX's bundled Docker/Incus.

## What's baked in

**Goodix fingerprint driver** (`27c6:533c`), via `libfprint-tod-goodix` from
COPR [`manciukic/libfprint-tod-goodix`](https://copr.fedorainfracloud.org/coprs/manciukic/libfprint-tod-goodix/)
— libfprint doesn't drive this reader in-tree.

`libfprint-tod` only `Provides: libfprint = 1.94.5`, no `Obsoletes`, and that
trails Fedora 44's stock libfprint — so `build_files/build.sh` uses
`dnf5 swap` rather than `install`, otherwise dnf5 sees it as a downgrade and
fails on file conflicts.

If the COPR hasn't published a build for the base image's current Fedora
release yet, pin `build_files/build.sh` to an older `fedora-NN` repo instead
— the blob itself is release-agnostic.

Everything else — zsh, dotfiles, Homebrew, dev tools — is deliberately left
out of the image and handled separately, post-install, on the running
system.

## Building locally

```bash
docker build -f Containerfile -t test .
```

(This host doesn't have podman/buildah; `docker build` works fine against
the same Containerfile. CI uses podman via the `Justfile`.)

## Switching to this image

```bash
sudo ostree admin pin 0   # pin the current deployment as a fallback first
sudo bootc switch --enforce-container-sigpolicy ghcr.io/kerrongordon/aurora-xps9500:latest
```

## Verifying a built image

- `rpm -q libfprint-tod-goodix` present, `libfprint` replaced not duplicated
- `fprintd` starts and sees the device: `fprintd-list $USER`
- `fprintd-enroll`, then `authselect enable-feature with-fingerprint`
- Image boots and `bootc upgrade` resolves cleanly

## Getting an ISO

GitHub Actions → **Build disk images** → **Run workflow** → pick `amd64`.
Builds an Anaconda installer ISO (and a qcow2) from whatever's currently at
`ghcr.io/kerrongordon/aurora-xps9500:latest`; the ISO installs like stock
Fedora, then a kickstart `%post` step runs `bootc switch` to land you on this
image. Pinned to `ubuntu-24.04` in `build-disk.yml` — `bootc-image-builder`'s
privileged nested mounts broke on `ubuntu-26.04` (a runner-image regression,
unrelated to this repo).

## Repo layout

This repo is templated from
[`ublue-os/image-template`](https://github.com/ublue-os/image-template),
which provides the GitHub Actions build, cosign signing, and rechunk step.
See that repo's README for the mechanics of the `Justfile`, disk-image
builds, and ArtifactHub listing — the pieces specific to this image are:

- `Containerfile` — `FROM` the base above, then `RUN /ctx/build.sh`
- `build_files/build.sh` — the Goodix COPR swap, kept idempotent
- `system_files/` — file overlays, empty (no overrides beyond the driver)
- `disk_config/iso.toml` — the KDE installer kickstart for ISO builds
