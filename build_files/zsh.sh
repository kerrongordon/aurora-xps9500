#!/bin/bash
set -euo pipefail

# Bundle the tools required by radleylewis/zsh for an offline first launch.
dnf5 install -y zsh git neovim eza bat fd-find fzf zoxide ripgrep
if ! command -v starship >/dev/null; then
    dnf5 -y copr enable atim/starship
    dnf5 install -y starship
    dnf5 -y copr disable atim/starship
fi

# Plasma Setup calls useradd -m without overriding the default login shell.
useradd -D -s /bin/zsh
useradd -D | grep -Fx 'SHELL=/bin/zsh'
grep -Fx /bin/zsh /etc/shells

# Keep Git metadata so the upstream zplugin-update command remains usable.
while read -r repository revision; do
    plugin="${repository##*/}"
    destination="/etc/skel/.config/zsh/plugins/$plugin"
    git clone "https://github.com/$repository.git" "$destination"
    git -C "$destination" reset --hard "$revision"
    test "$(git -C "$destination" rev-parse HEAD)" = "$revision"
    test -f "$destination/$plugin.plugin.zsh"
done <<'EOF'
zsh-users/zsh-autosuggestions 85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5
zsh-users/zsh-history-substring-search 349f731e321d643558652bf3a64a8b5263ed5fb1
jeffreytse/zsh-vi-mode 91cafe4a09b6670cb8e761aa413e5f7b9e00816f
zdharma-continuum/fast-syntax-highlighting 4672ad5dd9ad68a7effc1476d65afb7c584ce2b3
EOF

for tool in zsh git nvim eza bat fd fzf zoxide rg starship; do
    command -v "$tool"
done
for config in /etc/skel/.zshenv /etc/skel/.config/zsh/.zshenv \
    /etc/skel/.config/zsh/.zshrc /etc/skel/.config/zsh/*.zsh; do
    zsh -n "$config"
done

# Exercise startup with a fresh home, without inheriting the builder's config.
test_home=$(mktemp -d)
trap 'rm -rf "$test_home"' EXIT
cp -a /etc/skel/. "$test_home/"
env -i HOME="$test_home" PATH=/usr/bin:/bin TERM=xterm-256color \
    script --quiet --return --command 'zsh -i -c '\''
        [[ "$ZDOTDIR" = "$HOME/.config/zsh" ]] &&
        [[ -d "$XDG_STATE_HOME/zsh" && -d "$XDG_CACHE_HOME/zsh" ]] &&
        (( $+functions[compdef] && $+functions[_zplugin_load] &&
           $+functions[zvm_after_init] && $+widgets[fzf-history-widget] &&
           $+widgets[history-substring-search-up] )) &&
        starship prompt >/dev/null
    '\''' /dev/null </dev/null
