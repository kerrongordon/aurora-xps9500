#!/usr/bin/env bash
#
# setup-zsh-aurora.sh — radleylewis/zsh + Homebrew + mise + dev CLI tools
# on this aurora-xps9500 bootc image, with Toolbx parity.
#
# Ships in the image at /usr/libexec/ and runs once per user via the
# setup-zsh-aurora.service systemd --user unit (first login after account
# creation). Safe to re-run by hand too — every step is idempotent.
#
# Layout, and why:
#   /usr          the image already bakes in zsh (and, on this image, the
#                 Goodix fingerprint driver) — install_host_zsh below just
#                 confirms it's there. Not visible in Toolbx.
#   /home/linuxbrew
#                 Homebrew. Toolbx bind-mounts /home, so every brew binary is
#                 on PATH inside containers too. This is where dev tools go.
#   ~/.local/bin  starship, mise — shared with containers for the same reason.
#   ~/.config/zsh the config itself; overrides in local.zsh (git-ignored).
#   /etc/zshenv   ZDOTDIR hook baked into the image (system_files/etc/zshenv);
#                 --system-zshenv below is a no-op guard against also writing
#                 the same hook into ~/.zshenv.
#   toolbox       gets zsh (so `toolbox enter` works), git and build deps via
#                 dnf; everything else it inherits from $HOME.
#
# Usage: ./setup-zsh-aurora.sh [options]
#   --method auto|layer|brew   source for core CLI tools (default: auto)
#   --no-dev-tools             skip lazygit/gh/btop/yazi/... (brew only)
#   --toolbox NAME             container to create/provision (default: dev)
#   --no-toolbox               don't touch Toolbx
#   --toolbox-full             also dnf-install the core tools inside the
#                              container instead of inheriting brew's
#   --codecs                   full ffmpeg + VA-API hardware decoding
#   --fingerprint              set up the fingerprint reader (fprintd + PAM)
#   --nvidia                   set up the proprietary NVIDIA driver
#   --no-brew | --no-mise | --no-font | --no-chsh
#   --system-zshenv            ZDOTDIR snippet in /etc/zshenv, not ~/.zshenv
#   -h, --help

set -euo pipefail

REPO_URL="https://github.com/radleylewis/zsh"
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
ZDOTDIR_PATH="$XDG_CONFIG/zsh"
LOCAL_ZSH="$ZDOTDIR_PATH/local.zsh"
BREW_BIN="/home/linuxbrew/.linuxbrew/bin/brew"
FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"

METHOD="auto"
INSTALL_BREW=1
INSTALL_MISE=1
INSTALL_FONT=1
INSTALL_DEV_TOOLS=1
DO_CHSH=1
SYSTEM_ZSHENV=0
DO_TOOLBOX=1
TOOLBOX_NAME="dev"
TOOLBOX_FULL=0
DO_CODECS=0
DO_FINGERPRINT=0
DO_NVIDIA=0
REBOOT_NEEDED=0

# What the config itself needs. "binary:rpm:brew-formula" — empty rpm means
# Fedora doesn't package it.
CORE_TOOLS=(
  "nvim:neovim:neovim"
  "eza:eza:eza"
  "bat:bat:bat"
  "fd:fd-find:fd"
  "fzf:fzf:fzf"
  "rg:ripgrep:ripgrep"
  "zoxide:zoxide:zoxide"
  "starship::starship"
)

# Omarchy-ish dev extras. Brew only: several aren't in Fedora's repos, and brew
# is what the containers can see anyway.
DEV_TOOLS=(
  "lazygit:lazygit"      # git TUI
  "podman-tui:podman-tui" # container TUI, talks to the podman user socket
  "gh:gh"                # github cli
  "jq:jq"
  "delta:git-delta"      # git diffs
  "btop:btop"
  "fastfetch:fastfetch"
  "tldr:tealdeer"
  "yazi:yazi"            # file manager
  "gum:gum"              # shell script prompts
)

msg()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --method)        METHOD="${2:-}"; shift 2 ;;
    --method=*)      METHOD="${1#*=}"; shift ;;
    --no-dev-tools)  INSTALL_DEV_TOOLS=0; shift ;;
    --toolbox)       TOOLBOX_NAME="${2:-}"; shift 2 ;;
    --toolbox=*)     TOOLBOX_NAME="${1#*=}"; shift ;;
    --no-toolbox)    DO_TOOLBOX=0; shift ;;
    --toolbox-full)  TOOLBOX_FULL=1; shift ;;
    --codecs)        DO_CODECS=1; shift ;;
    --fingerprint)   DO_FINGERPRINT=1; shift ;;
    --nvidia)        DO_NVIDIA=1; shift ;;
    --no-brew)       INSTALL_BREW=0; shift ;;
    --no-mise)       INSTALL_MISE=0; shift ;;
    --system-zshenv) SYSTEM_ZSHENV=1; shift ;;
    --no-font)       INSTALL_FONT=0; shift ;;
    --no-chsh)       DO_CHSH=0; shift ;;
    -h|--help)       sed -n '3,32p' "$0"; exit 0 ;;
    *)               die "unknown option: $1" ;;
  esac
done

[[ "$METHOD" =~ ^(auto|layer|brew)$ ]] || die "--method must be auto, layer or brew"
[[ $EUID -ne 0 ]] || die "run as your normal user, not root (sudo is called where needed)"

IN_CONTAINER=0
[[ -f /run/.containerenv || -f /run/.toolboxenv ]] && IN_CONTAINER=1
if [[ $IN_CONTAINER -eq 1 ]]; then
  die "you're inside a container — run this on the host; it provisions Toolbx for you"
fi
[[ -f /run/ostree-booted ]] || warn "not an ostree/bootc system — rpm-ostree steps will be skipped"

load_brew_env() {
  if [[ -x "$BREW_BIN" ]] && ! command -v brew >/dev/null 2>&1; then
    eval "$("$BREW_BIN" shellenv)"
  fi
}

# ------------------------------------------------------------ rpm-ostree ----
layer_packages() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -gt 0 ]] || return 0
  [[ -f /run/ostree-booted ]] || die "need ${pkgs[*]} but this isn't an ostree system"
  msg "rpm-ostree install ${pkgs[*]}"
  if sudo rpm-ostree install --idempotent --allow-inactive --apply-live -y "${pkgs[@]}"; then
    msg "packages applied live"
  else
    warn "--apply-live failed (normal for some packages); staging instead"
    sudo rpm-ostree install --idempotent --allow-inactive -y "${pkgs[@]}"
    REBOOT_NEEDED=1
  fi
}

# -------------------------------------------------------------- homebrew ----
install_homebrew() {
  [[ $INSTALL_BREW -eq 1 ]] || return 0
  load_brew_env
  if command -v brew >/dev/null 2>&1; then
    msg "Homebrew already installed ($(command -v brew))"
    return
  fi
  local need=()
  for b in git curl file ps; do
    command -v "$b" >/dev/null 2>&1 || case "$b" in
      ps) need+=(procps-ng) ;;
      *)  need+=("$b") ;;
    esac
  done
  [[ ${#need[@]} -eq 0 ]] || layer_packages "${need[@]}"

  msg "installing Homebrew (large download — be patient on a slow link)"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  load_brew_env
  command -v brew >/dev/null 2>&1 || die "Homebrew installed but brew isn't on PATH"
}

# ------------------------------------------------------------- host zsh -----
install_host_zsh() {
  if [[ -x /usr/bin/zsh ]]; then
    msg "zsh already present at /usr/bin/zsh"
  else
    msg "layering zsh (login shells must come from the host, not brew)"
    layer_packages zsh
  fi
}

# ---------------------------------------------------------- core tools ------
install_core_tools() {
  local entry bin rpm formula rpms=() formulas=()
  for entry in "${CORE_TOOLS[@]}"; do
    IFS=':' read -r bin rpm formula <<< "$entry"
    command -v "$bin" >/dev/null 2>&1 && continue
    if [[ "$METHOD" == "brew" || -z "$rpm" ]]; then
      formulas+=("$formula")
    else
      rpms+=("$rpm")
    fi
  done

  [[ ${#rpms[@]} -eq 0 ]] || layer_packages "${rpms[@]}"

  if [[ ${#formulas[@]} -gt 0 ]]; then
    if command -v brew >/dev/null 2>&1; then
      msg "brew install ${formulas[*]}"
      brew install "${formulas[@]}"
    elif [[ " ${formulas[*]} " == *" starship "* ]]; then
      msg "installing starship to ~/.local/bin (not in Fedora repos, no brew here)"
      mkdir -p "$HOME/.local/bin"
      curl -fsSL https://starship.rs/install.sh | sh -s -- --bin-dir "$HOME/.local/bin" --yes
    fi
  fi
  [[ ${#rpms[@]} -gt 0 || ${#formulas[@]} -gt 0 ]] || msg "core CLI tools already present"
}

install_dev_tools() {
  [[ $INSTALL_DEV_TOOLS -eq 1 ]] || return 0
  if ! command -v brew >/dev/null 2>&1; then
    warn "dev tools are brew-only (shared with Toolbx via /home) — skipping"
    return
  fi
  local entry bin formula want=()
  for entry in "${DEV_TOOLS[@]}"; do
    IFS=':' read -r bin formula <<< "$entry"
    command -v "$bin" >/dev/null 2>&1 || want+=("$formula")
  done
  if [[ ${#want[@]} -eq 0 ]]; then
    msg "dev tools already present"
    return
  fi
  msg "brew install ${want[*]}"
  brew install "${want[@]}"
}

install_mise() {
  [[ $INSTALL_MISE -eq 1 ]] || return 0
  if command -v mise >/dev/null 2>&1; then
    msg "mise already installed ($(command -v mise))"
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    msg "brew install mise"
    brew install mise
  else
    msg "installing mise to ~/.local/bin via mise.run"
    mkdir -p "$HOME/.local/bin"
    curl -fsSL https://mise.run | MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh
  fi
}

# --------------------------------------------------------------- config -----
clone_config() {
  if [[ -d "$ZDOTDIR_PATH/.git" ]]; then
    msg "config already at $ZDOTDIR_PATH — pulling"
    git -C "$ZDOTDIR_PATH" pull --ff-only || warn "pull failed; leaving the checkout as-is"
  elif [[ -e "$ZDOTDIR_PATH" ]]; then
    die "$ZDOTDIR_PATH exists and is not a git checkout — move it aside first"
  else
    msg "cloning $REPO_URL -> $ZDOTDIR_PATH"
    mkdir -p "$XDG_CONFIG"
    git clone --depth 1 "$REPO_URL" "$ZDOTDIR_PATH"
  fi
}

write_block() {
  local target="$1" marker="$2" content="$3" sudo_cmd=""
  [[ "$target" == /etc/* ]] && sudo_cmd="sudo"
  if $sudo_cmd grep -qF "$marker" "$target" 2>/dev/null; then
    msg "$target already has the $marker block"
    return
  fi
  msg "appending $marker block to $target"
  if [[ -n "$sudo_cmd" ]]; then
    printf '\n%s\n' "$content" | sudo tee -a "$target" >/dev/null
  else
    mkdir -p "$(dirname "$target")"
    printf '\n%s\n' "$content" >> "$target"
  fi
}

write_zdotdir_hook() {
  local block
  block=$(cat <<'EOF'
# >>> zdotdir >>>
[[ -z "$XDG_CONFIG_HOME" ]] && export XDG_CONFIG_HOME="$HOME/.config"
if [[ -d "$XDG_CONFIG_HOME/zsh" ]]; then
  export ZDOTDIR="$XDG_CONFIG_HOME/zsh"
  [[ -f "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"
fi
# <<< zdotdir <<<
EOF
)
  if [[ $SYSTEM_ZSHENV -eq 1 ]]; then
    write_block /etc/zshenv "# >>> zdotdir >>>" "$block"   # Fedora path, not /etc/zsh/zshenv
  else
    write_block "$HOME/.zshenv" "# >>> zdotdir >>>" "$block"
  fi
}

# Runs on host AND inside every Toolbx container, since $HOME is shared.
# NO_BREW_IN_CONTAINER=1 opts a container out if a brew binary ever misbehaves
# against the container's glibc.
write_env_hook() {
  local block
  block=$(cat <<'EOF'
# >>> brew + mise env >>>
if [[ -f /run/.containerenv || -f /run/.toolboxenv ]]; then
  export IN_TOOLBOX=1
fi
if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]] \
   && [[ -z "$IN_TOOLBOX" || "$NO_BREW_IN_CONTAINER" != "1" ]]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
# mise shims cover non-interactive shells; interactive uses `mise activate`.
if [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims" ]]; then
  export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH"
fi
# Podman: ONLY inside Toolbx. /run/user/$UID is shared with the host, so this
# reaches the host engine instead of nesting containers. Never set this on the
# host itself — it flips podman into remote-client mode and breaks `toolbox`.
if [[ -n "$IN_TOOLBOX" ]] \
   && [[ -S "${XDG_RUNTIME_DIR:-/run/user/$UID}/podman/podman.sock" ]]; then
  export CONTAINER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$UID}/podman/podman.sock"
fi
# <<< brew + mise env <<<
EOF
)
  write_block "$HOME/.zshenv" "# >>> brew + mise env >>>" "$block"
}

# .zshrc sources $ZDOTDIR/local.zsh last and .gitignore ignores it.
# The starship bit matters for Toolbx: the shipped starship.toml uses an
# explicit format string with no $container module, so host and container
# prompts look identical. This derives a container-only copy that adds it.
write_local_zsh() {
  local block
  block=$(cat <<'EOF'
# >>> mise + toolbox >>>
if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate zsh)"
fi

if [[ -n "$IN_TOOLBOX" ]]; then
  # podman-remote drives the host engine over CONTAINER_HOST
  if ! command -v podman >/dev/null 2>&1 && command -v podman-remote >/dev/null 2>&1; then
    alias podman='podman-remote'
  fi

  _sc="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/starship-container.toml"
  if [[ -f "$ZDOTDIR/starship.toml" ]] \
     && { [[ ! -f "$_sc" ]] || [[ "$ZDOTDIR/starship.toml" -nt "$_sc" ]]; }; then
    sed 's/^format = "/format = "$container/' "$ZDOTDIR/starship.toml" > "$_sc"
  fi
  [[ -f "$_sc" ]] && export STARSHIP_CONFIG="$_sc"
  unset _sc
fi
# <<< mise + toolbox <<<
EOF
)
  write_block "$LOCAL_ZSH" "# >>> mise + toolbox >>>" "$block"
}

make_dirs() {
  msg "creating history and completion cache directories"
  mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/zsh" "${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
}

set_login_shell() {
  [[ $DO_CHSH -eq 1 ]] || return 0
  local shell_path="/usr/bin/zsh"
  if [[ ! -x "$shell_path" ]]; then
    warn "zsh is staged but not on disk yet — NOT changing your login shell now."
    warn "Reboot, then re-run this script (it's idempotent) and it will set the shell."
    return
  fi
  if [[ "${SHELL:-}" == "$shell_path" ]]; then
    msg "login shell is already $shell_path"
    return
  fi
  grep -qxF "$shell_path" /etc/shells || echo "$shell_path" | sudo tee -a /etc/shells >/dev/null
  msg "setting login shell to $shell_path"
  sudo chsh -s "$shell_path" "$USER"
}

# -------------------------------------------------------------- toolbx ------
# `toolbox enter` execs the login shell from the host passwd entry, so zsh MUST
# exist inside the container or entering fails outright.
provision_toolbox() {
  [[ $DO_TOOLBOX -eq 1 ]] || return 0
  if ! command -v toolbox >/dev/null 2>&1; then
    warn "toolbox not found on PATH — skipping container setup"
    return
  fi

  if toolbox list --containers 2>/dev/null | awk '{print $2}' | grep -qx "$TOOLBOX_NAME"; then
    msg "toolbox '$TOOLBOX_NAME' already exists"
  else
    msg "creating toolbox '$TOOLBOX_NAME'"
    toolbox create -y "$TOOLBOX_NAME"
  fi

  # zsh: required. git + compilers: the reason you use a toolbox at all.
  local pkgs=(zsh git gcc gcc-c++ make cmake pkgconf-pkg-config openssl-devel unzip
              podman-remote)

  # A tool is only inherited by the container if it resolves somewhere $HOME
  # can see — the brew prefix or ~/.local/bin. Anything coming from /usr is a
  # host rpm and is invisible in here, so it has to be installed again via dnf.
  # (Checking "is brew installed?" isn't enough: brew can be present while the
  # tools still resolve to layered rpms.)
  local entry bin rpm formula path
  for entry in "${CORE_TOOLS[@]}"; do
    IFS=':' read -r bin rpm formula <<< "$entry"
    [[ -n "$rpm" ]] || continue          # starship lives in ~/.local/bin or brew
    path=$(command -v "$bin" 2>/dev/null || true)
    if [[ $TOOLBOX_FULL -eq 1 ]] \
       || [[ -z "$path" ]] \
       || [[ "$path" != /home/linuxbrew/* && "$path" != "$HOME"/* ]]; then
      pkgs+=("$rpm")
    fi
  done

  msg "installing inside '$TOOLBOX_NAME': ${pkgs[*]}"
  toolbox run -c "$TOOLBOX_NAME" sudo dnf install -y "${pkgs[@]}"

  # Parity check: every binary the config calls must resolve inside the
  # container, or .zshrc throws "command not found" on every new shell.
  local missing=()
  for entry in "${CORE_TOOLS[@]}"; do
    IFS=':' read -r bin rpm formula <<< "$entry"
    toolbox run -c "$TOOLBOX_NAME" command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    msg "toolbox '$TOOLBOX_NAME' has every tool the config needs"
  else
    warn "missing inside '$TOOLBOX_NAME': ${missing[*]}"
    warn "re-run with --toolbox-full to install them from Fedora's repos in the container"
  fi
}

# podman-tui and anything speaking CONTAINER_HOST need the rootless socket.
enable_podman_socket() {
  command -v podman >/dev/null 2>&1 || return 0
  if systemctl --user is-active --quiet podman.socket; then
    msg "podman user socket already active"
    return
  fi
  msg "enabling rootless podman socket"
  systemctl --user enable --now podman.socket || warn "couldn't enable podman.socket"
}


# ============================================================== hardware =====
# Both of these are host-only and independent of everything above.

# True when the booted image comes from Universal Blue (Bazzite, Bluefin,
# Aurora). Those images already carry codecs, mesa-freeworld and NVIDIA, and
# layering on top of them fights the update mechanism.
is_ublue() {
  rpm-ostree status --booted 2>/dev/null | grep -qi 'ublue-os'
}

# Returns 0 if RPM Fusion is ready to use, 1 if it was just added and the
# system needs a reboot before anything can depend on it.
ensure_rpmfusion() {
  if rpm -q rpmfusion-free-release >/dev/null 2>&1 \
     && rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
    return 0
  fi
  local fed; fed=$(rpm -E %fedora)
  msg "layering RPM Fusion repos (free + nonfree)"
  sudo rpm-ostree install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fed}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fed}.noarch.rpm"
  REBOOT_NEEDED=1
  return 1
}

# Fedora ships crippled ffmpeg-free / mesa-va-drivers. Swapping them for the
# RPM Fusion builds is an override of base-image packages, not a layer — it
# can block `rpm-ostree upgrade` on days when Fedora and RPM Fusion are out of
# sync on mesa. `rpm-ostree override reset --all` undoes the lot.
setup_codecs() {
  [[ $DO_CODECS -eq 1 ]] || return 0

  if is_ublue; then
    msg "ublue image — full ffmpeg, mesa-freeworld and codecs ship in the image already"
    return
  fi

  ensure_rpmfusion || { warn "reboot, then re-run with --codecs"; return; }

  # The -free package set changes between Fedora releases, so read it off the
  # system instead of hardcoding a list that rots.
  local free_pkgs=()
  mapfile -t free_pkgs < <(rpm -qa --queryformat '%{NAME}\n' | grep -E \
    '^(ffmpeg|libavcodec|libavdevice|libavfilter|libavformat|libavutil|libpostproc|libswresample|libswscale)-free$' \
    | sort -u)

  if [[ ${#free_pkgs[@]} -gt 0 ]]; then
    msg "replacing ${#free_pkgs[@]} -free packages with full ffmpeg"
    sudo rpm-ostree override remove "${free_pkgs[@]}" --install ffmpeg
    REBOOT_NEEDED=1
  else
    msg "no -free ffmpeg packages present; installing ffmpeg"
    sudo rpm-ostree install --idempotent -y ffmpeg
  fi

  # VA-API: mesa's shipped drivers have the patented codecs stripped out.
  local mesa_swap=()
  rpm -q mesa-va-drivers    >/dev/null 2>&1 && mesa_swap+=(mesa-va-drivers)
  rpm -q mesa-vdpau-drivers >/dev/null 2>&1 && mesa_swap+=(mesa-vdpau-drivers)
  if [[ ${#mesa_swap[@]} -gt 0 ]]; then
    msg "swapping ${mesa_swap[*]} for the freeworld builds"
    local installs=()
    for m in "${mesa_swap[@]}"; do installs+=(--install "${m}-freeworld"); done
    sudo rpm-ostree override remove "${mesa_swap[@]}" "${installs[@]}"
    REBOOT_NEEDED=1
  fi

  # Per-vendor VA-API driver.
  local gpu_pkgs=()
  if lspci 2>/dev/null | grep -qi 'vga.*intel\|display.*intel'; then
    gpu_pkgs+=(intel-media-driver)          # Gen8+ (Broadwell and newer), iHD
  fi
  if lspci 2>/dev/null | grep -qi 'nvidia'; then
    gpu_pkgs+=(libva-nvidia-driver)          # NVDEC through VA-API
  fi
  gpu_pkgs+=(gstreamer1-plugin-libav gstreamer1-plugins-ugly gstreamer1-plugins-bad-freeworld)
  msg "installing ${gpu_pkgs[*]}"
  sudo rpm-ostree install --idempotent --allow-inactive -y "${gpu_pkgs[@]}" || \
    warn "some multimedia packages failed — check the names against your Fedora release"
  REBOOT_NEEDED=1

  # openh264 for Firefox. Only matters for an RPM Firefox; the Flatpak carries
  # its own openh264 extension and ignores the host entirely.
  if rpm -q noopenh264 >/dev/null 2>&1; then
    msg "replacing noopenh264 with the real openh264"
    sudo rpm-ostree override remove noopenh264 \
      --install openh264 --install gstreamer1-plugin-openh264 --install mozilla-openh264
  fi

  warn "reboot, then verify with: vainfo   (install libva-utils if missing)"
  if flatpak list 2>/dev/null | grep -qi 'org.mozilla.firefox'; then
    warn "your Firefox is a Flatpak — host codecs don't affect it; it bundles its own"
  fi
}

# Goodix readers split into two camps: the MOC ones libfprint drives in-tree,
# and the ones needing libfprint-tod plus a vendor blob. This enrolls if the
# in-tree driver claims the device, and tells you the USB ID if it doesn't.
setup_fingerprint() {
  [[ $DO_FINGERPRINT -eq 1 ]] || return 0

  local id=""
  if command -v lsusb >/dev/null 2>&1; then
    id=$(lsusb | grep -iE 'goodix|fingerprint|synaptics|validity|elan.*fingerprint' || true)
  fi
  if [[ -z "$id" ]]; then
    warn "no fingerprint reader spotted via lsusb — continuing anyway"
  else
    msg "reader: $id"
  fi

  command -v fprintd-enroll >/dev/null 2>&1 || layer_packages fprintd fprintd-pam
  if [[ $REBOOT_NEEDED -eq 1 ]]; then
    warn "fprintd was staged — reboot and re-run with --fingerprint to enroll"
    return
  fi

  # Does the driver actually bind? An unsupported Goodix fails right here.
  if ! fprintd-list "$USER" >/dev/null 2>&1      && ! sudo systemctl start fprintd.service >/dev/null 2>&1; then
    warn "fprintd can't talk to a device."
    warn "Check the USB ID above against libfprint's supported list; Goodix parts"
    warn "outside the MOC family need libfprint-tod and a vendor driver, which is"
    warn "awkward to layer on Atomic. Stop here if yours isn't in-tree."
    return
  fi

  msg "enrolling right index finger — touch the reader when prompted"
  if fprintd-enroll -f right-index-finger "$USER"; then
    msg "enrolling PAM (sudo, GDM/SDDM unlock)"
    sudo authselect enable-feature with-fingerprint
    msg "test it with: fprintd-verify   then: sudo -k && sudo true"
  else
    warn "enrollment failed — driver likely doesn't support this reader"
  fi
}

# On ublue-derived images (Bazzite, Bluefin, Aurora) NVIDIA belongs in the
# image, not in a layer — rebasing is the supported path and survives updates.
# On vanilla Silverblue/Kinoite this layers akmod-nvidia from RPM Fusion.
setup_nvidia() {
  [[ $DO_NVIDIA -eq 1 ]] || return 0

  if ! lspci 2>/dev/null | grep -qi 'nvidia'; then
    warn "no NVIDIA GPU found on the PCI bus — skipping"
    return
  fi

  if is_ublue; then
    warn "this is a ublue image — don't layer the driver, rebase to the NVIDIA variant:"
    echo
    echo "    # Turing (GTX 16xx / RTX 20xx) and newer — use the -open variant:"
    echo "    rpm-ostree rebase ostree-image-signed:docker://ghcr.io/ublue-os/<image>-nvidia-open:latest"
    echo "    # Pascal (GTX 10xx) and older:"
    echo "    rpm-ostree rebase ostree-image-signed:docker://ghcr.io/ublue-os/<image>-nvidia:latest"
    echo
    echo "    Check yours with: rpm-ostree status"
    return
  fi

  ensure_rpmfusion || { warn "reboot, then re-run with --nvidia"; return; }

  if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    warn "Secure Boot is on — akmods must be signed or the module won't load."
    warn "Run these, reboot, and enroll the key in the blue MOK screen:"
    echo "    sudo kmodgenca -a"
    echo "    sudo mokutil --import /etc/pki/akmods/certs/public_key.der"
  fi

  msg "layering akmod-nvidia (builds on each kernel update)"
  sudo rpm-ostree install -y akmod-nvidia xorg-x11-drv-nvidia-cuda

  msg "setting kernel arguments (nouveau off, DRM modeset on for Wayland)"
  sudo rpm-ostree kargs \
    --append-if-missing=rd.driver.blacklist=nouveau \
    --append-if-missing=modprobe.blacklist=nouveau \
    --append-if-missing=nvidia-drm.modeset=1

  REBOOT_NEEDED=1
  warn "reboot required. Give akmods a few minutes after boot to build the module."
  warn "Verify with: modinfo -F version nvidia   and: nvidia-smi"
  warn "Hybrid laptops keep rendering on the iGPU — run individual apps with:"
  echo "    __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>"
}

install_font() {
  [[ $INSTALL_FONT -eq 1 ]] || return 0
  local dir="$HOME/.local/share/fonts/JetBrainsMonoNerdFont"
  if [[ -d "$dir" ]] && compgen -G "$dir/*.ttf" >/dev/null; then
    msg "Nerd Font already installed"
    return
  fi
  command -v unzip >/dev/null 2>&1 || { warn "unzip missing — skipping font"; return; }
  msg "installing JetBrainsMono Nerd Font (starship needs the glyphs)"
  local tmp; tmp=$(mktemp -d)
  if curl -fL --progress-bar --connect-timeout 15 --max-time 900 \
          --retry 3 --retry-delay 5 --speed-limit 1024 --speed-time 60 \
          "$FONT_URL" -o "$tmp/font.zip"; then
    mkdir -p "$dir"
    unzip -qo "$tmp/font.zip" -d "$dir" -x 'README*' 'LICENSE*'
    fc-cache -f "$dir" >/dev/null
  else
    warn "font download failed — re-run later, or install it by hand"
  fi
  rm -rf "$tmp"
}

# ------------------------------------------------------------------ run -----
install_homebrew
load_brew_env
if [[ "$METHOD" == "auto" ]]; then
  command -v brew >/dev/null 2>&1 && METHOD="brew" || METHOD="layer"
fi
msg "package method: $METHOD"

install_host_zsh
install_core_tools
install_dev_tools
install_mise
clone_config
write_zdotdir_hook
write_env_hook
write_local_zsh
make_dirs
set_login_shell
enable_podman_socket
provision_toolbox
install_font
setup_codecs
setup_fingerprint
setup_nvidia

echo
msg "done."
if [[ $REBOOT_NEEDED -eq 1 ]]; then
  warn "layered packages are staged — reboot, then re-run this script"
else
  echo "   Open a new terminal (or run 'exec zsh'). Plugins clone on first launch."
fi
echo "   Config:    $ZDOTDIR_PATH  (your overrides: local.zsh, git-ignored)"
echo "   Env:       ~/.zshenv      (shared with Toolbx via \$HOME)"
[[ $DO_TOOLBOX -eq 1 ]] && echo "   Container: toolbox enter $TOOLBOX_NAME"
command -v mise >/dev/null 2>&1 && echo "   Runtimes:  mise use -g node@lts ruby@3.3 go@latest"
command -v podman-tui >/dev/null 2>&1 && echo "   Containers: podman-tui   (rootless, host socket)"
