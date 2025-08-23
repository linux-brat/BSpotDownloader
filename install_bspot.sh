#!/usr/bin/env bash
set -euo pipefail

# Linux-only installer for BSpotDownloader
# - Cleans previous install (launcher + local cache)
# - Installs dependencies if missing
# - Installs launcher that fetches bspot.sh from master (no VERSION file)
# - Preserves ~/.config/bspot/config
#
# Repo raw URL (fixed):
RAW_SCRIPT_URL="https://raw.githubusercontent.com/linux-brat/BSpotDownloader/master/bspot.sh"

# Paths
BIN_DIR="/usr/local/bin"
LAUNCHER_PATH="${BIN_DIR}/bspot"
ALIAS_PATH="${BIN_DIR}/bspotdownloader"
APP_HOME="${HOME}/.local/share/bspot"
APP_SCRIPT="${APP_HOME}/bspot.sh"
CONFIG_DIR="${HOME}/.config/bspot"
CONFIG_FILE="${CONFIG_DIR}/config"

die(){ echo "Error: $*" >&2; exit 1; }
say(){ echo "[*] $*"; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

need_sudo() {
  if [ ! -w "$BIN_DIR" ]; then
    have_cmd sudo || die "sudo is required to write to ${BIN_DIR}"
    SUDO="sudo"
  else
    SUDO=""
  fi
}

install_pkg_linux() {
  if have_cmd apt-get; then
    sudo apt-get update -y
    sudo apt-get install -y "$@"
  elif have_cmd dnf; then
    sudo dnf install -y "$@"
  elif have_cmd yum; then
    sudo yum install -y "$@"
  elif have_cmd pacman; then
    sudo pacman -Sy --noconfirm "$@"
  elif have_cmd zypper; then
    sudo zypper install -y "$@"
  else
    say "Auto install not supported; please install manually: $*"
  fi
}

ensure_dep() {
  local cmd="$1" pkg="$2"
  if ! have_cmd "$cmd"; then
    say "Installing: $cmd"
    install_pkg_linux "$pkg" || true
    have_cmd "$cmd" || die "Missing dependency: $cmd"
  fi
}

ensure_deps() {
  ensure_dep curl curl
  ensure_dep jq jq
  ensure_dep ffmpeg ffmpeg
  if ! have_cmd yt-dlp; then
    say "Installing yt-dlp"
    if have_cmd apt-get; then sudo apt-get install -y yt-dlp || true
    elif have_cmd dnf; then sudo dnf install -y yt-dlp || true
    elif have_cmd pacman; then sudo pacman -Sy --noconfirm yt-dlp || true
    elif have_cmd zypper; then sudo zypper install -y yt-dlp || true
    fi
    if ! have_cmd yt-dlp; then
      if have_cmd pipx; then pipx install yt-dlp || pipx upgrade yt-dlp || true
      elif have_cmd pip3; then pip3 install --user -U yt-dlp; export PATH="$HOME/.local/bin:$PATH"
      fi
    fi
    have_cmd yt-dlp || die "yt-dlp is required"
  fi
}

cleanup_old() {
  say "Cleaning previous install (safe)…"
  rm -f "${APP_SCRIPT}" 2>/dev/null || true
  $SUDO rm -f "${LAUNCHER_PATH}" "${ALIAS_PATH}" 2>/dev/null || true
}

write_launcher() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

# BSpotDownloader launcher (Linux) — fixed raw URL (master)
RAW_SCRIPT_URL="https://raw.githubusercontent.com/linux-brat/BSpotDownloader/master/bspot.sh"

APP_HOME="${HOME}/.local/share/bspot"
APP_SCRIPT="${APP_HOME}/bspot.sh"
CONFIG_DIR="${HOME}/.config/bspot"

usage() {
  cat <<EOF
BSpotDownloader launcher

Usage:
  bspot                 Launch the app menu
  bspot <url>           Process a single URL directly
  bspot --uninstall     Remove launcher, cache, and keep/remove config interactively
  bspot -h | --help     Show this help
EOF
}

fetch_fresh() {
  mkdir -p "$APP_HOME"
  local ts; ts="$(mktemp)"
  echo "[bspot] Fetching: $RAW_SCRIPT_URL"
  if ! curl -fsSL "$RAW_SCRIPT_URL" -o "$ts"; then
    echo "Cannot fetch BSpotDownloader from: $RAW_SCRIPT_URL"
    exit 1
  fi
  chmod +x "$ts"
  mv "$ts" "$APP_SCRIPT"
}

cmd_uninstall() {
  echo "Uninstalling BSpotDownloader…"
  # remove launcher and alias
  if [ -w "/usr/local/bin" ]; then SUDO=""; else command -v sudo >/dev/null 2>&1 && SUDO="sudo" || SUDO=""; fi
  $SUDO rm -f /usr/local/bin/bspot /usr/local/bin/bspotdownloader 2>/dev/null || true
  # remove local app cache
  rm -rf "$APP_HOME"
  # ask about config
  if [ -d "$CONFIG_DIR" ]; then
    read -r -p "Remove user config at $CONFIG_DIR? [y/N] " ans
    case "${ans,,}" in y|yes) rm -rf "$CONFIG_DIR"; echo "Config removed." ;; *) echo "Config kept." ;; esac
  fi
  echo "Uninstalled."
  exit 0
}

main() {
  mkdir -p "$CONFIG_DIR" "$APP_HOME"
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --uninstall) cmd_uninstall ;;
    *) ;;
  esac

  # Always fetch fresh script (since no VERSION file used)
  fetch_fresh

  # Forward execution to the app script with original args
  exec "$APP_SCRIPT" "$@"
}

main "$@"
LAUNCHER
  chmod +x "$tmp"
  $SUDO mv "$tmp" "$LAUNCHER_PATH"
  $SUDO ln -sf "$LAUNCHER_PATH" "$ALIAS_PATH"
  say "Installed launcher: $LAUNCHER_PATH (alias: $ALIAS_PATH)"
}

ensure_user_config() {
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "=== BSpotDownloader first-time setup ==="
    read -r -p "Spotify Client ID: " cid
    read -r -p "Spotify Client Secret: " csec
    {
      echo "SPOTIFY_CLIENT_ID=\"$cid\""
      echo "SPOTIFY_CLIENT_SECRET=\"$csec\""
      echo "DOWNLOADS_DIR=\"$HOME/Downloads/BSpotDownloader\""
      echo "YTDLP_SEARCH_COUNT=\"1\""
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    say "Saved: $CONFIG_FILE"
  else
    say "Using existing config: $CONFIG_FILE"
  fi
}

main() {
  need_sudo
  ensure_deps
  cleanup_old
  write_launcher
  ensure_user_config
  say "Done. Run: bspot  (or: bspotdownloader)"
}

main "$@"
