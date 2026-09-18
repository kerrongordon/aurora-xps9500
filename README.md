# aurora-xps9500

A personal [bootc](https://github.com/bootc-dev/bootc) image, derived from
[Aurora](https://github.com/ublue-os/aurora), for a Dell XPS 9500. Adds OEM
first-boot setup, a preconfigured Zsh shell, and the Goodix fingerprint driver, baked in
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

**Zsh for new accounts**, using [radleylewis/zsh](https://github.com/radleylewis/zsh).
Plasma Setup uses the image's `useradd` default, `/bin/zsh`, and copies the
configuration from `/etc/skel` into each new home. The image includes Neovim,
eza, bat, fd, fzf, zoxide, ripgrep, Starship (from `atim/starship` COPR when
not already installed), and the four pinned Zsh plugins. First launch works
without downloading plugins. Personal changes go in
`~/.config/zsh/local.zsh`; `zplugin-update` updates the user's plugin copies.
Use a Nerd Font in the terminal for the prompt and listing icons.

Existing accounts keep their current shell and dotfiles. Rebuild the OS image
and ISO to include these defaults in new installations.

### Toolbx

Toolbx shares your home, so it sees the same Zsh settings and plugins. It has
its own packages: install the dependencies inside each Fedora container:

```bash
toolbox enter
sudo dnf install -y zsh git neovim eza bat fd-find fzf zoxide ripgrep
sudo dnf copr enable -y atim/starship
sudo dnf install -y starship
sudo dnf copr disable -y atim/starship
exit
toolbox run zsh
```

Use `toolbox run --container NAME zsh` for a named container. Toolbx's default
shell is separate from the host account's shell; explicitly launching Zsh
avoids relying on that default. Other container distributions need equivalent
packages and a recent Fzf supporting `fzf --zsh`. The optional upstream `lf`
and `stream` helpers additionally require `lf` or `mpv` and suitable device
access; those tools are not bundled by this configuration.

## Building locally

```bash
podman build -t test .
```

Install Podman and Just before building. Use `just build` for the same
Podman build with image metadata used by CI. Podman automatically reads
the `Containerfile`.

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

OEM installation is the default: installation does not ask for a personal
account. On the installed system's first boot, Plasma Setup creates the
owner's account and configures their initial settings. The live USB still
uses a temporary live-session account; it is not copied into the installed
OS. For delivery to another person, shut down after installation and leave
the first-boot wizard for them to complete.

Rebuild the OS image first, then build the ISO against that published image.
Existing ISO downloads do not acquire these changes automatically. Before
shipping an OEM install, verify in a VM that installation skips account
creation, first boot shows Plasma Setup, and a second boot after completing
setup reaches normal login without repeating the wizard.

For a live desktop with Aurora's default apps, run **Build Live ISO** in
GitHub Actions. Download the `aurora-xps9500-live-iso` artifact from the
successful run. The live image installs the default Flatpaks listed in the
base image's `system-flatpaks.Brewfile`, and Anaconda copies them and their
runtimes into the installed system. The OS payload still requires internet
access during installation.

For the separate disk-image workflow:

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
- `build_files/zsh.sh` — shell dependencies, pinned plugins, default shell, startup checks
- `system_files/` — new-user Zsh configuration in `/etc/skel`
- `disk_config/iso.toml` — the KDE installer kickstart for ISO builds
