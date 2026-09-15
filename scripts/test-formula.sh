#!/usr/bin/env bash
# Installs Formula/muster.rb with Homebrew and runs the formula's test block.
# The pull request check and the "Update formula" workflow run it on their
# runner; it works on any machine with Homebrew, macOS or Linux, for example
# after scripts/update-formula.sh.
#
# The checkout is linked into Homebrew's tap directory as giantswarm/muster,
# so the formula is resolved from the working tree, uncommitted changes
# included.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMULA="$ROOT/Formula/muster.rb"
TAP="giantswarm/muster"
NAME="$TAP/muster"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1

if ! command -v brew >/dev/null; then
  # GitHub's Ubuntu runners ship Homebrew outside PATH.
  for candidate in /home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
      eval "$("$candidate" shellenv)"
      break
    fi
  done
  command -v brew >/dev/null || { echo "error: Homebrew is required" >&2; exit 1; }
fi

ruby -c "$FORMULA" >/dev/null

tap_dir="$(brew --repository)/Library/Taps/giantswarm/homebrew-muster"
if [[ -e "$tap_dir" && "$(readlink -f "$tap_dir")" != "$ROOT" ]]; then
  echo "error: $tap_dir is not this checkout; 'brew untap $TAP' first" >&2
  exit 1
fi
mkdir -p "$(dirname "$tap_dir")"
ln -sfn "$ROOT" "$tap_dir"

# Homebrew loads formulae from a third-party tap only after `brew trust`;
# Homebrew versions without the command do not ask for it.
if brew trust --help >/dev/null 2>&1; then
  brew trust "$TAP"
fi

brew audit --strict --formula "$NAME"
if brew list --formula --versions muster >/dev/null 2>&1; then
  brew reinstall --formula "$NAME"
else
  brew install --formula "$NAME"
fi
brew test "$NAME"
"$(brew --prefix)/bin/muster" version
