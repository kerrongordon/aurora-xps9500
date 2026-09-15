# aurora-xps9500

A personal [bootc](https://github.com/bootc-dev/bootc) image, derived from
[Aurora](https://github.com/ublue-os/aurora), for a Dell XPS 9500. It bakes in
the things that are painful as runtime `rpm-ostree override`s so they rebuild
cleanly with every `bootc upgrade` instead of fighting it.

## Base

```
ghcr.io/ublue-os/aurora-nvidia-open:stable
```

KDE, Fedora 44 line. `-nvidia-open` because the GTX 1650 Ti (Turing) in this
laptop is supported by the open driver, and the image ships pre-signed so no
MOK enrollment is needed. Base Aurora, not `aurora-dx` — this setup is
podman-only and doesn't want DX's bundled Docker/Incus.

## What's baked in

1. **Goodix fingerprint driver** (`27c6:533c`), via `libfprint-tod-goodix`
   from COPR [`manciukic/libfprint-tod-goodix`](https://copr.fedorainfracloud.org/coprs/manciukic/libfprint-tod-goodix/)
   — libfprint doesn't drive this reader in-tree. This has to happen at
   build time: as a runtime override it can block `bootc upgrade` the
   moment Fedora bumps libfprint.

   If the COPR hasn't published a build for the base image's current Fedora
   release yet, pin `build_files/build.sh` to an older `fedora-NN` repo —
   the blob itself is release-agnostic.

2. **zsh**, so a login shell always exists in `/usr`. Everything else
   zsh-related (config, plugins, starship, mise via Homebrew) is
   deliberately user-space — see below.

3. **zsh as the default shell for new accounts** (`system_files/etc/default/useradd`).
   Only affects accounts created after switching to this image — an existing
   account keeps whatever `/etc/passwd` already has, so it still needs a
   one-time `sudo chsh -s /usr/bin/zsh $USER` (the setup script below does
   this for you).

4. **`/etc/zshenv`** (`system_files/etc/zshenv`) — the `ZDOTDIR` hook, so any
   shell reads config from `~/.config/zsh` once it exists. Fedora reads
   `/etc/zshenv`, not Debian's `/etc/zsh/zshenv`.

## What stays out of the image

Homebrew and everything under it, the zsh config itself, dotfiles, fonts,
toolbox provisioning. These need `$HOME` and a network connection, which the
image can't provide, so they run post-install instead:

- **`setup-zsh-aurora.sh`** (`system_files/usr/libexec/`) — clones
  `radleylewis/zsh` into `~/.config/zsh`, installs Homebrew + dev CLI tools +
  mise, sets the login shell for existing accounts, and provisions a Toolbx
  container. Idempotent; safe to re-run by hand.
- **`setup-zsh-aurora.service`** (a systemd `--user` unit, enabled by default
  via a `default.target.wants` symlink) — runs that script once per account,
  guarded by a stamp file at `~/.local/state/setup-zsh-aurora.done`. Picked
  the first-login-unit approach over an `/etc/skel` checkout specifically so
  the brew/mise/Toolbx steps run automatically too — `/etc/skel` can only
  drop files at account-creation time, it can't execute anything.

Rule of thumb: if it works from `$HOME`, it doesn't belong in the image.

## Building locally

```bash
docker build -t test .
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
- `/usr/bin/zsh` exists
- Image boots and `bootc upgrade` resolves cleanly

## Repo layout

This repo is templated from
[`ublue-os/image-template`](https://github.com/ublue-os/image-template),
which provides the GitHub Actions build, cosign signing, and rechunk step.
See that repo's README for the mechanics of the `Justfile`, disk-image
builds, and ArtifactHub listing — the pieces specific to this image are:

- `Containerfile` — `FROM` the base above, then `RUN /ctx/build.sh`
- `build_files/build.sh` — the COPR + package install, kept idempotent
- `system_files/` — file overlays, empty for now
