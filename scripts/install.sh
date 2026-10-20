#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: bash install.sh [--skip-shell-change]' \
    'Install the radleylewis Zsh setup on Ubuntu/Debian or Oracle Linux 8/9.' \
    'Existing configuration files are backed up before replacement.' \
    'Run as your normal user, not with sudo. sudo is used for packages and chsh.'
}

change_shell=true
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --skip-shell-change) change_shell=false ;;
  '') ;;
  *) usage >&2; exit 1 ;;
esac
if (( $# > 1 )); then
  usage >&2
  exit 1
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
(( EUID != 0 )) || die 'Run as your normal user, not root.'
package_manager=apt
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
fi
if [[ "${ID:-}" == ol ]]; then
  oracle_version=${VERSION_ID:-}
  oracle_version=${oracle_version%%.*}
  case "$oracle_version" in
    8|9) ;;
    *) die "Unsupported Oracle Linux version: ${VERSION_ID:-unknown}. Expected 8 or 9." ;;
  esac
  command -v dnf >/dev/null || die 'Oracle Linux requires dnf.'
  package_manager=dnf
else
  command -v apt-get >/dev/null ||
    die 'This installer requires Ubuntu/Debian with apt-get or Oracle Linux 8/9 with dnf.'
fi
command -v sudo >/dev/null || die 'sudo is required for package installation.'

config_dir="$HOME/.config/zsh"
[[ -d "$config_dir" ]] ||
  die "Configuration repository not found at $config_dir. Clone it there before running this script."

export PATH="$HOME/.local/bin:$PATH"
work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT

replace_file() {
  local source=$1 target=$2 backup
  if [[ -e "$target" || -L "$target" ]]; then
    if cmp -s "$source" "$target"; then
      return
    fi
    [[ ! -d "$target" ]] || die "Expected a file, found directory: $target"
    backup=$(mktemp "${target}.backup.XXXXXXXX")
    cp -p -- "$target" "$backup"
    printf 'Backup: %s\n' "$backup"
    rm -- "$target"
  fi
  cp -- "$source" "$target"
}

printf 'Installing system packages...\n'
if [[ "$package_manager" == dnf ]]; then
  sudo dnf install -y "oracle-epel-release-el${oracle_version}"
  sudo dnf --enablerepo="ol${oracle_version}_developer_EPEL" \
    --enablerepo="ol${oracle_version}_codeready_builder" install -y \
    zsh git curl ca-certificates neovim bat fd-find fzf ripgrep util-linux-user tar gzip
else
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    zsh git curl ca-certificates neovim eza bat fd-find fzf ripgrep
fi

mkdir -p "$HOME/.local/bin" "$HOME/.local/state/zsh" "$HOME/.cache/zsh"
if [[ "$package_manager" == dnf ]] && ! command -v eza >/dev/null; then
  [[ "$(uname -m)" == x86_64 ]] ||
    die 'Automatic eza installation requires x86_64. Install eza manually and rerun.'
  # Use the static build because Oracle Linux 8 has an older glibc.
  curl -fsSL https://github.com/eza-community/eza/releases/latest/download/eza_x86_64-unknown-linux-musl.tar.gz \
    -o "$work_dir/eza.tar.gz"
  mkdir "$work_dir/eza"
  tar -xzf "$work_dir/eza.tar.gz" -C "$work_dir/eza"
  [[ -f "$work_dir/eza/eza" ]] || die 'eza binary not found in downloaded archive.'
  install -m 755 "$work_dir/eza/eza" "$HOME/.local/bin/eza"
fi
for tool in bat fd; do
  if ! command -v "$tool" >/dev/null; then
    case "$tool" in
      bat) executable=$(command -v batcat) ;;
      fd) executable=$(command -v fdfind) ;;
    esac
    target="$HOME/.local/bin/$tool"
    [[ ! -e "$target" && ! -L "$target" ]] ||
      die "Cannot create $target; an unusable file or link already exists."
    ln -s "$executable" "$target"
  fi
done

# Download fully before execution so a failed transfer cannot run a partial script.
if ! command -v zoxide >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \
    -o "$work_dir/zoxide-install.sh"
  sh "$work_dir/zoxide-install.sh"
fi
if ! command -v starship >/dev/null; then
  curl -fsSL https://starship.rs/install.sh -o "$work_dir/starship-install.sh"
  sh "$work_dir/starship-install.sh" --yes --bin-dir "$HOME/.local/bin"
fi

for tool in zsh git nvim eza bat fd fzf rg zoxide starship; do
  command -v "$tool" >/dev/null || die "Required executable not found: $tool"
done

for file in .zshenv .zshrc aliases.zsh bindings.zsh fzf.zsh plugins.zsh prompt.zsh; do
  [[ -f "$config_dir/$file" ]] || die "Missing configuration: $config_dir/$file"
  zsh -n "$config_dir/$file"
done
[[ -f "$config_dir/starship.toml" ]] || die "Missing configuration: $config_dir/starship.toml"

cat > "$work_dir/zshenv" <<'EOF'
export XDG_CONFIG_HOME="$HOME/.config"
export ZDOTDIR="$XDG_CONFIG_HOME/zsh"
source "$ZDOTDIR/.zshenv"
EOF
replace_file "$work_dir/zshenv" "$HOME/.zshenv"

cat > "$work_dir/preferences.zsh" <<'EOF'
alias ls='eza --icons=never'
alias ll='eza -lh --icons=never --git'
alias la='eza -lah --icons=never --git'
alias tree='eza --tree --icons=never'
EOF
replace_file "$work_dir/preferences.zsh" "$config_dir/installer-preferences.zsh"

local_config="$config_dir/local.zsh"
preferences_line='source "$ZDOTDIR/installer-preferences.zsh"'
if [[ -e "$local_config" || -L "$local_config" ]]; then
  [[ -f "$local_config" ]] || die "Not a regular file: $local_config"
  cp -- "$local_config" "$work_dir/local.zsh"
else
  : > "$work_dir/local.zsh"
fi
if ! grep -Fxq "$preferences_line" "$work_dir/local.zsh"; then
  printf '\n%s\n' "$preferences_line" >> "$work_dir/local.zsh"
fi
zsh -n "$work_dir/local.zsh"
replace_file "$work_dir/local.zsh" "$local_config"

cp -- "$config_dir/starship.toml" "$work_dir/starship.toml"
replace_file "$work_dir/starship.toml" "$config_dir/starship.toml"

printf 'Installing and checking plugins...\n'
ZDOTDIR="$config_dir" zsh -f -c '
  source "$ZDOTDIR/plugins.zsh" || exit 1
  for plugin in zsh-autosuggestions zsh-history-substring-search zsh-vi-mode fast-syntax-highlighting; do
    [[ -s "$ZDOTDIR/plugins/$plugin/$plugin.plugin.zsh" ]] || exit 1
  done
'
STARSHIP_CONFIG="$config_dir/starship.toml" starship prompt > "$work_dir/prompt"

if "$change_shell"; then
  user=$(id -un)
  shell=$(command -v zsh)
  current_shell=$(getent passwd "$user" | cut -d: -f7)
  if [[ "$current_shell" != "$shell" ]]; then
    sudo chsh -s "$shell" "$user"
  fi
  [[ "$(getent passwd "$user" | cut -d: -f7)" == "$shell" ]] ||
    die 'The default login shell was not changed successfully.'
fi

printf '\nSetup complete. Open a fresh Zsh terminal.\n'
printf 'In VS Code: Terminal: Select Default Profile -> zsh, then create a new terminal.\n'
printf 'Configuration: %s\n' "$config_dir"
printf 'Work directory: %s\n' "$work_dir"
