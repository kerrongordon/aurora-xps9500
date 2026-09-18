# Upstream configuration

Source: https://github.com/radleylewis/zsh
Revision: aa9e030b932d844ca5f8915a3aa51db18e079ca5
License: MIT (see LICENSE).

Adaptations: Fedora fzf integration, create history/cache directories on startup,
respect existing XDG paths, only query tty when attached to one, and correct
Starship's invalid #blue color to blue. Plugins are seeded at image build time.
Personal additions belong in local.zsh. New accounts receive their own editable
copy via /etc/skel; existing accounts are not overwritten by image updates.
