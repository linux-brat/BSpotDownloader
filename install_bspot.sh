#!/usr/bin/env bash
set -euo pipefail

# Linux-only installer for BSpotDownloader
# - Cleans previous install (launcher + local cache)
# - Installs dependencies if missing
# - Installs a launcher that fetches from fixed raw URLs on master
# - Preserves user config (~/.config/bspot/config)

# Fixed repo/URLs
RAW_BASE="https://raw.githubusercontent.com/linux-brat/BSpotDownloader/master"
RAW_SCRIPT="${RAW_BASE}/bspot.sh"
RAW_VERSION="${RAW_BASE}/VERSION"

# Paths
BIN_DIR="/usr/local/bin"
LAUNCHER_PATH="${BIN_DIR}/bspot"
ALIAS_PATH="${BIN_DIR}/bspotdownloader"
APP_HOME="${HOME}/.local/share/bspot"
APP_SCRIPT="${APP_HOME}/bspot.sh"
APP_VERSION_FILE="${APP_HOME}/VERSION"
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
  rm -f "${APP_SCRIPT}" "${APP_VERSION_FILE}" 2>/dev/null || true
  $SUDO rm -f "${LAUNCHER_PATH}" "${ALIAS_PATH}" 2>/dev/null || true
}

write_launcher() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

# BSpotDownloader launcher (Linux) — fixed raw URLs (master branch)

RAW_BASE="https://raw.githubusercontent.com/linux-brat/BSpotDownloader/master"
RAW_SCRIPT="${RAW_BASE}/bspot.sh"
RAW_VERSION="${RAW_BASE}/VERSION"

APP_HOME="${HOME}/.local/share/bspot"
APP_SCRIPT="${APP_HOME}/bspot.sh"
LOCAL_VER_FILE="${APP_HOME}/VERSION"

CONFIG_DIR="${HOME}/.config/bspot"
mkdir -p "$CONFIG_DIR" "$APP_HOME"

fetch_or_fail() {
  local url="$1" out="$2"
  if ! curl -fsSL "$url" -o "$out"; then
    echo "Cannot fetch BSpotDownloader from: $url"
    exit 1
  fi
}

update_always() {
  mkdir -p "$APP_HOME"
  local ts tv
  ts="$(mktemp)"; tv="$(mktemp)"
  echo "[bspot] Fetching: $RAW_SCRIPT"
  fetch_or_fail "$RAW_SCRIPT" "$ts"
  echo "[bspot] Fetching: $RAW_VERSION"
  fetch_or_fail "$RAW_VERSION" "$tv"
  chmod +x "$ts"
  mv "$ts" "$APP_SCRIPT"
  mv "$tv" "$LOCAL_VER_FILE"
}

update_always
exec "$APP_SCRIPT" "$@"
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
  say "Done. Run: bspot"
}

main "$@"
